// SPDX-License-Identifier: MIT
// Isolated ABI probe for the public FEX UnixLib Darwin port.

#include "FEXUnixLib.h"

#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <sys/mman.h>

namespace {
using NTSTATUS = int32_t;
using UnixLibEntry = NTSTATUS (*)(void*);

constexpr NTSTATUS STATUS_SUCCESS = 0;
constexpr NTSTATUS STATUS_NOT_SUPPORTED = static_cast<NTSTATUS>(0xC00000BBu);

bool Expect(const char* Name, NTSTATUS Actual, NTSTATUS Expected) {
  if (Actual == Expected) {
    std::cout << "PASS " << Name << " status=0x" << std::hex << static_cast<uint32_t>(Actual) << std::dec << '\n';
    return true;
  }

  std::cerr << "FAIL " << Name << " actual=0x" << std::hex << static_cast<uint32_t>(Actual) << " expected=0x"
            << static_cast<uint32_t>(Expected) << std::dec << '\n';
  return false;
}
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: fli_fex_unixlib_probe /absolute/path/to/libarm64ecfex.so\n";
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

  FEXUnixLib_SetHardwareTSOControlArgs TSO {.Enable = true};
  Passed &= Expect("hardware-tso-fallback", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::SetHardwareTSOControl)](&TSO),
                   STATUS_NOT_SUPPORTED);

  FEXUnixLib_SetKernelUnalignedAtomicControl Unaligned {.Flags = FEX_UNALIGN_ATOMIC_EMULATE};
  Passed &= Expect("unaligned-atomic-fallback",
                   Functions[static_cast<uint32_t>(FEXUnixLibFunctions::SetKernelUnalignedAtomicControl)](&Unaligned),
                   STATUS_NOT_SUPPORTED);

  void* AdviceRegion = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (AdviceRegion == MAP_FAILED) {
    std::cerr << "FAIL madvise test mmap\n";
    Passed = false;
  } else {
    FEXUnixLib_Madvise Huge {.Addr = AdviceRegion, .Size = 4096, .Advise = 14, .pad = 0};
    FEXUnixLib_Madvise NoHuge {.Addr = AdviceRegion, .Size = 4096, .Advise = 15, .pad = 0};
    Passed &= Expect("madv-hugepage-noop", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::Madvise)](&Huge), STATUS_SUCCESS);
    Passed &= Expect("madv-nohugepage-noop", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::Madvise)](&NoHuge), STATUS_SUCCESS);
    munmap(AdviceRegion, 4096);
  }

  FEXUnixLib_SetVMAName VMA {.Addr = nullptr, .Size = 0, .Name = "probe"};
  Passed &= Expect("vma-name-fallback", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::SetVMAName)](&VMA),
                   STATUS_NOT_SUPPORTED);

  FEXUnixLib_GetSHMStatsVMA Stats {.SHMBase = nullptr, .MapSize = 4096, .MaxSize = 8192};
  NTSTATUS InitialStats = Functions[static_cast<uint32_t>(FEXUnixLibFunctions::GetSHMStatsVMA)](&Stats);
  Passed &= Expect("shm-initial-map", InitialStats, STATUS_SUCCESS);

  if (InitialStats == STATUS_SUCCESS && Stats.SHMBase) {
    std::memset(Stats.SHMBase, 0x5A, Stats.MapSize);
    Stats.MapSize = 8192;
    Passed &= Expect("shm-grow", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::GetSHMStatsVMA)](&Stats), STATUS_SUCCESS);
    if (static_cast<const uint8_t*>(Stats.SHMBase)[0] != 0x5A) {
      std::cerr << "FAIL shm-grow did not preserve existing bytes\n";
      Passed = false;
    } else {
      std::cout << "PASS shm-grow-preserves-data\n";
    }
  } else {
    std::cerr << "FAIL shm-initial-map returned no address\n";
    Passed = false;
  }

  Passed &= Expect("shm-unlink", Functions[static_cast<uint32_t>(FEXUnixLibFunctions::DeleteSHMStatsFile)](nullptr), STATUS_SUCCESS);
  if (Stats.SHMBase) {
    munmap(Stats.SHMBase, Stats.MaxSize);
  }

  dlclose(Library);
  std::cout << (Passed ? "RESULT PASS\n" : "RESULT FAIL\n");
  return Passed ? 0 : 1;
}
