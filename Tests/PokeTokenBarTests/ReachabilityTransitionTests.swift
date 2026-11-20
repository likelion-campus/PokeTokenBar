import XCTest
@testable import PokeTokenBar

final class ReachabilityTransitionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testColdStartNeverTriggers() {
        var t = ReachabilityTransition()
        XCTAssertFalse(t.update(isSatisfied: true, now: t0))
        var u = ReachabilityTransition()
        XCTAssertFalse(u.update(isSatisfied: false, now: t0))
    }

    func testOfflineToOnlineTriggersOnce() {
        var t = ReachabilityTransition()
        XCTAssertFalse(t.update(isSatisfied: false, now: t0))
        XCTAssertTrue(t.update(isSatisfied: true, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(t.update(isSatisfied: true, now: t0.addingTimeInterval(2)), "already online")
        XCTAssertFalse(t.update(isSatisfied: false, now: t0.addingTimeInterval(3)), "going offline is not a reconnect")
    }

    func testFlappingInsideTheCooldownIsSuppressed() {
        var t = ReachabilityTransition(cooldown: 5)
        _ = t.update(isSatisfied: false, now: t0)
        XCTAssertTrue(t.update(isSatisfied: true, now: t0.addingTimeInterval(1)))
        _ = t.update(isSatisfied: false, now: t0.addingTimeInterval(2))
        XCTAssertFalse(t.update(isSatisfied: true, now: t0.addingTimeInterval(3)), "2 s after the last trigger")
        _ = t.update(isSatisfied: false, now: t0.addingTimeInterval(4))
        XCTAssertTrue(t.update(isSatisfied: true, now: t0.addingTimeInterval(7)), "6 s after the last trigger")
    }

    func testResetForgetsTheLastObservation() {
        var t = ReachabilityTransition()
        _ = t.update(isSatisfied: false, now: t0)
        t.reset()
        XCTAssertFalse(t.update(isSatisfied: true, now: t0.addingTimeInterval(10)), "first observation after a reset is a cold start")
    }
}
