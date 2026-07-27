#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

struct close_request
{
    const WCHAR *title_fragment;
    BOOL posted;
};

static BOOL CALLBACK close_matching_window(HWND hwnd, LPARAM parameter)
{
    struct close_request *request = (struct close_request *)parameter;
    WCHAR title[512];

    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    if (!title[0] || !wcsstr(title, request->title_fragment)) return TRUE;

    request->posted = PostMessageW(hwnd, WM_CLOSE, 0, 0);
    return FALSE;
}

int wmain(int argc, WCHAR **argv)
{
    struct close_request request;

    if (argc != 2) return 2;
    request.title_fragment = argv[1];
    request.posted = FALSE;
    EnumWindows(close_matching_window, (LPARAM)&request);
    return request.posted ? 0 : 1;
}
