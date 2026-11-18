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

/* ---- the plaza window: surface, frame clock, visibility helpers (stage 6 Task 5; window_*.cpp) ---------------------
 *
 * Window surface (D1): the frame bitmap of an offscreen surface, presented through a DirectComposition swap chain for the
 * window (CreateSwapChainForComposition: flip sequential, 2 buffers, B8G8R8A8, premultiplied alpha, frame-latency waitable
 * with maximum latency 1; DCompositionCreateDevice -> CreateTargetForHwnd(topmost FALSE) -> one visual). The window must have
 * WS_EX_NOREDIRECTIONBITMAP. ptb_gfx_frame draws into it as into any surface; ptb_gfx_window_present copies the frame into the
 * back buffer and presents with sync interval 1. After a device rebuild the swap chain and the composition are made again at
 * the next present. Commit runs once per swap chain, never per frame. Main thread only. Released with ptb_gfx_surface_release.
 * ptb_gfx_inject_fault kind 2: the next present reports DXGI_ERROR_DEVICE_REMOVED (0x887A0005) and the device is lost. */
PTBGfxSurface *ptb_gfx_surface_window(PTBGfxDevice *device, void *hwnd, uint32_t w, uint32_t h);
/* Frame and scratch bitmaps (made again at the next frame) and the swap chain's buffers (ResizeBuffers) to w x h pixels. */
int ptb_gfx_window_resize(PTBGfxSurface *surface, uint32_t w, uint32_t h);
/* 1 when a frame may be drawn and presented now: the frame-latency waitable is signalled (waited up to waitMs) or was taken
 * earlier and no present has used it yet. 0 when the GPU is still behind (the caller keeps the frame dirty). */
int ptb_gfx_window_acquire(PTBGfxSurface *surface, uint32_t waitMs);
/* 0 or DXGI_STATUS_OCCLUDED (0x087A0001, still a success) when presented; a device-removed / reset / hung code (the device is
 * then lost, rebuild it) or another failure (ptb_plaza_last_error says which stage). */
int ptb_gfx_window_present(PTBGfxSurface *surface);
typedef struct {
    uint32_t presents, occluded, acquireMisses, swapChainsMade, resizes, failures;
    uint32_t width, height;             /* the frame bitmap */
    uint32_t bufferWidth, bufferHeight; /* the swap chain's buffers (0 before the first one) */
} PTBGfxWindowStats;
void ptb_gfx_window_stats(PTBGfxSurface *surface, PTBGfxWindowStats *out);

/* Frame clock (D4): a thread that posts `message` (wParam 0) to `hwnd` once per frame while running, never two unanswered
 * (the window calls ptb_clock_ack when it handles one), and waits on an event with no timeout while not running (zero
 * wakeups). Frame source: IDXGIOutput::WaitForVBlank on the monitor given by ptb_clock_set_monitor (every N-th vblank,
 * N = max(1, floor(Hz / 60))), else a high-resolution waitable timer at 1/60 s (no output, a failing wait, or five waits in a
 * row shorter than 2 ms). The thread touches no app state. Create, set_monitor, set_running, ack, stats and destroy: main
 * thread. */
typedef struct PTBClock PTBClock;
typedef struct {
    uint32_t threadId;
    int32_t source;          /* 1 vblank, 2 timer */
    double refreshHz;        /* of the monitor's current mode, 0 when unknown */
    uint32_t divider;
    int32_t highResolutionTimer, running;
    uint64_t posted, waits, earlyReturns, fallbacks, parks;
    uint32_t samples;        /* intervals between posted ticks since the last reset (at most 1024 kept) */
    double p50Ms, p95Ms, p99Ms, maxMs;
} PTBClockStats;
PTBClock *ptb_clock_create(void *hwnd, uint32_t message);
/* The source for the monitor (HMONITOR): 1 vblank, 2 timer. forceTimer 1 skips the outputs. */
int ptb_clock_set_monitor(PTBClock *clock, void *monitor, int forceTimer);
void ptb_clock_set_running(PTBClock *clock, int on);
void ptb_clock_ack(PTBClock *clock);
void ptb_clock_stats(PTBClock *clock, PTBClockStats *out, int resetIntervals);
/* Stops the thread and waits for it (at most 2 s). 1 when it ended in time. */
int ptb_clock_destroy(PTBClock *clock);

/* Visibility (D5) and the window's geometry (D6). */
typedef struct {
    uint16_t name[32];       /* MONITORINFOEX.szDevice */
    int32_t monitor[4], work[4]; /* left, top, right, bottom; physical pixels */
    uint32_t dpi;            /* effective DPI (GetDpiForMonitor) */
    int32_t primary;
    uint64_t handle;         /* HMONITOR */
} PTBMonitor;
uint32_t ptb_monitors(PTBMonitor *out, uint32_t cap);
/* 1 when no pixel of the client area can be seen: off every monitor, or covered by the visible, uncloaked, unminimized,
 * non-layered top-level windows above it in z order (their DWM frame bounds). *above = the windows that took part. */
int ptb_window_covered(void *hwnd, uint32_t *above);
int ptb_window_cloaked(void *hwnd);                  /* DWMWA_CLOAKED != 0 */
int ptb_window_set_cloak(void *hwnd, int on);        /* DWMWA_CLOAK on a window of ours (selftest) */
/* WinEvent hooks (out of context, delivered through this thread's queue): the window's own cloak / uncloak (this process),
 * and, anywhere, a foreground change, a move/size end, a minimize start/end (rare events). Each posts `message` to hwnd with
 * wParam = the event (the system ones coalesced until ptb_window_hooks_ack). One window at a time. Returns hooks made. */
int ptb_window_hooks_install(void *hwnd, uint32_t message);
void ptb_window_hooks_ack(void);
void ptb_window_hooks_remove(void);
uint32_t ptb_window_hooks_live(void);
/* WTSRegisterSessionNotification(NOTIFY_FOR_THIS_SESSION) on (1) / off (0): WM_WTSSESSION_CHANGE for lock and disconnect. */
int ptb_window_session_notify(void *hwnd, int on);
/* stage 7 Task 22: this session now (WTSQuerySessionInformationW, WTSSessionInfoEx): *locked 1 at the lock screen,
 * *disconnected 1 when no console or remote connection is attached. Returns 1 when read, 0 (both 0) when not. */
int ptb_session_state(int *locked, int *disconnected);
/* fix/windows-pet-still: WTSINFOEX_LEVEL1's SessionFlags (0 LOCK, 1 UNLOCK, 0xFFFFFFFF unknown) and SessionState, raw (both
 * 0xFFFFFFFF when not read; returns 1 when read). */
int ptb_session_raw(uint32_t *sessionFlags, uint32_t *sessionState);
/* 1 when the input desktop is "Default" (the user's own), 0 when it is another or refuses this process (the secure desktop of
 * the lock screen or a UAC prompt), -1 when its name cannot be read. */
int ptb_input_desktop_default(void);
uint32_t ptb_window_dpi(void *hwnd);                  /* GetDpiForWindow, 96 when unknown */
/* The window rect (left, top, right, bottom relative to the client's origin) for a w x h client at `dpi`. */
int ptb_window_frame_for_client(uint32_t style, uint32_t exStyle, uint32_t dpi, int32_t w, int32_t h, int32_t out[4]);
/* DPI_AWARENESS of the window (0 unaware, 1 system, 2 per monitor; -1 unknown); *perMonitorV2 1 for PER_MONITOR_AWARE_V2. */
int ptb_window_dpi_awareness(void *hwnd, int *perMonitorV2);
uint32_t ptb_process_handle_count(void);
/* The client area as PrintWindow(PW_CLIENTONLY | PW_RENDERFULLCONTENT) draws it (composition content included), opaque
 * BGRA top-down; free *bgra with ptb_plaza_free (selftest evidence next to the screen capture). */
int ptb_window_print(void *hwnd, uint32_t *w, uint32_t *h, uint8_t **bgra);

/* ---- input (stage 6 Task 6) --------------------------------------------------------------------------------------- */

/* The plaza window's IME context: enabled 0 = ImmAssociateContextEx(hwnd, NULL, 0) (no composition, no VK_PROCESSKEY: a
 * game key stays a key), 1 = IACE_DEFAULT (the thread's default context back, for a text field). Returns 1 on success. */
int ptb_window_ime_set(void *hwnd, int enabled);
/* 1 when the window has an input context (ImmGetContext != NULL), 0 when it has none. */
int ptb_window_ime_has_context(void *hwnd);
/* 1 when the IME of this window's context is open (Hangul mode on a Korean layout); 0 when closed or no context. */
int ptb_window_ime_open(void *hwnd);
/* The characters a key press gives under `state` (256 bytes like GetKeyboardState; NULL = the thread's) and layout (NULL =
 * the thread's), as UTF-16 into out[cap]. `scan` carries 0xE000 for an extended key; a vk of 0 or 0xE5 (VK_PROCESSKEY) is
 * taken from the scan code. `flags` 0x4 leaves the keyboard's dead-key state alone (Windows 10 1607+). Returns the count
 * written, 0 for none, -1 for a dead key (the accent is in out[0]). */
int ptb_input_characters(uint32_t vk, uint32_t scan, void *hkl, const uint8_t *state, uint32_t flags, uint16_t *out, int cap);
/* LoadKeyboardLayoutW(klid, KLF_NOTELLSHELL): the handle of an installed layout without activating it (klid is UTF-16,
 * NUL-terminated, such as "00020409" for US International). NULL when it is not installed. */
void *ptb_input_load_layout(const uint16_t *klid);
/* GetKeyboardState into out[256] (this thread's queue state). Returns 1 on success. */
int ptb_input_keyboard_state(uint8_t *out);
/* SPI_GETWHEELSCROLLLINES (horizontal 0) or SPI_GETWHEELSCROLLCHARS (1): the system's lines per notch, 3 when unknown;
 * WHEEL_PAGESCROLL (a page per notch) comes back as 3 as well (the plaza has no page). */
uint32_t ptb_input_wheel_lines(int horizontal);
/* TrackMouseEvent(TME_LEAVE): WM_MOUSELEAVE once when the pointer leaves the client area. */
int ptb_window_track_leave(void *hwnd);

/* ---- plaza tooltips (Task 10, D18): one tooltips_class32 control owned by the window, a rectangle tool per hover text ---- */

/* The tooltip control (popup, TTS_ALWAYSTIP, never activates); NULL when it could not be made. */
void *ptb_tooltip_create(void *owner);
void ptb_tooltip_destroy(void *tooltip);
/* Replaces every tool: `count` rectangles (l, t, r, b in the owner's client pixels, 4 values each) with their UTF-16 texts (NUL-terminated).
 * Tool ids are index + 1. Returns how many tools the control took. */
int ptb_tooltip_set(void *tooltip, void *owner, const int32_t *rects, const uint16_t *const *texts, uint32_t count);
/* TTM_RELAYEVENT: the owner's mouse message (client coordinates in lParam) so the control can time its rest delay. */
void ptb_tooltip_relay(void *tooltip, void *owner, uint32_t message, uint64_t wParam, int64_t lParam);
int ptb_tooltip_count(void *tooltip);
/* TTM_GETTEXT of tool `index` (0-based) into `out` (UTF-16, capacity units); the length. */
int ptb_tooltip_text(void *tooltip, void *owner, uint32_t index, uint16_t *out, int capacity);
/* TTM_GETCURRENTTOOL: the tool whose text is showing (0-based), -1 when none. */
int ptb_tooltip_current(void *tooltip, void *owner);
int ptb_tooltip_visible(void *tooltip);
/* TTM_SETDELAYTIME (TTDT_INITIAL): the rest before the text shows, in ms (QA / selftest). */
void ptb_tooltip_set_delay(void *tooltip, int initialMs);

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

/* ---- clipboard (Task 12; clipboard.cpp) ------------------------------------------------------------------------------
 * Every writer opens the clipboard on a hidden message-only window of its own (a NULL owner makes SetClipboardData fail),
 * retries every 10 ms while another window has it open until `timeoutMs`, empties it, sets real data (never delayed
 * rendering) and closes it; the window is destroyed before the call returns. A GlobalAlloc block belongs to the system once
 * SetClipboardData succeeds and is freed here when it fails. On any failure the clipboard is left empty rather than half
 * written and the result is negative. Main thread or any thread (no message pump needed). */

/* The registered clipboard format "PNG" (what browsers, Office, Slack and chat apps read). */
unsigned ptb_clipboard_png_format(void);

/* Replaces the clipboard with the photo in two formats: the PNG bytes under "PNG" (straight alpha as PNG stores it) and the same
 * pixels as CF_DIBV5 (32-bit BI_BITFIELDS BGRA, bottom-up, STRAIGHT alpha). `rgba` is w*h*4 straight RGBA, row 0 at the top. */
int ptb_clipboard_set_image(const uint8_t *png, size_t pngLen, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t timeoutMs);

/* Replaces the clipboard with CF_UNICODETEXT (UTF-16, `count` code units, no terminator needed). */
int ptb_clipboard_set_text(const uint16_t *text, size_t count, uint32_t timeoutMs);

/* Copies one format's bytes out (tests and the selftest). Free with ptb_plaza_free. The app reads text with ptb_clipboard_read_text. */
int ptb_clipboard_read(unsigned format, uint8_t **bytes, size_t *len, uint32_t timeoutMs);

/* The chat field's paste (Task 11): CF_UNICODETEXT, at most `cap` UTF-16 units (no terminator) into out, whatever the clipboard
 * holds. Returns the units copied, 0 for no text on the clipboard, negative when it could not be opened. */
int ptb_clipboard_read_text(uint16_t *out, uint32_t cap, uint32_t timeoutMs);

/* Tests only: another thread opens the clipboard and keeps it open for `ms`; returns once it is held (negative: could not). */
int ptb_clipboard_hold(uint32_t ms);

#ifdef __cplusplus
}
#endif

#include "CPlazaD2DText.h" /* the DirectWrite text engine (Task 9) */
#include "CPlazaD2DChat.h" /* the chat field: native EDIT, IME, Korean IME probe (Task 11) */

#endif
