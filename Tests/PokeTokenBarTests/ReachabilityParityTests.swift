import Network
import XCTest
@testable import PokeTokenBar

/// The Bool state machine the Windows monitor uses must give the Mac monitor's answer for every history.
final class ReachabilityParityTests: XCTestCase {
    func testTransitionAgreesWithTheMacMonitorOnEveryPair() {
        let statuses: [NWPath.Status] = [.satisfied, .unsatisfied, .requiresConnection]
        let t0 = Date(timeIntervalSince1970: 5_000)
        let triggers: [Date?] = [nil, t0.addingTimeInterval(-1), t0.addingTimeInterval(-10)]
        for prev in [nil] + statuses.map(Optional.some) {
            for current in statuses {
                for last in triggers {
                    var t = ReachabilityTransition(cooldown: 5)
                    if let last {  // reproduce "triggered at `last`" then the history `prev`
                        _ = t.update(isSatisfied: false, now: last.addingTimeInterval(-1))
                        XCTAssertTrue(t.update(isSatisfied: true, now: last))
                    }
                    if let prev { _ = t.update(isSatisfied: prev == .satisfied, now: t0.addingTimeInterval(-0.5)) } else { t.reset() }
                    let mine = t.update(isSatisfied: current == .satisfied, now: t0)
                    let mac = NetworkReachabilityMonitor.shouldTriggerReconnect(
                        from: prev, to: current, lastTriggeredAt: last, now: t0, cooldown: 5)
                    XCTAssertEqual(mine, mac, "prev=\(String(describing: prev)) current=\(current) last=\(String(describing: last))")
                }
            }
        }
    }
}
