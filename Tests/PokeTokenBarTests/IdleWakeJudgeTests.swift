import XCTest
@testable import PokeTokenBar

/// The shared judge of the Windows selftest's idle windows (the verdict of `idle.window`, `team.idle`, `modalPump.idle`, `ui.kit.idle`). Real windows come from the CI logs of 2026-11-20..26; the
/// synthetic ones are the failures the judge exists for. Each rule has one case that only that rule fails.
final class IdleWakeJudgeTests: XCTestCase {
    private func window(_ seconds: Double = 60, cs: Int, passes: Int, wakes: Int?, refreshes: Int = 0, loop: IdleWakeJudge.Loop = .cfRunLoop,
                        fires: IdleWakeJudge.Fires = .init(), arrivals: [IdleBurstAttribution.Arrival] = []) -> IdleWakeJudge.Window {
        IdleWakeJudge.Window(seconds: seconds, loop: loop, cs: cs, passes: passes, wakes: wakes, fires: fires, refreshes: refreshes, arrivals: arrivals)
    }

    // MARK: real windows pass (their wake counts are what the counters would show: passes + fires + 1)

    func testTheReleaseIdleWindowThatCost104SwitchesPasses() {
        // release 45651391066, first installed attempt: 104 cs, 46 passes, safety 2, one refresh (legacy budget 69 failed it).
        let v = IdleWakeJudge.judge(window(cs: 104, passes: 46, wakes: 46 + 3 + 1, refreshes: 1, fires: .init(safety: 2, debounce: 1)))
        XCTAssertEqual(v.failures, [])
        XCTAssertEqual(v.residual, 1)
        XCTAssertEqual(v.ceiling, 60 + 3 * 49)
    }

    func testTheTeamWindowThatCost148SwitchesPasses() {
        // 45352376381, bundle team.idle: 148 cs, a refresh, safety 2, redial 8, dnssd 1, about 44 passes (legacy budget 87 failed it).
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 148, passes: 44, wakes: 44 + 11 + 2, refreshes: 1, fires: .init(safety: 2, redial: 8, dnssd: 1))).failures, [])
    }

    func testTheBundleWindowThatCost11SwitchesPasses() {
        // 44864580058: no refresh, one pass, two safety syncs, 11 cs (legacy budget 9 failed it).
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 11, passes: 1, wakes: 4, fires: .init(safety: 2))).failures, [])
    }

    func testTheModalWindowThatCost10SwitchesPasses() {
        // 45146411400, 10 s window: one safety sync, 10 cs (legacy budget 8 failed it).
        XCTAssertEqual(IdleWakeJudge.judge(window(10, cs: 10, passes: 1, wakes: 3, fires: .init(safety: 1))).failures, [])
    }

    // MARK: each rule fails its own case (and only it)

    func testR1ANamedTimerFiringTooOften() {
        let v = IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 11, fires: .init(safety: 10)))
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R1 safety 10 > 3") == true, "\(v.failures)")
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 4, fires: .init(safety: 3))).failures, [])
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 4, fires: .init(debounce: 2))).failures.count, 1)
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 4, fires: .init(day: 2))).failures.count, 1)
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 4, fires: .init(dnssd: 3))).failures.count, 1)
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 20, passes: 1, wakes: 12, fires: .init(redial: 11))).failures.count, 1)
    }

    func testR2TooManyPasses() {
        let v = IdleWakeJudge.judge(window(cs: 100, passes: 600, wakes: 600))
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R2 passes 600 > 3") == true, "\(v.failures)")
        // 80 per refresh: 83 passes pass with one refresh and 84 do not.
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 100, passes: 83, wakes: 83, refreshes: 1)).failures, [])
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 100, passes: 84, wakes: 84, refreshes: 1)).failures.count, 1)
    }

    func testR3UnattributedWakes() {
        let v = IdleWakeJudge.judge(window(cs: 60, passes: 1, wakes: 61 + 2, fires: .init(safety: 2)))   // a hidden 1 s timer: +60
        XCTAssertEqual(v.residual, 60)
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R3 unattributed wakes 60") == true, "\(v.failures)")
    }

    func testR3Boundary() {
        // W = 4 = the largest residual of 424 shadow windows (2) + 2. A residual of 4 passes, 5 fails (literal: changing W must change this test).
        XCTAssertEqual(IdleWakeJudge.Limits().residualAllowance, 4)
        let atW = IdleWakeJudge.judge(window(cs: 10, passes: 1, wakes: 1 + 4))
        XCTAssertEqual(atW.residual, 4)
        XCTAssertEqual(atW.failures, [])
        let overW = IdleWakeJudge.judge(window(cs: 10, passes: 1, wakes: 1 + 5))
        XCTAssertEqual(overW.residual, 5)
        XCTAssertEqual(overW.failures.count, 1)
        XCTAssertTrue(overW.failures.first?.hasPrefix("R3 unattributed wakes 5 > 4") == true, "\(overW.failures)")
        // The same boundary with a window's real shape: 60 s, a refresh, safety 2 (residual 4 = 46 + 2 + 1 passes' worth of wakes + 4).
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 100, passes: 46, wakes: 46 + 2 + 4, refreshes: 1, fires: .init(safety: 2))).failures, [])
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 100, passes: 46, wakes: 46 + 2 + 5, refreshes: 1, fires: .init(safety: 2))).failures.count, 1)
    }

    func testR3NoWakeCountOnTheCFLoopFailsAndTheDispatchLoopSkipsIt() {
        let cf = IdleWakeJudge.judge(window(cs: 10, passes: 1, wakes: nil))
        XCTAssertEqual(cf.failures.count, 1)
        XCTAssertTrue(cf.failures.first?.hasPrefix("R3 not judged") == true)
        XCTAssertNil(cf.residual)
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 10, passes: 1, wakes: nil, loop: .dispatchHandle)).failures, [])
    }

    func testR4RunawaySwitches() {
        let v = IdleWakeJudge.judge(window(cs: 400, passes: 1, wakes: 1, fires: .init(safety: 1)))
        XCTAssertEqual(v.ceiling, 60 + 3 * 2)
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R4 cs 400 > 66") == true, "\(v.failures)")
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 66, passes: 1, wakes: 2, fires: .init(safety: 1))).failures, [])
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 67, passes: 1, wakes: 2, fires: .init(safety: 1))).failures.count, 1)
    }

    // MARK: the loop strategies and the tolerated broadcast

    func testOnTheDispatchLoopEveryFireIsAlsoAPass() {
        // 4 passes of which 3 are named timer fires: one real pass. R2 judges passes - fires.
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 10, passes: 4, wakes: nil, loop: .dispatchHandle, fires: .init(safety: 2, debounce: 1))).failures, [])
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 100, passes: 600, wakes: nil, loop: .dispatchHandle)).failures.count, 1)
    }

    func testOneBroadcastFromOutsideIsTolerated() {
        func arrival(_ message: UInt32, root: Int, posted: Bool) -> IdleBurstAttribution.Arrival {
            .init(t: 3, message: message, root: root, rootClass: "C", posted: posted)
        }
        let w = IdleWakeJudge.Limits().residualAllowance
        let over = window(cs: 10, passes: 1, wakes: 1 + w + 1)
        XCTAssertEqual(IdleWakeJudge.judge(over).failures.count, 1)
        var sent = over
        sent.arrivals = [arrival(0x001A, root: 1, posted: false)]   // WM_SETTINGCHANGE, sent
        XCTAssertEqual(IdleWakeJudge.judge(sent).failures, [])
        var twoWindows = over
        twoWindows.arrivals = [arrival(0x0400, root: 1, posted: false), arrival(0x0400, root: 2, posted: false)]
        XCTAssertEqual(IdleWakeJudge.judge(twoWindows).failures, [])
        var posted = over
        posted.arrivals = [arrival(0x001A, root: 1, posted: true)]   // posted: ours or input, not tolerated
        XCTAssertEqual(IdleWakeJudge.judge(posted).failures.count, 1)
        var ours = over
        ours.arrivals = [arrival(0x0400, root: 1, posted: false)]   // sent to one window, no known broadcast
        XCTAssertEqual(IdleWakeJudge.judge(ours).failures.count, 1)
        // Only one broadcast's worth is tolerated.
        var many = window(cs: 10, passes: 1, wakes: 1 + w + 2)
        many.arrivals = [arrival(0x001A, root: 1, posted: false), arrival(0x031A, root: 1, posted: false)]
        XCTAssertEqual(IdleWakeJudge.judge(many).failures.count, 1)
    }

    // MARK: what the four injections do to the judge (the plan's section 3 table; CI runs them for real)

    func testAHiddenOneSecondTimerFailsOnR3InEveryWindowKind() {
        // 60 s with a refresh: ~60 unnamed wakes on top of the normal ones.
        let long = IdleWakeJudge.judge(window(cs: 160, passes: 46, wakes: 46 + 3 + 1 + 60, refreshes: 1, fires: .init(safety: 2, debounce: 1)))
        XCTAssertEqual(long.failures.count, 1)
        XCTAssertTrue(long.failures.first?.hasPrefix("R3") == true, "\(long.failures)")
        // 10 s (modal, ui.kit): about 10.
        let short = IdleWakeJudge.judge(window(10, cs: 12, passes: 1, wakes: 1 + 10, fires: .init()))
        XCTAssertEqual(short.failures.count, 1)
        XCTAssertTrue(short.failures.first?.hasPrefix("R3") == true, "\(short.failures)")
    }

    func testFiftyBlockingWaitsInOneBlockPassBecauseTheyAreOneWake() {
        // The case the switch budget got wrong (CI run 45800274652, bundle idle.window): 53 cs against its 9, passes 3, safety 2, wakes 6.
        let v = IdleWakeJudge.judge(window(cs: 53, passes: 3, wakes: 6, fires: .init(safety: 2)))
        XCTAssertEqual(v.failures, [])
        XCTAssertEqual(v.ceiling, 60 + 3 * 5)
    }

    func testAMainQueueLoopFailsOnR2() {
        let v = IdleWakeJudge.judge(window(cs: 1200, passes: 580, wakes: 580 + 3))
        XCTAssertTrue(v.failures.contains { $0.hasPrefix("R2 passes 580") }, "\(v.failures)")
    }

    func testThreeHundredPollWaitsFailOnR4Only() {
        // CI run 45800295466: cs 307, passes 3, safety 2.
        let v = IdleWakeJudge.judge(window(cs: 307, passes: 3, wakes: 6, fires: .init(safety: 2)))
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R4 cs 307 > 75") == true, "\(v.failures)")
    }

    func testWithoutRunawayKeepsR1ToR3AndDropsOnlyR4() {
        // modalPump.idle judges R4 itself, through IdleBurstAttribution (one broadcast burst tolerated).
        let runawayOnly = IdleWakeJudge.judge(window(10, cs: 400, passes: 1, wakes: 2))
        XCTAssertFalse(runawayOnly.ok)
        XCTAssertEqual(runawayOnly.withoutRunaway, [])
        let r3 = IdleWakeJudge.judge(window(10, cs: 12, passes: 1, wakes: 12))
        XCTAssertEqual(r3.withoutRunaway, r3.failures)
        XCTAssertEqual(r3.failures.count, 1)
    }

    // MARK: review round 1: the dispatch loop's R4, the negative residual, the broadcast, R1 at its limits, the 89-against-87 window

    func testOnTheDispatchLoopR4CountsPassesOnceBecauseFiresAreAlreadyInThem() {
        // 4 passes of which 3 are fires: wakes = (4 - 3) + 3 = 4, ceiling 60 + 3 * 4 (not 60 + 3 * 7).
        let v = IdleWakeJudge.judge(window(cs: 10, passes: 4, wakes: nil, loop: .dispatchHandle, fires: .init(safety: 2, debounce: 1)))
        XCTAssertEqual(v.ceiling, 60 + 3 * 4)
        XCTAssertNil(v.residual)
    }

    func testANegativeResidualBelowMinusWFailsAsAnInconsistentCounter() {
        // 6 passes but no wake counted: the accounting is broken (a wake counted twice, or a counter that misses wakes).
        let v = IdleWakeJudge.judge(window(cs: 10, passes: 6, wakes: 0, refreshes: 1))
        XCTAssertEqual(v.residual, -6)
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R3 counter inconsistent: residual -6 < -4") == true, "\(v.failures)")
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 10, passes: 5, wakes: 1, refreshes: 1)).failures, [])   // -4 = -W passes
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 10, passes: 6, wakes: 1, refreshes: 1)).failures.count, 1)   // -5 fails
    }

    func testABroadcastIsSubtractedOnlyAsFarAsAWakeIsLeftToExplain() {
        func sent() -> [IdleBurstAttribution.Arrival] { [.init(t: 3, message: 0x001A, root: 1, rootClass: "C", posted: false)] }
        // No wake left (raw 0): nothing is subtracted, the residual stays 0 (it used to become -1).
        var clean = window(cs: 10, passes: 1, wakes: 1); clean.arrivals = sent()
        XCTAssertEqual(IdleWakeJudge.judge(clean).residual, 0)
        // raw -4 with a broadcast stays -4 (passes), not -5 (which would fail).
        var low = window(cs: 10, passes: 5, wakes: 1, refreshes: 1); low.arrivals = sent()
        XCTAssertEqual(IdleWakeJudge.judge(low).residual, -4)
        XCTAssertEqual(IdleWakeJudge.judge(low).failures, [])
        // W + 1 unexplained wakes pass with a broadcast (one is its own), W + 2 fail: the allowance with a broadcast is W + 1 raw.
        var five = window(cs: 10, passes: 1, wakes: 1 + 5); five.arrivals = sent()
        XCTAssertEqual(IdleWakeJudge.judge(five).failures, [])
        var six = window(cs: 10, passes: 1, wakes: 1 + 6); six.arrivals = sent()
        XCTAssertEqual(IdleWakeJudge.judge(six).failures.count, 1)
    }

    func testR1AtItsLimitsPassesAndOneOverFails() {
        func fails(_ seconds: Double, _ fires: IdleWakeJudge.Fires) -> Int {
            IdleWakeJudge.judge(window(seconds, cs: 1, passes: 1, wakes: 1 + fires.total, fires: fires)).failures.filter { $0.hasPrefix("R1") }.count
        }
        XCTAssertEqual(fails(60, .init(redial: 10)), 0)   // 2 * (floor(60 / 15) + 1)
        XCTAssertEqual(fails(60, .init(redial: 11)), 1)
        XCTAssertEqual(fails(10, .init(redial: 2)), 0)    // 2 * (floor(10 / 15) + 1)
        XCTAssertEqual(fails(10, .init(redial: 3)), 1)
        XCTAssertEqual(fails(10, .init(safety: 1)), 0)    // floor(10 / 30) + 1
        XCTAssertEqual(fails(10, .init(safety: 2)), 1)
        XCTAssertEqual(fails(60, .init(safety: 3)), 0)
        XCTAssertEqual(fails(60, .init(safety: 4)), 1)
        XCTAssertEqual(fails(60, .init(dnssd: 2)), 0)
        XCTAssertEqual(fails(60, .init(dnssd: 3)), 1)
        XCTAssertEqual(fails(60, .init(debounce: 1)), 0)
        XCTAssertEqual(fails(60, .init(debounce: 2)), 1)
        XCTAssertEqual(fails(60, .init(day: 1)), 0)
        XCTAssertEqual(fails(60, .init(day: 2)), 1)
    }

    func testTheTeamWindowThatCost89AgainstABudgetOf87Passes() {
        // windows-app 45758990297 (#395's PR run, bundle team.idle), before the wake counter existed. From its log: cs 89, redial 8, dnssd 0,
        // one refresh, main cycles 40.3 M. ASSUMED (the line has no counters): passes 47 (the median of 68 team windows with a refresh is 48),
        // safety 2, residual 1. Legacy budget 87 failed it; here the ceiling is 60 + 3 * 57.
        let v = IdleWakeJudge.judge(window(cs: 89, passes: 47, wakes: 47 + 10 + 1, refreshes: 1, fires: .init(safety: 2, redial: 8)))
        XCTAssertEqual(v.failures, [])
        XCTAssertEqual(v.ceiling, 60 + 3 * 57)
    }
}
