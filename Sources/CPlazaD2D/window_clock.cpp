// The plaza's frame clock (stage 6 Task 5, D4): one thread per open plaza window that posts one tick message per frame
// to the window while it runs, and sleeps on an event (zero wakeups) while parked. It touches no app state: it only waits
// and calls PostMessageW. See CPlazaD2D.h ("the plaza window").
//
// Source: IDXGIOutput::WaitForVBlank on the output that shows the window (every N-th vblank, N = max(1, floor(Hz / 60)));
// a high-resolution waitable timer at 1/60 s when there is no output, WaitForVBlank fails, or it returns in under 2 ms five
// times in a row (WARP, RDP, some hybrid GPUs, display off). The timer is armed one frame at a time (relative, no drift
// from the wall clock), so a parked clock has no timer armed either.
#include "CPlazaD2D.h"
#include "internal.h"

#include <windows.h>
#include <dxgi.h>

#include <cstdlib>
#include <cstring>
#include <new>

namespace {

using namespace ptb;

const GUID kIidDXGIFactory1 = {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};

constexpr uint32_t kRing = 1024;   // tick intervals kept for the percentiles
constexpr double kEarlyMs = 2.0;   // a vblank wait shorter than this did not wait
constexpr int kEarlyLimit = 5;     // that many in a row: fall back to the timer

double qpcMs() {
    static LARGE_INTEGER frequency = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return static_cast<double>(now.QuadPart) * 1000.0 / static_cast<double>(frequency.QuadPart);
}

struct Clock {
    HWND hwnd = nullptr;
    UINT message = 0;
    HANDLE thread = nullptr;
    DWORD threadId = 0;
    HANDLE wake = nullptr;   // auto-reset: running turned on, or stop
    HANDLE timer = nullptr;  // high-resolution when the system has it
    int highResolution = 0;
    volatile LONG refs = 2;  // the owner and the thread
    volatile LONG running = 0, stop = 0, pending = 0;
    SRWLOCK lock = SRWLOCK_INIT;  // guards output, divider, refreshHz, source, forceTimer
    IDXGIOutput *output = nullptr;
    uint32_t divider = 1;
    double refreshHz = 0;
    int32_t source = 0;  // 0 none yet, 1 vblank, 2 timer
    int forceTimer = 0;
    // Counters (written by the thread, read by the owner: plain 64-bit loads on x64).
    volatile LONG64 posted = 0, waits = 0, early = 0, fallbacks = 0, parks = 0;
    // Intervals between posted ticks, ms.
    SRWLOCK ringLock = SRWLOCK_INIT;
    double ring[kRing] = {};
    uint32_t ringCount = 0, ringNext = 0;
    double lastPost = 0;
};

void unref(Clock *c) {
    if (InterlockedDecrement(&c->refs) != 0) return;
    if (c->output) c->output->Release();
    if (c->wake) CloseHandle(c->wake);
    if (c->timer) CloseHandle(c->timer);
    if (c->thread) CloseHandle(c->thread);
    delete c;
}

// One frame on the timer: due one 1/60 s after the previous due time (or now, after a park or a late wake).
void waitTimer(Clock *c, double &nextDue) {
    const double period = 1000.0 / 60.0;
    const double now = qpcMs();
    nextDue = (nextDue <= 0 || nextDue < now - period) ? now + period : nextDue + period;
    double ms = nextDue - now;
    if (ms < 0) ms = 0;
    LARGE_INTEGER due;
    due.QuadPart = -static_cast<LONGLONG>(ms * 10000.0);  // relative, 100 ns units
    if (!c->timer || !SetWaitableTimerEx(c->timer, &due, 0, nullptr, nullptr, nullptr, 0)) {
        Sleep(static_cast<DWORD>(ms + 0.5));
        return;
    }
    WaitForSingleObject(c->timer, INFINITE);
}

DWORD WINAPI clockMain(void *arg) {
    Clock *c = static_cast<Clock *>(arg);
    typedef HRESULT(WINAPI * DescribeFn)(HANDLE, PCWSTR);
    if (HMODULE k = GetModuleHandleW(L"kernel32.dll")) {
        if (auto describe = reinterpret_cast<DescribeFn>(reinterpret_cast<void *>(GetProcAddress(k, "SetThreadDescription")))) {
            describe(GetCurrentThread(), L"PokeTokenBar plaza clock");
        }
    }
    double nextDue = 0;
    int earlyRun = 0;
    bool wasRunning = false;
    while (!c->stop) {
        if (!c->running) {
            if (wasRunning) InterlockedIncrement64(&c->parks);
            wasRunning = false;
            nextDue = 0;
            WaitForSingleObject(c->wake, INFINITE);  // parked: no wakeup until running or stop
            continue;
        }
        wasRunning = true;
        IDXGIOutput *out = nullptr;
        uint32_t divider = 1;
        AcquireSRWLockShared(&c->lock);
        if (c->source == 1 && c->output && !c->forceTimer) {
            out = c->output;
            out->AddRef();
            divider = c->divider;
        }
        ReleaseSRWLockShared(&c->lock);
        bool waited = false;
        if (out) {
            bool fallback = false;
            for (uint32_t i = 0; i < divider && !c->stop; i++) {
                const double t0 = qpcMs();
                const HRESULT hr = out->WaitForVBlank();
                const double dt = qpcMs() - t0;
                if (FAILED(hr)) {
                    fallback = true;
                    break;
                }
                if (dt < kEarlyMs) InterlockedIncrement64(&c->early);
                earlyRun = dt < kEarlyMs ? earlyRun + 1 : 0;
                if (earlyRun >= kEarlyLimit) {
                    fallback = true;
                    break;
                }
            }
            out->Release();
            if (fallback) {
                earlyRun = 0;
                InterlockedIncrement64(&c->fallbacks);
                AcquireSRWLockExclusive(&c->lock);
                c->source = 2;  // until the window's monitor is set again
                if (c->output) c->output->Release();
                c->output = nullptr;
                ReleaseSRWLockExclusive(&c->lock);
            } else {
                waited = true;
            }
        }
        if (!waited && !c->stop) waitTimer(c, nextDue);
        InterlockedIncrement64(&c->waits);
        if (c->stop || !c->running) continue;
        if (InterlockedCompareExchange(&c->pending, 1, 0) == 0) {
            if (PostMessageW(c->hwnd, c->message, 0, 0)) {
                InterlockedIncrement64(&c->posted);
                const double now = qpcMs();
                AcquireSRWLockExclusive(&c->ringLock);
                if (c->lastPost > 0) {
                    c->ring[c->ringNext] = now - c->lastPost;
                    c->ringNext = (c->ringNext + 1) % kRing;
                    if (c->ringCount < kRing) c->ringCount++;
                }
                c->lastPost = now;
                ReleaseSRWLockExclusive(&c->ringLock);
            } else {
                InterlockedExchange(&c->pending, 0);  // the window is gone; the owner stops the clock
            }
        }
    }
    unref(c);
    return 0;
}

int cmpDouble(const void *a, const void *b) {
    const double x = *static_cast<const double *>(a), y = *static_cast<const double *>(b);
    return x < y ? -1 : (x > y ? 1 : 0);
}

}  // namespace

extern "C" PTBClock *ptb_clock_create(void *hwnd, uint32_t message) {
    if (!hwnd) {
        fail("ptb_clock_create", E_INVALIDARG);
        return nullptr;
    }
    Clock *c = new (std::nothrow) Clock();
    if (!c) {
        fail("ptb_clock_create", E_OUTOFMEMORY);
        return nullptr;
    }
    c->hwnd = static_cast<HWND>(hwnd);
    c->message = message;
    c->wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    c->timer = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002 /* CREATE_WAITABLE_TIMER_HIGH_RESOLUTION */, TIMER_ALL_ACCESS);
    c->highResolution = c->timer ? 1 : 0;
    if (!c->timer) c->timer = CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);  // before Windows 10 1803
    c->source = 2;
    c->thread = c->wake ? CreateThread(nullptr, 64 * 1024, clockMain, c, STACK_SIZE_PARAM_IS_A_RESERVATION, &c->threadId) : nullptr;
    if (!c->thread) {
        const HRESULT hr = HRESULT_FROM_WIN32(GetLastError());
        c->refs = 1;
        unref(c);
        fail("ptb_clock_create: thread", hr);
        return nullptr;
    }
    return reinterpret_cast<PTBClock *>(c);
}

extern "C" void ptb_clock_set_running(PTBClock *clock, int on) {
    Clock *c = reinterpret_cast<Clock *>(clock);
    if (!c) return;
    const LONG was = InterlockedExchange(&c->running, on ? 1 : 0);
    if (on && !was) SetEvent(c->wake);
}

extern "C" void ptb_clock_ack(PTBClock *clock) {
    Clock *c = reinterpret_cast<Clock *>(clock);
    if (c) InterlockedExchange(&c->pending, 0);
}

extern "C" int ptb_clock_set_monitor(PTBClock *clock, void *monitor, int forceTimer) {
    Clock *c = reinterpret_cast<Clock *>(clock);
    if (!c) return 0;
    IDXGIOutput *found = nullptr;
    double hz = 0;
    if (monitor && !forceTimer) {
        IDXGIFactory1 *factory = nullptr;
        if (LoadLibraryExW(L"dxgi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) &&
            SUCCEEDED(CreateDXGIFactory1(kIidDXGIFactory1, reinterpret_cast<void **>(&factory)))) {
            for (UINT a = 0; !found; a++) {
                IDXGIAdapter1 *adapter = nullptr;
                if (factory->EnumAdapters1(a, &adapter) != S_OK) break;
                for (UINT o = 0; !found; o++) {
                    IDXGIOutput *output = nullptr;
                    if (adapter->EnumOutputs(o, &output) != S_OK) break;
                    DXGI_OUTPUT_DESC desc;
                    if (SUCCEEDED(output->GetDesc(&desc)) && desc.Monitor == static_cast<HMONITOR>(monitor)) {
                        found = output;
                        DEVMODEW mode;
                        std::memset(&mode, 0, sizeof(mode));
                        mode.dmSize = sizeof(mode);
                        if (EnumDisplaySettingsW(desc.DeviceName, ENUM_CURRENT_SETTINGS, &mode) && mode.dmDisplayFrequency > 1)
                            hz = mode.dmDisplayFrequency;
                    } else {
                        output->Release();
                    }
                }
                adapter->Release();
            }
            factory->Release();
        }
    }
    AcquireSRWLockExclusive(&c->lock);
    if (c->output) c->output->Release();
    c->output = found;
    c->forceTimer = forceTimer;
    c->refreshHz = hz;
    c->divider = hz >= 120 ? static_cast<uint32_t>(hz / 60.0) : 1;
    c->source = found ? 1 : 2;
    const int32_t source = c->source;
    ReleaseSRWLockExclusive(&c->lock);
    return source;
}

extern "C" void ptb_clock_stats(PTBClock *clock, PTBClockStats *out, int resetIntervals) {
    Clock *c = reinterpret_cast<Clock *>(clock);
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!c) return;
    out->threadId = c->threadId;
    AcquireSRWLockShared(&c->lock);
    out->source = c->source;
    out->refreshHz = c->refreshHz;
    out->divider = c->divider;
    ReleaseSRWLockShared(&c->lock);
    out->highResolutionTimer = c->highResolution;
    out->running = c->running;
    out->posted = static_cast<uint64_t>(c->posted);
    out->waits = static_cast<uint64_t>(c->waits);
    out->fallbacks = static_cast<uint64_t>(c->fallbacks);
    out->earlyReturns = static_cast<uint64_t>(c->early);
    out->parks = static_cast<uint64_t>(c->parks);
    static double sorted[kRing];
    AcquireSRWLockExclusive(&c->ringLock);
    const uint32_t n = c->ringCount;
    std::memcpy(sorted, c->ring, sizeof(double) * n);  // order does not matter: sorted below
    if (resetIntervals) {
        c->ringCount = 0;
        c->ringNext = 0;
        c->lastPost = 0;
    }
    ReleaseSRWLockExclusive(&c->ringLock);
    out->samples = n;
    if (n == 0) return;
    std::qsort(sorted, n, sizeof(double), cmpDouble);
    out->p50Ms = sorted[n / 2];
    out->p95Ms = sorted[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1];
    out->p99Ms = sorted[(n * 99) / 100 < n ? (n * 99) / 100 : n - 1];
    out->maxMs = sorted[n - 1];
}

extern "C" int ptb_clock_destroy(PTBClock *clock) {
    Clock *c = reinterpret_cast<Clock *>(clock);
    if (!c) return 1;
    InterlockedExchange(&c->running, 0);
    InterlockedExchange(&c->stop, 1);
    SetEvent(c->wake);
    // A frame wait ends within one frame (timer) or one vblank; a WaitForVBlank that never returns (a display that went
    // away) leaves the thread to finish on its own: it holds its own reference.
    const DWORD r = WaitForSingleObject(c->thread, 2000);
    unref(c);
    return r == WAIT_OBJECT_0 ? 1 : 0;
}
