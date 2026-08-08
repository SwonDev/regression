#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <iostream>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

struct Arguments {
  std::string Helper;
  std::string HostHome;
  std::string ChildOutput;
  std::string ChildError;
  std::vector<std::string> HelperArguments;
  bool Valid {};
};

Arguments ParseArguments(int argc, char *argv[]) {
  Arguments result;
  if (argc < 9 || argc % 2 == 0 || argv == nullptr) {
    return result;
  }
  for (int index = 1; index < argc; index += 2) {
    if (argv[index] == nullptr || argv[index + 1] == nullptr) {
      return result;
    }
    const std::string_view option {argv[index]};
    if (option == "--helper") {
      result.Helper = argv[index + 1];
    } else if (option == "--host-home") {
      result.HostHome = argv[index + 1];
    } else if (option == "--child-output") {
      result.ChildOutput = argv[index + 1];
    } else if (option == "--child-error") {
      result.ChildError = argv[index + 1];
    } else if (option == "--helper-arg") {
      result.HelperArguments.emplace_back(argv[index + 1]);
    } else {
      return result;
    }
  }
  result.Valid = !result.Helper.empty()
    && !result.HostHome.empty()
    && !result.ChildOutput.empty()
    && !result.ChildError.empty()
    && result.Helper.front() == '/'
    && result.HostHome.front() == '/'
    && result.ChildOutput.front() == '/'
    && result.ChildError.front() == '/'
    && result.HelperArguments.size() <= 32;
  for (const std::string &argument : result.HelperArguments) {
    result.Valid = result.Valid && argument.size() <= 4096;
  }
  return result;
}

bool IsRegularExecutable(const std::string &path) {
  struct stat status {};
  return lstat(path.c_str(), &status) == 0
    && S_ISREG(status.st_mode)
    && (status.st_mode & S_IXUSR) != 0;
}

bool IsDirectory(const std::string &path) {
  struct stat status {};
  return lstat(path.c_str(), &status) == 0 && S_ISDIR(status.st_mode);
}

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

struct Result {
  bool workerReady {};
  bool workerBlockingAtSpawn {};
  bool pipeCloseOnExec {};
  bool outputsOpened {};
  bool fileActionsInitialized {};
  bool outputRedirected {};
  bool errorRedirected {};
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

Result RunSupervisor(const Arguments &arguments) {
  Result result;
  const int outputDescriptor = open(
    arguments.ChildOutput.c_str(),
    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
    S_IRUSR | S_IWUSR);
  const int errorDescriptor = open(
    arguments.ChildError.c_str(),
    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
    S_IRUSR | S_IWUSR);
  result.outputsOpened = outputDescriptor >= 0 && errorDescriptor >= 0;
  if (!result.outputsOpened) {
    const int savedError = errno;
    if (outputDescriptor >= 0) {
      close(outputDescriptor);
    }
    if (errorDescriptor >= 0) {
      close(errorDescriptor);
    }
    result.spawnResult = savedError;
    return result;
  }

  int workerPipe[2] {-1, -1};
  int readyPipe[2] {-1, -1};
  if (pipe(workerPipe) != 0 || pipe(readyPipe) != 0) {
    result.spawnResult = errno;
    if (workerPipe[0] >= 0) {
      close(workerPipe[0]);
      close(workerPipe[1]);
    }
    if (readyPipe[0] >= 0) {
      close(readyPipe[0]);
      close(readyPipe[1]);
    }
    close(outputDescriptor);
    close(errorDescriptor);
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
    setupResult = posix_spawn_file_actions_adddup2(
      &fileActions, outputDescriptor, STDOUT_FILENO);
    result.outputRedirected = setupResult == 0;
  }
  if (setupResult == 0) {
    setupResult = posix_spawn_file_actions_adddup2(
      &fileActions, errorDescriptor, STDERR_FILENO);
    result.errorRedirected = setupResult == 0;
  }
  if (setupResult == 0) {
    for (const int descriptor : {
           workerPipe[0], workerPipe[1], readyPipe[0], readyPipe[1],
           outputDescriptor, errorDescriptor}) {
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
    std::vector<char *> childArguments;
    childArguments.reserve(arguments.HelperArguments.size() + 2);
    childArguments.push_back(const_cast<char *>(arguments.Helper.c_str()));
    for (const std::string &argument : arguments.HelperArguments) {
      childArguments.push_back(const_cast<char *>(argument.c_str()));
    }
    childArguments.push_back(nullptr);
    const std::string homeEnvironment = "HOME=" + arguments.HostHome;
    char localeEnvironment[] = "LC_ALL=C";
    char *childEnvironment[] = {
      localeEnvironment,
      const_cast<char *>(homeEnvironment.c_str()),
      nullptr,
    };
    result.spawnResult = posix_spawn(
      &childPid,
      arguments.Helper.c_str(),
      &fileActions,
      &attributes,
      childArguments.data(),
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
  close(outputDescriptor);
  close(errorDescriptor);

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

  const Arguments arguments = ParseArguments(argc, argv);
  if (!arguments.Valid
      || !IsRegularExecutable(arguments.Helper)
      || !IsDirectory(arguments.HostHome)) {
    std::cerr << "Argumentos o recursos del ayudante no válidos.\n";
    return 64;
  }

  const Result result = RunSupervisor(arguments);
  const bool passed = result.workerReady
    && result.workerBlockingAtSpawn
    && result.pipeCloseOnExec
    && result.outputsOpened
    && result.fileActionsInitialized
    && result.outputRedirected
    && result.errorRedirected
    && result.spawnAttributesInitialized
    && result.signalMaskExplicit
    && result.signalDefaultsExplicit
    && result.spawnResult == 0
    && result.spawnedPidPositive
    && result.waitpidSuccess
    && result.waitpidMatchesSpawnedPid
    && result.childExited
    && result.childExitCode == 0
    && result.workerReleased
    && result.workerJoined;

  std::cout << "{"
            << "\"schema\":1,"
            << "\"host\":\"macos-arm64\","
            << "\"probe\":\"posix-spawn-external-helper\","
            << "\"multithreaded_host\":";
  PrintBoolean(result.workerReady && result.workerBlockingAtSpawn);
  std::cout << ",\"worker_ready\":";
  PrintBoolean(result.workerReady);
  std::cout << ",\"worker_blocking_at_spawn\":";
  PrintBoolean(result.workerBlockingAtSpawn);
  std::cout << ",\"pipe_close_on_exec\":";
  PrintBoolean(result.pipeCloseOnExec);
  std::cout << ",\"outputs_opened\":";
  PrintBoolean(result.outputsOpened);
  std::cout << ",\"file_actions_initialized\":";
  PrintBoolean(result.fileActionsInitialized);
  std::cout << ",\"child_stdout_redirected\":";
  PrintBoolean(result.outputRedirected);
  std::cout << ",\"child_stderr_redirected\":";
  PrintBoolean(result.errorRedirected);
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
            << ",\"explicit_argument_count\":"
            << (arguments.HelperArguments.size() + 1)
            << ",\"explicit_environment_count\":2"
            << ",\"explicit_environment_lc_all_c\":true"
            << ",\"explicit_environment_private_host_home\":true"
            << ",\"worker_released\":";
  PrintBoolean(result.workerReleased);
  std::cout << ",\"worker_joined\":";
  PrintBoolean(result.workerJoined);
  std::cout << ",\"passed\":";
  PrintBoolean(passed);
  std::cout << "}\n";
  return passed ? 0 : 1;
}
