#if os(Windows)
import Foundation

/// Callbacks that already run on the main thread, entering the main actor without a hop through the main queue.
/// Here and not in `Team/`: the scan there allows `MainActor.assumeIsolated` only inside main-queue blocks, because
/// the socket loop's and DNS-SD's callbacks run on pool threads.
enum WinMainThread {
    /// A repeating `Timer` on `RunLoop.main` (common modes): its block runs on the main thread, so `body` runs at the
    /// fire, as the Mac's `BonjourTeamTransport` redial timer does, with no second wake for a queue hop.
    @MainActor static func repeatingTimer(every interval: TimeInterval, tolerance: TimeInterval,
                                          _ body: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(fire: Date(timeIntervalSinceNow: interval), interval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

extension WindowsSystemEvents {
    /// `onWillSleep` for main-actor code. The handlers run on the main thread, inside the sink window's
    /// `WM_POWERBROADCAST` (`handlePowerBroadcast`), so `f` runs at once and finishes before the window procedure
    /// returns, which is before Windows suspends (a hop through the main queue could run only after the resume).
    func onWillSleepOnMain(_ f: @escaping @MainActor @Sendable () -> Void) {
        onWillSleep { MainActor.assumeIsolated { f() } }
    }

    /// `onWake` for main-actor code; runs at once, on the main thread, like `onWillSleepOnMain`.
    func onWakeOnMain(_ f: @escaping @MainActor @Sendable () -> Void) {
        onWake { MainActor.assumeIsolated { f() } }
    }
}
#endif
