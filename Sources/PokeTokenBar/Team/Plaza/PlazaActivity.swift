import Foundation

/// What I did in the plaza today, for the roster hover. Counted on my own Mac, sent to teammates, and shown
/// only while the sender's `day` is the receiver's today. SpriteKit-free.
struct PlazaActivity: Codable, Equatable, Sendable {
    var day: String
    var seconds = 0
    var iceBreaks = 0
    var fireworks = 0
    var tackles = 0
    var snowballHits = 0
    var greetings = 0
    var pickups = 0

    static let maxCount = 99_999
    static let maxSeconds = 86_400

    enum Kind: Sendable { case iceBreak, firework, tackle, snowballHit, greeting, pickup }

    init(day: String) { self.day = day }

    /// "yyyy-MM-dd" in the Mac's own calendar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The same numbers on the same day, a fresh zero on a new one.
    func rolled(to day: String) -> PlazaActivity { self.day == day ? self : PlazaActivity(day: day) }

    mutating func record(_ kind: Kind) {
        func up(_ n: Int) -> Int { min(n + 1, Self.maxCount) }
        switch kind {
        case .iceBreak: iceBreaks = up(iceBreaks)
        case .firework: fireworks = up(fireworks)
        case .tackle: tackles = up(tackles)
        case .snowballHit: snowballHits = up(snowballHits)
        case .greeting: greetings = up(greetings)
        case .pickup: pickups = up(pickups)
        }
    }

    /// Time only grows, and stops at a day.
    mutating func addSeconds(_ n: Int) {
        seconds = min(seconds + min(max(n, 0), Self.maxSeconds), Self.maxSeconds)
    }

    /// What a teammate sent, every value kept in range.
    var bounded: PlazaActivity {
        func keep(_ n: Int, _ top: Int) -> Int { min(max(n, 0), top) }
        var a = PlazaActivity(day: day)
        a.seconds = keep(seconds, Self.maxSeconds)
        a.iceBreaks = keep(iceBreaks, Self.maxCount)
        a.fireworks = keep(fireworks, Self.maxCount)
        a.tackles = keep(tackles, Self.maxCount)
        a.snowballHits = keep(snowballHits, Self.maxCount)
        a.greetings = keep(greetings, Self.maxCount)
        a.pickups = keep(pickups, Self.maxCount)
        return a
    }

    /// The numbers to show on `day`, or nil (no record) when they are from another day.
    func shown(on day: String) -> PlazaActivity? { self.day == day ? self : nil }

    /// Everything but the time. A change here is sent at once; a time-only change waits for the minute.
    func countsMatch(_ other: PlazaActivity) -> Bool {
        var same = self
        same.seconds = other.seconds
        return same == other
    }
}

extension PlazaActivity {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// The seven lines under a roster slot, in order. Empty when there is nothing to show (the slot says 기록 없음).
    static func rows(_ activity: PlazaActivity?) -> [Row] {
        guard let a = activity else { return [] }
        let l = L(.ko), minutes = a.seconds / 60
        return [
            Row(label: l.plazaActivityTime, value: l.plazaActivityDuration(hours: minutes / 60, minutes: minutes % 60)),
            Row(label: l.plazaActivityIceBreaks, value: "\(a.iceBreaks)"),
            Row(label: l.plazaActivityFireworks, value: "\(a.fireworks)"),
            Row(label: l.plazaActivityTackles, value: "\(a.tackles)"),
            Row(label: l.plazaActivitySnowballHits, value: "\(a.snowballHits)"),
            Row(label: l.plazaActivityGreetings, value: "\(a.greetings)"),
            Row(label: l.plazaActivityPickups, value: "\(a.pickups)"),
        ]
    }
}
