#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK probe_window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message) {
    case WM_CLOSE:
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

static void write_result(const char *line)
{
    FILE *result = fopen("d3d11-present-probe.log", "a");
    if (result != NULL) {
        fprintf(result, "%s\n", line);
        fclose(result);
    }
    puts(line);
    fflush(stdout);
}

int main(void)
{
    const wchar_t *class_name = L"RegressionD3D11PresentProbe";
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSEXW window_class = {0};
    HWND window = NULL;
    DXGI_SWAP_CHAIN_DESC swap_desc = {0};
    IDXGISwapChain *swap_chain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Texture2D *back_buffer = NULL;
    ID3D11RenderTargetView *render_target = NULL;
    D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_9_1;
    const D3D_FEATURE_LEVEL requested_levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0
    };
    HRESULT status;
    MSG message;
    unsigned int frame = 0;
    int exit_code = 1;

    DeleteFileA("d3d11-present-probe.log");

    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.lpfnWndProc = probe_window_proc;
    window_class.hInstance = instance;
    window_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
    window_class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    window_class.lpszClassName = class_name;

    if (RegisterClassExW(&window_class) == 0) {
        write_result("D3D11_PROBE_REGISTER_CLASS_FAILED");
        return 2;
    }

    window = CreateWindowExW(
        0,
        class_name,
        L"Regression — D3D11 presentation probe",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        960,
        600,
        NULL,
        NULL,
        instance,
        NULL
    );
    if (window == NULL) {
        write_result("D3D11_PROBE_CREATE_WINDOW_FAILED");
        goto cleanup;
    }

    swap_desc.BufferDesc.Width = 960;
    swap_desc.BufferDesc.Height = 600;
    swap_desc.BufferDesc.RefreshRate.Numerator = 60;
    swap_desc.BufferDesc.RefreshRate.Denominator = 1;
    swap_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = 2;
    swap_desc.OutputWindow = window;
    swap_desc.Windowed = TRUE;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    status = D3D11CreateDeviceAndSwapChain(
        NULL,
        D3D_DRIVER_TYPE_HARDWARE,
        NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        requested_levels,
        ARRAYSIZE(requested_levels),
        D3D11_SDK_VERSION,
        &swap_desc,
        &swap_chain,
        &device,
        &feature_level,
        &context
    );
    if (FAILED(status)) {
        char failure[96];
        snprintf(failure, sizeof(failure), "D3D11_PROBE_CREATE_DEVICE_FAILED hr=0x%08lx", (unsigned long)status);
        write_result(failure);
        goto cleanup;
    }

    status = IDXGISwapChain_GetBuffer(swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
    if (FAILED(status)) {
        write_result("D3D11_PROBE_GET_BACK_BUFFER_FAILED");
        goto cleanup;
    }

    status = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back_buffer, NULL, &render_target);
    if (FAILED(status)) {
        write_result("D3D11_PROBE_CREATE_RENDER_TARGET_FAILED");
        goto cleanup;
    }

    ShowWindow(window, SW_SHOW);
    UpdateWindow(window);
    write_result("D3D11_PROBE_DEVICE_CREATED");

    while (frame < 1800 && IsWindow(window)) {
        float phase = (float)(frame % 360) / 360.0f;
        const float color[4] = {
            0.08f + 0.40f * phase,
            0.20f + 0.45f * (1.0f - phase),
            0.72f,
            1.0f
        };

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                goto cleanup;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &render_target, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(context, render_target, color);
        status = IDXGISwapChain_Present(swap_chain, 0, 0);
        if (FAILED(status)) {
            char failure[96];
            snprintf(failure, sizeof(failure), "D3D11_PROBE_PRESENT_FAILED hr=0x%08lx", (unsigned long)status);
            write_result(failure);
            goto cleanup;
        }

        ++frame;
        if (frame == 120) {
            write_result("D3D11_PROBE_PRESENTED_120_FRAMES");
        }
        Sleep(16);
    }

    if (frame == 1800) {
        write_result("D3D11_PROBE_PRESENTED_1800_FRAMES");
        exit_code = 0;
    }

cleanup:
    if (context != NULL) {
        ID3D11DeviceContext_ClearState(context);
    }
    if (render_target != NULL) {
        ID3D11RenderTargetView_Release(render_target);
    }
    if (back_buffer != NULL) {
        ID3D11Texture2D_Release(back_buffer);
    }
    if (context != NULL) {
        ID3D11DeviceContext_Release(context);
    }
    if (device != NULL) {
        ID3D11Device_Release(device);
    }
    if (swap_chain != NULL) {
        IDXGISwapChain_Release(swap_chain);
    }
    if (window != NULL && IsWindow(window)) {
        DestroyWindow(window);
    }
    UnregisterClassW(class_name, instance);
    return exit_code;
}
