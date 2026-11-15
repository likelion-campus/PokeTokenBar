#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// The plaza's frame clock (D4): a thread (in `CPlazaD2D`, `window_clock.cpp`) that posts one tick message per frame to
/// the plaza window while it runs and waits on an event with no timeout while it does not (zero wakeups). Its source is
/// the vblank of the monitor that shows the window, every N-th one (N = max(1, ⌊Hz / 60⌋)), or a high-resolution timer at
/// 1/60 s where there is no usable vblank. The thread touches no Swift state: it only waits and posts, never two ticks
/// the window has not answered (`ack`). The window handles the tick on the main thread (`WinPlazaWindow`).
///
/// Wakeups: while running, one per frame on the clock thread and one on the main thread; while parked, none.
final class WinFrameClock: @unchecked Sendable {
    enum Source: Equatable { case vblank(refreshHz: Double), timer60 }

    private let raw: OpaquePointer
    private var destroyed = false

    /// nil when the thread cannot be made (the window then draws only on its own events, and logs it).
    init?(window: HWND, message: UINT) {
        guard let raw = ptb_clock_create(UnsafeMutableRawPointer(window), message) else { return nil }
        self.raw = raw
    }

    deinit { if !destroyed { _ = ptb_clock_destroy(raw) } }

    /// Main thread. Parks the thread when off (it finishes the frame wait it is in, at most one frame).
    func setRunning(_ on: Bool) { ptb_clock_set_running(raw, on ? 1 : 0) }

    /// Main thread: the posted tick was handled; the next one may be posted.
    func ack() { ptb_clock_ack(raw) }

    /// Main thread: the monitor that shows the window (`MonitorFromWindow`), on creation and when it changes.
    @discardableResult
    func setMonitor(_ monitor: HMONITOR?, forceTimer: Bool = false) -> Source {
        let source = ptb_clock_set_monitor(raw, monitor.map { UnsafeMutableRawPointer($0) }, forceTimer ? 1 : 0)
        return source == 1 ? .vblank(refreshHz: stats().refreshHz) : .timer60
    }

    func stats(resetIntervals: Bool = false) -> PTBClockStats {
        var s = PTBClockStats()
        ptb_clock_stats(raw, &s, resetIntervals ? 1 : 0)
        return s
    }

    var source: Source {
        let s = stats()
        return s.source == 1 ? .vblank(refreshHz: s.refreshHz) : .timer60
    }

    var ticksPosted: Int { Int(stats().posted) }
    var threadID: UInt32 { stats().threadId }

    /// Stops and joins the thread (at most 2 s). True when it ended in time.
    @discardableResult
    func destroy() -> Bool {
        guard !destroyed else { return true }
        destroyed = true
        return ptb_clock_destroy(raw) != 0
    }
}
#endif
