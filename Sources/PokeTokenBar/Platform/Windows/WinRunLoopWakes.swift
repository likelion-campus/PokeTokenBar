#if os(Windows)
import Foundation

/// Counts the waits of the main run loop that ended: a `.afterWaiting` observer (corelibs `RunLoop._observe`, an underscored SPI that
/// Foundation keeps for XCTest; it is Swift API inside Foundation, so it needs no CoreFoundation symbol). The selftest installs it
/// once at its start (`WindowsSelftest.run`), so a normal launch pays nothing. CoreFoundation does not notify `.afterWaiting` when it
/// polls instead of waiting, so the count should be one per real wake (a timer, a source, a message, the main queue); the selftest's
/// `idle.wakeCounter` proves that on every run. Read by `IdleWakeJudge` as `wakes`.
///
/// Not `@MainActor`: the observer's handler is called by CoreFoundation on the main thread, outside any actor. `_Observer` is
/// not `Sendable`, hence `nonisolated(unsafe)`; everything here runs on the main thread.
enum WinRunLoopWakes {
    nonisolated(unsafe) private static var observer: RunLoop._Observer?
    nonisolated(unsafe) private static var counted = 0

    /// Waits that ended since `install`; nil while no observer is installed.
    static var count: Int? { observer == nil ? nil : counted }

    /// Adds the observer to `RunLoop.main` in the default mode (the mode the main loop runs in). Call on the main thread; once only.
    static func install() {
        guard observer == nil else { return }
        observer = RunLoop.main._observe(RunLoop._Activity.afterWaiting, in: .default, repeats: true, order: 0) { _ in
            WinRunLoopWakes.counted += 1
        }
    }
}
#endif
