// SPDX-License-Identifier: MIT

#pragma once

// Subconjunto autocontenido de la ABI ELF de System V que necesita la sonda
// Darwin de FEX. macOS no distribuye <elf.h>; mantener estas estructuras en la
// sonda evita instalar cabeceras Linux globales o contaminar el runtime estable.

#include <cstdint>

using Elf32_Addr = uint32_t;
using Elf32_Half = uint16_t;
using Elf32_Off = uint32_t;
using Elf32_Sword = int32_t;
using Elf32_Word = uint32_t;

using Elf64_Addr = uint64_t;
using Elf64_Half = uint16_t;
using Elf64_Off = uint64_t;
using Elf64_Sword = int32_t;
using Elf64_Sxword = int64_t;
using Elf64_Word = uint32_t;
using Elf64_Xword = uint64_t;

constexpr int EI_MAG0 = 0;
constexpr int EI_MAG1 = 1;
constexpr int EI_MAG2 = 2;
constexpr int EI_MAG3 = 3;
constexpr int EI_CLASS = 4;
constexpr int EI_DATA = 5;
constexpr int EI_VERSION = 6;
constexpr int EI_OSABI = 7;
constexpr int EI_ABIVERSION = 8;
constexpr int EI_NIDENT = 16;

constexpr uint8_t ELFMAG0 = 0x7F;
constexpr uint8_t ELFMAG1 = 'E';
constexpr uint8_t ELFMAG2 = 'L';
constexpr uint8_t ELFMAG3 = 'F';
constexpr uint8_t ELFCLASS32 = 1;
constexpr uint8_t ELFCLASS64 = 2;
constexpr uint8_t ELFDATA2LSB = 1;
constexpr uint8_t ELFOSABI_SYSV = 0;
constexpr uint32_t EV_CURRENT = 1;

constexpr uint16_t ET_EXEC = 2;
constexpr uint16_t ET_DYN = 3;
constexpr uint16_t EM_386 = 3;
constexpr uint16_t EM_X86_64 = 62;

constexpr uint32_t PT_NULL = 0;
constexpr uint32_t PT_LOAD = 1;
constexpr uint32_t PT_DYNAMIC = 2;
constexpr uint32_t PT_INTERP = 3;
constexpr uint32_t PT_NOTE = 4;
constexpr uint32_t PT_PHDR = 6;
constexpr uint32_t PT_TLS = 7;

constexpr uint32_t PF_X = 1;
constexpr uint32_t PF_W = 2;
constexpr uint32_t PF_R = 4;

constexpr uint32_t SHT_NULL = 0;
constexpr uint32_t SHT_PROGBITS = 1;
constexpr uint32_t SHT_SYMTAB = 2;
constexpr uint32_t SHT_STRTAB = 3;
constexpr uint32_t SHT_RELA = 4;
constexpr uint32_t SHT_DYNAMIC = 6;
constexpr uint32_t SHT_NOBITS = 8;
constexpr uint32_t SHT_REL = 9;
constexpr uint32_t SHT_DYNSYM = 11;
constexpr uint32_t SHT_INIT_ARRAY = 14;

constexpr uint8_t STV_HIDDEN = 2;

constexpr int64_t DT_NULL = 0;
constexpr int64_t DT_NEEDED = 1;
constexpr int64_t DT_INIT = 12;
constexpr int64_t DT_TEXTREL = 22;
constexpr int64_t DT_FLAGS = 30;

constexpr uint64_t DF_TEXTREL = 0x00000004;

constexpr uint32_t R_386_32 = 1;
constexpr uint32_t R_386_PC32 = 2;
constexpr uint32_t R_386_RELATIVE = 8;
constexpr uint32_t R_386_TLS_TPOFF = 14;

constexpr uint32_t R_X86_64_64 = 1;
constexpr uint32_t R_X86_64_GLOB_DAT = 6;
constexpr uint32_t R_X86_64_JUMP_SLOT = 7;
constexpr uint32_t R_X86_64_RELATIVE = 8;
constexpr uint32_t R_X86_64_32 = 10;
constexpr uint32_t R_X86_64_DTPMOD64 = 16;
constexpr uint32_t R_X86_64_DTPOFF64 = 17;
constexpr uint32_t R_X86_64_TPOFF64 = 18;
constexpr uint32_t R_X86_64_IRELATIVE = 37;

#define ELF32_R_TYPE(value) ((value) & 0xFFU)
#define ELF32_R_SYM(value) ((value) >> 8)
#define ELF64_R_TYPE(value) (static_cast<uint32_t>(value))
#define ELF32_ST_BIND(value) ((value) >> 4)
#define ELF32_ST_TYPE(value) ((value) & 0x0F)
#define ELF32_ST_VISIBILITY(value) ((value) & 0x03)
#define ELF64_ST_BIND(value) ((value) >> 4)
#define ELF64_ST_TYPE(value) ((value) & 0x0F)
#define ELF64_ST_VISIBILITY(value) ((value) & 0x03)

struct Elf32_Ehdr {
  unsigned char e_ident[EI_NIDENT];
  Elf32_Half e_type;
  Elf32_Half e_machine;
  Elf32_Word e_version;
  Elf32_Addr e_entry;
  Elf32_Off e_phoff;
  Elf32_Off e_shoff;
  Elf32_Word e_flags;
  Elf32_Half e_ehsize;
  Elf32_Half e_phentsize;
  Elf32_Half e_phnum;
  Elf32_Half e_shentsize;
  Elf32_Half e_shnum;
  Elf32_Half e_shstrndx;
};

struct Elf64_Ehdr {
  unsigned char e_ident[EI_NIDENT];
  Elf64_Half e_type;
  Elf64_Half e_machine;
  Elf64_Word e_version;
  Elf64_Addr e_entry;
  Elf64_Off e_phoff;
  Elf64_Off e_shoff;
  Elf64_Word e_flags;
  Elf64_Half e_ehsize;
  Elf64_Half e_phentsize;
  Elf64_Half e_phnum;
  Elf64_Half e_shentsize;
  Elf64_Half e_shnum;
  Elf64_Half e_shstrndx;
};

struct Elf32_Phdr {
  Elf32_Word p_type;
  Elf32_Off p_offset;
  Elf32_Addr p_vaddr;
  Elf32_Addr p_paddr;
  Elf32_Word p_filesz;
  Elf32_Word p_memsz;
  Elf32_Word p_flags;
  Elf32_Word p_align;
};

struct Elf64_Phdr {
  Elf64_Word p_type;
  Elf64_Word p_flags;
  Elf64_Off p_offset;
  Elf64_Addr p_vaddr;
  Elf64_Addr p_paddr;
  Elf64_Xword p_filesz;
  Elf64_Xword p_memsz;
  Elf64_Xword p_align;
};

struct Elf32_Shdr {
  Elf32_Word sh_name;
  Elf32_Word sh_type;
  Elf32_Word sh_flags;
  Elf32_Addr sh_addr;
  Elf32_Off sh_offset;
  Elf32_Word sh_size;
  Elf32_Word sh_link;
  Elf32_Word sh_info;
  Elf32_Word sh_addralign;
  Elf32_Word sh_entsize;
};

struct Elf64_Shdr {
  Elf64_Word sh_name;
  Elf64_Word sh_type;
  Elf64_Xword sh_flags;
  Elf64_Addr sh_addr;
  Elf64_Off sh_offset;
  Elf64_Xword sh_size;
  Elf64_Word sh_link;
  Elf64_Word sh_info;
  Elf64_Xword sh_addralign;
  Elf64_Xword sh_entsize;
};

struct Elf32_Sym {
  Elf32_Word st_name;
  Elf32_Addr st_value;
  Elf32_Word st_size;
  unsigned char st_info;
  unsigned char st_other;
  Elf32_Half st_shndx;
};

struct Elf64_Sym {
  Elf64_Word st_name;
  unsigned char st_info;
  unsigned char st_other;
  Elf64_Half st_shndx;
  Elf64_Addr st_value;
  Elf64_Xword st_size;
};

struct Elf32_Dyn {
  Elf32_Sword d_tag;
  union {
    Elf32_Word d_val;
    Elf32_Addr d_ptr;
  } d_un;
};

struct Elf64_Dyn {
  Elf64_Sxword d_tag;
  union {
    Elf64_Xword d_val;
    Elf64_Addr d_ptr;
  } d_un;
};

struct Elf32_Rel {
  Elf32_Addr r_offset;
  Elf32_Word r_info;
};

struct Elf32_Rela {
  Elf32_Addr r_offset;
  Elf32_Word r_info;
  Elf32_Sword r_addend;
};

struct Elf64_Rela {
  Elf64_Addr r_offset;
  Elf64_Xword r_info;
  Elf64_Sxword r_addend;
};

static_assert(sizeof(Elf32_Ehdr) == 52);
static_assert(sizeof(Elf64_Ehdr) == 64);
static_assert(sizeof(Elf32_Phdr) == 32);
static_assert(sizeof(Elf64_Phdr) == 56);
static_assert(sizeof(Elf32_Shdr) == 40);
static_assert(sizeof(Elf64_Shdr) == 64);
static_assert(sizeof(Elf32_Sym) == 16);
static_assert(sizeof(Elf64_Sym) == 24);
static_assert(sizeof(Elf32_Dyn) == 8);
static_assert(sizeof(Elf64_Dyn) == 16);
static_assert(sizeof(Elf32_Rel) == 8);
static_assert(sizeof(Elf32_Rela) == 12);
static_assert(sizeof(Elf64_Rela) == 24);
