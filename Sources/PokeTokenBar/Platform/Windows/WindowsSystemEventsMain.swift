#if os(Windows)
import Foundation

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
