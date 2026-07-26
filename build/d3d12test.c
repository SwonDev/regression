#define INITGUID
#include <initguid.h>
#include <windows.h>
#include <dxgi1_4.h>
#include <d3d12.h>
#include <stdio.h>

int main(void) {
    HRESULT hr;
    IDXGIFactory4 *factory = NULL;
    hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory);
    printf("CreateDXGIFactory1: 0x%08lx factory=%p\n", hr, factory);
    if (FAILED(hr)) return 1;

    for (UINT i = 0; ; i++) {
        IDXGIAdapter1 *adapter = NULL;
        hr = factory->lpVtbl->EnumAdapters1(factory, i, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) { printf("EnumAdapters1(%u): NOT_FOUND\n", i); break; }
        printf("EnumAdapters1(%u): 0x%08lx adapter=%p\n", i, hr, adapter);
        if (FAILED(hr)) break;
        DXGI_ADAPTER_DESC1 desc;
        adapter->lpVtbl->GetDesc1(adapter, &desc);
        wprintf(L"  desc: %s vendor=%04x device=%04x\n", desc.Description, desc.VendorId, desc.DeviceId);

        ID3D12Device *dev = NULL;
        hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
        printf("  D3D12CreateDevice(adapter): 0x%08lx dev=%p\n", hr, dev);
        if (dev) dev->lpVtbl->Release(dev);
        adapter->lpVtbl->Release(adapter);
    }

    /* NULL adapter path */
    ID3D12Device *dev = NULL;
    hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    printf("D3D12CreateDevice(NULL): 0x%08lx dev=%p\n", hr, dev);
    if (dev) dev->lpVtbl->Release(dev);
    factory->lpVtbl->Release(factory);
    printf("DONE\n");
    return 0;
}
