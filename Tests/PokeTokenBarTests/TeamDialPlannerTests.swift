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
        p.discovered("a"); p.lost("a", now: t0)
        XCTAssertEqual(p.dueDials(now: t0), [])
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0), ["a"])
    }

    // MARK: - Rogue services (anyone on the network can advertise any number of names)

    private struct SeededGenerator: RandomNumberGenerator {
        var mix: PlazaSplitMix64
        init(seed: UInt64) { mix = PlazaSplitMix64(seed: seed) }
        mutating func next() -> UInt64 { mix.next() }
    }

    func testPicksStopAtTheLimit() {
        var p = TeamDialPlanner()
        for i in 0..<50 { p.discovered("n\(i)") }
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(p.dialPicks(now: t0, limit: 32, using: &rng).count, 32)
        XCTAssertEqual(p.dialPicks(now: t0, limit: 0, using: &rng), [])
        XCTAssertEqual(p.dialPicks(now: t0, limit: -3, using: &rng), [], "no room can come out negative")
        XCTAssertEqual(p.dialPicks(now: t0, limit: 99, using: &rng).count, 50)
    }

    /// A rogue can pick names that sort first, so a fixed order would never reach the real teammate.
    func testALastSortingNameIsStillPickedAmongMany() {
        var p = TeamDialPlanner()
        for i in 0..<100 { p.discovered("a-rogue-\(i)") }
        p.discovered("z-teammate")
        var rng = SeededGenerator(seed: 7)
        let rounds = (0..<50).map { _ in p.dialPicks(now: t0, limit: 32, using: &rng) }
        XCTAssertTrue(rounds.contains { $0.contains("z-teammate") })
    }

    func testPicksOnlyDueNames() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.discovered("b"); p.dialStarted("a", peer: "p1")
        var rng = SeededGenerator(seed: 1)
        XCTAssertEqual(p.dialPicks(now: t0, limit: 32, using: &rng), ["b"])
    }

    func testLostNameWithNothingPendingIsForgotten() {
        var p = TeamDialPlanner()
        for i in 0..<1000 { p.discovered("n\(i)"); p.lost("n\(i)", now: t0) }
        XCTAssertEqual(p.nameCount, 0, "rotating names must not pile up for the life of the app")
    }

    func testLostNameStillCoolingDownKeepsItsCooldown() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: true, now: t0)
        p.lost("a", now: t0.addingTimeInterval(1))
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0.addingTimeInterval(59)), [], "flapping must not skip the wait")
    }

    func testLostNameAfterItsCooldownIsForgotten() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: true, now: t0)
        p.lost("a", now: t0.addingTimeInterval(60))
        XCTAssertEqual(p.nameCount, 0)
    }

    func testLostNameWithALiveDialStaysUntilItEnds() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.lost("a", now: t0)
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0), [], "the dial is still running, so a second one would be a duplicate")
    }

    func testLostCoveredNameStaysCovered() {
        var p = TeamDialPlanner()
        p.discovered("a"); p.dialStarted("a", peer: "p1")
        p.cover(peer: "p1", by: "p2")
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)
        p.lost("a", now: t0)
        p.discovered("a")
        XCTAssertEqual(p.dueDials(now: t0), [])
    }
}
