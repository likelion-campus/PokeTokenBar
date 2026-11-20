import Foundation

/// The popover's one clock for relative texts ("Updated 3 minutes, 10 seconds", a reset "in 2 hours, 5 minutes", the
/// stale badge): it exists to be armed only while something on screen changes with time (stage 7, D10). The page gives it
/// the instants at which each visible relative text next reads differently (`RelativeTimeText.nextChange`); the clock arms
/// ONE one-shot `Timer(fire:)` at the earliest of them and calls `onTick` when it fires, and the page then reformats the
/// texts and gives it the next deadlines. No deadlines (nothing relative on screen, or the page closed) means no timer at
/// all. A closed popover has no clock.
@MainActor final class PopoverClock {
    /// The texts changed time: reformat them, then `setDeadlines` again.
    var onTick: (() -> Void)?
    /// The instant the timer is set for; nil = no timer.
    private(set) var armedFor: Date?
    private(set) var arms = 0, ticks = 0
    private var timer: Timer?
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    var isArmed: Bool { timer != nil }

    /// The earliest deadline after `now` (one already past fires at once: the text is stale).
    static func earliest(_ deadlines: [Date]) -> Date? { deadlines.min() }

    /// Arms the timer at the earliest of `dates`; none stops it. The same instant again keeps the timer it has.
    func setDeadlines(_ dates: [Date]) {
        guard let next = Self.earliest(dates) else {
            stop()
            return
        }
        if timer != nil, armedFor == next { return }
        stop()
        arms += 1
        armedFor = next
        let fire = max(next, now())
        let made = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fired() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        armedFor = nil
    }

    private func fired() {
        WakeTrace.count("popoverClock")
        timer = nil
        armedFor = nil
        ticks += 1
        onTick?()
    }
}
