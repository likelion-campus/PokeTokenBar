import Foundation

struct TeamNotice: Equatable, Sendable {
    let fromNickname: String
    let text: String
}

/// Lets the first notice through and holds the rest until the window ends, so a burst becomes one banner.
struct TeamNotificationBatcher {
    private let window: TimeInterval
    private var windowStart: Date?
    private var pending: [TeamNotice] = []

    init(window: TimeInterval = 30) { self.window = window }

    /// Returns the notice when nothing is waiting and no window is open; otherwise keeps it for `flush`.
    mutating func offer(_ item: TeamNotice, now: Date) -> TeamNotice? {
        if pending.isEmpty, !isWindowOpen(at: now) {
            windowStart = now
            return item
        }
        pending.append(item)
        return nil
    }

    /// Once the window is over, hands back what piled up. Posting it opens the next window.
    mutating func flush(now: Date) -> [TeamNotice] {
        guard let windowStart, now.timeIntervalSince(windowStart) >= window else { return [] }
        let out = pending
        pending = []
        self.windowStart = out.isEmpty ? nil : now
        return out
    }

    private func isWindowOpen(at now: Date) -> Bool {
        guard let windowStart else { return false }
        return now.timeIntervalSince(windowStart) < window
    }
}

@MainActor
protocol TeamNotificationPosting: AnyObject {
    func post(id: String, title: String, body: String)
    func requestAuthorization()
}

/// What was held back while the user focused, for the end line.
struct TeamFocusTally: Equatable {
    var hearts = 0, lols = 0, parties = 0, reactions = 0, news = 0
}
