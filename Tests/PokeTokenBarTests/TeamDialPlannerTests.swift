import XCTest
@testable import PokeTokenBar

final class TeamDialPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testDiscoveredEndpointIsDialedOnce() {
        var p = TeamDialPlanner()
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
        p.dialStarted("a", peer: "p1")
        XCTAssertEqual(p.dueDials(now: t0), [])
    }

    func testEndedConnectionIsRedialed() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
    }

    func testFailedHandshakeWaitsCooldown() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: true, now: t0)
        XCTAssertEqual(p.dueDials(now: t0.addingTimeInterval(59)), [])
        XCTAssertEqual(p.dueDials(now: t0.addingTimeInterval(60)), ["a"])
    }

    func testRefusedConnectionWaitsFiveMinutes() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: false, refused: true, now: t0)
        XCTAssertEqual(p.dueDials(now: t0.addingTimeInterval(299)), [])
        XCTAssertEqual(p.dueDials(now: t0.addingTimeInterval(300)), ["a"])
    }

    func testCoveredEndpointIsNotRedialedUntilKeptConnectionEnds() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)
        p.cover(peer: "p1", by: "p2")
        XCTAssertEqual(p.dueDials(now: t0), [])
        p.connectionEnded(peer: "p2", handshakeFailed: false, now: t0)
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
    }

    func testCoverOrderDoesNotMatter() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.cover(peer: "p1", by: "p2")
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)
        XCTAssertEqual(p.dueDials(now: t0), [])
        p.connectionEnded(peer: "p2", handshakeFailed: false, now: t0)
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
    }

    func testLostEndpointIsNotDialed() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.lost("a")
        XCTAssertEqual(p.dueDials(now: t0), [])
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
    }
}
