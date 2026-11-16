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

/// The common file dialogs (stage 7 Task 15): `save` 1 = save, 0 = open. Strings are NUL-terminated UTF-16; `title`,
/// `default_name` (save only), the one filter (`filter_name`, `filter_spec` like "*.json") and `default_ext` ("json") may be
/// NULL. The dialog is owned by `owner` (a window of this thread) and runs a modal loop on the calling STA thread. The chosen
/// file system path is written to `out` (UTF-16, NUL-terminated, at most `out_cap` units). Returns 0 chosen, 1 cancelled
/// (or closed by `ptb_file_dialog_close`), else an HRESULT (a negative value). It opens in Documents the first time and then
/// where the user last was.
int32_t ptb_file_dialog(void *owner, int32_t save, const uint16_t *title, const uint16_t *default_name,
                        const uint16_t *filter_name, const uint16_t *filter_spec, const uint16_t *default_ext,
                        uint16_t *out, uint32_t out_cap);

/// Closes the open file dialog as if the user cancelled (1), or does nothing (0). Same thread as the dialog.
int32_t ptb_file_dialog_close(void);

/// A task dialog (comctl32 v6, looked up when called) with custom buttons in order; `icon` 0 none, 1 warning, 2 error,
/// 3 information. `default_index` is the button Enter presses. Esc and the close box are allowed. `*chosen` is the index of
/// the pressed button, -1 for Esc or the close box. Returns 0, or an HRESULT when the dialog could not be shown.
int32_t ptb_task_dialog(void *owner, const uint16_t *window_title, const uint16_t *heading, const uint16_t *content,
                        int32_t icon, const uint16_t *const *buttons, int32_t count, int32_t default_index, int32_t *chosen);

/// The open task dialog's window, NULL when none.
void *ptb_task_dialog_window(void);

/// Sets the MSAA value (what a screen reader reads after the name) of a standard control, e.g. "100%" on a trackbar
/// whose position is not that number. 0 on success, else an HRESULT.
int32_t ptb_acc_set_value(void *hwnd, const uint16_t *text);

/// Reads the MSAA name and value of a window's client object (what a screen reader gets), UTF-16 NUL-terminated, either
/// buffer may be NULL. The selftest uses it. 0 on success, else an HRESULT.
int32_t ptb_acc_describe(void *hwnd, uint16_t *name, uint32_t name_cap, uint16_t *value, uint32_t value_cap);

#ifdef __cplusplus
}
#endif

#endif
