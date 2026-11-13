import XCTest
@testable import PokeTokenBar

@MainActor final class PlazaCampfireTests: XCTestCase {
    private func tile(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testSeatsAreTheEightFromTheSpec() async {
        let expected: [PlazaCampfire.Seat] = [
            .init(tile: tile(22, 13), facing: .down), .init(tile: tile(25, 13), facing: .down),
            .init(tile: tile(19, 13), facing: .right), .init(tile: tile(28, 13), facing: .left),
            .init(tile: tile(20, 16), facing: .right), .init(tile: tile(27, 16), facing: .left),
            .init(tile: tile(22, 19), facing: .up), .init(tile: tile(25, 19), facing: .up),
        ]
        XCTAssertEqual(PlazaCampfire.seats, expected)
        XCTAssertEqual(PlazaCampfire.durations, [25, 50, 480])
    }

    func testNearestFreeSeatSkipsTakenSeatsAndBreaksTiesInListOrder() async {
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(23, 14), occupied: [])?.tile, tile(22, 13))
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(23, 14), occupied: [tile(22, 13)])?.tile, tile(25, 13))
        let all = Set(PlazaCampfire.seats.map(\.tile))
        XCTAssertNil(PlazaCampfire.nearestFreeSeat(from: tile(23, 14), occupied: all))
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(21, 16), occupied: [])?.tile, tile(20, 16))
        // (23,16): (22,13) 과 (22,19) 가 거리 10 으로 동률 — 목록에서 앞선 자리가 이긴다.
        XCTAssertEqual(PlazaCampfire.nearestFreeSeat(from: tile(23, 16), occupied: [tile(20, 16), tile(27, 16)])?.tile, tile(22, 13))
    }

    /// 자리는 지도의 모닥불 자리에서 도출한다: 구덩이 왼쪽 위 칸 기준 오프셋이 그대로 따라온다.
    func testSeatsFollowThePitOnTheMap() async {
        let origin = PlazaMapData.map.campfireTiles.first!
        XCTAssertEqual(origin, tile(23, 15))
        XCTAssertEqual(PlazaCampfire.seats.first?.tile, tile(origin.x - 1, origin.y - 2))
        XCTAssertEqual(PlazaCampfire.seats.last?.tile, tile(origin.x + 2, origin.y + 4))
    }

    /// 모닥불이 옮겨지기 전 버전의 자리(35,21)는 가장 가까운 새 자리로 대응한다. 점유는 보지 않고 동률이면 목록 순서다.
    func testNearestSeatIgnoresOccupancyAndBreaksTiesInListOrder() async {
        XCTAssertEqual(PlazaCampfire.nearestSeat(to: tile(35, 21))?.tile, tile(27, 16))
        XCTAssertEqual(PlazaCampfire.nearestSeat(to: tile(22, 13))?.tile, tile(22, 13))
        XCTAssertEqual(PlazaCampfire.nearestSeat(to: tile(18, 15))?.tile, tile(19, 13), "tie with (20,16): the earlier seat wins")
    }

    func testClockFormat() async {
        XCTAssertEqual(PlazaCampfire.clock(1122), "18:42")
        XCTAssertEqual(PlazaCampfire.clock(27730), "7:42:10")
        XCTAssertEqual(PlazaCampfire.clock(0.2), "0:01")
        XCTAssertEqual(PlazaCampfire.clock(-5), "0:00")
        XCTAssertEqual(PlazaCampfire.clock(3600), "1:00:00")
    }

    func testRemainingWords() async {
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 1122), "19분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 27730), "7시간 43분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 30), "1분 남음")
        XCTAssertEqual(L(.ko).plazaFocusRemaining(seconds: 28800), "8시간 남음")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 25), "25분")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 50), "50분")
        XCTAssertEqual(L(.ko).plazaFocusDuration(minutes: 480), "8시간")
    }

    func testAcceptedEndsAtWindow() async {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PlazaFocus.accepted(nil, now: t0))
        XCTAssertNil(PlazaFocus.accepted(t0.addingTimeInterval(-1), now: t0))
        XCTAssertEqual(PlazaFocus.accepted(t0.addingTimeInterval(1500), now: t0), t0.addingTimeInterval(1500))
        let edge = t0.addingTimeInterval(PlazaFocus.maxAhead)
        XCTAssertEqual(PlazaFocus.accepted(edge, now: t0), edge)
        XCTAssertNil(PlazaFocus.accepted(edge.addingTimeInterval(1), now: t0))
        XCTAssertNil(PlazaFocus.accepted(.distantFuture, now: t0))
    }

    func testIsActive() async {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let f = PlazaFocus(endsAt: t0, minutes: 25, seat: tile(35, 21))
        XCTAssertTrue(f.isActive(at: t0.addingTimeInterval(-1)))
        XCTAssertFalse(f.isActive(at: t0))
    }

    func testFocusSurvivesPreferencesRoundTrip() async {
        let name = "plaza.test.\(UUID())"
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: name))
        XCTAssertNil(prefs.focus)
        let f = PlazaFocus(endsAt: Date(timeIntervalSince1970: 1_800_001_500), minutes: 25, seat: tile(35, 21))
        prefs.focus = f
        XCTAssertEqual(prefs.focus, f)
        prefs.focus = nil
        XCTAssertNil(prefs.focus)
    }
}
