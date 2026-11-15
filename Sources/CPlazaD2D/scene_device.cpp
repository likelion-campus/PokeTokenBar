// The scene renderer's device side (stage 6 Task 4): a Direct2D 1.1 device context over Direct3D 11, offscreen frame
// bitmaps, the bitmap table and the frame loop. See CPlazaD2D.h ("scene renderer") for the rules. Main thread only, except
// ptb_gfx_bitmap_release. Nothing here throws: tables are malloc'ed arrays, the release queue is guarded by an SRW lock.
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <d3d11.h>
#include <dxgi.h>
#ifndef PSAPI_VERSION
#define PSAPI_VERSION 2  // K32GetProcessMemoryInfo from kernel32 (no psapi.lib)
#endif
#include <psapi.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <new>

namespace {

using namespace ptb;

// Spelled out (not DEFINE_GUID / __uuidof), as codec.cpp and probe.cpp do.
const GUID kIidD2D1Factory1 = {0xbb12d362, 0xdaee, 0x4b9a, {0xaa, 0x1d, 0x14, 0xba, 0x40, 0x1c, 0xfa, 0x1f}};
const GUID kIidDXGIDevice = {0x54ec77fa, 0x1377, 0x44e6, {0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c}};
const GUID kClsidColorMatrix = {0x921f03d6, 0x641c, 0x47df, {0x85, 0x2d, 0xb4, 0xbb, 0x61, 0x53, 0xae, 0x11}};
const GUID kClsidArithmeticComposite = {0xfc151437, 0x049a, 0x4784, {0xa2, 0x4a, 0xf1, 0xc4, 0xda, 0xf2, 0x09, 0x87}};

const HRESULT kRecreateTarget = static_cast<HRESULT>(0x8899000CL);  // D2DERR_RECREATE_TARGET

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
    uint32_t options = 0;
    uint32_t uploads = 0, losses = 0, frames = 0;
    Ref<ID2D1Factory1> factory;  // device-independent: kept across rebuilds
    Ref<ID3D11Device> d3d;
    Ref<ID3D11DeviceContext> d3dContext;
    Ref<ID3D11Query> idleQuery;
    Ref<ID2D1Device> d2d;
    Ref<ID2D1DeviceContext> ctx;
    Ref<ID2D1SolidColorBrush> brush;
    Ref<ID2D1BitmapBrush1> bitmapBrush;
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

struct Surface {
    Device *device = nullptr;
    uint32_t w = 0, h = 0;
    uint32_t generation = 0;  // of the resources below; 0 = not made
    Ref<ID2D1Bitmap1> frame, scratchA, scratchB, readback;
};

bool loadable(const wchar_t *dll, HRESULT *hr) {
    if (LoadLibraryExW(dll, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) return true;
    *hr = HRESULT_FROM_WIN32(GetLastError());
    return false;
}

D2D1_MATRIX_3X2_F matrix(float a, float b, float c, float d, float tx, float ty) {
    D2D1_MATRIX_3X2_F m;
    m._11 = a;
    m._12 = b;
    m._21 = c;
    m._22 = d;
    m._31 = tx;
    m._32 = ty;
    return m;
}

const D2D1_MATRIX_3X2_F kIdentity = matrix(1, 0, 0, 1, 0, 0);

// A colour matrix that scales r, g, b, a and then adds the offsets (row vector times matrix, D2D's layout).
HRESULT setColorMatrix(ID2D1Effect *e, float r, float g, float b, float a, float offR, float offG, float offB, float offA) {
    D2D1_MATRIX_5X4_F m;
    std::memset(&m, 0, sizeof(m));
    m._11 = r;
    m._22 = g;
    m._33 = b;
    m._44 = a;
    m._51 = offR;
    m._52 = offG;
    m._53 = offB;
    m._54 = offA;
    return e->SetValue(D2D1_COLORMATRIX_PROP_COLOR_MATRIX, D2D1_PROPERTY_TYPE_MATRIX_5X4, reinterpret_cast<const BYTE *>(&m),
                       sizeof(m));
}

// The colour matrix applied to the values as they are (premultiplied in, premultiplied out: no un-premultiply step, which
// is what D2D1_COLORMATRIX_ALPHA_MODE_STRAIGHT means), clamped to 0...1.
HRESULT configureColorMatrix(ID2D1Effect *e) {
    const UINT32 mode = D2D1_COLORMATRIX_ALPHA_MODE_STRAIGHT;
    HRESULT hr = e->SetValue(D2D1_COLORMATRIX_PROP_ALPHA_MODE, D2D1_PROPERTY_TYPE_ENUM, reinterpret_cast<const BYTE *>(&mode),
                             sizeof(mode));
    if (FAILED(hr)) return hr;
    const BOOL clamp = TRUE;
    return e->SetValue(D2D1_COLORMATRIX_PROP_CLAMP_OUTPUT, D2D1_PROPERTY_TYPE_BOOL, reinterpret_cast<const BYTE *>(&clamp),
                       sizeof(clamp));
}

void releaseBitmaps(Device *d) {
    for (uint32_t i = 0; i < d->slotCount; i++) {
        if (d->slots[i]) d->slots[i]->Release();
        d->slots[i] = nullptr;
        d->slotBytes[i] = 0;
    }
    d->slotCount = 0;
    d->live = 0;
    d->liveBytes = 0;
}

void releaseDeviceObjects(Device *d) {
    d->arithOut.reset();
    d->dstOut.reset();
    d->tintOut.reset();
    d->arith.reset();
    d->dst.reset();
    d->tint.reset();
    d->bitmapBrush.reset();
    d->brush.reset();
    releaseBitmaps(d);
    d->ctx.reset();
    d->d2d.reset();
    d->idleQuery.reset();
    d->d3dContext.reset();
    d->d3d.reset();
}

HRESULT build(Device *d, int forceWarp, uint16_t *adapter, uint32_t adapterCap) {
    HRESULT hr = S_OK;
    for (const wchar_t *dll : {L"d3d11.dll", L"dxgi.dll", L"d2d1.dll"}) {
        if (!loadable(dll, &hr)) return fail("graphics DLL not loadable", hr);
    }
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                        D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3,  D3D_FEATURE_LEVEL_9_2,
                                        D3D_FEATURE_LEVEL_9_1};
    const UINT levelCount = sizeof(levels) / sizeof(levels[0]);
    D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_9_1;
    hr = E_FAIL;
    if (!forceWarp) {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, levelCount,
                               D3D11_SDK_VERSION, d->d3d.out(), &got, d->d3dContext.out());
        d->isWarp = 0;
    }
    if (FAILED(hr)) {
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, levelCount,
                               D3D11_SDK_VERSION, d->d3d.out(), &got, d->d3dContext.out());
        d->isWarp = 1;
    }
    if (FAILED(hr)) return fail("D3D11CreateDevice", hr);
    Ref<IDXGIDevice> dxgi;
    hr = d->d3d->QueryInterface(kIidDXGIDevice, reinterpret_cast<void **>(dxgi.out()));
    if (FAILED(hr)) return fail("IDXGIDevice", hr);
    if (adapter && adapterCap > 0) {
        adapter[0] = 0;
        Ref<IDXGIAdapter> a;
        DXGI_ADAPTER_DESC desc;
        if (SUCCEEDED(dxgi->GetAdapter(a.out())) && SUCCEEDED(a->GetDesc(&desc))) {
            uint32_t i = 0;
            for (; i + 1 < adapterCap && i < 127 && desc.Description[i]; i++) adapter[i] = static_cast<uint16_t>(desc.Description[i]);
            adapter[i] = 0;
        }
    }
    if (!d->factory.p) {
        D2D1_FACTORY_OPTIONS options;
        options.debugLevel = D2D1_DEBUG_LEVEL_NONE;
        hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, kIidD2D1Factory1, &options,
                               reinterpret_cast<void **>(d->factory.out()));
        if (FAILED(hr)) return fail("D2D1CreateFactory", hr);
    }
    hr = d->factory->CreateDevice(dxgi.p, d->d2d.out());
    if (FAILED(hr)) return fail("ID2D1Factory1::CreateDevice", hr);
    hr = d->d2d->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, d->ctx.out());
    if (FAILED(hr)) return fail("CreateDeviceContext", hr);
    d->ctx->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
    d->ctx->SetDpi(96.0f, 96.0f);
    d->ctx->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    const D2D1_COLOR_F white = {1, 1, 1, 1};
    hr = d->ctx->CreateSolidColorBrush(&white, nullptr, d->brush.out());
    if (FAILED(hr)) return fail("CreateSolidColorBrush", hr);
    hr = d->ctx->CreateEffect(kClsidColorMatrix, d->tint.out());
    if (FAILED(hr)) return fail("CreateEffect(ColorMatrix)", hr);
    hr = d->ctx->CreateEffect(kClsidColorMatrix, d->dst.out());
    if (FAILED(hr)) return fail("CreateEffect(ColorMatrix)", hr);
    hr = d->ctx->CreateEffect(kClsidArithmeticComposite, d->arith.out());
    if (FAILED(hr)) return fail("CreateEffect(ArithmeticComposite)", hr);
    hr = configureColorMatrix(d->tint.p);
    if (SUCCEEDED(hr)) hr = configureColorMatrix(d->dst.p);
    if (FAILED(hr)) return fail("colour matrix properties", hr);
    const BOOL clamp = TRUE;
    hr = d->arith->SetValue(D2D1_ARITHMETICCOMPOSITE_PROP_CLAMP_OUTPUT, D2D1_PROPERTY_TYPE_BOOL,
                            reinterpret_cast<const BYTE *>(&clamp), sizeof(clamp));
    if (FAILED(hr)) return fail("arithmetic composite properties", hr);
    d->tint->GetOutput(d->tintOut.out());
    d->dst->GetOutput(d->dstOut.out());
    d->arith->GetOutput(d->arithOut.out());
    // Arithmetic composite: input 0 is the destination (the copy under the sprite), input 1 the source.
    d->arith->SetInput(0, d->dstOut.p);
    d->arith->SetInput(1, d->tintOut.p);
    return S_OK;
}

void drain(Device *d) {
    AcquireSRWLockExclusive(&d->lock);
    for (uint32_t i = 0; i < d->pendingCount; i++) {
        const Pending p = d->pending[i];
        if (p.generation != d->generation || p.handle == 0 || p.handle > d->slotCount) continue;
        ID2D1Bitmap1 *&slot = d->slots[p.handle - 1];
        if (!slot) continue;
        slot->Release();
        slot = nullptr;
        d->live--;
        d->liveBytes -= d->slotBytes[p.handle - 1];
        d->slotBytes[p.handle - 1] = 0;
    }
    d->pendingCount = 0;
    ReleaseSRWLockExclusive(&d->lock);
}

ID2D1Bitmap1 *lookup(Device *d, uint32_t handle) {
    if (handle == 0 || handle > d->slotCount) return nullptr;
    return d->slots[handle - 1];
}

HRESULT makeBitmap(Device *d, uint32_t w, uint32_t h, D2D1_BITMAP_OPTIONS options, ID2D1Bitmap1 **out) {
    D2D1_BITMAP_PROPERTIES1 p;
    std::memset(&p, 0, sizeof(p));
    p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
    p.dpiX = 96.0f;
    p.dpiY = 96.0f;
    p.bitmapOptions = options;
    p.colorContext = nullptr;
    const D2D1_SIZE_U size = {w, h};
    return d->ctx->CreateBitmap(size, nullptr, 0, &p, out);
}

// The surface's frame and scratch bitmaps, made again after a resize or a device rebuild.
HRESULT ensure(Surface *s) {
    Device *d = s->device;
    if (s->generation == d->generation && s->frame.p) return S_OK;
    s->frame.reset();
    s->scratchA.reset();
    s->scratchB.reset();
    s->readback.reset();
    HRESULT hr = makeBitmap(d, s->w, s->h, D2D1_BITMAP_OPTIONS_TARGET, s->frame.out());
    if (SUCCEEDED(hr)) hr = makeBitmap(d, s->w, s->h, D2D1_BITMAP_OPTIONS_TARGET, s->scratchA.out());
    if (SUCCEEDED(hr)) hr = makeBitmap(d, s->w, s->h, D2D1_BITMAP_OPTIONS_TARGET, s->scratchB.out());
    if (FAILED(hr)) {
        s->frame.reset();
        return hr;
    }
    s->generation = d->generation;
    return S_OK;
}

void noteLoss(Device *d, HRESULT hr) {
    if (hr == kRecreateTarget && !d->lost) {
        d->lost = true;
        d->losses++;
    }
}

// One sprite drawn as it is (source over), with the given opacity: the unit square under the command's transform.
HRESULT drawPlain(Device *d, const PTBDrawCmd &k, float opacity, const char **stage) {
    ID2D1DeviceContext *c = d->ctx.p;
    const D2D1_MATRIX_3X2_F m = matrix(k.m[0], k.m[1], k.m[2], k.m[3], k.m[4], k.m[5]);
    const D2D1_RECT_F unit = {0, 0, 1, 1};
    if (k.kind == PTB_CMD_COLOR) {
        const D2D1_COLOR_F color = {k.color[0], k.color[1], k.color[2], k.color[3] * opacity};
        d->brush->SetColor(&color);
        c->SetTransform(&m);
        c->FillRectangle(&unit, d->brush.p);
        return S_OK;
    }
    ID2D1Bitmap1 *bitmap = lookup(d, k.bitmap);
    if (!bitmap) {
        *stage = "draw: stale or unknown bitmap handle";
        return E_HANDLE;
    }
    const D2D1_INTERPOLATION_MODE mode =
        (d->options & 1u) ? D2D1_INTERPOLATION_MODE_LINEAR : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
    const float sx = k.src[0], sy = k.src[1], sw = k.src[2], sh = k.src[3];
    if (sw <= 0 || sh <= 0) return S_OK;
    if (d->options & 2u) {
        if (!d->bitmapBrush.p) {
            D2D1_BITMAP_BRUSH_PROPERTIES1 bp;
            bp.extendModeX = D2D1_EXTEND_MODE_CLAMP;
            bp.extendModeY = D2D1_EXTEND_MODE_CLAMP;
            bp.interpolationMode = D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
            HRESULT hr = c->CreateBitmapBrush(bitmap, &bp, nullptr, d->bitmapBrush.out());
            if (FAILED(hr)) {
                *stage = "CreateBitmapBrush";
                return hr;
            }
        }
        ID2D1BitmapBrush1 *b = d->bitmapBrush.p;
        b->SetBitmap(bitmap);
        b->SetInterpolationMode1(mode);
        b->SetOpacity(opacity);
        // Brush space is the bitmap's texels; the brush transform maps them onto the unit square.
        const D2D1_MATRIX_3X2_F bt = matrix(1 / sw, 0, 0, 1 / sh, -sx / sw, -sy / sh);
        b->SetTransform(&bt);
        c->SetTransform(&m);
        c->FillRectangle(&unit, b);
        return S_OK;
    }
    const D2D1_RECT_F src = {sx, sy, sx + sw, sy + sh};
    c->SetTransform(&m);
    c->DrawBitmap(bitmap, &unit, opacity, mode, &src, nullptr);
    return S_OK;
}

// Colour blend and SpriteKit's multiply modes (see PTBDrawCmd): the sprite alone in scratch A, the destination under it
// copied to scratch B, a colour matrix / arithmetic composite of the two drawn back into the region.
HRESULT drawEffect(Device *d, Surface *s, const PTBDrawCmd &k, const char **stage) {
    ID2D1DeviceContext *c = d->ctx.p;
    int32_t l = k.region[0] > 0 ? k.region[0] : 0, t = k.region[1] > 0 ? k.region[1] : 0;
    int32_t r = k.region[2] < static_cast<int32_t>(s->w) ? k.region[2] : static_cast<int32_t>(s->w);
    int32_t b = k.region[3] < static_cast<int32_t>(s->h) ? k.region[3] : static_cast<int32_t>(s->h);
    if (k.hasClip) {
        if (k.clip[0] > l) l = k.clip[0];
        if (k.clip[1] > t) t = k.clip[1];
        if (k.clip[2] < r) r = k.clip[2];
        if (k.clip[3] < b) b = k.clip[3];
    }
    if (l >= r || t >= b) return S_OK;
    const D2D1_RECT_F region = {static_cast<float>(l), static_cast<float>(t), static_cast<float>(r), static_cast<float>(b)};
    const D2D1_POINT_2F at = {static_cast<float>(l), static_cast<float>(t)};
    const D2D1_POINT_2U copyAt = {static_cast<UINT32>(l), static_cast<UINT32>(t)};
    const D2D1_RECT_U copyRect = {static_cast<UINT32>(l), static_cast<UINT32>(t), static_cast<UINT32>(r), static_cast<UINT32>(b)};
    const float kx = k.blend == PTB_BLEND_MULTIPLY_X2 ? 2.0f : 1.0f;
    HRESULT hr = S_OK;

    if (k.kind == PTB_CMD_COLOR) {
        // Only the multiply modes come here (a plain colour needs no effect): rgb = kx * colour * dst, alpha = colour alpha.
        c->SetTarget(s->scratchA.p);  // the frame must not be the target while it is copied
        hr = s->scratchB->CopyFromBitmap(&copyAt, s->frame.p, &copyRect);
        c->SetTarget(s->frame.p);
        if (FAILED(hr)) {
            *stage = "CopyFromBitmap";
            return hr;
        }
        const float a = k.color[3] * k.opacity;
        hr = setColorMatrix(d->dst.p, kx * k.color[0] * a, kx * k.color[1] * a, kx * k.color[2] * a, 0, 0, 0, 0, a);
        if (FAILED(hr)) {
            *stage = "colour matrix";
            return hr;
        }
        d->dst->SetInput(0, s->scratchB.p);
        c->SetTransform(&kIdentity);
        c->DrawImage(d->dstOut.p, &at, &region, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, D2D1_COMPOSITE_MODE_SOURCE_COPY);
        c->Flush();  // the effect's properties and scratch bitmaps change for the next sprite
        return S_OK;
    }

    // The sprite alone, exact texels (opacity 1), in scratch A.
    c->SetTarget(s->scratchA.p);
    c->SetTransform(&kIdentity);
    c->PushAxisAlignedClip(&region, D2D1_ANTIALIAS_MODE_ALIASED);
    const D2D1_COLOR_F none = {0, 0, 0, 0};
    c->Clear(&none);
    hr = drawPlain(d, k, 1.0f, stage);
    c->SetTransform(&kIdentity);
    c->PopAxisAlignedClip();
    if (FAILED(hr)) {
        c->SetTarget(s->frame.p);
        return hr;
    }
    const float o = k.opacity;
    const float t0 = k.useTint ? k.tint[0] : 1.0f, t1 = k.useTint ? k.tint[1] : 1.0f, t2 = k.useTint ? k.tint[2] : 1.0f;
    hr = setColorMatrix(d->tint.p, t0 * o, t1 * o, t2 * o, o, 0, 0, 0, 0);
    if (FAILED(hr)) {
        c->SetTarget(s->frame.p);
        *stage = "colour matrix";
        return hr;
    }
    d->tint->SetInput(0, s->scratchA.p);
    if (k.blend == PTB_BLEND_ALPHA) {
        c->SetTarget(s->frame.p);
        c->SetTransform(&kIdentity);
        c->DrawImage(d->tintOut.p, &at, &region, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, D2D1_COMPOSITE_MODE_SOURCE_OVER);
        c->Flush();
        return S_OK;
    }
    hr = s->scratchB->CopyFromBitmap(&copyAt, s->frame.p, &copyRect);  // scratch A is the target, not the frame
    c->SetTarget(s->frame.p);
    if (FAILED(hr)) {
        *stage = "CopyFromBitmap";
        return hr;
    }
    // dst' = (dst.rgb, 1 / kx), so kx * src * dst' gives alpha = src alpha exactly (SpriteKit's) and rgb = kx * src * dst.
    hr = setColorMatrix(d->dst.p, 1, 1, 1, 0, 0, 0, 0, 1.0f / kx);
    if (SUCCEEDED(hr)) {
        const D2D1_VECTOR_4F coefficients = {kx, 0, 0, 0};
        hr = d->arith->SetValue(D2D1_ARITHMETICCOMPOSITE_PROP_COEFFICIENTS, D2D1_PROPERTY_TYPE_VECTOR4,
                                reinterpret_cast<const BYTE *>(&coefficients), sizeof(coefficients));
    }
    if (FAILED(hr)) {
        *stage = "multiply effect properties";
        return hr;
    }
    d->dst->SetInput(0, s->scratchB.p);
    c->SetTransform(&kIdentity);
    c->DrawImage(d->arithOut.p, &at, &region, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, D2D1_COMPOSITE_MODE_SOURCE_COPY);
    c->Flush();
    return S_OK;
}

HRESULT drawCommand(Device *d, Surface *s, const PTBDrawCmd &k, const char **stage) {
    const bool effect = k.blend != PTB_BLEND_ALPHA || (k.useTint && k.kind == PTB_CMD_BITMAP);
    if (effect) return drawEffect(d, s, k, stage);
    ID2D1DeviceContext *c = d->ctx.p;
    D2D1_RECT_F clip = {0, 0, 0, 0};
    if (k.hasClip) {
        clip = {static_cast<float>(k.clip[0]), static_cast<float>(k.clip[1]), static_cast<float>(k.clip[2]),
                static_cast<float>(k.clip[3])};
        if (clip.left >= clip.right || clip.top >= clip.bottom) return S_OK;
        c->SetTransform(&kIdentity);
        c->PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_ALIASED);
    }
    const HRESULT hr = drawPlain(d, k, k.opacity, stage);
    if (k.hasClip) {
        c->SetTransform(&kIdentity);
        c->PopAxisAlignedClip();
    }
    return hr;
}

bool grow(void **array, uint32_t *cap, uint32_t need, size_t itemSize) {
    if (need <= *cap) return true;
    uint32_t next = *cap ? *cap * 2 : 64;
    while (next < need) next *= 2;
    void *made = std::realloc(*array, static_cast<size_t>(next) * itemSize);
    if (!made) return false;
    *array = made;
    *cap = next;
    return true;
}

}  // namespace

extern "C" PTBGfxDevice *ptb_gfx_device_create(int forceWarp, uint16_t *adapter, uint32_t adapterCap) {
    Device *d = new (std::nothrow) Device();
    if (!d) {
        fail("ptb_gfx_device_create", E_OUTOFMEMORY);
        return nullptr;
    }
    const HRESULT hr = build(d, forceWarp, adapter, adapterCap);
    if (FAILED(hr)) {  // build set the error text
        releaseDeviceObjects(d);
        delete d;
        return nullptr;
    }
    d->generation = 1;
    return reinterpret_cast<PTBGfxDevice *>(d);
}

extern "C" int ptb_gfx_device_recreate(PTBGfxDevice *device, int forceWarp) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d) return fail("ptb_gfx_device_recreate", E_INVALIDARG);
    drain(d);
    releaseDeviceObjects(d);
    d->generation++;  // every handle and surface resource of the old generation is stale now
    d->lost = false;
    d->injectLoss = 0;
    const HRESULT hr = build(d, forceWarp, nullptr, 0);
    if (FAILED(hr)) {
        d->lost = true;
        return static_cast<int>(hr);
    }
    return 0;
}

extern "C" uint32_t ptb_gfx_device_generation(PTBGfxDevice *device) {
    const Device *d = reinterpret_cast<const Device *>(device);
    return d ? d->generation : 0;
}

extern "C" void ptb_gfx_device_stats(PTBGfxDevice *device, PTBGfxDeviceStats *out) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || !out) return;
    drain(d);
    out->generation = d->generation;
    out->uploads = d->uploads;
    out->liveBitmaps = d->live;
    out->liveBitmapBytes = d->liveBytes;
    out->losses = d->losses;
    out->frames = d->frames;
    out->isWarp = d->isWarp;
}

extern "C" void ptb_gfx_device_release(PTBGfxDevice *device) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d) return;
    releaseDeviceObjects(d);
    d->factory.reset();
    std::free(d->slots);
    std::free(d->slotBytes);
    std::free(d->pending);
    delete d;
}

extern "C" uint32_t ptb_gfx_bitmap(PTBGfxDevice *device, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t stride, int opaque) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || !rgba || w == 0 || h == 0 || stride < w * 4) {
        fail("ptb_gfx_bitmap", E_INVALIDARG);
        return 0;
    }
    if (d->lost) {
        fail("ptb_gfx_bitmap: device lost", kRecreateTarget);
        return 0;
    }
    drain(d);
    uint32_t slot = d->slotCount;
    for (uint32_t i = 0; i < d->slotCount; i++) {
        if (!d->slots[i]) {
            slot = i;
            break;
        }
    }
    if (slot == d->slotCount) {
        uint32_t capA = d->slotCap, capB = d->slotCap;
        if (!grow(reinterpret_cast<void **>(&d->slots), &capA, slot + 1, sizeof(ID2D1Bitmap1 *)) ||
            !grow(reinterpret_cast<void **>(&d->slotBytes), &capB, slot + 1, sizeof(uint64_t))) {
            fail("ptb_gfx_bitmap: table", E_OUTOFMEMORY);
            return 0;
        }
        d->slotCap = capA < capB ? capA : capB;
        d->slots[slot] = nullptr;
        d->slotBytes[slot] = 0;
        d->slotCount = slot + 1;
    }
    D2D1_BITMAP_PROPERTIES1 p;
    std::memset(&p, 0, sizeof(p));
    p.pixelFormat.format = DXGI_FORMAT_R8G8B8A8_UNORM;
    p.pixelFormat.alphaMode = opaque ? D2D1_ALPHA_MODE_IGNORE : D2D1_ALPHA_MODE_PREMULTIPLIED;
    p.dpiX = 96.0f;
    p.dpiY = 96.0f;
    p.bitmapOptions = D2D1_BITMAP_OPTIONS_NONE;
    p.colorContext = nullptr;
    const D2D1_SIZE_U size = {w, h};
    ID2D1Bitmap1 *bitmap = nullptr;
    const HRESULT hr = d->ctx->CreateBitmap(size, rgba, stride, &p, &bitmap);
    if (FAILED(hr)) {
        noteLoss(d, hr);
        fail("CreateBitmap", hr);
        return 0;
    }
    d->slots[slot] = bitmap;
    d->slotBytes[slot] = static_cast<uint64_t>(w) * h * 4;
    d->uploads++;
    d->live++;
    d->liveBytes += d->slotBytes[slot];
    return slot + 1;
}

extern "C" void ptb_gfx_bitmap_release(PTBGfxDevice *device, uint32_t handle, uint32_t generation) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || handle == 0) return;
    AcquireSRWLockExclusive(&d->lock);
    if (grow(reinterpret_cast<void **>(&d->pending), &d->pendingCap, d->pendingCount + 1, sizeof(Pending))) {
        d->pending[d->pendingCount++] = Pending{handle, generation};
    }
    ReleaseSRWLockExclusive(&d->lock);
}

extern "C" PTBGfxSurface *ptb_gfx_surface_offscreen(PTBGfxDevice *device, uint32_t w, uint32_t h) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || w == 0 || h == 0 || w > 16384 || h > 16384) {
        fail("ptb_gfx_surface_offscreen", E_INVALIDARG);
        return nullptr;
    }
    Surface *s = new (std::nothrow) Surface();
    if (!s) {
        fail("ptb_gfx_surface_offscreen", E_OUTOFMEMORY);
        return nullptr;
    }
    s->device = d;
    s->w = w;
    s->h = h;
    if (!d->lost) {
        const HRESULT hr = ensure(s);
        if (FAILED(hr)) {
            noteLoss(d, hr);
            fail("surface bitmaps", hr);
            delete s;
            return nullptr;
        }
    }
    return reinterpret_cast<PTBGfxSurface *>(s);
}

extern "C" int ptb_gfx_surface_resize(PTBGfxSurface *surface, uint32_t w, uint32_t h) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || w == 0 || h == 0 || w > 16384 || h > 16384) return fail("ptb_gfx_surface_resize", E_INVALIDARG);
    if (s->w == w && s->h == h) return 0;
    s->w = w;
    s->h = h;
    s->generation = 0;  // made again on the next frame
    s->frame.reset();
    s->scratchA.reset();
    s->scratchB.reset();
    s->readback.reset();
    return 0;
}

extern "C" void ptb_gfx_surface_release(PTBGfxSurface *surface) { delete reinterpret_cast<Surface *>(surface); }

extern "C" int ptb_gfx_frame(PTBGfxSurface *surface, const float clear[4], const PTBDrawCmd *cmds, uint32_t n) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || !clear || (n > 0 && !cmds)) return fail("ptb_gfx_frame", E_INVALIDARG);
    Device *d = s->device;
    if (d->lost) return fail("ptb_gfx_frame: device lost", kRecreateTarget);
    drain(d);
    HRESULT hr = ensure(s);
    if (FAILED(hr)) {
        noteLoss(d, hr);
        return fail("surface bitmaps", hr);
    }
    ID2D1DeviceContext *c = d->ctx.p;
    c->SetTarget(s->frame.p);
    c->BeginDraw();
    c->SetTransform(&kIdentity);
    c->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    c->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
    const D2D1_COLOR_F color = {clear[0], clear[1], clear[2], clear[3]};
    c->Clear(&color);
    HRESULT drawHr = S_OK;
    const char *stage = "draw";
    for (uint32_t i = 0; i < n; i++) {
        const char *at = "draw";
        const HRESULT one = cmds[i].kind == PTB_CMD_BITMAP || cmds[i].kind == PTB_CMD_COLOR
                                ? drawCommand(d, s, cmds[i], &at)
                                : E_INVALIDARG;
        if (FAILED(one) && SUCCEEDED(drawHr)) {
            drawHr = one;
            stage = at;
        }
    }
    c->SetTransform(&kIdentity);
    hr = c->EndDraw();
    c->SetTarget(nullptr);
    d->frames++;
    if (d->injectLoss) {
        d->injectLoss = 0;
        hr = kRecreateTarget;
    }
    if (hr == kRecreateTarget) {
        noteLoss(d, hr);
        return fail("EndDraw", hr);
    }
    if (FAILED(hr)) return fail("EndDraw", hr);
    if (FAILED(drawHr)) return fail(stage, drawHr);
    return 0;
}

extern "C" int ptb_gfx_read(PTBGfxSurface *surface, uint8_t *rgba, uint32_t stride) {
    Surface *s = reinterpret_cast<Surface *>(surface);
    if (!s || !rgba || stride < s->w * 4) return fail("ptb_gfx_read", E_INVALIDARG);
    Device *d = s->device;
    if (d->lost) return fail("ptb_gfx_read: device lost", kRecreateTarget);
    if (!s->frame.p || s->generation != d->generation) return fail("ptb_gfx_read: nothing drawn", E_FAIL);
    HRESULT hr = S_OK;
    if (!s->readback.p) {
        hr = makeBitmap(d, s->w, s->h, static_cast<D2D1_BITMAP_OPTIONS>(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
                        s->readback.out());
        if (FAILED(hr)) return fail("readback bitmap", hr);
    }
    hr = s->readback->CopyFromBitmap(nullptr, s->frame.p, nullptr);
    if (FAILED(hr)) {
        noteLoss(d, hr);
        return fail("readback copy", hr);
    }
    D2D1_MAPPED_RECT mapped;
    hr = s->readback->Map(D2D1_MAP_OPTIONS_READ, &mapped);
    if (FAILED(hr)) return fail("readback map", hr);
    for (uint32_t y = 0; y < s->h; y++) {
        const uint8_t *from = mapped.bits + static_cast<size_t>(y) * mapped.pitch;
        uint8_t *to = rgba + static_cast<size_t>(y) * stride;
        for (uint32_t x = 0; x < s->w; x++) {  // BGRA -> RGBA
            to[x * 4] = from[x * 4 + 2];
            to[x * 4 + 1] = from[x * 4 + 1];
            to[x * 4 + 2] = from[x * 4];
            to[x * 4 + 3] = from[x * 4 + 3];
        }
    }
    s->readback->Unmap();
    return 0;
}

extern "C" int ptb_gfx_finish(PTBGfxDevice *device) {
    Device *d = reinterpret_cast<Device *>(device);
    if (!d || !d->d3d.p || !d->d3dContext.p) return fail("ptb_gfx_finish", E_INVALIDARG);
    HRESULT hr = S_OK;
    if (!d->idleQuery.p) {
        D3D11_QUERY_DESC q;
        q.Query = D3D11_QUERY_EVENT;
        q.MiscFlags = 0;
        hr = d->d3d->CreateQuery(&q, d->idleQuery.out());
        if (FAILED(hr)) return fail("CreateQuery", hr);
    }
    d->d3dContext->End(d->idleQuery.p);
    d->d3dContext->Flush();
    const ULONGLONG deadline = GetTickCount64() + 10000;
    for (;;) {
        BOOL done = FALSE;
        hr = d->d3dContext->GetData(d->idleQuery.p, &done, sizeof(done), 0);
        if (hr == S_OK && done) return 0;
        if (FAILED(hr)) return fail("GetData", hr);
        if (GetTickCount64() > deadline) return fail("ptb_gfx_finish: timeout", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
        Sleep(0);
    }
}

extern "C" void ptb_gfx_inject_fault(PTBGfxDevice *device, int kind) {
    Device *d = reinterpret_cast<Device *>(device);
    if (d && kind == 1) d->injectLoss = 1;
}

extern "C" void ptb_gfx_set_options(PTBGfxDevice *device, uint32_t flags) {
    Device *d = reinterpret_cast<Device *>(device);
    if (d) d->options = flags;
}

extern "C" uint64_t ptb_gfx_process_private_bytes(void) {
    PROCESS_MEMORY_COUNTERS_EX counters;
    std::memset(&counters, 0, sizeof(counters));
    counters.cb = sizeof(counters);
    if (!K32GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&counters), sizeof(counters))) return 0;
    return counters.PrivateUsage;
}
