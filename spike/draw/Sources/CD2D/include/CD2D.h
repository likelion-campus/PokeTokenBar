#ifndef CD2D_H
#define CD2D_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PTBCanvas PTBCanvas;
/// hardware 0 = WARP software device (headless CI), 1 = the GPU. Returns NULL on failure; see ptb_last_error.
PTBCanvas *ptb_canvas_create(int width, int height, int hardware);
const char *ptb_last_error(void);
/// Adds a font file to the canvas's private collection (not installed system-wide). 1 on success.
int ptb_add_font(PTBCanvas *c, const char *utf8Path);
/// Loads a PNG. Returns a bitmap id >= 0, or -1.
int ptb_load_png(PTBCanvas *c, const char *utf8Path);
void ptb_begin(PTBCanvas *c, float r, float g, float b);
/// Nearest-neighbour blit of a source rect to a destination rect.
void ptb_draw_bitmap(PTBCanvas *c, int bitmap, float sx, float sy, float sw, float sh,
                     float dx, float dy, float dw, float dh, float alpha, int flipX);
void ptb_fill_round_rect(PTBCanvas *c, float x, float y, float w, float h, float radius, float r, float g, float b, float a);
/// family is looked up in the private collection first, then the system. colour = allow colour glyphs (emoji).
void ptb_draw_text(PTBCanvas *c, const char *utf8Text, const char *utf8Family, float size, int bold,
                   float x, float y, float r, float g, float b, int aliased, int colour);
/// Ends drawing and multiplies the rect by the colour (the plaza's daylight tint).
int ptb_end_with_multiply(PTBCanvas *c, float x, float y, float w, float h, float r, float g, float b);
int ptb_save_png(PTBCanvas *c, const char *utf8Path);
void ptb_canvas_free(PTBCanvas *c);
#ifdef __cplusplus
}
#endif
#endif
