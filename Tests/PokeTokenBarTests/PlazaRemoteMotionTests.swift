import XCTest
@testable import PokeTokenBar

final class PlazaRemoteMotionTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testAdjacentMoveTakesOneStep() {
        var m = PlazaRemoteMotion(tile: p(5, 5), facing: .down)
        m.moveTo(p(6, 5))
        XCTAssertTrue(m.isWalking)
        m.advance(by: 0.1)
        let mid = PlazaWalker.footPoint(from: p(5, 5), to: p(6, 5), progress: 0.5)
        XCTAssertEqual(m.footPoint.x, mid.x, accuracy: 1e-9)
        XCTAssertEqual(m.footPoint.y, mid.y, accuracy: 1e-9)
        XCTAssertEqual(m.facing, .right)
        m.advance(by: 0.1)
        XCTAssertEqual(m.footPoint, PlazaWalker.footPoint(from: p(6, 5), to: p(6, 5), progress: 0))
        XCTAssertEqual(m.tile, p(6, 5))
        XCTAssertFalse(m.isWalking)
    }

    func testQueuedMovesPlayInOrder() {
        var m = PlazaRemoteMotion(tile: p(5, 5), facing: .down)
        m.moveTo(p(6, 5)); m.moveTo(p(6, 6))
        var seen: [CGPoint] = []
        for _ in 0..<41 { m.advance(by: 0.01); seen.append(m.footPoint) }
        // 어느 순간에도 대각선 위에 있지 않다: 첫 칸 이동은 y가, 둘째 칸 이동은 x가 칸 값에 붙어 있다.
        let s = Double(PlazaMap.tileSize)
        for f in seen {
            XCTAssertTrue(abs(f.y - 5.875 * s) < 1e-6 || abs(f.x - 6.5 * s) < 1e-6, "off-axis point \(f)")
        }
        XCTAssertEqual(m.tile, p(6, 6)); XCTAssertEqual(m.facing, .down)
        XCTAssertFalse(m.isWalking)
    }

    func testSenderWalkingKeepsIsWalking() {
        var m = PlazaRemoteMotion(tile: p(1, 1), facing: .down)
        XCTAssertFalse(m.isWalking)
        m.senderIsWalking = true
        XCTAssertTrue(m.isWalking)
    }

    func testDistantMoveSnaps() {
        var m = PlazaRemoteMotion(tile: p(5, 5), facing: .down)
        m.moveTo(p(7, 5))
        XCTAssertEqual(m.tile, p(7, 5)); XCTAssertFalse(m.isWalking)
        m.moveTo(p(8, 6)) // 대각선도 옆 칸이 아니다
        XCTAssertEqual(m.tile, p(8, 6)); XCTAssertFalse(m.isWalking)
    }

    func testLongQueueCatchesUp() {
        var m = PlazaRemoteMotion(tile: p(0, 0), facing: .down)
        m.moveTo(p(1, 0)); m.moveTo(p(2, 0)); m.moveTo(p(3, 0))
        XCTAssertTrue(m.isWalking); XCTAssertEqual(m.tile, p(0, 0))
        m.moveTo(p(4, 0))
        XCTAssertEqual(m.tile, p(4, 0)); XCTAssertFalse(m.isWalking)
    }

    func testSnapClearsQueueAndStep() {
        var m = PlazaRemoteMotion(tile: p(0, 0), facing: .down)
        m.moveTo(p(1, 0)); m.advance(by: 0.05); m.moveTo(p(1, 1))
        m.snap(to: p(9, 9))
        XCTAssertEqual(m.tile, p(9, 9)); XCTAssertFalse(m.isWalking)
        m.advance(by: 1)
        XCTAssertEqual(m.tile, p(9, 9))
    }

    func testRepeatedSameTileIsIgnored() {
        var m = PlazaRemoteMotion(tile: p(2, 2), facing: .up)
        m.moveTo(p(2, 2))
        XCTAssertFalse(m.isWalking)
    }
}

final class PlazaShelterWandererTests: XCTestCase {
    private let shelter: [TilePoint] = (0..<3).flatMap { y in (0..<4).map { TilePoint(x: 10 + $0, y: 4 + y) } }

    func testWandererStartsAtSameTileOnEveryMac() {
        let a = PlazaShelterWanderer(memberID: "member-abc", shelter: shelter)
        let b = PlazaShelterWanderer(memberID: "member-abc", shelter: shelter)
        XCTAssertEqual(a.tile, b.tile)
        XCTAssertTrue(shelter.contains(a.tile))
        // FNV-1a("a") = 0xE40C292C
        let fixed = PlazaShelterWanderer(memberID: "a", shelter: shelter)
        XCTAssertEqual(fixed.tile, shelter[Int(0xE40C292C % 12)])
    }

    func testWandererStaysInShelter() {
        var w = PlazaShelterWanderer(memberID: "member-abc", shelter: shelter)
        var moves = 0
        for _ in 0..<(60 * 600) {
            let before = w.tile
            if let to = w.advance(by: 1.0 / 60) {
                moves += 1
                XCTAssertEqual(to, w.tile)
                XCTAssertTrue(shelter.contains(to))
                XCTAssertEqual(abs(to.x - before.x) + abs(to.y - before.y), 1)
            }
        }
        XCTAssertTrue((60...150).contains(moves), "moves = \(moves)")
    }

    func testWandererWaitsAtLeastFourSeconds() {
        var w = PlazaShelterWanderer(memberID: "x", shelter: shelter)
        XCTAssertNil(w.advance(by: 3.9))
    }

    func testWandererWithOneShelterTileStays() {
        var w = PlazaShelterWanderer(memberID: "x", shelter: [TilePoint(x: 3, y: 3)])
        for _ in 0..<100 { XCTAssertNil(w.advance(by: 1)) }
        XCTAssertEqual(w.tile, TilePoint(x: 3, y: 3))
    }

    func testWandererSkipsDisconnectedTile() {
        var w = PlazaShelterWanderer(memberID: "x", shelter: [TilePoint(x: 0, y: 0), TilePoint(x: 5, y: 5)])
        for _ in 0..<100 { XCTAssertNil(w.advance(by: 1)) }
    }
}
