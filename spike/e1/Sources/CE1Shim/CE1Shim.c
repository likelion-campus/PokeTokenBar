// Throwaway (Track B experiment E1). See include/CE1Shim.h.
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <realtimeapiset.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "CE1Shim.h"

static CRITICAL_SECTION g_log_lock;
static DWORD g_ctor_tid;
static HANDLE g_main_thread;
static LARGE_INTEGER g_qpf;

__attribute__((constructor)) static void e1_init(void) {
    InitializeCriticalSection(&g_log_lock);
    g_ctor_tid = GetCurrentThreadId();
    g_main_thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, g_ctor_tid);
    QueryPerformanceFrequency(&g_qpf);
}

void e1_log(const char *line) {
    EnterCriticalSection(&g_log_lock);
    fputs(line, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    LeaveCriticalSection(&g_log_lock);
}

uint32_t e1_tid(void) { return GetCurrentThreadId(); }
uint32_t e1_ctor_tid(void) { return g_ctor_tid; }
double e1_now_ms(void) {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)g_qpf.QuadPart;
}
uint32_t e1_qs_allinput(void) { return QS_ALLINPUT; }

// ---- P1 symbols -------------------------------------------------------------

static char g_modbuf[1024];

static FARPROC e1_find_in(const char *name, HMODULE *where) {
    HMODULE mods[1024];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof mods, &needed)) return NULL;
    DWORD n = needed / sizeof(HMODULE);
    if (n > 1024) n = 1024;
    for (DWORD i = 0; i < n; i++) {
        FARPROC p = GetProcAddress(mods[i], name);
        if (p) {
            if (where) *where = mods[i];
            return p;
        }
    }
    return NULL;
}

static FARPROC e1_find(const char *name) { return e1_find_in(name, NULL); }

const char *e1_symbol_module(const char *name) {
    HMODULE m = NULL;
    if (!e1_find_in(name, &m)) return NULL;
    GetModuleFileNameA(m, g_modbuf, sizeof g_modbuf);
    return g_modbuf;
}

void e1_list_modules(const char *prefix, const char *filter) {
    HMODULE mods[1024];
    DWORD needed = 0;
    if (!EnumProcessModules(GetCurrentProcess(), mods, sizeof mods, &needed)) return;
    DWORD n = needed / sizeof(HMODULE);
    if (n > 1024) n = 1024;
    char low[64];
    size_t fl = strlen(filter);
    if (fl >= sizeof low) fl = sizeof low - 1;
    for (size_t i = 0; i < fl; i++) low[i] = (char)tolower((unsigned char)filter[i]);
    low[fl] = 0;
    for (DWORD i = 0; i < n; i++) {
        char path[1024], lp[1024], line[1200];
        GetModuleFileNameA(mods[i], path, sizeof path);
        size_t pl = strlen(path);
        for (size_t j = 0; j <= pl; j++) lp[j] = (char)tolower((unsigned char)path[j]);
        if (strstr(lp, low)) {
            snprintf(line, sizeof line, "%s %s", prefix, path);
            e1_log(line);
        }
    }
}

// ---- CF / dispatch SPI ------------------------------------------------------

typedef void *(*fn_rl_get)(void);
typedef void (*fn_set_mask)(void *rl, uint32_t mask, const void *mode);
typedef uint32_t (*fn_get_mask)(void *rl, const void *mode);
typedef void (*fn_set_handler)(void *rl, const void *mode, void (*func)(void));
typedef void *(*fn_obs_create)(const void *alloc, uintptr_t activities, unsigned char repeats, intptr_t order,
                               void (*cb)(void *obs, uintptr_t activity, void *info), void *ctx);
typedef void (*fn_add_obs)(void *rl, void *obs, const void *mode);
typedef void *(*fn_dq_handle)(void);
typedef void (*fn_dq_drain)(void *);

static volatile LONG g_done;
static volatile LONG g_wakeups;
static volatile LONG g_pump_calls;
static volatile LONG g_pumped;

void e1_set_done(void) { InterlockedExchange(&g_done, 1); }
int e1_is_done(void) { return (int)g_done; }
long e1_wakeups(void) { return g_wakeups; }
long e1_pump_calls(void) { return g_pump_calls; }
long e1_pumped(void) { return g_pumped; }

static const void *e1_default_mode(void) {
    const void **p = (const void **)e1_find("kCFRunLoopDefaultMode");
    return p ? *p : NULL;
}

int e1_cf_set_mask(uint32_t mask) {
    fn_rl_get getMain = (fn_rl_get)e1_find("CFRunLoopGetMain");
    fn_set_mask set = (fn_set_mask)e1_find("_CFRunLoopSetWindowsMessageQueueMask");
    const void *mode = e1_default_mode();
    if (!getMain || !set || !mode) return -1;
    set(getMain(), mask, mode);
    return 0;
}

uint32_t e1_cf_get_mask(void) {
    fn_rl_get getMain = (fn_rl_get)e1_find("CFRunLoopGetMain");
    fn_get_mask get = (fn_get_mask)e1_find("_CFRunLoopGetWindowsMessageQueueMask");
    const void *mode = e1_default_mode();
    if (!getMain || !get || !mode) return 0xFFFFFFFFu;
    return get(getMain(), mode);
}

static void e1_drain_all(void) {
    MSG m;
    LONG n = 0;
    InterlockedIncrement(&g_pump_calls);
    while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
        if (m.message == WM_QUIT) {
            e1_set_done();
            break;
        }
        TranslateMessage(&m);
        DispatchMessageW(&m);
        n++;
    }
    InterlockedExchangeAdd(&g_pumped, n);
}

int e1_cf_install_drain_handler(void) {
    fn_rl_get getMain = (fn_rl_get)e1_find("CFRunLoopGetMain");
    fn_set_handler set = (fn_set_handler)e1_find("_CFRunLoopSetWindowsMessageQueueHandler");
    const void *mode = e1_default_mode();
    if (!getMain || !set || !mode) return -1;
    set(getMain(), mode, e1_drain_all);
    return 0;
}

static void e1_after_waiting(void *obs, uintptr_t activity, void *info) {
    (void)obs; (void)activity; (void)info;
    InterlockedIncrement(&g_wakeups);
}

int e1_cf_count_wakeups(void) {
    fn_rl_get getMain = (fn_rl_get)e1_find("CFRunLoopGetMain");
    fn_obs_create create = (fn_obs_create)e1_find("CFRunLoopObserverCreate");
    fn_add_obs add = (fn_add_obs)e1_find("CFRunLoopAddObserver");
    const void **common = (const void **)e1_find("kCFRunLoopCommonModes");
    if (!getMain || !create || !add || !common) return -1;
    void *obs = create(NULL, 64 /* kCFRunLoopAfterWaiting */, 1, 0, e1_after_waiting, NULL);
    if (!obs) return -1;
    add(getMain(), obs, *common);
    return 0;
}

void *e1_dispatch_handle(void) {
    fn_dq_handle f = (fn_dq_handle)e1_find("_dispatch_get_main_queue_port_4CF");
    return f ? f() : NULL;
}

static fn_dq_drain g_dq_drain;
int e1_dispatch_drain(void) {
    if (!g_dq_drain) g_dq_drain = (fn_dq_drain)e1_find("_dispatch_main_queue_callback_4CF");
    if (!g_dq_drain) return -1;
    g_dq_drain(NULL);
    return 0;
}

// ---- Window -----------------------------------------------------------------

#define E1_WM_POST (WM_APP + 1)
#define E1_MAXPOST 256

static e1_msg_cb g_cb;
static volatile LONG g_app5_seen;
static volatile LONG g_sent_on_main;
static volatile LONG g_char_n;
static uint32_t g_chars[8];
static double g_post_t0[E1_MAXPOST];
static double g_post_lat[E1_MAXPOST];
static volatile LONG g_post_delivered, g_post_on_main;

void e1_set_msg_callback(e1_msg_cb cb) { g_cb = cb; }

static LRESULT CALLBACK e1_wndproc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case E1_WM_POST: {
        double t1 = e1_now_ms();
        int i = (int)w;
        if (i >= 0 && i < E1_MAXPOST) g_post_lat[i] = t1 - g_post_t0[i];
        InterlockedIncrement(&g_post_delivered);
        if (GetCurrentThreadId() == g_ctor_tid) InterlockedIncrement(&g_post_on_main);
        return 0;
    }
    case WM_APP + 5:
        InterlockedIncrement(&g_app5_seen);
        return 0;
    case WM_APP + 6:
        if (GetCurrentThreadId() == g_ctor_tid) InterlockedIncrement(&g_sent_on_main);
        return 0x5151;
    case WM_CHAR: {
        LONG i = InterlockedIncrement(&g_char_n) - 1;
        if (i >= 0 && i < 8) g_chars[i] = (uint32_t)w;
        return 0;
    }
    case WM_TIMER:
        if (w == 1) {
            KillTimer(h, 1);
            EndMenu();
        }
        if (w == 4) {
            KillTimer(h, 4);
            PostMessageW(h, WM_KEYDOWN, VK_DOWN, 0);
            PostMessageW(h, WM_KEYDOWN, VK_RETURN, 0);
        }
        if (g_cb) g_cb(msg, w, l);
        return 0;
    case WM_ENTERMENULOOP:
    case WM_EXITMENULOOP:
        if (g_cb) g_cb(msg, w, l);
        break;
    default:
        if (msg >= WM_APP + 2 && msg <= WM_APP + 40) {
            if (g_cb) g_cb(msg, w, l);
            return 0;
        }
    }
    return DefWindowProcW(h, msg, w, l);
}

void *e1_make_window(int messageOnly) {
    static int registered;
    HINSTANCE inst = GetModuleHandleW(NULL);
    if (!registered) {
        WNDCLASSEXW wc;
        memset(&wc, 0, sizeof wc);
        wc.cbSize = sizeof wc;
        wc.lpfnWndProc = e1_wndproc;
        wc.hInstance = inst;
        wc.lpszClassName = L"PTBE1Sink";
        RegisterClassExW(&wc);
        registered = 1;
    }
    return CreateWindowExW(0, L"PTBE1Sink", L"ptbe1", WS_OVERLAPPED, 0, 0, 100, 100,
                           messageOnly ? HWND_MESSAGE : NULL, NULL, inst, NULL);
}

int e1_post(void *hwnd, uint32_t msg, uintptr_t w, intptr_t l) { return PostMessageW((HWND)hwnd, msg, w, l); }
intptr_t e1_send(void *hwnd, uint32_t msg, uintptr_t w, intptr_t l) { return SendMessageW((HWND)hwnd, msg, w, l); }
int e1_is_window(void *hwnd) { return IsWindow((HWND)hwnd) ? 1 : 0; }
uint32_t e1_window_thread(void *hwnd) { return GetWindowThreadProcessId((HWND)hwnd, NULL); }
int e1_thread_alive(uint32_t tid) {
    HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid);
    if (!h) return -1;
    DWORD code = 0;
    BOOL ok = GetExitCodeThread(h, &code);
    CloseHandle(h);
    return ok && code == STILL_ACTIVE ? 1 : 0;
}

typedef struct { HWND h; int count, interval, delay; } poster_args;

static DWORD WINAPI e1_poster_main(LPVOID p) {
    poster_args a = *(poster_args *)p;
    free(p);
    Sleep(a.delay);
    for (int i = 0; i < a.count && i < E1_MAXPOST; i++) {
        Sleep(a.interval);
        g_post_t0[i] = e1_now_ms();
        PostMessageW(a.h, E1_WM_POST, (WPARAM)i, 0);
    }
    return 0;
}

void e1_start_poster(void *hwnd, int count, int interval_ms, int delay_ms) {
    for (int i = 0; i < E1_MAXPOST; i++) g_post_lat[i] = -1;
    g_post_delivered = 0;
    g_post_on_main = 0;
    poster_args *a = (poster_args *)malloc(sizeof *a);
    a->h = (HWND)hwnd;
    a->count = count;
    a->interval = interval_ms;
    a->delay = delay_ms;
    HANDLE t = CreateThread(NULL, 0, e1_poster_main, a, 0, NULL);
    if (t) CloseHandle(t);
}

static int e1_cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

int e1_poster_stats(double *median, double *maxv, int *on_main) {
    double v[E1_MAXPOST];
    int n = 0;
    for (int i = 0; i < E1_MAXPOST; i++) if (g_post_lat[i] >= 0) v[n++] = g_post_lat[i];
    qsort(v, n, sizeof(double), e1_cmp_double);
    *median = n ? v[n / 2] : -1;
    *maxv = n ? v[n - 1] : -1;
    *on_main = (int)g_post_on_main;
    return (int)g_post_delivered;
}

// ---- Loops ------------------------------------------------------------------

long e1_run_dispatch_loop(double (*pass)(void)) {
    HANDLE h = (HANDLE)e1_dispatch_handle();
    if (!h) return -1;
    while (!g_done) {
        double ms = pass ? pass() : -1;
        if (g_done) break;
        DWORD timeout;
        if (ms < 0) timeout = 60000;
        else if (ms < 1) timeout = 1;
        else if (ms > 60000) timeout = 60000;
        else timeout = (DWORD)(ms + 0.999);
        DWORD r = MsgWaitForMultipleObjectsEx(1, &h, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        InterlockedIncrement(&g_wakeups);
        if (r == WAIT_OBJECT_0) e1_dispatch_drain();
        else if (r == WAIT_OBJECT_0 + 1) e1_drain_all();
    }
    return g_wakeups;
}

long e1_run_polling_loop(void (*pass)(void), int interval_ms) {
    UINT_PTR t = SetTimer(NULL, 0, (UINT)interval_ms, NULL);
    MSG m;
    while (!g_done) {
        BOOL r = GetMessageW(&m, NULL, 0, 0);
        if (r <= 0) break;
        InterlockedIncrement(&g_wakeups);
        if (m.message == WM_TIMER && m.hwnd == NULL && m.wParam == t) {
            pass();
            continue;
        }
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    KillTimer(NULL, t);
    return g_wakeups;
}

// ---- Idle cost --------------------------------------------------------------

static double e1_ft_ms(FILETIME f) {
    ULARGE_INTEGER u;
    u.LowPart = f.dwLowDateTime;
    u.HighPart = f.dwHighDateTime;
    return (double)u.QuadPart / 10000.0;
}

#define E1_MAXT 512
static DWORD g_mark_tids[E1_MAXT];
static ULONG64 g_mark_cyc[E1_MAXT];
static int g_mark_n;

static int e1_enum_threads(DWORD *tids, int max) {
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    int n = 0;
    if (s == INVALID_HANDLE_VALUE) return 0;
    THREADENTRY32 te;
    te.dwSize = sizeof te;
    DWORD pid = GetCurrentProcessId();
    if (Thread32First(s, &te)) {
        do {
            if (te.th32OwnerProcessID == pid && n < max) tids[n++] = te.th32ThreadID;
        } while (Thread32Next(s, &te));
    }
    CloseHandle(s);
    return n;
}

static ULONG64 e1_thread_cycles(DWORD tid) {
    HANDLE h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, FALSE, tid);
    ULONG64 c = 0;
    if (h) {
        QueryThreadCycleTime(h, &c);
        CloseHandle(h);
    }
    return c;
}

int e1_thread_count(void) {
    DWORD tids[E1_MAXT];
    return e1_enum_threads(tids, E1_MAXT);
}

void e1_cpu_now(e1_cpu *o) {
    o->threads = 0;  // clocks only: thread enumeration is expensive and would land inside a delta
    FILETIME c, e, k, u;
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    o->user_ms = e1_ft_ms(u);
    o->kernel_ms = e1_ft_ms(k);
    ULONG64 cy = 0;
    QueryProcessCycleTime(GetCurrentProcess(), &cy);
    o->cycles = cy;
    ULONG64 mc = 0;
    if (g_main_thread) QueryThreadCycleTime(g_main_thread, &mc);
    o->main_cycles = mc;
}

void e1_threads_mark(void) {
    g_mark_n = e1_enum_threads(g_mark_tids, E1_MAXT);
    for (int i = 0; i < g_mark_n; i++) g_mark_cyc[i] = e1_thread_cycles(g_mark_tids[i]);
}

void e1_threads_report(const char *prefix) {
    DWORD now[E1_MAXT];
    int n = e1_enum_threads(now, E1_MAXT);
    for (int i = 0; i < n; i++) {
        ULONG64 c = e1_thread_cycles(now[i]);
        ULONG64 base = 0;
        int known = 0;
        for (int j = 0; j < g_mark_n; j++) {
            if (g_mark_tids[j] == now[i]) {
                base = g_mark_cyc[j];
                known = 1;
                break;
            }
        }
        char line[256];
        snprintf(line, sizeof line, "%s tid=%lu main=%d new=%d dcycles=%llu", prefix, (unsigned long)now[i],
                 now[i] == g_ctor_tid, !known, (unsigned long long)(c - base));
        e1_log(line);
    }
}

// ---- P7 menu / P8 tray --------------------------------------------------------

int e1_track_menu(void *hwnd, int cancel_ms, int drain_ms, int keys_ms, double *t_call, double *t_return, unsigned long *err) {
    HWND h = (HWND)hwnd;
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING, 1, L"One");
    AppendMenuW(m, MF_STRING, 2, L"Two");
    SetForegroundWindow(h);
    SetTimer(h, 1, (UINT)cancel_ms, NULL);
    if (drain_ms > 0) SetTimer(h, 3, (UINT)drain_ms, NULL);
    if (keys_ms > 0) SetTimer(h, 4, (UINT)keys_ms, NULL);
    *t_call = e1_now_ms();
    SetLastError(0);
    int r = (int)TrackPopupMenuEx(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, 100, 100, h, NULL);
    *err = GetLastError();
    *t_return = e1_now_ms();
    KillTimer(h, 1);
    KillTimer(h, 3);
    KillTimer(h, 4);
    PostMessageW(h, WM_NULL, 0, 0);
    DestroyMenu(m);
    return r;
}

static int e1_count_process(const wchar_t *exe) {
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (s == INVALID_HANDLE_VALUE) return -1;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof pe;
    int n = 0;
    if (Process32FirstW(s, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, exe) == 0) n++;
        } while (Process32NextW(s, &pe));
    }
    CloseHandle(s);
    return n;
}

void e1_tray_probe(void *hwnd) {
    char line[600];
    DWORD sid = 0, n = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &sid);
    wchar_t ws[128] = L"?", dk[128] = L"?";
    GetUserObjectInformationW(GetProcessWindowStation(), UOI_NAME, ws, sizeof ws, &n);
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, dk, sizeof dk, &n);
    HWND tray = FindWindowW(L"Shell_TrayWnd", NULL);
    snprintf(line, sizeof line, "E1.P8 VALUE session=%lu winsta=%ls desktop=%ls Shell_TrayWnd=%s explorer_processes=%d",
             (unsigned long)sid, ws, dk, tray ? "present" : "absent", e1_count_process(L"explorer.exe"));
    e1_log(line);

    NOTIFYICONDATAW nid;
    memset(&nid, 0, sizeof nid);
    nid.cbSize = sizeof nid;
    nid.hWnd = (HWND)hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_APP + 20;
    nid.hIcon = LoadIconW(NULL, (LPCWSTR)IDI_APPLICATION);
    wcscpy_s(nid.szTip, 128, L"ptbe1");
    double t0 = e1_now_ms();
    SetLastError(0);
    BOOL add = Shell_NotifyIconW(NIM_ADD, &nid);
    DWORD eAdd = GetLastError();
    double tAdd = e1_now_ms() - t0;
    nid.uVersion = NOTIFYICON_VERSION_4;
    SetLastError(0);
    BOOL ver = Shell_NotifyIconW(NIM_SETVERSION, &nid);
    DWORD eVer = GetLastError();
    nid.uFlags = NIF_INFO;
    wcscpy_s(nid.szInfoTitle, 64, L"ptbe1");
    wcscpy_s(nid.szInfo, 256, L"balloon test");
    nid.dwInfoFlags = NIIF_INFO;
    SetLastError(0);
    BOOL info = Shell_NotifyIconW(NIM_MODIFY, &nid);
    DWORD eInfo = GetLastError();
    NOTIFYICONIDENTIFIER id;
    memset(&id, 0, sizeof id);
    id.cbSize = sizeof id;
    id.hWnd = (HWND)hwnd;
    id.uID = 1;
    RECT r;
    memset(&r, 0, sizeof r);
    HRESULT hr = Shell_NotifyIconGetRect(&id, &r);
    nid.uFlags = 0;
    SetLastError(0);
    BOOL del = Shell_NotifyIconW(NIM_DELETE, &nid);
    DWORD eDel = GetLastError();
    snprintf(line, sizeof line,
             "E1.P8 %s nim_add=%d err=%lu add_ms=%.1f nim_setversion=%d err=%lu nif_info_modify=%d err=%lu "
             "getrect_hr=0x%08lx rect=%ld,%ld,%ld,%ld nim_delete=%d err=%lu",
             add ? "PASS" : "FAIL", add, (unsigned long)eAdd, tAdd, ver, (unsigned long)eVer, info,
             (unsigned long)eInfo, (unsigned long)hr, r.left, r.top, r.right, r.bottom, del, (unsigned long)eDel);
    e1_log(line);
}

// ---- Unicode and hook probes (P2 k, l) ----------------------------------------

static HHOOK g_hook;
static volatile LONG g_hook_post, g_hook_char, g_hook_eaten;
static uint32_t g_hook_char_w;
static volatile LONG g_hook_flags_seen = -1;
static volatile LONG g_hook_redispatch, g_hook_redispatched;

// Sees every message a PeekMessage/GetMessage on this thread removes, before it is dispatched. CF's pump passes
// PM_REMOVE | PM_NOYIELD, so test the bit. Rewriting a message to WM_NULL "eats" it (where IsDialogMessageW would go).
static LRESULT CALLBACK e1_getmsg_hook(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && (w & PM_REMOVE)) {
        MSG *m = (MSG *)l;
        if (m->message == E1_WM_POST) {
            InterlockedIncrement(&g_hook_post);
            InterlockedExchange(&g_hook_flags_seen, (LONG)w);
        }
        if (m->message == WM_CHAR) {
            g_hook_char_w = (uint32_t)m->wParam;
            InterlockedIncrement(&g_hook_char);
            if (g_hook_redispatch) {
                // Deliver the Unicode form ourselves, then let CF's ANSI DispatchMessage see only WM_NULL.
                MSG copy = *m;
                m->message = WM_NULL;
                DispatchMessageW(&copy);
                InterlockedIncrement(&g_hook_redispatched);
            }
        }
        if (m->message == WM_APP + 5) {
            m->message = WM_NULL;
            InterlockedIncrement(&g_hook_eaten);
        }
    }
    return CallNextHookEx(g_hook, code, w, l);
}

int e1_install_getmsg_hook(void) {
    g_hook = SetWindowsHookExW(WH_GETMESSAGE, e1_getmsg_hook, NULL, GetCurrentThreadId());
    return g_hook ? 0 : (int)GetLastError();
}

void e1_hook_stats(int *posts, int *chars, uint32_t *last_char) {
    *posts = (int)g_hook_post;
    *chars = (int)g_hook_char;
    *last_char = g_hook_char_w;
}

int e1_hook_flags_seen(void) { return (int)g_hook_flags_seen; }
void e1_set_hook_redispatch(int on) { InterlockedExchange(&g_hook_redispatch, on); }
int e1_hook_redispatched(void) { return (int)g_hook_redispatched; }

// Text probe: a shown window that takes focus, and real input through SendInput(KEYEVENTF_UNICODE) -> VK_PACKET.
// The foreground lock refuses SetForegroundWindow to a process that did not get the last input; a synthetic Alt
// press (sent before our window is up front, so it lands on the previous foreground window) lifts it.
static void e1_force_foreground(HWND h) {
    SetForegroundWindow(h);
    if (GetForegroundWindow() == h) return;
    INPUT alt[2];
    memset(alt, 0, sizeof alt);
    alt[0].type = INPUT_KEYBOARD;
    alt[0].ki.wVk = VK_MENU;
    alt[1] = alt[0];
    alt[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, alt, sizeof(INPUT));
    SetForegroundWindow(h);
    if (GetForegroundWindow() == h) return;
    HWND fg = GetForegroundWindow();
    DWORD fgTid = fg ? GetWindowThreadProcessId(fg, NULL) : 0, me = GetCurrentThreadId();
    if (fgTid && fgTid != me) AttachThreadInput(me, fgTid, TRUE);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    if (fgTid && fgTid != me) AttachThreadInput(me, fgTid, FALSE);
}

void *e1_make_visible_window(void) {
    HWND h = (HWND)e1_make_window(0);
    if (!h) return NULL;
    SetWindowPos(h, HWND_TOP, 40, 40, 200, 120, SWP_SHOWWINDOW);
    ShowWindow(h, SW_SHOW);
    e1_force_foreground(h);
    SetFocus(h);
    return h;
}
int e1_is_foreground(void *hwnd) { return GetForegroundWindow() == (HWND)hwnd ? 1 : 0; }
int e1_send_unicode_input(uint32_t ch) {
    INPUT in[2];
    memset(in, 0, sizeof in);
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wScan = (WORD)ch;
    in[0].ki.dwFlags = KEYEVENTF_UNICODE;
    in[1] = in[0];
    in[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    return (int)SendInput(2, in, sizeof(INPUT));
}
int e1_hook_eaten(void) { return (int)g_hook_eaten; }

int e1_app5_seen(void) { return (int)g_app5_seen; }

// (m) cross-thread SendMessageTimeoutW: the WndProc must run on the main thread while the sender blocks.
static volatile LONG g_sent_n, g_sent_ok;
static double g_sent_lat[16];
static DWORD WINAPI e1_sender_main(LPVOID p) {
    HWND h = (HWND)p;
    for (int i = 0; i < 5; i++) {
        Sleep(150);
        double t0 = e1_now_ms();
        DWORD_PTR result = 0;
        LRESULT ok = SendMessageTimeoutW(h, WM_APP + 6, (WPARAM)i, 0, SMTO_NORMAL, 2000, &result);
        g_sent_lat[i] = e1_now_ms() - t0;
        if (ok && result == 0x5151) InterlockedIncrement(&g_sent_ok);
        InterlockedIncrement(&g_sent_n);
    }
    return 0;
}
void e1_start_sender(void *hwnd) {
    HANDLE t = CreateThread(NULL, 0, e1_sender_main, hwnd, 0, NULL);
    if (t) CloseHandle(t);
}
int e1_sender_stats(double *maxv, int *ok, int *on_main) {
    double mx = -1;
    int n = (int)g_sent_n;
    for (int i = 0; i < n && i < 16; i++) if (g_sent_lat[i] > mx) mx = g_sent_lat[i];
    *maxv = mx;
    *ok = (int)g_sent_ok;
    *on_main = (int)g_sent_on_main;
    return n;
}

int e1_chars(uint32_t *out, int max) {
    int n = (int)g_char_n;
    for (int i = 0; i < n && i < max && i < 8; i++) out[i] = g_chars[i];
    return n;
}

int e1_is_window_unicode(void *hwnd) { return IsWindowUnicode((HWND)hwnd) ? 1 : 0; }
uint32_t e1_acp(void) { return GetACP(); }

void e1_kill_self(unsigned int code) { TerminateProcess(GetCurrentProcess(), code); }

const char *e1_self_path(void) {
    static char buf[4096];
    wchar_t w[1024];
    DWORD n = GetModuleFileNameW(NULL, w, 1024);
    if (n == 0 || n >= 1024) return "";
    WideCharToMultiByte(CP_UTF8, 0, w, (int)n + 1, buf, sizeof buf, NULL, NULL);
    return buf;
}

#endif
