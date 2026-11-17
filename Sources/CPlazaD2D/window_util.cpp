// Win32 helpers for the plaza window (stage 6 Task 5): DPI and frame sizes, monitors, the cover check, DWM cloaking, the
// WinEvent hooks and the session notifications that tell the window whether a person can see it (D5, D6). Main thread
// only. Functions that are newer than Windows 10 1507 are looked up with GetProcAddress.
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>
#include <dwmapi.h>
#include <wtsapi32.h>  // stage 7 Task 22: WTSINFOEXW (the functions are looked up, nothing is linked)

#include <cstdlib>
#include <cstring>

// Windows 8+ values, spelled out in case the SDK headers are read for an older target.
#ifndef EVENT_OBJECT_CLOAKED
#define EVENT_OBJECT_CLOAKED 0x8017
#define EVENT_OBJECT_UNCLOAKED 0x8018
#endif
#ifndef WS_EX_NOREDIRECTIONBITMAP
#define WS_EX_NOREDIRECTIONBITMAP 0x00200000L
#endif

namespace {

using namespace ptb;

template <class Fn> Fn proc(const wchar_t *module, const char *name) {
    HMODULE m = GetModuleHandleW(module);
    if (!m) m = LoadLibraryExW(module, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return m ? reinterpret_cast<Fn>(reinterpret_cast<void *>(GetProcAddress(m, name))) : nullptr;
}

// ---- rect lists: what is left of the client area after the windows above it are taken away ----

constexpr int kMaxRects = 512;  // beyond this the area counts as visible (a conservative answer)

struct Rects {
    RECT r[kMaxRects];
    int n = 0;
    bool overflow = false;
    void add(const RECT &x) {
        if (x.left >= x.right || x.top >= x.bottom) return;
        if (n == kMaxRects) {
            overflow = true;
            return;
        }
        r[n++] = x;
    }
};

// out = a - b, at most four pieces.
void subtract(const RECT &a, const RECT &b, Rects &out) {
    RECT i;
    if (!IntersectRect(&i, &a, &b)) {
        out.add(a);
        return;
    }
    out.add(RECT{a.left, a.top, a.right, i.top});
    out.add(RECT{a.left, i.bottom, a.right, a.bottom});
    out.add(RECT{a.left, i.top, i.left, i.bottom});
    out.add(RECT{i.right, i.top, a.right, i.bottom});
}

struct CoverWalk {
    HWND target = nullptr;
    Rects *left = nullptr, *scratch = nullptr;
    uint32_t counted = 0;
    bool reached = false;
};

bool isCloaked(HWND h) {
    DWORD cloaked = 0;
    return SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) && cloaked != 0;
}

BOOL CALLBACK coverStep(HWND h, LPARAM param) {
    CoverWalk *w = reinterpret_cast<CoverWalk *>(param);
    if (h == w->target) {
        w->reached = true;
        return FALSE;  // windows below ours cannot cover it
    }
    if (!IsWindowVisible(h) || IsIconic(h)) return TRUE;
    const LONG_PTR ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
    if (ex & (WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOREDIRECTIONBITMAP)) return TRUE;  // may be see-through
    if (isCloaked(h)) return TRUE;
    RECT box;
    if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &box, sizeof(box))) && !GetWindowRect(h, &box)) return TRUE;
    if (box.left >= box.right || box.top >= box.bottom) return TRUE;
    w->scratch->n = 0;
    for (int i = 0; i < w->left->n; i++) subtract(w->left->r[i], box, *w->scratch);
    w->left->overflow = w->left->overflow || w->scratch->overflow;
    std::memcpy(w->left->r, w->scratch->r, sizeof(RECT) * static_cast<size_t>(w->scratch->n));
    w->left->n = w->scratch->n;
    w->counted++;
    return w->left->n == 0 ? FALSE : TRUE;  // nothing left: covered, stop
}

struct MonitorWalk {
    Rects *onScreen = nullptr;
    RECT client = {};
    PTBMonitor *out = nullptr;
    uint32_t cap = 0, count = 0;
};

BOOL CALLBACK clipToMonitor(HMONITOR, HDC, LPRECT r, LPARAM param) {
    MonitorWalk *w = reinterpret_cast<MonitorWalk *>(param);
    RECT i;
    if (IntersectRect(&i, &w->client, r)) w->onScreen->add(i);
    return TRUE;
}

typedef HRESULT(WINAPI *DpiForMonitorFn)(HMONITOR, int, UINT *, UINT *);

BOOL CALLBACK listMonitor(HMONITOR m, HDC, LPRECT, LPARAM param) {
    MonitorWalk *w = reinterpret_cast<MonitorWalk *>(param);
    if (w->count >= w->cap) return FALSE;
    MONITORINFOEXW info;
    std::memset(&info, 0, sizeof(info));
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(m, reinterpret_cast<MONITORINFO *>(&info))) return TRUE;
    PTBMonitor &o = w->out[w->count++];
    std::memset(&o, 0, sizeof(o));
    for (int i = 0; i < 31 && info.szDevice[i]; i++) o.name[i] = static_cast<uint16_t>(info.szDevice[i]);
    o.monitor[0] = info.rcMonitor.left;
    o.monitor[1] = info.rcMonitor.top;
    o.monitor[2] = info.rcMonitor.right;
    o.monitor[3] = info.rcMonitor.bottom;
    o.work[0] = info.rcWork.left;
    o.work[1] = info.rcWork.top;
    o.work[2] = info.rcWork.right;
    o.work[3] = info.rcWork.bottom;
    o.primary = (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
    UINT dx = 96, dy = 96;
    static DpiForMonitorFn dpiFor = proc<DpiForMonitorFn>(L"shcore.dll", "GetDpiForMonitor");
    if (!dpiFor || FAILED(dpiFor(m, 0 /* MDT_EFFECTIVE_DPI */, &dx, &dy))) dx = 96;
    o.dpi = dx;
    o.handle = reinterpret_cast<uint64_t>(m);
    return TRUE;
}

// ---- WinEvent hooks: one plaza window at a time ----

HWND gHookTarget = nullptr;
UINT gHookMessage = 0;
volatile LONG gHookPending = 0;
HWINEVENTHOOK gHooks[4] = {};
uint32_t gHookCount = 0;

void CALLBACK onWinEvent(HWINEVENTHOOK, DWORD event, HWND h, LONG object, LONG, DWORD, DWORD) {
    if (!gHookTarget) return;
    if (event == EVENT_OBJECT_CLOAKED || event == EVENT_OBJECT_UNCLOAKED) {
        if (h != gHookTarget || object != OBJID_WINDOW) return;
        PostMessageW(gHookTarget, gHookMessage, event, 0);  // always: the window reads the attribute itself
        return;
    }
    // Foreground, move/size end, minimize start/end anywhere: one pending check is enough.
    if (InterlockedCompareExchange(&gHookPending, 1, 0) == 0) PostMessageW(gHookTarget, gHookMessage, event, 0);
}

}  // namespace

extern "C" int ptb_window_covered(void *hwnd, uint32_t *above) {
    HWND h = static_cast<HWND>(hwnd);
    if (above) *above = 0;
    if (!h) return 0;
    RECT client;
    if (!GetClientRect(h, &client)) return 0;
    POINT origin = {0, 0};
    ClientToScreen(h, &origin);
    OffsetRect(&client, origin.x, origin.y);
    static Rects left, scratch;
    left.n = 0;
    left.overflow = false;
    scratch.n = 0;
    scratch.overflow = false;
    MonitorWalk mw;
    mw.onScreen = &left;
    mw.client = client;
    EnumDisplayMonitors(nullptr, nullptr, clipToMonitor, reinterpret_cast<LPARAM>(&mw));
    if (left.n == 0) return 1;  // on no monitor at all
    CoverWalk cw;
    cw.target = h;
    cw.left = &left;
    cw.scratch = &scratch;
    EnumWindows(coverStep, reinterpret_cast<LPARAM>(&cw));
    if (above) *above = cw.counted;
    if (left.overflow) return 0;
    return left.n == 0 ? 1 : 0;
}

extern "C" int ptb_window_cloaked(void *hwnd) { return hwnd && isCloaked(static_cast<HWND>(hwnd)) ? 1 : 0; }

extern "C" int ptb_window_set_cloak(void *hwnd, int on) {
    BOOL value = on ? TRUE : FALSE;
    return static_cast<int>(DwmSetWindowAttribute(static_cast<HWND>(hwnd), 13 /* DWMWA_CLOAK */, &value, sizeof(value)));
}

extern "C" int ptb_window_hooks_install(void *hwnd, uint32_t message) {
    if (gHookCount) return 0;
    gHookTarget = static_cast<HWND>(hwnd);
    gHookMessage = message;
    gHookPending = 0;
    const DWORD self = GetCurrentProcessId();
    const DWORD flags = WINEVENT_OUTOFCONTEXT;
    struct Range { DWORD from, to, process; } ranges[] = {
        {EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED, self},           // our window on another virtual desktop
        {EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, 0},           // anything activated: covering changes
        {EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MOVESIZEEND, 0},         // a window dragged away or over
        {EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND, 0},       // a covering window minimized or restored
    };
    for (const Range &r : ranges) {
        HWINEVENTHOOK hook = SetWinEventHook(r.from, r.to, nullptr, onWinEvent, r.process, 0, flags);
        if (hook) gHooks[gHookCount++] = hook;
    }
    return static_cast<int>(gHookCount);
}

extern "C" void ptb_window_hooks_ack(void) { InterlockedExchange(&gHookPending, 0); }

extern "C" void ptb_window_hooks_remove(void) {
    for (uint32_t i = 0; i < gHookCount; i++) UnhookWinEvent(gHooks[i]);
    gHookCount = 0;
    gHookTarget = nullptr;
}

extern "C" uint32_t ptb_window_hooks_live(void) { return gHookCount; }

extern "C" uint32_t ptb_window_dpi(void *hwnd) {
    typedef UINT(WINAPI * Fn)(HWND);
    static Fn dpiFor = proc<Fn>(L"user32.dll", "GetDpiForWindow");
    const UINT dpi = dpiFor && hwnd ? dpiFor(static_cast<HWND>(hwnd)) : 0;
    return dpi ? dpi : 96;
}

extern "C" int ptb_window_frame_for_client(uint32_t style, uint32_t exStyle, uint32_t dpi, int32_t w, int32_t h, int32_t out[4]) {
    RECT r = {0, 0, w, h};
    typedef BOOL(WINAPI * Fn)(LPRECT, DWORD, BOOL, DWORD, UINT);
    static Fn adjust = proc<Fn>(L"user32.dll", "AdjustWindowRectExForDpi");
    const BOOL ok = adjust ? adjust(&r, style, FALSE, exStyle, dpi) : AdjustWindowRectEx(&r, style, FALSE, exStyle);
    out[0] = r.left;
    out[1] = r.top;
    out[2] = r.right;
    out[3] = r.bottom;
    return ok ? 0 : fail("AdjustWindowRectExForDpi", HRESULT_FROM_WIN32(GetLastError()));
}

extern "C" int ptb_window_dpi_awareness(void *hwnd, int *perMonitorV2) {
    typedef void *(WINAPI * GetCtx)(HWND);
    typedef int(WINAPI * Awareness)(void *);
    typedef BOOL(WINAPI * Equal)(void *, void *);
    static GetCtx getCtx = proc<GetCtx>(L"user32.dll", "GetWindowDpiAwarenessContext");
    static Awareness awareness = proc<Awareness>(L"user32.dll", "GetAwarenessFromDpiAwarenessContext");
    static Equal equal = proc<Equal>(L"user32.dll", "AreDpiAwarenessContextsEqual");
    if (perMonitorV2) *perMonitorV2 = 0;
    if (!getCtx || !awareness || !hwnd) return -1;
    void *ctx = getCtx(static_cast<HWND>(hwnd));
    if (perMonitorV2 && equal) *perMonitorV2 = equal(ctx, reinterpret_cast<void *>(static_cast<intptr_t>(-4))) ? 1 : 0;
    return awareness(ctx);
}

extern "C" uint32_t ptb_monitors(PTBMonitor *out, uint32_t cap) {
    if (!out || cap == 0) return 0;
    MonitorWalk w;
    w.out = out;
    w.cap = cap;
    EnumDisplayMonitors(nullptr, nullptr, listMonitor, reinterpret_cast<LPARAM>(&w));
    return w.count;
}

extern "C" int ptb_window_session_notify(void *hwnd, int on) {
    typedef BOOL(WINAPI * Reg)(HWND, DWORD);
    typedef BOOL(WINAPI * Unreg)(HWND);
    static Reg reg = proc<Reg>(L"wtsapi32.dll", "WTSRegisterSessionNotification");
    static Unreg unreg = proc<Unreg>(L"wtsapi32.dll", "WTSUnRegisterSessionNotification");
    if (on) return reg && reg(static_cast<HWND>(hwnd), 0 /* NOTIFY_FOR_THIS_SESSION */) ? 1 : 0;
    return unreg && unreg(static_cast<HWND>(hwnd)) ? 1 : 0;
}

// --- stage 7 Task 22: the session's lock state now (begin) ---
extern "C" int ptb_session_state(int *locked, int *disconnected) {
    typedef BOOL(WINAPI * Query)(HANDLE, DWORD, WTS_INFO_CLASS, LPWSTR *, DWORD *);
    typedef void(WINAPI * Release)(PVOID);
    static Query query = proc<Query>(L"wtsapi32.dll", "WTSQuerySessionInformationW");
    static Release release = proc<Release>(L"wtsapi32.dll", "WTSFreeMemory");
    if (locked) *locked = 0;
    if (disconnected) *disconnected = 0;
    if (!query || !release) return 0;
    LPWSTR buffer = nullptr;
    DWORD bytes = 0;
    if (!query(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTSSessionInfoEx, &buffer, &bytes) || !buffer) return 0;
    int ok = 0;
    if (bytes >= sizeof(WTSINFOEXW)) {
        const WTSINFOEXW *info = reinterpret_cast<const WTSINFOEXW *>(buffer);
        if (info->Level == 1) {
            // WTS_SESSIONSTATE_LOCK is 0 and _UNLOCK 1 from Windows 8 on (Windows 7 swapped them; it is not supported).
            if (locked) *locked = info->Data.WTSInfoExLevel1.SessionFlags == 0 ? 1 : 0;
            if (disconnected) *disconnected = info->Data.WTSInfoExLevel1.SessionState == WTSDisconnected ? 1 : 0;
            ok = 1;
        }
    }
    release(buffer);
    return ok;
}
// --- stage 7 Task 22 (end) ---

extern "C" uint32_t ptb_process_handle_count(void) {
    DWORD n = 0;
    return GetProcessHandleCount(GetCurrentProcess(), &n) ? n : 0;
}

extern "C" int ptb_window_print(void *hwnd, uint32_t *w, uint32_t *h, uint8_t **bgra) {
    HWND window = static_cast<HWND>(hwnd);
    if (!window || !w || !h || !bgra) return fail("ptb_window_print", E_INVALIDARG);
    *bgra = nullptr;
    RECT client;
    if (!GetClientRect(window, &client) || client.right <= 0 || client.bottom <= 0) return fail("ptb_window_print: client", E_FAIL);
    const uint32_t cw = static_cast<uint32_t>(client.right), ch = static_cast<uint32_t>(client.bottom);
    HDC screen = GetDC(nullptr);
    HDC mem = screen ? CreateCompatibleDC(screen) : nullptr;
    BITMAPINFO bi;
    std::memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = static_cast<LONG>(cw);
    bi.bmiHeader.biHeight = -static_cast<LONG>(ch);
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HBITMAP dib = mem ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0) : nullptr;
    int result = fail("ptb_window_print: GDI", E_FAIL);
    if (dib && bits) {
        HGDIOBJ old = SelectObject(mem, dib);
        if (PrintWindow(window, mem, 0x1 /* PW_CLIENTONLY */ | 0x2 /* PW_RENDERFULLCONTENT */)) {
            const size_t bytes = static_cast<size_t>(cw) * ch * 4;
            uint8_t *out = static_cast<uint8_t *>(std::malloc(bytes));
            if (out) {
                std::memcpy(out, bits, bytes);
                for (size_t i = 3; i < bytes; i += 4) out[i] = 255;
                *bgra = out;
                *w = cw;
                *h = ch;
                result = 0;
            } else {
                result = fail("ptb_window_print", E_OUTOFMEMORY);
            }
        } else {
            result = fail("PrintWindow", HRESULT_FROM_WIN32(GetLastError()));
        }
        SelectObject(mem, old);
    }
    if (dib) DeleteObject(dib);
    if (mem) DeleteDC(mem);
    if (screen) ReleaseDC(nullptr, screen);
    return result;
}
