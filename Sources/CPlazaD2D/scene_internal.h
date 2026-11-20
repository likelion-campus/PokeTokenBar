// The scene renderer's device and surface records (stage 6 Task 4), shared by scene_device.cpp (device, offscreen frames,
// bitmaps) and window_surface.cpp (Task 5: the window's composition swap chain). INTERNAL: C++ only, not part of the C ABI.
// Main thread only, as everything in CPlazaD2D.h's "scene renderer" section.
#ifndef CPLAZAD2D_SCENE_INTERNAL_H
#define CPLAZAD2D_SCENE_INTERNAL_H

#include <windows.h>
#include <d2d1_1.h>
#include <d3d11.h>
#include <dxgi.h>

#include <cstdint>

namespace ptb {
namespace scene {

template <class T> struct Ref {
    T *p = nullptr;
    Ref() = default;
    Ref(const Ref &) = delete;
    Ref &operator=(const Ref &) = delete;
    ~Ref() { reset(); }
    void reset() {
        if (p) p->Release();
        p = nullptr;
    }
    T **out() {
        reset();
        return &p;
    }
    T *operator->() const { return p; }
};

struct Pending {
    uint32_t handle, generation;
};

struct Device {
    uint32_t generation = 0;
    int isWarp = 0;
    bool lost = false;
    int injectLoss = 0;
    int injectPresentLoss = 0;  // Task 5: the next window present reports DXGI_ERROR_DEVICE_REMOVED
    uint32_t options = 0;
    uint32_t uploads = 0, losses = 0, frames = 0;
    Ref<ID2D1Factory1> factory;  // device-independent: kept across rebuilds
    Ref<ID3D11Device> d3d;
    Ref<ID3D11DeviceContext> d3dContext;
    Ref<ID3D11Query> idleQuery;
    Ref<ID2D1Device> d2d;
    Ref<ID2D1DeviceContext> ctx;
    Ref<ID2D1SolidColorBrush> brush;
    Ref<ID2D1Effect> tint, dst, arith;
    Ref<ID2D1Image> tintOut, dstOut, arithOut;
    // Bitmap table: handle = slot + 1. A free slot holds nullptr.
    ID2D1Bitmap1 **slots = nullptr;
    uint64_t *slotBytes = nullptr;
    uint32_t slotCount = 0, slotCap = 0;
    uint32_t live = 0;
    uint64_t liveBytes = 0;
    // Releases asked for by any thread, done on the main thread at the next call.
    SRWLOCK lock = SRWLOCK_INIT;
    Pending *pending = nullptr;
    uint32_t pendingCount = 0, pendingCap = 0;
};

struct WindowParts;  // window_surface.cpp

struct Surface {
    Device *device = nullptr;
    uint32_t w = 0, h = 0;
    uint32_t generation = 0;  // of the resources below; 0 = not made
    Ref<ID2D1Bitmap1> frame, scratchA, scratchB, readback;
    WindowParts *window = nullptr;  // a window surface's swap chain and composition objects (Task 5); null offscreen
};

// scene_device.cpp: the frame and scratch bitmaps for the device's current generation (made again after a resize or a
// rebuild), and the loss bookkeeping a failed call does.
HRESULT ensureFrameBitmaps(Surface *s);
void noteDeviceLoss(Device *d, HRESULT hr);
// window_surface.cpp: releases a window surface's swap chain, composition objects and waitable handle.
void releaseWindowParts(WindowParts *w);

}  // namespace scene
}  // namespace ptb

#endif
