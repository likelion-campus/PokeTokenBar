import XCTest
@testable import PokeTokenBar

/// Movement rules around the plaza pond, on the real map: (31,18) is shore, (32,18) water, (30,18) land.
@MainActor
final class PlazaPondMotionTests: XCTestCase {
    private let map = PlazaMapData.map
    private let rightKey: UInt16 = 124
    private let leftKey: UInt16 = 123
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2, nickname: "me")
        s.size = CGSize(width: 800, height: 600)
        return s
    }

    private func member(_ id: String, _ tile: TilePoint) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: tile, facing: .down, isWalking: false)
    }

    private func run(_ s: PlazaScene, _ seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        s.update(t)
        while t < start + seconds - 1e-9 { t += 1.0 / 30; s.update(t) }
    }

    func testArrowKeysNeverEnterTheWater() {
        for shift in [false, true] {
            let s = scene(start: p(31, 18))
            s.currentModifiers = { shift ? .shift : [] }
            s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
            run(s, 1)
            XCTAssertEqual(s.walker.tile, p(31, 18), "shift=\(shift)")
            XCTAssertEqual(s.walker.facing, .right)
            XCTAssertFalse(s.isMeInWater)
        }
    }

    func testPlungeEntersWaterInOneJumpStep() {
        var w = PlazaWalker(tile: p(31, 18))
        let isWater = { [map] (q: TilePoint) in map.isWater(q) }
        let dur: (TilePoint, TilePoint, Bool) -> TimeInterval = { PlazaPond.stepDuration(from: $0, to: $1, running: $2, isWater: isWater) }
        w.press(.left)  // a held key must lose to the plunge
        w.plunge(.right)
        w.advance(by: 0.2, canEnter: { _ in false }, stepDuration: dur)
        XCTAssertEqual(w.tile, p(32, 18))
        XCTAssertTrue(w.isWalking, "still mid-step at 0.2 s")
        XCTAssertEqual(w.facing, .right)
        w.release(.left)
        w.advance(by: 0.17, canEnter: { _ in false }, stepDuration: dur)
        XCTAssertFalse(w.isWalking)
        XCTAssertEqual(w.tile, p(32, 18))
    }

    func testSwimmingStepsTakeAQuarterSecondAndClimbOut() {
        for shift in [false, true] {
            let s = scene(start: p(33, 18))
            s.currentModifiers = { shift ? .shift : [] }
            s.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
            run(s, 0.45)
            s.handleKeyUp(keyCode: rightKey)
            XCTAssertEqual(s.walker.tile, p(35, 18), "two 0.25 s steps by 0.45 s, shift=\(shift)")
            XCTAssertTrue(s.isMeInWater)
        }
        let out = scene(start: p(32, 18))
        out.handleKeyDown(keyCode: leftKey, characters: nil, isRepeat: false)
        out.handleKeyUp(keyCode: leftKey)
        run(out, 0.12)
        XCTAssertEqual(out.walker.tile, p(31, 18))
        XCTAssertTrue(out.walker.isWalking)
        run(out, 0.12, from: 0.12)
        XCTAssertFalse(out.walker.isWalking, "climbing out is a normal 0.15 s step")
        XCTAssertFalse(out.isMeInWater)
    }

    func testOldVersionTeammateOnWaterSwimsAndCannotPushMe() {
        let s = scene(start: p(35, 18))
        s.applyMembers([member("a", p(33, 18))])
        XCTAssertEqual(s.memberTiles["a"], p(33, 18), "not sent to the shelter")
        XCTAssertEqual(s.memberIsInWater("a"), true)
        XCTAssertNil(s.memberIsInWater("nobody"))
        s.pushMe(.left, tiles: 2)
        run(s, 1)
        XCTAssertEqual(s.walker.tile, p(35, 18))
    }

    func testFollowingSomeoneWhoPlungesStopsAtTheShore() {
        let s = scene(start: p(28, 18))
        s.applyMembers([member("a", p(30, 18))])
        XCTAssertTrue(s.follow(member: "a"))
        run(s, 0.5)
        XCTAssertEqual(s.followingMember, "a")
        s.applyMembers([member("a", p(32, 18))])
        run(s, 0.5, from: 0.5)
        XCTAssertNil(s.followingMember)
        XCTAssertFalse(s.isMeInWater)
    }

    func testWalkingToASwimmer() throws {
        let start = p(29, 17), target = p(34, 18)
        XCTAssertTrue(map.isWalkable(start))
        for dx in -2...2 { for dy in -2...2 { XCTAssertFalse(map.isWater(p(start.x + dx, start.y + dy)), "start is away from water") } }
        let edge = try XCTUnwrap(PlazaPond.nearestEdgeWater(to: target, isWater: { self.map.isWater($0) },
                                                            isLand: { self.map.isWalkable($0) }))
        XCTAssertNil(PlazaPathfinder.path(from: start, toNextTo: target, map: map), "no land tile touches the swimmer")
        let route = try XCTUnwrap(PlazaPathfinder.path(from: start, toNextTo: edge, map: map))
        let expected = route.reduce(start) { PlazaWalker.offset($0, $1) }
        XCTAssertEqual(expected, p(34, 16))
        XCTAssertTrue(PlazaPathfinder.isAdjacent(expected, edge))

        let s = scene(start: start)
        s.applyMembers([member("a", target)])
        XCTAssertTrue(s.walk(toMember: "a"))
        run(s, 6)
        XCTAssertEqual(s.walker.tile, expected)
        XCTAssertFalse(s.isMeInWater)
        XCTAssertNil(s.walkingToMember)
        let swimmer = scene(start: p(33, 18))
        swimmer.applyMembers([member("a", p(34, 18))])
        XCTAssertFalse(swimmer.walk(toMember: "a"))
        XCTAssertFalse(swimmer.follow(member: "a"))
    }

    /// The only shore tile next to the swimmer is taken by a teammate: the walk picks another water edge,
    /// not the swimmer's own tile, and ends on a free shore tile.
    func testWalkingToASwimmerWhoseShoreTileIsTaken() {
        let s = scene(start: p(29, 17))
        s.applyMembers([member("a", p(32, 18)), member("b", p(31, 18))])
        XCTAssertTrue(s.walk(toMember: "a"))
        run(s, 8)
        XCTAssertNil(s.walkingToMember)
        XCTAssertFalse(s.isMeInWater)
        let tile = s.walker.tile
        XCTAssertNotEqual(tile, p(31, 18))
        XCTAssertTrue(map.isWalkable(tile))
        XCTAssertTrue(PlazaDirection.allCases.contains { map.isWater(PlazaWalker.offset(tile, $0)) }, "on the shore: \(tile)")
    }
}
