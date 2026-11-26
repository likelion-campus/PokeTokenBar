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
        XCTAssertEqual(v.ceiling, 60 + 4 * 49)
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
        let v = IdleWakeJudge.judge(window(cs: 70, passes: 1, wakes: 61 + 2, fires: .init(safety: 2)))   // a hidden 1 s timer: +60
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
        XCTAssertEqual(v.ceiling, 60 + 4 * 2)
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R4 cs 400 > 68") == true, "\(v.failures)")
        XCTAssertEqual(IdleWakeJudge.judge(window(cs: 68, passes: 1, wakes: 2, fires: .init(safety: 1))).failures, [])
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
        // The case the switch budget got wrong: 53 cs against its 9, one pass, two wakes.
        let v = IdleWakeJudge.judge(window(cs: 53, passes: 1, wakes: 2))
        XCTAssertEqual(v.failures, [])
        XCTAssertEqual(v.ceiling, 60 + 4)
    }

    func testAMainQueueLoopFailsOnR2() {
        let v = IdleWakeJudge.judge(window(cs: 1200, passes: 580, wakes: 580 + 3))
        XCTAssertTrue(v.failures.contains { $0.hasPrefix("R2 passes 580") }, "\(v.failures)")
    }

    func testThreeHundredPollWaitsFailOnR4Only() {
        let v = IdleWakeJudge.judge(window(cs: 304, passes: 1, wakes: 2))
        XCTAssertEqual(v.failures.count, 1)
        XCTAssertTrue(v.failures.first?.hasPrefix("R4 cs 304 > 64") == true, "\(v.failures)")
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
}
