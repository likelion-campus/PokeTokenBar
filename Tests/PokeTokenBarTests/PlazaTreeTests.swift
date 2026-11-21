import XCTest
@testable import PokeTokenBar

/// 큰 나무(PR 5)의 순수 규칙. 지도의 'B' 칸이 나무의 자리다.
@MainActor final class PlazaTreeTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func block(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Set<TilePoint> {
        var out = Set<TilePoint>()
        for y in ys { for x in xs { out.insert(p(x, y)) } }
        return out
    }

    /// 나무 칸('B')을 풀로 되돌린 지도: 나무가 없던 때의 규칙.
    private func oldMap() throws -> PlazaMap {
        try PlazaMap(rows: PlazaMapData.rows.map { $0.replacingOccurrences(of: "B", with: ".") })
    }

    func testTheTreeIsTheBRun() async throws {
        XCTAssertEqual(PlazaTile(rawValue: "B"), .bigTree)
        XCTAssertFalse(PlazaTile.bigTree.isWalkable)
        XCTAssertEqual(PlazaTree.tiles(in: map), block(16...18, 9...10))
        XCTAssertEqual(PlazaTree.artRect(in: map), CGRect(x: 518, y: 256, width: 84, height: 96))
        XCTAssertEqual(PlazaTree.coveredTiles(in: map), block(16...18, 8...10))
        XCTAssertEqual(PlazaTree.z(in: map), 1.34375)
        let bare = try PlazaMap(rows: ["SN..", "...."])
        XCTAssertTrue(PlazaTree.tiles(in: bare).isEmpty)
        XCTAssertNil(PlazaTree.artRect(in: bare))
        XCTAssertTrue(PlazaTree.coveredTiles(in: bare).isEmpty)
        XCTAssertNil(PlazaTree.z(in: bare))
    }

    func testTheTreeAnswersLikeTheGrassItReplaced() async throws {
        let old = try oldMap()
        let trunk = PlazaTree.tiles(in: map)
        XCTAssertEqual(trunk.count, 6)
        for y in -1...32 {
            for x in -1...48 {
                let t = p(x, y)
                let isTree = trunk.contains(t)
                XCTAssertEqual(map.isWalkable(t), isTree ? false : old.isWalkable(t), "walkable \(t)")
                XCTAssertEqual(map.isWater(t), isTree ? false : old.isWater(t), "water \(t)")
                XCTAssertEqual(PlazaSnow.isSnowGround(t, in: map), isTree ? false : PlazaSnow.isSnowGround(t, in: old), "snow \(t)")
                XCTAssertEqual(PlazaSnowball.blocksBall(t, in: map), isTree ? true : PlazaSnowball.blocksBall(t, in: old), "ball \(t)")
                XCTAssertEqual(PlazaDitto.isGround(t, in: map), isTree ? false : PlazaDitto.isGround(t, in: old), "ditto \(t)")
                XCTAssertEqual(PlazaPond.shore(at: t, isWater: { map.isWater($0) }),
                               PlazaPond.shore(at: t, isWater: { old.isWater($0) }), "shore \(t)")
            }
        }
        XCTAssertEqual(map.spawn, old.spawn)
        XCTAssertEqual(map.boardTile, old.boardTile)
        XCTAssertEqual(map.shelterTiles, old.shelterTiles)
        XCTAssertEqual(map.campfireTiles, old.campfireTiles)
        XCTAssertEqual(PlazaItems.spawnCandidates, PlazaItems.candidates(in: PlazaMapData.itemLayoutMap))
        XCTAssertEqual(PlazaItems.openTiles(in: map), PlazaItems.openTiles(in: old).subtracting(PlazaTree.coveredTiles(in: map)))

        let route = try XCTUnwrap(PlazaPathfinder.path(from: p(15, 10), toNextTo: p(19, 10), map: map))
        let oldRoute = PlazaPathfinder.path(from: p(15, 10), toNextTo: p(19, 10), map: old)
        XCTAssertNotNil(oldRoute)
        var at = p(15, 10)
        for d in route {
            at = PlazaWalker.offset(at, d)
            XCTAssertFalse(trunk.contains(at), "the route enters the trunk at \(at)")
        }

        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.tree.lastTile.\(UUID())"))
        prefs.saveLastTile(p(17, 10))
        XCTAssertEqual(prefs.lastTile(validIn: map), map.spawn)
        XCTAssertEqual(prefs.lastTile(validIn: old), p(17, 10))
    }

    func testTheTreeStandsOnPlainGrassReachableFromEverySide() async throws {
        let old = try oldMap()
        let trunk = PlazaTree.tiles(in: map)
        for t in trunk { XCTAssertEqual(old.tile(at: t), .grass, "\(t)") }
        for t in trunk {
            for d in [PlazaDirection.up, .down, .left, .right] {
                let n = PlazaWalker.offset(t, d)
                if !trunk.contains(n) { XCTAssertTrue(map.isWalkable(n), "neighbour \(n) of \(t)") }
            }
        }
        let features: [(String, [TilePoint])] = [
            ("border tree", [p(9, 2), p(16, 2), p(0, 9)]),
            ("bush", [p(15, 4)]), ("shelter", map.shelterTiles), ("board", [map.boardTile]),
            ("tall grass", [p(11, 5)]), ("left pond", [p(13, 13)]), ("hot spring", [p(32, 14)]),
            ("campfire", map.campfireTiles),
        ]
        for (name, tiles) in features {
            for f in tiles {
                for t in trunk { XCTAssertGreaterThanOrEqual(max(abs(f.x - t.x), abs(f.y - t.y)), 3, "\(name) \(f) is too close to \(t)") }
            }
        }
        XCTAssertFalse(PlazaTree.coveredTiles(in: map).contains(map.spawn))
    }
}
