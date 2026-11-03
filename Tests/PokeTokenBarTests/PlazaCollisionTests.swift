import XCTest
@testable import PokeTokenBar

/// Characters do not overlap: a teammate's tile blocks the way, on foot, on the way to a teammate, and for
/// teammates resting in the shelter.
@MainActor
final class PlazaCollisionTests: XCTestCase {
    private let map = PlazaMapData.map
    private let rightKey: UInt16 = 124

    /// Six tiles to the right and one above and below each are open ground outside the shelter.
    private func openSpot() throws -> TilePoint {
        for y in 2..<(map.height - 2) {
            for x in 2..<(map.width - 8) {
                let tiles = (0...6).flatMap { dx in [-1, 0, 1].map { TilePoint(x: x + dx, y: y + $0) } }
                if tiles.allSatisfy({ map.isWalkable($0) && !map.shelterTiles.contains($0) }) { return TilePoint(x: x, y: y) }
            }
        }
        throw XCTSkip("the map has no open spot")
    }

    private func scene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2, nickname: "나")
        s.size = CGSize(width: 800, height: 600)
        return s
    }

    private func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false)
    }

    /// Steps the scene and records every tile I stood on.
    @discardableResult
    private func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) -> [TilePoint] {
        var t = start, visited: [TilePoint] = []
        scene.update(t)
        while t < start + seconds {
            t += 1.0 / 30
            scene.update(t)
            if visited.last != scene.walker.tile { visited.append(scene.walker.tile) }
        }
        return visited
    }

    private func right(_ p: TilePoint, _ n: Int = 1) -> TilePoint { TilePoint(x: p.x + n, y: p.y) }

    func testATeammateBlocksTheTileTheyStandOn() throws {
        let p = try openSpot()
        let s = scene(start: p)
        s.applyMembers([member("a", right(p))])
        s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        step(s, seconds: 1)
        s.handleKeyUp(keyCode: rightKey)
        XCTAssertEqual(s.walker.tile, p, "blocked")
        XCTAssertEqual(s.walker.facing, .right, "turned to face them")
    }

    /// A teammate who is walking blocks the tile they are walking into.
    func testATeammateWalkingInBlocksWhereTheyAreGoing() throws {
        let p = try openSpot()
        let s = scene(start: p)
        s.applyMembers([member("a", right(p, 2))])
        step(s, seconds: 0.1)
        s.applyMembers([member("a", right(p))])
        step(s, seconds: 1.0 / 30, from: 1)
        s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        step(s, seconds: 1, from: 2)
        s.handleKeyUp(keyCode: rightKey)
        XCTAssertEqual(s.walker.tile, p)
    }

    /// When we start on the same tile (everyone opens the plaza at the same spot), I can still step off it.
    func testICanStepOffATileIShare() throws {
        let p = try openSpot()
        let s = scene(start: p)
        s.applyMembers([member("a", p)])
        s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        s.handleKeyUp(keyCode: rightKey)
        step(s, seconds: 1)
        XCTAssertEqual(s.walker.tile, right(p))
    }

    /// Walking to a teammate from the roster goes around another teammate standing on the straight way.
    func testWalkingToATeammateGoesAroundAnotherOne() throws {
        let p = try openSpot()
        let s = scene(start: p)
        s.applyMembers([member("target", right(p, 4)), member("blocker", right(p))])
        XCTAssertTrue(s.walk(toMember: "target"))
        let visited = step(s, seconds: 4)
        XCTAssertFalse(visited.contains(right(p)), "never on the blocker's tile: \(visited)")
        XCTAssertEqual(abs(s.walker.tile.x - right(p, 4).x) + abs(s.walker.tile.y - p.y), 1, "ends beside the target")
        XCTAssertNil(s.walkingToMember)
    }

    /// Without a way through, the walk stops instead of pushing into a teammate.
    func testWalkingToAWalledInTeammateStops() throws {
        let p = try openSpot()
        let target = right(p, 3)
        let s = scene(start: p)
        let wall = [PlazaDirection.up, .down, .left, .right].map { PlazaWalker.offset(target, $0) }
        s.applyMembers([member("target", target)] + wall.enumerated().map { member("w\($0.offset)", $0.element) })
        XCTAssertTrue(s.walk(toMember: "target"))
        step(s, seconds: 2)
        XCTAssertNil(s.walkingToMember)
        XCTAssertFalse(wall.contains(s.walker.tile) || s.walker.tile == target)
    }

    /// A teammate resting in the shelter never wanders onto a blocked tile, and stays put when every way is blocked.
    func testShelterWandererAvoidsBlockedTiles() {
        let shelter = map.shelterTiles
        var free = PlazaShelterWanderer(memberID: "m", shelter: shelter)
        var blockedOnce = PlazaShelterWanderer(memberID: "m", shelter: shelter)
        let start = free.tile
        let neighbours = Set([PlazaDirection.up, .down, .left, .right].map { PlazaWalker.offset(start, $0) })
        XCTAssertNil(blockedOnce.advance(by: 60, blocked: neighbours), "every way is blocked: it stays")
        XCTAssertEqual(blockedOnce.tile, start)
        var landed: Set<TilePoint> = []
        let me = neighbours.first { shelter.contains($0) }!
        // One second at a time is shorter than any wait, so every move is reported.
        for _ in 0..<2000 {
            if let t = free.advance(by: 1, blocked: [me]) { landed.insert(t) }
        }
        XCTAssertFalse(landed.isEmpty, "it still wanders")
        XCTAssertFalse(landed.contains(me))
    }
}
