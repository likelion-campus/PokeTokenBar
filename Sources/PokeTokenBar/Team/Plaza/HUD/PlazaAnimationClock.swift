import Foundation

/// A panel's own clock for something that animates at a fixed beat (the roster's bouncing icons: a step every half
/// second). It exists only while it is wanted: `setRunning(false)` removes the timer, so a plaza with nothing to animate,
/// or a hidden one, has no timer at all and no wake-ups. The beat is `interval`; each beat calls `onTick` on the main
/// actor, which is where the panel reports a change (one render per beat). `beats` counts the beats since the clock
/// last started, so a panel derives a phase from it (SwiftUI's `up.toggle()` per 0.5 s is `beats` odd or even).
///
/// The timer is injectable so a test can drive beats by hand; the default is a `Timer(fire:interval:repeats:)` on the main
/// run loop in the common modes (a scroll or a menu tracking does not stop it). A `schedule` closure's callback returns
/// false once the clock is gone, which ends the repetition.
@MainActor final class PlazaAnimationClock {
    /// What `schedule` returns: calling it ends the repetition.
    typealias Stop = () -> Void

    let interval: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Bool) -> Stop
    private var stop: Stop?
    private(set) var beats = 0
    /// Called on every beat.
    var onTick: (() -> Void)?

    var isRunning: Bool { stop != nil }

    init(interval: TimeInterval, schedule: ((TimeInterval, @escaping @MainActor () -> Bool) -> Stop)? = nil) {
        self.interval = interval
        self.schedule = schedule ?? PlazaAnimationClock.mainRunLoop
    }

    /// Starts or stops the beat. Starting while running changes nothing (the phase goes on).
    func setRunning(_ run: Bool) {
        if run {
            guard stop == nil else { return }
            beats = 0
            stop = schedule(interval) { [weak self] in
                guard let self else { return false }   // the clock is gone: the timer ends itself
                self.beat()
                return true
            }
        } else if let stop {
            stop()
            self.stop = nil
        }
    }

    /// For tests: one beat as if the timer fired (only while running).
    func driveForTesting() { if isRunning { beat() } }

    private func beat() {
        beats += 1
        onTick?()
    }

    private static func mainRunLoop(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Bool) -> Stop {
        let timer = Timer(fire: Date().addingTimeInterval(interval), interval: interval, repeats: true) { t in
            if !MainActor.assumeIsolated({ fire() }) { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
