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
    INPUT events[2] = {0};
    unsigned long virtual_key;
    UINT sent;

    if (argc != 2)
    {
        fwprintf(stderr, L"Uso: send-input.exe <código de tecla virtual>\n");
        return 2;
    }

    virtual_key = wcstoul(argv[1], NULL, 0);
    if (virtual_key > 0xff)
    {
        fwprintf(stderr, L"Código de tecla virtual no válido: %lu\n", virtual_key);
        return 2;
    }

    events[0].type = INPUT_KEYBOARD;
    events[0].ki.wVk = (WORD)virtual_key;

    events[1] = events[0];
    events[1].ki.dwFlags = KEYEVENTF_KEYUP;

    sent = SendInput(ARRAYSIZE(events), events, sizeof(INPUT));
    if (sent != ARRAYSIZE(events))
    {
        fwprintf(stderr, L"SendInput envió %u de %u eventos (error %lu)\n",
                 sent, (unsigned)ARRAYSIZE(events), GetLastError());
        return 1;
    }

    return 0;
}
