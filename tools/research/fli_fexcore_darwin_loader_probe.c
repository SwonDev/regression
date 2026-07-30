// SPDX-License-Identifier: MIT
// Native macOS loader probe for the isolated FANTASY LIFE i research path.
//
// This program validates that an arm64 Mach-O FEXCore build can be loaded by
// dyld. It deliberately does not resolve or invoke any FEXCore API and never
// opens, maps, or executes a guest ELF file.

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

static bool process_is_translated(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) != 0) {
        return false;
    }
    return translated == 1;
}

int main(int argument_count, char **arguments) {
#if !defined(__aarch64__)
#error "This diagnostic must be compiled as native arm64."
#endif

    if (argument_count != 2) {
        fprintf(stderr, "Uso: fli-fexcore-darwin-loader-probe RUTA_DYLIB\n");
        return 64;
    }

    struct stat status = {0};
    if (lstat(arguments[1], &status) != 0 || !S_ISREG(status.st_mode) || S_ISLNK(status.st_mode)) {
        fprintf(stderr, "ERROR: la biblioteca debe ser un archivo regular y no simbólico.\n");
        return 66;
    }

    if (process_is_translated()) {
        fprintf(stderr, "ERROR: la sonda no puede ejecutarse mediante Rosetta.\n");
        return 69;
    }

    dlerror();
    void *handle = dlopen(arguments[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (handle == NULL) {
        // Do not expose a potentially sensitive absolute path from dlerror().
        fprintf(stderr, "ERROR: dyld no pudo cargar FEXCore; consulte el recibo de enlace.\n");
        return 70;
    }

    bool closed = dlclose(handle) == 0;
    printf("{\"schema\":1,\"host\":\"macos-arm64\",\"translated\":false,"
           "\"load_mode\":\"rtld-now-local\",\"loaded\":true,"
           "\"api_invoked\":false,\"guest_elf_executed\":false,"
           "\"closed\":%s}\n",
           closed ? "true" : "false");

    return closed ? EXIT_SUCCESS : 71;
}
