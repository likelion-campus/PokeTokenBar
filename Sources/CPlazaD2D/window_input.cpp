// Win32 input helpers for the plaza window (stage 6 Task 6, D7): the IME context of the window, the characters of a key press
// without eating the keyboard's dead-key state, the wheel's lines per notch and the pointer-leave request. Main thread only.
#include "CPlazaD2D.h"

#include <windows.h>
#include <imm.h>

#pragma comment(lib, "imm32.lib")

#ifndef IACE_DEFAULT
#define IACE_DEFAULT 0x0010
#endif

extern "C" {

int ptb_window_ime_set(void *hwnd, int enabled) {
    return ImmAssociateContextEx(static_cast<HWND>(hwnd), nullptr, enabled ? IACE_DEFAULT : 0) ? 1 : 0;
}

int ptb_window_ime_has_context(void *hwnd) {
    HIMC context = ImmGetContext(static_cast<HWND>(hwnd));
    if (!context) return 0;
    ImmReleaseContext(static_cast<HWND>(hwnd), context);
    return 1;
}

int ptb_window_ime_open(void *hwnd) {
    HIMC context = ImmGetContext(static_cast<HWND>(hwnd));
    if (!context) return 0;
    int open = ImmGetOpenStatus(context) ? 1 : 0;
    ImmReleaseContext(static_cast<HWND>(hwnd), context);
    return open;
}

int ptb_input_characters(uint32_t vk, uint32_t scan, void *hkl, const uint8_t *state, uint32_t flags, uint16_t *out, int cap) {
    HKL layout = hkl ? static_cast<HKL>(hkl) : GetKeyboardLayout(0);
    if (vk == 0 || vk == VK_PROCESSKEY) vk = MapVirtualKeyExW(scan, MAPVK_VSC_TO_VK_EX, layout);
    if (vk == 0) return 0;
    BYTE keys[256];
    if (state) {
        for (int i = 0; i < 256; i++) keys[i] = state[i];
    } else if (!GetKeyboardState(keys)) {
        return 0;
    }
    return ToUnicodeEx(vk, scan & 0xFF, keys, reinterpret_cast<LPWSTR>(out), cap, flags, layout);
}

void *ptb_input_load_layout(const uint16_t *klid) {
    return LoadKeyboardLayoutW(reinterpret_cast<LPCWSTR>(klid), KLF_NOTELLSHELL);
}

int ptb_input_keyboard_state(uint8_t *out) {
    return GetKeyboardState(out) ? 1 : 0;
}

uint32_t ptb_input_wheel_lines(int horizontal) {
    UINT lines = 3;
    if (!SystemParametersInfoW(horizontal ? SPI_GETWHEELSCROLLCHARS : SPI_GETWHEELSCROLLLINES, 0, &lines, 0)) return 3;
    return lines == WHEEL_PAGESCROLL || lines > 100 ? 3 : lines;
}

int ptb_window_track_leave(void *hwnd) {
    TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, static_cast<HWND>(hwnd), 0};
    return TrackMouseEvent(&track) ? 1 : 0;
}

}  // extern "C"
