// SPDX-License-Identifier: MIT

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/ArchHelpers/Arm64.h>
#include <FEXCore/Utils/LongJump.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <Linux/Utils/ELFParser.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <optional>
#include <signal.h>
#include <set>
#include <string>
#include <sys/ucontext.h>
#include <utility>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <poll.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/event.h>
#include <sys/mount.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern "C" ssize_t __getdirentries64(int, char*, size_t, off_t*);

namespace {
constexpr uint64_t InterpreterLoadOffset = 0x1'0000;
constexpr uint64_t InterpreterEntryOffset = 0x200;
constexpr uint64_t InterpreterDataOffset = 0x2000;
constexpr uint64_t StackOffset = 0x3'0000;
constexpr uint64_t StackStringsOffset = 0x3'1000;
constexpr size_t GuestMemorySize = 512 * 1024;
constexpr uint64_t RealInterpreterLoadOffset = 32 * 1024 * 1024;
constexpr uint64_t RealMMapArenaOffset = 48 * 1024 * 1024;
constexpr uint64_t RealMMapArenaLimitOffset = 112 * 1024 * 1024;
constexpr uint64_t RealLowPageAliasOffset = 116 * 1024 * 1024;
constexpr uint64_t RealLowPageAliasBackingSize = 16 * 1024;
constexpr uint64_t RealStackOffset = 120 * 1024 * 1024;
constexpr uint64_t RealStackStringsOffset = RealStackOffset + 0x4000;
constexpr uint64_t RealStopOffset = 127 * 1024 * 1024;
constexpr size_t RealGuestMemorySize = 128 * 1024 * 1024;
constexpr uint64_t LinuxSharedUserDataAddress = 0x7ffe0000;
constexpr uint64_t LinuxSharedUserDataSize = 4096;
constexpr uint64_t LinuxGuestPageSize = 4096;
constexpr uint64_t ObservedWineSessionMappingSize = 0x144000;
constexpr uint64_t ObservedWineUserSharedDataInitializationSize = 1848;
constexpr uint64_t LowGuestAddressLimit = uint64_t {1} << 32;
constexpr uint64_t HighSparseGuestBase = LowGuestAddressLimit;
constexpr uint64_t HighSparseGuestSize = 16 * 1024 * 1024;
static_assert(RealMMapArenaLimitOffset <= RealLowPageAliasOffset);
static_assert(RealLowPageAliasOffset + RealLowPageAliasBackingSize <= RealStackOffset);
static_assert(HighSparseGuestBase % LinuxGuestPageSize == 0);
static_assert(HighSparseGuestSize % LinuxGuestPageSize == 0);
constexpr uint64_t ReadSyscall = 0;
constexpr uint64_t WriteSyscall = 1;
constexpr uint64_t OpenSyscall = 2;
constexpr uint64_t StatSyscall = 4;
constexpr uint64_t PollSyscall = 7;
constexpr uint64_t BrkSyscall = 12;
constexpr uint64_t RtSigactionSyscall = 13;
constexpr uint64_t RtSigprocmaskSyscall = 14;
constexpr uint64_t IoctlSyscall = 16;
constexpr uint64_t LinuxTCGets2 = 0x802c542a;
constexpr uint64_t LinuxExt2IOCGetFlags = 0x80086601;
constexpr uint64_t AccessSyscall = 21;
constexpr uint64_t DupSyscall = 32;
constexpr uint64_t SocketSyscall = 41;
constexpr uint64_t ConnectSyscall = 42;
constexpr uint64_t AcceptSyscall = 43;
constexpr bool ExperimentalAcceptDispatchEnabled = true;
constexpr uint64_t SendMsgSyscall = 46;
constexpr uint64_t RecvMsgSyscall = 47;
constexpr uint64_t ShutdownSyscall = 48;
constexpr uint64_t BindSyscall = 49;
constexpr uint64_t ListenSyscall = 50;
constexpr uint64_t SocketPairSyscall = 53;
constexpr uint64_t SetSockOptSyscall = 54;
constexpr uint64_t GetSockOptSyscall = 55;
constexpr uint64_t GetPIDSyscall = 39;
constexpr uint64_t GetTIDSyscall = 186;
constexpr uint64_t CloneSyscall = 56;
constexpr uint64_t FcntlSyscall = 72;
constexpr uint64_t FTruncateSyscall = 77;
constexpr uint64_t ExecveSyscall = 59;
constexpr uint64_t Wait4Syscall = 61;
constexpr uint64_t WriteVSyscall = 20;
constexpr uint64_t PRead64Syscall = 17;
constexpr uint64_t PWrite64Syscall = 18;
constexpr uint64_t FStatSyscall = 5;
constexpr uint64_t MMapSyscall = 9;
constexpr uint64_t MUnmapSyscall = 11;
constexpr uint64_t EpollCreateSyscall = 213;
constexpr uint64_t GetDents64Syscall = 217;
constexpr uint64_t EpollWaitSyscall = 232;
constexpr uint64_t EpollCtlSyscall = 233;
constexpr uint64_t TgkillSyscall = 234;
constexpr uint64_t EpollPWait2Syscall = 441;
constexpr uint64_t CloseSyscall = 3;
constexpr uint64_t PrctlSyscall = 157;
constexpr uint64_t ArchPrctlSyscall = 158;
constexpr uint64_t SetTIDAddressSyscall = 218;
constexpr uint64_t SetRobustListSyscall = 273;
constexpr uint64_t RSeqSyscall = 334;
constexpr uint64_t MProtectSyscall = 10;
constexpr uint64_t Prlimit64Syscall = 302;
constexpr uint64_t Pipe2Syscall = 293;
constexpr uint64_t ClockGettimeSyscall = 228;
constexpr uint64_t ClockNanosleepSyscall = 230;
constexpr uint64_t GetrandomSyscall = 318;
constexpr uint64_t MemfdCreateSyscall = 319;
constexpr uint64_t UserfaultfdSyscall = 323;
constexpr uint64_t Clone3Syscall = 435;
constexpr uint64_t FAccessAt2Syscall = 439;
constexpr uint64_t FutexWaitVSyscall = 449;
constexpr uint64_t UnameSyscall = 63;
constexpr uint64_t GetcwdSyscall = 79;
constexpr uint64_t ChdirSyscall = 80;
constexpr uint64_t FChdirSyscall = 81;
constexpr uint64_t RenameSyscall = 82;
constexpr uint64_t MkdirSyscall = 83;
constexpr uint64_t UnlinkSyscall = 87;
constexpr uint64_t SymlinkSyscall = 88;
constexpr uint64_t ReadlinkSyscall = 89;
constexpr uint64_t ChmodSyscall = 90;
constexpr uint64_t UmaskSyscall = 95;
constexpr uint64_t GettimeofdaySyscall = 96;
constexpr uint64_t SysinfoSyscall = 99;
constexpr uint64_t TimeSyscall = 201;
constexpr uint64_t SchedGetAffinitySyscall = 204;
constexpr uint64_t GetUIDSyscall = 102;
constexpr uint64_t SetPrioritySyscall = 141;
constexpr uint64_t SigAltStackSyscall = 131;
constexpr uint64_t LinuxX86MinSignalStackSize = 2048;
constexpr uint64_t FStatFSSyscall = 138;
constexpr uint64_t OpenAtSyscall = 257;
constexpr uint64_t NewFStatAtSyscall = 262;
constexpr uint64_t ExitSyscall = 60;
constexpr uint64_t ExitGroupSyscall = 231;
constexpr uint64_t ExpectedExitCode = 42;
constexpr uint64_t FailureExitCode = 99;
constexpr int64_t LinuxAtFDCWD = -100;
constexpr int64_t LinuxFSetFDCommand = 2;
constexpr int64_t LinuxFGetFLCommand = 3;
constexpr int64_t LinuxFSetFLCommand = 4;
constexpr uint64_t LinuxOWriteOnlyAccessMode = 0x1;
constexpr uint64_t LinuxOReadWriteAccessMode = 0x2;
constexpr uint64_t LinuxOAppend = 0x400;
constexpr uint64_t LinuxONonBlock = 0x800;
constexpr std::string_view ExpectedArgument = "probe-arg";
constexpr std::string_view ExpectedOutput = "regression-fex-dynamic\n";
constexpr std::string_view InterpreterPath = "/lib64/ld-regression-probe.so";

bool WineIPCTraceEnabled() {
  const char* Enabled = getenv("REGRESSION_FLI_TRACE_WINE_IPC");
  return Enabled != nullptr && std::string_view {Enabled} == "1";
}

void TraceWineRequestHeader(
  std::string_view Source,
  int Descriptor,
  const void* Header,
  size_t HeaderSize) {
  if (!WineIPCTraceEnabled() || Header == nullptr || HeaderSize < 12) {
    return;
  }

  int32_t RequestCode {};
  uint32_t RequestSize {};
  uint32_t ReplySize {};
  const auto* Bytes = static_cast<const uint8_t*>(Header);
  std::memcpy(&RequestCode, Bytes, sizeof(RequestCode));
  std::memcpy(&RequestSize, Bytes + 4, sizeof(RequestSize));
  std::memcpy(&ReplySize, Bytes + 8, sizeof(ReplySize));
  std::cerr << "TRACE wine-ipc request source=" << Source
            << " fd=" << Descriptor
            << " req=" << RequestCode
            << " request-size=" << RequestSize
            << " reply-size=" << ReplySize
            << '\n';
  std::cerr.flush();
}

void TraceWineReplyHeader(
  std::string_view Source,
  int Descriptor,
  const void* Header,
  size_t HeaderSize) {
  if (!WineIPCTraceEnabled() || Header == nullptr || HeaderSize < 8) {
    return;
  }

  uint32_t Error {};
  uint32_t ReplySize {};
  const auto* Bytes = static_cast<const uint8_t*>(Header);
  std::memcpy(&Error, Bytes, sizeof(Error));
  std::memcpy(&ReplySize, Bytes + 4, sizeof(ReplySize));
  std::cerr << "TRACE wine-ipc reply source=" << Source
            << " fd=" << Descriptor
            << " error=" << Error
            << " reply-size=" << ReplySize
            << '\n';
  std::cerr.flush();
}

enum class ConnectPathClass : uint8_t {
  None,
  Empty,
  Abstract,
  Absolute,
  Relative,
};

constexpr std::string_view ConnectPathClassName(ConnectPathClass PathClass) {
  switch (PathClass) {
  case ConnectPathClass::None:
    return "none";
  case ConnectPathClass::Empty:
    return "empty";
  case ConnectPathClass::Abstract:
    return "abstract";
  case ConnectPathClass::Absolute:
    return "absolute";
  case ConnectPathClass::Relative:
    return "relative";
  }
  return "unknown";
}

enum class ConnectFailureReason : uint8_t {
  None,
  UnownedDescriptor,
  UnreadableAddress,
  UnsupportedFamily,
  EmptyPayload,
  AbstractPath,
  EmptyPath,
  RelativePath,
  PathResolutionRejected,
  HostCWDNotMirrored,
  MissingTarget,
  TargetNotSocket,
  HostPathTooLong,
  HostConnectFailed,
};

constexpr std::string_view ConnectFailureReasonName(ConnectFailureReason Reason) {
  switch (Reason) {
  case ConnectFailureReason::None:
    return "none";
  case ConnectFailureReason::UnownedDescriptor:
    return "unowned-descriptor";
  case ConnectFailureReason::UnreadableAddress:
    return "unreadable-address";
  case ConnectFailureReason::UnsupportedFamily:
    return "unsupported-family";
  case ConnectFailureReason::EmptyPayload:
    return "empty-payload";
  case ConnectFailureReason::AbstractPath:
    return "abstract-path";
  case ConnectFailureReason::EmptyPath:
    return "empty-path";
  case ConnectFailureReason::RelativePath:
    return "relative-path";
  case ConnectFailureReason::PathResolutionRejected:
    return "path-resolution-rejected";
  case ConnectFailureReason::HostCWDNotMirrored:
    return "host-cwd-not-mirrored";
  case ConnectFailureReason::MissingTarget:
    return "missing-target";
  case ConnectFailureReason::TargetNotSocket:
    return "target-not-socket";
  case ConnectFailureReason::HostPathTooLong:
    return "host-path-too-long";
  case ConnectFailureReason::HostConnectFailed:
    return "host-connect-failed";
  }
  return "unknown";
}

enum class AcceptFailureReason : uint8_t {
  None,
  NonListeningOrUnownedDescriptor,
  UnreadableAddressOrLength,
  UnmeasuredAddressLength,
  HostAcceptFailed,
  UnsupportedHostAddress,
};

constexpr std::string_view AcceptFailureReasonName(AcceptFailureReason Reason) {
  switch (Reason) {
  case AcceptFailureReason::None:
    return "none";
  case AcceptFailureReason::NonListeningOrUnownedDescriptor:
    return "non-listening-or-unowned-descriptor";
  case AcceptFailureReason::UnreadableAddressOrLength:
    return "unreadable-address-or-length";
  case AcceptFailureReason::UnmeasuredAddressLength:
    return "unmeasured-address-length";
  case AcceptFailureReason::HostAcceptFailed:
    return "host-accept-failed";
  case AcceptFailureReason::UnsupportedHostAddress:
    return "unsupported-host-address";
  }
  return "unknown";
}

enum class GetSockOptFailureReason : uint8_t {
  None,
  UnownedDescriptor,
  UnreadableLength,
  UnmeasuredShape,
  UnreadableValue,
  HostPeerIdentityFailed,
  HostPeerProcessFailed,
  HostPeerProcessLengthMismatch,
};

constexpr std::string_view GetSockOptFailureReasonName(GetSockOptFailureReason Reason) {
  switch (Reason) {
  case GetSockOptFailureReason::None:
    return "none";
  case GetSockOptFailureReason::UnownedDescriptor:
    return "unowned-descriptor";
  case GetSockOptFailureReason::UnreadableLength:
    return "unreadable-length";
  case GetSockOptFailureReason::UnmeasuredShape:
    return "unmeasured-shape";
  case GetSockOptFailureReason::UnreadableValue:
    return "unreadable-value";
  case GetSockOptFailureReason::HostPeerIdentityFailed:
    return "host-peer-identity-failed";
  case GetSockOptFailureReason::HostPeerProcessFailed:
    return "host-peer-process-failed";
  case GetSockOptFailureReason::HostPeerProcessLengthMismatch:
    return "host-peer-process-length-mismatch";
  }
  return "unknown";
}

enum class SendMsgFailureReason : uint8_t {
  None,
  UnownedDescriptor,
  UnreadableHeader,
  UnreadableIOVector,
  UnreadablePayload,
  UnreadableControl,
  UnmeasuredShape,
  UnownedTransferredDescriptor,
  HostControlLayoutUnavailable,
  HostSendFailed,
};

constexpr std::string_view SendMsgFailureReasonName(SendMsgFailureReason Reason) {
  switch (Reason) {
  case SendMsgFailureReason::None:
    return "none";
  case SendMsgFailureReason::UnownedDescriptor:
    return "unowned-descriptor";
  case SendMsgFailureReason::UnreadableHeader:
    return "unreadable-header";
  case SendMsgFailureReason::UnreadableIOVector:
    return "unreadable-iovector";
  case SendMsgFailureReason::UnreadablePayload:
    return "unreadable-payload";
  case SendMsgFailureReason::UnreadableControl:
    return "unreadable-control";
  case SendMsgFailureReason::UnmeasuredShape:
    return "unmeasured-shape";
  case SendMsgFailureReason::UnownedTransferredDescriptor:
    return "unowned-transferred-descriptor";
  case SendMsgFailureReason::HostControlLayoutUnavailable:
    return "host-control-layout-unavailable";
  case SendMsgFailureReason::HostSendFailed:
    return "host-send-failed";
  }
  return "unknown";
}

enum class MUnmapFailureReason : uint8_t {
  None,
  UnmeasuredShape,
  HostAnonymousRemapFailed,
  HostAnonymousRemapAddressMismatch,
  SparseHighUnmapFailed,
};

constexpr std::string_view MUnmapFailureReasonName(MUnmapFailureReason Reason) {
  switch (Reason) {
  case MUnmapFailureReason::None:
    return "none";
  case MUnmapFailureReason::UnmeasuredShape:
    return "unmeasured-shape";
  case MUnmapFailureReason::HostAnonymousRemapFailed:
    return "host-anonymous-remap-failed";
  case MUnmapFailureReason::HostAnonymousRemapAddressMismatch:
    return "host-anonymous-remap-address-mismatch";
  case MUnmapFailureReason::SparseHighUnmapFailed:
    return "sparse-high-unmap-failed";
  }
  return "unknown";
}

struct LinuxPeerCredentials {
  int32_t ProcessID {};
  uint32_t UserID {};
  uint32_t GroupID {};
};
static_assert(sizeof(LinuxPeerCredentials) == 12);

struct LinuxX86_64Stat {
  uint64_t Device {};
  uint64_t Inode {};
  uint64_t LinkCount {};
  uint32_t Mode {};
  uint32_t UserID {};
  uint32_t GroupID {};
  int32_t Padding {};
  uint64_t SpecialDevice {};
  int64_t Size {};
  int64_t BlockSize {};
  int64_t BlockCount {};
  int64_t AccessSeconds {};
  int64_t AccessNanoseconds {};
  int64_t ModificationSeconds {};
  int64_t ModificationNanoseconds {};
  int64_t ChangeSeconds {};
  int64_t ChangeNanoseconds {};
  std::array<int64_t, 3> Reserved {};
};
static_assert(sizeof(LinuxX86_64Stat) == 144);

struct __attribute__((packed)) LinuxDirent64Header {
  uint64_t Inode {};
  int64_t Offset {};
  uint16_t RecordLength {};
  uint8_t Type {};
};
static_assert(sizeof(LinuxDirent64Header) == 19);

struct LinuxRLimit64 {
  uint64_t Current {};
  uint64_t Maximum {};
};
static_assert(sizeof(LinuxRLimit64) == 16);

struct LinuxX86_64StackT {
  uint64_t StackPointer {};
  int32_t Flags {};
  uint32_t Padding {};
  uint64_t Size {};
};
static_assert(sizeof(LinuxX86_64StackT) == 24);

struct Prlimit64TraceEntry {
  int32_t ProcessID {};
  int32_t Resource {};
  std::string NewLimitClass {"none"};
  std::string OldLimitClass {"none"};
  uint64_t RequestedCurrent {};
  uint64_t RequestedMaximum {};
};

struct EpollCtlTraceEntry {
  int32_t EpollDescriptor {};
  int32_t Operation {};
  int32_t TargetDescriptor {};
  bool EventReadable {};
  uint32_t Events {};
  uint64_t Data {};
};

struct RegistryTemporarySyscallTraceEntry {
  uint64_t Number {};
  std::array<uint64_t, 6> Arguments {};
  bool Argument1DescriptorOwned {};
  bool Argument1MatchesRegistryTemporary {};
  bool Argument1DescriptorRegular {};
  bool Argument1DescriptorFIFO {};
  bool Argument1DescriptorSocket {};
};

struct RegistryTemporaryWriteTraceEntry {
  int64_t Descriptor {-1};
  uint64_t Buffer {};
  uint64_t ByteCount {};
  std::string BufferClass {"none"};
  bool BufferReadable {};
  uint64_t BufferFingerprint {};
  int64_t HostDescriptorFlags {-1};
  int64_t HostDescriptorError {};
  int64_t HostStatusFlags {-1};
  int64_t HostStatusError {};
  bool DescriptorStatSucceeded {};
  bool DescriptorRegular {};
  bool DescriptorFIFO {};
  bool DescriptorSocket {};
};

struct RegistryRenameTraceEntry {
  bool OldPathReadable {};
  bool NewPathReadable {};
  std::string OldPathClass {"none"};
  std::string NewPathClass {"none"};
  std::string OldDiagnosticPath {"redacted"};
  std::string NewDiagnosticPath {"redacted"};
  uint64_t OldPathLength {};
  uint64_t NewPathLength {};
  uint64_t OldPathFingerprint {};
  uint64_t NewPathFingerprint {};
  bool OldHostPathResolved {};
  bool NewHostPathResolved {};
  bool OldTargetExists {};
  bool OldTargetRegular {};
  bool OldTargetDirectory {};
  bool OldTargetSymlink {};
  bool NewTargetExists {};
  bool NewTargetRegular {};
  bool NewTargetDirectory {};
  bool NewTargetSymlink {};
  bool SameHostParent {};
};

struct Pipe2TraceEntry {
  uint64_t GuestPipe {};
  uint64_t Flags {};
  std::string PointerClass {"none"};
  bool LowShadowMapped {};
  bool LowShadowWritable {};
};

struct LinuxIOVector64 {
  uint64_t Base {};
  uint64_t Length {};
};
static_assert(sizeof(LinuxIOVector64) == 16);

struct LinuxMessageHeader64 {
  uint64_t Name {};
  uint32_t NameLength {};
  uint32_t NamePadding {};
  uint64_t IOVectors {};
  uint64_t IOVectorCount {};
  uint64_t Control {};
  uint64_t ControlLength {};
  int32_t Flags {};
  uint32_t FlagsPadding {};
};
static_assert(sizeof(LinuxMessageHeader64) == 56);

struct LinuxControlMessageHeader64 {
  uint64_t Length {};
  int32_t Level {};
  int32_t Type {};
};
static_assert(sizeof(LinuxControlMessageHeader64) == 16);

struct HighMMapRecord {
  uint64_t Address {};
  uint64_t Length {};
  uint64_t ArenaEnd {};
  uint64_t Protection {};
  uint64_t Flags {};
  uint64_t Offset {};
  int64_t Descriptor {-1};
  std::string DescriptorPathClass {"none"};
  std::string DescriptorGuestPath {"none"};
  bool Active {};
};

struct LowMMapRecord {
  uint64_t Address {};
  uint64_t Length {};
  uint64_t Protection {};
  uint64_t Flags {};
  uint64_t Offset {};
  int64_t Descriptor {-1};
  std::string DescriptorPathClass {"none"};
  std::string DescriptorGuestPath {"none"};
};

struct MMapCallRecord {
  uint64_t SyscallOrdinal {};
  uint64_t GuestRIP {};
  uint64_t GuestRSP {};
  uint64_t GuestRBP {};
  uint64_t GuestReturnAddress {};
  bool GuestReturnAddressReadable {};
  uint64_t GuestHeaderBuffer {};
  bool GuestHeaderReadable {};
  uint64_t GuestHeaderFirst64ByteFingerprint {};
  uint32_t GuestHeaderMagic {};
  uint16_t GuestHeaderType {};
  uint16_t GuestHeaderMachine {};
  uint64_t GuestHeaderEntry {};
  uint64_t RequestedAddress {};
  uint64_t Length {};
  uint64_t Protection {};
  uint64_t Flags {};
  uint64_t Offset {};
  int64_t Descriptor {-1};
  bool Completed {};
  bool Succeeded {};
  uint64_t ReturnedValue {};
  int64_t LinuxError {};
  uint64_t MappingAddress {};
  std::string OutcomeReason {"none"};
};

struct ReadELFHeaderRecord {
  uint64_t SyscallOrdinal {};
  int64_t Descriptor {-1};
  uint64_t GuestBuffer {};
  uint64_t RequestedByteCount {};
  uint64_t ReturnedByteCount {};
  uint64_t First64ByteFingerprint {};
  uint32_t Magic {};
  uint8_t ELFClass {};
  uint8_t DataEncoding {};
  uint16_t Type {};
  uint16_t Machine {};
  uint32_t Version {};
  uint64_t Entry {};
  uint64_t ProgramHeaderOffset {};
  uint16_t ProgramHeaderEntrySize {};
  uint16_t ProgramHeaderCount {};
  std::string DescriptorPathClass {"none"};
  std::string DescriptorGuestPath {"none"};
};

struct MMapArenaRejectRecord {
  uint64_t SyscallOrdinal {};
  uint64_t GuestRIP {};
  uint64_t GuestRSP {};
  uint64_t GuestReturnAddress {};
  bool GuestReturnAddressReadable {};
  std::array<uint64_t, 4> GuestStackWords {};
  uint64_t GuestStackWordCount {};
  uint64_t RequestedAddress {};
  uint64_t MappingAddress {};
  uint64_t Length {};
  uint64_t AlignedLength {};
  uint64_t Protection {};
  uint64_t Flags {};
  uint64_t Offset {};
  uint64_t NextMMapAddress {};
  int64_t Descriptor {-1};
  bool SharedFileShape {};
};

struct LinuxTimespec64 {
  int64_t Seconds {};
  int64_t Nanoseconds {};
};
static_assert(sizeof(LinuxTimespec64) == 16);

struct LinuxTimeval64 {
  int64_t Seconds {};
  int64_t Microseconds {};
};
static_assert(sizeof(LinuxTimeval64) == 16);

struct LinuxTimezone {
  int32_t MinutesWest {};
  int32_t DestinationTime {};
};
static_assert(sizeof(LinuxTimezone) == 8);

struct LinuxX86_64Sysinfo {
  int64_t Uptime {};
  std::array<uint64_t, 3> Loads {};
  uint64_t TotalRAM {};
  uint64_t FreeRAM {};
  uint64_t SharedRAM {};
  uint64_t BufferRAM {};
  uint64_t TotalSwap {};
  uint64_t FreeSwap {};
  uint16_t Processes {};
  uint16_t Padding {};
  uint64_t TotalHigh {};
  uint64_t FreeHigh {};
  uint32_t MemoryUnit {};
};
static_assert(sizeof(LinuxX86_64Sysinfo) == 112);
static_assert(offsetof(LinuxX86_64Sysinfo, TotalHigh) == 88);
static_assert(offsetof(LinuxX86_64Sysinfo, MemoryUnit) == 104);

struct LinuxX86_64StatFS {
  int64_t Type {};
  int64_t BlockSize {};
  uint64_t Blocks {};
  uint64_t BlocksFree {};
  uint64_t BlocksAvailable {};
  uint64_t Files {};
  uint64_t FilesFree {};
  std::array<int32_t, 2> FileSystemID {};
  int64_t NameLength {};
  int64_t FragmentSize {};
  int64_t Flags {};
  std::array<int64_t, 4> Spare {};
};
static_assert(sizeof(LinuxX86_64StatFS) == 120);

struct LinuxPollFD {
  int32_t Descriptor {};
  int16_t Events {};
  int16_t ReturnedEvents {};
};
static_assert(sizeof(LinuxPollFD) == 8);

struct LinuxFlock64 {
  int16_t Type {};
  int16_t Whence {};
  int32_t Padding {};
  int64_t Start {};
  int64_t Length {};
  int32_t ProcessID {};
  int32_t FinalPadding {};
};
static_assert(sizeof(LinuxFlock64) == 32);

struct FcntlTraceEntry {
  int64_t Descriptor {};
  int64_t Command {};
  uint64_t Argument {};
  bool DescriptorOwned {};
  bool DescriptorStandard {};
  bool DescriptorClosed {};
};

struct SetSockOptTraceEntry {
  int64_t Descriptor {};
  bool DescriptorOwned {};
  int64_t Level {};
  int64_t Option {};
  uint64_t ValueLength {};
  bool ValueReadable {};
  bool Int32ValueReadable {};
  int64_t Int32Value {};
};

struct LinuxFutexWaitV {
  uint64_t Value {};
  uint64_t Address {};
  uint32_t Flags {};
  uint32_t Reserved {};
};
static_assert(sizeof(LinuxFutexWaitV) == 24);

struct __attribute__((packed)) LinuxEpollEvent {
  uint32_t Events {};
  uint64_t Data {};
};
static_assert(sizeof(LinuxEpollEvent) == 12);

struct LinuxClone3Args {
  uint64_t Flags {};
  uint64_t PIDFD {};
  uint64_t ChildTID {};
  uint64_t ParentTID {};
  uint64_t ExitSignal {};
  uint64_t Stack {};
  uint64_t StackSize {};
  uint64_t TLS {};
  uint64_t SetTID {};
  uint64_t SetTIDSize {};
  uint64_t CGroup {};
};
static_assert(sizeof(LinuxClone3Args) == 88);

struct LinuxGuestSigAction {
  uint64_t Handler {};
  uint64_t Flags {};
  uint64_t Restorer {};
  uint64_t Mask {};
};
static_assert(sizeof(LinuxGuestSigAction) == 32);

std::optional<clockid_t> TranslateLinuxClockID(int32_t LinuxClock) {
  switch (LinuxClock) {
  case 0: return CLOCK_REALTIME;
  case 1: return CLOCK_MONOTONIC;
  case 2: return CLOCK_PROCESS_CPUTIME_ID;
  case 3: return CLOCK_THREAD_CPUTIME_ID;
#ifdef CLOCK_MONOTONIC_RAW
  case 4: return CLOCK_MONOTONIC_RAW;
#endif
  case 5: return CLOCK_REALTIME;
  case 6: return CLOCK_MONOTONIC;
  case 7: return CLOCK_MONOTONIC;
  default: return std::nullopt;
  }
}

bool IsValidLinuxTimespec(const LinuxTimespec64& Time) {
  return Time.Seconds >= 0 && Time.Nanoseconds >= 0 && Time.Nanoseconds < 1'000'000'000;
}

uint64_t FingerprintBytes(const uint8_t* Bytes, size_t Size) {
  constexpr uint64_t OffsetBasis = 14'695'981'039'346'656'037ULL;
  constexpr uint64_t Prime = 1'099'511'628'211ULL;
  uint64_t Hash = OffsetBasis;
  for (size_t Index = 0; Index < Size; ++Index) {
    Hash ^= Bytes[Index];
    Hash *= Prime;
  }
  return Hash;
}

int TranslateHostSocketErrorToLinux(int HostError) {
  switch (HostError) {
  case EAGAIN: return 11;
  case EINPROGRESS: return 115;
  case EALREADY: return 114;
  case ENOTSOCK: return 88;
  case EDESTADDRREQ: return 89;
  case EMSGSIZE: return 90;
  case EPROTOTYPE: return 91;
  case ENOPROTOOPT: return 92;
  case EPROTONOSUPPORT: return 93;
  case ESOCKTNOSUPPORT: return 94;
  case EOPNOTSUPP: return 95;
  case EPFNOSUPPORT: return 96;
  case EAFNOSUPPORT: return 97;
  case EADDRINUSE: return 98;
  case EADDRNOTAVAIL: return 99;
  case ENETDOWN: return 100;
  case ENETUNREACH: return 101;
  case ENETRESET: return 102;
  case ECONNABORTED: return 103;
  case ECONNRESET: return 104;
  case ENOBUFS: return 105;
  case EISCONN: return 106;
  case ENOTCONN: return 107;
  case ESHUTDOWN: return 108;
  case ETOOMANYREFS: return 109;
  case ETIMEDOUT: return 110;
  case ECONNREFUSED: return 111;
  case EHOSTDOWN: return 112;
  case EHOSTUNREACH: return 113;
  default: return HostError;
  }
}

int TranslateHostFileLockErrorToLinux(int HostError) {
  switch (HostError) {
  case EAGAIN: return 11;
  case EDEADLK: return 35;
  case ENOLCK: return 37;
  case EOVERFLOW: return 75;
  default: return HostError;
  }
}

int TranslateHostDupErrorToLinux(int HostError) {
  switch (HostError) {
  case EBADF: return 9;
  case EINTR: return 4;
  case EMFILE: return 24;
  case ENFILE: return 23;
  case ENOMEM: return 12;
  default: return 5;
  }
}

int TranslateHostFileOpenErrorToLinux(int HostError) {
  switch (HostError) {
  case EACCES: return 13;
  case EEXIST: return 17;
  case EINTR: return 4;
  case EISDIR: return 21;
  case ELOOP: return 40;
  case EMFILE: return 24;
  case ENAMETOOLONG: return 36;
  case ENFILE: return 23;
  case ENOENT: return 2;
  case ENOMEM: return 12;
  case ENOSPC: return 28;
  case ENOTDIR: return 20;
  case EROFS: return 30;
  default: return 5;
  }
}

int TranslateHostFcntlGetFlagsErrorToLinux(int HostError) {
  switch (HostError) {
  case EBADF: return 9;
  case EINTR: return 4;
  case EINVAL: return 22;
  default: return 5;
  }
}

int TranslateHostRegularWriteErrorToLinux(int HostError) {
  switch (HostError) {
  case EBADF: return 9;
  case EFBIG: return 27;
  case EINTR: return 4;
  case EINVAL: return 22;
  case EIO: return 5;
  case ENOSPC: return 28;
  case EPIPE: return 32;
  default: return 5;
  }
}

int TranslateHostRenameErrorToLinux(int HostError) {
  switch (HostError) {
  case EACCES: return 13;
  case EBUSY: return 16;
  case EEXIST: return 17;
  case EINVAL: return 22;
  case EIO: return 5;
  case EISDIR: return 21;
  case ELOOP: return 40;
  case ENAMETOOLONG: return 36;
  case ENOENT: return 2;
  case ENOSPC: return 28;
  case ENOTDIR: return 20;
  case ENOTEMPTY: return 39;
  case EPERM: return 1;
  case EROFS: return 30;
  case EXDEV: return 18;
  default: return 5;
  }
}

timespec RelativeDelayUntil(const LinuxTimespec64& Target, const timespec& Now) {
  timespec Delay {
    static_cast<time_t>(Target.Seconds - static_cast<int64_t>(Now.tv_sec)),
    static_cast<long>(Target.Nanoseconds - static_cast<int64_t>(Now.tv_nsec)),
  };
  if (Delay.tv_nsec < 0) {
    --Delay.tv_sec;
    Delay.tv_nsec += 1'000'000'000;
  }
  return Delay;
}

struct LinuxUtsName {
  std::array<char, 65> SystemName {};
  std::array<char, 65> NodeName {};
  std::array<char, 65> Release {};
  std::array<char, 65> Version {};
  std::array<char, 65> Machine {};
  std::array<char, 65> DomainName {};
};
static_assert(sizeof(LinuxUtsName) == 390);

class ConfigLifetime final {
public:
  ConfigLifetime() {
    FEXCore::Config::Initialize();
  }

  ~ConfigLifetime() {
    FEXCore::Config::Shutdown();
  }
};

class HostDisassemblyLogLifetime final {
public:
  explicit HostDisassemblyLogLifetime(bool Enabled)
    : Enabled {Enabled} {
    if (Enabled) {
      LogMan::Msg::InstallHandler([](LogMan::DebugLevels, const char* Message) {
        std::fprintf(stderr, "%s\n", Message);
      });
    }
  }

  ~HostDisassemblyLogLifetime() {
    if (Enabled) {
      LogMan::Msg::UnInstallHandler();
    }
  }

private:
  bool Enabled {};
};

struct MachVMRegionSnapshot {
  bool Present {};
  uint64_t Start {};
  uint64_t Size {};
  int Protection {};
  int MaximumProtection {};
};

struct MachVMAdjacencySnapshot {
  bool ScanSucceeded {};
  uint64_t RegionsScanned {};
  int ScanResult {KERN_INVALID_ARGUMENT};
  MachVMRegionSnapshot Previous;
  MachVMRegionSnapshot Containing;
  MachVMRegionSnapshot Next;
  uint64_t FaultOffsetWithinContaining {std::numeric_limits<uint64_t>::max()};
  bool FaultAtContainingLastByte {};
  bool FaultAtPreviousRegionEnd {};
  bool FaultOneByteBeforeNextRegion {};
};

MachVMAdjacencySnapshot InspectMachVMAdjacency(uint64_t FaultAddress) {
  MachVMAdjacencySnapshot Snapshot;
  mach_vm_address_t Cursor {};
  constexpr uint64_t MaximumRegionCount = 65'536;

  const auto ReadRegion = [](mach_vm_address_t QueryAddress,
                             MachVMRegionSnapshot* Region,
                             mach_vm_address_t* NextAddress) {
    mach_vm_address_t RegionAddress = QueryAddress;
    mach_vm_size_t RegionSize {};
    vm_region_basic_info_data_64_t Info {};
    mach_msg_type_number_t InfoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t ObjectName = MACH_PORT_NULL;
    const kern_return_t Result = mach_vm_region(
      mach_task_self(),
      &RegionAddress,
      &RegionSize,
      VM_REGION_BASIC_INFO_64,
      reinterpret_cast<vm_region_info_t>(&Info),
      &InfoCount,
      &ObjectName);
    if (ObjectName != MACH_PORT_NULL) {
      mach_port_deallocate(mach_task_self(), ObjectName);
    }
    if (Result != KERN_SUCCESS) {
      return Result;
    }
    if (RegionSize == 0
        || RegionAddress > std::numeric_limits<mach_vm_address_t>::max() - RegionSize) {
      return static_cast<kern_return_t>(KERN_INVALID_ADDRESS);
    }
    if (Region != nullptr) {
      Region->Present = true;
      Region->Start = RegionAddress;
      Region->Size = RegionSize;
      Region->Protection = Info.protection;
      Region->MaximumProtection = Info.max_protection;
    }
    if (NextAddress != nullptr) {
      *NextAddress = RegionAddress + RegionSize;
    }
    return Result;
  };

  for (uint64_t Index = 0; Index < MaximumRegionCount; ++Index) {
    MachVMRegionSnapshot Region;
    mach_vm_address_t NextAddress {};
    const kern_return_t Result = ReadRegion(Cursor, &Region, &NextAddress);
    Snapshot.ScanResult = Result;
    if (Result != KERN_SUCCESS) {
      return Snapshot;
    }
    ++Snapshot.RegionsScanned;

    const uint64_t RegionEnd = Region.Start + Region.Size;
    if (FaultAddress >= Region.Start && FaultAddress < RegionEnd) {
      Snapshot.Containing = Region;
      Snapshot.FaultOffsetWithinContaining = FaultAddress - Region.Start;
      Snapshot.FaultAtContainingLastByte = FaultAddress
          != std::numeric_limits<uint64_t>::max()
        && FaultAddress + 1 == RegionEnd;
      MachVMRegionSnapshot NextRegion;
      mach_vm_address_t IgnoredNextAddress {};
      const kern_return_t NextResult = ReadRegion(
        static_cast<mach_vm_address_t>(RegionEnd),
        &NextRegion,
        &IgnoredNextAddress);
      if (NextResult == KERN_SUCCESS) {
        Snapshot.Next = NextRegion;
        Snapshot.FaultOneByteBeforeNextRegion = FaultAddress
            != std::numeric_limits<uint64_t>::max()
          && FaultAddress + 1 == Snapshot.Next.Start;
      }
      Snapshot.ScanSucceeded = true;
      Snapshot.ScanResult = KERN_SUCCESS;
      return Snapshot;
    }
    if (Region.Start > FaultAddress) {
      Snapshot.Next = Region;
      Snapshot.FaultAtPreviousRegionEnd = Snapshot.Previous.Present
        && Snapshot.Previous.Start + Snapshot.Previous.Size == FaultAddress;
      Snapshot.FaultOneByteBeforeNextRegion = FaultAddress
          != std::numeric_limits<uint64_t>::max()
        && FaultAddress + 1 == Snapshot.Next.Start;
      Snapshot.ScanSucceeded = true;
      Snapshot.ScanResult = KERN_SUCCESS;
      return Snapshot;
    }

    Snapshot.Previous = Region;
    if (NextAddress <= Cursor) {
      Snapshot.ScanResult = KERN_INVALID_ADDRESS;
      return Snapshot;
    }
    Cursor = NextAddress;
  }

  Snapshot.ScanResult = KERN_RESOURCE_SHORTAGE;
  return Snapshot;
}

// macOS/arm64 mantiene los primeros 4 GiB detrás de __PAGEZERO. Esta reserva
// alta representa ese espacio lógico sin intentar mapear ninguna dirección
// baja del host. Solo se activa en la A/B explícita del laboratorio.
class LowGuestShadowMapping final {
public:
  static constexpr uint8_t MappedBit = 0x80;

  bool Allocate() {
    const long PageSizeResult = sysconf(_SC_PAGESIZE);
    if (PageSizeResult <= 0 || (PageSizeResult & (PageSizeResult - 1)) != 0
        || static_cast<uint64_t>(PageSizeResult) % LinuxGuestPageSize != 0
        || LowGuestAddressLimit > std::numeric_limits<size_t>::max()) {
      return false;
    }
    HostPageSize = static_cast<size_t>(PageSizeResult);
    Base = mmap(
      nullptr,
      static_cast<size_t>(LowGuestAddressLimit),
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS,
      -1,
      0);
    if (Base == MAP_FAILED) {
      return false;
    }
    RedirectBase = mmap(
      nullptr,
      HostPageSize,
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS,
      -1,
      0);
    if (RedirectBase == MAP_FAILED) {
      munmap(Base, static_cast<size_t>(LowGuestAddressLimit));
      Base = MAP_FAILED;
      return false;
    }
    PageStates.assign(
      static_cast<size_t>(LowGuestAddressLimit / LinuxGuestPageSize),
      uint8_t {});
    return true;
  }

  ~LowGuestShadowMapping() {
    if (RedirectBase != MAP_FAILED) {
      munmap(RedirectBase, HostPageSize);
    }
    if (Base != MAP_FAILED) {
      munmap(Base, static_cast<size_t>(LowGuestAddressLimit));
    }
  }

  bool IsAllocated() const {
    return Base != MAP_FAILED && RedirectBase != MAP_FAILED
      && HostPageSize != 0 && !PageStates.empty();
  }

  uint64_t Bias() const {
    return IsAllocated() ? reinterpret_cast<uint64_t>(Base) : 0;
  }

  size_t HostPageBytes() const {
    return HostPageSize;
  }

  uint64_t RedirectGuestPageAddress() const {
    return IsAllocated() ? LinuxSharedUserDataAddress : 0;
  }

  uint64_t RedirectHostPageAddress() const {
    return IsAllocated() ? reinterpret_cast<uint64_t>(RedirectBase) : 0;
  }

  uint64_t MappedLogicalPageMask(uint64_t Address, uint64_t Length) const {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0
        || Length % LinuxGuestPageSize != 0
        || Length / LinuxGuestPageSize > 64) {
      return 0;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    uint64_t Mask {};
    for (size_t Index = 0; Index < PageCount; ++Index) {
      if ((PageStates[FirstPage + Index] & MappedBit) != 0) {
        Mask |= uint64_t {1} << Index;
      }
    }
    return Mask;
  }

  uint64_t PackedLogicalPageStates(uint64_t Address, uint64_t Length) const {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0
        || Length % LinuxGuestPageSize != 0
        || Length / LinuxGuestPageSize > sizeof(uint64_t)) {
      return 0;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    uint64_t Packed {};
    for (size_t Index = 0; Index < PageCount; ++Index) {
      Packed |= uint64_t {PageStates[FirstPage + Index]} << (Index * 8);
    }
    return Packed;
  }

  bool ContainsLogicalRange(uint64_t Address, uint64_t Size) const {
    return IsAllocated() && Size != 0 && Address < LowGuestAddressLimit
      && Size <= LowGuestAddressLimit - Address;
  }

  bool ContainsMappedLogicalRange(
    uint64_t Address,
    uint64_t Size,
    int RequiredProtection = 0) const {
    if (!ContainsLogicalRange(Address, Size)
        || (RequiredProtection & ~(PROT_READ | PROT_WRITE | PROT_EXEC)) != 0) {
      return false;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    const size_t LastPage = static_cast<size_t>(
      (Address + Size - 1) / LinuxGuestPageSize);
    for (size_t Page = FirstPage; Page <= LastPage; ++Page) {
      const uint8_t State = PageStates[Page];
      if ((State & MappedBit) == 0
          || (State & RequiredProtection) != RequiredProtection) {
        return false;
      }
    }
    return true;
  }

  uint8_t PageStateForLogicalAddress(uint64_t Address) const {
    if (!ContainsLogicalRange(Address, 1)) {
      return 0;
    }
    return PageStates[static_cast<size_t>(Address / LinuxGuestPageSize)];
  }

  void* HostPointerForMappedLogicalRange(
    uint64_t Address,
    uint64_t Size,
    int RequiredProtection = 0) const {
    return ContainsMappedLogicalRange(Address, Size, RequiredProtection)
        && IsHostContiguousRange(Address, Size)
      ? Translate(Address)
      : nullptr;
  }

  void* HostPointerForWritableLogicalRange(uint64_t Address, uint64_t Size) const {
    return HostPointerForMappedLogicalRange(Address, Size, PROT_WRITE);
  }

  bool ContainsHostAddress(uint64_t Address) const {
    if (!IsAllocated()) {
      return false;
    }
    const uint64_t RedirectAddress = RedirectHostPageAddress();
    return (Address >= Bias() && Address - Bias() < LowGuestAddressLimit)
      || (Address >= RedirectAddress && Address - RedirectAddress < LinuxGuestPageSize);
  }

  uint64_t LogicalAddress(uint64_t HostAddress) const {
    const uint64_t RedirectAddress = RedirectHostPageAddress();
    if (RedirectAddress != 0 && HostAddress >= RedirectAddress
        && HostAddress - RedirectAddress < LinuxGuestPageSize) {
      return LinuxSharedUserDataAddress + (HostAddress - RedirectAddress);
    }
    return IsAllocated() && HostAddress >= Bias()
        && HostAddress - Bias() < LowGuestAddressLimit
      ? HostAddress - Bias()
      : std::numeric_limits<uint64_t>::max();
  }

  int Map(
    uint64_t Address,
    uint64_t Length,
    uint64_t Protection,
    bool NoReplace,
    bool Anonymous,
    int Descriptor,
    uint64_t Offset,
    uint64_t* FileBytes) {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0 || Length % LinuxGuestPageSize != 0) {
      return EINVAL;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    const auto Begin = PageStates.begin() + static_cast<ptrdiff_t>(FirstPage);
    const auto End = Begin + static_cast<ptrdiff_t>(PageCount);
    if (NoReplace && std::any_of(Begin, End, [](uint8_t State) {
          return (State & MappedBit) != 0;
        })) {
      return EEXIST;
    }
    if (!ResetRedirectAliasForReplacement(Address, Length)) {
      return ENOMEM;
    }

    const std::vector<uint8_t> PreviousStates {Begin, End};
    const bool NeedsContents = !Anonymous || Protection != PROT_NONE;
    if (NeedsContents && !MakeTemporarilyWritable(Address, Length)) {
      return ENOMEM;
    }
    if (NeedsContents) {
      ZeroLogicalRange(Address, Length);
    }
    uint64_t BytesRead {};
    if (!Anonymous) {
      if (Offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
        RestoreStates(FirstPage, PreviousStates);
        ApplyHostProtection(Address, Length);
        return EINVAL;
      }
      const int ReadError = ReadFileIntoLogicalRange(
        Descriptor, Offset, Address, Length, &BytesRead);
      if (ReadError != 0) {
        RestoreStates(FirstPage, PreviousStates);
        ApplyHostProtection(Address, Length);
        return ReadError;
      }
    }

    const uint8_t State = MappedBit | static_cast<uint8_t>(Protection);
    std::fill(Begin, End, State);
    if (!ApplyHostProtection(Address, Length)) {
      RestoreStates(FirstPage, PreviousStates);
      ApplyHostProtection(Address, Length);
      return ENOMEM;
    }
    if (FileBytes != nullptr) {
      *FileBytes = BytesRead;
    }
    ++MapCount;
    MappedGuestPages += PageCount;
    return 0;
  }

  int MapSharedFile(
    uint64_t Address,
    uint64_t Length,
    uint64_t Protection,
    int Descriptor,
    uint64_t Offset,
    uint64_t* HostAddress,
    uint64_t* HostSpan) {
    if (!ContainsLogicalRange(Address, Length)
        || Address != LinuxSharedUserDataAddress
        || Length != LinuxSharedUserDataSize
        || Offset % HostPageSize != 0
        || (Protection & ~uint64_t {PROT_READ | PROT_WRITE | PROT_EXEC}) != 0) {
      return EINVAL;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    if (Offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
      return EINVAL;
    }

    void* const Target = Translate(Address);
    void* const Result = mmap(
      Target,
      HostPageSize,
      static_cast<int>(Protection),
      MAP_SHARED | MAP_FIXED,
      Descriptor,
      static_cast<off_t>(Offset));
    if (Result == MAP_FAILED) {
      return errno;
    }
    if (Result != Target) {
      munmap(Result, HostPageSize);
      return EIO;
    }

    const uint8_t State = MappedBit | static_cast<uint8_t>(Protection);
    PageStates[FirstPage] = State;
    RedirectSharedFileMapped = true;
    if (HostAddress != nullptr) {
      *HostAddress = reinterpret_cast<uint64_t>(Target);
    }
    if (HostSpan != nullptr) {
      *HostSpan = HostPageSize;
    }
    ++MapCount;
    ++MappedGuestPages;
    return 0;
  }

  int Protect(uint64_t Address, uint64_t Length, uint64_t Protection) {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0 || Length % LinuxGuestPageSize != 0) {
      return EINVAL;
    }
    const size_t FirstPage = static_cast<size_t>(Address / LinuxGuestPageSize);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    const auto Begin = PageStates.begin() + static_cast<ptrdiff_t>(FirstPage);
    const auto End = Begin + static_cast<ptrdiff_t>(PageCount);
    if (std::any_of(Begin, End, [](uint8_t State) {
          return (State & MappedBit) == 0;
        })) {
      return ENOMEM;
    }
    const std::vector<uint8_t> PreviousStates {Begin, End};
    for (auto Iterator = Begin; Iterator != End; ++Iterator) {
      *Iterator = MappedBit | static_cast<uint8_t>(Protection);
    }
    if (!ApplyHostProtection(Address, Length)) {
      RestoreStates(FirstPage, PreviousStates);
      ApplyHostProtection(Address, Length);
      return ENOMEM;
    }
    ++ProtectCount;
    return 0;
  }

  uint64_t SuccessfulMapCount() const {
    return MapCount;
  }

  uint64_t SuccessfulProtectCount() const {
    return ProtectCount;
  }

  uint64_t TotalMappedGuestPages() const {
    return MappedGuestPages;
  }

private:
  bool IsRedirectedGuestAddress(uint64_t Address) const {
    return Address >= LinuxSharedUserDataAddress
      && Address - LinuxSharedUserDataAddress < LinuxSharedUserDataSize;
  }

  bool LogicalRangeTouchesRedirect(uint64_t Address, uint64_t Length) const {
    return Length != 0
      && Address < LinuxSharedUserDataAddress + LinuxSharedUserDataSize
      && LinuxSharedUserDataAddress < Address + Length;
  }

  bool IsHostContiguousRange(uint64_t Address, uint64_t Length) const {
    if (!ContainsLogicalRange(Address, Length)
        || !LogicalRangeTouchesRedirect(Address, Length)) {
      return ContainsLogicalRange(Address, Length);
    }
    return IsRedirectedGuestAddress(Address)
      && IsRedirectedGuestAddress(Address + Length - 1);
  }

  void* Translate(uint64_t Address) const {
    if (IsRedirectedGuestAddress(Address)) {
      return static_cast<uint8_t*>(RedirectBase)
        + (Address - LinuxSharedUserDataAddress);
    }
    return static_cast<uint8_t*>(Base) + Address;
  }

  uint64_t AlignDownToHostPage(uint64_t Address) const {
    return Address & ~uint64_t {HostPageSize - 1};
  }

  uint64_t AlignUpToHostPage(uint64_t Address) const {
    return (Address + HostPageSize - 1) & ~uint64_t {HostPageSize - 1};
  }

  void ZeroLogicalRange(uint64_t Address, uint64_t Length) const {
    uint64_t BytesZeroed {};
    while (BytesZeroed < Length) {
      const uint64_t LogicalAddress = Address + BytesZeroed;
      const uint64_t PageRemaining = LinuxGuestPageSize
        - (LogicalAddress % LinuxGuestPageSize);
      const uint64_t Chunk = std::min<uint64_t>(Length - BytesZeroed, PageRemaining);
      std::memset(Translate(LogicalAddress), 0, static_cast<size_t>(Chunk));
      BytesZeroed += Chunk;
    }
  }

  int ReadFileIntoLogicalRange(
    int Descriptor,
    uint64_t Offset,
    uint64_t Address,
    uint64_t Length,
    uint64_t* BytesReadResult) const {
    uint64_t BytesRead {};
    while (BytesRead < Length) {
      const uint64_t LogicalAddress = Address + BytesRead;
      const uint64_t PageRemaining = LinuxGuestPageSize
        - (LogicalAddress % LinuxGuestPageSize);
      const uint64_t Chunk = std::min<uint64_t>(Length - BytesRead, PageRemaining);
      const ssize_t Result = pread(
        Descriptor,
        Translate(LogicalAddress),
        static_cast<size_t>(Chunk),
        static_cast<off_t>(Offset + BytesRead));
      if (Result == -1 && errno == EINTR) {
        continue;
      }
      if (Result == -1) {
        return errno;
      }
      if (Result == 0) {
        break;
      }
      BytesRead += static_cast<uint64_t>(Result);
    }
    if (BytesReadResult != nullptr) {
      *BytesReadResult = BytesRead;
    }
    return 0;
  }

  bool ResetRedirectAliasForReplacement(uint64_t Address, uint64_t Length) {
    if (!RedirectSharedFileMapped || !LogicalRangeTouchesRedirect(Address, Length)) {
      return true;
    }
    void* const Result = mmap(
      RedirectBase,
      HostPageSize,
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
      -1,
      0);
    if (Result == MAP_FAILED || Result != RedirectBase) {
      return false;
    }
    RedirectSharedFileMapped = false;
    return true;
  }

  bool MakeTemporarilyWritable(uint64_t Address, uint64_t Length) const {
    uint64_t LastHostAddress = std::numeric_limits<uint64_t>::max();
    const uint64_t FirstGuestPage = Address & ~(LinuxGuestPageSize - 1);
    const uint64_t LastGuestPage = (Address + Length - 1)
      & ~(LinuxGuestPageSize - 1);
    for (uint64_t GuestPage = FirstGuestPage;
         GuestPage <= LastGuestPage;
         GuestPage += LinuxGuestPageSize) {
      const uint64_t HostAddress = IsRedirectedGuestAddress(GuestPage)
        ? RedirectHostPageAddress()
        : Bias() + AlignDownToHostPage(GuestPage);
      if (HostAddress == LastHostAddress) {
        continue;
      }
      if (mprotect(
            reinterpret_cast<void*>(HostAddress),
            HostPageSize,
            PROT_READ | PROT_WRITE) != 0) {
        return false;
      }
      LastHostAddress = HostAddress;
    }
    return true;
  }

  int ProtectionForState(uint8_t State) const {
    if ((State & MappedBit) == 0) {
      return PROT_NONE;
    }
    const int GuestProtection = State & (PROT_READ | PROT_WRITE | PROT_EXEC);
    int Protection {};
    if ((GuestProtection & (PROT_READ | PROT_EXEC)) != 0) {
      Protection |= PROT_READ;
    }
    if ((GuestProtection & PROT_WRITE) != 0) {
      Protection |= PROT_WRITE;
    }
    return Protection;
  }

  int HostProtectionForLinearPage(uint64_t HostGuestPageAddress) const {
    int Protection {};
    const uint64_t HostPageEnd = HostGuestPageAddress + HostPageSize;
    for (uint64_t GuestPage = HostGuestPageAddress;
         GuestPage < HostPageEnd;
         GuestPage += LinuxGuestPageSize) {
      if (IsRedirectedGuestAddress(GuestPage)) {
        continue;
      }
      const uint8_t State = PageStates[static_cast<size_t>(GuestPage / LinuxGuestPageSize)];
      Protection |= ProtectionForState(State);
    }
    return Protection;
  }

  bool ApplyHostProtection(uint64_t Address, uint64_t Length) const {
    uint64_t LastHostAddress = std::numeric_limits<uint64_t>::max();
    const uint64_t FirstGuestPage = Address & ~(LinuxGuestPageSize - 1);
    const uint64_t LastGuestPage = (Address + Length - 1)
      & ~(LinuxGuestPageSize - 1);
    for (uint64_t GuestPage = FirstGuestPage;
         GuestPage <= LastGuestPage;
         GuestPage += LinuxGuestPageSize) {
      const bool Redirected = IsRedirectedGuestAddress(GuestPage);
      const uint64_t HostGuestPage = AlignDownToHostPage(GuestPage);
      const uint64_t HostAddress = Redirected
        ? RedirectHostPageAddress()
        : Bias() + HostGuestPage;
      if (HostAddress == LastHostAddress) {
        continue;
      }
      const int Protection = Redirected
        ? ProtectionForState(
            PageStates[static_cast<size_t>(GuestPage / LinuxGuestPageSize)])
        : HostProtectionForLinearPage(HostGuestPage);
      if (mprotect(
            reinterpret_cast<void*>(HostAddress),
            HostPageSize,
            Protection) != 0) {
        return false;
      }
      LastHostAddress = HostAddress;
    }
    return true;
  }

  void RestoreStates(size_t FirstPage, const std::vector<uint8_t>& PreviousStates) {
    std::copy(
      PreviousStates.begin(),
      PreviousStates.end(),
      PageStates.begin() + static_cast<ptrdiff_t>(FirstPage));
  }

  void* Base {MAP_FAILED};
  void* RedirectBase {MAP_FAILED};
  size_t HostPageSize {};
  std::vector<uint8_t> PageStates;
  bool RedirectSharedFileMapped {};
  uint64_t MapCount {};
  uint64_t ProtectCount {};
  uint64_t MappedGuestPages {};
};

// Wine sondea el primer rango por encima de 4 GiB antes de crear el stack
// Windows. macOS no puede materializar esa dirección huésped literalmente en
// este proceso Mach-O, así que esta A/B expone una única ventana lógica alta y
// acotada respaldada por páginas host ordinarias. La traducción pertenece al
// contexto FEX experimental; el runtime estable no la activa.
class HighGuestSparseMapping final {
public:
  static constexpr uint8_t MappedBit = 0x80;

  bool Allocate() {
    const long PageSizeResult = sysconf(_SC_PAGESIZE);
    if (PageSizeResult <= 0 || (PageSizeResult & (PageSizeResult - 1)) != 0
        || static_cast<uint64_t>(PageSizeResult) % LinuxGuestPageSize != 0
        || HighSparseGuestSize > std::numeric_limits<size_t>::max()) {
      return false;
    }
    HostPageSize = static_cast<size_t>(PageSizeResult);
    Base = mmap(
      nullptr,
      static_cast<size_t>(HighSparseGuestSize),
      PROT_NONE,
      MAP_PRIVATE | MAP_ANONYMOUS,
      -1,
      0);
    if (Base == MAP_FAILED) {
      return false;
    }
    PageStates.assign(
      static_cast<size_t>(HighSparseGuestSize / LinuxGuestPageSize),
      uint8_t {});
    return true;
  }

  ~HighGuestSparseMapping() {
    if (Base != MAP_FAILED) {
      munmap(Base, static_cast<size_t>(HighSparseGuestSize));
    }
  }

  bool IsAllocated() const {
    return Base != MAP_FAILED && HostPageSize != 0 && !PageStates.empty();
  }

  uint64_t GuestBase() const {
    return HighSparseGuestBase;
  }

  uint64_t HostBase() const {
    return IsAllocated() ? reinterpret_cast<uint64_t>(Base) : 0;
  }

  uint64_t Size() const {
    return IsAllocated() ? HighSparseGuestSize : 0;
  }

  size_t HostPageBytes() const {
    return HostPageSize;
  }

  FEXCore::Context::GuestMemoryAddressRegion Region() const {
    return FEXCore::Context::GuestMemoryAddressRegion {
      .GuestBase = GuestBase(),
      .HostBase = HostBase(),
      .Size = Size(),
    };
  }

  bool ContainsLogicalRange(uint64_t Address, uint64_t Length) const {
    return IsAllocated() && Length != 0 && Address >= HighSparseGuestBase
      && Address - HighSparseGuestBase < HighSparseGuestSize
      && Length <= HighSparseGuestSize - (Address - HighSparseGuestBase);
  }

  bool ContainsMappedLogicalRange(
    uint64_t Address,
    uint64_t Length,
    int RequiredProtection = 0) const {
    if (!ContainsLogicalRange(Address, Length)
        || (RequiredProtection & ~(PROT_READ | PROT_WRITE | PROT_EXEC)) != 0) {
      return false;
    }
    const size_t FirstPage = PageIndex(Address);
    const size_t LastPage = PageIndex(Address + Length - 1);
    for (size_t Page = FirstPage; Page <= LastPage; ++Page) {
      const uint8_t State = PageStates[Page];
      if ((State & MappedBit) == 0
          || (State & RequiredProtection) != RequiredProtection) {
        return false;
      }
    }
    return true;
  }

  void* HostPointerForMappedLogicalRange(
    uint64_t Address,
    uint64_t Length,
    int RequiredProtection = 0) const {
    return ContainsMappedLogicalRange(Address, Length, RequiredProtection)
      ? Translate(Address)
      : nullptr;
  }

  bool ContainsHostAddress(uint64_t Address) const {
    return IsAllocated() && Address >= HostBase()
      && Address - HostBase() < HighSparseGuestSize;
  }

  uint64_t LogicalAddress(uint64_t HostAddress) const {
    return ContainsHostAddress(HostAddress)
      ? HighSparseGuestBase + (HostAddress - HostBase())
      : std::numeric_limits<uint64_t>::max();
  }

  int Map(
    uint64_t Address,
    uint64_t Length,
    uint64_t Protection,
    bool NoReplace,
    bool Anonymous,
    int Descriptor,
    uint64_t Offset,
    uint64_t* FileBytes) {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0
        || Length % LinuxGuestPageSize != 0) {
      return EINVAL;
    }
    const size_t FirstPage = PageIndex(Address);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    const auto Begin = PageStates.begin() + static_cast<ptrdiff_t>(FirstPage);
    const auto End = Begin + static_cast<ptrdiff_t>(PageCount);
    if (NoReplace && std::any_of(Begin, End, [](uint8_t State) {
          return (State & MappedBit) != 0;
        })) {
      return EEXIST;
    }

    const std::vector<uint8_t> PreviousStates {Begin, End};
    if (!MakeTemporarilyWritable(Address, Length)) {
      return ENOMEM;
    }
    std::memset(Translate(Address), 0, static_cast<size_t>(Length));
    uint64_t BytesRead {};
    if (!Anonymous) {
      if (Offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
        RestoreStates(FirstPage, PreviousStates);
        ApplyHostProtection(Address, Length);
        return EINVAL;
      }
      while (BytesRead < Length) {
        const ssize_t Result = pread(
          Descriptor,
          static_cast<uint8_t*>(Translate(Address)) + BytesRead,
          static_cast<size_t>(Length - BytesRead),
          static_cast<off_t>(Offset + BytesRead));
        if (Result == -1 && errno == EINTR) {
          continue;
        }
        if (Result == -1) {
          const int ReadError = errno;
          RestoreStates(FirstPage, PreviousStates);
          ApplyHostProtection(Address, Length);
          return ReadError;
        }
        if (Result == 0) {
          break;
        }
        BytesRead += static_cast<uint64_t>(Result);
      }
    }

    const uint8_t State = MappedBit | static_cast<uint8_t>(Protection);
    const uint64_t PreviouslyMapped = static_cast<uint64_t>(std::count_if(
      Begin,
      End,
      [](uint8_t PreviousState) { return (PreviousState & MappedBit) != 0; }));
    std::fill(Begin, End, State);
    if (!ApplyHostProtection(Address, Length)) {
      RestoreStates(FirstPage, PreviousStates);
      ApplyHostProtection(Address, Length);
      return ENOMEM;
    }
    if (FileBytes != nullptr) {
      *FileBytes = BytesRead;
    }
    ++MapCount;
    MappedGuestPages += PageCount - PreviouslyMapped;
    return 0;
  }

  int Protect(uint64_t Address, uint64_t Length, uint64_t Protection) {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0
        || Length % LinuxGuestPageSize != 0) {
      return EINVAL;
    }
    const size_t FirstPage = PageIndex(Address);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    const auto Begin = PageStates.begin() + static_cast<ptrdiff_t>(FirstPage);
    const auto End = Begin + static_cast<ptrdiff_t>(PageCount);
    if (std::any_of(Begin, End, [](uint8_t State) {
          return (State & MappedBit) == 0;
        })) {
      return ENOMEM;
    }
    const std::vector<uint8_t> PreviousStates {Begin, End};
    for (auto Iterator = Begin; Iterator != End; ++Iterator) {
      *Iterator = MappedBit | static_cast<uint8_t>(Protection);
    }
    if (!ApplyHostProtection(Address, Length)) {
      RestoreStates(FirstPage, PreviousStates);
      ApplyHostProtection(Address, Length);
      return ENOMEM;
    }
    ++ProtectCount;
    return 0;
  }

  int Unmap(uint64_t Address, uint64_t Length) {
    if (!ContainsLogicalRange(Address, Length)
        || Address % LinuxGuestPageSize != 0
        || Length % LinuxGuestPageSize != 0) {
      return EINVAL;
    }
    const size_t FirstPage = PageIndex(Address);
    const size_t PageCount = static_cast<size_t>(Length / LinuxGuestPageSize);
    const auto Begin = PageStates.begin() + static_cast<ptrdiff_t>(FirstPage);
    const auto End = Begin + static_cast<ptrdiff_t>(PageCount);
    const uint64_t PreviouslyMapped = static_cast<uint64_t>(std::count_if(
      Begin,
      End,
      [](uint8_t State) { return (State & MappedBit) != 0; }));
    if (!MakeTemporarilyWritable(Address, Length)) {
      return ENOMEM;
    }
    std::memset(Translate(Address), 0, static_cast<size_t>(Length));
    const std::vector<uint8_t> PreviousStates {Begin, End};
    std::fill(Begin, End, uint8_t {});
    if (!ApplyHostProtection(Address, Length)) {
      RestoreStates(FirstPage, PreviousStates);
      ApplyHostProtection(Address, Length);
      return ENOMEM;
    }
    ++UnmapCount;
    MappedGuestPages -= PreviouslyMapped;
    return 0;
  }

  uint64_t SuccessfulMapCount() const {
    return MapCount;
  }

  uint64_t SuccessfulProtectCount() const {
    return ProtectCount;
  }

  uint64_t SuccessfulUnmapCount() const {
    return UnmapCount;
  }

  uint64_t TotalMappedGuestPages() const {
    return MappedGuestPages;
  }

private:
  size_t PageIndex(uint64_t Address) const {
    return static_cast<size_t>((Address - HighSparseGuestBase) / LinuxGuestPageSize);
  }

  void* Translate(uint64_t Address) const {
    return static_cast<uint8_t*>(Base) + (Address - HighSparseGuestBase);
  }

  uint64_t HostPageGuestBase(uint64_t Address) const {
    const uint64_t Offset = Address - HighSparseGuestBase;
    return HighSparseGuestBase + (Offset & ~uint64_t {HostPageSize - 1});
  }

  int ProtectionForState(uint8_t State) const {
    if ((State & MappedBit) == 0) {
      return PROT_NONE;
    }
    const int GuestProtection = State & (PROT_READ | PROT_WRITE | PROT_EXEC);
    int Protection {};
    if ((GuestProtection & (PROT_READ | PROT_EXEC)) != 0) {
      Protection |= PROT_READ;
    }
    if ((GuestProtection & PROT_WRITE) != 0) {
      Protection |= PROT_WRITE;
    }
    return Protection;
  }

  int HostProtectionForPage(uint64_t HostGuestBase) const {
    int Protection {};
    for (uint64_t GuestPage = HostGuestBase;
         GuestPage < HostGuestBase + HostPageSize;
         GuestPage += LinuxGuestPageSize) {
      Protection |= ProtectionForState(PageStates[PageIndex(GuestPage)]);
    }
    return Protection;
  }

  bool MakeTemporarilyWritable(uint64_t Address, uint64_t Length) const {
    const uint64_t FirstHostGuestBase = HostPageGuestBase(Address);
    const uint64_t LastHostGuestBase = HostPageGuestBase(Address + Length - 1);
    for (uint64_t GuestPage = FirstHostGuestBase;
         GuestPage <= LastHostGuestBase;
         GuestPage += HostPageSize) {
      if (mprotect(Translate(GuestPage), HostPageSize, PROT_READ | PROT_WRITE) != 0) {
        return false;
      }
    }
    return true;
  }

  bool ApplyHostProtection(uint64_t Address, uint64_t Length) const {
    const uint64_t FirstHostGuestBase = HostPageGuestBase(Address);
    const uint64_t LastHostGuestBase = HostPageGuestBase(Address + Length - 1);
    for (uint64_t GuestPage = FirstHostGuestBase;
         GuestPage <= LastHostGuestBase;
         GuestPage += HostPageSize) {
      if (mprotect(
            Translate(GuestPage),
            HostPageSize,
            HostProtectionForPage(GuestPage)) != 0) {
        return false;
      }
    }
    return true;
  }

  void RestoreStates(size_t FirstPage, const std::vector<uint8_t>& PreviousStates) {
    std::copy(
      PreviousStates.begin(),
      PreviousStates.end(),
      PageStates.begin() + static_cast<ptrdiff_t>(FirstPage));
  }

  void* Base {MAP_FAILED};
  size_t HostPageSize {};
  std::vector<uint8_t> PageStates;
  uint64_t MapCount {};
  uint64_t ProtectCount {};
  uint64_t UnmapCount {};
  uint64_t MappedGuestPages {};
};

class ProbeSignalDelegator final : public FEXCore::SignalDelegator {};

// La API pública de FEXCore detiene un hilo desde una señal host redirigiendo
// el ucontext al handler de parada del dispatcher. El límite de esta sonda se
// alcanza dentro de HandleSyscall, donde cambiar solo CPUState::rip no fuerza
// la salida del bloque JIT actual. Este puente reproduce únicamente ese
// mecanismo de control en el helper efímero; no traduce señales del huésped ni
// forma parte del runtime que ejecutará Proton.
class DarwinDiagnosticThreadStopHandler final {
public:
  bool Attach(
    FEXCore::Core::InternalThreadState* Thread,
    uint64_t ThreadStopHandlerAddress,
    uint64_t GuestStopAddress) {
    if (Thread == nullptr || ActiveThread != nullptr
        || ThreadStopHandlerAddress == 0 || GuestStopAddress == 0) {
      return false;
    }

    struct sigaction Action {};
    sigemptyset(&Action.sa_mask);
    Action.sa_sigaction = Handle;
    Action.sa_flags = SA_SIGINFO;
    if (sigaction(SIGUSR2, &Action, &PreviousAction) != 0) {
      return false;
    }

    ActiveThread = Thread;
    ActiveThreadStopHandlerAddress = ThreadStopHandlerAddress;
    ActiveGuestStopAddress = GuestStopAddress;
    SignalTriggered = 0;
    Installed = true;
    return true;
  }

  static int Request() {
    return raise(SIGUSR2);
  }

  bool Triggered() const {
    return SignalTriggered != 0;
  }

  void Reset() {
    if (!Installed) {
      return;
    }
    sigaction(SIGUSR2, &PreviousAction, nullptr);
    ActiveThread = nullptr;
    ActiveThreadStopHandlerAddress = 0;
    ActiveGuestStopAddress = 0;
    Installed = false;
  }

  ~DarwinDiagnosticThreadStopHandler() {
    Reset();
  }

private:
  static void Handle(int Signal, siginfo_t*, void* RawContext) {
    auto* Thread = ActiveThread;
    auto* Context = static_cast<ucontext_t*>(RawContext);
    if (Signal != SIGUSR2 || Thread == nullptr || Context == nullptr
        || Context->uc_mcontext == nullptr
        || ActiveThreadStopHandlerAddress == 0 || ActiveGuestStopAddress == 0) {
      _exit(206);
    }

    auto* Frame = Thread->CurrentFrame;
    if (Frame == nullptr || Frame->ReturningStackLocation == 0) {
      _exit(207);
    }

    Frame->State.rip = ActiveGuestStopAddress;
    auto& HostState = Context->uc_mcontext->__ss;
    HostState.__sp = Frame->ReturningStackLocation;
    HostState.__pc = ActiveThreadStopHandlerAddress;
    SignalTriggered = 1;
  }

  struct sigaction PreviousAction {};
  bool Installed {};
  inline static thread_local FEXCore::Core::InternalThreadState* ActiveThread {};
  inline static thread_local uint64_t ActiveThreadStopHandlerAddress {};
  inline static thread_local uint64_t ActiveGuestStopAddress {};
  inline static thread_local volatile sig_atomic_t SignalTriggered {};
};

class DarwinUnalignedAccessHandler final {
public:
  static constexpr sig_atomic_t MaximumDiagnosticBackpatchCount = 10'000;
  static constexpr size_t MaximumPatternCount = 32;
  static constexpr size_t BoundaryInstructionRadius = 4;
  static constexpr size_t BoundaryInstructionCount = BoundaryInstructionRadius * 2 + 1;

  bool Attach(
    FEXCore::Core::InternalThreadState* Thread,
    uintptr_t GuestMemoryBase,
    size_t GuestMemorySize,
    uintptr_t LowShadowHostBase = 0,
    size_t LowShadowHostSize = 0,
    uintptr_t LowRedirectHostBase = 0,
    size_t LowRedirectHostSize = 0,
    uintptr_t HighSparseHostBase = 0,
    size_t HighSparseHostSize = 0,
    LowGuestShadowMapping* LowShadowMapping = nullptr,
    HighGuestSparseMapping* HighSparseMapping = nullptr) {
    if (Thread == nullptr || ActiveThread != nullptr || GuestMemorySize == 0
        || GuestMemoryBase > std::numeric_limits<uintptr_t>::max() - GuestMemorySize) {
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
    ActiveGuestMemoryBase = GuestMemoryBase;
    ActiveGuestMemoryLimit = GuestMemoryBase + GuestMemorySize;
    ActiveLowShadowHostBase = LowShadowHostBase;
    ActiveLowShadowHostLimit = LowShadowHostBase + LowShadowHostSize;
    ActiveLowRedirectHostBase = LowRedirectHostBase;
    ActiveLowRedirectHostLimit = LowRedirectHostBase + LowRedirectHostSize;
    ActiveHighSparseHostBase = HighSparseHostBase;
    ActiveHighSparseHostLimit = HighSparseHostBase + HighSparseHostSize;
    ActiveLowShadowMapping = LowShadowMapping;
    ActiveHighSparseMapping = HighSparseMapping;
    HandledCount = 0;
    SigbusCount = 0;
    SigsegvCount = 0;
    SigsegvMissingAddressCount = 0;
    HandledPatternCount = 0;
    HandledPatternOverflow = 0;
    HandledPatternGuestRIP.fill(0);
    HandledPatternHostProgramCounter.fill(0);
    HandledPatternInstruction.fill(0);
    HandledPatternFirstFaultAddress.fill(0);
    HandledPatternLastFaultAddress.fill(0);
    HandledPatternSignal.fill(0);
    HandledPatternCode.fill(0);
    HandledPatternHitCount.fill(0);
    SignalBoundarySeen = 0;
    SignalBoundarySignal = 0;
    SignalBoundaryCode = 0;
    SignalBoundaryProgramCounter = 0;
    SignalBoundaryInstruction = 0;
    SignalBoundaryInstructionNeighborhood.fill(0);
    SignalBoundaryInstructionNeighborhoodValidMask = 0;
    SignalBoundaryAddressRegister = 0;
    SignalBoundaryAddressRegisterMatchesFault = 0;
    SignalBoundaryJITGuardPage = 0;
    SignalBoundaryFaultAddress = 0;
    SignalBoundaryX4 = 0;
    SignalBoundaryFSBase = 0;
    SignalBoundaryGSBase = 0;
    SignalBoundaryRSP = 0;
    SignalBoundaryX4MatchesFault = 0;
    SignalBoundaryThreadState = 0;
    SignalBoundaryInterruptPage = 0;
    SignalBoundaryCallRetStack = 0;
    SignalBoundaryFaultOffset = std::numeric_limits<uint64_t>::max();
    SignalBoundaryGuestRIPOffset = std::numeric_limits<uint64_t>::max();
    SignalBoundaryRecoveredGuestRIP = 0;
    SignalBoundaryHostGPRs.fill(0);
    SignalBoundaryGuestGPRs.fill(0);
    DiagnosticBackpatchLimitSeen = 0;
    Handling = false;
    Installed = true;
    return true;
  }

  void Reset() {
    if (!Installed) {
      return;
    }
    ActiveThread = nullptr;
    ActiveGuestMemoryBase = 0;
    ActiveGuestMemoryLimit = 0;
    ActiveLowShadowHostBase = 0;
    ActiveLowShadowHostLimit = 0;
    ActiveLowRedirectHostBase = 0;
    ActiveLowRedirectHostLimit = 0;
    ActiveHighSparseHostBase = 0;
    ActiveHighSparseHostLimit = 0;
    ActiveLowShadowMapping = nullptr;
    ActiveHighSparseMapping = nullptr;
    Handling = false;
    sigaction(SIGSEGV, &PreviousSegvAction, nullptr);
    sigaction(SIGBUS, &PreviousBusAction, nullptr);
    Installed = false;
  }

  uint64_t Count() const {
    return static_cast<uint64_t>(HandledCount);
  }

  uint64_t BusCount() const {
    return static_cast<uint64_t>(SigbusCount);
  }

  uint64_t SegvCount() const {
    return static_cast<uint64_t>(SigsegvCount);
  }

  uint64_t SegvMissingAddressCount() const {
    return static_cast<uint64_t>(SigsegvMissingAddressCount);
  }

  bool BoundarySeen() const {
    return SignalBoundarySeen != 0;
  }

  uint64_t BoundarySignal() const {
    return static_cast<uint64_t>(SignalBoundarySignal);
  }

  int64_t BoundaryCode() const {
    return static_cast<int64_t>(SignalBoundaryCode);
  }

  uint64_t BoundaryInstruction() const {
    return SignalBoundaryInstruction;
  }

  uint64_t BoundaryProgramCounter() const {
    return SignalBoundaryProgramCounter;
  }

  std::array<uint32_t, BoundaryInstructionCount> BoundaryInstructionWords() const {
    return SignalBoundaryInstructionNeighborhood;
  }

  uint64_t BoundaryInstructionWordsValidMask() const {
    return SignalBoundaryInstructionNeighborhoodValidMask;
  }

  uint64_t BoundaryAddressRegister() const {
    return SignalBoundaryAddressRegister;
  }

  bool BoundaryAddressRegisterMatchesFault() const {
    return SignalBoundaryAddressRegisterMatchesFault != 0;
  }

  bool BoundaryIsJITGuardPage() const {
    return SignalBoundaryJITGuardPage != 0;
  }

  uint64_t BoundaryFaultAddress() const {
    return SignalBoundaryFaultAddress;
  }

  uint64_t BoundaryX4() const {
    return SignalBoundaryX4;
  }

  uint64_t BoundaryFSBase() const {
    return SignalBoundaryFSBase;
  }

  uint64_t BoundaryGSBase() const {
    return SignalBoundaryGSBase;
  }

  uint64_t BoundaryRSP() const {
    return SignalBoundaryRSP;
  }

  bool BoundaryX4MatchesFault() const {
    return SignalBoundaryX4MatchesFault != 0;
  }

  bool BoundaryIsThreadState() const {
    return SignalBoundaryThreadState != 0;
  }

  bool BoundaryIsInterruptPage() const {
    return SignalBoundaryInterruptPage != 0;
  }

  bool BoundaryIsCallRetStack() const {
    return SignalBoundaryCallRetStack != 0;
  }

  uint64_t BoundaryFaultOffset() const {
    return SignalBoundaryFaultOffset;
  }

  uint64_t BoundaryGuestRIPOffset() const {
    return SignalBoundaryGuestRIPOffset;
  }

  uint64_t BoundaryRecoveredGuestRIP() const {
    return SignalBoundaryRecoveredGuestRIP;
  }

  std::array<uint64_t, 29> BoundaryHostGPRs() const {
    return SignalBoundaryHostGPRs;
  }

  std::array<uint64_t, 16> BoundaryGuestGPRs() const {
    return SignalBoundaryGuestGPRs;
  }

  bool DiagnosticLimitSeen() const {
    return DiagnosticBackpatchLimitSeen != 0;
  }

  size_t PatternCount() const {
    return HandledPatternCount;
  }

  bool PatternOverflowSeen() const {
    return HandledPatternOverflow != 0;
  }

  std::array<uint64_t, MaximumPatternCount> PatternGuestRIPs() const {
    return HandledPatternGuestRIP;
  }

  std::array<uint64_t, MaximumPatternCount> PatternHostProgramCounters() const {
    return HandledPatternHostProgramCounter;
  }

  std::array<uint32_t, MaximumPatternCount> PatternInstructions() const {
    return HandledPatternInstruction;
  }

  std::array<uint64_t, MaximumPatternCount> PatternFirstFaultAddresses() const {
    return HandledPatternFirstFaultAddress;
  }

  std::array<uint64_t, MaximumPatternCount> PatternLastFaultAddresses() const {
    return HandledPatternLastFaultAddress;
  }

  std::array<int32_t, MaximumPatternCount> PatternSignals() const {
    return HandledPatternSignal;
  }

  std::array<int32_t, MaximumPatternCount> PatternCodes() const {
    return HandledPatternCode;
  }

  std::array<uint64_t, MaximumPatternCount> PatternHitCounts() const {
    return HandledPatternHitCount;
  }

  ~DarwinUnalignedAccessHandler() {
    Reset();
  }

private:
  static void RecordHandledPattern(
    FEXCore::Core::InternalThreadState* Thread,
    int Signal,
    int Code,
    uintptr_t ProgramCounter,
    uintptr_t FaultAddress) {
    const uint64_t GuestRIP = Thread->CTX->RestoreRIPFromHostPC(Thread, ProgramCounter);
    const uint32_t Instruction = *reinterpret_cast<const uint32_t*>(ProgramCounter);
    for (size_t Index = 0; Index < HandledPatternCount; ++Index) {
      if (HandledPatternGuestRIP[Index] != GuestRIP
          || HandledPatternInstruction[Index] != Instruction) {
        continue;
      }
      HandledPatternLastFaultAddress[Index] = FaultAddress;
      ++HandledPatternHitCount[Index];
      return;
    }
    if (HandledPatternCount >= MaximumPatternCount) {
      HandledPatternOverflow = 1;
      return;
    }
    const size_t Index = HandledPatternCount++;
    HandledPatternGuestRIP[Index] = GuestRIP;
    HandledPatternHostProgramCounter[Index] = ProgramCounter;
    HandledPatternInstruction[Index] = Instruction;
    HandledPatternFirstFaultAddress[Index] = FaultAddress;
    HandledPatternLastFaultAddress[Index] = FaultAddress;
    HandledPatternSignal[Index] = Signal;
    HandledPatternCode[Index] = Code;
    HandledPatternHitCount[Index] = 1;
  }

  static size_t AppendSignalTraceLiteral(
    char* Buffer,
    size_t Offset,
    size_t Capacity,
    std::string_view Literal) {
    for (const char Character : Literal) {
      if (Offset >= Capacity) {
        break;
      }
      Buffer[Offset++] = Character;
    }
    return Offset;
  }

  static size_t AppendSignalTraceHex(
    char* Buffer,
    size_t Offset,
    size_t Capacity,
    uintptr_t Value) {
    static constexpr std::string_view Digits {"0123456789abcdef"};
    Offset = AppendSignalTraceLiteral(Buffer, Offset, Capacity, "0x");
    bool Started = false;
    for (int Shift = static_cast<int>(sizeof(Value) * 8) - 4; Shift >= 0; Shift -= 4) {
      const auto Nibble = static_cast<size_t>((Value >> Shift) & 0xF);
      if (!Started && Nibble == 0 && Shift != 0) {
        continue;
      }
      Started = true;
      if (Offset >= Capacity) {
        break;
      }
      Buffer[Offset++] = Digits[Nibble];
    }
    return Offset;
  }

  static void WriteOutsideCodeBufferTrace(
    int Signal,
    int Code,
    uintptr_t ProgramCounter,
    uintptr_t FaultAddress,
    uintptr_t GuestRIP,
    uintptr_t HostLinkRegister,
    uintptr_t JITGuardPage,
    uintptr_t JITGuardLimit) {
    std::array<char, 768> Buffer {};
    size_t Offset = AppendSignalTraceLiteral(
      Buffer.data(), 0, Buffer.size(), "REGRESSION_SIGNAL_OUTSIDE_CODE_BUFFER signal=");
    Offset = AppendSignalTraceHex(
      Buffer.data(), Offset, Buffer.size(), static_cast<uintptr_t>(Signal));
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " code=");
    Offset = AppendSignalTraceHex(
      Buffer.data(), Offset, Buffer.size(), static_cast<uintptr_t>(Code));
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " pc=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ProgramCounter);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " fault=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), FaultAddress);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " guest_rip=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), GuestRIP);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " lr=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), HostLinkRegister);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " guest_base=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveGuestMemoryBase);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " guest_limit=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveGuestMemoryLimit);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " low_base=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveLowShadowHostBase);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " low_limit=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveLowShadowHostLimit);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " redirect_base=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveLowRedirectHostBase);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " redirect_limit=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveLowRedirectHostLimit);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " high_base=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveHighSparseHostBase);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " high_limit=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), ActiveHighSparseHostLimit);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " guard=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), JITGuardPage);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), " guard_limit=");
    Offset = AppendSignalTraceHex(Buffer.data(), Offset, Buffer.size(), JITGuardLimit);
    Offset = AppendSignalTraceLiteral(Buffer.data(), Offset, Buffer.size(), "\n");
    (void)::write(STDERR_FILENO, Buffer.data(), Offset);
  }

  static void Handle(int Signal, siginfo_t* Info, void* RawContext) {
    auto* Thread = ActiveThread;
    auto* Context = static_cast<ucontext_t*>(RawContext);
    const bool BusAlignment = Signal == SIGBUS && Info != nullptr && Info->si_code == BUS_ADRALN;
    const bool SegvAlignmentCandidate = Signal == SIGSEGV && Info != nullptr
      && (Info->si_code == SEGV_MAPERR || Info->si_code == SEGV_ACCERR);
    if (Handling) {
      _exit(204);
    }
    if ((!BusAlignment && !SegvAlignmentCandidate) || Thread == nullptr
        || Context == nullptr || Context->uc_mcontext == nullptr) {
      _exit(201);
    }

    auto& HostState = Context->uc_mcontext->__ss;
    const uintptr_t ProgramCounter = static_cast<uintptr_t>(HostState.__pc);
    const uintptr_t FaultAddress = reinterpret_cast<uintptr_t>(Info->si_addr);
    const uintptr_t JITGuardLimit = Thread->JITGuardPage + FEXCore::Utils::FEX_PAGE_SIZE;
    // Darwin may report an access to a PROT_NONE JIT guard page as SEGV_MAPERR.
    // The exact guard-page range check below keeps this recovery narrowly scoped.
    const bool JITGuardSignal = BusAlignment || SegvAlignmentCandidate;
    if (JITGuardSignal && FaultAddress >= Thread->JITGuardPage && FaultAddress < JITGuardLimit) {
      auto& HostVectorState = Context->uc_mcontext->__ns;
      std::array<uint64_t, 32> GPRs {};
      std::array<__uint128_t, 32> FPRs {};
      std::copy(std::begin(HostState.__x), std::end(HostState.__x), GPRs.begin());
      GPRs[29] = HostState.__fp;
      GPRs[30] = HostState.__lr;
      GPRs[31] = HostState.__sp;
      std::copy(std::begin(HostVectorState.__v), std::end(HostVectorState.__v), FPRs.begin());
      uint64_t RestartProgramCounter = HostState.__pc;

      FEXCore::UncheckedLongJump::ManuallyLoadJumpBuf(
        Thread->RestartJump,
        Thread->JITGuardOverflowArgument,
        GPRs.data(),
        FPRs.data(),
        &RestartProgramCounter);

      std::copy_n(GPRs.begin(), 29, std::begin(HostState.__x));
      HostState.__fp = GPRs[29];
      HostState.__lr = GPRs[30];
      HostState.__sp = GPRs[31];
      HostState.__pc = RestartProgramCounter;
      std::copy(FPRs.begin(), FPRs.end(), std::begin(HostVectorState.__v));
      return;
    }
    if (!Thread->CTX->IsAddressInCodeBuffer(Thread, ProgramCounter)) {
      const auto* Frame = Thread->CurrentFrame;
      WriteOutsideCodeBufferTrace(
        Signal,
        Info->si_code,
        ProgramCounter,
        FaultAddress,
        Frame != nullptr ? Frame->State.rip : 0,
        HostState.__lr,
        Thread->JITGuardPage,
        JITGuardLimit);
      _exit(202);
    }

    const bool FaultAddressMissing = FaultAddress == 0;
    const bool FaultAddressInGuest = FaultAddress >= ActiveGuestMemoryBase
      && FaultAddress < ActiveGuestMemoryLimit;
    // The Darwin host can back a logical guest range at a different address.
    // Extend the existing unaligned-access repair only for BUS_ADRALN inside
    // ranges owned by this isolated probe. Keep translated SEGVs on the guest
    // signal path so genuine protection and missing-page faults are preserved.
    const bool FaultAddressInMappedLowShadow = BusAlignment
      && ActiveLowShadowMapping != nullptr
      && ActiveLowShadowMapping->ContainsHostAddress(FaultAddress)
      && ActiveLowShadowMapping->ContainsMappedLogicalRange(
        ActiveLowShadowMapping->LogicalAddress(FaultAddress), 1);
    const bool FaultAddressInMappedHighSparse = BusAlignment
      && ActiveHighSparseMapping != nullptr
      && ActiveHighSparseMapping->ContainsHostAddress(FaultAddress)
      && ActiveHighSparseMapping->ContainsMappedLogicalRange(
        ActiveHighSparseMapping->LogicalAddress(FaultAddress), 1);
    const bool FaultAddressInTranslatedGuest = FaultAddressInMappedLowShadow
      || FaultAddressInMappedHighSparse;
    if (!FaultAddressMissing && !FaultAddressInGuest && !FaultAddressInTranslatedGuest) {
      RecordBoundary(Thread, Signal, Info->si_code, ProgramCounter, FaultAddress, HostState);
      return;
    }

    Handling = true;
    std::optional<int32_t> Result;
    {
      FEXCore::Allocator::JITWriteScope WriteScope;
      Result = FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess(
        Thread,
        FEXCore::ArchHelpers::Arm64::UnalignedHandlerType::HalfBarrier,
        ProgramCounter,
        HostState.__x);
    }
    if (!Result.has_value()) {
      Handling = false;
      RecordBoundary(Thread, Signal, Info->si_code, ProgramCounter, FaultAddress, HostState);
      return;
    }
    Handling = false;

    if (HandledCount >= MaximumDiagnosticBackpatchCount) {
      DiagnosticBackpatchLimitSeen = 1;
      RecordBoundary(Thread, Signal, Info->si_code, ProgramCounter, FaultAddress, HostState);
      return;
    }

    RecordHandledPattern(
      Thread,
      Signal,
      Info->si_code,
      ProgramCounter,
      FaultAddress);
    HostState.__pc = static_cast<uint64_t>(ProgramCounter + *Result);
    const sig_atomic_t PreviousCount = HandledCount;
    HandledCount = static_cast<sig_atomic_t>(PreviousCount + 1);
    if (Signal == SIGBUS) {
      const sig_atomic_t PreviousBusCount = SigbusCount;
      SigbusCount = static_cast<sig_atomic_t>(PreviousBusCount + 1);
    } else {
      const sig_atomic_t PreviousSegvCount = SigsegvCount;
      SigsegvCount = static_cast<sig_atomic_t>(PreviousSegvCount + 1);
      if (FaultAddress == 0) {
        const sig_atomic_t PreviousMissingAddressCount = SigsegvMissingAddressCount;
        SigsegvMissingAddressCount = static_cast<sig_atomic_t>(PreviousMissingAddressCount + 1);
      }
    }
  }

  static void RecordBoundary(
    FEXCore::Core::InternalThreadState* Thread,
    int Signal,
    int Code,
    uintptr_t ProgramCounter,
    uintptr_t FaultAddress,
    __darwin_arm_thread_state64& HostState) {
    auto* Frame = Thread->CurrentFrame;
    if (Frame == nullptr || Frame->Pointers.GuestSignal_SIGSEGV == 0) {
      _exit(205);
    }

    SignalBoundarySignal = static_cast<sig_atomic_t>(Signal);
    SignalBoundaryCode = static_cast<sig_atomic_t>(Code);
    SignalBoundaryProgramCounter = ProgramCounter;
    SignalBoundaryInstruction = *reinterpret_cast<const uint32_t*>(ProgramCounter);
    for (size_t Index = 0; Index < SignalBoundaryInstructionNeighborhood.size(); ++Index) {
      const int64_t RelativeInstruction = static_cast<int64_t>(Index)
        - static_cast<int64_t>(BoundaryInstructionRadius);
      if (RelativeInstruction < 0
          && ProgramCounter < static_cast<uintptr_t>(-RelativeInstruction) * sizeof(uint32_t)) {
        continue;
      }
      const uintptr_t CandidateProgramCounter = RelativeInstruction < 0
        ? ProgramCounter - static_cast<uintptr_t>(-RelativeInstruction) * sizeof(uint32_t)
        : ProgramCounter + static_cast<uintptr_t>(RelativeInstruction) * sizeof(uint32_t);
      if (!Thread->CTX->IsAddressInCodeBuffer(Thread, CandidateProgramCounter)) {
        continue;
      }
      SignalBoundaryInstructionNeighborhood[Index] =
        *reinterpret_cast<const uint32_t*>(CandidateProgramCounter);
      SignalBoundaryInstructionNeighborhoodValidMask |= 1ULL << Index;
    }
    SignalBoundaryAddressRegister = (SignalBoundaryInstruction >> 5) & 0x1F;
    const uint64_t AddressRegisterValue = SignalBoundaryAddressRegister == 31
      ? HostState.__sp
      : HostState.__x[SignalBoundaryAddressRegister];
    SignalBoundaryAddressRegisterMatchesFault = AddressRegisterValue == FaultAddress;
    SignalBoundaryFaultAddress = FaultAddress;
    SignalBoundaryX4 = HostState.__x[4];
    SignalBoundaryFSBase = Frame->State.fs_cached;
    SignalBoundaryGSBase = Frame->State.gs_cached;
    SignalBoundaryRSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
    SignalBoundaryX4MatchesFault = HostState.__x[4] == FaultAddress;
    const uintptr_t JITGuardLimit = Thread->JITGuardPage + FEXCore::Utils::FEX_PAGE_SIZE;
    SignalBoundaryJITGuardPage = Signal == SIGSEGV && Code == SEGV_ACCERR
      && FaultAddress >= Thread->JITGuardPage && FaultAddress < JITGuardLimit;
    const uintptr_t ThreadBase = reinterpret_cast<uintptr_t>(Thread);
    SignalBoundaryThreadState = FaultAddress >= ThreadBase
      && FaultAddress < ThreadBase + sizeof(*Thread);
    const uintptr_t InterruptPageBase = reinterpret_cast<uintptr_t>(&Thread->InterruptFaultPage);
    SignalBoundaryInterruptPage = FaultAddress >= InterruptPageBase
      && FaultAddress < InterruptPageBase + sizeof(Thread->InterruptFaultPage);
    const uintptr_t CallRetStackBase = reinterpret_cast<uintptr_t>(Thread->CallRetStackBase);
    SignalBoundaryCallRetStack = CallRetStackBase != 0
      && FaultAddress >= CallRetStackBase
      && FaultAddress < CallRetStackBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
    if (FaultAddress >= ActiveGuestMemoryBase && FaultAddress < ActiveGuestMemoryLimit) {
      SignalBoundaryFaultOffset = FaultAddress - ActiveGuestMemoryBase;
    }
    if (Frame->State.rip >= ActiveGuestMemoryBase && Frame->State.rip < ActiveGuestMemoryLimit) {
      SignalBoundaryGuestRIPOffset = Frame->State.rip - ActiveGuestMemoryBase;
    }
    SignalBoundaryRecoveredGuestRIP = Thread->CTX->RestoreRIPFromHostPC(Thread, ProgramCounter);
    for (size_t Index = 0; Index < SignalBoundaryHostGPRs.size(); ++Index) {
      SignalBoundaryHostGPRs[Index] = HostState.__x[Index];
    }
    for (size_t Index = 0; Index < SignalBoundaryGuestGPRs.size(); ++Index) {
      SignalBoundaryGuestGPRs[Index] = Frame->State.gregs[Index];
    }
    SignalBoundarySeen = 1;
    HostState.__pc = Frame->Pointers.GuestSignal_SIGSEGV;
  }

  inline static thread_local FEXCore::Core::InternalThreadState* ActiveThread {};
  inline static thread_local uintptr_t ActiveGuestMemoryBase {};
  inline static thread_local uintptr_t ActiveGuestMemoryLimit {};
  inline static thread_local uintptr_t ActiveLowShadowHostBase {};
  inline static thread_local uintptr_t ActiveLowShadowHostLimit {};
  inline static thread_local uintptr_t ActiveLowRedirectHostBase {};
  inline static thread_local uintptr_t ActiveLowRedirectHostLimit {};
  inline static thread_local uintptr_t ActiveHighSparseHostBase {};
  inline static thread_local uintptr_t ActiveHighSparseHostLimit {};
  inline static thread_local LowGuestShadowMapping* ActiveLowShadowMapping {};
  inline static thread_local HighGuestSparseMapping* ActiveHighSparseMapping {};
  inline static thread_local volatile sig_atomic_t HandledCount {};
  inline static thread_local volatile sig_atomic_t SigbusCount {};
  inline static thread_local volatile sig_atomic_t SigsegvCount {};
  inline static thread_local volatile sig_atomic_t SigsegvMissingAddressCount {};
  inline static thread_local size_t HandledPatternCount {};
  inline static thread_local volatile sig_atomic_t HandledPatternOverflow {};
  inline static thread_local std::array<uint64_t, MaximumPatternCount>
    HandledPatternGuestRIP {};
  inline static thread_local std::array<uint64_t, MaximumPatternCount>
    HandledPatternHostProgramCounter {};
  inline static thread_local std::array<uint32_t, MaximumPatternCount>
    HandledPatternInstruction {};
  inline static thread_local std::array<uint64_t, MaximumPatternCount>
    HandledPatternFirstFaultAddress {};
  inline static thread_local std::array<uint64_t, MaximumPatternCount>
    HandledPatternLastFaultAddress {};
  inline static thread_local std::array<int32_t, MaximumPatternCount>
    HandledPatternSignal {};
  inline static thread_local std::array<int32_t, MaximumPatternCount>
    HandledPatternCode {};
  inline static thread_local std::array<uint64_t, MaximumPatternCount>
    HandledPatternHitCount {};
  inline static thread_local volatile sig_atomic_t SignalBoundarySeen {};
  inline static thread_local volatile sig_atomic_t SignalBoundarySignal {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryCode {};
  inline static thread_local uint64_t SignalBoundaryProgramCounter {};
  inline static thread_local uint64_t SignalBoundaryInstruction {};
  inline static thread_local std::array<uint32_t, BoundaryInstructionCount>
    SignalBoundaryInstructionNeighborhood {};
  inline static thread_local uint64_t SignalBoundaryInstructionNeighborhoodValidMask {};
  inline static thread_local uint64_t SignalBoundaryAddressRegister {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryAddressRegisterMatchesFault {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryJITGuardPage {};
  inline static thread_local uint64_t SignalBoundaryFaultAddress {};
  inline static thread_local uint64_t SignalBoundaryX4 {};
  inline static thread_local uint64_t SignalBoundaryFSBase {};
  inline static thread_local uint64_t SignalBoundaryGSBase {};
  inline static thread_local uint64_t SignalBoundaryRSP {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryX4MatchesFault {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryThreadState {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryInterruptPage {};
  inline static thread_local volatile sig_atomic_t SignalBoundaryCallRetStack {};
  inline static thread_local uint64_t SignalBoundaryFaultOffset {std::numeric_limits<uint64_t>::max()};
  inline static thread_local uint64_t SignalBoundaryGuestRIPOffset {std::numeric_limits<uint64_t>::max()};
  inline static thread_local uint64_t SignalBoundaryRecoveredGuestRIP {};
  inline static thread_local std::array<uint64_t, 29> SignalBoundaryHostGPRs {};
  inline static thread_local std::array<uint64_t, 16> SignalBoundaryGuestGPRs {};
  inline static thread_local volatile sig_atomic_t DiagnosticBackpatchLimitSeen {};
  inline static thread_local volatile sig_atomic_t Handling {};
  struct sigaction PreviousBusAction {};
  struct sigaction PreviousSegvAction {};
  bool Installed {};
};

class ProcessSyscallHandler final : public FEXCore::HLE::SyscallHandler {
public:
  ProcessSyscallHandler(
    uint64_t GuestBase,
    uint64_t GuestSize,
    uint64_t StopAddress = 0,
    uint64_t InitialProgramBreak = 0,
    uint64_t ProgramBreakLimit = 0,
    uint64_t MMapArenaBase = 0,
    uint64_t MMapArenaLimit = 0,
    std::string RootFS = {},
    std::string GuestProgram = {},
    bool InstrumentLowPageAlias = false,
    uint64_t LowPageAliasBackingAddress = 0,
    uint64_t LowPageAliasBackingSize = 0,
    bool InstrumentLowMemoryBias = false,
    LowGuestShadowMapping* LowGuestShadow = nullptr,
    bool InstrumentHighMemoryRegion = false,
    HighGuestSparseMapping* HighGuestSparse = nullptr,
    bool InstrumentVForkChild = false,
    bool InstrumentVForkParent = false,
    bool InstrumentVForkParentProcessBridge = false,
    bool InstrumentVForkParentWineServerBridge = false,
    std::string HostExecutablePath = {},
    std::string WineServerBridgeDirectory = {},
    std::string CXAltLoaderGuestSocketPath = {},
    std::string CXAltLoaderHostSocketPath = {},
    uint64_t DiagnosticPostSessionSyscallLimit = 0)
    : GuestBase {GuestBase}
    , GuestSize {GuestSize}
    , StopAddress {StopAddress}
    , InitialProgramBreak {InitialProgramBreak}
    , CurrentProgramBreak {InitialProgramBreak}
    , ProgramBreakLimit {ProgramBreakLimit}
    , MMapArenaBase {MMapArenaBase}
    , NextMMapAddress {MMapArenaBase}
    , MMapArenaLimit {MMapArenaLimit}
    , RootFS {std::move(RootFS)}
    , GuestProgram {std::move(GuestProgram)}
    , HostExecutablePath {std::move(HostExecutablePath)}
    , WineServerBridgeDirectory {std::move(WineServerBridgeDirectory)}
    , CXAltLoaderGuestSocketPath {std::move(CXAltLoaderGuestSocketPath)}
    , CXAltLoaderHostSocketPath {std::move(CXAltLoaderHostSocketPath)}
    , LowPageAliasBackingAddress {LowPageAliasBackingAddress}
    , LowPageAliasBackingSize {LowPageAliasBackingSize}
    , LowGuestShadow {LowGuestShadow}
    , HighGuestSparse {HighGuestSparse} {
    OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64;
    LowPageAliasModeEnabled = InstrumentLowPageAlias;
    LowMemoryBiasModeEnabled = InstrumentLowMemoryBias;
    HighMemoryRegionModeEnabled = InstrumentHighMemoryRegion;
    VForkChildInstrumentationEnabled = InstrumentVForkChild;
    VForkParentInstrumentationEnabled = InstrumentVForkParent;
    VForkParentProcessBridgeEnabled = InstrumentVForkParentProcessBridge;
    VForkParentWineServerBridgeEnabled = InstrumentVForkParentWineServerBridge;
    PostSessionSyscallDiagnosticLimit = DiagnosticPostSessionSyscallLimit;
    if (!this->RootFS.empty()) {
      std::array<char, 4096> Canonical {};
      if (realpath(this->RootFS.c_str(), Canonical.data()) != nullptr) {
        this->RootFS = Canonical.data();
      }
    }
  }

  ~ProcessSyscallHandler() override {
    FinalizeVirtualVForkWineServerBridge();
    CleanupVirtualVForkBridgeChild();
    for (const int Descriptor : OwnedDescriptors) {
      close(Descriptor);
    }
  }

  void FinalizeOwnedVirtualVForkProcesses() {
    if (!VForkParentWineServerBridgeEnabled || VirtualVForkWineServerFinalized) {
      return;
    }
    for (const int Descriptor : OwnedDescriptors) {
      close(Descriptor);
    }
    OwnedDescriptors.clear();
    FinalizeVirtualVForkWineServerBridge();
  }

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame* Frame, FEXCore::HLE::SyscallArguments* Arguments) override {
    const uint64_t Number = Arguments->Argument[0];
    ++HandleSyscallCallCount;
    RecordPostRegistryTemporarySyscall(Arguments, Number);
    if (MaybeStopAtPostSessionSyscallBoundary(Frame, Arguments, Number)) {
      return static_cast<uint64_t>(-EINTR);
    }
    if (Number == ReadSyscall && !RootFS.empty()) {
      ReadSeen = true;
      ++ReadCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Buffer = Arguments->Argument[2];
      const uint64_t Count = Arguments->Argument[3];
      ReadLastDescriptor = Descriptor;
      ReadLastBuffer = Buffer;
      ReadLastCount = Count;
      ReadLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      ReadLastDescriptorReceivedSCMRights =
        ReceivedSCMRightsDescriptors.contains(Descriptor);
      void* GuestDestination = Count != 0
        ? HostPointerForGuestRange(Buffer, Count, PROT_WRITE)
        : nullptr;
      ReadLastBufferClass = Count == 0
        ? "empty"
        : (Contains(Buffer, Count)
            ? "guest-memory"
            : (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
                && LowGuestShadow->ContainsMappedLogicalRange(
                  Buffer,
                  Count,
                  PROT_WRITE)
              ? "low-shadow"
              : (GuestDestination != nullptr
                  ? "high-sparse"
                  : "scalar-or-outside")));
      struct stat DescriptorStat {};
      ReadLastDescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
      ReadLastDescriptorFIFO = ReadLastDescriptorStatSucceeded
        && S_ISFIFO(DescriptorStat.st_mode);
      ReadLastDescriptorSocket = ReadLastDescriptorStatSucceeded
        && S_ISSOCK(DescriptorStat.st_mode);
      ReadLastDescriptorRegular = ReadLastDescriptorStatSucceeded
        && S_ISREG(DescriptorStat.st_mode);
      if (const char* TraceReads = getenv("REGRESSION_FLI_TRACE_READS");
          TraceReads != nullptr && std::string_view {TraceReads} == "1") {
        std::cerr << "TRACE read call=" << ReadCallCount
                  << " fd=" << Descriptor
                  << " count=" << Count
                  << " buffer-class=" << ReadLastBufferClass
                  << " owned=" << (ReadLastDescriptorOwned ? 1 : 0)
                  << " scm-rights=" << (ReadLastDescriptorReceivedSCMRights ? 1 : 0)
                  << " fifo=" << (ReadLastDescriptorFIFO ? 1 : 0)
                  << " socket=" << (ReadLastDescriptorSocket ? 1 : 0)
                  << " regular=" << (ReadLastDescriptorRegular ? 1 : 0)
                  << '\n';
        std::cerr.flush();
      }
      if (!OwnedDescriptors.contains(Descriptor)) {
        return static_cast<uint64_t>(-EBADF);
      }
      if ((Count != 0 && GuestDestination == nullptr)
          || Count > static_cast<uint64_t>(std::numeric_limits<ssize_t>::max())) {
        return static_cast<uint64_t>(-EFAULT);
      }
      const ssize_t Result = read(Descriptor, GuestDestination, static_cast<size_t>(Count));
      if (Result == -1) {
        return static_cast<uint64_t>(-errno);
      }
      ReadByteCount += static_cast<uint64_t>(Result);
      constexpr uint64_t PreloaderELFHeaderReadSize = 2048;
      constexpr size_t ELFHeaderDiagnosticSize = 64;
      const bool ExactPreloaderELFHeaderRead = GuestProgram
          == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
        && ReadLastDescriptorOwned
        && ReadLastDescriptorRegular
        && Count == PreloaderELFHeaderReadSize
        && Result >= static_cast<ssize_t>(ELFHeaderDiagnosticSize);
      if (ExactPreloaderELFHeaderRead) {
        if (ReadELFHeaderRecordCount < ReadELFHeaderRecords.size()) {
          const auto* Bytes = static_cast<const uint8_t*>(GuestDestination);
          const auto ReadUInt16 = [Bytes](size_t Offset) {
            uint16_t Value {};
            std::memcpy(&Value, Bytes + Offset, sizeof(Value));
            return Value;
          };
          const auto ReadUInt32 = [Bytes](size_t Offset) {
            uint32_t Value {};
            std::memcpy(&Value, Bytes + Offset, sizeof(Value));
            return Value;
          };
          const auto ReadUInt64 = [Bytes](size_t Offset) {
            uint64_t Value {};
            std::memcpy(&Value, Bytes + Offset, sizeof(Value));
            return Value;
          };
          const auto [DescriptorPathClass, DescriptorGuestPath] =
            DescribeMappingDescriptor(Descriptor, false);
          ReadELFHeaderRecords[ReadELFHeaderRecordCount++] = ReadELFHeaderRecord {
            .SyscallOrdinal = ReadCallCount,
            .Descriptor = Descriptor,
            .GuestBuffer = Buffer,
            .RequestedByteCount = Count,
            .ReturnedByteCount = static_cast<uint64_t>(Result),
            .First64ByteFingerprint = FingerprintBytes(Bytes, ELFHeaderDiagnosticSize),
            .Magic = ReadUInt32(0),
            .ELFClass = Bytes[4],
            .DataEncoding = Bytes[5],
            .Type = ReadUInt16(16),
            .Machine = ReadUInt16(18),
            .Version = ReadUInt32(20),
            .Entry = ReadUInt64(24),
            .ProgramHeaderOffset = ReadUInt64(32),
            .ProgramHeaderEntrySize = ReadUInt16(54),
            .ProgramHeaderCount = ReadUInt16(56),
            .DescriptorPathClass = DescriptorPathClass,
            .DescriptorGuestPath = DescriptorGuestPath,
          };
        } else {
          ReadELFHeaderRecordOverflow = true;
        }
      }
      constexpr uint64_t WineFixedReplySize = 64;
      constexpr uint64_t WineReplyHeaderSize = 8;
      const bool ExactWineFixedReply = GuestProgram
          == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
        && ReadLastDescriptorOwned
        && ReadLastDescriptorFIFO
        && Count == WineFixedReplySize
        && Result == static_cast<ssize_t>(WineFixedReplySize);
      if (ExactWineFixedReply) {
        const auto* ReplyBytes = static_cast<const uint8_t*>(GuestDestination);
        std::memcpy(
          &ReadWineFixedReplyLastError,
          ReplyBytes,
          sizeof(ReadWineFixedReplyLastError));
        std::memcpy(
          &ReadWineFixedReplyLastDeclaredSize,
          ReplyBytes + sizeof(ReadWineFixedReplyLastError),
          sizeof(ReadWineFixedReplyLastDeclaredSize));
        ReadWineFixedReplySeen = true;
        ++ReadWineFixedReplyCount;
        ReadWineFixedReplyLastDescriptor = Descriptor;
        ReadWineFixedReplyLastReturnedByteCount = static_cast<uint64_t>(Result);
        TraceWineReplyHeader(
          "read",
          Descriptor,
          GuestDestination,
          static_cast<size_t>(WineReplyHeaderSize));
      }
      return static_cast<uint64_t>(Result);
    }
    if (Number == PRead64Syscall && !RootFS.empty()) {
      PRead64Seen = true;
      ++PRead64CallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Buffer = Arguments->Argument[2];
      const uint64_t Count = Arguments->Argument[3];
      const uint64_t Offset = Arguments->Argument[4];
      if (!OwnedDescriptors.contains(Descriptor)) {
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(Buffer, Count) || Count > static_cast<uint64_t>(std::numeric_limits<ssize_t>::max())
          || Offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
        return static_cast<uint64_t>(-EFAULT);
      }
      const ssize_t Result = pread(
        Descriptor,
        reinterpret_cast<void*>(Buffer),
        static_cast<size_t>(Count),
        static_cast<off_t>(Offset));
      if (Result == -1) {
        return static_cast<uint64_t>(-errno);
      }
      PRead64ByteCount += static_cast<uint64_t>(Result);
      return static_cast<uint64_t>(Result);
    }
    if (Number == FStatSyscall && !RootFS.empty()) {
      FStatSeen = true;
      ++FStatCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      const bool IsStandardDescriptor = Descriptor >= STDIN_FILENO && Descriptor <= STDERR_FILENO;
      if ((!OwnedDescriptors.contains(Descriptor) && !IsStandardDescriptor)
          || ClosedStandardDescriptors.contains(Descriptor)) {
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(GuestBuffer, sizeof(LinuxX86_64Stat))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      struct stat HostStat {};
      if (fstat(Descriptor, &HostStat) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      const LinuxX86_64Stat GuestStat = TranslateStat(HostStat);
      std::memcpy(reinterpret_cast<void*>(GuestBuffer), &GuestStat, sizeof(GuestStat));
      ++FStatSuccessCount;
      return 0;
    }
    if (Number == GetDents64Syscall && !RootFS.empty()) {
      constexpr uint64_t MaximumGuestDirectoryBufferSize = 1024 * 1024;
      constexpr uint64_t DarwinDirectoryBlockSize = 4096;
      GetDents64Seen = true;
      ++GetDents64CallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      const uint64_t ByteCount = Arguments->Argument[3];
      GetDents64LastDescriptor = Descriptor;
      GetDents64LastGuestBuffer = GuestBuffer;
      GetDents64LastByteCount = ByteCount;
      GetDents64LastHostError = 0;
      GetDents64LastLinuxError = 0;
      GetDents64LastFailureReason = "none";
      GetDents64LastReturnedByteCount = 0;
      GetDents64LastConvertedEntryCount = 0;
      GetDents64LastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      GetDents64LastDescriptorDirectory = false;
      GetDents64LastDescriptorPathConfined = false;
      GetDents64LastPosition = -1;
      GetDents64LastNextOffset = -1;
      GetDents64LastBufferClass = GuestBuffer == 0
        ? "zero"
        : (ByteCount == 0
            ? "empty-span"
            : (Contains(GuestBuffer, ByteCount)
                ? "guest-memory"
                : (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
                    && LowGuestShadow->HostPointerForMappedLogicalRange(
                      GuestBuffer, ByteCount, PROT_WRITE) != nullptr
                    ? "low-shadow"
                    : (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
                        && HighGuestSparse->HostPointerForMappedLogicalRange(
                          GuestBuffer, ByteCount, PROT_WRITE) != nullptr
                        ? "high-sparse"
                        : "scalar-or-unmapped"))));

      if (!GetDents64LastDescriptorOwned) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = EBADF;
        GetDents64LastFailureReason = "descriptor-not-owned";
        return static_cast<uint64_t>(-EBADF);
      }

      struct stat DescriptorStat {};
      if (fstat(Descriptor, &DescriptorStat) != 0) {
        const int HostError = errno;
        ++GetDents64FailureCount;
        GetDents64LastHostError = HostError;
        GetDents64LastLinuxError = HostError;
        GetDents64LastFailureReason = "descriptor-stat-failed";
        return static_cast<uint64_t>(-HostError);
      }
      GetDents64LastDescriptorDirectory = S_ISDIR(DescriptorStat.st_mode);
      if (!GetDents64LastDescriptorDirectory) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = ENOTDIR;
        GetDents64LastFailureReason = "descriptor-not-directory";
        return static_cast<uint64_t>(-ENOTDIR);
      }

      std::array<char, 4096> DescriptorPath {};
      if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) != 0) {
        const int HostError = errno;
        ++GetDents64FailureCount;
        GetDents64LastHostError = HostError;
        GetDents64LastLinuxError = EBADF;
        GetDents64LastFailureReason = "descriptor-path-unresolved";
        return static_cast<uint64_t>(-EBADF);
      }
      const std::string HostPath {DescriptorPath.data()};
      GetDents64LastDescriptorPathConfined = HostPath == RootFS
        || HostPath.starts_with(RootFS + '/');
      if (!GetDents64LastDescriptorPathConfined) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = EACCES;
        GetDents64LastFailureReason = "descriptor-outside-rootfs";
        return static_cast<uint64_t>(-EACCES);
      }

      if (ByteCount < 2 * DarwinDirectoryBlockSize
          || ByteCount > MaximumGuestDirectoryBufferSize
          || ByteCount > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = EINVAL;
        GetDents64LastFailureReason = "unsupported-buffer-size";
        return static_cast<uint64_t>(-EINVAL);
      }
      void* GuestDestination = HostPointerForGuestRange(
        GuestBuffer, ByteCount, PROT_WRITE);
      if (GuestDestination == nullptr) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = EFAULT;
        GetDents64LastFailureReason = "guest-buffer-unmapped";
        return static_cast<uint64_t>(-EFAULT);
      }

      // A Linux dirent64 may be four bytes larger than the equivalent Darwin
      // record because Linux aligns to eight bytes and Darwin to four. Since a
      // Darwin record is at least 24 bytes, reading at most 6/7 of the guest
      // capacity guarantees that every converted record still fits.
      const uint64_t SafeHostCapacity = ((ByteCount / 7) * 6)
        & ~(DarwinDirectoryBlockSize - 1);
      if (SafeHostCapacity < DarwinDirectoryBlockSize) {
        ++GetDents64FailureCount;
        GetDents64LastLinuxError = EINVAL;
        GetDents64LastFailureReason = "darwin-buffer-too-small";
        return static_cast<uint64_t>(-EINVAL);
      }
      std::vector<char> HostRecords(static_cast<size_t>(SafeHostCapacity));
      off_t Position {};
      errno = 0;
      const ssize_t HostResult = __getdirentries64(
        Descriptor,
        HostRecords.data(),
        HostRecords.size(),
        &Position);
      const int HostDirectoryError = HostResult == -1 ? errno : 0;
      if (HostResult == -1) {
        ++GetDents64FailureCount;
        GetDents64LastHostError = HostDirectoryError;
        GetDents64LastLinuxError = HostDirectoryError;
        GetDents64LastFailureReason = "darwin-getdirentries64-failed";
        return static_cast<uint64_t>(-HostDirectoryError);
      }
      GetDents64LastPosition = static_cast<int64_t>(Position);
      errno = 0;
      const off_t NextOffset = lseek(Descriptor, 0, SEEK_CUR);
      const int NextOffsetError = NextOffset == static_cast<off_t>(-1) ? errno : 0;
      if (NextOffset == static_cast<off_t>(-1)) {
        ++GetDents64FailureCount;
        GetDents64LastHostError = NextOffsetError;
        GetDents64LastLinuxError = EIO;
        GetDents64LastFailureReason = "next-directory-cookie-unavailable";
        if (lseek(Descriptor, Position, SEEK_SET) != static_cast<off_t>(-1)) {
          ++GetDents64RollbackSuccessCount;
        } else {
          ++GetDents64RollbackFailureCount;
        }
        return static_cast<uint64_t>(-EIO);
      }
      GetDents64LastNextOffset = static_cast<int64_t>(NextOffset);
      GetDents64HostByteCount += static_cast<uint64_t>(HostResult);
      if (HostResult == 0) {
        ++GetDents64SuccessCount;
        ++GetDents64EOFCount;
        return 0;
      }

      const auto RollBackDirectory = [&]() {
        if (lseek(Descriptor, Position, SEEK_SET) != static_cast<off_t>(-1)) {
          ++GetDents64RollbackSuccessCount;
        } else {
          ++GetDents64RollbackFailureCount;
        }
      };
      constexpr size_t DarwinNameOffset = offsetof(struct dirent, d_name);
      constexpr size_t MaximumDarwinNameLength =
        sizeof(std::declval<struct dirent>().d_name) - 1;
      std::vector<uint8_t> LinuxRecords(static_cast<size_t>(ByteCount), 0);
      size_t HostOffset {};
      size_t LinuxOffset {};
      uint64_t ConvertedEntryCount {};
      uint64_t SkippedZeroInodeCount {};
      while (HostOffset < static_cast<size_t>(HostResult)) {
        const size_t RemainingHostBytes = static_cast<size_t>(HostResult) - HostOffset;
        if (RemainingHostBytes < DarwinNameOffset + 1) {
          ++GetDents64FailureCount;
          GetDents64LastLinuxError = EIO;
          GetDents64LastFailureReason = "truncated-darwin-record-header";
          RollBackDirectory();
          return static_cast<uint64_t>(-EIO);
        }

        const uint8_t* HostRecord = reinterpret_cast<const uint8_t*>(
          HostRecords.data() + HostOffset);
        uint64_t Inode {};
        uint16_t RecordLength {};
        uint16_t NameLength {};
        uint8_t Type {};
        std::memcpy(&Inode, HostRecord + offsetof(struct dirent, d_ino), sizeof(Inode));
        std::memcpy(
          &RecordLength,
          HostRecord + offsetof(struct dirent, d_reclen),
          sizeof(RecordLength));
        std::memcpy(
          &NameLength,
          HostRecord + offsetof(struct dirent, d_namlen),
          sizeof(NameLength));
        std::memcpy(&Type, HostRecord + offsetof(struct dirent, d_type), sizeof(Type));
        const bool RecordShapeValid = RecordLength >= DarwinNameOffset + 1
          && RecordLength <= RemainingHostBytes
          && NameLength <= MaximumDarwinNameLength
          && DarwinNameOffset + static_cast<size_t>(NameLength) + 1 <= RecordLength
          && HostRecord[DarwinNameOffset + NameLength] == '\0';
        if (!RecordShapeValid) {
          ++GetDents64FailureCount;
          GetDents64LastLinuxError = EIO;
          GetDents64LastFailureReason = "invalid-darwin-record";
          RollBackDirectory();
          return static_cast<uint64_t>(-EIO);
        }

        if (Inode == 0) {
          ++SkippedZeroInodeCount;
          HostOffset += RecordLength;
          continue;
        }
        const size_t UnalignedLinuxLength = sizeof(LinuxDirent64Header)
          + static_cast<size_t>(NameLength) + 1;
        const size_t LinuxLength = (UnalignedLinuxLength + 7) & ~size_t {7};
        if (LinuxLength > std::numeric_limits<uint16_t>::max()
            || LinuxOffset > LinuxRecords.size()
            || LinuxLength > LinuxRecords.size() - LinuxOffset) {
          ++GetDents64FailureCount;
          GetDents64LastLinuxError = EIO;
          GetDents64LastFailureReason = "linux-record-capacity-exceeded";
          RollBackDirectory();
          return static_cast<uint64_t>(-EIO);
        }
        const LinuxDirent64Header LinuxHeader {
          .Inode = Inode,
          .Offset = static_cast<int64_t>(NextOffset),
          .RecordLength = static_cast<uint16_t>(LinuxLength),
          .Type = Type,
        };
        std::memcpy(
          LinuxRecords.data() + LinuxOffset,
          &LinuxHeader,
          sizeof(LinuxHeader));
        std::memcpy(
          LinuxRecords.data() + LinuxOffset + sizeof(LinuxHeader),
          HostRecord + DarwinNameOffset,
          static_cast<size_t>(NameLength) + 1);
        LinuxOffset += LinuxLength;
        ++ConvertedEntryCount;
        HostOffset += RecordLength;
      }

      std::memcpy(GuestDestination, LinuxRecords.data(), LinuxOffset);
      ++GetDents64SuccessCount;
      GetDents64LinuxByteCount += LinuxOffset;
      GetDents64EntryCount += ConvertedEntryCount;
      GetDents64SkippedZeroInodeCount += SkippedZeroInodeCount;
      GetDents64LastReturnedByteCount = LinuxOffset;
      GetDents64LastConvertedEntryCount = ConvertedEntryCount;
      return static_cast<uint64_t>(LinuxOffset);
    }
    if (Number == FcntlSyscall && !RootFS.empty()) {
      FcntlSeen = true;
      ++FcntlCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const int64_t Command = static_cast<int64_t>(Arguments->Argument[2]);
      const uint64_t Argument = Arguments->Argument[3];
      FcntlLastDescriptor = Descriptor;
      FcntlLastCommand = Command;
      FcntlLastArgument = Argument;
      FcntlLastArgumentClass = Argument == 0
        ? "zero"
        : (Contains(Argument, 1) ? "guest-memory" : "scalar-or-outside");
      FcntlLastLinuxError = 0;
      FcntlLastFailureReason = "none";
      const bool DescriptorOwned = OwnedDescriptors.contains(Descriptor);
      const bool DescriptorStandard = Descriptor >= STDIN_FILENO && Descriptor <= STDERR_FILENO;
      const bool DescriptorClosed = DescriptorStandard
        && ClosedStandardDescriptors.contains(Descriptor);
      const bool GetStatusFlagsCandidate = Command == LinuxFGetFLCommand
        && DescriptorOwned;
      int GetStatusHostFlags = -1;
      int GetStatusHostError = 0;
      if (GetStatusFlagsCandidate) {
        ++FcntlGetFlagsCandidateCount;
        FcntlGetFlagsLastDescriptorMatchesRegistryTemporary =
          RegistryTemporaryDescriptors.contains(Descriptor);
        if (FcntlGetFlagsLastDescriptorMatchesRegistryTemporary) {
          ++FcntlGetFlagsRegistryTemporaryCandidateCount;
        }
        const int SavedHostError = errno;
        GetStatusHostFlags = fcntl(Descriptor, F_GETFL);
        GetStatusHostError = GetStatusHostFlags == -1 ? errno : 0;
        errno = SavedHostError;
        FcntlGetFlagsLastHostFlags = GetStatusHostFlags;
        FcntlGetFlagsLastHostError = GetStatusHostError;
      }
      if (FcntlTraceCount < FcntlTrace.size()) {
        auto& Trace = FcntlTrace[FcntlTraceCount++];
        Trace.Descriptor = Descriptor;
        Trace.Command = Command;
        Trace.Argument = Argument;
        Trace.DescriptorOwned = DescriptorOwned;
        Trace.DescriptorStandard = DescriptorStandard;
        Trace.DescriptorClosed = DescriptorClosed;
      }
      const bool GetRegistryTemporaryStatusFlagsExactCandidate =
        GetStatusFlagsCandidate
        && RegistryTemporaryDescriptors.contains(Descriptor);
      if (GetRegistryTemporaryStatusFlagsExactCandidate) {
        struct stat HostStat {};
        const int SavedHostError = errno;
        const int StatResult = fstat(Descriptor, &HostStat);
        const int StatHostError = StatResult == -1 ? errno : 0;
        errno = SavedHostError;
        FcntlGetFlagsRegistryTemporaryLastDescriptorRegular =
          StatResult == 0 && S_ISREG(HostStat.st_mode);
        if (StatResult == -1) {
          const int LinuxError = TranslateHostFcntlGetFlagsErrorToLinux(StatHostError);
          ++FcntlGetFlagsRegistryTemporaryFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "registry-temporary-fstat-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        if (!FcntlGetFlagsRegistryTemporaryLastDescriptorRegular) {
          ++FcntlGetFlagsRegistryTemporaryFailureCount;
          FcntlLastLinuxError = EINVAL;
          FcntlLastFailureReason = "registry-temporary-not-regular";
          return static_cast<uint64_t>(-EINVAL);
        }
        if (GetStatusHostFlags == -1) {
          const int LinuxError = TranslateHostFcntlGetFlagsErrorToLinux(GetStatusHostError);
          ++FcntlGetFlagsRegistryTemporaryFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "registry-temporary-host-get-status-flags-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        if (GetStatusHostFlags != O_WRONLY) {
          ++FcntlGetFlagsRegistryTemporaryFailureCount;
          FcntlLastLinuxError = ENOTSUP;
          FcntlLastFailureReason = "registry-temporary-unmeasured-host-flags";
          return static_cast<uint64_t>(-ENOTSUP);
        }
        ++FcntlGetFlagsRegistryTemporarySuccessCount;
        FcntlGetFlagsRegistryTemporaryLastLinuxFlags = LinuxOWriteOnlyAccessMode;
        FcntlLastFailureReason = "none";
        return LinuxOWriteOnlyAccessMode;
      }
      if (GetStatusFlagsCandidate) {
        if (GetStatusHostFlags == -1) {
          const int LinuxError = TranslateHostFcntlGetFlagsErrorToLinux(GetStatusHostError);
          ++FcntlGetFlagsGenericFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "host-get-status-flags-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        constexpr int KnownHostStatusFlags = O_ACCMODE | O_APPEND | O_NONBLOCK;
        if ((GetStatusHostFlags & ~KnownHostStatusFlags) != 0) {
          ++FcntlGetFlagsGenericFailureCount;
          FcntlLastLinuxError = ENOTSUP;
          FcntlLastFailureReason = "untranslated-host-status-flags";
          return static_cast<uint64_t>(-ENOTSUP);
        }

        uint64_t LinuxFlags {};
        switch (GetStatusHostFlags & O_ACCMODE) {
        case O_RDONLY: break;
        case O_WRONLY: LinuxFlags |= LinuxOWriteOnlyAccessMode; break;
        case O_RDWR: LinuxFlags |= LinuxOReadWriteAccessMode; break;
        default:
          ++FcntlGetFlagsGenericFailureCount;
          FcntlLastLinuxError = EINVAL;
          FcntlLastFailureReason = "unsupported-host-access-mode";
          return static_cast<uint64_t>(-EINVAL);
        }
        if ((GetStatusHostFlags & O_APPEND) != 0) {
          LinuxFlags |= LinuxOAppend;
        }
        if ((GetStatusHostFlags & O_NONBLOCK) != 0) {
          LinuxFlags |= LinuxONonBlock;
        }
        ++FcntlGetFlagsGenericSuccessCount;
        FcntlGetFlagsGenericLastLinuxFlags = LinuxFlags;
        FcntlLastFailureReason = "none";
        return LinuxFlags;
      }
      const bool SetDescriptorFlagsExactCandidate = Command == LinuxFSetFDCommand
        && Descriptor != -1
        && DescriptorOwned
        && Argument == 1;
      if (Command == LinuxFSetFDCommand && Descriptor != -1) {
        ++FcntlSetDescriptorFlagsCallCount;
        if (SetDescriptorFlagsExactCandidate) {
          ++FcntlSetDescriptorFlagsExactCandidateCount;
        } else {
          ++FcntlSetDescriptorFlagsOtherShapeCount;
        }
      }

      // Esta es la única forma medida hasta ahora. Wine intenta marcar con
      // close-on-exec el resultado -1 de un openat relativo aún no soportado.
      // Linux responde EBADF sin inspeccionar el tercer argumento.
      if (Descriptor == -1 && Command == LinuxFSetFDCommand) {
        ++FcntlInvalidDescriptorCount;
        FcntlLastLinuxError = EBADF;
        FcntlLastFailureReason = "observed-invalid-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }

      if (SetDescriptorFlagsExactCandidate) {
        const int HostFlagsBefore = fcntl(Descriptor, F_GETFD);
        FcntlSetDescriptorFlagsLastHostFlagsBefore = HostFlagsBefore;
        if (HostFlagsBefore == -1) {
          const int LinuxError = TranslateHostSocketErrorToLinux(errno);
          ++FcntlSetDescriptorFlagsFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "host-get-descriptor-flags-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        if (fcntl(Descriptor, F_SETFD, HostFlagsBefore | FD_CLOEXEC) == -1) {
          const int LinuxError = TranslateHostSocketErrorToLinux(errno);
          ++FcntlSetDescriptorFlagsFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "host-set-descriptor-flags-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        const int HostFlagsAfter = fcntl(Descriptor, F_GETFD);
        FcntlSetDescriptorFlagsLastHostFlagsAfter = HostFlagsAfter;
        if (HostFlagsAfter == -1) {
          const int LinuxError = TranslateHostSocketErrorToLinux(errno);
          ++FcntlSetDescriptorFlagsFailureCount;
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "host-verify-descriptor-flags-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        if ((HostFlagsAfter & FD_CLOEXEC) == 0) {
          ++FcntlSetDescriptorFlagsFailureCount;
          FcntlLastLinuxError = EIO;
          FcntlLastFailureReason = "host-close-on-exec-not-set";
          return static_cast<uint64_t>(-EIO);
        }
        ++FcntlSetDescriptorFlagsSuccessCount;
        FcntlLastFailureReason = "none";
        return 0;
      }

      if (Command == LinuxFSetFLCommand) {
        ++FcntlSetFlagsCallCount;
        if (OwnedDescriptors.contains(Descriptor) && Argument == LinuxONonBlock) {
          const int HostFlagsBefore = fcntl(Descriptor, F_GETFL);
          FcntlSetFlagsLastHostFlagsBefore = HostFlagsBefore;
          if (HostFlagsBefore == -1) {
            const int LinuxError = TranslateHostSocketErrorToLinux(errno);
            FcntlLastLinuxError = LinuxError;
            FcntlLastFailureReason = "host-get-status-flags-failed";
            return static_cast<uint64_t>(-LinuxError);
          }
          if (fcntl(Descriptor, F_SETFL, O_NONBLOCK) == -1) {
            const int LinuxError = TranslateHostSocketErrorToLinux(errno);
            FcntlLastLinuxError = LinuxError;
            FcntlLastFailureReason = "host-set-status-flags-failed";
            return static_cast<uint64_t>(-LinuxError);
          }
          const int HostFlagsAfter = fcntl(Descriptor, F_GETFL);
          FcntlSetFlagsLastHostFlagsAfter = HostFlagsAfter;
          if (HostFlagsAfter == -1) {
            const int LinuxError = TranslateHostSocketErrorToLinux(errno);
            FcntlLastLinuxError = LinuxError;
            FcntlLastFailureReason = "host-verify-status-flags-failed";
            return static_cast<uint64_t>(-LinuxError);
          }
          if ((HostFlagsAfter & O_NONBLOCK) == 0) {
            FcntlLastLinuxError = EIO;
            FcntlLastFailureReason = "host-nonblock-not-set";
            return static_cast<uint64_t>(-EIO);
          }
          ++FcntlSetFlagsSuccessCount;
          FcntlLastFailureReason = "none";
          return 0;
        }
      }

      constexpr int64_t LinuxFSetLK = 6;
      if (Command == LinuxFSetLK) {
        ++FcntlSetLockCallCount;
        if (!OwnedDescriptors.contains(Descriptor)) {
          FcntlLastLinuxError = EBADF;
          FcntlLastFailureReason = "unowned-descriptor";
          return static_cast<uint64_t>(-EBADF);
        }
        if (!Contains(Argument, sizeof(LinuxFlock64))) {
          FcntlLastLinuxError = EFAULT;
          FcntlLastFailureReason = "unreadable-flock";
          return static_cast<uint64_t>(-EFAULT);
        }

        LinuxFlock64 GuestLock {};
        std::memcpy(
          &GuestLock,
          reinterpret_cast<const void*>(Argument),
          sizeof(GuestLock));
        FcntlLastFlockReadable = true;
        FcntlLastFlockType = GuestLock.Type;
        FcntlLastFlockWhence = GuestLock.Whence;
        FcntlLastFlockStart = GuestLock.Start;
        FcntlLastFlockLength = GuestLock.Length;
        FcntlLastFlockProcessID = GuestLock.ProcessID;

        std::optional<short> HostType;
        switch (GuestLock.Type) {
        case 0: HostType = F_RDLCK; break;
        case 1: HostType = F_WRLCK; break;
        case 2: HostType = F_UNLCK; break;
        default: break;
        }
        std::optional<short> HostWhence;
        switch (GuestLock.Whence) {
        case 0: HostWhence = SEEK_SET; break;
        case 1: HostWhence = SEEK_CUR; break;
        case 2: HostWhence = SEEK_END; break;
        default: break;
        }
        if (!HostType.has_value() || !HostWhence.has_value()) {
          FcntlLastLinuxError = EINVAL;
          FcntlLastFailureReason = "unsupported-flock-shape";
          return static_cast<uint64_t>(-EINVAL);
        }

        struct flock HostLock {};
        HostLock.l_type = *HostType;
        HostLock.l_whence = *HostWhence;
        HostLock.l_start = static_cast<off_t>(GuestLock.Start);
        HostLock.l_len = static_cast<off_t>(GuestLock.Length);
        if (fcntl(Descriptor, F_SETLK, &HostLock) == -1) {
          const int LinuxError = TranslateHostFileLockErrorToLinux(errno);
          FcntlLastLinuxError = LinuxError;
          FcntlLastFailureReason = "host-file-lock-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        ++FcntlSetLockSuccessCount;
        FcntlLastFailureReason = "none";
        return 0;
      }
    }
    if (Number == SetSockOptSyscall && !RootFS.empty()) {
      SetSockOptSeen = true;
      ++SetSockOptCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const int32_t Level = static_cast<int32_t>(Arguments->Argument[2]);
      const int32_t Option = static_cast<int32_t>(Arguments->Argument[3]);
      const uint64_t GuestValue = Arguments->Argument[4];
      const uint64_t ValueLength = Arguments->Argument[5];
      SetSockOptLastDescriptor = Descriptor;
      SetSockOptLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      SetSockOptLastLevel = Level;
      SetSockOptLastOption = Option;
      SetSockOptLastValueLength = ValueLength;
      SetSockOptLastValueReadable = false;
      SetSockOptLastInt32ValueReadable = false;
      SetSockOptLastInt32Value = 0;
      SetSockOptLastValueFingerprint = 0;
      SetSockOptLastValueClass = GuestValue == 0
        ? "zero"
        : (ValueLength != 0 && Contains(GuestValue, ValueLength)
            ? "guest-memory"
            : "scalar-or-outside");
      SetSockOptLastValueReadable = ValueLength != 0
        && ValueLength <= 64
        && Contains(GuestValue, ValueLength);
      if (SetSockOptLastValueReadable) {
        SetSockOptLastValueFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(GuestValue),
          static_cast<size_t>(ValueLength));
        if (ValueLength == sizeof(int32_t)) {
          int32_t ScalarValue {};
          std::memcpy(&ScalarValue, reinterpret_cast<const void*>(GuestValue), sizeof(ScalarValue));
          SetSockOptLastInt32Value = ScalarValue;
          SetSockOptLastInt32ValueReadable = true;
        }
      }
      if (SetSockOptTraceCount < SetSockOptTrace.size()) {
        auto& Trace = SetSockOptTrace[SetSockOptTraceCount++];
        Trace.Descriptor = Descriptor;
        Trace.DescriptorOwned = SetSockOptLastDescriptorOwned;
        Trace.Level = Level;
        Trace.Option = Option;
        Trace.ValueLength = ValueLength;
        Trace.ValueReadable = SetSockOptLastValueReadable;
        Trace.Int32ValueReadable = SetSockOptLastInt32ValueReadable;
        Trace.Int32Value = SetSockOptLastInt32Value;
      }
      constexpr int32_t LinuxSolSocket = 1;
      constexpr int32_t LinuxSoPassCred = 16;
      const bool PassCredentialsCandidate = SetSockOptLastDescriptorOwned
        && Level == LinuxSolSocket
        && Option == LinuxSoPassCred
        && ValueLength == sizeof(int32_t)
        && SetSockOptLastInt32ValueReadable
        && (SetSockOptLastInt32Value == 0 || SetSockOptLastInt32Value == 1);
      if (PassCredentialsCandidate) {
        ++SetSockOptPassCredentialsCandidateCount;
        if (SetSockOptLastInt32Value == 1) {
          ++SetSockOptPassCredentialsEnableCount;
        } else {
          ++SetSockOptPassCredentialsDisableCount;
        }
        // El build macOS de Wine omite SO_PASSCRED: las credenciales solo
        // alimentan el workaround Linux PR_SET_PTRACER. Mantener server_pid
        // desconocido reproduce esa ruta sin aplicar una opción host distinta.
        ++SetSockOptPassCredentialsNoHostOptionCount;
        ++SetSockOptSuccessCount;
        SetSockOptLastLinuxError = 0;
        SetSockOptLastFailureReason = "none-host-option-not-required";
        return 0;
      }
      ++SetSockOptOtherShapeCount;
      SetSockOptLastLinuxError = ENOSYS;
      SetSockOptLastFailureReason = "unmeasured-shape";
    }
    if (Number == SigAltStackSyscall && !RootFS.empty()) {
      SigAltStackSeen = true;
      ++SigAltStackCallCount;
      const uint64_t GuestNewStack = Arguments->Argument[1];
      const uint64_t GuestOldStack = Arguments->Argument[2];
      SigAltStackLastLinuxError = 0;
      SigAltStackLastFailureReason = "none";
      SigAltStackLastNewStackClass = GuestNewStack == 0
        ? "zero"
        : (Contains(GuestNewStack, sizeof(LinuxX86_64StackT))
            ? "guest-memory"
            : "scalar-or-outside");
      SigAltStackLastOldStackClass = GuestOldStack == 0
        ? "zero"
        : (Contains(GuestOldStack, sizeof(LinuxX86_64StackT))
            ? "guest-memory"
            : "scalar-or-outside");
      SigAltStackLastNewStackReadable = GuestNewStack != 0
        && Contains(GuestNewStack, sizeof(LinuxX86_64StackT));
      SigAltStackLastOldStackWritable = GuestOldStack != 0
        && Contains(GuestOldStack, sizeof(LinuxX86_64StackT));
      SigAltStackLastGuestRSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
      if (SigAltStackLastNewStackReadable) {
        LinuxX86_64StackT NewStack {};
        std::memcpy(&NewStack, reinterpret_cast<const void*>(GuestNewStack), sizeof(NewStack));
        SigAltStackLastStackPointer = NewStack.StackPointer;
        SigAltStackLastFlags = NewStack.Flags;
        SigAltStackLastSize = NewStack.Size;
        SigAltStackLastStackRangeReadable = NewStack.StackPointer != 0
          && NewStack.Size != 0
          && Contains(NewStack.StackPointer, NewStack.Size);
        SigAltStackLastStackRangeLowShadow = LowGuestShadow
          && LowGuestShadow->ContainsLogicalRange(NewStack.StackPointer, NewStack.Size);
        SigAltStackLastStackRangeLowShadowMapped = LowGuestShadow
          && LowGuestShadow->ContainsMappedLogicalRange(NewStack.StackPointer, NewStack.Size);
        SigAltStackLastStackRangeLowShadowReadable = LowGuestShadow
          && LowGuestShadow->ContainsMappedLogicalRange(
            NewStack.StackPointer, NewStack.Size, PROT_READ);
        SigAltStackLastStackRangeLowShadowWritable = LowGuestShadow
          && LowGuestShadow->ContainsMappedLogicalRange(
            NewStack.StackPointer, NewStack.Size, PROT_WRITE);
        SigAltStackLastStackRangeLowShadowExecutable = LowGuestShadow
          && LowGuestShadow->ContainsMappedLogicalRange(
            NewStack.StackPointer, NewStack.Size, PROT_EXEC);

        const bool StackEndRepresentable = NewStack.StackPointer != 0
          && NewStack.Size != 0
          && NewStack.Size <= std::numeric_limits<uint64_t>::max() - NewStack.StackPointer;
        const uint64_t StackEnd = StackEndRepresentable
          ? NewStack.StackPointer + NewStack.Size
          : 0;
        SigAltStackLastGuestRSPWithinStack = StackEndRepresentable
          && SigAltStackLastGuestRSP >= NewStack.StackPointer
          && SigAltStackLastGuestRSP <= StackEnd;

        const bool InstallCandidate = GuestOldStack == 0
          && NewStack.Flags == 0
          && NewStack.Size >= LinuxX86MinSignalStackSize
          && StackEndRepresentable
          && SigAltStackLastStackRangeLowShadowMapped
          && SigAltStackLastStackRangeLowShadowReadable
          && SigAltStackLastStackRangeLowShadowWritable
          && !SigAltStackLastGuestRSPWithinStack;
        if (InstallCandidate) {
          ++SigAltStackInstallCandidateCount;
          SigAltStackGuestState = NewStack;
          SigAltStackGuestStateInstalled = true;
          ++SigAltStackInstallSuccessCount;
          ++SigAltStackNoHostInstallCount;
          return 0;
        }
      }
      ++SigAltStackOtherShapeCount;
      SigAltStackLastLinuxError = ENOSYS;
      SigAltStackLastFailureReason = "unmeasured-shape";
    }
    if (Number == StatSyscall && !RootFS.empty()) {
      StatSeen = true;
      ++StatCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      if (!GuestPath.has_value() || !Contains(GuestBuffer, sizeof(LinuxX86_64Stat))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      TraceGuestPath("stat", *GuestPath);
      if (GuestPath->empty() || GuestPath->front() != '/') {
        return static_cast<uint64_t>(-ENOTSUP);
      }
      const auto HostPath = ResolveGuestPath(*GuestPath);
      if (!HostPath.has_value()) {
        return static_cast<uint64_t>(-EACCES);
      }
      struct stat HostStat {};
      if (stat(HostPath->c_str(), &HostStat) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      const LinuxX86_64Stat GuestStat = TranslateStat(HostStat);
      std::memcpy(reinterpret_cast<void*>(GuestBuffer), &GuestStat, sizeof(GuestStat));
      ++StatSuccessCount;
      return 0;
    }
    if (Number == MMapSyscall && MMapArenaBase != 0) {
      MMapSeen = true;
      ++MMapCallCount;
      constexpr uint64_t LinuxMapShared = 0x01;
      constexpr uint64_t LinuxMapPrivate = 0x02;
      constexpr uint64_t LinuxMapFixed = 0x10;
      constexpr uint64_t LinuxMapAnonymous = 0x20;
      constexpr uint64_t LinuxMapDenyWrite = 0x0800;
      constexpr uint64_t LinuxMapNoReserve = 0x4000;
      constexpr uint64_t LinuxMapStack = 0x20000;
      constexpr uint64_t LinuxMapFixedNoReplace = 0x100000;
      constexpr uint64_t AllowedFlags = LinuxMapPrivate | LinuxMapFixed | LinuxMapAnonymous
                                      | LinuxMapDenyWrite | LinuxMapNoReserve
                                      | LinuxMapStack | LinuxMapFixedNoReplace;
      constexpr uint64_t LinuxPageSize = 4096;
      const uint64_t RequestedAddress = Arguments->Argument[1];
      const uint64_t Length = Arguments->Argument[2];
      const uint64_t Protection = Arguments->Argument[3];
      const uint64_t Flags = Arguments->Argument[4];
      const int Descriptor = static_cast<int>(Arguments->Argument[5]);
      const uint64_t Offset = Arguments->Argument[6];
      const bool IsLowPageAliasRequest = RequestedAddress == LinuxSharedUserDataAddress
        && Length == LinuxSharedUserDataSize
        && Protection == PROT_READ
        && Flags == (LinuxMapPrivate | LinuxMapAnonymous | LinuxMapFixedNoReplace)
        && Descriptor == -1 && Offset == 0;
      MMapLastRequestedAddress = RequestedAddress;
      MMapLastLength = Length;
      MMapLastProtection = Protection;
      MMapLastFlags = Flags;
      MMapLastOffset = Offset;
      MMapLastDescriptorClass = (Flags & LinuxMapAnonymous) != 0
        ? (Descriptor == -1 ? "anonymous-negative-one" : "anonymous-other")
        : (OwnedDescriptors.contains(Descriptor) ? "owned" : "unowned");
      MMapLastFailureReason = "none";
      MMapLastLinuxError = 0;
      MMapLastAlignedLength = 0;
      MMapLastMappingAddress = 0;
      const uint64_t MMapSyscallOrdinal = MMapCallCount;
      const uint64_t MMapGuestRIP = Frame->State.rip;
      const uint64_t MMapGuestRSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
      const uint64_t MMapGuestRBP = Frame->State.gregs[FEXCore::X86State::REG_RBP];
      std::array<uint64_t, 4> MMapGuestStackWords {};
      uint64_t MMapGuestStackWordCount {};
      uint64_t MMapGuestReturnAddress {};
      bool MMapGuestReturnAddressReadable {};
      const void* MMapGuestStackBytes = Contains(MMapGuestRSP, sizeof(MMapGuestStackWords))
        ? reinterpret_cast<const void*>(MMapGuestRSP)
        : nullptr;
      if (MMapGuestStackBytes == nullptr
          && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr) {
        MMapGuestStackBytes = LowGuestShadow->HostPointerForMappedLogicalRange(
          MMapGuestRSP,
          sizeof(MMapGuestStackWords),
          PROT_READ);
      }
      if (MMapGuestStackBytes != nullptr) {
        std::memcpy(MMapGuestStackWords.data(), MMapGuestStackBytes,
                    sizeof(MMapGuestStackWords));
        MMapGuestStackWordCount = MMapGuestStackWords.size();
        MMapGuestReturnAddress = MMapGuestStackWords[0];
        MMapGuestReturnAddressReadable = true;
      }
      constexpr uint64_t MapSOLibHeaderOffsetFromRBP = 0x830;
      constexpr size_t MapSOLibHeaderDiagnosticSize = 64;
      const uint64_t MMapGuestHeaderBuffer = MMapGuestRBP >= MapSOLibHeaderOffsetFromRBP
        ? MMapGuestRBP - MapSOLibHeaderOffsetFromRBP
        : 0;
      const bool MMapGuestHeaderReadable = MMapGuestHeaderBuffer != 0
        && Contains(MMapGuestHeaderBuffer, MapSOLibHeaderDiagnosticSize);
      uint64_t MMapGuestHeaderFirst64ByteFingerprint {};
      uint32_t MMapGuestHeaderMagic {};
      uint16_t MMapGuestHeaderType {};
      uint16_t MMapGuestHeaderMachine {};
      uint64_t MMapGuestHeaderEntry {};
      if (MMapGuestHeaderReadable) {
        const auto* HeaderBytes = reinterpret_cast<const uint8_t*>(MMapGuestHeaderBuffer);
        MMapGuestHeaderFirst64ByteFingerprint = FingerprintBytes(
          HeaderBytes,
          MapSOLibHeaderDiagnosticSize);
        std::memcpy(&MMapGuestHeaderMagic, HeaderBytes, sizeof(MMapGuestHeaderMagic));
        std::memcpy(&MMapGuestHeaderType, HeaderBytes + 16, sizeof(MMapGuestHeaderType));
        std::memcpy(&MMapGuestHeaderMachine, HeaderBytes + 18, sizeof(MMapGuestHeaderMachine));
        std::memcpy(&MMapGuestHeaderEntry, HeaderBytes + 24, sizeof(MMapGuestHeaderEntry));
      }
      uint64_t MMapCallRecordIndexPlusOne {};
      if (MMapCallRecordCount >= MMapCallRecords.size()) {
        MMapCallRecordOverflow = true;
      } else {
        MMapCallRecordIndexPlusOne = MMapCallRecordCount + 1;
        MMapCallRecords[MMapCallRecordCount++] = MMapCallRecord {
          .SyscallOrdinal = MMapSyscallOrdinal,
          .GuestRIP = MMapGuestRIP,
          .GuestRSP = MMapGuestRSP,
          .GuestRBP = MMapGuestRBP,
          .GuestReturnAddress = MMapGuestReturnAddress,
          .GuestReturnAddressReadable = MMapGuestReturnAddressReadable,
          .GuestHeaderBuffer = MMapGuestHeaderBuffer,
          .GuestHeaderReadable = MMapGuestHeaderReadable,
          .GuestHeaderFirst64ByteFingerprint = MMapGuestHeaderFirst64ByteFingerprint,
          .GuestHeaderMagic = MMapGuestHeaderMagic,
          .GuestHeaderType = MMapGuestHeaderType,
          .GuestHeaderMachine = MMapGuestHeaderMachine,
          .GuestHeaderEntry = MMapGuestHeaderEntry,
          .RequestedAddress = RequestedAddress,
          .Length = Length,
          .Protection = Protection,
          .Flags = Flags,
          .Offset = Offset,
          .Descriptor = Descriptor,
        };
      }
      const auto RecordFailure = [this, MMapCallRecordIndexPlusOne](
                                   int LinuxError,
                                   std::string Reason) -> uint64_t {
        ++MMapFailureCount;
        MMapLastLinuxError = LinuxError;
        MMapLastFailureReason = Reason;
        const uint64_t ReturnedValue = static_cast<uint64_t>(-LinuxError);
        if (MMapCallRecordIndexPlusOne != 0) {
          MMapCallRecord& Record = MMapCallRecords[MMapCallRecordIndexPlusOne - 1];
          Record.Completed = true;
          Record.Succeeded = false;
          Record.ReturnedValue = ReturnedValue;
          Record.LinuxError = LinuxError;
          Record.MappingAddress = MMapLastMappingAddress;
          Record.OutcomeReason = std::move(Reason);
        }
        return ReturnedValue;
      };
      const auto RecordSuccess = [this, MMapCallRecordIndexPlusOne](
                                   uint64_t ReturnedValue,
                                   std::string Reason) -> uint64_t {
        if (MMapCallRecordIndexPlusOne != 0) {
          MMapCallRecord& Record = MMapCallRecords[MMapCallRecordIndexPlusOne - 1];
          Record.Completed = true;
          Record.Succeeded = true;
          Record.ReturnedValue = ReturnedValue;
          Record.LinuxError = 0;
          Record.MappingAddress = MMapLastMappingAddress;
          Record.OutcomeReason = std::move(Reason);
        }
        return ReturnedValue;
      };
      const auto RecordArenaReject = [this, MMapSyscallOrdinal, MMapGuestRIP, MMapGuestRSP,
                                      MMapGuestReturnAddress, MMapGuestReturnAddressReadable,
                                      MMapGuestStackWords, MMapGuestStackWordCount,
                                      RequestedAddress, Length, Protection, Flags, Descriptor,
                                      Offset](uint64_t MappingAddress,
                                                          uint64_t AlignedLength,
                                                          bool SharedFileShape) {
        if (MMapArenaRejectRecordCount >= MMapArenaRejectRecords.size()) {
          MMapArenaRejectRecordOverflow = true;
          return;
        }
        MMapArenaRejectRecord& Record =
          MMapArenaRejectRecords[MMapArenaRejectRecordCount++];
        Record.SyscallOrdinal = MMapSyscallOrdinal;
        Record.GuestRIP = MMapGuestRIP;
        Record.GuestRSP = MMapGuestRSP;
        Record.GuestReturnAddress = MMapGuestReturnAddress;
        Record.GuestReturnAddressReadable = MMapGuestReturnAddressReadable;
        Record.GuestStackWords = MMapGuestStackWords;
        Record.GuestStackWordCount = MMapGuestStackWordCount;
        Record.RequestedAddress = RequestedAddress;
        Record.MappingAddress = MappingAddress;
        Record.Length = Length;
        Record.AlignedLength = AlignedLength;
        Record.Protection = Protection;
        Record.Flags = Flags;
        Record.Offset = Offset;
        Record.NextMMapAddress = NextMMapAddress;
        Record.Descriptor = Descriptor;
        Record.SharedFileShape = SharedFileShape;
      };
      const bool SharedFixedLowCandidate = RequestedAddress == LinuxSharedUserDataAddress
        && Length == LinuxPageSize
        && Protection == PROT_READ
        && Flags == (LinuxMapShared | LinuxMapFixed)
        && OwnedDescriptors.contains(Descriptor)
        && Offset == 0;
      if (SharedFixedLowCandidate) {
        ++MMapSharedFixedLowCandidateCount;
        MMapSharedFixedLowLastDescriptor = Descriptor;
        MMapSharedFixedLowLastDescriptorReceivedSCMRights =
          ReceivedSCMRightsDescriptors.contains(Descriptor);
        MMapSharedFixedLowLastProtection = Protection;
        MMapSharedFixedLowLastFlags = Flags;
        MMapSharedFixedLowLastOffset = Offset;
        struct stat DescriptorStat {};
        if (fstat(Descriptor, &DescriptorStat) == 0) {
          MMapSharedFixedLowLastDescriptorStatSucceeded = true;
          MMapSharedFixedLowLastDescriptorRegular = S_ISREG(DescriptorStat.st_mode);
          MMapSharedFixedLowLastDescriptorSize = DescriptorStat.st_size;
        }
      }
      const bool ExactSharedFixedLowMapping = SharedFixedLowCandidate
        && MMapSharedFixedLowLastDescriptorReceivedSCMRights
        && MMapSharedFixedLowLastDescriptorStatSucceeded
        && MMapSharedFixedLowLastDescriptorRegular
        && MMapSharedFixedLowLastDescriptorSize == static_cast<int64_t>(LinuxPageSize);
      if (ExactSharedFixedLowMapping && LowMemoryBiasModeEnabled
          && LowGuestShadow != nullptr) {
        ++MMapSharedFixedLowAttemptCount;
        ++MMapFixedCallCount;
        ++LowMemoryMMapRequestCount;
        MMapSharedFixedLowLastHostMappedSubpageMask =
          LowGuestShadow->MappedLogicalPageMask(
            RequestedAddress,
            LowGuestShadow->HostPageBytes());
        MMapSharedFixedLowLastHostPackedSubpageStates =
          LowGuestShadow->PackedLogicalPageStates(
            RequestedAddress,
            LowGuestShadow->HostPageBytes());
        uint64_t HostAddress {};
        uint64_t HostSpan {};
        const int MapError = LowGuestShadow->MapSharedFile(
          RequestedAddress,
          Length,
          Protection,
          Descriptor,
          Offset,
          &HostAddress,
          &HostSpan);
        MMapSharedFixedLowLastHostAddress = HostAddress;
        MMapSharedFixedLowLastHostSpan = HostSpan;
        MMapLastMappingAddress = RequestedAddress;
        MMapLastAlignedLength = Length;
        if (MapError != 0) {
          ++MMapSharedFixedLowFailureCount;
          ++LowMemoryMMapFailureCount;
          return RecordFailure(MapError, "shared-fixed-low-shadow-map-failed");
        }
        ++MMapSharedFixedLowSuccessCount;
        ++LowMemoryMMapSuccessCount;
        ++MMapSuccessCount;
        MMapFileByteCount += Length;
        MMapLastFailureReason = "success-shared-fixed-low-shadow";
        RecordLowMMap(
          RequestedAddress,
          Length,
          Protection,
          Flags,
          Descriptor,
          Offset);
        return RecordSuccess(RequestedAddress, "success-shared-fixed-low-shadow");
      }
      const bool SharedFileCandidate = RequestedAddress == 0
        && Length != 0
        && Flags == LinuxMapShared
        && OwnedDescriptors.contains(Descriptor)
        && Offset % LinuxPageSize == 0;
      if (SharedFileCandidate) {
        ++MMapSharedFileCandidateCount;
        MMapSharedFileLastDescriptor = Descriptor;
        MMapSharedFileLastDescriptorMatchesMemfd = Descriptor == MemfdCreateLastDescriptor;
        MMapSharedFileLastLength = Length;
        MMapSharedFileLastProtection = Protection;
        MMapSharedFileLastOffset = Offset;
        struct stat DescriptorStat {};
        if (fstat(Descriptor, &DescriptorStat) == 0) {
          MMapSharedFileLastDescriptorStatSucceeded = true;
          MMapSharedFileLastDescriptorRegular = S_ISREG(DescriptorStat.st_mode);
          MMapSharedFileLastDescriptorSize = DescriptorStat.st_size;
        }
      }
      const bool ExactSharedUserDataMapping = SharedFileCandidate
        && Length == LinuxPageSize
        && Protection == PROT_WRITE
        && Descriptor == MemfdCreateLastDescriptor
        && MMapSharedFileLastDescriptorStatSucceeded
        && MMapSharedFileLastDescriptorRegular
        && MMapSharedFileLastDescriptorSize == static_cast<int64_t>(LinuxPageSize)
        && Offset == 0;
      const bool ExactSharedSessionMapping = SharedFileCandidate
        && Length == ObservedWineSessionMappingSize
        && Protection == (PROT_READ | PROT_WRITE)
        && Descriptor == MemfdCreateLastDescriptor
        && MMapSharedFileLastDescriptorStatSucceeded
        && MMapSharedFileLastDescriptorRegular
        && MMapSharedFileLastDescriptorSize
          == static_cast<int64_t>(ObservedWineSessionMappingSize)
        && Offset == 0;
      const bool ExactWineUserSharedDataInitializationMapping = SharedFileCandidate
        && Length == ObservedWineUserSharedDataInitializationSize
        && Protection == (PROT_READ | PROT_WRITE)
        && ReceivedSCMRightsDescriptors.contains(Descriptor)
        && MMapSharedFileLastDescriptorStatSucceeded
        && MMapSharedFileLastDescriptorRegular
        && MMapSharedFileLastDescriptorSize == static_cast<int64_t>(LinuxPageSize)
        && Offset == 0;
      if (ExactSharedUserDataMapping || ExactSharedSessionMapping
          || ExactWineUserSharedDataInitializationMapping) {
        const uint64_t HostPageSize = static_cast<uint64_t>(getpagesize());
        if (HostPageSize == 0 || (HostPageSize & (HostPageSize - 1)) != 0) {
          return RecordFailure(EINVAL, "invalid-host-page-size");
        }
        const uint64_t HostMappingSpan = (Length + HostPageSize - 1)
          & ~(HostPageSize - 1);
        const uint64_t MappingAddress = (NextMMapAddress + HostPageSize - 1)
          & ~(HostPageSize - 1);
        MMapLastMappingAddress = MappingAddress;
        MMapLastAlignedLength = Length;
        MMapSharedFileLastHostPageSize = HostPageSize;
        MMapSharedFileLastHostMappingSpan = HostMappingSpan;
        MMapSharedFileLastHostAddressRemainder = MappingAddress % HostPageSize;
        if (!ContainsMMapArena(MappingAddress, HostMappingSpan)) {
          RecordArenaReject(MappingAddress, HostMappingSpan, true);
          ++MMapArenaRejectCount;
          return RecordFailure(ENOMEM, "shared-file-outside-private-arena");
        }
        // The guest cannot choose this host address: only the next unused page in the
        // helper's private arena may be replaced by the measured shared file mapping.
        void* Result = mmap(
          reinterpret_cast<void*>(MappingAddress),
          HostMappingSpan,
          static_cast<int>(Protection),
          MAP_SHARED | MAP_FIXED,
          Descriptor,
          0);
        if (Result == MAP_FAILED) {
          return RecordFailure(errno, "host-shared-file-mmap-failed");
        }
        if (reinterpret_cast<uint64_t>(Result) != MappingAddress) {
          munmap(Result, HostMappingSpan);
          return RecordFailure(EIO, "host-shared-file-mmap-address-mismatch");
        }
        NextMMapAddress = MappingAddress + HostMappingSpan;
        RecordHighMMap(
          MappingAddress,
          Length,
          NextMMapAddress,
          Protection,
          Flags,
          Descriptor,
          Offset);
        ++MMapSharedFileSuccessCount;
        ++MMapSharedFileArenaReplacementCount;
        ++MMapSuccessCount;
        MMapLastFailureReason = "success-shared-file-private-arena";
        return RecordSuccess(MappingAddress, "success-shared-file-private-arena");
      }
      if ((Flags & LinuxMapFixed) != 0) {
        ++MMapFixedCallCount;
      }
      if ((Flags & LinuxMapFixedNoReplace) != 0) {
        ++MMapFixedNoReplaceCallCount;
      }
      if ((Flags & LinuxMapAnonymous) != 0) {
        ++MMapAnonymousCallCount;
      }
      if ((Flags & LinuxMapStack) != 0) {
        ++MMapStackCallCount;
      }
      if (IsLowPageAliasRequest) {
        LowPageAliasRequestSeen = true;
        ++LowPageAliasRequestCount;
      }
      if (Length == 0 || (Protection & ~uint64_t {PROT_READ | PROT_WRITE | PROT_EXEC}) != 0
          || (Flags & LinuxMapPrivate) == 0 || (Flags & ~AllowedFlags) != 0
          || Offset % LinuxPageSize != 0) {
        return RecordFailure(EINVAL, "invalid-shape");
      }
      if ((Flags & LinuxMapAnonymous) == 0 && !OwnedDescriptors.contains(Descriptor)) {
        return RecordFailure(EBADF, "unowned-file-descriptor");
      }
      if ((Flags & LinuxMapAnonymous) != 0 && Descriptor != -1) {
        return RecordFailure(EINVAL, "anonymous-descriptor-not-minus-one");
      }
      if (Length > std::numeric_limits<uint64_t>::max() - (LinuxPageSize - 1)) {
        return RecordFailure(ENOMEM, "length-overflow");
      }
      const uint64_t AlignedLength = (Length + LinuxPageSize - 1) & ~(LinuxPageSize - 1);
      uint64_t MappingAddress {};
      const bool FixedRequest = (Flags & (LinuxMapFixed | LinuxMapFixedNoReplace)) != 0;
      if (FixedRequest) {
        if (RequestedAddress % LinuxPageSize != 0) {
          return RecordFailure(EINVAL, "fixed-address-unaligned");
        }
        MappingAddress = RequestedAddress;
      } else {
        MappingAddress = (NextMMapAddress + LinuxPageSize - 1) & ~(LinuxPageSize - 1);
      }
      MMapLastMappingAddress = MappingAddress;
      MMapLastAlignedLength = AlignedLength;
      if (IsLowPageAliasRequest && LowPageAliasModeEnabled) {
        if (LowPageAliasAccepted) {
          return RecordFailure(EEXIST, "low-page-alias-already-present");
        }
        if (LowPageAliasBackingSize < RealLowPageAliasBackingSize
            || !Contains(LowPageAliasBackingAddress, RealLowPageAliasBackingSize)) {
          return RecordFailure(ENOMEM, "low-page-alias-backing-invalid");
        }
        std::memset(
          reinterpret_cast<void*>(LowPageAliasBackingAddress),
          0,
          static_cast<size_t>(RealLowPageAliasBackingSize));
        LowPageAliasAccepted = true;
        LowPageAliasBackingZeroed = true;
        ++LowPageAliasAcceptCount;
        ++MMapSuccessCount;
        MMapLastFailureReason = "success-low-page-alias-instrumented";
        return RecordSuccess(LinuxSharedUserDataAddress, "success-low-page-alias-instrumented");
      }
      if (FixedRequest && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
          && LowGuestShadow->ContainsLogicalRange(MappingAddress, AlignedLength)) {
        ++LowMemoryMMapRequestCount;
        uint64_t FileBytes {};
        const int LowMapError = LowGuestShadow->Map(
          MappingAddress,
          AlignedLength,
          Protection,
          (Flags & LinuxMapFixedNoReplace) != 0,
          (Flags & LinuxMapAnonymous) != 0,
          Descriptor,
          Offset,
          &FileBytes);
        if (LowMapError != 0) {
          ++LowMemoryMMapFailureCount;
          return RecordFailure(LowMapError, "low-memory-shadow-map-failed");
        }
        ++LowMemoryMMapSuccessCount;
        ++MMapSuccessCount;
        MMapFileByteCount += FileBytes;
        MMapLastFailureReason = "success-low-memory-shadow";
        RecordLowMMap(
          MappingAddress,
          AlignedLength,
          Protection,
          Flags,
          Descriptor,
          Offset);
        return RecordSuccess(MappingAddress, "success-low-memory-shadow");
      }
      if (FixedRequest && HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
          && HighGuestSparse->ContainsLogicalRange(MappingAddress, AlignedLength)) {
        ++HighMemoryMMapRequestCount;
        uint64_t FileBytes {};
        const int HighMapError = HighGuestSparse->Map(
          MappingAddress,
          AlignedLength,
          Protection,
          (Flags & LinuxMapFixedNoReplace) != 0,
          (Flags & LinuxMapAnonymous) != 0,
          Descriptor,
          Offset,
          &FileBytes);
        if (HighMapError != 0) {
          ++HighMemoryMMapFailureCount;
          return RecordFailure(HighMapError, "high-memory-sparse-map-failed");
        }
        ++HighMemoryMMapSuccessCount;
        ++MMapSuccessCount;
        MMapFileByteCount += FileBytes;
        MMapLastFailureReason = "success-high-memory-sparse";
        return RecordSuccess(MappingAddress, "success-high-memory-sparse");
      }
      if (!ContainsMMapArena(MappingAddress, AlignedLength)) {
        RecordArenaReject(MappingAddress, AlignedLength, false);
        ++MMapArenaRejectCount;
        return RecordFailure(ENOMEM, "outside-private-arena");
      }

      std::memset(reinterpret_cast<void*>(MappingAddress), 0, static_cast<size_t>(AlignedLength));
      if ((Flags & LinuxMapAnonymous) == 0) {
        if (Offset > static_cast<uint64_t>(std::numeric_limits<off_t>::max())) {
          return RecordFailure(EINVAL, "file-offset-overflow");
        }
        size_t TotalRead {};
        while (TotalRead < Length) {
          const ssize_t Result = pread(
            Descriptor,
            reinterpret_cast<void*>(MappingAddress + TotalRead),
            static_cast<size_t>(Length - TotalRead),
            static_cast<off_t>(Offset + TotalRead));
          if (Result == -1 && errno == EINTR) {
            continue;
          }
          if (Result == -1) {
            return RecordFailure(errno, "file-read-failed");
          }
          if (Result == 0) {
            break;
          }
          TotalRead += static_cast<size_t>(Result);
        }
        MMapFileByteCount += TotalRead;
      }
      if (!FixedRequest) {
        NextMMapAddress = MappingAddress + AlignedLength;
      }
      RecordHighMMap(
        MappingAddress,
        AlignedLength,
        FixedRequest ? MappingAddress + AlignedLength : NextMMapAddress,
        Protection,
        Flags,
        Descriptor,
        Offset);
      ++MMapSuccessCount;
      MMapLastFailureReason = "success";
      return RecordSuccess(MappingAddress, "success");
    }
    if (Number == MUnmapSyscall && MMapArenaBase != 0) {
      MUnmapSeen = true;
      ++MUnmapCallCount;
      constexpr uint64_t LinuxMapShared = 0x01;
      constexpr uint64_t LinuxMapPrivateAnonymous = 0x02 | 0x20;
      const uint64_t Address = Arguments->Argument[1];
      const uint64_t Length = Arguments->Argument[2];
      MUnmapLastAddress = Address;
      MUnmapLastLength = Length;
      MUnmapLastLinuxError = 0;
      MUnmapLastRangeZeroed = false;
      MUnmapLastCursorRewound = false;
      MUnmapLastHostPagesReleased = false;
      MUnmapLastFailureReason = MUnmapFailureReason::None;
      MUnmapLastActiveRecordIndexPlusOne = 0;
      MUnmapLastActiveRecordArenaEnd = 0;
      MUnmapLastActiveRecordProtection = 0;
      MUnmapLastActiveRecordFlags = 0;
      if (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
          && HighGuestSparse->ContainsLogicalRange(Address, Length)) {
        ++HighMemoryMUnmapRequestCount;
        const int HighUnmapError = HighGuestSparse->Unmap(Address, Length);
        if (HighUnmapError != 0) {
          ++HighMemoryMUnmapFailureCount;
          MUnmapLastLinuxError = HighUnmapError;
          MUnmapLastFailureReason = MUnmapFailureReason::SparseHighUnmapFailed;
          return static_cast<uint64_t>(-HighUnmapError);
        }
        ++HighMemoryMUnmapSuccessCount;
        ++MUnmapSuccessCount;
        MUnmapLastRangeZeroed = true;
        return 0;
      }
      for (uint64_t Index = HighMMapRecordCount; Index != 0; --Index) {
        const HighMMapRecord& Record = HighMMapRecords[Index - 1];
        if (Record.Active && Record.Address == Address && Record.Length == Length) {
          MUnmapLastActiveRecordIndexPlusOne = Index;
          MUnmapLastActiveRecordArenaEnd = Record.ArenaEnd;
          MUnmapLastActiveRecordProtection = Record.Protection;
          MUnmapLastActiveRecordFlags = Record.Flags;
          break;
        }
      }
      const bool EndValid = Length <= std::numeric_limits<uint64_t>::max() - Address;
      constexpr uint64_t LinuxMapStack = 0x20000;
      const bool ExactMeasuredParentVForkStackFlags =
        (VForkParentInstrumentationEnabled || VForkParentProcessBridgeEnabled
          || VForkParentWineServerBridgeEnabled)
        && VirtualVForkParentEntered
        && !VirtualVForkParentStackUnmapAccepted
        && MUnmapLastActiveRecordFlags == (LinuxMapPrivateAnonymous | LinuxMapStack);
      const bool ExactMeasuredLIFOShape = Length != 0
        && Address % LinuxGuestPageSize == 0
        && Length % LinuxGuestPageSize == 0
        && EndValid
        && ContainsMMapArena(Address, Length)
        && MUnmapLastActiveRecordIndexPlusOne != 0
        && MUnmapLastActiveRecordArenaEnd == NextMMapAddress
        && MUnmapLastActiveRecordProtection == (PROT_READ | PROT_WRITE)
        && (MUnmapLastActiveRecordFlags == LinuxMapPrivateAnonymous
            || ExactMeasuredParentVForkStackFlags);
      if (ExactMeasuredLIFOShape) {
        std::memset(reinterpret_cast<void*>(Address), 0, static_cast<size_t>(Length));
        MUnmapLastRangeZeroed = true;
        if (MUnmapLastActiveRecordIndexPlusOne != 0) {
          HighMMapRecords[MUnmapLastActiveRecordIndexPlusOne - 1].Active = false;
          ++MUnmapRecordDeactivationCount;
        }
        NextMMapAddress = Address;
        MUnmapLastCursorRewound = true;
        ++MUnmapSuccessCount;
        ++MUnmapLogicalLIFOCount;
        if (ExactMeasuredParentVForkStackFlags) {
          VirtualVForkParentStackUnmapAccepted = true;
          ++VirtualVForkParentStackUnmapAcceptCount;
          VirtualVForkParentStackUnmapAddress = Address;
          VirtualVForkParentStackUnmapLength = Length;
        }
        return 0;
      }
      const uint64_t HostPageSize = static_cast<uint64_t>(getpagesize());
      const bool HostPageSizeValid = HostPageSize != 0
        && (HostPageSize & (HostPageSize - 1)) == 0;
      const bool ExactMeasuredSharedUserDataLIFOShape =
        Length == ObservedWineUserSharedDataInitializationSize
        && EndValid
        && HostPageSizeValid
        && Address % HostPageSize == 0
        && ContainsMMapArena(Address, Length)
        && MUnmapLastActiveRecordIndexPlusOne != 0
        && MUnmapLastActiveRecordArenaEnd == NextMMapAddress
        && MUnmapLastActiveRecordArenaEnd - Address == HostPageSize
        && MUnmapLastActiveRecordProtection == (PROT_READ | PROT_WRITE)
        && MUnmapLastActiveRecordFlags == LinuxMapShared;
      if (ExactMeasuredSharedUserDataLIFOShape) {
        void* const Result = mmap(
          reinterpret_cast<void*>(Address),
          static_cast<size_t>(HostPageSize),
          PROT_READ | PROT_WRITE,
          MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
          -1,
          0);
        if (Result == MAP_FAILED) {
          MUnmapLastLinuxError = errno;
          MUnmapLastFailureReason = MUnmapFailureReason::HostAnonymousRemapFailed;
          return static_cast<uint64_t>(-errno);
        }
        if (reinterpret_cast<uint64_t>(Result) != Address) {
          munmap(Result, static_cast<size_t>(HostPageSize));
          MUnmapLastLinuxError = EIO;
          MUnmapLastFailureReason =
            MUnmapFailureReason::HostAnonymousRemapAddressMismatch;
          return static_cast<uint64_t>(-EIO);
        }
        std::memset(reinterpret_cast<void*>(Address), 0, static_cast<size_t>(HostPageSize));
        MUnmapLastRangeZeroed = true;
        HighMMapRecords[MUnmapLastActiveRecordIndexPlusOne - 1].Active = false;
        ++MUnmapRecordDeactivationCount;
        NextMMapAddress = Address;
        MUnmapLastCursorRewound = true;
        ++MUnmapSuccessCount;
        ++MUnmapLogicalLIFOCount;
        return 0;
      }
      MUnmapLastFailureReason = MUnmapFailureReason::UnmeasuredShape;
    }
    if (Number == CloseSyscall && !RootFS.empty()) {
      CloseSeen = true;
      ++CloseCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      if (Descriptor >= STDIN_FILENO && Descriptor <= STDERR_FILENO) {
        if (ClosedStandardDescriptors.contains(Descriptor)) {
          return static_cast<uint64_t>(-EBADF);
        }
        ClosedStandardDescriptors.insert(Descriptor);
        ++CloseSuccessCount;
        return 0;
      }
      const auto DescriptorIterator = OwnedDescriptors.find(Descriptor);
      if (DescriptorIterator == OwnedDescriptors.end()) {
        return static_cast<uint64_t>(-EBADF);
      }
      if (close(Descriptor) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      EpollDescriptors.erase(Descriptor);
      ReceivedSCMRightsDescriptors.erase(Descriptor);
      RegistryTemporaryDescriptors.erase(Descriptor);
      CXAltLoaderConnectedDescriptors.erase(Descriptor);
      OwnedDescriptors.erase(DescriptorIterator);
      ++CloseSuccessCount;
      return 0;
    }
    constexpr int64_t LinuxPrSetName = 15;
    if (Number == PrctlSyscall && !RootFS.empty()
        && static_cast<int64_t>(Arguments->Argument[1]) == LinuxPrSetName) {
      PrctlSeen = true;
      ++PrctlCallCount;
      constexpr size_t LinuxTaskNameSize = 16;
      const uint64_t GuestName = Arguments->Argument[2];
      if (!Contains(GuestName, LinuxTaskNameSize)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      std::array<char, LinuxTaskNameSize> Name {};
      std::memcpy(Name.data(), reinterpret_cast<const void*>(GuestName), Name.size());
      Name.back() = '\0';
      PrctlLastNameLength = strnlen(Name.data(), Name.size());
      PrctlLastNameFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(Name.data()),
        PrctlLastNameLength);
      const int Result = pthread_setname_np(Name.data());
      if (Result != 0) {
        return static_cast<uint64_t>(-Result);
      }
      ++PrctlSetNameSuccessCount;
      return 0;
    }
    constexpr uint64_t ObservedUserfaultfdFlags = 526337;
    if (Number == UserfaultfdSyscall && !RootFS.empty()
        && Arguments->Argument[1] == ObservedUserfaultfdFlags) {
      UserfaultfdSeen = true;
      ++UserfaultfdCallCount;
      UserfaultfdLastFlags = Arguments->Argument[1];
      ++UserfaultfdUnavailableCount;
      return static_cast<uint64_t>(-ENOSYS);
    }
    constexpr uint64_t LinuxKernelSigsetSize = sizeof(uint64_t);
    constexpr uint64_t LinuxSigBlock = 0;
    constexpr uint64_t LinuxSigSetMask = 2;
    constexpr int64_t LinuxMaximumSignal = 64;
    constexpr int64_t LinuxInternalSignalMinimum = 32;
    constexpr int64_t LinuxInternalSignalMaximum = 33;
    constexpr uint64_t LinuxSA_RESTORER = 0x0400'0000;
    constexpr uint64_t LinuxSA_RESTART = 0x1000'0000;
    constexpr int64_t LinuxSIGPIPE = 13;
    if (Number == RtSigactionSyscall && !RootFS.empty()
        && static_cast<int64_t>(Arguments->Argument[1]) == LinuxSIGPIPE
        && Arguments->Argument[2] != 0
        && Arguments->Argument[3] != 0
        && Arguments->Argument[4] == LinuxKernelSigsetSize) {
      const uint64_t GuestAction = Arguments->Argument[2];
      const uint64_t GuestOldAction = Arguments->Argument[3];
      if (!Contains(GuestAction, sizeof(LinuxGuestSigAction))
          || !Contains(GuestOldAction, sizeof(LinuxGuestSigAction))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxGuestSigAction RequestedAction {};
      std::memcpy(
        &RequestedAction,
        reinterpret_cast<const void*>(GuestAction),
        sizeof(RequestedAction));
      const bool ExactObservedIgnore = RequestedAction.Handler == 1
        && RequestedAction.Flags == (LinuxSA_RESTART | LinuxSA_RESTORER)
        && RequestedAction.Restorer != 0
        && Contains(RequestedAction.Restorer, 1);
      if (ExactObservedIgnore) {
        RtSigactionSeen = true;
        ++RtSigactionCallCount;
        RtSigactionLastSignal = LinuxSIGPIPE;
        RtSigactionLastSigsetSize = Arguments->Argument[4];
        const LinuxGuestSigAction& CurrentAction = GuestSignalActions[
          static_cast<size_t>(LinuxSIGPIPE)];
        std::memcpy(
          reinterpret_cast<void*>(GuestOldAction),
          &CurrentAction,
          sizeof(CurrentAction));
        GuestSignalActions[static_cast<size_t>(LinuxSIGPIPE)] = RequestedAction;
        RtSigactionLastActionFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(&RequestedAction),
          sizeof(RequestedAction));
        ++RtSigactionSetSuccessCount;
        ++RtSigactionGuestSigpipeIgnoreSuccessCount;
        return 0;
      }
    }
    if (Number == RtSigactionSyscall && !RootFS.empty()
        && VForkChildInstrumentationEnabled
        && static_cast<int64_t>(Arguments->Argument[1]) >= LinuxInternalSignalMinimum
        && static_cast<int64_t>(Arguments->Argument[1]) <= LinuxInternalSignalMaximum
        && Arguments->Argument[2] != 0
        && Arguments->Argument[3] == 0
        && Arguments->Argument[4] == LinuxKernelSigsetSize) {
      RtSigactionInternalCandidateSeen = true;
      RtSigactionInternalCandidateSignal = static_cast<int64_t>(Arguments->Argument[1]);
      RtSigactionInternalActionContained = Contains(
        Arguments->Argument[2],
        sizeof(LinuxGuestSigAction));
      LinuxGuestSigAction RequestedAction {};
      if (RtSigactionInternalActionContained) {
        std::memcpy(
          &RequestedAction,
          reinterpret_cast<const void*>(Arguments->Argument[2]),
          sizeof(RequestedAction));
      }
      RtSigactionInternalHandlerMatches = RequestedAction.Handler == 1;
      RtSigactionInternalFlagsMatch = RequestedAction.Flags == LinuxSA_RESTORER;
      RtSigactionInternalRestorerMatches = RequestedAction.Restorer != 0
        && Contains(RequestedAction.Restorer, 1);
      RtSigactionInternalMaskMatchesProcess = RequestedAction.Mask == GuestSignalMask;
      RtSigactionInternalCandidateMaskFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(&RequestedAction.Mask),
        sizeof(RequestedAction.Mask));
      RtSigactionInternalProcessMaskFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(&GuestSignalMask),
        sizeof(GuestSignalMask));
      const bool ExactObservedIgnore = RtSigactionInternalActionContained
        && RtSigactionInternalHandlerMatches
        && RtSigactionInternalFlagsMatch
        && RtSigactionInternalRestorerMatches;
      if (ExactObservedIgnore) {
        RtSigactionSeen = true;
        ++RtSigactionCallCount;
        RtSigactionLastSignal = RtSigactionInternalCandidateSignal;
        RtSigactionLastSigsetSize = Arguments->Argument[4];
        GuestSignalActions[static_cast<size_t>(RtSigactionInternalCandidateSignal)] = RequestedAction;
        RtSigactionLastActionFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(&RequestedAction),
          sizeof(RequestedAction));
        ++RtSigactionSetSuccessCount;
        return 0;
      }
    }
    if (Number == RtSigactionSyscall && !RootFS.empty()
        && VForkChildInstrumentationEnabled
        && static_cast<int64_t>(Arguments->Argument[1]) >= 1
        && static_cast<int64_t>(Arguments->Argument[1]) <= LinuxMaximumSignal
        && Arguments->Argument[2] == 0
        && Arguments->Argument[3] != 0
        && Arguments->Argument[4] == LinuxKernelSigsetSize) {
      RtSigactionSeen = true;
      ++RtSigactionCallCount;
      RtSigactionLastSignal = static_cast<int64_t>(Arguments->Argument[1]);
      RtSigactionLastSigsetSize = Arguments->Argument[4];
      const uint64_t GuestOldAction = Arguments->Argument[3];
      if (!Contains(GuestOldAction, sizeof(LinuxGuestSigAction))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      const LinuxGuestSigAction& CurrentAction = GuestSignalActions[
        static_cast<size_t>(RtSigactionLastSignal)];
      std::memcpy(
        reinterpret_cast<void*>(GuestOldAction),
        &CurrentAction,
        sizeof(CurrentAction));
      RtSigactionLastActionFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(&CurrentAction),
        sizeof(CurrentAction));
      ++RtSigactionQuerySuccessCount;
      return 0;
    }
    if (Number == RtSigactionSyscall && !RootFS.empty()
        && static_cast<int64_t>(Arguments->Argument[1]) >= 1
        && static_cast<int64_t>(Arguments->Argument[1]) <= LinuxMaximumSignal
        && Arguments->Argument[4] == LinuxKernelSigsetSize) {
      const int64_t Signal = static_cast<int64_t>(Arguments->Argument[1]);
      const uint64_t GuestAction = Arguments->Argument[2];
      const uint64_t GuestOldAction = Arguments->Argument[3];
      constexpr int64_t LinuxSIGKILL = 9;
      constexpr int64_t LinuxSIGSTOP = 19;
      if (GuestAction != 0 && (Signal == LinuxSIGKILL || Signal == LinuxSIGSTOP)) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if ((GuestAction != 0 && !Contains(GuestAction, sizeof(LinuxGuestSigAction)))
          || (GuestOldAction != 0
              && !Contains(GuestOldAction, sizeof(LinuxGuestSigAction)))) {
        return static_cast<uint64_t>(-EFAULT);
      }

      RtSigactionSeen = true;
      ++RtSigactionCallCount;
      RtSigactionLastSignal = Signal;
      RtSigactionLastSigsetSize = Arguments->Argument[4];
      const LinuxGuestSigAction& CurrentAction = GuestSignalActions[
        static_cast<size_t>(Signal)];
      if (GuestOldAction != 0) {
        std::memcpy(
          reinterpret_cast<void*>(GuestOldAction),
          &CurrentAction,
          sizeof(CurrentAction));
        if (GuestAction == 0) {
          ++RtSigactionQuerySuccessCount;
        }
      }
      if (GuestAction != 0) {
        LinuxGuestSigAction RequestedAction {};
        std::memcpy(
          &RequestedAction,
          reinterpret_cast<const void*>(GuestAction),
          sizeof(RequestedAction));
        constexpr uint64_t LinuxSIGKILLBit = uint64_t {1} << (LinuxSIGKILL - 1);
        constexpr uint64_t LinuxSIGSTOPBit = uint64_t {1} << (LinuxSIGSTOP - 1);
        RequestedAction.Mask &= ~(LinuxSIGKILLBit | LinuxSIGSTOPBit);
        GuestSignalActions[static_cast<size_t>(Signal)] = RequestedAction;
        RtSigactionLastActionFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(&RequestedAction),
          sizeof(RequestedAction));
        ++RtSigactionSetSuccessCount;
      } else {
        RtSigactionLastActionFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(&CurrentAction),
          sizeof(CurrentAction));
      }
      ++RtSigactionGuestTableOnlySuccessCount;
      return 0;
    }
    if (Number == RtSigprocmaskSyscall && !RootFS.empty()
        && VForkChildInstrumentationEnabled
        && Arguments->Argument[1] == LinuxSigBlock
        && Arguments->Argument[2] == 0
        && Arguments->Argument[3] != 0
        && Arguments->Argument[4] == LinuxKernelSigsetSize) {
      RtSigprocmaskSeen = true;
      ++RtSigprocmaskCallCount;
      RtSigprocmaskLastHow = Arguments->Argument[1];
      RtSigprocmaskLastSigsetSize = Arguments->Argument[4];
      const uint64_t GuestOldSet = Arguments->Argument[3];
      if (!Contains(GuestOldSet, LinuxKernelSigsetSize)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      std::memcpy(
        reinterpret_cast<void*>(GuestOldSet),
        &GuestSignalMask,
        sizeof(GuestSignalMask));
      RtSigprocmaskLastMaskFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(&GuestSignalMask),
        sizeof(GuestSignalMask));
      ++RtSigprocmaskQuerySuccessCount;
      ++RtSigprocmaskSuccessCount;
      return 0;
    }
    if (Number == RtSigprocmaskSyscall && !RootFS.empty()
        && (Arguments->Argument[1] == LinuxSigBlock
            || Arguments->Argument[1] == LinuxSigSetMask)
        && Arguments->Argument[4] == LinuxKernelSigsetSize
        && Arguments->Argument[2] != 0) {
      RtSigprocmaskSeen = true;
      ++RtSigprocmaskCallCount;
      RtSigprocmaskLastHow = Arguments->Argument[1];
      RtSigprocmaskLastSigsetSize = Arguments->Argument[4];
      const uint64_t GuestSet = Arguments->Argument[2];
      const uint64_t GuestOldSet = Arguments->Argument[3];
      if (!Contains(GuestSet, LinuxKernelSigsetSize)
          || (GuestOldSet != 0 && !Contains(GuestOldSet, LinuxKernelSigsetSize))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      if (GuestOldSet != 0) {
        std::memcpy(
          reinterpret_cast<void*>(GuestOldSet),
          &GuestSignalMask,
          sizeof(GuestSignalMask));
      }
      uint64_t RequestedMask {};
      std::memcpy(&RequestedMask, reinterpret_cast<const void*>(GuestSet), sizeof(RequestedMask));
      constexpr uint64_t LinuxSigKillBit = uint64_t {1} << (9 - 1);
      constexpr uint64_t LinuxSigStopBit = uint64_t {1} << (19 - 1);
      const uint64_t MaskableSignals = RequestedMask & ~(LinuxSigKillBit | LinuxSigStopBit);
      if (Arguments->Argument[1] == LinuxSigBlock) {
        GuestSignalMask |= MaskableSignals;
      } else {
        GuestSignalMask = MaskableSignals;
      }
      RtSigprocmaskLastMaskFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(&GuestSignalMask),
        sizeof(GuestSignalMask));
      ++RtSigprocmaskSuccessCount;
      return 0;
    }
    if (Number == ArchPrctlSyscall && !RootFS.empty()) {
      ArchPrctlSeen = true;
      ++ArchPrctlCallCount;
      constexpr uint32_t ArchSetGS = 0x1001;
      constexpr uint32_t ArchSetFS = 0x1002;
      constexpr uint32_t ArchGetFS = 0x1003;
      constexpr uint32_t ArchGetGS = 0x1004;
      constexpr uint32_t ArchGetCPUID = 0x1011;
      constexpr uint32_t ArchSetCPUID = 0x1012;
      constexpr uint32_t ArchCETStatus = 0x3001;
      constexpr uint64_t TaskMaximum64Bit = uint64_t {1} << 47;
      const uint32_t Code = static_cast<uint32_t>(Arguments->Argument[1]);
      const uint64_t Address = Arguments->Argument[2];
      switch (Code) {
      case ArchSetGS:
        if (Address >= TaskMaximum64Bit) {
          return static_cast<uint64_t>(-EPERM);
        }
        Frame->State.gs_cached = Address;
        ++ArchPrctlSetGSCount;
        return 0;
      case ArchSetFS:
        if (Address >= TaskMaximum64Bit) {
          return static_cast<uint64_t>(-EPERM);
        }
        Frame->State.fs_cached = Address;
        ++ArchPrctlSetFSCount;
        return 0;
      case ArchGetFS:
      case ArchGetGS:
        if (!Contains(Address, sizeof(uint64_t))) {
          return static_cast<uint64_t>(-EFAULT);
        }
        *reinterpret_cast<uint64_t*>(Address) = Code == ArchGetFS ? Frame->State.fs_cached : Frame->State.gs_cached;
        return 0;
      case ArchGetCPUID:
        return 1;
      case ArchSetCPUID:
        return static_cast<uint64_t>(-ENODEV);
      case ArchCETStatus:
        return static_cast<uint64_t>(-EINVAL);
      default:
        return static_cast<uint64_t>(-EINVAL);
      }
    }
    if (Number == GetUIDSyscall && !RootFS.empty()) {
      GetUIDSeen = true;
      ++GetUIDCallCount;
      LastGetUID = static_cast<uint64_t>(getuid());
      return LastGetUID;
    }
    if (Number == GetPIDSyscall && !RootFS.empty()) {
      GetPIDSeen = true;
      ++GetPIDCallCount;
      LastGetPID = static_cast<uint64_t>(getpid());
      return LastGetPID;
    }
    if (Number == SchedGetAffinitySyscall && !RootFS.empty()) {
      constexpr uint64_t LinuxKernelAffinityBytes = sizeof(uint64_t);
      constexpr int LinuxBadAddress = 14;
      constexpr int LinuxInvalidArgument = 22;
      const int64_t ProcessID = static_cast<int64_t>(Arguments->Argument[1]);
      const uint64_t CPUSetSize = Arguments->Argument[2];
      const uint64_t GuestMask = Arguments->Argument[3];
      if (ProcessID < 0 || CPUSetSize < LinuxKernelAffinityBytes) {
        return static_cast<uint64_t>(-LinuxInvalidArgument);
      }
      if (!Contains(GuestMask, CPUSetSize)) {
        return static_cast<uint64_t>(-LinuxBadAddress);
      }
      const long HostLogicalCPUCount = sysconf(_SC_NPROCESSORS_ONLN);
      const uint64_t LogicalCPUCount = HostLogicalCPUCount > 0
        ? static_cast<uint64_t>(HostLogicalCPUCount)
        : uint64_t {1};
      const uint64_t AffinityMask = LogicalCPUCount >= 64
        ? std::numeric_limits<uint64_t>::max()
        : (uint64_t {1} << LogicalCPUCount) - 1;
      std::memcpy(
        reinterpret_cast<void*>(GuestMask),
        &AffinityMask,
        sizeof(AffinityMask));
      std::cerr << "TRACE sched_getaffinity-result"
                << " pid=" << ProcessID
                << " cpusetsize=" << CPUSetSize
                << " logical-cpus=" << LogicalCPUCount
                << " returned-bytes=" << LinuxKernelAffinityBytes
                << '\n';
      std::cerr.flush();
      return LinuxKernelAffinityBytes;
    }
    if (Number == DupSyscall && !RootFS.empty()) {
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      if (!OwnedDescriptors.contains(Descriptor)) {
        return static_cast<uint64_t>(-9);
      }
      const int DuplicatedDescriptor = dup(Descriptor);
      if (DuplicatedDescriptor == -1) {
        return static_cast<uint64_t>(-TranslateHostDupErrorToLinux(errno));
      }
      OwnedDescriptors.insert(DuplicatedDescriptor);
      ClosedStandardDescriptors.erase(DuplicatedDescriptor);
      std::cerr << "TRACE dup-result"
                << " source=" << Descriptor
                << " duplicated=" << DuplicatedDescriptor
                << " source-status-flags=" << fcntl(Descriptor, F_GETFL)
                << " duplicated-descriptor-flags="
                << fcntl(DuplicatedDescriptor, F_GETFD)
                << '\n';
      std::cerr.flush();
      return static_cast<uint64_t>(DuplicatedDescriptor);
    }
    if (Number == GetTIDSyscall && !RootFS.empty()) {
      GetTIDSeen = true;
      ++GetTIDCallCount;

      // Match Wine's public macOS implementation of get_unix_tid(): return
      // the numeric Mach thread-port name after releasing the extra send right
      // acquired by mach_thread_self(). This is guest ABI state only; it does
      // not fabricate a Linux TID or alter the host thread.
      const mach_port_t ThreadPort = mach_thread_self();
      GetTIDLastMachPort = static_cast<uint64_t>(ThreadPort);
      GetTIDLastDeallocateResult = mach_port_deallocate(mach_task_self(), ThreadPort);
      if (GetTIDLastDeallocateResult == KERN_SUCCESS) {
        ++GetTIDDeallocateSuccessCount;
      }
      ++GetTIDSuccessCount;
      return GetTIDLastMachPort;
    }
    if (Number == SetPrioritySyscall && !RootFS.empty()) {
      SetPrioritySeen = true;
      ++SetPriorityCallCount;
      const int64_t Which = static_cast<int64_t>(Arguments->Argument[1]);
      const int64_t Who = static_cast<int64_t>(Arguments->Argument[2]);
      const int64_t Nice = static_cast<int32_t>(Arguments->Argument[3]);
      SetPriorityLastWhich = Which;
      SetPriorityLastWho = Who;
      SetPriorityLastNice = Nice;
      SetPriorityLastWhoMatchesPID = Who == static_cast<int64_t>(getpid());
      SetPriorityLastHostError = 0;
      SetPriorityLastLinuxError = 0;
      SetPriorityLastFailureReason = "none";
      constexpr int64_t ObservedCapabilityProbeNice = -20;
      constexpr int64_t ObservedResetNice = 0;
      if (Which != PRIO_PROCESS || !SetPriorityLastWhoMatchesPID
          || (Nice != ObservedCapabilityProbeNice && Nice != ObservedResetNice)) {
        SetPriorityLastLinuxError = EINVAL;
        SetPriorityLastFailureReason = "unmeasured-target";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (setpriority(PRIO_PROCESS, static_cast<id_t>(Who), static_cast<int>(Nice)) != 0) {
        const int HostError = errno;
        const int LinuxError = HostError == EACCES || HostError == EPERM
          ? EACCES
          : (HostError == ESRCH ? ESRCH : EIO);
        SetPriorityLastHostError = HostError;
        SetPriorityLastLinuxError = LinuxError;
        SetPriorityLastFailureReason = "host-setpriority-rejected";
        if (Nice == ObservedCapabilityProbeNice
            && (HostError == EACCES || HostError == EPERM)) {
          ++SetPriorityExpectedRejectionCount;
        } else {
          ++SetPriorityUnexpectedFailureCount;
        }
        return static_cast<uint64_t>(-LinuxError);
      }
      ++SetPrioritySuccessCount;
      return 0;
    }
    if (Number == PollSyscall && !RootFS.empty()) {
      PollSeen = true;
      ++PollCallCount;
      constexpr uint64_t ObservedDescriptorCount = 1;
      constexpr int64_t ObservedTimeoutMilliseconds = 1;
      constexpr int16_t LinuxPollIn = 0x0001;
      const uint64_t GuestPollDescriptors = Arguments->Argument[1];
      const uint64_t DescriptorCount = Arguments->Argument[2];
      const int64_t TimeoutMilliseconds = static_cast<int64_t>(Arguments->Argument[3]);
      PollLastDescriptorCount = DescriptorCount;
      PollLastTimeout = TimeoutMilliseconds;
      PollLastLinuxError = 0;
      if (DescriptorCount != ObservedDescriptorCount
          || TimeoutMilliseconds != ObservedTimeoutMilliseconds
          || !Contains(GuestPollDescriptors, sizeof(LinuxPollFD))) {
        PollLastLinuxError = EINVAL;
        return static_cast<uint64_t>(-EINVAL);
      }
      LinuxPollFD GuestDescriptor {};
      std::memcpy(
        &GuestDescriptor,
        reinterpret_cast<const void*>(GuestPollDescriptors),
        sizeof(GuestDescriptor));
      PollLastDescriptor = GuestDescriptor.Descriptor;
      PollLastEvents = GuestDescriptor.Events;
      if (!OwnedDescriptors.contains(GuestDescriptor.Descriptor)) {
        PollLastLinuxError = EBADF;
        return static_cast<uint64_t>(-EBADF);
      }
      if (GuestDescriptor.Events != LinuxPollIn) {
        PollLastLinuxError = EINVAL;
        return static_cast<uint64_t>(-EINVAL);
      }

      pollfd HostDescriptor {
        .fd = GuestDescriptor.Descriptor,
        .events = POLLIN,
        .revents = 0,
      };
      const int Result = poll(&HostDescriptor, 1, static_cast<int>(TimeoutMilliseconds));
      if (Result == -1) {
        PollLastLinuxError = errno;
        return static_cast<uint64_t>(-errno);
      }
      GuestDescriptor.ReturnedEvents = HostDescriptor.revents;
      PollLastReturnedEvents = GuestDescriptor.ReturnedEvents;
      std::memcpy(
        reinterpret_cast<void*>(GuestPollDescriptors),
        &GuestDescriptor,
        sizeof(GuestDescriptor));
      ++PollSuccessCount;
      PollReadyDescriptorCount += static_cast<uint64_t>(Result);
      return static_cast<uint64_t>(Result);
    }
    if (Number == Pipe2Syscall && !RootFS.empty()) {
      Pipe2Seen = true;
      ++Pipe2CallCount;
      const uint64_t GuestPipe = Arguments->Argument[1];
      const uint64_t Flags = Arguments->Argument[2];
      Pipe2LastGuestPointer = GuestPipe;
      Pipe2LastFlags = Flags;
      Pipe2LastLinuxError = 0;
      Pipe2LastPointerClass = "scalar-or-outside";
      Pipe2LastLowShadowMapped = false;
      Pipe2LastLowShadowWritable = false;
      if (Contains(GuestPipe, 2 * sizeof(int32_t))) {
        Pipe2LastPointerClass = "guest-memory";
      } else if (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
          && LowGuestShadow->ContainsLogicalRange(
            GuestPipe,
            2 * sizeof(int32_t))) {
        Pipe2LastPointerClass = "low-shadow";
        Pipe2LastLowShadowMapped = LowGuestShadow->ContainsMappedLogicalRange(
          GuestPipe,
          2 * sizeof(int32_t));
        Pipe2LastLowShadowWritable = LowGuestShadow->ContainsMappedLogicalRange(
          GuestPipe,
          2 * sizeof(int32_t),
          PROT_WRITE);
      }
      if (Pipe2TraceCount < Pipe2Trace.size()) {
        Pipe2Trace[Pipe2TraceCount++] = Pipe2TraceEntry {
          .GuestPipe = GuestPipe,
          .Flags = Flags,
          .PointerClass = Pipe2LastPointerClass,
          .LowShadowMapped = Pipe2LastLowShadowMapped,
          .LowShadowWritable = Pipe2LastLowShadowWritable,
        };
      }
      void* GuestPipeDestination = Contains(GuestPipe, 2 * sizeof(int32_t))
        ? reinterpret_cast<void*>(GuestPipe)
        : nullptr;
      bool UsesLowShadow = false;
      if (GuestPipeDestination == nullptr && LowMemoryBiasModeEnabled
          && LowGuestShadow != nullptr) {
        GuestPipeDestination = LowGuestShadow->HostPointerForWritableLogicalRange(
          GuestPipe,
          2 * sizeof(int32_t));
        UsesLowShadow = GuestPipeDestination != nullptr;
      }
      if (GuestPipeDestination == nullptr) {
        Pipe2LastLinuxError = EFAULT;
        return static_cast<uint64_t>(-EFAULT);
      }
      if (Flags != 0) {
        Pipe2LastLinuxError = EINVAL;
        return static_cast<uint64_t>(-EINVAL);
      }
      std::array<int, 2> HostPipe {-1, -1};
      if (pipe(HostPipe.data()) != 0) {
        Pipe2LastLinuxError = errno;
        return static_cast<uint64_t>(-errno);
      }
      const std::array<int32_t, 2> GuestDescriptors {
        static_cast<int32_t>(HostPipe[0]),
        static_cast<int32_t>(HostPipe[1]),
      };
      std::memcpy(
        GuestPipeDestination,
        GuestDescriptors.data(),
        sizeof(GuestDescriptors));
      OwnedDescriptors.insert(HostPipe[0]);
      OwnedDescriptors.insert(HostPipe[1]);
      if (UsesLowShadow) {
        ++Pipe2LowShadowWriteCount;
      }
      ++Pipe2SuccessCount;
      return 0;
    }
    if (Number == SocketSyscall && !RootFS.empty()) {
      SocketSeen = true;
      ++SocketCallCount;
      constexpr int64_t LinuxAFUnix = 1;
      constexpr int64_t LinuxSocketTypeMask = 0xF;
      constexpr int64_t LinuxSockStream = 1;
      constexpr int64_t LinuxSockNonblock = 0x800;
      constexpr int64_t LinuxSockCloexec = 0x8'0000;
      constexpr int64_t LinuxAllowedFlags = LinuxSockNonblock | LinuxSockCloexec;
      const int64_t Domain = static_cast<int64_t>(Arguments->Argument[1]);
      const int64_t Type = static_cast<int64_t>(Arguments->Argument[2]);
      const int64_t Protocol = static_cast<int64_t>(Arguments->Argument[3]);
      const int64_t BaseType = Type & LinuxSocketTypeMask;
      const int64_t Flags = Type & ~LinuxSocketTypeMask;
      if (Domain != LinuxAFUnix) {
        return static_cast<uint64_t>(-EAFNOSUPPORT);
      }
      if (BaseType != LinuxSockStream || Protocol != 0 || (Flags & ~LinuxAllowedFlags) != 0) {
        return static_cast<uint64_t>(-EPROTONOSUPPORT);
      }

      const int Descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
      if (Descriptor == -1) {
        return static_cast<uint64_t>(-errno);
      }
      const auto CloseWithError = [Descriptor](int HostError) -> uint64_t {
        close(Descriptor);
        return static_cast<uint64_t>(-HostError);
      };
      if ((Flags & LinuxSockNonblock) != 0) {
        const int ExistingFlags = fcntl(Descriptor, F_GETFL);
        if (ExistingFlags == -1 || fcntl(Descriptor, F_SETFL, ExistingFlags | O_NONBLOCK) == -1) {
          return CloseWithError(errno);
        }
      }
      if ((Flags & LinuxSockCloexec) != 0) {
        const int ExistingDescriptorFlags = fcntl(Descriptor, F_GETFD);
        if (ExistingDescriptorFlags == -1
            || fcntl(Descriptor, F_SETFD, ExistingDescriptorFlags | FD_CLOEXEC) == -1) {
          return CloseWithError(errno);
        }
      }
      OwnedDescriptors.insert(Descriptor);
      ++SocketSuccessCount;
      return static_cast<uint64_t>(Descriptor);
    }
    if (Number == SocketPairSyscall && !RootFS.empty()) {
      SocketPairSeen = true;
      ++SocketPairCallCount;
      constexpr int64_t LinuxAFUnix = 1;
      constexpr int64_t LinuxSocketTypeMask = 0xF;
      constexpr int64_t LinuxSockStream = 1;
      constexpr int64_t LinuxSockNonblock = 0x800;
      constexpr int64_t LinuxSockCloexec = 0x8'0000;
      constexpr int64_t LinuxAllowedFlags = LinuxSockNonblock | LinuxSockCloexec;
      const int64_t Domain = static_cast<int64_t>(Arguments->Argument[1]);
      const int64_t Type = static_cast<int64_t>(Arguments->Argument[2]);
      const int64_t Protocol = static_cast<int64_t>(Arguments->Argument[3]);
      const uint64_t GuestPair = Arguments->Argument[4];
      const int64_t BaseType = Type & LinuxSocketTypeMask;
      const int64_t Flags = Type & ~LinuxSocketTypeMask;
      SocketPairLastDomain = Domain;
      SocketPairLastType = Type;
      SocketPairLastProtocol = Protocol;
      SocketPairLastLinuxError = 0;
      if (!Contains(GuestPair, 2 * sizeof(int32_t))) {
        SocketPairLastLinuxError = EFAULT;
        return static_cast<uint64_t>(-EFAULT);
      }
      if (Domain != LinuxAFUnix) {
        SocketPairLastLinuxError = EAFNOSUPPORT;
        return static_cast<uint64_t>(-EAFNOSUPPORT);
      }
      if (BaseType != LinuxSockStream || Protocol != 0
          || (Flags & ~LinuxAllowedFlags) != 0) {
        SocketPairLastLinuxError = EPROTONOSUPPORT;
        return static_cast<uint64_t>(-EPROTONOSUPPORT);
      }

      std::array<int, 2> HostPair {-1, -1};
      if (socketpair(AF_UNIX, SOCK_STREAM, 0, HostPair.data()) != 0) {
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        SocketPairLastLinuxError = LinuxError;
        return static_cast<uint64_t>(-LinuxError);
      }
      const auto ClosePairWithError = [&HostPair](int HostError) -> uint64_t {
        const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
        close(HostPair[0]);
        close(HostPair[1]);
        return static_cast<uint64_t>(-LinuxError);
      };
      for (const int Descriptor : HostPair) {
        if ((Flags & LinuxSockNonblock) != 0) {
          const int ExistingFlags = fcntl(Descriptor, F_GETFL);
          if (ExistingFlags == -1
              || fcntl(Descriptor, F_SETFL, ExistingFlags | O_NONBLOCK) == -1) {
            const int HostError = errno;
            SocketPairLastLinuxError = TranslateHostSocketErrorToLinux(HostError);
            return ClosePairWithError(HostError);
          }
        }
        if ((Flags & LinuxSockCloexec) != 0) {
          const int ExistingDescriptorFlags = fcntl(Descriptor, F_GETFD);
          if (ExistingDescriptorFlags == -1
              || fcntl(Descriptor, F_SETFD, ExistingDescriptorFlags | FD_CLOEXEC) == -1) {
            const int HostError = errno;
            SocketPairLastLinuxError = TranslateHostSocketErrorToLinux(HostError);
            return ClosePairWithError(HostError);
          }
        }
      }

      const std::array<int32_t, 2> GuestDescriptors {
        static_cast<int32_t>(HostPair[0]),
        static_cast<int32_t>(HostPair[1]),
      };
      std::memcpy(
        reinterpret_cast<void*>(GuestPair),
        GuestDescriptors.data(),
        sizeof(GuestDescriptors));
      OwnedDescriptors.insert(HostPair[0]);
      OwnedDescriptors.insert(HostPair[1]);
      ++SocketPairSuccessCount;
      return 0;
    }
    if (Number == ShutdownSyscall && !RootFS.empty()) {
      ShutdownSeen = true;
      ++ShutdownCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const int64_t How = static_cast<int64_t>(Arguments->Argument[2]);
      ShutdownLastDescriptor = Descriptor;
      ShutdownLastHow = How;
      ShutdownLastLinuxError = 0;
      if (!OwnedDescriptors.contains(Descriptor)) {
        ShutdownLastLinuxError = EBADF;
        return static_cast<uint64_t>(-EBADF);
      }
      if (How < SHUT_RD || How > SHUT_RDWR) {
        ShutdownLastLinuxError = EINVAL;
        return static_cast<uint64_t>(-EINVAL);
      }
      if (shutdown(Descriptor, static_cast<int>(How)) != 0) {
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        ShutdownLastLinuxError = LinuxError;
        return static_cast<uint64_t>(-LinuxError);
      }
      ++ShutdownSuccessCount;
      return 0;
    }
    if (Number == BindSyscall && !RootFS.empty()) {
      BindSeen = true;
      ++BindCallCount;
      constexpr uint16_t LinuxAFUnix = 1;
      constexpr uint64_t ObservedAddressLength = 9;
      constexpr std::string_view ObservedSocketName = "socket";
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestAddress = Arguments->Argument[2];
      const uint64_t AddressLength = Arguments->Argument[3];
      BindLastDescriptor = Descriptor;
      BindLastAddressLength = AddressLength;
      BindLastLinuxError = 0;
      BindLastFailureReason = "none";
      BindLastPathClass = "unreadable";
      BindLastHostCWDMatchesGuest = false;
      BindLastEndpointCreated = false;
      if (!OwnedDescriptors.contains(Descriptor)) {
        BindLastLinuxError = EBADF;
        BindLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (AddressLength != ObservedAddressLength
          || !Contains(GuestAddress, AddressLength)) {
        BindLastLinuxError = EFAULT;
        BindLastFailureReason = "unreadable-or-unmeasured-address";
        return static_cast<uint64_t>(-EFAULT);
      }
      uint16_t Family {};
      std::memcpy(&Family, reinterpret_cast<const void*>(GuestAddress), sizeof(Family));
      BindLastFamily = Family;
      if (Family != LinuxAFUnix) {
        BindLastLinuxError = 97;
        BindLastFailureReason = "unsupported-family";
        return static_cast<uint64_t>(-97);
      }
      const auto* Path = reinterpret_cast<const char*>(GuestAddress + sizeof(Family));
      const size_t PayloadLength = static_cast<size_t>(AddressLength - sizeof(Family));
      const auto* Terminator = static_cast<const char*>(
        std::memchr(Path, '\0', PayloadLength));
      if (Terminator == nullptr) {
        BindLastLinuxError = EINVAL;
        BindLastFailureReason = "unterminated-path";
        return static_cast<uint64_t>(-EINVAL);
      }
      const std::string GuestSocketPath {Path, Terminator};
      BindLastPathLength = GuestSocketPath.size();
      BindLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestSocketPath.data()),
        GuestSocketPath.size());
      BindLastPathClass = GuestSocketPath.empty()
        ? "empty"
        : (GuestSocketPath.front() == '/' ? "absolute" : "relative");
      TraceGuestPath("bind", GuestSocketPath);
      if (GuestSocketPath != ObservedSocketName
          || static_cast<size_t>(Terminator - Path + 1) != PayloadLength) {
        BindLastLinuxError = ENOTSUP;
        BindLastFailureReason = "non-wineserver-socket-path";
        return static_cast<uint64_t>(-ENOTSUP);
      }

      const auto ExpectedHostCWD = ResolveGuestPath(".");
      std::array<char, 4096> HostCurrentDirectory {};
      if (!ExpectedHostCWD.has_value()
          || getcwd(HostCurrentDirectory.data(), HostCurrentDirectory.size()) == nullptr
          || std::string_view {HostCurrentDirectory.data()} != *ExpectedHostCWD) {
        BindLastLinuxError = EACCES;
        BindLastFailureReason = "host-cwd-not-mirrored";
        return static_cast<uint64_t>(-EACCES);
      }
      BindLastHostCWDMatchesGuest = true;

      sockaddr_un HostAddress {};
      HostAddress.sun_family = AF_UNIX;
      std::memcpy(
        HostAddress.sun_path,
        GuestSocketPath.c_str(),
        GuestSocketPath.size() + 1);
      const size_t HostAddressLength = offsetof(sockaddr_un, sun_path)
        + GuestSocketPath.size() + 1;
      HostAddress.sun_len = static_cast<uint8_t>(HostAddressLength);
      if (bind(
            Descriptor,
            reinterpret_cast<const sockaddr*>(&HostAddress),
            static_cast<socklen_t>(HostAddressLength)) != 0) {
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        BindLastLinuxError = LinuxError;
        BindLastFailureReason = "host-bind-failed";
        return static_cast<uint64_t>(-LinuxError);
      }
      struct stat EndpointStat {};
      BindLastEndpointCreated = lstat(GuestSocketPath.c_str(), &EndpointStat) == 0
        && S_ISSOCK(EndpointStat.st_mode);
      if (!BindLastEndpointCreated) {
        BindLastLinuxError = EIO;
        BindLastFailureReason = "endpoint-not-created";
        return static_cast<uint64_t>(-EIO);
      }
      ++BindSuccessCount;
      return 0;
    }
    if (Number == ListenSyscall && !RootFS.empty()) {
      ListenSeen = true;
      ++ListenCallCount;
      constexpr int ObservedBacklog = 5;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const int64_t Backlog = static_cast<int64_t>(Arguments->Argument[2]);
      ListenLastDescriptor = Descriptor;
      ListenLastBacklog = Backlog;
      ListenLastLinuxError = 0;
      ListenLastFailureReason = "none";
      if (!OwnedDescriptors.contains(Descriptor)) {
        ListenLastLinuxError = EBADF;
        ListenLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (Backlog != ObservedBacklog) {
        ListenLastLinuxError = EINVAL;
        ListenLastFailureReason = "unmeasured-backlog";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (listen(Descriptor, ObservedBacklog) != 0) {
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        ListenLastLinuxError = LinuxError;
        ListenLastFailureReason = "host-listen-failed";
        return static_cast<uint64_t>(-LinuxError);
      }
      ++ListenSuccessCount;
      return 0;
    }
    if (Number == FutexWaitVSyscall && !RootFS.empty()) {
      FutexWaitVSeen = true;
      ++FutexWaitVCallCount;
      FutexWaitVLastWaiterCount = Arguments->Argument[2];
      FutexWaitVLastFlags = Arguments->Argument[3];
      FutexWaitVLastClockID = static_cast<int64_t>(Arguments->Argument[5]);
      FutexWaitVLastLinuxError = 0;
      FutexWaitVLastFailureReason = "none";
      constexpr int LinuxENOSYS = 38;
      const bool ExactAvailabilityProbe = Arguments->Argument[1] == 0
        && Arguments->Argument[2] == 0
        && Arguments->Argument[3] == 0
        && Arguments->Argument[4] == 0
        && Arguments->Argument[5] == 0;
      if (ExactAvailabilityProbe) {
        ++FutexWaitVAvailabilityProbeCount;
        FutexWaitVLastLinuxError = LinuxENOSYS;
        FutexWaitVLastFailureReason = "host-interface-unavailable";
        return static_cast<uint64_t>(-LinuxENOSYS);
      }
    }
    if (Number == EpollCreateSyscall && !RootFS.empty()) {
      EpollCreateSeen = true;
      ++EpollCreateCallCount;
      constexpr int64_t ObservedSize = 128;
      const int64_t Size = static_cast<int64_t>(Arguments->Argument[1]);
      EpollCreateLastSize = Size;
      EpollCreateLastLinuxError = 0;
      EpollCreateLastFailureReason = "none";
      if (Size != ObservedSize) {
        EpollCreateLastLinuxError = EINVAL;
        EpollCreateLastFailureReason = "unmeasured-size";
        return static_cast<uint64_t>(-EINVAL);
      }
      const int Descriptor = kqueue();
      if (Descriptor == -1) {
        EpollCreateLastLinuxError = errno;
        EpollCreateLastFailureReason = "host-kqueue-failed";
        return static_cast<uint64_t>(-errno);
      }
      OwnedDescriptors.insert(Descriptor);
      EpollDescriptors.insert(Descriptor);
      EpollCreateLastDescriptor = Descriptor;
      ++EpollCreateSuccessCount;
      return static_cast<uint64_t>(Descriptor);
    }
    if (Number == EpollCtlSyscall && !RootFS.empty()) {
      EpollCtlSeen = true;
      ++EpollCtlCallCount;
      constexpr int64_t LinuxEpollCtlAdd = 1;
      constexpr uint32_t LinuxEpollIn = 0x0000'0001;
      constexpr uint32_t LinuxEpollOut = 0x0000'0004;
      const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
      const int64_t Operation = static_cast<int64_t>(Arguments->Argument[2]);
      const int TargetDescriptor = static_cast<int>(Arguments->Argument[3]);
      const uint64_t GuestEvent = Arguments->Argument[4];
      EpollCtlLastEpollDescriptor = EpollDescriptor;
      EpollCtlLastOperation = Operation;
      EpollCtlLastTargetDescriptor = TargetDescriptor;
      EpollCtlLastEventReadable = false;
      EpollCtlLastEvents = 0;
      EpollCtlLastData = 0;
      EpollCtlLastLinuxError = 0;
      EpollCtlLastFailureReason = "none";
      LinuxEpollEvent TracedEvent {};
      const bool TracedEventReadable = Contains(GuestEvent, sizeof(TracedEvent));
      if (TracedEventReadable) {
        std::memcpy(
          &TracedEvent,
          reinterpret_cast<const void*>(GuestEvent),
          sizeof(TracedEvent));
      }
      EpollCtlTraceEntry* TraceEntry {};
      if (EpollCtlTraceCount < EpollCtlTrace.size()) {
        TraceEntry = &EpollCtlTrace[EpollCtlTraceCount++];
        TraceEntry->EpollDescriptor = EpollDescriptor;
        TraceEntry->Operation = static_cast<int32_t>(Operation);
        TraceEntry->TargetDescriptor = TargetDescriptor;
        TraceEntry->EventReadable = TracedEventReadable;
        if (TracedEventReadable) {
          TraceEntry->Events = TracedEvent.Events;
          TraceEntry->Data = TracedEvent.Data;
        }
      }
      if (!EpollDescriptors.contains(EpollDescriptor)) {
        EpollCtlLastLinuxError = EBADF;
        EpollCtlLastFailureReason = "unknown-epoll-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (!OwnedDescriptors.contains(TargetDescriptor)) {
        EpollCtlLastLinuxError = EBADF;
        EpollCtlLastFailureReason = "unowned-target-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (Operation != LinuxEpollCtlAdd) {
        EpollCtlLastLinuxError = EINVAL;
        EpollCtlLastFailureReason = "unmeasured-operation";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!TracedEventReadable) {
        EpollCtlLastLinuxError = EFAULT;
        EpollCtlLastFailureReason = "unreadable-event";
        return static_cast<uint64_t>(-EFAULT);
      }
      const LinuxEpollEvent Event = TracedEvent;
      EpollCtlLastEventReadable = true;
      EpollCtlLastEvents = Event.Events;
      EpollCtlLastData = Event.Data;
      const bool IsReadRegistration = Event.Events == LinuxEpollIn;
      const bool IsWriteRegistration = Event.Events == LinuxEpollOut;
      if (IsWriteRegistration) {
        ++EpollCtlAddWriteCandidateCount;
      }
      if ((!IsReadRegistration && !IsWriteRegistration) ||
          Event.Data > std::numeric_limits<uint32_t>::max()) {
        EpollCtlLastLinuxError = EINVAL;
        EpollCtlLastFailureReason = "unmeasured-event-shape";
        return static_cast<uint64_t>(-EINVAL);
      }
      struct kevent Change {};
      EV_SET(
        &Change,
        static_cast<uintptr_t>(TargetDescriptor),
        IsWriteRegistration ? EVFILT_WRITE : EVFILT_READ,
        EV_ADD | EV_ENABLE,
        0,
        0,
        reinterpret_cast<void*>(static_cast<uintptr_t>(Event.Data)));
      if (kevent(EpollDescriptor, &Change, 1, nullptr, 0, nullptr) == -1) {
        EpollCtlLastLinuxError = errno;
        EpollCtlLastFailureReason = "host-kevent-add-failed";
        return static_cast<uint64_t>(-errno);
      }
      ++EpollCtlSuccessCount;
      if (IsWriteRegistration) {
        ++EpollCtlAddWriteSuccessCount;
      }
      return 0;
    }
    if (Number == EpollPWait2Syscall && !RootFS.empty()) {
      EpollPWait2Seen = true;
      ++EpollPWait2CallCount;
      constexpr int LinuxENOSYS = 38;
      constexpr int64_t ObservedMaxEvents = 128;
      constexpr int64_t ObservedTimeoutSeconds = 0;
      constexpr int64_t ObservedTimeoutNanoseconds = 16'000'000;
      constexpr uint64_t ObservedSignalSetSize = 8;
      const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestEvents = Arguments->Argument[2];
      const int64_t MaxEvents = static_cast<int64_t>(Arguments->Argument[3]);
      const uint64_t GuestTimeout = Arguments->Argument[4];
      const uint64_t GuestSignalMask = Arguments->Argument[5];
      const uint64_t SignalSetSize = Arguments->Argument[6];
      EpollPWait2LastDescriptor = EpollDescriptor;
      EpollPWait2LastDescriptorKnown = EpollDescriptors.contains(EpollDescriptor);
      EpollPWait2LastMaxEvents = MaxEvents;
      EpollPWait2LastLinuxError = 0;
      EpollPWait2LastFailureReason = "none";
      const bool EventSpanValid = MaxEvents > 0
        && MaxEvents <= 4096
        && static_cast<uint64_t>(MaxEvents)
          <= std::numeric_limits<uint64_t>::max() / sizeof(LinuxEpollEvent);
      const uint64_t EventSpan = EventSpanValid
        ? static_cast<uint64_t>(MaxEvents) * sizeof(LinuxEpollEvent)
        : 0;
      EpollPWait2LastEventsClass = GuestEvents == 0
        ? "zero"
        : (EventSpanValid && Contains(GuestEvents, EventSpan)
            ? "guest-memory-full-span"
            : (Contains(GuestEvents, sizeof(LinuxEpollEvent))
                ? "guest-memory-first-event"
                : "scalar-or-outside"));
      EpollPWait2LastTimeoutClass = GuestTimeout == 0
        ? "zero"
        : (Contains(GuestTimeout, sizeof(LinuxTimespec64))
            ? "guest-memory"
            : "scalar-or-outside");
      LinuxTimespec64 Timeout {};
      if (Contains(GuestTimeout, sizeof(Timeout))) {
        std::memcpy(&Timeout, reinterpret_cast<const void*>(GuestTimeout), sizeof(Timeout));
        EpollPWait2LastTimeoutReadable = true;
        EpollPWait2LastTimeoutSeconds = Timeout.Seconds;
        EpollPWait2LastTimeoutNanoseconds = Timeout.Nanoseconds;
      }
      EpollPWait2LastSignalSetSize = SignalSetSize;
      EpollPWait2LastSignalMaskClass = GuestSignalMask == 0
        ? "zero"
        : (SignalSetSize > 0 && SignalSetSize <= 128
            && Contains(GuestSignalMask, SignalSetSize)
              ? "guest-memory"
              : "scalar-or-outside");
      if (!EpollPWait2LastDescriptorKnown) {
        EpollPWait2LastLinuxError = EBADF;
        EpollPWait2LastFailureReason = "unknown-epoll-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (MaxEvents != ObservedMaxEvents) {
        EpollPWait2LastLinuxError = EINVAL;
        EpollPWait2LastFailureReason = "unmeasured-max-events";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!EventSpanValid || !Contains(GuestEvents, EventSpan)) {
        EpollPWait2LastLinuxError = EFAULT;
        EpollPWait2LastFailureReason = "unreadable-events";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (!EpollPWait2LastTimeoutReadable) {
        EpollPWait2LastLinuxError = EFAULT;
        EpollPWait2LastFailureReason = "unreadable-timeout";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (!IsValidLinuxTimespec(Timeout)
          || Timeout.Seconds != ObservedTimeoutSeconds
          || Timeout.Nanoseconds != ObservedTimeoutNanoseconds) {
        EpollPWait2LastLinuxError = EINVAL;
        EpollPWait2LastFailureReason = "unmeasured-timeout";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (GuestSignalMask != 0 || SignalSetSize != ObservedSignalSetSize) {
        EpollPWait2LastLinuxError = EINVAL;
        EpollPWait2LastFailureReason = "unmeasured-signal-mask";
        return static_cast<uint64_t>(-EINVAL);
      }
      ++EpollPWait2HostUnavailableFallbackCount;
      EpollPWait2LastLinuxError = LinuxENOSYS;
      EpollPWait2LastFailureReason = "host-interface-unavailable";
      return static_cast<uint64_t>(-LinuxENOSYS);
    }
    if (Number == EpollWaitSyscall && !RootFS.empty()) {
      EpollWaitSeen = true;
      ++EpollWaitCallCount;
      constexpr int64_t ObservedMaxEvents = 128;
      constexpr int64_t ObservedTimedTimeoutMilliseconds = 16;
      constexpr int64_t ObservedPollingTimeoutMilliseconds = 0;
      constexpr uint32_t LinuxEpollIn = 0x0000'0001;
      constexpr uint32_t LinuxEpollOut = 0x0000'0004;
      constexpr uint32_t LinuxEpollError = 0x0000'0008;
      constexpr uint32_t LinuxEpollHangup = 0x0000'0010;
      const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestEvents = Arguments->Argument[2];
      const int64_t MaxEvents = static_cast<int64_t>(Arguments->Argument[3]);
      const int64_t TimeoutMilliseconds = static_cast<int32_t>(Arguments->Argument[4]);
      EpollWaitLastDescriptor = EpollDescriptor;
      EpollWaitLastDescriptorKnown = EpollDescriptors.contains(EpollDescriptor);
      EpollWaitLastMaxEvents = MaxEvents;
      EpollWaitLastTimeout = TimeoutMilliseconds;
      EpollWaitLastLinuxError = 0;
      EpollWaitLastFailureReason = "none";
      const bool IsTimedWait = TimeoutMilliseconds == ObservedTimedTimeoutMilliseconds;
      const bool IsPollingWait = TimeoutMilliseconds == ObservedPollingTimeoutMilliseconds;
      if (IsTimedWait) {
        ++EpollWaitTimedCallCount;
      } else if (IsPollingWait) {
        ++EpollWaitPollingCallCount;
      }
      const bool EventSpanValid = MaxEvents > 0
        && MaxEvents <= 4096
        && static_cast<uint64_t>(MaxEvents)
          <= std::numeric_limits<uint64_t>::max() / sizeof(LinuxEpollEvent);
      const uint64_t EventSpan = EventSpanValid
        ? static_cast<uint64_t>(MaxEvents) * sizeof(LinuxEpollEvent)
        : 0;
      EpollWaitLastEventsClass = GuestEvents == 0
        ? "zero"
        : (EventSpanValid && Contains(GuestEvents, EventSpan)
            ? "guest-memory-full-span"
            : (Contains(GuestEvents, sizeof(LinuxEpollEvent))
                ? "guest-memory-first-event"
                : "scalar-or-outside"));
      if (!EpollWaitLastDescriptorKnown) {
        EpollWaitLastLinuxError = EBADF;
        EpollWaitLastFailureReason = "unknown-epoll-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (MaxEvents != ObservedMaxEvents) {
        EpollWaitLastLinuxError = EINVAL;
        EpollWaitLastFailureReason = "unmeasured-max-events";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!EventSpanValid || !Contains(GuestEvents, EventSpan)) {
        EpollWaitLastLinuxError = EFAULT;
        EpollWaitLastFailureReason = "unreadable-events";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (!IsTimedWait && !IsPollingWait) {
        EpollWaitLastLinuxError = EINVAL;
        EpollWaitLastFailureReason = "unmeasured-timeout";
        return static_cast<uint64_t>(-EINVAL);
      }
      std::array<struct kevent, ObservedMaxEvents> HostEvents {};
      const timespec HostTimeout {
        .tv_sec = 0,
        .tv_nsec = TimeoutMilliseconds * 1'000'000,
      };
      const int Result = kevent(
        EpollDescriptor,
        nullptr,
        0,
        HostEvents.data(),
        static_cast<int>(HostEvents.size()),
        &HostTimeout);
      if (Result == -1) {
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        EpollWaitLastLinuxError = LinuxError;
        EpollWaitLastFailureReason = "host-kevent-wait-failed";
        return static_cast<uint64_t>(-LinuxError);
      }
      for (int Index = 0; Index < Result; ++Index) {
        const auto& HostEvent = HostEvents[static_cast<size_t>(Index)];
        LinuxEpollEvent GuestEvent {};
        if (HostEvent.filter == EVFILT_READ) {
          GuestEvent.Events |= LinuxEpollIn;
        } else if (HostEvent.filter == EVFILT_WRITE) {
          GuestEvent.Events |= LinuxEpollOut;
        } else {
          EpollWaitLastLinuxError = EIO;
          EpollWaitLastFailureReason = "unsupported-host-filter";
          return static_cast<uint64_t>(-EIO);
        }
        if ((HostEvent.flags & EV_ERROR) != 0) {
          GuestEvent.Events |= LinuxEpollError;
        }
        if ((HostEvent.flags & EV_EOF) != 0) {
          GuestEvent.Events |= LinuxEpollHangup;
        }
        GuestEvent.Data = reinterpret_cast<uintptr_t>(HostEvent.udata);
        std::memcpy(
          reinterpret_cast<void*>(GuestEvents + static_cast<uint64_t>(Index) * sizeof(GuestEvent)),
          &GuestEvent,
          sizeof(GuestEvent));
      }
      ++EpollWaitSuccessCount;
      EpollWaitReturnedEventCount += static_cast<uint64_t>(Result);
      if (IsTimedWait) {
        ++EpollWaitTimedSuccessCount;
        EpollWaitTimedReturnedEventCount += static_cast<uint64_t>(Result);
      } else {
        ++EpollWaitPollingSuccessCount;
        EpollWaitPollingReturnedEventCount += static_cast<uint64_t>(Result);
      }
      if (Result == 0) {
        ++EpollWaitTimeoutCount;
      }
      return static_cast<uint64_t>(Result);
    }
    if (Number == GettimeofdaySyscall && !RootFS.empty()) {
      GettimeofdaySeen = true;
      ++GettimeofdayCallCount;
      const uint64_t GuestTime = Arguments->Argument[1];
      const uint64_t GuestTimezone = Arguments->Argument[2];
      GettimeofdayLastLinuxError = 0;
      GettimeofdayLastFailureReason = "none";
      if (!Contains(GuestTime, sizeof(LinuxTimeval64))) {
        GettimeofdayLastLinuxError = EFAULT;
        GettimeofdayLastFailureReason = "unreadable-timeval";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (GuestTimezone != 0) {
        GettimeofdayLastLinuxError = EINVAL;
        GettimeofdayLastFailureReason = "unmeasured-timezone-output";
        return static_cast<uint64_t>(-EINVAL);
      }
      timeval HostTime {};
      if (gettimeofday(&HostTime, nullptr) != 0) {
        GettimeofdayLastLinuxError = errno;
        GettimeofdayLastFailureReason = "host-gettimeofday-failed";
        return static_cast<uint64_t>(-errno);
      }
      const LinuxTimeval64 GuestResult {
        .Seconds = HostTime.tv_sec,
        .Microseconds = HostTime.tv_usec,
      };
      std::memcpy(
        reinterpret_cast<void*>(GuestTime),
        &GuestResult,
        sizeof(GuestResult));
      GettimeofdayLastSeconds = GuestResult.Seconds;
      GettimeofdayLastMicroseconds = GuestResult.Microseconds;
      ++GettimeofdaySuccessCount;
      return 0;
    }
    if (Number == SysinfoSyscall && !RootFS.empty()) {
      SysinfoSeen = true;
      ++SysinfoCallCount;
      const uint64_t GuestBuffer = Arguments->Argument[1];
      void* HostBuffer = nullptr;
      SysinfoLastBufferClass = "scalar-or-outside";
      if (Contains(GuestBuffer, sizeof(LinuxX86_64Sysinfo))) {
        HostBuffer = reinterpret_cast<void*>(GuestBuffer);
        SysinfoLastBufferClass = "guest-memory";
      } else if (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr) {
        HostBuffer = LowGuestShadow->HostPointerForMappedLogicalRange(
          GuestBuffer,
          sizeof(LinuxX86_64Sysinfo),
          PROT_WRITE);
        if (HostBuffer != nullptr) {
          SysinfoLastBufferClass = "low-shadow";
        }
      }
      if (HostBuffer == nullptr && HighMemoryRegionModeEnabled && HighGuestSparse != nullptr) {
        HostBuffer = HighGuestSparse->HostPointerForMappedLogicalRange(
          GuestBuffer,
          sizeof(LinuxX86_64Sysinfo),
          PROT_WRITE);
        if (HostBuffer != nullptr) {
          SysinfoLastBufferClass = "high-sparse";
        }
      }
      if (HostBuffer == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }

      timespec HostUptime {};
      if (clock_gettime(CLOCK_MONOTONIC, &HostUptime) != 0) {
        return static_cast<uint64_t>(-errno);
      }

      uint64_t TotalMemory {};
      size_t TotalMemorySize = sizeof(TotalMemory);
      if (sysctlbyname("hw.memsize", &TotalMemory, &TotalMemorySize, nullptr, 0) != 0
          || TotalMemorySize != sizeof(TotalMemory) || TotalMemory == 0) {
        return static_cast<uint64_t>(-EIO);
      }

      uint64_t FreeMemory {};
      const mach_port_t HostPort = mach_host_self();
      vm_size_t HostPageSize {};
      vm_statistics64_data_t HostVMStatistics {};
      mach_msg_type_number_t HostVMStatisticsCount = HOST_VM_INFO64_COUNT;
      const kern_return_t PageSizeResult = host_page_size(HostPort, &HostPageSize);
      const kern_return_t StatisticsResult = host_statistics64(
        HostPort,
        HOST_VM_INFO64,
        reinterpret_cast<host_info64_t>(&HostVMStatistics),
        &HostVMStatisticsCount);
      mach_port_deallocate(mach_task_self(), HostPort);
      if (PageSizeResult == KERN_SUCCESS && StatisticsResult == KERN_SUCCESS) {
        const uint64_t AvailablePages = static_cast<uint64_t>(HostVMStatistics.free_count)
          + static_cast<uint64_t>(HostVMStatistics.inactive_count);
        if (HostPageSize != 0
            && AvailablePages <= std::numeric_limits<uint64_t>::max() / HostPageSize) {
          FreeMemory = std::min(TotalMemory, AvailablePages * HostPageSize);
        }
      }

      LinuxX86_64Sysinfo GuestInfo {};
      GuestInfo.Uptime = HostUptime.tv_sec;
      std::array<double, 3> HostLoads {};
      const int LoadCount = getloadavg(HostLoads.data(), static_cast<int>(HostLoads.size()));
      constexpr double LinuxLoadScale = double {1ULL << 16};
      for (size_t Index = 0; Index < GuestInfo.Loads.size(); ++Index) {
        if (LoadCount > static_cast<int>(Index) && HostLoads[Index] > 0) {
          const double ScaledLoad = HostLoads[Index] * LinuxLoadScale;
          GuestInfo.Loads[Index] = ScaledLoad
              >= static_cast<double>(std::numeric_limits<uint64_t>::max())
            ? std::numeric_limits<uint64_t>::max()
            : static_cast<uint64_t>(ScaledLoad);
        }
      }
      GuestInfo.TotalRAM = TotalMemory;
      GuestInfo.FreeRAM = FreeMemory;
      GuestInfo.Processes = 1;
      GuestInfo.MemoryUnit = 1;
      std::memcpy(HostBuffer, &GuestInfo, sizeof(GuestInfo));
      SysinfoLastUptime = static_cast<uint64_t>(GuestInfo.Uptime);
      SysinfoLastTotalRAM = GuestInfo.TotalRAM;
      SysinfoLastFreeRAM = GuestInfo.FreeRAM;
      SysinfoLastMemoryUnit = GuestInfo.MemoryUnit;
      ++SysinfoSuccessCount;
      return 0;
    }
    if (Number == TimeSyscall && !RootFS.empty()) {
      TimeSeen = true;
      ++TimeCallCount;
      const uint64_t GuestOutput = Arguments->Argument[1];
      TimeLastLinuxError = 0;
      TimeLastFailureReason = "none";
      if (GuestOutput != 0) {
        TimeLastLinuxError = EINVAL;
        TimeLastFailureReason = "unmeasured-output-pointer";
        return static_cast<uint64_t>(-EINVAL);
      }
      ++TimeNullPointerCallCount;
      const time_t HostTime = time(nullptr);
      if (HostTime == static_cast<time_t>(-1)) {
        TimeLastLinuxError = errno;
        TimeLastFailureReason = "host-time-failed";
        return static_cast<uint64_t>(-errno);
      }
      TimeLastSeconds = static_cast<int64_t>(HostTime);
      ++TimeSuccessCount;
      return static_cast<uint64_t>(TimeLastSeconds);
    }
    if (Number == FStatFSSyscall && !RootFS.empty()) {
      FStatFSSeen = true;
      ++FStatFSCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      FStatFSLastDescriptor = Descriptor;
      FStatFSLastLinuxError = 0;
      FStatFSLastFailureReason = "none";
      if (!OwnedDescriptors.contains(Descriptor)) {
        FStatFSLastLinuxError = EBADF;
        FStatFSLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(GuestBuffer, sizeof(LinuxX86_64StatFS))) {
        FStatFSLastLinuxError = EFAULT;
        FStatFSLastFailureReason = "unreadable-buffer";
        return static_cast<uint64_t>(-EFAULT);
      }
      struct statfs HostStat {};
      if (fstatfs(Descriptor, &HostStat) != 0) {
        FStatFSLastLinuxError = errno;
        FStatFSLastFailureReason = "host-fstatfs-failed";
        return static_cast<uint64_t>(-errno);
      }
      constexpr int64_t LinuxExtFileSystemMagic = 0xEF53;
      LinuxX86_64StatFS GuestStat {
        .Type = LinuxExtFileSystemMagic,
        .BlockSize = static_cast<int64_t>(HostStat.f_bsize),
        .Blocks = static_cast<uint64_t>(HostStat.f_blocks),
        .BlocksFree = static_cast<uint64_t>(HostStat.f_bfree),
        .BlocksAvailable = static_cast<uint64_t>(HostStat.f_bavail),
        .Files = static_cast<uint64_t>(HostStat.f_files),
        .FilesFree = static_cast<uint64_t>(HostStat.f_ffree),
        .FileSystemID = {HostStat.f_fsid.val[0], HostStat.f_fsid.val[1]},
        .NameLength = NAME_MAX,
        .FragmentSize = static_cast<int64_t>(HostStat.f_bsize),
        .Flags = 0,
      };
      std::memcpy(
        reinterpret_cast<void*>(GuestBuffer),
        &GuestStat,
        sizeof(GuestStat));
      FStatFSLastType = GuestStat.Type;
      ++FStatFSSuccessCount;
      return 0;
    }
    if (Number == FAccessAt2Syscall && !RootFS.empty()) {
      FAccessAt2Seen = true;
      ++FAccessAt2CallCount;
      constexpr uint64_t LinuxAtEffectiveAccess = 0x200;
      const int32_t DirectoryDescriptor = static_cast<int32_t>(Arguments->Argument[1]);
      const auto GuestPath = ReadGuestPath(Arguments->Argument[2]);
      const uint64_t Mode = Arguments->Argument[3];
      const uint64_t Flags = Arguments->Argument[4];
      FAccessAt2LastDirectoryDescriptor = DirectoryDescriptor;
      FAccessAt2LastMode = Mode;
      FAccessAt2LastFlags = Flags;
      FAccessAt2LastLinuxError = 0;
      FAccessAt2LastFailureReason = "none";
      if (!GuestPath.has_value()) {
        FAccessAt2LastLinuxError = EFAULT;
        FAccessAt2LastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (DirectoryDescriptor != LinuxAtFDCWD || Mode != F_OK
          || Flags != LinuxAtEffectiveAccess) {
        FAccessAt2LastLinuxError = EINVAL;
        FAccessAt2LastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-EINVAL);
      }
      const auto HostPath = ResolveGuestPathWithParents(*GuestPath);
      if (!HostPath.has_value()) {
        FAccessAt2LastLinuxError = EACCES;
        FAccessAt2LastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      if (access(HostPath->c_str(), F_OK) != 0) {
        FAccessAt2LastLinuxError = errno;
        FAccessAt2LastFailureReason = "host-access-failed";
        return static_cast<uint64_t>(-errno);
      }
      ++FAccessAt2SuccessCount;
      return 0;
    }
    if (Number == MemfdCreateSyscall && !RootFS.empty()) {
      MemfdCreateSeen = true;
      ++MemfdCreateCallCount;
      constexpr uint64_t LinuxMFDExec = 0x10;
      const auto GuestName = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t Flags = Arguments->Argument[2];
      MemfdCreateLastFlags = Flags;
      MemfdCreateLastLinuxError = 0;
      MemfdCreateLastFailureReason = "none";
      MemfdCreateBackingUnlinked = false;
      MemfdCreateLastDescriptor = -1;
      if (!GuestName.has_value()) {
        MemfdCreateLastLinuxError = EFAULT;
        MemfdCreateLastFailureReason = "unreadable-name";
        return static_cast<uint64_t>(-EFAULT);
      }
      MemfdCreateLastNameLength = GuestName->size();
      MemfdCreateLastNameFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestName->data()),
        GuestName->size());
      if (*GuestName != "wine-mapping" || Flags != LinuxMFDExec) {
        MemfdCreateLastLinuxError = EINVAL;
        MemfdCreateLastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-EINVAL);
      }
      const auto HostTemplate = ResolveGuestCreationPath(".wine-mapping-XXXXXX");
      if (!HostTemplate.has_value()) {
        MemfdCreateLastLinuxError = EACCES;
        MemfdCreateLastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      std::vector<char> MutableTemplate(HostTemplate->begin(), HostTemplate->end());
      MutableTemplate.push_back('\0');
      const int Descriptor = mkstemp(MutableTemplate.data());
      if (Descriptor == -1) {
        MemfdCreateLastLinuxError = errno;
        MemfdCreateLastFailureReason = "host-mkstemp-failed";
        return static_cast<uint64_t>(-errno);
      }
      if (unlink(MutableTemplate.data()) != 0) {
        const int UnlinkError = errno;
        close(Descriptor);
        MemfdCreateLastLinuxError = UnlinkError;
        MemfdCreateLastFailureReason = "host-unlink-failed";
        return static_cast<uint64_t>(-UnlinkError);
      }
      OwnedDescriptors.insert(Descriptor);
      MemfdCreateBackingUnlinked = true;
      MemfdCreateLastDescriptor = Descriptor;
      ++MemfdCreateSuccessCount;
      return static_cast<uint64_t>(Descriptor);
    }
    if (Number == PWrite64Syscall && !RootFS.empty()) {
      PWrite64Seen = true;
      ++PWrite64CallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      const uint64_t ByteCount = Arguments->Argument[3];
      const uint64_t Offset = Arguments->Argument[4];
      PWrite64LastDescriptor = Descriptor;
      PWrite64LastByteCount = ByteCount;
      PWrite64LastOffset = Offset;
      PWrite64LastLinuxError = 0;
      PWrite64LastFailureReason = "none";
      if (!OwnedDescriptors.contains(Descriptor)) {
        PWrite64LastLinuxError = EBADF;
        PWrite64LastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      const bool IsMeasuredGrowFileOffset =
        Offset == LinuxSharedUserDataSize || Offset == ObservedWineSessionMappingSize;
      if (Descriptor != MemfdCreateLastDescriptor ||
          ByteCount != 1 ||
          !IsMeasuredGrowFileOffset) {
        PWrite64LastLinuxError = EINVAL;
        PWrite64LastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!Contains(GuestBuffer, ByteCount)) {
        PWrite64LastLinuxError = EFAULT;
        PWrite64LastFailureReason = "unreadable-buffer";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (*reinterpret_cast<const uint8_t*>(GuestBuffer) != 0) {
        PWrite64LastLinuxError = EINVAL;
        PWrite64LastFailureReason = "unexpected-buffer-content";
        return static_cast<uint64_t>(-EINVAL);
      }
      const ssize_t Written = pwrite(
        Descriptor,
        reinterpret_cast<const void*>(GuestBuffer),
        static_cast<size_t>(ByteCount),
        static_cast<off_t>(Offset));
      if (Written == -1) {
        PWrite64LastLinuxError = errno;
        PWrite64LastFailureReason = "host-pwrite-failed";
        return static_cast<uint64_t>(-errno);
      }
      if (Written != static_cast<ssize_t>(ByteCount)) {
        PWrite64LastLinuxError = EIO;
        PWrite64LastFailureReason = "short-write";
        return static_cast<uint64_t>(-EIO);
      }
      ++PWrite64SuccessCount;
      PWrite64WrittenByteCount += static_cast<uint64_t>(Written);
      if (Offset == ObservedWineSessionMappingSize) {
        SessionMappingWriteCompleted = true;
      }
      return static_cast<uint64_t>(Written);
    }
    if (Number == FTruncateSyscall && !RootFS.empty()) {
      FTruncateSeen = true;
      ++FTruncateCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Length = Arguments->Argument[2];
      FTruncateLastDescriptor = Descriptor;
      FTruncateLastLength = Length;
      FTruncateLastLinuxError = 0;
      FTruncateLastFailureReason = "none";
      if (!OwnedDescriptors.contains(Descriptor)) {
        FTruncateLastLinuxError = EBADF;
        FTruncateLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      const bool IsMeasuredGrowFileLength =
        Length == LinuxSharedUserDataSize || Length == ObservedWineSessionMappingSize;
      if (Descriptor != MemfdCreateLastDescriptor || !IsMeasuredGrowFileLength) {
        FTruncateLastLinuxError = EINVAL;
        FTruncateLastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-EINVAL);
      }
      if (ftruncate(Descriptor, static_cast<off_t>(Length)) != 0) {
        FTruncateLastLinuxError = errno;
        FTruncateLastFailureReason = "host-ftruncate-failed";
        return static_cast<uint64_t>(-errno);
      }
      ++FTruncateSuccessCount;
      return 0;
    }
    if (Number == FChdirSyscall && !RootFS.empty()) {
      FChdirSeen = true;
      ++FChdirCallCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      FChdirLastDescriptor = Descriptor;
      FChdirLastTargetDirectory = false;
      FChdirLastTargetConfined = false;
      FChdirLastHostCWDMatchesGuest = false;
      FChdirLastLinuxError = 0;
      FChdirLastFailureReason = "none";
      if (!OwnedDescriptors.contains(Descriptor)) {
        FChdirLastLinuxError = EBADF;
        FChdirLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      struct stat DescriptorStat {};
      if (fstat(Descriptor, &DescriptorStat) != 0) {
        FChdirLastLinuxError = errno;
        FChdirLastFailureReason = "host-fstat-failed";
        return static_cast<uint64_t>(-errno);
      }
      FChdirLastTargetDirectory = S_ISDIR(DescriptorStat.st_mode);
      if (!FChdirLastTargetDirectory) {
        FChdirLastLinuxError = ENOTDIR;
        FChdirLastFailureReason = "descriptor-not-directory";
        return static_cast<uint64_t>(-ENOTDIR);
      }
      std::array<char, 4096> DescriptorPath {};
      if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) != 0) {
        FChdirLastLinuxError = errno;
        FChdirLastFailureReason = "host-f-getpath-failed";
        return static_cast<uint64_t>(-errno);
      }
      const std::string HostPath {DescriptorPath.data()};
      FChdirLastPathLength = HostPath.size();
      FChdirLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(HostPath.data()),
        HostPath.size());
      FChdirLastTargetConfined = HostPath == RootFS || HostPath.starts_with(RootFS + '/');
      if (!FChdirLastTargetConfined) {
        FChdirLastLinuxError = EACCES;
        FChdirLastFailureReason = "descriptor-path-outside-rootfs";
        return static_cast<uint64_t>(-EACCES);
      }
      if (fchdir(Descriptor) != 0) {
        FChdirLastLinuxError = errno;
        FChdirLastFailureReason = "host-fchdir-failed";
        return static_cast<uint64_t>(-errno);
      }
      const std::string GuestPath = HostPath == RootFS
        ? "/"
        : HostPath.substr(RootFS.size());
      GuestCurrentWorkingDirectory = GuestPath;
      std::array<char, 4096> HostCurrentWorkingDirectory {};
      FChdirLastHostCWDMatchesGuest = getcwd(
        HostCurrentWorkingDirectory.data(),
        HostCurrentWorkingDirectory.size()) != nullptr
        && HostPath == HostCurrentWorkingDirectory.data();
      if (!FChdirLastHostCWDMatchesGuest) {
        FChdirLastLinuxError = EIO;
        FChdirLastFailureReason = "host-cwd-mismatch";
        return static_cast<uint64_t>(-EIO);
      }
      ++FChdirSuccessCount;
      return 0;
    }
    if (Number == ConnectSyscall && !RootFS.empty()) {
      ConnectSeen = true;
      ++ConnectCallCount;
      constexpr uint16_t LinuxAFUnix = 1;
      constexpr uint64_t LinuxSockaddrUnMaximum = 110;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestAddress = Arguments->Argument[2];
      const uint64_t AddressLength = Arguments->Argument[3];
      ConnectLastDescriptor = Descriptor;
      ConnectLastAddressLength = AddressLength;
      ConnectLastFamily = 0;
      ConnectLastPayloadLength = 0;
      ConnectLastPathLength = 0;
      ConnectLastPathFingerprint = 0;
      ConnectLastHostPathLength = 0;
      ConnectLastHostError = 0;
      ConnectLastAltLoaderMapped = false;
      ConnectLastPathClass = ConnectPathClass::None;
      ConnectLastFailureReason = ConnectFailureReason::None;
      if (!OwnedDescriptors.contains(Descriptor)) {
        ConnectLastLinuxError = EBADF;
        ConnectLastFailureReason = ConnectFailureReason::UnownedDescriptor;
        return static_cast<uint64_t>(-EBADF);
      }
      if (AddressLength < sizeof(uint16_t) || AddressLength > LinuxSockaddrUnMaximum
          || !Contains(GuestAddress, AddressLength)) {
        ConnectLastLinuxError = EFAULT;
        ConnectLastFailureReason = ConnectFailureReason::UnreadableAddress;
        return static_cast<uint64_t>(-EFAULT);
      }

      uint16_t Family {};
      std::memcpy(&Family, reinterpret_cast<const void*>(GuestAddress), sizeof(Family));
      ConnectLastFamily = Family;
      if (Family != LinuxAFUnix) {
        ConnectLastLinuxError = 97;
        ConnectLastFailureReason = ConnectFailureReason::UnsupportedFamily;
        return static_cast<uint64_t>(-97);
      }
      const auto* Path = reinterpret_cast<const char*>(GuestAddress + sizeof(Family));
      const size_t PayloadLength = static_cast<size_t>(AddressLength - sizeof(Family));
      ConnectLastPayloadLength = PayloadLength;
      if (PayloadLength == 0) {
        ConnectLastLinuxError = 95;
        ConnectLastPathClass = ConnectPathClass::Empty;
        ConnectLastFailureReason = ConnectFailureReason::EmptyPayload;
        return static_cast<uint64_t>(-95);
      }
      ConnectLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(Path), PayloadLength);
      if (Path[0] == '\0') {
        ConnectLastLinuxError = 95;
        ConnectLastPathClass = ConnectPathClass::Abstract;
        ConnectLastPathLength = PayloadLength;
        ConnectLastFailureReason = ConnectFailureReason::AbstractPath;
        return static_cast<uint64_t>(-95);
      }
      const auto* Terminator = static_cast<const char*>(std::memchr(Path, '\0', PayloadLength));
      const size_t PathLength = Terminator == nullptr
        ? PayloadLength
        : static_cast<size_t>(Terminator - Path);
      ConnectLastPathLength = PathLength;
      ConnectLastPathClass = PathLength == 0
        ? ConnectPathClass::Empty
        : (Path[0] == '/' ? ConnectPathClass::Absolute : ConnectPathClass::Relative);
      const std::string GuestSocketPath {Path, PathLength};
      TraceGuestPath("connect", GuestSocketPath);
      if (GuestSocketPath.empty()) {
        ConnectLastLinuxError = EINVAL;
        ConnectLastFailureReason = ConnectFailureReason::EmptyPath;
        return static_cast<uint64_t>(-EINVAL);
      }
      const bool ExactAltLoaderSocket = !CXAltLoaderGuestSocketPath.empty()
        && !CXAltLoaderHostSocketPath.empty()
        && GuestSocketPath == CXAltLoaderGuestSocketPath;
      std::string HostPath;
      if (ExactAltLoaderSocket) {
        HostPath = CXAltLoaderHostSocketPath;
        ++ConnectAltLoaderMappedCount;
        ConnectLastAltLoaderMapped = true;
      } else {
        const auto ResolvedHostPath = ResolveGuestPath(GuestSocketPath);
        if (!ResolvedHostPath.has_value()) {
          ConnectLastLinuxError = EACCES;
          ConnectLastFailureReason = ConnectFailureReason::PathResolutionRejected;
          return static_cast<uint64_t>(-EACCES);
        }
        HostPath = *ResolvedHostPath;
        ++ConnectRootFSConfinedCount;
      }
      ConnectLastHostPathLength = HostPath.size();

      const bool RelativePath = GuestSocketPath.front() != '/';
      if (RelativePath) {
        const auto ExpectedHostCWD = ResolveGuestPath(".");
        std::array<char, 4096> HostCurrentDirectory {};
        if (!ExpectedHostCWD.has_value()
            || getcwd(HostCurrentDirectory.data(), HostCurrentDirectory.size()) == nullptr
            || std::string_view {HostCurrentDirectory.data()} != *ExpectedHostCWD) {
          ConnectLastLinuxError = EACCES;
          ConnectLastFailureReason = ConnectFailureReason::HostCWDNotMirrored;
          return static_cast<uint64_t>(-EACCES);
        }
      }

      struct stat HostStat {};
      if (lstat(HostPath.c_str(), &HostStat) != 0) {
        ConnectLastHostError = errno;
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        if (LinuxError == ENOENT) {
          ++ConnectMissingTargetCount;
        }
        ConnectLastLinuxError = LinuxError;
        ConnectLastFailureReason = ConnectFailureReason::MissingTarget;
        return static_cast<uint64_t>(-LinuxError);
      }
      if (!S_ISSOCK(HostStat.st_mode)) {
        ConnectLastLinuxError = 111;
        ConnectLastFailureReason = ConnectFailureReason::TargetNotSocket;
        return static_cast<uint64_t>(-111);
      }
      const std::string HostSocketAddressPath = ExactAltLoaderSocket
        ? HostPath
        : (RelativePath ? GuestSocketPath : HostPath);
      if (HostSocketAddressPath.size() >= sizeof(sockaddr_un::sun_path)) {
        ConnectLastLinuxError = 36;
        ConnectLastFailureReason = ConnectFailureReason::HostPathTooLong;
        return static_cast<uint64_t>(-36);
      }

      sockaddr_un HostAddress {};
      HostAddress.sun_family = AF_UNIX;
      std::memcpy(
        HostAddress.sun_path,
        HostSocketAddressPath.data(),
        HostSocketAddressPath.size());
      HostAddress.sun_path[HostSocketAddressPath.size()] = '\0';
      const size_t HostAddressLength = offsetof(sockaddr_un, sun_path)
        + HostSocketAddressPath.size() + 1;
      HostAddress.sun_len = static_cast<uint8_t>(HostAddressLength);
      if (connect(Descriptor, reinterpret_cast<const sockaddr*>(&HostAddress),
                  static_cast<socklen_t>(HostAddressLength)) != 0) {
        ConnectLastHostError = errno;
        const int LinuxError = TranslateHostSocketErrorToLinux(errno);
        ConnectLastLinuxError = LinuxError;
        ConnectLastFailureReason = ConnectFailureReason::HostConnectFailed;
        return static_cast<uint64_t>(-LinuxError);
      }
      if (ExactAltLoaderSocket) {
        CXAltLoaderConnectedDescriptors.insert(Descriptor);
      }
      ++ConnectSuccessCount;
      ConnectLastLinuxError = 0;
      ConnectLastFailureReason = ConnectFailureReason::None;
      return 0;
    }
    if (ExperimentalAcceptDispatchEnabled && Number == AcceptSyscall && !RootFS.empty()) {
      dprintf(STDERR_FILENO, "FEX_ACCEPT_HANDLER_ENTER\n");
      return HandleAcceptSyscall(Arguments);
    }
    if (Number == GetSockOptSyscall && !RootFS.empty()) {
      GetSockOptSeen = true;
      ++GetSockOptCallCount;
      constexpr int64_t LinuxSOLSocket = 1;
      constexpr int64_t LinuxSOPeerCredentials = 17;
      constexpr uint32_t LinuxPeerCredentialsSize = sizeof(LinuxPeerCredentials);
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const int64_t Level = static_cast<int64_t>(Arguments->Argument[2]);
      const int64_t Option = static_cast<int64_t>(Arguments->Argument[3]);
      const uint64_t GuestValue = Arguments->Argument[4];
      const uint64_t GuestValueLength = Arguments->Argument[5];
      GetSockOptLastDescriptor = Descriptor;
      GetSockOptLastLevel = Level;
      GetSockOptLastOption = Option;
      GetSockOptLastLinuxError = 0;
      GetSockOptLastHostError = 0;
      GetSockOptLastFailureReason = GetSockOptFailureReason::None;
      if (!OwnedDescriptors.contains(Descriptor)) {
        GetSockOptLastLinuxError = EBADF;
        GetSockOptLastFailureReason = GetSockOptFailureReason::UnownedDescriptor;
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(GuestValueLength, sizeof(uint32_t))) {
        GetSockOptLastLinuxError = EFAULT;
        GetSockOptLastFailureReason = GetSockOptFailureReason::UnreadableLength;
        return static_cast<uint64_t>(-EFAULT);
      }
      uint32_t InputLength {};
      std::memcpy(
        &InputLength,
        reinterpret_cast<const void*>(GuestValueLength),
        sizeof(InputLength));
      GetSockOptLastInputLength = InputLength;
      if (Level != LinuxSOLSocket || Option != LinuxSOPeerCredentials
          || InputLength != LinuxPeerCredentialsSize) {
        GetSockOptLastFailureReason = GetSockOptFailureReason::UnmeasuredShape;
      } else if (!Contains(GuestValue, LinuxPeerCredentialsSize)) {
        GetSockOptLastLinuxError = EFAULT;
        GetSockOptLastFailureReason = GetSockOptFailureReason::UnreadableValue;
        return static_cast<uint64_t>(-EFAULT);
      } else {
        ++GetSockOptPeerCredentialsCallCount;
        uid_t HostUserID {};
        gid_t HostGroupID {};
        if (getpeereid(Descriptor, &HostUserID, &HostGroupID) != 0) {
          const int HostError = errno;
          const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
          GetSockOptLastHostError = HostError;
          GetSockOptLastLinuxError = LinuxError;
          GetSockOptLastFailureReason = GetSockOptFailureReason::HostPeerIdentityFailed;
          return static_cast<uint64_t>(-LinuxError);
        }
        pid_t HostProcessID {};
        socklen_t HostProcessIDLength = sizeof(HostProcessID);
        if (getsockopt(
              Descriptor,
              SOL_LOCAL,
              LOCAL_PEERPID,
              &HostProcessID,
              &HostProcessIDLength) != 0) {
          const int HostError = errno;
          const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
          GetSockOptLastHostError = HostError;
          GetSockOptLastLinuxError = LinuxError;
          GetSockOptLastFailureReason = GetSockOptFailureReason::HostPeerProcessFailed;
          return static_cast<uint64_t>(-LinuxError);
        }
        GetSockOptLastHostProcessLength = HostProcessIDLength;
        if (HostProcessIDLength != sizeof(HostProcessID)) {
          GetSockOptLastLinuxError = EIO;
          GetSockOptLastFailureReason =
            GetSockOptFailureReason::HostPeerProcessLengthMismatch;
          return static_cast<uint64_t>(-EIO);
        }
        const LinuxPeerCredentials GuestCredentials {
          .ProcessID = static_cast<int32_t>(HostProcessID),
          .UserID = static_cast<uint32_t>(HostUserID),
          .GroupID = static_cast<uint32_t>(HostGroupID),
        };
        std::memcpy(
          reinterpret_cast<void*>(GuestValue),
          &GuestCredentials,
          sizeof(GuestCredentials));
        std::memcpy(
          reinterpret_cast<void*>(GuestValueLength),
          &LinuxPeerCredentialsSize,
          sizeof(LinuxPeerCredentialsSize));
        GetSockOptLastHostProcessID = HostProcessID;
        GetSockOptLastHostUserID = HostUserID;
        GetSockOptLastHostGroupID = HostGroupID;
        GetSockOptLastOutputLength = LinuxPeerCredentialsSize;
        ++GetSockOptPeerCredentialsSuccessCount;
        return 0;
      }
    }
    if (Number == SendMsgSyscall && !RootFS.empty()) {
      SendMsgSeen = true;
      ++SendMsgCallCount;
      constexpr int32_t LinuxSOLSocket = 1;
      constexpr int32_t LinuxSCMRights = 1;
      constexpr uint64_t ServerHandlePayloadSize = sizeof(uint32_t);
      constexpr uint64_t ClientSendFDPayloadSize = 2 * sizeof(uint32_t);
      constexpr uint64_t MeasuredControlSize =
        sizeof(LinuxControlMessageHeader64) + sizeof(int32_t);
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestHeaderAddress = Arguments->Argument[2];
      const int64_t CallFlags = static_cast<int64_t>(Arguments->Argument[3]);
      SendMsgLastDescriptor = Descriptor;
      SendMsgLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      SendMsgLastCallFlags = CallFlags;
      SendMsgLastHeaderReadable = false;
      SendMsgLastNamePresent = false;
      SendMsgLastNameLength = 0;
      SendMsgLastIOVectorCount = 0;
      SendMsgLastFirstIOVectorReadable = false;
      SendMsgLastFirstIOVectorBase = 0;
      SendMsgLastFirstIOVectorLength = 0;
      SendMsgLastFirstIOVectorPayloadReadable = false;
      SendMsgLastFirstIOVectorPayloadFingerprint = 0;
      SendMsgLastControlPresent = false;
      SendMsgLastControlLength = 0;
      SendMsgLastControlReadable = false;
      SendMsgLastControlMessageLength = 0;
      SendMsgLastControlLevel = 0;
      SendMsgLastControlType = 0;
      SendMsgLastMessageFlags = 0;
      SendMsgLastTransferredDescriptor = -1;
      SendMsgLastTransferredDescriptorOwned = false;
      SendMsgLastTransferredDescriptorStandard = false;
      SendMsgLastTransferredDescriptorClosed = false;
      SendMsgLastTransferredDescriptorFlags = -1;
      SendMsgLastTransferredDescriptorFlagsError = 0;
      SendMsgLastTransferredStatusFlags = -1;
      SendMsgLastTransferredStatusFlagsError = 0;
      SendMsgLastTransferredDescriptorStatSucceeded = false;
      SendMsgLastTransferredDescriptorFIFO = false;
      SendMsgLastTransferredDescriptorSocket = false;
      SendMsgLastTransferredDescriptorRegular = false;
      SendMsgLastTransferredDescriptorCharacter = false;
      SendMsgLastHostError = 0;
      SendMsgLastLinuxError = 0;
      SendMsgLastFailureReason = SendMsgFailureReason::None;
      if (!SendMsgLastDescriptorOwned) {
        SendMsgLastLinuxError = EBADF;
        SendMsgLastFailureReason = SendMsgFailureReason::UnownedDescriptor;
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(GuestHeaderAddress, sizeof(LinuxMessageHeader64))) {
        SendMsgLastLinuxError = EFAULT;
        SendMsgLastFailureReason = SendMsgFailureReason::UnreadableHeader;
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxMessageHeader64 GuestHeader {};
      std::memcpy(
        &GuestHeader,
        reinterpret_cast<const void*>(GuestHeaderAddress),
        sizeof(GuestHeader));
      SendMsgLastHeaderReadable = true;
      SendMsgLastNamePresent = GuestHeader.Name != 0;
      SendMsgLastNameLength = GuestHeader.NameLength;
      SendMsgLastIOVectorCount = GuestHeader.IOVectorCount;
      SendMsgLastControlPresent = GuestHeader.Control != 0;
      SendMsgLastControlLength = GuestHeader.ControlLength;
      SendMsgLastMessageFlags = GuestHeader.Flags;
      if (!Contains(GuestHeader.IOVectors, sizeof(LinuxIOVector64))) {
        SendMsgLastLinuxError = EFAULT;
        SendMsgLastFailureReason = SendMsgFailureReason::UnreadableIOVector;
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxIOVector64 GuestVector {};
      std::memcpy(
        &GuestVector,
        reinterpret_cast<const void*>(GuestHeader.IOVectors),
        sizeof(GuestVector));
      SendMsgLastFirstIOVectorReadable = true;
      SendMsgLastFirstIOVectorBase = GuestVector.Base;
      SendMsgLastFirstIOVectorLength = GuestVector.Length;
      const bool ExactMeasuredPayloadSize =
        GuestVector.Length == ServerHandlePayloadSize
        || GuestVector.Length == ClientSendFDPayloadSize;
      SendMsgLastFirstIOVectorPayloadReadable = GuestVector.Length <= 4096
        && Contains(GuestVector.Base, GuestVector.Length);
      if (SendMsgLastFirstIOVectorPayloadReadable) {
        SendMsgLastFirstIOVectorPayloadFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(GuestVector.Base),
          static_cast<size_t>(GuestVector.Length));
      }
      if (ExactMeasuredPayloadSize
          && !SendMsgLastFirstIOVectorPayloadReadable) {
        SendMsgLastLinuxError = EFAULT;
        SendMsgLastFailureReason = SendMsgFailureReason::UnreadablePayload;
        return static_cast<uint64_t>(-EFAULT);
      }
      if (!Contains(GuestHeader.Control, MeasuredControlSize)) {
        SendMsgLastLinuxError = EFAULT;
        SendMsgLastFailureReason = SendMsgFailureReason::UnreadableControl;
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxControlMessageHeader64 GuestControl {};
      std::memcpy(
        &GuestControl,
        reinterpret_cast<const void*>(GuestHeader.Control),
        sizeof(GuestControl));
      SendMsgLastControlReadable = GuestHeader.ControlLength <= 4096
        && Contains(GuestHeader.Control, GuestHeader.ControlLength);
      SendMsgLastControlMessageLength = GuestControl.Length;
      SendMsgLastControlLevel = GuestControl.Level;
      SendMsgLastControlType = GuestControl.Type;
      int TransferredDescriptor {-1};
      std::memcpy(
        &TransferredDescriptor,
        reinterpret_cast<const void*>(
          GuestHeader.Control + sizeof(LinuxControlMessageHeader64)),
        sizeof(TransferredDescriptor));
      SendMsgLastTransferredDescriptor = TransferredDescriptor;
      SendMsgLastTransferredDescriptorOwned = OwnedDescriptors.contains(
        TransferredDescriptor);
      SendMsgLastTransferredDescriptorStandard = TransferredDescriptor >= STDIN_FILENO
        && TransferredDescriptor <= STDERR_FILENO;
      SendMsgLastTransferredDescriptorClosed =
        ClosedStandardDescriptors.contains(TransferredDescriptor);
      errno = 0;
      SendMsgLastTransferredDescriptorFlags = fcntl(TransferredDescriptor, F_GETFD);
      if (SendMsgLastTransferredDescriptorFlags == -1) {
        SendMsgLastTransferredDescriptorFlagsError = errno;
      }
      errno = 0;
      SendMsgLastTransferredStatusFlags = fcntl(TransferredDescriptor, F_GETFL);
      if (SendMsgLastTransferredStatusFlags == -1) {
        SendMsgLastTransferredStatusFlagsError = errno;
      }
      struct stat TransferredDescriptorStat {};
      errno = 0;
      SendMsgLastTransferredDescriptorStatSucceeded =
        fstat(TransferredDescriptor, &TransferredDescriptorStat) == 0;
      if (SendMsgLastTransferredDescriptorStatSucceeded) {
        SendMsgLastTransferredDescriptorFIFO = S_ISFIFO(TransferredDescriptorStat.st_mode);
        SendMsgLastTransferredDescriptorSocket = S_ISSOCK(TransferredDescriptorStat.st_mode);
        SendMsgLastTransferredDescriptorRegular = S_ISREG(TransferredDescriptorStat.st_mode);
        SendMsgLastTransferredDescriptorCharacter = S_ISCHR(TransferredDescriptorStat.st_mode);
      }
      const bool ExactOpenStandardErrorDescriptor =
        TransferredDescriptor == STDERR_FILENO
        && !ClosedStandardDescriptors.contains(STDERR_FILENO)
        && fcntl(STDERR_FILENO, F_GETFD) != -1;
      const bool ExactOpenStandardInputDescriptor =
        TransferredDescriptor == STDIN_FILENO
        && !SendMsgLastTransferredDescriptorClosed
        && SendMsgLastTransferredDescriptorFlags == 0
        && SendMsgLastTransferredStatusFlags == O_RDONLY
        && SendMsgLastTransferredDescriptorStatSucceeded
        && SendMsgLastTransferredDescriptorCharacter;
      const bool ExactOpenStandardOutputDescriptor =
        TransferredDescriptor == STDOUT_FILENO
        && !SendMsgLastTransferredDescriptorClosed
        && SendMsgLastTransferredDescriptorFlags == 0
        && SendMsgLastTransferredStatusFlags == O_WRONLY
        && SendMsgLastTransferredDescriptorStatSucceeded
        && SendMsgLastTransferredDescriptorFIFO;
      const bool TransferredDescriptorPermitted =
        SendMsgLastTransferredDescriptorOwned
        || ExactOpenStandardErrorDescriptor
        || ExactOpenStandardInputDescriptor
        || ExactOpenStandardOutputDescriptor;
      const bool ExactMeasuredShape = CallFlags == 0
        && GuestHeader.Name == 0
        && GuestHeader.NameLength == 0
        && GuestHeader.IOVectorCount == 1
        && GuestHeader.ControlLength == MeasuredControlSize
        && GuestHeader.Flags == 0
        && ExactMeasuredPayloadSize
        && GuestControl.Length == MeasuredControlSize
        && GuestControl.Level == LinuxSOLSocket
        && GuestControl.Type == LinuxSCMRights;
      if (ExactMeasuredShape && ExactOpenStandardInputDescriptor) {
        ++SendMsgStandardInputCandidateCount;
      }
      if (ExactMeasuredShape && ExactOpenStandardOutputDescriptor) {
        ++SendMsgStandardOutputCandidateCount;
      }
      if (!ExactMeasuredShape) {
        SendMsgLastFailureReason = SendMsgFailureReason::UnmeasuredShape;
      } else if (!TransferredDescriptorPermitted) {
        SendMsgLastLinuxError = EBADF;
        SendMsgLastFailureReason = SendMsgFailureReason::UnownedTransferredDescriptor;
        return static_cast<uint64_t>(-EBADF);
      } else {
        iovec HostVector {
          .iov_base = reinterpret_cast<void*>(GuestVector.Base),
          .iov_len = static_cast<size_t>(GuestVector.Length),
        };
        alignas(cmsghdr) std::array<std::byte, 64> HostControlStorage {};
        static_assert(CMSG_SPACE(sizeof(int)) <= HostControlStorage.size());
        msghdr HostHeader {};
        HostHeader.msg_iov = &HostVector;
        HostHeader.msg_iovlen = 1;
        HostHeader.msg_control = HostControlStorage.data();
        HostHeader.msg_controllen = CMSG_SPACE(sizeof(int));
        cmsghdr* HostControl = CMSG_FIRSTHDR(&HostHeader);
        if (HostControl == nullptr) {
          SendMsgLastLinuxError = EIO;
          SendMsgLastFailureReason = SendMsgFailureReason::HostControlLayoutUnavailable;
          return static_cast<uint64_t>(-EIO);
        }
        HostControl->cmsg_len = CMSG_LEN(sizeof(int));
        HostControl->cmsg_level = SOL_SOCKET;
        HostControl->cmsg_type = SCM_RIGHTS;
        std::memcpy(
          CMSG_DATA(HostControl),
          &TransferredDescriptor,
          sizeof(TransferredDescriptor));
        HostHeader.msg_controllen = CMSG_SPACE(sizeof(int));
        SendMsgLastHostControlLength = HostHeader.msg_controllen;
        const ssize_t Result = sendmsg(Descriptor, &HostHeader, 0);
        if (Result == -1) {
          const int HostError = errno;
          const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
          SendMsgLastHostError = HostError;
          SendMsgLastLinuxError = LinuxError;
          SendMsgLastFailureReason = SendMsgFailureReason::HostSendFailed;
          if (ExactOpenStandardInputDescriptor) {
            ++SendMsgStandardInputFailureCount;
          }
          if (ExactOpenStandardOutputDescriptor) {
            ++SendMsgStandardOutputFailureCount;
          }
          return static_cast<uint64_t>(-LinuxError);
        }
        SendMsgLastByteCount = static_cast<uint64_t>(Result);
        ++SendMsgSuccessCount;
        if (ExactOpenStandardInputDescriptor) {
          ++SendMsgStandardInputSuccessCount;
        }
        if (ExactOpenStandardOutputDescriptor) {
          ++SendMsgStandardOutputSuccessCount;
        }
        return static_cast<uint64_t>(Result);
      }
    }
    if (Number == SetTIDAddressSyscall && !RootFS.empty()) {
      SetTIDAddressSeen = true;
      ++SetTIDAddressCallCount;
      const uint64_t Address = Arguments->Argument[1];
      if (Address != 0 && !Contains(Address, sizeof(int32_t))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      ClearChildTID = Address;
      return static_cast<uint64_t>(getpid());
    }
    if (Number == SetRobustListSyscall && !RootFS.empty()) {
      SetRobustListSeen = true;
      ++SetRobustListCallCount;
      constexpr uint64_t LinuxRobustListHeadSize = 24;
      const uint64_t Address = Arguments->Argument[1];
      const uint64_t Length = Arguments->Argument[2];
      if (Length != LinuxRobustListHeadSize) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!Contains(Address, Length)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      RobustListHead = Address;
      return 0;
    }
    if (Number == RSeqSyscall && !RootFS.empty()) {
      RSeqSeen = true;
      ++RSeqCallCount;
      return static_cast<uint64_t>(-ENOSYS);
    }
    if (Number == MProtectSyscall && !RootFS.empty()) {
      MProtectSeen = true;
      ++MProtectCallCount;
      constexpr uint64_t LinuxPageSize = 4096;
      const uint64_t Address = Arguments->Argument[1];
      const uint64_t Length = Arguments->Argument[2];
      const uint64_t Protection = Arguments->Argument[3];
      if (Length == 0 || Address % LinuxPageSize != 0
          || (Protection & ~uint64_t {PROT_READ | PROT_WRITE | PROT_EXEC}) != 0) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
          && LowGuestShadow->ContainsLogicalRange(Address, Length)) {
        ++LowMemoryMProtectRequestCount;
        const int LowProtectError = LowGuestShadow->Protect(Address, Length, Protection);
        if (LowProtectError != 0) {
          ++LowMemoryMProtectFailureCount;
          return static_cast<uint64_t>(-LowProtectError);
        }
        ++LowMemoryMProtectSuccessCount;
        ++MProtectLogicalSuccessCount;
        return 0;
      }
      if (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
          && HighGuestSparse->ContainsLogicalRange(Address, Length)) {
        ++HighMemoryMProtectRequestCount;
        const int HighProtectError = HighGuestSparse->Protect(Address, Length, Protection);
        if (HighProtectError != 0) {
          ++HighMemoryMProtectFailureCount;
          return static_cast<uint64_t>(-HighProtectError);
        }
        ++HighMemoryMProtectSuccessCount;
        ++MProtectLogicalSuccessCount;
        return 0;
      }
      if (!Contains(Address, Length)) {
        return static_cast<uint64_t>(-ENOMEM);
      }
      ++MProtectLogicalSuccessCount;
      return 0;
    }
    if (Number == Prlimit64Syscall && !RootFS.empty()) {
      Prlimit64Seen = true;
      ++Prlimit64CallCount;
      constexpr int32_t LinuxRLimitStack = 3;
      constexpr int32_t LinuxRLimitCore = 4;
      constexpr int32_t LinuxRLimitNoFile = 7;
      constexpr int32_t LinuxRLimitAddressSpace = 9;
      constexpr int32_t LinuxRLimitNice = 13;
      const int32_t ProcessID = static_cast<int32_t>(Arguments->Argument[1]);
      const int32_t Resource = static_cast<int32_t>(Arguments->Argument[2]);
      const uint64_t NewLimit = Arguments->Argument[3];
      const uint64_t OldLimit = Arguments->Argument[4];
      Prlimit64LastProcessID = ProcessID;
      Prlimit64LastResource = Resource;
      Prlimit64LastNewLimitClass = NewLimit == 0
        ? "zero"
        : (Contains(NewLimit, sizeof(LinuxRLimit64)) ? "guest-memory" : "scalar-or-outside");
      Prlimit64LastOldLimitClass = OldLimit == 0
        ? "zero"
        : (Contains(OldLimit, sizeof(LinuxRLimit64)) ? "guest-memory" : "scalar-or-outside");
      const bool NewLimitReadable = NewLimit != 0
        && Contains(NewLimit, sizeof(LinuxRLimit64));
      const bool OldLimitReadable = OldLimit != 0
        && Contains(OldLimit, sizeof(LinuxRLimit64));
      if (Prlimit64TraceCount < Prlimit64Trace.size()) {
        auto& Trace = Prlimit64Trace[Prlimit64TraceCount++];
        Trace.ProcessID = ProcessID;
        Trace.Resource = Resource;
        Trace.NewLimitClass = Prlimit64LastNewLimitClass;
        Trace.OldLimitClass = Prlimit64LastOldLimitClass;
        if (NewLimitReadable) {
          LinuxRLimit64 RequestedLimit {};
          std::memcpy(
            &RequestedLimit,
            reinterpret_cast<const void*>(NewLimit),
            sizeof(RequestedLimit));
          Trace.RequestedCurrent = RequestedLimit.Current;
          Trace.RequestedMaximum = RequestedLimit.Maximum;
        }
      }
      const bool StackQueryCandidate = ProcessID == 0
        && Resource == LinuxRLimitStack
        && NewLimit == 0
        && OldLimitReadable;
      const bool CoreQueryCandidate = ProcessID == 0
        && Resource == LinuxRLimitCore
        && NewLimit == 0
        && OldLimitReadable;
      const bool NoFileQueryCandidate = ProcessID == 0
        && Resource == LinuxRLimitNoFile
        && NewLimit == 0
        && OldLimitReadable;
      LinuxRLimit64 RequestedNoFileLimit {};
      if (NewLimitReadable) {
        std::memcpy(
          &RequestedNoFileLimit,
          reinterpret_cast<const void*>(NewLimit),
          sizeof(RequestedNoFileLimit));
      }
      const bool NoFileSetCandidate = ProcessID == 0
        && Resource == LinuxRLimitNoFile
        && NewLimitReadable
        && OldLimit == 0
        && RequestedNoFileLimit.Current == std::numeric_limits<uint64_t>::max()
        && RequestedNoFileLimit.Maximum == std::numeric_limits<uint64_t>::max();
      const bool AddressSpaceQueryCandidate = ProcessID == 0
        && Resource == LinuxRLimitAddressSpace
        && NewLimit == 0
        && OldLimitReadable;
      LinuxRLimit64 RequestedAddressSpaceLimit {};
      if (NewLimitReadable) {
        std::memcpy(
          &RequestedAddressSpaceLimit,
          reinterpret_cast<const void*>(NewLimit),
          sizeof(RequestedAddressSpaceLimit));
      }
      const bool AddressSpaceSetCandidate = ProcessID == 0
        && Resource == LinuxRLimitAddressSpace
        && NewLimitReadable
        && OldLimit == 0
        && RequestedAddressSpaceLimit.Current == std::numeric_limits<uint64_t>::max()
        && RequestedAddressSpaceLimit.Maximum == std::numeric_limits<uint64_t>::max();
      const bool NiceQueryCandidate = ProcessID == 0
        && Resource == LinuxRLimitNice
        && NewLimit == 0
        && OldLimitReadable;
      const bool NiceSetCandidate = ProcessID == 0
        && Resource == LinuxRLimitNice
        && NewLimitReadable
        && (OldLimit == 0 || OldLimitReadable);
      if (StackQueryCandidate) {
        ++Prlimit64StackQueryCandidateCount;
      } else if (NoFileQueryCandidate) {
        ++Prlimit64NoFileQueryCandidateCount;
      } else if (NoFileSetCandidate) {
        ++Prlimit64NoFileSetCandidateCount;
        Prlimit64NoFileSetLastRequestedCurrent = RequestedNoFileLimit.Current;
        Prlimit64NoFileSetLastRequestedMaximum = RequestedNoFileLimit.Maximum;
      } else if (CoreQueryCandidate) {
        ++Prlimit64CoreQueryCandidateCount;
      } else if (AddressSpaceQueryCandidate) {
        ++Prlimit64AddressSpaceQueryCandidateCount;
      } else if (AddressSpaceSetCandidate) {
        ++Prlimit64AddressSpaceSetCandidateCount;
        Prlimit64AddressSpaceSetLastRequestedCurrent = RequestedAddressSpaceLimit.Current;
        Prlimit64AddressSpaceSetLastRequestedMaximum = RequestedAddressSpaceLimit.Maximum;
      } else if (NiceQueryCandidate) {
        ++Prlimit64NiceQueryCandidateCount;
      } else if (NiceSetCandidate) {
        ++Prlimit64NiceSetCandidateCount;
        LinuxRLimit64 RequestedLimit {};
        std::memcpy(
          &RequestedLimit,
          reinterpret_cast<const void*>(NewLimit),
          sizeof(RequestedLimit));
        Prlimit64NiceSetLastCurrent = RequestedLimit.Current;
        Prlimit64NiceSetLastMaximum = RequestedLimit.Maximum;
        Prlimit64NiceSetLastOldLimitClass = Prlimit64LastOldLimitClass;
      } else {
        ++Prlimit64OtherShapeCount;
      }
      Prlimit64LastCurrent = 0;
      Prlimit64LastMaximum = 0;
      Prlimit64LastHostError = 0;
      Prlimit64LastLinuxError = ENOSYS;
      Prlimit64LastFailureReason = "unmeasured-shape";

      if (NiceQueryCandidate) {
        ++Prlimit64NiceQueryUnsupportedCount;
        Prlimit64NiceQueryLastLinuxError = EINVAL;
        Prlimit64NiceQueryLastFailureReason = "host-resource-unavailable";
        Prlimit64LastLinuxError = EINVAL;
        Prlimit64LastFailureReason = "host-resource-unavailable";
        return static_cast<uint64_t>(-EINVAL);
      }

      if (NoFileSetCandidate) {
        const struct rlimit HostLimit {RLIM_INFINITY, RLIM_INFINITY};
        if (setrlimit(RLIMIT_NOFILE, &HostLimit) != 0) {
          const int HostError = errno;
          const int LinuxError = HostError == EINVAL
            ? EINVAL
            : (HostError == EPERM
                ? EPERM
                : (HostError == EACCES ? EACCES : EIO));
          ++Prlimit64NoFileSetFailureCount;
          Prlimit64NoFileSetLastHostError = HostError;
          Prlimit64NoFileSetLastLinuxError = LinuxError;
          Prlimit64NoFileSetLastFailureReason = "host-setrlimit-rejected";
          Prlimit64LastHostError = HostError;
          Prlimit64LastLinuxError = LinuxError;
          Prlimit64LastFailureReason = "host-setrlimit-rejected";
          return static_cast<uint64_t>(-LinuxError);
        }
        ++Prlimit64SuccessCount;
        ++Prlimit64NoFileSetSuccessCount;
        Prlimit64NoFileSetLastHostError = 0;
        Prlimit64NoFileSetLastLinuxError = 0;
        Prlimit64NoFileSetLastFailureReason = "none";
        Prlimit64LastLinuxError = 0;
        Prlimit64LastFailureReason = "none";
        return 0;
      }

      if (AddressSpaceSetCandidate) {
        const struct rlimit HostLimit {RLIM_INFINITY, RLIM_INFINITY};
        if (setrlimit(RLIMIT_AS, &HostLimit) != 0) {
          const int HostError = errno;
          const int LinuxError = HostError == EINVAL
            ? EINVAL
            : (HostError == EPERM
                ? EPERM
                : (HostError == EACCES ? EACCES : EIO));
          ++Prlimit64AddressSpaceSetFailureCount;
          Prlimit64AddressSpaceSetLastHostError = HostError;
          Prlimit64AddressSpaceSetLastLinuxError = LinuxError;
          Prlimit64AddressSpaceSetLastFailureReason = "host-setrlimit-rejected";
          Prlimit64LastHostError = HostError;
          Prlimit64LastLinuxError = LinuxError;
          Prlimit64LastFailureReason = "host-setrlimit-rejected";
          return static_cast<uint64_t>(-LinuxError);
        }
        ++Prlimit64SuccessCount;
        ++Prlimit64AddressSpaceSetSuccessCount;
        Prlimit64AddressSpaceSetLastHostError = 0;
        Prlimit64AddressSpaceSetLastLinuxError = 0;
        Prlimit64AddressSpaceSetLastFailureReason = "none";
        Prlimit64LastLinuxError = 0;
        Prlimit64LastFailureReason = "none";
        return 0;
      }

      int HostResource = -1;
      if (StackQueryCandidate) {
        HostResource = RLIMIT_STACK;
      } else if (NoFileQueryCandidate) {
        HostResource = RLIMIT_NOFILE;
      } else if (CoreQueryCandidate) {
        HostResource = RLIMIT_CORE;
      } else if (AddressSpaceQueryCandidate) {
        HostResource = RLIMIT_AS;
      }
      if (HostResource != -1) {
        struct rlimit HostLimit {};
        if (getrlimit(HostResource, &HostLimit) != 0) {
          const int HostError = errno;
          const int LinuxError = HostError == EINVAL ? EINVAL : EIO;
          Prlimit64LastHostError = HostError;
          Prlimit64LastLinuxError = LinuxError;
          Prlimit64LastFailureReason = "host-getrlimit-failed";
          return static_cast<uint64_t>(-LinuxError);
        }
        const auto ConvertLimit = [](rlim_t Value) {
          return Value == RLIM_INFINITY
            ? std::numeric_limits<uint64_t>::max()
            : static_cast<uint64_t>(Value);
        };
        const LinuxRLimit64 GuestLimit {
          ConvertLimit(HostLimit.rlim_cur),
          ConvertLimit(HostLimit.rlim_max),
        };
        std::memcpy(reinterpret_cast<void*>(OldLimit), &GuestLimit, sizeof(GuestLimit));
        Prlimit64LastCurrent = GuestLimit.Current;
        Prlimit64LastMaximum = GuestLimit.Maximum;
        Prlimit64LastLinuxError = 0;
        Prlimit64LastFailureReason = "none";
        ++Prlimit64SuccessCount;
        if (StackQueryCandidate) {
          ++Prlimit64StackQuerySuccessCount;
          Prlimit64StackLastCurrent = GuestLimit.Current;
          Prlimit64StackLastMaximum = GuestLimit.Maximum;
        } else if (NoFileQueryCandidate) {
          ++Prlimit64NoFileQuerySuccessCount;
          Prlimit64NoFileLastCurrent = GuestLimit.Current;
          Prlimit64NoFileLastMaximum = GuestLimit.Maximum;
        } else if (CoreQueryCandidate) {
          ++Prlimit64CoreQuerySuccessCount;
          Prlimit64CoreLastCurrent = GuestLimit.Current;
          Prlimit64CoreLastMaximum = GuestLimit.Maximum;
        } else {
          ++Prlimit64AddressSpaceQuerySuccessCount;
          Prlimit64AddressSpaceLastCurrent = GuestLimit.Current;
          Prlimit64AddressSpaceLastMaximum = GuestLimit.Maximum;
        }
        return 0;
      }
    }
    if (Number == ClockGettimeSyscall && !RootFS.empty()) {
      ClockGettimeSeen = true;
      ++ClockGettimeCallCount;
      const int32_t LinuxClock = static_cast<int32_t>(Arguments->Argument[1]);
      const uint64_t GuestTime = Arguments->Argument[2];
      if (!Contains(GuestTime, sizeof(LinuxTimespec64))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      const auto HostClock = TranslateLinuxClockID(LinuxClock);
      if (!HostClock.has_value()) {
        return static_cast<uint64_t>(-EINVAL);
      }
      struct timespec HostTime {};
      if (clock_gettime(*HostClock, &HostTime) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      const LinuxTimespec64 Time {
        static_cast<int64_t>(HostTime.tv_sec),
        static_cast<int64_t>(HostTime.tv_nsec),
      };
      std::memcpy(reinterpret_cast<void*>(GuestTime), &Time, sizeof(Time));
      ++ClockGettimeSuccessCount;
      return 0;
    }
    if (Number == ClockNanosleepSyscall && !RootFS.empty()) {
      ClockNanosleepSeen = true;
      ++ClockNanosleepCallCount;
      constexpr uint64_t LinuxTimerAbsolute = 1;
      const int32_t LinuxClock = static_cast<int32_t>(Arguments->Argument[1]);
      const uint64_t Flags = Arguments->Argument[2];
      const uint64_t GuestRequest = Arguments->Argument[3];
      const uint64_t GuestRemain = Arguments->Argument[4];
      if (Flags != 0 && Flags != LinuxTimerAbsolute) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (!Contains(GuestRequest, sizeof(LinuxTimespec64))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      if (Flags == 0 && GuestRemain != 0 && !Contains(GuestRemain, sizeof(LinuxTimespec64))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxTimespec64 GuestDelay {};
      std::memcpy(&GuestDelay, reinterpret_cast<const void*>(GuestRequest), sizeof(GuestDelay));
      if (!IsValidLinuxTimespec(GuestDelay)) {
        return static_cast<uint64_t>(-EINVAL);
      }
      const auto HostClock = TranslateLinuxClockID(LinuxClock);
      if (!HostClock.has_value()) {
        return static_cast<uint64_t>(-EINVAL);
      }

      ClockNanosleepLastRequestSeconds = static_cast<uint64_t>(GuestDelay.Seconds);
      ClockNanosleepLastRequestNanoseconds = static_cast<uint64_t>(GuestDelay.Nanoseconds);
      timespec HostDelay {
        static_cast<time_t>(GuestDelay.Seconds),
        static_cast<long>(GuestDelay.Nanoseconds),
      };
      if (Flags == LinuxTimerAbsolute) {
        ++ClockNanosleepAbsoluteCallCount;
        timespec HostNow {};
        if (clock_gettime(*HostClock, &HostNow) != 0) {
          return static_cast<uint64_t>(-errno);
        }
        HostDelay = RelativeDelayUntil(GuestDelay, HostNow);
        if (HostDelay.tv_sec < 0 || (HostDelay.tv_sec == 0 && HostDelay.tv_nsec == 0)) {
          ++ClockNanosleepSuccessCount;
          return 0;
        }
      }

      timespec HostRemain {};
      if (nanosleep(&HostDelay, &HostRemain) != 0) {
        const int HostError = errno;
        if (HostError == EINTR) {
          ++ClockNanosleepInterruptedCount;
          if (Flags == 0 && GuestRemain != 0) {
            const LinuxTimespec64 Remaining {
              static_cast<int64_t>(HostRemain.tv_sec),
              static_cast<int64_t>(HostRemain.tv_nsec),
            };
            std::memcpy(reinterpret_cast<void*>(GuestRemain), &Remaining, sizeof(Remaining));
          }
        }
        return static_cast<uint64_t>(-HostError);
      }
      ++ClockNanosleepSuccessCount;
      return 0;
    }
    if (Number == GetrandomSyscall && !RootFS.empty()) {
      GetrandomSeen = true;
      ++GetrandomCallCount;
      constexpr uint64_t LinuxGRNDNonblock = 0x1;
      constexpr uint64_t LinuxGRNDRandom = 0x2;
      constexpr uint64_t LinuxGRNDInsecure = 0x4;
      constexpr uint64_t AllowedFlags = LinuxGRNDNonblock | LinuxGRNDRandom | LinuxGRNDInsecure;
      constexpr size_t HostEntropyChunkSize = 256;
      const uint64_t GuestBuffer = Arguments->Argument[1];
      const uint64_t Length = Arguments->Argument[2];
      const uint64_t Flags = Arguments->Argument[3];
      if ((Flags & ~AllowedFlags) != 0) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (Length == 0) {
        ++GetrandomSuccessCount;
        return 0;
      }
      if (!Contains(GuestBuffer, Length)
          || Length > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        return static_cast<uint64_t>(-EFAULT);
      }

      size_t TotalBytes {};
      while (TotalBytes < static_cast<size_t>(Length)) {
        const size_t ChunkSize = std::min(
          HostEntropyChunkSize,
          static_cast<size_t>(Length) - TotalBytes);
        if (getentropy(reinterpret_cast<void*>(GuestBuffer + TotalBytes), ChunkSize) != 0) {
          return TotalBytes == 0
            ? static_cast<uint64_t>(-errno)
            : static_cast<uint64_t>(TotalBytes);
        }
        TotalBytes += ChunkSize;
      }
      ++GetrandomSuccessCount;
      GetrandomByteCount += TotalBytes;
      return static_cast<uint64_t>(TotalBytes);
    }
    if (Number == UnameSyscall && !RootFS.empty()) {
      UnameSeen = true;
      ++UnameCallCount;
      const uint64_t GuestBuffer = Arguments->Argument[1];
      if (!Contains(GuestBuffer, sizeof(LinuxUtsName))) {
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxUtsName GuestName {};
      const auto CopyField = [](auto& Destination, std::string_view Value) {
        const size_t Length = std::min(Destination.size() - 1, Value.size());
        std::memcpy(Destination.data(), Value.data(), Length);
        Destination[Length] = '\0';
      };
      CopyField(GuestName.SystemName, "Linux");
      CopyField(GuestName.NodeName, "regression-fli-lab");
      CopyField(GuestName.Release, "6.12.0-regression-fli-lab");
      CopyField(GuestName.Version, "#1 Regression FEXCore Darwin ABI research");
      CopyField(GuestName.Machine, "x86_64");
      CopyField(GuestName.DomainName, "(none)");
      std::memcpy(reinterpret_cast<void*>(GuestBuffer), &GuestName, sizeof(GuestName));
      ++UnameSuccessCount;
      return 0;
    }
    if (Number == GetcwdSyscall && !RootFS.empty()) {
      GetcwdSeen = true;
      ++GetcwdCallCount;
      const uint64_t GuestBuffer = Arguments->Argument[1];
      const uint64_t Size = Arguments->Argument[2];
      const uint64_t RequiredSize = GuestCurrentWorkingDirectory.size() + 1;
      if (Size == 0) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (Size < RequiredSize) {
        return static_cast<uint64_t>(-ERANGE);
      }
      if (!Contains(GuestBuffer, RequiredSize)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      std::memcpy(
        reinterpret_cast<void*>(GuestBuffer),
        GuestCurrentWorkingDirectory.data(),
        GuestCurrentWorkingDirectory.size());
      *reinterpret_cast<char*>(GuestBuffer + GuestCurrentWorkingDirectory.size()) = '\0';
      ++GetcwdSuccessCount;
      return RequiredSize;
    }
    if (Number == ChdirSyscall && !RootFS.empty()) {
      ChdirSeen = true;
      ++ChdirCallCount;
      ChdirLastHostPathResolved = false;
      ChdirLastHostCWDMatchesGuest = false;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      if (!GuestPath.has_value()) {
        return static_cast<uint64_t>(-EFAULT);
      }
      TraceGuestPath("chdir", *GuestPath);
      if (GuestPath->empty() || GuestPath->front() != '/') {
        return static_cast<uint64_t>(-ENOTSUP);
      }
      const auto HostPath = ResolveGuestPath(*GuestPath);
      if (!HostPath.has_value()) {
        return static_cast<uint64_t>(-EACCES);
      }
      ChdirLastHostPathResolved = true;
      struct stat TargetStat {};
      if (stat(HostPath->c_str(), &TargetStat) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      if (!S_ISDIR(TargetStat.st_mode)) {
        return static_cast<uint64_t>(-ENOTDIR);
      }
      // El ayudante representa un único proceso Linux. Reflejar su cwd en el
      // proceso host conserva la semántica compartida entre hilos y evita
      // expandir rutas AF_UNIX relativas más allá de sun_path en macOS.
      if (chdir(HostPath->c_str()) != 0) {
        return static_cast<uint64_t>(-errno);
      }
      GuestCurrentWorkingDirectory = *GuestPath;
      while (GuestCurrentWorkingDirectory.size() > 1
             && GuestCurrentWorkingDirectory.back() == '/') {
        GuestCurrentWorkingDirectory.pop_back();
      }
      std::array<char, 4096> HostCurrentDirectory {};
      if (getcwd(HostCurrentDirectory.data(), HostCurrentDirectory.size()) != nullptr) {
        const std::string HostCWD {HostCurrentDirectory.data()};
        ChdirLastHostCWDMatchesGuest = HostCWD == *HostPath;
      }
      if (!ChdirLastHostCWDMatchesGuest) {
        return static_cast<uint64_t>(-EIO);
      }
      ++ChdirHostMirrorSuccessCount;
      ++ChdirSuccessCount;
      return 0;
    }
    if (Number == UmaskSyscall && !RootFS.empty()) {
      UmaskSeen = true;
      ++UmaskCallCount;
      UmaskLastRequestedMode = Arguments->Argument[1];
      UmaskLastAppliedMode = UmaskLastRequestedMode & 0777ULL;
      UmaskLastPreviousMode = GuestUmask;
      GuestUmask = UmaskLastAppliedMode;
      ++UmaskSuccessCount;
      return UmaskLastPreviousMode;
    }
    if (Number == MkdirSyscall && !RootFS.empty()) {
      MkdirSeen = true;
      ++MkdirCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t Mode = Arguments->Argument[2];
      MkdirLastMode = Mode;
      MkdirLastAppliedMode = 0;
      MkdirLastTargetConfined = false;
      MkdirLastParentConfined = false;
      MkdirLastParentExists = false;
      MkdirLastParentDirectory = false;
      MkdirLastTargetExists = false;
      MkdirLastTargetDirectory = false;
      MkdirLastLinuxError = 0;
      MkdirLastFailureReason = "none";
      if (!GuestPath.has_value()) {
        MkdirLastPathClass = "unreadable";
        MkdirLastLinuxError = EFAULT;
        MkdirLastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      MkdirLastPathLength = GuestPath->size();
      MkdirLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      MkdirLastPathClass = GuestPath->empty()
        ? "empty"
        : (GuestPath->front() == '/' ? "absolute" : "relative");
      TraceGuestPath("mkdir", *GuestPath);
      if ((Mode & ~uint64_t {07777}) != 0) {
        MkdirLastLinuxError = EINVAL;
        MkdirLastFailureReason = "unsupported-mode";
        return static_cast<uint64_t>(-EINVAL);
      }
      const size_t Separator = GuestPath->find_last_of('/');
      const std::string ParentGuestPath = Separator == std::string::npos
        ? "."
        : (Separator == 0 ? "/" : GuestPath->substr(0, Separator));
      const std::string Basename = Separator == std::string::npos
        ? *GuestPath
        : GuestPath->substr(Separator + 1);
      if (!Basename.empty() && Basename != "." && Basename != "..") {
        const auto HostParent = ResolveGuestPathWithParents(ParentGuestPath);
        if (HostParent.has_value()) {
          MkdirLastParentConfined = true;
          struct stat ParentStat {};
          MkdirLastParentExists = lstat(HostParent->c_str(), &ParentStat) == 0;
          MkdirLastParentDirectory = MkdirLastParentExists
            && S_ISDIR(ParentStat.st_mode);
          const std::string HostTarget = *HostParent
            + (*HostParent == "/" ? "" : "/") + Basename;
          struct stat TargetStat {};
          MkdirLastTargetExists = lstat(HostTarget.c_str(), &TargetStat) == 0;
          MkdirLastTargetDirectory = MkdirLastTargetExists
            && S_ISDIR(TargetStat.st_mode);
        }
      }
      if (MkdirLastParentConfined && !MkdirLastParentExists) {
        MkdirLastLinuxError = ENOENT;
        MkdirLastFailureReason = "parent-not-found";
        return static_cast<uint64_t>(-ENOENT);
      }
      const auto HostPath = ResolveGuestCreationPath(*GuestPath);
      if (!HostPath.has_value()) {
        MkdirLastLinuxError = EACCES;
        MkdirLastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      MkdirLastTargetConfined = true;
      if (mkdir(HostPath->c_str(), static_cast<mode_t>(Mode & 07777)) != 0) {
        MkdirLastLinuxError = errno;
        MkdirLastFailureReason = "host-mkdir-failed";
        return static_cast<uint64_t>(-MkdirLastLinuxError);
      }
      struct stat CreatedStat {};
      if (lstat(HostPath->c_str(), &CreatedStat) != 0 || !S_ISDIR(CreatedStat.st_mode)) {
        MkdirLastLinuxError = EIO;
        MkdirLastFailureReason = "created-target-not-directory";
        return static_cast<uint64_t>(-EIO);
      }
      MkdirLastAppliedMode = static_cast<uint64_t>(CreatedStat.st_mode & 07777);
      ++MkdirSuccessCount;
      return 0;
    }
    if (Number == RenameSyscall && !RootFS.empty()) {
      RenameSeen = true;
      ++RenameCallCount;
      if (RegistryRenameTraceCount < RegistryRenameTrace.size()) {
        auto& Trace = RegistryRenameTrace[RegistryRenameTraceCount++];
        const auto OldGuestPath = ReadGuestPath(Arguments->Argument[1]);
        const auto NewGuestPath = ReadGuestPath(Arguments->Argument[2]);
        Trace.OldPathReadable = OldGuestPath.has_value();
        Trace.NewPathReadable = NewGuestPath.has_value();
        if (OldGuestPath.has_value()) {
          Trace.OldPathClass = OldGuestPath->empty()
            ? "empty"
            : (OldGuestPath->front() == '/' ? "absolute" : "relative");
          Trace.OldPathLength = OldGuestPath->size();
          Trace.OldPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(OldGuestPath->data()),
            OldGuestPath->size());
          if (IsSafeDiagnosticGuestPath(*OldGuestPath)) {
            Trace.OldDiagnosticPath = *OldGuestPath;
          }
          const auto OldHostPath = ResolveGuestPathWithParents(*OldGuestPath);
          Trace.OldHostPathResolved = OldHostPath.has_value();
          if (OldHostPath.has_value()) {
            struct stat OldTargetStat {};
            Trace.OldTargetExists = lstat(OldHostPath->c_str(), &OldTargetStat) == 0;
            if (Trace.OldTargetExists) {
              Trace.OldTargetRegular = S_ISREG(OldTargetStat.st_mode);
              Trace.OldTargetDirectory = S_ISDIR(OldTargetStat.st_mode);
              Trace.OldTargetSymlink = S_ISLNK(OldTargetStat.st_mode);
            }
          }
        }
        if (NewGuestPath.has_value()) {
          Trace.NewPathClass = NewGuestPath->empty()
            ? "empty"
            : (NewGuestPath->front() == '/' ? "absolute" : "relative");
          Trace.NewPathLength = NewGuestPath->size();
          Trace.NewPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(NewGuestPath->data()),
            NewGuestPath->size());
          if (IsSafeDiagnosticGuestPath(*NewGuestPath)) {
            Trace.NewDiagnosticPath = *NewGuestPath;
          }
          const auto NewHostPath = ResolveGuestPathWithParents(*NewGuestPath);
          Trace.NewHostPathResolved = NewHostPath.has_value();
          if (NewHostPath.has_value()) {
            struct stat NewTargetStat {};
            Trace.NewTargetExists = lstat(NewHostPath->c_str(), &NewTargetStat) == 0;
            if (Trace.NewTargetExists) {
              Trace.NewTargetRegular = S_ISREG(NewTargetStat.st_mode);
              Trace.NewTargetDirectory = S_ISDIR(NewTargetStat.st_mode);
              Trace.NewTargetSymlink = S_ISLNK(NewTargetStat.st_mode);
            }
          }
        }
        if (OldGuestPath.has_value() && NewGuestPath.has_value()) {
          const auto OldHostPath = ResolveGuestPathWithParents(*OldGuestPath);
          const auto NewHostPath = ResolveGuestPathWithParents(*NewGuestPath);
          if (OldHostPath.has_value() && NewHostPath.has_value()) {
            const auto ParentOf = [](const std::string& Path) {
              const size_t Separator = Path.find_last_of('/');
              return Separator == std::string::npos ? std::string {} : Path.substr(0, Separator);
            };
            Trace.SameHostParent = ParentOf(*OldHostPath) == ParentOf(*NewHostPath);
          }
        }
      }
      RenameLastHostError = 0;
      RenameLastLinuxError = 0;
      RenameLastFailureReason = "none";
      const auto OldGuestPath = ReadGuestPath(Arguments->Argument[1]);
      const auto NewGuestPath = ReadGuestPath(Arguments->Argument[2]);
      const auto IsRegistryTemporaryBasename = [](const std::string& Path) {
        return Path.size() >= 12
          && Path.starts_with("reg")
          && Path.ends_with(".tmp")
          && Path.find('/') == std::string::npos
          && std::all_of(
            Path.begin() + 3,
            Path.end() - 4,
            [](char Character) {
              return (Character >= '0' && Character <= '9')
                || (Character >= 'a' && Character <= 'f')
                || (Character >= 'A' && Character <= 'F');
            });
      };
      const auto IsRegistryDestinationBasename = [](const std::string& Path) {
        return Path == "system.reg" || Path == "userdef.reg" || Path == "user.reg";
      };
      const bool ExactCandidate = GuestProgram == "/opt/proton/files/bin/wineserver"
        && GuestCurrentWorkingDirectory == "/home/regression/.wine"
        && OldGuestPath.has_value()
        && NewGuestPath.has_value()
        && IsRegistryTemporaryBasename(*OldGuestPath)
        && IsRegistryDestinationBasename(*NewGuestPath)
        && RegistryTemporaryBasenames.contains(*OldGuestPath);
      if (!ExactCandidate) {
        RenameLastLinuxError = ENOTSUP;
        RenameLastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-ENOTSUP);
      }
      ++RenameExactCandidateCount;
      const auto FailRename = [this](
          int LinuxError,
          int HostError,
          const char* FailureReason) -> uint64_t {
        ++RenameFailureCount;
        RenameLastHostError = HostError;
        RenameLastLinuxError = LinuxError;
        RenameLastFailureReason = FailureReason;
        return static_cast<uint64_t>(-LinuxError);
      };
      const auto OldHostPath = ResolveGuestCreationPath(*OldGuestPath);
      const auto NewHostPath = ResolveGuestCreationPath(*NewGuestPath);
      if (!OldHostPath.has_value() || !NewHostPath.has_value()) {
        return FailRename(EACCES, 0, "path-resolution-rejected");
      }
      const auto ParentOf = [](const std::string& Path) {
        const size_t Separator = Path.find_last_of('/');
        return Separator == std::string::npos ? std::string {} : Path.substr(0, Separator);
      };
      if (ParentOf(*OldHostPath) != ParentOf(*NewHostPath)) {
        return FailRename(EXDEV, 0, "different-host-parent");
      }
      struct stat OldTargetStat {};
      if (lstat(OldHostPath->c_str(), &OldTargetStat) != 0) {
        const int HostError = errno;
        return FailRename(
          TranslateHostRenameErrorToLinux(HostError),
          HostError,
          "source-lstat-failed");
      }
      if (!S_ISREG(OldTargetStat.st_mode) || S_ISLNK(OldTargetStat.st_mode)) {
        return FailRename(EACCES, 0, "source-not-regular");
      }
      struct stat NewTargetStat {};
      if (lstat(NewHostPath->c_str(), &NewTargetStat) == 0) {
        if (!S_ISREG(NewTargetStat.st_mode) || S_ISLNK(NewTargetStat.st_mode)) {
          return FailRename(EACCES, 0, "destination-not-regular");
        }
      } else if (errno != ENOENT) {
        const int HostError = errno;
        return FailRename(
          TranslateHostRenameErrorToLinux(HostError),
          HostError,
          "destination-lstat-failed");
      }
      if (std::rename(OldHostPath->c_str(), NewHostPath->c_str()) != 0) {
        const int HostError = errno;
        return FailRename(
          TranslateHostRenameErrorToLinux(HostError),
          HostError,
          "host-rename-failed");
      }
      RegistryTemporaryBasenames.erase(*OldGuestPath);
      ++RenameSuccessCount;
      return 0;
    }
    if (Number == UnlinkSyscall && !RootFS.empty()) {
      UnlinkSeen = true;
      ++UnlinkCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      UnlinkLastHostPathResolved = false;
      UnlinkLastTargetExists = false;
      UnlinkLastTargetSocket = false;
      UnlinkLastLinuxError = 0;
      UnlinkLastFailureReason = "none";
      if (!GuestPath.has_value()) {
        UnlinkLastPathClass = "unreadable";
        UnlinkLastLinuxError = EFAULT;
        UnlinkLastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      UnlinkLastPathLength = GuestPath->size();
      UnlinkLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      UnlinkLastPathClass = GuestPath->empty()
        ? "empty"
        : (GuestPath->front() == '/' ? "absolute" : "relative");
      TraceGuestPath("unlink", *GuestPath);

      // La fuente pública de Wine y la A/B v20 coinciden: wineserver solo
      // retira el endpoint relativo "socket" mientras mantiene su lock.
      if (*GuestPath != "socket") {
        UnlinkLastLinuxError = ENOTSUP;
        UnlinkLastFailureReason = "non-wineserver-socket-path";
        return static_cast<uint64_t>(-ENOTSUP);
      }
      const auto HostPath = ResolveGuestCreationPath(*GuestPath);
      if (!HostPath.has_value()) {
        UnlinkLastLinuxError = EACCES;
        UnlinkLastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      UnlinkLastHostPathResolved = true;
      struct stat TargetStat {};
      if (lstat(HostPath->c_str(), &TargetStat) == 0) {
        UnlinkLastTargetExists = true;
        UnlinkLastTargetSocket = S_ISSOCK(TargetStat.st_mode);
        if (!UnlinkLastTargetSocket) {
          UnlinkLastLinuxError = EACCES;
          UnlinkLastFailureReason = "target-not-socket";
          return static_cast<uint64_t>(-EACCES);
        }
      }
      if (unlink(HostPath->c_str()) != 0) {
        UnlinkLastLinuxError = errno;
        UnlinkLastFailureReason = UnlinkLastLinuxError == ENOENT
          ? "target-missing"
          : "host-unlink-failed";
        if (UnlinkLastLinuxError == ENOENT) {
          ++UnlinkMissingTargetCount;
        }
        return static_cast<uint64_t>(-UnlinkLastLinuxError);
      }
      ++UnlinkSuccessCount;
      return 0;
    }
    if (Number == ChmodSyscall && !RootFS.empty()) {
      ChmodSeen = true;
      ++ChmodCallCount;
      constexpr uint64_t ObservedSocketMode = 0600;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t Mode = Arguments->Argument[2];
      ChmodLastMode = Mode;
      ChmodLastAppliedMode = 0;
      ChmodLastTargetSocket = false;
      ChmodLastLinuxError = 0;
      ChmodLastFailureReason = "none";
      if (!GuestPath.has_value()) {
        ChmodLastPathClass = "unreadable";
        ChmodLastLinuxError = EFAULT;
        ChmodLastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      ChmodLastPathLength = GuestPath->size();
      ChmodLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      ChmodLastPathClass = GuestPath->empty()
        ? "empty"
        : (GuestPath->front() == '/' ? "absolute" : "relative");
      TraceGuestPath("chmod", *GuestPath);
      if (*GuestPath != "socket" || Mode != ObservedSocketMode) {
        ChmodLastLinuxError = ENOTSUP;
        ChmodLastFailureReason = "non-wineserver-socket-shape";
        return static_cast<uint64_t>(-ENOTSUP);
      }
      const auto HostPath = ResolveGuestCreationPath(*GuestPath);
      if (!HostPath.has_value()) {
        ChmodLastLinuxError = EACCES;
        ChmodLastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      struct stat TargetStat {};
      if (lstat(HostPath->c_str(), &TargetStat) != 0) {
        ChmodLastLinuxError = errno;
        ChmodLastFailureReason = "host-lstat-failed";
        return static_cast<uint64_t>(-ChmodLastLinuxError);
      }
      ChmodLastTargetSocket = S_ISSOCK(TargetStat.st_mode);
      if (!ChmodLastTargetSocket) {
        ChmodLastLinuxError = EACCES;
        ChmodLastFailureReason = "target-not-socket";
        return static_cast<uint64_t>(-EACCES);
      }
      if (chmod(HostPath->c_str(), static_cast<mode_t>(Mode)) != 0) {
        ChmodLastLinuxError = errno;
        ChmodLastFailureReason = "host-chmod-failed";
        return static_cast<uint64_t>(-ChmodLastLinuxError);
      }
      struct stat AppliedStat {};
      if (lstat(HostPath->c_str(), &AppliedStat) != 0 || !S_ISSOCK(AppliedStat.st_mode)) {
        ChmodLastLinuxError = EIO;
        ChmodLastFailureReason = "socket-verification-failed";
        return static_cast<uint64_t>(-EIO);
      }
      ChmodLastAppliedMode = AppliedStat.st_mode & 07777;
      if (ChmodLastAppliedMode != Mode) {
        ChmodLastLinuxError = EIO;
        ChmodLastFailureReason = "mode-verification-failed";
        return static_cast<uint64_t>(-EIO);
      }
      ++ChmodSuccessCount;
      return 0;
    }
    if (Number == SymlinkSyscall && !RootFS.empty()) {
      SymlinkSeen = true;
      ++SymlinkCallCount;
      const auto GuestTarget = ReadGuestPath(Arguments->Argument[1]);
      const auto GuestLink = ReadGuestPath(Arguments->Argument[2]);
      SymlinkLastLinuxError = 0;
      SymlinkLastFailureReason = "none";
      SymlinkLastTargetConfined = false;
      SymlinkLastLinkConfined = false;
      SymlinkLastTargetReproduced = false;
      if (!GuestTarget.has_value() || !GuestLink.has_value()) {
        SymlinkLastTargetClass = GuestTarget.has_value() ? "readable" : "unreadable";
        SymlinkLastLinkClass = GuestLink.has_value() ? "readable" : "unreadable";
        SymlinkLastLinuxError = EFAULT;
        SymlinkLastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      SymlinkLastTargetLength = GuestTarget->size();
      SymlinkLastTargetFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestTarget->data()),
        GuestTarget->size());
      SymlinkLastLinkLength = GuestLink->size();
      SymlinkLastLinkFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestLink->data()),
        GuestLink->size());
      SymlinkLastTargetClass = GuestTarget->empty()
        ? "empty"
        : (GuestTarget->front() == '/' ? "absolute" : "relative");
      SymlinkLastLinkClass = GuestLink->empty()
        ? "empty"
        : (GuestLink->front() == '/' ? "absolute" : "relative");
      TraceGuestPath("symlink-target", *GuestTarget);
      TraceGuestPath("symlink-link", *GuestLink);
      const auto HostLink = ResolveGuestRelativeSymlink(*GuestTarget, *GuestLink);
      if (!HostLink.has_value()) {
        SymlinkLastLinuxError = EACCES;
        SymlinkLastFailureReason = "path-resolution-rejected";
        return static_cast<uint64_t>(-EACCES);
      }
      SymlinkLastTargetConfined = true;
      SymlinkLastLinkConfined = true;
      if (symlink(GuestTarget->c_str(), HostLink->c_str()) != 0) {
        SymlinkLastLinuxError = errno;
        SymlinkLastFailureReason = "host-symlink-failed";
        return static_cast<uint64_t>(-SymlinkLastLinuxError);
      }
      struct stat LinkStat {};
      std::array<char, 4096> LinkContents {};
      const ssize_t LinkLength = readlink(
        HostLink->c_str(),
        LinkContents.data(),
        LinkContents.size());
      if (lstat(HostLink->c_str(), &LinkStat) != 0
          || !S_ISLNK(LinkStat.st_mode)
          || LinkLength < 0
          || static_cast<size_t>(LinkLength) != GuestTarget->size()
          || std::memcmp(LinkContents.data(), GuestTarget->data(), GuestTarget->size()) != 0) {
        SymlinkLastLinuxError = EIO;
        SymlinkLastFailureReason = "created-link-mismatch";
        return static_cast<uint64_t>(-EIO);
      }
      SymlinkLastTargetReproduced = true;
      ++SymlinkSuccessCount;
      return 0;
    }
    if (Number == ReadlinkSyscall && !RootFS.empty()) {
      ReadlinkSeen = true;
      ++ReadlinkCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t GuestBuffer = Arguments->Argument[2];
      const uint64_t BufferSize = Arguments->Argument[3];
      if (!GuestPath.has_value()) {
        return static_cast<uint64_t>(-EFAULT);
      }
      TraceGuestPath("readlink", *GuestPath);
      if (BufferSize == 0) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (GuestProgram.empty()) {
        return static_cast<uint64_t>(-ENOENT);
      }
      if (*GuestPath != "/proc/self/exe" && *GuestPath != "/proc/thread-self/exe") {
        return static_cast<uint64_t>(-EINVAL);
      }
      const uint64_t ResultSize = std::min<uint64_t>(BufferSize, GuestProgram.size());
      if (!Contains(GuestBuffer, ResultSize)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      std::memcpy(reinterpret_cast<void*>(GuestBuffer), GuestProgram.data(), static_cast<size_t>(ResultSize));
      ++ReadlinkSuccessCount;
      ++ReadlinkProcSelfExeCount;
      return ResultSize;
    }
    if (Number == WriteVSyscall && !RootFS.empty()) {
      WriteVSeen = true;
      ++WriteVCallCount;
      constexpr uint64_t LinuxIOVectorMaximum = 1024;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestVectors = Arguments->Argument[2];
      const uint64_t VectorCount = Arguments->Argument[3];
      if ((Descriptor != STDOUT_FILENO && Descriptor != STDERR_FILENO)
          || ClosedStandardDescriptors.contains(Descriptor)) {
        constexpr uint64_t MeasuredWineReplyHeaderSize = 64;
        constexpr uint64_t MeasuredWineInitReplyPayloadSize = 4;
        constexpr uint64_t MeasuredWineDefaultDaclReplyPayloadSize = 28;
        constexpr uint64_t MeasuredWineVariableReplyPayloadSize = 162;
        constexpr uint64_t MeasuredWineSecondVariableReplyPayloadSize = 171;
        constexpr uint64_t MeasuredWineSecondVariableReplyFingerprint =
          10951602325348628875ULL;
        constexpr uint64_t MeasuredWineRequestHeaderSize = 64;
        constexpr uint64_t MeasuredWineOpenMappingRequestPayloadSize = 76;
        constexpr uint64_t MeasuredWineCreateKeyRequestPrimaryPayloadSize = 112;
        constexpr uint64_t MeasuredWineCreateKeyRequestAlternatePayloadSize = 108;
        constexpr uint64_t MeasuredWineCreateKeyRequestThirdPayloadSize = 128;
        constexpr uint64_t MeasuredWineCreateKeyRequestFourthPayloadSize = 140;
        constexpr uint64_t MeasuredWineCreateKeyRequestFifthPayloadSize = 136;
        constexpr uint64_t MeasuredWineCreateKeyRequestSixthPayloadSize = 84;
        constexpr uint32_t MeasuredWineCreateKeyRequestCode = 86;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestPayloadSize = 24;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestAlternatePayloadSize = 34;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestThirdPayloadSize = 26;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestFourthPayloadSize = 18;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestFifthPayloadSize = 16;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestSixthPayloadSize = 14;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestSeventhPayloadSize = 50;
        constexpr uint64_t MeasuredWineEnumKeyValueRequestEighthPayloadSize = 28;
        constexpr uint32_t MeasuredWineEnumKeyValueRequestCode = 93;
        constexpr uint32_t MeasuredWineEnumKeyValueReplySize = 68;
        constexpr uint32_t MeasuredWineEnumKeyValueSixthReplySize = 114;
        constexpr uint64_t MeasuredWineEnumKeyValueSixthPayloadFingerprint =
          16460010522796114687ULL;
        constexpr uint32_t MeasuredWineEnumKeyValueSeventhReplySize = 51;
        constexpr uint64_t MeasuredWineEnumKeyValueSeventhPayloadFingerprint =
          7421093395229464502ULL;
        constexpr uint32_t MeasuredWineEnumKeyValueEighthReplySize = 51;
        constexpr uint64_t MeasuredWineEnumKeyValueEighthPayloadFingerprint =
          9917584591413673814ULL;
        constexpr uint32_t MeasuredWineEnumKeyValueNinthReplySize = 68;
        constexpr uint64_t MeasuredWineEnumKeyValueNinthPayloadFingerprint =
          36714261633148441ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestPrimaryPayloadSize = 156;
        constexpr uint64_t MeasuredWineOpenKeyRequestAlternatePayloadSize = 148;
        constexpr uint64_t MeasuredWineOpenKeyRequestThirdPayloadSize = 118;
        constexpr uint64_t MeasuredWineOpenKeyRequestFourthPayloadSize = 164;
        constexpr uint64_t MeasuredWineOpenKeyRequestFifthPayloadSize = 132;
        constexpr uint64_t MeasuredWineOpenKeyRequestSixthPayloadSize = 182;
        constexpr uint64_t MeasuredWineOpenKeyRequestSeventhPayloadSize = 44;
        constexpr uint64_t MeasuredWineOpenKeyRequestEighthPayloadSize = 26;
        constexpr uint64_t MeasuredWineOpenKeyRequestNinthPayloadSize = 42;
        constexpr uint64_t MeasuredWineOpenKeyRequestTenthPayloadSize = 124;
        constexpr uint32_t MeasuredWineOpenKeyRequestCode = 87;
        constexpr uint32_t MeasuredWineOpenKeyRequestParent = 0;
        constexpr uint32_t MeasuredWineOpenKeyRequestAccess = 1;
        constexpr uint32_t MeasuredWineOpenKeyRequestAttributes = 64;
        constexpr uint64_t MeasuredWineOpenKeyRequestNameFingerprint =
          7694259118615906934ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestSixthNameFingerprint =
          2092701008132515287ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestSeventhNameFingerprint =
          16012710392547241188ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestEighthNameFingerprint =
          8069394229556537835ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestNinthNameFingerprint =
          7804196268085175278ULL;
        constexpr uint64_t MeasuredWineOpenKeyRequestTenthNameFingerprint =
          5926441467455827968ULL;
        constexpr uint64_t MeasuredWineCreateEventRequestPayloadSize = 80;
        constexpr uint32_t MeasuredWineCreateEventRequestCode = 30;
        constexpr uint32_t MeasuredWineCreateSymlinkRequestCode = 242;
        constexpr uint64_t MeasuredWineCreateSymlinkRequestPayloadSize = 20;
        constexpr uint32_t MeasuredWineCreateSymlinkRequestAccess = 983055;
        constexpr uint64_t MeasuredWineCreateSymlinkTargetFingerprint =
          7446848526332491749ULL;
        constexpr uint32_t MeasuredWineNewProcessRequestCode = 0;
        constexpr uint64_t MeasuredWineNewProcessObjectAttributesSize = 16;
        constexpr uint64_t MeasuredWineNewProcessStartupInfoSize = 354;
        constexpr uint64_t MinimumWineNewProcessEnvironmentSize =
          2 * sizeof(uint16_t);
        constexpr uint64_t MaximumWineNewProcessEnvironmentSize =
          1024ULL * 1024ULL;
        constexpr uint32_t MeasuredWineCreateFileRequestCode = 44;
        constexpr uint64_t MeasuredWineCreateFileObjectAttributesSize = 84;
        constexpr uint64_t MeasuredWineCreateFileNameSize = 51;
        constexpr uint64_t MeasuredWineCreateFileAlternateNameSize = 36;
        constexpr uint64_t MeasuredWineCreateFileThirdObjectAttributesSize = 96;
        constexpr uint64_t MeasuredWineCreateFileThirdNameSize = 58;
        constexpr uint32_t MeasuredWineCreateFileThirdAccess = 0x80100000U;
        constexpr uint32_t MeasuredWineCreateFileThirdSharing = 5;
        constexpr int32_t MeasuredWineCreateFileThirdDisposition = 1;
        constexpr uint32_t MeasuredWineCreateFileThirdOptions = 96;
        constexpr uint32_t MeasuredWineCreateFileThirdAttributes = 0;
        constexpr uint32_t MeasuredWineCreateFileThirdRootDirectory = 0;
        constexpr uint32_t MeasuredWineCreateFileThirdObjectAttributes = 0;
        constexpr uint32_t MeasuredWineCreateFileThirdSecurityDescriptorLength = 0;
        constexpr uint32_t MeasuredWineCreateFileThirdObjectNameLength = 80;
        constexpr uint64_t MeasuredWineCreateFileThirdObjectNameFingerprint =
          14801784545170724346ULL;
        constexpr uint64_t MeasuredWineCreateFileThirdUnixNameFingerprint =
          9302369010083266512ULL;
        constexpr uint64_t MeasuredWineCreateFileFourthObjectAttributesSize = 64;
        constexpr uint64_t MeasuredWineCreateFileFourthNameSize = 54;
        constexpr uint32_t MeasuredWineCreateFileFourthAccess = 0x00100020U;
        constexpr uint32_t MeasuredWineCreateFileFourthSharing = 5;
        constexpr int32_t MeasuredWineCreateFileFourthDisposition = 1;
        constexpr uint32_t MeasuredWineCreateFileFourthOptions = 32;
        constexpr uint32_t MeasuredWineCreateFileFourthAttributes = 0;
        constexpr uint32_t MeasuredWineCreateFileFourthRootDirectory = 0;
        constexpr uint32_t MeasuredWineCreateFileFourthObjectAttributes = 64;
        constexpr uint32_t MeasuredWineCreateFileFourthSecurityDescriptorLength = 0;
        constexpr uint32_t MeasuredWineCreateFileFourthObjectNameLength = 46;
        constexpr uint64_t MeasuredWineCreateFileFourthObjectNameFingerprint =
          16621620404146942047ULL;
        constexpr uint64_t MeasuredWineCreateFileFourthUnixNameFingerprint =
          12682502960721649899ULL;
        struct stat ReplyDescriptorStat {};
        const bool ReplyDescriptorStatSucceeded = fstat(Descriptor, &ReplyDescriptorStat) == 0;
        const int ReplyDescriptorFlags = fcntl(Descriptor, F_GETFD);
        const LinuxIOVector64* ReplyVectors {};
        const bool MeasuredWineVectorCount = VectorCount == 2
          || VectorCount == 3
          || VectorCount == 4;
        const uint64_t MeasuredWineVectorSpan = VectorCount * sizeof(LinuxIOVector64);
        if (MeasuredWineVectorCount) {
          ReplyVectors = static_cast<const LinuxIOVector64*>(
            HostPointerForGuestRange(
              GuestVectors,
              MeasuredWineVectorSpan,
              PROT_READ));
        }
        const auto ResolveReplyPayload = [&](const LinuxIOVector64& Vector) -> const void* {
          if (Vector.Length == 0) {
            return nullptr;
          }
          return HostPointerForGuestRange(Vector.Base, Vector.Length, PROT_READ);
        };
        const void* ReplyHeader = ReplyVectors ? ResolveReplyPayload(ReplyVectors[0]) : nullptr;
        const void* ReplyPayload = ReplyVectors ? ResolveReplyPayload(ReplyVectors[1]) : nullptr;
        const void* ReplyPayload3 = ReplyVectors && VectorCount >= 3
          ? ResolveReplyPayload(ReplyVectors[2])
          : nullptr;
        const void* ReplyPayload4 = ReplyVectors && VectorCount >= 4
          ? ResolveReplyPayload(ReplyVectors[3])
          : nullptr;
        uint32_t ReplyHeaderError {};
        uint32_t ReplyHeaderDeclaredSize {};
        uint32_t RequestHeaderCode {};
        uint32_t RequestHeaderRequestSize {};
        uint32_t RequestHeaderReplySize {};
        uint32_t RequestHeaderInfoSize {};
        uint32_t RequestHeaderHandlesSize {};
        uint32_t RequestHeaderJobsSize {};
        uint32_t RequestOpenKeyParent {};
        uint32_t RequestOpenKeyAccess {};
        uint32_t RequestOpenKeyAttributes {};
        bool RequestOpenKeyFixedFieldsReadable {};
        bool RequestOpenKeyNameEvenLength {};
        bool RequestOpenKeyNameHasEmbeddedNull {};
        uint64_t RequestOpenKeyNameFingerprint {};
        if (ReplyHeader) {
          const auto* ReplyHeaderBytes = static_cast<const uint8_t*>(ReplyHeader);
          std::memcpy(&ReplyHeaderError, ReplyHeaderBytes, sizeof(ReplyHeaderError));
          std::memcpy(
            &ReplyHeaderDeclaredSize,
            ReplyHeaderBytes + sizeof(ReplyHeaderError),
            sizeof(ReplyHeaderDeclaredSize));
          std::memcpy(
            &RequestHeaderCode,
            ReplyHeaderBytes,
            sizeof(RequestHeaderCode));
          std::memcpy(
            &RequestHeaderRequestSize,
            ReplyHeaderBytes + 4,
            sizeof(RequestHeaderRequestSize));
          std::memcpy(
            &RequestHeaderReplySize,
            ReplyHeaderBytes + 8,
            sizeof(RequestHeaderReplySize));
          if (ReplyVectors[0].Length >= 52) {
            std::memcpy(
              &RequestHeaderInfoSize,
              ReplyHeaderBytes + 40,
              sizeof(RequestHeaderInfoSize));
            std::memcpy(
              &RequestHeaderHandlesSize,
              ReplyHeaderBytes + 44,
              sizeof(RequestHeaderHandlesSize));
            std::memcpy(
              &RequestHeaderJobsSize,
              ReplyHeaderBytes + 48,
              sizeof(RequestHeaderJobsSize));
          }
          if (ReplyVectors[0].Length >= 24) {
            std::memcpy(
              &RequestOpenKeyParent,
              ReplyHeaderBytes + 12,
              sizeof(RequestOpenKeyParent));
            std::memcpy(
              &RequestOpenKeyAccess,
              ReplyHeaderBytes + 16,
              sizeof(RequestOpenKeyAccess));
            std::memcpy(
              &RequestOpenKeyAttributes,
              ReplyHeaderBytes + 20,
              sizeof(RequestOpenKeyAttributes));
            RequestOpenKeyFixedFieldsReadable = true;
          }
        }
        if (ReplyPayload && ReplyVectors[1].Length <= 4096) {
          const auto* Name = static_cast<const uint8_t*>(ReplyPayload);
          RequestOpenKeyNameEvenLength =
            ReplyVectors[1].Length % sizeof(uint16_t) == 0;
          RequestOpenKeyNameFingerprint = FingerprintBytes(
            Name,
            static_cast<size_t>(ReplyVectors[1].Length));
          if (RequestOpenKeyNameEvenLength) {
            for (uint64_t Offset = 0; Offset < ReplyVectors[1].Length;
                 Offset += sizeof(uint16_t)) {
              uint16_t CodeUnit {};
              std::memcpy(&CodeUnit, Name + Offset, sizeof(CodeUnit));
              if (CodeUnit == 0) {
                RequestOpenKeyNameHasEmbeddedNull = true;
                break;
              }
            }
          }
        }
        const bool MeasuredWineInitReplyShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineInitReplyPayloadSize;
        const bool MeasuredWineDefaultDaclReplyShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineDefaultDaclReplyPayloadSize
          && ReplyHeaderError == 0
          && ReplyHeaderDeclaredSize == MeasuredWineDefaultDaclReplyPayloadSize;
        const bool MeasuredWineVariableReplyShape = GuestProgram
            == "/opt/proton/files/bin/wineserver"
          && ReplyVectors
          && ReplyDescriptorFlags == 0
          && ReplyHeaderError == 0
          && ReplyHeaderDeclaredSize == ReplyVectors[1].Length
          && (ReplyVectors[1].Length == MeasuredWineVariableReplyPayloadSize
            || (ReplyVectors[1].Length == MeasuredWineSecondVariableReplyPayloadSize
              && ReplyPayload
              && FingerprintBytes(
                static_cast<const uint8_t*>(ReplyPayload),
                static_cast<size_t>(ReplyVectors[1].Length))
                == MeasuredWineSecondVariableReplyFingerprint));
        const bool ExactWineReply = Descriptor != STDOUT_FILENO
          && Descriptor != STDERR_FILENO
          && VectorCount == 2
          && OwnedDescriptors.contains(Descriptor)
          && ReceivedSCMRightsDescriptors.contains(Descriptor)
          && ReplyDescriptorFlags != -1
          && ReplyDescriptorStatSucceeded
          && S_ISFIFO(ReplyDescriptorStat.st_mode)
          && ReplyVectors
          && ReplyVectors[0].Length == MeasuredWineReplyHeaderSize
          && (MeasuredWineInitReplyShape
            || MeasuredWineDefaultDaclReplyShape
            || MeasuredWineVariableReplyShape)
          && ReplyHeader
          && ReplyPayload;
        if (ExactWineReply) {
          TraceWineReplyHeader(
            "writev",
            Descriptor,
            ReplyHeader,
            static_cast<size_t>(MeasuredWineReplyHeaderSize));
          ++WriteVWineReplyCandidateCount;
          if (MeasuredWineDefaultDaclReplyShape) {
            ++WriteVWineDefaultDaclReplyCandidateCount;
          }
          if (MeasuredWineVariableReplyShape) {
            ++WriteVWineVariableReplyCandidateCount;
          }
          WriteVWineReplyLastDescriptor = Descriptor;
          WriteVWineReplyLastVectorCount = VectorCount;
          WriteVWineReplyLastRequestedByteCount =
            ReplyVectors[0].Length + ReplyVectors[1].Length;
          std::array<iovec, 2> HostVectors {{
            {const_cast<void*>(ReplyHeader), static_cast<size_t>(ReplyVectors[0].Length)},
            {const_cast<void*>(ReplyPayload), static_cast<size_t>(ReplyVectors[1].Length)},
          }};
          errno = 0;
          const ssize_t Result = ::writev(Descriptor, HostVectors.data(), HostVectors.size());
          WriteVWineReplyLastReturnedByteCount = Result;
          if (Result < 0) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            ++WriteVWineReplyFailureCount;
            if (MeasuredWineDefaultDaclReplyShape) {
              ++WriteVWineDefaultDaclReplyFailureCount;
            }
            if (MeasuredWineVariableReplyShape) {
              ++WriteVWineVariableReplyFailureCount;
            }
            WriteVWineReplyLastHostError = HostError;
            WriteVWineReplyLastLinuxError = LinuxError;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteVWineReplySuccessCount;
          if (MeasuredWineDefaultDaclReplyShape) {
            ++WriteVWineDefaultDaclReplySuccessCount;
          }
          if (MeasuredWineVariableReplyShape) {
            ++WriteVWineVariableReplySuccessCount;
          }
          ++WriteVSuccessCount;
          WriteVVectorCount += VectorCount;
          WriteVByteCount += static_cast<uint64_t>(Result);
          WriteVWineReplyLastHostError = 0;
          WriteVWineReplyLastLinuxError = 0;
          return static_cast<uint64_t>(Result);
        }
        const bool MeasuredWineOpenMappingRequestShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenMappingRequestPayloadSize;
        const bool MeasuredWineCreateKeyRequestPayloadShape = ReplyVectors
          && (ReplyVectors[1].Length == MeasuredWineCreateKeyRequestPrimaryPayloadSize
            || ReplyVectors[1].Length == MeasuredWineCreateKeyRequestAlternatePayloadSize
            || ReplyVectors[1].Length == MeasuredWineCreateKeyRequestThirdPayloadSize
            || ReplyVectors[1].Length == MeasuredWineCreateKeyRequestFourthPayloadSize);
        const bool MeasuredWineCreateKeyFifthRequestPayloadShape = [&] {
          if (!ReplyHeader || !ReplyPayload || !ReplyVectors
              || ReplyVectors[0].Length != MeasuredWineRequestHeaderSize
              || ReplyVectors[1].Length != MeasuredWineCreateKeyRequestFifthPayloadSize) {
            return false;
          }
          const auto* Fixed = static_cast<const uint8_t*>(ReplyHeader);
          const auto* Payload = static_cast<const uint8_t*>(ReplyPayload);
          uint32_t Access {};
          uint32_t Options {};
          uint32_t RootDirectory {};
          uint32_t Attributes {};
          uint32_t SecurityDescriptorLength {};
          uint32_t NameLength {};
          std::memcpy(&Access, Fixed + 12, sizeof(Access));
          std::memcpy(&Options, Fixed + 16, sizeof(Options));
          std::memcpy(&RootDirectory, Payload, sizeof(RootDirectory));
          std::memcpy(&Attributes, Payload + 4, sizeof(Attributes));
          std::memcpy(
            &SecurityDescriptorLength,
            Payload + 8,
            sizeof(SecurityDescriptorLength));
          std::memcpy(&NameLength, Payload + 12, sizeof(NameLength));
          const uint64_t ObjectAttributesLength =
            (16 + (uint64_t {SecurityDescriptorLength} & ~uint64_t {1})
              + (uint64_t {NameLength} & ~uint64_t {1}) + 3) & ~uint64_t {3};
          return Access == 983103
            && Options == 0
            && RootDirectory == 0
            && Attributes == 192
            && SecurityDescriptorLength == 0
            && NameLength == 120
            && ObjectAttributesLength == ReplyVectors[1].Length
            && NameLength % 2 == 0
            && FingerprintBytes(Payload + 16, NameLength)
              == 13414519971843043962ULL
            && FingerprintBytes(Payload + ObjectAttributesLength, 0)
              == 14695981039346656037ULL;
        }();
        const bool MeasuredWineCreateKeySixthRequestPayloadShape = [&] {
          if (!ReplyHeader || !ReplyPayload || !ReplyVectors
              || ReplyVectors[0].Length != MeasuredWineRequestHeaderSize
              || ReplyVectors[1].Length != MeasuredWineCreateKeyRequestSixthPayloadSize) {
            return false;
          }
          const auto* Fixed = static_cast<const uint8_t*>(ReplyHeader);
          const auto* Payload = static_cast<const uint8_t*>(ReplyPayload);
          uint32_t Access {};
          uint32_t Options {};
          uint32_t RootDirectory {};
          uint32_t Attributes {};
          uint32_t SecurityDescriptorLength {};
          uint32_t NameLength {};
          std::memcpy(&Access, Fixed + 12, sizeof(Access));
          std::memcpy(&Options, Fixed + 16, sizeof(Options));
          std::memcpy(&RootDirectory, Payload, sizeof(RootDirectory));
          std::memcpy(&Attributes, Payload + 4, sizeof(Attributes));
          std::memcpy(
            &SecurityDescriptorLength,
            Payload + 8,
            sizeof(SecurityDescriptorLength));
          std::memcpy(&NameLength, Payload + 12, sizeof(NameLength));
          const uint64_t ObjectAttributesLength =
            (16 + (uint64_t {SecurityDescriptorLength} & ~uint64_t {1})
              + (uint64_t {NameLength} & ~uint64_t {1}) + 3) & ~uint64_t {3};
          return Access == 983103
            && Options == 0
            && RootDirectory == 0
            && Attributes == 192
            && SecurityDescriptorLength == 0
            && NameLength == 68
            && ObjectAttributesLength == ReplyVectors[1].Length
            && NameLength % 2 == 0
            && FingerprintBytes(Payload + 16, NameLength)
              == 16432771884631432949ULL
            && FingerprintBytes(Payload + ObjectAttributesLength, 0)
              == 14695981039346656037ULL;
        }();
        const bool MeasuredWineCreateKeyRequestShape =
          (MeasuredWineCreateKeyRequestPayloadShape
            || MeasuredWineCreateKeyFifthRequestPayloadShape
            || MeasuredWineCreateKeySixthRequestPayloadShape)
          && RequestHeaderCode == MeasuredWineCreateKeyRequestCode
          && RequestHeaderRequestSize == ReplyVectors[1].Length
          && RequestHeaderReplySize == 0;
        const bool MeasuredWineEnumKeyValueKnownRequestPayloadShape = ReplyVectors
          && (ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestPayloadSize
            || ReplyVectors[1].Length
              == MeasuredWineEnumKeyValueRequestAlternatePayloadSize
            || ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestThirdPayloadSize
            || ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestFourthPayloadSize
            || ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestFifthPayloadSize)
          && RequestHeaderReplySize == MeasuredWineEnumKeyValueReplySize;
        const bool MeasuredWineEnumKeyValueSixthRequestPayloadShape = ReplyVectors
          && ReplyPayload
          && ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestSixthPayloadSize
          && RequestHeaderReplySize == MeasuredWineEnumKeyValueSixthReplySize
          && FingerprintBytes(
            static_cast<const uint8_t*>(ReplyPayload),
            ReplyVectors[1].Length)
            == MeasuredWineEnumKeyValueSixthPayloadFingerprint;
        const bool MeasuredWineEnumKeyValueSeventhRequestPayloadShape = ReplyVectors
          && ReplyPayload
          && ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestSeventhPayloadSize
          && RequestHeaderReplySize == MeasuredWineEnumKeyValueSeventhReplySize
          && FingerprintBytes(
            static_cast<const uint8_t*>(ReplyPayload),
            ReplyVectors[1].Length)
            == MeasuredWineEnumKeyValueSeventhPayloadFingerprint;
        const bool MeasuredWineEnumKeyValueEighthRequestPayloadShape = ReplyVectors
          && ReplyPayload
          && ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestEighthPayloadSize
          && RequestHeaderReplySize == MeasuredWineEnumKeyValueEighthReplySize
          && FingerprintBytes(
            static_cast<const uint8_t*>(ReplyPayload),
            ReplyVectors[1].Length)
            == MeasuredWineEnumKeyValueEighthPayloadFingerprint;
        const bool MeasuredWineEnumKeyValueNinthRequestPayloadShape = ReplyVectors
          && ReplyPayload
          && ReplyVectors[1].Length == MeasuredWineEnumKeyValueRequestSixthPayloadSize
          && RequestHeaderReplySize == MeasuredWineEnumKeyValueNinthReplySize
          && FingerprintBytes(
            static_cast<const uint8_t*>(ReplyPayload),
            ReplyVectors[1].Length)
            == MeasuredWineEnumKeyValueNinthPayloadFingerprint;
        const bool MeasuredWineEnumKeyValueRequestShape = ReplyVectors
          && (MeasuredWineEnumKeyValueKnownRequestPayloadShape
            || MeasuredWineEnumKeyValueSixthRequestPayloadShape
            || MeasuredWineEnumKeyValueSeventhRequestPayloadShape
            || MeasuredWineEnumKeyValueEighthRequestPayloadShape
            || MeasuredWineEnumKeyValueNinthRequestPayloadShape)
          && RequestHeaderCode == MeasuredWineEnumKeyValueRequestCode
          && RequestHeaderRequestSize == ReplyVectors[1].Length
          && RequestHeaderReplySize != 0;
        const bool MeasuredWineOpenKeyKnownRequestPayloadShape = ReplyVectors
          && (ReplyVectors[1].Length == MeasuredWineOpenKeyRequestPrimaryPayloadSize
            || ReplyVectors[1].Length == MeasuredWineOpenKeyRequestAlternatePayloadSize
            || ReplyVectors[1].Length == MeasuredWineOpenKeyRequestThirdPayloadSize
            || ReplyVectors[1].Length == MeasuredWineOpenKeyRequestFourthPayloadSize);
        const bool MeasuredWineOpenKeyFifthRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestFifthPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == MeasuredWineOpenKeyRequestParent
          && RequestOpenKeyAccess == MeasuredWineOpenKeyRequestAccess
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestNameFingerprint;
        const bool MeasuredWineOpenKeySixthRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestSixthPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == MeasuredWineOpenKeyRequestParent
          && RequestOpenKeyAccess == MeasuredWineOpenKeyRequestAccess
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestSixthNameFingerprint;
        const bool MeasuredWineOpenKeySeventhRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestSeventhPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == 20
          && RequestOpenKeyAccess == 983103
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestSeventhNameFingerprint;
        const bool MeasuredWineOpenKeyEighthRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestEighthPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == 24
          && RequestOpenKeyAccess == 983103
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestEighthNameFingerprint;
        const bool MeasuredWineOpenKeyNinthRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestNinthPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == 28
          && RequestOpenKeyAccess == 983103
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestNinthNameFingerprint;
        const bool MeasuredWineOpenKeyTenthRequestPayloadShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineOpenKeyRequestTenthPayloadSize
          && RequestOpenKeyFixedFieldsReadable
          && RequestOpenKeyParent == 0
          && RequestOpenKeyAccess == 983103
          && RequestOpenKeyAttributes == MeasuredWineOpenKeyRequestAttributes
          && RequestOpenKeyNameEvenLength
          && !RequestOpenKeyNameHasEmbeddedNull
          && RequestOpenKeyNameFingerprint
            == MeasuredWineOpenKeyRequestTenthNameFingerprint;
        const bool MeasuredWineOpenKeyRequestShape =
          (MeasuredWineOpenKeyKnownRequestPayloadShape
            || MeasuredWineOpenKeyFifthRequestPayloadShape
            || MeasuredWineOpenKeySixthRequestPayloadShape
            || MeasuredWineOpenKeySeventhRequestPayloadShape
            || MeasuredWineOpenKeyEighthRequestPayloadShape
            || MeasuredWineOpenKeyNinthRequestPayloadShape
            || MeasuredWineOpenKeyTenthRequestPayloadShape)
          && RequestHeaderCode == MeasuredWineOpenKeyRequestCode
          && RequestHeaderRequestSize == ReplyVectors[1].Length
          && RequestHeaderReplySize == 0;
        const bool MeasuredWineCreateEventRequestShape = ReplyVectors
          && ReplyVectors[1].Length == MeasuredWineCreateEventRequestPayloadSize
          && RequestHeaderCode == MeasuredWineCreateEventRequestCode
          && RequestHeaderRequestSize == MeasuredWineCreateEventRequestPayloadSize
          && RequestHeaderReplySize == 0;
        const bool MeasuredWineCreateSymlinkRequestShape = [&] {
          if (!ReplyVectors
              || VectorCount != 2
              || ReplyVectors[0].Length != MeasuredWineRequestHeaderSize
              || ReplyVectors[1].Length
                != MeasuredWineCreateSymlinkRequestPayloadSize
              || RequestHeaderCode != MeasuredWineCreateSymlinkRequestCode
              || RequestHeaderRequestSize
                != MeasuredWineCreateSymlinkRequestPayloadSize
              || RequestHeaderReplySize != 0
              || !ReplyHeader
              || !ReplyPayload) {
            return false;
          }
          const auto* FixedRequest = static_cast<const uint8_t*>(ReplyHeader);
          const auto* Target = static_cast<const uint8_t*>(ReplyPayload);
          uint32_t Access {};
          std::memcpy(&Access, FixedRequest + 12, sizeof(Access));
          if (Access != MeasuredWineCreateSymlinkRequestAccess
              || ReplyVectors[1].Length % sizeof(uint16_t) != 0
              || FingerprintBytes(
                Target,
                static_cast<size_t>(ReplyVectors[1].Length))
                != MeasuredWineCreateSymlinkTargetFingerprint) {
            return false;
          }
          for (uint64_t Offset = 0; Offset < ReplyVectors[1].Length;
               Offset += sizeof(uint16_t)) {
            uint16_t CodeUnit {};
            std::memcpy(&CodeUnit, Target + Offset, sizeof(CodeUnit));
            if (CodeUnit == 0) {
              return false;
            }
          }
          return true;
        }();
        const bool ExactWineRequestDescriptor = GuestProgram
            == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
          && Descriptor != STDOUT_FILENO
          && Descriptor != STDERR_FILENO
          && OwnedDescriptors.contains(Descriptor)
          && ReceivedSCMRightsDescriptors.contains(Descriptor)
          && ReplyDescriptorFlags != -1
          && ReplyDescriptorStatSucceeded
          && S_ISFIFO(ReplyDescriptorStat.st_mode);
        const uint64_t MeasuredWineNewProcessRequestPayloadSize =
          ReplyVectors && VectorCount == 4
            ? ReplyVectors[1].Length
              + ReplyVectors[2].Length
              + ReplyVectors[3].Length
            : 0;
        const bool MeasuredWineNewProcessEnvironmentShape = [&] {
          if (!ReplyVectors || VectorCount != 4 || !ReplyPayload4) {
            return false;
          }
          const uint64_t EnvironmentSize = ReplyVectors[3].Length;
          if (EnvironmentSize < MinimumWineNewProcessEnvironmentSize
              || EnvironmentSize > MaximumWineNewProcessEnvironmentSize
              || EnvironmentSize % sizeof(uint16_t) != 0) {
            return false;
          }
          const auto* EnvironmentBytes = static_cast<const uint8_t*>(ReplyPayload4);
          uint16_t PenultimateCodeUnit {};
          uint16_t TerminalCodeUnit {};
          std::memcpy(
            &PenultimateCodeUnit,
            EnvironmentBytes + EnvironmentSize - 2 * sizeof(uint16_t),
            sizeof(PenultimateCodeUnit));
          std::memcpy(
            &TerminalCodeUnit,
            EnvironmentBytes + EnvironmentSize - sizeof(uint16_t),
            sizeof(TerminalCodeUnit));
          return PenultimateCodeUnit == 0 && TerminalCodeUnit == 0;
        }();
        const bool MeasuredWineNewProcessRequestShape = ReplyVectors
          && VectorCount == 4
          && ReplyVectors[0].Length == MeasuredWineRequestHeaderSize
          && ReplyVectors[1].Length == MeasuredWineNewProcessObjectAttributesSize
          && ReplyVectors[2].Length == MeasuredWineNewProcessStartupInfoSize
          && MeasuredWineNewProcessEnvironmentShape
          && RequestHeaderCode == MeasuredWineNewProcessRequestCode
          && RequestHeaderRequestSize
            == MeasuredWineNewProcessRequestPayloadSize
          && RequestHeaderReplySize == 0
          && RequestHeaderInfoSize == ReplyVectors[2].Length
          && RequestHeaderHandlesSize == 0
          && RequestHeaderJobsSize == 0
          && ReplyHeader
          && ReplyPayload
          && ReplyPayload3
          && ReplyPayload4;
        const bool ExactWineNewProcessRequest = ExactWineRequestDescriptor
          && MeasuredWineNewProcessRequestShape;
        if (ExactWineNewProcessRequest) {
          TraceWineRequestHeader(
            "writev",
            Descriptor,
            ReplyHeader,
            static_cast<size_t>(MeasuredWineRequestHeaderSize));
          ++WriteVWineRequestCandidateCount;
          ++WriteVWineNewProcessRequestCandidateCount;
          WriteVWineRequestLastDescriptor = Descriptor;
          WriteVWineRequestLastVectorCount = VectorCount;
          WriteVWineRequestLastRequestedByteCount = MeasuredWineRequestHeaderSize
            + MeasuredWineNewProcessRequestPayloadSize;
          std::array<iovec, 4> HostVectors {{
            {const_cast<void*>(ReplyHeader), static_cast<size_t>(ReplyVectors[0].Length)},
            {const_cast<void*>(ReplyPayload), static_cast<size_t>(ReplyVectors[1].Length)},
            {const_cast<void*>(ReplyPayload3), static_cast<size_t>(ReplyVectors[2].Length)},
            {const_cast<void*>(ReplyPayload4), static_cast<size_t>(ReplyVectors[3].Length)},
          }};
          errno = 0;
          const ssize_t Result = ::writev(Descriptor, HostVectors.data(), HostVectors.size());
          WriteVWineRequestLastReturnedByteCount = Result;
          if (Result < 0) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            ++WriteVWineRequestFailureCount;
            ++WriteVWineNewProcessRequestFailureCount;
            WriteVWineRequestLastHostError = HostError;
            WriteVWineRequestLastLinuxError = LinuxError;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteVWineRequestSuccessCount;
          ++WriteVWineNewProcessRequestSuccessCount;
          ++WriteVSuccessCount;
          WriteVVectorCount += VectorCount;
          WriteVByteCount += static_cast<uint64_t>(Result);
          WriteVWineRequestLastHostError = 0;
          WriteVWineRequestLastLinuxError = 0;
          return static_cast<uint64_t>(Result);
        }
        const bool MeasuredWineCreateFileKnownRequestShape = ReplyVectors
          && VectorCount == 3
          && ReplyVectors[0].Length == MeasuredWineRequestHeaderSize
          && ReplyVectors[1].Length == MeasuredWineCreateFileObjectAttributesSize
          && (ReplyVectors[2].Length == MeasuredWineCreateFileNameSize
            || ReplyVectors[2].Length == MeasuredWineCreateFileAlternateNameSize)
          && RequestHeaderCode == MeasuredWineCreateFileRequestCode
          && RequestHeaderRequestSize == MeasuredWineCreateFileObjectAttributesSize
            + ReplyVectors[2].Length
          && RequestHeaderReplySize == 0
          && ReplyHeader
          && ReplyPayload
          && ReplyPayload3;
        const bool MeasuredWineCreateFileThirdRequestShape = [&] {
          if (!ReplyVectors
              || VectorCount != 3
              || ReplyVectors[0].Length != MeasuredWineRequestHeaderSize
              || ReplyVectors[1].Length
                != MeasuredWineCreateFileThirdObjectAttributesSize
              || ReplyVectors[2].Length != MeasuredWineCreateFileThirdNameSize
              || RequestHeaderCode != MeasuredWineCreateFileRequestCode
              || RequestHeaderRequestSize
                != MeasuredWineCreateFileThirdObjectAttributesSize
                  + MeasuredWineCreateFileThirdNameSize
              || RequestHeaderReplySize != 0
              || ReplyDescriptorFlags != FD_CLOEXEC
              || !ReplyHeader
              || !ReplyPayload
              || !ReplyPayload3) {
            return false;
          }

          const auto* Fixed = static_cast<const uint8_t*>(ReplyHeader);
          const auto* ObjectAttributes = static_cast<const uint8_t*>(ReplyPayload);
          const auto* UnixName = static_cast<const uint8_t*>(ReplyPayload3);
          uint32_t Access {};
          uint32_t Sharing {};
          int32_t Disposition {};
          uint32_t Options {};
          uint32_t Attributes {};
          uint32_t RootDirectory {};
          uint32_t ObjectAttributeFlags {};
          uint32_t SecurityDescriptorLength {};
          uint32_t ObjectNameLength {};
          std::memcpy(&Access, Fixed + 12, sizeof(Access));
          std::memcpy(&Sharing, Fixed + 16, sizeof(Sharing));
          std::memcpy(&Disposition, Fixed + 20, sizeof(Disposition));
          std::memcpy(&Options, Fixed + 24, sizeof(Options));
          std::memcpy(&Attributes, Fixed + 28, sizeof(Attributes));
          std::memcpy(&RootDirectory, ObjectAttributes, sizeof(RootDirectory));
          std::memcpy(
            &ObjectAttributeFlags,
            ObjectAttributes + 4,
            sizeof(ObjectAttributeFlags));
          std::memcpy(
            &SecurityDescriptorLength,
            ObjectAttributes + 8,
            sizeof(SecurityDescriptorLength));
          std::memcpy(
            &ObjectNameLength,
            ObjectAttributes + 12,
            sizeof(ObjectNameLength));

          const uint64_t VariableLength = ReplyVectors[1].Length - 16;
          const bool ComponentLengthsValid = SecurityDescriptorLength <= VariableLength
            && ObjectNameLength <= VariableLength - SecurityDescriptorLength;
          const uint64_t ObjectAttributesLength = ComponentLengthsValid
            ? (16 + uint64_t {SecurityDescriptorLength}
              + uint64_t {ObjectNameLength} + 3) & ~uint64_t {3}
            : 0;
          if (Access != MeasuredWineCreateFileThirdAccess
              || Sharing != MeasuredWineCreateFileThirdSharing
              || Disposition != MeasuredWineCreateFileThirdDisposition
              || Options != MeasuredWineCreateFileThirdOptions
              || Attributes != MeasuredWineCreateFileThirdAttributes
              || RootDirectory != MeasuredWineCreateFileThirdRootDirectory
              || ObjectAttributeFlags
                != MeasuredWineCreateFileThirdObjectAttributes
              || SecurityDescriptorLength
                != MeasuredWineCreateFileThirdSecurityDescriptorLength
              || ObjectNameLength != MeasuredWineCreateFileThirdObjectNameLength
              || SecurityDescriptorLength % sizeof(uint16_t) != 0
              || ObjectNameLength % sizeof(uint16_t) != 0
              || ObjectAttributesLength != ReplyVectors[1].Length) {
            return false;
          }

          const auto* ObjectName = ObjectAttributes + 16 + SecurityDescriptorLength;
          for (uint64_t Offset = 0; Offset < ObjectNameLength;
               Offset += sizeof(uint16_t)) {
            uint16_t CodeUnit {};
            std::memcpy(&CodeUnit, ObjectName + Offset, sizeof(CodeUnit));
            if (CodeUnit == 0) {
              return false;
            }
          }
          for (uint64_t Offset = 0; Offset < ReplyVectors[2].Length; ++Offset) {
            if (UnixName[Offset] == 0
                || UnixName[Offset] < 0x20
                || UnixName[Offset] > 0x7e) {
              return false;
            }
          }
          return UnixName[0] == '/'
            && FingerprintBytes(ObjectName, ObjectNameLength)
              == MeasuredWineCreateFileThirdObjectNameFingerprint
            && FingerprintBytes(UnixName, ReplyVectors[2].Length)
              == MeasuredWineCreateFileThirdUnixNameFingerprint;
        }();
        const bool MeasuredWineCreateFileFourthRequestShape = [&] {
          if (!ReplyVectors
              || VectorCount != 3
              || ReplyVectors[0].Length != MeasuredWineRequestHeaderSize
              || ReplyVectors[1].Length
                != MeasuredWineCreateFileFourthObjectAttributesSize
              || ReplyVectors[2].Length != MeasuredWineCreateFileFourthNameSize
              || RequestHeaderCode != MeasuredWineCreateFileRequestCode
              || RequestHeaderRequestSize
                != MeasuredWineCreateFileFourthObjectAttributesSize
                  + MeasuredWineCreateFileFourthNameSize
              || RequestHeaderReplySize != 0
              || ReplyDescriptorFlags != FD_CLOEXEC
              || !ReplyHeader
              || !ReplyPayload
              || !ReplyPayload3) {
            return false;
          }

          const auto* Fixed = static_cast<const uint8_t*>(ReplyHeader);
          const auto* ObjectAttributes = static_cast<const uint8_t*>(ReplyPayload);
          const auto* UnixName = static_cast<const uint8_t*>(ReplyPayload3);
          uint32_t Access {};
          uint32_t Sharing {};
          int32_t Disposition {};
          uint32_t Options {};
          uint32_t Attributes {};
          uint32_t RootDirectory {};
          uint32_t ObjectAttributeFlags {};
          uint32_t SecurityDescriptorLength {};
          uint32_t ObjectNameLength {};
          std::memcpy(&Access, Fixed + 12, sizeof(Access));
          std::memcpy(&Sharing, Fixed + 16, sizeof(Sharing));
          std::memcpy(&Disposition, Fixed + 20, sizeof(Disposition));
          std::memcpy(&Options, Fixed + 24, sizeof(Options));
          std::memcpy(&Attributes, Fixed + 28, sizeof(Attributes));
          std::memcpy(&RootDirectory, ObjectAttributes, sizeof(RootDirectory));
          std::memcpy(
            &ObjectAttributeFlags,
            ObjectAttributes + 4,
            sizeof(ObjectAttributeFlags));
          std::memcpy(
            &SecurityDescriptorLength,
            ObjectAttributes + 8,
            sizeof(SecurityDescriptorLength));
          std::memcpy(
            &ObjectNameLength,
            ObjectAttributes + 12,
            sizeof(ObjectNameLength));

          const uint64_t VariableLength = ReplyVectors[1].Length - 16;
          const bool ComponentLengthsValid = SecurityDescriptorLength <= VariableLength
            && ObjectNameLength <= VariableLength - SecurityDescriptorLength;
          const uint64_t ObjectAttributesLength = ComponentLengthsValid
            ? (16 + uint64_t {SecurityDescriptorLength}
              + uint64_t {ObjectNameLength} + 3) & ~uint64_t {3}
            : 0;
          if (Access != MeasuredWineCreateFileFourthAccess
              || Sharing != MeasuredWineCreateFileFourthSharing
              || Disposition != MeasuredWineCreateFileFourthDisposition
              || Options != MeasuredWineCreateFileFourthOptions
              || Attributes != MeasuredWineCreateFileFourthAttributes
              || RootDirectory != MeasuredWineCreateFileFourthRootDirectory
              || ObjectAttributeFlags
                != MeasuredWineCreateFileFourthObjectAttributes
              || SecurityDescriptorLength
                != MeasuredWineCreateFileFourthSecurityDescriptorLength
              || ObjectNameLength != MeasuredWineCreateFileFourthObjectNameLength
              || SecurityDescriptorLength % sizeof(uint16_t) != 0
              || ObjectNameLength % sizeof(uint16_t) != 0
              || ObjectAttributesLength != ReplyVectors[1].Length) {
            return false;
          }

          const auto* ObjectName = ObjectAttributes + 16 + SecurityDescriptorLength;
          for (uint64_t Offset = 0; Offset < ObjectNameLength;
               Offset += sizeof(uint16_t)) {
            uint16_t CodeUnit {};
            std::memcpy(&CodeUnit, ObjectName + Offset, sizeof(CodeUnit));
            if (CodeUnit == 0) {
              return false;
            }
          }
          for (uint64_t Offset = 0; Offset < ReplyVectors[2].Length; ++Offset) {
            if (UnixName[Offset] == 0
                || UnixName[Offset] < 0x20
                || UnixName[Offset] > 0x7e) {
              return false;
            }
          }
          return UnixName[0] == '/'
            && FingerprintBytes(ObjectName, ObjectNameLength)
              == MeasuredWineCreateFileFourthObjectNameFingerprint
            && FingerprintBytes(UnixName, ReplyVectors[2].Length)
              == MeasuredWineCreateFileFourthUnixNameFingerprint;
        }();
        const bool MeasuredWineCreateFileRequestShape =
          MeasuredWineCreateFileKnownRequestShape
          || MeasuredWineCreateFileThirdRequestShape
          || MeasuredWineCreateFileFourthRequestShape;
        const bool ExactWineCreateFileRequest = ExactWineRequestDescriptor
          && MeasuredWineCreateFileRequestShape;
        if (ExactWineCreateFileRequest) {
          TraceWineRequestHeader(
            "writev",
            Descriptor,
            ReplyHeader,
            static_cast<size_t>(MeasuredWineRequestHeaderSize));
          ++WriteVWineRequestCandidateCount;
          ++WriteVWineCreateFileRequestCandidateCount;
          WriteVWineRequestLastDescriptor = Descriptor;
          WriteVWineRequestLastVectorCount = VectorCount;
          WriteVWineRequestLastRequestedByteCount = MeasuredWineRequestHeaderSize
            + RequestHeaderRequestSize;
          std::array<iovec, 3> HostVectors {{
            {const_cast<void*>(ReplyHeader), static_cast<size_t>(ReplyVectors[0].Length)},
            {const_cast<void*>(ReplyPayload), static_cast<size_t>(ReplyVectors[1].Length)},
            {const_cast<void*>(ReplyPayload3), static_cast<size_t>(ReplyVectors[2].Length)},
          }};
          errno = 0;
          const ssize_t Result = ::writev(Descriptor, HostVectors.data(), HostVectors.size());
          WriteVWineRequestLastReturnedByteCount = Result;
          if (Result < 0) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            ++WriteVWineRequestFailureCount;
            ++WriteVWineCreateFileRequestFailureCount;
            WriteVWineRequestLastHostError = HostError;
            WriteVWineRequestLastLinuxError = LinuxError;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteVWineRequestSuccessCount;
          ++WriteVWineCreateFileRequestSuccessCount;
          ++WriteVSuccessCount;
          WriteVVectorCount += VectorCount;
          WriteVByteCount += static_cast<uint64_t>(Result);
          WriteVWineRequestLastHostError = 0;
          WriteVWineRequestLastLinuxError = 0;
          return static_cast<uint64_t>(Result);
        }
        const bool ExactWineRequest = ExactWineRequestDescriptor
          && VectorCount == 2
          && ReplyVectors
          && ReplyVectors[0].Length == MeasuredWineRequestHeaderSize
          && (MeasuredWineOpenMappingRequestShape
            || MeasuredWineCreateKeyRequestShape
            || MeasuredWineEnumKeyValueRequestShape
            || MeasuredWineOpenKeyRequestShape
            || MeasuredWineCreateEventRequestShape
            || MeasuredWineCreateSymlinkRequestShape)
          && ReplyHeader
          && ReplyPayload;
        if (ExactWineRequest) {
          TraceWineRequestHeader(
            "writev",
            Descriptor,
            ReplyHeader,
            static_cast<size_t>(MeasuredWineRequestHeaderSize));
          ++WriteVWineRequestCandidateCount;
          if (MeasuredWineCreateKeyRequestShape) {
            ++WriteVWineCreateKeyRequestCandidateCount;
          }
          if (MeasuredWineEnumKeyValueRequestShape) {
            ++WriteVWineEnumKeyValueRequestCandidateCount;
          }
          if (MeasuredWineOpenKeyRequestShape) {
            ++WriteVWineOpenKeyRequestCandidateCount;
          }
          if (MeasuredWineCreateEventRequestShape) {
            ++WriteVWineCreateEventRequestCandidateCount;
          }
          if (MeasuredWineCreateSymlinkRequestShape) {
            ++WriteVWineCreateSymlinkRequestCandidateCount;
          }
          WriteVWineRequestLastDescriptor = Descriptor;
          WriteVWineRequestLastVectorCount = VectorCount;
          WriteVWineRequestLastRequestedByteCount =
            ReplyVectors[0].Length + ReplyVectors[1].Length;
          std::array<iovec, 2> HostVectors {{
            {const_cast<void*>(ReplyHeader), static_cast<size_t>(ReplyVectors[0].Length)},
            {const_cast<void*>(ReplyPayload), static_cast<size_t>(ReplyVectors[1].Length)},
          }};
          errno = 0;
          const ssize_t Result = ::writev(Descriptor, HostVectors.data(), HostVectors.size());
          WriteVWineRequestLastReturnedByteCount = Result;
          if (Result < 0) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            ++WriteVWineRequestFailureCount;
            if (MeasuredWineCreateKeyRequestShape) {
              ++WriteVWineCreateKeyRequestFailureCount;
            }
            if (MeasuredWineEnumKeyValueRequestShape) {
              ++WriteVWineEnumKeyValueRequestFailureCount;
            }
            if (MeasuredWineOpenKeyRequestShape) {
              ++WriteVWineOpenKeyRequestFailureCount;
            }
            if (MeasuredWineCreateEventRequestShape) {
              ++WriteVWineCreateEventRequestFailureCount;
            }
            if (MeasuredWineCreateSymlinkRequestShape) {
              ++WriteVWineCreateSymlinkRequestFailureCount;
            }
            WriteVWineRequestLastHostError = HostError;
            WriteVWineRequestLastLinuxError = LinuxError;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteVWineRequestSuccessCount;
          if (MeasuredWineCreateKeyRequestShape) {
            ++WriteVWineCreateKeyRequestSuccessCount;
          }
          if (MeasuredWineEnumKeyValueRequestShape) {
            ++WriteVWineEnumKeyValueRequestSuccessCount;
          }
          if (MeasuredWineOpenKeyRequestShape) {
            ++WriteVWineOpenKeyRequestSuccessCount;
          }
          if (MeasuredWineCreateEventRequestShape) {
            ++WriteVWineCreateEventRequestSuccessCount;
          }
          if (MeasuredWineCreateSymlinkRequestShape) {
            ++WriteVWineCreateSymlinkRequestSuccessCount;
          }
          ++WriteVSuccessCount;
          WriteVVectorCount += VectorCount;
          WriteVByteCount += static_cast<uint64_t>(Result);
          WriteVWineRequestLastHostError = 0;
          WriteVWineRequestLastLinuxError = 0;
          return static_cast<uint64_t>(Result);
        }
        ++WriteVRejectedCallCount;
        if (WriteVRejectedCallCount == 1) {
          WriteVRejectedFirstDescriptor = Descriptor;
          WriteVRejectedFirstDescriptorOwned = OwnedDescriptors.contains(Descriptor);
          WriteVRejectedFirstDescriptorStandard = Descriptor >= STDIN_FILENO
            && Descriptor <= STDERR_FILENO;
          WriteVRejectedFirstDescriptorClosed = ClosedStandardDescriptors.contains(Descriptor);
          WriteVRejectedFirstDescriptorMatchesRecvMsg = Descriptor
            == RecvMsgLastReceivedDescriptor;
          WriteVRejectedFirstDescriptorReceivedSCMRights =
            ReceivedSCMRightsDescriptors.contains(Descriptor);
          WriteVRejectedFirstGuestVectors = GuestVectors;
          WriteVRejectedFirstVectorCount = VectorCount;

          errno = 0;
          WriteVRejectedFirstHostDescriptorFlags = fcntl(Descriptor, F_GETFD);
          WriteVRejectedFirstHostDescriptorError =
            WriteVRejectedFirstHostDescriptorFlags == -1 ? errno : 0;
          errno = 0;
          WriteVRejectedFirstHostStatusFlags = fcntl(Descriptor, F_GETFL);
          WriteVRejectedFirstHostStatusError =
            WriteVRejectedFirstHostStatusFlags == -1 ? errno : 0;
          struct stat DescriptorStat {};
          WriteVRejectedFirstDescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
          if (WriteVRejectedFirstDescriptorStatSucceeded) {
            WriteVRejectedFirstDescriptorFIFO = S_ISFIFO(DescriptorStat.st_mode);
            WriteVRejectedFirstDescriptorSocket = S_ISSOCK(DescriptorStat.st_mode);
            WriteVRejectedFirstDescriptorRegular = S_ISREG(DescriptorStat.st_mode);
          }

          const bool VectorSpanValid = VectorCount <= 8
            && VectorCount <= std::numeric_limits<uint64_t>::max()
              / sizeof(LinuxIOVector64);
          const uint64_t VectorSpan = VectorSpanValid
            ? VectorCount * sizeof(LinuxIOVector64)
            : 0;
          const LinuxIOVector64* Vectors {};
          WriteVRejectedFirstGuestVectorsClass = GuestVectors == 0
            ? "zero"
            : "scalar-or-outside";
          if (VectorSpanValid && VectorSpan != 0) {
            Vectors = static_cast<const LinuxIOVector64*>(
              HostPointerForGuestRange(GuestVectors, VectorSpan, PROT_READ));
          }
          if (Vectors != nullptr) {
            WriteVRejectedFirstGuestVectorsClass = Contains(GuestVectors, VectorSpan)
              ? "guest-memory"
              : (LowGuestShadow
                  && LowGuestShadow->ContainsMappedLogicalRange(
                    GuestVectors,
                    VectorSpan,
                    PROT_READ)
                ? "low-shadow"
                : "high-sparse");
            WriteVRejectedFirstGuestVectorsReadable = true;
          }

          auto CapturePayload = [&](const LinuxIOVector64& Vector,
                                    uint64_t& Base,
                                    uint64_t& Length,
                                    std::string& BufferClass,
                                    bool& Readable,
                                    uint64_t& Fingerprint) {
            Base = Vector.Base;
            Length = Vector.Length;
            BufferClass = Vector.Length == 0 ? "empty" : "scalar-or-outside";
            Readable = Vector.Length == 0;
            Fingerprint = 0;
            const uint8_t* Bytes {};
            if (Vector.Length != 0 && Vector.Length <= 4096) {
              Bytes = static_cast<const uint8_t*>(
                HostPointerForGuestRange(Vector.Base, Vector.Length, PROT_READ));
              if (Bytes != nullptr) {
                BufferClass = Contains(Vector.Base, Vector.Length)
                  ? "guest-memory"
                  : (LowGuestShadow
                      && LowGuestShadow->ContainsMappedLogicalRange(
                        Vector.Base,
                        Vector.Length,
                        PROT_READ)
                    ? "low-shadow"
                    : "high-sparse");
                Readable = true;
              }
            }
            if (Bytes) {
              Fingerprint = FingerprintBytes(Bytes, static_cast<size_t>(Vector.Length));
            }
          };

          WriteVRejectedFirstAllPayloadsReadable = Vectors != nullptr;
          if (Vectors) {
            for (uint64_t Index = 0; Index < VectorCount; ++Index) {
              const auto& Vector = Vectors[Index];
              if (Vector.Length > std::numeric_limits<uint64_t>::max()
                  - WriteVRejectedFirstTotalByteCount) {
                WriteVRejectedFirstAllPayloadsReadable = false;
                break;
              }
              WriteVRejectedFirstTotalByteCount += Vector.Length;
              const bool PayloadReadable = Vector.Length == 0
                || (Vector.Length <= 4096
                  && HostPointerForGuestRange(
                    Vector.Base,
                    Vector.Length,
                    PROT_READ) != nullptr);
              WriteVRejectedFirstAllPayloadsReadable &= PayloadReadable;
            }
            if (VectorCount >= 1) {
              CapturePayload(
                Vectors[0],
                WriteVRejectedFirstVector1Base,
                WriteVRejectedFirstVector1Length,
                WriteVRejectedFirstVector1Class,
                WriteVRejectedFirstVector1Readable,
                WriteVRejectedFirstVector1Fingerprint);
              WriteVRejectedFirstOfficialWineServer = GuestProgram
                == "/opt/proton/files/bin/wineserver";
              WriteVRejectedFirstReplyHeaderReadable =
                WriteVRejectedFirstOfficialWineServer
                && ReplyHeader
                && Vectors[0].Length == MeasuredWineReplyHeaderSize;
              if (WriteVRejectedFirstReplyHeaderReadable) {
                WriteVRejectedFirstReplyError = ReplyHeaderError;
                WriteVRejectedFirstReplyDeclaredSize = ReplyHeaderDeclaredSize;
                WriteVRejectedFirstReplyDeclaredSizeMatchesVector2 = VectorCount == 2
                  && ReplyHeaderDeclaredSize == Vectors[1].Length;
                TraceWineReplyHeader(
                  "rejected-writev",
                  Descriptor,
                  ReplyHeader,
                  static_cast<size_t>(Vectors[0].Length));
              }
              if (GuestProgram == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
                  && WriteVRejectedFirstVector1Readable
                  && Vectors[0].Length >= 12) {
                const void* Header = ResolveReplyPayload(Vectors[0]);
                if (Header) {
                  const auto* HeaderBytes = static_cast<const uint8_t*>(Header);
                  std::memcpy(
                    &WriteVRejectedFirstRequestCode,
                    HeaderBytes,
                    sizeof(WriteVRejectedFirstRequestCode));
                  std::memcpy(
                    &WriteVRejectedFirstRequestSize,
                    HeaderBytes + 4,
                    sizeof(WriteVRejectedFirstRequestSize));
                  std::memcpy(
                    &WriteVRejectedFirstReplySize,
                    HeaderBytes + 8,
                    sizeof(WriteVRejectedFirstReplySize));
                  WriteVRejectedFirstRequestHeaderReadable = true;
                  TraceWineRequestHeader(
                    "rejected-writev",
                    Descriptor,
                    Header,
                    static_cast<size_t>(Vectors[0].Length));
                }
              }
            }
            if (VectorCount >= 2) {
              CapturePayload(
                Vectors[1],
                WriteVRejectedFirstVector2Base,
                WriteVRejectedFirstVector2Length,
                WriteVRejectedFirstVector2Class,
                WriteVRejectedFirstVector2Readable,
                WriteVRejectedFirstVector2Fingerprint);

              const bool OpenKeyShape = GuestProgram
                  == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
                && WriteVRejectedFirstDescriptorOwned
                && WriteVRejectedFirstDescriptorReceivedSCMRights
                && WriteVRejectedFirstDescriptorFIFO
                && Vectors[0].Length == MeasuredWineRequestHeaderSize
                && WriteVRejectedFirstRequestHeaderReadable
                && WriteVRejectedFirstRequestCode
                  == static_cast<int32_t>(MeasuredWineOpenKeyRequestCode)
                && WriteVRejectedFirstRequestSize == Vectors[1].Length
                && WriteVRejectedFirstReplySize == 0
                && WriteVRejectedFirstVector2Readable;
              WriteVRejectedFirstOpenKeyCandidate = OpenKeyShape;
              if (OpenKeyShape) {
                const auto* FixedRequest = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[0]));
                const auto* Name = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[1]));
                WriteVRejectedFirstOpenKeyFixedFieldsReadable = FixedRequest != nullptr;
                if (FixedRequest) {
                  std::memcpy(
                    &WriteVRejectedFirstOpenKeyParent,
                    FixedRequest + 12,
                    sizeof(WriteVRejectedFirstOpenKeyParent));
                  std::memcpy(
                    &WriteVRejectedFirstOpenKeyAccess,
                    FixedRequest + 16,
                    sizeof(WriteVRejectedFirstOpenKeyAccess));
                  std::memcpy(
                    &WriteVRejectedFirstOpenKeyAttributes,
                    FixedRequest + 20,
                    sizeof(WriteVRejectedFirstOpenKeyAttributes));
                }
                WriteVRejectedFirstOpenKeyNameLength = Vectors[1].Length;
                WriteVRejectedFirstOpenKeyNameEvenLength =
                  Vectors[1].Length % sizeof(uint16_t) == 0;
                WriteVRejectedFirstOpenKeyNameReadable = Name != nullptr;
                if (Name && WriteVRejectedFirstOpenKeyNameEvenLength) {
                  WriteVRejectedFirstOpenKeyNameHasEmbeddedNull = false;
                  for (uint64_t Offset = 0; Offset < Vectors[1].Length;
                       Offset += sizeof(uint16_t)) {
                    uint16_t CodeUnit {};
                    std::memcpy(&CodeUnit, Name + Offset, sizeof(CodeUnit));
                    if (CodeUnit == 0) {
                      WriteVRejectedFirstOpenKeyNameHasEmbeddedNull = true;
                      break;
                    }
                  }
                }
              }

              const bool CreateKeyShape = GuestProgram
                  == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
                && WriteVRejectedFirstDescriptorOwned
                && WriteVRejectedFirstDescriptorReceivedSCMRights
                && WriteVRejectedFirstDescriptorFIFO
                && Vectors[0].Length == MeasuredWineRequestHeaderSize
                && WriteVRejectedFirstRequestHeaderReadable
                && WriteVRejectedFirstRequestCode
                  == static_cast<int32_t>(MeasuredWineCreateKeyRequestCode)
                && WriteVRejectedFirstRequestSize == Vectors[1].Length
                && WriteVRejectedFirstReplySize == 0
                && WriteVRejectedFirstVector2Readable
                && Vectors[1].Length >= 16;
              WriteVRejectedFirstCreateKeyCandidate = CreateKeyShape;
              if (CreateKeyShape) {
                const auto* FixedRequest = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[0]));
                const auto* Payload = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[1]));
                WriteVRejectedFirstCreateKeyFixedFieldsReadable = FixedRequest != nullptr;
                WriteVRejectedFirstCreateKeyObjectAttributesReadable = Payload != nullptr;
                if (FixedRequest) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeyAccess,
                    FixedRequest + 12,
                    sizeof(WriteVRejectedFirstCreateKeyAccess));
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeyOptions,
                    FixedRequest + 16,
                    sizeof(WriteVRejectedFirstCreateKeyOptions));
                }
                if (Payload) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeyRootDirectory,
                    Payload,
                    sizeof(WriteVRejectedFirstCreateKeyRootDirectory));
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeyAttributes,
                    Payload + 4,
                    sizeof(WriteVRejectedFirstCreateKeyAttributes));
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeySecurityDescriptorLength,
                    Payload + 8,
                    sizeof(WriteVRejectedFirstCreateKeySecurityDescriptorLength));
                  std::memcpy(
                    &WriteVRejectedFirstCreateKeyNameLength,
                    Payload + 12,
                    sizeof(WriteVRejectedFirstCreateKeyNameLength));
                  const uint64_t VariableLength = Vectors[1].Length - 16;
                  const uint64_t SecurityLength =
                    WriteVRejectedFirstCreateKeySecurityDescriptorLength;
                  const uint64_t NameLength = WriteVRejectedFirstCreateKeyNameLength;
                  const bool ComponentLengthsValid = SecurityLength <= VariableLength
                    && NameLength <= VariableLength - SecurityLength;
                  const uint64_t ObjectAttributesLength = ComponentLengthsValid
                    ? (16 + (SecurityLength & ~uint64_t {1})
                      + (NameLength & ~uint64_t {1}) + 3) & ~uint64_t {3}
                    : 0;
                  WriteVRejectedFirstCreateKeyObjectAttributesLength =
                    ObjectAttributesLength;
                  WriteVRejectedFirstCreateKeyLayoutValid = ComponentLengthsValid
                    && ObjectAttributesLength <= Vectors[1].Length;
                  if (WriteVRejectedFirstCreateKeyLayoutValid) {
                    const auto* Name = Payload + 16 + SecurityLength;
                    const auto* Class = Payload + ObjectAttributesLength;
                    WriteVRejectedFirstCreateKeyNameEvenLength = NameLength % 2 == 0;
                    WriteVRejectedFirstCreateKeyClassLength =
                      Vectors[1].Length - ObjectAttributesLength;
                    WriteVRejectedFirstCreateKeyClassEvenLength =
                      WriteVRejectedFirstCreateKeyClassLength % 2 == 0;
                    WriteVRejectedFirstCreateKeyNameFingerprint = FingerprintBytes(
                      Name,
                      static_cast<size_t>(NameLength));
                    WriteVRejectedFirstCreateKeyClassFingerprint = FingerprintBytes(
                      Class,
                      static_cast<size_t>(WriteVRejectedFirstCreateKeyClassLength));
                  }
                }
              }

              const bool CreateSymlinkShape = GuestProgram
                  == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
                && WriteVRejectedFirstDescriptorOwned
                && WriteVRejectedFirstDescriptorReceivedSCMRights
                && WriteVRejectedFirstDescriptorFIFO
                && Vectors[0].Length == MeasuredWineRequestHeaderSize
                && WriteVRejectedFirstRequestHeaderReadable
                && WriteVRejectedFirstRequestCode
                  == static_cast<int32_t>(MeasuredWineCreateSymlinkRequestCode)
                && WriteVRejectedFirstRequestSize == Vectors[1].Length
                && WriteVRejectedFirstReplySize == 0
                && WriteVRejectedFirstVector2Readable
                && Vectors[1].Length >= 16;
              WriteVRejectedFirstCreateSymlinkCandidate = CreateSymlinkShape;
              if (CreateSymlinkShape) {
                const auto* FixedRequest = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[0]));
                const auto* Payload = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[1]));
                WriteVRejectedFirstCreateSymlinkFixedFieldsReadable =
                  FixedRequest != nullptr;
                WriteVRejectedFirstCreateSymlinkObjectAttributesReadable =
                  Payload != nullptr;
                WriteVRejectedFirstCreateSymlinkRequestSizeMatchesPayload =
                  WriteVRejectedFirstRequestSize == Vectors[1].Length;
                if (FixedRequest) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateSymlinkAccess,
                    FixedRequest + 12,
                    sizeof(WriteVRejectedFirstCreateSymlinkAccess));
                }
                if (Payload) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateSymlinkRootDirectory,
                    Payload,
                    sizeof(WriteVRejectedFirstCreateSymlinkRootDirectory));
                  std::memcpy(
                    &WriteVRejectedFirstCreateSymlinkAttributes,
                    Payload + 4,
                    sizeof(WriteVRejectedFirstCreateSymlinkAttributes));
                  std::memcpy(
                    &WriteVRejectedFirstCreateSymlinkSecurityDescriptorLength,
                    Payload + 8,
                    sizeof(WriteVRejectedFirstCreateSymlinkSecurityDescriptorLength));
                  std::memcpy(
                    &WriteVRejectedFirstCreateSymlinkNameLength,
                    Payload + 12,
                    sizeof(WriteVRejectedFirstCreateSymlinkNameLength));

                  const uint64_t VariableLength = Vectors[1].Length - 16;
                  const uint64_t SecurityLength =
                    WriteVRejectedFirstCreateSymlinkSecurityDescriptorLength;
                  const uint64_t NameLength =
                    WriteVRejectedFirstCreateSymlinkNameLength;
                  const bool ComponentLengthsValid = SecurityLength <= VariableLength
                    && NameLength <= VariableLength - SecurityLength;
                  const uint64_t ObjectAttributesLength = ComponentLengthsValid
                    ? (16 + (SecurityLength & ~uint64_t {1})
                      + (NameLength & ~uint64_t {1}) + 3) & ~uint64_t {3}
                    : 0;
                  WriteVRejectedFirstCreateSymlinkCalculatedObjectAttributesLength =
                    ObjectAttributesLength;
                  WriteVRejectedFirstCreateSymlinkObjectAttributesLayoutValid =
                    ComponentLengthsValid
                    && ObjectAttributesLength <= Vectors[1].Length;
                  if (WriteVRejectedFirstCreateSymlinkObjectAttributesLayoutValid) {
                    const auto* Name = Payload + 16 + SecurityLength;
                    const auto* Target = Payload + ObjectAttributesLength;
                    WriteVRejectedFirstCreateSymlinkNameEvenLength =
                      NameLength % sizeof(uint16_t) == 0;
                    WriteVRejectedFirstCreateSymlinkTargetLength =
                      Vectors[1].Length - ObjectAttributesLength;
                    WriteVRejectedFirstCreateSymlinkTargetEvenLength =
                      WriteVRejectedFirstCreateSymlinkTargetLength
                        % sizeof(uint16_t) == 0;
                    WriteVRejectedFirstCreateSymlinkNameFingerprint =
                      FingerprintBytes(Name, static_cast<size_t>(NameLength));
                    WriteVRejectedFirstCreateSymlinkTargetFingerprint =
                      FingerprintBytes(
                        Target,
                        static_cast<size_t>(
                          WriteVRejectedFirstCreateSymlinkTargetLength));
                    if (WriteVRejectedFirstCreateSymlinkNameEvenLength) {
                      for (uint64_t Offset = 0; Offset < NameLength;
                           Offset += sizeof(uint16_t)) {
                        uint16_t CodeUnit {};
                        std::memcpy(&CodeUnit, Name + Offset, sizeof(CodeUnit));
                        if (CodeUnit == 0) {
                          WriteVRejectedFirstCreateSymlinkNameHasEmbeddedNull = true;
                          break;
                        }
                      }
                    }
                    if (WriteVRejectedFirstCreateSymlinkTargetEvenLength) {
                      for (uint64_t Offset = 0;
                           Offset < WriteVRejectedFirstCreateSymlinkTargetLength;
                           Offset += sizeof(uint16_t)) {
                        uint16_t CodeUnit {};
                        std::memcpy(&CodeUnit, Target + Offset, sizeof(CodeUnit));
                        if (CodeUnit == 0) {
                          WriteVRejectedFirstCreateSymlinkTargetHasEmbeddedNull = true;
                          break;
                        }
                      }
                    }
                  }
                }
              }
            }
            if (VectorCount >= 3) {
              CapturePayload(
                Vectors[2],
                WriteVRejectedFirstVector3Base,
                WriteVRejectedFirstVector3Length,
                WriteVRejectedFirstVector3Class,
                WriteVRejectedFirstVector3Readable,
                WriteVRejectedFirstVector3Fingerprint);

              const bool CreateFileShape = GuestProgram
                  == "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader"
                && WriteVRejectedFirstDescriptorOwned
                && WriteVRejectedFirstDescriptorReceivedSCMRights
                && WriteVRejectedFirstDescriptorFIFO
                && WriteVRejectedFirstHostDescriptorFlags == FD_CLOEXEC
                && VectorCount == 3
                && Vectors[0].Length == MeasuredWineRequestHeaderSize
                && WriteVRejectedFirstRequestHeaderReadable
                && WriteVRejectedFirstRequestCode
                  == static_cast<int32_t>(MeasuredWineCreateFileRequestCode)
                && Vectors[1].Length <= std::numeric_limits<uint32_t>::max()
                && Vectors[2].Length <= std::numeric_limits<uint32_t>::max()
                && Vectors[1].Length <= std::numeric_limits<uint64_t>::max()
                  - Vectors[2].Length
                && WriteVRejectedFirstRequestSize
                  == Vectors[1].Length + Vectors[2].Length
                && WriteVRejectedFirstReplySize == 0
                && WriteVRejectedFirstVector1Readable
                && WriteVRejectedFirstVector2Readable
                && WriteVRejectedFirstVector3Readable
                && Vectors[1].Length >= 16;
              WriteVRejectedFirstCreateFileCandidate = CreateFileShape;
              if (CreateFileShape) {
                const auto* FixedRequest = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[0]));
                const auto* ObjectAttributes = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[1]));
                const auto* UnixName = static_cast<const uint8_t*>(
                  ResolveReplyPayload(Vectors[2]));
                WriteVRejectedFirstCreateFileFixedFieldsReadable = FixedRequest != nullptr;
                WriteVRejectedFirstCreateFileObjectAttributesReadable =
                  ObjectAttributes != nullptr;
                WriteVRejectedFirstCreateFileUnixNameReadable = UnixName != nullptr;
                WriteVRejectedFirstCreateFileRequestSizeMatchesPayloads =
                  WriteVRejectedFirstRequestSize
                    == Vectors[1].Length + Vectors[2].Length;

                if (FixedRequest) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileAccess,
                    FixedRequest + 12,
                    sizeof(WriteVRejectedFirstCreateFileAccess));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileSharing,
                    FixedRequest + 16,
                    sizeof(WriteVRejectedFirstCreateFileSharing));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileDisposition,
                    FixedRequest + 20,
                    sizeof(WriteVRejectedFirstCreateFileDisposition));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileOptions,
                    FixedRequest + 24,
                    sizeof(WriteVRejectedFirstCreateFileOptions));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileAttributes,
                    FixedRequest + 28,
                    sizeof(WriteVRejectedFirstCreateFileAttributes));
                }

                if (ObjectAttributes) {
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileRootDirectory,
                    ObjectAttributes,
                    sizeof(WriteVRejectedFirstCreateFileRootDirectory));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileObjectAttributes,
                    ObjectAttributes + 4,
                    sizeof(WriteVRejectedFirstCreateFileObjectAttributes));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileSecurityDescriptorLength,
                    ObjectAttributes + 8,
                    sizeof(WriteVRejectedFirstCreateFileSecurityDescriptorLength));
                  std::memcpy(
                    &WriteVRejectedFirstCreateFileObjectNameLength,
                    ObjectAttributes + 12,
                    sizeof(WriteVRejectedFirstCreateFileObjectNameLength));

                  const uint64_t SecurityLength =
                    WriteVRejectedFirstCreateFileSecurityDescriptorLength;
                  const uint64_t ObjectNameLength =
                    WriteVRejectedFirstCreateFileObjectNameLength;
                  const uint64_t VariableLength = Vectors[1].Length - 16;
                  WriteVRejectedFirstCreateFileSecurityDescriptorEvenLength =
                    SecurityLength % sizeof(uint16_t) == 0;
                  WriteVRejectedFirstCreateFileObjectNameEvenLength =
                    ObjectNameLength % sizeof(uint16_t) == 0;
                  const bool ComponentLengthsValid = SecurityLength <= VariableLength
                    && ObjectNameLength <= VariableLength - SecurityLength;
                  const uint64_t CalculatedLength = ComponentLengthsValid
                    ? (16 + SecurityLength + ObjectNameLength + 3) & ~uint64_t {3}
                    : 0;
                  WriteVRejectedFirstCreateFileCalculatedObjectAttributesLength =
                    CalculatedLength;
                  WriteVRejectedFirstCreateFileObjectAttributesLayoutValid =
                    ComponentLengthsValid
                    && WriteVRejectedFirstCreateFileSecurityDescriptorEvenLength
                    && WriteVRejectedFirstCreateFileObjectNameEvenLength
                    && CalculatedLength == Vectors[1].Length;

                  if (WriteVRejectedFirstCreateFileObjectAttributesLayoutValid) {
                    const auto* SecurityDescriptor = ObjectAttributes + 16;
                    const auto* ObjectName = SecurityDescriptor + SecurityLength;
                    WriteVRejectedFirstCreateFileSecurityDescriptorFingerprint =
                      FingerprintBytes(
                        SecurityDescriptor,
                        static_cast<size_t>(SecurityLength));
                    WriteVRejectedFirstCreateFileObjectNameFingerprint = FingerprintBytes(
                      ObjectName,
                      static_cast<size_t>(ObjectNameLength));
                    for (uint64_t Offset = 0; Offset < ObjectNameLength;
                         Offset += sizeof(uint16_t)) {
                      uint16_t CodeUnit {};
                      std::memcpy(&CodeUnit, ObjectName + Offset, sizeof(CodeUnit));
                      if (CodeUnit == 0) {
                        WriteVRejectedFirstCreateFileObjectNameHasEmbeddedNull = true;
                        break;
                      }
                    }
                  }
                }

                WriteVRejectedFirstCreateFileUnixNameLength = Vectors[2].Length;
                if (UnixName) {
                  WriteVRejectedFirstCreateFileUnixNameFingerprint = FingerprintBytes(
                    UnixName,
                    static_cast<size_t>(Vectors[2].Length));
                  WriteVRejectedFirstCreateFileUnixNamePrintableASCII = true;
                  for (uint64_t Offset = 0; Offset < Vectors[2].Length; ++Offset) {
                    if (UnixName[Offset] == 0) {
                      WriteVRejectedFirstCreateFileUnixNameHasEmbeddedNull = true;
                    }
                    if (UnixName[Offset] < 0x20 || UnixName[Offset] > 0x7e) {
                      WriteVRejectedFirstCreateFileUnixNamePrintableASCII = false;
                    }
                  }
                  WriteVRejectedFirstCreateFileUnixNamePathClass =
                    Vectors[2].Length == 0
                      ? "empty"
                      : UnixName[0] == '/'
                        ? "absolute"
                        : "relative";
                }
              }
            }
            if (VectorCount >= 4) {
              CapturePayload(
                Vectors[3],
                WriteVRejectedFirstVector4Base,
                WriteVRejectedFirstVector4Length,
                WriteVRejectedFirstVector4Class,
                WriteVRejectedFirstVector4Readable,
                WriteVRejectedFirstVector4Fingerprint);
            }
          }
        }
        return static_cast<uint64_t>(-EBADF);
      }
      if (VectorCount > LinuxIOVectorMaximum) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (VectorCount == 0) {
        ++WriteVSuccessCount;
        return 0;
      }
      const auto* Vectors = static_cast<const LinuxIOVector64*>(
        HostPointerForGuestRange(
          GuestVectors,
          VectorCount * sizeof(LinuxIOVector64),
          PROT_READ));
      if (Vectors == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }

      uint64_t TotalBytes {};
      for (uint64_t Index = 0; Index < VectorCount; ++Index) {
        const LinuxIOVector64 Vector = Vectors[Index];
        if (Vector.Length > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) - TotalBytes) {
          return static_cast<uint64_t>(-EINVAL);
        }
        if (Vector.Length != 0
            && HostPointerForGuestRange(
              Vector.Base,
              Vector.Length,
              PROT_READ) == nullptr) {
          return static_cast<uint64_t>(-EFAULT);
        }
        TotalBytes += Vector.Length;
      }

      for (uint64_t Index = 0; Index < VectorCount; ++Index) {
        const LinuxIOVector64 Vector = Vectors[Index];
        if (Vector.Length == 0) {
          continue;
        }
        const auto* Payload = static_cast<const char*>(
          HostPointerForGuestRange(
            Vector.Base,
            Vector.Length,
            PROT_READ));
        if (Descriptor == STDOUT_FILENO) {
          CapturedOutput.append(
            Payload,
            static_cast<size_t>(Vector.Length));
        } else {
          CapturedError.append(
            Payload,
            static_cast<size_t>(Vector.Length));
        }
      }
      ++WriteVSuccessCount;
      WriteVVectorCount += VectorCount;
      WriteVByteCount += TotalBytes;
      return TotalBytes;
    }
    if (Number == WriteSyscall) {
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Buffer = Arguments->Argument[2];
      const uint64_t Count = Arguments->Argument[3];
      const bool IsOutputDescriptor = Descriptor == STDOUT_FILENO
        || Descriptor == STDERR_FILENO;
      const bool IsClosedOutputDescriptor = IsOutputDescriptor
        && ClosedStandardDescriptors.contains(Descriptor);
      if (CXAltLoaderConnectedDescriptors.contains(Descriptor)) {
        constexpr uint64_t MaximumAltLoaderWriteSize = 16ULL * 1024ULL * 1024ULL;
        ++WriteAltLoaderCandidateCount;
        WriteAltLoaderLastDescriptor = Descriptor;
        WriteAltLoaderLastByteCount = Count;
        WriteAltLoaderLastReturnedByteCount = -1;
        WriteAltLoaderLastHostError = 0;
        WriteAltLoaderLastLinuxError = 0;

        if (!OwnedDescriptors.contains(Descriptor) || Descriptor <= STDERR_FILENO) {
          WriteAltLoaderLastLinuxError = EBADF;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-EBADF);
        }
        if (Count > MaximumAltLoaderWriteSize) {
          WriteAltLoaderLastLinuxError = E2BIG;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-E2BIG);
        }
        const void* Payload = Count == 0
          ? nullptr
          : HostPointerForGuestRange(Buffer, Count, PROT_READ);
        if (Count != 0 && !Payload) {
          WriteAltLoaderLastLinuxError = EFAULT;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-EFAULT);
        }

        errno = 0;
        const int HostDescriptorFlags = fcntl(Descriptor, F_GETFD);
        const int HostDescriptorFlagsError = HostDescriptorFlags == -1 ? errno : 0;
        errno = 0;
        struct stat DescriptorStat {};
        const bool DescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
        const int DescriptorStatError = DescriptorStatSucceeded ? 0 : errno;
        if (HostDescriptorFlagsError != 0) {
          const int LinuxError = TranslateHostFcntlGetFlagsErrorToLinux(
            HostDescriptorFlagsError);
          WriteAltLoaderLastHostError = HostDescriptorFlagsError;
          WriteAltLoaderLastLinuxError = LinuxError;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-LinuxError);
        }
        if ((HostDescriptorFlags & FD_CLOEXEC) == 0
            || !DescriptorStatSucceeded
            || !S_ISSOCK(DescriptorStat.st_mode)) {
          WriteAltLoaderLastHostError = DescriptorStatError;
          WriteAltLoaderLastLinuxError = EBADF;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-EBADF);
        }

        ssize_t Result;
        do {
          Result = write(Descriptor, Payload, static_cast<size_t>(Count));
        } while (Result == -1 && errno == EINTR);
        if (Result == -1) {
          const int HostError = errno;
          const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
          WriteAltLoaderLastHostError = HostError;
          WriteAltLoaderLastLinuxError = LinuxError;
          ++WriteAltLoaderFailureCount;
          return static_cast<uint64_t>(-LinuxError);
        }
        WriteAltLoaderLastReturnedByteCount = Result;
        ++WriteAltLoaderSuccessCount;
        WriteAltLoaderWrittenByteCount += static_cast<uint64_t>(Result);
        return static_cast<uint64_t>(Result);
      }
      if (RegistryTemporaryDescriptors.contains(Descriptor)) {
        ++WriteRegistryTemporaryCandidateCount;
        if (WriteRegistryTemporaryTraceCount < WriteRegistryTemporaryTrace.size()) {
          auto& Trace = WriteRegistryTemporaryTrace[WriteRegistryTemporaryTraceCount++];
          Trace.Descriptor = Descriptor;
          Trace.Buffer = Buffer;
          Trace.ByteCount = Count;
          Trace.BufferClass = Count == 0 ? "empty" : "scalar-or-outside";
          Trace.BufferReadable = Count == 0;
          const uint8_t* ReadableBytes {};
          if (Count != 0 && Count <= 4096 && Contains(Buffer, Count)) {
            Trace.BufferClass = "guest-memory";
            Trace.BufferReadable = true;
            ReadableBytes = reinterpret_cast<const uint8_t*>(Buffer);
          } else if (Count != 0 && Count <= 4096 && LowGuestShadow
              && LowGuestShadow->ContainsMappedLogicalRange(Buffer, Count, PROT_READ)) {
            Trace.BufferClass = "low-shadow";
            Trace.BufferReadable = true;
            ReadableBytes = reinterpret_cast<const uint8_t*>(
              LowGuestShadow->HostPointerForMappedLogicalRange(Buffer, Count, PROT_READ));
          }
          if (ReadableBytes) {
            Trace.BufferFingerprint = FingerprintBytes(
              ReadableBytes,
              static_cast<size_t>(Count));
          }
          const int SavedHostError = errno;
          errno = 0;
          Trace.HostDescriptorFlags = fcntl(Descriptor, F_GETFD);
          Trace.HostDescriptorError = Trace.HostDescriptorFlags == -1 ? errno : 0;
          errno = 0;
          Trace.HostStatusFlags = fcntl(Descriptor, F_GETFL);
          Trace.HostStatusError = Trace.HostStatusFlags == -1 ? errno : 0;
          errno = 0;
          struct stat DescriptorStat {};
          Trace.DescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
          if (Trace.DescriptorStatSucceeded) {
            Trace.DescriptorRegular = S_ISREG(DescriptorStat.st_mode);
            Trace.DescriptorFIFO = S_ISFIFO(DescriptorStat.st_mode);
            Trace.DescriptorSocket = S_ISSOCK(DescriptorStat.st_mode);
          }
          errno = SavedHostError;
        }

        constexpr uint64_t MaximumMeasuredRegistryTemporaryWriteSize = 4096;
        const uint8_t* ReadableBytes {};
        if (Count > 0 && Count <= MaximumMeasuredRegistryTemporaryWriteSize
            && Contains(Buffer, Count)) {
          ReadableBytes = reinterpret_cast<const uint8_t*>(Buffer);
        } else if (Count > 0 && Count <= MaximumMeasuredRegistryTemporaryWriteSize
            && LowGuestShadow
            && LowGuestShadow->ContainsMappedLogicalRange(Buffer, Count, PROT_READ)) {
          ReadableBytes = reinterpret_cast<const uint8_t*>(
            LowGuestShadow->HostPointerForMappedLogicalRange(Buffer, Count, PROT_READ));
        }

        const int SavedHostError = errno;
        errno = 0;
        const int HostDescriptorFlags = fcntl(Descriptor, F_GETFD);
        const int HostDescriptorError = HostDescriptorFlags == -1 ? errno : 0;
        errno = 0;
        const int HostStatusFlags = fcntl(Descriptor, F_GETFL);
        const int HostStatusError = HostStatusFlags == -1 ? errno : 0;
        errno = 0;
        struct stat DescriptorStat {};
        const bool DescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
        errno = SavedHostError;

        const bool ExactRegistryTemporaryWrite =
          OwnedDescriptors.contains(Descriptor)
          && Descriptor > STDERR_FILENO
          && ReadableBytes
          && HostDescriptorError == 0
          && HostDescriptorFlags == 0
          && HostStatusError == 0
          && HostStatusFlags == O_WRONLY
          && DescriptorStatSucceeded
          && S_ISREG(DescriptorStat.st_mode);
        if (ExactRegistryTemporaryWrite) {
          ++WriteRegistryTemporaryExactCandidateCount;
          WriteRegistryTemporaryLastDescriptor = Descriptor;
          WriteRegistryTemporaryLastByteCount = Count;
          WriteRegistryTemporaryLastReturnedByteCount = -1;
          WriteRegistryTemporaryLastHostError = 0;
          WriteRegistryTemporaryLastLinuxError = 0;
          ssize_t Result;
          do {
            Result = write(
              Descriptor,
              ReadableBytes,
              static_cast<size_t>(Count));
          } while (Result == -1 && errno == EINTR);
          if (Result == -1) {
            const int HostError = errno;
            const int LinuxError = TranslateHostRegularWriteErrorToLinux(HostError);
            WriteRegistryTemporaryLastHostError = HostError;
            WriteRegistryTemporaryLastLinuxError = LinuxError;
            ++WriteRegistryTemporaryFailureCount;
            return static_cast<uint64_t>(-LinuxError);
          }
          WriteRegistryTemporaryLastReturnedByteCount = Result;
          ++WriteRegistryTemporarySuccessCount;
          WriteRegistryTemporaryWrittenByteCount += static_cast<uint64_t>(Result);
          return static_cast<uint64_t>(Result);
        }
      }
      if (!IsOutputDescriptor || IsClosedOutputDescriptor) {
        constexpr uint64_t MeasuredWineRequestSize = 64;
        struct stat RequestDescriptorStat {};
        const bool RequestDescriptorStatSucceeded = fstat(
          Descriptor,
          &RequestDescriptorStat) == 0;
        const int RequestDescriptorFlags = fcntl(Descriptor, F_GETFD);
        const void* MeasuredWineBuffer = Count == MeasuredWineRequestSize
          ? HostPointerForGuestRange(Buffer, Count, PROT_READ)
          : nullptr;
        const bool ExactWineReplyHeader = GuestProgram
            == "/opt/proton/files/bin/wineserver"
          && !IsOutputDescriptor
          && OwnedDescriptors.contains(Descriptor)
          && ReceivedSCMRightsDescriptors.contains(Descriptor)
          && RequestDescriptorFlags != -1
          && (RequestDescriptorFlags & FD_CLOEXEC) == 0
          && RequestDescriptorStatSucceeded
          && S_ISFIFO(RequestDescriptorStat.st_mode)
          && Count == MeasuredWineRequestSize
          && MeasuredWineBuffer;
        if (ExactWineReplyHeader) {
          TraceWineReplyHeader(
            "write",
            Descriptor,
            MeasuredWineBuffer,
            static_cast<size_t>(Count));
          WriteWineReplySeen = true;
          ++WriteWineReplyCandidateCount;
          WriteWineReplyLastDescriptor = Descriptor;
          WriteWineReplyLastByteCount = Count;
          WriteWineReplyLastHostError = 0;
          WriteWineReplyLastLinuxError = 0;
          ssize_t Result;
          do {
            Result = write(
              Descriptor,
              MeasuredWineBuffer,
              static_cast<size_t>(Count));
          } while (Result == -1 && errno == EINTR);
          if (Result == -1) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            WriteWineReplyLastHostError = HostError;
            WriteWineReplyLastLinuxError = LinuxError;
            ++WriteWineReplyFailureCount;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteWineReplySuccessCount;
          WriteWineReplyWrittenByteCount += static_cast<uint64_t>(Result);
          return static_cast<uint64_t>(Result);
        }
        const bool ExactWineRequestPipe = !IsOutputDescriptor
          && OwnedDescriptors.contains(Descriptor)
          && ReceivedSCMRightsDescriptors.contains(Descriptor)
          && RequestDescriptorFlags != -1
          && (RequestDescriptorFlags & FD_CLOEXEC) != 0
          && RequestDescriptorStatSucceeded
          && S_ISFIFO(RequestDescriptorStat.st_mode)
          && Count == MeasuredWineRequestSize
          && MeasuredWineBuffer;
        if (ExactWineRequestPipe) {
          TraceWineRequestHeader(
            "write",
            Descriptor,
            MeasuredWineBuffer,
            static_cast<size_t>(Count));
          WriteRequestPipeSeen = true;
          ++WriteRequestPipeCandidateCount;
          WriteRequestPipeLastDescriptor = Descriptor;
          WriteRequestPipeLastByteCount = Count;
          WriteRequestPipeLastHostError = 0;
          WriteRequestPipeLastLinuxError = 0;
          ssize_t Result;
          do {
            Result = write(
              Descriptor,
              MeasuredWineBuffer,
              static_cast<size_t>(Count));
          } while (Result == -1 && errno == EINTR);
          if (Result == -1) {
            const int HostError = errno;
            const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
            WriteRequestPipeLastHostError = HostError;
            WriteRequestPipeLastLinuxError = LinuxError;
            ++WriteRequestPipeFailureCount;
            return static_cast<uint64_t>(-LinuxError);
          }
          ++WriteRequestPipeSuccessCount;
          WriteRequestPipeWrittenByteCount += static_cast<uint64_t>(Result);
          return static_cast<uint64_t>(Result);
        }
        ++WriteRejectedCallCount;
        if (WriteRejectedCallCount == 1) {
          WriteRejectedFirstDescriptor = Descriptor;
          WriteRejectedFirstDescriptorOwned = OwnedDescriptors.contains(Descriptor);
          WriteRejectedFirstDescriptorStandard = Descriptor >= STDIN_FILENO
            && Descriptor <= STDERR_FILENO;
          WriteRejectedFirstDescriptorClosed = IsClosedOutputDescriptor;
          WriteRejectedFirstDescriptorMatchesRecvMsg = Descriptor
            == RecvMsgLastReceivedDescriptor;
          WriteRejectedFirstBuffer = Buffer;
          WriteRejectedFirstByteCount = Count;
          WriteRejectedFirstBufferClass = "scalar-or-outside";
          WriteRejectedFirstBufferReadable = false;
          WriteRejectedFirstBufferFingerprint = 0;

          const uint8_t* ReadableBytes {};
          if (Count != 0 && Count <= 4096) {
            ReadableBytes = static_cast<const uint8_t*>(
              HostPointerForGuestRange(Buffer, Count, PROT_READ));
            if (ReadableBytes) {
              WriteRejectedFirstBufferClass = Contains(Buffer, Count)
                ? "guest-memory"
                : (LowGuestShadow
                    && LowGuestShadow->ContainsMappedLogicalRange(
                      Buffer,
                      Count,
                      PROT_READ)
                  ? "low-shadow"
                  : "high-sparse");
              WriteRejectedFirstBufferReadable = true;
            }
          }
          if (ReadableBytes) {
            WriteRejectedFirstBufferFingerprint = FingerprintBytes(
              ReadableBytes,
              static_cast<size_t>(Count));
          }

          errno = 0;
          WriteRejectedFirstHostDescriptorFlags = fcntl(Descriptor, F_GETFD);
          WriteRejectedFirstHostDescriptorError =
            WriteRejectedFirstHostDescriptorFlags == -1 ? errno : 0;
          struct stat DescriptorStat {};
          WriteRejectedFirstDescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
          if (WriteRejectedFirstDescriptorStatSucceeded) {
            WriteRejectedFirstDescriptorFIFO = S_ISFIFO(DescriptorStat.st_mode);
            WriteRejectedFirstDescriptorSocket = S_ISSOCK(DescriptorStat.st_mode);
            WriteRejectedFirstDescriptorRegular = S_ISREG(DescriptorStat.st_mode);
          }
        }
        return static_cast<uint64_t>(-EBADF);
      }
      if (Count > 4096 || !Contains(Buffer, Count)) {
        return static_cast<uint64_t>(-EFAULT);
      }
      WriteSeen = true;
      ++WriteCallCount;
      WriteByteCount += Count;
      if (Descriptor == STDOUT_FILENO) {
        CapturedOutput.append(reinterpret_cast<const char*>(Buffer), static_cast<size_t>(Count));
      } else {
        CapturedError.append(reinterpret_cast<const char*>(Buffer), static_cast<size_t>(Count));
      }
      return Count;
    }
    if (Number == BrkSyscall && InitialProgramBreak != 0) {
      BrkSeen = true;
      ++BrkCallCount;
      const uint64_t Requested = Arguments->Argument[1];
      if (Requested == 0) {
        return CurrentProgramBreak;
      }
      if (Requested < InitialProgramBreak || Requested > ProgramBreakLimit) {
        return CurrentProgramBreak;
      }
      if (Requested > CurrentProgramBreak) {
        std::memset(
          reinterpret_cast<void*>(CurrentProgramBreak),
          0,
          static_cast<size_t>(Requested - CurrentProgramBreak));
      }
      CurrentProgramBreak = Requested;
      return CurrentProgramBreak;
    }
    if (Number == AccessSyscall && !RootFS.empty()) {
      AccessSeen = true;
      ++AccessCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      if (!GuestPath.has_value()) {
        return static_cast<uint64_t>(-EFAULT);
      }
      TraceGuestPath("access", *GuestPath);
      const auto HostPath = ResolveGuestPath(*GuestPath);
      if (!HostPath.has_value()) {
        return static_cast<uint64_t>(-EACCES);
      }
      const int Mode = static_cast<int>(Arguments->Argument[2]);
      if (Mode != F_OK && (Mode & ~(R_OK | W_OK | X_OK)) != 0) {
        return static_cast<uint64_t>(-EINVAL);
      }
      if (access(HostPath->c_str(), Mode) == 0) {
        return 0;
      }
      return static_cast<uint64_t>(-errno);
    }
    if (Number == OpenSyscall && !RootFS.empty()) {
      OpenSeen = true;
      ++OpenCallCount;
      const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
      const uint64_t Flags = Arguments->Argument[2];
      const uint64_t Mode = Arguments->Argument[3];
      OpenLastFlags = Flags;
      OpenLastMode = Mode;
      if (!GuestPath.has_value()) {
        OpenLastPathClass = "unreadable";
        OpenLastLinuxError = EFAULT;
        return static_cast<uint64_t>(-EFAULT);
      }
      const bool IntlNLSDiagnostic = BeginIntlNLSDiagnostic("open", *GuestPath);
      OpenLastPathLength = GuestPath->size();
      OpenLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      TraceGuestPath("open", *GuestPath);
      if (GuestPath->empty() || GuestPath->front() != '/') {
        OpenLastPathClass = GuestPath->empty() ? "empty" : "relative";
        OpenLastLinuxError = ENOTSUP;
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, ENOTSUP);
        return static_cast<uint64_t>(-ENOTSUP);
      }
      OpenLastPathClass = "absolute";
      // Linux solo interpreta el tercer argumento cuando O_CREAT/O_TMPFILE
      // está presente. El subconjunto admitido es O_RDONLY (flags == 0), así
      // que el valor residual de mode no debe alterar el resultado.
      if (Flags != 0) {
        OpenLastLinuxError = EINVAL;
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, EINVAL);
        return static_cast<uint64_t>(-EINVAL);
      }
      const auto HostPath = ResolveGuestPath(*GuestPath);
      if (!HostPath.has_value()) {
        OpenLastLinuxError = EACCES;
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, EACCES);
        return static_cast<uint64_t>(-EACCES);
      }
      struct stat HostStat {};
      if (stat(HostPath->c_str(), &HostStat) != 0) {
        OpenLastLinuxError = errno;
        FinishIntlNLSDiagnostic(
          IntlNLSDiagnostic,
          true,
          false,
          false,
          OpenLastLinuxError);
        return static_cast<uint64_t>(-OpenLastLinuxError);
      }
      if (!S_ISREG(HostStat.st_mode)) {
        OpenLastLinuxError = EACCES;
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, true, true, false, EACCES);
        return static_cast<uint64_t>(-EACCES);
      }
      const int Descriptor = open(HostPath->c_str(), O_RDONLY | O_CLOEXEC);
      if (Descriptor == -1) {
        OpenLastLinuxError = errno;
        FinishIntlNLSDiagnostic(
          IntlNLSDiagnostic,
          true,
          true,
          true,
          OpenLastLinuxError);
        return static_cast<uint64_t>(-OpenLastLinuxError);
      }
      OwnedDescriptors.insert(Descriptor);
      ++OpenSuccessCount;
      OpenLastLinuxError = 0;
      if (IntlNLSDiagnostic) {
        IntlNLSLastDescriptor = Descriptor;
      }
      FinishIntlNLSDiagnostic(IntlNLSDiagnostic, true, true, true, 0);
      return static_cast<uint64_t>(Descriptor);
    }
    if (Number == OpenAtSyscall && !RootFS.empty()) {
      OpenAtSeen = true;
      ++OpenAtCallCount;
      constexpr uint64_t LinuxOWriteOnly = 0x1;
      constexpr uint64_t LinuxOReadWrite = 0x2;
      constexpr uint64_t LinuxOCreate = 0x40;
      constexpr uint64_t LinuxOExclusive = 0x80;
      constexpr uint64_t LinuxOTruncate = 0x200;
      constexpr uint64_t LinuxOCloexec = 0x80000;
      constexpr uint64_t LinuxOLargeFile = 0x8000;
      constexpr uint64_t LinuxAccessMode = 0x3;
      const int32_t DirectoryDescriptor = static_cast<int32_t>(Arguments->Argument[1]);
      const auto GuestPath = ReadGuestPath(Arguments->Argument[2]);
      const uint64_t Flags = Arguments->Argument[3];
      const uint64_t Mode = Arguments->Argument[4];
      OpenAtLastDirectoryDescriptor = DirectoryDescriptor;
      OpenAtLastFlags = Flags;
      OpenAtLastMode = Mode;
      OpenAtLastPathClass = "unreadable";
      OpenAtLastPathLength = 0;
      OpenAtLastPathFingerprint = 0;
      OpenAtLastHostPathResolved = false;
      OpenAtLastTargetExists = false;
      OpenAtLastTargetDirectory = false;
      OpenAtLastTargetRegular = false;
      OpenAtLastLinuxError = 0;
      OpenAtLastFailureReason = "none";
      if (!GuestPath.has_value()) {
        OpenAtLastLinuxError = EFAULT;
        OpenAtLastFailureReason = "unreadable-path";
        return static_cast<uint64_t>(-EFAULT);
      }
      const bool IntlNLSDiagnostic = BeginIntlNLSDiagnostic("openat", *GuestPath);
      RecordTemporaryMappingCandidate(*GuestPath, Flags, Mode);
      OpenAtLastPathLength = GuestPath->size();
      OpenAtLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      OpenAtLastPathClass = GuestPath->empty()
        ? "empty"
        : (GuestPath->front() == '/' ? "absolute" : "relative");
      TraceGuestPath("openat", *GuestPath);
      if (GuestProgram == "/opt/proton/files/bin/wineserver") {
        std::cerr << "TRACE wineserver-openat call=" << OpenAtCallCount
                  << " dirfd=" << DirectoryDescriptor
                  << " flags=" << Flags
                  << " mode=" << Mode
                  << " path-length=" << GuestPath->size()
                  << " path-fingerprint=" << OpenAtLastPathFingerprint
                  << " guest-path=" << *GuestPath
                  << '\n';
        std::cerr.flush();
      }
      if (DirectoryDescriptor != LinuxAtFDCWD || GuestPath->empty()) {
        OpenAtLastLinuxError = ENOTSUP;
        OpenAtLastFailureReason = "directory-descriptor-not-enabled";
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, ENOTSUP);
        return static_cast<uint64_t>(-ENOTSUP);
      }
      const bool CreateTruncatedWrite = Flags
          == (LinuxOWriteOnly | LinuxOCreate | LinuxOTruncate)
        && Mode == 0600;
      const bool CreateExclusiveTemporaryMapping = Flags
          == (LinuxOReadWrite | LinuxOCreate | LinuxOExclusive)
        && Mode == 0600
        && IsTemporaryMappingCandidate(*GuestPath, Flags, Mode);
      const bool RegistryTemporaryBasename = GuestPath->size() >= 12
        && GuestPath->starts_with("reg")
        && GuestPath->ends_with(".tmp")
        && GuestPath->find('/') == std::string::npos
        && std::all_of(
          GuestPath->begin() + 3,
          GuestPath->end() - 4,
          [](char Character) {
            return (Character >= '0' && Character <= '9')
              || (Character >= 'a' && Character <= 'f')
              || (Character >= 'A' && Character <= 'F');
          });
      const bool CreateExclusiveRegistryTemporary = GuestProgram
          == "/opt/proton/files/bin/wineserver"
        && GuestCurrentWorkingDirectory == "/home/regression/.wine"
        && Flags == (LinuxOWriteOnly | LinuxOCreate | LinuxOExclusive)
        && Mode == 0666
        && RegistryTemporaryBasename;
      const bool ReadOnly = (Flags & LinuxAccessMode) == 0
        && (Flags & ~(LinuxOCloexec | LinuxOLargeFile | LinuxONonBlock
          | LinuxAccessMode)) == 0;
      if (!CreateTruncatedWrite && !CreateExclusiveTemporaryMapping
          && !CreateExclusiveRegistryTemporary && !ReadOnly) {
        OpenAtLastLinuxError = EINVAL;
        OpenAtLastFailureReason = "unsupported-flags";
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, EINVAL);
        return static_cast<uint64_t>(-EINVAL);
      }
      const auto HostPath = (CreateTruncatedWrite || CreateExclusiveTemporaryMapping
          || CreateExclusiveRegistryTemporary)
        ? ResolveGuestCreationPath(*GuestPath)
        : ResolveGuestPathWithParents(*GuestPath);
      if (!HostPath.has_value()) {
        OpenAtLastLinuxError = EACCES;
        OpenAtLastFailureReason = "path-resolution-rejected";
        FinishIntlNLSDiagnostic(IntlNLSDiagnostic, false, false, false, EACCES);
        return static_cast<uint64_t>(-EACCES);
      }
      OpenAtLastHostPathResolved = true;
      struct stat TargetStat {};
      if (lstat(HostPath->c_str(), &TargetStat) == 0) {
        OpenAtLastTargetExists = true;
        OpenAtLastTargetDirectory = S_ISDIR(TargetStat.st_mode);
        OpenAtLastTargetRegular = S_ISREG(TargetStat.st_mode);
      }
      int HostFlags = O_RDONLY;
      if (CreateTruncatedWrite) {
        HostFlags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW;
      } else if (CreateExclusiveTemporaryMapping) {
        HostFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW;
      } else if (CreateExclusiveRegistryTemporary) {
        HostFlags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW;
      }
      if (!CreateTruncatedWrite && !CreateExclusiveTemporaryMapping
          && !CreateExclusiveRegistryTemporary
          && (Flags & LinuxOCloexec) != 0) {
        HostFlags |= O_CLOEXEC;
      }
      if (!CreateTruncatedWrite && !CreateExclusiveTemporaryMapping
          && !CreateExclusiveRegistryTemporary
          && (Flags & LinuxONonBlock) != 0) {
        HostFlags |= O_NONBLOCK;
      }
      const int Descriptor = (CreateTruncatedWrite || CreateExclusiveTemporaryMapping
          || CreateExclusiveRegistryTemporary)
        ? open(HostPath->c_str(), HostFlags, static_cast<mode_t>(Mode))
        : open(HostPath->c_str(), HostFlags);
      if (Descriptor == -1) {
        const int HostError = errno;
        OpenAtLastLinuxError = CreateExclusiveRegistryTemporary
          ? TranslateHostFileOpenErrorToLinux(HostError)
          : HostError;
        OpenAtLastFailureReason = "host-open-failed";
        if (CreateExclusiveTemporaryMapping) {
          TemporaryMappingExclusiveCreateLastLinuxError = OpenAtLastLinuxError;
        }
        FinishIntlNLSDiagnostic(
          IntlNLSDiagnostic,
          true,
          OpenAtLastTargetExists,
          OpenAtLastTargetRegular,
          OpenAtLastLinuxError);
        return static_cast<uint64_t>(-OpenAtLastLinuxError);
      }
      OwnedDescriptors.insert(Descriptor);
      ++OpenAtSuccessCount;
      OpenAtLastFailureReason = "none";
      if (CreateExclusiveTemporaryMapping) {
        ++TemporaryMappingExclusiveCreateSuccessCount;
        TemporaryMappingExclusiveCreateLastDescriptor = Descriptor;
        TemporaryMappingExclusiveCreateLastLinuxError = 0;
      }
      if (CreateExclusiveRegistryTemporary) {
        ++RegistryTemporaryOpenSuccessCount;
        RegistryTemporaryLastDescriptor = Descriptor;
        RegistryTemporaryDescriptors.insert(Descriptor);
        RegistryTemporaryBasenames.insert(*GuestPath);
        if (!RegistryTemporaryTraceActive) {
          RegistryTemporaryTraceActive = true;
          RegistryTemporaryTraceTriggerOpenAtCallCount = OpenAtCallCount;
        }
      }
      if (IntlNLSDiagnostic) {
        IntlNLSLastDescriptor = Descriptor;
      }
      FinishIntlNLSDiagnostic(
        IntlNLSDiagnostic,
        true,
        OpenAtLastTargetExists,
        OpenAtLastTargetRegular,
        0);
      return static_cast<uint64_t>(Descriptor);
    }
    if (Number == NewFStatAtSyscall && !RootFS.empty()) {
      NewFStatAtSeen = true;
      ++NewFStatAtCallCount;
      constexpr uint64_t LinuxAtSymlinkNoFollow = 0x100;
      constexpr uint64_t LinuxAtNoAutomount = 0x800;
      const int32_t DirectoryDescriptor = static_cast<int32_t>(Arguments->Argument[1]);
      const auto GuestPath = ReadGuestPath(Arguments->Argument[2]);
      const uint64_t GuestBuffer = Arguments->Argument[3];
      const uint64_t Flags = Arguments->Argument[4];
      NewFStatAtLastDirectoryDescriptor = DirectoryDescriptor;
      NewFStatAtLastFlags = Flags;
      NewFStatAtLastPathClass = "unreadable";
      NewFStatAtLastPathLength = 0;
      NewFStatAtLastPathFingerprint = 0;
      NewFStatAtLastHostPathResolved = false;
      NewFStatAtLastTargetExists = false;
      NewFStatAtLastTargetDirectory = false;
      NewFStatAtLastTargetRegular = false;
      NewFStatAtLastLinuxError = 0;
      NewFStatAtLastFailureReason = "none";
      const auto FailNewFStatAt = [&](int64_t LinuxError, std::string_view Reason) {
        ++NewFStatAtFailureCount;
        NewFStatAtLastLinuxError = LinuxError;
        NewFStatAtLastFailureReason = Reason;
        return static_cast<uint64_t>(-LinuxError);
      };
      if (!GuestPath.has_value()) {
        return FailNewFStatAt(EFAULT, "unreadable-path");
      }
      NewFStatAtLastPathLength = GuestPath->size();
      NewFStatAtLastPathFingerprint = FingerprintBytes(
        reinterpret_cast<const uint8_t*>(GuestPath->data()),
        GuestPath->size());
      NewFStatAtLastPathClass = GuestPath->empty()
        ? "empty"
        : (GuestPath->front() == '/' ? "absolute" : "relative");
      const bool RelativePath = !GuestPath->empty() && GuestPath->front() != '/';
      if (RelativePath) {
        ++NewFStatAtRelativePathCallCount;
      }
      TraceGuestPath("newfstatat", *GuestPath);
      if (!Contains(GuestBuffer, sizeof(LinuxX86_64Stat))) {
        return FailNewFStatAt(EFAULT, "invalid-guest-buffer");
      }
      if (DirectoryDescriptor != LinuxAtFDCWD) {
        return FailNewFStatAt(ENOTSUP, "directory-descriptor-not-enabled");
      }
      if (GuestPath->empty()) {
        return FailNewFStatAt(ENOTSUP, "empty-path-not-enabled");
      }
      if ((Flags & ~(LinuxAtSymlinkNoFollow | LinuxAtNoAutomount)) != 0) {
        return FailNewFStatAt(EINVAL, "unsupported-flags");
      }
      const auto HostPath = ResolveGuestPath(*GuestPath);
      if (!HostPath.has_value()) {
        return FailNewFStatAt(EACCES, "path-resolution-rejected");
      }
      NewFStatAtLastHostPathResolved = true;
      struct stat ObservedTargetStat {};
      if (lstat(HostPath->c_str(), &ObservedTargetStat) == 0) {
        NewFStatAtLastTargetExists = true;
        NewFStatAtLastTargetDirectory = S_ISDIR(ObservedTargetStat.st_mode);
        NewFStatAtLastTargetRegular = S_ISREG(ObservedTargetStat.st_mode);
      }
      struct stat HostStat {};
      const int Result = (Flags & LinuxAtSymlinkNoFollow) != 0
                       ? lstat(HostPath->c_str(), &HostStat)
                       : stat(HostPath->c_str(), &HostStat);
      if (Result != 0) {
        return FailNewFStatAt(errno, "host-stat-failed");
      }
      const LinuxX86_64Stat GuestStat = TranslateStat(HostStat);
      std::memcpy(reinterpret_cast<void*>(GuestBuffer), &GuestStat, sizeof(GuestStat));
      ++NewFStatAtSuccessCount;
      if (RelativePath) {
        ++NewFStatAtRelativePathSuccessCount;
      }
      NewFStatAtLastLinuxError = 0;
      NewFStatAtLastFailureReason = "none";
      return 0;
    }
    if (Number == Clone3Syscall && !RootFS.empty()) {
      Clone3Seen = true;
      ++Clone3CallCount;
      constexpr uint64_t LinuxCloneVM = 0x00000100;
      constexpr uint64_t LinuxCloneVFork = 0x00004000;
      constexpr uint64_t LinuxCloneClearSighand = 0x1'0000'0000;
      constexpr uint64_t LinuxSigChild = 17;
      constexpr uint64_t ObservedSpawnStackSize = 36'864;
      const uint64_t GuestCloneArgs = Arguments->Argument[1];
      const uint64_t CloneArgsSize = Arguments->Argument[2];
      Clone3LastSize = CloneArgsSize;
      Clone3LastLinuxError = 0;
      Clone3LastFailureReason = "not-enabled";
      if (CloneArgsSize == sizeof(LinuxClone3Args)
          && Contains(GuestCloneArgs, sizeof(LinuxClone3Args))) {
        LinuxClone3Args GuestArgs {};
        std::memcpy(&GuestArgs, reinterpret_cast<const void*>(GuestCloneArgs), sizeof(GuestArgs));
        Clone3LastStructureReadable = true;
        Clone3LastFlags = GuestArgs.Flags;
        Clone3LastExitSignal = GuestArgs.ExitSignal;
        Clone3LastStackSize = GuestArgs.StackSize;
        const bool ExactClearSighandSpawn = GuestArgs.Flags
              == (LinuxCloneClearSighand | LinuxCloneVM | LinuxCloneVFork)
          && GuestArgs.PIDFD == 0 && GuestArgs.ChildTID == 0 && GuestArgs.ParentTID == 0
          && GuestArgs.ExitSignal == LinuxSigChild
          && GuestArgs.StackSize == ObservedSpawnStackSize
          && Contains(GuestArgs.Stack, GuestArgs.StackSize)
          && GuestArgs.TLS == 0 && GuestArgs.SetTID == 0 && GuestArgs.SetTIDSize == 0
          && GuestArgs.CGroup == 0;
        if (ExactClearSighandSpawn) {
          ++Clone3ClearSighandFallbackCount;
          Clone3LastLinuxError = EINVAL;
          Clone3LastFailureReason = "public-fex-clear-sighand-fallback";
          return static_cast<uint64_t>(-EINVAL);
        }
      }
    }
    if (Number == CloneSyscall && !RootFS.empty()
        && (VForkChildInstrumentationEnabled || VForkParentInstrumentationEnabled
            || VForkParentProcessBridgeEnabled
            || VForkParentWineServerBridgeEnabled)) {
      constexpr uint64_t LinuxCloneVM = 0x00000100;
      constexpr uint64_t LinuxCloneVFork = 0x00004000;
      constexpr uint64_t LinuxSigChild = 17;
      constexpr uint64_t DiagnosticParentPID = 4242;
      const uint64_t Flags = Arguments->Argument[1];
      const uint64_t ChildStack = Arguments->Argument[2];
      const bool ExactObservedVFork = Flags == (LinuxCloneVM | LinuxCloneVFork | LinuxSigChild)
        && ChildStack != 0 && Contains(ChildStack, 1)
        && Arguments->Argument[3] == 0 && Arguments->Argument[4] == 0
        && Arguments->Argument[5] == 0;
      if (ExactObservedVFork) {
        if (VForkParentWineServerBridgeEnabled) {
          ++VirtualVForkParentEntryCount;
          VirtualVForkParentEntered = true;
          if (!SpawnVirtualVForkWineServerBridge()
              || !SpawnVirtualVForkBridgeChild()) {
            return static_cast<uint64_t>(-EAGAIN);
          }
          VirtualVForkParentResumed = true;
          return static_cast<uint64_t>(VirtualVForkBridgeProcessID);
        }
        if (VForkParentProcessBridgeEnabled) {
          ++VirtualVForkParentEntryCount;
          VirtualVForkParentEntered = true;
          if (!SpawnVirtualVForkBridgeChild()) {
            return static_cast<uint64_t>(-EAGAIN);
          }
          VirtualVForkParentResumed = true;
          return static_cast<uint64_t>(VirtualVForkBridgeProcessID);
        }
        if (VForkParentInstrumentationEnabled) {
          ++VirtualVForkParentEntryCount;
          VirtualVForkParentEntered = true;
          VirtualVForkParentDiagnosticPID = DiagnosticParentPID;
          VirtualVForkParentResumed = true;
          return DiagnosticParentPID;
        }
        ++VirtualVForkChildEntryCount;
        VirtualVForkChildEntered = true;
        Frame->State.gregs[FEXCore::X86State::REG_RSP] = ChildStack;
        VirtualVForkChildStackApplied = true;
        return 0;
      }
    }
    if (Number == Wait4Syscall && !RootFS.empty()
        && (VForkParentProcessBridgeEnabled
            || VForkParentWineServerBridgeEnabled)) {
      VirtualVForkBridgeWaitSeen = true;
      const int64_t RequestedPID = static_cast<int64_t>(Arguments->Argument[1]);
      const uint64_t GuestStatus = Arguments->Argument[2];
      const uint64_t Options = Arguments->Argument[3];
      const uint64_t GuestResourceUsage = Arguments->Argument[4];
      VirtualVForkBridgeWaitPIDMatched = RequestedPID == VirtualVForkBridgeProcessID;
      void* const HostStatus = GuestStatus == 0
        ? nullptr
        : HostPointerForGuestRange(GuestStatus, sizeof(int32_t), PROT_WRITE);
      VirtualVForkBridgeWaitStatusWritable = HostStatus != nullptr;
      VirtualVForkBridgeWaitResourceUsageZero = GuestResourceUsage == 0;
      if (!VirtualVForkBridgeWaitPIDMatched || Options != 0
          || !VirtualVForkBridgeWaitStatusWritable
          || !VirtualVForkBridgeWaitResourceUsageZero
          || VirtualVForkBridgeChildReaped) {
        VirtualVForkBridgeLastHostError = EINVAL;
        return static_cast<uint64_t>(-EINVAL);
      }

      int HostWaitStatus = 0;
      pid_t WaitResult = -1;
      do {
        WaitResult = waitpid(
          static_cast<pid_t>(VirtualVForkBridgeProcessID),
          &HostWaitStatus,
          0);
      } while (WaitResult < 0 && errno == EINTR);
      VirtualVForkBridgeWaitResult = WaitResult;
      if (WaitResult != static_cast<pid_t>(VirtualVForkBridgeProcessID)) {
        VirtualVForkBridgeLastHostError = errno != 0 ? errno : ECHILD;
        return static_cast<uint64_t>(-VirtualVForkBridgeLastHostError);
      }
      VirtualVForkBridgeHostWaitStatus = HostWaitStatus;
      VirtualVForkBridgeChildExited = WIFEXITED(HostWaitStatus);
      VirtualVForkBridgeChildExitCode = VirtualVForkBridgeChildExited
        ? WEXITSTATUS(HostWaitStatus)
        : -1;
      VirtualVForkBridgeChildReaped = true;
      std::memcpy(HostStatus, &HostWaitStatus, sizeof(HostWaitStatus));
      ++VirtualVForkBridgeWaitSuccessCount;
      return static_cast<uint64_t>(WaitResult);
    }
    if (Number == ExitSyscall || Number == ExitGroupSyscall) {
      ExitSeen = true;
      ExitGroupSeen = Number == ExitGroupSyscall;
      ExitCode = Arguments->Argument[1];
      ExitGuestRIP = Frame->State.rip;
      ExitGuestRSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
      ExitGuestRBP = Frame->State.gregs[FEXCore::X86State::REG_RBP];
      ExitGuestRIPClass = Contains(ExitGuestRIP, 1)
        ? "guest-memory"
        : (ContainsMMapArena(ExitGuestRIP, 1)
            ? "mmap-arena"
            : (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
                && LowGuestShadow->ContainsMappedLogicalRange(
                  ExitGuestRIP, 1, PROT_EXEC)
              ? "low-shadow-executable"
              : "scalar-or-outside"));
      const void* StackBytes = Contains(ExitGuestRSP, sizeof(ExitGuestStackWords))
        ? reinterpret_cast<const void*>(ExitGuestRSP)
        : nullptr;
      if (StackBytes == nullptr && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr) {
        StackBytes = LowGuestShadow->HostPointerForMappedLogicalRange(
          ExitGuestRSP,
          sizeof(ExitGuestStackWords),
          PROT_READ);
      }
      if (StackBytes != nullptr) {
        std::memcpy(ExitGuestStackWords.data(), StackBytes, sizeof(ExitGuestStackWords));
        ExitGuestStackWordCount = ExitGuestStackWords.size();
      }
      constexpr uint64_t MaximumFrameStep = 1ULL << 20;
      uint64_t CurrentFramePointer = ExitGuestRBP;
      for (size_t Index = 0; Index < ExitGuestFramePointers.size(); ++Index) {
        const void* FrameBytes = Contains(CurrentFramePointer, 2 * sizeof(uint64_t))
          ? reinterpret_cast<const void*>(CurrentFramePointer)
          : nullptr;
        if (FrameBytes == nullptr && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr) {
          FrameBytes = LowGuestShadow->HostPointerForMappedLogicalRange(
            CurrentFramePointer,
            2 * sizeof(uint64_t),
            PROT_READ);
        }
        if (FrameBytes == nullptr) {
          break;
        }
        uint64_t NextFramePointer {};
        uint64_t ReturnAddress {};
        std::memcpy(&NextFramePointer, FrameBytes, sizeof(NextFramePointer));
        std::memcpy(
          &ReturnAddress,
          static_cast<const uint8_t*>(FrameBytes) + sizeof(uint64_t),
          sizeof(ReturnAddress));
        ExitGuestFramePointers[Index] = CurrentFramePointer;
        ExitGuestFrameReturnAddresses[Index] = ReturnAddress;
        ExitGuestFrameCount = Index + 1;
        if (NextFramePointer <= CurrentFramePointer
            || NextFramePointer - CurrentFramePointer > MaximumFrameStep
            || (NextFramePointer & (alignof(uint64_t) - 1)) != 0) {
          break;
        }
        CurrentFramePointer = NextFramePointer;
      }
      Stop(Frame);
      return 0;
    }
    if (Number == RecvMsgSyscall && !RootFS.empty()) {
      RecvMsgSeen = true;
      ++RecvMsgCallCount;
      constexpr int64_t LinuxMsgCmsgCloseOnExec = 0x40000000;
      constexpr int32_t LinuxSOLSocket = 1;
      constexpr int32_t LinuxSCMRights = 1;
      constexpr uint64_t ServerToClientPayloadSize = sizeof(uint32_t);
      constexpr uint64_t ClientToServerPayloadSize = 2 * sizeof(uint32_t);
      constexpr uint64_t MeasuredControlBufferSize = 256;
      constexpr uint64_t LinuxControlMessageLength =
        sizeof(LinuxControlMessageHeader64) + sizeof(int32_t);
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t GuestHeaderAddress = Arguments->Argument[2];
      RecvMsgLastDescriptor = Descriptor;
      RecvMsgLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      RecvMsgLastCallFlags = static_cast<int64_t>(Arguments->Argument[3]);
      RecvMsgLastByteCount = 0;
      RecvMsgLastHostControlLength = 0;
      RecvMsgLastHostControlMessageLength = 0;
      RecvMsgLastReceivedDescriptor = -1;
      RecvMsgLastPayloadValue = 0;
      RecvMsgLastHostMessageFlags = 0;
      RecvMsgLastHostError = 0;
      RecvMsgLastLinuxError = 0;
      RecvMsgLastHeaderReadable = false;
      RecvMsgLastNamePresent = false;
      RecvMsgLastNameLength = 0;
      RecvMsgLastIOVectorCount = 0;
      RecvMsgLastFirstIOVectorReadable = false;
      RecvMsgLastFirstIOVectorBase = 0;
      RecvMsgLastFirstIOVectorLength = 0;
      RecvMsgLastFirstIOVectorPayloadReadable = false;
      RecvMsgLastControlPresent = false;
      RecvMsgLastControlLength = 0;
      RecvMsgLastControlReadable = false;
      RecvMsgLastMessageFlags = 0;
      RecvMsgLastFailureReason = "none";
      if (!RecvMsgLastDescriptorOwned) {
        RecvMsgLastLinuxError = EBADF;
        RecvMsgLastFailureReason = "unowned-descriptor";
        return static_cast<uint64_t>(-EBADF);
      }
      if (!Contains(GuestHeaderAddress, sizeof(LinuxMessageHeader64))) {
        RecvMsgLastLinuxError = EFAULT;
        RecvMsgLastFailureReason = "unreadable-header";
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxMessageHeader64 GuestHeader {};
      std::memcpy(
        &GuestHeader,
        reinterpret_cast<const void*>(GuestHeaderAddress),
        sizeof(GuestHeader));
      RecvMsgLastHeaderReadable = true;
      RecvMsgLastNamePresent = GuestHeader.Name != 0;
      RecvMsgLastNameLength = GuestHeader.NameLength;
      RecvMsgLastIOVectorCount = GuestHeader.IOVectorCount;
      RecvMsgLastControlPresent = GuestHeader.Control != 0;
      RecvMsgLastControlLength = GuestHeader.ControlLength;
      RecvMsgLastMessageFlags = GuestHeader.Flags;
      if (!Contains(GuestHeader.IOVectors, sizeof(LinuxIOVector64))) {
        RecvMsgLastLinuxError = EFAULT;
        RecvMsgLastFailureReason = "unreadable-iovector";
        return static_cast<uint64_t>(-EFAULT);
      }
      LinuxIOVector64 GuestVector {};
      std::memcpy(
        &GuestVector,
        reinterpret_cast<const void*>(GuestHeader.IOVectors),
        sizeof(GuestVector));
      RecvMsgLastFirstIOVectorReadable = true;
      RecvMsgLastFirstIOVectorBase = GuestVector.Base;
      RecvMsgLastFirstIOVectorLength = GuestVector.Length;
      RecvMsgLastFirstIOVectorPayloadReadable = GuestVector.Length == 0
        || Contains(GuestVector.Base, GuestVector.Length);
      RecvMsgLastControlReadable = GuestHeader.ControlLength == 0
        || Contains(GuestHeader.Control, GuestHeader.ControlLength);
      if (!RecvMsgLastFirstIOVectorPayloadReadable) {
        RecvMsgLastLinuxError = EFAULT;
        RecvMsgLastFailureReason = "unreadable-payload";
        return static_cast<uint64_t>(-EFAULT);
      }
      if (!RecvMsgLastControlReadable) {
        RecvMsgLastLinuxError = EFAULT;
        RecvMsgLastFailureReason = "unreadable-control";
        return static_cast<uint64_t>(-EFAULT);
      }
      const bool ExactDirectionalShape =
        (RecvMsgLastCallFlags == LinuxMsgCmsgCloseOnExec
          && GuestVector.Length == ServerToClientPayloadSize)
        || (RecvMsgLastCallFlags == 0
          && GuestVector.Length == ClientToServerPayloadSize);
      const bool ExactMeasuredShape = GuestHeader.Name == 0
        && GuestHeader.NameLength == 0
        && GuestHeader.IOVectorCount == 1
        && GuestHeader.Control != 0
        && GuestHeader.ControlLength == MeasuredControlBufferSize
        && GuestHeader.Flags == 0
        && ExactDirectionalShape;
      if (!ExactMeasuredShape) {
        RecvMsgLastLinuxError = EINVAL;
        RecvMsgLastFailureReason = "unmeasured-shape";
        return static_cast<uint64_t>(-EINVAL);
      }

      iovec HostVector {
        .iov_base = reinterpret_cast<void*>(GuestVector.Base),
        .iov_len = static_cast<size_t>(GuestVector.Length),
      };
      alignas(cmsghdr) std::array<std::byte, 64> HostControlStorage {};
      static_assert(CMSG_SPACE(sizeof(int)) <= HostControlStorage.size());
      msghdr HostHeader {};
      HostHeader.msg_iov = &HostVector;
      HostHeader.msg_iovlen = 1;
      HostHeader.msg_control = HostControlStorage.data();
      HostHeader.msg_controllen = CMSG_SPACE(sizeof(int));
      const ssize_t Result = recvmsg(Descriptor, &HostHeader, 0);
      if (Result == -1) {
        const int HostError = errno;
        const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
        RecvMsgLastHostError = HostError;
        RecvMsgLastLinuxError = LinuxError;
        RecvMsgLastFailureReason = "host-receive-failed";
        return static_cast<uint64_t>(-LinuxError);
      }
      RecvMsgLastByteCount = static_cast<uint64_t>(Result);
      RecvMsgLastHostControlLength = HostHeader.msg_controllen;
      RecvMsgLastHostMessageFlags = HostHeader.msg_flags;
      std::memcpy(
        &RecvMsgLastPayloadValue,
        reinterpret_cast<const void*>(GuestVector.Base),
        sizeof(RecvMsgLastPayloadValue));
      cmsghdr* HostControl = CMSG_FIRSTHDR(&HostHeader);
      const bool ExactHostControl = HostControl != nullptr
        && HostControl->cmsg_len == CMSG_LEN(sizeof(int))
        && HostControl->cmsg_level == SOL_SOCKET
        && HostControl->cmsg_type == SCM_RIGHTS;
      int ReceivedDescriptor {-1};
      if (ExactHostControl) {
        std::memcpy(
          &ReceivedDescriptor,
          CMSG_DATA(HostControl),
          sizeof(ReceivedDescriptor));
      }
      if (Result != static_cast<ssize_t>(GuestVector.Length)
          || HostHeader.msg_flags != 0
          || !ExactHostControl) {
        if (ReceivedDescriptor >= 0) {
          close(ReceivedDescriptor);
        }
        RecvMsgLastLinuxError = EIO;
        RecvMsgLastFailureReason = "unmeasured-host-response";
        return static_cast<uint64_t>(-EIO);
      }
      RecvMsgLastHostControlMessageLength = HostControl->cmsg_len;
      if (ReceivedDescriptor < 0) {
        RecvMsgLastLinuxError = EIO;
        RecvMsgLastFailureReason = "invalid-received-descriptor";
        return static_cast<uint64_t>(-EIO);
      }
      if (RecvMsgLastCallFlags == LinuxMsgCmsgCloseOnExec
          && fcntl(ReceivedDescriptor, F_SETFD, FD_CLOEXEC) != 0) {
        const int HostError = errno;
        const int LinuxError = TranslateHostSocketErrorToLinux(HostError);
        close(ReceivedDescriptor);
        RecvMsgLastHostError = HostError;
        RecvMsgLastLinuxError = LinuxError;
        RecvMsgLastFailureReason = "close-on-exec-failed";
        return static_cast<uint64_t>(-LinuxError);
      }
      const LinuxControlMessageHeader64 GuestControl {
        .Length = LinuxControlMessageLength,
        .Level = LinuxSOLSocket,
        .Type = LinuxSCMRights,
      };
      std::memcpy(
        reinterpret_cast<void*>(GuestHeader.Control),
        &GuestControl,
        sizeof(GuestControl));
      std::memcpy(
        reinterpret_cast<void*>(
          GuestHeader.Control + sizeof(LinuxControlMessageHeader64)),
        &ReceivedDescriptor,
        sizeof(ReceivedDescriptor));
      GuestHeader.ControlLength = LinuxControlMessageLength;
      GuestHeader.Flags = 0;
      std::memcpy(
        reinterpret_cast<void*>(GuestHeaderAddress),
        &GuestHeader,
        sizeof(GuestHeader));
      OwnedDescriptors.insert(ReceivedDescriptor);
      ReceivedSCMRightsDescriptors.insert(ReceivedDescriptor);
      RecvMsgLastReceivedDescriptor = ReceivedDescriptor;
      RecvMsgLastControlLength = LinuxControlMessageLength;
      ++RecvMsgSuccessCount;
      return static_cast<uint64_t>(Result);
    }
    if (Number == IoctlSyscall && !RootFS.empty()
        && Arguments->Argument[2] == LinuxTCGets2) {
      ++IoctlTCGets2CandidateCount;
      constexpr size_t LinuxTermios2Size = 44;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Argument = Arguments->Argument[3];
      IoctlTCGets2LastDescriptor = Descriptor;
      IoctlTCGets2LastArgument = Argument;
      IoctlTCGets2LastDescriptorStandard = Descriptor >= STDIN_FILENO
        && Descriptor <= STDERR_FILENO;
      IoctlTCGets2LastDescriptorClosed = IoctlTCGets2LastDescriptorStandard
        && ClosedStandardDescriptors.contains(Descriptor);
      IoctlTCGets2LastArgumentWritable =
        HostPointerForGuestRange(Argument, LinuxTermios2Size, PROT_WRITE) != nullptr;

      struct stat DescriptorStat {};
      IoctlTCGets2LastDescriptorStatSucceeded =
        fstat(Descriptor, &DescriptorStat) == 0;
      IoctlTCGets2LastDescriptorCharacter =
        IoctlTCGets2LastDescriptorStatSucceeded
        && S_ISCHR(DescriptorStat.st_mode);
      IoctlTCGets2LastDescriptorFIFO =
        IoctlTCGets2LastDescriptorStatSucceeded
        && S_ISFIFO(DescriptorStat.st_mode);
      errno = 0;
      IoctlTCGets2LastDescriptorTTY = isatty(Descriptor) == 1;
      IoctlTCGets2LastHostError = errno;

      if (IoctlTCGets2LastDescriptorStandard
          && !IoctlTCGets2LastDescriptorClosed
          && IoctlTCGets2LastArgumentWritable
          && IoctlTCGets2LastDescriptorStatSucceeded
          && !IoctlTCGets2LastDescriptorTTY) {
        // glibc implements isatty() with TCGETS2 on Linux. The laboratory's
        // inherited standard streams may be /dev/null or runner pipes. Linux
        // reports ENOTTY for every valid non-terminal descriptor and leaves
        // termios2 untouched; this is exactly the branch Wine uses to select
        // its no-console path.
        ++IoctlTCGets2NonTTYCount;
        IoctlTCGets2LastLinuxError = ENOTTY;
        return static_cast<uint64_t>(-ENOTTY);
      }
    }
    if (Number == IoctlSyscall && !RootFS.empty()
        && Arguments->Argument[2] == LinuxExt2IOCGetFlags) {
      ++IoctlExt2GetFlagsCandidateCount;
      const int Descriptor = static_cast<int>(Arguments->Argument[1]);
      const uint64_t Argument = Arguments->Argument[3];
      IoctlExt2GetFlagsLastDescriptor = Descriptor;
      IoctlExt2GetFlagsLastArgument = Argument;
      IoctlExt2GetFlagsLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
      if (!IoctlExt2GetFlagsLastDescriptorOwned) {
        IoctlExt2GetFlagsLastLinuxError = EBADF;
        return static_cast<uint64_t>(-EBADF);
      }

      constexpr size_t LinuxLongSize = sizeof(uint64_t);
      IoctlExt2GetFlagsLastArgumentWritable =
        HostPointerForGuestRange(Argument, LinuxLongSize, PROT_WRITE) != nullptr;
      if (!IoctlExt2GetFlagsLastArgumentWritable) {
        IoctlExt2GetFlagsLastLinuxError = EFAULT;
        return static_cast<uint64_t>(-EFAULT);
      }

      struct stat DescriptorStat {};
      IoctlExt2GetFlagsLastDescriptorStatSucceeded =
        fstat(Descriptor, &DescriptorStat) == 0;
      IoctlExt2GetFlagsLastDescriptorDirectory =
        IoctlExt2GetFlagsLastDescriptorStatSucceeded
        && S_ISDIR(DescriptorStat.st_mode);
      IoctlExt2GetFlagsLastDescriptorRegular =
        IoctlExt2GetFlagsLastDescriptorStatSucceeded
        && S_ISREG(DescriptorStat.st_mode);

      std::array<char, 4096> DescriptorPath {};
      if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) == 0) {
        const std::string HostPath {DescriptorPath.data()};
        IoctlExt2GetFlagsLastDescriptorPathReadable = true;
        IoctlExt2GetFlagsLastDescriptorPathLength = HostPath.size();
        IoctlExt2GetFlagsLastDescriptorPathFingerprint = FingerprintBytes(
          reinterpret_cast<const uint8_t*>(HostPath.data()),
          HostPath.size());
        IoctlExt2GetFlagsLastDescriptorPathConfined =
          HostPath == RootFS || HostPath.starts_with(RootFS + '/');
      }

      if (!IoctlExt2GetFlagsLastDescriptorStatSucceeded
          || (!IoctlExt2GetFlagsLastDescriptorDirectory
            && !IoctlExt2GetFlagsLastDescriptorRegular)
          || !IoctlExt2GetFlagsLastDescriptorPathConfined) {
        IoctlExt2GetFlagsLastLinuxError = EACCES;
        return static_cast<uint64_t>(-EACCES);
      }

      // Proton's Linux Wine asks for ext2 flags before falling back to
      // fstatfs. The private RootFS is hosted by APFS, so there is no ext2
      // attribute namespace to translate. ENOTTY is the Linux contract for
      // an otherwise valid descriptor whose filesystem does not implement
      // EXT2_IOC_GETFLAGS; it deliberately leaves the guest buffer untouched.
      ++IoctlExt2GetFlagsUnsupportedFilesystemCount;
      IoctlExt2GetFlagsLastLinuxError = ENOTTY;
      return static_cast<uint64_t>(-ENOTTY);
    }
    if (UnexpectedSyscall == std::numeric_limits<uint64_t>::max()) {
      UnexpectedSyscall = Number;
      if (Number == SchedGetAffinitySyscall) {
        const int64_t ProcessID = static_cast<int64_t>(Arguments->Argument[1]);
        const uint64_t CPUSetSize = Arguments->Argument[2];
        const uint64_t GuestMask = Arguments->Argument[3];
        const bool MaskRangeReadable = CPUSetSize != 0
          && CPUSetSize <= 4096
          && Contains(GuestMask, CPUSetSize);
        std::cerr << "TRACE sched_getaffinity"
                  << " pid=" << ProcessID
                  << " cpusetsize=" << CPUSetSize
                  << " mask=" << GuestMask
                  << " mask-class="
                  << (MaskRangeReadable ? "guest-memory" : "scalar-or-outside")
                  << " mask-range-readable=" << (MaskRangeReadable ? 1 : 0)
                  << '\n';
        std::cerr.flush();
      }
      if (Number == DupSyscall) {
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const bool DescriptorOwned = OwnedDescriptors.contains(Descriptor);
        const bool DescriptorStandard = Descriptor >= STDIN_FILENO
          && Descriptor <= STDERR_FILENO;
        const bool DescriptorClosed = DescriptorStandard
          && ClosedStandardDescriptors.contains(Descriptor);
        struct stat DescriptorStat {};
        const bool DescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
        const int DescriptorFlags = fcntl(Descriptor, F_GETFD);
        const int StatusFlags = fcntl(Descriptor, F_GETFL);
        std::cerr << "TRACE dup"
                  << " descriptor=" << Descriptor
                  << " owned=" << (DescriptorOwned ? 1 : 0)
                  << " standard=" << (DescriptorStandard ? 1 : 0)
                  << " closed=" << (DescriptorClosed ? 1 : 0)
                  << " stat-ok=" << (DescriptorStatSucceeded ? 1 : 0)
                  << " regular="
                  << (DescriptorStatSucceeded && S_ISREG(DescriptorStat.st_mode) ? 1 : 0)
                  << " fifo="
                  << (DescriptorStatSucceeded && S_ISFIFO(DescriptorStat.st_mode) ? 1 : 0)
                  << " socket="
                  << (DescriptorStatSucceeded && S_ISSOCK(DescriptorStat.st_mode) ? 1 : 0)
                  << " descriptor-flags=" << DescriptorFlags
                  << " status-flags=" << StatusFlags
                  << '\n';
        std::cerr.flush();
      }
      if (Number == TgkillSyscall) {
        UnsupportedTgkillBoundarySeen = true;
        UnsupportedTgkillThreadGroupID = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedTgkillThreadID = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedTgkillSignal = static_cast<int64_t>(Arguments->Argument[3]);
        UnsupportedTgkillThreadGroupMatchesLastGetPID = GetPIDSeen
          && UnsupportedTgkillThreadGroupID == static_cast<int64_t>(LastGetPID);
        UnsupportedTgkillThreadMatchesLastGetTID = GetTIDSeen
          && UnsupportedTgkillThreadID == static_cast<int64_t>(GetTIDLastMachPort);
      }
      if (Number == UmaskSyscall) {
        UnsupportedUmaskBoundarySeen = true;
        UnsupportedUmaskRequestedMode = Arguments->Argument[1];
        UnsupportedUmaskRequestedModePermissionBitsOnly =
          (UnsupportedUmaskRequestedMode & ~0777ULL) == 0;
        UnsupportedUmaskCallOrdinal = HandleSyscallCallCount;
        UnsupportedUmaskGuestRIP = Frame->State.rip;
        UnsupportedUmaskWriteRequestPipeCountAtBoundary = WriteRequestPipeCandidateCount;
        UnsupportedUmaskReadWineFixedReplyCountAtBoundary = ReadWineFixedReplyCount;
        UnsupportedUmaskWriteRejectedCountAtBoundary = WriteRejectedCallCount;
      }
      if (Number == GetDents64Syscall) {
        UnsupportedGetDents64BoundarySeen = true;
        UnsupportedGetDents64CallOrdinal = HandleSyscallCallCount;
        UnsupportedGetDents64GuestRIP = Frame->State.rip;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestBuffer = Arguments->Argument[2];
        const uint64_t ByteCount = Arguments->Argument[3];
        UnsupportedGetDents64Descriptor = Descriptor;
        UnsupportedGetDents64DescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedGetDents64GuestBuffer = GuestBuffer;
        UnsupportedGetDents64ByteCount = ByteCount;

        struct stat DescriptorStat {};
        UnsupportedGetDents64DescriptorStatSucceeded =
          fstat(Descriptor, &DescriptorStat) == 0;
        UnsupportedGetDents64DescriptorDirectory =
          UnsupportedGetDents64DescriptorStatSucceeded
          && S_ISDIR(DescriptorStat.st_mode);

        errno = 0;
        const off_t CurrentOffset = lseek(Descriptor, 0, SEEK_CUR);
        if (CurrentOffset != static_cast<off_t>(-1)) {
          UnsupportedGetDents64DescriptorOffsetReadable = true;
          UnsupportedGetDents64DescriptorOffset = static_cast<int64_t>(CurrentOffset);
        } else {
          UnsupportedGetDents64DescriptorOffsetHostError = errno;
        }

        std::array<char, 4096> DescriptorPath {};
        if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) == 0) {
          const std::string HostPath {DescriptorPath.data()};
          UnsupportedGetDents64DescriptorPathReadable = true;
          UnsupportedGetDents64DescriptorPathLength = HostPath.size();
          UnsupportedGetDents64DescriptorPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(HostPath.data()),
            HostPath.size());
          UnsupportedGetDents64DescriptorPathConfined = !RootFS.empty()
            && (HostPath == RootFS || HostPath.starts_with(RootFS + '/'));
        }

        if (GuestBuffer == 0) {
          UnsupportedGetDents64BufferClass = "zero";
        } else if (ByteCount == 0) {
          UnsupportedGetDents64BufferClass = "empty-span";
        } else if (Contains(GuestBuffer, ByteCount)) {
          UnsupportedGetDents64BufferClass = "guest-memory";
          UnsupportedGetDents64BufferWritable = true;
        } else if (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
            && LowGuestShadow->HostPointerForMappedLogicalRange(
              GuestBuffer, ByteCount, PROT_WRITE) != nullptr) {
          UnsupportedGetDents64BufferClass = "low-shadow";
          UnsupportedGetDents64BufferWritable = true;
        } else if (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
            && HighGuestSparse->HostPointerForMappedLogicalRange(
              GuestBuffer, ByteCount, PROT_WRITE) != nullptr) {
          UnsupportedGetDents64BufferClass = "high-sparse";
          UnsupportedGetDents64BufferWritable = true;
        } else {
          UnsupportedGetDents64BufferClass = "scalar-or-unmapped";
        }
      }
      if (Number == IoctlSyscall) {
        constexpr uint64_t LinuxIOCNumberMask = 0xff;
        constexpr uint64_t LinuxIOCTypeMask = 0xff;
        constexpr uint64_t LinuxIOCSizeMask = 0x3fff;
        constexpr uint64_t LinuxIOCDirectionMask = 0x3;
        UnsupportedIoctlBoundarySeen = true;
        UnsupportedIoctlCallOrdinal = HandleSyscallCallCount;
        UnsupportedIoctlGuestRIP = Frame->State.rip;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t Request = Arguments->Argument[2];
        const uint64_t Argument = Arguments->Argument[3];
        UnsupportedIoctlDescriptor = Descriptor;
        UnsupportedIoctlRequest = Request;
        UnsupportedIoctlArgument = Argument;
        UnsupportedIoctlDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedIoctlDescriptorStandard = Descriptor >= STDIN_FILENO
          && Descriptor <= STDERR_FILENO;
        UnsupportedIoctlDescriptorClosed = UnsupportedIoctlDescriptorStandard
          && ClosedStandardDescriptors.contains(Descriptor);
        UnsupportedIoctlRequestNumber = Request & LinuxIOCNumberMask;
        UnsupportedIoctlRequestType = (Request >> 8) & LinuxIOCTypeMask;
        UnsupportedIoctlRequestSize = (Request >> 16) & LinuxIOCSizeMask;
        UnsupportedIoctlRequestDirection = (Request >> 30) & LinuxIOCDirectionMask;

        struct stat DescriptorStat {};
        UnsupportedIoctlDescriptorStatSucceeded = fstat(Descriptor, &DescriptorStat) == 0;
        UnsupportedIoctlDescriptorFIFO = UnsupportedIoctlDescriptorStatSucceeded
          && S_ISFIFO(DescriptorStat.st_mode);
        UnsupportedIoctlDescriptorSocket = UnsupportedIoctlDescriptorStatSucceeded
          && S_ISSOCK(DescriptorStat.st_mode);
        UnsupportedIoctlDescriptorRegular = UnsupportedIoctlDescriptorStatSucceeded
          && S_ISREG(DescriptorStat.st_mode);
        UnsupportedIoctlDescriptorCharacter = UnsupportedIoctlDescriptorStatSucceeded
          && S_ISCHR(DescriptorStat.st_mode);
        UnsupportedIoctlDescriptorTTY = isatty(Descriptor) == 1;
        UnsupportedIoctlDescriptorFlags = fcntl(Descriptor, F_GETFL);
        UnsupportedIoctlDescriptorFlagsReadable = UnsupportedIoctlDescriptorFlags != -1;

        const uint64_t DiagnosticSize = UnsupportedIoctlRequestSize != 0
          && UnsupportedIoctlRequestSize <= 4096
          ? UnsupportedIoctlRequestSize
          : 1;
        const void* ReadableArgument = Argument != 0
          ? HostPointerForGuestRange(Argument, DiagnosticSize, PROT_READ)
          : nullptr;
        void* WritableArgument = Argument != 0
          ? HostPointerForGuestRange(Argument, DiagnosticSize, PROT_WRITE)
          : nullptr;
        UnsupportedIoctlArgumentReadable = ReadableArgument != nullptr;
        UnsupportedIoctlArgumentWritable = WritableArgument != nullptr;
        UnsupportedIoctlArgumentClass = Argument == 0
          ? "zero"
          : (Contains(Argument, DiagnosticSize)
              ? "guest-memory"
              : (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
                  && LowGuestShadow->HostPointerForMappedLogicalRange(
                    Argument, DiagnosticSize, PROT_READ) != nullptr
                ? "low-shadow"
                : (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr
                    && HighGuestSparse->HostPointerForMappedLogicalRange(
                      Argument, DiagnosticSize, PROT_READ) != nullptr
                  ? "high-sparse"
                  : "scalar-or-unmapped")));
        if (ReadableArgument != nullptr && DiagnosticSize <= 4096) {
          UnsupportedIoctlArgumentFingerprint = FingerprintBytes(
            static_cast<const uint8_t*>(ReadableArgument),
            static_cast<size_t>(DiagnosticSize));
        }
        UnsupportedIoctlReadWineFixedReplyCountAtBoundary = ReadWineFixedReplyCount;
        UnsupportedIoctlWriteRequestPipeCountAtBoundary = WriteRequestPipeCandidateCount;
      }
      if (Number == SocketSyscall) {
        UnsupportedSocketBoundarySeen = true;
        UnsupportedSocketDomain = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedSocketType = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedSocketProtocol = static_cast<int64_t>(Arguments->Argument[3]);
      }
      if (Number == AcceptSyscall) {
        UnsupportedAcceptBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestAddress = Arguments->Argument[2];
        const uint64_t GuestAddressLength = Arguments->Argument[3];
        UnsupportedAcceptDescriptor = Descriptor;
        UnsupportedAcceptDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedAcceptAddressClass = GuestAddress == 0
          ? "zero"
          : (Contains(GuestAddress, sizeof(uint16_t))
              ? "guest-memory"
              : "scalar-or-outside");
        UnsupportedAcceptAddressLengthClass = GuestAddressLength == 0
          ? "zero"
          : (Contains(GuestAddressLength, sizeof(uint32_t))
              ? "guest-memory"
              : "scalar-or-outside");
        if (Contains(GuestAddressLength, sizeof(uint32_t))) {
          std::memcpy(
            &UnsupportedAcceptAddressLength,
            reinterpret_cast<const void*>(GuestAddressLength),
            sizeof(UnsupportedAcceptAddressLength));
          UnsupportedAcceptAddressLengthReadable = true;
        }
      }
      if (Number == GetSockOptSyscall) {
        UnsupportedGetSockOptBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestValue = Arguments->Argument[4];
        const uint64_t GuestValueLength = Arguments->Argument[5];
        UnsupportedGetSockOptDescriptor = Descriptor;
        UnsupportedGetSockOptDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedGetSockOptLevel = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedGetSockOptOption = static_cast<int64_t>(Arguments->Argument[3]);
        UnsupportedGetSockOptValuePointerNonZero = GuestValue != 0;
        UnsupportedGetSockOptLengthPointerNonZero = GuestValueLength != 0;
        if (Contains(GuestValueLength, sizeof(uint32_t))) {
          std::memcpy(
            &UnsupportedGetSockOptValueLength,
            reinterpret_cast<const void*>(GuestValueLength),
            sizeof(UnsupportedGetSockOptValueLength));
          UnsupportedGetSockOptLengthReadable = true;
          if (UnsupportedGetSockOptValueLength <= 4096
              && Contains(GuestValue, UnsupportedGetSockOptValueLength)) {
            UnsupportedGetSockOptValueReadable = true;
          }
        }
      }
      if (Number == SendMsgSyscall) {
        UnsupportedSendMsgBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestHeader = Arguments->Argument[2];
        UnsupportedSendMsgDescriptor = Descriptor;
        UnsupportedSendMsgDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedSendMsgCallFlags = static_cast<int64_t>(Arguments->Argument[3]);
        if (Contains(GuestHeader, sizeof(LinuxMessageHeader64))) {
          LinuxMessageHeader64 Header {};
          std::memcpy(&Header, reinterpret_cast<const void*>(GuestHeader), sizeof(Header));
          UnsupportedSendMsgHeaderReadable = true;
          UnsupportedSendMsgNamePresent = Header.Name != 0;
          UnsupportedSendMsgNameLength = Header.NameLength;
          UnsupportedSendMsgIOVectorCount = Header.IOVectorCount;
          UnsupportedSendMsgControlPresent = Header.Control != 0;
          UnsupportedSendMsgControlLength = Header.ControlLength;
          UnsupportedSendMsgMessageFlags = Header.Flags;
          if (Header.IOVectorCount == 1
              && Contains(Header.IOVectors, sizeof(LinuxIOVector64))) {
            LinuxIOVector64 Vector {};
            std::memcpy(
              &Vector,
              reinterpret_cast<const void*>(Header.IOVectors),
              sizeof(Vector));
            UnsupportedSendMsgFirstIOVectorReadable = true;
            UnsupportedSendMsgFirstIOVectorLength = Vector.Length;
            if (Vector.Length >= sizeof(uint32_t)
                && Contains(Vector.Base, sizeof(uint32_t))) {
              std::memcpy(
                &UnsupportedSendMsgFirstIOVectorValue,
                reinterpret_cast<const void*>(Vector.Base),
                sizeof(UnsupportedSendMsgFirstIOVectorValue));
              UnsupportedSendMsgFirstIOVectorValueReadable = true;
            }
          }
          if (Header.ControlLength >= sizeof(LinuxControlMessageHeader64)
              && Contains(Header.Control, sizeof(LinuxControlMessageHeader64))) {
            LinuxControlMessageHeader64 Control {};
            std::memcpy(
              &Control,
              reinterpret_cast<const void*>(Header.Control),
              sizeof(Control));
            UnsupportedSendMsgFirstControlReadable = true;
            UnsupportedSendMsgFirstControlMessageLength = Control.Length;
            UnsupportedSendMsgFirstControlLevel = Control.Level;
            UnsupportedSendMsgFirstControlType = Control.Type;
            if (Control.Length >= sizeof(LinuxControlMessageHeader64) + sizeof(int32_t)
                && Contains(
                  Header.Control + sizeof(LinuxControlMessageHeader64),
                  sizeof(int32_t))) {
              std::memcpy(
                &UnsupportedSendMsgFirstControlDescriptor,
                reinterpret_cast<const void*>(
                  Header.Control + sizeof(LinuxControlMessageHeader64)),
                sizeof(UnsupportedSendMsgFirstControlDescriptor));
              UnsupportedSendMsgFirstControlDescriptorReadable = true;
              UnsupportedSendMsgFirstControlDescriptorOwned = OwnedDescriptors.contains(
                UnsupportedSendMsgFirstControlDescriptor);
            }
          }
        }
      }
      if (Number == MUnmapSyscall) {
        UnsupportedMUnmapBoundarySeen = true;
        const uint64_t Address = Arguments->Argument[1];
        const uint64_t Length = Arguments->Argument[2];
        UnsupportedMUnmapAddress = Address;
        UnsupportedMUnmapLength = Length;
        UnsupportedMUnmapAddressLinuxPageAligned = Address % LinuxGuestPageSize == 0;
        UnsupportedMUnmapLengthLinuxPageAligned = Length % LinuxGuestPageSize == 0;
        UnsupportedMUnmapRangeInGuestMemory = Contains(Address, Length);
        UnsupportedMUnmapRangeInMMapArena = ContainsMMapArena(Address, Length);
        UnsupportedMUnmapRangeBelowNextMMapAddress = Address >= MMapArenaBase
          && Address <= NextMMapAddress
          && Length <= NextMMapAddress - Address;
        UnsupportedMUnmapMatchesLastMapping = Address == MMapLastMappingAddress
          && Length == MMapLastAlignedLength;
        UnsupportedMUnmapAddressOffsetFromArena = Address >= MMapArenaBase
          ? Address - MMapArenaBase
          : std::numeric_limits<uint64_t>::max();
        UnsupportedMUnmapLastMappingAddress = MMapLastMappingAddress;
        UnsupportedMUnmapLastMappingLength = MMapLastAlignedLength;
      }
      if (Number == SocketPairSyscall) {
        UnsupportedSocketPairBoundarySeen = true;
        UnsupportedSocketPairDomain = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedSocketPairType = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedSocketPairProtocol = static_cast<int64_t>(Arguments->Argument[3]);
        const uint64_t GuestPair = Arguments->Argument[4];
        if (Contains(GuestPair, 2 * sizeof(int32_t))) {
          UnsupportedSocketPairVectorClass = "guest-memory";
          UnsupportedSocketPairVectorReadable = true;
        } else if (GuestPair == 0) {
          UnsupportedSocketPairVectorClass = "zero";
        } else {
          UnsupportedSocketPairVectorClass = "scalar-or-outside";
        }
      }
      if (Number == ShutdownSyscall) {
        UnsupportedShutdownBoundarySeen = true;
        UnsupportedShutdownDescriptor = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedShutdownHow = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedShutdownDescriptorOwned = OwnedDescriptors.contains(
          static_cast<int>(UnsupportedShutdownDescriptor));
      }
      if (Number == PollSyscall) {
        UnsupportedPollBoundarySeen = true;
        const uint64_t GuestPollDescriptors = Arguments->Argument[1];
        UnsupportedPollDescriptorCount = Arguments->Argument[2];
        UnsupportedPollTimeout = static_cast<int64_t>(Arguments->Argument[3]);
        if (UnsupportedPollDescriptorCount <= 1024
            && Contains(
              GuestPollDescriptors,
              UnsupportedPollDescriptorCount * sizeof(LinuxPollFD))) {
          UnsupportedPollArrayReadable = true;
          if (UnsupportedPollDescriptorCount != 0) {
            LinuxPollFD FirstDescriptor {};
            std::memcpy(
              &FirstDescriptor,
              reinterpret_cast<const void*>(GuestPollDescriptors),
              sizeof(FirstDescriptor));
            UnsupportedPollFirstDescriptor = FirstDescriptor.Descriptor;
            UnsupportedPollFirstEvents = FirstDescriptor.Events;
            UnsupportedPollFirstReturnedEvents = FirstDescriptor.ReturnedEvents;
            UnsupportedPollFirstDescriptorOwned = OwnedDescriptors.contains(
              FirstDescriptor.Descriptor);
          }
        }
      }
      if (Number == Pipe2Syscall) {
        UnsupportedPipe2BoundarySeen = true;
        const uint64_t GuestPipe = Arguments->Argument[1];
        UnsupportedPipe2Flags = Arguments->Argument[2];
        UnsupportedPipe2VectorReadable = Contains(GuestPipe, 2 * sizeof(int32_t));
        UnsupportedPipe2VectorClass = UnsupportedPipe2VectorReadable
          ? "guest-memory"
          : (GuestPipe == 0 ? "zero" : "scalar-or-outside");
      }
      if (Number == ConnectSyscall) {
        UnsupportedConnectBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestAddress = Arguments->Argument[2];
        const uint64_t AddressLength = Arguments->Argument[3];
        UnsupportedConnectDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedConnectAddressLength = AddressLength;
        constexpr uint64_t LinuxSockaddrUnMaximum = 110;
        if (AddressLength >= sizeof(uint16_t) && AddressLength <= LinuxSockaddrUnMaximum
            && Contains(GuestAddress, AddressLength)) {
          uint16_t Family {};
          std::memcpy(&Family, reinterpret_cast<const void*>(GuestAddress), sizeof(Family));
          UnsupportedConnectFamily = Family;
          const auto* Path = reinterpret_cast<const uint8_t*>(GuestAddress + sizeof(Family));
          const size_t PayloadLength = static_cast<size_t>(AddressLength - sizeof(Family));
          UnsupportedConnectPathFingerprint = FingerprintBytes(Path, PayloadLength);
          if (PayloadLength == 0) {
            UnsupportedConnectPathClass = "empty";
          } else if (Path[0] == '\0') {
            UnsupportedConnectPathClass = "abstract";
            UnsupportedConnectPathLength = PayloadLength;
          } else {
            const auto* Terminator = static_cast<const uint8_t*>(
              std::memchr(Path, '\0', PayloadLength));
            UnsupportedConnectPathLength = Terminator == nullptr
              ? PayloadLength
              : static_cast<size_t>(Terminator - Path);
            UnsupportedConnectPathClass = Path[0] == '/' ? "absolute" : "relative";
            const std::string GuestSocketPath {
              reinterpret_cast<const char*>(Path),
              UnsupportedConnectPathLength,
            };
            TraceGuestPath("connect", GuestSocketPath);
          }
        }
      }
      if (Number == BindSyscall) {
        UnsupportedBindBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestAddress = Arguments->Argument[2];
        const uint64_t AddressLength = Arguments->Argument[3];
        UnsupportedBindDescriptor = Descriptor;
        UnsupportedBindDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedBindAddressLength = AddressLength;
        constexpr uint64_t LinuxSockaddrUnMaximum = 110;
        if (AddressLength >= sizeof(uint16_t) && AddressLength <= LinuxSockaddrUnMaximum
            && Contains(GuestAddress, AddressLength)) {
          UnsupportedBindAddressReadable = true;
          uint16_t Family {};
          std::memcpy(&Family, reinterpret_cast<const void*>(GuestAddress), sizeof(Family));
          UnsupportedBindFamily = Family;
          const auto* Path = reinterpret_cast<const uint8_t*>(GuestAddress + sizeof(Family));
          const size_t PayloadLength = static_cast<size_t>(AddressLength - sizeof(Family));
          UnsupportedBindPathFingerprint = FingerprintBytes(Path, PayloadLength);
          if (PayloadLength == 0) {
            UnsupportedBindPathClass = "empty";
          } else if (Path[0] == '\0') {
            UnsupportedBindPathClass = "abstract";
            UnsupportedBindPathLength = PayloadLength;
          } else {
            const auto* Terminator = static_cast<const uint8_t*>(
              std::memchr(Path, '\0', PayloadLength));
            UnsupportedBindPathLength = Terminator == nullptr
              ? PayloadLength
              : static_cast<size_t>(Terminator - Path);
            UnsupportedBindPathTerminated = Terminator != nullptr;
            UnsupportedBindPathClass = Path[0] == '/' ? "absolute" : "relative";
            const std::string GuestSocketPath {
              reinterpret_cast<const char*>(Path),
              UnsupportedBindPathLength,
            };
            TraceGuestPath("bind", GuestSocketPath);
            const auto HostPath = ResolveGuestCreationPath(GuestSocketPath);
            UnsupportedBindHostPathResolved = HostPath.has_value();
            if (HostPath.has_value()) {
              struct stat TargetStat {};
              UnsupportedBindTargetExists = lstat(HostPath->c_str(), &TargetStat) == 0;
            }
          }
        }
      }
      if (Number == ListenSyscall) {
        UnsupportedListenBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        UnsupportedListenDescriptor = Descriptor;
        UnsupportedListenDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedListenBacklog = static_cast<int64_t>(Arguments->Argument[2]);
      }
      if (Number == SetPrioritySyscall) {
        UnsupportedSetPriorityBoundarySeen = true;
        UnsupportedSetPriorityWhich = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedSetPriorityWho = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedSetPriorityNice = static_cast<int32_t>(Arguments->Argument[3]);
      }
      if (Number == FutexWaitVSyscall) {
        UnsupportedFutexWaitVBoundarySeen = true;
        const uint64_t GuestWaiters = Arguments->Argument[1];
        const uint64_t WaiterCount = Arguments->Argument[2];
        const uint64_t Flags = Arguments->Argument[3];
        const uint64_t GuestTimeout = Arguments->Argument[4];
        const int64_t ClockID = static_cast<int64_t>(Arguments->Argument[5]);
        UnsupportedFutexWaitVWaiterCount = WaiterCount;
        UnsupportedFutexWaitVFlags = Flags;
        UnsupportedFutexWaitVClockID = ClockID;

        if (WaiterCount <= 128
            && WaiterCount <= std::numeric_limits<uint64_t>::max() / sizeof(LinuxFutexWaitV)
            && Contains(GuestWaiters, WaiterCount * sizeof(LinuxFutexWaitV))) {
          UnsupportedFutexWaitVArrayReadable = true;
          if (WaiterCount != 0) {
            LinuxFutexWaitV FirstWaiter {};
            std::memcpy(
              &FirstWaiter,
              reinterpret_cast<const void*>(GuestWaiters),
              sizeof(FirstWaiter));
            UnsupportedFutexWaitVFirstExpectedValue = FirstWaiter.Value;
            UnsupportedFutexWaitVFirstAddress = FirstWaiter.Address;
            UnsupportedFutexWaitVFirstFlags = FirstWaiter.Flags;
            UnsupportedFutexWaitVFirstReserved = FirstWaiter.Reserved;
            if (Contains(FirstWaiter.Address, sizeof(uint32_t))) {
              UnsupportedFutexWaitVFirstAddressClass = "guest-memory";
              UnsupportedFutexWaitVFirstAddressReadable = true;
              std::memcpy(
                &UnsupportedFutexWaitVFirstCurrentValue,
                reinterpret_cast<const void*>(FirstWaiter.Address),
                sizeof(UnsupportedFutexWaitVFirstCurrentValue));
            } else if (FirstWaiter.Address == 0) {
              UnsupportedFutexWaitVFirstAddressClass = "zero";
            } else if (FirstWaiter.Address < LowGuestAddressLimit) {
              UnsupportedFutexWaitVFirstAddressClass = "low-logical";
            } else {
              UnsupportedFutexWaitVFirstAddressClass = "scalar-or-outside";
            }
          }
        }

        if (GuestTimeout == 0) {
          UnsupportedFutexWaitVTimeoutClass = "zero";
        } else if (Contains(GuestTimeout, sizeof(LinuxTimespec64))) {
          UnsupportedFutexWaitVTimeoutClass = "guest-memory";
          UnsupportedFutexWaitVTimeoutReadable = true;
          LinuxTimespec64 Timeout {};
          std::memcpy(
            &Timeout,
            reinterpret_cast<const void*>(GuestTimeout),
            sizeof(Timeout));
          UnsupportedFutexWaitVTimeoutSeconds = Timeout.Seconds;
          UnsupportedFutexWaitVTimeoutNanoseconds = Timeout.Nanoseconds;
        } else {
          UnsupportedFutexWaitVTimeoutClass = "scalar-or-outside";
        }
      }
      if (Number == EpollCreateSyscall) {
        UnsupportedEpollCreateBoundarySeen = true;
        UnsupportedEpollCreateSize = static_cast<int64_t>(Arguments->Argument[1]);
      }
      if (Number == EpollCtlSyscall) {
        UnsupportedEpollCtlBoundarySeen = true;
        const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
        const int64_t Operation = static_cast<int64_t>(Arguments->Argument[2]);
        const int TargetDescriptor = static_cast<int>(Arguments->Argument[3]);
        const uint64_t GuestEvent = Arguments->Argument[4];
        UnsupportedEpollCtlEpollDescriptor = EpollDescriptor;
        UnsupportedEpollCtlOperation = Operation;
        UnsupportedEpollCtlTargetDescriptor = TargetDescriptor;
        UnsupportedEpollCtlEpollDescriptorOwned = OwnedDescriptors.contains(EpollDescriptor);
        UnsupportedEpollCtlEpollDescriptorKnown = EpollDescriptors.contains(EpollDescriptor);
        UnsupportedEpollCtlTargetDescriptorOwned = OwnedDescriptors.contains(TargetDescriptor);
        UnsupportedEpollCtlEventClass = GuestEvent == 0
          ? "zero"
          : (Contains(GuestEvent, sizeof(LinuxEpollEvent))
              ? "guest-memory"
              : "scalar-or-outside");
        if (Contains(GuestEvent, sizeof(LinuxEpollEvent))) {
          LinuxEpollEvent Event {};
          std::memcpy(
            &Event,
            reinterpret_cast<const void*>(GuestEvent),
            sizeof(Event));
          UnsupportedEpollCtlEventReadable = true;
          UnsupportedEpollCtlEvents = Event.Events;
          UnsupportedEpollCtlData = Event.Data;
        }
      }
      if (Number == GettimeofdaySyscall) {
        UnsupportedGettimeofdayBoundarySeen = true;
        const uint64_t GuestTime = Arguments->Argument[1];
        const uint64_t GuestTimezone = Arguments->Argument[2];
        UnsupportedGettimeofdayTimeClass = GuestTime == 0
          ? "zero"
          : (Contains(GuestTime, sizeof(LinuxTimeval64))
              ? "guest-memory"
              : "scalar-or-outside");
        UnsupportedGettimeofdayTimeReadable = Contains(
          GuestTime,
          sizeof(LinuxTimeval64));
        UnsupportedGettimeofdayTimezoneClass = GuestTimezone == 0
          ? "zero"
          : (Contains(GuestTimezone, sizeof(LinuxTimezone))
              ? "guest-memory"
              : "scalar-or-outside");
        UnsupportedGettimeofdayTimezoneReadable = Contains(
          GuestTimezone,
          sizeof(LinuxTimezone));
      }
      if (Number == FStatFSSyscall) {
        UnsupportedFStatFSBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestBuffer = Arguments->Argument[2];
        UnsupportedFStatFSDescriptor = Descriptor;
        UnsupportedFStatFSDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedFStatFSDescriptorMatchesIntlNLS = Descriptor == IntlNLSLastDescriptor;
        UnsupportedFStatFSBufferClass = GuestBuffer == 0
          ? "zero"
          : (Contains(GuestBuffer, 1) ? "guest-memory" : "scalar-or-outside");
      }
      if (Number == FAccessAt2Syscall) {
        UnsupportedFAccessAt2BoundarySeen = true;
        UnsupportedFAccessAt2DirectoryDescriptor = static_cast<int32_t>(Arguments->Argument[1]);
        const auto GuestPath = ReadGuestPath(Arguments->Argument[2]);
        UnsupportedFAccessAt2Mode = Arguments->Argument[3];
        UnsupportedFAccessAt2Flags = Arguments->Argument[4];
        UnsupportedFAccessAt2PathReadable = GuestPath.has_value();
        if (GuestPath.has_value()) {
          UnsupportedFAccessAt2PathLength = GuestPath->size();
          UnsupportedFAccessAt2PathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          UnsupportedFAccessAt2PathClass = GuestPath->empty()
            ? "empty"
            : (GuestPath->front() == '/' ? "absolute" : "relative");
          if (IsSafeDiagnosticGuestPath(*GuestPath)) {
            UnsupportedFAccessAt2DiagnosticPath = *GuestPath;
          }
          const auto HostPath = ResolveGuestPathWithParents(*GuestPath);
          UnsupportedFAccessAt2HostPathResolved = HostPath.has_value();
          if (HostPath.has_value()) {
            struct stat TargetStat {};
            UnsupportedFAccessAt2TargetExists = lstat(HostPath->c_str(), &TargetStat) == 0;
          }
        } else {
          UnsupportedFAccessAt2PathClass = "unreadable";
        }
      }
      if (Number == MemfdCreateSyscall) {
        UnsupportedMemfdCreateBoundarySeen = true;
        const auto GuestName = ReadGuestPath(Arguments->Argument[1]);
        UnsupportedMemfdCreateFlags = Arguments->Argument[2];
        UnsupportedMemfdCreateNameReadable = GuestName.has_value();
        if (GuestName.has_value()) {
          UnsupportedMemfdCreateNameLength = GuestName->size();
          UnsupportedMemfdCreateNameFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestName->data()),
            GuestName->size());
          if (*GuestName == "wine-mapping") {
            UnsupportedMemfdCreateDiagnosticName = *GuestName;
          }
        }
      }
      if (Number == PWrite64Syscall) {
        UnsupportedPWrite64BoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestBuffer = Arguments->Argument[2];
        const uint64_t ByteCount = Arguments->Argument[3];
        UnsupportedPWrite64Descriptor = Descriptor;
        UnsupportedPWrite64DescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedPWrite64DescriptorMatchesMemfd = Descriptor == MemfdCreateLastDescriptor;
        UnsupportedPWrite64ByteCount = ByteCount;
        UnsupportedPWrite64Offset = Arguments->Argument[4];
        if (GuestBuffer == 0) {
          UnsupportedPWrite64BufferClass = "zero";
        } else if (ByteCount <= 4096 && Contains(GuestBuffer, ByteCount)) {
          UnsupportedPWrite64BufferClass = "guest-memory";
          UnsupportedPWrite64BufferReadable = true;
          UnsupportedPWrite64BufferFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestBuffer),
            static_cast<size_t>(ByteCount));
          if (ByteCount != 0) {
            UnsupportedPWrite64FirstByte = *reinterpret_cast<const uint8_t*>(GuestBuffer);
          }
        } else {
          UnsupportedPWrite64BufferClass = "scalar-or-outside";
        }
      }
      if (Number == FTruncateSyscall) {
        UnsupportedFTruncateBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        UnsupportedFTruncateDescriptor = Descriptor;
        UnsupportedFTruncateDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedFTruncateDescriptorMatchesMemfd = Descriptor == MemfdCreateLastDescriptor;
        UnsupportedFTruncateLength = Arguments->Argument[2];
      }
      if (Number == FChdirSyscall) {
        UnsupportedFChdirBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        UnsupportedFChdirDescriptor = Descriptor;
        UnsupportedFChdirDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        struct stat DescriptorStat {};
        if (fstat(Descriptor, &DescriptorStat) == 0) {
          UnsupportedFChdirDescriptorStatSucceeded = true;
          UnsupportedFChdirDescriptorDirectory = S_ISDIR(DescriptorStat.st_mode);
        }
        std::array<char, 4096> DescriptorPath {};
        if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) == 0) {
          const std::string HostPath {DescriptorPath.data()};
          UnsupportedFChdirDescriptorPathReadable = true;
          UnsupportedFChdirDescriptorPathLength = HostPath.size();
          UnsupportedFChdirDescriptorPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(HostPath.data()),
            HostPath.size());
          UnsupportedFChdirDescriptorPathConfined = HostPath == RootFS
            || HostPath.starts_with(RootFS + '/');
        }
      }
      if (Number == CloneSyscall) {
        UnsupportedCloneBoundarySeen = true;
        const uint64_t Flags = Arguments->Argument[1];
        const auto ClassifyPointer = [this](uint64_t Address, uint64_t Size, bool AllowEnd) {
          if (Address == 0) return std::string {"zero"};
          if (Size != 0 && Contains(Address, Size)) return std::string {"guest-memory"};
          if (AllowEnd && Contains(Address - 1, 1)) return std::string {"guest-memory-end"};
          if (Size != 0 && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
              && LowGuestShadow->ContainsLogicalRange(Address, Size)) {
            return std::string {"low-shadow"};
          }
          if (AllowEnd && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
              && LowGuestShadow->ContainsLogicalRange(Address - 1, 1)) {
            return std::string {"low-shadow-end"};
          }
          return std::string {"scalar-or-outside"};
        };
        UnsupportedCloneFlags = Flags;
        UnsupportedCloneExitSignal = Flags & 0xff;
        UnsupportedCloneChildStackClass = ClassifyPointer(Arguments->Argument[2], 1, true);
        UnsupportedCloneParentTIDClass = ClassifyPointer(
          Arguments->Argument[3], sizeof(uint32_t), false);
        UnsupportedCloneChildTIDClass = ClassifyPointer(
          Arguments->Argument[4], sizeof(uint32_t), false);
        UnsupportedCloneTLSClass = ClassifyPointer(
          Arguments->Argument[5], sizeof(uint64_t), false);
      }
      if (Number == Wait4Syscall) {
        UnsupportedWait4BoundarySeen = true;
        UnsupportedWait4ProcessID = static_cast<int64_t>(Arguments->Argument[1]);
        UnsupportedWait4Options = Arguments->Argument[3];
        const uint64_t GuestStatus = Arguments->Argument[2];
        const uint64_t GuestResourceUsage = Arguments->Argument[4];
        UnsupportedWait4StatusClass = GuestStatus == 0
          ? "zero"
          : (Contains(GuestStatus, sizeof(int32_t))
              ? "guest-memory"
              : "scalar-or-outside");
        UnsupportedWait4ResourceUsageClass = GuestResourceUsage == 0
          ? "zero"
          : (Contains(GuestResourceUsage, 1)
              ? "guest-memory"
              : "scalar-or-outside");
      }
      if (Number == FcntlSyscall) {
        UnsupportedFcntlBoundarySeen = true;
        const int Descriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t Argument = Arguments->Argument[3];
        UnsupportedFcntlDescriptor = Descriptor;
        UnsupportedFcntlCommand = static_cast<int64_t>(Arguments->Argument[2]);
        UnsupportedFcntlDescriptorOwned = OwnedDescriptors.contains(Descriptor);
        UnsupportedFcntlDescriptorStandard = Descriptor >= STDIN_FILENO
          && Descriptor <= STDERR_FILENO;
        UnsupportedFcntlDescriptorClosed = UnsupportedFcntlDescriptorStandard
          && ClosedStandardDescriptors.contains(Descriptor);
        UnsupportedFcntlArgumentClass = Argument == 0
          ? "zero"
          : (Contains(Argument, 1) ? "guest-memory" : "scalar-or-outside");
        constexpr int64_t LinuxFSetLK = 6;
        if (UnsupportedFcntlCommand == LinuxFSetLK
            && Contains(Argument, sizeof(LinuxFlock64))) {
          LinuxFlock64 GuestLock {};
          std::memcpy(
            &GuestLock,
            reinterpret_cast<const void*>(Argument),
            sizeof(GuestLock));
          UnsupportedFcntlFlockReadable = true;
          UnsupportedFcntlFlockType = GuestLock.Type;
          UnsupportedFcntlFlockWhence = GuestLock.Whence;
          UnsupportedFcntlFlockStart = GuestLock.Start;
          UnsupportedFcntlFlockLength = GuestLock.Length;
          UnsupportedFcntlFlockProcessID = GuestLock.ProcessID;
        }
      }
      if (Number == UnlinkSyscall) {
        UnsupportedUnlinkBoundarySeen = true;
        const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
        UnsupportedUnlinkPathReadable = GuestPath.has_value();
        if (GuestPath.has_value()) {
          UnsupportedUnlinkPathLength = GuestPath->size();
          UnsupportedUnlinkPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          TraceGuestPath("unlink", *GuestPath);
          UnsupportedUnlinkPathClass = GuestPath->empty()
            ? "empty"
            : (GuestPath->front() == '/' ? "absolute" : "relative");
          const auto HostPath = ResolveGuestCreationPath(*GuestPath);
          UnsupportedUnlinkHostPathResolved = HostPath.has_value();
          if (HostPath.has_value()) {
            struct stat TargetStat {};
            if (lstat(HostPath->c_str(), &TargetStat) == 0) {
              UnsupportedUnlinkTargetExists = true;
              UnsupportedUnlinkTargetSocket = S_ISSOCK(TargetStat.st_mode);
              UnsupportedUnlinkTargetRegular = S_ISREG(TargetStat.st_mode);
              UnsupportedUnlinkTargetDirectory = S_ISDIR(TargetStat.st_mode);
              UnsupportedUnlinkTargetSymlink = S_ISLNK(TargetStat.st_mode);
            }
          }
        } else {
          UnsupportedUnlinkPathClass = "unreadable";
        }
      }
      if (Number == ChmodSyscall) {
        UnsupportedChmodBoundarySeen = true;
        const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
        UnsupportedChmodMode = Arguments->Argument[2];
        UnsupportedChmodPathReadable = GuestPath.has_value();
        if (GuestPath.has_value()) {
          UnsupportedChmodPathLength = GuestPath->size();
          UnsupportedChmodPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          TraceGuestPath("chmod", *GuestPath);
          UnsupportedChmodPathClass = GuestPath->empty()
            ? "empty"
            : (GuestPath->front() == '/' ? "absolute" : "relative");
          const auto HostPath = ResolveGuestCreationPath(*GuestPath);
          UnsupportedChmodHostPathResolved = HostPath.has_value();
          if (HostPath.has_value()) {
            struct stat TargetStat {};
            if (lstat(HostPath->c_str(), &TargetStat) == 0) {
              UnsupportedChmodTargetExists = true;
              UnsupportedChmodTargetSocket = S_ISSOCK(TargetStat.st_mode);
              UnsupportedChmodCurrentMode = TargetStat.st_mode & 07777;
            }
          }
        } else {
          UnsupportedChmodPathClass = "unreadable";
        }
      }
      if (Number == OpenSyscall) {
        UnsupportedOpenBoundarySeen = true;
        UnsupportedOpenFlags = Arguments->Argument[2];
        UnsupportedOpenMode = Arguments->Argument[3];
        const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
        UnsupportedOpenPathReadable = GuestPath.has_value();
        if (GuestPath.has_value()) {
          UnsupportedOpenPathLength = GuestPath->size();
          UnsupportedOpenPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          TraceGuestPath("open", *GuestPath);
          if (GuestPath->empty()) {
            UnsupportedOpenPathClass = "empty";
          } else if (GuestPath->front() == '/') {
            UnsupportedOpenPathClass = "absolute";
            const auto HostPath = ResolveGuestPath(*GuestPath);
            if (HostPath.has_value()) {
              struct stat TargetStat {};
              UnsupportedOpenTargetExists = lstat(HostPath->c_str(), &TargetStat) == 0
                && S_ISREG(TargetStat.st_mode);
            }
          } else {
            UnsupportedOpenPathClass = "relative";
          }
        } else {
          UnsupportedOpenPathClass = "unreadable";
        }
      }
      if (Number == PrctlSyscall) {
        UnsupportedPrctlBoundarySeen = true;
        UnsupportedPrctlOption = static_cast<int64_t>(Arguments->Argument[1]);
        const uint64_t Argument2 = Arguments->Argument[2];
        if (Argument2 == 0) {
          UnsupportedPrctlArgument2Class = "zero";
        } else if (Contains(Argument2, 1)) {
          UnsupportedPrctlArgument2Class = "guest-memory";
          constexpr size_t LinuxTaskNameSize = 16;
          const size_t Available = static_cast<size_t>(GuestBase + GuestSize - Argument2);
          const size_t Limit = std::min(Available, LinuxTaskNameSize);
          const auto* Begin = reinterpret_cast<const uint8_t*>(Argument2);
          const auto* Terminator = static_cast<const uint8_t*>(
            std::memchr(Begin, '\0', Limit));
          UnsupportedPrctlArgument2StringLength = Terminator == nullptr
            ? Limit
            : static_cast<size_t>(Terminator - Begin);
          UnsupportedPrctlArgument2StringTerminated = Terminator != nullptr;
          UnsupportedPrctlArgument2StringFingerprint = FingerprintBytes(
            Begin,
            UnsupportedPrctlArgument2StringLength);
        } else {
          UnsupportedPrctlArgument2Class = "scalar";
        }
      }
      if (Number == UserfaultfdSyscall) {
        UnsupportedUserfaultfdBoundarySeen = true;
        UnsupportedUserfaultfdFlags = Arguments->Argument[1];
      }
      if (Number == Clone3Syscall) {
        UnsupportedClone3BoundarySeen = true;
        const uint64_t GuestCloneArgs = Arguments->Argument[1];
        const uint64_t CloneArgsSize = Arguments->Argument[2];
        UnsupportedClone3Size = CloneArgsSize;
        const auto ClassifyPointer = [this](uint64_t Address, uint64_t Size) {
          if (Address == 0) return std::string {"zero"};
          if (Size != 0 && Contains(Address, Size)) return std::string {"guest-memory"};
          if (Size != 0 && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
              && LowGuestShadow->ContainsLogicalRange(Address, Size)) {
            return std::string {"low-shadow"};
          }
          return std::string {"scalar-or-outside"};
        };
        const uint64_t CopySize = std::min<uint64_t>(CloneArgsSize, sizeof(LinuxClone3Args));
        UnsupportedClone3ArgumentClass = ClassifyPointer(GuestCloneArgs, CopySize);
        if (CopySize >= 64 && Contains(GuestCloneArgs, CopySize)) {
          LinuxClone3Args GuestArgs {};
          std::memcpy(&GuestArgs, reinterpret_cast<const void*>(GuestCloneArgs), CopySize);
          UnsupportedClone3StructureReadable = true;
          UnsupportedClone3CopiedSize = CopySize;
          UnsupportedClone3Flags = GuestArgs.Flags;
          UnsupportedClone3ExitSignal = GuestArgs.ExitSignal;
          UnsupportedClone3StackSize = GuestArgs.StackSize;
          UnsupportedClone3SetTIDSize = GuestArgs.SetTIDSize;
          UnsupportedClone3CGroup = GuestArgs.CGroup;
          UnsupportedClone3PIDFDClass = ClassifyPointer(GuestArgs.PIDFD, sizeof(uint32_t));
          UnsupportedClone3ChildTIDClass = ClassifyPointer(GuestArgs.ChildTID, sizeof(uint32_t));
          UnsupportedClone3ParentTIDClass = ClassifyPointer(GuestArgs.ParentTID, sizeof(uint32_t));
          UnsupportedClone3StackClass = ClassifyPointer(GuestArgs.Stack, GuestArgs.StackSize);
          UnsupportedClone3TLSClass = ClassifyPointer(GuestArgs.TLS, sizeof(uint64_t));
          UnsupportedClone3SetTIDClass = ClassifyPointer(
            GuestArgs.SetTID,
            GuestArgs.SetTIDSize > std::numeric_limits<uint64_t>::max() / sizeof(uint32_t)
              ? 0
              : GuestArgs.SetTIDSize * sizeof(uint32_t));
        }
      }
      if (Number == RtSigactionSyscall) {
        UnsupportedRtSigactionBoundarySeen = true;
        UnsupportedRtSigactionSignal = static_cast<int64_t>(Arguments->Argument[1]);
        const uint64_t GuestAction = Arguments->Argument[2];
        const uint64_t GuestOldAction = Arguments->Argument[3];
        UnsupportedRtSigactionSigsetSize = Arguments->Argument[4];
        const auto ClassifyPointer = [this](uint64_t Address, uint64_t Size) {
          if (Address == 0) return std::string {"zero"};
          if (Address == 1) return std::string {"signal-ignore"};
          if (Size != 0 && Contains(Address, Size)) return std::string {"guest-memory"};
          if (Size != 0 && LowMemoryBiasModeEnabled && LowGuestShadow != nullptr
              && LowGuestShadow->ContainsLogicalRange(Address, Size)) {
            return std::string {"low-shadow"};
          }
          return std::string {"scalar-or-outside"};
        };
        UnsupportedRtSigactionActionClass = ClassifyPointer(
          GuestAction,
          sizeof(LinuxGuestSigAction));
        UnsupportedRtSigactionOldActionClass = ClassifyPointer(
          GuestOldAction,
          sizeof(LinuxGuestSigAction));
        if (GuestAction != 0 && Contains(GuestAction, sizeof(LinuxGuestSigAction))) {
          LinuxGuestSigAction Action {};
          std::memcpy(&Action, reinterpret_cast<const void*>(GuestAction), sizeof(Action));
          UnsupportedRtSigactionActionReadable = true;
          UnsupportedRtSigactionHandlerClass = ClassifyPointer(Action.Handler, 1);
          UnsupportedRtSigactionFlags = Action.Flags;
          UnsupportedRtSigactionRestorerClass = ClassifyPointer(Action.Restorer, 1);
          UnsupportedRtSigactionMaskFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(&Action.Mask),
            sizeof(Action.Mask));
          UnsupportedRtSigactionActionFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(&Action),
            sizeof(Action));
        }
      }
      if (Number == RtSigprocmaskSyscall) {
        UnsupportedRtSigprocmaskBoundarySeen = true;
        UnsupportedRtSigprocmaskHow = static_cast<int64_t>(Arguments->Argument[1]);
        const uint64_t GuestSet = Arguments->Argument[2];
        const uint64_t GuestOldSet = Arguments->Argument[3];
        UnsupportedRtSigprocmaskSigsetSize = Arguments->Argument[4];
        const auto ClassifyPointer = [this](uint64_t Address, uint64_t Size) {
          if (Address == 0) return std::string {"zero"};
          if (Size != 0 && Contains(Address, Size)) return std::string {"guest-memory"};
          return std::string {"scalar-or-outside"};
        };
        UnsupportedRtSigprocmaskSetClass = ClassifyPointer(
          GuestSet,
          UnsupportedRtSigprocmaskSigsetSize);
        UnsupportedRtSigprocmaskOldSetClass = ClassifyPointer(
          GuestOldSet,
          UnsupportedRtSigprocmaskSigsetSize);
        if (GuestSet != 0 && UnsupportedRtSigprocmaskSigsetSize != 0
            && Contains(GuestSet, UnsupportedRtSigprocmaskSigsetSize)) {
          UnsupportedRtSigprocmaskSetFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestSet),
            static_cast<size_t>(UnsupportedRtSigprocmaskSigsetSize));
        }
      }
      if (Number == ExecveSyscall) {
        UnsupportedExecveBoundarySeen = true;
        const auto GuestTarget = ReadGuestPath(Arguments->Argument[1]);
        if (GuestTarget.has_value()) {
          UnsupportedExecvePathLength = GuestTarget->size();
          UnsupportedExecvePathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestTarget->data()),
            GuestTarget->size());
          TraceGuestPath("execve", *GuestTarget);
          const size_t Separator = GuestTarget->find_last_of('/');
          const std::string_view Basename = Separator == std::string::npos
            ? std::string_view {*GuestTarget}
            : std::string_view {*GuestTarget}.substr(Separator + 1);
          if (Basename == "wineserver") {
            UnsupportedExecveTargetKind = "proton-wineserver";
          } else if (Basename == "wine-preloader" || Basename == "wine64-preloader") {
            UnsupportedExecveTargetKind = "proton-wine-preloader";
          } else if (Basename == "wine" || Basename == "wine64") {
            UnsupportedExecveTargetKind = "proton-wine-loader";
          } else if (!GuestTarget->empty() && GuestTarget->front() == '/') {
            UnsupportedExecveTargetKind = "absolute-other";
          } else {
            UnsupportedExecveTargetKind = "relative-other";
          }
          UnsupportedExecveParentSegmentSeen = GuestTarget->find("/../") != std::string::npos
            || GuestTarget->ends_with("/..");
          if (!GuestTarget->empty() && GuestTarget->front() == '/') {
            const auto NormalizedGuestTarget = NormalizeGuestPathWithParents(*GuestTarget);
            UnsupportedExecveNormalizedPathConfined = NormalizedGuestTarget.has_value();
            if (NormalizedGuestTarget.has_value()) {
              UnsupportedExecveNormalizedPathLength = NormalizedGuestTarget->size();
              UnsupportedExecveNormalizedPathFingerprint = FingerprintBytes(
                reinterpret_cast<const uint8_t*>(NormalizedGuestTarget->data()),
                NormalizedGuestTarget->size());
            }
            const auto HostTarget = ResolveGuestPathWithParents(*GuestTarget);
            if (HostTarget.has_value()) {
              struct stat TargetStat {};
              UnsupportedExecveTargetExists = lstat(HostTarget->c_str(), &TargetStat) == 0
                && S_ISREG(TargetStat.st_mode);
            }
          }
        }

        const uint64_t GuestArgv = Arguments->Argument[2];
        constexpr uint64_t MaximumArguments = 32;
        UnsupportedExecveArgvReadable = Contains(GuestArgv, sizeof(uint64_t));
        if (UnsupportedExecveArgvReadable) {
          for (uint64_t Index = 0; Index <= MaximumArguments; ++Index) {
            const uint64_t PointerAddress = GuestArgv + Index * sizeof(uint64_t);
            if (!Contains(PointerAddress, sizeof(uint64_t))) {
              UnsupportedExecveArgvReadable = false;
              break;
            }
            uint64_t ArgumentAddress {};
            std::memcpy(
              &ArgumentAddress,
              reinterpret_cast<const void*>(PointerAddress),
              sizeof(ArgumentAddress));
            if (ArgumentAddress == 0) {
              UnsupportedExecveArgvTerminated = true;
              break;
            }
            const auto GuestArgument = ReadGuestPath(ArgumentAddress);
            if (!GuestArgument.has_value()) {
              UnsupportedExecveArgvReadable = false;
              break;
            }
            UnsupportedExecveArgLengths.push_back(GuestArgument->size());
            UnsupportedExecveArgFingerprints.push_back(FingerprintBytes(
              reinterpret_cast<const uint8_t*>(GuestArgument->data()),
              GuestArgument->size()));
            UnsupportedExecveArgKinds.push_back(ClassifyExecveArgument(Index, *GuestArgument));
            TraceExecveArgument(Index, *GuestArgument);
            ++UnsupportedExecveArgCount;
          }
        }

        const uint64_t GuestEnvp = Arguments->Argument[3];
        constexpr uint64_t MaximumEnvironmentEntries = 64;
        UnsupportedExecveEnvpReadable = Contains(GuestEnvp, sizeof(uint64_t));
        if (UnsupportedExecveEnvpReadable) {
          for (uint64_t Index = 0; Index <= MaximumEnvironmentEntries; ++Index) {
            const uint64_t PointerAddress = GuestEnvp + Index * sizeof(uint64_t);
            if (!Contains(PointerAddress, sizeof(uint64_t))) {
              UnsupportedExecveEnvpReadable = false;
              break;
            }
            uint64_t EnvironmentAddress {};
            std::memcpy(
              &EnvironmentAddress,
              reinterpret_cast<const void*>(PointerAddress),
              sizeof(EnvironmentAddress));
            if (EnvironmentAddress == 0) {
              UnsupportedExecveEnvpTerminated = true;
              break;
            }
            const auto EnvironmentEntry = ReadGuestPath(EnvironmentAddress);
            if (!EnvironmentEntry.has_value()) {
              UnsupportedExecveEnvpReadable = false;
              break;
            }
            ++UnsupportedExecveEnvCount;
            if (*EnvironmentEntry == "LC_ALL=C") {
              UnsupportedExecveEnvHasLCAllC = true;
            } else if (*EnvironmentEntry == "HOME=/home/regression") {
              UnsupportedExecveEnvHasPrivateHome = true;
            } else if (*EnvironmentEntry == "WINELOADERNOEXEC=1") {
              UnsupportedExecveEnvHasWineLoaderNoExec = true;
            } else if (*EnvironmentEntry == "WINEARCH=wow64") {
              UnsupportedExecveEnvHasWineArchWow64 = true;
            } else {
              ++UnsupportedExecveEnvUnknownCount;
            }
          }
        }
      }
      if (Number == ChdirSyscall) {
        UnsupportedChdirBoundarySeen = true;
        const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
        if (GuestPath.has_value()) {
          UnsupportedChdirPathLength = GuestPath->size();
          UnsupportedChdirPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          UnsupportedChdirPathClass = GuestPath->empty()
            ? "empty"
            : (GuestPath->front() == '/' ? "absolute" : "relative");
          TraceGuestPath("chdir", *GuestPath);
          const auto HostPath = ResolveGuestPath(*GuestPath);
          if (HostPath.has_value()) {
            struct stat TargetStat {};
            UnsupportedChdirTargetExists = lstat(HostPath->c_str(), &TargetStat) == 0;
            UnsupportedChdirTargetDirectory = UnsupportedChdirTargetExists
              && S_ISDIR(TargetStat.st_mode);
          }
        }
      }
      if (Number == MkdirSyscall) {
        UnsupportedMkdirBoundarySeen = true;
        UnsupportedMkdirMode = Arguments->Argument[2];
        const auto GuestPath = ReadGuestPath(Arguments->Argument[1]);
        UnsupportedMkdirPathReadable = GuestPath.has_value();
        if (GuestPath.has_value()) {
          UnsupportedMkdirPathLength = GuestPath->size();
          UnsupportedMkdirPathFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestPath->data()),
            GuestPath->size());
          UnsupportedMkdirPathClass = GuestPath->empty()
            ? "empty"
            : (GuestPath->front() == '/' ? "absolute" : "relative");
          TraceGuestPath("mkdir", *GuestPath);

          const size_t Separator = GuestPath->find_last_of('/');
          const std::string ParentGuestPath = Separator == std::string::npos
            ? "."
            : (Separator == 0 ? "/" : GuestPath->substr(0, Separator));
          const std::string Basename = Separator == std::string::npos
            ? *GuestPath
            : GuestPath->substr(Separator + 1);
          if (!Basename.empty() && Basename != "." && Basename != "..") {
            const auto HostParent = ResolveGuestPath(ParentGuestPath);
            if (HostParent.has_value()) {
              UnsupportedMkdirParentConfined = true;
              struct stat ParentStat {};
              UnsupportedMkdirParentExists = lstat(HostParent->c_str(), &ParentStat) == 0;
              UnsupportedMkdirParentDirectory = UnsupportedMkdirParentExists
                && S_ISDIR(ParentStat.st_mode);
              const std::string HostTarget = *HostParent
                + (*HostParent == "/" ? "" : "/") + Basename;
              struct stat TargetStat {};
              UnsupportedMkdirTargetExists = lstat(HostTarget.c_str(), &TargetStat) == 0;
              UnsupportedMkdirTargetDirectory = UnsupportedMkdirTargetExists
                && S_ISDIR(TargetStat.st_mode);
            }
          }
        } else {
          UnsupportedMkdirPathClass = "unreadable";
        }
      }
      if (Number == SymlinkSyscall) {
        UnsupportedSymlinkBoundarySeen = true;
        const auto GuestTarget = ReadGuestPath(Arguments->Argument[1]);
        const auto GuestLink = ReadGuestPath(Arguments->Argument[2]);
        UnsupportedSymlinkTargetReadable = GuestTarget.has_value();
        UnsupportedSymlinkLinkReadable = GuestLink.has_value();
        if (GuestTarget.has_value()) {
          UnsupportedSymlinkTargetLength = GuestTarget->size();
          UnsupportedSymlinkTargetFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestTarget->data()),
            GuestTarget->size());
          UnsupportedSymlinkTargetClass = GuestTarget->empty()
            ? "empty"
            : (GuestTarget->front() == '/' ? "absolute" : "relative");
          TraceGuestPath("symlink-target", *GuestTarget);
        } else {
          UnsupportedSymlinkTargetClass = "unreadable";
        }
        if (GuestLink.has_value()) {
          UnsupportedSymlinkLinkLength = GuestLink->size();
          UnsupportedSymlinkLinkFingerprint = FingerprintBytes(
            reinterpret_cast<const uint8_t*>(GuestLink->data()),
            GuestLink->size());
          UnsupportedSymlinkLinkClass = GuestLink->empty()
            ? "empty"
            : (GuestLink->front() == '/' ? "absolute" : "relative");
          TraceGuestPath("symlink-link", *GuestLink);
          const auto HostLink = ResolveGuestCreationPath(*GuestLink);
          if (HostLink.has_value()) {
            UnsupportedSymlinkLinkParentConfined = true;
            const size_t Separator = HostLink->find_last_of('/');
            const std::string HostParent = Separator == 0
              ? "/"
              : HostLink->substr(0, Separator);
            struct stat ParentStat {};
            UnsupportedSymlinkLinkParentExists = lstat(HostParent.c_str(), &ParentStat) == 0;
            UnsupportedSymlinkLinkParentDirectory = UnsupportedSymlinkLinkParentExists
              && S_ISDIR(ParentStat.st_mode);
            struct stat LinkStat {};
            UnsupportedSymlinkLinkExists = lstat(HostLink->c_str(), &LinkStat) == 0;
          }
        } else {
          UnsupportedSymlinkLinkClass = "unreadable";
        }
      }
    }
    Stop(Frame);
    if (PostSessionSyscallDiagnosticLimit != 0) {
      ++UnsupportedDiagnosticStopSignalRequestCount;
      if (DarwinDiagnosticThreadStopHandler::Request() != 0) {
        UnsupportedDiagnosticStopSignalLastHostError = errno;
      }
    }
    return static_cast<uint64_t>(-ENOSYS);
  }

  FEXCore::HLE::ExecutableRangeInfo
  QueryGuestExecutableRange(
    FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    ++ExecutableRangeQueryCount;
    const bool LowShadowExecutable = LowGuestShadow != nullptr
      && LowGuestShadow->ContainsMappedLogicalRange(Address, 1, PROT_EXEC);
    const bool LowShadowHostAddress = LowGuestShadow != nullptr
      && LowGuestShadow->ContainsHostAddress(Address);
    const uint64_t LowShadowHostLogicalAddress = LowShadowHostAddress
      ? LowGuestShadow->LogicalAddress(Address)
      : std::numeric_limits<uint64_t>::max();
    const bool LowShadowHostExecutable = LowShadowHostAddress
      && LowShadowHostLogicalAddress != std::numeric_limits<uint64_t>::max()
      && LowGuestShadow->ContainsMappedLogicalRange(
        LowShadowHostLogicalAddress, 1, PROT_EXEC);
    if (ExecutableRangeQueryCount <= 16) {
      const uint8_t LowState = LowGuestShadow != nullptr
        ? LowGuestShadow->PageStateForLogicalAddress(Address)
        : 0;
      const uint8_t LowHostState = LowShadowHostLogicalAddress
          != std::numeric_limits<uint64_t>::max()
        ? LowGuestShadow->PageStateForLogicalAddress(LowShadowHostLogicalAddress)
        : 0;
      std::fprintf(
        stderr,
        "REGRESSION_EXECUTABLE_RANGE_QUERY count=%llu address=0x%llx "
        "guest_base=0x%llx guest_size=0x%llx low_state=0x%x low_exec=%d "
        "low_host=%d low_host_logical=0x%llx low_host_state=0x%x "
        "low_host_exec=%d\n",
        static_cast<unsigned long long>(ExecutableRangeQueryCount),
        static_cast<unsigned long long>(Address),
        static_cast<unsigned long long>(GuestBase),
        static_cast<unsigned long long>(GuestSize),
        static_cast<unsigned int>(LowState),
        LowShadowExecutable ? 1 : 0,
        LowShadowHostAddress ? 1 : 0,
        static_cast<unsigned long long>(LowShadowHostLogicalAddress),
        static_cast<unsigned int>(LowHostState),
        LowShadowHostExecutable ? 1 : 0);
    }
    if (LowShadowHostExecutable) {
      const uint64_t HostPageBase = Address & ~(LinuxGuestPageSize - 1);
      const bool Writable = LowGuestShadow->ContainsMappedLogicalRange(
        LowShadowHostLogicalAddress, 1, PROT_WRITE);
      return {HostPageBase, LinuxGuestPageSize, Writable};
    }
    if (LowShadowExecutable) {
      const uint64_t PageBase = Address & ~(LinuxGuestPageSize - 1);
      const bool Writable = LowGuestShadow->ContainsMappedLogicalRange(
        Address, 1, PROT_WRITE);
      return {PageBase, LinuxGuestPageSize, Writable};
    }
    return {GuestBase, GuestSize, false};
  }

  std::optional<FEXCore::ExecutableFileSectionInfo>
  LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t) override {
    return std::nullopt;
  }

  bool WriteSeen {};
  bool ExitSeen {};
  bool ExitGroupSeen {};
  uint64_t ExitGuestRIP {};
  uint64_t ExitGuestRSP {};
  uint64_t ExitGuestRBP {};
  std::string ExitGuestRIPClass {"none"};
  std::array<uint64_t, 8> ExitGuestStackWords {};
  size_t ExitGuestStackWordCount {};
  std::array<uint64_t, 8> ExitGuestFramePointers {};
  std::array<uint64_t, 8> ExitGuestFrameReturnAddresses {};
  size_t ExitGuestFrameCount {};
  bool BrkSeen {};
  bool AccessSeen {};
  bool OpenSeen {};
  bool OpenAtSeen {};
  bool NewFStatAtSeen {};
  bool ReadSeen {};
  bool GetDents64Seen {};
  bool PRead64Seen {};
  bool FStatSeen {};
  bool FcntlSeen {};
  bool SetSockOptSeen {};
  bool SigAltStackSeen {};
  bool StatSeen {};
  bool MMapSeen {};
  bool MUnmapSeen {};
  bool CloseSeen {};
  bool PrctlSeen {};
  bool UserfaultfdSeen {};
  bool RtSigprocmaskSeen {};
  bool ArchPrctlSeen {};
  bool SetTIDAddressSeen {};
  bool SetRobustListSeen {};
  bool RSeqSeen {};
  bool MProtectSeen {};
  bool Prlimit64Seen {};
  bool ClockGettimeSeen {};
  bool PostSessionSyscallDiagnosticLimitSeen {};
  bool ClockNanosleepSeen {};
  bool GetrandomSeen {};
  bool UnameSeen {};
  bool GetcwdSeen {};
  bool ChdirSeen {};
  bool MkdirSeen {};
  bool RenameSeen {};
  bool UnlinkSeen {};
  bool ChmodSeen {};
  bool SymlinkSeen {};
  bool ReadlinkSeen {};
  bool GetUIDSeen {};
  bool GetPIDSeen {};
  bool GetTIDSeen {};
  bool SetPrioritySeen {};
  bool PollSeen {};
  bool Pipe2Seen {};
  bool SocketSeen {};
  bool SocketPairSeen {};
  bool ShutdownSeen {};
  bool BindSeen {};
  bool ListenSeen {};
  bool FutexWaitVSeen {};
  bool EpollCreateSeen {};
  bool EpollCtlSeen {};
  bool EpollPWait2Seen {};
  bool EpollWaitSeen {};
  bool GettimeofdaySeen {};
  bool SysinfoSeen {};
  bool TimeSeen {};
  bool FStatFSSeen {};
  bool FAccessAt2Seen {};
  bool MemfdCreateSeen {};
  bool PWrite64Seen {};
  bool FTruncateSeen {};
  bool FChdirSeen {};
  bool ConnectSeen {};
  bool GetSockOptSeen {};
  bool SendMsgSeen {};
  bool RecvMsgSeen {};
  bool WriteVSeen {};
  uint64_t BrkCallCount {};
  uint64_t AccessCallCount {};
  uint64_t OpenCallCount {};
  uint64_t OpenSuccessCount {};
  uint64_t OpenLastFlags {};
  uint64_t OpenLastMode {};
  uint64_t OpenLastPathLength {};
  uint64_t OpenLastPathFingerprint {};
  int64_t OpenLastLinuxError {};
  std::string OpenLastPathClass {"none"};
  uint64_t OpenAtCallCount {};
  uint64_t OpenAtSuccessCount {};
  int64_t OpenAtLastDirectoryDescriptor {};
  uint64_t OpenAtLastFlags {};
  uint64_t OpenAtLastMode {};
  uint64_t OpenAtLastPathLength {};
  uint64_t OpenAtLastPathFingerprint {};
  bool OpenAtLastHostPathResolved {};
  bool OpenAtLastTargetExists {};
  bool OpenAtLastTargetDirectory {};
  bool OpenAtLastTargetRegular {};
  int64_t OpenAtLastLinuxError {};
  std::string OpenAtLastPathClass {"none"};
  std::string OpenAtLastFailureReason {"none"};
  uint64_t RegistryTemporaryOpenSuccessCount {};
  int64_t RegistryTemporaryLastDescriptor {-1};
  bool RegistryTemporaryTraceActive {};
  uint64_t RegistryTemporaryTraceTriggerOpenAtCallCount {};
  std::array<RegistryTemporarySyscallTraceEntry, 32> RegistryTemporarySyscallTrace {};
  size_t RegistryTemporarySyscallTraceCount {};
  uint64_t IntlNLSOpenCandidateCount {};
  std::vector<std::string> IntlNLSOpenCandidatePaths {};
  std::string IntlNLSLastOperation {"none"};
  bool IntlNLSLastHostPathResolved {};
  bool IntlNLSLastTargetExists {};
  bool IntlNLSLastTargetRegular {};
  int64_t IntlNLSLastLinuxError {};
  int64_t IntlNLSLastDescriptor {-1};
  uint64_t TemporaryMappingOpenCandidateCount {};
  std::string TemporaryMappingFirstCandidatePath {"none"};
  std::string TemporaryMappingLastCandidatePath {"none"};
  uint64_t TemporaryMappingExclusiveCreateSuccessCount {};
  int64_t TemporaryMappingExclusiveCreateLastDescriptor {-1};
  int64_t TemporaryMappingExclusiveCreateLastLinuxError {};
  uint64_t NewFStatAtCallCount {};
  uint64_t NewFStatAtSuccessCount {};
  uint64_t NewFStatAtFailureCount {};
  uint64_t NewFStatAtRelativePathCallCount {};
  uint64_t NewFStatAtRelativePathSuccessCount {};
  int64_t NewFStatAtLastDirectoryDescriptor {};
  uint64_t NewFStatAtLastFlags {};
  uint64_t NewFStatAtLastPathLength {};
  uint64_t NewFStatAtLastPathFingerprint {};
  bool NewFStatAtLastHostPathResolved {};
  bool NewFStatAtLastTargetExists {};
  bool NewFStatAtLastTargetDirectory {};
  bool NewFStatAtLastTargetRegular {};
  int64_t NewFStatAtLastLinuxError {};
  std::string NewFStatAtLastPathClass {"none"};
  std::string NewFStatAtLastFailureReason {"none"};
  uint64_t ReadCallCount {};
  uint64_t ReadByteCount {};
  int64_t ReadLastDescriptor {-1};
  uint64_t ReadLastBuffer {};
  uint64_t ReadLastCount {};
  bool ReadLastDescriptorOwned {};
  bool ReadLastDescriptorReceivedSCMRights {};
  bool ReadLastDescriptorStatSucceeded {};
  bool ReadLastDescriptorFIFO {};
  bool ReadLastDescriptorSocket {};
  bool ReadLastDescriptorRegular {};
  std::string ReadLastBufferClass {"none"};
  std::array<ReadELFHeaderRecord, 4> ReadELFHeaderRecords {};
  size_t ReadELFHeaderRecordCount {};
  bool ReadELFHeaderRecordOverflow {};
  bool ReadWineFixedReplySeen {};
  uint64_t ReadWineFixedReplyCount {};
  int64_t ReadWineFixedReplyLastDescriptor {-1};
  uint64_t ReadWineFixedReplyLastReturnedByteCount {};
  uint32_t ReadWineFixedReplyLastError {};
  uint32_t ReadWineFixedReplyLastDeclaredSize {};
  uint64_t GetDents64CallCount {};
  uint64_t GetDents64SuccessCount {};
  uint64_t GetDents64FailureCount {};
  uint64_t GetDents64EOFCount {};
  uint64_t GetDents64HostByteCount {};
  uint64_t GetDents64LinuxByteCount {};
  uint64_t GetDents64EntryCount {};
  uint64_t GetDents64SkippedZeroInodeCount {};
  uint64_t GetDents64RollbackSuccessCount {};
  uint64_t GetDents64RollbackFailureCount {};
  int64_t GetDents64LastDescriptor {-1};
  uint64_t GetDents64LastGuestBuffer {};
  uint64_t GetDents64LastByteCount {};
  uint64_t GetDents64LastReturnedByteCount {};
  uint64_t GetDents64LastConvertedEntryCount {};
  bool GetDents64LastDescriptorOwned {};
  bool GetDents64LastDescriptorDirectory {};
  bool GetDents64LastDescriptorPathConfined {};
  int64_t GetDents64LastPosition {-1};
  int64_t GetDents64LastNextOffset {-1};
  int64_t GetDents64LastHostError {};
  int64_t GetDents64LastLinuxError {};
  std::string GetDents64LastBufferClass {"none"};
  std::string GetDents64LastFailureReason {"none"};
  uint64_t PRead64CallCount {};
  uint64_t PRead64ByteCount {};
  uint64_t FStatCallCount {};
  uint64_t FStatSuccessCount {};
  uint64_t FcntlCallCount {};
  uint64_t FcntlInvalidDescriptorCount {};
  uint64_t FcntlGetFlagsCandidateCount {};
  uint64_t FcntlGetFlagsRegistryTemporaryCandidateCount {};
  uint64_t FcntlGetFlagsRegistryTemporarySuccessCount {};
  uint64_t FcntlGetFlagsRegistryTemporaryFailureCount {};
  uint64_t FcntlGetFlagsRegistryTemporaryLastLinuxFlags {};
  uint64_t FcntlGetFlagsGenericSuccessCount {};
  uint64_t FcntlGetFlagsGenericFailureCount {};
  uint64_t FcntlGetFlagsGenericLastLinuxFlags {};
  int64_t FcntlGetFlagsLastHostFlags {-1};
  int64_t FcntlGetFlagsLastHostError {};
  bool FcntlGetFlagsLastDescriptorMatchesRegistryTemporary {};
  bool FcntlGetFlagsRegistryTemporaryLastDescriptorRegular {};
  uint64_t FcntlSetFlagsCallCount {};
  uint64_t FcntlSetFlagsSuccessCount {};
  uint64_t FcntlSetLockCallCount {};
  uint64_t FcntlSetLockSuccessCount {};
  uint64_t FcntlSetDescriptorFlagsCallCount {};
  uint64_t FcntlSetDescriptorFlagsExactCandidateCount {};
  uint64_t FcntlSetDescriptorFlagsOtherShapeCount {};
  uint64_t FcntlSetDescriptorFlagsSuccessCount {};
  uint64_t FcntlSetDescriptorFlagsFailureCount {};
  int64_t FcntlSetDescriptorFlagsLastHostFlagsBefore {-1};
  int64_t FcntlSetDescriptorFlagsLastHostFlagsAfter {-1};
  std::array<FcntlTraceEntry, 16> FcntlTrace {};
  size_t FcntlTraceCount {};
  int64_t FcntlSetFlagsLastHostFlagsBefore {-1};
  int64_t FcntlSetFlagsLastHostFlagsAfter {-1};
  int64_t FcntlLastDescriptor {};
  int64_t FcntlLastCommand {};
  uint64_t FcntlLastArgument {};
  int64_t FcntlLastLinuxError {};
  bool FcntlLastFlockReadable {};
  int64_t FcntlLastFlockType {};
  int64_t FcntlLastFlockWhence {};
  int64_t FcntlLastFlockStart {};
  int64_t FcntlLastFlockLength {};
  int64_t FcntlLastFlockProcessID {};
  std::string FcntlLastArgumentClass {"none"};
  std::string FcntlLastFailureReason {"none"};
  uint64_t SetSockOptCallCount {};
  int64_t SetSockOptLastDescriptor {};
  bool SetSockOptLastDescriptorOwned {};
  int64_t SetSockOptLastLevel {};
  int64_t SetSockOptLastOption {};
  uint64_t SetSockOptLastValueLength {};
  std::string SetSockOptLastValueClass {"none"};
  bool SetSockOptLastValueReadable {};
  bool SetSockOptLastInt32ValueReadable {};
  int64_t SetSockOptLastInt32Value {};
  uint64_t SetSockOptLastValueFingerprint {};
  uint64_t SetSockOptPassCredentialsCandidateCount {};
  uint64_t SetSockOptPassCredentialsEnableCount {};
  uint64_t SetSockOptPassCredentialsDisableCount {};
  uint64_t SetSockOptPassCredentialsNoHostOptionCount {};
  uint64_t SetSockOptSuccessCount {};
  uint64_t SetSockOptOtherShapeCount {};
  int64_t SetSockOptLastLinuxError {};
  std::string SetSockOptLastFailureReason {"none"};
  std::array<SetSockOptTraceEntry, 8> SetSockOptTrace {};
  size_t SetSockOptTraceCount {};
  uint64_t SigAltStackCallCount {};
  std::string SigAltStackLastNewStackClass {"none"};
  std::string SigAltStackLastOldStackClass {"none"};
  bool SigAltStackLastNewStackReadable {};
  bool SigAltStackLastOldStackWritable {};
  uint64_t SigAltStackLastStackPointer {};
  int64_t SigAltStackLastFlags {};
  uint64_t SigAltStackLastSize {};
  uint64_t SigAltStackLastGuestRSP {};
  bool SigAltStackLastStackRangeReadable {};
  bool SigAltStackLastStackRangeLowShadow {};
  bool SigAltStackLastStackRangeLowShadowMapped {};
  bool SigAltStackLastStackRangeLowShadowReadable {};
  bool SigAltStackLastStackRangeLowShadowWritable {};
  bool SigAltStackLastStackRangeLowShadowExecutable {};
  bool SigAltStackLastGuestRSPWithinStack {};
  uint64_t SigAltStackInstallCandidateCount {};
  uint64_t SigAltStackInstallSuccessCount {};
  uint64_t SigAltStackNoHostInstallCount {};
  uint64_t SigAltStackOtherShapeCount {};
  int64_t SigAltStackLastLinuxError {};
  std::string SigAltStackLastFailureReason {"none"};
  LinuxX86_64StackT SigAltStackGuestState {};
  bool SigAltStackGuestStateInstalled {};
  uint64_t StatCallCount {};
  uint64_t StatSuccessCount {};
  uint64_t MMapCallCount {};
  uint64_t MMapSuccessCount {};
  uint64_t MMapFileByteCount {};
  uint64_t MMapFailureCount {};
  uint64_t MMapFixedCallCount {};
  uint64_t MMapFixedNoReplaceCallCount {};
  uint64_t MMapAnonymousCallCount {};
  uint64_t MMapStackCallCount {};
  uint64_t MMapArenaRejectCount {};
  std::array<MMapArenaRejectRecord, 64> MMapArenaRejectRecords {};
  uint64_t MMapArenaRejectRecordCount {};
  bool MMapArenaRejectRecordOverflow {};
  uint64_t MMapSharedFileCandidateCount {};
  uint64_t MMapSharedFileSuccessCount {};
  uint64_t MMapSharedFileArenaReplacementCount {};
  int64_t MMapSharedFileLastDescriptor {};
  bool MMapSharedFileLastDescriptorMatchesMemfd {};
  bool MMapSharedFileLastDescriptorStatSucceeded {};
  bool MMapSharedFileLastDescriptorRegular {};
  int64_t MMapSharedFileLastDescriptorSize {};
  uint64_t MMapSharedFileLastLength {};
  uint64_t MMapSharedFileLastProtection {};
  uint64_t MMapSharedFileLastOffset {};
  uint64_t MMapSharedFileLastHostPageSize {};
  uint64_t MMapSharedFileLastHostMappingSpan {};
  uint64_t MMapSharedFileLastHostAddressRemainder {};
  uint64_t MMapSharedFixedLowCandidateCount {};
  int64_t MMapSharedFixedLowLastDescriptor {};
  bool MMapSharedFixedLowLastDescriptorReceivedSCMRights {};
  bool MMapSharedFixedLowLastDescriptorStatSucceeded {};
  bool MMapSharedFixedLowLastDescriptorRegular {};
  int64_t MMapSharedFixedLowLastDescriptorSize {};
  uint64_t MMapSharedFixedLowLastProtection {};
  uint64_t MMapSharedFixedLowLastFlags {};
  uint64_t MMapSharedFixedLowLastOffset {};
  uint64_t MMapSharedFixedLowAttemptCount {};
  uint64_t MMapSharedFixedLowSuccessCount {};
  uint64_t MMapSharedFixedLowFailureCount {};
  uint64_t MMapSharedFixedLowLastHostAddress {};
  uint64_t MMapSharedFixedLowLastHostSpan {};
  uint64_t MMapSharedFixedLowLastHostMappedSubpageMask {};
  uint64_t MMapSharedFixedLowLastHostPackedSubpageStates {};
  uint64_t MMapLastRequestedAddress {};
  uint64_t MMapLastLength {};
  uint64_t MMapLastAlignedLength {};
  uint64_t MMapLastProtection {};
  uint64_t MMapLastFlags {};
  uint64_t MMapLastOffset {};
  uint64_t MMapLastMappingAddress {};
  int64_t MMapLastLinuxError {};
  std::string MMapLastDescriptorClass {"none"};
  std::string MMapLastFailureReason {"none"};
  std::array<HighMMapRecord, 64> HighMMapRecords {};
  uint64_t HighMMapRecordCount {};
  bool HighMMapRecordOverflow {};
  std::array<LowMMapRecord, 128> LowMMapRecords {};
  uint64_t LowMMapRecordCount {};
  bool LowMMapRecordOverflow {};
  std::array<MMapCallRecord, 128> MMapCallRecords {};
  uint64_t MMapCallRecordCount {};
  bool MMapCallRecordOverflow {};
  uint64_t MUnmapCallCount {};
  uint64_t MUnmapSuccessCount {};
  uint64_t MUnmapLogicalLIFOCount {};
  uint64_t MUnmapRecordDeactivationCount {};
  uint64_t MUnmapLastAddress {};
  uint64_t MUnmapLastLength {};
  uint64_t MUnmapLastActiveRecordIndexPlusOne {};
  uint64_t MUnmapLastActiveRecordArenaEnd {};
  uint64_t MUnmapLastActiveRecordProtection {};
  uint64_t MUnmapLastActiveRecordFlags {};
  int64_t MUnmapLastLinuxError {};
  bool MUnmapLastRangeZeroed {};
  bool MUnmapLastCursorRewound {};
  bool MUnmapLastHostPagesReleased {};
  MUnmapFailureReason MUnmapLastFailureReason {MUnmapFailureReason::None};
  bool Clone3Seen {};
  bool Clone3LastStructureReadable {};
  uint64_t Clone3CallCount {};
  uint64_t Clone3ClearSighandFallbackCount {};
  uint64_t Clone3LastSize {};
  uint64_t Clone3LastFlags {};
  uint64_t Clone3LastExitSignal {};
  uint64_t Clone3LastStackSize {};
  int64_t Clone3LastLinuxError {};
  std::string Clone3LastFailureReason {"none"};
  bool VForkChildInstrumentationEnabled {};
  bool VForkParentInstrumentationEnabled {};
  bool VForkParentProcessBridgeEnabled {};
  bool VForkParentWineServerBridgeEnabled {};
  bool VirtualVForkChildEntered {};
  bool VirtualVForkChildStackApplied {};
  uint64_t VirtualVForkChildEntryCount {};
  bool VirtualVForkParentEntered {};
  bool VirtualVForkParentResumed {};
  uint64_t VirtualVForkParentEntryCount {};
  uint64_t VirtualVForkParentDiagnosticPID {};
  bool VirtualVForkParentStackUnmapAccepted {};
  uint64_t VirtualVForkParentStackUnmapAcceptCount {};
  uint64_t VirtualVForkParentStackUnmapAddress {};
  uint64_t VirtualVForkParentStackUnmapLength {};
  uint64_t VirtualVForkBridgeSpawnAttemptCount {};
  int64_t VirtualVForkBridgeSpawnResult {-1};
  int64_t VirtualVForkBridgeProcessID {-1};
  bool VirtualVForkBridgeProcessIDPositive {};
  bool VirtualVForkBridgeSignalMaskExplicit {};
  bool VirtualVForkBridgeSignalDefaultsExplicit {};
  bool VirtualVForkBridgeWaitSeen {};
  bool VirtualVForkBridgeWaitPIDMatched {};
  bool VirtualVForkBridgeWaitStatusWritable {};
  bool VirtualVForkBridgeWaitResourceUsageZero {};
  uint64_t VirtualVForkBridgeWaitSuccessCount {};
  int64_t VirtualVForkBridgeWaitResult {-1};
  int64_t VirtualVForkBridgeHostWaitStatus {-1};
  bool VirtualVForkBridgeChildExited {};
  int64_t VirtualVForkBridgeChildExitCode {-1};
  bool VirtualVForkBridgeChildReaped {};
  int64_t VirtualVForkBridgeLastHostError {};
  uint64_t VirtualVForkWineServerSpawnAttemptCount {};
  int64_t VirtualVForkWineServerSpawnResult {-1};
  int64_t VirtualVForkWineServerProcessID {-1};
  bool VirtualVForkWineServerProcessIDPositive {};
  bool VirtualVForkWineServerSignalMaskExplicit {};
  bool VirtualVForkWineServerSignalDefaultsExplicit {};
  bool VirtualVForkWineServerSocketReady {};
  uint64_t VirtualVForkWineServerSocketReadinessPollCount {};
  bool VirtualVForkWineServerExitedBeforeReady {};
  bool VirtualVForkWineServerProcessReaped {};
  int64_t VirtualVForkWineServerHostWaitStatus {-1};
  bool VirtualVForkWineServerChildExited {};
  int64_t VirtualVForkWineServerChildExitCode {-1};
  bool VirtualVForkWineServerChildSignaled {};
  int64_t VirtualVForkWineServerChildTermSignal {-1};
  bool VirtualVForkWineServerCleanupSignalSent {};
  bool VirtualVForkWineServerForceKillSignalSent {};
  bool VirtualVForkWineServerFinalized {};
  int64_t VirtualVForkWineServerLastHostError {};
  std::string VirtualVForkWineServerGuestSocketPath {"none"};
  bool RtSigactionSeen {};
  uint64_t RtSigactionCallCount {};
  uint64_t RtSigactionQuerySuccessCount {};
  uint64_t RtSigactionSetSuccessCount {};
  uint64_t RtSigactionGuestSigpipeIgnoreSuccessCount {};
  uint64_t RtSigactionGuestTableOnlySuccessCount {};
  int64_t RtSigactionLastSignal {};
  uint64_t RtSigactionLastSigsetSize {};
  uint64_t RtSigactionLastActionFingerprint {};
  bool RtSigactionInternalCandidateSeen {};
  bool RtSigactionInternalActionContained {};
  bool RtSigactionInternalHandlerMatches {};
  bool RtSigactionInternalFlagsMatch {};
  bool RtSigactionInternalRestorerMatches {};
  bool RtSigactionInternalMaskMatchesProcess {};
  int64_t RtSigactionInternalCandidateSignal {};
  uint64_t RtSigactionInternalCandidateMaskFingerprint {};
  uint64_t RtSigactionInternalProcessMaskFingerprint {};
  bool LowPageAliasModeEnabled {};
  bool LowPageAliasRequestSeen {};
  bool LowPageAliasAccepted {};
  bool LowPageAliasBackingZeroed {};
  bool LowMemoryBiasModeEnabled {};
  bool HighMemoryRegionModeEnabled {};
  uint64_t LowPageAliasRequestCount {};
  uint64_t LowPageAliasAcceptCount {};
  uint64_t LowMemoryMMapRequestCount {};
  uint64_t LowMemoryMMapSuccessCount {};
  uint64_t LowMemoryMMapFailureCount {};
  uint64_t LowMemoryMProtectRequestCount {};
  uint64_t LowMemoryMProtectSuccessCount {};
  uint64_t LowMemoryMProtectFailureCount {};
  uint64_t HighMemoryMMapRequestCount {};
  uint64_t HighMemoryMMapSuccessCount {};
  uint64_t HighMemoryMMapFailureCount {};
  uint64_t HighMemoryMProtectRequestCount {};
  uint64_t HighMemoryMProtectSuccessCount {};
  uint64_t HighMemoryMProtectFailureCount {};
  uint64_t HighMemoryMUnmapRequestCount {};
  uint64_t HighMemoryMUnmapSuccessCount {};
  uint64_t HighMemoryMUnmapFailureCount {};
  uint64_t CloseCallCount {};
  uint64_t CloseSuccessCount {};
  uint64_t PrctlCallCount {};
  uint64_t PrctlSetNameSuccessCount {};
  uint64_t PrctlLastNameLength {};
  uint64_t PrctlLastNameFingerprint {};
  uint64_t UserfaultfdCallCount {};
  uint64_t UserfaultfdUnavailableCount {};
  uint64_t UserfaultfdLastFlags {};
  uint64_t RtSigprocmaskCallCount {};
  uint64_t RtSigprocmaskSuccessCount {};
  uint64_t RtSigprocmaskQuerySuccessCount {};
  uint64_t RtSigprocmaskLastHow {};
  uint64_t RtSigprocmaskLastSigsetSize {};
  uint64_t RtSigprocmaskLastMaskFingerprint {};
  uint64_t ArchPrctlCallCount {};
  uint64_t ArchPrctlSetFSCount {};
  uint64_t ArchPrctlSetGSCount {};
  uint64_t SetTIDAddressCallCount {};
  uint64_t SetRobustListCallCount {};
  uint64_t RSeqCallCount {};
  uint64_t MProtectCallCount {};
  uint64_t MProtectLogicalSuccessCount {};
  uint64_t Prlimit64CallCount {};
  uint64_t Prlimit64SuccessCount {};
  uint64_t Prlimit64StackQueryCandidateCount {};
  uint64_t Prlimit64StackQuerySuccessCount {};
  uint64_t Prlimit64StackLastCurrent {};
  uint64_t Prlimit64StackLastMaximum {};
  uint64_t Prlimit64NoFileQueryCandidateCount {};
  uint64_t Prlimit64NoFileQuerySuccessCount {};
  uint64_t Prlimit64NoFileLastCurrent {};
  uint64_t Prlimit64NoFileLastMaximum {};
  uint64_t Prlimit64NoFileSetCandidateCount {};
  uint64_t Prlimit64NoFileSetSuccessCount {};
  uint64_t Prlimit64NoFileSetFailureCount {};
  uint64_t Prlimit64NoFileSetLastRequestedCurrent {};
  uint64_t Prlimit64NoFileSetLastRequestedMaximum {};
  int64_t Prlimit64NoFileSetLastHostError {};
  int64_t Prlimit64NoFileSetLastLinuxError {};
  std::string Prlimit64NoFileSetLastFailureReason {"none"};
  uint64_t Prlimit64CoreQueryCandidateCount {};
  uint64_t Prlimit64CoreQuerySuccessCount {};
  uint64_t Prlimit64CoreLastCurrent {};
  uint64_t Prlimit64CoreLastMaximum {};
  uint64_t Prlimit64AddressSpaceQueryCandidateCount {};
  uint64_t Prlimit64AddressSpaceQuerySuccessCount {};
  uint64_t Prlimit64AddressSpaceLastCurrent {};
  uint64_t Prlimit64AddressSpaceLastMaximum {};
  uint64_t Prlimit64AddressSpaceSetCandidateCount {};
  uint64_t Prlimit64AddressSpaceSetSuccessCount {};
  uint64_t Prlimit64AddressSpaceSetFailureCount {};
  uint64_t Prlimit64AddressSpaceSetLastRequestedCurrent {};
  uint64_t Prlimit64AddressSpaceSetLastRequestedMaximum {};
  int64_t Prlimit64AddressSpaceSetLastHostError {};
  int64_t Prlimit64AddressSpaceSetLastLinuxError {};
  std::string Prlimit64AddressSpaceSetLastFailureReason {"none"};
  uint64_t Prlimit64NiceQueryCandidateCount {};
  uint64_t Prlimit64NiceQueryUnsupportedCount {};
  int64_t Prlimit64NiceQueryLastLinuxError {};
  std::string Prlimit64NiceQueryLastFailureReason {"none"};
  uint64_t Prlimit64NiceSetCandidateCount {};
  uint64_t Prlimit64OtherShapeCount {};
  uint64_t Prlimit64NiceSetLastCurrent {};
  uint64_t Prlimit64NiceSetLastMaximum {};
  std::string Prlimit64NiceSetLastOldLimitClass {"none"};
  std::array<Prlimit64TraceEntry, 8> Prlimit64Trace {};
  size_t Prlimit64TraceCount {};
  int64_t Prlimit64LastProcessID {};
  int64_t Prlimit64LastResource {};
  std::string Prlimit64LastNewLimitClass {"none"};
  std::string Prlimit64LastOldLimitClass {"none"};
  uint64_t Prlimit64LastCurrent {};
  uint64_t Prlimit64LastMaximum {};
  int64_t Prlimit64LastHostError {};
  int64_t Prlimit64LastLinuxError {};
  std::string Prlimit64LastFailureReason {"none"};
  uint64_t ClockGettimeCallCount {};
  uint64_t ClockGettimeSuccessCount {};
  uint64_t HandleSyscallCallCount {};
  uint64_t PostSessionSyscallDiagnosticLimit {};
  uint64_t PostSessionSyscallDiagnosticCallCount {};
  uint64_t PostSessionBoundarySyscallNumber {};
  std::string PostSessionBoundaryArgument1Class {"none"};
  bool PostSessionBoundaryEpollPWait2Seen {};
  int64_t PostSessionBoundaryEpollPWait2Descriptor {};
  bool PostSessionBoundaryEpollPWait2DescriptorOwned {};
  bool PostSessionBoundaryEpollPWait2DescriptorKnown {};
  int64_t PostSessionBoundaryEpollPWait2MaxEvents {};
  std::string PostSessionBoundaryEpollPWait2EventsClass {"none"};
  std::string PostSessionBoundaryEpollPWait2TimeoutClass {"none"};
  bool PostSessionBoundaryEpollPWait2TimeoutReadable {};
  int64_t PostSessionBoundaryEpollPWait2TimeoutSeconds {};
  int64_t PostSessionBoundaryEpollPWait2TimeoutNanoseconds {};
  std::string PostSessionBoundaryEpollPWait2SignalMaskClass {"none"};
  uint64_t PostSessionBoundaryEpollPWait2SignalSetSize {};
  bool PostSessionBoundaryEpollWaitSeen {};
  int64_t PostSessionBoundaryEpollWaitDescriptor {};
  bool PostSessionBoundaryEpollWaitDescriptorOwned {};
  bool PostSessionBoundaryEpollWaitDescriptorKnown {};
  int64_t PostSessionBoundaryEpollWaitMaxEvents {};
  std::string PostSessionBoundaryEpollWaitEventsClass {"none"};
  int64_t PostSessionBoundaryEpollWaitTimeout {};
  std::array<uint64_t, 16> PostSessionLiveTrace {};
  size_t PostSessionLiveTraceCount {};
  uint64_t PostSessionDiagnosticStopSignalRequestCount {};
  int64_t PostSessionDiagnosticStopSignalLastHostError {};
  uint64_t UnsupportedDiagnosticStopSignalRequestCount {};
  int64_t UnsupportedDiagnosticStopSignalLastHostError {};
  uint64_t ClockNanosleepCallCount {};
  uint64_t ClockNanosleepSuccessCount {};
  uint64_t ClockNanosleepInterruptedCount {};
  uint64_t ClockNanosleepAbsoluteCallCount {};
  uint64_t ClockNanosleepLastRequestSeconds {};
  uint64_t ClockNanosleepLastRequestNanoseconds {};
  uint64_t GetrandomCallCount {};
  uint64_t GetrandomSuccessCount {};
  uint64_t GetrandomByteCount {};
  uint64_t UnameCallCount {};
  uint64_t UnameSuccessCount {};
  uint64_t GetcwdCallCount {};
  uint64_t GetcwdSuccessCount {};
  uint64_t ChdirCallCount {};
  uint64_t ChdirSuccessCount {};
  uint64_t ChdirHostMirrorSuccessCount {};
  bool ChdirLastHostPathResolved {};
  bool ChdirLastHostCWDMatchesGuest {};
  bool UmaskSeen {};
  uint64_t UmaskCallCount {};
  uint64_t UmaskSuccessCount {};
  uint64_t UmaskLastRequestedMode {};
  uint64_t UmaskLastAppliedMode {};
  uint64_t UmaskLastPreviousMode {};
  uint64_t GuestUmask {0022};
  uint64_t MkdirCallCount {};
  uint64_t MkdirSuccessCount {};
  uint64_t MkdirLastMode {};
  uint64_t MkdirLastAppliedMode {};
  uint64_t MkdirLastPathLength {};
  uint64_t MkdirLastPathFingerprint {};
  bool MkdirLastTargetConfined {};
  bool MkdirLastParentConfined {};
  bool MkdirLastParentExists {};
  bool MkdirLastParentDirectory {};
  bool MkdirLastTargetExists {};
  bool MkdirLastTargetDirectory {};
  int64_t MkdirLastLinuxError {};
  std::string MkdirLastPathClass {"none"};
  std::string MkdirLastFailureReason {"none"};
  uint64_t RenameCallCount {};
  std::array<RegistryRenameTraceEntry, 8> RegistryRenameTrace {};
  size_t RegistryRenameTraceCount {};
  uint64_t RenameExactCandidateCount {};
  uint64_t RenameSuccessCount {};
  uint64_t RenameFailureCount {};
  int64_t RenameLastHostError {};
  int64_t RenameLastLinuxError {};
  std::string RenameLastFailureReason {"none"};
  uint64_t UnlinkCallCount {};
  uint64_t UnlinkSuccessCount {};
  uint64_t UnlinkMissingTargetCount {};
  uint64_t UnlinkLastPathLength {};
  uint64_t UnlinkLastPathFingerprint {};
  bool UnlinkLastHostPathResolved {};
  bool UnlinkLastTargetExists {};
  bool UnlinkLastTargetSocket {};
  int64_t UnlinkLastLinuxError {};
  std::string UnlinkLastPathClass {"none"};
  std::string UnlinkLastFailureReason {"none"};
  uint64_t ChmodCallCount {};
  uint64_t ChmodSuccessCount {};
  uint64_t ChmodLastPathLength {};
  uint64_t ChmodLastPathFingerprint {};
  uint64_t ChmodLastMode {};
  uint64_t ChmodLastAppliedMode {};
  bool ChmodLastTargetSocket {};
  int64_t ChmodLastLinuxError {};
  std::string ChmodLastPathClass {"none"};
  std::string ChmodLastFailureReason {"none"};
  uint64_t SymlinkCallCount {};
  uint64_t SymlinkSuccessCount {};
  uint64_t SymlinkLastTargetLength {};
  uint64_t SymlinkLastTargetFingerprint {};
  uint64_t SymlinkLastLinkLength {};
  uint64_t SymlinkLastLinkFingerprint {};
  bool SymlinkLastTargetConfined {};
  bool SymlinkLastLinkConfined {};
  bool SymlinkLastTargetReproduced {};
  int64_t SymlinkLastLinuxError {};
  std::string SymlinkLastTargetClass {"none"};
  std::string SymlinkLastLinkClass {"none"};
  std::string SymlinkLastFailureReason {"none"};
  uint64_t ReadlinkCallCount {};
  uint64_t ReadlinkSuccessCount {};
  uint64_t ReadlinkProcSelfExeCount {};
  uint64_t GetUIDCallCount {};
  uint64_t LastGetUID {};
  uint64_t GetPIDCallCount {};
  uint64_t LastGetPID {};
  uint64_t GetTIDCallCount {};
  uint64_t GetTIDSuccessCount {};
  uint64_t GetTIDDeallocateSuccessCount {};
  uint64_t GetTIDLastMachPort {};
  kern_return_t GetTIDLastDeallocateResult {KERN_SUCCESS};
  uint64_t SetPriorityCallCount {};
  uint64_t SetPrioritySuccessCount {};
  uint64_t SetPriorityExpectedRejectionCount {};
  uint64_t SetPriorityUnexpectedFailureCount {};
  int64_t SetPriorityLastWhich {};
  int64_t SetPriorityLastWho {};
  int64_t SetPriorityLastNice {};
  bool SetPriorityLastWhoMatchesPID {};
  int64_t SetPriorityLastHostError {};
  int64_t SetPriorityLastLinuxError {};
  std::string SetPriorityLastFailureReason {"none"};
  uint64_t PollCallCount {};
  uint64_t PollSuccessCount {};
  uint64_t PollReadyDescriptorCount {};
  uint64_t PollLastDescriptorCount {};
  int64_t PollLastTimeout {};
  int64_t PollLastDescriptor {};
  int64_t PollLastEvents {};
  int64_t PollLastReturnedEvents {};
  int64_t PollLastLinuxError {};
  uint64_t Pipe2CallCount {};
  uint64_t Pipe2SuccessCount {};
  uint64_t Pipe2LowShadowWriteCount {};
  uint64_t Pipe2LastGuestPointer {};
  uint64_t Pipe2LastFlags {};
  int64_t Pipe2LastLinuxError {};
  std::string Pipe2LastPointerClass {"none"};
  bool Pipe2LastLowShadowMapped {};
  bool Pipe2LastLowShadowWritable {};
  std::array<Pipe2TraceEntry, 8> Pipe2Trace {};
  size_t Pipe2TraceCount {};
  uint64_t SocketCallCount {};
  uint64_t SocketSuccessCount {};
  uint64_t SocketPairCallCount {};
  uint64_t SocketPairSuccessCount {};
  int64_t SocketPairLastDomain {};
  int64_t SocketPairLastType {};
  int64_t SocketPairLastProtocol {};
  int64_t SocketPairLastLinuxError {};
  uint64_t ShutdownCallCount {};
  uint64_t ShutdownSuccessCount {};
  int64_t ShutdownLastDescriptor {};
  int64_t ShutdownLastHow {};
  int64_t ShutdownLastLinuxError {};
  uint64_t BindCallCount {};
  uint64_t BindSuccessCount {};
  int64_t BindLastDescriptor {};
  uint64_t BindLastAddressLength {};
  uint64_t BindLastFamily {};
  uint64_t BindLastPathLength {};
  uint64_t BindLastPathFingerprint {};
  bool BindLastHostCWDMatchesGuest {};
  bool BindLastEndpointCreated {};
  int64_t BindLastLinuxError {};
  std::string BindLastPathClass {"none"};
  std::string BindLastFailureReason {"none"};
  uint64_t ListenCallCount {};
  uint64_t ListenSuccessCount {};
  int64_t ListenLastDescriptor {};
  int64_t ListenLastBacklog {};
  int64_t ListenLastLinuxError {};
  std::string ListenLastFailureReason {"none"};
  uint64_t FutexWaitVCallCount {};
  uint64_t FutexWaitVAvailabilityProbeCount {};
  uint64_t FutexWaitVLastWaiterCount {};
  uint64_t FutexWaitVLastFlags {};
  int64_t FutexWaitVLastClockID {};
  int64_t FutexWaitVLastLinuxError {};
  std::string FutexWaitVLastFailureReason {"none"};
  uint64_t EpollCreateCallCount {};
  uint64_t EpollCreateSuccessCount {};
  int64_t EpollCreateLastSize {};
  int64_t EpollCreateLastDescriptor {};
  int64_t EpollCreateLastLinuxError {};
  std::string EpollCreateLastFailureReason {"none"};
  uint64_t EpollCtlCallCount {};
  uint64_t EpollCtlSuccessCount {};
  uint64_t EpollCtlAddWriteCandidateCount {};
  uint64_t EpollCtlAddWriteSuccessCount {};
  int64_t EpollCtlLastEpollDescriptor {};
  int64_t EpollCtlLastOperation {};
  int64_t EpollCtlLastTargetDescriptor {};
  bool EpollCtlLastEventReadable {};
  uint64_t EpollCtlLastEvents {};
  uint64_t EpollCtlLastData {};
  int64_t EpollCtlLastLinuxError {};
  std::string EpollCtlLastFailureReason {"none"};
  std::array<EpollCtlTraceEntry, 32> EpollCtlTrace {};
  size_t EpollCtlTraceCount {};
  uint64_t EpollPWait2CallCount {};
  uint64_t EpollPWait2HostUnavailableFallbackCount {};
  int64_t EpollPWait2LastDescriptor {};
  bool EpollPWait2LastDescriptorKnown {};
  int64_t EpollPWait2LastMaxEvents {};
  std::string EpollPWait2LastEventsClass {"none"};
  std::string EpollPWait2LastTimeoutClass {"none"};
  bool EpollPWait2LastTimeoutReadable {};
  int64_t EpollPWait2LastTimeoutSeconds {};
  int64_t EpollPWait2LastTimeoutNanoseconds {};
  std::string EpollPWait2LastSignalMaskClass {"none"};
  uint64_t EpollPWait2LastSignalSetSize {};
  int64_t EpollPWait2LastLinuxError {};
  std::string EpollPWait2LastFailureReason {"none"};
  uint64_t EpollWaitCallCount {};
  uint64_t EpollWaitSuccessCount {};
  uint64_t EpollWaitTimeoutCount {};
  uint64_t EpollWaitReturnedEventCount {};
  uint64_t EpollWaitTimedCallCount {};
  uint64_t EpollWaitTimedSuccessCount {};
  uint64_t EpollWaitTimedReturnedEventCount {};
  uint64_t EpollWaitPollingCallCount {};
  uint64_t EpollWaitPollingSuccessCount {};
  uint64_t EpollWaitPollingReturnedEventCount {};
  int64_t EpollWaitLastDescriptor {};
  bool EpollWaitLastDescriptorKnown {};
  int64_t EpollWaitLastMaxEvents {};
  std::string EpollWaitLastEventsClass {"none"};
  int64_t EpollWaitLastTimeout {};
  int64_t EpollWaitLastLinuxError {};
  std::string EpollWaitLastFailureReason {"none"};
  uint64_t GettimeofdayCallCount {};
  uint64_t GettimeofdaySuccessCount {};
  int64_t GettimeofdayLastSeconds {};
  int64_t GettimeofdayLastMicroseconds {};
  int64_t GettimeofdayLastLinuxError {};
  std::string GettimeofdayLastFailureReason {"none"};
  uint64_t SysinfoCallCount {};
  uint64_t SysinfoSuccessCount {};
  uint64_t SysinfoLastUptime {};
  uint64_t SysinfoLastTotalRAM {};
  uint64_t SysinfoLastFreeRAM {};
  uint64_t SysinfoLastMemoryUnit {};
  std::string SysinfoLastBufferClass {"none"};
  uint64_t TimeCallCount {};
  uint64_t TimeNullPointerCallCount {};
  uint64_t TimeSuccessCount {};
  int64_t TimeLastSeconds {};
  int64_t TimeLastLinuxError {};
  std::string TimeLastFailureReason {"none"};
  uint64_t FStatFSCallCount {};
  uint64_t FStatFSSuccessCount {};
  int64_t FStatFSLastDescriptor {};
  int64_t FStatFSLastType {};
  int64_t FStatFSLastLinuxError {};
  std::string FStatFSLastFailureReason {"none"};
  uint64_t FAccessAt2CallCount {};
  uint64_t FAccessAt2SuccessCount {};
  int64_t FAccessAt2LastDirectoryDescriptor {};
  uint64_t FAccessAt2LastMode {};
  uint64_t FAccessAt2LastFlags {};
  int64_t FAccessAt2LastLinuxError {};
  std::string FAccessAt2LastFailureReason {"none"};
  uint64_t MemfdCreateCallCount {};
  uint64_t MemfdCreateSuccessCount {};
  uint64_t MemfdCreateLastFlags {};
  uint64_t MemfdCreateLastNameLength {};
  uint64_t MemfdCreateLastNameFingerprint {};
  int64_t MemfdCreateLastDescriptor {-1};
  int64_t MemfdCreateLastLinuxError {};
  bool MemfdCreateBackingUnlinked {};
  std::string MemfdCreateLastFailureReason {"none"};
  uint64_t PWrite64CallCount {};
  uint64_t PWrite64SuccessCount {};
  uint64_t PWrite64WrittenByteCount {};
  bool SessionMappingWriteCompleted {};
  int64_t PWrite64LastDescriptor {};
  uint64_t PWrite64LastByteCount {};
  uint64_t PWrite64LastOffset {};
  int64_t PWrite64LastLinuxError {};
  std::string PWrite64LastFailureReason {"none"};
  uint64_t FTruncateCallCount {};
  uint64_t FTruncateSuccessCount {};
  int64_t FTruncateLastDescriptor {};
  uint64_t FTruncateLastLength {};
  int64_t FTruncateLastLinuxError {};
  std::string FTruncateLastFailureReason {"none"};
  uint64_t FChdirCallCount {};
  uint64_t FChdirSuccessCount {};
  int64_t FChdirLastDescriptor {};
  uint64_t FChdirLastPathLength {};
  uint64_t FChdirLastPathFingerprint {};
  bool FChdirLastTargetDirectory {};
  bool FChdirLastTargetConfined {};
  bool FChdirLastHostCWDMatchesGuest {};
  int64_t FChdirLastLinuxError {};
  std::string FChdirLastFailureReason {"none"};
  uint64_t ConnectCallCount {};
  uint64_t ConnectRootFSConfinedCount {};
  uint64_t ConnectAltLoaderMappedCount {};
  uint64_t ConnectMissingTargetCount {};
  uint64_t ConnectSuccessCount {};
  int64_t ConnectLastDescriptor {-1};
  uint64_t ConnectLastAddressLength {};
  uint64_t ConnectLastFamily {};
  uint64_t ConnectLastPayloadLength {};
  uint64_t ConnectLastPathLength {};
  uint64_t ConnectLastPathFingerprint {};
  uint64_t ConnectLastHostPathLength {};
  int64_t ConnectLastHostError {};
  int64_t ConnectLastLinuxError {};
  bool ConnectLastAltLoaderMapped {};
  ConnectPathClass ConnectLastPathClass {ConnectPathClass::None};
  ConnectFailureReason ConnectLastFailureReason {ConnectFailureReason::None};
  bool AcceptSeen {};
  uint64_t AcceptCallCount {};
  uint64_t AcceptSuccessCount {};
  bool AcceptLastDescriptorOwned {};
  int64_t AcceptLastDescriptor {};
  int64_t AcceptLastAcceptedDescriptor {-1};
  uint32_t AcceptLastInputAddressLength {};
  uint32_t AcceptLastHostAddressLength {};
  uint32_t AcceptLastGuestAddressLength {};
  int64_t AcceptLastLinuxError {};
  AcceptFailureReason AcceptLastFailureReason {AcceptFailureReason::None};
  uint64_t GetSockOptCallCount {};
  uint64_t GetSockOptPeerCredentialsCallCount {};
  uint64_t GetSockOptPeerCredentialsSuccessCount {};
  int64_t GetSockOptLastDescriptor {};
  int64_t GetSockOptLastLevel {};
  int64_t GetSockOptLastOption {};
  uint32_t GetSockOptLastInputLength {};
  uint32_t GetSockOptLastOutputLength {};
  uint32_t GetSockOptLastHostProcessLength {};
  int64_t GetSockOptLastHostProcessID {};
  uint64_t GetSockOptLastHostUserID {};
  uint64_t GetSockOptLastHostGroupID {};
  int64_t GetSockOptLastHostError {};
  int64_t GetSockOptLastLinuxError {};
  GetSockOptFailureReason GetSockOptLastFailureReason {GetSockOptFailureReason::None};
  uint64_t SendMsgCallCount {};
  uint64_t SendMsgSuccessCount {};
  uint64_t SendMsgStandardInputCandidateCount {};
  uint64_t SendMsgStandardInputSuccessCount {};
  uint64_t SendMsgStandardInputFailureCount {};
  uint64_t SendMsgStandardOutputCandidateCount {};
  uint64_t SendMsgStandardOutputSuccessCount {};
  uint64_t SendMsgStandardOutputFailureCount {};
  uint64_t SendMsgLastByteCount {};
  uint64_t SendMsgLastHostControlLength {};
  bool SendMsgLastDescriptorOwned {};
  bool SendMsgLastHeaderReadable {};
  bool SendMsgLastNamePresent {};
  bool SendMsgLastFirstIOVectorReadable {};
  bool SendMsgLastFirstIOVectorPayloadReadable {};
  bool SendMsgLastControlPresent {};
  bool SendMsgLastControlReadable {};
  bool SendMsgLastTransferredDescriptorOwned {};
  bool SendMsgLastTransferredDescriptorStandard {};
  bool SendMsgLastTransferredDescriptorClosed {};
  bool SendMsgLastTransferredDescriptorStatSucceeded {};
  bool SendMsgLastTransferredDescriptorFIFO {};
  bool SendMsgLastTransferredDescriptorSocket {};
  bool SendMsgLastTransferredDescriptorRegular {};
  bool SendMsgLastTransferredDescriptorCharacter {};
  int64_t SendMsgLastDescriptor {};
  int64_t SendMsgLastCallFlags {};
  int64_t SendMsgLastTransferredDescriptor {-1};
  int64_t SendMsgLastTransferredDescriptorFlags {-1};
  int64_t SendMsgLastTransferredDescriptorFlagsError {};
  int64_t SendMsgLastTransferredStatusFlags {-1};
  int64_t SendMsgLastTransferredStatusFlagsError {};
  int64_t SendMsgLastMessageFlags {};
  int64_t SendMsgLastControlLevel {};
  int64_t SendMsgLastControlType {};
  int64_t SendMsgLastHostError {};
  int64_t SendMsgLastLinuxError {};
  uint64_t SendMsgLastNameLength {};
  uint64_t SendMsgLastIOVectorCount {};
  uint64_t SendMsgLastFirstIOVectorBase {};
  uint64_t SendMsgLastFirstIOVectorLength {};
  uint64_t SendMsgLastFirstIOVectorPayloadFingerprint {};
  uint64_t SendMsgLastControlLength {};
  uint64_t SendMsgLastControlMessageLength {};
  SendMsgFailureReason SendMsgLastFailureReason {SendMsgFailureReason::None};
  uint64_t RecvMsgCallCount {};
  uint64_t RecvMsgSuccessCount {};
  uint64_t RecvMsgLastByteCount {};
  uint64_t RecvMsgLastHostControlLength {};
  uint64_t RecvMsgLastHostControlMessageLength {};
  bool RecvMsgLastDescriptorOwned {};
  bool RecvMsgLastHeaderReadable {};
  bool RecvMsgLastNamePresent {};
  bool RecvMsgLastFirstIOVectorReadable {};
  bool RecvMsgLastFirstIOVectorPayloadReadable {};
  bool RecvMsgLastControlPresent {};
  bool RecvMsgLastControlReadable {};
  int64_t RecvMsgLastDescriptor {};
  int64_t RecvMsgLastCallFlags {};
  int64_t RecvMsgLastMessageFlags {};
  int64_t RecvMsgLastReceivedDescriptor {-1};
  int64_t RecvMsgLastHostMessageFlags {};
  int64_t RecvMsgLastHostError {};
  int64_t RecvMsgLastLinuxError {};
  uint32_t RecvMsgLastNameLength {};
  uint32_t RecvMsgLastPayloadValue {};
  uint64_t RecvMsgLastIOVectorCount {};
  uint64_t RecvMsgLastFirstIOVectorBase {};
  uint64_t RecvMsgLastFirstIOVectorLength {};
  uint64_t RecvMsgLastControlLength {};
  std::string RecvMsgLastFailureReason {"none"};
  uint64_t WriteVCallCount {};
  uint64_t WriteVSuccessCount {};
  uint64_t WriteVVectorCount {};
  uint64_t WriteVByteCount {};
  uint64_t WriteVWineReplyCandidateCount {};
  uint64_t WriteVWineReplySuccessCount {};
  uint64_t WriteVWineReplyFailureCount {};
  uint64_t WriteVWineDefaultDaclReplyCandidateCount {};
  uint64_t WriteVWineDefaultDaclReplySuccessCount {};
  uint64_t WriteVWineDefaultDaclReplyFailureCount {};
  uint64_t WriteVWineVariableReplyCandidateCount {};
  uint64_t WriteVWineVariableReplySuccessCount {};
  uint64_t WriteVWineVariableReplyFailureCount {};
  int64_t WriteVWineReplyLastDescriptor {-1};
  uint64_t WriteVWineReplyLastVectorCount {};
  uint64_t WriteVWineReplyLastRequestedByteCount {};
  int64_t WriteVWineReplyLastReturnedByteCount {-1};
  int64_t WriteVWineReplyLastHostError {};
  int64_t WriteVWineReplyLastLinuxError {};
  uint64_t WriteVWineRequestCandidateCount {};
  uint64_t WriteVWineRequestSuccessCount {};
  uint64_t WriteVWineRequestFailureCount {};
  uint64_t WriteVWineCreateKeyRequestCandidateCount {};
  uint64_t WriteVWineCreateKeyRequestSuccessCount {};
  uint64_t WriteVWineCreateKeyRequestFailureCount {};
  uint64_t WriteVWineEnumKeyValueRequestCandidateCount {};
  uint64_t WriteVWineEnumKeyValueRequestSuccessCount {};
  uint64_t WriteVWineEnumKeyValueRequestFailureCount {};
  uint64_t WriteVWineOpenKeyRequestCandidateCount {};
  uint64_t WriteVWineOpenKeyRequestSuccessCount {};
  uint64_t WriteVWineOpenKeyRequestFailureCount {};
  uint64_t WriteVWineCreateEventRequestCandidateCount {};
  uint64_t WriteVWineCreateEventRequestSuccessCount {};
  uint64_t WriteVWineCreateEventRequestFailureCount {};
  uint64_t WriteVWineCreateSymlinkRequestCandidateCount {};
  uint64_t WriteVWineCreateSymlinkRequestSuccessCount {};
  uint64_t WriteVWineCreateSymlinkRequestFailureCount {};
  uint64_t WriteVWineNewProcessRequestCandidateCount {};
  uint64_t WriteVWineNewProcessRequestSuccessCount {};
  uint64_t WriteVWineNewProcessRequestFailureCount {};
  uint64_t WriteVWineCreateFileRequestCandidateCount {};
  uint64_t WriteVWineCreateFileRequestSuccessCount {};
  uint64_t WriteVWineCreateFileRequestFailureCount {};
  int64_t WriteVWineRequestLastDescriptor {-1};
  uint64_t WriteVWineRequestLastVectorCount {};
  uint64_t WriteVWineRequestLastRequestedByteCount {};
  int64_t WriteVWineRequestLastReturnedByteCount {-1};
  int64_t WriteVWineRequestLastHostError {};
  int64_t WriteVWineRequestLastLinuxError {};
  uint64_t WriteVRejectedCallCount {};
  int64_t WriteVRejectedFirstDescriptor {-1};
  bool WriteVRejectedFirstDescriptorOwned {};
  bool WriteVRejectedFirstDescriptorStandard {};
  bool WriteVRejectedFirstDescriptorClosed {};
  bool WriteVRejectedFirstDescriptorMatchesRecvMsg {};
  bool WriteVRejectedFirstDescriptorReceivedSCMRights {};
  int64_t WriteVRejectedFirstHostDescriptorFlags {-1};
  int64_t WriteVRejectedFirstHostDescriptorError {};
  int64_t WriteVRejectedFirstHostStatusFlags {-1};
  int64_t WriteVRejectedFirstHostStatusError {};
  bool WriteVRejectedFirstDescriptorStatSucceeded {};
  bool WriteVRejectedFirstDescriptorFIFO {};
  bool WriteVRejectedFirstDescriptorSocket {};
  bool WriteVRejectedFirstDescriptorRegular {};
  uint64_t WriteVRejectedFirstGuestVectors {};
  uint64_t WriteVRejectedFirstVectorCount {};
  std::string WriteVRejectedFirstGuestVectorsClass {"none"};
  bool WriteVRejectedFirstGuestVectorsReadable {};
  uint64_t WriteVRejectedFirstTotalByteCount {};
  bool WriteVRejectedFirstAllPayloadsReadable {};
  uint64_t WriteVRejectedFirstVector1Base {};
  uint64_t WriteVRejectedFirstVector1Length {};
  std::string WriteVRejectedFirstVector1Class {"none"};
  bool WriteVRejectedFirstVector1Readable {};
  uint64_t WriteVRejectedFirstVector1Fingerprint {};
  bool WriteVRejectedFirstOfficialWineServer {};
  bool WriteVRejectedFirstReplyHeaderReadable {};
  bool WriteVRejectedFirstReplyDeclaredSizeMatchesVector2 {};
  uint32_t WriteVRejectedFirstReplyError {};
  uint32_t WriteVRejectedFirstReplyDeclaredSize {};
  bool WriteVRejectedFirstRequestHeaderReadable {};
  int32_t WriteVRejectedFirstRequestCode {};
  uint32_t WriteVRejectedFirstRequestSize {};
  uint32_t WriteVRejectedFirstReplySize {};
  bool WriteVRejectedFirstOpenKeyCandidate {};
  bool WriteVRejectedFirstOpenKeyFixedFieldsReadable {};
  uint32_t WriteVRejectedFirstOpenKeyParent {};
  uint32_t WriteVRejectedFirstOpenKeyAccess {};
  uint32_t WriteVRejectedFirstOpenKeyAttributes {};
  uint64_t WriteVRejectedFirstOpenKeyNameLength {};
  bool WriteVRejectedFirstOpenKeyNameEvenLength {};
  bool WriteVRejectedFirstOpenKeyNameReadable {};
  bool WriteVRejectedFirstOpenKeyNameHasEmbeddedNull {};
  bool WriteVRejectedFirstCreateKeyCandidate {};
  bool WriteVRejectedFirstCreateKeyFixedFieldsReadable {};
  bool WriteVRejectedFirstCreateKeyObjectAttributesReadable {};
  uint32_t WriteVRejectedFirstCreateKeyAccess {};
  uint32_t WriteVRejectedFirstCreateKeyOptions {};
  uint32_t WriteVRejectedFirstCreateKeyRootDirectory {};
  uint32_t WriteVRejectedFirstCreateKeyAttributes {};
  uint32_t WriteVRejectedFirstCreateKeySecurityDescriptorLength {};
  uint32_t WriteVRejectedFirstCreateKeyNameLength {};
  uint64_t WriteVRejectedFirstCreateKeyObjectAttributesLength {};
  bool WriteVRejectedFirstCreateKeyLayoutValid {};
  bool WriteVRejectedFirstCreateKeyNameEvenLength {};
  uint64_t WriteVRejectedFirstCreateKeyNameFingerprint {};
  uint64_t WriteVRejectedFirstCreateKeyClassLength {};
  bool WriteVRejectedFirstCreateKeyClassEvenLength {};
  uint64_t WriteVRejectedFirstCreateKeyClassFingerprint {};
  bool WriteVRejectedFirstCreateSymlinkCandidate {};
  bool WriteVRejectedFirstCreateSymlinkFixedFieldsReadable {};
  bool WriteVRejectedFirstCreateSymlinkObjectAttributesReadable {};
  bool WriteVRejectedFirstCreateSymlinkRequestSizeMatchesPayload {};
  uint32_t WriteVRejectedFirstCreateSymlinkAccess {};
  uint32_t WriteVRejectedFirstCreateSymlinkRootDirectory {};
  uint32_t WriteVRejectedFirstCreateSymlinkAttributes {};
  uint32_t WriteVRejectedFirstCreateSymlinkSecurityDescriptorLength {};
  uint32_t WriteVRejectedFirstCreateSymlinkNameLength {};
  uint64_t WriteVRejectedFirstCreateSymlinkCalculatedObjectAttributesLength {};
  bool WriteVRejectedFirstCreateSymlinkObjectAttributesLayoutValid {};
  bool WriteVRejectedFirstCreateSymlinkNameEvenLength {};
  bool WriteVRejectedFirstCreateSymlinkNameHasEmbeddedNull {};
  uint64_t WriteVRejectedFirstCreateSymlinkNameFingerprint {};
  uint64_t WriteVRejectedFirstCreateSymlinkTargetLength {};
  bool WriteVRejectedFirstCreateSymlinkTargetEvenLength {};
  bool WriteVRejectedFirstCreateSymlinkTargetHasEmbeddedNull {};
  uint64_t WriteVRejectedFirstCreateSymlinkTargetFingerprint {};
  bool WriteVRejectedFirstCreateFileCandidate {};
  bool WriteVRejectedFirstCreateFileFixedFieldsReadable {};
  bool WriteVRejectedFirstCreateFileObjectAttributesReadable {};
  bool WriteVRejectedFirstCreateFileUnixNameReadable {};
  bool WriteVRejectedFirstCreateFileRequestSizeMatchesPayloads {};
  uint32_t WriteVRejectedFirstCreateFileAccess {};
  uint32_t WriteVRejectedFirstCreateFileSharing {};
  int32_t WriteVRejectedFirstCreateFileDisposition {};
  uint32_t WriteVRejectedFirstCreateFileOptions {};
  uint32_t WriteVRejectedFirstCreateFileAttributes {};
  uint32_t WriteVRejectedFirstCreateFileRootDirectory {};
  uint32_t WriteVRejectedFirstCreateFileObjectAttributes {};
  uint32_t WriteVRejectedFirstCreateFileSecurityDescriptorLength {};
  uint32_t WriteVRejectedFirstCreateFileObjectNameLength {};
  bool WriteVRejectedFirstCreateFileSecurityDescriptorEvenLength {};
  bool WriteVRejectedFirstCreateFileObjectNameEvenLength {};
  uint64_t WriteVRejectedFirstCreateFileCalculatedObjectAttributesLength {};
  bool WriteVRejectedFirstCreateFileObjectAttributesLayoutValid {};
  uint64_t WriteVRejectedFirstCreateFileSecurityDescriptorFingerprint {};
  uint64_t WriteVRejectedFirstCreateFileObjectNameFingerprint {};
  bool WriteVRejectedFirstCreateFileObjectNameHasEmbeddedNull {};
  uint64_t WriteVRejectedFirstCreateFileUnixNameLength {};
  uint64_t WriteVRejectedFirstCreateFileUnixNameFingerprint {};
  bool WriteVRejectedFirstCreateFileUnixNameHasEmbeddedNull {};
  bool WriteVRejectedFirstCreateFileUnixNamePrintableASCII {};
  std::string WriteVRejectedFirstCreateFileUnixNamePathClass {"none"};
  uint64_t WriteVRejectedFirstVector2Base {};
  uint64_t WriteVRejectedFirstVector2Length {};
  std::string WriteVRejectedFirstVector2Class {"none"};
  bool WriteVRejectedFirstVector2Readable {};
  uint64_t WriteVRejectedFirstVector2Fingerprint {};
  uint64_t WriteVRejectedFirstVector3Base {};
  uint64_t WriteVRejectedFirstVector3Length {};
  std::string WriteVRejectedFirstVector3Class {"none"};
  bool WriteVRejectedFirstVector3Readable {};
  uint64_t WriteVRejectedFirstVector3Fingerprint {};
  uint64_t WriteVRejectedFirstVector4Base {};
  uint64_t WriteVRejectedFirstVector4Length {};
  std::string WriteVRejectedFirstVector4Class {"none"};
  bool WriteVRejectedFirstVector4Readable {};
  uint64_t WriteVRejectedFirstVector4Fingerprint {};
  uint64_t WriteCallCount {};
  uint64_t WriteByteCount {};
  uint64_t WriteAltLoaderCandidateCount {};
  uint64_t WriteAltLoaderSuccessCount {};
  uint64_t WriteAltLoaderFailureCount {};
  uint64_t WriteAltLoaderWrittenByteCount {};
  int64_t WriteAltLoaderLastDescriptor {-1};
  uint64_t WriteAltLoaderLastByteCount {};
  int64_t WriteAltLoaderLastReturnedByteCount {-1};
  int64_t WriteAltLoaderLastHostError {};
  int64_t WriteAltLoaderLastLinuxError {};
  uint64_t WriteRegistryTemporaryCandidateCount {};
  std::array<RegistryTemporaryWriteTraceEntry, 8> WriteRegistryTemporaryTrace {};
  size_t WriteRegistryTemporaryTraceCount {};
  uint64_t WriteRegistryTemporaryExactCandidateCount {};
  uint64_t WriteRegistryTemporarySuccessCount {};
  uint64_t WriteRegistryTemporaryFailureCount {};
  uint64_t WriteRegistryTemporaryWrittenByteCount {};
  int64_t WriteRegistryTemporaryLastDescriptor {-1};
  uint64_t WriteRegistryTemporaryLastByteCount {};
  int64_t WriteRegistryTemporaryLastReturnedByteCount {-1};
  int64_t WriteRegistryTemporaryLastHostError {};
  int64_t WriteRegistryTemporaryLastLinuxError {};
  bool WriteWineReplySeen {};
  uint64_t WriteWineReplyCandidateCount {};
  uint64_t WriteWineReplySuccessCount {};
  uint64_t WriteWineReplyFailureCount {};
  uint64_t WriteWineReplyWrittenByteCount {};
  int64_t WriteWineReplyLastDescriptor {-1};
  uint64_t WriteWineReplyLastByteCount {};
  int64_t WriteWineReplyLastHostError {};
  int64_t WriteWineReplyLastLinuxError {};
  bool WriteRequestPipeSeen {};
  uint64_t WriteRequestPipeCandidateCount {};
  uint64_t WriteRequestPipeSuccessCount {};
  uint64_t WriteRequestPipeFailureCount {};
  uint64_t WriteRequestPipeWrittenByteCount {};
  int64_t WriteRequestPipeLastDescriptor {-1};
  uint64_t WriteRequestPipeLastByteCount {};
  int64_t WriteRequestPipeLastHostError {};
  int64_t WriteRequestPipeLastLinuxError {};
  uint64_t WriteRejectedCallCount {};
  int64_t WriteRejectedFirstDescriptor {-1};
  bool WriteRejectedFirstDescriptorOwned {};
  bool WriteRejectedFirstDescriptorStandard {};
  bool WriteRejectedFirstDescriptorClosed {};
  bool WriteRejectedFirstDescriptorMatchesRecvMsg {};
  int64_t WriteRejectedFirstHostDescriptorFlags {-1};
  int64_t WriteRejectedFirstHostDescriptorError {};
  bool WriteRejectedFirstDescriptorStatSucceeded {};
  bool WriteRejectedFirstDescriptorFIFO {};
  bool WriteRejectedFirstDescriptorSocket {};
  bool WriteRejectedFirstDescriptorRegular {};
  uint64_t WriteRejectedFirstBuffer {};
  uint64_t WriteRejectedFirstByteCount {};
  std::string WriteRejectedFirstBufferClass {"none"};
  bool WriteRejectedFirstBufferReadable {};
  uint64_t WriteRejectedFirstBufferFingerprint {};
  uint64_t ExitCode {std::numeric_limits<uint64_t>::max()};
  uint64_t UnexpectedSyscall {std::numeric_limits<uint64_t>::max()};
  uint64_t IoctlTCGets2CandidateCount {};
  uint64_t IoctlTCGets2NonTTYCount {};
  int64_t IoctlTCGets2LastDescriptor {-1};
  uint64_t IoctlTCGets2LastArgument {};
  int64_t IoctlTCGets2LastHostError {};
  int64_t IoctlTCGets2LastLinuxError {};
  bool IoctlTCGets2LastDescriptorStandard {};
  bool IoctlTCGets2LastDescriptorClosed {};
  bool IoctlTCGets2LastArgumentWritable {};
  bool IoctlTCGets2LastDescriptorStatSucceeded {};
  bool IoctlTCGets2LastDescriptorCharacter {};
  bool IoctlTCGets2LastDescriptorFIFO {};
  bool IoctlTCGets2LastDescriptorTTY {};
  uint64_t IoctlExt2GetFlagsCandidateCount {};
  uint64_t IoctlExt2GetFlagsUnsupportedFilesystemCount {};
  int64_t IoctlExt2GetFlagsLastDescriptor {};
  uint64_t IoctlExt2GetFlagsLastArgument {};
  int64_t IoctlExt2GetFlagsLastLinuxError {};
  bool IoctlExt2GetFlagsLastDescriptorOwned {};
  bool IoctlExt2GetFlagsLastArgumentWritable {};
  bool IoctlExt2GetFlagsLastDescriptorStatSucceeded {};
  bool IoctlExt2GetFlagsLastDescriptorDirectory {};
  bool IoctlExt2GetFlagsLastDescriptorRegular {};
  bool IoctlExt2GetFlagsLastDescriptorPathReadable {};
  bool IoctlExt2GetFlagsLastDescriptorPathConfined {};
  uint64_t IoctlExt2GetFlagsLastDescriptorPathLength {};
  uint64_t IoctlExt2GetFlagsLastDescriptorPathFingerprint {};
  bool UnsupportedIoctlBoundarySeen {};
  bool UnsupportedIoctlDescriptorOwned {};
  bool UnsupportedIoctlDescriptorStandard {};
  bool UnsupportedIoctlDescriptorClosed {};
  bool UnsupportedIoctlDescriptorStatSucceeded {};
  bool UnsupportedIoctlDescriptorFIFO {};
  bool UnsupportedIoctlDescriptorSocket {};
  bool UnsupportedIoctlDescriptorRegular {};
  bool UnsupportedIoctlDescriptorCharacter {};
  bool UnsupportedIoctlDescriptorTTY {};
  bool UnsupportedIoctlDescriptorFlagsReadable {};
  bool UnsupportedIoctlArgumentReadable {};
  bool UnsupportedIoctlArgumentWritable {};
  int64_t UnsupportedIoctlDescriptor {};
  int64_t UnsupportedIoctlDescriptorFlags {-1};
  uint64_t UnsupportedIoctlRequest {};
  uint64_t UnsupportedIoctlRequestNumber {};
  uint64_t UnsupportedIoctlRequestType {};
  uint64_t UnsupportedIoctlRequestSize {};
  uint64_t UnsupportedIoctlRequestDirection {};
  uint64_t UnsupportedIoctlArgument {};
  uint64_t UnsupportedIoctlArgumentFingerprint {};
  uint64_t UnsupportedIoctlCallOrdinal {};
  uint64_t UnsupportedIoctlGuestRIP {};
  uint64_t UnsupportedIoctlReadWineFixedReplyCountAtBoundary {};
  uint64_t UnsupportedIoctlWriteRequestPipeCountAtBoundary {};
  std::string UnsupportedIoctlArgumentClass {"none"};
  bool UnsupportedGetDents64BoundarySeen {};
  bool UnsupportedGetDents64DescriptorOwned {};
  bool UnsupportedGetDents64DescriptorStatSucceeded {};
  bool UnsupportedGetDents64DescriptorDirectory {};
  bool UnsupportedGetDents64DescriptorOffsetReadable {};
  bool UnsupportedGetDents64DescriptorPathReadable {};
  bool UnsupportedGetDents64DescriptorPathConfined {};
  bool UnsupportedGetDents64BufferWritable {};
  int64_t UnsupportedGetDents64Descriptor {};
  int64_t UnsupportedGetDents64DescriptorOffset {};
  int64_t UnsupportedGetDents64DescriptorOffsetHostError {};
  uint64_t UnsupportedGetDents64GuestBuffer {};
  uint64_t UnsupportedGetDents64ByteCount {};
  uint64_t UnsupportedGetDents64CallOrdinal {};
  uint64_t UnsupportedGetDents64GuestRIP {};
  uint64_t UnsupportedGetDents64DescriptorPathLength {};
  uint64_t UnsupportedGetDents64DescriptorPathFingerprint {};
  std::string UnsupportedGetDents64BufferClass {"none"};
  bool UnsupportedUmaskBoundarySeen {};
  bool UnsupportedUmaskRequestedModePermissionBitsOnly {};
  uint64_t UnsupportedUmaskRequestedMode {};
  uint64_t UnsupportedUmaskCallOrdinal {};
  uint64_t UnsupportedUmaskGuestRIP {};
  uint64_t UnsupportedUmaskWriteRequestPipeCountAtBoundary {};
  uint64_t UnsupportedUmaskReadWineFixedReplyCountAtBoundary {};
  uint64_t UnsupportedUmaskWriteRejectedCountAtBoundary {};
  bool UnsupportedTgkillBoundarySeen {};
  bool UnsupportedTgkillThreadGroupMatchesLastGetPID {};
  bool UnsupportedTgkillThreadMatchesLastGetTID {};
  int64_t UnsupportedTgkillThreadGroupID {};
  int64_t UnsupportedTgkillThreadID {};
  int64_t UnsupportedTgkillSignal {};
  bool UnsupportedSocketBoundarySeen {};
  int64_t UnsupportedSocketDomain {};
  int64_t UnsupportedSocketType {};
  int64_t UnsupportedSocketProtocol {};
  bool UnsupportedAcceptBoundarySeen {};
  bool UnsupportedAcceptDescriptorOwned {};
  bool UnsupportedAcceptAddressLengthReadable {};
  int64_t UnsupportedAcceptDescriptor {};
  uint32_t UnsupportedAcceptAddressLength {};
  std::string UnsupportedAcceptAddressClass {"none"};
  std::string UnsupportedAcceptAddressLengthClass {"none"};
  bool UnsupportedGetSockOptBoundarySeen {};
  bool UnsupportedGetSockOptDescriptorOwned {};
  bool UnsupportedGetSockOptValuePointerNonZero {};
  bool UnsupportedGetSockOptLengthPointerNonZero {};
  bool UnsupportedGetSockOptLengthReadable {};
  bool UnsupportedGetSockOptValueReadable {};
  int64_t UnsupportedGetSockOptDescriptor {};
  int64_t UnsupportedGetSockOptLevel {};
  int64_t UnsupportedGetSockOptOption {};
  uint32_t UnsupportedGetSockOptValueLength {};
  bool UnsupportedSendMsgBoundarySeen {};
  bool UnsupportedSendMsgDescriptorOwned {};
  bool UnsupportedSendMsgHeaderReadable {};
  bool UnsupportedSendMsgNamePresent {};
  bool UnsupportedSendMsgControlPresent {};
  bool UnsupportedSendMsgFirstIOVectorReadable {};
  bool UnsupportedSendMsgFirstIOVectorValueReadable {};
  bool UnsupportedSendMsgFirstControlReadable {};
  bool UnsupportedSendMsgFirstControlDescriptorReadable {};
  bool UnsupportedSendMsgFirstControlDescriptorOwned {};
  int64_t UnsupportedSendMsgDescriptor {};
  int64_t UnsupportedSendMsgCallFlags {};
  int64_t UnsupportedSendMsgMessageFlags {};
  int64_t UnsupportedSendMsgFirstControlLevel {};
  int64_t UnsupportedSendMsgFirstControlType {};
  int64_t UnsupportedSendMsgFirstControlDescriptor {};
  uint32_t UnsupportedSendMsgNameLength {};
  uint32_t UnsupportedSendMsgFirstIOVectorValue {};
  uint64_t UnsupportedSendMsgIOVectorCount {};
  uint64_t UnsupportedSendMsgControlLength {};
  uint64_t UnsupportedSendMsgFirstIOVectorLength {};
  uint64_t UnsupportedSendMsgFirstControlMessageLength {};
  bool UnsupportedMUnmapBoundarySeen {};
  bool UnsupportedMUnmapAddressLinuxPageAligned {};
  bool UnsupportedMUnmapLengthLinuxPageAligned {};
  bool UnsupportedMUnmapRangeInGuestMemory {};
  bool UnsupportedMUnmapRangeInMMapArena {};
  bool UnsupportedMUnmapRangeBelowNextMMapAddress {};
  bool UnsupportedMUnmapMatchesLastMapping {};
  uint64_t UnsupportedMUnmapAddress {};
  uint64_t UnsupportedMUnmapLength {};
  uint64_t UnsupportedMUnmapAddressOffsetFromArena {};
  uint64_t UnsupportedMUnmapLastMappingAddress {};
  uint64_t UnsupportedMUnmapLastMappingLength {};
  bool UnsupportedSocketPairBoundarySeen {};
  bool UnsupportedSocketPairVectorReadable {};
  int64_t UnsupportedSocketPairDomain {};
  int64_t UnsupportedSocketPairType {};
  int64_t UnsupportedSocketPairProtocol {};
  std::string UnsupportedSocketPairVectorClass {"none"};
  bool UnsupportedShutdownBoundarySeen {};
  bool UnsupportedShutdownDescriptorOwned {};
  int64_t UnsupportedShutdownDescriptor {};
  int64_t UnsupportedShutdownHow {};
  bool UnsupportedPollBoundarySeen {};
  bool UnsupportedPollArrayReadable {};
  bool UnsupportedPollFirstDescriptorOwned {};
  uint64_t UnsupportedPollDescriptorCount {};
  int64_t UnsupportedPollTimeout {};
  int64_t UnsupportedPollFirstDescriptor {};
  int64_t UnsupportedPollFirstEvents {};
  int64_t UnsupportedPollFirstReturnedEvents {};
  bool UnsupportedPipe2BoundarySeen {};
  bool UnsupportedPipe2VectorReadable {};
  uint64_t UnsupportedPipe2Flags {};
  std::string UnsupportedPipe2VectorClass {"none"};
  bool UnsupportedConnectBoundarySeen {};
  bool UnsupportedConnectDescriptorOwned {};
  uint64_t UnsupportedConnectAddressLength {};
  uint64_t UnsupportedConnectFamily {};
  uint64_t UnsupportedConnectPathLength {};
  uint64_t UnsupportedConnectPathFingerprint {};
  std::string UnsupportedConnectPathClass {"none"};
  bool UnsupportedBindBoundarySeen {};
  bool UnsupportedBindDescriptorOwned {};
  bool UnsupportedBindAddressReadable {};
  bool UnsupportedBindPathTerminated {};
  bool UnsupportedBindHostPathResolved {};
  bool UnsupportedBindTargetExists {};
  int64_t UnsupportedBindDescriptor {};
  uint64_t UnsupportedBindAddressLength {};
  uint64_t UnsupportedBindFamily {};
  uint64_t UnsupportedBindPathLength {};
  uint64_t UnsupportedBindPathFingerprint {};
  std::string UnsupportedBindPathClass {"none"};
  bool UnsupportedListenBoundarySeen {};
  bool UnsupportedListenDescriptorOwned {};
  int64_t UnsupportedListenDescriptor {};
  int64_t UnsupportedListenBacklog {};
  bool UnsupportedFutexWaitVBoundarySeen {};
  bool UnsupportedFutexWaitVArrayReadable {};
  bool UnsupportedFutexWaitVFirstAddressReadable {};
  bool UnsupportedFutexWaitVTimeoutReadable {};
  uint64_t UnsupportedFutexWaitVWaiterCount {};
  uint64_t UnsupportedFutexWaitVFlags {};
  int64_t UnsupportedFutexWaitVClockID {};
  uint64_t UnsupportedFutexWaitVFirstExpectedValue {};
  uint64_t UnsupportedFutexWaitVFirstAddress {};
  uint64_t UnsupportedFutexWaitVFirstFlags {};
  uint64_t UnsupportedFutexWaitVFirstReserved {};
  uint64_t UnsupportedFutexWaitVFirstCurrentValue {};
  int64_t UnsupportedFutexWaitVTimeoutSeconds {};
  int64_t UnsupportedFutexWaitVTimeoutNanoseconds {};
  std::string UnsupportedFutexWaitVFirstAddressClass {"none"};
  std::string UnsupportedFutexWaitVTimeoutClass {"none"};
  bool UnsupportedEpollCreateBoundarySeen {};
  int64_t UnsupportedEpollCreateSize {};
  bool UnsupportedEpollCtlBoundarySeen {};
  bool UnsupportedEpollCtlEpollDescriptorOwned {};
  bool UnsupportedEpollCtlEpollDescriptorKnown {};
  bool UnsupportedEpollCtlTargetDescriptorOwned {};
  bool UnsupportedEpollCtlEventReadable {};
  int64_t UnsupportedEpollCtlEpollDescriptor {};
  int64_t UnsupportedEpollCtlOperation {};
  int64_t UnsupportedEpollCtlTargetDescriptor {};
  uint64_t UnsupportedEpollCtlEvents {};
  uint64_t UnsupportedEpollCtlData {};
  std::string UnsupportedEpollCtlEventClass {"none"};
  bool UnsupportedGettimeofdayBoundarySeen {};
  bool UnsupportedGettimeofdayTimeReadable {};
  bool UnsupportedGettimeofdayTimezoneReadable {};
  std::string UnsupportedGettimeofdayTimeClass {"none"};
  std::string UnsupportedGettimeofdayTimezoneClass {"none"};
  bool UnsupportedSetPriorityBoundarySeen {};
  int64_t UnsupportedSetPriorityWhich {};
  int64_t UnsupportedSetPriorityWho {};
  int64_t UnsupportedSetPriorityNice {};
  bool UnsupportedFStatFSBoundarySeen {};
  int64_t UnsupportedFStatFSDescriptor {};
  bool UnsupportedFStatFSDescriptorOwned {};
  bool UnsupportedFStatFSDescriptorMatchesIntlNLS {};
  std::string UnsupportedFStatFSBufferClass {"none"};
  bool UnsupportedFAccessAt2BoundarySeen {};
  int64_t UnsupportedFAccessAt2DirectoryDescriptor {};
  uint64_t UnsupportedFAccessAt2Mode {};
  uint64_t UnsupportedFAccessAt2Flags {};
  bool UnsupportedFAccessAt2PathReadable {};
  uint64_t UnsupportedFAccessAt2PathLength {};
  uint64_t UnsupportedFAccessAt2PathFingerprint {};
  std::string UnsupportedFAccessAt2PathClass {"none"};
  std::string UnsupportedFAccessAt2DiagnosticPath {"redacted"};
  bool UnsupportedFAccessAt2HostPathResolved {};
  bool UnsupportedFAccessAt2TargetExists {};
  bool UnsupportedMemfdCreateBoundarySeen {};
  bool UnsupportedMemfdCreateNameReadable {};
  uint64_t UnsupportedMemfdCreateNameLength {};
  uint64_t UnsupportedMemfdCreateNameFingerprint {};
  uint64_t UnsupportedMemfdCreateFlags {};
  std::string UnsupportedMemfdCreateDiagnosticName {"redacted"};
  bool UnsupportedPWrite64BoundarySeen {};
  bool UnsupportedPWrite64DescriptorOwned {};
  bool UnsupportedPWrite64DescriptorMatchesMemfd {};
  bool UnsupportedPWrite64BufferReadable {};
  int64_t UnsupportedPWrite64Descriptor {};
  uint64_t UnsupportedPWrite64ByteCount {};
  uint64_t UnsupportedPWrite64Offset {};
  uint64_t UnsupportedPWrite64BufferFingerprint {};
  uint64_t UnsupportedPWrite64FirstByte {};
  std::string UnsupportedPWrite64BufferClass {"none"};
  bool UnsupportedFTruncateBoundarySeen {};
  bool UnsupportedFTruncateDescriptorOwned {};
  bool UnsupportedFTruncateDescriptorMatchesMemfd {};
  int64_t UnsupportedFTruncateDescriptor {};
  uint64_t UnsupportedFTruncateLength {};
  bool UnsupportedFChdirBoundarySeen {};
  bool UnsupportedFChdirDescriptorOwned {};
  bool UnsupportedFChdirDescriptorStatSucceeded {};
  bool UnsupportedFChdirDescriptorDirectory {};
  bool UnsupportedFChdirDescriptorPathReadable {};
  bool UnsupportedFChdirDescriptorPathConfined {};
  int64_t UnsupportedFChdirDescriptor {};
  uint64_t UnsupportedFChdirDescriptorPathLength {};
  uint64_t UnsupportedFChdirDescriptorPathFingerprint {};
  bool UnsupportedCloneBoundarySeen {};
  uint64_t UnsupportedCloneFlags {};
  uint64_t UnsupportedCloneExitSignal {};
  std::string UnsupportedCloneChildStackClass {"none"};
  std::string UnsupportedCloneParentTIDClass {"none"};
  std::string UnsupportedCloneChildTIDClass {"none"};
  std::string UnsupportedCloneTLSClass {"none"};
  bool UnsupportedWait4BoundarySeen {};
  int64_t UnsupportedWait4ProcessID {};
  uint64_t UnsupportedWait4Options {};
  std::string UnsupportedWait4StatusClass {"none"};
  std::string UnsupportedWait4ResourceUsageClass {"none"};
  bool UnsupportedFcntlBoundarySeen {};
  bool UnsupportedFcntlDescriptorOwned {};
  bool UnsupportedFcntlDescriptorStandard {};
  bool UnsupportedFcntlDescriptorClosed {};
  int64_t UnsupportedFcntlDescriptor {};
  int64_t UnsupportedFcntlCommand {};
  std::string UnsupportedFcntlArgumentClass {"none"};
  bool UnsupportedFcntlFlockReadable {};
  int64_t UnsupportedFcntlFlockType {};
  int64_t UnsupportedFcntlFlockWhence {};
  int64_t UnsupportedFcntlFlockStart {};
  int64_t UnsupportedFcntlFlockLength {};
  int64_t UnsupportedFcntlFlockProcessID {};
  bool UnsupportedUnlinkBoundarySeen {};
  bool UnsupportedUnlinkPathReadable {};
  bool UnsupportedUnlinkHostPathResolved {};
  bool UnsupportedUnlinkTargetExists {};
  bool UnsupportedUnlinkTargetSocket {};
  bool UnsupportedUnlinkTargetRegular {};
  bool UnsupportedUnlinkTargetDirectory {};
  bool UnsupportedUnlinkTargetSymlink {};
  uint64_t UnsupportedUnlinkPathLength {};
  uint64_t UnsupportedUnlinkPathFingerprint {};
  std::string UnsupportedUnlinkPathClass {"none"};
  bool UnsupportedChmodBoundarySeen {};
  bool UnsupportedChmodPathReadable {};
  bool UnsupportedChmodHostPathResolved {};
  bool UnsupportedChmodTargetExists {};
  bool UnsupportedChmodTargetSocket {};
  uint64_t UnsupportedChmodPathLength {};
  uint64_t UnsupportedChmodPathFingerprint {};
  uint64_t UnsupportedChmodMode {};
  uint64_t UnsupportedChmodCurrentMode {};
  std::string UnsupportedChmodPathClass {"none"};
  bool UnsupportedOpenBoundarySeen {};
  bool UnsupportedOpenPathReadable {};
  bool UnsupportedOpenTargetExists {};
  uint64_t UnsupportedOpenFlags {};
  uint64_t UnsupportedOpenMode {};
  uint64_t UnsupportedOpenPathLength {};
  uint64_t UnsupportedOpenPathFingerprint {};
  std::string UnsupportedOpenPathClass {"none"};
  bool UnsupportedPrctlBoundarySeen {};
  bool UnsupportedPrctlArgument2StringTerminated {};
  int64_t UnsupportedPrctlOption {};
  uint64_t UnsupportedPrctlArgument2StringLength {};
  uint64_t UnsupportedPrctlArgument2StringFingerprint {};
  std::string UnsupportedPrctlArgument2Class {"none"};
  bool UnsupportedUserfaultfdBoundarySeen {};
  uint64_t UnsupportedUserfaultfdFlags {};
  bool UnsupportedClone3BoundarySeen {};
  bool UnsupportedClone3StructureReadable {};
  uint64_t UnsupportedClone3Size {};
  uint64_t UnsupportedClone3CopiedSize {};
  uint64_t UnsupportedClone3Flags {};
  uint64_t UnsupportedClone3ExitSignal {};
  uint64_t UnsupportedClone3StackSize {};
  uint64_t UnsupportedClone3SetTIDSize {};
  uint64_t UnsupportedClone3CGroup {};
  std::string UnsupportedClone3ArgumentClass {"none"};
  std::string UnsupportedClone3PIDFDClass {"none"};
  std::string UnsupportedClone3ChildTIDClass {"none"};
  std::string UnsupportedClone3ParentTIDClass {"none"};
  std::string UnsupportedClone3StackClass {"none"};
  std::string UnsupportedClone3TLSClass {"none"};
  std::string UnsupportedClone3SetTIDClass {"none"};
  bool UnsupportedRtSigactionBoundarySeen {};
  bool UnsupportedRtSigactionActionReadable {};
  int64_t UnsupportedRtSigactionSignal {};
  uint64_t UnsupportedRtSigactionSigsetSize {};
  uint64_t UnsupportedRtSigactionFlags {};
  uint64_t UnsupportedRtSigactionMaskFingerprint {};
  uint64_t UnsupportedRtSigactionActionFingerprint {};
  std::string UnsupportedRtSigactionActionClass {"none"};
  std::string UnsupportedRtSigactionOldActionClass {"none"};
  std::string UnsupportedRtSigactionHandlerClass {"none"};
  std::string UnsupportedRtSigactionRestorerClass {"none"};
  bool UnsupportedRtSigprocmaskBoundarySeen {};
  int64_t UnsupportedRtSigprocmaskHow {};
  uint64_t UnsupportedRtSigprocmaskSigsetSize {};
  uint64_t UnsupportedRtSigprocmaskSetFingerprint {};
  std::string UnsupportedRtSigprocmaskSetClass {"none"};
  std::string UnsupportedRtSigprocmaskOldSetClass {"none"};
  bool UnsupportedExecveBoundarySeen {};
  bool UnsupportedExecveTargetExists {};
  bool UnsupportedExecveParentSegmentSeen {};
  bool UnsupportedExecveNormalizedPathConfined {};
  bool UnsupportedExecveArgvReadable {};
  bool UnsupportedExecveArgvTerminated {};
  bool UnsupportedExecveEnvpReadable {};
  bool UnsupportedExecveEnvpTerminated {};
  bool UnsupportedExecveEnvHasLCAllC {};
  bool UnsupportedExecveEnvHasPrivateHome {};
  bool UnsupportedExecveEnvHasWineLoaderNoExec {};
  bool UnsupportedExecveEnvHasWineArchWow64 {};
  uint64_t UnsupportedExecvePathLength {};
  uint64_t UnsupportedExecvePathFingerprint {};
  uint64_t UnsupportedExecveNormalizedPathLength {};
  uint64_t UnsupportedExecveNormalizedPathFingerprint {};
  uint64_t UnsupportedExecveArgCount {};
  uint64_t UnsupportedExecveEnvCount {};
  uint64_t UnsupportedExecveEnvUnknownCount {};
  std::string UnsupportedExecveTargetKind {"none"};
  bool UnsupportedChdirBoundarySeen {};
  bool UnsupportedChdirTargetExists {};
  bool UnsupportedChdirTargetDirectory {};
  bool UnsupportedMkdirBoundarySeen {};
  bool UnsupportedMkdirPathReadable {};
  bool UnsupportedMkdirParentConfined {};
  bool UnsupportedMkdirParentExists {};
  bool UnsupportedMkdirParentDirectory {};
  bool UnsupportedMkdirTargetExists {};
  bool UnsupportedMkdirTargetDirectory {};
  uint64_t UnsupportedMkdirPathLength {};
  uint64_t UnsupportedMkdirPathFingerprint {};
  uint64_t UnsupportedMkdirMode {};
  std::string UnsupportedMkdirPathClass {"none"};
  bool UnsupportedSymlinkBoundarySeen {};
  bool UnsupportedSymlinkTargetReadable {};
  bool UnsupportedSymlinkLinkReadable {};
  bool UnsupportedSymlinkLinkParentConfined {};
  bool UnsupportedSymlinkLinkParentExists {};
  bool UnsupportedSymlinkLinkParentDirectory {};
  bool UnsupportedSymlinkLinkExists {};
  uint64_t UnsupportedSymlinkTargetLength {};
  uint64_t UnsupportedSymlinkTargetFingerprint {};
  uint64_t UnsupportedSymlinkLinkLength {};
  uint64_t UnsupportedSymlinkLinkFingerprint {};
  std::string UnsupportedSymlinkTargetClass {"none"};
  std::string UnsupportedSymlinkLinkClass {"none"};
  uint64_t UnsupportedChdirPathLength {};
  uint64_t UnsupportedChdirPathFingerprint {};
  std::string UnsupportedChdirPathClass {"none"};
  std::vector<uint64_t> UnsupportedExecveArgLengths;
  std::vector<uint64_t> UnsupportedExecveArgFingerprints;
  std::vector<std::string> UnsupportedExecveArgKinds;
  std::string CapturedOutput;
  std::string CapturedError;

private:
  uint64_t GuestSignalMask {};
  std::array<LinuxGuestSigAction, 65> GuestSignalActions {};

  void RecordVirtualVForkWineServerWaitStatus(int Status) {
    VirtualVForkWineServerHostWaitStatus = Status;
    VirtualVForkWineServerChildExited = WIFEXITED(Status);
    VirtualVForkWineServerChildExitCode = VirtualVForkWineServerChildExited
      ? WEXITSTATUS(Status)
      : -1;
    VirtualVForkWineServerChildSignaled = WIFSIGNALED(Status);
    VirtualVForkWineServerChildTermSignal = VirtualVForkWineServerChildSignaled
      ? WTERMSIG(Status)
      : -1;
    VirtualVForkWineServerProcessReaped = true;
  }

  bool SpawnVirtualVForkWineServerBridge() {
    ++VirtualVForkWineServerSpawnAttemptCount;
    VirtualVForkWineServerSpawnResult = EINVAL;
    VirtualVForkWineServerLastHostError = 0;
    if (!VForkParentWineServerBridgeEnabled || HostExecutablePath.empty()
        || WineServerBridgeDirectory.empty()
        || VirtualVForkWineServerProcessID > 0) {
      return false;
    }

    const std::string PrefixPath = RootFS + "/home/regression/.wine";
    struct stat PrefixStat {};
    if (lstat(PrefixPath.c_str(), &PrefixStat) != 0
        || !S_ISDIR(PrefixStat.st_mode)
        || PrefixStat.st_uid != getuid()) {
      VirtualVForkWineServerLastHostError = errno != 0 ? errno : EACCES;
      return false;
    }

    std::array<char, 160> ServerName {};
    const int NameLength = std::snprintf(
      ServerName.data(),
      ServerName.size(),
      "server-%llx-%llx",
      static_cast<unsigned long long>(PrefixStat.st_dev),
      static_cast<unsigned long long>(PrefixStat.st_ino));
    if (NameLength <= 0
        || static_cast<size_t>(NameLength) >= ServerName.size()) {
      VirtualVForkWineServerLastHostError = ENAMETOOLONG;
      return false;
    }

    VirtualVForkWineServerGuestSocketPath = "/tmp/.wine-"
      + std::to_string(getuid()) + "/" + ServerName.data() + "/socket";
    const std::string HostSocketPath = RootFS + VirtualVForkWineServerGuestSocketPath;
    const std::string ProbeOutputPath =
      WineServerBridgeDirectory + "/wineserver-process-probe.json";
    const std::string HostStderrPath =
      WineServerBridgeDirectory + "/wineserver-host-stderr.log";
    const std::string GuestStderrPath =
      WineServerBridgeDirectory + "/wineserver-guest-stderr.log";
    constexpr int PrivateOutputFlags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC;
    const int ProbeOutputDescriptor = open(
      ProbeOutputPath.c_str(),
      PrivateOutputFlags,
      S_IRUSR | S_IWUSR);
    if (ProbeOutputDescriptor < 0) {
      VirtualVForkWineServerLastHostError = errno;
      return false;
    }
    const int HostStderrDescriptor = open(
      HostStderrPath.c_str(),
      PrivateOutputFlags,
      S_IRUSR | S_IWUSR);
    if (HostStderrDescriptor < 0) {
      VirtualVForkWineServerLastHostError = errno;
      close(ProbeOutputDescriptor);
      return false;
    }

    posix_spawn_file_actions_t FileActions;
    int SetupResult = posix_spawn_file_actions_init(&FileActions);
    const bool FileActionsInitialized = SetupResult == 0;
    if (SetupResult == 0) {
      SetupResult = posix_spawn_file_actions_adddup2(
        &FileActions,
        ProbeOutputDescriptor,
        STDOUT_FILENO);
    }
    if (SetupResult == 0) {
      SetupResult = posix_spawn_file_actions_adddup2(
        &FileActions,
        HostStderrDescriptor,
        STDERR_FILENO);
    }
    if (SetupResult == 0 && ProbeOutputDescriptor != STDOUT_FILENO) {
      SetupResult = posix_spawn_file_actions_addclose(
        &FileActions,
        ProbeOutputDescriptor);
    }
    if (SetupResult == 0 && HostStderrDescriptor != STDERR_FILENO) {
      SetupResult = posix_spawn_file_actions_addclose(
        &FileActions,
        HostStderrDescriptor);
    }

    posix_spawnattr_t Attributes;
    const int AttributeInitResult = posix_spawnattr_init(&Attributes);
    const bool AttributesInitialized = AttributeInitResult == 0;
    if (SetupResult == 0) {
      SetupResult = AttributeInitResult;
    }
    if (SetupResult == 0) {
      sigset_t EmptySignals;
      if (sigemptyset(&EmptySignals) != 0) {
        SetupResult = errno;
      } else {
        SetupResult = posix_spawnattr_setsigmask(&Attributes, &EmptySignals);
        VirtualVForkWineServerSignalMaskExplicit = SetupResult == 0;
        if (SetupResult == 0) {
          SetupResult = posix_spawnattr_setsigdefault(&Attributes, &EmptySignals);
          VirtualVForkWineServerSignalDefaultsExplicit = SetupResult == 0;
        }
      }
    }
    if (SetupResult == 0) {
      constexpr short SpawnFlags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
      SetupResult = posix_spawnattr_setflags(&Attributes, SpawnFlags);
    }

    pid_t ServerPID = -1;
    if (SetupResult == 0) {
      char* ServerArguments[] = {
        const_cast<char*>(HostExecutablePath.c_str()),
        const_cast<char*>("--real-rootfs"),
        const_cast<char*>(RootFS.c_str()),
        const_cast<char*>("--guest-program"),
        const_cast<char*>("/opt/proton/files/bin/wineserver"),
        const_cast<char*>("--guest-component-kind"),
        const_cast<char*>("official-proton-wineserver"),
        const_cast<char*>("--private-stderr-output"),
        const_cast<char*>(GuestStderrPath.c_str()),
        const_cast<char*>("--guest-arg"),
        const_cast<char*>("-f"),
        nullptr,
      };
      char LocaleEnvironment[] = "LC_ALL=C";
      char HomeEnvironment[] = "HOME=/home/regression";
      char* ServerEnvironment[] = {
        LocaleEnvironment,
        HomeEnvironment,
        nullptr,
      };
      VirtualVForkWineServerSpawnResult = posix_spawn(
        &ServerPID,
        HostExecutablePath.c_str(),
        &FileActions,
        &Attributes,
        ServerArguments,
        ServerEnvironment);
    } else {
      VirtualVForkWineServerSpawnResult = SetupResult;
    }
    if (AttributesInitialized) {
      static_cast<void>(posix_spawnattr_destroy(&Attributes));
    }
    if (FileActionsInitialized) {
      static_cast<void>(posix_spawn_file_actions_destroy(&FileActions));
    }
    close(ProbeOutputDescriptor);
    close(HostStderrDescriptor);

    if (VirtualVForkWineServerSpawnResult != 0 || ServerPID <= 0) {
      VirtualVForkWineServerLastHostError = VirtualVForkWineServerSpawnResult != 0
        ? VirtualVForkWineServerSpawnResult
        : ECHILD;
      return false;
    }
    VirtualVForkWineServerProcessID = ServerPID;
    VirtualVForkWineServerProcessIDPositive = true;

    constexpr uint64_t MaximumReadinessPolls = 500;
    constexpr timespec ReadinessDelay {.tv_sec = 0, .tv_nsec = 20'000'000};
    for (uint64_t PollIndex = 0; PollIndex < MaximumReadinessPolls; ++PollIndex) {
      ++VirtualVForkWineServerSocketReadinessPollCount;
      struct stat SocketStat {};
      if (lstat(HostSocketPath.c_str(), &SocketStat) == 0
          && S_ISSOCK(SocketStat.st_mode)
          && SocketStat.st_uid == getuid()) {
        VirtualVForkWineServerSocketReady = true;
        return true;
      }

      int Status = 0;
      const pid_t WaitResult = waitpid(ServerPID, &Status, WNOHANG);
      if (WaitResult == ServerPID) {
        VirtualVForkWineServerExitedBeforeReady = true;
        RecordVirtualVForkWineServerWaitStatus(Status);
        VirtualVForkWineServerLastHostError = ECHILD;
        return false;
      }
      if (WaitResult < 0 && errno != EINTR) {
        VirtualVForkWineServerLastHostError = errno;
        return false;
      }
      static_cast<void>(nanosleep(&ReadinessDelay, nullptr));
    }

    VirtualVForkWineServerLastHostError = ETIMEDOUT;
    return false;
  }

  bool SpawnVirtualVForkBridgeChild() {
    ++VirtualVForkBridgeSpawnAttemptCount;
    VirtualVForkBridgeSpawnResult = EINVAL;
    VirtualVForkBridgeLastHostError = 0;
    if ((!VForkParentProcessBridgeEnabled
          && !VForkParentWineServerBridgeEnabled)
        || HostExecutablePath.empty()
        || VirtualVForkBridgeProcessID > 0) {
      return false;
    }

    posix_spawnattr_t Attributes;
    int SetupResult = posix_spawnattr_init(&Attributes);
    bool AttributesInitialized = SetupResult == 0;
    if (SetupResult == 0) {
      sigset_t EmptySignals;
      if (sigemptyset(&EmptySignals) != 0) {
        SetupResult = errno;
      } else {
        SetupResult = posix_spawnattr_setsigmask(&Attributes, &EmptySignals);
        VirtualVForkBridgeSignalMaskExplicit = SetupResult == 0;
        if (SetupResult == 0) {
          SetupResult = posix_spawnattr_setsigdefault(&Attributes, &EmptySignals);
          VirtualVForkBridgeSignalDefaultsExplicit = SetupResult == 0;
        }
      }
    }
    if (SetupResult == 0) {
      constexpr short SpawnFlags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
      SetupResult = posix_spawnattr_setflags(&Attributes, SpawnFlags);
    }

    pid_t ChildPID = -1;
    if (SetupResult == 0) {
      char* ChildArguments[] = {
        const_cast<char*>(HostExecutablePath.c_str()),
        const_cast<char*>("--native-vfork-proxy-child"),
        nullptr,
      };
      char LocaleEnvironment[] = "LC_ALL=C";
      char HomeEnvironment[] = "HOME=/home/regression";
      char* ChildEnvironment[] = {
        LocaleEnvironment,
        HomeEnvironment,
        nullptr,
      };
      VirtualVForkBridgeSpawnResult = posix_spawn(
        &ChildPID,
        HostExecutablePath.c_str(),
        nullptr,
        &Attributes,
        ChildArguments,
        ChildEnvironment);
    } else {
      VirtualVForkBridgeSpawnResult = SetupResult;
    }
    if (AttributesInitialized) {
      static_cast<void>(posix_spawnattr_destroy(&Attributes));
    }

    if (VirtualVForkBridgeSpawnResult != 0 || ChildPID <= 0) {
      VirtualVForkBridgeLastHostError = VirtualVForkBridgeSpawnResult != 0
        ? VirtualVForkBridgeSpawnResult
        : ECHILD;
      return false;
    }
    VirtualVForkBridgeProcessID = ChildPID;
    VirtualVForkBridgeProcessIDPositive = true;
    return true;
  }

  void CleanupVirtualVForkBridgeChild() {
    if (VirtualVForkBridgeProcessID <= 0 || VirtualVForkBridgeChildReaped) {
      return;
    }
    int Status = 0;
    pid_t Result = waitpid(
      static_cast<pid_t>(VirtualVForkBridgeProcessID),
      &Status,
      WNOHANG);
    if (Result == 0) {
      static_cast<void>(kill(static_cast<pid_t>(VirtualVForkBridgeProcessID), SIGTERM));
      do {
        Result = waitpid(
          static_cast<pid_t>(VirtualVForkBridgeProcessID),
          &Status,
          0);
      } while (Result < 0 && errno == EINTR);
    }
    if (Result == static_cast<pid_t>(VirtualVForkBridgeProcessID)) {
      VirtualVForkBridgeChildReaped = true;
    }
  }

  void FinalizeVirtualVForkWineServerBridge() {
    if (VirtualVForkWineServerFinalized) {
      return;
    }
    VirtualVForkWineServerFinalized = true;
    if (VirtualVForkWineServerProcessID <= 0
        || VirtualVForkWineServerProcessReaped) {
      return;
    }

    constexpr timespec CompletionDelay {.tv_sec = 0, .tv_nsec = 20'000'000};
    constexpr uint64_t CompletionPolls = 100;
    int Status = 0;
    pid_t Result = 0;
    for (uint64_t PollIndex = 0; PollIndex < CompletionPolls; ++PollIndex) {
      Result = waitpid(
        static_cast<pid_t>(VirtualVForkWineServerProcessID),
        &Status,
        WNOHANG);
      if (Result == static_cast<pid_t>(VirtualVForkWineServerProcessID)) {
        RecordVirtualVForkWineServerWaitStatus(Status);
        return;
      }
      if (Result < 0 && errno != EINTR) {
        VirtualVForkWineServerLastHostError = errno;
        return;
      }
      static_cast<void>(nanosleep(&CompletionDelay, nullptr));
    }

    if (kill(static_cast<pid_t>(VirtualVForkWineServerProcessID), SIGTERM) == 0) {
      VirtualVForkWineServerCleanupSignalSent = true;
    } else if (errno != ESRCH) {
      VirtualVForkWineServerLastHostError = errno;
    }
    for (uint64_t PollIndex = 0; PollIndex < CompletionPolls; ++PollIndex) {
      Result = waitpid(
        static_cast<pid_t>(VirtualVForkWineServerProcessID),
        &Status,
        WNOHANG);
      if (Result == static_cast<pid_t>(VirtualVForkWineServerProcessID)) {
        RecordVirtualVForkWineServerWaitStatus(Status);
        return;
      }
      if (Result < 0 && errno != EINTR) {
        VirtualVForkWineServerLastHostError = errno;
        return;
      }
      static_cast<void>(nanosleep(&CompletionDelay, nullptr));
    }

    if (kill(static_cast<pid_t>(VirtualVForkWineServerProcessID), SIGKILL) == 0) {
      VirtualVForkWineServerForceKillSignalSent = true;
    } else if (errno != ESRCH) {
      VirtualVForkWineServerLastHostError = errno;
    }
    do {
      Result = waitpid(
        static_cast<pid_t>(VirtualVForkWineServerProcessID),
        &Status,
        0);
    } while (Result < 0 && errno == EINTR);
    if (Result == static_cast<pid_t>(VirtualVForkWineServerProcessID)) {
      RecordVirtualVForkWineServerWaitStatus(Status);
    } else if (Result < 0) {
      VirtualVForkWineServerLastHostError = errno;
    }
  }

  __attribute__((noinline, used))
  uint64_t HandleAcceptSyscall(FEXCore::HLE::SyscallArguments* Arguments) {
    AcceptSeen = true;
    ++AcceptCallCount;
    constexpr uint16_t LinuxAFUnix = 1;
    const int Descriptor = static_cast<int>(Arguments->Argument[1]);
    constexpr uint32_t LinuxSockaddrUnSize = 110;
    const uint64_t GuestAddress = Arguments->Argument[2];
    const uint64_t GuestAddressLength = Arguments->Argument[3];
    AcceptLastDescriptor = Descriptor;
    AcceptLastDescriptorOwned = OwnedDescriptors.contains(Descriptor);
    AcceptLastAcceptedDescriptor = -1;
    AcceptLastLinuxError = 0;
    AcceptLastFailureReason = AcceptFailureReason::None;
    if (!AcceptLastDescriptorOwned || Descriptor != ListenLastDescriptor
        || ListenSuccessCount == 0) {
      AcceptLastLinuxError = EBADF;
      AcceptLastFailureReason = AcceptFailureReason::NonListeningOrUnownedDescriptor;
      return static_cast<uint64_t>(-EBADF);
    }
    if (!Contains(GuestAddress, LinuxSockaddrUnSize)
        || !Contains(GuestAddressLength, sizeof(uint32_t))) {
      AcceptLastLinuxError = EFAULT;
      AcceptLastFailureReason = AcceptFailureReason::UnreadableAddressOrLength;
      return static_cast<uint64_t>(-EFAULT);
    }
    uint32_t InputAddressLength {};
    std::memcpy(
      &InputAddressLength,
      reinterpret_cast<const void*>(GuestAddressLength),
      sizeof(InputAddressLength));
    AcceptLastInputAddressLength = InputAddressLength;
    if (InputAddressLength != LinuxSockaddrUnSize) {
      AcceptLastLinuxError = EINVAL;
      AcceptLastFailureReason = AcceptFailureReason::UnmeasuredAddressLength;
      return static_cast<uint64_t>(-EINVAL);
    }

    sockaddr_un HostAddress {};
    socklen_t HostAddressLength = sizeof(HostAddress);
    const int AcceptedDescriptor = accept(
      Descriptor,
      reinterpret_cast<sockaddr*>(&HostAddress),
      &HostAddressLength);
    if (AcceptedDescriptor == -1) {
      const int LinuxError = TranslateHostSocketErrorToLinux(errno);
      AcceptLastLinuxError = LinuxError;
      AcceptLastFailureReason = AcceptFailureReason::HostAcceptFailed;
      return static_cast<uint64_t>(-LinuxError);
    }
    AcceptLastHostAddressLength = HostAddressLength;
    if (HostAddressLength < offsetof(sockaddr_un, sun_path)
        || HostAddress.sun_family != AF_UNIX) {
      close(AcceptedDescriptor);
      AcceptLastLinuxError = EAFNOSUPPORT;
      AcceptLastFailureReason = AcceptFailureReason::UnsupportedHostAddress;
      return static_cast<uint64_t>(-EAFNOSUPPORT);
    }
    const size_t HostPathLength = std::min<size_t>(
      HostAddressLength - offsetof(sockaddr_un, sun_path),
      sizeof(HostAddress.sun_path));
    const uint32_t OutputAddressLength = static_cast<uint32_t>(
      sizeof(LinuxAFUnix) + HostPathLength);
    std::array<uint8_t, LinuxSockaddrUnSize> LinuxAddress {};
    std::memcpy(LinuxAddress.data(), &LinuxAFUnix, sizeof(LinuxAFUnix));
    std::memcpy(
      LinuxAddress.data() + sizeof(LinuxAFUnix),
      HostAddress.sun_path,
      HostPathLength);
    const size_t CopyLength = std::min<size_t>(InputAddressLength, OutputAddressLength);
    std::memcpy(
      reinterpret_cast<void*>(GuestAddress),
      LinuxAddress.data(),
      CopyLength);
    std::memcpy(
      reinterpret_cast<void*>(GuestAddressLength),
      &OutputAddressLength,
      sizeof(OutputAddressLength));
    OwnedDescriptors.insert(AcceptedDescriptor);
    AcceptLastGuestAddressLength = OutputAddressLength;
    AcceptLastAcceptedDescriptor = AcceptedDescriptor;
    ++AcceptSuccessCount;
    return static_cast<uint64_t>(AcceptedDescriptor);
  }

  void Stop(FEXCore::Core::CpuStateFrame* Frame) const {
    if (StopAddress != 0 && Frame != nullptr) {
      Frame->State.rip = StopAddress;
    }
  }

  void RecordPostRegistryTemporarySyscall(
    const FEXCore::HLE::SyscallArguments* Arguments,
    uint64_t Number) {
    if (!RegistryTemporaryTraceActive || Arguments == nullptr
        || RegistryTemporarySyscallTraceCount >= RegistryTemporarySyscallTrace.size()) {
      return;
    }
    auto& Entry = RegistryTemporarySyscallTrace[RegistryTemporarySyscallTraceCount++];
    Entry.Number = Number;
    for (size_t Index = 0; Index < Entry.Arguments.size(); ++Index) {
      Entry.Arguments[Index] = Arguments->Argument[Index + 1];
    }
    const int Descriptor = static_cast<int>(Entry.Arguments[0]);
    Entry.Argument1DescriptorOwned = OwnedDescriptors.contains(Descriptor);
    Entry.Argument1MatchesRegistryTemporary = RegistryTemporaryDescriptors.contains(Descriptor);
    if (!Entry.Argument1DescriptorOwned) {
      return;
    }
    const int SavedHostError = errno;
    struct stat DescriptorStat {};
    const int StatResult = fstat(Descriptor, &DescriptorStat);
    errno = SavedHostError;
    if (StatResult != 0) {
      return;
    }
    Entry.Argument1DescriptorRegular = S_ISREG(DescriptorStat.st_mode);
    Entry.Argument1DescriptorFIFO = S_ISFIFO(DescriptorStat.st_mode);
    Entry.Argument1DescriptorSocket = S_ISSOCK(DescriptorStat.st_mode);
  }

  bool MaybeStopAtPostSessionSyscallBoundary(
    FEXCore::Core::CpuStateFrame* Frame,
    const FEXCore::HLE::SyscallArguments* Arguments,
    uint64_t Number) {
    if (SessionMappingWriteCompleted
        && PostSessionSyscallDiagnosticCallCount >= 14
        && PostSessionLiveTraceCount < PostSessionLiveTrace.size()) {
      PostSessionLiveTrace[PostSessionLiveTraceCount++] = Number;
      dprintf(
        STDERR_FILENO,
        "DIAGNOSTIC post-session-count=%llu syscall=%llu limit=%llu\n",
        static_cast<unsigned long long>(PostSessionSyscallDiagnosticCallCount),
        static_cast<unsigned long long>(Number),
        static_cast<unsigned long long>(PostSessionSyscallDiagnosticLimit));
    }
    if (PostSessionSyscallDiagnosticLimitSeen) {
      Stop(Frame);
      ++PostSessionDiagnosticStopSignalRequestCount;
      if (DarwinDiagnosticThreadStopHandler::Request() != 0) {
        PostSessionDiagnosticStopSignalLastHostError = errno;
      }
      return true;
    }
    if (PostSessionSyscallDiagnosticLimit == 0 || !SessionMappingWriteCompleted) {
      return false;
    }
    ++PostSessionSyscallDiagnosticCallCount;
    if (PostSessionSyscallDiagnosticCallCount >= PostSessionSyscallDiagnosticLimit) {
      PostSessionBoundarySyscallNumber = Number;
      const uint64_t Argument1 = Arguments == nullptr ? 0 : Arguments->Argument[1];
      PostSessionBoundaryArgument1Class = Arguments == nullptr
        ? "unavailable"
        : (Argument1 == 0
          ? "null"
          : (Contains(Argument1, sizeof(uint64_t)) ? "contained-u64" : "outside"));
      if (Arguments != nullptr && Number == EpollPWait2Syscall) {
        PostSessionBoundaryEpollPWait2Seen = true;
        const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestEvents = Arguments->Argument[2];
        const int64_t MaxEvents = static_cast<int64_t>(Arguments->Argument[3]);
        const uint64_t GuestTimeout = Arguments->Argument[4];
        const uint64_t GuestSignalMask = Arguments->Argument[5];
        const uint64_t SignalSetSize = Arguments->Argument[6];
        PostSessionBoundaryEpollPWait2Descriptor = EpollDescriptor;
        PostSessionBoundaryEpollPWait2DescriptorOwned = OwnedDescriptors.contains(EpollDescriptor);
        PostSessionBoundaryEpollPWait2DescriptorKnown = EpollDescriptors.contains(EpollDescriptor);
        PostSessionBoundaryEpollPWait2MaxEvents = MaxEvents;
        const bool EventSpanValid = MaxEvents > 0
          && MaxEvents <= 4096
          && static_cast<uint64_t>(MaxEvents)
            <= std::numeric_limits<uint64_t>::max() / sizeof(LinuxEpollEvent);
        const uint64_t EventSpan = EventSpanValid
          ? static_cast<uint64_t>(MaxEvents) * sizeof(LinuxEpollEvent)
          : 0;
        PostSessionBoundaryEpollPWait2EventsClass = GuestEvents == 0
          ? "zero"
          : (EventSpanValid && Contains(GuestEvents, EventSpan)
              ? "guest-memory-full-span"
              : (Contains(GuestEvents, sizeof(LinuxEpollEvent))
                  ? "guest-memory-first-event"
                  : "scalar-or-outside"));
        PostSessionBoundaryEpollPWait2TimeoutClass = GuestTimeout == 0
          ? "zero"
          : (Contains(GuestTimeout, sizeof(LinuxTimespec64))
              ? "guest-memory"
              : "scalar-or-outside");
        if (Contains(GuestTimeout, sizeof(LinuxTimespec64))) {
          LinuxTimespec64 Timeout {};
          std::memcpy(&Timeout, reinterpret_cast<const void*>(GuestTimeout), sizeof(Timeout));
          PostSessionBoundaryEpollPWait2TimeoutReadable = true;
          PostSessionBoundaryEpollPWait2TimeoutSeconds = Timeout.Seconds;
          PostSessionBoundaryEpollPWait2TimeoutNanoseconds = Timeout.Nanoseconds;
        }
        PostSessionBoundaryEpollPWait2SignalSetSize = SignalSetSize;
        const bool SignalMaskSpanValid = SignalSetSize > 0 && SignalSetSize <= 128;
        PostSessionBoundaryEpollPWait2SignalMaskClass = GuestSignalMask == 0
          ? "zero"
          : (SignalMaskSpanValid && Contains(GuestSignalMask, SignalSetSize)
              ? "guest-memory"
              : "scalar-or-outside");
      }
      if (Arguments != nullptr && Number == EpollWaitSyscall) {
        PostSessionBoundaryEpollWaitSeen = true;
        const int EpollDescriptor = static_cast<int>(Arguments->Argument[1]);
        const uint64_t GuestEvents = Arguments->Argument[2];
        const int64_t MaxEvents = static_cast<int64_t>(Arguments->Argument[3]);
        PostSessionBoundaryEpollWaitDescriptor = EpollDescriptor;
        PostSessionBoundaryEpollWaitDescriptorOwned = OwnedDescriptors.contains(EpollDescriptor);
        PostSessionBoundaryEpollWaitDescriptorKnown = EpollDescriptors.contains(EpollDescriptor);
        PostSessionBoundaryEpollWaitMaxEvents = MaxEvents;
        const bool EventSpanValid = MaxEvents > 0
          && MaxEvents <= 4096
          && static_cast<uint64_t>(MaxEvents)
            <= std::numeric_limits<uint64_t>::max() / sizeof(LinuxEpollEvent);
        const uint64_t EventSpan = EventSpanValid
          ? static_cast<uint64_t>(MaxEvents) * sizeof(LinuxEpollEvent)
          : 0;
        PostSessionBoundaryEpollWaitEventsClass = GuestEvents == 0
          ? "zero"
          : (EventSpanValid && Contains(GuestEvents, EventSpan)
              ? "guest-memory-full-span"
              : (Contains(GuestEvents, sizeof(LinuxEpollEvent))
                  ? "guest-memory-first-event"
                  : "scalar-or-outside"));
        PostSessionBoundaryEpollWaitTimeout = static_cast<int32_t>(Arguments->Argument[4]);
      }
      PostSessionSyscallDiagnosticLimitSeen = true;
      Stop(Frame);
      ++PostSessionDiagnosticStopSignalRequestCount;
      if (DarwinDiagnosticThreadStopHandler::Request() != 0) {
        PostSessionDiagnosticStopSignalLastHostError = errno;
      }
      return true;
    }
    return false;
  }

  bool Contains(uint64_t Address, uint64_t Size) const {
    return Address >= GuestBase && Address + Size >= Address && Address + Size <= GuestBase + GuestSize;
  }

  void* HostPointerForGuestRange(
    uint64_t Address,
    uint64_t Size,
    int RequiredProtection) const {
    if (Size == 0) {
      return nullptr;
    }
    if (Contains(Address, Size)) {
      return reinterpret_cast<void*>(Address);
    }
    if (LowMemoryBiasModeEnabled && LowGuestShadow != nullptr) {
      if (void* Pointer = LowGuestShadow->HostPointerForMappedLogicalRange(
            Address, Size, RequiredProtection)) {
        return Pointer;
      }
    }
    if (HighMemoryRegionModeEnabled && HighGuestSparse != nullptr) {
      return HighGuestSparse->HostPointerForMappedLogicalRange(
        Address, Size, RequiredProtection);
    }
    return nullptr;
  }

  void RecordHighMMap(
    uint64_t Address,
    uint64_t Length,
    uint64_t ArenaEnd,
    uint64_t Protection,
    uint64_t Flags,
    int Descriptor,
    uint64_t Offset) {
    if (!ContainsMMapArena(Address, Length)) {
      return;
    }
    if (HighMMapRecordCount >= HighMMapRecords.size()) {
      HighMMapRecordOverflow = true;
      return;
    }
    const auto [DescriptorPathClass, DescriptorGuestPath] =
      DescribeMappingDescriptor(Descriptor, (Flags & 0x20) != 0);
    HighMMapRecords[HighMMapRecordCount++] = HighMMapRecord {
      .Address = Address,
      .Length = Length,
      .ArenaEnd = ArenaEnd,
      .Protection = Protection,
      .Flags = Flags,
      .Offset = Offset,
      .Descriptor = Descriptor,
      .DescriptorPathClass = DescriptorPathClass,
      .DescriptorGuestPath = DescriptorGuestPath,
      .Active = true,
    };
  }

  void RecordLowMMap(
    uint64_t Address,
    uint64_t Length,
    uint64_t Protection,
    uint64_t Flags,
    int Descriptor,
    uint64_t Offset) {
    if (Length == 0 || Address >= LowGuestAddressLimit
        || Length > LowGuestAddressLimit - Address) {
      return;
    }
    if (LowMMapRecordCount >= LowMMapRecords.size()) {
      LowMMapRecordOverflow = true;
      return;
    }
    const auto [DescriptorPathClass, DescriptorGuestPath] =
      DescribeMappingDescriptor(Descriptor, (Flags & 0x20) != 0);
    LowMMapRecords[LowMMapRecordCount++] = LowMMapRecord {
      .Address = Address,
      .Length = Length,
      .Protection = Protection,
      .Flags = Flags,
      .Offset = Offset,
      .Descriptor = Descriptor,
      .DescriptorPathClass = DescriptorPathClass,
      .DescriptorGuestPath = DescriptorGuestPath,
    };
  }

  std::pair<std::string, std::string> DescribeMappingDescriptor(
    int Descriptor,
    bool Anonymous) const {
    if (Anonymous) {
      return {"anonymous", "none"};
    }
    if (!OwnedDescriptors.contains(Descriptor)) {
      return {"unowned", "none"};
    }
    std::array<char, 4096> DescriptorPath {};
    if (fcntl(Descriptor, F_GETPATH, DescriptorPath.data()) != 0) {
      return {
        ReceivedSCMRightsDescriptors.contains(Descriptor)
          ? "scm-rights-unresolved"
          : "owned-unresolved",
        "none",
      };
    }
    const std::string HostPath {DescriptorPath.data()};
    const std::string GuestPath = HostPath == RootFS
      ? "/"
      : (HostPath.starts_with(RootFS + '/')
          ? HostPath.substr(RootFS.size())
          : std::string {});
    if (GuestPath.empty() || !IsSafeDiagnosticGuestPath(GuestPath)) {
      return {"outside-rootfs", "redacted"};
    }
    return {"rootfs-file", GuestPath};
  }

  bool ContainsMMapArena(uint64_t Address, uint64_t Size) const {
    return Address >= MMapArenaBase && Address + Size >= Address && Address + Size <= MMapArenaLimit;
  }

  std::optional<std::string> ReadGuestPath(uint64_t Address) const {
    constexpr size_t MaximumPathLength = 4096;
    if (Contains(Address, 1)) {
      const size_t Available = static_cast<size_t>(GuestBase + GuestSize - Address);
      const size_t Limit = std::min(Available, MaximumPathLength);
      const auto* Begin = reinterpret_cast<const char*>(Address);
      const auto* End = static_cast<const char*>(std::memchr(Begin, '\0', Limit));
      if (End == nullptr) {
        return std::nullopt;
      }
      return std::string {Begin, End};
    }

    if (!LowMemoryBiasModeEnabled || LowGuestShadow == nullptr) {
      return std::nullopt;
    }
    std::string Path;
    Path.reserve(128);
    for (size_t Offset = 0; Offset < MaximumPathLength; ++Offset) {
      if (Address > std::numeric_limits<uint64_t>::max() - Offset) {
        return std::nullopt;
      }
      const auto* Character = static_cast<const char*>(
        LowGuestShadow->HostPointerForMappedLogicalRange(
          Address + Offset,
          1,
          PROT_READ));
      if (Character == nullptr) {
        return std::nullopt;
      }
      if (*Character == '\0') {
        return Path;
      }
      Path.push_back(*Character);
    }
    return std::nullopt;
  }

  static bool IsSafeDiagnosticGuestPath(const std::string& GuestPath) {
    if (GuestPath.empty() || GuestPath.size() > 512) {
      return false;
    }
    return std::all_of(GuestPath.begin(), GuestPath.end(), [](unsigned char Character) {
      return (Character >= 'a' && Character <= 'z')
        || (Character >= 'A' && Character <= 'Z')
        || (Character >= '0' && Character <= '9')
        || Character == '/' || Character == '_' || Character == '-'
        || Character == '.' || Character == '+';
    });
  }

  static bool IsSafeIntlNLSDiagnosticPath(const std::string& GuestPath) {
    constexpr std::string_view Basename {"l_intl.nls"};
    return GuestPath.ends_with(Basename) && IsSafeDiagnosticGuestPath(GuestPath);
  }

  bool BeginIntlNLSDiagnostic(
    std::string_view Operation,
    const std::string& GuestPath) {
    if (!IsSafeIntlNLSDiagnosticPath(GuestPath)) {
      return false;
    }
    ++IntlNLSOpenCandidateCount;
    if (IntlNLSOpenCandidatePaths.size() < 8) {
      IntlNLSOpenCandidatePaths.push_back(GuestPath);
    }
    IntlNLSLastOperation = Operation;
    IntlNLSLastHostPathResolved = false;
    IntlNLSLastTargetExists = false;
    IntlNLSLastTargetRegular = false;
    IntlNLSLastLinuxError = 0;
    return true;
  }

  void FinishIntlNLSDiagnostic(
    bool Enabled,
    bool HostPathResolved,
    bool TargetExists,
    bool TargetRegular,
    int64_t LinuxError) {
    if (!Enabled) {
      return;
    }
    IntlNLSLastHostPathResolved = HostPathResolved;
    IntlNLSLastTargetExists = TargetExists;
    IntlNLSLastTargetRegular = TargetRegular;
    IntlNLSLastLinuxError = LinuxError;
  }

  bool IsTemporaryMappingCandidate(
    const std::string& GuestPath,
    uint64_t Flags,
    uint64_t Mode) const {
    constexpr uint64_t LinuxOReadWrite = 0x2;
    constexpr uint64_t LinuxOCreate = 0x40;
    constexpr uint64_t LinuxOExclusive = 0x80;
    constexpr std::string_view Prefix {"tmpmap-"};
    if (Flags != (LinuxOReadWrite | LinuxOCreate | LinuxOExclusive)
        || Mode != 0600 || GuestPath.size() != Prefix.size() + 8
        || !GuestPath.starts_with(Prefix)) {
      return false;
    }
    return std::all_of(
      GuestPath.begin() + static_cast<ptrdiff_t>(Prefix.size()),
      GuestPath.end(),
      [](unsigned char Character) {
        return (Character >= '0' && Character <= '9')
          || (Character >= 'a' && Character <= 'f')
          || (Character >= 'A' && Character <= 'F');
      });
  }

  void RecordTemporaryMappingCandidate(
    const std::string& GuestPath,
    uint64_t Flags,
    uint64_t Mode) {
    if (!IsTemporaryMappingCandidate(GuestPath, Flags, Mode)) {
      return;
    }
    ++TemporaryMappingOpenCandidateCount;
    if (TemporaryMappingFirstCandidatePath == "none") {
      TemporaryMappingFirstCandidatePath = GuestPath;
    }
    TemporaryMappingLastCandidatePath = GuestPath;
  }

  std::optional<std::string> ResolveGuestPath(const std::string& GuestPath) const {
    const std::string EffectivePath = GuestPath.empty()
      ? GuestCurrentWorkingDirectory
      : (GuestPath.front() == '/'
          ? GuestPath
          : GuestCurrentWorkingDirectory + (GuestCurrentWorkingDirectory == "/" ? "" : "/") + GuestPath);

    std::string Normalized;
    size_t Cursor = EffectivePath.front() == '/' ? 1 : 0;
    while (Cursor <= EffectivePath.size()) {
      const size_t Separator = EffectivePath.find('/', Cursor);
      const size_t End = Separator == std::string::npos ? EffectivePath.size() : Separator;
      const std::string_view Component {EffectivePath.data() + Cursor, End - Cursor};
      if (Component == "..") {
        return std::nullopt;
      }
      if (!Component.empty() && Component != ".") {
        Normalized += '/';
        Normalized.append(Component);
      }
      if (Separator == std::string::npos) {
        break;
      }
      Cursor = Separator + 1;
    }

    std::string Candidate = RootFS + Normalized;
    if (access(Candidate.c_str(), F_OK) != 0 && Normalized.starts_with("/lib64/")) {
      Candidate = RootFS + "/usr" + Normalized;
    }
    if (access(Candidate.c_str(), F_OK) == 0) {
      std::array<char, 4096> Canonical {};
      if (realpath(Candidate.c_str(), Canonical.data()) == nullptr) {
        return std::nullopt;
      }
      const std::string Resolved {Canonical.data()};
      if (Resolved != RootFS && !Resolved.starts_with(RootFS + '/')) {
        return std::nullopt;
      }
      Candidate = Resolved;
    }
    return Candidate;
  }

  std::optional<std::string> NormalizeGuestPathWithParents(
    const std::string& GuestPath) const {
    if (GuestPath.empty()) {
      return std::nullopt;
    }
    const std::string EffectivePath = GuestPath.front() == '/'
      ? GuestPath
      : GuestCurrentWorkingDirectory
        + (GuestCurrentWorkingDirectory == "/" ? "" : "/")
        + GuestPath;

    std::vector<std::string_view> Components;
    size_t Cursor = EffectivePath.front() == '/' ? 1 : 0;
    while (Cursor <= EffectivePath.size()) {
      const size_t Separator = EffectivePath.find('/', Cursor);
      const size_t End = Separator == std::string::npos ? EffectivePath.size() : Separator;
      const std::string_view Component {EffectivePath.data() + Cursor, End - Cursor};
      if (Component == "..") {
        if (Components.empty()) {
          return std::nullopt;
        }
        Components.pop_back();
      } else if (!Component.empty() && Component != ".") {
        Components.emplace_back(Component);
      }
      if (Separator == std::string::npos) {
        break;
      }
      Cursor = Separator + 1;
    }

    std::string Normalized {"/"};
    for (size_t Index = 0; Index < Components.size(); ++Index) {
      if (Index != 0) {
        Normalized += '/';
      }
      Normalized.append(Components[Index]);
    }
    return Normalized;
  }

  std::optional<std::string> ResolveGuestPathWithParents(
    const std::string& GuestPath) const {
    const auto Normalized = NormalizeGuestPathWithParents(GuestPath);
    if (!Normalized.has_value()) {
      return std::nullopt;
    }

    std::string Candidate = RootFS + *Normalized;
    if (access(Candidate.c_str(), F_OK) != 0 && Normalized->starts_with("/lib64/")) {
      Candidate = RootFS + "/usr" + *Normalized;
    }
    if (access(Candidate.c_str(), F_OK) != 0) {
      return Candidate;
    }

    std::array<char, 4096> Canonical {};
    if (realpath(Candidate.c_str(), Canonical.data()) == nullptr) {
      return std::nullopt;
    }
    const std::string Resolved {Canonical.data()};
    if (Resolved != RootFS && !Resolved.starts_with(RootFS + '/')) {
      return std::nullopt;
    }
    return Resolved;
  }

  std::optional<std::string> ResolveGuestCreationPath(const std::string& GuestPath) const {
    if (GuestPath.empty() || GuestPath.back() == '/') {
      return std::nullopt;
    }
    const size_t Separator = GuestPath.find_last_of('/');
    const std::string ParentGuestPath = Separator == std::string::npos
      ? "."
      : (Separator == 0 ? "/" : GuestPath.substr(0, Separator));
    const std::string Basename = Separator == std::string::npos
      ? GuestPath
      : GuestPath.substr(Separator + 1);
    if (Basename.empty() || Basename == "." || Basename == "..") {
      return std::nullopt;
    }
    const auto HostParent = ResolveGuestPath(ParentGuestPath);
    if (!HostParent.has_value()) {
      return std::nullopt;
    }
    struct stat ParentStat {};
    if (lstat(HostParent->c_str(), &ParentStat) != 0 || !S_ISDIR(ParentStat.st_mode)) {
      return std::nullopt;
    }
    return *HostParent + (*HostParent == "/" ? "" : "/") + Basename;
  }

  std::optional<std::string> ResolveGuestRelativeSymlink(
    const std::string& GuestTarget,
    const std::string& GuestLink) const {
    if (GuestTarget.empty() || GuestTarget.front() == '/') {
      return std::nullopt;
    }
    const auto HostLink = ResolveGuestCreationPath(GuestLink);
    if (!HostLink.has_value()) {
      return std::nullopt;
    }
    const size_t Separator = HostLink->find_last_of('/');
    const std::string HostParent = Separator == 0
      ? "/"
      : HostLink->substr(0, Separator);
    const std::string CandidateTarget = HostParent + "/" + GuestTarget;
    std::array<char, 4096> CanonicalTarget {};
    if (realpath(CandidateTarget.c_str(), CanonicalTarget.data()) == nullptr) {
      return std::nullopt;
    }
    const std::string ResolvedTarget {CanonicalTarget.data()};
    if (ResolvedTarget != RootFS && !ResolvedTarget.starts_with(RootFS + '/')) {
      return std::nullopt;
    }
    return HostLink;
  }

  static void TraceGuestPath(std::string_view Operation, const std::string& GuestPath) {
    const char* Enabled = getenv("REGRESSION_FLI_TRACE_GUEST_PATHS");
    if (Enabled != nullptr && std::string_view {Enabled} == "1") {
      std::cerr << "TRACE " << Operation << " guest-path=" << GuestPath << '\n';
    }
  }

  static void TraceExecveArgument(uint64_t Index, const std::string& Argument) {
    const char* Enabled = getenv("REGRESSION_FLI_TRACE_EXECVE_ARGUMENTS");
    if (Enabled != nullptr && std::string_view {Enabled} == "1") {
      std::cerr << "TRACE execve argv[" << Index << "]=" << Argument << '\n';
    }
  }

  static std::string ClassifyExecveArgument(uint64_t Index, const std::string& Argument) {
    if (Argument.empty()) {
      return "empty";
    }
    if (Index == 0 && Argument.front() == '/') {
      return "executable-path";
    }
    if (Argument.size() >= 3
        && ((Argument[0] >= 'A' && Argument[0] <= 'Z')
            || (Argument[0] >= 'a' && Argument[0] <= 'z'))
        && Argument[1] == ':'
        && (Argument[2] == '\\' || Argument[2] == '/')) {
      return "windows-path";
    }
    if (Argument.front() == '-' && Argument.size() > 1) {
      return "dash-option";
    }
    if (Argument.front() == '/' && Argument.find('/', 1) == std::string::npos) {
      return "slash-option";
    }
    if (Argument.front() == '/') {
      return "absolute-path";
    }
    return "literal";
  }

  static LinuxX86_64Stat TranslateStat(const struct stat& HostStat) {
    LinuxX86_64Stat GuestStat {};
    GuestStat.Device = static_cast<uint64_t>(HostStat.st_dev);
    GuestStat.Inode = HostStat.st_ino;
    GuestStat.LinkCount = HostStat.st_nlink;
    GuestStat.Mode = HostStat.st_mode;
    GuestStat.UserID = HostStat.st_uid;
    GuestStat.GroupID = HostStat.st_gid;
    GuestStat.SpecialDevice = static_cast<uint64_t>(HostStat.st_rdev);
    GuestStat.Size = HostStat.st_size;
    GuestStat.BlockSize = HostStat.st_blksize;
    GuestStat.BlockCount = HostStat.st_blocks;
    GuestStat.AccessSeconds = HostStat.st_atimespec.tv_sec;
    GuestStat.AccessNanoseconds = HostStat.st_atimespec.tv_nsec;
    GuestStat.ModificationSeconds = HostStat.st_mtimespec.tv_sec;
    GuestStat.ModificationNanoseconds = HostStat.st_mtimespec.tv_nsec;
    GuestStat.ChangeSeconds = HostStat.st_ctimespec.tv_sec;
    GuestStat.ChangeNanoseconds = HostStat.st_ctimespec.tv_nsec;
    return GuestStat;
  }

  uint64_t GuestBase {};
  uint64_t GuestSize {};
  uint64_t ExecutableRangeQueryCount {};
  uint64_t StopAddress {};
  uint64_t InitialProgramBreak {};
  uint64_t CurrentProgramBreak {};
  uint64_t ProgramBreakLimit {};
  uint64_t MMapArenaBase {};
  uint64_t NextMMapAddress {};
  uint64_t MMapArenaLimit {};
  std::string RootFS;
  std::string GuestProgram;
  std::string HostExecutablePath;
  std::string WineServerBridgeDirectory;
  std::string CXAltLoaderGuestSocketPath;
  std::string CXAltLoaderHostSocketPath;
  std::string GuestCurrentWorkingDirectory {"/"};
  uint64_t LowPageAliasBackingAddress {};
  uint64_t LowPageAliasBackingSize {};
  LowGuestShadowMapping* LowGuestShadow {};
  HighGuestSparseMapping* HighGuestSparse {};
  std::set<int> OwnedDescriptors;
  std::set<int> ReceivedSCMRightsDescriptors;
  std::set<int> EpollDescriptors;
  std::set<int> RegistryTemporaryDescriptors;
  std::set<int> CXAltLoaderConnectedDescriptors;
  std::set<std::string> RegistryTemporaryBasenames;
  std::set<int> ClosedStandardDescriptors;
  uint64_t ClearChildTID {};
  uint64_t RobustListHead {};
};

bool WriteAll(int Descriptor, const void* Data, size_t Size) {
  const auto* Bytes = static_cast<const uint8_t*>(Data);
  size_t Written {};
  while (Written < Size) {
    const ssize_t Result = write(Descriptor, Bytes + Written, Size - Written);
    if (Result == -1 && errno == EINTR) {
      continue;
    }
    if (Result <= 0) {
      return false;
    }
    Written += static_cast<size_t>(Result);
  }
  return true;
}

bool WritePrivateFile(const std::string& Path, const std::vector<uint8_t>& Image) {
  const int Descriptor = open(Path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR);
  if (Descriptor == -1) {
    return false;
  }
  const bool Passed = WriteAll(Descriptor, Image.data(), Image.size()) && close(Descriptor) == 0;
  if (!Passed) {
    close(Descriptor);
    unlink(Path.c_str());
  }
  return Passed;
}

bool WritePrivateTextFile(const std::string& Path, std::string_view Text) {
  const int Descriptor = open(Path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR);
  if (Descriptor == -1) {
    return false;
  }
  const bool Passed = WriteAll(Descriptor, Text.data(), Text.size()) && close(Descriptor) == 0;
  if (!Passed) {
    close(Descriptor);
    unlink(Path.c_str());
  }
  return Passed;
}

void Append(std::vector<uint8_t>& Code, std::initializer_list<uint8_t> Bytes) {
  Code.insert(Code.end(), Bytes.begin(), Bytes.end());
}

size_t AppendRel32(std::vector<uint8_t>& Code) {
  const size_t Offset = Code.size();
  Code.resize(Code.size() + sizeof(int32_t));
  return Offset;
}

bool PatchRelative(std::vector<uint8_t>& Code, size_t DisplacementOffset, int64_t Target) {
  const int64_t Origin = static_cast<int64_t>(InterpreterEntryOffset + DisplacementOffset + sizeof(int32_t));
  const int64_t Delta = Target - Origin;
  if (Delta < std::numeric_limits<int32_t>::min() || Delta > std::numeric_limits<int32_t>::max()) {
    return false;
  }
  const int32_t Value = static_cast<int32_t>(Delta);
  std::memcpy(Code.data() + DisplacementOffset, &Value, sizeof(Value));
  return true;
}

std::optional<std::vector<uint8_t>> BuildInterpreterCode() {
  std::vector<uint8_t> Code;
  std::vector<size_t> FailureBranches;

  // Reproduce de forma aislada la decisión ET_DYN exacta del preloader oficial.
  // RBP apunta 0x820 bytes después de la palabra controlada. RAX=0 hace que la
  // carga [RBP + RAX - 0xb18] lea un qword propio situado 0x2f8 bytes antes.
  // Las cuatro instrucciones entre CMP y JE son byte a byte las del preloader.
  Append(Code, {0xB8, 0x00, 0x00, 0x00, 0x00});       // mov eax, 0
  Append(Code, {0x49, 0xBF, 0x11, 0x22, 0x33, 0x44,
                0x55, 0x66, 0x77, 0x88});             // movabs r15, 0x8877665544332211
  Append(Code, {0x48, 0x8D, 0x2D});                   // lea rbp, [rip + test_word + 0x820]
  const size_t ETDynBaseDisplacement = AppendRel32(Code);
  Append(Code, {0x66, 0x83, 0xBD, 0xE0, 0xF7, 0xFF, 0xFF, 0x03}); // cmpw $3, -0x820(rbp)
  Append(Code, {0x4C, 0x8B, 0xB4, 0x05, 0xE8, 0xF4, 0xFF, 0xFF}); // movq -0xb18(rbp,rax), r14
  Append(Code, {0x66, 0x49, 0x0F, 0x6E, 0xC7});       // movq r15, xmm0
  Append(Code, {0x66, 0x49, 0x0F, 0x6E, 0xD6});       // movq r14, xmm2
  Append(Code, {0x66, 0x0F, 0x6C, 0xC2});             // punpcklqdq xmm2, xmm0
  Append(Code, {0x0F, 0x84});                         // je et_dyn_success
  const size_t ETDynSuccessBranch = AppendRel32(Code);
  Append(Code, {0xE9});                               // jmp failure
  FailureBranches.push_back(AppendRel32(Code));
  const size_t ETDynSuccessOffset = Code.size();

  // El intérprete controlado comprueba argc y argv[1] desde la pila Linux.
  Append(Code, {0x48, 0x83, 0x3C, 0x24, 0x02});       // cmp qword ptr [rsp], 2
  Append(Code, {0x0F, 0x85});
  FailureBranches.push_back(AppendRel32(Code));        // jne failure
  Append(Code, {0x48, 0x8B, 0x5C, 0x24, 0x10});       // mov rbx, [rsp + 16]
  Append(Code, {0x80, 0x3B, static_cast<uint8_t>('p')});
  Append(Code, {0x0F, 0x85});
  FailureBranches.push_back(AppendRel32(Code));
  Append(Code, {0x80, 0x7B, 0x08, static_cast<uint8_t>('g')});
  Append(Code, {0x0F, 0x85});
  FailureBranches.push_back(AppendRel32(Code));

  Append(Code, {0xB8, 0x01, 0x00, 0x00, 0x00});       // mov eax, write
  Append(Code, {0xBF, 0x01, 0x00, 0x00, 0x00});       // mov edi, stdout
  Append(Code, {0x48, 0x8D, 0x35});                   // lea rsi, [rip + message]
  const size_t MessageDisplacement = AppendRel32(Code);
  Append(Code, {0xBA, static_cast<uint8_t>(ExpectedOutput.size()), 0x00, 0x00, 0x00});
  Append(Code, {0x0F, 0x05});                         // syscall
  Append(Code, {0x83, 0xF8, static_cast<uint8_t>(ExpectedOutput.size())});
  Append(Code, {0x0F, 0x85});
  FailureBranches.push_back(AppendRel32(Code));

  Append(Code, {0x80, 0x3D});                         // cmp byte ptr [rip + bss], 0
  const size_t BSSDisplacement = AppendRel32(Code);
  Append(Code, {0x00});
  Append(Code, {0x0F, 0x85});
  FailureBranches.push_back(AppendRel32(Code));

  Append(Code, {0xB8, 0x3C, 0x00, 0x00, 0x00});       // mov eax, exit
  Append(Code, {0xBF, 0x2A, 0x00, 0x00, 0x00});       // mov edi, 42
  Append(Code, {0x0F, 0x05, 0xF4});                   // syscall; hlt

  const size_t FailureOffset = Code.size();
  Append(Code, {0xB8, 0x3C, 0x00, 0x00, 0x00});
  Append(Code, {0xBF, 0x63, 0x00, 0x00, 0x00});       // mov edi, 99
  Append(Code, {0x0F, 0x05, 0xF4});

  Code.resize((Code.size() + 7U) & ~size_t {7U}, 0x00);
  const size_t ETDynSourceQwordOffset = Code.size();
  Append(Code, {0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11});
  Code.resize(ETDynSourceQwordOffset + 0x2F8, 0x00);
  const size_t ETDynWordOffset = Code.size();
  Append(Code, {0x03, 0x00});                         // ELF e_type = ET_DYN

  if (!PatchRelative(Code, MessageDisplacement, InterpreterDataOffset)
      || !PatchRelative(Code, BSSDisplacement, InterpreterDataOffset + ExpectedOutput.size())
      || !PatchRelative(Code, ETDynBaseDisplacement,
                        InterpreterEntryOffset + ETDynWordOffset + 0x820)
      || !PatchRelative(Code, ETDynSuccessBranch,
                        InterpreterEntryOffset + ETDynSuccessOffset)) {
    return std::nullopt;
  }
  for (const size_t Branch : FailureBranches) {
    if (!PatchRelative(Code, Branch, InterpreterEntryOffset + FailureOffset)) {
      return std::nullopt;
    }
  }
  return Code;
}

std::vector<uint8_t> BuildMainELF() {
  constexpr uint64_t MainEntryOffset = 0x300;
  constexpr uint64_t InterpreterStringOffset = 0x180;
  std::vector<uint8_t> Image(4096);

  Elf64_Ehdr Header {};
  Header.e_ident[EI_MAG0] = ELFMAG0;
  Header.e_ident[EI_MAG1] = ELFMAG1;
  Header.e_ident[EI_MAG2] = ELFMAG2;
  Header.e_ident[EI_MAG3] = ELFMAG3;
  Header.e_ident[EI_CLASS] = ELFCLASS64;
  Header.e_ident[EI_DATA] = ELFDATA2LSB;
  Header.e_ident[EI_VERSION] = EV_CURRENT;
  Header.e_ident[EI_OSABI] = ELFOSABI_SYSV;
  Header.e_type = ET_DYN;
  Header.e_machine = EM_X86_64;
  Header.e_version = EV_CURRENT;
  Header.e_entry = MainEntryOffset;
  Header.e_phoff = sizeof(Elf64_Ehdr);
  Header.e_ehsize = sizeof(Elf64_Ehdr);
  Header.e_phentsize = sizeof(Elf64_Phdr);
  Header.e_phnum = 2;
  Header.e_shentsize = sizeof(Elf64_Shdr);

  std::array<Elf64_Phdr, 2> ProgramHeaders {};
  ProgramHeaders[0].p_type = PT_LOAD;
  ProgramHeaders[0].p_flags = PF_R | PF_X;
  ProgramHeaders[0].p_filesz = MainEntryOffset + 1;
  ProgramHeaders[0].p_memsz = ProgramHeaders[0].p_filesz;
  ProgramHeaders[0].p_align = 0x1000;
  ProgramHeaders[1].p_type = PT_INTERP;
  ProgramHeaders[1].p_offset = InterpreterStringOffset;
  ProgramHeaders[1].p_vaddr = InterpreterStringOffset;
  ProgramHeaders[1].p_paddr = InterpreterStringOffset;
  ProgramHeaders[1].p_filesz = InterpreterPath.size() + 1;
  ProgramHeaders[1].p_memsz = ProgramHeaders[1].p_filesz;
  ProgramHeaders[1].p_flags = PF_R;
  ProgramHeaders[1].p_align = 1;

  std::memcpy(Image.data(), &Header, sizeof(Header));
  std::memcpy(Image.data() + Header.e_phoff, ProgramHeaders.data(), sizeof(ProgramHeaders));
  std::memcpy(Image.data() + InterpreterStringOffset, InterpreterPath.data(), InterpreterPath.size());
  Image[MainEntryOffset] = 0xF4;
  return Image;
}

std::optional<std::vector<uint8_t>> BuildInterpreterELF() {
  auto Code = BuildInterpreterCode();
  if (!Code) {
    return std::nullopt;
  }
  constexpr uint64_t DataFileOffset = 0x1000;
  std::vector<uint8_t> Image(DataFileOffset + ExpectedOutput.size());

  Elf64_Ehdr Header {};
  Header.e_ident[EI_MAG0] = ELFMAG0;
  Header.e_ident[EI_MAG1] = ELFMAG1;
  Header.e_ident[EI_MAG2] = ELFMAG2;
  Header.e_ident[EI_MAG3] = ELFMAG3;
  Header.e_ident[EI_CLASS] = ELFCLASS64;
  Header.e_ident[EI_DATA] = ELFDATA2LSB;
  Header.e_ident[EI_VERSION] = EV_CURRENT;
  Header.e_ident[EI_OSABI] = ELFOSABI_SYSV;
  Header.e_type = ET_DYN;
  Header.e_machine = EM_X86_64;
  Header.e_version = EV_CURRENT;
  Header.e_entry = InterpreterEntryOffset;
  Header.e_phoff = sizeof(Elf64_Ehdr);
  Header.e_ehsize = sizeof(Elf64_Ehdr);
  Header.e_phentsize = sizeof(Elf64_Phdr);
  Header.e_phnum = 2;
  Header.e_shentsize = sizeof(Elf64_Shdr);

  std::array<Elf64_Phdr, 2> ProgramHeaders {};
  ProgramHeaders[0].p_type = PT_LOAD;
  ProgramHeaders[0].p_flags = PF_R | PF_X;
  ProgramHeaders[0].p_filesz = InterpreterEntryOffset + Code->size();
  ProgramHeaders[0].p_memsz = ProgramHeaders[0].p_filesz;
  ProgramHeaders[0].p_align = 0x1000;
  ProgramHeaders[1].p_type = PT_LOAD;
  ProgramHeaders[1].p_flags = PF_R | PF_W;
  ProgramHeaders[1].p_offset = DataFileOffset;
  ProgramHeaders[1].p_vaddr = InterpreterDataOffset;
  ProgramHeaders[1].p_paddr = InterpreterDataOffset;
  ProgramHeaders[1].p_filesz = ExpectedOutput.size();
  ProgramHeaders[1].p_memsz = 0x1000;
  ProgramHeaders[1].p_align = 0x1000;

  std::memcpy(Image.data(), &Header, sizeof(Header));
  std::memcpy(Image.data() + Header.e_phoff, ProgramHeaders.data(), sizeof(ProgramHeaders));
  std::copy(Code->begin(), Code->end(), Image.begin() + InterpreterEntryOffset);
  std::copy(ExpectedOutput.begin(), ExpectedOutput.end(), Image.begin() + DataFileOffset);
  return Image;
}

class TemporaryDynamicELFs final {
public:
  bool Create() {
    char Pattern[] = "/private/tmp/regression-fli-process-probe.XXXXXX";
    char* Created = mkdtemp(Pattern);
    if (Created == nullptr) {
      return false;
    }
    Root = Created;
    LibDirectory = Root + "/lib64";
    MainPath = Root + "/probe-main";
    InterpreterFile = LibDirectory + "/ld-regression-probe.so";
    if (mkdir(LibDirectory.c_str(), S_IRWXU) == -1) {
      return false;
    }
    auto Interpreter = BuildInterpreterELF();
    return Interpreter && WritePrivateFile(MainPath, BuildMainELF()) && WritePrivateFile(InterpreterFile, *Interpreter);
  }

  ~TemporaryDynamicELFs() {
    if (!InterpreterFile.empty()) {
      unlink(InterpreterFile.c_str());
    }
    if (!MainPath.empty()) {
      unlink(MainPath.c_str());
    }
    if (!LibDirectory.empty()) {
      rmdir(LibDirectory.c_str());
    }
    if (!Root.empty()) {
      rmdir(Root.c_str());
    }
  }

  std::string Root;
  std::string MainPath;

private:
  std::string LibDirectory;
  std::string InterpreterFile;
};

class GuestMapping final {
public:
  explicit GuestMapping(size_t Size = GuestMemorySize)
    : Size {Size} {}

  bool Allocate() {
    Base = mmap(nullptr, Size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return Base != MAP_FAILED;
  }

  ~GuestMapping() {
    if (Base != MAP_FAILED) {
      munmap(Base, Size);
    }
  }

  uint64_t Address() const {
    return reinterpret_cast<uint64_t>(Base);
  }

  bool MakeReadOnly() const {
    return mprotect(Base, Size, PROT_READ) == 0;
  }

private:
  void* Base {MAP_FAILED};
  size_t Size {};
};

class CallRetStackMapping final {
public:
  bool Attach(FEXCore::Core::InternalThreadState* Thread) {
    const long PageSizeResult = sysconf(_SC_PAGESIZE);
    if (Thread == nullptr || PageSizeResult <= 0) {
      return false;
    }
    PageSize = static_cast<size_t>(PageSizeResult);
    AllocationSize = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE + 2 * PageSize;
    Allocation = mmap(nullptr, AllocationSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (Allocation == MAP_FAILED) {
      return false;
    }
    auto* Base = static_cast<uint8_t*>(Allocation) + PageSize;
    if (mprotect(Base, FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE, PROT_READ | PROT_WRITE) != 0) {
      munmap(Allocation, AllocationSize);
      Allocation = MAP_FAILED;
      return false;
    }
    Thread->CallRetStackBase = Base;
    Thread->CurrentFrame->State.callret_sp = reinterpret_cast<uint64_t>(Base)
                                              + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE / 4;
    return true;
  }

  ~CallRetStackMapping() {
    if (Allocation != MAP_FAILED) {
      munmap(Allocation, AllocationSize);
    }
  }

private:
  void* Allocation {MAP_FAILED};
  size_t AllocationSize {};
  size_t PageSize {};
};

bool PReadAll(int Descriptor, void* Data, size_t Size, off_t Offset) {
  auto* Bytes = static_cast<uint8_t*>(Data);
  size_t Read {};
  while (Read < Size) {
    const ssize_t Result = pread(Descriptor, Bytes + Read, Size - Read, Offset + static_cast<off_t>(Read));
    if (Result == -1 && errno == EINTR) {
      continue;
    }
    if (Result <= 0) {
      return false;
    }
    Read += static_cast<size_t>(Result);
  }
  return true;
}

bool MapELF(const ELFParser& Parser, uint64_t GuestBase, uint64_t GuestSize, uint64_t LoadBase, size_t* SegmentCount) {
  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_LOAD) {
      continue;
    }
    const uint64_t Destination = LoadBase + Header.p_vaddr;
    if (Header.p_memsz < Header.p_filesz || Destination < GuestBase
        || Destination + Header.p_memsz < Destination
        || Destination + Header.p_memsz > GuestBase + GuestSize) {
      return false;
    }
    std::memset(reinterpret_cast<void*>(Destination), 0, static_cast<size_t>(Header.p_memsz));
    if (Header.p_filesz != 0
        && !PReadAll(Parser.fd, reinterpret_cast<void*>(Destination), static_cast<size_t>(Header.p_filesz), Header.p_offset)) {
      return false;
    }
    ++*SegmentCount;
  }
  return true;
}

struct StackResult final {
  uint64_t Pointer {};
  bool Valid {};
};

StackResult BuildInitialStack(uint64_t GuestBase, const ELFParser& Main, uint64_t MainBase, uint64_t InterpreterBase) {
  const uint64_t Strings = GuestBase + StackStringsOffset;
  const std::string Argv0 = "probe-main";
  const std::string Environment = "FLI_PROBE=1";
  auto* StringData = reinterpret_cast<char*>(Strings);
  std::memcpy(StringData, Argv0.c_str(), Argv0.size() + 1);
  const uint64_t Argv0Address = Strings;
  const uint64_t Argv1Address = Argv0Address + Argv0.size() + 1;
  std::memcpy(reinterpret_cast<void*>(Argv1Address), ExpectedArgument.data(), ExpectedArgument.size());
  *reinterpret_cast<char*>(Argv1Address + ExpectedArgument.size()) = '\0';
  const uint64_t EnvironmentAddress = Argv1Address + ExpectedArgument.size() + 1;
  std::memcpy(reinterpret_cast<void*>(EnvironmentAddress), Environment.c_str(), Environment.size() + 1);

  std::vector<uint64_t> Words {
    2,
    Argv0Address,
    Argv1Address,
    0,
    EnvironmentAddress,
    0,
    3, MainBase + Main.ehdr.e_phoff,                  // AT_PHDR
    4, sizeof(Elf64_Phdr),                            // AT_PHENT
    5, Main.ehdr.e_phnum,                             // AT_PHNUM
    6, 4096,                                          // AT_PAGESZ
    7, InterpreterBase,                               // AT_BASE
    9, MainBase + Main.ehdr.e_entry,                  // AT_ENTRY
    0, 0,                                             // AT_NULL
  };
  const uint64_t StackPointer = (GuestBase + StackOffset) & ~uint64_t {0xF};
  std::memcpy(reinterpret_cast<void*>(StackPointer), Words.data(), Words.size() * sizeof(uint64_t));
  const bool Valid = *reinterpret_cast<const uint64_t*>(StackPointer) == 2
                  && std::strcmp(reinterpret_cast<const char*>(Argv1Address), ExpectedArgument.data()) == 0;
  return {StackPointer, Valid};
}

StackResult BuildRealInitialStack(
  uint64_t GuestBase,
  const ELFParser& Main,
  uint64_t MainBase,
  uint64_t InterpreterBase,
  std::string_view GuestProgram,
  const std::vector<std::string>& GuestArguments,
  bool IncludeWineLoaderNoExec,
  bool IncludeWineArchWow64,
  bool IncludeBindNow,
  std::string_view CXAltLoaderSocket) {
  constexpr std::array<uint64_t, 2> RandomWords {
    0x5245475245535349ULL,
    0x4F4E2D464C492D31ULL,
  };
  const std::string Argv0 {GuestProgram};
  const std::string Environment = "LC_ALL=C";
  const std::string HomeEnvironment = "HOME=/home/regression";
  const std::string WineLoaderNoExecEnvironment = "WINELOADERNOEXEC=1";
  const std::string WineArchWow64Environment = "WINEARCH=wow64";
  const std::string BindNowEnvironment = "LD_BIND_NOW=1";
  const std::string CXAltLoaderEnvironment = CXAltLoaderSocket.empty()
    ? std::string {}
    : "CX_ALT_LOADER_SOCKET=" + std::string {CXAltLoaderSocket};
  const std::string Platform = "x86_64";
  uint64_t Cursor = GuestBase + RealStackStringsOffset;

  const auto CopyString = [&Cursor](const std::string& Value) {
    const uint64_t Address = Cursor;
    std::memcpy(reinterpret_cast<void*>(Address), Value.c_str(), Value.size() + 1);
    Cursor += Value.size() + 1;
    return Address;
  };

  const uint64_t Argv0Address = CopyString(Argv0);
  std::vector<uint64_t> ArgumentAddresses;
  ArgumentAddresses.reserve(GuestArguments.size());
  for (const auto& Argument : GuestArguments) {
    ArgumentAddresses.push_back(CopyString(Argument));
  }
  const uint64_t EnvironmentAddress = CopyString(Environment);
  const uint64_t HomeEnvironmentAddress = CopyString(HomeEnvironment);
  const uint64_t WineLoaderNoExecEnvironmentAddress = IncludeWineLoaderNoExec
    ? CopyString(WineLoaderNoExecEnvironment)
    : 0;
  const uint64_t WineArchWow64EnvironmentAddress = IncludeWineArchWow64
    ? CopyString(WineArchWow64Environment)
    : 0;
  const uint64_t BindNowEnvironmentAddress = IncludeBindNow
    ? CopyString(BindNowEnvironment)
    : 0;
  const uint64_t CXAltLoaderEnvironmentAddress = !CXAltLoaderEnvironment.empty()
    ? CopyString(CXAltLoaderEnvironment)
    : 0;
  const uint64_t PlatformAddress = CopyString(Platform);
  Cursor = (Cursor + 15) & ~uint64_t {15};
  const uint64_t RandomAddress = Cursor;
  std::memcpy(reinterpret_cast<void*>(RandomAddress), RandomWords.data(), sizeof(RandomWords));

  std::vector<uint64_t> Words;
  Words.reserve(6 + ArgumentAddresses.size() + 2 * 18);
  Words.push_back(1 + ArgumentAddresses.size());
  Words.push_back(Argv0Address);
  Words.insert(Words.end(), ArgumentAddresses.begin(), ArgumentAddresses.end());
  Words.push_back(0);
  Words.push_back(EnvironmentAddress);
  Words.push_back(HomeEnvironmentAddress);
  if (IncludeWineLoaderNoExec) {
    Words.push_back(WineLoaderNoExecEnvironmentAddress);
  }
  if (IncludeWineArchWow64) {
    Words.push_back(WineArchWow64EnvironmentAddress);
  }
  if (IncludeBindNow) {
    Words.push_back(BindNowEnvironmentAddress);
  }
  if (!CXAltLoaderEnvironment.empty()) {
    Words.push_back(CXAltLoaderEnvironmentAddress);
  }
  Words.push_back(0);
  Words.insert(Words.end(), {
    3, MainBase + Main.ehdr.e_phoff,                  // AT_PHDR
    4, sizeof(Elf64_Phdr),                            // AT_PHENT
    5, Main.ehdr.e_phnum,                             // AT_PHNUM
    6, 4096,                                          // AT_PAGESZ
    7, InterpreterBase,                               // AT_BASE
    8, 0,                                             // AT_FLAGS
    9, MainBase + Main.ehdr.e_entry,                  // AT_ENTRY
    11, getuid(),                                     // AT_UID
    12, geteuid(),                                    // AT_EUID
    13, getgid(),                                     // AT_GID
    14, getegid(),                                    // AT_EGID
    16, 0,                                            // AT_HWCAP
    17, 100,                                          // AT_CLKTCK
    23, 0,                                            // AT_SECURE
    24, PlatformAddress,                              // AT_PLATFORM
    25, RandomAddress,                                // AT_RANDOM
    26, 0,                                            // AT_HWCAP2
    31, Argv0Address,                                 // AT_EXECFN
    51, 2048,                                         // AT_MINSIGSTKSZ
    0, 0,                                             // AT_NULL
  });
  const uint64_t StackPointer = (GuestBase + RealStackOffset) & ~uint64_t {0xF};
  std::memcpy(reinterpret_cast<void*>(StackPointer), Words.data(), Words.size() * sizeof(uint64_t));
  const bool Valid = *reinterpret_cast<const uint64_t*>(StackPointer) == 1
                  + GuestArguments.size()
                  && std::strcmp(reinterpret_cast<const char*>(Argv0Address), Argv0.c_str()) == 0
                  && std::strcmp(reinterpret_cast<const char*>(PlatformAddress), Platform.c_str()) == 0
                  && *reinterpret_cast<const uint64_t*>(RandomAddress) == RandomWords[0];
  return {StackPointer, Valid};
}

bool ELFHasZeroedBSS(const ELFParser& Parser, uint64_t LoadBase) {
  bool FoundBSS {};
  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_LOAD || Header.p_memsz <= Header.p_filesz) {
      continue;
    }
    FoundBSS = true;
    const auto* Begin = reinterpret_cast<const uint8_t*>(LoadBase + Header.p_vaddr + Header.p_filesz);
    const size_t Size = static_cast<size_t>(Header.p_memsz - Header.p_filesz);
    if (!std::all_of(Begin, Begin + Size, [](uint8_t Value) { return Value == 0; })) {
      return false;
    }
  }
  return FoundBSS;
}

std::optional<uint64_t> ELFProgramBreak(const ELFParser& Parser, uint64_t LoadBase) {
  constexpr uint64_t LinuxPageSize = 4096;
  uint64_t HighestEnd {};
  for (const auto& Header : Parser.phdrs) {
    if (Header.p_type != PT_LOAD || Header.p_vaddr + Header.p_memsz < Header.p_vaddr) {
      continue;
    }
    HighestEnd = std::max(HighestEnd, LoadBase + Header.p_vaddr + Header.p_memsz);
  }
  if (HighestEnd == 0 || HighestEnd > std::numeric_limits<uint64_t>::max() - (LinuxPageSize - 1)) {
    return std::nullopt;
  }
  return (HighestEnd + LinuxPageSize - 1) & ~(LinuxPageSize - 1);
}

const char* KnownSyscallName(uint64_t Number) {
  switch (Number) {
  case 0: return "read";
  case 2: return "open";
  case 3: return "close";
  case 4: return "stat";
  case 5: return "fstat";
  case 7: return "poll";
  case 9: return "mmap";
  case 10: return "mprotect";
  case 11: return "munmap";
  case 12: return "brk";
  case 13: return "rt_sigaction";
  case 14: return "rt_sigprocmask";
  case 16: return "ioctl";
  case 17: return "pread64";
  case 18: return "pwrite64";
  case 20: return "writev";
  case 21: return "access";
  case 32: return "dup";
  case 39: return "getpid";
  case 41: return "socket";
  case 42: return "connect";
  case 43: return "accept";
  case 46: return "sendmsg";
  case 47: return "recvmsg";
  case 48: return "shutdown";
  case 49: return "bind";
  case 50: return "listen";
  case 53: return "socketpair";
  case 55: return "getsockopt";
  case 56: return "clone";
  case 59: return "execve";
  case 61: return "wait4";
  case 63: return "uname";
  case 54: return "setsockopt";
  case 131: return "sigaltstack";
  case 186: return "gettid";
  case 72: return "fcntl";
  case 77: return "ftruncate";
  case 79: return "getcwd";
  case 80: return "chdir";
  case 81: return "fchdir";
  case 83: return "mkdir";
  case 87: return "unlink";
  case 88: return "symlink";
  case 89: return "readlink";
  case 90: return "chmod";
  case 95: return "umask";
  case 96: return "gettimeofday";
  case 99: return "sysinfo";
  case 102: return "getuid";
  case 138: return "fstatfs";
  case 140: return "getpriority";
  case 141: return "setpriority";
  case 157: return "prctl";
  case 158: return "arch_prctl";
  case 204: return "sched_getaffinity";
  case 213: return "epoll_create";
  case 217: return "getdents64";
  case 218: return "set_tid_address";
  case 228: return "clock_gettime";
  case 230: return "clock_nanosleep";
  case 233: return "epoll_ctl";
  case 234: return "tgkill";
  case 257: return "openat";
  case 262: return "newfstatat";
  case 273: return "set_robust_list";
  case 293: return "pipe2";
  case 302: return "prlimit64";
  case 318: return "getrandom";
  case 319: return "memfd_create";
  case 323: return "userfaultfd";
  case 334: return "rseq";
  case 435: return "clone3";
  case 439: return "faccessat2";
  case 449: return "futex_waitv";
  default: return "unknown";
  }
}

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

bool IsSafeGuestProgram(std::string_view GuestProgram) {
  if (GuestProgram.size() < 2 || GuestProgram.front() != '/') {
    return false;
  }
  size_t Cursor = 1;
  while (Cursor <= GuestProgram.size()) {
    const size_t Separator = GuestProgram.find('/', Cursor);
    const size_t End = Separator == std::string_view::npos ? GuestProgram.size() : Separator;
    const std::string_view Component = GuestProgram.substr(Cursor, End - Cursor);
    if (Component.empty() || Component == "." || Component == "..") {
      return false;
    }
    if (!std::all_of(Component.begin(), Component.end(), [](char Character) {
          return (Character >= 'a' && Character <= 'z')
              || (Character >= 'A' && Character <= 'Z')
              || (Character >= '0' && Character <= '9')
              || Character == '.' || Character == '_' || Character == '-' || Character == '+';
        })) {
      return false;
    }
    if (Separator == std::string_view::npos) {
      break;
    }
    Cursor = Separator + 1;
  }
  return true;
}

int RunRealRootFS(
  const std::string& RootFS,
  std::string_view GuestProgram,
  std::string_view GuestComponentKind,
  const std::vector<std::string>& GuestArguments,
  bool InitialWineCommandLine,
  bool WineArchWow64,
  const std::string& PrivateStderrOutput,
  const std::string& PrivateIRDumpDirectory,
  bool DisassembleHostBlocks,
  bool InstrumentLowPageAlias,
  bool InstrumentLowMemoryBias,
  bool InstrumentHighMemoryRegion,
  bool InstrumentVForkChild,
  bool InstrumentVForkParent,
  bool InstrumentVForkParentProcessBridge,
  bool InstrumentVForkParentWineServerBridge,
  const std::string& HostExecutablePath,
  const std::string& WineServerBridgeDirectory,
  bool GuestBindNow,
  const std::string& CXAltLoaderSocket,
  const std::string& CXAltLoaderHostSocket,
  uint64_t DiagnosticPostSessionSyscallLimit) {
  if (!IsSafeGuestProgram(GuestProgram)) {
    std::cerr << "La ruta del ejecutable huésped no es absoluta y normalizada.\n";
    return 64;
  }
  const bool ProtonWineComponent = GuestComponentKind == "official-proton-wine64";
  const bool ProtonWinePreloaderComponent =
    GuestComponentKind == "official-proton-wine64-preloader";
  const bool ProtonWineServerComponent =
    GuestComponentKind == "official-proton-wineserver";
  const bool OfficialProtonComponent = ProtonWineComponent
    || ProtonWinePreloaderComponent
    || ProtonWineServerComponent;
  const bool IncludeWineLoaderNoExec = ProtonWinePreloaderComponent
    && !InitialWineCommandLine;
  if (GuestComponentKind != "generic" && !OfficialProtonComponent) {
    std::cerr << "El tipo de componente huésped no pertenece al conjunto permitido.\n";
    return 64;
  }
  if (DiagnosticPostSessionSyscallLimit != 0 && !ProtonWineServerComponent) {
    std::cerr << "El límite diagnóstico posterior al session mapping solo admite wineserver oficial.\n";
    return 64;
  }
  std::string CanonicalHostExecutablePath;
  if (InstrumentVForkParentProcessBridge
      || InstrumentVForkParentWineServerBridge) {
    std::array<char, 4096> CanonicalHostExecutableBuffer {};
    struct stat HostExecutableStat {};
    if (realpath(HostExecutablePath.c_str(), CanonicalHostExecutableBuffer.data()) == nullptr
        || lstat(CanonicalHostExecutableBuffer.data(), &HostExecutableStat) != 0
        || !S_ISREG(HostExecutableStat.st_mode)
        || (HostExecutableStat.st_mode & S_IXUSR) == 0) {
      std::cerr << "El puente de proceso vfork exige el helper host regular y ejecutable.\n";
      return 66;
    }
    CanonicalHostExecutablePath = CanonicalHostExecutableBuffer.data();
  }
  std::string CanonicalWineServerBridgeDirectory;
  if (InstrumentVForkParentWineServerBridge) {
    std::array<char, 4096> CanonicalBridgeBuffer {};
    struct stat BridgeStat {};
    constexpr std::string_view PrivateBridgePrefix =
      "/private/tmp/regression-fli-fex-process-probe.";
    if (realpath(WineServerBridgeDirectory.c_str(), CanonicalBridgeBuffer.data()) == nullptr
        || lstat(CanonicalBridgeBuffer.data(), &BridgeStat) != 0
        || !S_ISDIR(BridgeStat.st_mode)
        || BridgeStat.st_uid != getuid()
        || (BridgeStat.st_mode & (S_IRWXG | S_IRWXO)) != 0
        || !std::string_view {CanonicalBridgeBuffer.data()}.starts_with(PrivateBridgePrefix)) {
      std::cerr << "El puente wineserver exige un directorio privado 0700 del build.\n";
      return 66;
    }
    CanonicalWineServerBridgeDirectory = CanonicalBridgeBuffer.data();
  }
  if (ProtonWineComponent
      && GuestProgram != "/opt/proton/files/lib/wine/x86_64-unix/wine64") {
    std::cerr << "El componente Proton Wine64 no usa su ruta invitada canónica.\n";
    return 64;
  }
  if (ProtonWinePreloaderComponent
      && GuestProgram != "/opt/proton/files/lib/wine/x86_64-unix/wine-preloader") {
    std::cerr << "El preloader Proton Wine64 no usa su ruta invitada canónica.\n";
    return 64;
  }
  if (ProtonWineServerComponent
      && GuestProgram != "/opt/proton/files/bin/wineserver") {
    std::cerr << "Wineserver oficial no usa su ruta invitada canónica.\n";
    return 64;
  }
  if (InitialWineCommandLine
      && (!ProtonWinePreloaderComponent || GuestArguments.size() < 2
          || GuestArguments.front()
               != "/opt/proton/files/lib/wine/x86_64-unix/wine")) {
    std::cerr << "La línea inicial de Wine exige preloader, loader y programa oficiales.\n";
    return 64;
  }
  if (WineArchWow64
      && (!ProtonWinePreloaderComponent || GuestArguments.size() < 2
          || GuestArguments.front()
               != "/opt/proton/files/lib/wine/x86_64-unix/wine")) {
    std::cerr << "WINEARCH=wow64 exige preloader, loader y programa oficiales.\n";
    return 64;
  }
  if (CXAltLoaderSocket.empty() != CXAltLoaderHostSocket.empty()) {
    std::cerr << "El socket alternativo exige rutas huésped y host emparejadas.\n";
    return 64;
  }
  if (!CXAltLoaderSocket.empty()
      && (!ProtonWinePreloaderComponent
          || !CXAltLoaderSocket.starts_with("/tmp/")
          || CXAltLoaderSocket.size() >= sizeof(sockaddr_un::sun_path)
          || !IsSafeGuestProgram(CXAltLoaderSocket))) {
    std::cerr << "El socket alternativo exige una ruta huésped segura bajo /tmp.\n";
    return 64;
  }
  if ((InstrumentLowPageAlias || InstrumentLowMemoryBias || InstrumentHighMemoryRegion)
      && !ProtonWinePreloaderComponent) {
    std::cerr << "La instrumentación de memoria exige el preloader Wine64 oficial.\n";
    return 64;
  }
  if (InstrumentLowPageAlias && InstrumentLowMemoryBias) {
    std::cerr << "Los candidatos de alias y shadow bajo son A/B mutuamente excluyentes.\n";
    return 64;
  }
  if (InstrumentHighMemoryRegion && !InstrumentLowMemoryBias) {
    std::cerr << "La ventana alta instrumental exige el shadow bajo de la misma sesión.\n";
    return 64;
  }
  if ((InstrumentVForkChild || InstrumentVForkParent
       || InstrumentVForkParentProcessBridge
       || InstrumentVForkParentWineServerBridge)
      && (!InstrumentLowMemoryBias || !ProtonWinePreloaderComponent)) {
    std::cerr << "La rama vfork instrumental exige el preloader oficial y el shadow bajo.\n";
    return 64;
  }
  const uint64_t VForkModeCount = static_cast<uint64_t>(InstrumentVForkChild)
    + static_cast<uint64_t>(InstrumentVForkParent)
    + static_cast<uint64_t>(InstrumentVForkParentProcessBridge)
    + static_cast<uint64_t>(InstrumentVForkParentWineServerBridge);
  if (VForkModeCount > 1) {
    std::cerr << "Las ramas vfork instrumentales son mutuamente excluyentes.\n";
    return 64;
  }
  if (GuestBindNow
      && (!ProtonWinePreloaderComponent
          || VForkModeCount != 0)) {
    std::cerr << "LD_BIND_NOW diagnóstico exige el preloader oficial sin rama vfork instrumental.\n";
    return 64;
  }
  size_t TotalArgumentBytes {};
  for (const auto& Argument : GuestArguments) {
    if (Argument.size() > 4096 || TotalArgumentBytes > 64 * 1024 - (Argument.size() + 1)) {
      std::cerr << "Los argumentos huéspedes superan el límite aislado de la sonda.\n";
      return 64;
    }
    TotalArgumentBytes += Argument.size() + 1;
  }
  if (GuestArguments.size() > 32) {
    std::cerr << "La sonda admite como máximo 32 argumentos huéspedes.\n";
    return 64;
  }
  std::string CanonicalIRDumpDirectory;
  if (!PrivateIRDumpDirectory.empty()) {
    std::array<char, 4096> CanonicalIRDumpBuffer {};
    struct stat IRDumpStat {};
    if (realpath(PrivateIRDumpDirectory.c_str(), CanonicalIRDumpBuffer.data()) == nullptr
        || lstat(CanonicalIRDumpBuffer.data(), &IRDumpStat) != 0
        || !S_ISDIR(IRDumpStat.st_mode)
        || IRDumpStat.st_uid != getuid()
        || (IRDumpStat.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
      std::cerr << "El directorio privado de IR no existe o no está confinado al usuario.\n";
      return 66;
    }
    CanonicalIRDumpDirectory = CanonicalIRDumpBuffer.data();
  }
  std::array<char, 4096> CanonicalRootBuffer {};
  if (realpath(RootFS.c_str(), CanonicalRootBuffer.data()) == nullptr) {
    std::cerr << "No se pudo resolver el RootFS privado.\n";
    return 66;
  }
  const std::string CanonicalRootFS {CanonicalRootBuffer.data()};
  std::string CanonicalCXAltLoaderHostSocket;
  if (!CXAltLoaderSocket.empty()) {
    constexpr std::string_view PrivateAltLoaderPrefix =
      "/private/tmp/regression-fli-cx-alt-loader.";
    std::array<char, 4096> CanonicalAltLoaderSocketBuffer {};
    struct stat AltLoaderSocketStat {};
    if (realpath(CXAltLoaderHostSocket.c_str(), CanonicalAltLoaderSocketBuffer.data()) == nullptr
        || lstat(CanonicalAltLoaderSocketBuffer.data(), &AltLoaderSocketStat) != 0
        || !S_ISSOCK(AltLoaderSocketStat.st_mode)
        || AltLoaderSocketStat.st_uid != getuid()
        || (AltLoaderSocketStat.st_mode & (S_IRWXG | S_IRWXO)) != 0
        || !std::string_view {CanonicalAltLoaderSocketBuffer.data()}.starts_with(
          PrivateAltLoaderPrefix)
        || std::strlen(CanonicalAltLoaderSocketBuffer.data())
          >= sizeof(sockaddr_un::sun_path)) {
      std::cerr << "El socket alternativo host no es corto, privado o propiedad del usuario.\n";
      return 66;
    }
    CanonicalCXAltLoaderHostSocket = CanonicalAltLoaderSocketBuffer.data();
    const auto Separator = CanonicalCXAltLoaderHostSocket.find_last_of('/');
    const std::string Parent = Separator == std::string::npos
      ? std::string {}
      : CanonicalCXAltLoaderHostSocket.substr(0, Separator);
    struct stat ParentStat {};
    if (Parent.empty() || lstat(Parent.c_str(), &ParentStat) != 0
        || !S_ISDIR(ParentStat.st_mode)
        || ParentStat.st_uid != getuid()
        || (ParentStat.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
      std::cerr << "El directorio del socket alternativo host no es privado 0700.\n";
      return 66;
    }
  }
  const std::string GuestHomePath = CanonicalRootFS + "/home/regression";
  struct stat GuestHomeStat {};
  const bool GuestHomeDirectoryPresent = lstat(GuestHomePath.c_str(), &GuestHomeStat) == 0
    && S_ISDIR(GuestHomeStat.st_mode);
  const std::string GuestWinePrefixPath = GuestHomePath + "/.wine";
  struct stat GuestWinePrefixStat {};
  const bool GuestWinePrefixDirectoryPresent =
    lstat(GuestWinePrefixPath.c_str(), &GuestWinePrefixStat) == 0
    && S_ISDIR(GuestWinePrefixStat.st_mode);
  const std::string RequestedMainPath = CanonicalRootFS + std::string {GuestProgram};
  std::array<char, 4096> CanonicalMainBuffer {};
  if (realpath(RequestedMainPath.c_str(), CanonicalMainBuffer.data()) == nullptr) {
    std::cerr << "El RootFS no contiene el ejecutable huésped solicitado.\n";
    return 66;
  }
  const std::string MainPath {CanonicalMainBuffer.data()};
  struct stat MainStat {};
  if ((MainPath != CanonicalRootFS && !MainPath.starts_with(CanonicalRootFS + '/'))
      || stat(MainPath.c_str(), &MainStat) != 0 || !S_ISREG(MainStat.st_mode)
      || access(MainPath.c_str(), R_OK) != 0) {
    std::cerr << "El ejecutable huésped escapa del RootFS o no es regular y legible.\n";
    return 66;
  }

  ELFParser Main;
  if (!Main.ReadElf(fextl::string {MainPath.c_str()})
      || Main.type != ELFLoader::ELFContainer::TYPE_X86_64
      || Main.ehdr.e_type != ET_DYN) {
    std::cerr << "ELFParser no cargó el ejecutable PIE real x86-64.\n";
    return 70;
  }
  const bool StaticPIE = Main.InterpreterElf.empty();
  if (StaticPIE != ProtonWinePreloaderComponent) {
    std::cerr << "La presencia de PT_INTERP no coincide con el componente declarado.\n";
    return 70;
  }

  ELFParser Interpreter;
  if (!StaticPIE) {
    const std::string InterpreterGuestPath {Main.InterpreterElf.c_str()};
    std::string InterpreterFile = CanonicalRootFS + InterpreterGuestPath;
    if (access(InterpreterFile.c_str(), R_OK) != 0 && InterpreterGuestPath.starts_with("/lib64/")) {
      InterpreterFile = CanonicalRootFS + "/usr" + InterpreterGuestPath;
    }
    if (access(InterpreterFile.c_str(), R_OK) != 0
        || !Interpreter.ReadElf(fextl::string {InterpreterFile.c_str()})
        || Interpreter.type != ELFLoader::ELFContainer::TYPE_X86_64
        || Interpreter.ehdr.e_type != ET_DYN || !Interpreter.InterpreterElf.empty()) {
      std::cerr << "ELFParser no cargó el ld-linux x86-64 real.\n";
      return 70;
    }
  }

  GuestMapping Mapping {RealGuestMemorySize};
  if (!Mapping.Allocate()) {
    std::cerr << "No se pudo reservar el espacio del proceso glibc huésped.\n";
    return 70;
  }
  LowGuestShadowMapping LowGuestShadow;
  if (InstrumentLowMemoryBias && !LowGuestShadow.Allocate()) {
    std::cerr << "No se pudo reservar el shadow lógico bajo de 4 GiB.\n";
    return 70;
  }
  HighGuestSparseMapping HighGuestSparse;
  if (InstrumentHighMemoryRegion && !HighGuestSparse.Allocate()) {
    std::cerr << "No se pudo reservar la ventana huésped alta dispersa.\n";
    return 70;
  }
  const uint64_t GuestBase = Mapping.Address();
  const uint64_t MainBase = GuestBase;
  const uint64_t InterpreterBase = GuestBase + RealInterpreterLoadOffset;
  const uint64_t StopAddress = GuestBase + RealStopOffset;
  const auto InitialProgramBreak = ELFProgramBreak(Main, MainBase);
  size_t SegmentCount {};
  if (!MapELF(Main, GuestBase, RealGuestMemorySize, MainBase, &SegmentCount)
      || (!StaticPIE
          && !MapELF(Interpreter, GuestBase, RealGuestMemorySize, InterpreterBase, &SegmentCount))) {
    std::cerr << "No se pudieron mapear los segmentos ELF reales.\n";
    return 70;
  }
  *reinterpret_cast<uint8_t*>(StopAddress) = 0xF4;
  const bool BSSZeroed = StaticPIE
    ? ELFHasZeroedBSS(Main, MainBase)
    : ELFHasZeroedBSS(Interpreter, InterpreterBase);
  const StackResult Stack = BuildRealInitialStack(
    GuestBase,
    Main,
    MainBase,
    InterpreterBase,
    GuestProgram,
    GuestArguments,
    IncludeWineLoaderNoExec,
    WineArchWow64,
    GuestBindNow,
    CXAltLoaderSocket);
  const uint64_t ProgramBreakLimit = StaticPIE
    ? GuestBase + RealMMapArenaOffset
    : InterpreterBase;
  if (!BSSZeroed || !Stack.Valid || !InitialProgramBreak.has_value()
      || *InitialProgramBreak >= ProgramBreakLimit) {
    std::cerr << "El BSS o la pila inicial del proceso ELF no quedaron válidos.\n";
    return 70;
  }

  FEXCore::HostFeatures Features {};
  Features.DCacheLineSize = 64;
  Features.ICacheLineSize = 64;
  Features.SupportsCacheMaintenanceOps = true;
  Features.CPUMIDRs.emplace_back(0x61000000U);
  ConfigLifetime Config;
  HostDisassemblyLogLifetime HostDisassemblyLog {DisassembleHostBlocks};
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
  if (!CanonicalIRDumpDirectory.empty()) {
    FEXCore::Config::Set(FEXCore::Config::CONFIG_DUMPIR, CanonicalIRDumpDirectory);
    FEXCore::Config::Set(FEXCore::Config::CONFIG_PASSMANAGERDUMPIR, "3");
  }
  if (DisassembleHostBlocks) {
    constexpr uint64_t DisassemblyMode =
      static_cast<uint64_t>(FEXCore::Config::Disassemble::BLOCKS)
      | static_cast<uint64_t>(FEXCore::Config::Disassemble::STATS);
    FEXCore::Config::Set(
      FEXCore::Config::CONFIG_DISASSEMBLE,
      std::to_string(DisassemblyMode));
  }
  ProbeSignalDelegator SignalDelegator;
  ProcessSyscallHandler SyscallHandler {
    GuestBase,
    RealGuestMemorySize,
    StopAddress,
    *InitialProgramBreak,
    ProgramBreakLimit,
    GuestBase + RealMMapArenaOffset,
    GuestBase + RealMMapArenaLimitOffset,
    CanonicalRootFS,
    std::string {GuestProgram},
    InstrumentLowPageAlias,
    InstrumentLowPageAlias ? GuestBase + RealLowPageAliasOffset : 0,
    InstrumentLowPageAlias ? RealLowPageAliasBackingSize : 0,
    InstrumentLowMemoryBias,
    InstrumentLowMemoryBias ? &LowGuestShadow : nullptr,
    InstrumentHighMemoryRegion,
    InstrumentHighMemoryRegion ? &HighGuestSparse : nullptr,
    InstrumentVForkChild,
    InstrumentVForkParent,
    InstrumentVForkParentProcessBridge,
    InstrumentVForkParentWineServerBridge,
    CanonicalHostExecutablePath,
    CanonicalWineServerBridgeDirectory,
    CXAltLoaderSocket,
    CanonicalCXAltLoaderHostSocket,
    DiagnosticPostSessionSyscallLimit,
  };
  auto Context = FEXCore::Context::Context::CreateNewContext(Features);
  if (!Context) {
    std::cerr << "FEXCore no creó el contexto glibc real.\n";
    return 70;
  }
#if defined(REGRESSION_FEXCORE_GUEST_MEMORY_BIAS)
  if (InstrumentLowMemoryBias) {
    Context->SetGuestMemoryAddressBias(
      LowGuestShadow.Bias(),
      LowGuestAddressLimit,
      LowGuestShadow.RedirectGuestPageAddress(),
      LowGuestShadow.RedirectHostPageAddress());
  }
  if (InstrumentHighMemoryRegion) {
    const auto Region = HighGuestSparse.Region();
    if (!Context->SetGuestMemoryAddressRegions(&Region, 1)) {
      std::cerr << "FEXCore rechazó la ventana huésped alta acotada.\n";
      return 70;
    }
  }
#else
  if (InstrumentLowMemoryBias || InstrumentHighMemoryRegion) {
    std::cerr << "La dylib/probe no expone el candidato de sesgo de memoria huésped.\n";
    return 70;
  }
#endif
  Context->EnableExitOnHLT();
  Context->SetSignalDelegator(&SignalDelegator);
  Context->SetSyscallHandler(&SyscallHandler);
  if (!Context->InitCore()) {
    std::cerr << "FEXCore no inicializó el contexto glibc real.\n";
    return 70;
  }

  const uint64_t GuestRIP = StaticPIE
    ? MainBase + Main.ehdr.e_entry
    : InterpreterBase + Interpreter.ehdr.e_entry;
  auto* Thread = Context->CreateThread(GuestRIP, Stack.Pointer);
  if (Thread == nullptr) {
    std::cerr << "FEXCore no creó el hilo ELF real.\n";
    return 70;
  }
  CallRetStackMapping CallRetStack;
  if (!CallRetStack.Attach(Thread)) {
    Context->DestroyThread(Thread);
    std::cerr << "No se pudo inicializar la pila call-ret de FEX.\n";
    return 70;
  }
  std::array<FEXCore::Core::CPUState::gdt_segment, 32> GDT {};
  ConfigureLongMode(Thread, GDT);
  Context->CompileRIP(Thread, GuestRIP);
  DarwinUnalignedAccessHandler UnalignedHandler;
  if (!UnalignedHandler.Attach(
        Thread,
        GuestBase,
        RealGuestMemorySize,
        InstrumentLowMemoryBias ? LowGuestShadow.Bias() : 0,
        InstrumentLowMemoryBias ? LowGuestAddressLimit : 0,
        InstrumentLowMemoryBias ? LowGuestShadow.RedirectHostPageAddress() : 0,
        InstrumentLowMemoryBias ? LowGuestShadow.HostPageBytes() : 0,
        InstrumentHighMemoryRegion ? HighGuestSparse.HostBase() : 0,
        InstrumentHighMemoryRegion ? HighGuestSparse.Size() : 0,
        InstrumentLowMemoryBias ? &LowGuestShadow : nullptr,
        InstrumentHighMemoryRegion ? &HighGuestSparse : nullptr)) {
    Context->DestroyThread(Thread);
    std::cerr << "No se pudo instalar el puente SIGBUS de FEX.\n";
    return 70;
  }
  DarwinDiagnosticThreadStopHandler DiagnosticStopHandler;
  if (DiagnosticPostSessionSyscallLimit != 0
      && !DiagnosticStopHandler.Attach(
        Thread,
        SignalDelegator.GetConfig().ThreadStopHandlerAddress,
        StopAddress)) {
    UnalignedHandler.Reset();
    Context->DestroyThread(Thread);
    std::cerr << "No se pudo instalar la parada diagnóstica aislada de FEX.\n";
    return 70;
  }
  Context->ExecuteThread(Thread);
  const bool DiagnosticStopSignalTriggered = DiagnosticStopHandler.Triggered();
  DiagnosticStopHandler.Reset();
  const uint64_t UnalignedBackpatchCount = UnalignedHandler.Count();
  const uint64_t UnalignedSigbusCount = UnalignedHandler.BusCount();
  const uint64_t UnalignedSigsegvCount = UnalignedHandler.SegvCount();
  const uint64_t UnalignedSigsegvMissingAddressCount = UnalignedHandler.SegvMissingAddressCount();
  const bool UnalignedDiagnosticLimitSeen = UnalignedHandler.DiagnosticLimitSeen();
  const size_t UnalignedPatternCount = UnalignedHandler.PatternCount();
  const bool UnalignedPatternOverflowSeen = UnalignedHandler.PatternOverflowSeen();
  const auto UnalignedPatternGuestRIPs = UnalignedHandler.PatternGuestRIPs();
  const auto UnalignedPatternHostProgramCounters =
    UnalignedHandler.PatternHostProgramCounters();
  const auto UnalignedPatternInstructions = UnalignedHandler.PatternInstructions();
  const auto UnalignedPatternFirstFaultAddresses =
    UnalignedHandler.PatternFirstFaultAddresses();
  const auto UnalignedPatternLastFaultAddresses =
    UnalignedHandler.PatternLastFaultAddresses();
  const auto UnalignedPatternSignals = UnalignedHandler.PatternSignals();
  const auto UnalignedPatternCodes = UnalignedHandler.PatternCodes();
  const auto UnalignedPatternHitCounts = UnalignedHandler.PatternHitCounts();
  const bool RawGuestSignalBoundarySeen = UnalignedHandler.BoundarySeen();
  const uint64_t GuestSignalBoundarySignal = UnalignedHandler.BoundarySignal();
  const int64_t GuestSignalBoundaryCode = UnalignedHandler.BoundaryCode();
  const uint64_t GuestSignalBoundaryProgramCounter =
    UnalignedHandler.BoundaryProgramCounter();
  const uint64_t GuestSignalBoundaryInstruction = UnalignedHandler.BoundaryInstruction();
  const auto GuestSignalBoundaryInstructionWords =
    UnalignedHandler.BoundaryInstructionWords();
  const uint64_t GuestSignalBoundaryInstructionWordsValidMask =
    UnalignedHandler.BoundaryInstructionWordsValidMask();
  const uint64_t GuestSignalBoundaryAddressRegister =
    UnalignedHandler.BoundaryAddressRegister();
  const bool GuestSignalBoundaryAddressRegisterMatchesFault =
    UnalignedHandler.BoundaryAddressRegisterMatchesFault();
  const bool GuestSignalBoundaryJITGuardPage = UnalignedHandler.BoundaryIsJITGuardPage();
  const uint64_t HostGuestSignalBoundaryFaultAddress = UnalignedHandler.BoundaryFaultAddress();
  const MachVMAdjacencySnapshot GuestSignalBoundaryMachVM = RawGuestSignalBoundarySeen
    ? InspectMachVMAdjacency(HostGuestSignalBoundaryFaultAddress)
    : MachVMAdjacencySnapshot {};
  const bool GuestSignalBoundaryInLowShadow = InstrumentLowMemoryBias
    && LowGuestShadow.ContainsHostAddress(HostGuestSignalBoundaryFaultAddress);
  const bool GuestSignalBoundaryInHighSparse = InstrumentHighMemoryRegion
    && HighGuestSparse.ContainsHostAddress(HostGuestSignalBoundaryFaultAddress);
  const uint64_t GuestSignalBoundaryFaultAddress = GuestSignalBoundaryInLowShadow
    ? LowGuestShadow.LogicalAddress(HostGuestSignalBoundaryFaultAddress)
    : (GuestSignalBoundaryInHighSparse
        ? HighGuestSparse.LogicalAddress(HostGuestSignalBoundaryFaultAddress)
        : HostGuestSignalBoundaryFaultAddress);
  const uint64_t GuestSignalBoundaryX4 = UnalignedHandler.BoundaryX4();
  const uint64_t GuestSignalBoundaryFSBase = UnalignedHandler.BoundaryFSBase();
  const uint64_t GuestSignalBoundaryGSBase = UnalignedHandler.BoundaryGSBase();
  const uint64_t GuestSignalBoundaryRSP = UnalignedHandler.BoundaryRSP();
  const bool GuestSignalBoundaryX4MatchesFault = UnalignedHandler.BoundaryX4MatchesFault();
  const bool GuestSignalBoundaryThreadState = UnalignedHandler.BoundaryIsThreadState();
  const bool GuestSignalBoundaryInterruptPage = UnalignedHandler.BoundaryIsInterruptPage();
  const bool GuestSignalBoundaryCallRetStack = UnalignedHandler.BoundaryIsCallRetStack();
  const uint64_t GuestSignalBoundaryFaultOffset = UnalignedHandler.BoundaryFaultOffset();
  const uint64_t GuestSignalBoundaryRIPOffset = UnalignedHandler.BoundaryGuestRIPOffset();
  const uint64_t GuestSignalBoundaryRecoveredGuestRIP =
    UnalignedHandler.BoundaryRecoveredGuestRIP();
  const std::array<uint64_t, 29> GuestSignalBoundaryHostGPRs =
    UnalignedHandler.BoundaryHostGPRs();
  const uint8_t GuestSignalBoundaryFaultLowPageState =
    LowGuestShadow.PageStateForLogicalAddress(GuestSignalBoundaryFaultAddress);
  const uint8_t GuestSignalBoundaryRecoveredRIPLowPageState =
    LowGuestShadow.PageStateForLogicalAddress(GuestSignalBoundaryRecoveredGuestRIP);
  const uint64_t LowGuestShadowHostBase = InstrumentLowMemoryBias
    ? LowGuestShadow.Bias()
    : 0;
  std::array<uint64_t, 7> GuestSignalBoundaryTEBWords {};
  bool GuestSignalBoundaryTEBMapped {};
  uint64_t GuestSignalBoundaryKernelStack {};
  bool GuestSignalBoundaryKernelStackMapped {};
  uint64_t GuestSignalBoundaryDeallocationStack {};
  bool GuestSignalBoundaryDeallocationStackMapped {};
  if (RawGuestSignalBoundarySeen && InstrumentLowMemoryBias) {
    const void* TEBBytes = LowGuestShadow.HostPointerForMappedLogicalRange(
      GuestSignalBoundaryGSBase,
      sizeof(GuestSignalBoundaryTEBWords),
      PROT_READ);
    if (TEBBytes != nullptr) {
      std::memcpy(
        GuestSignalBoundaryTEBWords.data(),
        TEBBytes,
        sizeof(GuestSignalBoundaryTEBWords));
      GuestSignalBoundaryTEBMapped = true;
    }
    const void* KernelStackBytes = LowGuestShadow.HostPointerForMappedLogicalRange(
      GuestSignalBoundaryGSBase + 0x3A8,
      sizeof(GuestSignalBoundaryKernelStack),
      PROT_READ);
    if (KernelStackBytes != nullptr) {
      std::memcpy(
        &GuestSignalBoundaryKernelStack,
        KernelStackBytes,
        sizeof(GuestSignalBoundaryKernelStack));
      GuestSignalBoundaryKernelStackMapped = true;
    }
    const void* DeallocationStackBytes = LowGuestShadow.HostPointerForMappedLogicalRange(
      GuestSignalBoundaryGSBase + 0x1478,
      sizeof(GuestSignalBoundaryDeallocationStack),
      PROT_READ);
    if (DeallocationStackBytes != nullptr) {
      std::memcpy(
        &GuestSignalBoundaryDeallocationStack,
        DeallocationStackBytes,
        sizeof(GuestSignalBoundaryDeallocationStack));
      GuestSignalBoundaryDeallocationStackMapped = true;
    }
  }
  const std::array<uint64_t, 16> GuestSignalBoundaryGuestGPRs =
    UnalignedHandler.BoundaryGuestGPRs();
  std::array<uint64_t, 16> GuestSignalBoundaryStackWords {};
  size_t GuestSignalBoundaryStackWordCount {};
  std::array<uint64_t, 8> GuestSignalBoundaryFramePointers {};
  std::array<uint64_t, 8> GuestSignalBoundaryFrameReturnAddresses {};
  size_t GuestSignalBoundaryFrameCount {};
  if (RawGuestSignalBoundarySeen && InstrumentLowMemoryBias) {
    const auto DirectGuestPointer = [GuestBase](uint64_t Address, size_t Size) -> const void* {
      const uint64_t GuestLimit = GuestBase + RealGuestMemorySize;
      if (Address < GuestBase || Address > GuestLimit || Size > GuestLimit - Address) {
        return nullptr;
      }
      return reinterpret_cast<const void*>(Address);
    };
    const void* StackBytes = DirectGuestPointer(
      GuestSignalBoundaryRSP,
      sizeof(GuestSignalBoundaryStackWords));
    if (StackBytes == nullptr) {
      StackBytes = LowGuestShadow.HostPointerForMappedLogicalRange(
        GuestSignalBoundaryRSP,
        sizeof(GuestSignalBoundaryStackWords),
        PROT_READ);
    }
    if (StackBytes == nullptr && InstrumentHighMemoryRegion) {
      StackBytes = HighGuestSparse.HostPointerForMappedLogicalRange(
        GuestSignalBoundaryRSP,
        sizeof(GuestSignalBoundaryStackWords),
        PROT_READ);
    }
    if (StackBytes != nullptr) {
      std::memcpy(
        GuestSignalBoundaryStackWords.data(),
        StackBytes,
        sizeof(GuestSignalBoundaryStackWords));
      GuestSignalBoundaryStackWordCount = GuestSignalBoundaryStackWords.size();
    }

    constexpr uint64_t MaximumFrameStep = 1ULL << 20;
    uint64_t CurrentFramePointer =
      GuestSignalBoundaryGuestGPRs[FEXCore::X86State::REG_RBP];
    for (size_t Index = 0; Index < GuestSignalBoundaryFramePointers.size(); ++Index) {
      const void* FrameBytes = DirectGuestPointer(
        CurrentFramePointer,
        2 * sizeof(uint64_t));
      if (FrameBytes == nullptr) {
        FrameBytes = LowGuestShadow.HostPointerForMappedLogicalRange(
          CurrentFramePointer,
          2 * sizeof(uint64_t),
          PROT_READ);
      }
      if (FrameBytes == nullptr && InstrumentHighMemoryRegion) {
        FrameBytes = HighGuestSparse.HostPointerForMappedLogicalRange(
          CurrentFramePointer,
          2 * sizeof(uint64_t),
          PROT_READ);
      }
      if (FrameBytes == nullptr) {
        break;
      }

      std::array<uint64_t, 2> FrameWords {};
      std::memcpy(FrameWords.data(), FrameBytes, sizeof(FrameWords));
      GuestSignalBoundaryFramePointers[Index] = CurrentFramePointer;
      GuestSignalBoundaryFrameReturnAddresses[Index] = FrameWords[1];
      ++GuestSignalBoundaryFrameCount;

      const uint64_t NextFramePointer = FrameWords[0];
      if (NextFramePointer <= CurrentFramePointer
          || NextFramePointer - CurrentFramePointer > MaximumFrameStep) {
        break;
      }
      CurrentFramePointer = NextFramePointer;
    }
  }
  const char* TraceSignalAddresses = getenv("REGRESSION_FLI_TRACE_SIGNAL_ADDRESSES");
  if (RawGuestSignalBoundarySeen && TraceSignalAddresses != nullptr
      && std::string_view {TraceSignalAddresses} == "1") {
    std::cerr << std::hex
              << "TRACE signal logical-fault=0x" << GuestSignalBoundaryFaultAddress
              << " low-shadow=" << (GuestSignalBoundaryInLowShadow ? 1 : 0)
              << " x4=0x" << GuestSignalBoundaryX4
              << " fs=0x" << GuestSignalBoundaryFSBase
              << " rsp=0x" << GuestSignalBoundaryRSP
              << " guest-base=0x" << GuestBase
              << " guest-limit=0x" << GuestBase + RealGuestMemorySize
              << std::dec << '\n';
  }
  UnalignedHandler.Reset();

  const bool UnsupportedSeen = SyscallHandler.UnexpectedSyscall != std::numeric_limits<uint64_t>::max();
  const bool ControlledStopSignalSeen = RawGuestSignalBoundarySeen
    && GuestSignalBoundaryRIPOffset == RealStopOffset
    && (UnsupportedSeen
        || SyscallHandler.ExitSeen
        || SyscallHandler.PostSessionSyscallDiagnosticLimitSeen);
  const bool GuestSignalBoundarySeen = RawGuestSignalBoundarySeen && !ControlledStopSignalSeen;
  const bool GuestSignalBoundaryInLastMMapRequest = GuestSignalBoundarySeen
    && SyscallHandler.MMapLastLength != 0
    && GuestSignalBoundaryFaultAddress >= SyscallHandler.MMapLastRequestedAddress
    && GuestSignalBoundaryFaultAddress - SyscallHandler.MMapLastRequestedAddress
      < SyscallHandler.MMapLastLength;
  const bool Completed = SyscallHandler.ExitSeen && SyscallHandler.ExitCode == 0;
  const bool BoundarySeen = UnsupportedSeen
    || SyscallHandler.ExitSeen
    || GuestSignalBoundarySeen
    || SyscallHandler.PostSessionSyscallDiagnosticLimitSeen;
  const bool ProtonWineNTDLLLoadFailure = OfficialProtonComponent
    && SyscallHandler.CapturedError.find("wine: could not load ntdll.so:") != std::string::npos;
  const bool ProtonWineGLIBCVersionFailure = OfficialProtonComponent
    && SyscallHandler.CapturedError.find("GLIBC_2.34") != std::string::npos
    && SyscallHandler.CapturedError.find("not found") != std::string::npos;
  const uint64_t Unsupported = SyscallHandler.UnexpectedSyscall;
  Context->DestroyThread(Thread);
  SyscallHandler.FinalizeOwnedVirtualVForkProcesses();

  constexpr std::string_view PrivateDiagnosticPrefix =
    "/private/tmp/regression-fli-fex-process-probe.";
  constexpr size_t MaximumPrivateDiagnosticBytes = 1024 * 1024;
  if (!PrivateStderrOutput.empty()) {
    const bool SafeDiagnosticPath = PrivateStderrOutput.starts_with(PrivateDiagnosticPrefix)
      && PrivateStderrOutput.find("/../") == std::string::npos
      && PrivateStderrOutput.find("/./") == std::string::npos
      && !PrivateStderrOutput.ends_with('/');
    if (!SafeDiagnosticPath
        || SyscallHandler.CapturedError.size() > MaximumPrivateDiagnosticBytes
        || !WritePrivateTextFile(PrivateStderrOutput, SyscallHandler.CapturedError)) {
      std::cerr << "No se pudo persistir el diagnóstico huésped privado.\n";
      return 70;
    }
  }

  std::cout << "{\"schema\":1,\"host\":\"macos-arm64\",\"parser\":\"FEX-ELFParser\""
            << ",\"mode\":\""
            << (StaticPIE ? "real-static-pie-first-syscall" : "real-glibc-first-syscall")
            << "\""
            << ",\"main_elf\":\"" << GuestProgram << "\",\"main_elf_loaded\":true"
            << ",\"guest_arg_count\":" << GuestArguments.size()
            << ",\"guest_component_kind\":\"" << GuestComponentKind << "\""
            << ",\"pt_interp_resolved\":" << (StaticPIE ? "false" : "true")
            << ",\"interpreter_elf_loaded\":" << (StaticPIE ? "false" : "true")
            << ",\"dynamic_interpreter\":\""
            << (StaticPIE ? "none-static-pie" : "private-rootfs-glibc-ld-linux-x86-64")
            << "\""
            << ",\"wine_loader_noexec_environment\":"
            << (IncludeWineLoaderNoExec ? "true" : "false")
            << ",\"wine_arch_wow64_environment\":"
            << (WineArchWow64 ? "true" : "false")
            << ",\"post_wine_reexec_wow64_entry\":"
            << (WineArchWow64 && !InitialWineCommandLine ? "true" : "false")
            << ",\"initial_wine_command_line_enabled\":"
            << (InitialWineCommandLine ? "true" : "false")
            << ",\"bind_now_environment\":"
            << (GuestBindNow ? "true" : "false")
            << ",\"cx_alt_loader_socket_environment\":"
            << (!CXAltLoaderSocket.empty() ? "true" : "false")
            << ",\"cx_alt_loader_host_socket_mapped\":"
            << (!CanonicalCXAltLoaderHostSocket.empty() ? "true" : "false")
            << ",\"private_guest_home_present\":true"
            << ",\"private_guest_home_directory_present\":"
            << (GuestHomeDirectoryPresent ? "true" : "false")
            << ",\"private_wine_prefix_directory_present\":"
            << (GuestWinePrefixDirectoryPresent ? "true" : "false")
            << ",\"segments_loaded\":" << SegmentCount
            << ",\"bss_zeroed\":" << (BSSZeroed ? "true" : "false")
            << ",\"initial_stack_present\":" << (Stack.Valid ? "true" : "false")
            << ",\"auxv_present\":true"
            << ",\"guest_entry_executed\":" << (BoundarySeen ? "true" : "false")
            << ",\"glibc_interpreter_mapped\":" << (StaticPIE ? "false" : "true")
            << ",\"glibc_entry_executed\":"
            << (!StaticPIE && BoundarySeen ? "true" : "false")
            << ",\"unaligned_backpatch_count\":" << UnalignedBackpatchCount
            << ",\"unaligned_sigbus_count\":" << UnalignedSigbusCount
            << ",\"unaligned_sigsegv_count\":" << UnalignedSigsegvCount
            << ",\"unaligned_sigsegv_missing_address_count\":"
            << UnalignedSigsegvMissingAddressCount
            << ",\"unaligned_diagnostic_limit\":"
            << DarwinUnalignedAccessHandler::MaximumDiagnosticBackpatchCount
            << ",\"unaligned_diagnostic_limit_seen\":"
            << (UnalignedDiagnosticLimitSeen ? "true" : "false")
            << ",\"unaligned_pattern_limit\":"
            << DarwinUnalignedAccessHandler::MaximumPatternCount
            << ",\"unaligned_pattern_overflow_seen\":"
            << (UnalignedPatternOverflowSeen ? "true" : "false")
            << ",\"unaligned_patterns\":[";
  for (size_t Index = 0; Index < UnalignedPatternCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"guest_rip\":" << UnalignedPatternGuestRIPs[Index]
              << ",\"host_program_counter\":"
              << UnalignedPatternHostProgramCounters[Index]
              << ",\"instruction\":" << UnalignedPatternInstructions[Index]
              << ",\"first_host_fault_address\":"
              << UnalignedPatternFirstFaultAddresses[Index]
              << ",\"last_host_fault_address\":"
              << UnalignedPatternLastFaultAddresses[Index]
              << ",\"signal\":" << UnalignedPatternSignals[Index]
              << ",\"code\":" << UnalignedPatternCodes[Index]
              << ",\"hit_count\":" << UnalignedPatternHitCounts[Index]
              << '}';
  }
  std::cout << ']'
            << ",\"raw_guest_signal_boundary_seen\":"
            << (RawGuestSignalBoundarySeen ? "true" : "false")
            << ",\"controlled_stop_signal_seen\":"
            << (ControlledStopSignalSeen ? "true" : "false")
            << ",\"guest_signal_boundary_seen\":" << (GuestSignalBoundarySeen ? "true" : "false")
            << ",\"guest_signal_boundary_signal\":" << GuestSignalBoundarySignal
            << ",\"guest_signal_boundary_code\":" << GuestSignalBoundaryCode
            << ",\"guest_signal_boundary_host_program_counter\":"
            << GuestSignalBoundaryProgramCounter
            << ",\"guest_signal_boundary_instruction\":" << GuestSignalBoundaryInstruction
            << ",\"guest_signal_boundary_instruction_neighborhood_relative_start\":-"
            << DarwinUnalignedAccessHandler::BoundaryInstructionRadius
            << ",\"guest_signal_boundary_instruction_neighborhood_valid_mask\":"
            << GuestSignalBoundaryInstructionWordsValidMask
            << ",\"guest_signal_boundary_instruction_neighborhood\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryInstructionWords.size(); ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryInstructionWords[Index];
  }
  std::cout << ']'
            << ",\"guest_signal_boundary_address_register\":"
            << GuestSignalBoundaryAddressRegister
            << ",\"guest_signal_boundary_address_register_matches_fault\":"
            << (GuestSignalBoundaryAddressRegisterMatchesFault ? "true" : "false")
            << ",\"guest_signal_boundary_low_shadow\":"
            << (GuestSignalBoundaryInLowShadow ? "true" : "false")
            << ",\"guest_signal_boundary_high_sparse\":"
            << (GuestSignalBoundaryInHighSparse ? "true" : "false")
            << ",\"guest_signal_boundary_last_mmap_request\":"
            << (GuestSignalBoundaryInLastMMapRequest ? "true" : "false")
            << ",\"guest_signal_boundary_last_mmap_offset\":";
  if (GuestSignalBoundaryInLastMMapRequest) {
    std::cout << GuestSignalBoundaryFaultAddress - SyscallHandler.MMapLastRequestedAddress;
  } else {
    std::cout << "null";
  }
  std::cout
            << ",\"guest_signal_boundary_low_address\":";
  if (GuestSignalBoundarySeen && GuestSignalBoundaryFaultAddress < 0x1'0000'0000ULL) {
    std::cout << GuestSignalBoundaryFaultAddress;
  } else {
    std::cout << "null";
  }
  std::cout
            << ",\"guest_signal_boundary_jit_guard_page\":"
            << (GuestSignalBoundaryJITGuardPage ? "true" : "false")
            << ",\"guest_signal_boundary_x4_matches_fault\":"
            << (GuestSignalBoundaryX4MatchesFault ? "true" : "false")
            << ",\"guest_signal_boundary_thread_state\":"
            << (GuestSignalBoundaryThreadState ? "true" : "false")
            << ",\"guest_signal_boundary_interrupt_page\":"
            << (GuestSignalBoundaryInterruptPage ? "true" : "false")
            << ",\"guest_signal_boundary_callret_stack\":"
            << (GuestSignalBoundaryCallRetStack ? "true" : "false")
            << ",\"guest_signal_boundary_fault_offset\":";
  if (GuestSignalBoundaryFaultOffset == std::numeric_limits<uint64_t>::max()) {
    std::cout << "null";
  } else {
    std::cout << GuestSignalBoundaryFaultOffset;
  }
  std::cout << ",\"guest_signal_boundary_rip_offset\":";
  if (GuestSignalBoundaryRIPOffset == std::numeric_limits<uint64_t>::max()) {
    std::cout << "null";
  } else {
    std::cout << GuestSignalBoundaryRIPOffset;
  }
  std::cout << ",\"guest_signal_boundary_recovered_rip_offset\":";
  if (GuestSignalBoundaryRecoveredGuestRIP >= GuestBase
      && GuestSignalBoundaryRecoveredGuestRIP < GuestBase + RealGuestMemorySize) {
    std::cout << GuestSignalBoundaryRecoveredGuestRIP - GuestBase;
  } else {
    std::cout << "null";
  }
  std::cout << ",\"guest_signal_boundary_recovered_guest_rip\":"
            << GuestSignalBoundaryRecoveredGuestRIP
            << ",\"guest_memory_base\":" << GuestBase
            << ",\"low_memory_shadow_host_base\":" << LowGuestShadowHostBase
            << ",\"guest_signal_boundary_host_fault_address\":"
            << HostGuestSignalBoundaryFaultAddress
            << ",\"guest_signal_boundary_mach_region_scan_succeeded\":"
            << (GuestSignalBoundaryMachVM.ScanSucceeded ? "true" : "false")
            << ",\"guest_signal_boundary_mach_region_scan_result\":"
            << GuestSignalBoundaryMachVM.ScanResult
            << ",\"guest_signal_boundary_mach_region_scan_count\":"
            << GuestSignalBoundaryMachVM.RegionsScanned
            << ",\"guest_signal_boundary_mach_previous_region_present\":"
            << (GuestSignalBoundaryMachVM.Previous.Present ? "true" : "false")
            << ",\"guest_signal_boundary_mach_previous_region_start\":"
            << GuestSignalBoundaryMachVM.Previous.Start
            << ",\"guest_signal_boundary_mach_previous_region_size\":"
            << GuestSignalBoundaryMachVM.Previous.Size
            << ",\"guest_signal_boundary_mach_previous_region_protection\":"
            << GuestSignalBoundaryMachVM.Previous.Protection
            << ",\"guest_signal_boundary_mach_previous_region_maximum_protection\":"
            << GuestSignalBoundaryMachVM.Previous.MaximumProtection
            << ",\"guest_signal_boundary_mach_containing_region_present\":"
            << (GuestSignalBoundaryMachVM.Containing.Present ? "true" : "false")
            << ",\"guest_signal_boundary_mach_containing_region_start\":"
            << GuestSignalBoundaryMachVM.Containing.Start
            << ",\"guest_signal_boundary_mach_containing_region_size\":"
            << GuestSignalBoundaryMachVM.Containing.Size
            << ",\"guest_signal_boundary_mach_containing_region_fault_offset\":";
  if (GuestSignalBoundaryMachVM.FaultOffsetWithinContaining
      == std::numeric_limits<uint64_t>::max()) {
    std::cout << "null";
  } else {
    std::cout << GuestSignalBoundaryMachVM.FaultOffsetWithinContaining;
  }
  std::cout
            << ",\"guest_signal_boundary_mach_containing_region_protection\":"
            << GuestSignalBoundaryMachVM.Containing.Protection
            << ",\"guest_signal_boundary_mach_containing_region_maximum_protection\":"
            << GuestSignalBoundaryMachVM.Containing.MaximumProtection
            << ",\"guest_signal_boundary_mach_fault_at_containing_last_byte\":"
            << (GuestSignalBoundaryMachVM.FaultAtContainingLastByte ? "true" : "false")
            << ",\"guest_signal_boundary_mach_next_region_present\":"
            << (GuestSignalBoundaryMachVM.Next.Present ? "true" : "false")
            << ",\"guest_signal_boundary_mach_next_region_start\":"
            << GuestSignalBoundaryMachVM.Next.Start
            << ",\"guest_signal_boundary_mach_next_region_size\":"
            << GuestSignalBoundaryMachVM.Next.Size
            << ",\"guest_signal_boundary_mach_next_region_protection\":"
            << GuestSignalBoundaryMachVM.Next.Protection
            << ",\"guest_signal_boundary_mach_next_region_maximum_protection\":"
            << GuestSignalBoundaryMachVM.Next.MaximumProtection
            << ",\"guest_signal_boundary_mach_fault_at_previous_region_end\":"
            << (GuestSignalBoundaryMachVM.FaultAtPreviousRegionEnd ? "true" : "false")
            << ",\"guest_signal_boundary_mach_fault_one_byte_before_next_region\":"
            << (GuestSignalBoundaryMachVM.FaultOneByteBeforeNextRegion ? "true" : "false")
            << ",\"guest_signal_boundary_fault_low_page_state\":"
            << static_cast<uint64_t>(GuestSignalBoundaryFaultLowPageState)
            << ",\"guest_signal_boundary_fault_low_page_mapped\":"
            << ((GuestSignalBoundaryFaultLowPageState & LowGuestShadowMapping::MappedBit) != 0
              ? "true" : "false")
            << ",\"guest_signal_boundary_recovered_rip_low_page_state\":"
            << static_cast<uint64_t>(GuestSignalBoundaryRecoveredRIPLowPageState)
            << ",\"guest_signal_boundary_recovered_rip_low_page_mapped\":"
            << ((GuestSignalBoundaryRecoveredRIPLowPageState
                & LowGuestShadowMapping::MappedBit) != 0 ? "true" : "false")
            << ",\"guest_signal_boundary_fs_base\":" << GuestSignalBoundaryFSBase
            << ",\"guest_signal_boundary_gs_base\":" << GuestSignalBoundaryGSBase
            << ",\"guest_signal_boundary_teb_mapped\":"
            << (GuestSignalBoundaryTEBMapped ? "true" : "false")
            << ",\"guest_signal_boundary_teb_exception_list\":"
            << GuestSignalBoundaryTEBWords[0]
            << ",\"guest_signal_boundary_teb_stack_base\":"
            << GuestSignalBoundaryTEBWords[1]
            << ",\"guest_signal_boundary_teb_stack_limit\":"
            << GuestSignalBoundaryTEBWords[2]
            << ",\"guest_signal_boundary_teb_subsystem_tib\":"
            << GuestSignalBoundaryTEBWords[3]
            << ",\"guest_signal_boundary_teb_fiber_data\":"
            << GuestSignalBoundaryTEBWords[4]
            << ",\"guest_signal_boundary_teb_arbitrary_user_pointer\":"
            << GuestSignalBoundaryTEBWords[5]
            << ",\"guest_signal_boundary_teb_self\":"
            << GuestSignalBoundaryTEBWords[6]
            << ",\"guest_signal_boundary_kernel_stack_mapped\":"
            << (GuestSignalBoundaryKernelStackMapped ? "true" : "false")
            << ",\"guest_signal_boundary_kernel_stack\":"
            << GuestSignalBoundaryKernelStack
            << ",\"guest_signal_boundary_deallocation_stack_mapped\":"
            << (GuestSignalBoundaryDeallocationStackMapped ? "true" : "false")
            << ",\"guest_signal_boundary_deallocation_stack\":"
            << GuestSignalBoundaryDeallocationStack
            << ",\"guest_signal_boundary_rsp\":" << GuestSignalBoundaryRSP
            << ",\"guest_signal_boundary_x4\":" << GuestSignalBoundaryX4
            << ",\"guest_signal_boundary_host_gprs\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryHostGPRs.size(); ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryHostGPRs[Index];
  }
  std::cout << ']'
            << ",\"guest_signal_boundary_guest_gprs\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryGuestGPRs.size(); ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryGuestGPRs[Index];
  }
  std::cout << ']'
            << ",\"guest_signal_boundary_stack_words\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryStackWordCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryStackWords[Index];
  }
  std::cout << ']'
            << ",\"guest_signal_boundary_frame_pointers\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryFrameCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryFramePointers[Index];
  }
  std::cout << ']'
            << ",\"guest_signal_boundary_frame_return_addresses\":[";
  for (size_t Index = 0; Index < GuestSignalBoundaryFrameCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << GuestSignalBoundaryFrameReturnAddresses[Index];
  }
  std::cout << ']';
  std::cout
            << ",\"brk_syscall_seen\":" << (SyscallHandler.BrkSeen ? "true" : "false")
            << ",\"brk_call_count\":" << SyscallHandler.BrkCallCount
            << ",\"access_syscall_seen\":" << (SyscallHandler.AccessSeen ? "true" : "false")
            << ",\"access_call_count\":" << SyscallHandler.AccessCallCount
            << ",\"open_syscall_seen\":" << (SyscallHandler.OpenSeen ? "true" : "false")
            << ",\"open_call_count\":" << SyscallHandler.OpenCallCount
            << ",\"open_success_count\":" << SyscallHandler.OpenSuccessCount
            << ",\"open_last_path_class\":\"" << SyscallHandler.OpenLastPathClass << "\""
            << ",\"open_last_path_length\":" << SyscallHandler.OpenLastPathLength
            << ",\"open_last_path_fingerprint\":" << SyscallHandler.OpenLastPathFingerprint
            << ",\"open_last_flags\":" << SyscallHandler.OpenLastFlags
            << ",\"open_last_mode\":" << SyscallHandler.OpenLastMode
            << ",\"open_last_linux_error\":" << SyscallHandler.OpenLastLinuxError
            << ",\"openat_syscall_seen\":" << (SyscallHandler.OpenAtSeen ? "true" : "false")
            << ",\"openat_call_count\":" << SyscallHandler.OpenAtCallCount
            << ",\"openat_success_count\":" << SyscallHandler.OpenAtSuccessCount
            << ",\"openat_last_directory_descriptor\":"
            << SyscallHandler.OpenAtLastDirectoryDescriptor
            << ",\"openat_last_flags\":" << SyscallHandler.OpenAtLastFlags
            << ",\"openat_last_mode\":" << SyscallHandler.OpenAtLastMode
            << ",\"openat_last_path_class\":\""
            << SyscallHandler.OpenAtLastPathClass << "\""
            << ",\"openat_last_path_length\":" << SyscallHandler.OpenAtLastPathLength
            << ",\"openat_last_path_fingerprint\":"
            << SyscallHandler.OpenAtLastPathFingerprint
            << ",\"openat_last_host_path_resolved\":"
            << (SyscallHandler.OpenAtLastHostPathResolved ? "true" : "false")
            << ",\"openat_last_target_exists\":"
            << (SyscallHandler.OpenAtLastTargetExists ? "true" : "false")
            << ",\"openat_last_target_directory\":"
            << (SyscallHandler.OpenAtLastTargetDirectory ? "true" : "false")
            << ",\"openat_last_target_regular\":"
            << (SyscallHandler.OpenAtLastTargetRegular ? "true" : "false")
            << ",\"openat_last_linux_error\":" << SyscallHandler.OpenAtLastLinuxError
            << ",\"openat_last_failure_reason\":\""
            << SyscallHandler.OpenAtLastFailureReason << "\""
            << ",\"registry_temporary_open_success_count\":"
            << SyscallHandler.RegistryTemporaryOpenSuccessCount
            << ",\"registry_temporary_last_descriptor\":"
            << SyscallHandler.RegistryTemporaryLastDescriptor
            << ",\"registry_temporary_trace_active\":"
            << (SyscallHandler.RegistryTemporaryTraceActive ? "true" : "false")
            << ",\"registry_temporary_trace_trigger_openat_call_count\":"
            << SyscallHandler.RegistryTemporaryTraceTriggerOpenAtCallCount
            << ",\"registry_temporary_syscall_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.RegistryTemporarySyscallTraceCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    const auto& Entry = SyscallHandler.RegistryTemporarySyscallTrace[Index];
    std::cout << "{\"number\":" << Entry.Number << ",\"arguments\":[";
    for (size_t ArgumentIndex = 0; ArgumentIndex < Entry.Arguments.size(); ++ArgumentIndex) {
      if (ArgumentIndex != 0) {
        std::cout << ',';
      }
      std::cout << Entry.Arguments[ArgumentIndex];
    }
    std::cout << "]"
              << ",\"argument1_descriptor_owned\":"
              << (Entry.Argument1DescriptorOwned ? "true" : "false")
              << ",\"argument1_matches_registry_temporary\":"
              << (Entry.Argument1MatchesRegistryTemporary ? "true" : "false")
              << ",\"argument1_descriptor_regular\":"
              << (Entry.Argument1DescriptorRegular ? "true" : "false")
              << ",\"argument1_descriptor_fifo\":"
              << (Entry.Argument1DescriptorFIFO ? "true" : "false")
              << ",\"argument1_descriptor_socket\":"
              << (Entry.Argument1DescriptorSocket ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"intl_nls_open_candidate_count\":"
            << SyscallHandler.IntlNLSOpenCandidateCount
            << ",\"intl_nls_open_candidate_paths\":[";
  for (size_t Index = 0; Index < SyscallHandler.IntlNLSOpenCandidatePaths.size(); ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << '\"' << SyscallHandler.IntlNLSOpenCandidatePaths[Index] << '\"';
  }
  std::cout << ']'
            << ",\"intl_nls_last_operation\":\""
            << SyscallHandler.IntlNLSLastOperation << "\""
            << ",\"intl_nls_last_host_path_resolved\":"
            << (SyscallHandler.IntlNLSLastHostPathResolved ? "true" : "false")
            << ",\"intl_nls_last_target_exists\":"
            << (SyscallHandler.IntlNLSLastTargetExists ? "true" : "false")
            << ",\"intl_nls_last_target_regular\":"
            << (SyscallHandler.IntlNLSLastTargetRegular ? "true" : "false")
            << ",\"intl_nls_last_linux_error\":"
            << SyscallHandler.IntlNLSLastLinuxError
            << ",\"intl_nls_last_descriptor\":"
            << SyscallHandler.IntlNLSLastDescriptor
            << ",\"temporary_mapping_open_candidate_count\":"
            << SyscallHandler.TemporaryMappingOpenCandidateCount
            << ",\"temporary_mapping_first_candidate_path\":\""
            << SyscallHandler.TemporaryMappingFirstCandidatePath << "\""
            << ",\"temporary_mapping_last_candidate_path\":\""
            << SyscallHandler.TemporaryMappingLastCandidatePath << "\""
            << ",\"temporary_mapping_exclusive_create_success_count\":"
            << SyscallHandler.TemporaryMappingExclusiveCreateSuccessCount
            << ",\"temporary_mapping_exclusive_create_last_descriptor\":"
            << SyscallHandler.TemporaryMappingExclusiveCreateLastDescriptor
            << ",\"temporary_mapping_exclusive_create_last_linux_error\":"
            << SyscallHandler.TemporaryMappingExclusiveCreateLastLinuxError
            << ",\"newfstatat_syscall_seen\":" << (SyscallHandler.NewFStatAtSeen ? "true" : "false")
            << ",\"newfstatat_call_count\":" << SyscallHandler.NewFStatAtCallCount
            << ",\"newfstatat_success_count\":" << SyscallHandler.NewFStatAtSuccessCount
            << ",\"newfstatat_failure_count\":" << SyscallHandler.NewFStatAtFailureCount
            << ",\"newfstatat_relative_path_call_count\":"
            << SyscallHandler.NewFStatAtRelativePathCallCount
            << ",\"newfstatat_relative_path_success_count\":"
            << SyscallHandler.NewFStatAtRelativePathSuccessCount
            << ",\"newfstatat_last_directory_descriptor\":"
            << SyscallHandler.NewFStatAtLastDirectoryDescriptor
            << ",\"newfstatat_last_flags\":" << SyscallHandler.NewFStatAtLastFlags
            << ",\"newfstatat_last_path_class\":\""
            << SyscallHandler.NewFStatAtLastPathClass << "\""
            << ",\"newfstatat_last_path_length\":" << SyscallHandler.NewFStatAtLastPathLength
            << ",\"newfstatat_last_path_fingerprint\":"
            << SyscallHandler.NewFStatAtLastPathFingerprint
            << ",\"newfstatat_last_host_path_resolved\":"
            << (SyscallHandler.NewFStatAtLastHostPathResolved ? "true" : "false")
            << ",\"newfstatat_last_target_exists\":"
            << (SyscallHandler.NewFStatAtLastTargetExists ? "true" : "false")
            << ",\"newfstatat_last_target_directory\":"
            << (SyscallHandler.NewFStatAtLastTargetDirectory ? "true" : "false")
            << ",\"newfstatat_last_target_regular\":"
            << (SyscallHandler.NewFStatAtLastTargetRegular ? "true" : "false")
            << ",\"newfstatat_last_linux_error\":" << SyscallHandler.NewFStatAtLastLinuxError
            << ",\"newfstatat_last_failure_reason\":\""
            << SyscallHandler.NewFStatAtLastFailureReason << "\""
            << ",\"read_syscall_seen\":" << (SyscallHandler.ReadSeen ? "true" : "false")
            << ",\"read_call_count\":" << SyscallHandler.ReadCallCount
            << ",\"read_byte_count\":" << SyscallHandler.ReadByteCount
            << ",\"read_last_descriptor\":" << SyscallHandler.ReadLastDescriptor
            << ",\"read_last_buffer\":" << SyscallHandler.ReadLastBuffer
            << ",\"read_last_count\":" << SyscallHandler.ReadLastCount
            << ",\"read_last_buffer_class\":\""
            << SyscallHandler.ReadLastBufferClass << "\""
            << ",\"read_last_descriptor_owned\":"
            << (SyscallHandler.ReadLastDescriptorOwned ? "true" : "false")
            << ",\"read_last_descriptor_received_scm_rights\":"
            << (SyscallHandler.ReadLastDescriptorReceivedSCMRights ? "true" : "false")
            << ",\"read_last_descriptor_stat_succeeded\":"
            << (SyscallHandler.ReadLastDescriptorStatSucceeded ? "true" : "false")
            << ",\"read_last_descriptor_fifo\":"
            << (SyscallHandler.ReadLastDescriptorFIFO ? "true" : "false")
            << ",\"read_last_descriptor_socket\":"
            << (SyscallHandler.ReadLastDescriptorSocket ? "true" : "false")
            << ",\"read_last_descriptor_regular\":"
            << (SyscallHandler.ReadLastDescriptorRegular ? "true" : "false")
            << ",\"read_elf_header_record_count\":"
            << SyscallHandler.ReadELFHeaderRecordCount
            << ",\"read_elf_header_record_overflow\":"
            << (SyscallHandler.ReadELFHeaderRecordOverflow ? "true" : "false")
            << ",\"read_elf_header_records\":[";
  for (size_t Index = 0; Index < SyscallHandler.ReadELFHeaderRecordCount; ++Index) {
    const ReadELFHeaderRecord& Record = SyscallHandler.ReadELFHeaderRecords[Index];
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"syscall_ordinal\":" << Record.SyscallOrdinal
              << ",\"descriptor\":" << Record.Descriptor
              << ",\"guest_buffer\":" << Record.GuestBuffer
              << ",\"requested_byte_count\":" << Record.RequestedByteCount
              << ",\"returned_byte_count\":" << Record.ReturnedByteCount
              << ",\"first_64_byte_fingerprint\":" << Record.First64ByteFingerprint
              << ",\"magic\":" << Record.Magic
              << ",\"elf_class\":" << static_cast<uint64_t>(Record.ELFClass)
              << ",\"data_encoding\":" << static_cast<uint64_t>(Record.DataEncoding)
              << ",\"type\":" << Record.Type
              << ",\"machine\":" << Record.Machine
              << ",\"version\":" << Record.Version
              << ",\"entry\":" << Record.Entry
              << ",\"program_header_offset\":" << Record.ProgramHeaderOffset
              << ",\"program_header_entry_size\":" << Record.ProgramHeaderEntrySize
              << ",\"program_header_count\":" << Record.ProgramHeaderCount
              << ",\"descriptor_path_class\":\""
              << Record.DescriptorPathClass << "\""
              << ",\"descriptor_guest_path\":\""
              << Record.DescriptorGuestPath << "\"}"
              ;
  }
  std::cout << ']'
            << ",\"read_wine_fixed_reply_seen\":"
            << (SyscallHandler.ReadWineFixedReplySeen ? "true" : "false")
            << ",\"read_wine_fixed_reply_count\":"
            << SyscallHandler.ReadWineFixedReplyCount
            << ",\"read_wine_fixed_reply_last_descriptor\":"
            << SyscallHandler.ReadWineFixedReplyLastDescriptor
            << ",\"read_wine_fixed_reply_last_returned_byte_count\":"
            << SyscallHandler.ReadWineFixedReplyLastReturnedByteCount
            << ",\"read_wine_fixed_reply_last_error\":"
            << SyscallHandler.ReadWineFixedReplyLastError
            << ",\"read_wine_fixed_reply_last_declared_size\":"
            << SyscallHandler.ReadWineFixedReplyLastDeclaredSize
            << ",\"getdents64_syscall_seen\":"
            << (SyscallHandler.GetDents64Seen ? "true" : "false")
            << ",\"getdents64_call_count\":" << SyscallHandler.GetDents64CallCount
            << ",\"getdents64_success_count\":" << SyscallHandler.GetDents64SuccessCount
            << ",\"getdents64_failure_count\":" << SyscallHandler.GetDents64FailureCount
            << ",\"getdents64_eof_count\":" << SyscallHandler.GetDents64EOFCount
            << ",\"getdents64_host_byte_count\":"
            << SyscallHandler.GetDents64HostByteCount
            << ",\"getdents64_linux_byte_count\":"
            << SyscallHandler.GetDents64LinuxByteCount
            << ",\"getdents64_entry_count\":" << SyscallHandler.GetDents64EntryCount
            << ",\"getdents64_skipped_zero_inode_count\":"
            << SyscallHandler.GetDents64SkippedZeroInodeCount
            << ",\"getdents64_rollback_success_count\":"
            << SyscallHandler.GetDents64RollbackSuccessCount
            << ",\"getdents64_rollback_failure_count\":"
            << SyscallHandler.GetDents64RollbackFailureCount
            << ",\"getdents64_last_descriptor\":"
            << SyscallHandler.GetDents64LastDescriptor
            << ",\"getdents64_last_guest_buffer\":"
            << SyscallHandler.GetDents64LastGuestBuffer
            << ",\"getdents64_last_byte_count\":"
            << SyscallHandler.GetDents64LastByteCount
            << ",\"getdents64_last_returned_byte_count\":"
            << SyscallHandler.GetDents64LastReturnedByteCount
            << ",\"getdents64_last_converted_entry_count\":"
            << SyscallHandler.GetDents64LastConvertedEntryCount
            << ",\"getdents64_last_descriptor_owned\":"
            << (SyscallHandler.GetDents64LastDescriptorOwned ? "true" : "false")
            << ",\"getdents64_last_descriptor_directory\":"
            << (SyscallHandler.GetDents64LastDescriptorDirectory ? "true" : "false")
            << ",\"getdents64_last_descriptor_path_confined\":"
            << (SyscallHandler.GetDents64LastDescriptorPathConfined ? "true" : "false")
            << ",\"getdents64_last_position\":"
            << SyscallHandler.GetDents64LastPosition
            << ",\"getdents64_last_next_offset\":"
            << SyscallHandler.GetDents64LastNextOffset
            << ",\"getdents64_last_host_error\":"
            << SyscallHandler.GetDents64LastHostError
            << ",\"getdents64_last_linux_error\":"
            << SyscallHandler.GetDents64LastLinuxError
            << ",\"getdents64_last_buffer_class\":\""
            << SyscallHandler.GetDents64LastBufferClass << "\""
            << ",\"getdents64_last_failure_reason\":\""
            << SyscallHandler.GetDents64LastFailureReason << "\""
            << ",\"pread64_syscall_seen\":" << (SyscallHandler.PRead64Seen ? "true" : "false")
            << ",\"pread64_call_count\":" << SyscallHandler.PRead64CallCount
            << ",\"pread64_byte_count\":" << SyscallHandler.PRead64ByteCount
            << ",\"fstat_syscall_seen\":" << (SyscallHandler.FStatSeen ? "true" : "false")
            << ",\"fstat_call_count\":" << SyscallHandler.FStatCallCount
            << ",\"fstat_success_count\":" << SyscallHandler.FStatSuccessCount
            << ",\"fcntl_syscall_seen\":" << (SyscallHandler.FcntlSeen ? "true" : "false")
            << ",\"fcntl_call_count\":" << SyscallHandler.FcntlCallCount
            << ",\"fcntl_invalid_descriptor_count\":"
            << SyscallHandler.FcntlInvalidDescriptorCount
            << ",\"fcntl_get_flags_candidate_count\":"
            << SyscallHandler.FcntlGetFlagsCandidateCount
            << ",\"fcntl_get_flags_registry_temporary_candidate_count\":"
            << SyscallHandler.FcntlGetFlagsRegistryTemporaryCandidateCount
            << ",\"fcntl_get_flags_registry_temporary_success_count\":"
            << SyscallHandler.FcntlGetFlagsRegistryTemporarySuccessCount
            << ",\"fcntl_get_flags_registry_temporary_failure_count\":"
            << SyscallHandler.FcntlGetFlagsRegistryTemporaryFailureCount
            << ",\"fcntl_get_flags_registry_temporary_last_linux_flags\":"
            << SyscallHandler.FcntlGetFlagsRegistryTemporaryLastLinuxFlags
            << ",\"fcntl_get_flags_generic_success_count\":"
            << SyscallHandler.FcntlGetFlagsGenericSuccessCount
            << ",\"fcntl_get_flags_generic_failure_count\":"
            << SyscallHandler.FcntlGetFlagsGenericFailureCount
            << ",\"fcntl_get_flags_generic_last_linux_flags\":"
            << SyscallHandler.FcntlGetFlagsGenericLastLinuxFlags
            << ",\"fcntl_get_flags_last_host_flags\":"
            << SyscallHandler.FcntlGetFlagsLastHostFlags
            << ",\"fcntl_get_flags_last_host_error\":"
            << SyscallHandler.FcntlGetFlagsLastHostError
            << ",\"fcntl_get_flags_last_descriptor_matches_registry_temporary\":"
            << (SyscallHandler.FcntlGetFlagsLastDescriptorMatchesRegistryTemporary
              ? "true" : "false")
            << ",\"fcntl_get_flags_registry_temporary_last_descriptor_regular\":"
            << (SyscallHandler.FcntlGetFlagsRegistryTemporaryLastDescriptorRegular
              ? "true" : "false")
            << ",\"fcntl_set_flags_call_count\":"
            << SyscallHandler.FcntlSetFlagsCallCount
            << ",\"fcntl_set_flags_success_count\":"
            << SyscallHandler.FcntlSetFlagsSuccessCount
            << ",\"fcntl_set_flags_last_host_flags_before\":"
            << SyscallHandler.FcntlSetFlagsLastHostFlagsBefore
            << ",\"fcntl_set_flags_last_host_flags_after\":"
            << SyscallHandler.FcntlSetFlagsLastHostFlagsAfter
            << ",\"fcntl_set_lock_call_count\":"
            << SyscallHandler.FcntlSetLockCallCount
            << ",\"fcntl_set_lock_success_count\":"
            << SyscallHandler.FcntlSetLockSuccessCount
            << ",\"fcntl_set_descriptor_flags_call_count\":"
            << SyscallHandler.FcntlSetDescriptorFlagsCallCount
            << ",\"fcntl_set_descriptor_flags_exact_candidate_count\":"
            << SyscallHandler.FcntlSetDescriptorFlagsExactCandidateCount
            << ",\"fcntl_set_descriptor_flags_other_shape_count\":"
            << SyscallHandler.FcntlSetDescriptorFlagsOtherShapeCount
            << ",\"fcntl_set_descriptor_flags_success_count\":"
            << SyscallHandler.FcntlSetDescriptorFlagsSuccessCount
            << ",\"fcntl_set_descriptor_flags_failure_count\":"
            << SyscallHandler.FcntlSetDescriptorFlagsFailureCount
            << ",\"fcntl_set_descriptor_flags_last_host_flags_before\":"
            << SyscallHandler.FcntlSetDescriptorFlagsLastHostFlagsBefore
            << ",\"fcntl_set_descriptor_flags_last_host_flags_after\":"
            << SyscallHandler.FcntlSetDescriptorFlagsLastHostFlagsAfter
            << ",\"fcntl_last_descriptor\":" << SyscallHandler.FcntlLastDescriptor
            << ",\"fcntl_last_command\":" << SyscallHandler.FcntlLastCommand
            << ",\"fcntl_last_argument\":" << SyscallHandler.FcntlLastArgument
            << ",\"fcntl_last_argument_class\":\""
            << SyscallHandler.FcntlLastArgumentClass << "\""
            << ",\"fcntl_last_linux_error\":" << SyscallHandler.FcntlLastLinuxError
            << ",\"fcntl_last_flock_readable\":"
            << (SyscallHandler.FcntlLastFlockReadable ? "true" : "false")
            << ",\"fcntl_last_flock_type\":" << SyscallHandler.FcntlLastFlockType
            << ",\"fcntl_last_flock_whence\":" << SyscallHandler.FcntlLastFlockWhence
            << ",\"fcntl_last_flock_start\":" << SyscallHandler.FcntlLastFlockStart
            << ",\"fcntl_last_flock_length\":" << SyscallHandler.FcntlLastFlockLength
            << ",\"fcntl_last_flock_process_id\":"
            << SyscallHandler.FcntlLastFlockProcessID
            << ",\"fcntl_last_failure_reason\":\""
            << SyscallHandler.FcntlLastFailureReason << "\""
            << ",\"fcntl_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.FcntlTraceCount; ++Index) {
    const auto& Trace = SyscallHandler.FcntlTrace[Index];
    if (Index != 0) std::cout << ',';
    std::cout << "{\"descriptor\":" << Trace.Descriptor
              << ",\"command\":" << Trace.Command
              << ",\"argument\":" << Trace.Argument
              << ",\"descriptor_owned\":" << (Trace.DescriptorOwned ? "true" : "false")
              << ",\"descriptor_standard\":" << (Trace.DescriptorStandard ? "true" : "false")
              << ",\"descriptor_closed\":" << (Trace.DescriptorClosed ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"setsockopt_syscall_seen\":"
            << (SyscallHandler.SetSockOptSeen ? "true" : "false")
            << ",\"setsockopt_call_count\":" << SyscallHandler.SetSockOptCallCount
            << ",\"setsockopt_last_descriptor\":" << SyscallHandler.SetSockOptLastDescriptor
            << ",\"setsockopt_last_descriptor_owned\":"
            << (SyscallHandler.SetSockOptLastDescriptorOwned ? "true" : "false")
            << ",\"setsockopt_last_level\":" << SyscallHandler.SetSockOptLastLevel
            << ",\"setsockopt_last_option\":" << SyscallHandler.SetSockOptLastOption
            << ",\"setsockopt_last_value_length\":"
            << SyscallHandler.SetSockOptLastValueLength
            << ",\"setsockopt_last_value_class\":\""
            << SyscallHandler.SetSockOptLastValueClass << "\""
            << ",\"setsockopt_last_value_readable\":"
            << (SyscallHandler.SetSockOptLastValueReadable ? "true" : "false")
            << ",\"setsockopt_last_int32_value_readable\":"
            << (SyscallHandler.SetSockOptLastInt32ValueReadable ? "true" : "false")
            << ",\"setsockopt_last_int32_value\":"
            << SyscallHandler.SetSockOptLastInt32Value
            << ",\"setsockopt_last_value_fingerprint\":"
            << SyscallHandler.SetSockOptLastValueFingerprint
            << ",\"setsockopt_pass_credentials_candidate_count\":"
            << SyscallHandler.SetSockOptPassCredentialsCandidateCount
            << ",\"setsockopt_pass_credentials_enable_count\":"
            << SyscallHandler.SetSockOptPassCredentialsEnableCount
            << ",\"setsockopt_pass_credentials_disable_count\":"
            << SyscallHandler.SetSockOptPassCredentialsDisableCount
            << ",\"setsockopt_pass_credentials_no_host_option_count\":"
            << SyscallHandler.SetSockOptPassCredentialsNoHostOptionCount
            << ",\"setsockopt_success_count\":" << SyscallHandler.SetSockOptSuccessCount
            << ",\"setsockopt_other_shape_count\":" << SyscallHandler.SetSockOptOtherShapeCount
            << ",\"setsockopt_last_linux_error\":" << SyscallHandler.SetSockOptLastLinuxError
            << ",\"setsockopt_last_failure_reason\":\""
            << SyscallHandler.SetSockOptLastFailureReason << "\""
            << ",\"setsockopt_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.SetSockOptTraceCount; ++Index) {
    const auto& Trace = SyscallHandler.SetSockOptTrace[Index];
    if (Index != 0) std::cout << ',';
    std::cout << "{\"descriptor\":" << Trace.Descriptor
              << ",\"descriptor_owned\":" << (Trace.DescriptorOwned ? "true" : "false")
              << ",\"level\":" << Trace.Level
              << ",\"option\":" << Trace.Option
              << ",\"value_length\":" << Trace.ValueLength
              << ",\"value_readable\":" << (Trace.ValueReadable ? "true" : "false")
              << ",\"int32_value_readable\":" << (Trace.Int32ValueReadable ? "true" : "false")
              << ",\"int32_value\":" << Trace.Int32Value
              << '}';
  }
  std::cout << ']'
            << ",\"sigaltstack_syscall_seen\":"
            << (SyscallHandler.SigAltStackSeen ? "true" : "false")
            << ",\"sigaltstack_call_count\":" << SyscallHandler.SigAltStackCallCount
            << ",\"sigaltstack_last_new_stack_class\":\""
            << SyscallHandler.SigAltStackLastNewStackClass << "\""
            << ",\"sigaltstack_last_old_stack_class\":\""
            << SyscallHandler.SigAltStackLastOldStackClass << "\""
            << ",\"sigaltstack_last_new_stack_readable\":"
            << (SyscallHandler.SigAltStackLastNewStackReadable ? "true" : "false")
            << ",\"sigaltstack_last_old_stack_writable\":"
            << (SyscallHandler.SigAltStackLastOldStackWritable ? "true" : "false")
            << ",\"sigaltstack_last_stack_pointer\":"
            << SyscallHandler.SigAltStackLastStackPointer
            << ",\"sigaltstack_last_flags\":" << SyscallHandler.SigAltStackLastFlags
            << ",\"sigaltstack_last_size\":" << SyscallHandler.SigAltStackLastSize
            << ",\"sigaltstack_last_guest_rsp\":" << SyscallHandler.SigAltStackLastGuestRSP
            << ",\"sigaltstack_last_stack_range_readable\":"
            << (SyscallHandler.SigAltStackLastStackRangeReadable ? "true" : "false")
            << ",\"sigaltstack_last_stack_range_low_shadow\":"
            << (SyscallHandler.SigAltStackLastStackRangeLowShadow ? "true" : "false")
            << ",\"sigaltstack_last_stack_range_low_shadow_mapped\":"
            << (SyscallHandler.SigAltStackLastStackRangeLowShadowMapped ? "true" : "false")
            << ",\"sigaltstack_last_stack_range_low_shadow_readable\":"
            << (SyscallHandler.SigAltStackLastStackRangeLowShadowReadable ? "true" : "false")
            << ",\"sigaltstack_last_stack_range_low_shadow_writable\":"
            << (SyscallHandler.SigAltStackLastStackRangeLowShadowWritable ? "true" : "false")
            << ",\"sigaltstack_last_stack_range_low_shadow_executable\":"
            << (SyscallHandler.SigAltStackLastStackRangeLowShadowExecutable ? "true" : "false")
            << ",\"sigaltstack_last_guest_rsp_within_stack\":"
            << (SyscallHandler.SigAltStackLastGuestRSPWithinStack ? "true" : "false")
            << ",\"sigaltstack_install_candidate_count\":"
            << SyscallHandler.SigAltStackInstallCandidateCount
            << ",\"sigaltstack_install_success_count\":"
            << SyscallHandler.SigAltStackInstallSuccessCount
            << ",\"sigaltstack_no_host_install_count\":"
            << SyscallHandler.SigAltStackNoHostInstallCount
            << ",\"sigaltstack_other_shape_count\":"
            << SyscallHandler.SigAltStackOtherShapeCount
            << ",\"sigaltstack_last_linux_error\":"
            << SyscallHandler.SigAltStackLastLinuxError
            << ",\"sigaltstack_last_failure_reason\":\""
            << SyscallHandler.SigAltStackLastFailureReason << "\""
            << ",\"sigaltstack_guest_state_installed\":"
            << (SyscallHandler.SigAltStackGuestStateInstalled ? "true" : "false")
            << ",\"sigaltstack_guest_state_pointer\":"
            << SyscallHandler.SigAltStackGuestState.StackPointer
            << ",\"sigaltstack_guest_state_flags\":"
            << SyscallHandler.SigAltStackGuestState.Flags
            << ",\"sigaltstack_guest_state_size\":"
            << SyscallHandler.SigAltStackGuestState.Size
            << ",\"stat_syscall_seen\":" << (SyscallHandler.StatSeen ? "true" : "false")
            << ",\"stat_call_count\":" << SyscallHandler.StatCallCount
            << ",\"stat_success_count\":" << SyscallHandler.StatSuccessCount
            << ",\"mmap_syscall_seen\":" << (SyscallHandler.MMapSeen ? "true" : "false")
            << ",\"mmap_call_count\":" << SyscallHandler.MMapCallCount
            << ",\"mmap_success_count\":" << SyscallHandler.MMapSuccessCount
            << ",\"mmap_file_byte_count\":" << SyscallHandler.MMapFileByteCount
            << ",\"mmap_failure_count\":" << SyscallHandler.MMapFailureCount
            << ",\"mmap_fixed_call_count\":" << SyscallHandler.MMapFixedCallCount
            << ",\"mmap_fixed_noreplace_call_count\":"
            << SyscallHandler.MMapFixedNoReplaceCallCount
            << ",\"mmap_anonymous_call_count\":" << SyscallHandler.MMapAnonymousCallCount
            << ",\"mmap_stack_call_count\":" << SyscallHandler.MMapStackCallCount
            << ",\"mmap_arena_reject_count\":" << SyscallHandler.MMapArenaRejectCount
            << ",\"mmap_arena_reject_record_count\":"
            << SyscallHandler.MMapArenaRejectRecordCount
            << ",\"mmap_arena_reject_record_overflow\":"
            << (SyscallHandler.MMapArenaRejectRecordOverflow ? "true" : "false")
            << ",\"mmap_arena_reject_records\":[";
  for (uint64_t Index = 0; Index < SyscallHandler.MMapArenaRejectRecordCount; ++Index) {
    const MMapArenaRejectRecord& Record = SyscallHandler.MMapArenaRejectRecords[Index];
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"syscall_ordinal\":" << Record.SyscallOrdinal
              << ",\"guest_rip\":" << Record.GuestRIP
              << ",\"guest_rsp\":" << Record.GuestRSP
              << ",\"guest_return_address\":" << Record.GuestReturnAddress
              << ",\"guest_return_address_readable\":"
              << (Record.GuestReturnAddressReadable ? "true" : "false")
              << ",\"guest_stack_word_count\":" << Record.GuestStackWordCount
              << ",\"guest_stack_words\":[";
    for (uint64_t StackIndex = 0; StackIndex < Record.GuestStackWordCount; ++StackIndex) {
      if (StackIndex != 0) {
        std::cout << ',';
      }
      std::cout << Record.GuestStackWords[StackIndex];
    }
    std::cout << ']'
              << ",\"requested_address\":" << Record.RequestedAddress
              << ",\"mapping_address\":" << Record.MappingAddress
              << ",\"length\":" << Record.Length
              << ",\"aligned_length\":" << Record.AlignedLength
              << ",\"protection\":" << Record.Protection
              << ",\"flags\":" << Record.Flags
              << ",\"offset\":" << Record.Offset
              << ",\"next_mmap_address\":" << Record.NextMMapAddress
              << ",\"descriptor\":" << Record.Descriptor
              << ",\"shared_file_shape\":"
              << (Record.SharedFileShape ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"mmap_shared_file_candidate_count\":"
            << SyscallHandler.MMapSharedFileCandidateCount
            << ",\"mmap_shared_file_success_count\":"
            << SyscallHandler.MMapSharedFileSuccessCount
            << ",\"mmap_shared_file_arena_replacement_count\":"
            << SyscallHandler.MMapSharedFileArenaReplacementCount
            << ",\"mmap_shared_file_last_descriptor\":"
            << SyscallHandler.MMapSharedFileLastDescriptor
            << ",\"mmap_shared_file_last_descriptor_matches_memfd\":"
            << (SyscallHandler.MMapSharedFileLastDescriptorMatchesMemfd ? "true" : "false")
            << ",\"mmap_shared_file_last_descriptor_stat_succeeded\":"
            << (SyscallHandler.MMapSharedFileLastDescriptorStatSucceeded ? "true" : "false")
            << ",\"mmap_shared_file_last_descriptor_regular\":"
            << (SyscallHandler.MMapSharedFileLastDescriptorRegular ? "true" : "false")
            << ",\"mmap_shared_file_last_descriptor_size\":"
            << SyscallHandler.MMapSharedFileLastDescriptorSize
            << ",\"mmap_shared_file_last_length\":"
            << SyscallHandler.MMapSharedFileLastLength
            << ",\"mmap_shared_file_last_protection\":"
            << SyscallHandler.MMapSharedFileLastProtection
            << ",\"mmap_shared_file_last_offset\":"
            << SyscallHandler.MMapSharedFileLastOffset
            << ",\"mmap_shared_file_last_host_page_size\":"
            << SyscallHandler.MMapSharedFileLastHostPageSize
            << ",\"mmap_shared_file_last_host_mapping_span\":"
            << SyscallHandler.MMapSharedFileLastHostMappingSpan
            << ",\"mmap_shared_file_last_host_address_remainder\":"
            << SyscallHandler.MMapSharedFileLastHostAddressRemainder
            << ",\"mmap_shared_fixed_low_candidate_count\":"
            << SyscallHandler.MMapSharedFixedLowCandidateCount
            << ",\"mmap_shared_fixed_low_last_descriptor\":"
            << SyscallHandler.MMapSharedFixedLowLastDescriptor
            << ",\"mmap_shared_fixed_low_last_descriptor_received_scm_rights\":"
            << (SyscallHandler.MMapSharedFixedLowLastDescriptorReceivedSCMRights ? "true" : "false")
            << ",\"mmap_shared_fixed_low_last_descriptor_stat_succeeded\":"
            << (SyscallHandler.MMapSharedFixedLowLastDescriptorStatSucceeded ? "true" : "false")
            << ",\"mmap_shared_fixed_low_last_descriptor_regular\":"
            << (SyscallHandler.MMapSharedFixedLowLastDescriptorRegular ? "true" : "false")
            << ",\"mmap_shared_fixed_low_last_descriptor_size\":"
            << SyscallHandler.MMapSharedFixedLowLastDescriptorSize
            << ",\"mmap_shared_fixed_low_last_protection\":"
            << SyscallHandler.MMapSharedFixedLowLastProtection
            << ",\"mmap_shared_fixed_low_last_flags\":"
            << SyscallHandler.MMapSharedFixedLowLastFlags
            << ",\"mmap_shared_fixed_low_last_offset\":"
            << SyscallHandler.MMapSharedFixedLowLastOffset
            << ",\"mmap_shared_fixed_low_attempt_count\":"
            << SyscallHandler.MMapSharedFixedLowAttemptCount
            << ",\"mmap_shared_fixed_low_success_count\":"
            << SyscallHandler.MMapSharedFixedLowSuccessCount
            << ",\"mmap_shared_fixed_low_failure_count\":"
            << SyscallHandler.MMapSharedFixedLowFailureCount
            << ",\"mmap_shared_fixed_low_last_host_address\":"
            << SyscallHandler.MMapSharedFixedLowLastHostAddress
            << ",\"mmap_shared_fixed_low_last_host_span\":"
            << SyscallHandler.MMapSharedFixedLowLastHostSpan
            << ",\"mmap_shared_fixed_low_last_host_mapped_subpage_mask\":"
            << SyscallHandler.MMapSharedFixedLowLastHostMappedSubpageMask
            << ",\"mmap_shared_fixed_low_last_host_packed_subpage_states\":"
            << SyscallHandler.MMapSharedFixedLowLastHostPackedSubpageStates
            << ",\"mmap_last_requested_address\":" << SyscallHandler.MMapLastRequestedAddress
            << ",\"mmap_last_length\":" << SyscallHandler.MMapLastLength
            << ",\"mmap_last_aligned_length\":" << SyscallHandler.MMapLastAlignedLength
            << ",\"mmap_last_protection\":" << SyscallHandler.MMapLastProtection
            << ",\"mmap_last_flags\":" << SyscallHandler.MMapLastFlags
            << ",\"mmap_last_offset\":" << SyscallHandler.MMapLastOffset
            << ",\"mmap_last_mapping_address\":" << SyscallHandler.MMapLastMappingAddress
            << ",\"mmap_last_linux_error\":" << SyscallHandler.MMapLastLinuxError
            << ",\"mmap_last_descriptor_class\":\"" << SyscallHandler.MMapLastDescriptorClass << "\""
            << ",\"mmap_last_failure_reason\":\"" << SyscallHandler.MMapLastFailureReason << "\""
            << ",\"mmap_call_record_count\":"
            << SyscallHandler.MMapCallRecordCount
            << ",\"mmap_call_record_overflow\":"
            << (SyscallHandler.MMapCallRecordOverflow ? "true" : "false")
            << ",\"mmap_call_records\":[";
  for (uint64_t Index = 0; Index < SyscallHandler.MMapCallRecordCount; ++Index) {
    const MMapCallRecord& Record = SyscallHandler.MMapCallRecords[Index];
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"syscall_ordinal\":" << Record.SyscallOrdinal
              << ",\"guest_rip\":" << Record.GuestRIP
              << ",\"guest_rsp\":" << Record.GuestRSP
              << ",\"guest_rbp\":" << Record.GuestRBP
              << ",\"guest_return_address\":" << Record.GuestReturnAddress
              << ",\"guest_return_address_readable\":"
              << (Record.GuestReturnAddressReadable ? "true" : "false")
              << ",\"guest_header_buffer\":" << Record.GuestHeaderBuffer
              << ",\"guest_header_readable\":"
              << (Record.GuestHeaderReadable ? "true" : "false")
              << ",\"guest_header_first_64_byte_fingerprint\":"
              << Record.GuestHeaderFirst64ByteFingerprint
              << ",\"guest_header_magic\":" << Record.GuestHeaderMagic
              << ",\"guest_header_type\":" << Record.GuestHeaderType
              << ",\"guest_header_machine\":" << Record.GuestHeaderMachine
              << ",\"guest_header_entry\":" << Record.GuestHeaderEntry
              << ",\"requested_address\":" << Record.RequestedAddress
              << ",\"length\":" << Record.Length
              << ",\"protection\":" << Record.Protection
              << ",\"flags\":" << Record.Flags
              << ",\"offset\":" << Record.Offset
              << ",\"descriptor\":" << Record.Descriptor
              << ",\"completed\":" << (Record.Completed ? "true" : "false")
              << ",\"succeeded\":" << (Record.Succeeded ? "true" : "false")
              << ",\"returned_value\":" << Record.ReturnedValue
              << ",\"linux_error\":" << Record.LinuxError
              << ",\"mapping_address\":" << Record.MappingAddress
              << ",\"outcome_reason\":\"" << Record.OutcomeReason << "\""
              << '}';
  }
  std::cout << ']'
            << ",\"high_mmap_record_count\":"
            << SyscallHandler.HighMMapRecordCount
            << ",\"high_mmap_record_overflow\":"
            << (SyscallHandler.HighMMapRecordOverflow ? "true" : "false")
            << ",\"high_mmap_records\":[";
  for (uint64_t Index = 0; Index < SyscallHandler.HighMMapRecordCount; ++Index) {
    const HighMMapRecord& Record = SyscallHandler.HighMMapRecords[Index];
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"address\":" << Record.Address
              << ",\"length\":" << Record.Length
              << ",\"arena_end\":" << Record.ArenaEnd
              << ",\"protection\":" << Record.Protection
              << ",\"flags\":" << Record.Flags
              << ",\"offset\":" << Record.Offset
              << ",\"descriptor\":" << Record.Descriptor
              << ",\"descriptor_path_class\":\""
              << Record.DescriptorPathClass << "\""
              << ",\"descriptor_guest_path\":\""
              << Record.DescriptorGuestPath << "\""
              << ",\"contains_signal_fault\":"
              << (GuestSignalBoundaryFaultAddress >= Record.Address
                  && GuestSignalBoundaryFaultAddress - Record.Address < Record.Length
                ? "true" : "false")
              << ",\"contains_recovered_guest_rip\":"
              << (GuestSignalBoundaryRecoveredGuestRIP >= Record.Address
                  && GuestSignalBoundaryRecoveredGuestRIP - Record.Address < Record.Length
                ? "true" : "false")
              << ",\"active\":" << (Record.Active ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"low_mmap_record_count\":"
            << SyscallHandler.LowMMapRecordCount
            << ",\"low_mmap_record_overflow\":"
            << (SyscallHandler.LowMMapRecordOverflow ? "true" : "false")
            << ",\"low_mmap_records\":[";
  for (uint64_t Index = 0; Index < SyscallHandler.LowMMapRecordCount; ++Index) {
    const LowMMapRecord& Record = SyscallHandler.LowMMapRecords[Index];
    if (Index != 0) {
      std::cout << ',';
    }
    std::cout << "{\"address\":" << Record.Address
              << ",\"length\":" << Record.Length
              << ",\"protection\":" << Record.Protection
              << ",\"flags\":" << Record.Flags
              << ",\"offset\":" << Record.Offset
              << ",\"descriptor\":" << Record.Descriptor
              << ",\"descriptor_path_class\":\""
              << Record.DescriptorPathClass << "\""
              << ",\"descriptor_guest_path\":\""
              << Record.DescriptorGuestPath << "\""
              << ",\"contains_signal_fault\":"
              << (GuestSignalBoundaryFaultAddress >= Record.Address
                  && GuestSignalBoundaryFaultAddress - Record.Address < Record.Length
                ? "true" : "false")
              << ",\"contains_recovered_guest_rip\":"
              << (GuestSignalBoundaryRecoveredGuestRIP >= Record.Address
                  && GuestSignalBoundaryRecoveredGuestRIP - Record.Address < Record.Length
                ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"munmap_syscall_seen\":"
            << (SyscallHandler.MUnmapSeen ? "true" : "false")
            << ",\"munmap_call_count\":" << SyscallHandler.MUnmapCallCount
            << ",\"munmap_success_count\":" << SyscallHandler.MUnmapSuccessCount
            << ",\"munmap_logical_lifo_count\":"
            << SyscallHandler.MUnmapLogicalLIFOCount
            << ",\"munmap_record_deactivation_count\":"
            << SyscallHandler.MUnmapRecordDeactivationCount
            << ",\"munmap_last_address\":" << SyscallHandler.MUnmapLastAddress
            << ",\"munmap_last_length\":" << SyscallHandler.MUnmapLastLength
            << ",\"munmap_last_active_record_index_plus_one\":"
            << SyscallHandler.MUnmapLastActiveRecordIndexPlusOne
            << ",\"munmap_last_active_record_arena_end\":"
            << SyscallHandler.MUnmapLastActiveRecordArenaEnd
            << ",\"munmap_last_active_record_protection\":"
            << SyscallHandler.MUnmapLastActiveRecordProtection
            << ",\"munmap_last_active_record_flags\":"
            << SyscallHandler.MUnmapLastActiveRecordFlags
            << ",\"munmap_last_linux_error\":"
            << SyscallHandler.MUnmapLastLinuxError
            << ",\"munmap_last_range_zeroed\":"
            << (SyscallHandler.MUnmapLastRangeZeroed ? "true" : "false")
            << ",\"munmap_last_cursor_rewound\":"
            << (SyscallHandler.MUnmapLastCursorRewound ? "true" : "false")
            << ",\"munmap_last_host_pages_released\":"
            << (SyscallHandler.MUnmapLastHostPagesReleased ? "true" : "false")
            << ",\"munmap_last_failure_reason\":\""
            << MUnmapFailureReasonName(SyscallHandler.MUnmapLastFailureReason) << "\""
            << ",\"clone3_syscall_seen\":" << (SyscallHandler.Clone3Seen ? "true" : "false")
            << ",\"clone3_call_count\":" << SyscallHandler.Clone3CallCount
            << ",\"clone3_clear_sighand_fallback_count\":"
            << SyscallHandler.Clone3ClearSighandFallbackCount
            << ",\"clone3_last_structure_readable\":"
            << (SyscallHandler.Clone3LastStructureReadable ? "true" : "false")
            << ",\"clone3_last_size\":" << SyscallHandler.Clone3LastSize
            << ",\"clone3_last_flags\":" << SyscallHandler.Clone3LastFlags
            << ",\"clone3_last_exit_signal\":" << SyscallHandler.Clone3LastExitSignal
            << ",\"clone3_last_stack_size\":" << SyscallHandler.Clone3LastStackSize
            << ",\"clone3_last_linux_error\":" << SyscallHandler.Clone3LastLinuxError
            << ",\"clone3_last_failure_reason\":\""
            << SyscallHandler.Clone3LastFailureReason << "\""
            << ",\"virtual_vfork_child_instrumentation_enabled\":"
            << (SyscallHandler.VForkChildInstrumentationEnabled ? "true" : "false")
            << ",\"virtual_vfork_parent_instrumentation_enabled\":"
            << (SyscallHandler.VForkParentInstrumentationEnabled ? "true" : "false")
            << ",\"virtual_vfork_parent_process_bridge_enabled\":"
            << (SyscallHandler.VForkParentProcessBridgeEnabled ? "true" : "false")
            << ",\"virtual_vfork_parent_wineserver_bridge_enabled\":"
            << (SyscallHandler.VForkParentWineServerBridgeEnabled ? "true" : "false")
            << ",\"virtual_vfork_child_entered\":"
            << (SyscallHandler.VirtualVForkChildEntered ? "true" : "false")
            << ",\"virtual_vfork_child_stack_applied\":"
            << (SyscallHandler.VirtualVForkChildStackApplied ? "true" : "false")
            << ",\"virtual_vfork_child_entry_count\":"
            << SyscallHandler.VirtualVForkChildEntryCount
            << ",\"virtual_vfork_parent_entered\":"
            << (SyscallHandler.VirtualVForkParentEntered ? "true" : "false")
            << ",\"virtual_vfork_parent_entry_count\":"
            << SyscallHandler.VirtualVForkParentEntryCount
            << ",\"virtual_vfork_parent_diagnostic_pid\":"
            << SyscallHandler.VirtualVForkParentDiagnosticPID
            << ",\"virtual_vfork_parent_resumed\":"
            << (SyscallHandler.VirtualVForkParentResumed ? "true" : "false")
            << ",\"virtual_vfork_parent_stack_unmap_accepted\":"
            << (SyscallHandler.VirtualVForkParentStackUnmapAccepted ? "true" : "false")
            << ",\"virtual_vfork_parent_stack_unmap_accept_count\":"
            << SyscallHandler.VirtualVForkParentStackUnmapAcceptCount
            << ",\"virtual_vfork_parent_stack_unmap_address\":"
            << SyscallHandler.VirtualVForkParentStackUnmapAddress
            << ",\"virtual_vfork_parent_stack_unmap_length\":"
            << SyscallHandler.VirtualVForkParentStackUnmapLength
            << ",\"virtual_vfork_bridge_spawn_attempt_count\":"
            << SyscallHandler.VirtualVForkBridgeSpawnAttemptCount
            << ",\"virtual_vfork_bridge_spawn_result\":"
            << SyscallHandler.VirtualVForkBridgeSpawnResult
            << ",\"virtual_vfork_bridge_process_id\":"
            << SyscallHandler.VirtualVForkBridgeProcessID
            << ",\"virtual_vfork_bridge_process_id_positive\":"
            << (SyscallHandler.VirtualVForkBridgeProcessIDPositive ? "true" : "false")
            << ",\"virtual_vfork_bridge_signal_mask_explicit\":"
            << (SyscallHandler.VirtualVForkBridgeSignalMaskExplicit ? "true" : "false")
            << ",\"virtual_vfork_bridge_signal_defaults_explicit\":"
            << (SyscallHandler.VirtualVForkBridgeSignalDefaultsExplicit ? "true" : "false")
            << ",\"virtual_vfork_bridge_wait_seen\":"
            << (SyscallHandler.VirtualVForkBridgeWaitSeen ? "true" : "false")
            << ",\"virtual_vfork_bridge_wait_pid_matched\":"
            << (SyscallHandler.VirtualVForkBridgeWaitPIDMatched ? "true" : "false")
            << ",\"virtual_vfork_bridge_wait_status_writable\":"
            << (SyscallHandler.VirtualVForkBridgeWaitStatusWritable ? "true" : "false")
            << ",\"virtual_vfork_bridge_wait_resource_usage_zero\":"
            << (SyscallHandler.VirtualVForkBridgeWaitResourceUsageZero ? "true" : "false")
            << ",\"virtual_vfork_bridge_wait_success_count\":"
            << SyscallHandler.VirtualVForkBridgeWaitSuccessCount
            << ",\"virtual_vfork_bridge_wait_result\":"
            << SyscallHandler.VirtualVForkBridgeWaitResult
            << ",\"virtual_vfork_bridge_host_wait_status\":"
            << SyscallHandler.VirtualVForkBridgeHostWaitStatus
            << ",\"virtual_vfork_bridge_child_exited\":"
            << (SyscallHandler.VirtualVForkBridgeChildExited ? "true" : "false")
            << ",\"virtual_vfork_bridge_child_exit_code\":"
            << SyscallHandler.VirtualVForkBridgeChildExitCode
            << ",\"virtual_vfork_bridge_child_reaped\":"
            << (SyscallHandler.VirtualVForkBridgeChildReaped ? "true" : "false")
            << ",\"virtual_vfork_bridge_last_host_error\":"
            << SyscallHandler.VirtualVForkBridgeLastHostError
            << ",\"virtual_vfork_wineserver_spawn_attempt_count\":"
            << SyscallHandler.VirtualVForkWineServerSpawnAttemptCount
            << ",\"virtual_vfork_wineserver_spawn_result\":"
            << SyscallHandler.VirtualVForkWineServerSpawnResult
            << ",\"virtual_vfork_wineserver_process_id\":"
            << SyscallHandler.VirtualVForkWineServerProcessID
            << ",\"virtual_vfork_wineserver_process_id_positive\":"
            << (SyscallHandler.VirtualVForkWineServerProcessIDPositive ? "true" : "false")
            << ",\"virtual_vfork_wineserver_signal_mask_explicit\":"
            << (SyscallHandler.VirtualVForkWineServerSignalMaskExplicit ? "true" : "false")
            << ",\"virtual_vfork_wineserver_signal_defaults_explicit\":"
            << (SyscallHandler.VirtualVForkWineServerSignalDefaultsExplicit ? "true" : "false")
            << ",\"virtual_vfork_wineserver_guest_socket_path\":\""
            << SyscallHandler.VirtualVForkWineServerGuestSocketPath << "\""
            << ",\"virtual_vfork_wineserver_socket_ready\":"
            << (SyscallHandler.VirtualVForkWineServerSocketReady ? "true" : "false")
            << ",\"virtual_vfork_wineserver_socket_readiness_poll_count\":"
            << SyscallHandler.VirtualVForkWineServerSocketReadinessPollCount
            << ",\"virtual_vfork_wineserver_exited_before_ready\":"
            << (SyscallHandler.VirtualVForkWineServerExitedBeforeReady ? "true" : "false")
            << ",\"virtual_vfork_wineserver_process_reaped\":"
            << (SyscallHandler.VirtualVForkWineServerProcessReaped ? "true" : "false")
            << ",\"virtual_vfork_wineserver_host_wait_status\":"
            << SyscallHandler.VirtualVForkWineServerHostWaitStatus
            << ",\"virtual_vfork_wineserver_child_exited\":"
            << (SyscallHandler.VirtualVForkWineServerChildExited ? "true" : "false")
            << ",\"virtual_vfork_wineserver_child_exit_code\":"
            << SyscallHandler.VirtualVForkWineServerChildExitCode
            << ",\"virtual_vfork_wineserver_child_signaled\":"
            << (SyscallHandler.VirtualVForkWineServerChildSignaled ? "true" : "false")
            << ",\"virtual_vfork_wineserver_child_term_signal\":"
            << SyscallHandler.VirtualVForkWineServerChildTermSignal
            << ",\"virtual_vfork_wineserver_cleanup_signal_sent\":"
            << (SyscallHandler.VirtualVForkWineServerCleanupSignalSent ? "true" : "false")
            << ",\"virtual_vfork_wineserver_force_kill_signal_sent\":"
            << (SyscallHandler.VirtualVForkWineServerForceKillSignalSent ? "true" : "false")
            << ",\"virtual_vfork_wineserver_finalized\":"
            << (SyscallHandler.VirtualVForkWineServerFinalized ? "true" : "false")
            << ",\"virtual_vfork_wineserver_last_host_error\":"
            << SyscallHandler.VirtualVForkWineServerLastHostError
            << ",\"rt_sigaction_syscall_seen\":"
            << (SyscallHandler.RtSigactionSeen ? "true" : "false")
            << ",\"rt_sigaction_call_count\":" << SyscallHandler.RtSigactionCallCount
            << ",\"rt_sigaction_query_success_count\":"
            << SyscallHandler.RtSigactionQuerySuccessCount
            << ",\"rt_sigaction_set_success_count\":"
            << SyscallHandler.RtSigactionSetSuccessCount
            << ",\"rt_sigaction_guest_sigpipe_ignore_success_count\":"
            << SyscallHandler.RtSigactionGuestSigpipeIgnoreSuccessCount
            << ",\"rt_sigaction_guest_table_only_success_count\":"
            << SyscallHandler.RtSigactionGuestTableOnlySuccessCount
            << ",\"rt_sigaction_last_signal\":" << SyscallHandler.RtSigactionLastSignal
            << ",\"rt_sigaction_last_sigset_size\":"
            << SyscallHandler.RtSigactionLastSigsetSize
            << ",\"rt_sigaction_last_action_fingerprint\":"
            << SyscallHandler.RtSigactionLastActionFingerprint
            << ",\"rt_sigaction_internal_candidate_seen\":"
            << (SyscallHandler.RtSigactionInternalCandidateSeen ? "true" : "false")
            << ",\"rt_sigaction_internal_candidate_signal\":"
            << SyscallHandler.RtSigactionInternalCandidateSignal
            << ",\"rt_sigaction_internal_action_contained\":"
            << (SyscallHandler.RtSigactionInternalActionContained ? "true" : "false")
            << ",\"rt_sigaction_internal_handler_matches\":"
            << (SyscallHandler.RtSigactionInternalHandlerMatches ? "true" : "false")
            << ",\"rt_sigaction_internal_flags_match\":"
            << (SyscallHandler.RtSigactionInternalFlagsMatch ? "true" : "false")
            << ",\"rt_sigaction_internal_restorer_matches\":"
            << (SyscallHandler.RtSigactionInternalRestorerMatches ? "true" : "false")
            << ",\"rt_sigaction_internal_mask_matches_process\":"
            << (SyscallHandler.RtSigactionInternalMaskMatchesProcess ? "true" : "false")
            << ",\"rt_sigaction_internal_candidate_mask_fingerprint\":"
            << SyscallHandler.RtSigactionInternalCandidateMaskFingerprint
            << ",\"rt_sigaction_internal_process_mask_fingerprint\":"
            << SyscallHandler.RtSigactionInternalProcessMaskFingerprint
            << ",\"low_page_alias_mode_enabled\":"
            << (SyscallHandler.LowPageAliasModeEnabled ? "true" : "false")
            << ",\"low_page_alias_request_seen\":"
            << (SyscallHandler.LowPageAliasRequestSeen ? "true" : "false")
            << ",\"low_page_alias_request_count\":"
            << SyscallHandler.LowPageAliasRequestCount
            << ",\"low_page_alias_accepted\":"
            << (SyscallHandler.LowPageAliasAccepted ? "true" : "false")
            << ",\"low_page_alias_accept_count\":"
            << SyscallHandler.LowPageAliasAcceptCount
            << ",\"low_page_alias_backing_zeroed\":"
            << (SyscallHandler.LowPageAliasBackingZeroed ? "true" : "false")
            << ",\"low_page_alias_guest_address\":" << LinuxSharedUserDataAddress
            << ",\"low_page_alias_guest_length\":" << LinuxSharedUserDataSize
            << ",\"low_page_alias_host_backing_offset\":" << RealLowPageAliasOffset
            << ",\"low_page_alias_fault_boundary\":"
            << (GuestSignalBoundarySeen && SyscallHandler.LowPageAliasAccepted
                  && GuestSignalBoundaryFaultAddress >= LinuxSharedUserDataAddress
                  && GuestSignalBoundaryFaultAddress
                    < LinuxSharedUserDataAddress + LinuxSharedUserDataSize
                ? "true" : "false")
            << ",\"low_page_alias_fault_offset\":";
  if (GuestSignalBoundarySeen && GuestSignalBoundaryFaultAddress >= LinuxSharedUserDataAddress
      && GuestSignalBoundaryFaultAddress < LinuxSharedUserDataAddress + LinuxSharedUserDataSize) {
    std::cout << GuestSignalBoundaryFaultAddress - LinuxSharedUserDataAddress;
  } else {
    std::cout << "null";
  }
  std::cout
            << ",\"low_memory_bias_mode_enabled\":"
            << (SyscallHandler.LowMemoryBiasModeEnabled ? "true" : "false")
            << ",\"low_memory_shadow_reserved\":"
            << (InstrumentLowMemoryBias && LowGuestShadow.IsAllocated() ? "true" : "false")
            << ",\"low_memory_shadow_guest_limit\":" << LowGuestAddressLimit
            << ",\"low_memory_shadow_host_page_size\":"
            << (InstrumentLowMemoryBias ? LowGuestShadow.HostPageBytes() : 0)
            << ",\"low_memory_sparse_redirect_enabled\":"
            << (InstrumentLowMemoryBias && LowGuestShadow.RedirectHostPageAddress() != 0
                  ? "true" : "false")
            << ",\"low_memory_sparse_redirect_guest_page\":"
            << (InstrumentLowMemoryBias ? LowGuestShadow.RedirectGuestPageAddress() : 0)
            << ",\"low_memory_sparse_redirect_host_page\":"
            << (InstrumentLowMemoryBias ? LowGuestShadow.RedirectHostPageAddress() : 0)
            << ",\"low_memory_host_low_mapping_created\":false"
            << ",\"low_memory_exec_host_enforced\":false"
            << ",\"low_memory_mmap_request_count\":"
            << SyscallHandler.LowMemoryMMapRequestCount
            << ",\"low_memory_mmap_success_count\":"
            << SyscallHandler.LowMemoryMMapSuccessCount
            << ",\"low_memory_mmap_failure_count\":"
            << SyscallHandler.LowMemoryMMapFailureCount
            << ",\"low_memory_mprotect_request_count\":"
            << SyscallHandler.LowMemoryMProtectRequestCount
            << ",\"low_memory_mprotect_success_count\":"
            << SyscallHandler.LowMemoryMProtectSuccessCount
            << ",\"low_memory_mprotect_failure_count\":"
            << SyscallHandler.LowMemoryMProtectFailureCount
            << ",\"low_memory_shadow_successful_map_count\":"
            << LowGuestShadow.SuccessfulMapCount()
            << ",\"low_memory_shadow_successful_protect_count\":"
            << LowGuestShadow.SuccessfulProtectCount()
            << ",\"low_memory_shadow_mapped_guest_pages\":"
            << LowGuestShadow.TotalMappedGuestPages()
            << ",\"high_memory_region_mode_enabled\":"
            << (SyscallHandler.HighMemoryRegionModeEnabled ? "true" : "false")
            << ",\"high_memory_region_reserved\":"
            << (InstrumentHighMemoryRegion && HighGuestSparse.IsAllocated() ? "true" : "false")
            << ",\"high_memory_region_guest_base\":" << HighSparseGuestBase
            << ",\"high_memory_region_host_base\":"
            << (InstrumentHighMemoryRegion ? HighGuestSparse.HostBase() : 0)
            << ",\"high_memory_region_size\":"
            << (InstrumentHighMemoryRegion ? HighGuestSparse.Size() : 0)
            << ",\"high_memory_region_host_page_size\":"
            << (InstrumentHighMemoryRegion ? HighGuestSparse.HostPageBytes() : 0)
            << ",\"high_memory_mmap_request_count\":"
            << SyscallHandler.HighMemoryMMapRequestCount
            << ",\"high_memory_mmap_success_count\":"
            << SyscallHandler.HighMemoryMMapSuccessCount
            << ",\"high_memory_mmap_failure_count\":"
            << SyscallHandler.HighMemoryMMapFailureCount
            << ",\"high_memory_mprotect_request_count\":"
            << SyscallHandler.HighMemoryMProtectRequestCount
            << ",\"high_memory_mprotect_success_count\":"
            << SyscallHandler.HighMemoryMProtectSuccessCount
            << ",\"high_memory_mprotect_failure_count\":"
            << SyscallHandler.HighMemoryMProtectFailureCount
            << ",\"high_memory_munmap_request_count\":"
            << SyscallHandler.HighMemoryMUnmapRequestCount
            << ",\"high_memory_munmap_success_count\":"
            << SyscallHandler.HighMemoryMUnmapSuccessCount
            << ",\"high_memory_munmap_failure_count\":"
            << SyscallHandler.HighMemoryMUnmapFailureCount
            << ",\"high_memory_region_successful_map_count\":"
            << HighGuestSparse.SuccessfulMapCount()
            << ",\"high_memory_region_successful_protect_count\":"
            << HighGuestSparse.SuccessfulProtectCount()
            << ",\"high_memory_region_successful_unmap_count\":"
            << HighGuestSparse.SuccessfulUnmapCount()
            << ",\"high_memory_region_mapped_guest_pages\":"
            << HighGuestSparse.TotalMappedGuestPages()
            << ",\"close_syscall_seen\":" << (SyscallHandler.CloseSeen ? "true" : "false")
            << ",\"close_call_count\":" << SyscallHandler.CloseCallCount
            << ",\"close_success_count\":" << SyscallHandler.CloseSuccessCount
            << ",\"prctl_syscall_seen\":" << (SyscallHandler.PrctlSeen ? "true" : "false")
            << ",\"prctl_call_count\":" << SyscallHandler.PrctlCallCount
            << ",\"prctl_set_name_success_count\":"
            << SyscallHandler.PrctlSetNameSuccessCount
            << ",\"prctl_last_name_length\":" << SyscallHandler.PrctlLastNameLength
            << ",\"prctl_last_name_fingerprint\":"
            << SyscallHandler.PrctlLastNameFingerprint
            << ",\"userfaultfd_syscall_seen\":"
            << (SyscallHandler.UserfaultfdSeen ? "true" : "false")
            << ",\"userfaultfd_call_count\":" << SyscallHandler.UserfaultfdCallCount
            << ",\"userfaultfd_unavailable_count\":"
            << SyscallHandler.UserfaultfdUnavailableCount
            << ",\"userfaultfd_last_flags\":" << SyscallHandler.UserfaultfdLastFlags
            << ",\"rt_sigprocmask_syscall_seen\":"
            << (SyscallHandler.RtSigprocmaskSeen ? "true" : "false")
            << ",\"rt_sigprocmask_call_count\":" << SyscallHandler.RtSigprocmaskCallCount
            << ",\"rt_sigprocmask_success_count\":" << SyscallHandler.RtSigprocmaskSuccessCount
            << ",\"rt_sigprocmask_query_success_count\":"
            << SyscallHandler.RtSigprocmaskQuerySuccessCount
            << ",\"rt_sigprocmask_last_how\":" << SyscallHandler.RtSigprocmaskLastHow
            << ",\"rt_sigprocmask_last_sigset_size\":"
            << SyscallHandler.RtSigprocmaskLastSigsetSize
            << ",\"rt_sigprocmask_last_mask_fingerprint\":"
            << SyscallHandler.RtSigprocmaskLastMaskFingerprint
            << ",\"arch_prctl_syscall_seen\":" << (SyscallHandler.ArchPrctlSeen ? "true" : "false")
            << ",\"arch_prctl_call_count\":" << SyscallHandler.ArchPrctlCallCount
            << ",\"arch_prctl_set_fs_count\":" << SyscallHandler.ArchPrctlSetFSCount
            << ",\"arch_prctl_set_gs_count\":" << SyscallHandler.ArchPrctlSetGSCount
            << ",\"set_tid_address_syscall_seen\":" << (SyscallHandler.SetTIDAddressSeen ? "true" : "false")
            << ",\"set_tid_address_call_count\":" << SyscallHandler.SetTIDAddressCallCount
            << ",\"set_robust_list_syscall_seen\":" << (SyscallHandler.SetRobustListSeen ? "true" : "false")
            << ",\"set_robust_list_call_count\":" << SyscallHandler.SetRobustListCallCount
            << ",\"rseq_syscall_seen\":" << (SyscallHandler.RSeqSeen ? "true" : "false")
            << ",\"rseq_call_count\":" << SyscallHandler.RSeqCallCount
            << ",\"mprotect_syscall_seen\":" << (SyscallHandler.MProtectSeen ? "true" : "false")
            << ",\"mprotect_call_count\":" << SyscallHandler.MProtectCallCount
            << ",\"mprotect_logical_success_count\":" << SyscallHandler.MProtectLogicalSuccessCount
            << ",\"mprotect_host_enforced\":"
            << (SyscallHandler.LowMemoryMProtectSuccessCount != 0 ? "true" : "false")
            << ",\"prlimit64_syscall_seen\":" << (SyscallHandler.Prlimit64Seen ? "true" : "false")
            << ",\"prlimit64_call_count\":" << SyscallHandler.Prlimit64CallCount
            << ",\"prlimit64_success_count\":" << SyscallHandler.Prlimit64SuccessCount
            << ",\"prlimit64_stack_query_candidate_count\":"
            << SyscallHandler.Prlimit64StackQueryCandidateCount
            << ",\"prlimit64_stack_query_success_count\":"
            << SyscallHandler.Prlimit64StackQuerySuccessCount
            << ",\"prlimit64_stack_last_current\":"
            << SyscallHandler.Prlimit64StackLastCurrent
            << ",\"prlimit64_stack_last_maximum\":"
            << SyscallHandler.Prlimit64StackLastMaximum
            << ",\"prlimit64_nofile_query_candidate_count\":"
            << SyscallHandler.Prlimit64NoFileQueryCandidateCount
            << ",\"prlimit64_nofile_query_success_count\":"
            << SyscallHandler.Prlimit64NoFileQuerySuccessCount
            << ",\"prlimit64_nofile_last_current\":"
            << SyscallHandler.Prlimit64NoFileLastCurrent
            << ",\"prlimit64_nofile_last_maximum\":"
            << SyscallHandler.Prlimit64NoFileLastMaximum
            << ",\"prlimit64_nofile_set_candidate_count\":"
            << SyscallHandler.Prlimit64NoFileSetCandidateCount
            << ",\"prlimit64_nofile_set_success_count\":"
            << SyscallHandler.Prlimit64NoFileSetSuccessCount
            << ",\"prlimit64_nofile_set_failure_count\":"
            << SyscallHandler.Prlimit64NoFileSetFailureCount
            << ",\"prlimit64_nofile_set_last_requested_current\":"
            << SyscallHandler.Prlimit64NoFileSetLastRequestedCurrent
            << ",\"prlimit64_nofile_set_last_requested_maximum\":"
            << SyscallHandler.Prlimit64NoFileSetLastRequestedMaximum
            << ",\"prlimit64_nofile_set_last_host_error\":"
            << SyscallHandler.Prlimit64NoFileSetLastHostError
            << ",\"prlimit64_nofile_set_last_linux_error\":"
            << SyscallHandler.Prlimit64NoFileSetLastLinuxError
            << ",\"prlimit64_nofile_set_last_failure_reason\":\""
            << SyscallHandler.Prlimit64NoFileSetLastFailureReason << "\""
            << ",\"prlimit64_core_query_candidate_count\":"
            << SyscallHandler.Prlimit64CoreQueryCandidateCount
            << ",\"prlimit64_core_query_success_count\":"
            << SyscallHandler.Prlimit64CoreQuerySuccessCount
            << ",\"prlimit64_core_last_current\":"
            << SyscallHandler.Prlimit64CoreLastCurrent
            << ",\"prlimit64_core_last_maximum\":"
            << SyscallHandler.Prlimit64CoreLastMaximum
            << ",\"prlimit64_address_space_query_candidate_count\":"
            << SyscallHandler.Prlimit64AddressSpaceQueryCandidateCount
            << ",\"prlimit64_address_space_query_success_count\":"
            << SyscallHandler.Prlimit64AddressSpaceQuerySuccessCount
            << ",\"prlimit64_address_space_last_current\":"
            << SyscallHandler.Prlimit64AddressSpaceLastCurrent
            << ",\"prlimit64_address_space_last_maximum\":"
            << SyscallHandler.Prlimit64AddressSpaceLastMaximum
            << ",\"prlimit64_address_space_set_candidate_count\":"
            << SyscallHandler.Prlimit64AddressSpaceSetCandidateCount
            << ",\"prlimit64_address_space_set_success_count\":"
            << SyscallHandler.Prlimit64AddressSpaceSetSuccessCount
            << ",\"prlimit64_address_space_set_failure_count\":"
            << SyscallHandler.Prlimit64AddressSpaceSetFailureCount
            << ",\"prlimit64_address_space_set_last_requested_current\":"
            << SyscallHandler.Prlimit64AddressSpaceSetLastRequestedCurrent
            << ",\"prlimit64_address_space_set_last_requested_maximum\":"
            << SyscallHandler.Prlimit64AddressSpaceSetLastRequestedMaximum
            << ",\"prlimit64_address_space_set_last_host_error\":"
            << SyscallHandler.Prlimit64AddressSpaceSetLastHostError
            << ",\"prlimit64_address_space_set_last_linux_error\":"
            << SyscallHandler.Prlimit64AddressSpaceSetLastLinuxError
            << ",\"prlimit64_address_space_set_last_failure_reason\":\""
            << SyscallHandler.Prlimit64AddressSpaceSetLastFailureReason << "\""
            << ",\"prlimit64_nice_query_candidate_count\":"
            << SyscallHandler.Prlimit64NiceQueryCandidateCount
            << ",\"prlimit64_nice_query_unsupported_count\":"
            << SyscallHandler.Prlimit64NiceQueryUnsupportedCount
            << ",\"prlimit64_nice_query_last_linux_error\":"
            << SyscallHandler.Prlimit64NiceQueryLastLinuxError
            << ",\"prlimit64_nice_query_last_failure_reason\":\""
            << SyscallHandler.Prlimit64NiceQueryLastFailureReason << "\""
            << ",\"prlimit64_nice_set_candidate_count\":"
            << SyscallHandler.Prlimit64NiceSetCandidateCount
            << ",\"prlimit64_other_shape_count\":"
            << SyscallHandler.Prlimit64OtherShapeCount
            << ",\"prlimit64_nice_set_last_current\":"
            << SyscallHandler.Prlimit64NiceSetLastCurrent
            << ",\"prlimit64_nice_set_last_maximum\":"
            << SyscallHandler.Prlimit64NiceSetLastMaximum
            << ",\"prlimit64_nice_set_last_old_limit_class\":\""
            << SyscallHandler.Prlimit64NiceSetLastOldLimitClass << "\""
            << ",\"prlimit64_last_process_id\":" << SyscallHandler.Prlimit64LastProcessID
            << ",\"prlimit64_last_resource\":" << SyscallHandler.Prlimit64LastResource
            << ",\"prlimit64_last_new_limit_class\":\""
            << SyscallHandler.Prlimit64LastNewLimitClass << "\""
            << ",\"prlimit64_last_old_limit_class\":\""
            << SyscallHandler.Prlimit64LastOldLimitClass << "\""
            << ",\"prlimit64_last_current\":" << SyscallHandler.Prlimit64LastCurrent
            << ",\"prlimit64_last_maximum\":" << SyscallHandler.Prlimit64LastMaximum
            << ",\"prlimit64_last_host_error\":"
            << SyscallHandler.Prlimit64LastHostError
            << ",\"prlimit64_last_linux_error\":"
            << SyscallHandler.Prlimit64LastLinuxError
            << ",\"prlimit64_last_failure_reason\":\""
            << SyscallHandler.Prlimit64LastFailureReason << "\""
            << ",\"prlimit64_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.Prlimit64TraceCount; ++Index) {
    const auto& Trace = SyscallHandler.Prlimit64Trace[Index];
    if (Index != 0) std::cout << ',';
    std::cout << "{\"process_id\":" << Trace.ProcessID
              << ",\"resource\":" << Trace.Resource
              << ",\"new_limit_class\":\"" << Trace.NewLimitClass << "\""
              << ",\"old_limit_class\":\"" << Trace.OldLimitClass << "\""
              << ",\"requested_current\":" << Trace.RequestedCurrent
              << ",\"requested_maximum\":" << Trace.RequestedMaximum
              << '}';
  }
  std::cout << ']'
            << ",\"clock_gettime_syscall_seen\":" << (SyscallHandler.ClockGettimeSeen ? "true" : "false")
            << ",\"clock_gettime_call_count\":" << SyscallHandler.ClockGettimeCallCount
            << ",\"clock_gettime_success_count\":" << SyscallHandler.ClockGettimeSuccessCount
            << ",\"handle_syscall_call_count\":" << SyscallHandler.HandleSyscallCallCount
            << ",\"post_session_syscall_diagnostic_limit\":"
            << SyscallHandler.PostSessionSyscallDiagnosticLimit
            << ",\"post_session_syscall_diagnostic_call_count\":"
            << SyscallHandler.PostSessionSyscallDiagnosticCallCount
            << ",\"post_session_boundary_syscall_number\":"
            << SyscallHandler.PostSessionBoundarySyscallNumber
            << ",\"post_session_boundary_argument1_class\":\""
            << SyscallHandler.PostSessionBoundaryArgument1Class << "\""
            << ",\"post_session_boundary_epoll_pwait2_seen\":"
            << (SyscallHandler.PostSessionBoundaryEpollPWait2Seen ? "true" : "false")
            << ",\"post_session_boundary_epoll_pwait2_descriptor\":"
            << SyscallHandler.PostSessionBoundaryEpollPWait2Descriptor
            << ",\"post_session_boundary_epoll_pwait2_descriptor_owned\":"
            << (SyscallHandler.PostSessionBoundaryEpollPWait2DescriptorOwned ? "true" : "false")
            << ",\"post_session_boundary_epoll_pwait2_descriptor_known\":"
            << (SyscallHandler.PostSessionBoundaryEpollPWait2DescriptorKnown ? "true" : "false")
            << ",\"post_session_boundary_epoll_pwait2_max_events\":"
            << SyscallHandler.PostSessionBoundaryEpollPWait2MaxEvents
            << ",\"post_session_boundary_epoll_pwait2_events_class\":\""
            << SyscallHandler.PostSessionBoundaryEpollPWait2EventsClass << "\""
            << ",\"post_session_boundary_epoll_pwait2_timeout_class\":\""
            << SyscallHandler.PostSessionBoundaryEpollPWait2TimeoutClass << "\""
            << ",\"post_session_boundary_epoll_pwait2_timeout_readable\":"
            << (SyscallHandler.PostSessionBoundaryEpollPWait2TimeoutReadable ? "true" : "false")
            << ",\"post_session_boundary_epoll_pwait2_timeout_seconds\":"
            << SyscallHandler.PostSessionBoundaryEpollPWait2TimeoutSeconds
            << ",\"post_session_boundary_epoll_pwait2_timeout_nanoseconds\":"
            << SyscallHandler.PostSessionBoundaryEpollPWait2TimeoutNanoseconds
            << ",\"post_session_boundary_epoll_pwait2_signal_mask_class\":\""
            << SyscallHandler.PostSessionBoundaryEpollPWait2SignalMaskClass << "\""
            << ",\"post_session_boundary_epoll_pwait2_signal_set_size\":"
            << SyscallHandler.PostSessionBoundaryEpollPWait2SignalSetSize
            << ",\"post_session_boundary_epoll_wait_seen\":"
            << (SyscallHandler.PostSessionBoundaryEpollWaitSeen ? "true" : "false")
            << ",\"post_session_boundary_epoll_wait_descriptor\":"
            << SyscallHandler.PostSessionBoundaryEpollWaitDescriptor
            << ",\"post_session_boundary_epoll_wait_descriptor_owned\":"
            << (SyscallHandler.PostSessionBoundaryEpollWaitDescriptorOwned ? "true" : "false")
            << ",\"post_session_boundary_epoll_wait_descriptor_known\":"
            << (SyscallHandler.PostSessionBoundaryEpollWaitDescriptorKnown ? "true" : "false")
            << ",\"post_session_boundary_epoll_wait_max_events\":"
            << SyscallHandler.PostSessionBoundaryEpollWaitMaxEvents
            << ",\"post_session_boundary_epoll_wait_events_class\":\""
            << SyscallHandler.PostSessionBoundaryEpollWaitEventsClass << "\""
            << ",\"post_session_boundary_epoll_wait_timeout\":"
            << SyscallHandler.PostSessionBoundaryEpollWaitTimeout
            << ",\"post_session_syscall_diagnostic_limit_seen\":"
            << (SyscallHandler.PostSessionSyscallDiagnosticLimitSeen ? "true" : "false")
            << ",\"post_session_diagnostic_stop_signal_request_count\":"
            << SyscallHandler.PostSessionDiagnosticStopSignalRequestCount
            << ",\"post_session_diagnostic_stop_signal_last_host_error\":"
            << SyscallHandler.PostSessionDiagnosticStopSignalLastHostError
            << ",\"post_session_diagnostic_stop_signal_triggered\":"
            << (DiagnosticStopSignalTriggered ? "true" : "false")
            << ",\"unsupported_diagnostic_stop_signal_request_count\":"
            << SyscallHandler.UnsupportedDiagnosticStopSignalRequestCount
            << ",\"unsupported_diagnostic_stop_signal_last_host_error\":"
            << SyscallHandler.UnsupportedDiagnosticStopSignalLastHostError
            << ",\"post_session_live_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.PostSessionLiveTraceCount; ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.PostSessionLiveTrace[Index];
  }
  std::cout << ']'
            << ",\"clock_nanosleep_syscall_seen\":" << (SyscallHandler.ClockNanosleepSeen ? "true" : "false")
            << ",\"clock_nanosleep_call_count\":" << SyscallHandler.ClockNanosleepCallCount
            << ",\"clock_nanosleep_success_count\":" << SyscallHandler.ClockNanosleepSuccessCount
            << ",\"clock_nanosleep_interrupted_count\":" << SyscallHandler.ClockNanosleepInterruptedCount
            << ",\"clock_nanosleep_absolute_call_count\":" << SyscallHandler.ClockNanosleepAbsoluteCallCount
            << ",\"clock_nanosleep_last_request_seconds\":" << SyscallHandler.ClockNanosleepLastRequestSeconds
            << ",\"clock_nanosleep_last_request_nanoseconds\":" << SyscallHandler.ClockNanosleepLastRequestNanoseconds
            << ",\"getrandom_syscall_seen\":" << (SyscallHandler.GetrandomSeen ? "true" : "false")
            << ",\"getrandom_call_count\":" << SyscallHandler.GetrandomCallCount
            << ",\"getrandom_success_count\":" << SyscallHandler.GetrandomSuccessCount
            << ",\"getrandom_byte_count\":" << SyscallHandler.GetrandomByteCount
            << ",\"uname_syscall_seen\":" << (SyscallHandler.UnameSeen ? "true" : "false")
            << ",\"uname_call_count\":" << SyscallHandler.UnameCallCount
            << ",\"uname_success_count\":" << SyscallHandler.UnameSuccessCount
            << ",\"getcwd_syscall_seen\":" << (SyscallHandler.GetcwdSeen ? "true" : "false")
            << ",\"getcwd_call_count\":" << SyscallHandler.GetcwdCallCount
            << ",\"getcwd_success_count\":" << SyscallHandler.GetcwdSuccessCount
            << ",\"chdir_syscall_seen\":" << (SyscallHandler.ChdirSeen ? "true" : "false")
            << ",\"chdir_call_count\":" << SyscallHandler.ChdirCallCount
            << ",\"chdir_success_count\":" << SyscallHandler.ChdirSuccessCount
            << ",\"chdir_host_mirror_success_count\":"
            << SyscallHandler.ChdirHostMirrorSuccessCount
            << ",\"chdir_last_host_path_resolved\":"
            << (SyscallHandler.ChdirLastHostPathResolved ? "true" : "false")
            << ",\"chdir_last_host_cwd_matches_guest\":"
            << (SyscallHandler.ChdirLastHostCWDMatchesGuest ? "true" : "false")
            << ",\"umask_syscall_seen\":"
            << (SyscallHandler.UmaskSeen ? "true" : "false")
            << ",\"umask_call_count\":" << SyscallHandler.UmaskCallCount
            << ",\"umask_success_count\":" << SyscallHandler.UmaskSuccessCount
            << ",\"umask_last_requested_mode\":"
            << SyscallHandler.UmaskLastRequestedMode
            << ",\"umask_last_applied_mode\":"
            << SyscallHandler.UmaskLastAppliedMode
            << ",\"umask_last_previous_mode\":"
            << SyscallHandler.UmaskLastPreviousMode
            << ",\"umask_current_mode\":" << SyscallHandler.GuestUmask
            << ",\"mkdir_syscall_seen\":" << (SyscallHandler.MkdirSeen ? "true" : "false")
            << ",\"mkdir_call_count\":" << SyscallHandler.MkdirCallCount
            << ",\"mkdir_success_count\":" << SyscallHandler.MkdirSuccessCount
            << ",\"mkdir_last_path_class\":\"" << SyscallHandler.MkdirLastPathClass << "\""
            << ",\"mkdir_last_path_length\":" << SyscallHandler.MkdirLastPathLength
            << ",\"mkdir_last_path_fingerprint\":"
            << SyscallHandler.MkdirLastPathFingerprint
            << ",\"mkdir_last_mode\":" << SyscallHandler.MkdirLastMode
            << ",\"mkdir_last_applied_mode\":" << SyscallHandler.MkdirLastAppliedMode
            << ",\"mkdir_last_target_confined\":"
            << (SyscallHandler.MkdirLastTargetConfined ? "true" : "false")
            << ",\"mkdir_last_parent_confined\":"
            << (SyscallHandler.MkdirLastParentConfined ? "true" : "false")
            << ",\"mkdir_last_parent_exists\":"
            << (SyscallHandler.MkdirLastParentExists ? "true" : "false")
            << ",\"mkdir_last_parent_directory\":"
            << (SyscallHandler.MkdirLastParentDirectory ? "true" : "false")
            << ",\"mkdir_last_target_exists\":"
            << (SyscallHandler.MkdirLastTargetExists ? "true" : "false")
            << ",\"mkdir_last_target_directory\":"
            << (SyscallHandler.MkdirLastTargetDirectory ? "true" : "false")
            << ",\"mkdir_last_linux_error\":" << SyscallHandler.MkdirLastLinuxError
            << ",\"mkdir_last_failure_reason\":\""
            << SyscallHandler.MkdirLastFailureReason << "\""
            << ",\"rename_syscall_seen\":"
            << (SyscallHandler.RenameSeen ? "true" : "false")
            << ",\"rename_call_count\":" << SyscallHandler.RenameCallCount
            << ",\"registry_rename_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.RegistryRenameTraceCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    const auto& Trace = SyscallHandler.RegistryRenameTrace[Index];
    std::cout << "{\"old_path_readable\":"
              << (Trace.OldPathReadable ? "true" : "false")
              << ",\"new_path_readable\":"
              << (Trace.NewPathReadable ? "true" : "false")
              << ",\"old_path_class\":\"" << Trace.OldPathClass << "\""
              << ",\"new_path_class\":\"" << Trace.NewPathClass << "\""
              << ",\"old_diagnostic_path\":\"" << Trace.OldDiagnosticPath << "\""
              << ",\"new_diagnostic_path\":\"" << Trace.NewDiagnosticPath << "\""
              << ",\"old_path_length\":" << Trace.OldPathLength
              << ",\"new_path_length\":" << Trace.NewPathLength
              << ",\"old_path_fingerprint\":" << Trace.OldPathFingerprint
              << ",\"new_path_fingerprint\":" << Trace.NewPathFingerprint
              << ",\"old_host_path_resolved\":"
              << (Trace.OldHostPathResolved ? "true" : "false")
              << ",\"new_host_path_resolved\":"
              << (Trace.NewHostPathResolved ? "true" : "false")
              << ",\"old_target_exists\":"
              << (Trace.OldTargetExists ? "true" : "false")
              << ",\"old_target_regular\":"
              << (Trace.OldTargetRegular ? "true" : "false")
              << ",\"old_target_directory\":"
              << (Trace.OldTargetDirectory ? "true" : "false")
              << ",\"old_target_symlink\":"
              << (Trace.OldTargetSymlink ? "true" : "false")
              << ",\"new_target_exists\":"
              << (Trace.NewTargetExists ? "true" : "false")
              << ",\"new_target_regular\":"
              << (Trace.NewTargetRegular ? "true" : "false")
              << ",\"new_target_directory\":"
              << (Trace.NewTargetDirectory ? "true" : "false")
              << ",\"new_target_symlink\":"
              << (Trace.NewTargetSymlink ? "true" : "false")
              << ",\"same_host_parent\":"
              << (Trace.SameHostParent ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"rename_exact_candidate_count\":"
            << SyscallHandler.RenameExactCandidateCount
            << ",\"rename_success_count\":"
            << SyscallHandler.RenameSuccessCount
            << ",\"rename_failure_count\":"
            << SyscallHandler.RenameFailureCount
            << ",\"rename_last_host_error\":"
            << SyscallHandler.RenameLastHostError
            << ",\"rename_last_linux_error\":"
            << SyscallHandler.RenameLastLinuxError
            << ",\"rename_last_failure_reason\":\""
            << SyscallHandler.RenameLastFailureReason << "\""
            << ",\"unlink_syscall_seen\":"
            << (SyscallHandler.UnlinkSeen ? "true" : "false")
            << ",\"unlink_call_count\":" << SyscallHandler.UnlinkCallCount
            << ",\"unlink_success_count\":" << SyscallHandler.UnlinkSuccessCount
            << ",\"unlink_missing_target_count\":"
            << SyscallHandler.UnlinkMissingTargetCount
            << ",\"unlink_last_path_class\":\""
            << SyscallHandler.UnlinkLastPathClass << "\""
            << ",\"unlink_last_path_length\":" << SyscallHandler.UnlinkLastPathLength
            << ",\"unlink_last_path_fingerprint\":"
            << SyscallHandler.UnlinkLastPathFingerprint
            << ",\"unlink_last_host_path_resolved\":"
            << (SyscallHandler.UnlinkLastHostPathResolved ? "true" : "false")
            << ",\"unlink_last_target_exists\":"
            << (SyscallHandler.UnlinkLastTargetExists ? "true" : "false")
            << ",\"unlink_last_target_socket\":"
            << (SyscallHandler.UnlinkLastTargetSocket ? "true" : "false")
            << ",\"unlink_last_linux_error\":" << SyscallHandler.UnlinkLastLinuxError
            << ",\"unlink_last_failure_reason\":\""
            << SyscallHandler.UnlinkLastFailureReason << "\""
            << ",\"chmod_syscall_seen\":"
            << (SyscallHandler.ChmodSeen ? "true" : "false")
            << ",\"chmod_call_count\":" << SyscallHandler.ChmodCallCount
            << ",\"chmod_success_count\":" << SyscallHandler.ChmodSuccessCount
            << ",\"chmod_last_path_class\":\""
            << SyscallHandler.ChmodLastPathClass << "\""
            << ",\"chmod_last_path_length\":" << SyscallHandler.ChmodLastPathLength
            << ",\"chmod_last_path_fingerprint\":"
            << SyscallHandler.ChmodLastPathFingerprint
            << ",\"chmod_last_mode\":" << SyscallHandler.ChmodLastMode
            << ",\"chmod_last_applied_mode\":" << SyscallHandler.ChmodLastAppliedMode
            << ",\"chmod_last_target_socket\":"
            << (SyscallHandler.ChmodLastTargetSocket ? "true" : "false")
            << ",\"chmod_last_linux_error\":" << SyscallHandler.ChmodLastLinuxError
            << ",\"chmod_last_failure_reason\":\""
            << SyscallHandler.ChmodLastFailureReason << "\""
            << ",\"symlink_syscall_seen\":"
            << (SyscallHandler.SymlinkSeen ? "true" : "false")
            << ",\"symlink_call_count\":" << SyscallHandler.SymlinkCallCount
            << ",\"symlink_success_count\":" << SyscallHandler.SymlinkSuccessCount
            << ",\"symlink_last_target_class\":\""
            << SyscallHandler.SymlinkLastTargetClass << "\""
            << ",\"symlink_last_target_length\":"
            << SyscallHandler.SymlinkLastTargetLength
            << ",\"symlink_last_target_fingerprint\":"
            << SyscallHandler.SymlinkLastTargetFingerprint
            << ",\"symlink_last_link_class\":\""
            << SyscallHandler.SymlinkLastLinkClass << "\""
            << ",\"symlink_last_link_length\":" << SyscallHandler.SymlinkLastLinkLength
            << ",\"symlink_last_link_fingerprint\":"
            << SyscallHandler.SymlinkLastLinkFingerprint
            << ",\"symlink_last_target_confined\":"
            << (SyscallHandler.SymlinkLastTargetConfined ? "true" : "false")
            << ",\"symlink_last_link_confined\":"
            << (SyscallHandler.SymlinkLastLinkConfined ? "true" : "false")
            << ",\"symlink_last_target_reproduced\":"
            << (SyscallHandler.SymlinkLastTargetReproduced ? "true" : "false")
            << ",\"symlink_last_linux_error\":" << SyscallHandler.SymlinkLastLinuxError
            << ",\"symlink_last_failure_reason\":\""
            << SyscallHandler.SymlinkLastFailureReason << "\""
            << ",\"readlink_syscall_seen\":" << (SyscallHandler.ReadlinkSeen ? "true" : "false")
            << ",\"readlink_call_count\":" << SyscallHandler.ReadlinkCallCount
            << ",\"readlink_success_count\":" << SyscallHandler.ReadlinkSuccessCount
            << ",\"readlink_proc_self_exe_count\":" << SyscallHandler.ReadlinkProcSelfExeCount
            << ",\"getuid_syscall_seen\":" << (SyscallHandler.GetUIDSeen ? "true" : "false")
            << ",\"getuid_call_count\":" << SyscallHandler.GetUIDCallCount
            << ",\"getuid_value\":" << SyscallHandler.LastGetUID
            << ",\"getpid_syscall_seen\":" << (SyscallHandler.GetPIDSeen ? "true" : "false")
            << ",\"getpid_call_count\":" << SyscallHandler.GetPIDCallCount
            << ",\"getpid_value\":" << SyscallHandler.LastGetPID
            << ",\"getpid_matches_host_process\":"
            << (SyscallHandler.GetPIDSeen
                  && SyscallHandler.LastGetPID == static_cast<uint64_t>(getpid())
                ? "true" : "false")
            << ",\"gettid_syscall_seen\":" << (SyscallHandler.GetTIDSeen ? "true" : "false")
            << ",\"gettid_call_count\":" << SyscallHandler.GetTIDCallCount
            << ",\"gettid_success_count\":" << SyscallHandler.GetTIDSuccessCount
            << ",\"gettid_last_mach_port\":" << SyscallHandler.GetTIDLastMachPort
            << ",\"gettid_deallocate_success_count\":"
            << SyscallHandler.GetTIDDeallocateSuccessCount
            << ",\"gettid_last_deallocate_result\":"
            << static_cast<int64_t>(SyscallHandler.GetTIDLastDeallocateResult)
            << ",\"setpriority_syscall_seen\":"
            << (SyscallHandler.SetPrioritySeen ? "true" : "false")
            << ",\"setpriority_call_count\":" << SyscallHandler.SetPriorityCallCount
            << ",\"setpriority_success_count\":"
            << SyscallHandler.SetPrioritySuccessCount
            << ",\"setpriority_expected_rejection_count\":"
            << SyscallHandler.SetPriorityExpectedRejectionCount
            << ",\"setpriority_unexpected_failure_count\":"
            << SyscallHandler.SetPriorityUnexpectedFailureCount
            << ",\"setpriority_last_which\":" << SyscallHandler.SetPriorityLastWhich
            << ",\"setpriority_last_who\":" << SyscallHandler.SetPriorityLastWho
            << ",\"setpriority_last_nice\":" << SyscallHandler.SetPriorityLastNice
            << ",\"setpriority_last_who_matches_pid\":"
            << (SyscallHandler.SetPriorityLastWhoMatchesPID ? "true" : "false")
            << ",\"setpriority_last_host_error\":"
            << SyscallHandler.SetPriorityLastHostError
            << ",\"setpriority_last_linux_error\":"
            << SyscallHandler.SetPriorityLastLinuxError
            << ",\"setpriority_last_failure_reason\":\""
            << SyscallHandler.SetPriorityLastFailureReason << "\""
            << ",\"poll_syscall_seen\":" << (SyscallHandler.PollSeen ? "true" : "false")
            << ",\"poll_call_count\":" << SyscallHandler.PollCallCount
            << ",\"poll_success_count\":" << SyscallHandler.PollSuccessCount
            << ",\"poll_ready_descriptor_count\":"
            << SyscallHandler.PollReadyDescriptorCount
            << ",\"poll_last_descriptor_count\":"
            << SyscallHandler.PollLastDescriptorCount
            << ",\"poll_last_timeout\":" << SyscallHandler.PollLastTimeout
            << ",\"poll_last_descriptor\":" << SyscallHandler.PollLastDescriptor
            << ",\"poll_last_events\":" << SyscallHandler.PollLastEvents
            << ",\"poll_last_returned_events\":"
            << SyscallHandler.PollLastReturnedEvents
            << ",\"poll_last_linux_error\":" << SyscallHandler.PollLastLinuxError
            << ",\"pipe2_syscall_seen\":" << (SyscallHandler.Pipe2Seen ? "true" : "false")
            << ",\"pipe2_call_count\":" << SyscallHandler.Pipe2CallCount
            << ",\"pipe2_success_count\":" << SyscallHandler.Pipe2SuccessCount
            << ",\"pipe2_low_shadow_write_count\":"
            << SyscallHandler.Pipe2LowShadowWriteCount
            << ",\"pipe2_last_guest_pointer\":"
            << SyscallHandler.Pipe2LastGuestPointer
            << ",\"pipe2_last_flags\":" << SyscallHandler.Pipe2LastFlags
            << ",\"pipe2_last_linux_error\":" << SyscallHandler.Pipe2LastLinuxError
            << ",\"pipe2_last_pointer_class\":\""
            << SyscallHandler.Pipe2LastPointerClass << "\""
            << ",\"pipe2_last_low_shadow_mapped\":"
            << (SyscallHandler.Pipe2LastLowShadowMapped ? "true" : "false")
            << ",\"pipe2_last_low_shadow_writable\":"
            << (SyscallHandler.Pipe2LastLowShadowWritable ? "true" : "false")
            << ",\"pipe2_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.Pipe2TraceCount; ++Index) {
    const auto& Trace = SyscallHandler.Pipe2Trace[Index];
    if (Index != 0) std::cout << ',';
    std::cout << "{\"guest_pointer\":" << Trace.GuestPipe
              << ",\"flags\":" << Trace.Flags
              << ",\"pointer_class\":\"" << Trace.PointerClass << "\""
              << ",\"low_shadow_mapped\":"
              << (Trace.LowShadowMapped ? "true" : "false")
              << ",\"low_shadow_writable\":"
              << (Trace.LowShadowWritable ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"socket_syscall_seen\":" << (SyscallHandler.SocketSeen ? "true" : "false")
            << ",\"socket_call_count\":" << SyscallHandler.SocketCallCount
            << ",\"socket_success_count\":" << SyscallHandler.SocketSuccessCount
            << ",\"socketpair_syscall_seen\":"
            << (SyscallHandler.SocketPairSeen ? "true" : "false")
            << ",\"socketpair_call_count\":" << SyscallHandler.SocketPairCallCount
            << ",\"socketpair_success_count\":" << SyscallHandler.SocketPairSuccessCount
            << ",\"socketpair_last_domain\":" << SyscallHandler.SocketPairLastDomain
            << ",\"socketpair_last_type\":" << SyscallHandler.SocketPairLastType
            << ",\"socketpair_last_protocol\":" << SyscallHandler.SocketPairLastProtocol
            << ",\"socketpair_last_linux_error\":"
            << SyscallHandler.SocketPairLastLinuxError
            << ",\"shutdown_syscall_seen\":"
            << (SyscallHandler.ShutdownSeen ? "true" : "false")
            << ",\"shutdown_call_count\":" << SyscallHandler.ShutdownCallCount
            << ",\"shutdown_success_count\":" << SyscallHandler.ShutdownSuccessCount
            << ",\"shutdown_last_descriptor\":"
            << SyscallHandler.ShutdownLastDescriptor
            << ",\"shutdown_last_how\":" << SyscallHandler.ShutdownLastHow
            << ",\"shutdown_last_linux_error\":"
            << SyscallHandler.ShutdownLastLinuxError
            << ",\"bind_syscall_seen\":" << (SyscallHandler.BindSeen ? "true" : "false")
            << ",\"bind_call_count\":" << SyscallHandler.BindCallCount
            << ",\"bind_success_count\":" << SyscallHandler.BindSuccessCount
            << ",\"bind_last_descriptor\":" << SyscallHandler.BindLastDescriptor
            << ",\"bind_last_address_length\":" << SyscallHandler.BindLastAddressLength
            << ",\"bind_last_family\":" << SyscallHandler.BindLastFamily
            << ",\"bind_last_path_class\":\""
            << SyscallHandler.BindLastPathClass << "\""
            << ",\"bind_last_path_length\":" << SyscallHandler.BindLastPathLength
            << ",\"bind_last_path_fingerprint\":"
            << SyscallHandler.BindLastPathFingerprint
            << ",\"bind_last_host_cwd_matches_guest\":"
            << (SyscallHandler.BindLastHostCWDMatchesGuest ? "true" : "false")
            << ",\"bind_last_endpoint_created\":"
            << (SyscallHandler.BindLastEndpointCreated ? "true" : "false")
            << ",\"bind_last_linux_error\":" << SyscallHandler.BindLastLinuxError
            << ",\"bind_last_failure_reason\":\""
            << SyscallHandler.BindLastFailureReason << "\""
            << ",\"listen_syscall_seen\":"
            << (SyscallHandler.ListenSeen ? "true" : "false")
            << ",\"listen_call_count\":" << SyscallHandler.ListenCallCount
            << ",\"listen_success_count\":" << SyscallHandler.ListenSuccessCount
            << ",\"listen_last_descriptor\":" << SyscallHandler.ListenLastDescriptor
            << ",\"listen_last_backlog\":" << SyscallHandler.ListenLastBacklog
            << ",\"listen_last_linux_error\":" << SyscallHandler.ListenLastLinuxError
            << ",\"listen_last_failure_reason\":\""
            << SyscallHandler.ListenLastFailureReason << "\""
            << ",\"futex_waitv_syscall_seen\":"
            << (SyscallHandler.FutexWaitVSeen ? "true" : "false")
            << ",\"futex_waitv_call_count\":" << SyscallHandler.FutexWaitVCallCount
            << ",\"futex_waitv_availability_probe_count\":"
            << SyscallHandler.FutexWaitVAvailabilityProbeCount
            << ",\"futex_waitv_last_waiter_count\":"
            << SyscallHandler.FutexWaitVLastWaiterCount
            << ",\"futex_waitv_last_flags\":" << SyscallHandler.FutexWaitVLastFlags
            << ",\"futex_waitv_last_clock_id\":" << SyscallHandler.FutexWaitVLastClockID
            << ",\"futex_waitv_last_linux_error\":"
            << SyscallHandler.FutexWaitVLastLinuxError
            << ",\"futex_waitv_last_failure_reason\":\""
            << SyscallHandler.FutexWaitVLastFailureReason << "\""
            << ",\"epoll_create_syscall_seen\":"
            << (SyscallHandler.EpollCreateSeen ? "true" : "false")
            << ",\"epoll_create_call_count\":" << SyscallHandler.EpollCreateCallCount
            << ",\"epoll_create_success_count\":"
            << SyscallHandler.EpollCreateSuccessCount
            << ",\"epoll_create_last_size\":" << SyscallHandler.EpollCreateLastSize
            << ",\"epoll_create_last_descriptor\":"
            << SyscallHandler.EpollCreateLastDescriptor
            << ",\"epoll_create_last_linux_error\":"
            << SyscallHandler.EpollCreateLastLinuxError
            << ",\"epoll_create_last_failure_reason\":\""
            << SyscallHandler.EpollCreateLastFailureReason << "\""
            << ",\"epoll_ctl_syscall_seen\":"
            << (SyscallHandler.EpollCtlSeen ? "true" : "false")
            << ",\"epoll_ctl_call_count\":" << SyscallHandler.EpollCtlCallCount
            << ",\"epoll_ctl_success_count\":" << SyscallHandler.EpollCtlSuccessCount
            << ",\"epoll_ctl_add_write_candidate_count\":"
            << SyscallHandler.EpollCtlAddWriteCandidateCount
            << ",\"epoll_ctl_add_write_success_count\":"
            << SyscallHandler.EpollCtlAddWriteSuccessCount
            << ",\"epoll_ctl_last_epoll_descriptor\":"
            << SyscallHandler.EpollCtlLastEpollDescriptor
            << ",\"epoll_ctl_last_operation\":" << SyscallHandler.EpollCtlLastOperation
            << ",\"epoll_ctl_last_target_descriptor\":"
            << SyscallHandler.EpollCtlLastTargetDescriptor
            << ",\"epoll_ctl_last_event_readable\":"
            << (SyscallHandler.EpollCtlLastEventReadable ? "true" : "false")
            << ",\"epoll_ctl_last_events\":" << SyscallHandler.EpollCtlLastEvents
            << ",\"epoll_ctl_last_data\":" << SyscallHandler.EpollCtlLastData
            << ",\"epoll_ctl_last_linux_error\":"
            << SyscallHandler.EpollCtlLastLinuxError
            << ",\"epoll_ctl_last_failure_reason\":\""
            << SyscallHandler.EpollCtlLastFailureReason << "\""
            << ",\"epoll_ctl_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.EpollCtlTraceCount; ++Index) {
    const auto& Trace = SyscallHandler.EpollCtlTrace[Index];
    if (Index != 0) std::cout << ',';
    std::cout << "{\"epoll_descriptor\":" << Trace.EpollDescriptor
              << ",\"operation\":" << Trace.Operation
              << ",\"target_descriptor\":" << Trace.TargetDescriptor
              << ",\"event_readable\":" << (Trace.EventReadable ? "true" : "false")
              << ",\"events\":" << Trace.Events
              << ",\"data\":" << Trace.Data
              << '}';
  }
  std::cout << ']'
            << ",\"epoll_pwait2_syscall_seen\":"
            << (SyscallHandler.EpollPWait2Seen ? "true" : "false")
            << ",\"epoll_pwait2_call_count\":"
            << SyscallHandler.EpollPWait2CallCount
            << ",\"epoll_pwait2_host_unavailable_fallback_count\":"
            << SyscallHandler.EpollPWait2HostUnavailableFallbackCount
            << ",\"epoll_pwait2_last_descriptor\":"
            << SyscallHandler.EpollPWait2LastDescriptor
            << ",\"epoll_pwait2_last_descriptor_known\":"
            << (SyscallHandler.EpollPWait2LastDescriptorKnown ? "true" : "false")
            << ",\"epoll_pwait2_last_max_events\":"
            << SyscallHandler.EpollPWait2LastMaxEvents
            << ",\"epoll_pwait2_last_events_class\":\""
            << SyscallHandler.EpollPWait2LastEventsClass << "\""
            << ",\"epoll_pwait2_last_timeout_class\":\""
            << SyscallHandler.EpollPWait2LastTimeoutClass << "\""
            << ",\"epoll_pwait2_last_timeout_readable\":"
            << (SyscallHandler.EpollPWait2LastTimeoutReadable ? "true" : "false")
            << ",\"epoll_pwait2_last_timeout_seconds\":"
            << SyscallHandler.EpollPWait2LastTimeoutSeconds
            << ",\"epoll_pwait2_last_timeout_nanoseconds\":"
            << SyscallHandler.EpollPWait2LastTimeoutNanoseconds
            << ",\"epoll_pwait2_last_signal_mask_class\":\""
            << SyscallHandler.EpollPWait2LastSignalMaskClass << "\""
            << ",\"epoll_pwait2_last_signal_set_size\":"
            << SyscallHandler.EpollPWait2LastSignalSetSize
            << ",\"epoll_pwait2_last_linux_error\":"
            << SyscallHandler.EpollPWait2LastLinuxError
            << ",\"epoll_pwait2_last_failure_reason\":\""
            << SyscallHandler.EpollPWait2LastFailureReason << "\""
            << ",\"epoll_wait_syscall_seen\":"
            << (SyscallHandler.EpollWaitSeen ? "true" : "false")
            << ",\"epoll_wait_call_count\":" << SyscallHandler.EpollWaitCallCount
            << ",\"epoll_wait_success_count\":" << SyscallHandler.EpollWaitSuccessCount
            << ",\"epoll_wait_timeout_count\":" << SyscallHandler.EpollWaitTimeoutCount
            << ",\"epoll_wait_returned_event_count\":"
            << SyscallHandler.EpollWaitReturnedEventCount
            << ",\"epoll_wait_timed_call_count\":"
            << SyscallHandler.EpollWaitTimedCallCount
            << ",\"epoll_wait_timed_success_count\":"
            << SyscallHandler.EpollWaitTimedSuccessCount
            << ",\"epoll_wait_timed_returned_event_count\":"
            << SyscallHandler.EpollWaitTimedReturnedEventCount
            << ",\"epoll_wait_polling_call_count\":"
            << SyscallHandler.EpollWaitPollingCallCount
            << ",\"epoll_wait_polling_success_count\":"
            << SyscallHandler.EpollWaitPollingSuccessCount
            << ",\"epoll_wait_polling_returned_event_count\":"
            << SyscallHandler.EpollWaitPollingReturnedEventCount
            << ",\"epoll_wait_last_descriptor\":"
            << SyscallHandler.EpollWaitLastDescriptor
            << ",\"epoll_wait_last_descriptor_known\":"
            << (SyscallHandler.EpollWaitLastDescriptorKnown ? "true" : "false")
            << ",\"epoll_wait_last_max_events\":"
            << SyscallHandler.EpollWaitLastMaxEvents
            << ",\"epoll_wait_last_events_class\":\""
            << SyscallHandler.EpollWaitLastEventsClass << "\""
            << ",\"epoll_wait_last_timeout\":" << SyscallHandler.EpollWaitLastTimeout
            << ",\"epoll_wait_last_linux_error\":"
            << SyscallHandler.EpollWaitLastLinuxError
            << ",\"epoll_wait_last_failure_reason\":\""
            << SyscallHandler.EpollWaitLastFailureReason << "\""
            << ",\"gettimeofday_syscall_seen\":"
            << (SyscallHandler.GettimeofdaySeen ? "true" : "false")
            << ",\"gettimeofday_call_count\":" << SyscallHandler.GettimeofdayCallCount
            << ",\"gettimeofday_success_count\":"
            << SyscallHandler.GettimeofdaySuccessCount
            << ",\"gettimeofday_last_seconds\":"
            << SyscallHandler.GettimeofdayLastSeconds
            << ",\"gettimeofday_last_microseconds\":"
            << SyscallHandler.GettimeofdayLastMicroseconds
            << ",\"gettimeofday_last_linux_error\":"
            << SyscallHandler.GettimeofdayLastLinuxError
            << ",\"gettimeofday_last_failure_reason\":\""
            << SyscallHandler.GettimeofdayLastFailureReason << "\""
            << ",\"sysinfo_syscall_seen\":"
            << (SyscallHandler.SysinfoSeen ? "true" : "false")
            << ",\"sysinfo_call_count\":" << SyscallHandler.SysinfoCallCount
            << ",\"sysinfo_success_count\":" << SyscallHandler.SysinfoSuccessCount
            << ",\"sysinfo_last_buffer_class\":\""
            << SyscallHandler.SysinfoLastBufferClass << "\""
            << ",\"sysinfo_last_uptime\":" << SyscallHandler.SysinfoLastUptime
            << ",\"sysinfo_last_total_ram\":" << SyscallHandler.SysinfoLastTotalRAM
            << ",\"sysinfo_last_free_ram\":" << SyscallHandler.SysinfoLastFreeRAM
            << ",\"sysinfo_last_memory_unit\":"
            << SyscallHandler.SysinfoLastMemoryUnit
            << ",\"time_syscall_seen\":"
            << (SyscallHandler.TimeSeen ? "true" : "false")
            << ",\"time_call_count\":" << SyscallHandler.TimeCallCount
            << ",\"time_null_pointer_call_count\":"
            << SyscallHandler.TimeNullPointerCallCount
            << ",\"time_success_count\":" << SyscallHandler.TimeSuccessCount
            << ",\"time_last_seconds\":" << SyscallHandler.TimeLastSeconds
            << ",\"time_last_linux_error\":" << SyscallHandler.TimeLastLinuxError
            << ",\"time_last_failure_reason\":\""
            << SyscallHandler.TimeLastFailureReason << "\""
            << ",\"fstatfs_syscall_seen\":"
            << (SyscallHandler.FStatFSSeen ? "true" : "false")
            << ",\"fstatfs_call_count\":" << SyscallHandler.FStatFSCallCount
            << ",\"fstatfs_success_count\":" << SyscallHandler.FStatFSSuccessCount
            << ",\"fstatfs_last_descriptor\":" << SyscallHandler.FStatFSLastDescriptor
            << ",\"fstatfs_last_type\":" << SyscallHandler.FStatFSLastType
            << ",\"fstatfs_last_linux_error\":"
            << SyscallHandler.FStatFSLastLinuxError
            << ",\"fstatfs_last_failure_reason\":\""
            << SyscallHandler.FStatFSLastFailureReason << "\""
            << ",\"faccessat2_syscall_seen\":"
            << (SyscallHandler.FAccessAt2Seen ? "true" : "false")
            << ",\"faccessat2_call_count\":" << SyscallHandler.FAccessAt2CallCount
            << ",\"faccessat2_success_count\":"
            << SyscallHandler.FAccessAt2SuccessCount
            << ",\"faccessat2_last_directory_descriptor\":"
            << SyscallHandler.FAccessAt2LastDirectoryDescriptor
            << ",\"faccessat2_last_mode\":" << SyscallHandler.FAccessAt2LastMode
            << ",\"faccessat2_last_flags\":" << SyscallHandler.FAccessAt2LastFlags
            << ",\"faccessat2_last_linux_error\":"
            << SyscallHandler.FAccessAt2LastLinuxError
            << ",\"faccessat2_last_failure_reason\":\""
            << SyscallHandler.FAccessAt2LastFailureReason << "\""
            << ",\"memfd_create_syscall_seen\":"
            << (SyscallHandler.MemfdCreateSeen ? "true" : "false")
            << ",\"memfd_create_call_count\":"
            << SyscallHandler.MemfdCreateCallCount
            << ",\"memfd_create_success_count\":"
            << SyscallHandler.MemfdCreateSuccessCount
            << ",\"memfd_create_last_flags\":"
            << SyscallHandler.MemfdCreateLastFlags
            << ",\"memfd_create_last_name_length\":"
            << SyscallHandler.MemfdCreateLastNameLength
            << ",\"memfd_create_last_name_fingerprint\":"
            << SyscallHandler.MemfdCreateLastNameFingerprint
            << ",\"memfd_create_last_descriptor\":"
            << SyscallHandler.MemfdCreateLastDescriptor
            << ",\"memfd_create_backing_unlinked\":"
            << (SyscallHandler.MemfdCreateBackingUnlinked ? "true" : "false")
            << ",\"memfd_create_last_linux_error\":"
            << SyscallHandler.MemfdCreateLastLinuxError
            << ",\"memfd_create_last_failure_reason\":\""
            << SyscallHandler.MemfdCreateLastFailureReason << "\""
            << ",\"pwrite64_syscall_seen\":"
            << (SyscallHandler.PWrite64Seen ? "true" : "false")
            << ",\"pwrite64_call_count\":"
            << SyscallHandler.PWrite64CallCount
            << ",\"pwrite64_success_count\":"
            << SyscallHandler.PWrite64SuccessCount
            << ",\"pwrite64_written_byte_count\":"
            << SyscallHandler.PWrite64WrittenByteCount
            << ",\"session_mapping_write_completed\":"
            << (SyscallHandler.SessionMappingWriteCompleted ? "true" : "false")
            << ",\"pwrite64_last_descriptor\":"
            << SyscallHandler.PWrite64LastDescriptor
            << ",\"pwrite64_last_byte_count\":"
            << SyscallHandler.PWrite64LastByteCount
            << ",\"pwrite64_last_offset\":"
            << SyscallHandler.PWrite64LastOffset
            << ",\"pwrite64_last_linux_error\":"
            << SyscallHandler.PWrite64LastLinuxError
            << ",\"pwrite64_last_failure_reason\":\""
            << SyscallHandler.PWrite64LastFailureReason << "\""
            << ",\"ftruncate_syscall_seen\":"
            << (SyscallHandler.FTruncateSeen ? "true" : "false")
            << ",\"ftruncate_call_count\":"
            << SyscallHandler.FTruncateCallCount
            << ",\"ftruncate_success_count\":"
            << SyscallHandler.FTruncateSuccessCount
            << ",\"ftruncate_last_descriptor\":"
            << SyscallHandler.FTruncateLastDescriptor
            << ",\"ftruncate_last_length\":"
            << SyscallHandler.FTruncateLastLength
            << ",\"ftruncate_last_linux_error\":"
            << SyscallHandler.FTruncateLastLinuxError
            << ",\"ftruncate_last_failure_reason\":\""
            << SyscallHandler.FTruncateLastFailureReason << "\""
            << ",\"fchdir_syscall_seen\":"
            << (SyscallHandler.FChdirSeen ? "true" : "false")
            << ",\"fchdir_call_count\":"
            << SyscallHandler.FChdirCallCount
            << ",\"fchdir_success_count\":"
            << SyscallHandler.FChdirSuccessCount
            << ",\"fchdir_last_descriptor\":"
            << SyscallHandler.FChdirLastDescriptor
            << ",\"fchdir_last_path_length\":"
            << SyscallHandler.FChdirLastPathLength
            << ",\"fchdir_last_path_fingerprint\":"
            << SyscallHandler.FChdirLastPathFingerprint
            << ",\"fchdir_last_target_directory\":"
            << (SyscallHandler.FChdirLastTargetDirectory ? "true" : "false")
            << ",\"fchdir_last_target_confined\":"
            << (SyscallHandler.FChdirLastTargetConfined ? "true" : "false")
            << ",\"fchdir_last_host_cwd_matches_guest\":"
            << (SyscallHandler.FChdirLastHostCWDMatchesGuest ? "true" : "false")
            << ",\"fchdir_last_linux_error\":"
            << SyscallHandler.FChdirLastLinuxError
            << ",\"fchdir_last_failure_reason\":\""
            << SyscallHandler.FChdirLastFailureReason << "\""
            << ",\"connect_syscall_seen\":" << (SyscallHandler.ConnectSeen ? "true" : "false")
            << ",\"connect_call_count\":" << SyscallHandler.ConnectCallCount
            << ",\"connect_rootfs_confined_count\":"
            << SyscallHandler.ConnectRootFSConfinedCount
            << ",\"connect_alt_loader_mapped_count\":"
            << SyscallHandler.ConnectAltLoaderMappedCount
            << ",\"connect_missing_target_count\":"
            << SyscallHandler.ConnectMissingTargetCount
            << ",\"connect_success_count\":" << SyscallHandler.ConnectSuccessCount
            << ",\"connect_last_descriptor\":" << SyscallHandler.ConnectLastDescriptor
            << ",\"connect_last_address_length\":"
            << SyscallHandler.ConnectLastAddressLength
            << ",\"connect_last_family\":" << SyscallHandler.ConnectLastFamily
            << ",\"connect_last_payload_length\":"
            << SyscallHandler.ConnectLastPayloadLength
            << ",\"connect_last_path_class\":\""
            << ConnectPathClassName(SyscallHandler.ConnectLastPathClass) << "\""
            << ",\"connect_last_path_length\":" << SyscallHandler.ConnectLastPathLength
            << ",\"connect_last_path_fingerprint\":"
            << SyscallHandler.ConnectLastPathFingerprint
            << ",\"connect_last_host_path_length\":"
            << SyscallHandler.ConnectLastHostPathLength
            << ",\"connect_last_host_error\":" << SyscallHandler.ConnectLastHostError
            << ",\"connect_last_linux_error\":" << SyscallHandler.ConnectLastLinuxError
            << ",\"connect_last_alt_loader_mapped\":"
            << (SyscallHandler.ConnectLastAltLoaderMapped ? "true" : "false")
            << ",\"connect_last_failure_reason\":\""
            << ConnectFailureReasonName(SyscallHandler.ConnectLastFailureReason) << "\""
            << ",\"accept_syscall_seen\":" << (SyscallHandler.AcceptSeen ? "true" : "false")
            << ",\"accept_call_count\":" << SyscallHandler.AcceptCallCount
            << ",\"accept_success_count\":" << SyscallHandler.AcceptSuccessCount
            << ",\"accept_last_descriptor\":" << SyscallHandler.AcceptLastDescriptor
            << ",\"accept_last_descriptor_owned\":"
            << (SyscallHandler.AcceptLastDescriptorOwned ? "true" : "false")
            << ",\"accept_last_accepted_descriptor\":"
            << SyscallHandler.AcceptLastAcceptedDescriptor
            << ",\"accept_last_input_address_length\":"
            << SyscallHandler.AcceptLastInputAddressLength
            << ",\"accept_last_host_address_length\":"
            << SyscallHandler.AcceptLastHostAddressLength
            << ",\"accept_last_guest_address_length\":"
            << SyscallHandler.AcceptLastGuestAddressLength
            << ",\"accept_last_linux_error\":" << SyscallHandler.AcceptLastLinuxError
            << ",\"accept_last_failure_reason\":\""
            << AcceptFailureReasonName(SyscallHandler.AcceptLastFailureReason) << "\""
            << ",\"getsockopt_syscall_seen\":"
            << (SyscallHandler.GetSockOptSeen ? "true" : "false")
            << ",\"getsockopt_call_count\":" << SyscallHandler.GetSockOptCallCount
            << ",\"getsockopt_peer_credentials_call_count\":"
            << SyscallHandler.GetSockOptPeerCredentialsCallCount
            << ",\"getsockopt_peer_credentials_success_count\":"
            << SyscallHandler.GetSockOptPeerCredentialsSuccessCount
            << ",\"getsockopt_last_descriptor\":"
            << SyscallHandler.GetSockOptLastDescriptor
            << ",\"getsockopt_last_level\":" << SyscallHandler.GetSockOptLastLevel
            << ",\"getsockopt_last_option\":" << SyscallHandler.GetSockOptLastOption
            << ",\"getsockopt_last_input_length\":"
            << SyscallHandler.GetSockOptLastInputLength
            << ",\"getsockopt_last_output_length\":"
            << SyscallHandler.GetSockOptLastOutputLength
            << ",\"getsockopt_last_host_process_length\":"
            << SyscallHandler.GetSockOptLastHostProcessLength
            << ",\"getsockopt_last_host_process_id\":"
            << SyscallHandler.GetSockOptLastHostProcessID
            << ",\"getsockopt_last_host_user_id\":"
            << SyscallHandler.GetSockOptLastHostUserID
            << ",\"getsockopt_last_host_group_id\":"
            << SyscallHandler.GetSockOptLastHostGroupID
            << ",\"getsockopt_last_host_error\":"
            << SyscallHandler.GetSockOptLastHostError
            << ",\"getsockopt_last_linux_error\":"
            << SyscallHandler.GetSockOptLastLinuxError
            << ",\"getsockopt_last_failure_reason\":\""
            << GetSockOptFailureReasonName(SyscallHandler.GetSockOptLastFailureReason) << "\""
            << ",\"sendmsg_syscall_seen\":"
            << (SyscallHandler.SendMsgSeen ? "true" : "false")
            << ",\"sendmsg_call_count\":" << SyscallHandler.SendMsgCallCount
            << ",\"sendmsg_success_count\":" << SyscallHandler.SendMsgSuccessCount
            << ",\"sendmsg_standard_input_candidate_count\":"
            << SyscallHandler.SendMsgStandardInputCandidateCount
            << ",\"sendmsg_standard_input_success_count\":"
            << SyscallHandler.SendMsgStandardInputSuccessCount
            << ",\"sendmsg_standard_input_failure_count\":"
            << SyscallHandler.SendMsgStandardInputFailureCount
            << ",\"sendmsg_standard_output_candidate_count\":"
            << SyscallHandler.SendMsgStandardOutputCandidateCount
            << ",\"sendmsg_standard_output_success_count\":"
            << SyscallHandler.SendMsgStandardOutputSuccessCount
            << ",\"sendmsg_standard_output_failure_count\":"
            << SyscallHandler.SendMsgStandardOutputFailureCount
            << ",\"sendmsg_last_byte_count\":"
            << SyscallHandler.SendMsgLastByteCount
            << ",\"sendmsg_last_host_control_length\":"
            << SyscallHandler.SendMsgLastHostControlLength
            << ",\"sendmsg_last_descriptor\":"
            << SyscallHandler.SendMsgLastDescriptor
            << ",\"sendmsg_last_descriptor_owned\":"
            << (SyscallHandler.SendMsgLastDescriptorOwned ? "true" : "false")
            << ",\"sendmsg_last_call_flags\":"
            << SyscallHandler.SendMsgLastCallFlags
            << ",\"sendmsg_last_header_readable\":"
            << (SyscallHandler.SendMsgLastHeaderReadable ? "true" : "false")
            << ",\"sendmsg_last_name_present\":"
            << (SyscallHandler.SendMsgLastNamePresent ? "true" : "false")
            << ",\"sendmsg_last_name_length\":"
            << SyscallHandler.SendMsgLastNameLength
            << ",\"sendmsg_last_iovector_count\":"
            << SyscallHandler.SendMsgLastIOVectorCount
            << ",\"sendmsg_last_first_iovector_readable\":"
            << (SyscallHandler.SendMsgLastFirstIOVectorReadable ? "true" : "false")
            << ",\"sendmsg_last_first_iovector_base\":"
            << SyscallHandler.SendMsgLastFirstIOVectorBase
            << ",\"sendmsg_last_first_iovector_length\":"
            << SyscallHandler.SendMsgLastFirstIOVectorLength
            << ",\"sendmsg_last_first_iovector_payload_readable\":"
            << (SyscallHandler.SendMsgLastFirstIOVectorPayloadReadable ? "true" : "false")
            << ",\"sendmsg_last_first_iovector_payload_fingerprint\":"
            << SyscallHandler.SendMsgLastFirstIOVectorPayloadFingerprint
            << ",\"sendmsg_last_control_present\":"
            << (SyscallHandler.SendMsgLastControlPresent ? "true" : "false")
            << ",\"sendmsg_last_control_length\":"
            << SyscallHandler.SendMsgLastControlLength
            << ",\"sendmsg_last_control_readable\":"
            << (SyscallHandler.SendMsgLastControlReadable ? "true" : "false")
            << ",\"sendmsg_last_control_message_length\":"
            << SyscallHandler.SendMsgLastControlMessageLength
            << ",\"sendmsg_last_control_level\":"
            << SyscallHandler.SendMsgLastControlLevel
            << ",\"sendmsg_last_control_type\":"
            << SyscallHandler.SendMsgLastControlType
            << ",\"sendmsg_last_message_flags\":"
            << SyscallHandler.SendMsgLastMessageFlags
            << ",\"sendmsg_last_transferred_descriptor\":"
            << SyscallHandler.SendMsgLastTransferredDescriptor
            << ",\"sendmsg_last_transferred_descriptor_owned\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorOwned ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_standard\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorStandard ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_closed\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorClosed ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_flags\":"
            << SyscallHandler.SendMsgLastTransferredDescriptorFlags
            << ",\"sendmsg_last_transferred_descriptor_flags_error\":"
            << SyscallHandler.SendMsgLastTransferredDescriptorFlagsError
            << ",\"sendmsg_last_transferred_status_flags\":"
            << SyscallHandler.SendMsgLastTransferredStatusFlags
            << ",\"sendmsg_last_transferred_status_flags_error\":"
            << SyscallHandler.SendMsgLastTransferredStatusFlagsError
            << ",\"sendmsg_last_transferred_descriptor_stat_succeeded\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorStatSucceeded ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_fifo\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorFIFO ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_socket\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorSocket ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_regular\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorRegular ? "true" : "false")
            << ",\"sendmsg_last_transferred_descriptor_character\":"
            << (SyscallHandler.SendMsgLastTransferredDescriptorCharacter ? "true" : "false")
            << ",\"sendmsg_last_host_error\":"
            << SyscallHandler.SendMsgLastHostError
            << ",\"sendmsg_last_linux_error\":"
            << SyscallHandler.SendMsgLastLinuxError
            << ",\"sendmsg_last_failure_reason\":\""
            << SendMsgFailureReasonName(SyscallHandler.SendMsgLastFailureReason) << "\""
            << ",\"recvmsg_syscall_seen\":"
            << (SyscallHandler.RecvMsgSeen ? "true" : "false")
            << ",\"recvmsg_call_count\":" << SyscallHandler.RecvMsgCallCount
            << ",\"recvmsg_success_count\":" << SyscallHandler.RecvMsgSuccessCount
            << ",\"recvmsg_last_byte_count\":"
            << SyscallHandler.RecvMsgLastByteCount
            << ",\"recvmsg_last_host_control_length\":"
            << SyscallHandler.RecvMsgLastHostControlLength
            << ",\"recvmsg_last_host_control_message_length\":"
            << SyscallHandler.RecvMsgLastHostControlMessageLength
            << ",\"recvmsg_last_descriptor\":"
            << SyscallHandler.RecvMsgLastDescriptor
            << ",\"recvmsg_last_descriptor_owned\":"
            << (SyscallHandler.RecvMsgLastDescriptorOwned ? "true" : "false")
            << ",\"recvmsg_last_call_flags\":"
            << SyscallHandler.RecvMsgLastCallFlags
            << ",\"recvmsg_last_header_readable\":"
            << (SyscallHandler.RecvMsgLastHeaderReadable ? "true" : "false")
            << ",\"recvmsg_last_name_present\":"
            << (SyscallHandler.RecvMsgLastNamePresent ? "true" : "false")
            << ",\"recvmsg_last_name_length\":"
            << SyscallHandler.RecvMsgLastNameLength
            << ",\"recvmsg_last_iovector_count\":"
            << SyscallHandler.RecvMsgLastIOVectorCount
            << ",\"recvmsg_last_first_iovector_readable\":"
            << (SyscallHandler.RecvMsgLastFirstIOVectorReadable ? "true" : "false")
            << ",\"recvmsg_last_first_iovector_base\":"
            << SyscallHandler.RecvMsgLastFirstIOVectorBase
            << ",\"recvmsg_last_first_iovector_length\":"
            << SyscallHandler.RecvMsgLastFirstIOVectorLength
            << ",\"recvmsg_last_first_iovector_payload_readable\":"
            << (SyscallHandler.RecvMsgLastFirstIOVectorPayloadReadable ? "true" : "false")
            << ",\"recvmsg_last_payload_value\":"
            << SyscallHandler.RecvMsgLastPayloadValue
            << ",\"recvmsg_last_control_present\":"
            << (SyscallHandler.RecvMsgLastControlPresent ? "true" : "false")
            << ",\"recvmsg_last_control_length\":"
            << SyscallHandler.RecvMsgLastControlLength
            << ",\"recvmsg_last_control_readable\":"
            << (SyscallHandler.RecvMsgLastControlReadable ? "true" : "false")
            << ",\"recvmsg_last_message_flags\":"
            << SyscallHandler.RecvMsgLastMessageFlags
            << ",\"recvmsg_last_received_descriptor\":"
            << SyscallHandler.RecvMsgLastReceivedDescriptor
            << ",\"recvmsg_last_host_message_flags\":"
            << SyscallHandler.RecvMsgLastHostMessageFlags
            << ",\"recvmsg_last_host_error\":"
            << SyscallHandler.RecvMsgLastHostError
            << ",\"recvmsg_last_linux_error\":"
            << SyscallHandler.RecvMsgLastLinuxError
            << ",\"recvmsg_last_failure_reason\":\""
            << SyscallHandler.RecvMsgLastFailureReason << "\""
            << ",\"writev_syscall_seen\":" << (SyscallHandler.WriteVSeen ? "true" : "false")
            << ",\"writev_call_count\":" << SyscallHandler.WriteVCallCount
            << ",\"writev_success_count\":" << SyscallHandler.WriteVSuccessCount
            << ",\"writev_vector_count\":" << SyscallHandler.WriteVVectorCount
            << ",\"writev_byte_count\":" << SyscallHandler.WriteVByteCount
            << ",\"writev_wine_reply_candidate_count\":"
            << SyscallHandler.WriteVWineReplyCandidateCount
            << ",\"writev_wine_reply_success_count\":"
            << SyscallHandler.WriteVWineReplySuccessCount
            << ",\"writev_wine_reply_failure_count\":"
            << SyscallHandler.WriteVWineReplyFailureCount
            << ",\"writev_wine_default_dacl_reply_candidate_count\":"
            << SyscallHandler.WriteVWineDefaultDaclReplyCandidateCount
            << ",\"writev_wine_default_dacl_reply_success_count\":"
            << SyscallHandler.WriteVWineDefaultDaclReplySuccessCount
            << ",\"writev_wine_default_dacl_reply_failure_count\":"
            << SyscallHandler.WriteVWineDefaultDaclReplyFailureCount
            << ",\"writev_wine_variable_reply_candidate_count\":"
            << SyscallHandler.WriteVWineVariableReplyCandidateCount
            << ",\"writev_wine_variable_reply_success_count\":"
            << SyscallHandler.WriteVWineVariableReplySuccessCount
            << ",\"writev_wine_variable_reply_failure_count\":"
            << SyscallHandler.WriteVWineVariableReplyFailureCount
            << ",\"writev_wine_reply_last_descriptor\":"
            << SyscallHandler.WriteVWineReplyLastDescriptor
            << ",\"writev_wine_reply_last_vector_count\":"
            << SyscallHandler.WriteVWineReplyLastVectorCount
            << ",\"writev_wine_reply_last_requested_byte_count\":"
            << SyscallHandler.WriteVWineReplyLastRequestedByteCount
            << ",\"writev_wine_reply_last_returned_byte_count\":"
            << SyscallHandler.WriteVWineReplyLastReturnedByteCount
            << ",\"writev_wine_reply_last_host_error\":"
            << SyscallHandler.WriteVWineReplyLastHostError
            << ",\"writev_wine_reply_last_linux_error\":"
            << SyscallHandler.WriteVWineReplyLastLinuxError
            << ",\"writev_wine_request_candidate_count\":"
            << SyscallHandler.WriteVWineRequestCandidateCount
            << ",\"writev_wine_request_success_count\":"
            << SyscallHandler.WriteVWineRequestSuccessCount
            << ",\"writev_wine_request_failure_count\":"
            << SyscallHandler.WriteVWineRequestFailureCount
            << ",\"writev_wine_create_key_request_candidate_count\":"
            << SyscallHandler.WriteVWineCreateKeyRequestCandidateCount
            << ",\"writev_wine_create_key_request_success_count\":"
            << SyscallHandler.WriteVWineCreateKeyRequestSuccessCount
            << ",\"writev_wine_create_key_request_failure_count\":"
            << SyscallHandler.WriteVWineCreateKeyRequestFailureCount
            << ",\"writev_wine_enum_key_value_request_candidate_count\":"
            << SyscallHandler.WriteVWineEnumKeyValueRequestCandidateCount
            << ",\"writev_wine_enum_key_value_request_success_count\":"
            << SyscallHandler.WriteVWineEnumKeyValueRequestSuccessCount
            << ",\"writev_wine_enum_key_value_request_failure_count\":"
            << SyscallHandler.WriteVWineEnumKeyValueRequestFailureCount
            << ",\"writev_wine_open_key_request_candidate_count\":"
            << SyscallHandler.WriteVWineOpenKeyRequestCandidateCount
            << ",\"writev_wine_open_key_request_success_count\":"
            << SyscallHandler.WriteVWineOpenKeyRequestSuccessCount
            << ",\"writev_wine_open_key_request_failure_count\":"
            << SyscallHandler.WriteVWineOpenKeyRequestFailureCount
            << ",\"writev_wine_create_event_request_candidate_count\":"
            << SyscallHandler.WriteVWineCreateEventRequestCandidateCount
            << ",\"writev_wine_create_event_request_success_count\":"
            << SyscallHandler.WriteVWineCreateEventRequestSuccessCount
            << ",\"writev_wine_create_event_request_failure_count\":"
            << SyscallHandler.WriteVWineCreateEventRequestFailureCount
            << ",\"writev_wine_create_symlink_request_candidate_count\":"
            << SyscallHandler.WriteVWineCreateSymlinkRequestCandidateCount
            << ",\"writev_wine_create_symlink_request_success_count\":"
            << SyscallHandler.WriteVWineCreateSymlinkRequestSuccessCount
            << ",\"writev_wine_create_symlink_request_failure_count\":"
            << SyscallHandler.WriteVWineCreateSymlinkRequestFailureCount
            << ",\"writev_wine_new_process_request_candidate_count\":"
            << SyscallHandler.WriteVWineNewProcessRequestCandidateCount
            << ",\"writev_wine_new_process_request_success_count\":"
            << SyscallHandler.WriteVWineNewProcessRequestSuccessCount
            << ",\"writev_wine_new_process_request_failure_count\":"
            << SyscallHandler.WriteVWineNewProcessRequestFailureCount
            << ",\"writev_wine_create_file_request_candidate_count\":"
            << SyscallHandler.WriteVWineCreateFileRequestCandidateCount
            << ",\"writev_wine_create_file_request_success_count\":"
            << SyscallHandler.WriteVWineCreateFileRequestSuccessCount
            << ",\"writev_wine_create_file_request_failure_count\":"
            << SyscallHandler.WriteVWineCreateFileRequestFailureCount
            << ",\"writev_wine_request_last_descriptor\":"
            << SyscallHandler.WriteVWineRequestLastDescriptor
            << ",\"writev_wine_request_last_vector_count\":"
            << SyscallHandler.WriteVWineRequestLastVectorCount
            << ",\"writev_wine_request_last_requested_byte_count\":"
            << SyscallHandler.WriteVWineRequestLastRequestedByteCount
            << ",\"writev_wine_request_last_returned_byte_count\":"
            << SyscallHandler.WriteVWineRequestLastReturnedByteCount
            << ",\"writev_wine_request_last_host_error\":"
            << SyscallHandler.WriteVWineRequestLastHostError
            << ",\"writev_wine_request_last_linux_error\":"
            << SyscallHandler.WriteVWineRequestLastLinuxError
            << ",\"writev_rejected_call_count\":"
            << SyscallHandler.WriteVRejectedCallCount
            << ",\"writev_rejected_first_descriptor\":"
            << SyscallHandler.WriteVRejectedFirstDescriptor
            << ",\"writev_rejected_first_descriptor_owned\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorOwned ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_standard\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorStandard ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_closed\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorClosed ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_matches_recvmsg\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorMatchesRecvMsg ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_received_scm_rights\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorReceivedSCMRights ? "true" : "false")
            << ",\"writev_rejected_first_host_descriptor_flags\":"
            << SyscallHandler.WriteVRejectedFirstHostDescriptorFlags
            << ",\"writev_rejected_first_host_descriptor_error\":"
            << SyscallHandler.WriteVRejectedFirstHostDescriptorError
            << ",\"writev_rejected_first_host_status_flags\":"
            << SyscallHandler.WriteVRejectedFirstHostStatusFlags
            << ",\"writev_rejected_first_host_status_error\":"
            << SyscallHandler.WriteVRejectedFirstHostStatusError
            << ",\"writev_rejected_first_descriptor_stat_succeeded\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorStatSucceeded ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_fifo\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorFIFO ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_socket\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorSocket ? "true" : "false")
            << ",\"writev_rejected_first_descriptor_regular\":"
            << (SyscallHandler.WriteVRejectedFirstDescriptorRegular ? "true" : "false")
            << ",\"writev_rejected_first_guest_vectors\":"
            << SyscallHandler.WriteVRejectedFirstGuestVectors
            << ",\"writev_rejected_first_vector_count\":"
            << SyscallHandler.WriteVRejectedFirstVectorCount
            << ",\"writev_rejected_first_guest_vectors_class\":\""
            << SyscallHandler.WriteVRejectedFirstGuestVectorsClass << "\""
            << ",\"writev_rejected_first_guest_vectors_readable\":"
            << (SyscallHandler.WriteVRejectedFirstGuestVectorsReadable ? "true" : "false")
            << ",\"writev_rejected_first_total_byte_count\":"
            << SyscallHandler.WriteVRejectedFirstTotalByteCount
            << ",\"writev_rejected_first_all_payloads_readable\":"
            << (SyscallHandler.WriteVRejectedFirstAllPayloadsReadable ? "true" : "false")
            << ",\"writev_rejected_first_vector1_base\":"
            << SyscallHandler.WriteVRejectedFirstVector1Base
            << ",\"writev_rejected_first_vector1_length\":"
            << SyscallHandler.WriteVRejectedFirstVector1Length
            << ",\"writev_rejected_first_vector1_class\":\""
            << SyscallHandler.WriteVRejectedFirstVector1Class << "\""
            << ",\"writev_rejected_first_vector1_readable\":"
            << (SyscallHandler.WriteVRejectedFirstVector1Readable ? "true" : "false")
            << ",\"writev_rejected_first_vector1_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstVector1Fingerprint
            << ",\"writev_rejected_first_official_wineserver\":"
            << (SyscallHandler.WriteVRejectedFirstOfficialWineServer ? "true" : "false")
            << ",\"writev_rejected_first_reply_header_readable\":"
            << (SyscallHandler.WriteVRejectedFirstReplyHeaderReadable ? "true" : "false")
            << ",\"writev_rejected_first_reply_error\":"
            << SyscallHandler.WriteVRejectedFirstReplyError
            << ",\"writev_rejected_first_reply_declared_size\":"
            << SyscallHandler.WriteVRejectedFirstReplyDeclaredSize
            << ",\"writev_rejected_first_reply_declared_size_matches_vector2\":"
            << (SyscallHandler.WriteVRejectedFirstReplyDeclaredSizeMatchesVector2
                  ? "true" : "false")
            << ",\"writev_rejected_first_request_header_readable\":"
            << (SyscallHandler.WriteVRejectedFirstRequestHeaderReadable ? "true" : "false")
            << ",\"writev_rejected_first_request_code\":"
            << SyscallHandler.WriteVRejectedFirstRequestCode
            << ",\"writev_rejected_first_request_size\":"
            << SyscallHandler.WriteVRejectedFirstRequestSize
            << ",\"writev_rejected_first_reply_size\":"
            << SyscallHandler.WriteVRejectedFirstReplySize
            << ",\"writev_rejected_first_open_key_candidate\":"
            << (SyscallHandler.WriteVRejectedFirstOpenKeyCandidate ? "true" : "false")
            << ",\"writev_rejected_first_open_key_fixed_fields_readable\":"
            << (SyscallHandler.WriteVRejectedFirstOpenKeyFixedFieldsReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_open_key_parent\":"
            << SyscallHandler.WriteVRejectedFirstOpenKeyParent
            << ",\"writev_rejected_first_open_key_access\":"
            << SyscallHandler.WriteVRejectedFirstOpenKeyAccess
            << ",\"writev_rejected_first_open_key_attributes\":"
            << SyscallHandler.WriteVRejectedFirstOpenKeyAttributes
            << ",\"writev_rejected_first_open_key_name_length\":"
            << SyscallHandler.WriteVRejectedFirstOpenKeyNameLength
            << ",\"writev_rejected_first_open_key_name_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstOpenKeyNameEvenLength ? "true" : "false")
            << ",\"writev_rejected_first_open_key_name_readable\":"
            << (SyscallHandler.WriteVRejectedFirstOpenKeyNameReadable ? "true" : "false")
            << ",\"writev_rejected_first_open_key_name_has_embedded_null\":"
            << (SyscallHandler.WriteVRejectedFirstOpenKeyNameHasEmbeddedNull
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_key_candidate\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyCandidate ? "true" : "false")
            << ",\"writev_rejected_first_create_key_fixed_fields_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyFixedFieldsReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_key_object_attributes_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyObjectAttributesReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_key_access\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyAccess
            << ",\"writev_rejected_first_create_key_options\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyOptions
            << ",\"writev_rejected_first_create_key_root_directory\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyRootDirectory
            << ",\"writev_rejected_first_create_key_attributes\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyAttributes
            << ",\"writev_rejected_first_create_key_security_descriptor_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeySecurityDescriptorLength
            << ",\"writev_rejected_first_create_key_name_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyNameLength
            << ",\"writev_rejected_first_create_key_object_attributes_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyObjectAttributesLength
            << ",\"writev_rejected_first_create_key_layout_valid\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyLayoutValid ? "true" : "false")
            << ",\"writev_rejected_first_create_key_name_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyNameEvenLength ? "true" : "false")
            << ",\"writev_rejected_first_create_key_name_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyNameFingerprint
            << ",\"writev_rejected_first_create_key_class_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyClassLength
            << ",\"writev_rejected_first_create_key_class_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateKeyClassEvenLength ? "true" : "false")
            << ",\"writev_rejected_first_create_key_class_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateKeyClassFingerprint
            << ",\"writev_rejected_first_create_symlink_candidate\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkCandidate
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_fixed_fields_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkFixedFieldsReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_object_attributes_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkObjectAttributesReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_request_size_matches_payload\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkRequestSizeMatchesPayload
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_access\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkAccess
            << ",\"writev_rejected_first_create_symlink_root_directory\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkRootDirectory
            << ",\"writev_rejected_first_create_symlink_attributes\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkAttributes
            << ",\"writev_rejected_first_create_symlink_security_descriptor_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkSecurityDescriptorLength
            << ",\"writev_rejected_first_create_symlink_name_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkNameLength
            << ",\"writev_rejected_first_create_symlink_calculated_object_attributes_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkCalculatedObjectAttributesLength
            << ",\"writev_rejected_first_create_symlink_object_attributes_layout_valid\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkObjectAttributesLayoutValid
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_name_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkNameEvenLength
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_name_has_embedded_null\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkNameHasEmbeddedNull
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_name_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkNameFingerprint
            << ",\"writev_rejected_first_create_symlink_target_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkTargetLength
            << ",\"writev_rejected_first_create_symlink_target_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkTargetEvenLength
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_target_has_embedded_null\":"
            << (SyscallHandler.WriteVRejectedFirstCreateSymlinkTargetHasEmbeddedNull
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_symlink_target_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateSymlinkTargetFingerprint
            << ",\"writev_rejected_first_create_file_candidate\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileCandidate ? "true" : "false")
            << ",\"writev_rejected_first_create_file_fixed_fields_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileFixedFieldsReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_object_attributes_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileObjectAttributesReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_unix_name_readable\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileUnixNameReadable
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_request_size_matches_payloads\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileRequestSizeMatchesPayloads
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_access\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileAccess
            << ",\"writev_rejected_first_create_file_sharing\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileSharing
            << ",\"writev_rejected_first_create_file_disposition\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileDisposition
            << ",\"writev_rejected_first_create_file_options\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileOptions
            << ",\"writev_rejected_first_create_file_attributes\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileAttributes
            << ",\"writev_rejected_first_create_file_root_directory\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileRootDirectory
            << ",\"writev_rejected_first_create_file_object_attributes\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileObjectAttributes
            << ",\"writev_rejected_first_create_file_security_descriptor_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileSecurityDescriptorLength
            << ",\"writev_rejected_first_create_file_object_name_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileObjectNameLength
            << ",\"writev_rejected_first_create_file_security_descriptor_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileSecurityDescriptorEvenLength
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_object_name_even_length\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileObjectNameEvenLength
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_calculated_object_attributes_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileCalculatedObjectAttributesLength
            << ",\"writev_rejected_first_create_file_object_attributes_layout_valid\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileObjectAttributesLayoutValid
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_security_descriptor_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileSecurityDescriptorFingerprint
            << ",\"writev_rejected_first_create_file_object_name_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileObjectNameFingerprint
            << ",\"writev_rejected_first_create_file_object_name_has_embedded_null\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileObjectNameHasEmbeddedNull
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_unix_name_length\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileUnixNameLength
            << ",\"writev_rejected_first_create_file_unix_name_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstCreateFileUnixNameFingerprint
            << ",\"writev_rejected_first_create_file_unix_name_has_embedded_null\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileUnixNameHasEmbeddedNull
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_unix_name_printable_ascii\":"
            << (SyscallHandler.WriteVRejectedFirstCreateFileUnixNamePrintableASCII
                  ? "true" : "false")
            << ",\"writev_rejected_first_create_file_unix_name_path_class\":\""
            << SyscallHandler.WriteVRejectedFirstCreateFileUnixNamePathClass << "\""
            << ",\"writev_rejected_first_vector2_base\":"
            << SyscallHandler.WriteVRejectedFirstVector2Base
            << ",\"writev_rejected_first_vector2_length\":"
            << SyscallHandler.WriteVRejectedFirstVector2Length
            << ",\"writev_rejected_first_vector2_class\":\""
            << SyscallHandler.WriteVRejectedFirstVector2Class << "\""
            << ",\"writev_rejected_first_vector2_readable\":"
            << (SyscallHandler.WriteVRejectedFirstVector2Readable ? "true" : "false")
            << ",\"writev_rejected_first_vector2_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstVector2Fingerprint
            << ",\"writev_rejected_first_vector3_base\":"
            << SyscallHandler.WriteVRejectedFirstVector3Base
            << ",\"writev_rejected_first_vector3_length\":"
            << SyscallHandler.WriteVRejectedFirstVector3Length
            << ",\"writev_rejected_first_vector3_class\":\""
            << SyscallHandler.WriteVRejectedFirstVector3Class << "\""
            << ",\"writev_rejected_first_vector3_readable\":"
            << (SyscallHandler.WriteVRejectedFirstVector3Readable ? "true" : "false")
            << ",\"writev_rejected_first_vector3_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstVector3Fingerprint
            << ",\"writev_rejected_first_vector4_base\":"
            << SyscallHandler.WriteVRejectedFirstVector4Base
            << ",\"writev_rejected_first_vector4_length\":"
            << SyscallHandler.WriteVRejectedFirstVector4Length
            << ",\"writev_rejected_first_vector4_class\":\""
            << SyscallHandler.WriteVRejectedFirstVector4Class << "\""
            << ",\"writev_rejected_first_vector4_readable\":"
            << (SyscallHandler.WriteVRejectedFirstVector4Readable ? "true" : "false")
            << ",\"writev_rejected_first_vector4_fingerprint\":"
            << SyscallHandler.WriteVRejectedFirstVector4Fingerprint
            << ",\"write_syscall_seen\":" << (SyscallHandler.WriteSeen ? "true" : "false")
            << ",\"write_call_count\":" << SyscallHandler.WriteCallCount
            << ",\"write_byte_count\":" << SyscallHandler.WriteByteCount
            << ",\"write_alt_loader_candidate_count\":"
            << SyscallHandler.WriteAltLoaderCandidateCount
            << ",\"write_alt_loader_success_count\":"
            << SyscallHandler.WriteAltLoaderSuccessCount
            << ",\"write_alt_loader_failure_count\":"
            << SyscallHandler.WriteAltLoaderFailureCount
            << ",\"write_alt_loader_written_byte_count\":"
            << SyscallHandler.WriteAltLoaderWrittenByteCount
            << ",\"write_alt_loader_last_descriptor\":"
            << SyscallHandler.WriteAltLoaderLastDescriptor
            << ",\"write_alt_loader_last_byte_count\":"
            << SyscallHandler.WriteAltLoaderLastByteCount
            << ",\"write_alt_loader_last_returned_byte_count\":"
            << SyscallHandler.WriteAltLoaderLastReturnedByteCount
            << ",\"write_alt_loader_last_host_error\":"
            << SyscallHandler.WriteAltLoaderLastHostError
            << ",\"write_alt_loader_last_linux_error\":"
            << SyscallHandler.WriteAltLoaderLastLinuxError
            << ",\"write_registry_temporary_candidate_count\":"
            << SyscallHandler.WriteRegistryTemporaryCandidateCount
            << ",\"write_registry_temporary_trace\":[";
  for (size_t Index = 0; Index < SyscallHandler.WriteRegistryTemporaryTraceCount; ++Index) {
    if (Index != 0) {
      std::cout << ',';
    }
    const auto& Trace = SyscallHandler.WriteRegistryTemporaryTrace[Index];
    std::cout << "{\"descriptor\":" << Trace.Descriptor
              << ",\"buffer\":" << Trace.Buffer
              << ",\"byte_count\":" << Trace.ByteCount
              << ",\"buffer_class\":\"" << Trace.BufferClass << "\""
              << ",\"buffer_readable\":" << (Trace.BufferReadable ? "true" : "false")
              << ",\"buffer_fingerprint\":" << Trace.BufferFingerprint
              << ",\"host_descriptor_flags\":" << Trace.HostDescriptorFlags
              << ",\"host_descriptor_error\":" << Trace.HostDescriptorError
              << ",\"host_status_flags\":" << Trace.HostStatusFlags
              << ",\"host_status_error\":" << Trace.HostStatusError
              << ",\"descriptor_stat_succeeded\":"
              << (Trace.DescriptorStatSucceeded ? "true" : "false")
              << ",\"descriptor_regular\":" << (Trace.DescriptorRegular ? "true" : "false")
              << ",\"descriptor_fifo\":" << (Trace.DescriptorFIFO ? "true" : "false")
              << ",\"descriptor_socket\":" << (Trace.DescriptorSocket ? "true" : "false")
              << '}';
  }
  std::cout << ']'
            << ",\"write_registry_temporary_exact_candidate_count\":"
            << SyscallHandler.WriteRegistryTemporaryExactCandidateCount
            << ",\"write_registry_temporary_success_count\":"
            << SyscallHandler.WriteRegistryTemporarySuccessCount
            << ",\"write_registry_temporary_failure_count\":"
            << SyscallHandler.WriteRegistryTemporaryFailureCount
            << ",\"write_registry_temporary_written_byte_count\":"
            << SyscallHandler.WriteRegistryTemporaryWrittenByteCount
            << ",\"write_registry_temporary_last_descriptor\":"
            << SyscallHandler.WriteRegistryTemporaryLastDescriptor
            << ",\"write_registry_temporary_last_byte_count\":"
            << SyscallHandler.WriteRegistryTemporaryLastByteCount
            << ",\"write_registry_temporary_last_returned_byte_count\":"
            << SyscallHandler.WriteRegistryTemporaryLastReturnedByteCount
            << ",\"write_registry_temporary_last_host_error\":"
            << SyscallHandler.WriteRegistryTemporaryLastHostError
            << ",\"write_registry_temporary_last_linux_error\":"
            << SyscallHandler.WriteRegistryTemporaryLastLinuxError
            << ",\"write_wine_reply_seen\":"
            << (SyscallHandler.WriteWineReplySeen ? "true" : "false")
            << ",\"write_wine_reply_candidate_count\":"
            << SyscallHandler.WriteWineReplyCandidateCount
            << ",\"write_wine_reply_success_count\":"
            << SyscallHandler.WriteWineReplySuccessCount
            << ",\"write_wine_reply_failure_count\":"
            << SyscallHandler.WriteWineReplyFailureCount
            << ",\"write_wine_reply_written_byte_count\":"
            << SyscallHandler.WriteWineReplyWrittenByteCount
            << ",\"write_wine_reply_last_descriptor\":"
            << SyscallHandler.WriteWineReplyLastDescriptor
            << ",\"write_wine_reply_last_byte_count\":"
            << SyscallHandler.WriteWineReplyLastByteCount
            << ",\"write_wine_reply_last_host_error\":"
            << SyscallHandler.WriteWineReplyLastHostError
            << ",\"write_wine_reply_last_linux_error\":"
            << SyscallHandler.WriteWineReplyLastLinuxError
            << ",\"write_request_pipe_seen\":"
            << (SyscallHandler.WriteRequestPipeSeen ? "true" : "false")
            << ",\"write_request_pipe_candidate_count\":"
            << SyscallHandler.WriteRequestPipeCandidateCount
            << ",\"write_request_pipe_success_count\":"
            << SyscallHandler.WriteRequestPipeSuccessCount
            << ",\"write_request_pipe_failure_count\":"
            << SyscallHandler.WriteRequestPipeFailureCount
            << ",\"write_request_pipe_written_byte_count\":"
            << SyscallHandler.WriteRequestPipeWrittenByteCount
            << ",\"write_request_pipe_last_descriptor\":"
            << SyscallHandler.WriteRequestPipeLastDescriptor
            << ",\"write_request_pipe_last_byte_count\":"
            << SyscallHandler.WriteRequestPipeLastByteCount
            << ",\"write_request_pipe_last_host_error\":"
            << SyscallHandler.WriteRequestPipeLastHostError
            << ",\"write_request_pipe_last_linux_error\":"
            << SyscallHandler.WriteRequestPipeLastLinuxError
            << ",\"write_rejected_call_count\":" << SyscallHandler.WriteRejectedCallCount
            << ",\"write_rejected_first_descriptor\":"
            << SyscallHandler.WriteRejectedFirstDescriptor
            << ",\"write_rejected_first_descriptor_owned\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorOwned ? "true" : "false")
            << ",\"write_rejected_first_descriptor_standard\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorStandard ? "true" : "false")
            << ",\"write_rejected_first_descriptor_closed\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorClosed ? "true" : "false")
            << ",\"write_rejected_first_descriptor_matches_recvmsg\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorMatchesRecvMsg ? "true" : "false")
            << ",\"write_rejected_first_host_descriptor_flags\":"
            << SyscallHandler.WriteRejectedFirstHostDescriptorFlags
            << ",\"write_rejected_first_host_descriptor_error\":"
            << SyscallHandler.WriteRejectedFirstHostDescriptorError
            << ",\"write_rejected_first_descriptor_stat_succeeded\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorStatSucceeded ? "true" : "false")
            << ",\"write_rejected_first_descriptor_fifo\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorFIFO ? "true" : "false")
            << ",\"write_rejected_first_descriptor_socket\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorSocket ? "true" : "false")
            << ",\"write_rejected_first_descriptor_regular\":"
            << (SyscallHandler.WriteRejectedFirstDescriptorRegular ? "true" : "false")
            << ",\"write_rejected_first_buffer\":" << SyscallHandler.WriteRejectedFirstBuffer
            << ",\"write_rejected_first_byte_count\":"
            << SyscallHandler.WriteRejectedFirstByteCount
            << ",\"write_rejected_first_buffer_class\":\""
            << SyscallHandler.WriteRejectedFirstBufferClass << "\""
            << ",\"write_rejected_first_buffer_readable\":"
            << (SyscallHandler.WriteRejectedFirstBufferReadable ? "true" : "false")
            << ",\"write_rejected_first_buffer_fingerprint\":"
            << SyscallHandler.WriteRejectedFirstBufferFingerprint
            << ",\"stdout_byte_count\":" << SyscallHandler.CapturedOutput.size()
            << ",\"stderr_byte_count\":" << SyscallHandler.CapturedError.size()
            << ",\"first_unsupported_syscall\":";
  if (UnsupportedSeen) {
    std::cout << Unsupported;
  } else {
    std::cout << "null";
  }
  std::cout << ",\"first_unsupported_syscall_name\":\""
            << (UnsupportedSeen ? KnownSyscallName(Unsupported) : "none") << "\""
            << ",\"ioctl_tcgets2_candidate_count\":"
            << SyscallHandler.IoctlTCGets2CandidateCount
            << ",\"ioctl_tcgets2_non_tty_count\":"
            << SyscallHandler.IoctlTCGets2NonTTYCount
            << ",\"ioctl_tcgets2_last_descriptor\":"
            << SyscallHandler.IoctlTCGets2LastDescriptor
            << ",\"ioctl_tcgets2_last_descriptor_standard\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorStandard ? "true" : "false")
            << ",\"ioctl_tcgets2_last_descriptor_closed\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorClosed ? "true" : "false")
            << ",\"ioctl_tcgets2_last_argument\":"
            << SyscallHandler.IoctlTCGets2LastArgument
            << ",\"ioctl_tcgets2_last_argument_writable\":"
            << (SyscallHandler.IoctlTCGets2LastArgumentWritable ? "true" : "false")
            << ",\"ioctl_tcgets2_last_descriptor_stat_succeeded\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorStatSucceeded ? "true" : "false")
            << ",\"ioctl_tcgets2_last_descriptor_character\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorCharacter ? "true" : "false")
            << ",\"ioctl_tcgets2_last_descriptor_fifo\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorFIFO ? "true" : "false")
            << ",\"ioctl_tcgets2_last_descriptor_tty\":"
            << (SyscallHandler.IoctlTCGets2LastDescriptorTTY ? "true" : "false")
            << ",\"ioctl_tcgets2_last_host_error\":"
            << SyscallHandler.IoctlTCGets2LastHostError
            << ",\"ioctl_tcgets2_last_linux_error\":"
            << SyscallHandler.IoctlTCGets2LastLinuxError
            << ",\"ioctl_ext2_getflags_candidate_count\":"
            << SyscallHandler.IoctlExt2GetFlagsCandidateCount
            << ",\"ioctl_ext2_getflags_unsupported_filesystem_count\":"
            << SyscallHandler.IoctlExt2GetFlagsUnsupportedFilesystemCount
            << ",\"ioctl_ext2_getflags_last_descriptor\":"
            << SyscallHandler.IoctlExt2GetFlagsLastDescriptor
            << ",\"ioctl_ext2_getflags_last_descriptor_owned\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorOwned ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_argument\":"
            << SyscallHandler.IoctlExt2GetFlagsLastArgument
            << ",\"ioctl_ext2_getflags_last_argument_writable\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastArgumentWritable ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_stat_succeeded\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorStatSucceeded ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_directory\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorDirectory ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_regular\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorRegular ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_path_readable\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorPathReadable ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_path_confined\":"
            << (SyscallHandler.IoctlExt2GetFlagsLastDescriptorPathConfined ? "true" : "false")
            << ",\"ioctl_ext2_getflags_last_descriptor_path_length\":"
            << SyscallHandler.IoctlExt2GetFlagsLastDescriptorPathLength
            << ",\"ioctl_ext2_getflags_last_descriptor_path_fingerprint\":"
            << SyscallHandler.IoctlExt2GetFlagsLastDescriptorPathFingerprint
            << ",\"ioctl_ext2_getflags_last_linux_error\":"
            << SyscallHandler.IoctlExt2GetFlagsLastLinuxError
            << ",\"unsupported_ioctl_boundary_seen\":"
            << (SyscallHandler.UnsupportedIoctlBoundarySeen ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor\":"
            << SyscallHandler.UnsupportedIoctlDescriptor
            << ",\"unsupported_ioctl_descriptor_owned\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorOwned ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_standard\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorStandard ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_closed\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorClosed ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_stat_succeeded\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorStatSucceeded ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_fifo\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorFIFO ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_socket\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorSocket ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_regular\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorRegular ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_character\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorCharacter ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_tty\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorTTY ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_flags_readable\":"
            << (SyscallHandler.UnsupportedIoctlDescriptorFlagsReadable ? "true" : "false")
            << ",\"unsupported_ioctl_descriptor_flags\":"
            << SyscallHandler.UnsupportedIoctlDescriptorFlags
            << ",\"unsupported_ioctl_request\":"
            << SyscallHandler.UnsupportedIoctlRequest
            << ",\"unsupported_ioctl_request_number\":"
            << SyscallHandler.UnsupportedIoctlRequestNumber
            << ",\"unsupported_ioctl_request_type\":"
            << SyscallHandler.UnsupportedIoctlRequestType
            << ",\"unsupported_ioctl_request_size\":"
            << SyscallHandler.UnsupportedIoctlRequestSize
            << ",\"unsupported_ioctl_request_direction\":"
            << SyscallHandler.UnsupportedIoctlRequestDirection
            << ",\"unsupported_ioctl_argument\":"
            << SyscallHandler.UnsupportedIoctlArgument
            << ",\"unsupported_ioctl_argument_class\":\""
            << SyscallHandler.UnsupportedIoctlArgumentClass << "\""
            << ",\"unsupported_ioctl_argument_readable\":"
            << (SyscallHandler.UnsupportedIoctlArgumentReadable ? "true" : "false")
            << ",\"unsupported_ioctl_argument_writable\":"
            << (SyscallHandler.UnsupportedIoctlArgumentWritable ? "true" : "false")
            << ",\"unsupported_ioctl_argument_fingerprint\":"
            << SyscallHandler.UnsupportedIoctlArgumentFingerprint
            << ",\"unsupported_ioctl_call_ordinal\":"
            << SyscallHandler.UnsupportedIoctlCallOrdinal
            << ",\"unsupported_ioctl_guest_rip\":"
            << SyscallHandler.UnsupportedIoctlGuestRIP
            << ",\"unsupported_ioctl_read_wine_fixed_reply_count_at_boundary\":"
            << SyscallHandler.UnsupportedIoctlReadWineFixedReplyCountAtBoundary
            << ",\"unsupported_ioctl_write_request_pipe_count_at_boundary\":"
            << SyscallHandler.UnsupportedIoctlWriteRequestPipeCountAtBoundary
            << ",\"unsupported_getdents64_boundary_seen\":"
            << (SyscallHandler.UnsupportedGetDents64BoundarySeen ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor\":"
            << SyscallHandler.UnsupportedGetDents64Descriptor
            << ",\"unsupported_getdents64_descriptor_owned\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorOwned ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_stat_succeeded\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorStatSucceeded ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_directory\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorDirectory ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_offset_readable\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorOffsetReadable ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_offset\":"
            << SyscallHandler.UnsupportedGetDents64DescriptorOffset
            << ",\"unsupported_getdents64_descriptor_offset_host_error\":"
            << SyscallHandler.UnsupportedGetDents64DescriptorOffsetHostError
            << ",\"unsupported_getdents64_descriptor_path_readable\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorPathReadable ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_path_confined\":"
            << (SyscallHandler.UnsupportedGetDents64DescriptorPathConfined ? "true" : "false")
            << ",\"unsupported_getdents64_descriptor_path_length\":"
            << SyscallHandler.UnsupportedGetDents64DescriptorPathLength
            << ",\"unsupported_getdents64_descriptor_path_fingerprint\":"
            << SyscallHandler.UnsupportedGetDents64DescriptorPathFingerprint
            << ",\"unsupported_getdents64_guest_buffer\":"
            << SyscallHandler.UnsupportedGetDents64GuestBuffer
            << ",\"unsupported_getdents64_byte_count\":"
            << SyscallHandler.UnsupportedGetDents64ByteCount
            << ",\"unsupported_getdents64_buffer_class\":\""
            << SyscallHandler.UnsupportedGetDents64BufferClass << "\""
            << ",\"unsupported_getdents64_buffer_writable\":"
            << (SyscallHandler.UnsupportedGetDents64BufferWritable ? "true" : "false")
            << ",\"unsupported_getdents64_call_ordinal\":"
            << SyscallHandler.UnsupportedGetDents64CallOrdinal
            << ",\"unsupported_getdents64_guest_rip\":"
            << SyscallHandler.UnsupportedGetDents64GuestRIP
            << ",\"unsupported_umask_boundary_seen\":"
            << (SyscallHandler.UnsupportedUmaskBoundarySeen ? "true" : "false")
            << ",\"unsupported_umask_requested_mode\":"
            << SyscallHandler.UnsupportedUmaskRequestedMode
            << ",\"unsupported_umask_requested_mode_permission_bits_only\":"
            << (SyscallHandler.UnsupportedUmaskRequestedModePermissionBitsOnly
                  ? "true" : "false")
            << ",\"unsupported_umask_call_ordinal\":"
            << SyscallHandler.UnsupportedUmaskCallOrdinal
            << ",\"unsupported_umask_guest_rip\":"
            << SyscallHandler.UnsupportedUmaskGuestRIP
            << ",\"unsupported_umask_write_request_pipe_count_at_boundary\":"
            << SyscallHandler.UnsupportedUmaskWriteRequestPipeCountAtBoundary
            << ",\"unsupported_umask_read_wine_fixed_reply_count_at_boundary\":"
            << SyscallHandler.UnsupportedUmaskReadWineFixedReplyCountAtBoundary
            << ",\"unsupported_umask_write_rejected_count_at_boundary\":"
            << SyscallHandler.UnsupportedUmaskWriteRejectedCountAtBoundary
            << ",\"unsupported_tgkill_boundary_seen\":"
            << (SyscallHandler.UnsupportedTgkillBoundarySeen ? "true" : "false")
            << ",\"unsupported_tgkill_thread_group_id\":"
            << SyscallHandler.UnsupportedTgkillThreadGroupID
            << ",\"unsupported_tgkill_thread_id\":"
            << SyscallHandler.UnsupportedTgkillThreadID
            << ",\"unsupported_tgkill_signal\":"
            << SyscallHandler.UnsupportedTgkillSignal
            << ",\"unsupported_tgkill_thread_group_matches_last_getpid\":"
            << (SyscallHandler.UnsupportedTgkillThreadGroupMatchesLastGetPID
                  ? "true" : "false")
            << ",\"unsupported_tgkill_thread_matches_last_gettid\":"
            << (SyscallHandler.UnsupportedTgkillThreadMatchesLastGetTID
                  ? "true" : "false")
            << ",\"unsupported_socket_boundary_seen\":"
            << (SyscallHandler.UnsupportedSocketBoundarySeen ? "true" : "false")
            << ",\"unsupported_socket_domain\":" << SyscallHandler.UnsupportedSocketDomain
            << ",\"unsupported_socket_type\":" << SyscallHandler.UnsupportedSocketType
            << ",\"unsupported_socket_protocol\":" << SyscallHandler.UnsupportedSocketProtocol
            << ",\"unsupported_accept_boundary_seen\":"
            << (SyscallHandler.UnsupportedAcceptBoundarySeen ? "true" : "false")
            << ",\"unsupported_accept_descriptor\":"
            << SyscallHandler.UnsupportedAcceptDescriptor
            << ",\"unsupported_accept_descriptor_owned\":"
            << (SyscallHandler.UnsupportedAcceptDescriptorOwned ? "true" : "false")
            << ",\"unsupported_accept_address_class\":\""
            << SyscallHandler.UnsupportedAcceptAddressClass << "\""
            << ",\"unsupported_accept_address_length_class\":\""
            << SyscallHandler.UnsupportedAcceptAddressLengthClass << "\""
            << ",\"unsupported_accept_address_length_readable\":"
            << (SyscallHandler.UnsupportedAcceptAddressLengthReadable ? "true" : "false")
            << ",\"unsupported_accept_address_length\":"
            << SyscallHandler.UnsupportedAcceptAddressLength
            << ",\"unsupported_getsockopt_boundary_seen\":"
            << (SyscallHandler.UnsupportedGetSockOptBoundarySeen ? "true" : "false")
            << ",\"unsupported_getsockopt_descriptor\":"
            << SyscallHandler.UnsupportedGetSockOptDescriptor
            << ",\"unsupported_getsockopt_descriptor_owned\":"
            << (SyscallHandler.UnsupportedGetSockOptDescriptorOwned ? "true" : "false")
            << ",\"unsupported_getsockopt_level\":"
            << SyscallHandler.UnsupportedGetSockOptLevel
            << ",\"unsupported_getsockopt_option\":"
            << SyscallHandler.UnsupportedGetSockOptOption
            << ",\"unsupported_getsockopt_value_pointer_nonzero\":"
            << (SyscallHandler.UnsupportedGetSockOptValuePointerNonZero ? "true" : "false")
            << ",\"unsupported_getsockopt_length_pointer_nonzero\":"
            << (SyscallHandler.UnsupportedGetSockOptLengthPointerNonZero ? "true" : "false")
            << ",\"unsupported_getsockopt_length_readable\":"
            << (SyscallHandler.UnsupportedGetSockOptLengthReadable ? "true" : "false")
            << ",\"unsupported_getsockopt_value_readable\":"
            << (SyscallHandler.UnsupportedGetSockOptValueReadable ? "true" : "false")
            << ",\"unsupported_getsockopt_value_length\":"
            << SyscallHandler.UnsupportedGetSockOptValueLength
            << ",\"unsupported_sendmsg_boundary_seen\":"
            << (SyscallHandler.UnsupportedSendMsgBoundarySeen ? "true" : "false")
            << ",\"unsupported_sendmsg_descriptor\":"
            << SyscallHandler.UnsupportedSendMsgDescriptor
            << ",\"unsupported_sendmsg_descriptor_owned\":"
            << (SyscallHandler.UnsupportedSendMsgDescriptorOwned ? "true" : "false")
            << ",\"unsupported_sendmsg_call_flags\":"
            << SyscallHandler.UnsupportedSendMsgCallFlags
            << ",\"unsupported_sendmsg_header_readable\":"
            << (SyscallHandler.UnsupportedSendMsgHeaderReadable ? "true" : "false")
            << ",\"unsupported_sendmsg_name_present\":"
            << (SyscallHandler.UnsupportedSendMsgNamePresent ? "true" : "false")
            << ",\"unsupported_sendmsg_name_length\":"
            << SyscallHandler.UnsupportedSendMsgNameLength
            << ",\"unsupported_sendmsg_iovector_count\":"
            << SyscallHandler.UnsupportedSendMsgIOVectorCount
            << ",\"unsupported_sendmsg_first_iovector_readable\":"
            << (SyscallHandler.UnsupportedSendMsgFirstIOVectorReadable ? "true" : "false")
            << ",\"unsupported_sendmsg_first_iovector_length\":"
            << SyscallHandler.UnsupportedSendMsgFirstIOVectorLength
            << ",\"unsupported_sendmsg_first_iovector_value_readable\":"
            << (SyscallHandler.UnsupportedSendMsgFirstIOVectorValueReadable ? "true" : "false")
            << ",\"unsupported_sendmsg_first_iovector_value\":"
            << SyscallHandler.UnsupportedSendMsgFirstIOVectorValue
            << ",\"unsupported_sendmsg_control_present\":"
            << (SyscallHandler.UnsupportedSendMsgControlPresent ? "true" : "false")
            << ",\"unsupported_sendmsg_control_length\":"
            << SyscallHandler.UnsupportedSendMsgControlLength
            << ",\"unsupported_sendmsg_first_control_readable\":"
            << (SyscallHandler.UnsupportedSendMsgFirstControlReadable ? "true" : "false")
            << ",\"unsupported_sendmsg_first_control_message_length\":"
            << SyscallHandler.UnsupportedSendMsgFirstControlMessageLength
            << ",\"unsupported_sendmsg_first_control_level\":"
            << SyscallHandler.UnsupportedSendMsgFirstControlLevel
            << ",\"unsupported_sendmsg_first_control_type\":"
            << SyscallHandler.UnsupportedSendMsgFirstControlType
            << ",\"unsupported_sendmsg_first_control_descriptor_readable\":"
            << (SyscallHandler.UnsupportedSendMsgFirstControlDescriptorReadable ? "true" : "false")
            << ",\"unsupported_sendmsg_first_control_descriptor\":"
            << SyscallHandler.UnsupportedSendMsgFirstControlDescriptor
            << ",\"unsupported_sendmsg_first_control_descriptor_owned\":"
            << (SyscallHandler.UnsupportedSendMsgFirstControlDescriptorOwned ? "true" : "false")
            << ",\"unsupported_sendmsg_message_flags\":"
            << SyscallHandler.UnsupportedSendMsgMessageFlags
            << ",\"unsupported_munmap_boundary_seen\":"
            << (SyscallHandler.UnsupportedMUnmapBoundarySeen ? "true" : "false")
            << ",\"unsupported_munmap_address\":"
            << SyscallHandler.UnsupportedMUnmapAddress
            << ",\"unsupported_munmap_length\":"
            << SyscallHandler.UnsupportedMUnmapLength
            << ",\"unsupported_munmap_address_linux_page_aligned\":"
            << (SyscallHandler.UnsupportedMUnmapAddressLinuxPageAligned ? "true" : "false")
            << ",\"unsupported_munmap_length_linux_page_aligned\":"
            << (SyscallHandler.UnsupportedMUnmapLengthLinuxPageAligned ? "true" : "false")
            << ",\"unsupported_munmap_range_in_guest_memory\":"
            << (SyscallHandler.UnsupportedMUnmapRangeInGuestMemory ? "true" : "false")
            << ",\"unsupported_munmap_range_in_mmap_arena\":"
            << (SyscallHandler.UnsupportedMUnmapRangeInMMapArena ? "true" : "false")
            << ",\"unsupported_munmap_range_below_next_mmap_address\":"
            << (SyscallHandler.UnsupportedMUnmapRangeBelowNextMMapAddress ? "true" : "false")
            << ",\"unsupported_munmap_matches_last_mapping\":"
            << (SyscallHandler.UnsupportedMUnmapMatchesLastMapping ? "true" : "false")
            << ",\"unsupported_munmap_address_offset_from_arena\":"
            << SyscallHandler.UnsupportedMUnmapAddressOffsetFromArena
            << ",\"unsupported_munmap_last_mapping_address\":"
            << SyscallHandler.UnsupportedMUnmapLastMappingAddress
            << ",\"unsupported_munmap_last_mapping_length\":"
            << SyscallHandler.UnsupportedMUnmapLastMappingLength
            << ",\"unsupported_socketpair_boundary_seen\":"
            << (SyscallHandler.UnsupportedSocketPairBoundarySeen ? "true" : "false")
            << ",\"unsupported_socketpair_domain\":"
            << SyscallHandler.UnsupportedSocketPairDomain
            << ",\"unsupported_socketpair_type\":"
            << SyscallHandler.UnsupportedSocketPairType
            << ",\"unsupported_socketpair_protocol\":"
            << SyscallHandler.UnsupportedSocketPairProtocol
            << ",\"unsupported_socketpair_vector_class\":\""
            << SyscallHandler.UnsupportedSocketPairVectorClass << "\""
            << ",\"unsupported_socketpair_vector_readable\":"
            << (SyscallHandler.UnsupportedSocketPairVectorReadable ? "true" : "false")
            << ",\"unsupported_shutdown_boundary_seen\":"
            << (SyscallHandler.UnsupportedShutdownBoundarySeen ? "true" : "false")
            << ",\"unsupported_shutdown_descriptor_owned\":"
            << (SyscallHandler.UnsupportedShutdownDescriptorOwned ? "true" : "false")
            << ",\"unsupported_shutdown_descriptor\":"
            << SyscallHandler.UnsupportedShutdownDescriptor
            << ",\"unsupported_shutdown_how\":"
            << SyscallHandler.UnsupportedShutdownHow
            << ",\"unsupported_poll_boundary_seen\":"
            << (SyscallHandler.UnsupportedPollBoundarySeen ? "true" : "false")
            << ",\"unsupported_poll_array_readable\":"
            << (SyscallHandler.UnsupportedPollArrayReadable ? "true" : "false")
            << ",\"unsupported_poll_descriptor_count\":"
            << SyscallHandler.UnsupportedPollDescriptorCount
            << ",\"unsupported_poll_timeout\":"
            << SyscallHandler.UnsupportedPollTimeout
            << ",\"unsupported_poll_first_descriptor\":"
            << SyscallHandler.UnsupportedPollFirstDescriptor
            << ",\"unsupported_poll_first_events\":"
            << SyscallHandler.UnsupportedPollFirstEvents
            << ",\"unsupported_poll_first_returned_events\":"
            << SyscallHandler.UnsupportedPollFirstReturnedEvents
            << ",\"unsupported_poll_first_descriptor_owned\":"
            << (SyscallHandler.UnsupportedPollFirstDescriptorOwned ? "true" : "false")
            << ",\"unsupported_pipe2_boundary_seen\":"
            << (SyscallHandler.UnsupportedPipe2BoundarySeen ? "true" : "false")
            << ",\"unsupported_pipe2_vector_readable\":"
            << (SyscallHandler.UnsupportedPipe2VectorReadable ? "true" : "false")
            << ",\"unsupported_pipe2_vector_class\":\""
            << SyscallHandler.UnsupportedPipe2VectorClass << "\""
            << ",\"unsupported_pipe2_flags\":" << SyscallHandler.UnsupportedPipe2Flags
            << ",\"unsupported_connect_boundary_seen\":"
            << (SyscallHandler.UnsupportedConnectBoundarySeen ? "true" : "false")
            << ",\"unsupported_connect_descriptor_owned\":"
            << (SyscallHandler.UnsupportedConnectDescriptorOwned ? "true" : "false")
            << ",\"unsupported_connect_address_length\":"
            << SyscallHandler.UnsupportedConnectAddressLength
            << ",\"unsupported_connect_family\":" << SyscallHandler.UnsupportedConnectFamily
            << ",\"unsupported_connect_path_class\":\""
            << SyscallHandler.UnsupportedConnectPathClass << "\""
            << ",\"unsupported_connect_path_length\":"
            << SyscallHandler.UnsupportedConnectPathLength
            << ",\"unsupported_connect_path_fingerprint\":"
            << SyscallHandler.UnsupportedConnectPathFingerprint
            << ",\"unsupported_bind_boundary_seen\":"
            << (SyscallHandler.UnsupportedBindBoundarySeen ? "true" : "false")
            << ",\"unsupported_bind_descriptor\":"
            << SyscallHandler.UnsupportedBindDescriptor
            << ",\"unsupported_bind_descriptor_owned\":"
            << (SyscallHandler.UnsupportedBindDescriptorOwned ? "true" : "false")
            << ",\"unsupported_bind_address_readable\":"
            << (SyscallHandler.UnsupportedBindAddressReadable ? "true" : "false")
            << ",\"unsupported_bind_address_length\":"
            << SyscallHandler.UnsupportedBindAddressLength
            << ",\"unsupported_bind_family\":" << SyscallHandler.UnsupportedBindFamily
            << ",\"unsupported_bind_path_class\":\""
            << SyscallHandler.UnsupportedBindPathClass << "\""
            << ",\"unsupported_bind_path_terminated\":"
            << (SyscallHandler.UnsupportedBindPathTerminated ? "true" : "false")
            << ",\"unsupported_bind_path_length\":"
            << SyscallHandler.UnsupportedBindPathLength
            << ",\"unsupported_bind_path_fingerprint\":"
            << SyscallHandler.UnsupportedBindPathFingerprint
            << ",\"unsupported_bind_host_path_resolved\":"
            << (SyscallHandler.UnsupportedBindHostPathResolved ? "true" : "false")
            << ",\"unsupported_bind_target_exists\":"
            << (SyscallHandler.UnsupportedBindTargetExists ? "true" : "false")
            << ",\"unsupported_listen_boundary_seen\":"
            << (SyscallHandler.UnsupportedListenBoundarySeen ? "true" : "false")
            << ",\"unsupported_listen_descriptor\":"
            << SyscallHandler.UnsupportedListenDescriptor
            << ",\"unsupported_listen_descriptor_owned\":"
            << (SyscallHandler.UnsupportedListenDescriptorOwned ? "true" : "false")
            << ",\"unsupported_listen_backlog\":"
            << SyscallHandler.UnsupportedListenBacklog
            << ",\"unsupported_futex_waitv_boundary_seen\":"
            << (SyscallHandler.UnsupportedFutexWaitVBoundarySeen ? "true" : "false")
            << ",\"unsupported_futex_waitv_array_readable\":"
            << (SyscallHandler.UnsupportedFutexWaitVArrayReadable ? "true" : "false")
            << ",\"unsupported_futex_waitv_waiter_count\":"
            << SyscallHandler.UnsupportedFutexWaitVWaiterCount
            << ",\"unsupported_futex_waitv_flags\":"
            << SyscallHandler.UnsupportedFutexWaitVFlags
            << ",\"unsupported_futex_waitv_clock_id\":"
            << SyscallHandler.UnsupportedFutexWaitVClockID
            << ",\"unsupported_futex_waitv_first_expected_value\":"
            << SyscallHandler.UnsupportedFutexWaitVFirstExpectedValue
            << ",\"unsupported_futex_waitv_first_address\":"
            << SyscallHandler.UnsupportedFutexWaitVFirstAddress
            << ",\"unsupported_futex_waitv_first_flags\":"
            << SyscallHandler.UnsupportedFutexWaitVFirstFlags
            << ",\"unsupported_futex_waitv_first_reserved\":"
            << SyscallHandler.UnsupportedFutexWaitVFirstReserved
            << ",\"unsupported_futex_waitv_first_address_class\":\""
            << SyscallHandler.UnsupportedFutexWaitVFirstAddressClass << "\""
            << ",\"unsupported_futex_waitv_first_address_readable\":"
            << (SyscallHandler.UnsupportedFutexWaitVFirstAddressReadable ? "true" : "false")
            << ",\"unsupported_futex_waitv_first_current_value\":"
            << SyscallHandler.UnsupportedFutexWaitVFirstCurrentValue
            << ",\"unsupported_futex_waitv_timeout_class\":\""
            << SyscallHandler.UnsupportedFutexWaitVTimeoutClass << "\""
            << ",\"unsupported_futex_waitv_timeout_readable\":"
            << (SyscallHandler.UnsupportedFutexWaitVTimeoutReadable ? "true" : "false")
            << ",\"unsupported_futex_waitv_timeout_seconds\":"
            << SyscallHandler.UnsupportedFutexWaitVTimeoutSeconds
            << ",\"unsupported_futex_waitv_timeout_nanoseconds\":"
            << SyscallHandler.UnsupportedFutexWaitVTimeoutNanoseconds
            << ",\"unsupported_epoll_create_boundary_seen\":"
            << (SyscallHandler.UnsupportedEpollCreateBoundarySeen ? "true" : "false")
            << ",\"unsupported_epoll_create_size\":"
            << SyscallHandler.UnsupportedEpollCreateSize
            << ",\"unsupported_epoll_ctl_boundary_seen\":"
            << (SyscallHandler.UnsupportedEpollCtlBoundarySeen ? "true" : "false")
            << ",\"unsupported_epoll_ctl_epoll_descriptor\":"
            << SyscallHandler.UnsupportedEpollCtlEpollDescriptor
            << ",\"unsupported_epoll_ctl_epoll_descriptor_owned\":"
            << (SyscallHandler.UnsupportedEpollCtlEpollDescriptorOwned ? "true" : "false")
            << ",\"unsupported_epoll_ctl_epoll_descriptor_known\":"
            << (SyscallHandler.UnsupportedEpollCtlEpollDescriptorKnown ? "true" : "false")
            << ",\"unsupported_epoll_ctl_operation\":"
            << SyscallHandler.UnsupportedEpollCtlOperation
            << ",\"unsupported_epoll_ctl_target_descriptor\":"
            << SyscallHandler.UnsupportedEpollCtlTargetDescriptor
            << ",\"unsupported_epoll_ctl_target_descriptor_owned\":"
            << (SyscallHandler.UnsupportedEpollCtlTargetDescriptorOwned ? "true" : "false")
            << ",\"unsupported_epoll_ctl_event_class\":\""
            << SyscallHandler.UnsupportedEpollCtlEventClass << "\""
            << ",\"unsupported_epoll_ctl_event_readable\":"
            << (SyscallHandler.UnsupportedEpollCtlEventReadable ? "true" : "false")
            << ",\"unsupported_epoll_ctl_events\":"
            << SyscallHandler.UnsupportedEpollCtlEvents
            << ",\"unsupported_epoll_ctl_data\":"
            << SyscallHandler.UnsupportedEpollCtlData
            << ",\"unsupported_gettimeofday_boundary_seen\":"
            << (SyscallHandler.UnsupportedGettimeofdayBoundarySeen ? "true" : "false")
            << ",\"unsupported_gettimeofday_time_class\":\""
            << SyscallHandler.UnsupportedGettimeofdayTimeClass << "\""
            << ",\"unsupported_gettimeofday_time_readable\":"
            << (SyscallHandler.UnsupportedGettimeofdayTimeReadable ? "true" : "false")
            << ",\"unsupported_gettimeofday_timezone_class\":\""
            << SyscallHandler.UnsupportedGettimeofdayTimezoneClass << "\""
            << ",\"unsupported_gettimeofday_timezone_readable\":"
            << (SyscallHandler.UnsupportedGettimeofdayTimezoneReadable ? "true" : "false")
            << ",\"unsupported_setpriority_boundary_seen\":"
            << (SyscallHandler.UnsupportedSetPriorityBoundarySeen ? "true" : "false")
            << ",\"unsupported_setpriority_which\":"
            << SyscallHandler.UnsupportedSetPriorityWhich
            << ",\"unsupported_setpriority_who\":"
            << SyscallHandler.UnsupportedSetPriorityWho
            << ",\"unsupported_setpriority_nice\":"
            << SyscallHandler.UnsupportedSetPriorityNice
            << ",\"unsupported_fstatfs_boundary_seen\":"
            << (SyscallHandler.UnsupportedFStatFSBoundarySeen ? "true" : "false")
            << ",\"unsupported_fstatfs_descriptor\":"
            << SyscallHandler.UnsupportedFStatFSDescriptor
            << ",\"unsupported_fstatfs_descriptor_owned\":"
            << (SyscallHandler.UnsupportedFStatFSDescriptorOwned ? "true" : "false")
            << ",\"unsupported_fstatfs_descriptor_matches_intl_nls\":"
            << (SyscallHandler.UnsupportedFStatFSDescriptorMatchesIntlNLS ? "true" : "false")
            << ",\"unsupported_fstatfs_buffer_class\":\""
            << SyscallHandler.UnsupportedFStatFSBufferClass << "\""
            << ",\"unsupported_faccessat2_boundary_seen\":"
            << (SyscallHandler.UnsupportedFAccessAt2BoundarySeen ? "true" : "false")
            << ",\"unsupported_faccessat2_directory_descriptor\":"
            << SyscallHandler.UnsupportedFAccessAt2DirectoryDescriptor
            << ",\"unsupported_faccessat2_mode\":"
            << SyscallHandler.UnsupportedFAccessAt2Mode
            << ",\"unsupported_faccessat2_flags\":"
            << SyscallHandler.UnsupportedFAccessAt2Flags
            << ",\"unsupported_faccessat2_path_readable\":"
            << (SyscallHandler.UnsupportedFAccessAt2PathReadable ? "true" : "false")
            << ",\"unsupported_faccessat2_path_class\":\""
            << SyscallHandler.UnsupportedFAccessAt2PathClass << "\""
            << ",\"unsupported_faccessat2_path_length\":"
            << SyscallHandler.UnsupportedFAccessAt2PathLength
            << ",\"unsupported_faccessat2_path_fingerprint\":"
            << SyscallHandler.UnsupportedFAccessAt2PathFingerprint
            << ",\"unsupported_faccessat2_diagnostic_path\":\""
            << SyscallHandler.UnsupportedFAccessAt2DiagnosticPath << "\""
            << ",\"unsupported_faccessat2_host_path_resolved\":"
            << (SyscallHandler.UnsupportedFAccessAt2HostPathResolved ? "true" : "false")
            << ",\"unsupported_faccessat2_target_exists\":"
            << (SyscallHandler.UnsupportedFAccessAt2TargetExists ? "true" : "false")
            << ",\"unsupported_memfd_create_boundary_seen\":"
            << (SyscallHandler.UnsupportedMemfdCreateBoundarySeen ? "true" : "false")
            << ",\"unsupported_memfd_create_name_readable\":"
            << (SyscallHandler.UnsupportedMemfdCreateNameReadable ? "true" : "false")
            << ",\"unsupported_memfd_create_name_length\":"
            << SyscallHandler.UnsupportedMemfdCreateNameLength
            << ",\"unsupported_memfd_create_name_fingerprint\":"
            << SyscallHandler.UnsupportedMemfdCreateNameFingerprint
            << ",\"unsupported_memfd_create_flags\":"
            << SyscallHandler.UnsupportedMemfdCreateFlags
            << ",\"unsupported_memfd_create_diagnostic_name\":\""
            << SyscallHandler.UnsupportedMemfdCreateDiagnosticName << "\""
            << ",\"unsupported_pwrite64_boundary_seen\":"
            << (SyscallHandler.UnsupportedPWrite64BoundarySeen ? "true" : "false")
            << ",\"unsupported_pwrite64_descriptor\":"
            << SyscallHandler.UnsupportedPWrite64Descriptor
            << ",\"unsupported_pwrite64_descriptor_owned\":"
            << (SyscallHandler.UnsupportedPWrite64DescriptorOwned ? "true" : "false")
            << ",\"unsupported_pwrite64_descriptor_matches_memfd\":"
            << (SyscallHandler.UnsupportedPWrite64DescriptorMatchesMemfd ? "true" : "false")
            << ",\"unsupported_pwrite64_byte_count\":"
            << SyscallHandler.UnsupportedPWrite64ByteCount
            << ",\"unsupported_pwrite64_offset\":"
            << SyscallHandler.UnsupportedPWrite64Offset
            << ",\"unsupported_pwrite64_buffer_class\":\""
            << SyscallHandler.UnsupportedPWrite64BufferClass << "\""
            << ",\"unsupported_pwrite64_buffer_readable\":"
            << (SyscallHandler.UnsupportedPWrite64BufferReadable ? "true" : "false")
            << ",\"unsupported_pwrite64_buffer_fingerprint\":"
            << SyscallHandler.UnsupportedPWrite64BufferFingerprint
            << ",\"unsupported_pwrite64_first_byte\":"
            << SyscallHandler.UnsupportedPWrite64FirstByte
            << ",\"unsupported_ftruncate_boundary_seen\":"
            << (SyscallHandler.UnsupportedFTruncateBoundarySeen ? "true" : "false")
            << ",\"unsupported_ftruncate_descriptor\":"
            << SyscallHandler.UnsupportedFTruncateDescriptor
            << ",\"unsupported_ftruncate_descriptor_owned\":"
            << (SyscallHandler.UnsupportedFTruncateDescriptorOwned ? "true" : "false")
            << ",\"unsupported_ftruncate_descriptor_matches_memfd\":"
            << (SyscallHandler.UnsupportedFTruncateDescriptorMatchesMemfd ? "true" : "false")
            << ",\"unsupported_ftruncate_length\":"
            << SyscallHandler.UnsupportedFTruncateLength
            << ",\"unsupported_fchdir_boundary_seen\":"
            << (SyscallHandler.UnsupportedFChdirBoundarySeen ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor\":"
            << SyscallHandler.UnsupportedFChdirDescriptor
            << ",\"unsupported_fchdir_descriptor_owned\":"
            << (SyscallHandler.UnsupportedFChdirDescriptorOwned ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor_stat_succeeded\":"
            << (SyscallHandler.UnsupportedFChdirDescriptorStatSucceeded ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor_directory\":"
            << (SyscallHandler.UnsupportedFChdirDescriptorDirectory ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor_path_readable\":"
            << (SyscallHandler.UnsupportedFChdirDescriptorPathReadable ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor_path_confined\":"
            << (SyscallHandler.UnsupportedFChdirDescriptorPathConfined ? "true" : "false")
            << ",\"unsupported_fchdir_descriptor_path_length\":"
            << SyscallHandler.UnsupportedFChdirDescriptorPathLength
            << ",\"unsupported_fchdir_descriptor_path_fingerprint\":"
            << SyscallHandler.UnsupportedFChdirDescriptorPathFingerprint
            << ",\"unsupported_clone_boundary_seen\":"
            << (SyscallHandler.UnsupportedCloneBoundarySeen ? "true" : "false")
            << ",\"unsupported_clone_flags\":" << SyscallHandler.UnsupportedCloneFlags
            << ",\"unsupported_clone_exit_signal\":"
            << SyscallHandler.UnsupportedCloneExitSignal
            << ",\"unsupported_clone_child_stack_class\":\""
            << SyscallHandler.UnsupportedCloneChildStackClass << "\""
            << ",\"unsupported_clone_parent_tid_class\":\""
            << SyscallHandler.UnsupportedCloneParentTIDClass << "\""
            << ",\"unsupported_clone_child_tid_class\":\""
            << SyscallHandler.UnsupportedCloneChildTIDClass << "\""
            << ",\"unsupported_clone_tls_class\":\""
            << SyscallHandler.UnsupportedCloneTLSClass << "\""
            << ",\"unsupported_wait4_boundary_seen\":"
            << (SyscallHandler.UnsupportedWait4BoundarySeen ? "true" : "false")
            << ",\"unsupported_wait4_process_id\":"
            << SyscallHandler.UnsupportedWait4ProcessID
            << ",\"unsupported_wait4_options\":"
            << SyscallHandler.UnsupportedWait4Options
            << ",\"unsupported_wait4_status_class\":\""
            << SyscallHandler.UnsupportedWait4StatusClass << "\""
            << ",\"unsupported_wait4_resource_usage_class\":\""
            << SyscallHandler.UnsupportedWait4ResourceUsageClass << "\""
            << ",\"unsupported_fcntl_boundary_seen\":"
            << (SyscallHandler.UnsupportedFcntlBoundarySeen ? "true" : "false")
            << ",\"unsupported_fcntl_descriptor\":"
            << SyscallHandler.UnsupportedFcntlDescriptor
            << ",\"unsupported_fcntl_descriptor_owned\":"
            << (SyscallHandler.UnsupportedFcntlDescriptorOwned ? "true" : "false")
            << ",\"unsupported_fcntl_descriptor_standard\":"
            << (SyscallHandler.UnsupportedFcntlDescriptorStandard ? "true" : "false")
            << ",\"unsupported_fcntl_descriptor_closed\":"
            << (SyscallHandler.UnsupportedFcntlDescriptorClosed ? "true" : "false")
            << ",\"unsupported_fcntl_command\":"
            << SyscallHandler.UnsupportedFcntlCommand
            << ",\"unsupported_fcntl_argument_class\":\""
            << SyscallHandler.UnsupportedFcntlArgumentClass << "\""
            << ",\"unsupported_fcntl_flock_readable\":"
            << (SyscallHandler.UnsupportedFcntlFlockReadable ? "true" : "false")
            << ",\"unsupported_fcntl_flock_type\":"
            << SyscallHandler.UnsupportedFcntlFlockType
            << ",\"unsupported_fcntl_flock_whence\":"
            << SyscallHandler.UnsupportedFcntlFlockWhence
            << ",\"unsupported_fcntl_flock_start\":"
            << SyscallHandler.UnsupportedFcntlFlockStart
            << ",\"unsupported_fcntl_flock_length\":"
            << SyscallHandler.UnsupportedFcntlFlockLength
            << ",\"unsupported_fcntl_flock_process_id\":"
            << SyscallHandler.UnsupportedFcntlFlockProcessID
            << ",\"unsupported_unlink_boundary_seen\":"
            << (SyscallHandler.UnsupportedUnlinkBoundarySeen ? "true" : "false")
            << ",\"unsupported_unlink_path_readable\":"
            << (SyscallHandler.UnsupportedUnlinkPathReadable ? "true" : "false")
            << ",\"unsupported_unlink_path_class\":\""
            << SyscallHandler.UnsupportedUnlinkPathClass << "\""
            << ",\"unsupported_unlink_path_length\":"
            << SyscallHandler.UnsupportedUnlinkPathLength
            << ",\"unsupported_unlink_path_fingerprint\":"
            << SyscallHandler.UnsupportedUnlinkPathFingerprint
            << ",\"unsupported_unlink_host_path_resolved\":"
            << (SyscallHandler.UnsupportedUnlinkHostPathResolved ? "true" : "false")
            << ",\"unsupported_unlink_target_exists\":"
            << (SyscallHandler.UnsupportedUnlinkTargetExists ? "true" : "false")
            << ",\"unsupported_unlink_target_socket\":"
            << (SyscallHandler.UnsupportedUnlinkTargetSocket ? "true" : "false")
            << ",\"unsupported_unlink_target_regular\":"
            << (SyscallHandler.UnsupportedUnlinkTargetRegular ? "true" : "false")
            << ",\"unsupported_unlink_target_directory\":"
            << (SyscallHandler.UnsupportedUnlinkTargetDirectory ? "true" : "false")
            << ",\"unsupported_unlink_target_symlink\":"
            << (SyscallHandler.UnsupportedUnlinkTargetSymlink ? "true" : "false")
            << ",\"unsupported_chmod_boundary_seen\":"
            << (SyscallHandler.UnsupportedChmodBoundarySeen ? "true" : "false")
            << ",\"unsupported_chmod_path_readable\":"
            << (SyscallHandler.UnsupportedChmodPathReadable ? "true" : "false")
            << ",\"unsupported_chmod_path_class\":\""
            << SyscallHandler.UnsupportedChmodPathClass << "\""
            << ",\"unsupported_chmod_path_length\":"
            << SyscallHandler.UnsupportedChmodPathLength
            << ",\"unsupported_chmod_path_fingerprint\":"
            << SyscallHandler.UnsupportedChmodPathFingerprint
            << ",\"unsupported_chmod_mode\":" << SyscallHandler.UnsupportedChmodMode
            << ",\"unsupported_chmod_host_path_resolved\":"
            << (SyscallHandler.UnsupportedChmodHostPathResolved ? "true" : "false")
            << ",\"unsupported_chmod_target_exists\":"
            << (SyscallHandler.UnsupportedChmodTargetExists ? "true" : "false")
            << ",\"unsupported_chmod_target_socket\":"
            << (SyscallHandler.UnsupportedChmodTargetSocket ? "true" : "false")
            << ",\"unsupported_chmod_current_mode\":"
            << SyscallHandler.UnsupportedChmodCurrentMode
            << ",\"unsupported_open_boundary_seen\":"
            << (SyscallHandler.UnsupportedOpenBoundarySeen ? "true" : "false")
            << ",\"unsupported_open_path_readable\":"
            << (SyscallHandler.UnsupportedOpenPathReadable ? "true" : "false")
            << ",\"unsupported_open_path_class\":\""
            << SyscallHandler.UnsupportedOpenPathClass << "\""
            << ",\"unsupported_open_path_length\":"
            << SyscallHandler.UnsupportedOpenPathLength
            << ",\"unsupported_open_path_fingerprint\":"
            << SyscallHandler.UnsupportedOpenPathFingerprint
            << ",\"unsupported_open_target_exists\":"
            << (SyscallHandler.UnsupportedOpenTargetExists ? "true" : "false")
            << ",\"unsupported_open_flags\":"
            << SyscallHandler.UnsupportedOpenFlags
            << ",\"unsupported_open_mode\":"
            << SyscallHandler.UnsupportedOpenMode
            << ",\"unsupported_prctl_boundary_seen\":"
            << (SyscallHandler.UnsupportedPrctlBoundarySeen ? "true" : "false")
            << ",\"unsupported_prctl_option\":"
            << SyscallHandler.UnsupportedPrctlOption
            << ",\"unsupported_prctl_argument2_class\":\""
            << SyscallHandler.UnsupportedPrctlArgument2Class << "\""
            << ",\"unsupported_prctl_argument2_string_terminated\":"
            << (SyscallHandler.UnsupportedPrctlArgument2StringTerminated ? "true" : "false")
            << ",\"unsupported_prctl_argument2_string_length\":"
            << SyscallHandler.UnsupportedPrctlArgument2StringLength
            << ",\"unsupported_prctl_argument2_string_fingerprint\":"
            << SyscallHandler.UnsupportedPrctlArgument2StringFingerprint
            << ",\"unsupported_userfaultfd_boundary_seen\":"
            << (SyscallHandler.UnsupportedUserfaultfdBoundarySeen ? "true" : "false")
            << ",\"unsupported_userfaultfd_flags\":"
            << SyscallHandler.UnsupportedUserfaultfdFlags
            << ",\"unsupported_clone3_boundary_seen\":"
            << (SyscallHandler.UnsupportedClone3BoundarySeen ? "true" : "false")
            << ",\"unsupported_clone3_structure_readable\":"
            << (SyscallHandler.UnsupportedClone3StructureReadable ? "true" : "false")
            << ",\"unsupported_clone3_size\":" << SyscallHandler.UnsupportedClone3Size
            << ",\"unsupported_clone3_copied_size\":"
            << SyscallHandler.UnsupportedClone3CopiedSize
            << ",\"unsupported_clone3_flags\":" << SyscallHandler.UnsupportedClone3Flags
            << ",\"unsupported_clone3_exit_signal\":"
            << SyscallHandler.UnsupportedClone3ExitSignal
            << ",\"unsupported_clone3_stack_size\":"
            << SyscallHandler.UnsupportedClone3StackSize
            << ",\"unsupported_clone3_set_tid_size\":"
            << SyscallHandler.UnsupportedClone3SetTIDSize
            << ",\"unsupported_clone3_cgroup\":"
            << SyscallHandler.UnsupportedClone3CGroup
            << ",\"unsupported_clone3_argument_class\":\""
            << SyscallHandler.UnsupportedClone3ArgumentClass << "\""
            << ",\"unsupported_clone3_pidfd_class\":\""
            << SyscallHandler.UnsupportedClone3PIDFDClass << "\""
            << ",\"unsupported_clone3_child_tid_class\":\""
            << SyscallHandler.UnsupportedClone3ChildTIDClass << "\""
            << ",\"unsupported_clone3_parent_tid_class\":\""
            << SyscallHandler.UnsupportedClone3ParentTIDClass << "\""
            << ",\"unsupported_clone3_stack_class\":\""
            << SyscallHandler.UnsupportedClone3StackClass << "\""
            << ",\"unsupported_clone3_tls_class\":\""
            << SyscallHandler.UnsupportedClone3TLSClass << "\""
            << ",\"unsupported_clone3_set_tid_class\":\""
            << SyscallHandler.UnsupportedClone3SetTIDClass << "\""
            << ",\"unsupported_rt_sigaction_boundary_seen\":"
            << (SyscallHandler.UnsupportedRtSigactionBoundarySeen ? "true" : "false")
            << ",\"unsupported_rt_sigaction_action_readable\":"
            << (SyscallHandler.UnsupportedRtSigactionActionReadable ? "true" : "false")
            << ",\"unsupported_rt_sigaction_signal\":"
            << SyscallHandler.UnsupportedRtSigactionSignal
            << ",\"unsupported_rt_sigaction_sigset_size\":"
            << SyscallHandler.UnsupportedRtSigactionSigsetSize
            << ",\"unsupported_rt_sigaction_action_class\":\""
            << SyscallHandler.UnsupportedRtSigactionActionClass << "\""
            << ",\"unsupported_rt_sigaction_oldaction_class\":\""
            << SyscallHandler.UnsupportedRtSigactionOldActionClass << "\""
            << ",\"unsupported_rt_sigaction_handler_class\":\""
            << SyscallHandler.UnsupportedRtSigactionHandlerClass << "\""
            << ",\"unsupported_rt_sigaction_flags\":"
            << SyscallHandler.UnsupportedRtSigactionFlags
            << ",\"unsupported_rt_sigaction_restorer_class\":\""
            << SyscallHandler.UnsupportedRtSigactionRestorerClass << "\""
            << ",\"unsupported_rt_sigaction_mask_fingerprint\":"
            << SyscallHandler.UnsupportedRtSigactionMaskFingerprint
            << ",\"unsupported_rt_sigaction_action_fingerprint\":"
            << SyscallHandler.UnsupportedRtSigactionActionFingerprint
            << ",\"unsupported_rt_sigprocmask_boundary_seen\":"
            << (SyscallHandler.UnsupportedRtSigprocmaskBoundarySeen ? "true" : "false")
            << ",\"unsupported_rt_sigprocmask_how\":"
            << SyscallHandler.UnsupportedRtSigprocmaskHow
            << ",\"unsupported_rt_sigprocmask_sigset_size\":"
            << SyscallHandler.UnsupportedRtSigprocmaskSigsetSize
            << ",\"unsupported_rt_sigprocmask_set_class\":\""
            << SyscallHandler.UnsupportedRtSigprocmaskSetClass << "\""
            << ",\"unsupported_rt_sigprocmask_oldset_class\":\""
            << SyscallHandler.UnsupportedRtSigprocmaskOldSetClass << "\""
            << ",\"unsupported_rt_sigprocmask_set_fingerprint\":"
            << SyscallHandler.UnsupportedRtSigprocmaskSetFingerprint
            << ",\"unsupported_execve_boundary_seen\":"
            << (SyscallHandler.UnsupportedExecveBoundarySeen ? "true" : "false")
            << ",\"unsupported_execve_target_kind\":\""
            << SyscallHandler.UnsupportedExecveTargetKind << "\""
            << ",\"unsupported_execve_path_length\":"
            << SyscallHandler.UnsupportedExecvePathLength
            << ",\"unsupported_execve_path_fingerprint\":"
            << SyscallHandler.UnsupportedExecvePathFingerprint
            << ",\"unsupported_execve_target_exists\":"
            << (SyscallHandler.UnsupportedExecveTargetExists ? "true" : "false")
            << ",\"unsupported_execve_parent_segment_seen\":"
            << (SyscallHandler.UnsupportedExecveParentSegmentSeen ? "true" : "false")
            << ",\"unsupported_execve_normalized_path_confined\":"
            << (SyscallHandler.UnsupportedExecveNormalizedPathConfined ? "true" : "false")
            << ",\"unsupported_execve_normalized_path_length\":"
            << SyscallHandler.UnsupportedExecveNormalizedPathLength
            << ",\"unsupported_execve_normalized_path_fingerprint\":"
            << SyscallHandler.UnsupportedExecveNormalizedPathFingerprint
            << ",\"unsupported_execve_argv_readable\":"
            << (SyscallHandler.UnsupportedExecveArgvReadable ? "true" : "false")
            << ",\"unsupported_execve_argv_terminated\":"
            << (SyscallHandler.UnsupportedExecveArgvTerminated ? "true" : "false")
            << ",\"unsupported_execve_arg_count\":"
            << SyscallHandler.UnsupportedExecveArgCount
            << ",\"unsupported_execve_envp_readable\":"
            << (SyscallHandler.UnsupportedExecveEnvpReadable ? "true" : "false")
            << ",\"unsupported_execve_envp_terminated\":"
            << (SyscallHandler.UnsupportedExecveEnvpTerminated ? "true" : "false")
            << ",\"unsupported_execve_env_count\":"
            << SyscallHandler.UnsupportedExecveEnvCount
            << ",\"unsupported_execve_env_unknown_count\":"
            << SyscallHandler.UnsupportedExecveEnvUnknownCount
            << ",\"unsupported_execve_env_has_lc_all_c\":"
            << (SyscallHandler.UnsupportedExecveEnvHasLCAllC ? "true" : "false")
            << ",\"unsupported_execve_env_has_private_home\":"
            << (SyscallHandler.UnsupportedExecveEnvHasPrivateHome ? "true" : "false")
            << ",\"unsupported_execve_env_has_wine_loader_noexec\":"
            << (SyscallHandler.UnsupportedExecveEnvHasWineLoaderNoExec ? "true" : "false")
            << ",\"unsupported_execve_env_has_wine_arch_wow64\":"
            << (SyscallHandler.UnsupportedExecveEnvHasWineArchWow64 ? "true" : "false")
            << ",\"unsupported_execve_arg_lengths\":[";
  for (size_t Index = 0; Index < SyscallHandler.UnsupportedExecveArgLengths.size(); ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.UnsupportedExecveArgLengths[Index];
  }
  std::cout << "],\"unsupported_execve_arg_fingerprints\":[";
  for (size_t Index = 0; Index < SyscallHandler.UnsupportedExecveArgFingerprints.size(); ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.UnsupportedExecveArgFingerprints[Index];
  }
  std::cout << "],\"unsupported_execve_arg_kinds\":[";
  for (size_t Index = 0; Index < SyscallHandler.UnsupportedExecveArgKinds.size(); ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << '\"' << SyscallHandler.UnsupportedExecveArgKinds[Index] << '\"';
  }
  std::cout << "]"
            << ",\"unsupported_chdir_boundary_seen\":"
            << (SyscallHandler.UnsupportedChdirBoundarySeen ? "true" : "false")
            << ",\"unsupported_chdir_path_class\":\""
            << SyscallHandler.UnsupportedChdirPathClass << "\""
            << ",\"unsupported_chdir_path_length\":"
            << SyscallHandler.UnsupportedChdirPathLength
            << ",\"unsupported_chdir_path_fingerprint\":"
            << SyscallHandler.UnsupportedChdirPathFingerprint
            << ",\"unsupported_chdir_target_exists\":"
            << (SyscallHandler.UnsupportedChdirTargetExists ? "true" : "false")
            << ",\"unsupported_chdir_target_directory\":"
            << (SyscallHandler.UnsupportedChdirTargetDirectory ? "true" : "false")
            << ",\"unsupported_mkdir_boundary_seen\":"
            << (SyscallHandler.UnsupportedMkdirBoundarySeen ? "true" : "false")
            << ",\"unsupported_mkdir_path_readable\":"
            << (SyscallHandler.UnsupportedMkdirPathReadable ? "true" : "false")
            << ",\"unsupported_mkdir_path_class\":\""
            << SyscallHandler.UnsupportedMkdirPathClass << "\""
            << ",\"unsupported_mkdir_path_length\":"
            << SyscallHandler.UnsupportedMkdirPathLength
            << ",\"unsupported_mkdir_path_fingerprint\":"
            << SyscallHandler.UnsupportedMkdirPathFingerprint
            << ",\"unsupported_mkdir_mode\":" << SyscallHandler.UnsupportedMkdirMode
            << ",\"unsupported_mkdir_parent_confined\":"
            << (SyscallHandler.UnsupportedMkdirParentConfined ? "true" : "false")
            << ",\"unsupported_mkdir_parent_exists\":"
            << (SyscallHandler.UnsupportedMkdirParentExists ? "true" : "false")
            << ",\"unsupported_mkdir_parent_directory\":"
            << (SyscallHandler.UnsupportedMkdirParentDirectory ? "true" : "false")
            << ",\"unsupported_mkdir_target_exists\":"
            << (SyscallHandler.UnsupportedMkdirTargetExists ? "true" : "false")
            << ",\"unsupported_mkdir_target_directory\":"
            << (SyscallHandler.UnsupportedMkdirTargetDirectory ? "true" : "false")
            << ",\"unsupported_symlink_boundary_seen\":"
            << (SyscallHandler.UnsupportedSymlinkBoundarySeen ? "true" : "false")
            << ",\"unsupported_symlink_target_readable\":"
            << (SyscallHandler.UnsupportedSymlinkTargetReadable ? "true" : "false")
            << ",\"unsupported_symlink_target_class\":\""
            << SyscallHandler.UnsupportedSymlinkTargetClass << "\""
            << ",\"unsupported_symlink_target_length\":"
            << SyscallHandler.UnsupportedSymlinkTargetLength
            << ",\"unsupported_symlink_target_fingerprint\":"
            << SyscallHandler.UnsupportedSymlinkTargetFingerprint
            << ",\"unsupported_symlink_link_readable\":"
            << (SyscallHandler.UnsupportedSymlinkLinkReadable ? "true" : "false")
            << ",\"unsupported_symlink_link_class\":\""
            << SyscallHandler.UnsupportedSymlinkLinkClass << "\""
            << ",\"unsupported_symlink_link_length\":"
            << SyscallHandler.UnsupportedSymlinkLinkLength
            << ",\"unsupported_symlink_link_fingerprint\":"
            << SyscallHandler.UnsupportedSymlinkLinkFingerprint
            << ",\"unsupported_symlink_link_parent_confined\":"
            << (SyscallHandler.UnsupportedSymlinkLinkParentConfined ? "true" : "false")
            << ",\"unsupported_symlink_link_parent_exists\":"
            << (SyscallHandler.UnsupportedSymlinkLinkParentExists ? "true" : "false")
            << ",\"unsupported_symlink_link_parent_directory\":"
            << (SyscallHandler.UnsupportedSymlinkLinkParentDirectory ? "true" : "false")
            << ",\"unsupported_symlink_link_exists\":"
            << (SyscallHandler.UnsupportedSymlinkLinkExists ? "true" : "false")
            << ",\"exit_syscall_seen\":" << (SyscallHandler.ExitSeen ? "true" : "false")
            << ",\"exit_group_seen\":" << (SyscallHandler.ExitGroupSeen ? "true" : "false")
            << ",\"exit_code\":";
  if (SyscallHandler.ExitSeen) {
    std::cout << SyscallHandler.ExitCode;
  } else {
    std::cout << "null";
  }
  std::cout << ",\"exit_guest_rip\":" << SyscallHandler.ExitGuestRIP
            << ",\"exit_guest_rsp\":" << SyscallHandler.ExitGuestRSP
            << ",\"exit_guest_rbp\":" << SyscallHandler.ExitGuestRBP
            << ",\"exit_guest_rip_class\":\""
            << SyscallHandler.ExitGuestRIPClass << "\""
            << ",\"exit_guest_stack_words\":[";
  for (size_t Index = 0; Index < SyscallHandler.ExitGuestStackWordCount; ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.ExitGuestStackWords[Index];
  }
  std::cout << ']'
            << ",\"exit_guest_frame_pointers\":[";
  for (size_t Index = 0; Index < SyscallHandler.ExitGuestFrameCount; ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.ExitGuestFramePointers[Index];
  }
  std::cout << "]"
            << ",\"exit_guest_frame_return_addresses\":[";
  for (size_t Index = 0; Index < SyscallHandler.ExitGuestFrameCount; ++Index) {
    if (Index != 0) std::cout << ',';
    std::cout << SyscallHandler.ExitGuestFrameReturnAddresses[Index];
  }
  std::cout << ']'
            << ",\"main_completed\":" << (Completed ? "true" : "false")
            << ",\"proton_component_executed\":" << (OfficialProtonComponent ? "true" : "false")
            << ",\"proton_wine_ntdll_load_failure\":" << (ProtonWineNTDLLLoadFailure ? "true" : "false")
            << ",\"proton_wine_glibc_version_failure\":" << (ProtonWineGLIBCVersionFailure ? "true" : "false")
            << ",\"proton_executed\":false,\"steam_executed\":false,\"eac_executed\":false}\n";
  return BoundarySeen ? 0 : 70;
}
} // namespace

int RunControlled() {
  TemporaryDynamicELFs Fixture;
  if (!Fixture.Create()) {
    std::cerr << "No se pudo crear el par ELF dinámico controlado.\n";
    return 70;
  }

  ELFParser Main;
  if (!Main.ReadElf(fextl::string {Fixture.MainPath.c_str()}) || Main.type != ELFLoader::ELFContainer::TYPE_X86_64
      || Main.InterpreterElf.empty() || std::string {Main.InterpreterElf.c_str()} != InterpreterPath) {
    std::cerr << "ELFParser no resolvió PT_INTERP en el ELF principal.\n";
    return 70;
  }
  const std::string InterpreterFile = Fixture.Root + std::string {Main.InterpreterElf.c_str()};
  ELFParser Interpreter;
  if (!Interpreter.ReadElf(fextl::string {InterpreterFile.c_str()})
      || Interpreter.type != ELFLoader::ELFContainer::TYPE_X86_64 || !Interpreter.InterpreterElf.empty()) {
    std::cerr << "ELFParser no cargó el intérprete x86-64 controlado.\n";
    return 70;
  }

  GuestMapping Mapping;
  if (!Mapping.Allocate()) {
    std::cerr << "No se pudo reservar el espacio de proceso huésped.\n";
    return 70;
  }
  const uint64_t GuestBase = Mapping.Address();
  const uint64_t MainBase = GuestBase;
  const uint64_t InterpreterBase = GuestBase + InterpreterLoadOffset;
  size_t SegmentCount {};
  if (!MapELF(Main, GuestBase, GuestMemorySize, MainBase, &SegmentCount)
      || !MapELF(Interpreter, GuestBase, GuestMemorySize, InterpreterBase, &SegmentCount)) {
    std::cerr << "No se pudieron mapear los segmentos ELF controlados.\n";
    return 70;
  }
  const uint64_t BSSAddress = InterpreterBase + InterpreterDataOffset + ExpectedOutput.size();
  const bool BSSZeroed = *reinterpret_cast<const uint8_t*>(BSSAddress) == 0;
  const StackResult Stack = BuildInitialStack(GuestBase, Main, MainBase, InterpreterBase);
  if (!BSSZeroed || !Stack.Valid || !Mapping.MakeReadOnly()) {
    std::cerr << "El BSS o la pila Linux inicial no quedaron válidos.\n";
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
  ProcessSyscallHandler SyscallHandler {GuestBase, GuestMemorySize};
  auto Context = FEXCore::Context::Context::CreateNewContext(Features);
  if (!Context) {
    std::cerr << "FEXCore no creó el contexto de proceso dinámico.\n";
    return 70;
  }
  Context->EnableExitOnHLT();
  Context->SetSignalDelegator(&SignalDelegator);
  Context->SetSyscallHandler(&SyscallHandler);
  if (!Context->InitCore()) {
    std::cerr << "FEXCore no inicializó el contexto de proceso dinámico.\n";
    return 70;
  }

  const uint64_t GuestRIP = InterpreterBase + Interpreter.ehdr.e_entry;
  auto* Thread = Context->CreateThread(GuestRIP, Stack.Pointer);
  if (Thread == nullptr) {
    std::cerr << "FEXCore no creó el hilo del intérprete controlado.\n";
    return 70;
  }
  CallRetStackMapping CallRetStack;
  if (!CallRetStack.Attach(Thread)) {
    Context->DestroyThread(Thread);
    std::cerr << "No se pudo inicializar la pila call-ret controlada.\n";
    return 70;
  }
  std::array<FEXCore::Core::CPUState::gdt_segment, 32> GDT {};
  ConfigureLongMode(Thread, GDT);
  Context->CompileRIP(Thread, GuestRIP);
  DarwinUnalignedAccessHandler UnalignedHandler;
  if (!UnalignedHandler.Attach(Thread, GuestBase, GuestMemorySize)) {
    Context->DestroyThread(Thread);
    std::cerr << "No se pudo instalar el puente SIGBUS controlado de FEX.\n";
    return 70;
  }
  Context->ExecuteThread(Thread);
  const uint64_t UnalignedBackpatchCount = UnalignedHandler.Count();
  const uint64_t UnalignedSigbusCount = UnalignedHandler.BusCount();
  const uint64_t UnalignedSigsegvCount = UnalignedHandler.SegvCount();
  const uint64_t UnalignedSigsegvMissingAddressCount = UnalignedHandler.SegvMissingAddressCount();
  UnalignedHandler.Reset();

  const bool OutputMatches = SyscallHandler.CapturedOutput == ExpectedOutput;
  const bool Passed = SyscallHandler.WriteSeen && OutputMatches && SyscallHandler.ExitSeen
                   && SyscallHandler.ExitCode == ExpectedExitCode
                   && SyscallHandler.UnexpectedSyscall == std::numeric_limits<uint64_t>::max();
  Context->DestroyThread(Thread);

  std::cout << "{\"schema\":1,\"host\":\"macos-arm64\",\"parser\":\"FEX-ELFParser\""
            << ",\"main_elf_loaded\":true,\"pt_interp_resolved\":true,\"interpreter_elf_loaded\":true"
            << ",\"dynamic_interpreter\":\"controlled-x86-64-fixture\",\"segments_loaded\":" << SegmentCount
            << ",\"bss_zeroed\":" << (BSSZeroed ? "true" : "false")
            << ",\"initial_stack_present\":" << (Stack.Valid ? "true" : "false")
            << ",\"argv_seen_by_guest\":" << (SyscallHandler.ExitCode != FailureExitCode ? "true" : "false")
            << ",\"auxv_present\":true,\"unaligned_backpatch_count\":" << UnalignedBackpatchCount
            << ",\"unaligned_sigbus_count\":" << UnalignedSigbusCount
            << ",\"unaligned_sigsegv_count\":" << UnalignedSigsegvCount
            << ",\"unaligned_sigsegv_missing_address_count\":"
            << UnalignedSigsegvMissingAddressCount
            << ",\"write_syscall_seen\":" << (SyscallHandler.WriteSeen ? "true" : "false")
            << ",\"captured_output_match\":" << (OutputMatches ? "true" : "false")
            << ",\"exit_syscall_seen\":" << (SyscallHandler.ExitSeen ? "true" : "false")
            << ",\"exit_code\":" << SyscallHandler.ExitCode
            << ",\"glibc_loaded\":false,\"proton_executed\":false,\"steam_executed\":false,\"eac_executed\":false}\n";
  return Passed ? 0 : 70;
}

int main(int argc, char** argv) {
  if (argc == 2 && std::string_view {argv[1]} == "--native-vfork-proxy-child") {
    return 0;
  }
  if (argc == 1) {
    return RunControlled();
  }
  if (argc >= 3 && std::string_view {argv[1]} == "--real-rootfs") {
    std::string_view GuestProgram = "/usr/bin/true";
    std::string_view GuestComponentKind = "generic";
    std::string PrivateStderrOutput;
    std::string PrivateIRDumpDirectory;
    bool DisassembleHostBlocks = false;
    bool InstrumentLowPageAlias = false;
    bool InstrumentLowMemoryBias = false;
    bool InstrumentHighMemoryRegion = false;
    bool InstrumentVForkChild = false;
    bool InstrumentVForkParent = false;
    bool InstrumentVForkParentProcessBridge = false;
    bool InstrumentVForkParentWineServerBridge = false;
    std::string WineServerBridgeDirectory;
    bool GuestBindNow = false;
    bool InitialWineCommandLine = false;
    bool WineArchWow64 = false;
    std::string CXAltLoaderSocket;
    std::string CXAltLoaderHostSocket;
    uint64_t DiagnosticPostSessionSyscallLimit = 0;
    std::vector<std::string> GuestArguments;
    for (int Index = 3; Index < argc;) {
      const std::string_view Option {argv[Index]};
      if (Option == "--instrument-low-page-alias") {
        InstrumentLowPageAlias = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-low-memory-bias") {
        InstrumentLowMemoryBias = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-high-memory-region") {
        InstrumentHighMemoryRegion = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-vfork-child") {
        InstrumentVForkChild = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-vfork-parent") {
        InstrumentVForkParent = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-vfork-parent-process-bridge") {
        InstrumentVForkParentProcessBridge = true;
        ++Index;
        continue;
      }
      if (Option == "--instrument-vfork-parent-wineserver-bridge") {
        InstrumentVForkParentWineServerBridge = true;
        ++Index;
        continue;
      }
      if (Option == "--guest-bind-now") {
        GuestBindNow = true;
        ++Index;
        continue;
      }
      if (Option == "--initial-wine-command-line") {
        InitialWineCommandLine = true;
        ++Index;
        continue;
      }
      if (Option == "--wine-arch-wow64") {
        WineArchWow64 = true;
        ++Index;
        continue;
      }
      if (Option == "--disassemble-host-blocks") {
        DisassembleHostBlocks = true;
        ++Index;
        continue;
      }
      if (Index + 1 >= argc) {
        std::cerr << "Falta el valor de una opción del proceso huésped.\n";
        return 64;
      }
      if (Option == "--guest-program") {
        GuestProgram = argv[Index + 1];
      } else if (Option == "--guest-arg") {
        GuestArguments.emplace_back(argv[Index + 1]);
      } else if (Option == "--guest-component-kind") {
        GuestComponentKind = argv[Index + 1];
      } else if (Option == "--private-stderr-output") {
        PrivateStderrOutput = argv[Index + 1];
      } else if (Option == "--private-ir-dump-dir") {
        PrivateIRDumpDirectory = argv[Index + 1];
      } else if (Option == "--vfork-wineserver-bridge-dir") {
        WineServerBridgeDirectory = argv[Index + 1];
      } else if (Option == "--cx-alt-loader-socket") {
        CXAltLoaderSocket = argv[Index + 1];
      } else if (Option == "--cx-alt-loader-host-socket") {
        CXAltLoaderHostSocket = argv[Index + 1];
      } else if (Option == "--diagnostic-post-session-syscall-limit") {
        char* End = nullptr;
        errno = 0;
        const unsigned long long Parsed = std::strtoull(argv[Index + 1], &End, 10);
        if (errno != 0 || End == argv[Index + 1] || *End != '\0'
            || Parsed == 0 || Parsed > 10'000'000) {
          std::cerr << "El límite diagnóstico posterior al session mapping no es válido.\n";
          return 64;
        }
        DiagnosticPostSessionSyscallLimit = static_cast<uint64_t>(Parsed);
      } else {
        std::cerr << "Opción de proceso huésped desconocida.\n";
        return 64;
      }
      Index += 2;
    }
    return RunRealRootFS(
      argv[2],
      GuestProgram,
      GuestComponentKind,
      GuestArguments,
      InitialWineCommandLine,
      WineArchWow64,
      PrivateStderrOutput,
      PrivateIRDumpDirectory,
      DisassembleHostBlocks,
      InstrumentLowPageAlias,
      InstrumentLowMemoryBias,
      InstrumentHighMemoryRegion,
      InstrumentVForkChild,
      InstrumentVForkParent,
      InstrumentVForkParentProcessBridge,
      InstrumentVForkParentWineServerBridge,
      argv[0],
      WineServerBridgeDirectory,
      GuestBindNow,
      CXAltLoaderSocket,
      CXAltLoaderHostSocket,
      DiagnosticPostSessionSyscallLimit);
  }
  std::cerr << "Uso: fli-fexcore-process-probe [--real-rootfs RUTA "
               "[--guest-program /RUTA] [--guest-arg VALOR]... "
               "[--guest-component-kind TIPO] [--private-stderr-output RUTA_PRIVADA] "
               "[--private-ir-dump-dir DIRECTORIO_PRIVADO] "
               "[--disassemble-host-blocks] "
               "[--instrument-low-page-alias|--instrument-low-memory-bias] "
               "[--instrument-high-memory-region] "
               "[--instrument-vfork-child|--instrument-vfork-parent|"
               "--instrument-vfork-parent-process-bridge|"
               "--instrument-vfork-parent-wineserver-bridge] "
               "[--vfork-wineserver-bridge-dir DIRECTORIO_PRIVADO] [--guest-bind-now] "
               "[--cx-alt-loader-socket /tmp/SOCKET] "
               "[--cx-alt-loader-host-socket /private/tmp/SOCKET] "
               "[--initial-wine-command-line] "
               "[--wine-arch-wow64] "
               "[--diagnostic-post-session-syscall-limit N]]\n";
  return 64;
}
