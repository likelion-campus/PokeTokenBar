import Foundation


/// The selftest's `modalPump.idle` verdict once its 10 s window is over its budget (Windows; pure, so it is tested on both systems).
///
/// The window counts the main thread's context switches; a budget covers the wakes the app itself schedules (`3 + 5 per known timer
/// wake + 60 per store refresh`). Twice a single 100 ms sample took 12 switches at ~5 s (kit/pc-14 44297197674, and 44225879845 on a
/// tree before #285) while every other run took 1: one loop iteration, nothing of ours due. A message another process sends to every
/// top-level window (a broadcast such as WM_SETTINGCHANGE) is handled inside the pump without a loop iteration and costs one switch per
/// window; nothing in the window named what arrived. So the messages that reach the main thread are recorded (`WinMessageArrivals`) and
/// ONE burst is tolerated when it is such a broadcast from outside; anything else over the budget still fails, named.
enum IdleBurstAttribution {
    /// One timeline sample: `cs` switches in the 100 ms that ended `t` seconds into the window.
    struct Wake: Sendable, Equatable {
        let t: Double
        let cs: Int
    }

    /// A message that reached the main thread `t` seconds into the window: posted (removed by the pump) or sent from another thread.
    struct Arrival: Sendable, Equatable {
        let t: Double
        let message: UInt32
        /// The top-level window it went to, and that window's class.
        let root: Int
        let rootClass: String
        let posted: Bool
    }

    struct Verdict: Sendable, Equatable {
        let ok: Bool
        let note: String
    }

    /// Messages the system and the shell send to every top-level window (each is a broadcast even when only one of ours got it).
    static let broadcastNames: [UInt32: String] = [
        0x0015: "WM_SYSCOLORCHANGE", 0x001A: "WM_SETTINGCHANGE", 0x001D: "WM_FONTCHANGE", 0x001E: "WM_TIMECHANGE",
        0x007E: "WM_DISPLAYCHANGE", 0x0218: "WM_POWERBROADCAST", 0x0219: "WM_DEVICECHANGE", 0x031A: "WM_THEMECHANGED",
        0x031E: "WM_DWMCOMPOSITIONCHANGED", 0x0320: "WM_DWMCOLORIZATIONCOLORCHANGED",
    ]

    static func name(_ message: UInt32) -> String { broadcastNames[message] ?? "0x" + String(message, radix: 16) }

    /// Within budget: ok. Over it: the largest sample is a tolerated burst only when every message that arrived in it (its 100 ms,
    /// `slack` either side) was SENT from another thread and either reached at least two of our top-level windows (the shape of a
    /// broadcast: our code never sends one) or is a known system broadcast; then the rest must fit the budget. A burst with no message,
    /// with a posted message (ours, or input), or with a sent message to one window that is no broadcast fails.
    static func judge(cs: Int, budget: Int, wakes: [Wake], arrivals: [Arrival], slack: Double = 0.25) -> Verdict {
        guard cs > budget else { return Verdict(ok: true, note: "within budget") }
        guard let burst = wakes.max(by: { $0.cs < $1.cs }) else {
            return Verdict(ok: false, note: "over budget with no timeline sample")
        }
        let near = arrivals.filter { $0.t >= burst.t - 0.1 - slack && $0.t <= burst.t + slack }
        let at = String(format: "%.1fs+%d", burst.t, burst.cs)
        guard !near.isEmpty else {
            return Verdict(ok: false, note: "burst at \(at) unattributed: no message reached the main thread then (\(listing(arrivals)))")
        }
        let posted = near.filter(\.posted)
        guard posted.isEmpty else {
            return Verdict(ok: false, note: "burst at \(at) has posted messages (ours or input): \(listing(posted))")
        }
        let byMessage = Dictionary(grouping: near, by: \.message)
        let broadcast = byMessage.allSatisfy { message, list in
            broadcastNames[message] != nil || Set(list.map(\.root)).count >= 2
        }
        guard broadcast else {
            return Verdict(ok: false, note: "burst at \(at): sent from another thread but not a broadcast: \(listing(near))")
        }
        let rest = cs - burst.cs
        let named = "burst at \(at) tolerated, a broadcast from outside: \(listing(near))"
        guard rest <= budget else {
            return Verdict(ok: false, note: "\(named); the rest \(rest) is still over the budget \(budget)")
        }
        return Verdict(ok: true, note: "\(named); the rest \(rest) within the budget \(budget)")
    }

    /// "WM_SETTINGCHANGE x3 to PokeTokenBarSink,PokeTokenBarPopover sent" (by message, in arrival order).
    static func listing(_ arrivals: [Arrival]) -> String {
        guard !arrivals.isEmpty else { return "none" }
        var order: [UInt32] = []
        for a in arrivals where !order.contains(a.message) { order.append(a.message) }
        return order.map { message in
            let list = arrivals.filter { $0.message == message }
            var classes: [String] = []
            for a in list where !classes.contains(a.rootClass) { classes.append(a.rootClass) }
            return "\(name(message)) x\(list.count) to \(classes.joined(separator: ",")) \(list.allSatisfy(\.posted) ? "posted" : list.contains(where: \.posted) ? "sent+posted" : "sent")"
        }.joined(separator: "; ")
    }
}
