// SPDX-License-Identifier: MIT
// Executable-memory contract probe for the isolated FEXCore Darwin port.
//
// This uses FEXCore's own inline allocator API to allocate one JIT page, writes
// two native arm64 instructions through Apple's per-thread JIT protection and
// executes them. It never loads or executes a guest binary.

#include <FEXCore/Utils/AllocatorHooks.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

int main() {
#if !defined(__aarch64__)
#error "This diagnostic must be compiled as native arm64."
#endif

  const size_t PageSize = static_cast<size_t>(getpagesize());
  errno = 0;
  void* Mapping = FEXCore::Allocator::VirtualAlloc(PageSize, true);
  if (Mapping == nullptr || Mapping == MAP_FAILED) {
    std::printf("{\"schema\":1,\"host\":\"macos-arm64\","
                "\"fex_virtual_alloc\":false,\"errno\":%d,"
                "\"guest_elf_executed\":false}\n",
                errno);
    return 70;
  }

  const uint32_t Instructions[] = {
    0x52800540U, // mov w0, #42
    0xd65f03c0U, // ret
  };

  const bool JITProtectionSupported = pthread_jit_write_protect_supported_np() != 0;
  if (JITProtectionSupported) {
    pthread_jit_write_protect_np(0);
  }
  std::memcpy(Mapping, Instructions, sizeof(Instructions));
  __builtin___clear_cache(static_cast<char*>(Mapping), static_cast<char*>(Mapping) + sizeof(Instructions));
  if (JITProtectionSupported) {
    pthread_jit_write_protect_np(1);
  }

  using ProbeFunction = uint32_t (*)();
  const uint32_t Result = reinterpret_cast<ProbeFunction>(Mapping)();
  FEXCore::Allocator::VirtualFree(Mapping, PageSize);

  std::printf("{\"schema\":1,\"host\":\"macos-arm64\","
              "\"fex_virtual_alloc\":true,\"jit_write_protection\":%s,"
              "\"native_result\":%u,\"guest_elf_executed\":false}\n",
              JITProtectionSupported ? "true" : "false",
              Result);
  return Result == 42 ? 0 : 71;
}
