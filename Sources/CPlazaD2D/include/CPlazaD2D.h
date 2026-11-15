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

#ifdef __cplusplus
}
#endif

#endif
