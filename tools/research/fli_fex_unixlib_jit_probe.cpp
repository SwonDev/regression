// SPDX-License-Identifier: MIT
// Controlled MAP_JIT/W^X probe for Regression's public FEX UnixLib Darwin port.

#include "FEXUnixLib.h"

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <sys/mman.h>
#include <unistd.h>

namespace {
using NTSTATUS = int32_t;
using UnixLibEntry = NTSTATUS (*)(void*);
using JITFunction = int (*)();

constexpr NTSTATUS STATUS_SUCCESS = 0;
constexpr NTSTATUS STATUS_INVALID_PARAMETER = static_cast<NTSTATUS>(0xC000000Du);
constexpr NTSTATUS STATUS_NOT_SUPPORTED = static_cast<NTSTATUS>(0xC00000BBu);

bool ExpectStatus(const char* Name, NTSTATUS Actual, NTSTATUS Expected) {
  if (Actual == Expected) {
    std::cout << "PASS " << Name << " status=0x" << std::hex << static_cast<uint32_t>(Actual) << std::dec << '\n';
    return true;
  }

  std::cerr << "FAIL " << Name << " actual=0x" << std::hex << static_cast<uint32_t>(Actual) << " expected=0x"
            << static_cast<uint32_t>(Expected) << std::dec << '\n';
  return false;
}

NTSTATUS Call(UnixLibEntry* Functions, FEXUnixLibFunctions Function, void* Args) {
  return Functions[static_cast<uint32_t>(Function)](Args);
}
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: fli_fex_unixlib_jit_probe /absolute/path/to/libarm64ecfex.so\n";
    return 64;
  }

  void* Library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!Library) {
    std::cerr << "dlopen failed: " << dlerror() << '\n';
    return 65;
  }

  auto* Functions = reinterpret_cast<UnixLibEntry*>(dlsym(Library, "__wine_unix_call_funcs"));
  if (!Functions) {
    std::cerr << "dlsym failed: " << dlerror() << '\n';
    dlclose(Library);
    return 66;
  }

  bool Passed = true;
  const long PageSizeResult = sysconf(_SC_PAGESIZE);
  if (PageSizeResult <= 0) {
    std::cerr << "FAIL page-size\n";
    dlclose(Library);
    return 67;
  }
  const size_t PageSize = static_cast<size_t>(PageSizeResult);

  FEXUnixLib_AllocateJITMemory InvalidAllocation {.Base = nullptr, .Size = 0};
  Passed &= ExpectStatus("jit-allocate-rejects-zero",
                         Call(Functions, FEXUnixLibFunctions::AllocateJITMemory, &InvalidAllocation),
                         STATUS_INVALID_PARAMETER);

  FEXUnixLib_AllocateJITMemory Allocation {.Base = nullptr, .Size = PageSize * 2};
  const NTSTATUS AllocationStatus = Call(Functions, FEXUnixLibFunctions::AllocateJITMemory, &Allocation);
  Passed &= ExpectStatus("jit-allocate-map-jit", AllocationStatus, STATUS_SUCCESS);
  if (AllocationStatus != STATUS_SUCCESS || !Allocation.Base) {
    std::cerr << "FAIL jit-allocate returned no address\n";
    dlclose(Library);
    return 1;
  }

  FEXUnixLib_SetJITWriteProtection Writable {.Enabled = 0};
  Passed &= ExpectStatus("jit-write-window-open",
                         Call(Functions, FEXUnixLibFunctions::SetJITWriteProtection, &Writable),
                         STATUS_SUCCESS);

  // arm64: mov w0, #42; ret
  constexpr uint32_t Code[] = {0x52800540u, 0xD65F03C0u};
  std::memcpy(Allocation.Base, Code, sizeof(Code));

  FEXUnixLib_SetJITWriteProtection Executable {.Enabled = 1};
  Passed &= ExpectStatus("jit-write-window-close",
                         Call(Functions, FEXUnixLibFunctions::SetJITWriteProtection, &Executable),
                         STATUS_SUCCESS);
  __builtin___clear_cache(static_cast<char*>(Allocation.Base), static_cast<char*>(Allocation.Base) + sizeof(Code));

  const int Result = reinterpret_cast<JITFunction>(Allocation.Base)();
  if (Result == 42) {
    std::cout << "PASS jit-execute result=42\n";
  } else {
    std::cerr << "FAIL jit-execute result=" << Result << " expected=42\n";
    Passed = false;
  }

  auto* GuardPage = static_cast<uint8_t*>(Allocation.Base) + PageSize;
  FEXUnixLib_ProtectJITMemory Guard {
    .Base = GuardPage,
    .Size = PageSize,
    .Protection = 0,
    .Pad = 0,
  };
  errno = 0;
  Passed &= ExpectStatus("jit-guard-page-none", Call(Functions, FEXUnixLibFunctions::ProtectJITMemory, &Guard), STATUS_SUCCESS);
  if (errno != 0) {
    std::cout << "INFO jit-guard-page-none errno=" << errno << '\n';
  }

  Guard.Protection = FEX_JIT_PROT_READ | FEX_JIT_PROT_WRITE | FEX_JIT_PROT_EXEC;
  errno = 0;
  Passed &= ExpectStatus("jit-guard-page-restore-rejected",
                         Call(Functions, FEXUnixLibFunctions::ProtectJITMemory, &Guard),
                         STATUS_NOT_SUPPORTED);
  if (errno != 0) {
    std::cout << "INFO jit-guard-page-restore errno=" << errno << '\n';
  }

  FEXUnixLib_ProtectJITMemory Unowned {
    .Base = reinterpret_cast<void*>(PageSize),
    .Size = PageSize,
    .Protection = FEX_JIT_PROT_READ,
    .Pad = 0,
  };
  Passed &= ExpectStatus("jit-protect-rejects-unowned",
                         Call(Functions, FEXUnixLibFunctions::ProtectJITMemory, &Unowned),
                         STATUS_NOT_SUPPORTED);

  FEXUnixLib_FreeJITMemory Free {.Base = Allocation.Base, .Size = Allocation.Size};
  Passed &= ExpectStatus("jit-free-owned", Call(Functions, FEXUnixLibFunctions::FreeJITMemory, &Free), STATUS_SUCCESS);
  Passed &= ExpectStatus("jit-free-rejects-stale", Call(Functions, FEXUnixLibFunctions::FreeJITMemory, &Free), STATUS_NOT_SUPPORTED);

  dlclose(Library);
  std::cout << (Passed ? "RESULT PASS\n" : "RESULT FAIL\n");
  return Passed ? 0 : 1;
}
