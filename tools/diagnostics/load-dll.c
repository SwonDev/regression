#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>

int wmain(int argc, WCHAR **argv)
{
    HMODULE module;
    DWORD error;

    if (argc != 2)
    {
        fwprintf(stderr, L"Uso: load-dll.exe <ruta-dll>\n");
        return 2;
    }

    SetLastError(ERROR_SUCCESS);
    module = LoadLibraryW(argv[1]);
    if (!module)
    {
        error = GetLastError();
        fwprintf(stderr, L"LoadLibraryW(%ls) falló con error %lu (0x%08lx)\n",
                 argv[1], error, error);
        return 1;
    }

    wprintf(L"LoadLibraryW(%ls) cargó %p\n", argv[1], module);
    FreeLibrary(module);
    return 0;
}
