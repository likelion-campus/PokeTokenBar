#if os(Windows)
import Foundation

/// The plaza's drawing loop as the controller sees it (`renderLoop`, the Mac's `SKView`): `isPaused` is what the
/// controller's `setRendering` and its watchdog write. It owns the frame clock and runs it only while the window has been
/// shown, the view is not paused and the stage is not paused (D4); otherwise the clock thread is parked.
@MainActor final class WinPlazaView: PlazaPausableView {
    let clock: WinFrameClock?
    private let stagePaused: () -> Bool
    /// The window has been shown (`bringToFront`) and not dismantled.
    var isShown = false { didSet { if isShown != oldValue { update() } } }
    /// The controller's pause: hidden, covered, minimized, or the watchdog's kick.
    var isPaused = false { didSet { if isPaused != oldValue { update() } } }
    private(set) var isRunning = false
    /// How many times the clock was started and parked (the selftest reads them).
    private(set) var starts = 0, parks = 0

    init(clock: WinFrameClock?, stagePaused: @escaping () -> Bool) {
        self.clock = clock
        self.stagePaused = stagePaused
    }

    /// The stage's pause changed, or anything above: run or park the clock.
    func update() {
        let run = isShown && !isPaused && !stagePaused()
        guard run != isRunning else { return }
        isRunning = run
        if run { starts += 1 } else { parks += 1 }
        clock?.setRunning(run)
    }

    /// The window is going away: park and join the clock thread.
    @discardableResult
    func stop() -> Bool {
        isShown = false
        return clock?.destroy() ?? true
    }
}
#endif
