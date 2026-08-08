#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <string_view>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char **environ;

namespace {

constexpr int kChildSuccessExitCode = 42;
constexpr std::string_view kChildArgument = "--child";
constexpr std::string_view kLocaleEnvironment = "LC_ALL=C";
constexpr std::string_view kHomeEnvironment = "HOME=/home/regression";

bool SetCloseOnExec(int descriptor) {
  const int flags = fcntl(descriptor, F_GETFD);
  return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0;
}

bool ReadByte(int descriptor) {
  char value {};
  while (true) {
    const ssize_t result = read(descriptor, &value, sizeof(value));
    if (result == 1) {
      return true;
    }
    if (result < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
}

bool WriteByte(int descriptor) {
  const char value = 'x';
  while (true) {
    const ssize_t result = write(descriptor, &value, sizeof(value));
    if (result == 1) {
      return true;
    }
    if (result < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
}

std::string ExecutablePath() {
  char path[PATH_MAX] {};
  uint32_t size = sizeof(path);
  if (_NSGetExecutablePath(path, &size) != 0) {
    return {};
  }

  char canonical[PATH_MAX] {};
  if (realpath(path, canonical) == nullptr) {
    return {};
  }
  return canonical;
}

int RunChild(int argc, char *argv[]) {
  if (argc != 2 || argv == nullptr || argv[0] == nullptr || argv[1] == nullptr
      || std::string_view {argv[1]} != kChildArgument) {
    return 91;
  }

  size_t environmentCount = 0;
  bool localePresent = false;
  bool homePresent = false;
  if (environ == nullptr) {
    return 92;
  }

  for (char **entry = environ; *entry != nullptr; ++entry) {
    ++environmentCount;
    const std::string_view value {*entry};
    localePresent = localePresent || value == kLocaleEnvironment;
    homePresent = homePresent || value == kHomeEnvironment;
    if (environmentCount > 2) {
      return 93;
    }
  }

  if (environmentCount != 2 || !localePresent || !homePresent) {
    return 94;
  }
  return kChildSuccessExitCode;
}

struct Result {
  bool workerReady {};
  bool workerBlockingAtSpawn {};
  bool pipeCloseOnExec {};
  bool fileActionsInitialized {};
  bool spawnAttributesInitialized {};
  bool signalMaskExplicit {};
  bool signalDefaultsExplicit {};
  int spawnResult {-1};
  bool spawnedPidPositive {};
  bool waitpidSuccess {};
  bool waitpidMatchesSpawnedPid {};
  bool childExited {};
  int childExitCode {-1};
  bool workerReleased {};
  bool workerJoined {};
};

Result RunParent(const std::string &executable) {
  Result result;
  int workerPipe[2] {-1, -1};
  int readyPipe[2] {-1, -1};

  if (pipe(workerPipe) != 0 || pipe(readyPipe) != 0) {
    if (workerPipe[0] >= 0) {
      close(workerPipe[0]);
      close(workerPipe[1]);
    }
    if (readyPipe[0] >= 0) {
      close(readyPipe[0]);
      close(readyPipe[1]);
    }
    result.spawnResult = errno;
    return result;
  }

  result.pipeCloseOnExec = SetCloseOnExec(workerPipe[0])
    && SetCloseOnExec(workerPipe[1])
    && SetCloseOnExec(readyPipe[0])
    && SetCloseOnExec(readyPipe[1]);

  std::atomic<bool> workerBlocking {false};
  std::thread worker([&] {
    workerBlocking.store(true, std::memory_order_release);
    static_cast<void>(WriteByte(readyPipe[1]));
    static_cast<void>(ReadByte(workerPipe[0]));
  });

  result.workerReady = ReadByte(readyPipe[0]);
  result.workerBlockingAtSpawn = workerBlocking.load(std::memory_order_acquire);

  posix_spawn_file_actions_t fileActions;
  int setupResult = posix_spawn_file_actions_init(&fileActions);
  result.fileActionsInitialized = setupResult == 0;
  if (setupResult == 0) {
    for (const int descriptor : {workerPipe[0], workerPipe[1], readyPipe[0], readyPipe[1]}) {
      setupResult = posix_spawn_file_actions_addclose(&fileActions, descriptor);
      if (setupResult != 0) {
        break;
      }
    }
  }

  posix_spawnattr_t attributes;
  if (setupResult == 0) {
    setupResult = posix_spawnattr_init(&attributes);
    result.spawnAttributesInitialized = setupResult == 0;
  }

  if (setupResult == 0) {
    sigset_t emptySignals;
    if (sigemptyset(&emptySignals) != 0) {
      setupResult = errno;
    } else {
      setupResult = posix_spawnattr_setsigmask(&attributes, &emptySignals);
      result.signalMaskExplicit = setupResult == 0;
      if (setupResult == 0) {
        setupResult = posix_spawnattr_setsigdefault(&attributes, &emptySignals);
        result.signalDefaultsExplicit = setupResult == 0;
      }
    }
  }

  if (setupResult == 0) {
    const short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    setupResult = posix_spawnattr_setflags(&attributes, flags);
  }

  pid_t childPid = -1;
  if (setupResult == 0) {
    char childArgument[] = "--child";
    char *childArguments[] = {
      const_cast<char *>(executable.c_str()),
      childArgument,
      nullptr,
    };
    char localeEnvironment[] = "LC_ALL=C";
    char homeEnvironment[] = "HOME=/home/regression";
    char *childEnvironment[] = {
      localeEnvironment,
      homeEnvironment,
      nullptr,
    };
    result.spawnResult = posix_spawn(
      &childPid,
      executable.c_str(),
      &fileActions,
      &attributes,
      childArguments,
      childEnvironment);
    result.spawnedPidPositive = result.spawnResult == 0 && childPid > 0;
  } else {
    result.spawnResult = setupResult;
  }

  if (result.spawnAttributesInitialized) {
    static_cast<void>(posix_spawnattr_destroy(&attributes));
  }
  if (result.fileActionsInitialized) {
    static_cast<void>(posix_spawn_file_actions_destroy(&fileActions));
  }

  if (result.spawnedPidPositive) {
    int status = 0;
    pid_t waited = -1;
    do {
      waited = waitpid(childPid, &status, 0);
    } while (waited < 0 && errno == EINTR);
    result.waitpidSuccess = waited > 0;
    result.waitpidMatchesSpawnedPid = waited == childPid;
    result.childExited = waited == childPid && WIFEXITED(status);
    if (result.childExited) {
      result.childExitCode = WEXITSTATUS(status);
    }
  }

  result.workerReleased = WriteByte(workerPipe[1]);
  worker.join();
  result.workerJoined = true;

  close(workerPipe[0]);
  close(workerPipe[1]);
  close(readyPipe[0]);
  close(readyPipe[1]);
  return result;
}

void PrintBoolean(bool value) {
  std::cout << (value ? "true" : "false");
}

}  // namespace

int main(int argc, char *argv[]) {
#if !defined(__APPLE__) || !defined(__aarch64__)
#error "Esta sonda solo puede compilarse para macOS arm64."
#endif

  if (argc == 2 && argv != nullptr && argv[1] != nullptr
      && std::string_view {argv[1]} == kChildArgument) {
    return RunChild(argc, argv);
  }

  const std::string executable = ExecutablePath();
  if (executable.empty()) {
    std::cerr << "No se pudo resolver la ruta canónica de la sonda.\n";
    return 70;
  }

  const Result result = RunParent(executable);
  const bool passed = result.workerReady
    && result.workerBlockingAtSpawn
    && result.pipeCloseOnExec
    && result.fileActionsInitialized
    && result.spawnAttributesInitialized
    && result.signalMaskExplicit
    && result.signalDefaultsExplicit
    && result.spawnResult == 0
    && result.spawnedPidPositive
    && result.waitpidSuccess
    && result.waitpidMatchesSpawnedPid
    && result.childExited
    && result.childExitCode == kChildSuccessExitCode
    && result.workerReleased
    && result.workerJoined;

  std::cout << "{"
            << "\"schema\":1,"
            << "\"host\":\"macos-arm64\","
            << "\"probe\":\"posix-spawn-supervisor\","
            << "\"multithreaded_host\":";
  PrintBoolean(result.workerReady && result.workerBlockingAtSpawn);
  std::cout << ",\"worker_ready\":";
  PrintBoolean(result.workerReady);
  std::cout << ",\"worker_blocking_at_spawn\":";
  PrintBoolean(result.workerBlockingAtSpawn);
  std::cout << ",\"pipe_close_on_exec\":";
  PrintBoolean(result.pipeCloseOnExec);
  std::cout << ",\"file_actions_initialized\":";
  PrintBoolean(result.fileActionsInitialized);
  std::cout << ",\"spawn_attributes_initialized\":";
  PrintBoolean(result.spawnAttributesInitialized);
  std::cout << ",\"spawn_signal_mask_explicit\":";
  PrintBoolean(result.signalMaskExplicit);
  std::cout << ",\"spawn_signal_defaults_explicit\":";
  PrintBoolean(result.signalDefaultsExplicit);
  std::cout << ",\"spawn_result\":" << result.spawnResult
            << ",\"spawned_pid_positive\":";
  PrintBoolean(result.spawnedPidPositive);
  std::cout << ",\"waitpid_success\":";
  PrintBoolean(result.waitpidSuccess);
  std::cout << ",\"waitpid_matches_spawned_pid\":";
  PrintBoolean(result.waitpidMatchesSpawnedPid);
  std::cout << ",\"child_exited\":";
  PrintBoolean(result.childExited);
  std::cout << ",\"child_exit_code\":" << result.childExitCode
            << ",\"child_contract_passed\":";
  PrintBoolean(result.childExitCode == kChildSuccessExitCode);
  std::cout << ",\"explicit_argument_count\":2"
            << ",\"explicit_environment_count\":2"
            << ",\"explicit_environment_lc_all_c\":true"
            << ",\"explicit_environment_private_home\":true"
            << ",\"worker_released\":";
  PrintBoolean(result.workerReleased);
  std::cout << ",\"worker_joined\":";
  PrintBoolean(result.workerJoined);
  std::cout << ",\"fex_executed\":false"
            << ",\"wine_executed\":false"
            << ",\"proton_executed\":false"
            << ",\"steam_executed\":false"
            << ",\"game_executed\":false"
            << ",\"eac_executed\":false"
            << ",\"passed\":";
  PrintBoolean(passed);
  std::cout << "}\n";
  return passed ? 0 : 1;
}
