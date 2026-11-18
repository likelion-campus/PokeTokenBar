#ifndef CPLAZAD2D_PAINT_H
#define CPLAZAD2D_PAINT_H

/* ---- the popover's antialiased shape painter (stage 7, visual polish K2; ui_paint.cpp) --------------------------------
 * GDI's RoundRect has no antialiasing, so every kit-drawn card, tile, pill and hover fill had jagged corners next to the
 * Direct2D-drawn parts. This draws rounded rectangles through a CPU Direct2D DC render target
 * (D2D1_RENDER_TARGET_TYPE_SOFTWARE: no GPU device, no swap chain, nothing between paints) bound to the DC of a paint in
 * progress, one bounded batch per call.
 *
 *  - Main thread only (the popover's). The target is created on the first call and kept for the process, so opening and
 *    closing pages creates no handles; it is recreated when Direct2D asks (D2DERR_RECREATE_TARGET).
 *  - Units are device pixels of the DC (dpi 96, no transform): the caller snaps strokes to whole pixels.
 *  - `x, y` are relative to (left, top) of the bounds; a shape is clipped to the bounds. A stroke is drawn INSIDE the
 *    rectangle (its outer edge is the rectangle), so the rectangle is what the shape covers.
 *  - Colours are 0xAARRGGBB, straight alpha; alpha 0 skips the fill or stroke. The result is blended over what the DC holds.
 *  - Fallible like the rest of the library: 0 is success, negative a failure (ptb_plaza_last_error). The caller falls back to
 *    GDI and logs once. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x, y, w, h;
    float radius;       /* corner radius; capped at half the shorter side; 0 is a plain rectangle */
    uint32_t fill;      /* 0xAARRGGBB */
    uint32_t stroke;    /* 0xAARRGGBB */
    float strokeWidth;  /* 0: no stroke */
} PTBPaintShape;

/* Draws `count` shapes in order into `hdc`, inside the bounds (left, top, right, bottom) in the DC's own coordinates. */
int ptb_paint_shapes(void *hdc, int32_t left, int32_t top, int32_t right, int32_t bottom, const PTBPaintShape *shapes, uint32_t count);

/* Batches drawn and failed since the process started (the selftest reads them). */
void ptb_paint_stats(uint64_t *drawn, uint64_t *failed);

#ifdef __cplusplus
}
#endif

#endif
