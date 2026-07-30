// SPDX-License-Identifier: MIT

#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/HostFeatures.h>

#include <exception>
#include <iostream>

int main() {
  FEXCore::HostFeatures Features {};
  Features.DCacheLineSize = 64;
  Features.ICacheLineSize = 64;
  Features.SupportsCacheMaintenanceOps = true;

  // FEX usa el MIDR para describir la topología x86 expuesta al huésped. Este
  // valor identifica de forma conservadora un núcleo Apple genérico; no
  // pretende modelar todavía las capacidades concretas del M5.
  Features.CPUMIDRs.emplace_back(0x61000000U);

  try {
    auto Context = FEXCore::Context::Context::CreateNewContext(Features);
    if (!Context) {
      std::cout << R"({"schema":1,"host":"macos-arm64","context_created":false,"init_core":false,"guest_elf_executed":false})"
                << '\n';
      return 70;
    }

    std::cout << R"({"schema":1,"host":"macos-arm64","context_created":true,"init_core":false,"signal_delegator":false,"syscall_handler":false,"guest_elf_executed":false})"
              << '\n';
    return 0;
  } catch (const std::exception& Error) {
    std::cerr << "FEXCore context exception: " << Error.what() << '\n';
  } catch (...) {
    std::cerr << "FEXCore context exception: unknown\n";
  }

  std::cout << R"({"schema":1,"host":"macos-arm64","context_created":false,"init_core":false,"guest_elf_executed":false})"
            << '\n';
  return 70;
}
