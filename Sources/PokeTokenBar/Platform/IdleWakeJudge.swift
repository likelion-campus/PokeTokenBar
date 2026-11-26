import Foundation

/// The shared judge of the Windows selftest's idle windows (`idle.window`, `team.idle`, `modalPump.idle`, `ui.kit.idle`). Pure, so it
/// is tested on both systems (`IdleWakeJudgeTests`).
///
/// An idle window exists to catch a busy loop: something waking the main thread that nobody accounts for. The old verdicts budgeted
/// the main thread's context switches (`3 + 3..5 per known timer wake + 60 per store refresh`), but a switch count measures the runner
/// as much as the app: the same wakes cost 1.5-2x the switches now and then (release run 45651391066: 104 cs against 45 on the
/// retry, same work, 46 loop passes). This judge counts WAKES instead, from four sources that add up:
///   - `passes`: returns of `RunLoop.main.run` (a source, a message or a main-queue block was handled);
///   - named fires: the timers the app counts itself (settings safety sync, debounce, day timer, team redial, DNS-SD events);
///   - `wakes`: every wait on the main run loop that ended (`WinRunLoopWakes`, the `.afterWaiting` observer);
///   - tolerated broadcast arrivals: one system broadcast from outside costs one wake that nothing of ours caused.
///
/// PR 2 made this the verdict of `idle.window`, `team.idle` and `modalPump.idle` (`ui.kit.idle` still decides by its switch budget: too few
/// windows of its own, see its check). The old switch budgets are printed as `legacy{...}` for one release. Each limit below carries the
/// sample it rests on; none was tuned to make a window pass.
enum IdleWakeJudge {
    enum Loop: Sendable, Equatable {
        /// `RunLoop.main.run` with CoreFoundation's wait: `wakes` is observable.
        case cfRunLoop
        /// `PTB_WIN_LOOP=dispatch`: our own wait, no CF wait to observe; every wait is a pass and a timer fire counts in `passes`.
        case dispatchHandle
    }

    /// The named timer fires of a window (each counted by the app itself).
    struct Fires: Sendable, Equatable {
        var safety = 0, debounce = 0, day = 0, redial = 0, dnssd = 0
        var total: Int { safety + debounce + day + redial + dnssd }
        init(safety: Int = 0, debounce: Int = 0, day: Int = 0, redial: Int = 0, dnssd: Int = 0) {
            (self.safety, self.debounce, self.day, self.redial, self.dnssd) = (safety, debounce, day, redial, dnssd)
        }
    }

    struct Window: Sendable, Equatable {
        var seconds: Double
        var loop: Loop = .cfRunLoop
        /// Main-thread context switches: only R4 reads them (a runaway), the verdict is not about them otherwise.
        var cs: Int
        /// Difference in `WinMainLoop.iterations`.
        var passes: Int
        /// Difference in `WinRunLoopWakes.count`; nil = unavailable (observer not installed).
        var wakes: Int?
        var fires: Fires = Fires()
        /// `IdleBurstAttribution.refreshesInWindow`.
        var refreshes: Int = 0
        var arrivals: [IdleBurstAttribution.Arrival] = []
    }

    /// Every number carries its sample. "Shadow windows" = 424 windows of 8 runs (45761653192 45765179757 45765184311 45765188799 45784146296
    /// 45787217942 45787394423 45787403934: bundle and installed selftest, 2026-11-26): idle.window 136, team.idle 136, modalPump.idle 136,
    /// ui.kit.idle 16.
    struct Limits: Sendable, Equatable {
        /// R1. Periods are the timers' own; the ceilings are what the logs of 145 runs (2026-11-20..25) and the shadow windows show:
        /// safety 0-2 fires (N=294 idle windows), debounce 0 (N=294), day 0 (N=294), redial 8 in 60 s (N=273), dnssd 0 (N=288).
        var safetyPeriod = 30.0           // fires <= floor(s / 30) + 1
        var debounceMax = 1
        var dayMax = 1
        var redialPeriod = 15.0           // fires <= 2 * (floor(s / 15) + 1): two transports redial every 15 s
        var dnssdMax = 2
        /// R2. Passes without a refresh: 1 (N=76 idle.window) or 1-2 (team, N=68); with a refresh 43-53 (N=145 shadow windows), 37-52 (installed
        /// idle.window, N=132 earlier), 17-51 (ui.kit.idle, N=105 earlier). 80 is 1.5 x the highest seen (53).
        var passBase = 3
        var passesPerRefresh = 80
        /// R3. W = max residual + 2 = 4: the residual (wakes - passes - named fires - tolerated broadcast) was 0 in 327, 1 in 83 and 2 in 14 of
        /// the 424 shadow windows (min 0, median 0, max 2; per kind and refresh at least N=5 windows, in none above 2). Not above 3, so no unknown
        /// waker. Thin cells: modalPump.idle with a refresh N=10, ui.kit.idle (N=16, none with a refresh in the installed selftest; its check does
        /// not use the judge yet).
        var residualAllowance = 4
        /// One broadcast from outside is tolerated per window (what `IdleBurstAttribution.judge` tolerates too).
        var toleratedBroadcasts = 1
        /// R4, a runaway guard only. cs <= seconds + factor * (passes + fires). The highest cs / ceiling in the shadow windows is 0.27 (N=424);
        /// the highest ever seen is 148 cs in a team window (ceiling at its counts about 240, ratio 0.62, one window of 132). 104 cs (idle,
        /// refresh, ceiling 256) and 148 stay under it. Re-derive when a window comes within 0.8 of its ceiling.
        var csPerWake = 4
    }

    struct Verdict: Sendable, Equatable {
        /// The rules that failed, each one named with its numbers: "R1 safety 10 > 3", ...
        let failures: [String]
        /// `wakes - passes - Σ fires - tolerated`; nil when `wakes` is unavailable.
        let residual: Int?
        /// R4's ceiling at this window's counts.
        let ceiling: Int
        var ok: Bool { failures.isEmpty }
        /// R1-R3 only: the verdict without the runaway ceiling (`modalPump.idle` judges R4 through `IdleBurstAttribution`, which tolerates one broadcast burst).
        var withoutRunaway: [String] { failures.filter { !$0.hasPrefix("R4") } }
    }

    static func judge(_ w: Window, limits l: Limits = Limits()) -> Verdict {
        var failures: [String] = []
        let f = w.fires
        func over(_ name: String, _ value: Int, _ limit: Int) {
            if value > limit { failures.append("R1 \(name) \(value) > \(limit)") }
        }
        // R1: a named timer fires more often than its period allows.
        over("safety", f.safety, Int((w.seconds / l.safetyPeriod).rounded(.down)) + 1)
        over("debounce", f.debounce, l.debounceMax)
        over("day", f.day, l.dayMax)
        over("redial", f.redial, 2 * (Int((w.seconds / l.redialPeriod).rounded(.down)) + 1))
        over("dnssd", f.dnssd, l.dnssdMax)
        // R2: too many loop passes. On the dispatch-handle loop every timer fire is a pass too.
        let passes = w.loop == .dispatchHandle ? max(0, w.passes - f.total) : w.passes
        let passLimit = l.passBase + l.passesPerRefresh * w.refreshes
        if passes > passLimit { failures.append("R2 passes \(passes) > \(passLimit) (\(w.refreshes) refresh)") }
        // R3: wakes nobody accounts for. Skipped on the dispatch-handle loop (nothing to observe there).
        var residual: Int?
        if w.loop == .cfRunLoop {
            if let wakes = w.wakes {
                let tolerated = tolerableBroadcast(w.arrivals) ? l.toleratedBroadcasts : 0
                let r = wakes - w.passes - f.total - tolerated
                residual = r
                if r > l.residualAllowance {
                    failures.append("R3 unattributed wakes \(r) > \(l.residualAllowance) (wakes \(wakes) - passes \(w.passes) - fires \(f.total) - broadcast \(tolerated))")
                }
            } else {
                failures.append("R3 not judged: no wake count (observer not installed)")
            }
        }
        // R4: runaway context switches, the only role cs keeps.
        let ceiling = Int(w.seconds.rounded()) + l.csPerWake * (w.passes + f.total)
        if w.cs > ceiling { failures.append("R4 cs \(w.cs) > \(ceiling)") }
        return Verdict(failures: failures, residual: residual, ceiling: ceiling)
    }

    /// A message sent from another thread or process to every top-level window (a system broadcast, or a send that reached two or more
    /// of our windows: our code never sends one) is a wake nothing of ours caused.
    static func tolerableBroadcast(_ arrivals: [IdleBurstAttribution.Arrival]) -> Bool {
        let sent = arrivals.filter { !$0.posted }
        return Dictionary(grouping: sent, by: \.message).contains { message, list in
            IdleBurstAttribution.broadcastNames[message] != nil || Set(list.map(\.root)).count >= 2
        }
    }
}
