import Foundation

/// A rate limit that allows a burst: it starts full and refills steadily up to `capacity`. Pure, the caller brings the clock.
struct TeamTokenBucket {
    private let capacity: Double
    private let perSecond: Double
    private var tokens: Double
    private var last: Date?

    init(capacity: Double, perSecond: Double) {
        self.capacity = capacity
        self.perSecond = perSecond
        tokens = capacity
    }

    /// Spends `amount` if it is all there. A refusal spends nothing.
    mutating func take(_ amount: Double = 1, now: Date) -> Bool {
        if let last { tokens = min(capacity, tokens + max(now.timeIntervalSince(last), 0) * perSecond) }
        last = now
        guard tokens >= amount else { return false }
        tokens -= amount
        return true
    }
}
