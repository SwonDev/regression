/*
 * Isolated macOS probe for the Wine ARM64 16 KiB fallback laboratory.
 *
 * Build the same source with a large and a host-page-sized __PAGEZERO to
 * determine whether KUSER_SHARED_DATA can be mapped at its fixed Windows
 * address without involving Wine, FEX, Steam, or EAC.
 */

#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void)
{
    const mach_vm_address_t requested = 0x7ffe0000;
    const vm_size_t page_size = (vm_size_t)sysconf(_SC_PAGESIZE);
    mach_vm_address_t address = requested;
    kern_return_t result;
    void *mapping;

    printf("host_page_size=%" PRIu64 " requested=0x%" PRIx64 " size=0x%" PRIx64 "\n",
           (uint64_t)page_size, (uint64_t)requested, (uint64_t)page_size);

    result = mach_vm_map(mach_task_self(), &address, page_size, 0, VM_FLAGS_FIXED,
                         MEMORY_OBJECT_NULL, 0, FALSE, VM_PROT_READ,
                         VM_PROT_ALL, VM_INHERIT_COPY);
    printf("mach_vm_map=%d (%s) returned=0x%" PRIx64 "\n",
           result, mach_error_string(result), (uint64_t)address);
    if (result != KERN_SUCCESS) return 10;

    mapping = mmap((void *)(uintptr_t)requested, page_size, PROT_READ,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    printf("mmap=%p errno=%d (%s)\n", mapping, errno, strerror(errno));
    if (mapping == MAP_FAILED) return 11;
    if (mapping != (void *)(uintptr_t)requested) return 12;

    if (munmap(mapping, page_size))
    {
        fprintf(stderr, "munmap failed: %s\n", strerror(errno));
        return 13;
    }
    return 0;
}
