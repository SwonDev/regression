#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>

static BOOL CALLBACK print_window(HWND hwnd, LPARAM context)
{
    WCHAR title[512];
    WCHAR class_name[256];
    RECT window_rect;
    RECT client_rect;
    POINT client_origin = {0, 0};
    DWORD process_id = 0;
    MONITORINFO monitor = {.cbSize = sizeof(monitor)};
    HMONITOR monitor_handle;

    (void)context;
    if (!IsWindowVisible(hwnd)) return TRUE;

    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    GetClassNameW(hwnd, class_name, ARRAYSIZE(class_name));
    GetWindowThreadProcessId(hwnd, &process_id);
    GetWindowRect(hwnd, &window_rect);
    GetClientRect(hwnd, &client_rect);
    ClientToScreen(hwnd, &client_origin);
    monitor_handle = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(monitor_handle, &monitor);

    wprintf(
        L"hwnd=%p pid=%lu title=\"%ls\" class=\"%ls\" "
        L"window=%ld,%ld %ldx%ld client=%ld,%ld %ldx%ld "
        L"monitor=%ld,%ld %ldx%ld dpi=%u\n",
        hwnd,
        process_id,
        title,
        class_name,
        window_rect.left,
        window_rect.top,
        window_rect.right - window_rect.left,
        window_rect.bottom - window_rect.top,
        client_origin.x,
        client_origin.y,
        client_rect.right - client_rect.left,
        client_rect.bottom - client_rect.top,
        monitor.rcMonitor.left,
        monitor.rcMonitor.top,
        monitor.rcMonitor.right - monitor.rcMonitor.left,
        monitor.rcMonitor.bottom - monitor.rcMonitor.top,
        GetDpiForWindow(hwnd)
    );
    return TRUE;
}

int wmain(void)
{
    DEVMODEW mode = {.dmSize = sizeof(mode)};

    if (EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &mode))
    {
        wprintf(
            L"display=%lux%lu@%lu bpp=%lu position=%ld,%ld "
            L"system=%dx%d virtual=%d,%d %dx%d\n",
            mode.dmPelsWidth,
            mode.dmPelsHeight,
            mode.dmDisplayFrequency,
            mode.dmBitsPerPel,
            mode.dmPosition.x,
            mode.dmPosition.y,
            GetSystemMetrics(SM_CXSCREEN),
            GetSystemMetrics(SM_CYSCREEN),
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN)
        );
    }

    EnumWindows(print_window, 0);
    return 0;
}
