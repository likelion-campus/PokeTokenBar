#if os(Windows)
import Foundation

/// The verdict of each idle check's window (`IdleWakeJudge` documents the rules; PR 2 made it the check's verdict), printed with the old
/// switch budget's verdict as `legacy{...}`, informational for one release. `ui.kit.idle` is not flipped yet: there the legacy verdict
/// decides and the judge's is informational. A check calls `begin` right before its window is measured and `end` right after, with the
/// numbers it already has.
@MainActor enum IdleShadow {
    struct Mark {
        let passes: Int
        let wakes: Int?
    }

    /// Also starts recording what reaches the main thread (`WinMessageArrivals`: thread hooks, only until `end`).
    static func begin() -> Mark {
        WinMessageArrivals.begin()
        return Mark(passes: WinMainLoop.iterations, wakes: WinRunLoopWakes.count)
    }

    /// Which loop the process runs: the dispatch-handle one has no CF wait to observe. Read from the app itself: `selftestApp` is set only
    /// after the modal checks, so a caller early in the selftest must pass its own `app`.
    static func loop(of app: WindowsAppDelegate?) -> IdleWakeJudge.Loop {
        app?.loopStrategy == .dispatchHandle ? .dispatchHandle : .cfRunLoop
    }

    struct Outcome {
        let text: String
        let verdict: IdleWakeJudge.Verdict
        /// What reached the main thread in the window (the caller may judge it too).
        let arrivals: [IdleBurstAttribution.Arrival]
    }

    static func end(_ mark: Mark, seconds: Double, cs: Int, fires: IdleWakeJudge.Fires, refreshes: Int, loop: IdleWakeJudge.Loop,
                    legacyBudget: Int, legacyOK: Bool, legacyDecides: Bool = false) -> Outcome {
        let arrivals = WinMessageArrivals.end()
        let passes = WinMainLoop.iterations - mark.passes
        let wakes: Int? = mark.wakes.flatMap { a in WinRunLoopWakes.count.map { $0 - a } }
        let window = IdleWakeJudge.Window(seconds: seconds, loop: loop, cs: cs, passes: passes, wakes: wakes, fires: fires, refreshes: refreshes,
                                          arrivals: arrivals)
        let v = IdleWakeJudge.judge(window)
        var text = "legacy{budget=\(legacyBudget),verdict=\(legacyOK ? "pass" : "fail"),\(legacyDecides ? "decides" : "informational")} "
            + "judge{verdict=\(v.ok ? "pass" : "fail"),wakes=\(wakes.map(String.init) ?? "n/a"),passes=\(passes),fires=\(fires.total),"
            + "residual=\(v.residual.map(String.init) ?? "n/a"),ceiling=\(v.ceiling)} "
            + "judge_fires={safety:\(fires.safety), debounce:\(fires.debounce), day:\(fires.day), redial:\(fires.redial), dnssd:\(fires.dnssd)} "
            + "judge_refreshes=\(refreshes) judge_arrivals=\(IdleBurstAttribution.listing(arrivals))"
        if !v.ok { text += " judge_failures=[\(v.failures.joined(separator: "; "))]" }
        return Outcome(text: text, verdict: v, arrivals: arrivals)
    }
}

/// `PTB_SELFTEST_IDLE_LOOP=N` (workflow input `idle_loop`; 0 or unset = off; forced off in release mode): N more informational windows after
/// each of `idle.window`, `team.idle` and `modalPump.idle`, in the bundle and the installed selftest. Each prints the judge's numbers, and a
/// summary line per kind gives the residual's spread for windows with and without a store refresh. Nothing in them is judged: they are
/// where the residual's distribution (W) comes from.
enum IdleLoop {
    static var count: Int { Int(ProcessInfo.processInfo.environment["PTB_SELFTEST_IDLE_LOOP"] ?? "") ?? 0 }
}

extension WindowsSelftest {
    /// One window over the app as it is (a store refresh landing in it is kept). `team` supplies the transports' redial and DNS-SD counters.
    @MainActor static func shadowLoopWindow(_ app: WindowsAppDelegate, seconds: Double, legacy: (base: Int, perFire: Int),
                                            team: (() -> (redial: Int, dnssd: Int))? = nil)
        async -> (text: String, residual: Int?, refreshed: Bool)? {
        let k0 = knownWakes(app)
        let t0: (redial: Int, dnssd: Int) = team?() ?? (0, 0)
        let mark = IdleShadow.begin()
        let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID)
        let k1 = knownWakes(app)
        let t1: (redial: Int, dnssd: Int) = team?() ?? (0, 0)
        let fires = IdleWakeJudge.Fires(safety: k1.safety - k0.safety, debounce: k1.debounce - k0.debounce, day: k1.day - k0.day,
                                        redial: t1.redial - t0.redial, dnssd: t1.dnssd - t0.dnssd)
        let refreshes = k1.refreshesInWindow(since: k0)
        guard let sample else {
            _ = WinMessageArrivals.end()
            return nil
        }
        let budget = legacy.base + legacy.perFire * fires.total + 60 * refreshes
        let shadow = IdleShadow.end(mark, seconds: seconds, cs: sample.mainContextSwitches, fires: fires, refreshes: refreshes, loop: IdleShadow.loop(of: app),
                                    legacyBudget: budget, legacyOK: sample.mainContextSwitches <= budget)
        let text = "sec=\(Int(seconds)) main_cs=\(sample.mainContextSwitches) main_Mcyc=\(String(format: "%.2f", Double(sample.mainCycles) / 1e6)) "
            + "process_Mcyc=\(String(format: "%.1f", Double(sample.processCycles) / 1e6)) layout_ok=\(sample.layoutOK) " + shadow.text
        return (text, shadow.verdict.residual, refreshes > 0)
    }

    /// `IdleLoop.count` windows of one kind, each a line, then the summary.
    @MainActor static func idleLoopWindows(_ r: Recorder, _ app: WindowsAppDelegate, seconds: Double, kind: String, legacy: (base: Int, perFire: Int),
                                           team: (() -> (redial: Int, dnssd: Int))? = nil) async {
        var withRefresh: [Int] = [], without: [Int] = []
        var unavailable = 0
        for i in 1...max(1, IdleLoop.count) {
            guard let w = await shadowLoopWindow(app, seconds: seconds, legacy: legacy, team: team) else {
                r.add("idleLoop.\(kind)", true, "#\(i) measurement failed (informational)")
                continue
            }
            if let residual = w.residual {
                if w.refreshed { withRefresh.append(residual) } else { without.append(residual) }
            } else {
                unavailable += 1
            }
            r.add("idleLoop.\(kind)", true, "#\(i) \(w.text) (informational)")
        }
        func spread(_ v: [Int]) -> String {
            let s = v.sorted()
            return s.isEmpty ? "N=0" : "N=\(s.count) min=\(s[0]) median=\(s[s.count / 2]) max=\(s[s.count - 1])"
        }
        r.add("idleLoop.\(kind).summary", true,
              "residual with a refresh \(spread(withRefresh)); without a refresh \(spread(without)); no wake count in \(unavailable) (informational)")
    }
}
#endif
