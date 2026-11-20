// The plaza window's surface (stage 6 Task 5, D1): the renderer's frame bitmap presented through a DirectComposition swap
// chain. Main thread only. See CPlazaD2D.h ("the plaza window").
//
// Chain: the device's D3D11 device -> IDXGIFactory2::CreateSwapChainForComposition (flip sequential, 2 buffers,
// B8G8R8A8, premultiplied alpha, frame-latency waitable, maximum latency 1) -> DCompositionCreateDevice ->
// CreateTargetForHwnd(hwnd, topmost FALSE) -> one visual whose content is the swap chain. The window has
// WS_EX_NOREDIRECTIONBITMAP, so the composition is the only thing in its client area (a transparent clear shows the desktop).
// A frame: the renderer draws the frame bitmap (ptb_gfx_frame), then present copies it into the back buffer and calls
// Present(1, 0). Commit happens once per swap chain, never per frame.
#include "CPlazaD2D.h"
#include "internal.h"
#include "scene_internal.h"

#include <windows.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_3.h>

#include <cstring>
#include <new>

namespace {

using namespace ptb;
using namespace ptb::scene;

const GUID kIidDXGIDevice = {0x54ec77fa, 0x1377, 0x44e6, {0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c}};
const GUID kIidDXGIFactory2 = {0x50c83a1c, 0xe072, 0x4c48, {0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0}};
const GUID kIidDXGISwapChain2 = {0xa8be2ac4, 0x199f, 0x4946, {0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7}};
const GUID kIidDXGISurface = {0xcafcb56c, 0x6ac3, 0x4889, {0xbf, 0x47, 0x9e, 0x23, 0xbb, 0xd2, 0x60, 0xec}};
const GUID kIidDCompositionDevice = {0xc37ea93a, 0xe7aa, 0x450d, {0xb1, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3}};

const HRESULT kDeviceRemoved = static_cast<HRESULT>(0x887A0005L);  // DXGI_ERROR_DEVICE_REMOVED
const HRESULT kDeviceHung = static_cast<HRESULT>(0x887A0006L);     // DXGI_ERROR_DEVICE_HUNG
const HRESULT kDeviceReset = static_cast<HRESULT>(0x887A0007L);    // DXGI_ERROR_DEVICE_RESET
const HRESULT kRecreateTarget = static_cast<HRESULT>(0x8899000CL); // D2DERR_RECREATE_TARGET
const HRESULT kOccluded = static_cast<HRESULT>(0x087A0001L);       // DXGI_STATUS_OCCLUDED (success)
const UINT kFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

bool isLoss(HRESULT hr) { return hr == kDeviceRemoved || hr == kDeviceHung || hr == kDeviceReset || hr == kRecreateTarget; }

}  // namespace

namespace ptb {
namespace scene {

struct WindowParts {
    HWND hwnd = nullptr;
    uint32_t generation = 0;  // the device generation the swap chain belongs to; 0 = none
    Ref<IDXGISwapChain1> swapChain;
    Ref<IDCompositionDevice> dcomp;
    Ref<IDCompositionTarget> target;
    Ref<IDCompositionVisual> visual;
    Ref<ID2D1Bitmap1> backBuffer;  // buffer 0 as a Direct2D target (D3D11 rotates flip-model buffers behind it)
    HANDLE waitable = nullptr;
    bool tokenHeld = false;        // the waitable was signalled and no present has used it yet
    uint32_t presents = 0, occluded = 0, acquireMisses = 0, swapChainsMade = 0, resizes = 0, failures = 0;
};

void releaseWindowParts(WindowParts *w) {
    if (!w) return;
    w->backBuffer.reset();
    w->visual.reset();
    w->target.reset();
    w->dcomp.reset();
    w->swapChain.reset();
    if (w->waitable) CloseHandle(w->waitable);
    w->waitable = nullptr;
    delete w;
}

}  // namespace scene
}  // namespace ptb

namespace {

void dropSwapChain(WindowParts *w) {
    w->backBuffer.reset();
    w->visual.reset();
    w->target.reset();  // before a new CreateTargetForHwnd: one target per window
    w->dcomp.reset();
    w->swapChain.reset();
    if (w->waitable) CloseHandle(w->waitable);
    w->waitable = nullptr;
    w->tokenHeld = false;
    w->generation = 0;
}

HRESULT makeBackBuffer(Device *d, WindowParts *w) {
    w->backBuffer.reset();
    Ref<IDXGISurface> buffer;
    HRESULT hr = w->swapChain->GetBuffer(0, kIidDXGISurface, reinterpret_cast<void **>(buffer.out()));
    if (FAILED(hr)) return fail("IDXGISwapChain1::GetBuffer", hr);
    D2D1_BITMAP_PROPERTIES1 p;
    std::memset(&p, 0, sizeof(p));
    p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
    p.dpiX = 96.0f;
    p.dpiY = 96.0f;
    p.bitmapOptions = static_cast<D2D1_BITMAP_OPTIONS>(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
    hr = d->ctx->CreateBitmapFromDxgiSurface(buffer.p, &p, w->backBuffer.out());
    if (FAILED(hr)) return fail("CreateBitmapFromDxgiSurface(back buffer)", hr);
    return S_OK;
}

// The swap chain, its composition and its back-buffer target for the device's current generation.
HRESULT ensureSwapChain(Surface *s) {
    Device *d = s->device;
    WindowParts *w = s->window;
    if (w->generation == d->generation && w->swapChain.p && w->backBuffer.p) return S_OK;
    dropSwapChain(w);
    Ref<IDXGIDevice> dxgi;
    HRESULT hr = d->d3d->QueryInterface(kIidDXGIDevice, reinterpret_cast<void **>(dxgi.out()));
    if (FAILED(hr)) return fail("IDXGIDevice", hr);
    Ref<IDXGIAdapter> adapter;
    hr = dxgi->GetAdapter(adapter.out());
    if (FAILED(hr)) return fail("IDXGIDevice::GetAdapter", hr);
    Ref<IDXGIFactory2> factory;
    hr = adapter->GetParent(kIidDXGIFactory2, reinterpret_cast<void **>(factory.out()));
    if (FAILED(hr)) return fail("IDXGIFactory2", hr);
    DXGI_SWAP_CHAIN_DESC1 desc;
    std::memset(&desc, 0, sizeof(desc));
    desc.Width = s->w;
    desc.Height = s->h;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    desc.Flags = kFlags;
    hr = factory->CreateSwapChainForComposition(d->d3d.p, &desc, nullptr, w->swapChain.out());
    if (FAILED(hr)) return fail("CreateSwapChainForComposition", hr);
    Ref<IDXGISwapChain2> chain2;
    hr = w->swapChain->QueryInterface(kIidDXGISwapChain2, reinterpret_cast<void **>(chain2.out()));
    if (FAILED(hr)) return fail("IDXGISwapChain2", hr);
    hr = chain2->SetMaximumFrameLatency(1);
    if (FAILED(hr)) return fail("SetMaximumFrameLatency", hr);
    w->waitable = chain2->GetFrameLatencyWaitableObject();
    if (!w->waitable) return fail("GetFrameLatencyWaitableObject", E_FAIL);
    hr = DCompositionCreateDevice(dxgi.p, kIidDCompositionDevice, reinterpret_cast<void **>(w->dcomp.out()));
    if (FAILED(hr)) return fail("DCompositionCreateDevice", hr);
    hr = w->dcomp->CreateTargetForHwnd(w->hwnd, FALSE, w->target.out());
    if (FAILED(hr)) return fail("IDCompositionDevice::CreateTargetForHwnd", hr);
    hr = w->dcomp->CreateVisual(w->visual.out());
    if (FAILED(hr)) return fail("IDCompositionDevice::CreateVisual", hr);
    hr = w->visual->SetContent(w->swapChain.p);
    if (SUCCEEDED(hr)) hr = w->target->SetRoot(w->visual.p);
    if (SUCCEEDED(hr)) hr = w->dcomp->Commit();
    if (FAILED(hr)) return fail("DirectComposition visual / commit", hr);
    hr = makeBackBuffer(d, w);
    if (FAILED(hr)) return hr;
    w->generation = d->generation;
    w->swapChainsMade++;
    return S_OK;
}

}  // namespace

extern "C" PTBGfxSurface *ptb_gfx_surface_window(PTBGfxDevice *device, void *hwnd, uint32_t w, uint32_t h) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || !hwnd || w == 0 || h == 0 || w > 16384 || h > 16384) {
        fail("ptb_gfx_surface_window", E_INVALIDARG);
        return nullptr;
    }
    HRESULT hr = S_OK;
    if (!LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
        fail("dcomp.dll not loadable", HRESULT_FROM_WIN32(GetLastError()));
        return nullptr;
    }
    Surface *s = new (std::nothrow) Surface();
    WindowParts *parts = new (std::nothrow) WindowParts();
    if (!s || !parts) {
        delete s;
        delete parts;
        fail("ptb_gfx_surface_window", E_OUTOFMEMORY);
        return nullptr;
    }
    s->device = d;
    s->w = w;
    s->h = h;
    s->window = parts;
    parts->hwnd = static_cast<HWND>(hwnd);
    if (!d->lost) {
        hr = ensureFrameBitmaps(s);
        if (SUCCEEDED(hr)) hr = ensureSwapChain(s);
        if (FAILED(hr)) {  // the error text is set
            releaseWindowParts(parts);
            s->window = nullptr;
            delete s;
            return nullptr;
        }
    }
    return reinterpret_cast<PTBGfxSurface *>(s);
}

extern "C" int ptb_gfx_window_resize(PTBGfxSurface *surface, uint32_t w, uint32_t h) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || !s->window || w == 0 || h == 0 || w > 16384 || h > 16384) return fail("ptb_gfx_window_resize", E_INVALIDARG);
    if (s->w == w && s->h == h) return 0;
    s->w = w;
    s->h = h;
    s->generation = 0;  // frame and scratch bitmaps are made again on the next frame
    s->frame.reset();
    s->scratchA.reset();
    s->scratchB.reset();
    s->readback.reset();
    WindowParts *win = s->window;
    win->resizes++;
    Device *d = s->device;
    if (!win->swapChain.p || win->generation != d->generation || d->lost) return 0;  // made at the next present
    win->backBuffer.reset();  // ResizeBuffers needs every reference to the buffers gone (the context's target is null)
    HRESULT hr = win->swapChain->ResizeBuffers(2, w, h, DXGI_FORMAT_UNKNOWN, kFlags);
    if (FAILED(hr)) {
        win->failures++;
        if (isLoss(hr)) noteDeviceLoss(d, hr);
        dropSwapChain(win);
        return fail("ResizeBuffers", hr);
    }
    hr = makeBackBuffer(d, win);
    if (FAILED(hr)) {
        dropSwapChain(win);
        return static_cast<int>(hr);
    }
    return 0;
}

extern "C" int ptb_gfx_window_acquire(PTBGfxSurface *surface, uint32_t waitMs) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || !s->window) return 0;
    WindowParts *w = s->window;
    if (s->device->lost) return 1;  // the frame call reports the loss and the device is rebuilt
    if (w->generation != s->device->generation || !w->waitable) return 1;  // made again at the present
    if (w->tokenHeld) return 1;
    if (WaitForSingleObjectEx(w->waitable, waitMs, FALSE) == WAIT_OBJECT_0) {
        w->tokenHeld = true;
        return 1;
    }
    w->acquireMisses++;
    return 0;
}

extern "C" int ptb_gfx_window_present(PTBGfxSurface *surface) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || !s->window) return fail("ptb_gfx_window_present", E_INVALIDARG);
    Device *d = s->device;
    WindowParts *w = s->window;
    if (d->lost) return fail("ptb_gfx_window_present: device lost", kRecreateTarget);
    if (!s->frame.p || s->generation != d->generation) return fail("ptb_gfx_window_present: nothing drawn", E_FAIL);
    HRESULT hr = ensureSwapChain(s);
    if (FAILED(hr)) {
        w->failures++;
        if (isLoss(hr)) noteDeviceLoss(d, hr);
        return static_cast<int>(hr);
    }
    if (d->injectPresentLoss) {
        d->injectPresentLoss = 0;
        w->failures++;
        noteDeviceLoss(d, kDeviceRemoved);
        return fail("Present (injected)", kDeviceRemoved);
    }
    ID2D1DeviceContext *c = d->ctx.p;
    c->SetTarget(w->backBuffer.p);
    c->BeginDraw();
    const D2D1_MATRIX_3X2_F identity = {1, 0, 0, 1, 0, 0};
    c->SetTransform(&identity);
    const D2D1_POINT_2F origin = {0, 0};
    const D2D1_RECT_F all = {0, 0, static_cast<float>(s->w), static_cast<float>(s->h)};
    c->DrawImage(s->frame.p, &origin, &all, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, D2D1_COMPOSITE_MODE_SOURCE_COPY);
    hr = c->EndDraw();
    c->SetTarget(nullptr);
    if (FAILED(hr)) {
        w->failures++;
        if (isLoss(hr)) noteDeviceLoss(d, hr);
        return fail("present: EndDraw (back buffer)", hr);
    }
    hr = w->swapChain->Present(1, 0);
    w->tokenHeld = false;
    if (FAILED(hr)) {
        w->failures++;
        if (isLoss(hr)) noteDeviceLoss(d, hr);
        return fail("Present", hr);
    }
    w->presents++;
    if (hr == kOccluded) w->occluded++;
    return static_cast<int>(hr);
}

extern "C" void ptb_gfx_window_stats(PTBGfxSurface *surface, PTBGfxWindowStats *out) {
    const Surface *s = reinterpret_cast<const Surface *>(surface);
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!s || !s->window) return;
    const WindowParts *w = s->window;
    out->presents = w->presents;
    out->occluded = w->occluded;
    out->acquireMisses = w->acquireMisses;
    out->swapChainsMade = w->swapChainsMade;
    out->resizes = w->resizes;
    out->failures = w->failures;
    out->width = s->w;
    out->height = s->h;
    if (w->swapChain.p) {
        DXGI_SWAP_CHAIN_DESC1 desc;
        if (SUCCEEDED(w->swapChain->GetDesc1(&desc))) {
            out->bufferWidth = desc.Width;
            out->bufferHeight = desc.Height;
        }
    }
}
