// The plaza window's hover texts (stage 6 Task 10, D18): one system tooltip control (tooltips_class32) owned by the window, a
// rectangle tool per tooltip a panel's drawing carries. The window relays its mouse messages (TTM_RELAYEVENT); the system shows
// the text after its own rest delay, never activates and never takes the keyboard. Main thread only.
#include "CPlazaD2D.h"

#include <windows.h>
#include <commctrl.h>

#include <cstddef>
#include <cstring>

#pragma comment(lib, "comctl32.lib")

namespace {

// The v1 layout of TTTOOLINFOW (up to lpszText): every comctl32 version accepts it, with or without a visual-styles manifest.
constexpr UINT kToolInfoSize = static_cast<UINT>(offsetof(TTTOOLINFOW, lpszText) + sizeof(LPWSTR));

TTTOOLINFOW toolInfo(HWND owner, UINT_PTR id) {
    TTTOOLINFOW ti;
    std::memset(&ti, 0, sizeof(ti));
    ti.cbSize = kToolInfoSize;
    ti.hwnd = owner;
    ti.uId = id;
    return ti;
}

}  // namespace

extern "C" {

void *ptb_tooltip_create(void *owner) {
    INITCOMMONCONTROLSEX icc;
    icc.dwSize = sizeof(icc);
    icc.dwICC = ICC_WIN95_CLASSES;
    InitCommonControlsEx(&icc);
    HWND tip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT,
                               CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, static_cast<HWND>(owner), nullptr,
                               GetModuleHandleW(nullptr), nullptr);
    if (!tip) return nullptr;
    SendMessageW(tip, TTM_SETMAXTIPWIDTH, 0, 320);
    return tip;
}

void ptb_tooltip_destroy(void *tooltip) {
    if (tooltip) DestroyWindow(static_cast<HWND>(tooltip));
}

int ptb_tooltip_set(void *tooltip, void *owner, const int32_t *rects, const uint16_t *const *texts, uint32_t count) {
    if (!tooltip) return -1;
    HWND tip = static_cast<HWND>(tooltip);
    HWND own = static_cast<HWND>(owner);
    int old = static_cast<int>(SendMessageW(tip, TTM_GETTOOLCOUNT, 0, 0));
    for (int i = 0; i < old; i++) {
        TTTOOLINFOW ti = toolInfo(own, static_cast<UINT_PTR>(i + 1));
        SendMessageW(tip, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&ti));
    }
    int added = 0;
    for (uint32_t i = 0; i < count; i++) {
        TTTOOLINFOW ti = toolInfo(own, static_cast<UINT_PTR>(i + 1));
        ti.rect.left = rects[4 * i];
        ti.rect.top = rects[4 * i + 1];
        ti.rect.right = rects[4 * i + 2];
        ti.rect.bottom = rects[4 * i + 3];
        ti.lpszText = const_cast<LPWSTR>(reinterpret_cast<const WCHAR *>(texts[i]));
        if (SendMessageW(tip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&ti))) added++;
    }
    return added;
}

void ptb_tooltip_relay(void *tooltip, void *owner, uint32_t message, uint64_t wParam, int64_t lParam) {
    if (!tooltip) return;
    MSG msg;
    std::memset(&msg, 0, sizeof(msg));
    msg.hwnd = static_cast<HWND>(owner);
    msg.message = message;
    msg.wParam = static_cast<WPARAM>(wParam);
    msg.lParam = static_cast<LPARAM>(lParam);
    SendMessageW(static_cast<HWND>(tooltip), TTM_RELAYEVENT, 0, reinterpret_cast<LPARAM>(&msg));
}

int ptb_tooltip_count(void *tooltip) {
    return tooltip ? static_cast<int>(SendMessageW(static_cast<HWND>(tooltip), TTM_GETTOOLCOUNT, 0, 0)) : 0;
}

int ptb_tooltip_text(void *tooltip, void *owner, uint32_t index, uint16_t *out, int capacity) {
    if (!tooltip || !out || capacity < 2) return -1;
    out[0] = 0;
    TTTOOLINFOW ti = toolInfo(static_cast<HWND>(owner), static_cast<UINT_PTR>(index + 1));
    ti.lpszText = reinterpret_cast<LPWSTR>(out);
    SendMessageW(static_cast<HWND>(tooltip), TTM_GETTEXTW, static_cast<WPARAM>(capacity), reinterpret_cast<LPARAM>(&ti));
    out[capacity - 1] = 0;
    int n = 0;
    while (n < capacity - 1 && out[n]) n++;
    return n;
}

int ptb_tooltip_current(void *tooltip, void *owner) {
    if (!tooltip) return -1;
    TTTOOLINFOW ti = toolInfo(static_cast<HWND>(owner), 0);
    if (!SendMessageW(static_cast<HWND>(tooltip), TTM_GETCURRENTTOOLW, 0, reinterpret_cast<LPARAM>(&ti))) return -1;
    return static_cast<int>(ti.uId) - 1;
}

int ptb_tooltip_visible(void *tooltip) {
    return tooltip && IsWindowVisible(static_cast<HWND>(tooltip)) ? 1 : 0;
}

void ptb_tooltip_set_delay(void *tooltip, int initialMs) {
    if (tooltip) SendMessageW(static_cast<HWND>(tooltip), TTM_SETDELAYTIME, TTDT_INITIAL, initialMs);
}

}  // extern "C"
