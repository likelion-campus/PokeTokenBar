import XCTest
@testable import PokeTokenBar

final class PlazaPathfinderTests: XCTestCase {
    private let map = PlazaMapData.map

    private func follow(_ steps: [PlazaDirection], from start: TilePoint) -> [TilePoint] {
        var at = start
        return steps.map { at = PlazaWalker.offset(at, $0); return at }
    }

    func testAlreadyNextToTheTargetNeedsNoSteps() {
        let s = map.spawn
        XCTAssertEqual(PlazaPathfinder.path(from: s, toNextTo: TilePoint(x: s.x + 1, y: s.y), map: map), [])
    }

    func testShortestWalkablePathEndsBesideTheTarget() throws {
        let start = map.spawn, target = TilePoint(x: map.spawn.x + 6, y: map.spawn.y)
        let steps = try XCTUnwrap(PlazaPathfinder.path(from: start, toNextTo: target, map: map))
        let tiles = follow(steps, from: start)
        XCTAssertTrue(tiles.allSatisfy(map.isWalkable))
        XCTAssertTrue(PlazaPathfinder.isAdjacent(try XCTUnwrap(tiles.last), target))
        XCTAssertEqual(steps.count, 5)
    }

    func testGoesAroundTheSignpost() throws {
        let b = map.boardTile
        let start = TilePoint(x: b.x, y: b.y - 1), target = TilePoint(x: b.x, y: b.y + 2)
        let steps = try XCTUnwrap(PlazaPathfinder.path(from: start, toNextTo: target, map: map))
        let tiles = follow(steps, from: start)
        XCTAssertFalse(tiles.contains(b), "the path never enters the sign")
        XCTAssertTrue(tiles.allSatisfy(map.isWalkable))
        XCTAssertTrue(PlazaPathfinder.isAdjacent(try XCTUnwrap(tiles.last), target))
    }

    func testTargetDeepInTheTreesIsUnreachable() {
        XCTAssertNil(PlazaPathfinder.path(from: map.spawn, toNextTo: TilePoint(x: 0, y: 0), map: map))
    }

    func testFacingDirection() {
        let p = TilePoint(x: 5, y: 5)
        XCTAssertEqual(PlazaPathfinder.direction(from: p, to: TilePoint(x: 6, y: 5)), .right)
        XCTAssertEqual(PlazaPathfinder.direction(from: p, to: TilePoint(x: 4, y: 5)), .left)
        XCTAssertEqual(PlazaPathfinder.direction(from: p, to: TilePoint(x: 5, y: 6)), .down)
        XCTAssertEqual(PlazaPathfinder.direction(from: p, to: TilePoint(x: 5, y: 4)), .up)
    }
}
