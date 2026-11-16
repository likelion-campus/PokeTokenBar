import Foundation

/// The popover's one animation timer (stage 7 D16): a single one-shot `Timer(fire:)` armed for the earliest next frame
/// due across the visible animated slots. `setDue(nil)` removes it, so a closed popover, a hidden or scrolled-out view, a
/// still sprite or animation turned off has no timer at all. A fire clears the timer and calls `onTick`; the owner
/// answers with the next `setDue`. The scheduler is injectable so a test reads the due times it was asked for.
@MainActor final class PopoverAnimationClock {
    typealias Stop = () -> Void
    /// Arms a one-shot call at `due`; the returned closure cancels it.
    typealias Schedule = (Date, @escaping @MainActor () -> Void) -> Stop

    private let schedule: Schedule
    private var stop: Stop?
    private(set) var armedDue: Date?
    private(set) var armCount = 0
    private(set) var fireCount = 0
    var onTick: (() -> Void)?

    var isArmed: Bool { stop != nil }

    init(schedule: Schedule? = nil) {
        self.schedule = schedule ?? PopoverAnimationClock.mainRunLoop
    }

    /// Arms for `next`, or removes the timer for nil. The same due date changes nothing.
    func setDue(_ next: Date?) {
        guard let next else {
            stop?()
            stop = nil
            armedDue = nil
            return
        }
        if stop != nil, armedDue == next { return }
        stop?()
        armedDue = next
        armCount += 1
        stop = schedule(next) { [weak self] in
            guard let self else { return }
            self.stop = nil
            self.armedDue = nil
            self.fireCount += 1
            self.onTick?()
        }
    }

    private static func mainRunLoop(_ due: Date, _ fire: @escaping @MainActor () -> Void) -> Stop {
        let timer = Timer(fire: due, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
