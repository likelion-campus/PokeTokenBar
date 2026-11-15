// The canvas: state stack, clips, primitives, images, pixels (see canvas.h). The shadow / blend compositor is canvas_composite.cpp,
// the C functions are canvas_api.cpp.
#include "canvas.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace ptb {
namespace {

const GUID kClsidImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kIidImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
const GUID kIidD2D1Factory = {0x06152247, 0x6f50, 0x465a, {0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07}};
// GUID_WICPixelFormat32bppPBGRA
const GUID kPixelFormatPBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x10}};

SRWLOCK gFactoryLock = SRWLOCK_INIT;
ID2D1Factory *gFactory = nullptr;  // process lifetime; one multi-threaded factory

// The process's multi-threaded Direct2D factory (AddRef'ed into `out`).
int sharedFactory(Ref<ID2D1Factory> &out) {
    AcquireSRWLockExclusive(&gFactoryLock);
    HRESULT hr = S_OK;
    if (!gFactory) {
        if (!LoadLibraryExW(L"d2d1.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
            hr = HRESULT_FROM_WIN32(GetLastError());
        } else {
            hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, kIidD2D1Factory, nullptr,
                                   reinterpret_cast<void **>(&gFactory));
            if (FAILED(hr)) gFactory = nullptr;
        }
    }
    if (SUCCEEDED(hr)) {
        gFactory->AddRef();
        out.p = gFactory;
    }
    ReleaseSRWLockExclusive(&gFactoryLock);
    return SUCCEEDED(hr) ? 0 : fail("D2D1CreateFactory", hr);
}

D2D1_COLOR_F color(const Rgba &c) {
    auto clamp = [](double v) { return static_cast<float>(v < 0 ? 0 : (v > 1 ? 1 : v)); };
    return D2D1_COLOR_F{clamp(c.r), clamp(c.g), clamp(c.b), clamp(c.a)};
}

}  // namespace

// ---------------------------------------------------------------------------------------------------------------------------
// Creation

int Canvas::init() {
    int code = sharedFactory(factory);
    if (code != 0) return code;
    HRESULT hr = ensureCom();
    if (FAILED(hr)) return fail("COM init", hr);
    hr = CoCreateInstance(kClsidImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kIidImagingFactory,
                          reinterpret_cast<void **>(wicFactory.out()));
    if (FAILED(hr)) return fail("WIC factory", hr);
    code = makeSurface(main);
    if (code != 0) return code;
    main.rt->BeginDraw();
    main.rt->Clear(D2D1_COLOR_F{0, 0, 0, 0});
    return 0;
}

Canvas::~Canvas() {
    // The main surface is mid-draw; a target must end its draw before it is released.
    if (main.rt) {
        for (size_t i = clips.size(); i > 0; i--) popClip(main, clips[i - 1]);
        main.rt->EndDraw();
    }
}

int Canvas::makeSurface(Surface &s) {
    HRESULT hr = wicFactory->CreateBitmap(width, height, kPixelFormatPBGRA, WICBitmapCacheOnDemand, s.wic.out());
    if (FAILED(hr)) return fail("CreateBitmap", hr);
    D2D1_RENDER_TARGET_PROPERTIES props = {};
    props.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
    props.pixelFormat.format = DXGI_FORMAT_UNKNOWN;
    props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_UNKNOWN;
    props.dpiX = 96.0f;
    props.dpiY = 96.0f;
    props.usage = D2D1_RENDER_TARGET_USAGE_NONE;
    props.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;
    hr = factory->CreateWicBitmapRenderTarget(s.wic.get(), props, s.rt.out());
    if (FAILED(hr)) return fail("CreateWicBitmapRenderTarget", hr);
    s.rt->SetDpi(96.0f, 96.0f);
    const D2D1_COLOR_F black = {0, 0, 0, 1};
    hr = s.rt->CreateSolidColorBrush(black, s.brush.out());
    if (FAILED(hr)) return fail("CreateSolidColorBrush", hr);
    return 0;
}

void Canvas::note(const char *stage, HRESULT hr) {
    failures++;
    fail(stage, hr);
}

uint64_t Canvas::bytesAllocated() const {
    uint64_t total = static_cast<uint64_t>(width) * height * 4;
    if (scratch.wic) total += static_cast<uint64_t>(width) * height * 4;
    if (mask.wic) total += static_cast<uint64_t>(width) * height * 4;
    for (const Image &i : images) total += i.bgra.size();
    return total;
}

// ---------------------------------------------------------------------------------------------------------------------------
// State

void Canvas::save() {
    st.clipBase = clips.size();
    saved.push_back(st);
}

void Canvas::restore() {
    if (saved.empty()) return;  // CoreGraphics ignores an unbalanced restore
    const State previous = saved.back();
    saved.pop_back();
    while (clips.size() > previous.clipBase) {
        popClip(main, clips.back());
        clips.pop_back();
        clipGeneration++;
    }
    st = previous;
}

void Canvas::translate(double x, double y) { st.ctm = concat(Affine{1, 0, 0, 1, x, y}, st.ctm); }
void Canvas::scale(double x, double y) { st.ctm = concat(Affine{x, 0, 0, y, 0, 0}, st.ctm); }
void Canvas::rotate(double radians) {
    const double c = std::cos(radians), s = std::sin(radians);
    st.ctm = concat(Affine{c, s, -s, c, 0, 0}, st.ctm);
}

void Canvas::prepare(Surface &s) {
    const D2D1_MATRIX_3X2_F m = matrix(device());
    s.rt->SetTransform(&m);
    s.rt->SetAntialiasMode(aliased() ? D2D1_ANTIALIAS_MODE_ALIASED : D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
}

void Canvas::setBrush(Surface &surface, const Rgba &c, float opacity) {
    const D2D1_COLOR_F f = color(c);
    surface.brush->SetColor(&f);
    surface.brush->SetOpacity(opacity);
}

ID2D1StrokeStyle *Canvas::strokeStyle(int join, int cap) {
    Ref<ID2D1StrokeStyle> &slot = styles[join == kJoinRound ? 1 : 0][cap == kCapRound ? 1 : 0];
    if (!slot) {
        D2D1_STROKE_STYLE_PROPERTIES p = {};
        p.startCap = p.endCap = p.dashCap = (cap == kCapRound ? D2D1_CAP_STYLE_ROUND : D2D1_CAP_STYLE_FLAT);
        p.lineJoin = (join == kJoinRound ? D2D1_LINE_JOIN_ROUND : D2D1_LINE_JOIN_MITER_OR_BEVEL);
        p.miterLimit = 10.0f;  // CoreGraphics' default
        p.dashStyle = D2D1_DASH_STYLE_SOLID;
        p.dashOffset = 0;
        const HRESULT hr = factory->CreateStrokeStyle(p, nullptr, 0, slot.out());
        if (FAILED(hr)) { note("CreateStrokeStyle", hr); return nullptr; }
    }
    return slot.get();
}

// ---------------------------------------------------------------------------------------------------------------------------
// Clips (device space; the stack is replayed on the mask surface and after a pixel read)

void Canvas::pushClip(Surface &s, const Clip &c) {
    const D2D1_MATRIX_3X2_F identity = D2D1::Matrix3x2F::Identity();
    s.rt->SetTransform(&identity);
    const D2D1_ANTIALIAS_MODE mode = c.aliased ? D2D1_ANTIALIAS_MODE_ALIASED : D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
    if (c.axis) {
        s.rt->PushAxisAlignedClip(c.rect, mode);
        return;
    }
    D2D1_LAYER_PARAMETERS lp = {};
    lp.contentBounds = D2D1_RECT_F{-FLT_MAX, -FLT_MAX, FLT_MAX, FLT_MAX};
    lp.geometricMask = c.geometry.get();
    lp.maskAntialiasMode = mode;
    lp.maskTransform = identity;
    lp.opacity = 1.0f;
    lp.opacityBrush = nullptr;
    lp.layerOptions = D2D1_LAYER_OPTIONS_NONE;
    s.rt->PushLayer(lp, nullptr);
}

void Canvas::popClip(Surface &s, const Clip &c) {
    if (c.axis) s.rt->PopAxisAlignedClip();
    else s.rt->PopLayer();
}

void Canvas::clipRect(double x, double y, double w, double h) {
    const Affine m = device();
    Clip c;
    c.aliased = aliased();
    const bool straight = std::fabs(m.b) < 1e-9 && std::fabs(m.c) < 1e-9;
    const bool quarter = std::fabs(m.a) < 1e-9 && std::fabs(m.d) < 1e-9;
    const double xs[4] = {x, x + w, x + w, x}, ys[4] = {y, y, y + h, y + h};
    double px[4], py[4];
    for (int i = 0; i < 4; i++) {
        px[i] = m.a * xs[i] + m.c * ys[i] + m.tx;
        py[i] = m.b * xs[i] + m.d * ys[i] + m.ty;
    }
    if (straight || quarter) {
        c.axis = true;
        c.rect.left = static_cast<float>(*std::min_element(px, px + 4));
        c.rect.right = static_cast<float>(*std::max_element(px, px + 4));
        c.rect.top = static_cast<float>(*std::min_element(py, py + 4));
        c.rect.bottom = static_cast<float>(*std::max_element(py, py + 4));
    } else {
        const uint8_t ops[5] = {0, 1, 1, 1, 3};
        double coords[30] = {};
        for (int i = 0; i < 4; i++) { coords[i * 6] = px[i]; coords[i * 6 + 1] = py[i]; }
        Ref<ID2D1PathGeometry> g;
        if (makeGeometry(ops, 5, coords, nullptr, g) != 0) { failures++; return; }
        c.geometry.p = g.p;
        g.p->AddRef();
    }
    pushClip(main, c);
    clips.push_back(c);
    clipGeneration++;
}

int Canvas::clipPath(const uint8_t *ops, int n, const double *coords) {
    const Affine m = device();
    Clip c;
    c.aliased = aliased();
    Ref<ID2D1PathGeometry> g;
    const int code = makeGeometry(ops, n, coords, &m, g);
    if (code != 0) { failures++; return code; }
    c.geometry.p = g.p;
    g.p->AddRef();
    pushClip(main, c);
    clips.push_back(c);
    clipGeneration++;
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
// Geometry from path ops

int Canvas::makeGeometry(const uint8_t *ops, int n, const double *coords, const Affine *xf, Ref<ID2D1PathGeometry> &out) {
    HRESULT hr = factory->CreatePathGeometry(out.out());
    if (FAILED(hr)) return fail("CreatePathGeometry", hr);
    Ref<ID2D1GeometrySink> sink;
    hr = out->Open(sink.out());
    if (FAILED(hr)) return fail("GeometryOpen", hr);
    sink->SetFillMode(D2D1_FILL_MODE_WINDING);  // CoreGraphics' fillPath is non-zero winding; Direct2D's default is alternate
    auto P = [&](double x, double y) {
        if (xf) {
            return D2D1_POINT_2F{static_cast<float>(xf->a * x + xf->c * y + xf->tx), static_cast<float>(xf->b * x + xf->d * y + xf->ty)};
        }
        return D2D1_POINT_2F{static_cast<float>(x), static_cast<float>(y)};
    };
    bool started = false, hasStart = false;
    D2D1_POINT_2F start{}, cur{};
    auto begin = [&]() {
        if (!started) {
            sink->BeginFigure(cur, D2D1_FIGURE_BEGIN_FILLED);
            started = true;
        }
    };
    for (int i = 0; i < n; i++) {
        const double *v = coords + 6 * i;
        switch (ops[i]) {
        case 0:  // move: the figure begins at its first segment (an empty figure is not made)
            if (started) { sink->EndFigure(D2D1_FIGURE_END_OPEN); started = false; }
            start = cur = P(v[0], v[1]);
            hasStart = true;
            break;
        case 1: {
            const D2D1_POINT_2F p = P(v[0], v[1]);
            if (!hasStart) { start = cur = p; hasStart = true; break; }
            begin();
            sink->AddLine(p);
            cur = p;
            break;
        }
        case 2: {
            const D2D1_POINT_2F to = P(v[0], v[1]), c1 = P(v[2], v[3]), c2 = P(v[4], v[5]);
            if (!hasStart) { start = cur = to; hasStart = true; break; }
            if (to.x == cur.x && to.y == cur.y && c1.x == cur.x && c1.y == cur.y && c2.x == cur.x && c2.y == cur.y) break;  // a zero curve
            begin();
            const D2D1_BEZIER_SEGMENT seg = {c1, c2, to};
            sink->AddBezier(seg);
            cur = to;
            break;
        }
        default:  // close: the next segment starts again at the figure's start (CoreGraphics' current point)
            if (started) { sink->EndFigure(D2D1_FIGURE_END_CLOSED); started = false; }
            cur = start;
            break;
        }
    }
    if (started) sink->EndFigure(D2D1_FIGURE_END_OPEN);
    hr = sink->Close();
    if (FAILED(hr)) return fail("GeometryClose", hr);
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
// Drawing

void Canvas::fillRect(double x, double y, double w, double h) {
    const D2D1_RECT_F r = {static_cast<float>(std::min(x, x + w)), static_cast<float>(std::min(y, y + h)),
                           static_cast<float>(std::max(x, x + w)), static_cast<float>(std::max(y, y + h))};
    const Rgba c = st.fill;
    paint([&](Surface &s, float opacity) {
        setBrush(s, c, opacity);
        s.rt->FillRectangle(r, s.brush.get());
    });
}

static D2D1_ELLIPSE ellipseIn(double x, double y, double w, double h) {
    const double nx = std::min(x, x + w), ny = std::min(y, y + h), aw = std::fabs(w), ah = std::fabs(h);
    return D2D1_ELLIPSE{D2D1_POINT_2F{static_cast<float>(nx + aw / 2), static_cast<float>(ny + ah / 2)},
                        static_cast<float>(aw / 2), static_cast<float>(ah / 2)};
}

void Canvas::fillEllipse(double x, double y, double w, double h) {
    const D2D1_ELLIPSE e = ellipseIn(x, y, w, h);
    const Rgba c = st.fill;
    paint([&](Surface &s, float opacity) {
        setBrush(s, c, opacity);
        s.rt->FillEllipse(e, s.brush.get());
    });
}

void Canvas::strokeEllipse(double x, double y, double w, double h, double lineWidth) {
    const D2D1_ELLIPSE e = ellipseIn(x, y, w, h);
    const Rgba c = st.stroke;
    ID2D1StrokeStyle *style = strokeStyle(st.join, kCapButt);
    paint([&](Surface &s, float opacity) {
        setBrush(s, c, opacity);
        s.rt->DrawEllipse(e, s.brush.get(), static_cast<float>(lineWidth), style);
    });
}

int Canvas::fillPath(const uint8_t *ops, int n, const double *coords) {
    Ref<ID2D1PathGeometry> g;
    const int code = makeGeometry(ops, n, coords, nullptr, g);
    if (code != 0) { failures++; return code; }
    const Rgba c = st.fill;
    paint([&](Surface &s, float opacity) {
        setBrush(s, c, opacity);
        s.rt->FillGeometry(g.get(), s.brush.get(), nullptr);
    });
    return 0;
}

int Canvas::strokePath(const uint8_t *ops, int n, const double *coords, double lineWidth, int cap) {
    Ref<ID2D1PathGeometry> g;
    const int code = makeGeometry(ops, n, coords, nullptr, g);
    if (code != 0) { failures++; return code; }
    const Rgba c = st.stroke;
    ID2D1StrokeStyle *style = strokeStyle(st.join, cap);
    paint([&](Surface &s, float opacity) {
        setBrush(s, c, opacity);
        s.rt->DrawGeometry(g.get(), s.brush.get(), static_cast<float>(lineWidth), style);
    });
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
// Images

int Canvas::uploadImage(uint32_t w, uint32_t h, const uint8_t *rgba, bool opaque, uint32_t *id) {
    if (w == 0 || h == 0 || !rgba) return fail("uploadImage", E_INVALIDARG);
    Image img;
    img.w = w;
    img.h = h;
    img.bgra.resize(static_cast<size_t>(w) * h * 4);
    const size_t count = static_cast<size_t>(w) * h;
    for (size_t i = 0; i < count; i++) {
        img.bgra[i * 4 + 0] = rgba[i * 4 + 2];
        img.bgra[i * 4 + 1] = rgba[i * 4 + 1];
        img.bgra[i * 4 + 2] = rgba[i * 4 + 0];
        img.bgra[i * 4 + 3] = opaque ? 255 : rgba[i * 4 + 3];
    }
    images.push_back(std::move(img));
    *id = static_cast<uint32_t>(images.size() - 1);
    return 0;
}

ID2D1Bitmap *Canvas::bitmapFor(Surface &s, uint32_t id) {
    if (id >= images.size()) return nullptr;
    if (s.bitmaps.size() <= id) s.bitmaps.resize(id + 1);
    if (!s.bitmaps[id]) {
        const Image &img = images[id];
        D2D1_BITMAP_PROPERTIES props = {};
        props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
        props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
        props.dpiX = 96.0f;
        props.dpiY = 96.0f;
        const HRESULT hr = s.rt->CreateBitmap(D2D1_SIZE_U{img.w, img.h}, img.bgra.data(), img.w * 4, props, s.bitmaps[id].out());
        if (FAILED(hr)) { note("CreateBitmap(image)", hr); return nullptr; }
    }
    return s.bitmaps[id].get();
}

int Canvas::drawImage(uint32_t id, double x, double y, double w, double h) {
    if (id >= images.size()) return fail("drawImage", E_INVALIDARG);
    const double nx = std::min(x, x + w), ny = std::min(y, y + h), aw = std::fabs(w), ah = std::fabs(h);
    const D2D1_RECT_F dst = {static_cast<float>(nx), static_cast<float>(ny), static_cast<float>(nx + aw), static_cast<float>(ny + ah)};
    const bool nearest = st.interpolationNone;
    // The image is upright in USER space (y up): un-flip about its own rect before the CTM and the canvas flip.
    const Affine unflip = {1, 0, 0, -1, 0, 2 * ny + ah};
    const Affine total = concat(concat(unflip, st.ctm), Affine{1, 0, 0, -1, 0, static_cast<double>(height)});
    paint([&](Surface &s, float opacity) {
        ID2D1Bitmap *bitmap = bitmapFor(s, id);
        if (!bitmap) return;
        const D2D1_MATRIX_3X2_F m = matrix(total);
        s.rt->SetTransform(&m);
        s.rt->DrawBitmap(bitmap, dst, opacity,
                         nearest ? D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR : D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, nullptr);
    });
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------------------
// Pixels: the main surface is ended (its clips popped) while the WIC bitmap is read or written, then drawing resumes.

int Canvas::suspendMain() {
    for (size_t i = clips.size(); i > 0; i--) popClip(main, clips[i - 1]);
    const HRESULT hr = main.rt->EndDraw();
    if (FAILED(hr)) { fail("EndDraw", hr); return static_cast<int>(hr); }
    return 0;
}

void Canvas::resumeMain() {
    main.rt->BeginDraw();
    for (const Clip &c : clips) pushClip(main, c);
}

int Canvas::readPixels(uint8_t *out) {
    const int code = suspendMain();
    int result = code;
    if (code == 0) {
        Ref<IWICBitmapLock> lock;
        const WICRect rect = {0, 0, static_cast<INT>(width), static_cast<INT>(height)};
        HRESULT hr = main.wic->Lock(&rect, WICBitmapLockRead, lock.out());
        UINT stride = 0, size = 0;
        BYTE *data = nullptr;
        if (SUCCEEDED(hr)) hr = lock->GetStride(&stride);
        if (SUCCEEDED(hr)) hr = lock->GetDataPointer(&size, &data);
        if (FAILED(hr)) {
            result = fail("read pixels", hr);
        } else {
            for (uint32_t y = 0; y < height; y++) {
                const uint8_t *row = data + static_cast<size_t>(y) * stride;
                uint8_t *dst = out + static_cast<size_t>(y) * width * 4;
                for (uint32_t x = 0; x < width; x++) {
                    dst[x * 4 + 0] = row[x * 4 + 2];
                    dst[x * 4 + 1] = row[x * 4 + 1];
                    dst[x * 4 + 2] = row[x * 4 + 0];
                    dst[x * 4 + 3] = row[x * 4 + 3];
                }
            }
        }
    }
    resumeMain();
    return result;
}

int Canvas::writePixels(const uint8_t *in) {
    const int code = suspendMain();
    int result = code;
    if (code == 0) {
        Ref<IWICBitmapLock> lock;
        const WICRect rect = {0, 0, static_cast<INT>(width), static_cast<INT>(height)};
        HRESULT hr = main.wic->Lock(&rect, WICBitmapLockWrite, lock.out());
        UINT stride = 0, size = 0;
        BYTE *data = nullptr;
        if (SUCCEEDED(hr)) hr = lock->GetStride(&stride);
        if (SUCCEEDED(hr)) hr = lock->GetDataPointer(&size, &data);
        if (FAILED(hr)) {
            result = fail("write pixels", hr);
        } else {
            for (uint32_t y = 0; y < height; y++) {
                uint8_t *row = data + static_cast<size_t>(y) * stride;
                const uint8_t *src = in + static_cast<size_t>(y) * width * 4;
                for (uint32_t x = 0; x < width; x++) {
                    row[x * 4 + 0] = src[x * 4 + 2];
                    row[x * 4 + 1] = src[x * 4 + 1];
                    row[x * 4 + 2] = src[x * 4 + 0];
                    row[x * 4 + 3] = src[x * 4 + 3];
                }
            }
        }
    }
    resumeMain();
    return result;
}

}  // namespace ptb
