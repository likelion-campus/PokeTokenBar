#ifndef CWINSHIM_H
#define CWINSHIM_H

#include <stddef.h>
#include <stdint.h>

#include "CWinCrash.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the shim ABI version.
int ptb_shim_abi(void);

/// Decodes a PNG (WIC) into straight-alpha BGRA, 4 bytes per pixel, top-down. 0 on success, else an HRESULT-like
/// nonzero code. The caller frees `*bgra` with `ptb_free`.
int ptb_png_to_bgra(const uint8_t *png, size_t len, uint32_t *w, uint32_t *h, uint8_t **bgra);

void ptb_free(void *p);

/// Builds an HICON of `size` x `size` from straight-alpha BGRA: the transparent border is cropped to a square around
/// the artwork, then scaled nearest-neighbour. NULL on failure. The caller owns the icon (DestroyIcon).
void *ptb_icon_from_bgra(const uint8_t *bgra, uint32_t w, uint32_t h, uint32_t size);

/// Reads an HICON's color bitmap as straight-alpha BGRA, top-down. 0 on success; free `*bgra` with `ptb_free`.
int ptb_icon_to_bgra(void *hicon, uint32_t *w, uint32_t *h, uint8_t **bgra);

/// Copies a rectangle of the screen (virtual-screen coordinates) as opaque BGRA. 0 on success; free with `ptb_free`.
int ptb_capture_screen(int32_t x, int32_t y, uint32_t w, uint32_t h, uint8_t **bgra);

/// Writes straight-alpha BGRA as a PNG file (WIC). `path` is NUL-terminated UTF-16. 0 on success.
int ptb_png_write_bgra(const uint16_t *path, const uint8_t *bgra, uint32_t w, uint32_t h);

#ifdef __cplusplus
}
#endif

#endif
