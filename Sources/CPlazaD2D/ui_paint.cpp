// The popover's antialiased shape painter (CPlazaD2DPaint.h): a CPU Direct2D DC render target, bound per call.
#include "CPlazaD2DPaint.h"
#include "canvas.h"

#include <algorithm>

namespace ptb {

/// canvas_core.cpp: the process's multi-threaded Direct2D factory.
int sharedD2DFactory(Ref<ID2D1Factory> &out);

namespace {

Ref<ID2D1DCRenderTarget> gTarget;  // main thread only; kept for the process
Ref<ID2D1SolidColorBrush> gBrush;
uint64_t gDrawn = 0, gFailed = 0;

int ensureTarget() {
    if (gTarget && gBrush) return 0;
    gTarget.reset();
    gBrush.reset();
    Ref<ID2D1Factory> factory;
    int code = sharedD2DFactory(factory);
    if (code != 0) return code;
    D2D1_RENDER_TARGET_PROPERTIES props = {};
    props.type = D2D1_RENDER_TARGET_TYPE_SOFTWARE;  // no GPU device: the popover has none (plan D7)
    props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
    props.dpiX = 96.0f;
    props.dpiY = 96.0f;
    props.usage = D2D1_RENDER_TARGET_USAGE_NONE;
    props.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;
    HRESULT hr = factory->CreateDCRenderTarget(&props, gTarget.out());
    if (FAILED(hr)) return fail("CreateDCRenderTarget", hr);
    const D2D1_COLOR_F black = {0, 0, 0, 1};
    hr = gTarget->CreateSolidColorBrush(black, gBrush.out());
    if (FAILED(hr)) {
        gTarget.reset();
        return fail("CreateSolidColorBrush", hr);
    }
    return 0;
}

D2D1_COLOR_F colorOf(uint32_t argb) {
    return D2D1_COLOR_F{static_cast<float>((argb >> 16) & 0xFF) / 255.0f, static_cast<float>((argb >> 8) & 0xFF) / 255.0f,
                        static_cast<float>(argb & 0xFF) / 255.0f, static_cast<float>(argb >> 24) / 255.0f};
}

}  // namespace
}  // namespace ptb

extern "C" {

int ptb_paint_shapes(void *hdc, int32_t left, int32_t top, int32_t right, int32_t bottom, const PTBPaintShape *shapes, uint32_t count) {
    using namespace ptb;
    if (!hdc || (count > 0 && !shapes)) return fail("ptb_paint_shapes", E_INVALIDARG);
    if (right <= left || bottom <= top || count == 0) return 0;
    int code = ensureTarget();
    if (code != 0) { gFailed++; return code; }
    RECT bounds = {left, top, right, bottom};
    HRESULT hr = gTarget->BindDC(static_cast<HDC>(hdc), &bounds);
    if (FAILED(hr)) { gFailed++; return fail("BindDC", hr); }
    gTarget->BeginDraw();
    gTarget->SetTransform(D2D1::Matrix3x2F::Identity());
    gTarget->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    for (uint32_t i = 0; i < count; i++) {
        const PTBPaintShape &s = shapes[i];
        if (s.w <= 0 || s.h <= 0) continue;
        const float radius = std::max(0.0f, std::min(s.radius, std::min(s.w, s.h) / 2));
        if ((s.fill >> 24) != 0) {
            gBrush->SetColor(colorOf(s.fill));
            const D2D1_RECT_F r = D2D1::RectF(s.x, s.y, s.x + s.w, s.y + s.h);
            if (radius > 0) gTarget->FillRoundedRectangle(D2D1::RoundedRect(r, radius, radius), gBrush.get());
            else gTarget->FillRectangle(r, gBrush.get());
        }
        if (s.strokeWidth > 0 && (s.stroke >> 24) != 0) {
            gBrush->SetColor(colorOf(s.stroke));
            const float half = s.strokeWidth / 2;
            const D2D1_RECT_F r = D2D1::RectF(s.x + half, s.y + half, s.x + s.w - half, s.y + s.h - half);
            if (r.right > r.left && r.bottom > r.top) {
                const float inner = std::max(0.0f, radius - half);
                if (inner > 0) gTarget->DrawRoundedRectangle(D2D1::RoundedRect(r, inner, inner), gBrush.get(), s.strokeWidth);
                else gTarget->DrawRectangle(r, gBrush.get(), s.strokeWidth);
            }
        }
    }
    hr = gTarget->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        gTarget.reset();
        gBrush.reset();
    }
    if (FAILED(hr)) { gFailed++; return fail("EndDraw", hr); }
    gDrawn++;
    return 0;
}

void ptb_paint_stats(uint64_t *drawn, uint64_t *failed) {
    if (drawn) *drawn = ptb::gDrawn;
    if (failed) *failed = ptb::gFailed;
}

}  // extern "C"
