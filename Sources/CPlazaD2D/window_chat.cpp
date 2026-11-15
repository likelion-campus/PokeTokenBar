// The plaza's chat field (stage 6 Task 11, D13): a native one-line EDIT in a small host window that is a child of the plaza
// window, the IME calls the field's rules need, and a probe of the Korean IME (a TSF text service) for the selftest.
// Main thread only. The EDIT is subclassed the classic way (SetWindowLongPtrW + CallWindowProcW, user32 only: SetWindowSubclass
// needs comctl32 v6, which the XCTest process does not load).
#include "CPlazaD2D.h"

#include <windows.h>
#include <imm.h>
#include <msctf.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <string>

#pragma comment(lib, "imm32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "ole32.lib")

#ifndef EM_SETCUEBANNER
#define EM_SETCUEBANNER 0x1501
#endif
#ifndef TF_IPPMF_FORPROCESS
#define TF_IPPMF_FORPROCESS 0x10000000
#endif
#ifndef TF_IPPMF_ENABLEPROFILE
#define TF_IPPMF_ENABLEPROFILE 0x00000001
#endif
#ifndef TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE
#define TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE 0x00000004
#endif

namespace {

struct ChatField {
    HWND host = nullptr;
    HWND edit = nullptr;
    WNDPROC original = nullptr;
    PTBChatProc proc = nullptr;
    void *context = nullptr;
    HBRUSH brush = nullptr;
    HFONT font = nullptr;
    COLORREF text = RGB(255, 255, 255);
    COLORREF back = RGB(0x1D, 0x4F, 0x5C);
};

const wchar_t *const kHostClass = L"PokeTokenBarPlazaChatHost";

ChatField *fieldOf(HWND hwnd) { return reinterpret_cast<ChatField *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA)); }

LRESULT CALLBACK editProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    ChatField *f = fieldOf(hwnd);
    if (!f) return DefWindowProcW(hwnd, message, wParam, lParam);
    WNDPROC original = f->original;
    if (message == WM_NCDESTROY) {
        SetWindowLongPtrW(hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(original));
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        return CallWindowProcW(original, hwnd, message, wParam, lParam);
    }
    if (f->proc) {
        int handled = 0;
        const int64_t result = f->proc(f->context, message, static_cast<uint64_t>(wParam), static_cast<int64_t>(lParam), &handled);
        if (handled) return static_cast<LRESULT>(result);
    }
    return CallWindowProcW(original, hwnd, message, wParam, lParam);
}

LRESULT CALLBACK hostProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    ChatField *f = fieldOf(hwnd);
    switch (message) {
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC:
        if (f && f->brush) {
            HDC dc = reinterpret_cast<HDC>(wParam);
            SetTextColor(dc, f->text);
            SetBkColor(dc, f->back);
            SetBkMode(dc, OPAQUE);
            return reinterpret_cast<LRESULT>(f->brush);
        }
        break;
    case WM_COMMAND:
        if (f && f->proc && HIWORD(wParam) == EN_CHANGE) {
            int handled = 0;
            f->proc(f->context, PTB_CHAT_CHANGED, 0, 0, &handled);
            return 0;
        }
        break;
    case WM_ERASEBKGND:
        if (f && f->brush) {
            RECT r;
            GetClientRect(hwnd, &r);
            FillRect(reinterpret_cast<HDC>(wParam), &r, f->brush);
            return 1;
        }
        break;
    case WM_SETFOCUS:
        if (f && f->edit) SetFocus(f->edit);   // the host never keeps the keyboard
        return 0;
    case WM_MOUSEACTIVATE:
        break;   // DefWindowProc asks the plaza window (the top-level parent)
    default:
        break;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

bool registerHost(HINSTANCE instance) {
    static bool registered = false;
    if (registered) return true;
    WNDCLASSEXW wc;
    std::memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = hostProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32513) /* IDC_IBEAM */);
    wc.lpszClassName = kHostClass;
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    registered = true;
    return true;
}

ChatField *fieldOfEdit(void *edit) { return edit ? fieldOf(static_cast<HWND>(edit)) : nullptr; }

struct Context {
    HWND hwnd;
    HIMC himc;
    explicit Context(void *h) : hwnd(static_cast<HWND>(h)), himc(h ? ImmGetContext(static_cast<HWND>(h)) : nullptr) {}
    ~Context() { if (himc) ImmReleaseContext(hwnd, himc); }
};

void appendf(std::wstring &s, const wchar_t *format, ...) {
    wchar_t buf[256];
    va_list args;
    va_start(args, format);
    _vsnwprintf_s(buf, sizeof(buf) / sizeof(buf[0]), _TRUNCATE, format, args);
    va_end(args);
    s += buf;
}

std::wstring guidText(REFGUID g) {
    wchar_t buf[64];
    return StringFromGUID2(g, buf, 64) > 0 ? std::wstring(buf) : std::wstring(L"?");
}

// CLSID_TF_InputProcessorProfiles, IID_ITfInputProcessorProfileMgr, GUID_TFCAT_TIP_KEYBOARD (spelled out: no uuid.lib).
const GUID kProfilesClsid = {0x33C53A50, 0xF456, 0x4884, {0xB0, 0x49, 0x85, 0xFD, 0x64, 0x3E, 0xCF, 0xED}};
const IID kProfileMgrIid = {0x71C6E74C, 0x0F28, 0x11D8, {0xA8, 0x2A, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C}};
const GUID kKeyboardCategory = {0x34745C63, 0xB2F0, 0x4784, {0x8B, 0x67, 0x5E, 0x12, 0xC8, 0x70, 0x1A, 0x31}};

TF_INPUTPROCESSORPROFILE gBefore;
bool gHaveBefore = false;

void copyOut(const std::wstring &s, uint16_t *out, int cap) {
    if (!out || cap <= 0) return;
    const size_t n = s.size() < static_cast<size_t>(cap - 1) ? s.size() : static_cast<size_t>(cap - 1);
    for (size_t i = 0; i < n; i++) out[i] = static_cast<uint16_t>(s[i]);
    out[n] = 0;
}

}  // namespace

extern "C" {

void *ptb_chat_edit_create(void *parent, int layered, PTBChatProc proc, void *context) {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    if (!parent || !registerHost(instance)) return nullptr;
    ChatField *f = new ChatField();
    f->proc = proc;
    f->context = context;
    f->brush = CreateSolidBrush(f->back);
    f->host = CreateWindowExW(layered ? WS_EX_LAYERED : 0, kHostClass, L"", WS_CHILD | WS_CLIPCHILDREN, 0, 0, 1, 1,
                              static_cast<HWND>(parent), nullptr, instance, nullptr);
    if (!f->host) {
        DeleteObject(f->brush);
        delete f;
        return nullptr;
    }
    SetWindowLongPtrW(f->host, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(f));
    if (layered) SetLayeredWindowAttributes(f->host, 0, 255, LWA_ALPHA);
    f->edit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_LEFT | ES_AUTOHSCROLL, 0, 0, 1, 1, f->host,
                              reinterpret_cast<HMENU>(static_cast<INT_PTR>(1)), instance, nullptr);
    if (!f->edit) {
        DestroyWindow(f->host);
        DeleteObject(f->brush);
        delete f;
        return nullptr;
    }
    SetWindowLongPtrW(f->edit, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(f));
    f->original = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(f->edit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(editProc)));
    return f->edit;
}

void ptb_chat_edit_destroy(void *edit) {
    ChatField *f = fieldOfEdit(edit);
    if (!f) return;
    f->proc = nullptr;
    f->context = nullptr;
    SetWindowLongPtrW(f->host, GWLP_USERDATA, 0);
    DestroyWindow(f->host);   // the EDIT goes with it (its WM_NCDESTROY puts its own procedure back)
    if (f->font) DeleteObject(f->font);
    if (f->brush) DeleteObject(f->brush);
    delete f;
}

void *ptb_chat_edit_host(void *edit) {
    ChatField *f = fieldOfEdit(edit);
    return f ? f->host : nullptr;
}

int ptb_chat_edit_place(void *edit, int32_t x, int32_t y, int32_t w, int32_t h, int show) {
    ChatField *f = fieldOfEdit(edit);
    if (!f) return 0;
    if (!show) {
        return SetWindowPos(f->host, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_HIDEWINDOW) ? 1 : 0;
    }
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    BOOL ok = SetWindowPos(f->host, HWND_TOP, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    ok = ok && SetWindowPos(f->edit, nullptr, 0, 0, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    return ok ? 1 : 0;
}

int64_t ptb_chat_edit_default(void *edit, uint32_t message, uint64_t wParam, int64_t lParam) {
    ChatField *f = fieldOfEdit(edit);
    if (!f || !f->original) return 0;
    return CallWindowProcW(f->original, f->edit, message, static_cast<WPARAM>(wParam), static_cast<LPARAM>(lParam));
}

int ptb_chat_edit_style(void *edit, uint32_t text, uint32_t back, const uint16_t *face, int32_t pixelHeight, int32_t quality,
                        int32_t margin) {
    ChatField *f = fieldOfEdit(edit);
    if (!f) return 0;
    HFONT font = CreateFontW(-pixelHeight, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                             CLIP_DEFAULT_PRECIS, static_cast<DWORD>(quality), DEFAULT_PITCH | FF_DONTCARE,
                             reinterpret_cast<LPCWSTR>(face));
    HBRUSH brush = CreateSolidBrush(static_cast<COLORREF>(back));
    if (!font || !brush) {
        if (font) DeleteObject(font);
        if (brush) DeleteObject(brush);
        return 0;
    }
    SendMessageW(f->edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    SendMessageW(f->edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELONG(margin, margin));
    if (f->font) DeleteObject(f->font);
    if (f->brush) DeleteObject(f->brush);
    f->font = font;
    f->brush = brush;
    f->text = static_cast<COLORREF>(text);
    f->back = static_cast<COLORREF>(back);
    InvalidateRect(f->host, nullptr, TRUE);
    InvalidateRect(f->edit, nullptr, TRUE);
    return 1;
}

int ptb_chat_edit_cue(void *edit, const uint16_t *text) {
    if (!edit) return 0;
    return SendMessageW(static_cast<HWND>(edit), EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(text)) ? 1 : 0;
}

int ptb_chat_font_add(const uint16_t *path) {
    return AddFontResourceExW(reinterpret_cast<LPCWSTR>(path), FR_PRIVATE, nullptr);
}

int ptb_chat_caret(int32_t out[2]) {
    POINT p;
    if (!GetCaretPos(&p)) return 0;
    out[0] = p.x;
    out[1] = p.y;
    return 1;
}

uint32_t ptb_chat_caret_blink_ms(void) { return GetCaretBlinkTime(); }

void *ptb_chat_caret_window(void) {
    GUITHREADINFO info;
    std::memset(&info, 0, sizeof(info));
    info.cbSize = sizeof(info);
    if (!GetGUIThreadInfo(GetCurrentThreadId(), &info)) return nullptr;
    return info.hwndCaret;
}

int ptb_ime_string(void *hwnd, uint32_t kind, uint16_t *out, int cap) {
    Context c(hwnd);
    if (!c.himc) return -1;
    const LONG bytes = ImmGetCompositionStringW(c.himc, kind, nullptr, 0);
    if (kind == GCS_CURSORPOS) return static_cast<int>(bytes);
    if (bytes <= 0) return 0;
    const int units = static_cast<int>(bytes / 2);
    if (out && cap > 0) {
        const LONG take = units <= cap ? bytes : static_cast<LONG>(cap) * 2;
        ImmGetCompositionStringW(c.himc, kind, out, static_cast<DWORD>(take));
    }
    return units;
}

int ptb_ime_finish(void *hwnd, int cancel) {
    Context c(hwnd);
    if (!c.himc) return -1;
    return ImmNotifyIME(c.himc, NI_COMPOSITIONSTR, cancel ? CPS_CANCEL : CPS_COMPLETE, 0) ? 1 : 0;
}

int ptb_ime_place(void *hwnd, int32_t x, int32_t y, int32_t lineHeight) {
    Context c(hwnd);
    if (!c.himc) return 0;
    COMPOSITIONFORM form;
    std::memset(&form, 0, sizeof(form));
    form.dwStyle = CFS_POINT;
    form.ptCurrentPos.x = x;
    form.ptCurrentPos.y = y;
    const BOOL a = ImmSetCompositionWindow(c.himc, &form);
    CANDIDATEFORM cand;
    std::memset(&cand, 0, sizeof(cand));
    cand.dwIndex = 0;
    cand.dwStyle = CFS_EXCLUDE;
    cand.ptCurrentPos.x = x;
    cand.ptCurrentPos.y = y + lineHeight;
    cand.rcArea.left = x;
    cand.rcArea.top = y;
    cand.rcArea.right = x + 1;
    cand.rcArea.bottom = y + lineHeight;
    const BOOL b = ImmSetCandidateWindow(c.himc, &cand);
    return a && b ? 1 : 0;
}

int ptb_ime_windows(void *hwnd, int32_t out[10]) {
    Context c(hwnd);
    if (!c.himc) return 0;
    COMPOSITIONFORM form;
    std::memset(&form, 0, sizeof(form));
    CANDIDATEFORM cand;
    std::memset(&cand, 0, sizeof(cand));
    const BOOL a = ImmGetCompositionWindow(c.himc, &form);
    const BOOL b = ImmGetCandidateWindow(c.himc, 0, &cand);
    out[0] = static_cast<int32_t>(form.dwStyle);
    out[1] = form.ptCurrentPos.x;
    out[2] = form.ptCurrentPos.y;
    out[3] = static_cast<int32_t>(cand.dwStyle);
    out[4] = cand.ptCurrentPos.x;
    out[5] = cand.ptCurrentPos.y;
    out[6] = cand.rcArea.left;
    out[7] = cand.rcArea.top;
    out[8] = cand.rcArea.right;
    out[9] = cand.rcArea.bottom;
    return (a ? 1 : 0) | (b ? 2 : 0);
}

int ptb_ime_status(void *hwnd, uint32_t out[3]) {
    Context c(hwnd);
    if (!c.himc) return 0;
    DWORD conversion = 0, sentence = 0;
    ImmGetConversionStatus(c.himc, &conversion, &sentence);
    out[0] = conversion;
    out[1] = sentence;
    out[2] = ImmGetOpenStatus(c.himc) ? 1 : 0;
    return 1;
}

int ptb_ime_set_status(void *hwnd, int open, uint32_t conversion) {
    Context c(hwnd);
    if (!c.himc) return 0;
    DWORD current = 0, sentence = 0;
    ImmGetConversionStatus(c.himc, &current, &sentence);
    const BOOL a = ImmSetOpenStatus(c.himc, open ? TRUE : FALSE);
    const BOOL b = ImmSetConversionStatus(c.himc, conversion, sentence);
    return a && b ? 1 : 0;
}

int ptb_ime_set_composition(void *hwnd, const uint16_t *text, uint32_t len) {
    Context c(hwnd);
    if (!c.himc) return 0;
    return ImmSetCompositionStringW(c.himc, SCS_SETSTR, const_cast<uint16_t *>(text), len * 2, nullptr, 0) ? 1 : 0;
}

int ptb_ime_korean(int activate, uint16_t *out, int cap) {
    std::wstring report;
    ITfInputProcessorProfileMgr *mgr = nullptr;
    HRESULT hr = CoCreateInstance(kProfilesClsid, nullptr, CLSCTX_INPROC_SERVER, kProfileMgrIid, reinterpret_cast<void **>(&mgr));
    if (FAILED(hr) || !mgr) {
        appendf(report, L"TSF profile manager: 0x%08lX", static_cast<unsigned long>(hr));
        copyOut(report, out, cap);
        return -1;
    }
    TF_INPUTPROCESSORPROFILE active;
    std::memset(&active, 0, sizeof(active));
    hr = mgr->GetActiveProfile(kKeyboardCategory, &active);
    appendf(report, L"active before: hr=0x%08lX lang=%04X type=%lu hkl=%p; ", static_cast<unsigned long>(hr),
            static_cast<unsigned>(active.langid), static_cast<unsigned long>(active.dwProfileType), static_cast<void *>(active.hkl));
    IEnumTfInputProcessorProfiles *profiles = nullptr;
    hr = mgr->EnumProfiles(0x0412, &profiles);
    int found = 0;
    TF_INPUTPROCESSORPROFILE korean;
    std::memset(&korean, 0, sizeof(korean));
    appendf(report, L"Korean profiles (hr=0x%08lX):", static_cast<unsigned long>(hr));
    if (SUCCEEDED(hr) && profiles) {
        TF_INPUTPROCESSORPROFILE p;
        ULONG n = 0;
        while (profiles->Next(1, &p, &n) == S_OK && n == 1) {
            appendf(report, L" [type=%lu flags=0x%lX ", static_cast<unsigned long>(p.dwProfileType), static_cast<unsigned long>(p.dwFlags));
            report += guidText(p.clsid);
            report += L"]";
            if (p.dwProfileType == TF_PROFILETYPE_INPUTPROCESSOR && !found) {
                korean = p;
                found = 1;
            }
        }
        profiles->Release();
    }
    int result = found;
    if (activate && found) {
        if (!gHaveBefore) {
            gBefore = active;
            gHaveBefore = true;
        }
        hr = mgr->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, 0x0412, korean.clsid, korean.guidProfile, nullptr,
                                  TF_IPPMF_FORPROCESS | TF_IPPMF_ENABLEPROFILE | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE);
        TF_INPUTPROCESSORPROFILE now;
        std::memset(&now, 0, sizeof(now));
        const HRESULT hr2 = mgr->GetActiveProfile(kKeyboardCategory, &now);
        appendf(report, L"; activate hr=0x%08lX; active after: hr=0x%08lX lang=%04X type=%lu", static_cast<unsigned long>(hr),
                static_cast<unsigned long>(hr2), static_cast<unsigned>(now.langid), static_cast<unsigned long>(now.dwProfileType));
        result = now.langid == 0x0412 && now.dwProfileType == TF_PROFILETYPE_INPUTPROCESSOR ? 1 : -1;
    }
    mgr->Release();
    copyOut(report, out, cap);
    return result;
}

int ptb_ime_korean_restore(void) {
    if (!gHaveBefore) return 0;
    ITfInputProcessorProfileMgr *mgr = nullptr;
    HRESULT hr = CoCreateInstance(kProfilesClsid, nullptr, CLSCTX_INPROC_SERVER, kProfileMgrIid, reinterpret_cast<void **>(&mgr));
    if (FAILED(hr) || !mgr) return -1;
    hr = mgr->ActivateProfile(gBefore.dwProfileType, gBefore.langid, gBefore.clsid, gBefore.guidProfile, gBefore.hkl,
                              TF_IPPMF_FORPROCESS | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE);
    mgr->Release();
    gHaveBefore = false;
    return SUCCEEDED(hr) ? 1 : -1;
}

}  // extern "C"
