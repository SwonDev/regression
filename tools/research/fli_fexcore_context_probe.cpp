// SPDX-License-Identifier: MIT

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/SignalScopeGuards.h>
#include <FEXCore/fextl/set.h>
#include <Interface/Core/LookupCache.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <optional>
#include <signal.h>
#include <string_view>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

namespace {
class ConfigLifetime final {
public:
  ConfigLifetime() {
    FEXCore::Config::Initialize();
  }

  ~ConfigLifetime() {
    FEXCore::Config::Shutdown();
  }
};

class ProbeSignalDelegator final : public FEXCore::SignalDelegator {};

class DarwinGuestRegionFaultHandler final {
public:
  bool Attach(
    FEXCore::Core::InternalThreadState* Thread,
    uintptr_t ExpectedHostAddress) {
    if (Thread == nullptr || ActiveThread != nullptr || ExpectedHostAddress == 0) {
      return false;
    }

    struct sigaction Action {};
    sigemptyset(&Action.sa_mask);
    Action.sa_sigaction = Handle;
    Action.sa_flags = SA_SIGINFO;
    if (sigaction(SIGBUS, &Action, &PreviousBusAction) != 0) {
      return false;
    }
    if (sigaction(SIGSEGV, &Action, &PreviousSegvAction) != 0) {
      sigaction(SIGBUS, &PreviousBusAction, nullptr);
      return false;
    }

    ActiveThread = Thread;
    ExpectedFaultHostAddress = ExpectedHostAddress;
    FaultCount = 0;
    FaultSignal = 0;
    FaultCode = 0;
    FaultHostAddress = 0;
    FaultGuestAddress = 0;
    FaultRecoveredGuestRIP = 0;
    FaultHostProgramCounter = 0;
    FaultHostPCInJIT = 0;
    FaultTranslationSucceeded = 0;
    FaultExpectedHostMatched = 0;
    Handling = 0;
    Installed = true;
    return true;
  }

  bool Reset() {
    if (!Installed) {
      return true;
    }

    ActiveThread = nullptr;
    ExpectedFaultHostAddress = 0;
    Handling = 0;
    const bool SegvRestored = sigaction(SIGSEGV, &PreviousSegvAction, nullptr) == 0;
    const bool BusRestored = sigaction(SIGBUS, &PreviousBusAction, nullptr) == 0;
    Installed = false;
    return SegvRestored && BusRestored;
  }

  uint64_t Count() const {
    return static_cast<uint64_t>(FaultCount);
  }

  int Signal() const {
    return static_cast<int>(FaultSignal);
  }

  int Code() const {
    return static_cast<int>(FaultCode);
  }

  uint64_t HostAddress() const {
    return FaultHostAddress;
  }

  uint64_t GuestAddress() const {
    return FaultGuestAddress;
  }

  uint64_t RecoveredGuestRIP() const {
    return FaultRecoveredGuestRIP;
  }

  uint64_t HostProgramCounter() const {
    return FaultHostProgramCounter;
  }

  bool HostPCWasInJIT() const {
    return FaultHostPCInJIT != 0;
  }

  bool TranslationSucceeded() const {
    return FaultTranslationSucceeded != 0;
  }

  bool ExpectedHostMatched() const {
    return FaultExpectedHostMatched != 0;
  }

  ~DarwinGuestRegionFaultHandler() {
    Reset();
  }

private:
  static void Handle(int Signal, siginfo_t* Info, void* RawContext) {
    auto* Thread = ActiveThread;
    auto* Context = static_cast<ucontext_t*>(RawContext);
    if (Handling != 0) {
      _exit(211);
    }
    if ((Signal != SIGBUS && Signal != SIGSEGV) || Thread == nullptr
        || Info == nullptr || Context == nullptr || Context->uc_mcontext == nullptr) {
      _exit(212);
    }

    Handling = 1;
    auto& HostState = Context->uc_mcontext->__ss;
    const uintptr_t ProgramCounter = static_cast<uintptr_t>(HostState.__pc);
    const uintptr_t HostAddress = reinterpret_cast<uintptr_t>(Info->si_addr);
    uint64_t GuestAddress {};
    const bool HostPCInJIT = Thread->CTX->IsAddressInCodeBuffer(Thread, ProgramCounter);
    const bool TranslationSucceeded =
      Thread->CTX->TranslateHostMemoryAddress(HostAddress, &GuestAddress);
    const uint64_t RecoveredGuestRIP =
      Thread->CTX->RestoreRIPFromHostPC(Thread, ProgramCounter);
    auto* Frame = Thread->CurrentFrame;
    if (Frame == nullptr || Frame->Pointers.GuestSignal_SIGSEGV == 0) {
      _exit(213);
    }
    if (FaultCount != 0) {
      _exit(214);
    }

    FaultSignal = static_cast<sig_atomic_t>(Signal);
    FaultCode = static_cast<sig_atomic_t>(Info->si_code);
    FaultHostAddress = HostAddress;
    FaultGuestAddress = GuestAddress;
    FaultRecoveredGuestRIP = RecoveredGuestRIP;
    FaultHostProgramCounter = ProgramCounter;
    FaultHostPCInJIT = HostPCInJIT ? 1 : 0;
    FaultTranslationSucceeded = TranslationSucceeded ? 1 : 0;
    FaultExpectedHostMatched = HostAddress == ExpectedFaultHostAddress ? 1 : 0;
    FaultCount = 1;
    Handling = 0;
    HostState.__pc = Frame->Pointers.GuestSignal_SIGSEGV;
  }

  struct sigaction PreviousBusAction {};
  struct sigaction PreviousSegvAction {};
  bool Installed {};

  inline static thread_local FEXCore::Core::InternalThreadState* ActiveThread {};
  inline static thread_local uintptr_t ExpectedFaultHostAddress {};
  inline static thread_local volatile sig_atomic_t Handling {};
  inline static thread_local volatile sig_atomic_t FaultCount {};
  inline static thread_local volatile sig_atomic_t FaultSignal {};
  inline static thread_local volatile sig_atomic_t FaultCode {};
  inline static thread_local uint64_t FaultHostAddress {};
  inline static thread_local uint64_t FaultGuestAddress {};
  inline static thread_local uint64_t FaultRecoveredGuestRIP {};
  inline static thread_local uint64_t FaultHostProgramCounter {};
  inline static thread_local volatile sig_atomic_t FaultHostPCInJIT {};
  inline static thread_local volatile sig_atomic_t FaultTranslationSucceeded {};
  inline static thread_local volatile sig_atomic_t FaultExpectedHostMatched {};
};

class ScopedHostMapping final {
public:
  bool Allocate(size_t Size) {
    Address = mmap(nullptr, Size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    MappingSize = Address == MAP_FAILED ? 0 : Size;
    return Address != MAP_FAILED;
  }

  ~ScopedHostMapping() {
    if (Address != MAP_FAILED) {
      munmap(Address, MappingSize);
    }
  }

  void* Data() const {
    return Address;
  }

  bool Unmap() {
    if (Address == MAP_FAILED || munmap(Address, MappingSize) != 0) {
      return false;
    }
    Address = MAP_FAILED;
    MappingSize = 0;
    return true;
  }

private:
  void* Address {MAP_FAILED};
  size_t MappingSize {};
};

class ProbeSyscallHandler final : public FEXCore::HLE::SyscallHandler {
public:
  ProbeSyscallHandler() {
    OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64;
  }

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame*, FEXCore::HLE::SyscallArguments*) override {
    return 0;
  }

  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return {0, UINT64_MAX, true};
  }

  std::optional<FEXCore::ExecutableFileSectionInfo>
  LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return std::nullopt;
  }
};

void ConfigureLongMode(FEXCore::Core::InternalThreadState* Thread, std::array<FEXCore::Core::CPUState::gdt_segment, 32>& GDT) {
  auto* Frame = Thread->CurrentFrame;
  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = GDT.data();
  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = GDT.data();
  Frame->State.cs_idx = FEXCore::Core::CPUState::DEFAULT_USER_CS << 3;

  auto* CodeSegment = FEXCore::Core::CPUState::GetSegmentFromIndex(Frame->State, Frame->State.cs_idx);
  FEXCore::Core::CPUState::SetGDTBase(CodeSegment, 0);
  FEXCore::Core::CPUState::SetGDTLimit(CodeSegment, 0xFFFFFU);
  CodeSegment->L = 1;
  CodeSegment->D = 0;
  Frame->State.cs_cached = FEXCore::Core::CPUState::CalculateGDTBase(*CodeSegment);
}
} // namespace

int main(int argc, char** argv) {
#if defined(REGRESSION_FEXCORE_GUEST_MEMORY_BIAS)
  constexpr bool GuestMemoryBiasProbeAvailable = true;
#else
  constexpr bool GuestMemoryBiasProbeAvailable = false;
#endif
  const bool LowMemoryBiasRequested = argc == 2 && std::string_view {argv[1]} == "--execute-low-memory-bias";
  const bool SparseRedirectRequested = argc == 2 && std::string_view {argv[1]} == "--execute-sparse-page-redirect";
  const bool SparseHighRegionsRequested = argc == 2 && std::string_view {argv[1]} == "--execute-sparse-high-regions";
  const bool AddressTranslationRequested = argc == 2 && std::string_view {argv[1]} == "--inspect-address-translation";
  const bool RegionLifecycleRequested = argc == 2 && std::string_view {argv[1]} == "--execute-region-lifecycle";
  const bool RegionFaultAttributionRequested =
    argc == 2 && std::string_view {argv[1]} == "--execute-region-fault-attribution";
  if (argc != 2 || (std::string_view {argv[1]} != "--context" && std::string_view {argv[1]} != "--init-core"
                    && std::string_view {argv[1]} != "--compile-one" && std::string_view {argv[1]} != "--execute-one"
                    && std::string_view {argv[1]} != "--execute-linked"
                    && std::string_view {argv[1]} != "--invalidate-linked"
                    && std::string_view {argv[1]} != "--invalidate-indirect"
                    && !(GuestMemoryBiasProbeAvailable
                      && (LowMemoryBiasRequested || SparseRedirectRequested || SparseHighRegionsRequested
                          || AddressTranslationRequested || RegionLifecycleRequested
                          || RegionFaultAttributionRequested)))) {
    std::cerr << "Uso: fli-fexcore-context-probe --context|--init-core|--compile-one|--execute-one|--execute-linked|--invalidate-linked|--invalidate-indirect|--execute-low-memory-bias|--execute-sparse-page-redirect|--execute-sparse-high-regions|--inspect-address-translation|--execute-region-lifecycle|--execute-region-fault-attribution\n";
    return 64;
  }
  const std::string_view Mode {argv[1]};
  const bool InvalidationRequested = Mode == "--invalidate-linked";
  const bool IndirectInvalidationRequested = Mode == "--invalidate-indirect";
  const bool LinkedExecutionRequested = Mode == "--execute-linked" || InvalidationRequested;
  const bool ExecutionRequested = Mode == "--execute-one" || LinkedExecutionRequested || IndirectInvalidationRequested
                               || LowMemoryBiasRequested || SparseRedirectRequested || SparseHighRegionsRequested
                               || RegionLifecycleRequested || RegionFaultAttributionRequested;
  const bool CompilationRequested = Mode == "--compile-one" || ExecutionRequested;
  const bool InitCoreRequested = Mode == "--init-core" || CompilationRequested || AddressTranslationRequested;

  void* AllocatorSample = FEXCore::Allocator::aligned_alloc(alignof(uint32_t), sizeof(uint32_t));
  if (AllocatorSample == nullptr) {
    std::cout << R"({"schema":1,"host":"macos-arm64","small_alignment_allocation":false,"context_created":false,"init_core":false,"guest_elf_executed":false})"
              << '\n';
    return 70;
  }
  FEXCore::Allocator::aligned_free(AllocatorSample);

  FEXCore::HostFeatures Features {};
  Features.DCacheLineSize = 64;
  Features.ICacheLineSize = 64;
  Features.SupportsCacheMaintenanceOps = true;

  // FEX usa el MIDR para describir la topología x86 expuesta al huésped. Este
  // valor identifica de forma conservadora un núcleo Apple genérico; no
  // pretende modelar todavía las capacidades concretas del M5.
  Features.CPUMIDRs.emplace_back(0x61000000U);

  try {
    ConfigLifetime Config;
    constexpr uint64_t GuestLowPageAddress = 0x001E2000ULL;
    constexpr uint64_t GuestLowTargetAddress = 0x001E2F70ULL;
    constexpr uint32_t GuestLowExpectedValue = 0x12345678U;
    alignas(4096) std::array<uint8_t, 4096> GuestLowPage {};
    [[maybe_unused]] const uint64_t GuestMemoryBias =
      reinterpret_cast<uint64_t>(GuestLowPage.data()) - GuestLowPageAddress;
    constexpr uint64_t GuestRedirectPageAddress = 0x7FFE0000ULL;
    constexpr uint64_t GuestRedirectTargetAddress = GuestRedirectPageAddress + 0x270;
    constexpr uint64_t GuestAdjacentTargetAddress = GuestRedirectPageAddress + 0x1270;
    constexpr uint32_t GuestRedirectExpectedValue = 0x12345678U;
    constexpr uint32_t GuestAdjacentExpectedValue = 0x87654321U;
    constexpr uint64_t GuestHighRegion1Address = 0x0000000100000000ULL;
    constexpr uint64_t GuestHighRegion2Address = 0x00007FFFFFF30000ULL;
    constexpr uint64_t GuestHighRegionTargetOffset = 0x270;
    constexpr uint64_t GuestHighRegion1TargetAddress = GuestHighRegion1Address + GuestHighRegionTargetOffset;
    constexpr uint64_t GuestHighRegion2TargetAddress = GuestHighRegion2Address + GuestHighRegionTargetOffset;
    constexpr uint32_t GuestHighRegion1ExpectedValue = 0x11223344U;
    constexpr uint32_t GuestHighRegion2ExpectedValue = 0x55667788U;
    constexpr uint32_t GuestHighRegionExpectedResult =
      GuestHighRegion1ExpectedValue + GuestHighRegion2ExpectedValue;
    ScopedHostMapping SparseLinearMapping;
    ScopedHostMapping SparseRedirectMapping;
    ScopedHostMapping SparseHighRegion1Mapping;
    ScopedHostMapping SparseHighRegion2Mapping;
    ScopedHostMapping SparseInvalidMapping;
    const long HostPageSizeResult = sysconf(_SC_PAGESIZE);
    if (SparseRedirectRequested || AddressTranslationRequested) {
      if (HostPageSizeResult <= 0
          || !SparseLinearMapping.Allocate(uint64_t {1} << 32)
          || !SparseRedirectMapping.Allocate(static_cast<size_t>(HostPageSizeResult))) {
        std::cerr << "No se pudo reservar el shadow disperso controlado.\n";
        return 70;
      }
      const uint64_t HostPageSize = static_cast<uint64_t>(HostPageSizeResult);
      const uint64_t AdjacentHostPage = GuestAdjacentTargetAddress
        & ~(HostPageSize - 1);
      if (mprotect(
            static_cast<uint8_t*>(SparseLinearMapping.Data()) + AdjacentHostPage,
            static_cast<size_t>(HostPageSize),
            PROT_READ | PROT_WRITE) != 0
          || mprotect(
            SparseRedirectMapping.Data(),
            static_cast<size_t>(HostPageSize),
            PROT_READ | PROT_WRITE) != 0) {
        std::cerr << "No se pudo habilitar la pareja de páginas controlada.\n";
        return 70;
      }
    }
    if (SparseHighRegionsRequested || AddressTranslationRequested || RegionLifecycleRequested
        || RegionFaultAttributionRequested) {
      if (HostPageSizeResult <= 0
          || !SparseHighRegion1Mapping.Allocate(static_cast<size_t>(HostPageSizeResult))
          || !SparseHighRegion2Mapping.Allocate(static_cast<size_t>(HostPageSizeResult))
          || (AddressTranslationRequested
              && !SparseInvalidMapping.Allocate(static_cast<size_t>(HostPageSizeResult)))
          || mprotect(
               SparseHighRegion1Mapping.Data(),
               static_cast<size_t>(HostPageSizeResult),
               PROT_READ | PROT_WRITE) != 0
          || mprotect(
               SparseHighRegion2Mapping.Data(),
               static_cast<size_t>(HostPageSizeResult),
               PROT_READ | PROT_WRITE) != 0) {
        std::cerr << "No se pudieron preparar las dos regiones altas controladas.\n";
        return 70;
      }
    }
    if (CompilationRequested) {
      FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
      if (LinkedExecutionRequested) {
        FEXCore::Config::Set(FEXCore::Config::CONFIG_MULTIBLOCK, "0");
      }
    }

    ProbeSignalDelegator SignalDelegator;
    ProbeSyscallHandler SyscallHandler;
    auto Context = FEXCore::Context::Context::CreateNewContext(Features);
    if (!Context) {
      std::cout << R"({"schema":1,"host":"macos-arm64","small_alignment_allocation":true,"context_created":false,"init_core":false,"guest_elf_executed":false})"
                << '\n';
      return 70;
    }
#if defined(REGRESSION_FEXCORE_GUEST_MEMORY_BIAS)
    if (LowMemoryBiasRequested) {
      Context->SetGuestMemoryAddressBias(GuestMemoryBias, 1ULL << 32);
    } else if (SparseRedirectRequested) {
      Context->SetGuestMemoryAddressBias(
        reinterpret_cast<uint64_t>(SparseLinearMapping.Data()),
        1ULL << 32,
        GuestRedirectPageAddress,
        reinterpret_cast<uint64_t>(SparseRedirectMapping.Data()));
    } else if (SparseHighRegionsRequested || AddressTranslationRequested || RegionLifecycleRequested
               || RegionFaultAttributionRequested) {
      Context->SetGuestMemoryAddressBias(
        AddressTranslationRequested
          ? reinterpret_cast<uint64_t>(SparseLinearMapping.Data())
          : GuestMemoryBias,
        1ULL << 32,
        AddressTranslationRequested ? GuestRedirectPageAddress : 0,
        AddressTranslationRequested
          ? reinterpret_cast<uint64_t>(SparseRedirectMapping.Data())
          : 0);
      const uint64_t HostPageSize = static_cast<uint64_t>(HostPageSizeResult);
      const std::array<FEXCore::Context::GuestMemoryAddressRegion, 2> Regions {{
        {
          GuestHighRegion1Address,
          reinterpret_cast<uint64_t>(SparseHighRegion1Mapping.Data()),
          HostPageSize,
        },
        {
          GuestHighRegion2Address,
          reinterpret_cast<uint64_t>(SparseHighRegion2Mapping.Data()),
          HostPageSize,
        },
      }};
      const size_t RegionCount =
        (RegionLifecycleRequested || RegionFaultAttributionRequested) ? 1 : Regions.size();
      if (!Context->SetGuestMemoryAddressRegions(Regions.data(), RegionCount)) {
        std::cerr << "FEXCore rechazó las regiones altas controladas.\n";
        return 70;
      }
      if (RegionLifecycleRequested) {
        std::memcpy(
          static_cast<uint8_t*>(SparseHighRegion1Mapping.Data()) + GuestHighRegionTargetOffset,
          &GuestHighRegion1ExpectedValue,
          sizeof(GuestHighRegion1ExpectedValue));
        std::memcpy(
          static_cast<uint8_t*>(SparseHighRegion2Mapping.Data()) + GuestHighRegionTargetOffset,
          &GuestHighRegion2ExpectedValue,
          sizeof(GuestHighRegion2ExpectedValue));
      }
    }
#endif

    bool CoreInitialized {};
    if (InitCoreRequested) {
      if (ExecutionRequested) {
        Context->EnableExitOnHLT();
      }
      Context->SetSignalDelegator(&SignalDelegator);
      if (CompilationRequested) {
        Context->SetSyscallHandler(&SyscallHandler);
      }
      CoreInitialized = Context->InitCore();
      if (!CoreInitialized) {
        std::cout << R"({"schema":1,"host":"macos-arm64","mode":"init-core","small_alignment_allocation":true,"config_initialized":true,"context_created":true,"init_core":false,"signal_delegator":true,"syscall_handler":false,"guest_elf_executed":false})"
                  << '\n';
        return 70;
      }
    }

    bool JITBlockCompiled {};
    bool GuestCodeExecuted {};
    bool CodeInvalidationExercised {};
    bool IndirectLinkExercised {};
    bool IndirectInvalidationExercised {};
    uint64_t IndirectBranchDistance {};
    uint64_t GuestResult {};
    uint32_t GuestLowStoredValue {};
    bool GuestMemoryBiasPassed {};
    uint32_t GuestRedirectStoredValue {};
    uint32_t GuestAdjacentStoredValue {};
    bool GuestSparseRedirectPassed {};
    uint32_t GuestHighRegion1StoredValue {};
    uint32_t GuestHighRegion2StoredValue {};
    bool GuestSparseHighRegionsPassed {};
    uint64_t TranslatedLowHostAddress {};
    uint64_t TranslatedRedirectHostAddress {};
    uint64_t TranslatedHighRegion1HostAddress {};
    uint64_t TranslatedHighRegion2HostAddress {};
    uint64_t RoundTripLowGuestAddress {};
    uint64_t RoundTripRedirectGuestAddress {};
    uint64_t RoundTripHighRegion1GuestAddress {};
    uint64_t RoundTripHighRegion2GuestAddress {};
    bool InvalidGuestOverlapRejected {};
    bool InvalidHostOverlapRejected {};
    bool UnmappedGuestRejected {};
    bool UnmappedHostRejected {};
    bool NullTranslationOutputRejected {};
    bool AddressTranslationContractPassed {};
    uint64_t GuestLifecycleInitialResult {};
    uint64_t GuestLifecycleUpdatedResult {};
    uint64_t LifecycleHostCodeBeforeUpdate {};
    uint64_t LifecycleHostCodeAfterUpdate {};
    uint64_t LifecycleUpdatedHostAddress {};
    bool GuestRegionUpdatePassed {};
    bool GuestRegionClearPassed {};
    bool GuestBackingProtectionPassed {};
    bool GuestBackingUnmapPassed {};
    bool JITBlockReusedAfterRegionUpdate {};
    bool GuestRegionLifecyclePassed {};
    bool GuestRegionFaultHandlerAttached {};
    bool GuestRegionFaultSeen {};
    uint64_t GuestRegionFaultCount {};
    int GuestRegionFaultSignal {};
    int GuestRegionFaultCode {};
    uint64_t GuestRegionFaultHostAddress {};
    uint64_t GuestRegionFaultExpectedHostAddress {};
    uint64_t GuestRegionFaultGuestAddress {};
    uint64_t GuestRegionFaultRecoveredRIP {};
    uint64_t GuestRegionFaultExpectedRIP {};
    uint64_t GuestRegionFaultHostProgramCounter {};
    bool GuestRegionFaultHostPCInJIT {};
    bool GuestRegionFaultTranslationSucceeded {};
    bool GuestRegionFaultExpectedHostMatched {};
    bool GuestRegionFaultBackingProtected {};
    bool GuestRegionFaultHandlersRestored {};
    bool GuestRegionFaultBackingRestored {};
    bool GuestRegionFaultMapCleared {};
    bool GuestRegionFaultAttributionPassed {};
    if (AddressTranslationRequested) {
      const uint64_t HostPageSize = static_cast<uint64_t>(HostPageSizeResult);
      const uint64_t LinearHostAddress =
        reinterpret_cast<uint64_t>(SparseLinearMapping.Data()) + GuestLowTargetAddress;
      const uint64_t RedirectHostAddress =
        reinterpret_cast<uint64_t>(SparseRedirectMapping.Data())
        + (GuestRedirectTargetAddress - GuestRedirectPageAddress);
      const uint64_t HighRegion1HostAddress =
        reinterpret_cast<uint64_t>(SparseHighRegion1Mapping.Data())
        + GuestHighRegionTargetOffset;
      const uint64_t HighRegion2HostAddress =
        reinterpret_cast<uint64_t>(SparseHighRegion2Mapping.Data())
        + GuestHighRegionTargetOffset;
      const bool ForwardTranslationsPassed =
        Context->TranslateGuestMemoryAddress(GuestLowTargetAddress, &TranslatedLowHostAddress)
        && TranslatedLowHostAddress == LinearHostAddress
        && Context->TranslateGuestMemoryAddress(
          GuestRedirectTargetAddress,
          &TranslatedRedirectHostAddress)
        && TranslatedRedirectHostAddress == RedirectHostAddress
        && Context->TranslateGuestMemoryAddress(
          GuestHighRegion1TargetAddress,
          &TranslatedHighRegion1HostAddress)
        && TranslatedHighRegion1HostAddress == HighRegion1HostAddress
        && Context->TranslateGuestMemoryAddress(
          GuestHighRegion2TargetAddress,
          &TranslatedHighRegion2HostAddress)
        && TranslatedHighRegion2HostAddress == HighRegion2HostAddress;
      const bool ReverseTranslationsPassed =
        Context->TranslateHostMemoryAddress(LinearHostAddress, &RoundTripLowGuestAddress)
        && RoundTripLowGuestAddress == GuestLowTargetAddress
        && Context->TranslateHostMemoryAddress(
          RedirectHostAddress,
          &RoundTripRedirectGuestAddress)
        && RoundTripRedirectGuestAddress == GuestRedirectTargetAddress
        && Context->TranslateHostMemoryAddress(
          HighRegion1HostAddress,
          &RoundTripHighRegion1GuestAddress)
        && RoundTripHighRegion1GuestAddress == GuestHighRegion1TargetAddress
        && Context->TranslateHostMemoryAddress(
          HighRegion2HostAddress,
          &RoundTripHighRegion2GuestAddress)
        && RoundTripHighRegion2GuestAddress == GuestHighRegion2TargetAddress;

      const FEXCore::Context::GuestMemoryAddressRegion InvalidGuestOverlap {
        GuestLowPageAddress,
        reinterpret_cast<uint64_t>(SparseInvalidMapping.Data()),
        0x1000,
      };
      InvalidGuestOverlapRejected =
        !Context->SetGuestMemoryAddressRegions(&InvalidGuestOverlap, 1);
      const std::array<FEXCore::Context::GuestMemoryAddressRegion, 2>
        InvalidHostOverlap {{
          {
            GuestHighRegion1Address,
            reinterpret_cast<uint64_t>(SparseHighRegion1Mapping.Data()),
            HostPageSize,
          },
          {
            GuestHighRegion2Address + HostPageSize,
            reinterpret_cast<uint64_t>(SparseHighRegion1Mapping.Data()) + 0x1000,
            0x1000,
          },
        }};
      InvalidHostOverlapRejected =
        !Context->SetGuestMemoryAddressRegions(
          InvalidHostOverlap.data(),
          InvalidHostOverlap.size());

      uint64_t UnchangedOutput = 0xA5A5A5A5A5A5A5A5ULL;
      UnmappedGuestRejected = !Context->TranslateGuestMemoryAddress(
        GuestHighRegion2Address + HostPageSize,
        &UnchangedOutput)
        && UnchangedOutput == 0xA5A5A5A5A5A5A5A5ULL;
      UnmappedHostRejected = !Context->TranslateHostMemoryAddress(
        1,
        &UnchangedOutput)
        && UnchangedOutput == 0xA5A5A5A5A5A5A5A5ULL;
      NullTranslationOutputRejected =
        !Context->TranslateGuestMemoryAddress(GuestLowTargetAddress, nullptr)
        && !Context->TranslateHostMemoryAddress(LinearHostAddress, nullptr);
      AddressTranslationContractPassed =
        ForwardTranslationsPassed
        && ReverseTranslationsPassed
        && InvalidGuestOverlapRejected
        && InvalidHostOverlapRejected
        && UnmappedGuestRejected
        && UnmappedHostRejected
        && NullTranslationOutputRejected;
    }
    if (CompilationRequested) {
      alignas(16) std::array<uint8_t, 64> GuestCode {};
      alignas(16) std::array<uint8_t, 4096> GuestStack {};
      if (RegionLifecycleRequested || RegionFaultAttributionRequested) {
        GuestCode = {
          0x48, 0xBB, 0x70, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
          0x8B, 0x03,
          0xF4,
        };
      } else if (SparseHighRegionsRequested) {
        GuestCode = {
          0x48, 0xBB, 0x70, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
          0xC7, 0x03, 0x44, 0x33, 0x22, 0x11,
          0x8B, 0x03,
          0x48, 0xBB, 0x70, 0x02, 0xF3, 0xFF, 0xFF, 0x7F, 0x00, 0x00,
          0xC7, 0x03, 0x88, 0x77, 0x66, 0x55,
          0x8B, 0x0B,
          0x01, 0xC8,
          0xF4,
        };
      } else if (SparseRedirectRequested) {
        GuestCode = {
          0x48, 0xBB, 0x70, 0x02, 0xFE, 0x7F, 0x00, 0x00, 0x00, 0x00,
          0xC7, 0x03, 0x78, 0x56, 0x34, 0x12,
          0x8B, 0x0B,
          0x48, 0xBB, 0x70, 0x12, 0xFE, 0x7F, 0x00, 0x00, 0x00, 0x00,
          0xC7, 0x03, 0x21, 0x43, 0x65, 0x87,
          0x8B, 0x03,
          0xF4,
        };
      } else if (LowMemoryBiasRequested) {
        GuestCode = {
          0x48, 0xBB, 0x70, 0x2F, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00,
          0xC7, 0x03, 0x78, 0x56, 0x34, 0x12,
          0x8B, 0x03,
          0xF4,
        };
      } else if (LinkedExecutionRequested) {
        GuestCode = {0xB8, 0x29, 0x00, 0x00, 0x00, 0xEB, 0x01, 0x90, 0x83, 0xC0, 0x01, 0xF4};
      } else if (ExecutionRequested) {
        GuestCode = {0xB8, 0x2A, 0x00, 0x00, 0x00, 0xF4};
      } else {
        GuestCode[0] = 0x90;
      }

      const uint64_t GuestRIP = reinterpret_cast<uint64_t>(GuestCode.data());
      const uint64_t GuestRSP = (reinterpret_cast<uint64_t>(GuestStack.data() + GuestStack.size())) & ~uint64_t {0xF};
      auto* Thread = Context->CreateThread(GuestRIP, GuestRSP);
      if (Thread == nullptr) {
        std::cout << R"({"schema":1,"host":"macos-arm64","context_created":true,"init_core":true,"thread_created":false,"guest_x86_decoded":false,"jit_block_compiled":false,"guest_code_executed":false,"guest_elf_executed":false})"
                  << '\n';
        return 70;
      }

      std::array<FEXCore::Core::CPUState::gdt_segment, 32> GDT {};
      DarwinGuestRegionFaultHandler RegionFaultHandler;
      ConfigureLongMode(Thread, GDT);
      if (ExecutionRequested) {
        Context->CompileRIP(Thread, GuestRIP);
      } else {
        Context->CompileRIPCount(Thread, GuestRIP, 1);
      }
      JITBlockCompiled = true;

      if (ExecutionRequested) {
        if (RegionFaultAttributionRequested) {
          const size_t HostPageSize = static_cast<size_t>(HostPageSizeResult);
          GuestRegionFaultExpectedHostAddress =
            reinterpret_cast<uint64_t>(SparseHighRegion1Mapping.Data())
            + GuestHighRegionTargetOffset;
          GuestRegionFaultExpectedRIP = GuestRIP + 10;
          GuestRegionFaultBackingProtected =
            mprotect(SparseHighRegion1Mapping.Data(), HostPageSize, PROT_NONE) == 0;
          GuestRegionFaultHandlerAttached =
            GuestRegionFaultBackingProtected
            && RegionFaultHandler.Attach(Thread, GuestRegionFaultExpectedHostAddress);
          if (!GuestRegionFaultHandlerAttached) {
            if (GuestRegionFaultBackingProtected) {
              mprotect(
                SparseHighRegion1Mapping.Data(),
                HostPageSize,
                PROT_READ | PROT_WRITE);
            }
            Context->DestroyThread(Thread);
            std::cerr << "No se pudo preparar el fallo de región controlado.\n";
            return 70;
          }
        }
        Context->ExecuteThread(Thread);
        GuestCodeExecuted = true;
        GuestResult = Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RAX];
        if (RegionFaultAttributionRequested) {
          const size_t HostPageSize = static_cast<size_t>(HostPageSizeResult);
          GuestRegionFaultCount = RegionFaultHandler.Count();
          GuestRegionFaultSeen = GuestRegionFaultCount == 1;
          GuestRegionFaultSignal = RegionFaultHandler.Signal();
          GuestRegionFaultCode = RegionFaultHandler.Code();
          GuestRegionFaultHostAddress = RegionFaultHandler.HostAddress();
          GuestRegionFaultGuestAddress = RegionFaultHandler.GuestAddress();
          GuestRegionFaultRecoveredRIP = RegionFaultHandler.RecoveredGuestRIP();
          GuestRegionFaultHostProgramCounter = RegionFaultHandler.HostProgramCounter();
          GuestRegionFaultHostPCInJIT = RegionFaultHandler.HostPCWasInJIT();
          GuestRegionFaultTranslationSucceeded = RegionFaultHandler.TranslationSucceeded();
          GuestRegionFaultExpectedHostMatched = RegionFaultHandler.ExpectedHostMatched();
          GuestRegionFaultHandlersRestored = RegionFaultHandler.Reset();
          GuestRegionFaultMapCleared =
            Context->SetGuestMemoryAddressRegions(nullptr, 0);
          GuestRegionFaultBackingRestored =
            mprotect(
              SparseHighRegion1Mapping.Data(),
              HostPageSize,
              PROT_READ | PROT_WRITE) == 0;
          GuestRegionFaultAttributionPassed =
            GuestRegionFaultHandlerAttached
            && GuestRegionFaultSeen
            && (GuestRegionFaultSignal == SIGBUS || GuestRegionFaultSignal == SIGSEGV)
            && GuestRegionFaultHostAddress == GuestRegionFaultExpectedHostAddress
            && GuestRegionFaultExpectedHostMatched
            && GuestRegionFaultTranslationSucceeded
            && GuestRegionFaultGuestAddress == GuestHighRegion1TargetAddress
            && GuestRegionFaultRecoveredRIP == GuestRegionFaultExpectedRIP
            && GuestRegionFaultHostPCInJIT
            && GuestRegionFaultHandlersRestored
            && GuestRegionFaultMapCleared
            && GuestRegionFaultBackingRestored;
        } else if (RegionLifecycleRequested) {
          const uint64_t HostPageSize = static_cast<uint64_t>(HostPageSizeResult);
          const auto FindSharedHostCode = [&]() -> uint64_t {
            auto LookupReadLock = Thread->LookupCache->Shared->AcquireReadLock();
            const auto* Entry =
              Thread->LookupCache->Shared->FindBlock(GuestRIP, LookupReadLock);
            return Entry == nullptr ? 0 : Entry->HostCode;
          };
          GuestLifecycleInitialResult = GuestResult;
          LifecycleHostCodeBeforeUpdate = FindSharedHostCode();
          const FEXCore::Context::GuestMemoryAddressRegion UpdatedRegion {
            GuestHighRegion1Address,
            reinterpret_cast<uint64_t>(SparseHighRegion2Mapping.Data()),
            HostPageSize,
          };
          const bool RegionUpdated =
            Context->SetGuestMemoryAddressRegions(&UpdatedRegion, 1);
          const uint64_t ExpectedUpdatedHostAddress =
            reinterpret_cast<uint64_t>(SparseHighRegion2Mapping.Data())
            + GuestHighRegionTargetOffset;
          const bool UpdatedTranslationPassed =
            Context->TranslateGuestMemoryAddress(
              GuestHighRegion1TargetAddress,
              &LifecycleUpdatedHostAddress)
            && LifecycleUpdatedHostAddress == ExpectedUpdatedHostAddress;
          const bool RetiredBackingProtected =
            mprotect(
              SparseHighRegion1Mapping.Data(),
              static_cast<size_t>(HostPageSize),
              PROT_NONE) == 0;

          Thread->CurrentFrame->State.rip = GuestRIP;
          Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RAX] = 0;
          Context->ExecuteThread(Thread);
          GuestLifecycleUpdatedResult =
            Thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RAX];
          GuestResult = GuestLifecycleUpdatedResult;
          LifecycleHostCodeAfterUpdate = FindSharedHostCode();
          JITBlockReusedAfterRegionUpdate =
            LifecycleHostCodeBeforeUpdate != 0
            && LifecycleHostCodeBeforeUpdate == LifecycleHostCodeAfterUpdate;
          GuestRegionUpdatePassed =
            RegionUpdated
            && UpdatedTranslationPassed
            && GuestLifecycleInitialResult == GuestHighRegion1ExpectedValue
            && GuestLifecycleUpdatedResult == GuestHighRegion2ExpectedValue
            && JITBlockReusedAfterRegionUpdate;

          const bool RegionsCleared =
            Context->SetGuestMemoryAddressRegions(nullptr, 0);
          uint64_t UnchangedGuestOutput = 0xA5A5A5A5A5A5A5A5ULL;
          uint64_t UnchangedHostOutput = 0x5A5A5A5A5A5A5A5AULL;
          const bool ClearedGuestTranslationRejected =
            !Context->TranslateGuestMemoryAddress(
              GuestHighRegion1TargetAddress,
              &UnchangedGuestOutput)
            && UnchangedGuestOutput == 0xA5A5A5A5A5A5A5A5ULL;
          const bool ClearedHostTranslationRejected =
            !Context->TranslateHostMemoryAddress(
              ExpectedUpdatedHostAddress,
              &UnchangedHostOutput)
            && UnchangedHostOutput == 0x5A5A5A5A5A5A5A5AULL;
          GuestRegionClearPassed =
            RegionsCleared
            && ClearedGuestTranslationRejected
            && ClearedHostTranslationRejected;
          const bool ActiveBackingProtected =
            mprotect(
              SparseHighRegion2Mapping.Data(),
              static_cast<size_t>(HostPageSize),
              PROT_NONE) == 0;
          GuestBackingProtectionPassed =
            RetiredBackingProtected && ActiveBackingProtected;
          GuestBackingUnmapPassed =
            SparseHighRegion1Mapping.Unmap()
            && SparseHighRegion2Mapping.Unmap();
          uint64_t PostUnmapOutput = 0xC3C3C3C3C3C3C3C3ULL;
          const bool PostUnmapTranslationRejected =
            !Context->TranslateGuestMemoryAddress(
              GuestHighRegion1TargetAddress,
              &PostUnmapOutput)
            && PostUnmapOutput == 0xC3C3C3C3C3C3C3C3ULL;
          GuestRegionLifecyclePassed =
            GuestRegionUpdatePassed
            && GuestRegionClearPassed
            && GuestBackingProtectionPassed
            && GuestBackingUnmapPassed
            && PostUnmapTranslationRejected;
        } else if (SparseHighRegionsRequested) {
          std::memcpy(
            &GuestHighRegion1StoredValue,
            static_cast<uint8_t*>(SparseHighRegion1Mapping.Data()) + GuestHighRegionTargetOffset,
            sizeof(GuestHighRegion1StoredValue));
          std::memcpy(
            &GuestHighRegion2StoredValue,
            static_cast<uint8_t*>(SparseHighRegion2Mapping.Data()) + GuestHighRegionTargetOffset,
            sizeof(GuestHighRegion2StoredValue));
          GuestSparseHighRegionsPassed =
            GuestHighRegion1StoredValue == GuestHighRegion1ExpectedValue
            && GuestHighRegion2StoredValue == GuestHighRegion2ExpectedValue
            && GuestResult == GuestHighRegionExpectedResult;
        } else if (LowMemoryBiasRequested) {
          const size_t TargetOffset = GuestLowTargetAddress - GuestLowPageAddress;
          std::memcpy(&GuestLowStoredValue, GuestLowPage.data() + TargetOffset, sizeof(GuestLowStoredValue));
          GuestMemoryBiasPassed = GuestLowStoredValue == GuestLowExpectedValue && GuestResult == GuestLowExpectedValue;
        } else if (SparseRedirectRequested) {
          std::memcpy(
            &GuestRedirectStoredValue,
            static_cast<uint8_t*>(SparseRedirectMapping.Data())
              + (GuestRedirectTargetAddress - GuestRedirectPageAddress),
            sizeof(GuestRedirectStoredValue));
          std::memcpy(
            &GuestAdjacentStoredValue,
            static_cast<uint8_t*>(SparseLinearMapping.Data()) + GuestAdjacentTargetAddress,
            sizeof(GuestAdjacentStoredValue));
          GuestSparseRedirectPassed =
            GuestRedirectStoredValue == GuestRedirectExpectedValue
            && GuestAdjacentStoredValue == GuestAdjacentExpectedValue
            && GuestResult == GuestAdjacentExpectedValue;
        }
      }
      if (InvalidationRequested) {
        auto CodeInvalidationLock = FEXCore::GuardSignalDeferringSection(Context->GetCodeInvalidationMutex(), Thread);
        Context->InvalidateCodeBuffersCodeRange(GuestRIP, GuestCode.size());
        Context->InvalidateThreadCachedCodeRange(Thread, GuestRIP, GuestCode.size());
        CodeInvalidationExercised = true;
      }
      if (IndirectInvalidationRequested) {
        constexpr size_t FakeJITSize = 256ULL * 1024 * 1024;
        constexpr size_t FakeRecordBytes = 64;
        auto* FakeJIT = static_cast<uint8_t*>(FEXCore::Allocator::VirtualAlloc(FakeJITSize, true));
        if (FakeJIT == nullptr || FakeJIT == MAP_FAILED) {
          std::cerr << "No se pudo reservar el registro JIT indirecto.\n";
          return 70;
        }

        auto* Record = reinterpret_cast<FEXCore::Context::ExitFunctionLinkData*>(FakeJIT + 0x10);
        const uint64_t FakeGuestRIP = GuestRIP + 0x100000;
        const uint64_t FarHostCode = reinterpret_cast<uint64_t>(FakeJIT) + 0x0C000000ULL;
        {
          FEXCore::Allocator::JITWriteScope WriteScope;
          std::fill_n(FakeJIT, FakeRecordBytes, uint8_t {});
          Record->GuestRIP = FakeGuestRIP;
          Record->CallerOffset = 0x10;
        }

        fextl::set<uint64_t> FakeEntrypoints {FakeGuestRIP};
        fextl::vector<uint64_t> FakeCodePages {FakeGuestRIP & ~uint64_t {0xFFF}};
        {
          auto LookupWriteLock = Thread->LookupCache->Shared->AcquireWriteLock();
          Thread->LookupCache->Shared->AddBlockExecutableRange(
            FakeEntrypoints, FakeCodePages.front(), FEXCore::Utils::FEX_PAGE_SIZE, LookupWriteLock);
          Thread->LookupCache->Shared->AddBlockMapping(
            FakeGuestRIP, FakeCodePages, reinterpret_cast<void*>(FarHostCode), LookupWriteLock);
        }

        using ExitFunctionLinkFn = uint64_t (*)(FEXCore::Core::CpuStateFrame*, FEXCore::Context::ExitFunctionLinkData*);
        auto ExitFunctionLink = reinterpret_cast<ExitFunctionLinkFn>(Thread->CurrentFrame->Pointers.ExitFunctionLink);
        const uint64_t LinkedHostCode = ExitFunctionLink(Thread->CurrentFrame, Record);
        const uint64_t CallerAddress = reinterpret_cast<uint64_t>(FakeJIT) + 0x10;
        IndirectBranchDistance = FarHostCode - CallerAddress;
        if (LinkedHostCode != FarHostCode || IndirectBranchDistance <= 0x08000000ULL) {
          std::cerr << "El enlazador no seleccionó el destino indirecto controlado.\n";
          return 70;
        }
        IndirectLinkExercised = true;

        {
          auto CodeInvalidationLock = FEXCore::GuardSignalDeferringSection(Context->GetCodeInvalidationMutex(), Thread);
          Context->InvalidateCodeBuffersCodeRange(FakeGuestRIP, 1);
          Context->InvalidateThreadCachedCodeRange(Thread, FakeGuestRIP, 1);
        }
        IndirectInvalidationExercised = true;
        FEXCore::Allocator::VirtualFree(FakeJIT, FakeJITSize);
      }
      Context->DestroyThread(Thread);
    }

    const std::string_view ReceiptMode =
      RegionFaultAttributionRequested ? "execute-region-fault-attribution"
      : RegionLifecycleRequested ? "execute-region-lifecycle"
      : AddressTranslationRequested ? "inspect-address-translation"
      : SparseHighRegionsRequested ? "execute-sparse-high-regions"
      : SparseRedirectRequested ? "execute-sparse-page-redirect"
      : LowMemoryBiasRequested ? "execute-low-memory-bias"
      : IndirectInvalidationRequested ? "invalidate-indirect"
      : InvalidationRequested ? "invalidate-linked"
      : LinkedExecutionRequested ? "execute-linked"
      : ExecutionRequested ? "execute-one"
      : CompilationRequested ? "compile-one"
      : InitCoreRequested ? "init-core"
                          : "context";
    std::cout << "{\"schema\":1,\"host\":\"macos-arm64\",\"mode\":\""
              << ReceiptMode
              << "\",\"small_alignment_allocation\":true,\"config_initialized\":true,\"context_created\":true,\"init_core\":"
              << (CoreInitialized ? "true" : "false")
              << ",\"signal_delegator\":" << (InitCoreRequested ? "true" : "false")
              << ",\"syscall_handler\":" << (CompilationRequested ? "true" : "false")
              << ",\"thread_created\":" << (CompilationRequested ? "true" : "false")
              << ",\"guest_x86_decoded\":" << (JITBlockCompiled ? "true" : "false")
              << ",\"jit_block_compiled\":" << (JITBlockCompiled ? "true" : "false")
              << ",\"guest_code_executed\":" << (GuestCodeExecuted ? "true" : "false")
              << ",\"guest_result\":" << GuestResult
              << ",\"runtime_link_exercised\":" << (LinkedExecutionRequested && GuestCodeExecuted ? "true" : "false")
              << ",\"code_invalidation_exercised\":" << (CodeInvalidationExercised ? "true" : "false")
              << ",\"indirect_link_exercised\":" << (IndirectLinkExercised ? "true" : "false")
              << ",\"indirect_invalidation_exercised\":" << (IndirectInvalidationExercised ? "true" : "false")
              << ",\"indirect_branch_distance\":" << IndirectBranchDistance
              << ",\"guest_memory_bias_enabled\":"
              << ((LowMemoryBiasRequested || SparseRedirectRequested || SparseHighRegionsRequested
                   || AddressTranslationRequested || RegionLifecycleRequested
                   || RegionFaultAttributionRequested) ? "true" : "false")
              << ",\"guest_low_target_address\":" << GuestLowTargetAddress
              << ",\"guest_low_stored_value\":" << GuestLowStoredValue
              << ",\"guest_memory_bias_passed\":" << (GuestMemoryBiasPassed ? "true" : "false")
              << ",\"guest_sparse_redirect_enabled\":"
              << ((SparseRedirectRequested || AddressTranslationRequested) ? "true" : "false")
              << ",\"guest_redirect_target_address\":" << GuestRedirectTargetAddress
              << ",\"guest_adjacent_target_address\":" << GuestAdjacentTargetAddress
              << ",\"guest_redirect_stored_value\":" << GuestRedirectStoredValue
              << ",\"guest_adjacent_stored_value\":" << GuestAdjacentStoredValue
              << ",\"guest_sparse_redirect_passed\":" << (GuestSparseRedirectPassed ? "true" : "false")
              << ",\"guest_sparse_high_regions_enabled\":"
              << ((SparseHighRegionsRequested || AddressTranslationRequested || RegionLifecycleRequested
                   || RegionFaultAttributionRequested)
                    ? "true" : "false")
              << ",\"guest_high_region_1_target_address\":" << GuestHighRegion1TargetAddress
              << ",\"guest_high_region_2_target_address\":" << GuestHighRegion2TargetAddress
              << ",\"guest_high_region_1_stored_value\":" << GuestHighRegion1StoredValue
              << ",\"guest_high_region_2_stored_value\":" << GuestHighRegion2StoredValue
              << ",\"guest_sparse_high_regions_passed\":" << (GuestSparseHighRegionsPassed ? "true" : "false")
              << ",\"address_translation_contract_enabled\":" << (AddressTranslationRequested ? "true" : "false")
              << ",\"translated_low_host_address\":" << TranslatedLowHostAddress
              << ",\"translated_redirect_host_address\":" << TranslatedRedirectHostAddress
              << ",\"translated_high_region_1_host_address\":" << TranslatedHighRegion1HostAddress
              << ",\"translated_high_region_2_host_address\":" << TranslatedHighRegion2HostAddress
              << ",\"round_trip_low_guest_address\":" << RoundTripLowGuestAddress
              << ",\"round_trip_redirect_guest_address\":" << RoundTripRedirectGuestAddress
              << ",\"round_trip_high_region_1_guest_address\":" << RoundTripHighRegion1GuestAddress
              << ",\"round_trip_high_region_2_guest_address\":" << RoundTripHighRegion2GuestAddress
              << ",\"invalid_guest_overlap_rejected\":" << (InvalidGuestOverlapRejected ? "true" : "false")
              << ",\"invalid_host_overlap_rejected\":" << (InvalidHostOverlapRejected ? "true" : "false")
              << ",\"unmapped_guest_rejected\":" << (UnmappedGuestRejected ? "true" : "false")
              << ",\"unmapped_host_rejected\":" << (UnmappedHostRejected ? "true" : "false")
              << ",\"null_translation_output_rejected\":" << (NullTranslationOutputRejected ? "true" : "false")
              << ",\"address_translation_contract_passed\":" << (AddressTranslationContractPassed ? "true" : "false")
              << ",\"guest_region_lifecycle_enabled\":" << (RegionLifecycleRequested ? "true" : "false")
              << ",\"guest_lifecycle_initial_result\":" << GuestLifecycleInitialResult
              << ",\"guest_lifecycle_updated_result\":" << GuestLifecycleUpdatedResult
              << ",\"lifecycle_host_code_before_update\":" << LifecycleHostCodeBeforeUpdate
              << ",\"lifecycle_host_code_after_update\":" << LifecycleHostCodeAfterUpdate
              << ",\"lifecycle_updated_host_address\":" << LifecycleUpdatedHostAddress
              << ",\"guest_region_update_passed\":" << (GuestRegionUpdatePassed ? "true" : "false")
              << ",\"guest_region_clear_passed\":" << (GuestRegionClearPassed ? "true" : "false")
              << ",\"guest_backing_protection_passed\":" << (GuestBackingProtectionPassed ? "true" : "false")
              << ",\"guest_backing_unmap_passed\":" << (GuestBackingUnmapPassed ? "true" : "false")
              << ",\"jit_block_reused_after_region_update\":"
              << (JITBlockReusedAfterRegionUpdate ? "true" : "false")
              << ",\"guest_region_lifecycle_passed\":" << (GuestRegionLifecyclePassed ? "true" : "false")
              << ",\"guest_region_fault_attribution_enabled\":"
              << (RegionFaultAttributionRequested ? "true" : "false")
              << ",\"guest_region_fault_handler_attached\":"
              << (GuestRegionFaultHandlerAttached ? "true" : "false")
              << ",\"guest_region_fault_seen\":" << (GuestRegionFaultSeen ? "true" : "false")
              << ",\"guest_region_fault_count\":" << GuestRegionFaultCount
              << ",\"guest_region_fault_signal\":" << GuestRegionFaultSignal
              << ",\"guest_region_fault_code\":" << GuestRegionFaultCode
              << ",\"guest_region_fault_host_address\":" << GuestRegionFaultHostAddress
              << ",\"guest_region_fault_expected_host_address\":"
              << GuestRegionFaultExpectedHostAddress
              << ",\"guest_region_fault_guest_address\":" << GuestRegionFaultGuestAddress
              << ",\"guest_region_fault_expected_guest_address\":" << GuestHighRegion1TargetAddress
              << ",\"guest_region_fault_recovered_rip\":" << GuestRegionFaultRecoveredRIP
              << ",\"guest_region_fault_expected_rip\":" << GuestRegionFaultExpectedRIP
              << ",\"guest_region_fault_host_pc\":" << GuestRegionFaultHostProgramCounter
              << ",\"guest_region_fault_host_pc_in_jit\":"
              << (GuestRegionFaultHostPCInJIT ? "true" : "false")
              << ",\"guest_region_fault_translation_succeeded\":"
              << (GuestRegionFaultTranslationSucceeded ? "true" : "false")
              << ",\"guest_region_fault_expected_host_matched\":"
              << (GuestRegionFaultExpectedHostMatched ? "true" : "false")
              << ",\"guest_region_fault_backing_protected\":"
              << (GuestRegionFaultBackingProtected ? "true" : "false")
              << ",\"guest_region_fault_handlers_restored\":"
              << (GuestRegionFaultHandlersRestored ? "true" : "false")
              << ",\"guest_region_fault_backing_restored\":"
              << (GuestRegionFaultBackingRestored ? "true" : "false")
              << ",\"guest_region_fault_map_cleared\":"
              << (GuestRegionFaultMapCleared ? "true" : "false")
              << ",\"guest_region_fault_attribution_passed\":"
              << (GuestRegionFaultAttributionPassed ? "true" : "false")
              << ",\"guest_elf_executed\":false}\n";
    return 0;
  } catch (const std::exception& Error) {
    std::cerr << "FEXCore context exception: " << Error.what() << '\n';
  } catch (...) {
    std::cerr << "FEXCore context exception: unknown\n";
  }

  std::cout << R"({"schema":1,"host":"macos-arm64","small_alignment_allocation":true,"context_created":false,"init_core":false,"guest_elf_executed":false})"
            << '\n';
  return 70;
}
