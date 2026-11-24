import XCTest
@testable import PokeTokenBar

/// The Mac half of the stability audit batch: the display-awake flags and the team transport's missed wake.
@MainActor
final class AuditStabilityMacTests: XCTestCase {
    // MARK: 1. the awake flag follows the platform, not only the notifications

    func testAwakeFlagIsCorrectedWhenAWakeNotificationWasMissed() {
        XCTAssertEqual(AppDelegate.displayAwakeCorrection(current: false, displaysAsleep: false), true,
                       "screensDidWake never came: the sprite and the pet stayed stopped")
        XCTAssertEqual(AppDelegate.displayAwakeCorrection(current: true, displaysAsleep: true), false)
        XCTAssertNil(AppDelegate.displayAwakeCorrection(current: true, displaysAsleep: false))
        XCTAssertNil(AppDelegate.displayAwakeCorrection(current: false, displaysAsleep: true))
    }

    // MARK: 1b. a transport suspended by willSleep starts again without didWake

    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_700_000_000) }

    private func makeSleptTransport(_ clock: Clock) -> BonjourTeamTransport {
        let t = BonjourTeamTransport(advertise: false)
        t.clock = { clock.now }
        var rng = SystemRandomNumberGenerator()
        t.start(code: TeamCode.generate(using: &rng))
        addTeardownBlock { t.stop() }
        t.handleWillSleep()
        return t
    }

    func testReachabilityEventAfterAMinuteOfSleepRestartsTheTransport() async {
        let clock = Clock()
        let t = makeSleptTransport(clock)
        t.restart()                       // a reachability event right away: still asleep
        XCTAssertNil(t.listenerPort)
        clock.now.addTimeInterval(BonjourTeamTransport.wakeRecoveryDelay + 1)
        t.restart()                       // the first one after a minute
        let up = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(up, "didWake never came and a network event did not bring the team back")
    }

    func testTheRecoveryTimerRestartsTheTransportToo() async {
        let clock = Clock()
        let t = makeSleptTransport(clock)
        clock.now.addTimeInterval(BonjourTeamTransport.wakeRecoveryDelay + 1)
        t.recoverFromMissedWake()
        let up = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(up)
    }

    func testDidWakeStillRestartsImmediately() async {
        let clock = Clock()
        let t = makeSleptTransport(clock)
        t.handleDidWake()
        let up = await contractWaitUntil(5) { t.listenerPort != nil }
        XCTAssertTrue(up)
    }
}
