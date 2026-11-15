#ifndef CPLAZAD2D_CHAT_H
#define CPLAZAD2D_CHAT_H

/* ---- the plaza's chat field (stage 6 Task 11, D13) -------------------------------------------------------------------
 * A native one-line EDIT (ES_AUTOHSCROLL) in a small host window that is a child of the plaza window, over the composition
 * (DirectComposition with topmost FALSE puts the visual tree behind child windows). The host paints the bar colour, answers
 * WM_CTLCOLOREDIT and forwards EN_CHANGE; the EDIT is subclassed (SetWindowLongPtrW, user32 only) and every message it gets
 * goes to `proc` first. Main thread only. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Called for every message of the EDIT before the EDIT sees it, and with message PTB_CHAT_CHANGED when the text changed
 * (EN_CHANGE). *handled = 1: `result` is returned to Windows; 0: the EDIT's own procedure runs. */
#define PTB_CHAT_CHANGED 0x8060u
typedef int64_t (*PTBChatProc)(void *context, uint32_t message, uint64_t wParam, int64_t lParam, int *handled);

/* Makes the host (hidden) under `parent` and the EDIT in it. layered 1: the host is WS_EX_LAYERED (opaque), the fallback when a
 * plain child is not composed over a WS_EX_NOREDIRECTIONBITMAP parent. Returns the EDIT, NULL on failure (GetLastError). */
void *ptb_chat_edit_create(void *parent, int layered, PTBChatProc proc, void *context);
/* Destroys the host and the EDIT; the callback is not called afterwards. */
void ptb_chat_edit_destroy(void *edit);
/* The host window (the EDIT's parent). */
void *ptb_chat_edit_host(void *edit);
/* Places the host at (x, y, w, h) in the parent's client pixels and shows or hides it, never activating. */
int ptb_chat_edit_place(void *edit, int32_t x, int32_t y, int32_t w, int32_t h, int show);
/* The EDIT's own procedure for a message (call only from inside the callback). */
int64_t ptb_chat_edit_default(void *edit, uint32_t message, uint64_t wParam, int64_t lParam);
/* Text colour, background colour (0x00BBGGRR), the font (face, pixel height, quality as LOGFONT lfQuality) and the left/right
 * margins in pixels. Replaces the previous font and brush. Returns 1 on success. */
int ptb_chat_edit_style(void *edit, uint32_t text, uint32_t back, const uint16_t *face, int32_t pixelHeight, int32_t quality,
                        int32_t margin);
/* EM_SETCUEBANNER (shown while focused); 0 when the EDIT is not comctl32 v6 (no manifest, e.g. in XCTest). */
int ptb_chat_edit_cue(void *edit, const uint16_t *text);
/* AddFontResourceExW(path, FR_PRIVATE): fonts added (0 = failed). */
int ptb_chat_font_add(const uint16_t *path);
/* GetCaretPos in the EDIT's client pixels; 0 when this thread has no caret. */
int ptb_chat_caret(int32_t out[2]);
/* GetCaretBlinkTime (ms; INFINITE = 0xFFFFFFFF when blinking is off) and the window with this thread's caret (NULL when none). */
uint32_t ptb_chat_caret_blink_ms(void);
void *ptb_chat_caret_window(void);

/* ---- the IME of a window's input context (imm32) ---- */

/* ImmGetCompositionStringW(kind): 0x8 GCS_COMPSTR, 0x800 GCS_RESULTSTR into out (UTF-16 units, no NUL); the length in units,
 * -1 without a context. kind 0x80 GCS_CURSORPOS returns the caret's position in the composition. */
int ptb_ime_string(void *hwnd, uint32_t kind, uint16_t *out, int cap);
/* ImmNotifyIME(NI_COMPOSITIONSTR, cancel ? CPS_CANCEL : CPS_COMPLETE): 1 when the IME took it, 0 when not, -1 without a context. */
int ptb_ime_finish(void *hwnd, int cancel);
/* The composition window at (x, y) (CFS_POINT) and the candidate list next to the line (CFS_EXCLUDE: x, y, x + 1, y + lineHeight),
 * in the window's client pixels. 1 on success. */
int ptb_ime_place(void *hwnd, int32_t x, int32_t y, int32_t lineHeight);
/* Read back: out[0] composition style, out[1..2] its point, out[3] candidate style, out[4..5] its point, out[6..9] its area. */
int ptb_ime_windows(void *hwnd, int32_t out[10]);
/* out[0] conversion mode, out[1] sentence mode, out[2] open status of the window's context. 0 without a context. */
int ptb_ime_status(void *hwnd, uint32_t out[3]);
int ptb_ime_set_status(void *hwnd, int open, uint32_t conversion);
/* ImmSetCompositionStringW(SCS_SETSTR, text): what an IME would hold. 1 when it took it (only with an IME that supports it). */
int ptb_ime_set_composition(void *hwnd, const uint16_t *text, uint32_t len);

/* The Korean IME (a TSF text service). Writes a one-line report (UTF-16, NUL-terminated) into out. activate 1: enables it and
 * activates it for this process only (TF_IPPMF_FORPROCESS; CI only). Returns 1 when a Korean text service is the process's
 * keyboard profile afterwards (or, without activate, when one is installed), 0 when none is installed, -1 when TSF failed. */
int ptb_ime_korean(int activate, uint16_t *out, int cap);
/* Puts back the keyboard profile that was active before ptb_ime_korean(1). */
int ptb_ime_korean_restore(void);

/* The field's paste reads the clipboard's CF_UNICODETEXT with Task 12's ptb_clipboard_read (CPlazaD2D.h). */

#ifdef __cplusplus
}
#endif

#endif
