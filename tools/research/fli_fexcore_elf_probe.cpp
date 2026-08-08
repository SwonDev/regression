// SPDX-License-Identifier: MIT

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <Linux/Utils/ELFContainer.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <optional>
#include <string>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr uint64_t GuestEntryOffset = 0x100;
constexpr uint64_t ExpectedSyscall = 60;
constexpr uint64_t ExpectedExitCode = 42;

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

class ProbeSyscallHandler final : public FEXCore::HLE::SyscallHandler {
public:
  ProbeSyscallHandler(uint64_t GuestBase, uint64_t GuestSize)
    : GuestBase {GuestBase}
    , GuestSize {GuestSize} {
    OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64;
  }

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame*, FEXCore::HLE::SyscallArguments* Arguments) override {
    SyscallSeen = true;
    SyscallNumber = Arguments->Argument[0];
    SyscallArgument = Arguments->Argument[1];
    return 0;
  }

  FEXCore::HLE::ExecutableRangeInfo
  QueryGuestExecutableRange(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return {GuestBase, GuestSize, false};
  }

  std::optional<FEXCore::ExecutableFileSectionInfo>
  LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return std::nullopt;
  }

  bool SyscallSeen {};
  uint64_t SyscallNumber {std::numeric_limits<uint64_t>::max()};
  uint64_t SyscallArgument {std::numeric_limits<uint64_t>::max()};

private:
  uint64_t GuestBase {};
  uint64_t GuestSize {};
};

class TemporaryELF final {
public:
  bool Create() {
    std::array<uint8_t, 4096> Image {};
    Elf64_Ehdr Header {};
    Header.e_ident[EI_MAG0] = ELFMAG0;
    Header.e_ident[EI_MAG1] = ELFMAG1;
    Header.e_ident[EI_MAG2] = ELFMAG2;
    Header.e_ident[EI_MAG3] = ELFMAG3;
    Header.e_ident[EI_CLASS] = ELFCLASS64;
    Header.e_ident[EI_DATA] = ELFDATA2LSB;
    Header.e_ident[EI_VERSION] = EV_CURRENT;
    Header.e_ident[EI_OSABI] = ELFOSABI_SYSV;
    Header.e_type = ET_EXEC;
    Header.e_machine = EM_X86_64;
    Header.e_version = EV_CURRENT;
    Header.e_entry = GuestEntryOffset;
    Header.e_phoff = sizeof(Elf64_Ehdr);
    Header.e_ehsize = sizeof(Elf64_Ehdr);
    Header.e_phentsize = sizeof(Elf64_Phdr);
    Header.e_phnum = 1;
    Header.e_shentsize = sizeof(Elf64_Shdr);

    constexpr std::array<uint8_t, 13> GuestCode {
      0xB8, 0x3C, 0x00, 0x00, 0x00, // mov eax, 60 (exit)
      0xBF, 0x2A, 0x00, 0x00, 0x00, // mov edi, 42
      0x0F, 0x05,                   // syscall
      0xF4,                         // hlt (salida controlada de la sonda)
    };

    Elf64_Phdr ProgramHeader {};
    ProgramHeader.p_type = PT_LOAD;
    ProgramHeader.p_flags = PF_R | PF_X;
    ProgramHeader.p_offset = 0;
    ProgramHeader.p_vaddr = 0;
    ProgramHeader.p_paddr = 0;
    ProgramHeader.p_filesz = GuestEntryOffset + GuestCode.size();
    ProgramHeader.p_memsz = ProgramHeader.p_filesz;
    ProgramHeader.p_align = 0x1000;

    std::memcpy(Image.data(), &Header, sizeof(Header));
    std::memcpy(Image.data() + Header.e_phoff, &ProgramHeader, sizeof(ProgramHeader));
    std::copy(GuestCode.begin(), GuestCode.end(), Image.begin() + GuestEntryOffset);

    char Pattern[] = "/private/tmp/regression-fli-elf-probe.XXXXXX";
    const int Descriptor = mkstemp(Pattern);
    if (Descriptor == -1) {
      return false;
    }
    Path = Pattern;
    if (fchmod(Descriptor, S_IRUSR | S_IWUSR) == -1) {
      close(Descriptor);
      unlink(Path.c_str());
      Path.clear();
      return false;
    }

    size_t Written {};
    while (Written < Image.size()) {
      const ssize_t Result = write(Descriptor, Image.data() + Written, Image.size() - Written);
      if (Result == -1 && errno == EINTR) {
        continue;
      }
      if (Result <= 0) {
        close(Descriptor);
        unlink(Path.c_str());
        Path.clear();
        return false;
      }
      Written += static_cast<size_t>(Result);
    }

    if (close(Descriptor) == -1) {
      unlink(Path.c_str());
      Path.clear();
      return false;
    }
    return true;
  }

  ~TemporaryELF() {
    if (!Path.empty()) {
      unlink(Path.c_str());
    }
  }

  const std::string& GetPath() const {
    return Path;
  }

private:
  std::string Path;
};

class GuestMapping final {
public:
  bool Allocate() {
    const long PageSize = sysconf(_SC_PAGESIZE);
    Size = PageSize > 0 ? static_cast<size_t>(PageSize) : 16 * 1024;
    Base = mmap(nullptr, Size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return Base != MAP_FAILED;
  }

  ~GuestMapping() {
    if (Base != MAP_FAILED) {
      munmap(Base, Size);
    }
  }

  void* GetBase() const {
    return Base;
  }

  size_t GetSize() const {
    return Size;
  }

private:
  void* Base {MAP_FAILED};
  size_t Size {};
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

int main() {
  TemporaryELF Fixture;
  if (!Fixture.Create()) {
    std::cerr << "No se pudo crear el ELF controlado.\n";
    return 70;
  }

  ELFLoader::ELFContainer Container {fextl::string {Fixture.GetPath().c_str()}, fextl::string {}, true};
  if (!Container.WasLoaded() || Container.GetMode() != ELFLoader::ELFContainer::MODE_64BIT || Container.HasDynamicLinker()) {
    std::cerr << "El parser público de FEX rechazó el ELF x86-64 controlado.\n";
    return 70;
  }

  GuestMapping Mapping;
  if (!Mapping.Allocate()) {
    std::cerr << "No se pudo reservar la memoria huésped.\n";
    return 70;
  }

  bool SectionBoundsValid {true};
  const uint64_t GuestBase = reinterpret_cast<uint64_t>(Mapping.GetBase());
  Container.WriteLoadableSections(
    [&](void* Data, uint64_t GuestAddress, uint64_t Size) {
      if (GuestAddress < GuestBase || GuestAddress + Size < GuestAddress || GuestAddress + Size > GuestBase + Mapping.GetSize()) {
        SectionBoundsValid = false;
        return;
      }
      std::memcpy(reinterpret_cast<void*>(GuestAddress), Data, Size);
    },
    GuestBase);
  if (!SectionBoundsValid || mprotect(Mapping.GetBase(), Mapping.GetSize(), PROT_READ) == -1) {
    std::cerr << "El mapeo ELF controlado no respetó sus límites.\n";
    return 70;
  }

  FEXCore::HostFeatures Features {};
  Features.DCacheLineSize = 64;
  Features.ICacheLineSize = 64;
  Features.SupportsCacheMaintenanceOps = true;
  Features.CPUMIDRs.emplace_back(0x61000000U);

  ConfigLifetime Config;
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");

  ProbeSignalDelegator SignalDelegator;
  ProbeSyscallHandler SyscallHandler {GuestBase, Mapping.GetSize()};
  auto Context = FEXCore::Context::Context::CreateNewContext(Features);
  if (!Context) {
    std::cerr << "FEXCore no creó el contexto ELF.\n";
    return 70;
  }
  Context->EnableExitOnHLT();
  Context->SetSignalDelegator(&SignalDelegator);
  Context->SetSyscallHandler(&SyscallHandler);
  if (!Context->InitCore()) {
    std::cerr << "FEXCore no inicializó el contexto ELF.\n";
    return 70;
  }

  alignas(16) std::array<uint8_t, 16 * 1024> GuestStack {};
  const uint64_t GuestRIP = GuestBase + Container.GetEntryPoint();
  const uint64_t GuestRSP = (reinterpret_cast<uint64_t>(GuestStack.data() + GuestStack.size())) & ~uint64_t {0xF};
  auto* Thread = Context->CreateThread(GuestRIP, GuestRSP);
  if (Thread == nullptr) {
    std::cerr << "FEXCore no creó el hilo ELF.\n";
    return 70;
  }

  std::array<FEXCore::Core::CPUState::gdt_segment, 32> GDT {};
  ConfigureLongMode(Thread, GDT);
  Context->CompileRIP(Thread, GuestRIP);
  Context->ExecuteThread(Thread);

  const bool Passed = SyscallHandler.SyscallSeen && SyscallHandler.SyscallNumber == ExpectedSyscall
                   && SyscallHandler.SyscallArgument == ExpectedExitCode;
  Context->DestroyThread(Thread);

  std::cout << "{\"schema\":1,\"host\":\"macos-arm64\",\"parser\":\"FEX-ELFContainer\",\"elf_loaded\":true"
            << ",\"elf_class\":64,\"elf_machine\":\"x86_64\",\"dynamic_linker\":false"
            << ",\"guest_entry_offset\":" << Container.GetEntryPoint()
            << ",\"guest_elf_executed\":true,\"linux_syscall_seen\":" << (SyscallHandler.SyscallSeen ? "true" : "false")
            << ",\"linux_syscall_number\":" << SyscallHandler.SyscallNumber
            << ",\"linux_syscall_argument\":" << SyscallHandler.SyscallArgument
            << ",\"expected_exit_code\":" << ExpectedExitCode
            << ",\"proton_executed\":false,\"steam_executed\":false,\"eac_executed\":false}\n";
  return Passed ? 0 : 70;
}
