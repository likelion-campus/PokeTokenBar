#ifndef CPLAZAD2D_ACCESS_H
#define CPLAZAD2D_ACCESS_H

/* ---- the popover's overlay scroll lane as an MSAA scroll bar (ui_access.cpp) -------------------------------------------
 * The page scroller used to be the system's scroll bar, whose MSAA object (role scroll bar, a value, a range) told a screen
 * reader that the page scrolls. The overlay lane is a plain window, so it answers WM_GETOBJECT (OBJID_CLIENT) itself: an
 * IAccessible that wraps the system's own client object of the window (everything delegated: parent, location, state, hit test)
 * and says ROLE_SYSTEM_SCROLLBAR with a value in percent. The numbers are window properties the page sets
 * ("PTB.ScrollPos", "PTB.ScrollRange", "PTB.ScrollPage": pixels); the object keeps no state of its own, so it cannot outlive
 * what it describes. Main thread. */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The answer to WM_GETOBJECT for the lane (wParam, lParam as received): the LRESULT of the object, or 0 when the request is
 * not for OBJID_CLIENT or the object could not be made. */
int64_t ptb_scrollbar_get_object(void *hwnd, uint64_t wParam, int64_t lParam);

/* Selftest: asks the system for the window's accessible object as a client does (AccessibleObjectFromWindow) and reads its
 * role (get_accRole), state (get_accState) and value text (get_accValue, UTF-16, at most `cap` units, NUL-terminated).
 * Returns 0 on success, an HRESULT on failure. */
int ptb_scrollbar_probe(void *hwnd, int32_t *role, int32_t *state, uint16_t *value, uint32_t cap);

#ifdef __cplusplus
}
#endif

#endif
