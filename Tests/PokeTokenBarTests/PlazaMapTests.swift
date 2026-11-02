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
        let below = TilePoint(x: map.boardTile.x, y: map.boardTile.y + 2)
        XCTAssertTrue(map.isWalkable(below), "소식판은 아래 칸에서 위를 보고 말을 건다(2부)")
    }

    func testBorderIsThreeTilesOfTrees() {
        for y in 0..<map.height {
            for x in 0..<map.width where x < 3 || y < 3 || x >= map.width - 3 || y >= map.height - 3 {
                XCTAssertEqual(map.tile(at: .init(x: x, y: y)), .tree, "(\(x),\(y))")
            }
        }
    }

    func testOnlySimpleKinds() {
        var counts: [Character: Int] = [:]
        for ch in PlazaMapData.rows.joined() { counts[ch, default: 0] += 1 }
        XCTAssertTrue(Set(counts.keys).isSubset(of: [".", "f", "S", "T", "b", "N"]))
        XCTAssertTrue((30...50).contains(counts["f", default: 0]), "flowers \(counts["f", default: 0])")
        XCTAssertTrue((6...10).contains(counts["b", default: 0]), "bushes \(counts["b", default: 0])")
    }

    func testBushesDoNotTouch() {
        var bushes: [TilePoint] = []
        for y in 0..<map.height { for x in 0..<map.width where map.tile(at: .init(x: x, y: y)) == .bush { bushes.append(.init(x: x, y: y)) } }
        for a in bushes { for b in bushes where a != b {
            XCTAssertGreaterThan(max(abs(a.x - b.x), abs(a.y - b.y)), 1, "\(a) \(b)")
        } }
    }

    /// The board is one big 2x2 signpost, readable from every side.
    func testBoardIsOneTwoByTwoSign() {
        var boards: [TilePoint] = []
        for y in 0..<map.height { for x in 0..<map.width where map.tile(at: .init(x: x, y: y)) == .board { boards.append(.init(x: x, y: y)) } }
        let b = map.boardTile
        XCTAssertEqual(Set(boards), [b, .init(x: b.x + 1, y: b.y), .init(x: b.x, y: b.y + 1), .init(x: b.x + 1, y: b.y + 1)])
        for d in 0...1 {
            XCTAssertTrue(map.isWalkable(.init(x: b.x + d, y: b.y - 1)))
            XCTAssertTrue(map.isWalkable(.init(x: b.x + d, y: b.y + 2)))
            XCTAssertTrue(map.isWalkable(.init(x: b.x - 1, y: b.y + d)))
            XCTAssertTrue(map.isWalkable(.init(x: b.x + 2, y: b.y + d)))
        }
    }

    /// Someone standing on an away member's tile faces down by default. No shelter tile may face the board
    /// downwards, or the board would win and the member couldn't be talked to there.
    func testNoShelterTileFacesTheBoardDownwards() {
        for p in map.shelterTiles {
            XCTAssertNotEqual(map.tile(at: .init(x: p.x, y: p.y + 1)), .board, "\(p)")
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
