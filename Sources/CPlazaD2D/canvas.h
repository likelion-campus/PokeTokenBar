// The plaza canvas on Direct2D over a WIC bitmap (stage 6, Task 8). INTERNAL header: C++ only, not part of the C ABI
// (CPlazaD2D.h has the C functions Swift calls). Later C++ in this target (the DirectWrite text engine, Task 9) includes this
// header to draw INTO a canvas through `Canvas::paint`, so shadow, blend, global alpha, clips and the antialias flags apply to
// its output exactly as they do to a rectangle.
//
// Conventions (CoreGraphics', as `CGPlazaCanvas`): user space has its origin at the bottom-left and y up; the canvas applies one
// flip (device y = height - y) after the CTM. Pixels are premultiplied; the WIC bitmap is 32bpp PBGRA (row 0 at the top) and the
// C functions hand out premultiplied RGBA.
#ifndef CPLAZAD2D_CANVAS_H
#define CPLAZAD2D_CANVAS_H

#ifndef NOMINMAX
#define NOMINMAX  // windows.h must not turn std::min / std::max into macros
#endif
#include "internal.h"

#include <d2d1.h>
#include <d2d1helper.h>
#include <wincodec.h>

#include <cfloat>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

namespace ptb {

/// A movable COM reference.
template <class T> class Ref {
public:
    Ref() = default;
    Ref(const Ref &o) : p(o.p) { if (p) p->AddRef(); }
    Ref(Ref &&o) noexcept : p(o.p) { o.p = nullptr; }
    Ref &operator=(Ref o) { std::swap(p, o.p); return *this; }
    ~Ref() { if (p) p->Release(); }
    T **out() { reset(); return &p; }
    void reset() { if (p) { p->Release(); p = nullptr; } }
    T *operator->() const { return p; }
    T *get() const { return p; }
    explicit operator bool() const { return p != nullptr; }
    T *p = nullptr;
};

/// CGAffineTransform's meaning: x' = a x + c y + tx, y' = b x + d y + ty (the same numbers D2D1_MATRIX_3X2_F holds).
struct Affine {
    double a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;
};

/// The transform that applies `first`, then `then`.
inline Affine concat(const Affine &first, const Affine &then) {
    Affine r;
    r.a = first.a * then.a + first.b * then.c;
    r.b = first.a * then.b + first.b * then.d;
    r.c = first.c * then.a + first.d * then.c;
    r.d = first.c * then.b + first.d * then.d;
    r.tx = first.tx * then.a + first.ty * then.c + then.tx;
    r.ty = first.tx * then.b + first.ty * then.d + then.ty;
    return r;
}

struct Rgba {  // sRGB components, straight alpha
    double r = 0, g = 0, b = 0, a = 1;
};

enum BlendMode { kBlendNormal = 0, kBlendMultiply = 1, kBlendSourceAtop = 2 };
enum LineJoin { kJoinMiter = 0, kJoinRound = 1 };
enum LineCap { kCapButt = 0, kCapRound = 1 };

/// The CoreGraphics graphics state: everything `saveState` keeps and `restoreState` brings back.
struct State {
    Affine ctm;
    double alpha = 1;
    int blend = kBlendNormal;
    Rgba fill{0, 0, 0, 1}, stroke{0, 0, 0, 1};
    double lineWidth = 1;
    int join = kJoinMiter;
    bool hasShadow = false;
    double shadowDx = 0, shadowDy = 0, shadowBlur = 0;  // device pixels, y up (CG's setShadow offset)
    Rgba shadowColor{0, 0, 0, 0};
    bool shouldAntialias = true, allowsAntialiasing = true;
    bool shouldSmoothFonts = true;  // recorded for the text engine; no effect on shapes
    bool interpolationNone = false;
    bool textStroke = false;        // CG's text drawing mode: false = fill, true = stroke
    size_t clipBase = 0;            // size of the clip stack when this level was saved
};

/// One Direct2D target over a WIC bitmap. Each canvas has a main surface; a scratch and a mask surface are made the first time
/// a shadow or a non-normal blend needs them.
struct Surface {
    Ref<IWICBitmap> wic;
    Ref<ID2D1RenderTarget> rt;
    Ref<ID2D1SolidColorBrush> brush;
    std::vector<Ref<ID2D1Bitmap>> bitmaps;  // by image id, made on first use on this surface
};

struct Clip {
    bool axis = false;       // a device-space rectangle (PushAxisAlignedClip) or a geometry (PushLayer)
    D2D1_RECT_F rect{};
    Ref<ID2D1Geometry> geometry;  // device space
    bool aliased = false;
};

class Canvas {
public:
    /// What a paint body draws with. `opacity` is the global alpha and the body MUST multiply it into everything it draws on
    /// the main surface (brush->SetOpacity, DrawBitmap's opacity); the composite path passes 1 and applies alpha itself.
    /// The surface's transform (CTM then the flip) and antialias mode are set when the body runs; a body that needs another
    /// transform (an image's un-flip) sets it and need not restore it.
    using Paint = std::function<void(Surface &surface, float opacity)>;

    uint32_t width, height;
    State st;
    bool drewText = false;
    uint32_t failures = 0;  // draw calls that failed (the call is skipped); the text of the last is in ptb_plaza_last_error

    Canvas(uint32_t w, uint32_t h) : width(w), height(h) {}
    ~Canvas();
    int init();

    // ---- state (CoreGraphics' names)
    void save();
    void restore();
    void translate(double x, double y);
    void scale(double x, double y);
    void rotate(double radians);
    bool aliased() const { return !(st.shouldAntialias && st.allowsAntialiasing); }

    /// The total user → device transform: CTM, then the flip.
    Affine device() const { return concat(st.ctm, Affine{1, 0, 0, -1, 0, static_cast<double>(height)}); }
    static D2D1_MATRIX_3X2_F matrix(const Affine &m) {
        return D2D1::Matrix3x2F(static_cast<float>(m.a), static_cast<float>(m.b), static_cast<float>(m.c),
                                static_cast<float>(m.d), static_cast<float>(m.tx), static_cast<float>(m.ty));
    }

    // ---- clips
    void clipRect(double x, double y, double w, double h);
    /// `ops`: 0 move, 1 line, 2 cubic (to, c1, c2), 3 close; six doubles per op.
    int clipPath(const uint8_t *ops, int n, const double *coords);

    // ---- drawing
    /// Runs `body` so that the current blend, shadow and alpha apply to what it draws.
    void paint(const Paint &body);
    void fillRect(double x, double y, double w, double h);
    void fillEllipse(double x, double y, double w, double h);
    void strokeEllipse(double x, double y, double w, double h, double lineWidth);
    int fillPath(const uint8_t *ops, int n, const double *coords);
    int strokePath(const uint8_t *ops, int n, const double *coords, double lineWidth, int cap);
    int uploadImage(uint32_t w, uint32_t h, const uint8_t *rgbaPremultiplied, bool opaque, uint32_t *id);
    int drawImage(uint32_t id, double x, double y, double w, double h);

    // ---- pixels
    int readPixels(uint8_t *rgbaPremultiplied);
    int writePixels(const uint8_t *rgbaPremultiplied);
    uint64_t bytesAllocated() const;

    // ---- for text and other drawers
    ID2D1Factory *d2dFactory() const { return factory.get(); }
    Surface &mainSurface() { return main; }
    /// Fills `surface.brush` with `c` (straight sRGB) at `opacity`.
    static void setBrush(Surface &surface, const Rgba &c, float opacity);
    /// The stroke style for the current join and `cap`; cached per canvas.
    ID2D1StrokeStyle *strokeStyle(int join, int cap);

private:
    struct Image {
        uint32_t w = 0, h = 0;
        std::vector<uint8_t> bgra;  // premultiplied
    };

    Ref<ID2D1Factory> factory;
    Ref<IWICImagingFactory> wicFactory;
    Surface main, scratch, mask;
    std::vector<State> saved;
    std::vector<Clip> clips;
    uint32_t clipGeneration = 0, maskGeneration = 0xFFFFFFFFu;
    std::vector<Image> images;
    Ref<ID2D1StrokeStyle> styles[2][2];

    int makeSurface(Surface &s);
    void prepare(Surface &s);
    void pushClip(Surface &s, const Clip &c);
    void popClip(Surface &s, const Clip &c);
    int suspendMain();
    void resumeMain();
    int ensureAuxiliary();
    int renderMask();
    void composite();
    ID2D1Bitmap *bitmapFor(Surface &s, uint32_t id);
    int makeGeometry(const uint8_t *ops, int n, const double *coords, const Affine *transform, Ref<ID2D1PathGeometry> &out);
    void note(const char *stage, HRESULT hr);
};

}  // namespace ptb

#endif
