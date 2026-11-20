// The C functions of the plaza canvas (CPlazaD2D.h, "canvas" section). Thin: the state machine is ptb::Canvas.
#include "CPlazaD2D.h"
#include "canvas.h"

#include <new>

using ptb::Canvas;

static Canvas *C(PTBCanvas *c) { return reinterpret_cast<Canvas *>(c); }
static ptb::Rgba rgba(double r, double g, double b, double a) { return ptb::Rgba{r, g, b, a}; }

extern "C" {

int ptb_canvas_create(uint32_t w, uint32_t h, PTBCanvas **out) {
    if (!out) return ptb::fail("ptb_canvas_create", E_INVALIDARG);
    *out = nullptr;
    if (w == 0 || h == 0 || w > 16384 || h > 16384 || static_cast<uint64_t>(w) * h * 4 > (512ull << 20)) return ptb::fail("canvas size", E_INVALIDARG);
    Canvas *canvas = new (std::nothrow) Canvas(w, h);
    if (!canvas) return ptb::fail("canvas alloc", E_OUTOFMEMORY);
    const int code = canvas->init();
    if (code != 0) { delete canvas; return code; }
    *out = reinterpret_cast<PTBCanvas *>(canvas);
    return 0;
}

void ptb_canvas_release(PTBCanvas *c) { delete C(c); }
uint32_t ptb_canvas_failures(PTBCanvas *c) { return C(c)->failures; }
uint64_t ptb_canvas_bytes(PTBCanvas *c) { return C(c)->bytesAllocated(); }
int ptb_canvas_drew_text(PTBCanvas *c) { return C(c)->drewText ? 1 : 0; }

void ptb_canvas_save(PTBCanvas *c) { C(c)->save(); }
void ptb_canvas_restore(PTBCanvas *c) { C(c)->restore(); }
void ptb_canvas_translate(PTBCanvas *c, double x, double y) { C(c)->translate(x, y); }
void ptb_canvas_scale(PTBCanvas *c, double x, double y) { C(c)->scale(x, y); }
void ptb_canvas_rotate(PTBCanvas *c, double radians) { C(c)->rotate(radians); }
void ptb_canvas_set_alpha(PTBCanvas *c, double a) { C(c)->st.alpha = a < 0 ? 0 : (a > 1 ? 1 : a); }
void ptb_canvas_set_blend(PTBCanvas *c, int mode) { C(c)->st.blend = mode; }
void ptb_canvas_set_fill(PTBCanvas *c, double r, double g, double b, double a) { C(c)->st.fill = rgba(r, g, b, a); }
void ptb_canvas_set_stroke(PTBCanvas *c, double r, double g, double b, double a) { C(c)->st.stroke = rgba(r, g, b, a); }
void ptb_canvas_set_line_width(PTBCanvas *c, double w) { C(c)->st.lineWidth = w; }
void ptb_canvas_set_line_join(PTBCanvas *c, int join) { C(c)->st.join = join; }
void ptb_canvas_set_shadow(PTBCanvas *c, int on, double dx, double dy, double blur, double r, double g, double b, double a) {
    ptb::State &s = C(c)->st;
    s.hasShadow = on != 0;
    s.shadowDx = dx;
    s.shadowDy = dy;
    s.shadowBlur = blur;
    s.shadowColor = rgba(r, g, b, a);
}
void ptb_canvas_set_should_antialias(PTBCanvas *c, int on) { C(c)->st.shouldAntialias = on != 0; }
void ptb_canvas_set_allows_antialiasing(PTBCanvas *c, int on) { C(c)->st.allowsAntialiasing = on != 0; }
void ptb_canvas_set_should_smooth_fonts(PTBCanvas *c, int on) { C(c)->st.shouldSmoothFonts = on != 0; }
void ptb_canvas_set_interpolation_none(PTBCanvas *c) { C(c)->st.interpolationNone = true; }
void ptb_canvas_set_text_stroke(PTBCanvas *c, int on) { C(c)->st.textStroke = on != 0; }

void ptb_canvas_clip_rect(PTBCanvas *c, double x, double y, double w, double h) { C(c)->clipRect(x, y, w, h); }
int ptb_canvas_clip_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords) { return C(c)->clipPath(ops, n, coords); }
void ptb_canvas_fill_rect(PTBCanvas *c, double x, double y, double w, double h) { C(c)->fillRect(x, y, w, h); }
void ptb_canvas_fill_ellipse(PTBCanvas *c, double x, double y, double w, double h) { C(c)->fillEllipse(x, y, w, h); }
void ptb_canvas_stroke_ellipse(PTBCanvas *c, double x, double y, double w, double h, double lineWidth) { C(c)->strokeEllipse(x, y, w, h, lineWidth); }
int ptb_canvas_fill_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords) { return C(c)->fillPath(ops, n, coords); }
int ptb_canvas_stroke_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords, double lineWidth, int cap) {
    return C(c)->strokePath(ops, n, coords, lineWidth, cap);
}
int ptb_canvas_upload_image(PTBCanvas *c, uint32_t w, uint32_t h, const uint8_t *rgba, int opaque, uint32_t *id) {
    return C(c)->uploadImage(w, h, rgba, opaque != 0, id);
}
int ptb_canvas_draw_image(PTBCanvas *c, uint32_t id, double x, double y, double w, double h) { return C(c)->drawImage(id, x, y, w, h); }
int ptb_canvas_read_pixels(PTBCanvas *c, uint8_t *rgba) { return C(c)->readPixels(rgba); }
int ptb_canvas_write_pixels(PTBCanvas *c, const uint8_t *rgba) { return C(c)->writePixels(rgba); }

}  // extern "C"
