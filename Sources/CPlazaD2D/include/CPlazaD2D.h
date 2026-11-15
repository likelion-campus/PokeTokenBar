#ifndef CPLAZAD2D_H
#define CPLAZAD2D_H

/*
 * CPlazaD2D: the Windows plaza's Direct2D / DirectWrite / WIC glue. Windows-only target (declared only in the Windows
 * branch of Package.swift). Plain C ABI; Swift imports it only inside Platform/Windows/Plaza/.
 *
 * Rules for every function here
 *  - No C++ exception crosses the boundary (the implementation throws nothing and catches nothing it did not make).
 *  - Fallible functions return an HRESULT as a signed int: 0 (S_OK) or a positive value is success, negative is failure.
 *    On failure ptb_plaza_last_error() has a one-line text for the CALLING thread. Nothing is swallowed.
 *  - No COM pointer is ever handed to the caller. Every COM object is created and released inside one call; later
 *    stages that keep objects (devices, surfaces) expose opaque handles with a create/release pair.
 *  - Memory returned by a function is malloc'ed here and freed only with ptb_plaza_free.
 *
 * Threads
 *  - ptb_com_init_sta: the process main thread, once, before anything else touches COM (WindowsApp.main).
 *  - Everything else: any thread. A thread that has no COM apartment gets the MTA the first time it calls in (and gives it
 *    back when the thread ends); a thread that already is an STA (the main thread) is used as it is.
 *  - Nothing here runs at launch except ptb_com_init_sta. Factories are created on first use (ptb_gfx_probe and the codecs),
 *    so a launch that never draws creates no Direct2D, DirectWrite or WIC object.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- errors and memory ------------------------------------------------------------------------------------------ */

/* The last failure text on the calling thread ("stage: 0xHRESULT"), or "" when none. Valid until the next call that fails. */
const char *ptb_plaza_last_error(void);
void ptb_plaza_free(void *p);

/* ---- COM apartment ---------------------------------------------------------------------------------------------- */

/* CoInitializeEx(COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) on the calling thread. Main thread only, first.
 * S_OK, S_FALSE (already STA) are success; RPC_E_CHANGED_MODE (0x80010106) means the thread was MTA already. */
int ptb_com_init_sta(void);

/* CoGetApartmentType for the calling thread: *type is APTTYPE (0 STA, 1 MTA, 2 NA, 3 main STA; the first STA of a process
 * is the main STA), *qualifier is APTTYPEQUALIFIER (1 = implicit MTA). CO_E_NOTINITIALIZED (0x800401F0) when none. */
int ptb_com_apartment(int *type, int *qualifier);

/* ---- availability ----------------------------------------------------------------------------------------------- */

typedef struct {
    int32_t wic;          /* HRESULT of creating the WIC imaging factory (0 = available) */
    int32_t d2d;          /* HRESULT of creating a multi-threaded Direct2D factory */
    int32_t dwrite;       /* HRESULT of creating a shared DirectWrite factory */
    uint32_t missingDlls; /* bit 0 d2d1, 1 dwrite, 2 d3d11, 3 dxgi, 4 dcomp, 5 windowscodecs: not loadable from System32 */
} PTBGfxProbe;

/* Loads the graphics DLLs from System32, creates each of the three factories once and releases it. Returns 0 when all
 * three exist, else the first failing HRESULT. Never crashes when a DLL is missing (the DLLs are delay-loaded). Any thread. */
int ptb_gfx_probe(PTBGfxProbe *out);

/* DirectWrite's verdict on a font file (UTF-16, NUL-terminated path): *supported 0/1, *faces the number of faces in it. */
int ptb_dwrite_analyze_font(const uint16_t *path, int *supported, uint32_t *faces);

/* ---- codecs (WIC) ----------------------------------------------------------------------------------------------- */

/* Decodes the first frame of PNG, JPEG, BMP, ... as 8-bit RGBA, STRAIGHT (not premultiplied) alpha, row 0 at the top,
 * tightly packed. No colour management, no gamma: the stored 8-bit values come back as they are (a 16-bit PNG is rounded).
 * Limits: 1..16384 per side. The caller frees *rgba with ptb_plaza_free. Any thread. */
int ptb_wic_decode_straight_rgba(const uint8_t *data, size_t len, uint32_t *w, uint32_t *h, uint8_t **rgba);

/* Encodes straight-alpha RGBA (tightly packed, row 0 at the top) as a PNG (32-bit, no gamma or colour chunks).
 * The caller frees *png with ptb_plaza_free. Any thread. */
int ptb_wic_encode_png_straight_rgba(const uint8_t *rgba, uint32_t w, uint32_t h, uint8_t **png, size_t *len);

/* WIC's own reading of a GIF, for cross-checking the app's GIF decoder (the app does not use WIC for GIF pixels: WIC
 * returns the sub-frames uncomposited). *count is the number of frames; delaysCs[i] (i < min(count, cap)) is the frame's
 * graphic-control delay in 1/100 s, or -1 when it has none. */
int ptb_wic_gif_delays(const uint8_t *data, size_t len, uint32_t *count, int32_t *delaysCs, uint32_t cap);

/* ---- scene renderer: device, surfaces, bitmaps, frames (stage 6 Task 4; scene_device.cpp) ----------------------------
 *
 * One Direct2D 1.1 device context over a Direct3D 11 device (hardware, or WARP when asked or when hardware creation
 * fails), from a SINGLE-THREADED Direct2D factory. Threads: everything below is MAIN THREAD ONLY, except
 * ptb_gfx_bitmap_release, which any thread may call (it queues; the next main-thread call releases).
 * Units are device pixels (D2D1_UNIT_MODE_PIXELS, 96 dpi), origin top-left, y down. No COM apartment is needed.
 * Device loss: a call that meets D2DERR_RECREATE_TARGET (0x8899000C) marks the device lost and returns that code; every
 * later frame call returns it too until ptb_gfx_device_recreate, which makes new D3D/D2D objects, drops every bitmap of the
 * old generation (their handles become stale) and bumps the generation; surfaces rebuild their own resources lazily. */

typedef struct PTBGfxDevice PTBGfxDevice;
typedef struct PTBGfxSurface PTBGfxSurface;

typedef struct {
    uint32_t generation;      /* starts at 1; +1 per ptb_gfx_device_recreate */
    uint32_t uploads;         /* bitmaps created over the device's life (all generations) */
    uint32_t liveBitmaps;     /* bitmaps alive now */
    uint64_t liveBitmapBytes; /* their pixel bytes (w * h * 4) */
    uint32_t losses;          /* losses met (real or injected) */
    uint32_t frames;          /* ptb_gfx_frame calls that reached EndDraw */
    int32_t isWarp;           /* 1 when the D3D device is WARP */
} PTBGfxDeviceStats;

/* NULL on failure (ptb_plaza_last_error says why). `adapter` (may be NULL) receives the adapter's description, UTF-16,
 * NUL-terminated, at most adapterCap units. forceWarp: 1 = WARP only; 0 = hardware, WARP when hardware fails. */
PTBGfxDevice *ptb_gfx_device_create(int forceWarp, uint16_t *adapter, uint32_t adapterCap);
int ptb_gfx_device_recreate(PTBGfxDevice *device, int forceWarp);
uint32_t ptb_gfx_device_generation(PTBGfxDevice *device);
void ptb_gfx_device_stats(PTBGfxDevice *device, PTBGfxDeviceStats *out);
/* Releases the device and everything it made. The caller has released every surface of it first. */
void ptb_gfx_device_release(PTBGfxDevice *device);

/* Premultiplied RGBA8 (row 0 top) as a device bitmap (DXGI_FORMAT_R8G8B8A8_UNORM; `opaque` = alpha ignored, for
 * noneSkipLast). Returns a handle > 0, or 0 on failure. */
uint32_t ptb_gfx_bitmap(PTBGfxDevice *device, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t stride, int opaque);
/* Any thread. A handle of an older generation is ignored (its bitmap is gone already). */
void ptb_gfx_bitmap_release(PTBGfxDevice *device, uint32_t handle, uint32_t generation);

/* An offscreen target: a frame bitmap (B8G8R8A8_UNORM, premultiplied) plus the scratch bitmaps the blend paths use. */
PTBGfxSurface *ptb_gfx_surface_offscreen(PTBGfxDevice *device, uint32_t w, uint32_t h);
int ptb_gfx_surface_resize(PTBGfxSurface *surface, uint32_t w, uint32_t h);
void ptb_gfx_surface_release(PTBGfxSurface *surface);

enum { PTB_CMD_BITMAP = 0, PTB_CMD_COLOR = 1 };
enum { PTB_BLEND_ALPHA = 0, PTB_BLEND_MULTIPLY = 1, PTB_BLEND_MULTIPLY_X2 = 2 };

/* One sprite (or panel layer). The local rect is the unit square, (0,0) top-left, y down; `m` maps it to target pixels:
 * x' = m[0] x + m[2] y + m[4], y' = m[1] x + m[3] y + m[5].
 *  - bitmap: the bitmap's texels src (x, y, w, h; texels, y down) fill the unit square, nearest-neighbour.
 *  - colour: the unit square filled with `color` (straight sRGB, alpha included).
 *  - opacity multiplies every channel (premultiplied), as SpriteKit's node alpha.
 *  - useTint (bitmap only): every colour channel is multiplied by tint (SpriteKit's colour blend: 1 - f + f * colour).
 *  - blend ALPHA: source over. MULTIPLY / MULTIPLY_X2 (SpriteKit's, measured): inside `region` the result is
 *    rgb = k * src.rgb * dst.rgb (clamped to 1; k = 1 or 2), alpha = src.alpha, premultiplied; outside it nothing changes.
 *  - region: integer target pixels (left, top, right, bottom) the tint / multiply paths may write: for MULTIPLY the
 *    sprite's exact pixel coverage (axis-aligned sprites only), for a tint the bounding box. Ignored by plain draws.
 *  - clip: integer target pixels (left, top, right, bottom), when hasClip. */
typedef struct {
    uint8_t kind, blend, hasClip, useTint;
    uint32_t bitmap;
    float src[4];
    float m[6];
    float opacity;
    float color[4];
    float tint[3];
    int32_t region[4];
    int32_t clip[4];
} PTBDrawCmd;

/* Clears the frame bitmap to `clear` (straight RGBA) and draws the commands in order. */
int ptb_gfx_frame(PTBGfxSurface *surface, const float clear[4], const PTBDrawCmd *cmds, uint32_t n);
/* The frame bitmap as RGBA8 premultiplied, row 0 top (`stride` bytes per row). */
int ptb_gfx_read(PTBGfxSurface *surface, uint8_t *rgba, uint32_t stride);
/* Waits until the device has executed everything submitted (timing on WARP; never on a frame path). */
int ptb_gfx_finish(PTBGfxDevice *device);

/* Test and selftest switches. kind 1: the next ptb_gfx_frame's EndDraw reports D2DERR_RECREATE_TARGET (the device is then
 * lost, as after a driver reset). */
void ptb_gfx_inject_fault(PTBGfxDevice *device, int kind);
/* Debug options (bit flags): 1 = linear instead of nearest sampling (fault injection). 0 = the default. */
void ptb_gfx_set_options(PTBGfxDevice *device, uint32_t flags);
/* The process's private bytes (PROCESS_MEMORY_COUNTERS_EX.PrivateUsage), for the frame-cost evidence; 0 on failure. */
uint64_t ptb_gfx_process_private_bytes(void);

/* ---- canvas (Task 8) -------------------------------------------------------------------------------------------- */

/* A Direct2D canvas over a WIC bitmap with CoreGraphics' conventions: origin bottom-left, y up, a CTM, a save/restore state
 * stack, premultiplied pixels (the bytes handed out are premultiplied RGBA, row 0 at the top). All state lives behind the handle.
 * One canvas is used by one thread at a time; canvases may be made and used on any thread. Void functions that fail count the
 * failure (ptb_canvas_failures) and leave the canvas as it was. Paths: ops[i] 0 move, 1 line, 2 cubic (point, control1,
 * control2), 3 close; coords holds six doubles per op (x, y, c1x, c1y, c2x, c2y). Blend: 0 normal, 1 multiply, 2 source-atop.
 * Join: 0 miter, 1 round. Cap: 0 butt, 1 round. Direct2D is created on first use (delay-loaded); check ptb_gfx_probe first. */
typedef struct PTBCanvas PTBCanvas;

int ptb_canvas_create(uint32_t w, uint32_t h, PTBCanvas **out);
void ptb_canvas_release(PTBCanvas *c);
uint32_t ptb_canvas_failures(PTBCanvas *c);
uint64_t ptb_canvas_bytes(PTBCanvas *c);   /* bytes the canvas holds: pixel surfaces plus uploaded images */
int ptb_canvas_drew_text(PTBCanvas *c);    /* 1 once any text was drawn into it (set by the text engine, Task 9) */

void ptb_canvas_save(PTBCanvas *c);
void ptb_canvas_restore(PTBCanvas *c);
void ptb_canvas_translate(PTBCanvas *c, double x, double y);
void ptb_canvas_scale(PTBCanvas *c, double x, double y);
void ptb_canvas_rotate(PTBCanvas *c, double radians);
void ptb_canvas_set_alpha(PTBCanvas *c, double a);
void ptb_canvas_set_blend(PTBCanvas *c, int mode);
void ptb_canvas_set_fill(PTBCanvas *c, double r, double g, double b, double a);    /* straight sRGB */
void ptb_canvas_set_stroke(PTBCanvas *c, double r, double g, double b, double a);
void ptb_canvas_set_line_width(PTBCanvas *c, double w);
void ptb_canvas_set_line_join(PTBCanvas *c, int join);
void ptb_canvas_set_shadow(PTBCanvas *c, int on, double dx, double dy, double blur, double r, double g, double b, double a);
void ptb_canvas_set_should_antialias(PTBCanvas *c, int on);
void ptb_canvas_set_allows_antialiasing(PTBCanvas *c, int on);
void ptb_canvas_set_should_smooth_fonts(PTBCanvas *c, int on);
void ptb_canvas_set_interpolation_none(PTBCanvas *c);
void ptb_canvas_set_text_stroke(PTBCanvas *c, int on);

void ptb_canvas_clip_rect(PTBCanvas *c, double x, double y, double w, double h);
int ptb_canvas_clip_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords);
void ptb_canvas_fill_rect(PTBCanvas *c, double x, double y, double w, double h);
void ptb_canvas_fill_ellipse(PTBCanvas *c, double x, double y, double w, double h);
void ptb_canvas_stroke_ellipse(PTBCanvas *c, double x, double y, double w, double h, double lineWidth);
int ptb_canvas_fill_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords);
int ptb_canvas_stroke_path(PTBCanvas *c, const uint8_t *ops, int n, const double *coords, double lineWidth, int cap);

/* Uploads premultiplied RGBA (row 0 at the top) once; `opaque` forces alpha 255 (a noneSkipLast bitmap). The id is valid for
 * this canvas for its lifetime. */
int ptb_canvas_upload_image(PTBCanvas *c, uint32_t w, uint32_t h, const uint8_t *rgba, int opaque, uint32_t *id);
int ptb_canvas_draw_image(PTBCanvas *c, uint32_t id, double x, double y, double w, double h);

/* Copies the canvas out as / overwrites it from premultiplied RGBA, row 0 at the top, w*h*4 bytes. */
int ptb_canvas_read_pixels(PTBCanvas *c, uint8_t *rgba);
int ptb_canvas_write_pixels(PTBCanvas *c, const uint8_t *rgba);

#ifdef __cplusplus
}
#endif

#include "CPlazaD2DText.h" /* the DirectWrite text engine (Task 9) */

#endif
