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
/// PR 1 prints the verdict beside today's (shadow: no check's pass or fail reads it). Every number in `Limits` is PROVISIONAL UNTIL
/// PR 2, which sets them from the shadow windows of at least 5 runs; none was tuned to make a window pass.
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

    /// PROVISIONAL UNTIL PR 2 (each with the sample it comes from; the plan's section 1, `idle-plan/plan.md`).
    struct Limits: Sendable, Equatable {
        /// R1. Seen in 145 runs: safety 0-2 (N=294 idle windows), debounce 0 (N=294), day 0 (N=294), redial 8 in 60 s (N=273), dnssd 0 (N=288).
        var safetyPeriod = 30.0           // fires <= floor(s / 30) + 1
        var debounceMax = 1
        var dayMax = 1
        var redialPeriod = 15.0           // fires <= 2 * (floor(s / 15) + 1): two transports redial every 15 s
        var dnssdMax = 2
        /// R2. Without a refresh 1-2 passes (N~600 windows); with a refresh 37-52 (installed idle.window, N=132), 17-51 (ui.kit.idle, N=105),
        /// 29-44 (diag branch, N=78). 80 is 1.5 x the highest seen.
        var passBase = 3
        var passesPerRefresh = 80
        /// R3. The allowance is a stand-in until PR 2 (W = max residual + 2 over N >= 200 shadow windows, at least 5 runs).
        var residualAllowance = 3
        /// One broadcast from outside is tolerated per window (what `IdleBurstAttribution.judge` tolerates too).
        var toleratedBroadcasts = 1
        /// R4. cs <= seconds + factor * (passes + fires). Worst cs seen: idle with a refresh 104 (N=132), team with a refresh 148 (N=132),
        /// idle without 11 (N=138), modal 5 (N=279), ui.kit with a refresh 56 (N=105); each stays under its ceiling.
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
