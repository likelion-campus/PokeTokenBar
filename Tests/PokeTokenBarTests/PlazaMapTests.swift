import XCTest
@testable import PokeTokenBar

final class PlazaMapTests: XCTestCase {
    let map = PlazaMapData.map

    func testSizeIs48By32() {
        XCTAssertEqual(map.width, 48); XCTAssertEqual(map.height, 32)
        XCTAssertEqual(map.pixelSize, CGSize(width: 48 * 32, height: 32 * 32))
    }

    func testBorderIsNotWalkable() {
        for x in 0..<map.width { XCTAssertFalse(map.isWalkable(.init(x: x, y: 0))); XCTAssertFalse(map.isWalkable(.init(x: x, y: map.height - 1))) }
        for y in 0..<map.height { XCTAssertFalse(map.isWalkable(.init(x: 0, y: y))); XCTAssertFalse(map.isWalkable(.init(x: map.width - 1, y: y))) }
    }

    func testEveryWalkableTileIsReachableFromSpawn() {
        var seen: Set<TilePoint> = [map.spawn]
        var queue = [map.spawn]
        while let p = queue.popLast() {
            for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let n = TilePoint(x: p.x + d.0, y: p.y + d.1)
                if map.isWalkable(n), seen.insert(n).inserted { queue.append(n) }
            }
        }
        var walkable = 0
        for y in 0..<map.height { for x in 0..<map.width where map.isWalkable(.init(x: x, y: y)) { walkable += 1 } }
        XCTAssertEqual(seen.count, walkable)
    }

    func testShelterBoardAndSpawn() {
        XCTAssertGreaterThanOrEqual(map.shelterTiles.count, 12)
        XCTAssertEqual(map.tile(at: map.spawn), .shelter)
        let below = TilePoint(x: map.boardTile.x, y: map.boardTile.y + 1)
        XCTAssertTrue(map.isWalkable(below), "소식판은 아래 칸에서 위를 보고 말을 건다(2부)")
    }

    func testHasEachArea() {
        let all = PlazaMapData.rows.joined()
        for ch: Character in ["W", "f", ",", "P"] {
            XCTAssertTrue(all.contains(ch), "missing area \(ch)")
        }
    }

    func testRejectsBadRows() {
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TT"]))
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TXT", "TTT"]))
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TST", "TTT"]))   // 소식판 없음
    }

    func testOutsideIsTree() {
        XCTAssertEqual(map.tile(at: .init(x: -1, y: 5)), .tree)
        XCTAssertFalse(map.isWalkable(.init(x: map.width, y: 5)))
    }
}
