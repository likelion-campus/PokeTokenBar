import Foundation

/// When to report "the network came back", as a Bool state machine. The same rule as
/// `NetworkReachabilityMonitor.shouldTriggerReconnect` (the Mac, `NWPath.Status`): the first observation never
/// triggers, only not-satisfied to satisfied does, and a second trigger inside `cooldown` is suppressed (an interface
/// that flaps). `ReachabilityParityTests` compares the two on the Mac.
struct ReachabilityTransition: Sendable {
    let cooldown: TimeInterval
    private var previous: Bool?
    private var lastTriggeredAt: Date?

    init(cooldown: TimeInterval = 5) { self.cooldown = cooldown }

    /// True = report a reconnect.
    mutating func update(isSatisfied: Bool, now: Date) -> Bool {
        let before = previous
        previous = isSatisfied
        guard let before, !before, isSatisfied else { return false }
        if let lastTriggeredAt, now.timeIntervalSince(lastTriggeredAt) < cooldown { return false }
        lastTriggeredAt = now
        return true
    }

    /// Forgets the last observation (the Mac monitor does on `stop()`); the cooldown clock stays.
    mutating func reset() { previous = nil }
}
