// SPDX-License-Identifier: MIT
// Native macOS feasibility probe for the isolated FANTASY LIFE i research path.
//
// This program never executes the supplied ELF file. It validates only the
// public ELF header and program-header layout, then proves that an arm64 Mach-O
// helper can use Apple's supported JIT write-protection API.

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

enum {
    ELF_IDENT_SIZE = 16,
    ELF_CLASS_64 = 2,
    ELF_DATA_LITTLE_ENDIAN = 1,
    ELF_VERSION_CURRENT = 1,
    ELF_OSABI_SYSV = 0,
    ELF_TYPE_RELOCATABLE = 1,
    ELF_TYPE_EXECUTABLE = 2,
    ELF_TYPE_SHARED_OBJECT = 3,
    ELF_MACHINE_X86_64 = 62,
    ELF_PROGRAM_LOAD = 1,
    ELF_PROGRAM_DYNAMIC = 2,
    ELF_PROGRAM_INTERPRETER = 3,
    ELF_PROGRAM_GNU_STACK = 0x6474e551,
};

typedef struct __attribute__((packed)) {
    unsigned char ident[ELF_IDENT_SIZE];
    uint16_t type;
    uint16_t machine;
    uint32_t version;
    uint64_t entry;
    uint64_t program_header_offset;
    uint64_t section_header_offset;
    uint32_t flags;
    uint16_t header_size;
    uint16_t program_header_entry_size;
    uint16_t program_header_count;
    uint16_t section_header_entry_size;
    uint16_t section_header_count;
    uint16_t section_name_index;
} Elf64Header;

typedef struct __attribute__((packed)) {
    uint32_t type;
    uint32_t flags;
    uint64_t offset;
    uint64_t virtual_address;
    uint64_t physical_address;
    uint64_t file_size;
    uint64_t memory_size;
    uint64_t alignment;
} Elf64ProgramHeader;

typedef struct {
    bool valid;
    uint16_t type;
    uint16_t program_header_count;
    uint16_t load_segment_count;
    bool has_dynamic_segment;
    bool has_interpreter;
    bool has_gnu_stack;
    uint64_t file_size;
} ElfSummary;

static bool range_is_inside_file(uint64_t offset, uint64_t size, uint64_t file_size) {
    return offset <= file_size && size <= file_size - offset;
}

static bool read_exact_at(int file_descriptor, void *buffer, size_t size, off_t offset) {
    unsigned char *cursor = buffer;
    size_t remaining = size;

    while (remaining > 0) {
        ssize_t count = pread(file_descriptor, cursor, remaining, offset);
        if (count == 0) {
            return false;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
        offset += count;
    }
    return true;
}

static const char *elf_type_name(uint16_t type) {
    switch (type) {
        case ELF_TYPE_RELOCATABLE:
            return "relocatable";
        case ELF_TYPE_EXECUTABLE:
            return "executable";
        case ELF_TYPE_SHARED_OBJECT:
            return "shared-object";
        default:
            return "unsupported";
    }
}

static bool inspect_elf(const char *path, ElfSummary *summary, char *error, size_t error_size) {
    memset(summary, 0, sizeof(*summary));

    int file_descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file_descriptor < 0) {
        snprintf(error, error_size, "open:%d", errno);
        return false;
    }

    struct stat status = {0};
    if (fstat(file_descriptor, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < (off_t)sizeof(Elf64Header)) {
        snprintf(error, error_size, "not-regular-elf");
        close(file_descriptor);
        return false;
    }
    summary->file_size = (uint64_t)status.st_size;

    Elf64Header header = {0};
    if (!read_exact_at(file_descriptor, &header, sizeof(header), 0)) {
        snprintf(error, error_size, "read-header");
        close(file_descriptor);
        return false;
    }

    const unsigned char expected_magic[4] = {0x7f, 'E', 'L', 'F'};
    if (memcmp(header.ident, expected_magic, sizeof(expected_magic)) != 0 ||
        header.ident[4] != ELF_CLASS_64 ||
        header.ident[5] != ELF_DATA_LITTLE_ENDIAN ||
        header.ident[6] != ELF_VERSION_CURRENT ||
        (header.ident[7] != ELF_OSABI_SYSV && header.ident[7] != 3) ||
        header.version != ELF_VERSION_CURRENT ||
        header.machine != ELF_MACHINE_X86_64 ||
        header.header_size != sizeof(Elf64Header) ||
        (header.type != ELF_TYPE_RELOCATABLE &&
         header.type != ELF_TYPE_EXECUTABLE &&
         header.type != ELF_TYPE_SHARED_OBJECT)) {
        snprintf(error, error_size, "unsupported-elf64-x86-64");
        close(file_descriptor);
        return false;
    }

    summary->type = header.type;
    summary->program_header_count = header.program_header_count;

    if (header.program_header_count > 0) {
        if (header.program_header_entry_size != sizeof(Elf64ProgramHeader)) {
            snprintf(error, error_size, "program-header-size");
            close(file_descriptor);
            return false;
        }

        uint64_t table_size = (uint64_t)header.program_header_entry_size * header.program_header_count;
        if (!range_is_inside_file(header.program_header_offset, table_size, summary->file_size)) {
            snprintf(error, error_size, "program-header-range");
            close(file_descriptor);
            return false;
        }

        for (uint16_t index = 0; index < header.program_header_count; ++index) {
            Elf64ProgramHeader program_header = {0};
            off_t offset = (off_t)(header.program_header_offset +
                                   (uint64_t)index * header.program_header_entry_size);
            if (!read_exact_at(file_descriptor, &program_header, sizeof(program_header), offset)) {
                snprintf(error, error_size, "read-program-header");
                close(file_descriptor);
                return false;
            }
            if (!range_is_inside_file(program_header.offset, program_header.file_size, summary->file_size) ||
                program_header.memory_size < program_header.file_size) {
                snprintf(error, error_size, "segment-range");
                close(file_descriptor);
                return false;
            }

            switch (program_header.type) {
                case ELF_PROGRAM_LOAD:
                    summary->load_segment_count += 1;
                    break;
                case ELF_PROGRAM_DYNAMIC:
                    summary->has_dynamic_segment = true;
                    break;
                case ELF_PROGRAM_INTERPRETER:
                    summary->has_interpreter = true;
                    break;
                case ELF_PROGRAM_GNU_STACK:
                    summary->has_gnu_stack = true;
                    break;
                default:
                    break;
            }
        }

        if (header.type != ELF_TYPE_RELOCATABLE && summary->load_segment_count == 0) {
            snprintf(error, error_size, "missing-load-segment");
            close(file_descriptor);
            return false;
        }
    }

    summary->valid = true;
    close(file_descriptor);
    return true;
}

static bool process_is_translated(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) != 0) {
        return false;
    }
    return translated == 1;
}

static bool run_arm64_jit(uint32_t *result, char *error, size_t error_size) {
#if !defined(__aarch64__)
    snprintf(error, error_size, "host-not-arm64");
    return false;
#else
    const size_t page_size = (size_t)getpagesize();
    void *mapping = mmap(NULL,
                         page_size,
                         PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT,
                         -1,
                         0);
    if (mapping == MAP_FAILED) {
        snprintf(error, error_size, "map-jit:%d", errno);
        return false;
    }

    const uint32_t instructions[] = {
        0x52800540U, // mov w0, #42
        0xd65f03c0U, // ret
    };

    pthread_jit_write_protect_np(0);
    memcpy(mapping, instructions, sizeof(instructions));
    __builtin___clear_cache(mapping, (char *)mapping + sizeof(instructions));
    pthread_jit_write_protect_np(1);

    uint32_t (*function)(void) = NULL;
    memcpy(&function, &mapping, sizeof(function));
    *result = function();
    munmap(mapping, page_size);

    if (*result != 42U) {
        snprintf(error, error_size, "jit-result:%" PRIu32, *result);
        return false;
    }
    return true;
#endif
}

static void print_usage(const char *program) {
    fprintf(stderr, "Uso: %s [--elf RUTA]\n", program);
}

int main(int argc, char **argv) {
    const char *elf_path = NULL;
    if (argc == 3 && strcmp(argv[1], "--elf") == 0) {
        elf_path = argv[2];
    } else if (argc != 1) {
        print_usage(argv[0]);
        return 64;
    }

    char jit_error[64] = "none";
    uint32_t jit_result = 0;
    const bool jit_passed = run_arm64_jit(&jit_result, jit_error, sizeof(jit_error));
    const bool translated = process_is_translated();

    ElfSummary elf = {0};
    char elf_error[64] = "not-requested";
    bool elf_passed = true;
    if (elf_path != NULL) {
        elf_passed = inspect_elf(elf_path, &elf, elf_error, sizeof(elf_error));
        if (elf_passed) {
            snprintf(elf_error, sizeof(elf_error), "none");
        }
    }

    printf("{\"schema_version\":1,");
    printf("\"host\":{\"format\":\"mach-o\",\"architecture\":\"%s\",\"translated\":%s},",
#if defined(__aarch64__)
           "arm64",
#else
           "unsupported",
#endif
           translated ? "true" : "false");
    printf("\"jit\":{\"api\":\"map-jit+pthreads\",\"passed\":%s,\"result\":%" PRIu32 ",\"error\":\"%s\"},",
           jit_passed ? "true" : "false",
           jit_result,
           jit_error);
    printf("\"elf\":{\"requested\":%s,\"passed\":%s,\"class\":\"elf64\",\"machine\":\"x86_64\",",
           elf_path != NULL ? "true" : "false",
           elf_passed ? "true" : "false");
    printf("\"type\":\"%s\",\"file_size\":%" PRIu64 ",\"program_headers\":%u,\"load_segments\":%u,",
           elf.valid ? elf_type_name(elf.type) : "unknown",
           elf.file_size,
           elf.program_header_count,
           elf.load_segment_count);
    printf("\"dynamic\":%s,\"interpreter\":%s,\"gnu_stack\":%s,\"error\":\"%s\"},",
           elf.has_dynamic_segment ? "true" : "false",
           elf.has_interpreter ? "true" : "false",
           elf.has_gnu_stack ? "true" : "false",
           elf_error);
    printf("\"passed\":%s}\n", (jit_passed && !translated && elf_passed) ? "true" : "false");

    return (jit_passed && !translated && elf_passed) ? 0 : 1;
}
