// Canvas::paint and the CPU compositor for what Direct2D's plain render target cannot do: a drop shadow and the multiply and
// source-atop blends. The primitive is drawn at full strength into the scratch surface, then (shadow under it, global alpha,
// clip coverage) combined with the main surface's pixels in premultiplied arithmetic, CoreGraphics' formulas:
//   normal      R = S + D (1 - Sa)
//   multiply    R = S (1 - Da) + D (1 - Sa) + S D      (alpha as normal)
//   source-atop R = S Da + D (1 - Sa)                  (alpha stays Da)
// Shadow: the alpha of the primitive, moved by the offset (device pixels, y up), blurred with a Gaussian of sigma = blur / 2,
// tinted with the shadow colour (its alpha included) and put under the primitive.
#include "canvas.h"

#include <windows.h>

#include <algorithm>
#include <cmath>

namespace ptb {

void Canvas::paint(const Paint &body) {
    if (st.blend == kBlendNormal && !st.hasShadow) {
        prepare(main);
        body(main, static_cast<float>(st.alpha));
        return;
    }
    if (ensureAuxiliary() != 0) { failures++; return; }
    scratch.rt->BeginDraw();
    scratch.rt->Clear(D2D1_COLOR_F{0, 0, 0, 0});
    prepare(scratch);
    body(scratch, 1.0f);
    const HRESULT hr = scratch.rt->EndDraw();
    if (FAILED(hr)) { note("EndDraw(scratch)", hr); return; }
    composite();
}

int Canvas::ensureAuxiliary() {
    if (scratch.rt) return 0;
    const int code = makeSurface(scratch);
    if (code != 0) return code;
    return makeSurface(mask);
}

// The clip stack as coverage: white drawn through every clip into the mask (cached until a clip changes).
int Canvas::renderMask() {
    if (maskGeneration == clipGeneration) return 0;
    mask.rt->BeginDraw();
    mask.rt->Clear(D2D1_COLOR_F{0, 0, 0, 0});
    for (const Clip &c : clips) pushClip(mask, c);
    const D2D1_MATRIX_3X2_F identity = D2D1::Matrix3x2F::Identity();
    mask.rt->SetTransform(&identity);
    mask.rt->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    setBrush(mask, Rgba{1, 1, 1, 1}, 1.0f);
    mask.rt->FillRectangle(D2D1_RECT_F{0, 0, static_cast<float>(width), static_cast<float>(height)}, mask.brush.get());
    for (size_t i = clips.size(); i > 0; i--) popClip(mask, clips[i - 1]);
    const HRESULT hr = mask.rt->EndDraw();
    if (FAILED(hr)) return fail("EndDraw(mask)", hr);
    maskGeneration = clipGeneration;
    return 0;
}

namespace {

struct Locked {
    Ref<IWICBitmapLock> lock;
    BYTE *data = nullptr;
    UINT stride = 0;
    bool open(IWICBitmap *bitmap, DWORD flags, uint32_t w, uint32_t h) {
        const WICRect rect = {0, 0, static_cast<INT>(w), static_cast<INT>(h)};
        UINT size = 0;
        if (FAILED(bitmap->Lock(&rect, flags, lock.out()))) return false;
        if (FAILED(lock->GetStride(&stride))) return false;
        return SUCCEEDED(lock->GetDataPointer(&size, &data));
    }
};

inline uint8_t toByte(float v) {
    const float s = v * 255.0f + 0.5f;
    return static_cast<uint8_t>(s < 0 ? 0 : (s > 255 ? 255 : s));
}

// Gaussian blur of a w x h float plane (values 0..1), pixels outside count as 0.
void blur(std::vector<float> &plane, uint32_t w, uint32_t h, double sigma) {
    if (sigma < 0.05) return;
    const int radius = std::max(1, static_cast<int>(std::ceil(sigma * 3)));
    std::vector<float> k(radius + 1);
    double sum = 0;
    for (int i = 0; i <= radius; i++) { k[i] = static_cast<float>(std::exp(-(i * i) / (2 * sigma * sigma))); sum += (i == 0 ? 1 : 2) * k[i]; }
    for (float &v : k) v = static_cast<float>(v / sum);
    std::vector<float> tmp(plane.size(), 0.0f);
    for (uint32_t y = 0; y < h; y++) {
        for (uint32_t x = 0; x < w; x++) {
            float acc = 0;
            for (int i = -radius; i <= radius; i++) {
                const int xx = static_cast<int>(x) + i;
                if (xx < 0 || xx >= static_cast<int>(w)) continue;
                acc += plane[static_cast<size_t>(y) * w + xx] * k[std::abs(i)];
            }
            tmp[static_cast<size_t>(y) * w + x] = acc;
        }
    }
    for (uint32_t y = 0; y < h; y++) {
        for (uint32_t x = 0; x < w; x++) {
            float acc = 0;
            for (int i = -radius; i <= radius; i++) {
                const int yy = static_cast<int>(y) + i;
                if (yy < 0 || yy >= static_cast<int>(h)) continue;
                acc += tmp[static_cast<size_t>(yy) * w + x] * k[std::abs(i)];
            }
            plane[static_cast<size_t>(y) * w + x] = acc;
        }
    }
}

}  // namespace

void Canvas::composite() {
    const bool useMask = !clips.empty();
    if (useMask && renderMask() != 0) { failures++; return; }
    if (suspendMain() != 0) { failures++; resumeMain(); return; }

    Locked dst, src, cov;
    bool ok = dst.open(main.wic.get(), WICBitmapLockWrite, width, height) && src.open(scratch.wic.get(), WICBitmapLockRead, width, height) &&
              (!useMask || cov.open(mask.wic.get(), WICBitmapLockRead, width, height));
    if (!ok) {
        note("lock for composite", E_FAIL);
    } else {
        const size_t count = static_cast<size_t>(width) * height;
        std::vector<float> shadow;  // premultiplied shadow alpha plane (already tinted by the colour's alpha)
        if (st.hasShadow) {
            shadow.assign(count, 0.0f);
            const int dx = static_cast<int>(std::lround(st.shadowDx)), dy = -static_cast<int>(std::lround(st.shadowDy));
            for (uint32_t y = 0; y < height; y++) {
                const int sy = static_cast<int>(y) - dy;
                if (sy < 0 || sy >= static_cast<int>(height)) continue;
                const uint8_t *row = src.data + static_cast<size_t>(sy) * src.stride;
                for (uint32_t x = 0; x < width; x++) {
                    const int sx = static_cast<int>(x) - dx;
                    if (sx < 0 || sx >= static_cast<int>(width)) continue;
                    shadow[static_cast<size_t>(y) * width + x] = row[sx * 4 + 3] / 255.0f;
                }
            }
            blur(shadow, width, height, st.shadowBlur / 2);
        }
        const float galpha = static_cast<float>(st.alpha);
        const float shR = static_cast<float>(st.shadowColor.r), shG = static_cast<float>(st.shadowColor.g),
                    shB = static_cast<float>(st.shadowColor.b), shA = static_cast<float>(st.shadowColor.a);
        for (uint32_t y = 0; y < height; y++) {
            const uint8_t *s = src.data + static_cast<size_t>(y) * src.stride;
            uint8_t *d = dst.data + static_cast<size_t>(y) * dst.stride;
            const uint8_t *m = useMask ? cov.data + static_cast<size_t>(y) * cov.stride : nullptr;
            for (uint32_t x = 0; x < width; x++) {
                float c[4] = {s[x * 4 + 0] / 255.0f, s[x * 4 + 1] / 255.0f, s[x * 4 + 2] / 255.0f, s[x * 4 + 3] / 255.0f};  // B G R A
                if (st.hasShadow) {
                    const float sa = shadow[static_cast<size_t>(y) * width + x] * shA;
                    const float under = sa * (1 - c[3]);
                    c[0] += shB * under;
                    c[1] += shG * under;
                    c[2] += shR * under;
                    c[3] += under;
                }
                float k = galpha;
                if (m) k *= m[x * 4 + 3] / 255.0f;
                if (k <= 0) continue;
                for (float &v : c) v *= k;
                const float D[4] = {d[x * 4 + 0] / 255.0f, d[x * 4 + 1] / 255.0f, d[x * 4 + 2] / 255.0f, d[x * 4 + 3] / 255.0f};
                float r[4];
                for (int i = 0; i < 3; i++) {
                    switch (st.blend) {
                    case kBlendMultiply: r[i] = c[i] * (1 - D[3]) + D[i] * (1 - c[3]) + c[i] * D[i]; break;
                    case kBlendSourceAtop: r[i] = c[i] * D[3] + D[i] * (1 - c[3]); break;
                    default: r[i] = c[i] + D[i] * (1 - c[3]); break;
                    }
                }
                r[3] = (st.blend == kBlendSourceAtop) ? D[3] : c[3] + D[3] * (1 - c[3]);
                for (int i = 0; i < 4; i++) d[x * 4 + i] = toByte(r[i]);
            }
        }
    }
    dst.lock.reset();
    src.lock.reset();
    cov.lock.reset();
    resumeMain();
}

}  // namespace ptb
