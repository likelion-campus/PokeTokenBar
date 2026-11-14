// The crash filter. Everything that runs while the process is dying lives here because C guarantees what Swift
// does not: no allocation, no lock, no runtime. The record is formatted into stack buffers and written with
// WriteFile to a handle opened at install. The module lookup and the minidump run on a helper thread the crashing
// thread waits on for a bounded time, so a lock the crashed thread held (heap, loader) cannot keep the process alive.
#include "CWinCrash.h"

#include <windows.h>
#include <dbghelp.h>
#include <fcntl.h>
#include <io.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct { char *p; char *end; } ptb_buf;

static void b_str(ptb_buf *b, const char *s) { while (*s && b->p < b->end) *b->p++ = *s++; }

static void b_num(ptb_buf *b, uint64_t v, unsigned base, int min_digits) {
    char tmp[24];
    int n = 0;
    do { tmp[n++] = "0123456789ABCDEF"[v % base]; v /= base; } while (v != 0 || n < min_digits);
    while (n > 0 && b->p < b->end) *b->p++ = tmp[--n];
}

static void b_hex(ptb_buf *b, uint64_t v, int digits) { b_str(b, "0x"); b_num(b, v, 16, digits); }

typedef PVOID (NTAPI *pc_to_header_fn)(PVOID, PVOID *);
typedef LONG (WINAPI *rtl_get_version_fn)(OSVERSIONINFOW *);

static HANDLE g_log = INVALID_HANDLE_VALUE;
static wchar_t g_dump_dir[520];
static char g_version[64] = "unknown";
static char g_info[160];            // " version=... os=10.0.26100", formatted at install
static ptb_crash_hook g_hook;
static pc_to_header_fn g_pc_to_header;
static LPTOP_LEVEL_EXCEPTION_FILTER g_prev;
static volatile LONG g_busy;
static EXCEPTION_POINTERS *g_ep;
static DWORD g_crash_tid;
static SYSTEMTIME g_time;
static int g_dumps;                 // minidumps are opt-in (PTB_CRASH_DUMPS=1), decided once at install

static void log_write(const char *s, size_t n) {
    DWORD written = 0;
    if (g_log != INVALID_HANDLE_VALUE) WriteFile(g_log, s, (DWORD)n, &written, NULL);
}

static void log_buf(const ptb_buf *b, const char *start) { log_write(start, (size_t)(b->p - start)); }

static void put_time(ptb_buf *b, const SYSTEMTIME *t) {
    b_num(b, t->wYear, 10, 4); b_str(b, "-"); b_num(b, t->wMonth, 10, 2); b_str(b, "-"); b_num(b, t->wDay, 10, 2);
    b_str(b, "T"); b_num(b, t->wHour, 10, 2); b_str(b, ":"); b_num(b, t->wMinute, 10, 2); b_str(b, ":"); b_num(b, t->wSecond, 10, 2);
    b_str(b, "Z");
}

static void put_common(ptb_buf *b) {
    b_str(b, " pid="); b_num(b, GetCurrentProcessId(), 10, 1);
    b_str(b, " tid="); b_num(b, g_crash_tid, 10, 1);
    b_str(b, " utc="); put_time(b, &g_time);
    b_str(b, g_info);
    b_str(b, "\n");
}

static void record_exception(EXCEPTION_POINTERS *ep) {
    char line[512];
    ptb_buf b = { line, line + sizeof line - 1 };
    EXCEPTION_RECORD *er = ep->ExceptionRecord;
    PVOID base = NULL;
    if (g_pc_to_header) g_pc_to_header(er->ExceptionAddress, &base);
    b_str(&b, "[CRASH] exception "); b_hex(&b, (uint32_t)er->ExceptionCode, 8);
    b_str(&b, " at "); b_hex(&b, (uint64_t)(uintptr_t)er->ExceptionAddress, 16);
    b_str(&b, "\n[CRASH] base="); b_hex(&b, (uint64_t)(uintptr_t)base, 16);
    b_str(&b, " offset="); b_hex(&b, base ? (uint64_t)((uintptr_t)er->ExceptionAddress - (uintptr_t)base) : 0, 1);
    put_common(&b);
    if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2) {
        ULONG_PTR kind = er->ExceptionInformation[0];
        b_str(&b, "[CRASH] access violation: ");
        b_str(&b, kind == 0 ? "read" : kind == 1 ? "write" : "execute");
        b_str(&b, " of "); b_hex(&b, (uint64_t)er->ExceptionInformation[1], 16);
        b_str(&b, "\n");
    }
    log_buf(&b, line);
}

static void record_signal(int sig) {
    char line[320];
    ptb_buf b = { line, line + sizeof line - 1 };
    b_str(&b, "[CRASH] fatal signal ");
    b_str(&b, sig == SIGABRT ? "SIGABRT (abort/assert)" : "received");
    put_common(&b);
    log_buf(&b, line);
}

static DWORD WINAPI hook_thread(LPVOID unused) { (void)unused; if (g_hook) g_hook(); return 0; }

static void put_module(void) {
    char line[320];
    ptb_buf b = { line, line + sizeof line - 1 };
    HMODULE module = NULL;
    uintptr_t address = (uintptr_t)g_ep->ExceptionRecord->ExceptionAddress;
    b_str(&b, "[CRASH] module=");
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)address, &module)) {
        wchar_t path[MAX_PATH];
        DWORD n = GetModuleFileNameW(module, path, MAX_PATH);
        DWORD start = 0;
        for (DWORD i = 0; i < n; i++) if (path[i] == L'\\' || path[i] == L'/') start = i + 1;
        for (DWORD i = start; i < n; i++) { char c = path[i] < 0x80 && path[i] >= 0x20 ? (char)path[i] : '?'; if (b.p < b.end) *b.p++ = c; }
        b_str(&b, "+"); b_hex(&b, address - (uintptr_t)module, 1);
    } else {
        b_str(&b, "unknown");
    }
    b_str(&b, "\n");
    log_buf(&b, line);
}

static void put_dump(void) {
    char name[96];
    ptb_buf nb = { name, name + sizeof name - 1 };
    char line[160];
    ptb_buf b = { line, line + sizeof line - 1 };
    wchar_t path[600];
    size_t n = 0;
    b_str(&nb, "PokeTokenBar-");
    b_num(&nb, g_time.wYear, 10, 4); b_num(&nb, g_time.wMonth, 10, 2); b_num(&nb, g_time.wDay, 10, 2);
    b_str(&nb, "-");
    b_num(&nb, g_time.wHour, 10, 2); b_num(&nb, g_time.wMinute, 10, 2); b_num(&nb, g_time.wSecond, 10, 2);
    b_str(&nb, "-"); b_num(&nb, GetCurrentProcessId(), 10, 1);
    b_str(&nb, ".dmp");
    *nb.p = 0;
    for (; g_dump_dir[n] && n < 520; n++) path[n] = g_dump_dir[n];
    path[n++] = L'\\';
    for (const char *c = name; *c && n < 599; c++) path[n++] = (wchar_t)*c;
    path[n] = 0;
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        b_str(&b, "[CRASH] dump not written: CreateFile error "); b_num(&b, GetLastError(), 10, 1); b_str(&b, "\n");
        log_buf(&b, line);
        return;
    }
    MINIDUMP_EXCEPTION_INFORMATION info = { g_crash_tid, g_ep, FALSE };
    BOOL ok = MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file, MiniDumpNormal, g_ep ? &info : NULL, NULL, NULL);
    DWORD error = ok ? 0 : GetLastError();
    CloseHandle(file);
    if (ok) { b_str(&b, "[CRASH] dump="); b_str(&b, name); b_str(&b, "\n"); }
    else { b_str(&b, "[CRASH] dump not written: MiniDumpWriteDump error "); b_num(&b, error, 10, 1); b_str(&b, "\n"); }
    log_buf(&b, line);
}

static DWORD WINAPI extras_thread(LPVOID unused) {
    (void)unused;
    if (g_hook) {
        HANDLE t = CreateThread(NULL, 0, hook_thread, NULL, 0, NULL);
        if (t) { WaitForSingleObject(t, 500); CloseHandle(t); }
    }
    if (g_ep) put_module();
    if (g_dumps) {
        put_dump();
    } else {
        static const char off[] = "[CRASH] dump=off (minidumps are opt-in: set PTB_CRASH_DUMPS=1)\n";
        log_write(off, sizeof off - 1);
    }
    return 0;
}

static void run_extras(void) {
    HANDLE t = CreateThread(NULL, 0, extras_thread, NULL, 0, NULL);
    if (t) { WaitForSingleObject(t, 5000); CloseHandle(t); }
    if (g_log != INVALID_HANDLE_VALUE) FlushFileBuffers(g_log);
}

static LONG WINAPI crash_filter(EXCEPTION_POINTERS *ep) {
    if (InterlockedCompareExchange(&g_busy, 1, 0) == 0) {
        g_ep = ep;
        g_crash_tid = GetCurrentThreadId();
        GetSystemTime(&g_time);
        record_exception(ep);
        run_extras();
    }
    if (g_prev) return g_prev(ep);
    return EXCEPTION_CONTINUE_SEARCH;
}

static void abort_handler(int sig) {
    if (InterlockedCompareExchange(&g_busy, 1, 0) == 0) {
        g_ep = NULL;
        g_crash_tid = GetCurrentThreadId();
        GetSystemTime(&g_time);
        record_signal(sig);
        run_extras();
    }
    // returning lets abort() finish as it would have
}

void ptb_crash_set_version(const char *utf8) {
    size_t n = 0;
    if (!utf8) return;
    for (; utf8[n] && n < sizeof g_version - 1; n++) {
        unsigned char c = (unsigned char)utf8[n];
        g_version[n] = (c > 0x20 && c < 0x7F) ? (char)c : '_';
    }
    g_version[n] = 0;
}

int ptb_crash_dumps_opted_in(void) {
    wchar_t value[8];
    DWORD n = GetEnvironmentVariableW(L"PTB_CRASH_DUMPS", value, 8);
    return n == 1 && value[0] == L'1';
}

int ptb_crash_install(const uint16_t *crash_log_path, const uint16_t *dump_dir, ptb_crash_hook before_dump) {
    if (g_log != INVALID_HANDLE_VALUE) return 0;
    g_log = CreateFileW((const wchar_t *)crash_log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_log == INVALID_HANDLE_VALUE) return (int)GetLastError();
    size_t i = 0;
    for (; dump_dir && dump_dir[i] && i < 519; i++) g_dump_dir[i] = (wchar_t)dump_dir[i];
    g_dump_dir[i] = 0;
    g_hook = before_dump;
    g_dumps = ptb_crash_dumps_opted_in();

    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    g_pc_to_header = ntdll ? (pc_to_header_fn)(void *)GetProcAddress(ntdll, "RtlPcToFileHeader") : NULL;
    ptb_buf b = { g_info, g_info + sizeof g_info - 1 };
    b_str(&b, " version="); b_str(&b, g_version);
    b_str(&b, " os=");
    rtl_get_version_fn get_version = ntdll ? (rtl_get_version_fn)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    OSVERSIONINFOW os;
    ZeroMemory(&os, sizeof os);
    os.dwOSVersionInfoSize = sizeof os;
    if (get_version && get_version(&os) == 0) {
        b_num(&b, os.dwMajorVersion, 10, 1); b_str(&b, "."); b_num(&b, os.dwMinorVersion, 10, 1); b_str(&b, "."); b_num(&b, os.dwBuildNumber, 10, 1);
    } else {
        b_str(&b, "unknown");
    }
    *b.p = 0;

    g_prev = SetUnhandledExceptionFilter(crash_filter);
    signal(SIGABRT, abort_handler);
    return 0;
}

int ptb_crash_redirect_stderr(const uint16_t *path) {
    HANDLE h = CreateFileW((const wchar_t *)path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return (int)GetLastError();
    int fd = _open_osfhandle((intptr_t)h, _O_APPEND | _O_BINARY);
    if (fd < 0) { CloseHandle(h); return -1; }
    if (_dup2(fd, 2) != 0) { _close(fd); return -2; }
    _close(fd);
    setvbuf(stderr, NULL, _IONBF, 0);
    return 0;
}

void ptb_crash_selftest_trigger(int mode) {
    if (mode == 0) { *(volatile int *)8 = 1; }
    else if (mode == 1) { volatile int v = *(volatile int *)8; (void)v; }
    else if (mode == 2) { abort(); }
}
