#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int wmain(int argc, wchar_t **argv)
{
    DEVMODEW mode = {0};
    LONG result;

    if (argc != 4)
    {
        fwprintf(stderr, L"Uso: set-display-mode.exe <ancho> <alto> <Hz>\n");
        return 2;
    }

    mode.dmSize = sizeof(mode);
    mode.dmPelsWidth = wcstoul(argv[1], NULL, 10);
    mode.dmPelsHeight = wcstoul(argv[2], NULL, 10);
    mode.dmDisplayFrequency = wcstoul(argv[3], NULL, 10);
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;

    result = ChangeDisplaySettingsExW(NULL, &mode, NULL, CDS_FULLSCREEN, NULL);
    wprintf(L"ChangeDisplaySettingsExW(%lu x %lu @ %lu) = %ld\n",
            mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency, result);
    return result == DISP_CHANGE_SUCCESSFUL ? 0 : 1;
}
