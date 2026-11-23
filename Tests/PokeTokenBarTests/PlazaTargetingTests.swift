import XCTest
@testable import PokeTokenBar

final class PlazaTargetingTests: XCTestCase {
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testFacingTileIsNextToMe() {
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .up), p(5, 4))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .down), p(5, 6))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .left), p(4, 5))
        XCTAssertEqual(PlazaTargeting.facingTile(from: p(5, 5), facing: .right), p(6, 5))
    }

    func testTargetPrefersFacingTile() {
        let members = ["b": p(6, 5), "a": p(5, 5), "c": p(6, 5)]
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: members), "b")
    }

    func testTargetFallsBackToSameTile() {
        let members = ["z": p(5, 5), "y": p(5, 5), "far": p(9, 9)]
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: members), "y")
    }

    func testTargetFallsBackToTilesBesideMe() {
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["n": p(5, 4)]), "n")
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["w": p(4, 5), "s": p(5, 6)]), "s",
                       "up, down, left, right order")
        XCTAssertEqual(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["n": p(5, 4), "e": p(6, 5)]), "e",
                       "the facing tile still comes first")
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["d": p(6, 6)]), "diagonal is not beside")
    }

    func testTargetIsNilWhenNobodyNear() {
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: ["far": p(9, 9)]))
        XCTAssertNil(PlazaTargeting.member(from: p(5, 5), facing: .right, members: [:]))
    }

    func testSpaceReachesTheCampfireLikeTheBoard() {
        let map = PlazaMapData.map
        XCTAssertEqual(PlazaInteraction.target(from: p(23, 14), facing: .down, map: map, members: [:]),
                       PlazaInteractionHit(target: .campfire, facing: .down))
        XCTAssertEqual(PlazaInteraction.target(from: p(22, 15), facing: .up, map: map, members: [:]),
                       PlazaInteractionHit(target: .campfire, facing: .right))
        XCTAssertEqual(PlazaInteraction.target(from: p(22, 15), facing: .up, map: map, members: ["m": p(22, 14)]),
                       PlazaInteractionHit(target: .member("m"), facing: .up), "a member on the faced tile beats a side pit")
    }

    // MARK: - Body size (PR 2)

    private func body(_ x: Int, _ y: Int, _ c: Int) -> PlazaBody { PlazaBody(foot: p(x, y), size: c) }

    /// A random layout: me on a walkable tile, a facing, and 0...5 members (IDs a...f) within ±2 of me.
    private func layout(_ rng: inout PlazaSplitMix64, classes: ClosedRange<Int>) -> (me: TilePoint, facing: PlazaDirection, members: [String: PlazaBody]) {
        let map = PlazaMapData.map
        func r(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        var me = p(r(map.width), r(map.height))
        while !map.isWalkable(me) { me = p(r(map.width), r(map.height)) }
        let facing = [PlazaDirection.up, .down, .left, .right][r(4)]
        var members: [String: PlazaBody] = [:]
        for id in ["a", "b", "c", "d", "e", "f"].prefix(r(6)) {
            members[id] = PlazaBody(foot: p(me.x + r(5) - 2, me.y + r(5) - 2), size: classes.lowerBound + r(classes.count))
        }
        return (me, facing, members)
    }

    func testEveryTileRuleIsUnchangedWhenEveryoneIsClassOne() {
        var rng = PlazaSplitMix64(seed: 0x2B0D)
        let map = PlazaMapData.map
        var foundMembers = 0, memberHits = 0, touchingPairs = 0
        for _ in 0..<20_000 {
            let l = layout(&rng, classes: 1...1)
            let tiles = l.members.mapValues(\.foot)
            let me = PlazaBody(foot: l.me, size: 1)
            let found = PlazaTargeting.member(me: me, facing: l.facing, members: l.members)
            XCTAssertEqual(found, LegacyPlazaTargeting.member(from: l.me, facing: l.facing, members: tiles))
            if found != nil { foundMembers += 1 }
            let hit = PlazaInteraction.target(me: me, facing: l.facing, map: map, members: l.members)
            // The fortune stall is a target the old rule never had; everything else is unchanged.
            if hit?.target != .stall { XCTAssertEqual(hit, LegacyPlazaInteraction.target(from: l.me, facing: l.facing, map: map, members: tiles)) }
            if case .member? = hit?.target { memberHits += 1 }
            let other = p(l.me.x + Int(rng.next() % 7) - 3, l.me.y + Int(rng.next() % 7) - 3)
            for fallback in [PlazaDirection.up, .down, .left, .right] {
                let o = PlazaBody(foot: other, size: 1)
                if me.touches(o) { touchingPairs += 1 }
                XCTAssertEqual(me.touches(o), LegacyPlazaTackle.pushes(from: l.me, to: other))
                XCTAssertEqual(me.touches(o) ? PlazaTargeting.turn(from: l.me, to: other, facing: fallback) : fallback,
                               LegacyPlazaTackle.direction(from: l.me, to: other, fallback: fallback))
            }
        }
        // The comparison must not go vacuous: layouts really find people, hit members and touch.
        XCTAssertGreaterThan(foundMembers, 3000)
        XCTAssertGreaterThan(memberHits, 3000)
        XCTAssertGreaterThan(touchingPairs, 3000)
    }

    func testTheFoundMemberAlwaysTouchesMe() {
        var rng = PlazaSplitMix64(seed: 0x70C4)
        var found = 0
        for _ in 0..<20_000 {
            let l = layout(&rng, classes: 1...3)
            let me = PlazaBody(foot: l.me, size: Int(rng.next() % 3) + 1)
            if let id = PlazaTargeting.member(me: me, facing: l.facing, members: l.members) {
                found += 1
                XCTAssertTrue(me.touches(l.members[id]!), "\(id)")
            }
        }
        XCTAssertGreaterThan(found, 1000, "the layouts must actually find people")
    }

    func testABigMemberCoveringOnlyTheFacedTileIsFound() {
        let members = ["a": body(7, 6, 2), "b": body(5, 4, 1)]
        XCTAssertEqual(PlazaTargeting.member(me: body(5, 5, 1), facing: .right, members: members), "a")
        XCTAssertEqual(PlazaTargeting.turn(from: p(5, 5), to: p(7, 6), facing: .right), .right)
    }

    func testABigMemberCoveringMyTileComesBeforeASide() {
        let members = ["a": body(5, 7, 3), "b": body(4, 5, 1)]
        XCTAssertEqual(PlazaTargeting.member(me: body(5, 5, 1), facing: .up, members: members), "a")
        XCTAssertEqual(PlazaTargeting.turn(from: p(5, 5), to: p(5, 7), facing: .up), .down)
    }

    func testABigMemberCoveringOnlyASideIsFound() {
        let members = ["a": body(3, 6, 2)]
        XCTAssertEqual(PlazaTargeting.member(me: body(5, 5, 1), facing: .up, members: members), "a")
        XCTAssertEqual(PlazaTargeting.turn(from: p(5, 5), to: p(3, 6), facing: .up), .left)
    }

    func testOnlyTouchingFindsTheNearestFootThenTheSmallerID() {
        let members = ["z": body(5, 2, 1), "m": body(3, 4, 1), "a": body(7, 3, 1)]
        let me = body(5, 5, 3)
        XCTAssertEqual(PlazaTargeting.member(me: me, facing: .down, members: members), "m")
        XCTAssertEqual(PlazaTargeting.turn(from: p(5, 5), to: p(3, 4), facing: .down), .left)
        XCTAssertNil(PlazaTargeting.member(me: body(5, 5, 1), facing: .down, members: members))
    }

    func testAFacedMemberBeatsOneThatOnlyTouches() {
        let members = ["z": body(5, 4, 1), "a": body(5, 2, 1)]
        XCTAssertEqual(PlazaTargeting.member(me: body(5, 5, 3), facing: .up, members: members), "z")
    }

    func testBigBodiesReachDiagonallyAndTwoTilesOut() {
        let me = body(5, 5, 1)
        XCTAssertEqual(PlazaTargeting.member(me: me, facing: .up, members: ["d": body(6, 6, 2)]), "d")
        XCTAssertNil(PlazaTargeting.member(me: me, facing: .up, members: ["d": body(6, 6, 1)]))
        XCTAssertEqual(PlazaTargeting.member(me: me, facing: .up, members: ["t": body(5, 8, 3)]), "t")
        XCTAssertNil(PlazaTargeting.member(me: me, facing: .up, members: ["t": body(5, 9, 3)]))
    }

    func testTurningFacesAnAdjacentFootElseTheLongerAxisElseStays() {
        let from = p(5, 5)
        XCTAssertEqual(PlazaTargeting.turn(from: from, to: p(6, 5), facing: .up), .right)
        XCTAssertEqual(PlazaTargeting.turn(from: from, to: p(5, 2), facing: .left), .up)
        XCTAssertEqual(PlazaTargeting.turn(from: from, to: p(7, 6), facing: .up), .right)
        XCTAssertEqual(PlazaTargeting.turn(from: from, to: from, facing: .up), .up)
    }

    /// 대각선(차이가 같음): `facing` 이 상대 쪽이면 그대로, 반대쪽이면 같은 축에서 상대 쪽으로 돈다.
    func testADiagonalKeepsAFacingTowardThemAndTurnsAFacingAway() {
        let from = p(5, 5)
        for (to, toward) in [(p(6, 6), (PlazaDirection.right, PlazaDirection.down)), (p(4, 6), (.left, .down)),
                             (p(6, 4), (.right, .up)), (p(4, 4), (.left, .up))] {
            XCTAssertEqual(PlazaTargeting.turn(from: from, to: to, facing: toward.0), toward.0)
            XCTAssertEqual(PlazaTargeting.turn(from: from, to: to, facing: toward.1), toward.1)
            let opposite0: PlazaDirection = toward.0 == .right ? .left : .right
            let opposite1: PlazaDirection = toward.1 == .down ? .up : .down
            XCTAssertEqual(PlazaTargeting.turn(from: from, to: to, facing: opposite0), toward.0, "\(to) \(opposite0)")
            XCTAssertEqual(PlazaTargeting.turn(from: from, to: to, facing: opposite1), toward.1, "\(to) \(opposite1)")
        }
    }

    func testTheBoardStillComesFirst() {
        let map = PlazaMapData.map
        let b = map.boardTile
        let left = p(b.x - 1, b.y + 1)
        let side = PlazaInteraction.target(me: PlazaBody(foot: left, size: 1), facing: .down, map: map,
                                           members: ["m": body(left.x - 2, left.y + 1, 2)])
        XCTAssertEqual(side, PlazaInteractionHit(target: .board, facing: .right))
        let faced = PlazaInteraction.target(me: PlazaBody(foot: left, size: 1), facing: .down, map: map,
                                            members: ["m": body(left.x + 1, left.y + 3, 3)])
        XCTAssertEqual(faced, PlazaInteractionHit(target: .member("m"), facing: .down))
    }

    // MARK: - Final review fixes

    /// Real map: the board's right-hand shelter tile (22,5) has the board at (23,5) on my right. A class-2 teammate directly
    /// below me covers my tile with its body, but the board still comes first when nobody is faced (TEAM.md, spec 6.3).
    func testABigBodyBelowMeDoesNotTakeSpaceFromTheBoard() {
        let map = PlazaMapData.map
        XCTAssertEqual(map.tile(at: p(23, 5)), .board, "test precondition")
        let me = body(22, 5, 1)
        let hit = PlazaInteraction.target(me: me, facing: .up, map: map, members: ["m": body(22, 6, 2)])
        XCTAssertEqual(hit, PlazaInteractionHit(target: .board, facing: .right))
        // Faced, a class-2 body still wins over a side board: it covers the faced tile (22,4).
        XCTAssertEqual(PlazaInteraction.target(me: me, facing: .up, map: map, members: ["m": body(22, 4, 2)])?.target, .member("m"))
        // A foot on my own tile is still a member before a side board, as before this PR.
        XCTAssertEqual(PlazaInteraction.target(me: me, facing: .up, map: map, members: ["m": body(22, 5, 1)])?.target, .member("m"))
    }

    func testABigBodyBesideMeDoesNotTakeSpaceFromTheCampfire() {
        let map = PlazaMapData.map
        XCTAssertEqual(map.tile(at: p(23, 15)), .campfire, "test precondition")
        let me = body(23, 14, 1)
        // The class-2 member at (24,14) covers (23,14), my tile, but not the faced tile (22,14); the campfire is on my side (below).
        let hit = PlazaInteraction.target(me: me, facing: .left, map: map, members: ["m": body(24, 14, 2)])
        XCTAssertEqual(hit, PlazaInteractionHit(target: .campfire, facing: .down))
    }

    /// The body that covers my tile and is not faced is still found, after the board and campfire.
    func testABodyCoveringMyTileIsFoundAfterTheSideObjects() {
        let members = ["m": body(24, 14, 2)]
        XCTAssertEqual(PlazaTargeting.member(me: body(23, 14, 1), facing: .left, members: members), "m")
        XCTAssertNil(PlazaTargeting.memberAhead(me: body(23, 14, 1), facing: .left, members: members), "not ahead: it only covers my tile")
        XCTAssertEqual(PlazaTargeting.memberAround(me: body(23, 14, 1), facing: .left, members: members), "m")
    }

    /// A small teammate in front is not hidden by a big one behind it with a smaller ID.
    func testASmallTeammateInFrontIsNotHiddenByABigOneBehind() {
        let members = ["s": body(11, 10, 1), "b": body(12, 10, 3)]
        XCTAssertEqual(PlazaTargeting.member(me: body(10, 10, 1), facing: .right, members: members), "s", "faced")
        XCTAssertEqual(PlazaTargeting.member(me: body(10, 10, 1), facing: .up, members: members), "s", "beside me, whatever I face")
        XCTAssertEqual(PlazaTargeting.member(me: body(10, 10, 1), facing: .down, members: members), "s")
        XCTAssertEqual(PlazaTargeting.member(me: body(11, 9, 1), facing: .down, members: members), "s", "from above")
        XCTAssertEqual(PlazaTargeting.member(me: body(11, 11, 1), facing: .up, members: members), "s", "from below")
        XCTAssertEqual(PlazaInteraction.target(me: body(10, 10, 1), facing: .right, map: PlazaMapData.map, members: members)?.target, .member("s"))
        // Two class-1 feet on one tile still fall back to the smaller ID.
        XCTAssertEqual(PlazaTargeting.member(me: body(10, 10, 1), facing: .right, members: ["y": body(11, 10, 1), "x": body(11, 10, 1)]), "x")
        // Equal distance, different feet: the smaller ID.
        XCTAssertEqual(PlazaTargeting.member(me: body(10, 10, 1), facing: .right, members: ["q": body(12, 10, 3), "p": body(11, 11, 3)]), "p")
    }
}
