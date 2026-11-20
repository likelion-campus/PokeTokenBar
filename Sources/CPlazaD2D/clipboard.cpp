// The Windows clipboard for the plaza photo and for text (see CPlazaD2D.h, "clipboard").
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace {

using namespace ptb;

constexpr uint32_t kDibV5HeaderSize = 124;  // sizeof(BITMAPV5HEADER)
constexpr uint64_t kMaxPixels = 64ull << 20;  // 256 MB of BGRA; the plaza's photos are far smaller (16384 per side is the renderer's cap)

LRESULT CALLBACK ownerProc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcW(h, m, w, l); }

// A hidden message-only window that owns the clipboard for the length of one call (EmptyClipboard + SetClipboardData need an
// owner; a NULL owner makes SetClipboardData fail). It is destroyed before the call returns: nothing stays alive between photos.
// The data stays on the clipboard after the owner is gone because it is real data, not delayed rendering.
struct Owner {
    HWND hwnd = nullptr;
    Owner() {
        static const ATOM atom = [] {
            WNDCLASSEXW wc = {};
            wc.cbSize = sizeof(wc);
            wc.lpfnWndProc = ownerProc;
            wc.hInstance = GetModuleHandleW(nullptr);
            wc.lpszClassName = L"PokeTokenBarClipboardOwner";
            return RegisterClassExW(&wc);
        }();
        if (atom) hwnd = CreateWindowExW(0, L"PokeTokenBarClipboardOwner", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                         GetModuleHandleW(nullptr), nullptr);
    }
    ~Owner() { if (hwnd) DestroyWindow(hwnd); }
};

// OpenClipboard fails with ACCESS_DENIED while another window has it open; retry every 10 ms until `timeoutMs` has passed.
bool openWithRetry(HWND owner, uint32_t timeoutMs, DWORD *lastError) {
    const ULONGLONG start = GetTickCount64();
    for (;;) {
        if (OpenClipboard(owner)) return true;
        *lastError = GetLastError();
        if (GetTickCount64() - start >= timeoutMs) return false;
        Sleep(10);
    }
}

// Moves `size` bytes into a fresh movable block; the caller owns it until SetClipboardData succeeds.
HGLOBAL makeBlock(size_t size, uint8_t **bytes) {
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!h) return nullptr;
    void *p = GlobalLock(h);
    if (!p) { GlobalFree(h); return nullptr; }
    *bytes = static_cast<uint8_t *>(p);
    return h;
}

// Hands a filled block to the clipboard. The system owns it only when SetClipboardData succeeds; on failure it is freed here.
int setBlock(UINT format, HGLOBAL h, const char *stage) {
    GlobalUnlock(h);
    if (!SetClipboardData(format, h)) {
        const DWORD e = GetLastError();
        GlobalFree(h);
        return fail(stage, HRESULT_FROM_WIN32(e ? e : ERROR_INVALID_DATA));
    }
    return 0;
}

int openForWrite(Owner &owner, uint32_t timeoutMs) {
    if (!owner.hwnd) return fail("clipboard owner window", HRESULT_FROM_WIN32(GetLastError()));
    DWORD err = 0;
    if (!openWithRetry(owner.hwnd, timeoutMs, &err)) return fail("OpenClipboard (busy)", HRESULT_FROM_WIN32(err));
    if (!EmptyClipboard()) {
        const DWORD e = GetLastError();
        CloseClipboard();
        return fail("EmptyClipboard", HRESULT_FROM_WIN32(e));
    }
    return 0;
}

struct Hold {
    DWORD ms;
    HANDLE ready;
    bool opened;
};

DWORD WINAPI holdProc(LPVOID arg) {
    Hold *hold = static_cast<Hold *>(arg);
    const DWORD ms = hold->ms;
    const bool opened = OpenClipboard(nullptr) != 0;
    hold->opened = opened;
    SetEvent(hold->ready);  // hold is the creator's stack object: not touched after this
    if (!opened) return 1;
    Sleep(ms);
    CloseClipboard();
    return 0;
}

}  // namespace

extern "C" {

unsigned ptb_clipboard_png_format(void) {
    static const UINT f = RegisterClipboardFormatW(L"PNG");
    return f;
}

int ptb_clipboard_set_image(const uint8_t *png, size_t pngLen, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t timeoutMs) {
    if (!png || pngLen == 0 || !rgba || w == 0 || h == 0 || static_cast<uint64_t>(w) * h > kMaxPixels) return fail("clipboard image input", E_INVALIDARG);
    const UINT pngFormat = ptb_clipboard_png_format();
    if (!pngFormat) return fail("RegisterClipboardFormat(PNG)", HRESULT_FROM_WIN32(GetLastError()));

    Owner owner;
    int code = openForWrite(owner, timeoutMs);
    if (code < 0) return code;

    // 1. PNG: the registered "PNG" format, the bytes as encoded (straight alpha, as PNG stores it). Most modern apps prefer it.
    uint8_t *dst = nullptr;
    HGLOBAL block = makeBlock(pngLen, &dst);
    if (!block) {
        code = fail("GlobalAlloc(PNG)", E_OUTOFMEMORY);
    } else {
        std::memcpy(dst, png, pngLen);
        code = setBlock(pngFormat, block, "SetClipboardData(PNG)");
    }

    // 2. CF_DIBV5: BITMAPV5HEADER + 32-bit BI_BITFIELDS BGRA, bottom-up, STRAIGHT alpha (the DIBV5 convention for the clipboard;
    //    a consumer that ignores alpha sees the colour channels as they are). Windows derives CF_DIB and CF_BITMAP from it.
    if (code >= 0) {
        const size_t pixelBytes = static_cast<size_t>(w) * h * 4;
        block = makeBlock(kDibV5HeaderSize + pixelBytes, &dst);
        if (!block) {
            code = fail("GlobalAlloc(DIBV5)", E_OUTOFMEMORY);
        } else {
            BITMAPV5HEADER header = {};
            header.bV5Size = kDibV5HeaderSize;
            header.bV5Width = static_cast<LONG>(w);
            header.bV5Height = static_cast<LONG>(h);  // positive: bottom-up, which every consumer reads
            header.bV5Planes = 1;
            header.bV5BitCount = 32;
            header.bV5Compression = BI_BITFIELDS;
            header.bV5SizeImage = static_cast<DWORD>(pixelBytes);
            header.bV5RedMask = 0x00FF0000;
            header.bV5GreenMask = 0x0000FF00;
            header.bV5BlueMask = 0x000000FF;
            header.bV5AlphaMask = 0xFF000000;
            header.bV5CSType = 0x73524742;  // LCS_sRGB
            header.bV5Intent = 4;           // LCS_GM_IMAGES
            std::memcpy(dst, &header, kDibV5HeaderSize);
            uint8_t *out = dst + kDibV5HeaderSize;
            for (uint32_t y = 0; y < h; ++y) {
                const uint8_t *src = rgba + static_cast<size_t>(h - 1 - y) * w * 4;  // the bottom source row first
                uint8_t *row = out + static_cast<size_t>(y) * w * 4;
                for (uint32_t x = 0; x < w; ++x) {
                    row[x * 4 + 0] = src[x * 4 + 2];
                    row[x * 4 + 1] = src[x * 4 + 1];
                    row[x * 4 + 2] = src[x * 4 + 0];
                    row[x * 4 + 3] = src[x * 4 + 3];
                }
            }
            code = setBlock(CF_DIBV5, block, "SetClipboardData(DIBV5)");
        }
    }
    if (code < 0) EmptyClipboard();  // never leave half a photo behind; the failure text stays
    CloseClipboard();
    return code;
}

int ptb_clipboard_set_text(const uint16_t *text, size_t count, uint32_t timeoutMs) {
    if (!text || count > (64u << 20)) return fail("clipboard text input", E_INVALIDARG);
    Owner owner;
    int code = openForWrite(owner, timeoutMs);
    if (code < 0) return code;
    uint8_t *dst = nullptr;
    HGLOBAL block = makeBlock((count + 1) * sizeof(uint16_t), &dst);
    if (!block) {
        code = fail("GlobalAlloc(text)", E_OUTOFMEMORY);
    } else {
        if (count) std::memcpy(dst, text, count * sizeof(uint16_t));
        std::memset(dst + count * sizeof(uint16_t), 0, sizeof(uint16_t));
        code = setBlock(CF_UNICODETEXT, block, "SetClipboardData(text)");
    }
    if (code < 0) EmptyClipboard();
    CloseClipboard();
    return code;
}

int ptb_clipboard_read_text(uint16_t *out, uint32_t cap, uint32_t timeoutMs) {
    if (!out || cap == 0) return fail("clipboard text input", E_INVALIDARG);
    DWORD err = 0;
    if (!openWithRetry(nullptr, timeoutMs, &err)) return fail("OpenClipboard (busy)", HRESULT_FROM_WIN32(err));
    int copied = 0;
    HANDLE data = IsClipboardFormatAvailable(CF_UNICODETEXT) ? GetClipboardData(CF_UNICODETEXT) : nullptr;
    if (data) {
        const SIZE_T units = GlobalSize(data) / sizeof(uint16_t);
        const uint16_t *p = static_cast<const uint16_t *>(GlobalLock(data));
        if (p) {
            while (static_cast<uint32_t>(copied) < cap && static_cast<SIZE_T>(copied) < units && p[copied] != 0) {
                out[copied] = p[copied];
                copied++;
            }
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    return copied;
}

int ptb_clipboard_read(unsigned format, uint8_t **bytes, size_t *len, uint32_t timeoutMs) {
    if (!bytes || !len) return fail("clipboard read input", E_INVALIDARG);
    *bytes = nullptr;
    *len = 0;
    DWORD err = 0;
    if (!openWithRetry(nullptr, timeoutMs, &err)) return fail("OpenClipboard (busy)", HRESULT_FROM_WIN32(err));
    int code = 0;
    HANDLE data = IsClipboardFormatAvailable(format) ? GetClipboardData(format) : nullptr;
    if (!data) {
        code = fail("clipboard format not present", HRESULT_FROM_WIN32(ERROR_NOT_FOUND));
    } else {
        const SIZE_T size = GlobalSize(data);
        const void *p = GlobalLock(data);
        if (!p || size == 0) {
            code = fail("GlobalLock(clipboard data)", HRESULT_FROM_WIN32(GetLastError()));
        } else {
            uint8_t *copy = static_cast<uint8_t *>(std::malloc(size));
            if (!copy) {
                code = fail("malloc", E_OUTOFMEMORY);
            } else {
                std::memcpy(copy, p, size);
                *bytes = copy;
                *len = size;
            }
        }
        if (p) GlobalUnlock(data);
    }
    CloseClipboard();
    return code;
}

int ptb_clipboard_hold(uint32_t ms) {
    Hold hold = {ms, CreateEventW(nullptr, TRUE, FALSE, nullptr), false};
    if (!hold.ready) return fail("CreateEvent", HRESULT_FROM_WIN32(GetLastError()));
    HANDLE thread = CreateThread(nullptr, 0, holdProc, &hold, 0, nullptr);
    if (!thread) {
        const DWORD e = GetLastError();
        CloseHandle(hold.ready);
        return fail("CreateThread", HRESULT_FROM_WIN32(e));
    }
    WaitForSingleObject(hold.ready, INFINITE);
    const bool opened = hold.opened;
    CloseHandle(hold.ready);
    CloseHandle(thread);  // the thread ends on its own after `ms`
    return opened ? 0 : fail("OpenClipboard (hold)", HRESULT_FROM_WIN32(ERROR_BUSY));
}

}  // extern "C"
