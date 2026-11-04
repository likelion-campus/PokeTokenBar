import XCTest
@testable import PokeTokenBar

@MainActor final class PlazaCampfireTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    private func tile(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testSeatsAreTheEightFromTheSpec() {
        let expected: [PlazaCampfire.Seat] = [
            .init(tile: tile(35, 21), facing: .down), .init(tile: tile(38, 21), facing: .down),
            .init(tile: tile(32, 21), facing: .right), .init(tile: tile(41, 21), facing: .left),
            .init(tile: tile(33, 24), facing: .right), .init(tile: tile(40, 24), facing: .left),
            .init(tile: tile(35, 27), facing: .up), .init(tile: tile(38, 27), facing: .up),
        ]
        XCTAssertEqual(PlazaCampfire.seats, expected)
        XCTAssertEqual(PlazaCampfire.durations, [25, 50, 480])
    }

    func testNearestFreeSeatSkipsTakenSeatsAndBreaksTiesInListOrder() {
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(36, 22), occupied: [])?.tile, tile(35, 21))
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(36, 22), occupied: [tile(35, 21)])?.tile, tile(38, 21))
        let all = Set(PlazaCampfire.seats.map(\.tile))
        XCTAssertNil(PlazaCampfire.nearestFreeSeat(from: tile(36, 22), occupied: all))
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(34, 24), occupied: [])?.tile, tile(33, 24))
        // (36,24): (35,21) 과 (35,27) 이 거리 10 으로 동률 — 목록에서 앞선 자리가 이긴다.
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(36, 24), occupied: [tile(33, 24), tile(40, 24)])?.tile, tile(35, 21))
    }

    func testClockFormat() {
        XCTAssertEqual(PlazaCampfire.clock(1122), "18:42")
        XCTAssertEqual(PlazaCampfire.clock(27730), "7:42:10")
        XCTAssertEqual(PlazaCampfire.clock(0.2), "0:01")
        XCTAssertEqual(PlazaCampfire.clock(-5), "0:00")
        XCTAssertEqual(PlazaCampfire.clock(3600), "1:00:00")
    }

    func testRemainingWords() {
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 1122), "19분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 27730), "7시간 43분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 30), "1분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 28800), "8시간 남음")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 25), "25분")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 50), "50분")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 480), "8시간")
    }

    func testAcceptedEndsAtWindow() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PlazaFocus.accepted(nil, now: t0))
        XCTAssertNil(PlazaFocus.accepted(t0.addingTimeInterval(-1), now: t0))
        XCTAssertEqual(PlazaFocus.accepted(t0.addingTimeInterval(1500), now: t0), t0.addingTimeInterval(1500))
        let edge = t0.addingTimeInterval(PlazaFocus.maxAhead)
        XCTAssertEqual(PlazaFocus.accepted(edge, now: t0), edge)
        XCTAssertNil(PlazaFocus.accepted(edge.addingTimeInterval(1), now: t0))
        XCTAssertNil(PlazaFocus.accepted(.distantFuture, now: t0))
    }

    func testIsActive() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let f = PlazaFocus(endsAt: t0, minutes: 25, seat: tile(35, 21))
        XCTAssertTrue(f.isActive(at: t0.addingTimeInterval(-1)))
        XCTAssertFalse(f.isActive(at: t0))
    }

    func testFocusSurvivesPreferencesRoundTrip() {
        let name = "plaza.test.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertNil(prefs.focus)
        let f = PlazaFocus(endsAt: Date(timeIntervalSince1970: 1_800_001_500), minutes: 25, seat: tile(35, 21))
        prefs.focus = f
        XCTAssertEqual(prefs.focus, f)
        prefs.focus = nil
        XCTAssertNil(prefs.focus)
    }
}
