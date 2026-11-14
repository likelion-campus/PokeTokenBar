#ifndef CE1SHIM_H
#define CE1SHIM_H
// Throwaway (Track B experiment E1): Win32 + CF/dispatch SPI helpers for the main-loop probes.
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/// One line to stdout, locked and flushed (survives TerminateProcess).
void e1_log(const char *line);
uint32_t e1_tid(void);
/// Thread id that ran this shim's CRT constructor = the process main thread.
uint32_t e1_ctor_tid(void);
double e1_now_ms(void);
uint32_t e1_qs_allinput(void);

// P1: symbol lookup over every loaded module (EnumProcessModules + GetProcAddress).
/// Module path that exports `name`, or NULL. The buffer is reused by the next call.
const char *e1_symbol_module(const char *name);
/// Logs every loaded module whose path contains `filter` (case-insensitive) with `prefix`.
void e1_list_modules(const char *prefix, const char *filter);

// CF / dispatch SPI, looked up at runtime.
/// _CFRunLoopSetWindowsMessageQueueMask(CFRunLoopGetMain(), mask, kCFRunLoopDefaultMode). 0 ok, -1 missing.
int e1_cf_set_mask(uint32_t mask);
/// Returns the mask for the default mode, or 0xFFFFFFFF if the getter is missing.
uint32_t e1_cf_get_mask(void);
/// _CFRunLoopSetWindowsMessageQueueHandler(main, default mode, drain-all pump). Main thread only. 0 ok, -1 missing.
int e1_cf_install_drain_handler(void);
/// Adds a kCFRunLoopAfterWaiting observer (common modes) to the main run loop that counts wakeups. 0 ok, -1 missing.
int e1_cf_count_wakeups(void);
void *e1_dispatch_handle(void);
/// _dispatch_main_queue_callback_4CF(NULL). 0 ok, -1 missing.
int e1_dispatch_drain(void);

// Window + messages.
typedef void (*e1_msg_cb)(uint32_t msg, uintptr_t wparam, intptr_t lparam);
void e1_set_msg_callback(e1_msg_cb cb);
/// Hidden top-level window (messageOnly 0) or HWND_MESSAGE window (1). Not shown.
void *e1_make_window(int messageOnly);
int e1_post(void *hwnd, uint32_t msg, uintptr_t w, intptr_t l);
intptr_t e1_send(void *hwnd, uint32_t msg, uintptr_t w, intptr_t l);
int e1_is_window(void *hwnd);
uint32_t e1_window_thread(void *hwnd);
int e1_thread_alive(uint32_t tid);

/// Background thread: after delay_ms, posts WM_APP+1 `count` times, interval_ms apart; the WndProc records latency.
void e1_start_poster(void *hwnd, int count, int interval_ms, int delay_ms);
/// Returns delivered count; fills median/max latency (ms) and how many ran on the ctor thread.
int e1_poster_stats(double *median, double *maxv, int *on_main);

// Loops.
void e1_set_done(void);
int e1_is_done(void);
long e1_wakeups(void);
long e1_pump_calls(void);
long e1_pumped(void);
/// Strategy 2: MsgWaitForMultipleObjectsEx on the dispatch main-queue handle. `pass` runs timers and
/// returns ms until the next timer (< 0 = none). Timeout clamped to [1 ms, 60 s]. Returns -1 if the handle is missing.
long e1_run_dispatch_loop(double (*pass)(void));
/// Strategy 3: GetMessageW + a thread SetTimer(interval_ms) that calls `pass`.
long e1_run_polling_loop(void (*pass)(void), int interval_ms);

// Idle cost.
typedef struct e1_cpu {
    double user_ms;
    double kernel_ms;
    uint64_t cycles;
    uint64_t main_cycles;
    int threads;
} e1_cpu;
/// Clocks only (threads is left 0). Use e1_thread_count outside a measured interval.
void e1_cpu_now(e1_cpu *out);
int e1_thread_count(void);
void e1_threads_mark(void);
void e1_threads_report(const char *prefix);

// P7 / P8.
/// TrackPopupMenuEx on hwnd; WM_TIMER id 1 after cancel_ms calls EndMenu. If drain_ms > 0, WM_TIMER id 3 every
/// drain_ms is forwarded to the callback while the menu runs. Returns the TrackPopupMenuEx result.
/// If keys_ms > 0, WM_TIMER id 4 after keys_ms posts WM_KEYDOWN VK_DOWN then VK_RETURN (selects item 1 if the menu sees them).
int e1_track_menu(void *hwnd, int cancel_ms, int drain_ms, int keys_ms, double *t_call, double *t_return, unsigned long *err);
void e1_tray_probe(void *hwnd);

/// TerminateProcess(GetCurrentProcess(), code): no atexit, no DLL detach.
void e1_kill_self(unsigned int code);
// P2 (k, l): what CF's message pump does to text and whether a WH_GETMESSAGE hook sees its messages.
int e1_install_getmsg_hook(void);
void e1_hook_stats(int *posts, int *chars, uint32_t *last_char);
/// WM_CHAR wParams the WndProc received, in order. Returns the count.
int e1_chars(uint32_t *out, int max);
int e1_is_window_unicode(void *hwnd);
/// Raw wParam (remove flags) the hook saw for the last WM_APP+1, or -1.
int e1_hook_flags_seen(void);
/// How many WM_APP+5 the hook rewrote to WM_NULL, and how many still reached the WndProc.
int e1_hook_eaten(void);
int e1_app5_seen(void);
/// (m) A background thread sends WM_APP+6 five times with SendMessageTimeoutW (2 s), 150 ms apart.
void e1_start_sender(void *hwnd);
int e1_sender_stats(double *maxv, int *ok, int *on_main);
uint32_t e1_acp(void);

/// GetModuleFileNameW(NULL) as UTF-8.
const char *e1_self_path(void);

#ifdef __cplusplus
}
#endif
#endif
