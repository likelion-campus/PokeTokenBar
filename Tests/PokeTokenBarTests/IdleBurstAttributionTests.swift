import XCTest
@testable import PokeTokenBar

/// `modalPump.idle` over its budget (`IdleBurstAttribution.judge`): one burst is tolerated only when it is a broadcast another process
/// sent; anything else still fails, with what arrived named.
final class IdleBurstAttributionTests: XCTestCase {
    private typealias A = IdleBurstAttribution.Arrival
    private typealias W = IdleBurstAttribution.Wake
    // The failing runs' shape: budget 8, one 100 ms sample of 12 at ~4.9 s, the safety wake's 1 elsewhere.
    private let wakes = [W(t: 1.2, cs: 1), W(t: 4.9, cs: 12)]
    private let sink = 0x10, popover = 0x20, tray = 0x30

    private func sent(_ message: UInt32, at t: Double, to root: Int, _ cls: String) -> A { A(t: t, message: message, root: root, rootClass: cls, posted: false) }
    private func judge(_ arrivals: [A], cs: Int = 13, budget: Int = 8) -> IdleBurstAttribution.Verdict {
        IdleBurstAttribution.judge(cs: cs, budget: budget, wakes: wakes, arrivals: arrivals)
    }

    func testWithinTheBudgetNothingIsJudged() {
        XCTAssertEqual(IdleBurstAttribution.judge(cs: 8, budget: 8, wakes: wakes, arrivals: []).ok, true)
    }

    func testABroadcastToSeveralOfOurWindowsIsToleratedOnceAndNamed() {
        let v = judge([sent(0xC0F1, at: 4.85, to: sink, "PokeTokenBarSink"), sent(0xC0F1, at: 4.86, to: popover, "PokeTokenBarPopover"),
                       sent(0xC0F1, at: 4.86, to: tray, "PokeTokenBarTray")])
        XCTAssertTrue(v.ok, v.note)
        XCTAssertTrue(v.note.contains("0xc0f1 x3 to PokeTokenBarSink,PokeTokenBarPopover,PokeTokenBarTray sent"), v.note)
    }

    func testAKnownSystemBroadcastIsToleratedEvenToOneWindow() {
        let v = judge([sent(0x1A, at: 4.9, to: sink, "PokeTokenBarSink")])
        XCTAssertTrue(v.ok, v.note)
        XCTAssertTrue(v.note.contains("WM_SETTINGCHANGE x1"), v.note)
    }

    func testAnUnattributedBurstFails() {
        let v = judge([])
        XCTAssertFalse(v.ok)
        XCTAssertTrue(v.note.contains("unattributed"), v.note)
        // a message long before the burst does not explain it
        XCTAssertFalse(judge([sent(0x1A, at: 1.0, to: sink, "PokeTokenBarSink")]).ok)
    }

    func testAPostedMessageInTheBurstFails() {
        let posted = A(t: 4.88, message: 0x113, root: sink, rootClass: "PokeTokenBarSink", posted: true)
        let v = judge([sent(0x1A, at: 4.86, to: sink, "PokeTokenBarSink"), posted])
        XCTAssertFalse(v.ok)
        XCTAssertTrue(v.note.contains("posted"), v.note)
    }

    func testASentMessageToOneWindowThatIsNoBroadcastFails() {
        // e.g. a worker thread of ours sending to the sink: from another thread, but not a broadcast
        let v = judge([sent(0x8030, at: 4.9, to: sink, "PokeTokenBarSink")])
        XCTAssertFalse(v.ok)
        XCTAssertTrue(v.note.contains("not a broadcast"), v.note)
    }

    func testOnlyOneBurstIsTolerated() {
        // a broadcast at 4.9 s explains 12; another 5 elsewhere over the budget of 8 still fails
        let twoBursts = [W(t: 1.2, cs: 5), W(t: 4.9, cs: 12), W(t: 7.0, cs: 5)]
        let v = IdleBurstAttribution.judge(cs: 22, budget: 8, wakes: twoBursts,
                                           arrivals: [sent(0x1A, at: 4.9, to: sink, "PokeTokenBarSink")])
        XCTAssertFalse(v.ok)
        XCTAssertTrue(v.note.contains("the rest 10 is still over the budget 8"), v.note)
    }

    /// A refresh still running at the window's end is budgeted although the app has not counted it yet (the release run's
    /// `ui.kit.idle`: refresh 0, 39 switches, budget 11); finished ones count as before, and a quiet window budgets none.
    func testARefreshStillRunningAtTheWindowsEndIsBudgeted() {
        XCTAssertEqual(IdleBurstAttribution.refreshesInWindow(countBefore: 4, countAfter: 4, runningAtEnd: true), 1)
        XCTAssertEqual(IdleBurstAttribution.refreshesInWindow(countBefore: 4, countAfter: 5, runningAtEnd: false), 1)
        XCTAssertEqual(IdleBurstAttribution.refreshesInWindow(countBefore: 4, countAfter: 5, runningAtEnd: true), 2, "one finished, the next running")
        XCTAssertEqual(IdleBurstAttribution.refreshesInWindow(countBefore: 4, countAfter: 4, runningAtEnd: false), 0)
    }
}
