// SPDX-License-Identifier: MIT

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>

#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <string_view>
#include <unistd.h>

namespace {
constexpr mach_vm_address_t WineSharedUserDataAddress = 0x7ffe0000;
constexpr mach_vm_size_t WineGuestPageSize = 4096;
constexpr uint64_t Sentinel = 0x5245475245535349ULL;

struct PageZeroDescription {
  bool Found {};
  bool ContainsTarget {};
  bool HasNoFileContents {};
  bool HasNoPermissions {};
  uint64_t Address {};
  uint64_t Size {};
};

struct RegionDescription {
  kern_return_t Result {KERN_FAILURE};
  mach_vm_address_t Address {};
  mach_vm_size_t Size {};
  vm_prot_t Protection {};
  vm_prot_t MaximumProtection {};
  bool ContainsTarget {};
};

mach_vm_size_t AlignUp(mach_vm_size_t Value, mach_vm_size_t Alignment) {
  return (Value + Alignment - 1) & ~(Alignment - 1);
}

bool RangeContains(
  uint64_t RangeAddress,
  uint64_t RangeSize,
  uint64_t Target,
  uint64_t TargetSize) {
  if (RangeSize > std::numeric_limits<uint64_t>::max() - RangeAddress
      || TargetSize > std::numeric_limits<uint64_t>::max() - Target) {
    return false;
  }
  return Target >= RangeAddress
    && Target + TargetSize <= RangeAddress + RangeSize;
}

PageZeroDescription DescribePageZero(mach_vm_size_t RoundedLength) {
  PageZeroDescription Result;
  const auto* Command = reinterpret_cast<const uint8_t*>(&_mh_execute_header)
    + sizeof(mach_header_64);

  for (uint32_t Index = 0; Index < _mh_execute_header.ncmds; ++Index) {
    const auto* Header = reinterpret_cast<const load_command*>(Command);
    if (Header->cmdsize < sizeof(load_command)) {
      break;
    }
    if (Header->cmd == LC_SEGMENT_64 && Header->cmdsize >= sizeof(segment_command_64)) {
      const auto* Segment = reinterpret_cast<const segment_command_64*>(Command);
      if (std::strncmp(Segment->segname, SEG_PAGEZERO, sizeof(Segment->segname)) == 0) {
        Result.Found = true;
        Result.Address = Segment->vmaddr;
        Result.Size = Segment->vmsize;
        Result.ContainsTarget = RangeContains(
          Segment->vmaddr,
          Segment->vmsize,
          WineSharedUserDataAddress,
          RoundedLength);
        Result.HasNoFileContents = Segment->fileoff == 0 && Segment->filesize == 0;
        Result.HasNoPermissions = Segment->initprot == VM_PROT_NONE
          && Segment->maxprot == VM_PROT_NONE;
        break;
      }
    }
    Command += Header->cmdsize;
  }
  return Result;
}

RegionDescription DescribeRegion(mach_vm_address_t Target) {
  RegionDescription Result;
  vm_region_basic_info_data_64_t Info {};
  mach_msg_type_number_t Count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t ObjectName = MACH_PORT_NULL;
  Result.Address = Target;
  Result.Result = mach_vm_region(
    mach_task_self(),
    &Result.Address,
    &Result.Size,
    VM_REGION_BASIC_INFO_64,
    reinterpret_cast<vm_region_info_t>(&Info),
    &Count,
    &ObjectName);
  if (ObjectName != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), ObjectName);
  }
  if (Result.Result == KERN_SUCCESS) {
    Result.Protection = Info.protection;
    Result.MaximumProtection = Info.max_protection;
    Result.ContainsTarget = RangeContains(Result.Address, Result.Size, Target, 1);
  }
  return Result;
}
} // namespace

int main(int ArgumentCount, char** Arguments) {
  const bool ReleaseOwnPageZero = ArgumentCount == 2
    && std::string_view(Arguments[1]) == "--release-own-pagezero";
  if (!ReleaseOwnPageZero) {
    std::cerr << "Esta sonda exige --release-own-pagezero.\n";
    return 64;
  }

  const long PageSizeResult = sysconf(_SC_PAGESIZE);
  if (PageSizeResult <= 0) {
    std::cerr << "No se pudo obtener el tamaño de página del host.\n";
    return 70;
  }

  const auto HostPageSize = static_cast<mach_vm_size_t>(PageSizeResult);
  const bool HostPageSizeIsPowerOfTwo = (HostPageSize & (HostPageSize - 1)) == 0;
  if (!HostPageSizeIsPowerOfTwo
      || WineGuestPageSize > std::numeric_limits<mach_vm_size_t>::max() - (HostPageSize - 1)) {
    std::cerr << "El tamaño de página del host no permite una alineación segura.\n";
    return 70;
  }

  const mach_vm_size_t RoundedLength = AlignUp(WineGuestPageSize, HostPageSize);
  const bool TargetIsHostPageAligned = WineSharedUserDataAddress % HostPageSize == 0;
  const PageZeroDescription PageZero = DescribePageZero(RoundedLength);
  const bool PageZeroIsSafeToRelease = PageZero.Found
    && PageZero.ContainsTarget
    && PageZero.HasNoFileContents
    && PageZero.HasNoPermissions;
  const RegionDescription RegionBefore = DescribeRegion(WineSharedUserDataAddress);

  mach_vm_address_t InitialAddress = WineSharedUserDataAddress;
  const kern_return_t InitialAllocateResult = TargetIsHostPageAligned
    ? mach_vm_allocate(
        mach_task_self(),
        &InitialAddress,
        RoundedLength,
        VM_FLAGS_FIXED)
    : KERN_INVALID_ARGUMENT;
  const bool InitialAllocateSucceeded = InitialAllocateResult == KERN_SUCCESS
    && InitialAddress == WineSharedUserDataAddress;

  const kern_return_t PageZeroReleaseResult = !InitialAllocateSucceeded
      && PageZeroIsSafeToRelease
    ? mach_vm_deallocate(
        mach_task_self(),
        WineSharedUserDataAddress,
        RoundedLength)
    : KERN_FAILURE;
  const RegionDescription RegionAfterRelease = DescribeRegion(WineSharedUserDataAddress);

  mach_vm_address_t CandidateAddress = WineSharedUserDataAddress;
  const kern_return_t CandidateAllocateResult = !InitialAllocateSucceeded
      && PageZeroReleaseResult == KERN_SUCCESS
    ? mach_vm_allocate(
        mach_task_self(),
        &CandidateAddress,
        RoundedLength,
        VM_FLAGS_FIXED)
    : KERN_FAILURE;
  const bool CandidateAllocateSucceeded = CandidateAllocateResult == KERN_SUCCESS
    && CandidateAddress == WineSharedUserDataAddress;

  kern_return_t ProtectResult = KERN_FAILURE;
  kern_return_t CollisionAllocateResult = KERN_FAILURE;
  bool SentinelPreserved {};
  kern_return_t CleanupResult = KERN_FAILURE;
  if (CandidateAllocateSucceeded) {
    auto* const Value = reinterpret_cast<volatile uint64_t*>(WineSharedUserDataAddress);
    *Value = Sentinel;
    ProtectResult = mach_vm_protect(
      mach_task_self(),
      WineSharedUserDataAddress,
      RoundedLength,
      false,
      VM_PROT_READ);

    mach_vm_address_t CollisionAddress = WineSharedUserDataAddress;
    CollisionAllocateResult = mach_vm_allocate(
      mach_task_self(),
      &CollisionAddress,
      RoundedLength,
      VM_FLAGS_FIXED);
    SentinelPreserved = *Value == Sentinel;
    CleanupResult = mach_vm_deallocate(
      mach_task_self(),
      WineSharedUserDataAddress,
      RoundedLength);
  }

  mach_vm_address_t ReallocateAddress = WineSharedUserDataAddress;
  const kern_return_t ReallocateResult = CleanupResult == KERN_SUCCESS
    ? mach_vm_allocate(
        mach_task_self(),
        &ReallocateAddress,
        RoundedLength,
        VM_FLAGS_FIXED)
    : KERN_FAILURE;
  const bool ReallocateSucceeded = ReallocateResult == KERN_SUCCESS
    && ReallocateAddress == WineSharedUserDataAddress;
  const kern_return_t ReallocateCleanupResult = ReallocateSucceeded
    ? mach_vm_deallocate(
        mach_task_self(),
        WineSharedUserDataAddress,
        RoundedLength)
    : KERN_FAILURE;

  const bool CollisionRejected = CollisionAllocateResult != KERN_SUCCESS;
  const bool Passed = PageZeroIsSafeToRelease
    && !InitialAllocateSucceeded
    && PageZeroReleaseResult == KERN_SUCCESS
    && CandidateAllocateSucceeded
    && ProtectResult == KERN_SUCCESS
    && CollisionRejected
    && SentinelPreserved
    && CleanupResult == KERN_SUCCESS
    && ReallocateSucceeded
    && ReallocateCleanupResult == KERN_SUCCESS;

  std::cout << "{\"schema\":2"
            << ",\"host\":\"macos-arm64\""
            << ",\"requested_address\":" << WineSharedUserDataAddress
            << ",\"guest_requested_length\":" << WineGuestPageSize
            << ",\"host_page_size\":" << HostPageSize
            << ",\"host_page_size_power_of_two\":"
            << (HostPageSizeIsPowerOfTwo ? "true" : "false")
            << ",\"target_host_page_aligned\":"
            << (TargetIsHostPageAligned ? "true" : "false")
            << ",\"rounded_host_length\":" << RoundedLength
            << ",\"pagezero_found\":" << (PageZero.Found ? "true" : "false")
            << ",\"pagezero_address\":" << PageZero.Address
            << ",\"pagezero_size\":" << PageZero.Size
            << ",\"pagezero_contains_target\":"
            << (PageZero.ContainsTarget ? "true" : "false")
            << ",\"pagezero_has_no_file_contents\":"
            << (PageZero.HasNoFileContents ? "true" : "false")
            << ",\"pagezero_has_no_permissions\":"
            << (PageZero.HasNoPermissions ? "true" : "false")
            << ",\"pagezero_safe_to_release\":"
            << (PageZeroIsSafeToRelease ? "true" : "false")
            << ",\"region_before_result\":" << RegionBefore.Result
            << ",\"region_before_address\":" << RegionBefore.Address
            << ",\"region_before_size\":" << RegionBefore.Size
            << ",\"region_before_protection\":" << RegionBefore.Protection
            << ",\"region_before_maximum_protection\":" << RegionBefore.MaximumProtection
            << ",\"region_before_contains_target\":"
            << (RegionBefore.ContainsTarget ? "true" : "false")
            << ",\"initial_allocate_result\":" << InitialAllocateResult
            << ",\"initial_allocate_success\":"
            << (InitialAllocateSucceeded ? "true" : "false")
            << ",\"pagezero_release_result\":" << PageZeroReleaseResult
            << ",\"pagezero_release_success\":"
            << (PageZeroReleaseResult == KERN_SUCCESS ? "true" : "false")
            << ",\"region_after_release_result\":" << RegionAfterRelease.Result
            << ",\"region_after_release_address\":" << RegionAfterRelease.Address
            << ",\"region_after_release_size\":" << RegionAfterRelease.Size
            << ",\"region_after_release_protection\":" << RegionAfterRelease.Protection
            << ",\"region_after_release_maximum_protection\":"
            << RegionAfterRelease.MaximumProtection
            << ",\"region_after_release_contains_target\":"
            << (RegionAfterRelease.ContainsTarget ? "true" : "false")
            << ",\"candidate_allocate_result\":" << CandidateAllocateResult
            << ",\"candidate_allocate_success\":"
            << (CandidateAllocateSucceeded ? "true" : "false")
            << ",\"protect_read_only_result\":" << ProtectResult
            << ",\"protect_read_only_success\":"
            << (ProtectResult == KERN_SUCCESS ? "true" : "false")
            << ",\"collision_allocate_result\":" << CollisionAllocateResult
            << ",\"collision_rejected\":" << (CollisionRejected ? "true" : "false")
            << ",\"sentinel_preserved\":" << (SentinelPreserved ? "true" : "false")
            << ",\"cleanup_deallocate_result\":" << CleanupResult
            << ",\"cleanup_deallocate_success\":"
            << (CleanupResult == KERN_SUCCESS ? "true" : "false")
            << ",\"reallocate_result\":" << ReallocateResult
            << ",\"reallocate_success\":"
            << (ReallocateSucceeded ? "true" : "false")
            << ",\"reallocate_cleanup_result\":" << ReallocateCleanupResult
            << ",\"reallocate_cleanup_success\":"
            << (ReallocateCleanupResult == KERN_SUCCESS ? "true" : "false")
            << ",\"vm_flags_overwrite_used\":false"
            << ",\"posix_map_fixed_used\":false"
            << ",\"passed\":" << (Passed ? "true" : "false")
            << "}\n";
  return Passed ? 0 : 1;
}
