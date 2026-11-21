import XCTest
@testable import PokeTokenBar

final class PlazaSnowballTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    func testAimHitsTheFirstTargetAhead() async {
        let a = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(14, 12), "b": p(12, 12)], map: map)
        XCTAssertEqual(a?.end, .actor(id: "b", tile: p(12, 12)))
        XCTAssertEqual(a?.frames, 2)
        let b = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(21, 12)], map: map)
        XCTAssertEqual(b?.end, .ground(p(20, 12)))
        XCTAssertEqual(b?.frames, 10)
        let c = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["x": p(10, 12)], map: map)
        XCTAssertEqual(c?.end, .ground(p(20, 12)))
        let edge = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(20, 12)], map: map)
        XCTAssertEqual(edge?.end, .actor(id: "a", tile: p(20, 12)))
        XCTAssertEqual(edge?.frames, 10)
        let past = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["a": p(21, 12)], map: map)
        XCTAssertEqual(past?.end, .ground(p(20, 12)))   // eleven tiles away is out of range
        let d = PlazaSnowball.aim(from: p(10, 12), facing: .right, targets: ["b": p(12, 12), "a": p(12, 12)], map: map)
        XCTAssertEqual(d?.end, .actor(id: "a", tile: p(12, 12)))
    }

    func testAimStopsBeforeObstaclesAndFliesOverWater() async {
        let a = PlazaSnowball.aim(from: p(12, 17), facing: .right, targets: ["m": p(16, 17)], map: map)
        XCTAssertEqual(a?.end, .ground(p(14, 17)))
        let b = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: [:], map: map)
        XCTAssertEqual(b?.end, .ground(p(7, 14)))
        let c = PlazaSnowball.aim(from: p(17, 14), facing: .left, targets: ["s": p(13, 14)], map: map)
        XCTAssertEqual(c?.end, .actor(id: "s", tile: p(13, 14)))
    }

    func testVerticalThrowsAimAlongTheColumn() async {
        // Column 10: grass at row 11-12, pond rows 13-15, grass again at row 16.
        let down = PlazaSnowball.aim(from: p(10, 11), facing: .down, targets: [:], map: map)
        XCTAssertEqual(down?.end, .ground(p(10, 21)))   // over the pond, ten tiles on
        XCTAssertEqual(down?.frames, 10)
        let swimmer = PlazaSnowball.aim(from: p(10, 11), facing: .down, targets: ["s": p(10, 14), "t": p(10, 15)], map: map)
        XCTAssertEqual(swimmer?.end, .actor(id: "s", tile: p(10, 14)))
        XCTAssertEqual(swimmer?.frames, 3)
        let up = PlazaSnowball.aim(from: p(10, 16), facing: .up, targets: [:], map: map)
        XCTAssertEqual(up?.end, .ground(p(10, 6)))
        let target = PlazaSnowball.aim(from: p(10, 16), facing: .up, targets: ["a": p(10, 13)], map: map)
        XCTAssertEqual(target?.end, .actor(id: "a", tile: p(10, 13)))
        XCTAssertNil(PlazaSnowball.aim(from: p(10, 3), facing: .up, targets: [:], map: map))   // the tree line above
        XCTAssertNil(PlazaSnowball.aim(from: p(15, 16), facing: .down, targets: [:], map: map)) // the bush at (15,17)
    }

    func testFacingAnObstacleOrTheEdgeThrowsNothing() async {
        XCTAssertNil(PlazaSnowball.aim(from: p(3, 12), facing: .left, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(44, 12), facing: .right, targets: [:], map: map))
        XCTAssertNil(PlazaSnowball.aim(from: p(14, 17), facing: .right, targets: [:], map: map))
    }

    func testHitsNeedTheSameLineTheRightWayWithinEleven() async {
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 12), target: p(14, 12), direction: .left))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(3, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(2, 12), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(10, 11), target: p(14, 12), direction: .right))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(14, 12), target: p(14, 12), direction: .right))
    }

    func testVerticalHitsNeedTheSameColumnTheRightWayWithinEleven() async {
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 9), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 1), direction: .down))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 16), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(5, 17), direction: .down))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 5), target: p(6, 9), direction: .down))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 8), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 15), direction: .up))
        XCTAssertTrue(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 1), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(5, 0), direction: .up))
        XCTAssertFalse(PlazaSnowball.hits(thrower: p(5, 12), target: p(4, 8), direction: .up))
    }

    func testFramesAreTheTileCountFromOneToTen() async {
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .down, end: .actor(id: nil, tile: p(0, 10))).frames, 10)
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .down, end: .actor(id: nil, tile: p(0, 14))).frames, 10)
        XCTAssertEqual(PlazaSnowballShot(from: p(0, 0), direction: .right, end: .ground(p(1, 0))).frames, 1)
    }

    func testTheArcStartsAtTheHandPeaksAndEndsOnTheBodyOrTheGround() async {
        XCTAssertEqual(PlazaSnowball.height(at: 0, endHeight: 24), 14)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 24), 24)
        XCTAssertEqual(PlazaSnowball.height(at: 1, endHeight: 0), 0)
        XCTAssertEqual(PlazaSnowball.height(at: 0.5, endHeight: 0), 23)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 0), 14)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 30), 15)
        XCTAssertEqual(PlazaSnowball.bodyHeight(spriteHeight: 80), 24)
    }

    func testBurstPiecesSpreadToThirtyTwoAndStayUpOnAMiss() async {
        let radius: [CGFloat] = [18, 22, 28, 32], drop: [CGFloat] = [0, 2, 8, 16], glyphs = [1, 0, 1, 2]
        for step in 0..<4 {
            let ground = PlazaSnowball.burstPieces(step: step, onGround: true)
            let air = PlazaSnowball.burstPieces(step: step, onGround: false)
            XCTAssertEqual(ground.count, step == 0 ? 5 : 5)
            XCTAssertEqual(air.count, step == 0 ? 5 : 6)
            if step == 0 {
                for set in [ground, air] {
                    XCTAssertTrue(set.contains { $0.offset == CGVector(dx: 0, dy: 0) && $0.glyph == 0 })
                }
            }
            for piece in air where !(step == 0 && piece.offset == .zero) {
                XCTAssertEqual(piece.glyph, glyphs[step])
                XCTAssertEqual(hypot(piece.offset.dx, piece.offset.dy + drop[step]), radius[step], accuracy: 1e-9)
                XCTAssertLessThanOrEqual(radius[step], 32)
            }
            for piece in ground {
                XCTAssertLessThanOrEqual(abs(piece.offset.dx), 32)
                XCTAssertGreaterThanOrEqual(piece.offset.dy, 0)
            }
        }
    }

    func testShadedGridsAddTheShadeRightAndBelow() async {
        XCTAssertEqual(PlazaSnowballArt.shaded([".W.", "WWW", ".W."]), [".Wo.", "WWWo", "oWo.", ".o.."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["WW", "WS"]), ["WWo", "WSo", "oo."])
        XCTAssertEqual(PlazaSnowballArt.shaded(["W"]), ["Wo", "o."])
    }

    // MARK: - Body size (PR 2)

    private func body(_ x: Int, _ y: Int, _ c: Int) -> PlazaBody { PlazaBody(foot: p(x, y), size: c) }

    func testEveryThrowIsUnchangedWhenEveryoneIsClassOne() {
        var rng = PlazaSplitMix64(seed: 0x5B0A)
        func r(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        let dirs: [PlazaDirection] = [.up, .down, .left, .right]
        for _ in 0..<20_000 {
            var from = p(r(map.width), r(map.height))
            while !map.isWalkable(from) { from = p(r(map.width), r(map.height)) }
            let facing = dirs[r(4)]
            var targets: [String: TilePoint] = [:]
            for id in ["a", "b", "c", "d", "e"].prefix(r(5)) {
                let ahead = r(13), off = r(3) - 1
                var t = from
                for _ in 0..<ahead { t = PlazaWalker.offset(t, facing) }
                switch facing { case .left, .right: t.y += off; case .up, .down: t.x += off }
                targets[id] = t
            }
            XCTAssertEqual(PlazaSnowball.aim(from: from, facing: facing, bodies: PlazaBody.ones(targets), map: map),
                           LegacyPlazaSnowball.aim(from: from, facing: facing, targets: targets, map: map))
            let thrower = p(20 + r(27) - 13, 20 + r(27) - 13), target = p(20 + r(27) - 13, 20 + r(27) - 13)
            for d in dirs {
                let hit = PlazaSnowball.hitTile(thrower: thrower, target: PlazaBody(foot: target, size: 1), direction: d)
                XCTAssertEqual(hit != nil, LegacyPlazaSnowball.hits(thrower: thrower, target: target, direction: d))
                if let hit { XCTAssertEqual(hit, target) }
            }
            // The same row/column as the target: the interesting case the random pair rarely lands on.
            let inLine = p(target.x - 5, target.y)
            XCTAssertEqual(PlazaSnowball.hitTile(thrower: inLine, target: PlazaBody(foot: target, size: 1), direction: .right) != nil,
                           LegacyPlazaSnowball.hits(thrower: inLine, target: target, direction: .right))
        }
    }

    func testABigBodyOneRowOffTheLineIsHitAndASmallOneIsMissed() {
        let from = p(10, 12)
        let g3 = PlazaSnowball.aim(from: from, facing: .right, bodies: ["g": body(16, 13, 3)], map: map)
        XCTAssertEqual(g3?.end, .actor(id: "g", tile: p(15, 12)))
        XCTAssertEqual(g3?.frames, 5)
        XCTAssertEqual(PlazaSnowball.aim(from: from, facing: .right, bodies: ["g": body(16, 13, 2)], map: map)?.end, .actor(id: "g", tile: p(15, 12)))
        XCTAssertEqual(PlazaSnowball.aim(from: from, facing: .right, bodies: ["g": body(16, 11, 2)], map: map)?.end, .ground(p(20, 12)),
                       "the line runs below its foot")
        XCTAssertEqual(PlazaSnowball.aim(from: from, facing: .right, bodies: ["g": body(16, 13, 1)], map: map)?.end, .ground(p(20, 12)))
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: from, target: body(16, 13, 3), direction: .right), p(15, 12))
        XCTAssertNil(PlazaSnowball.hitTile(thrower: from, target: body(16, 13, 1), direction: .right))
    }

    func testAColumnThrowHitsABigBodyBesideTheColumn() {
        let from = p(10, 16)
        let shot = PlazaSnowball.aim(from: from, facing: .up, bodies: ["g": body(11, 9, 3)], map: map)
        XCTAssertEqual(shot?.end, .actor(id: "g", tile: p(10, 9)))
        XCTAssertEqual(shot?.frames, 7)
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: from, target: body(11, 9, 3), direction: .up), p(10, 9))
        XCTAssertEqual(PlazaSnowball.aim(from: from, facing: .up, bodies: ["g": body(11, 9, 1)], map: map)?.end, .ground(p(10, 6)))
    }

    func testTheReceiverFindsTheNearestBodyColumnWithinEleven() {
        let g = body(16, 13, 3)
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: p(4, 12), target: g, direction: .right), p(15, 12))
        XCTAssertNil(PlazaSnowball.hitTile(thrower: p(3, 12), target: g, direction: .right))
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: p(16, 12), target: g, direction: .right), p(17, 12))
        XCTAssertEqual(PlazaSnowball.aim(from: p(16, 12), facing: .right, bodies: ["g": g], map: map)?.end, .actor(id: "g", tile: p(17, 12)))
    }

    func testTheReceiverAgreesWithTheThrowersAim() throws {
        let open = try PlazaMap(rows: ["NS" + String(repeating: ".", count: 38)] + Array(repeating: String(repeating: ".", count: 40), count: 29))
        var rng = PlazaSplitMix64(seed: 0xA61E)
        func r(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        let dirs: [PlazaDirection] = [.up, .down, .left, .right]
        var hits = 0
        for _ in 0..<10_000 {
            let from = p(14 + r(12), 12 + r(6))
            let facing = dirs[r(4)]
            let target = PlazaBody(foot: p(from.x + r(25) - 12, from.y + r(25) - 12), size: r(3) + 1)
            let shot = PlazaSnowball.aim(from: from, facing: facing, bodies: ["t": target], map: open)
            let entry = PlazaSnowball.hitTile(thrower: from, target: target, direction: facing)
            if case .actor(_, let tile)? = shot?.end {
                hits += 1
                XCTAssertEqual(entry, tile)
            }
            if let entry, abs(entry.x - from.x) + abs(entry.y - from.y) <= PlazaSnowball.range {
                XCTAssertEqual(shot?.end, .actor(id: "t", tile: entry))
            }
        }
        XCTAssertGreaterThan(hits, 200, "the layouts must actually hit")
    }

    // MARK: - Sender/receiver agreement at the edges (review fixes)

    /// 40x30 open ground (board (0,0), shelter (1,0)), with `blocked` tiles turned into trees.
    private func openMap(trees blocked: [TilePoint] = []) throws -> PlazaMap {
        var rows = ["NS" + String(repeating: ".", count: 38)] + Array(repeating: String(repeating: ".", count: 40), count: 29)
        for t in blocked {
            var row = Array(rows[t.y]); row[t.x] = "T"; rows[t.y] = String(row)
        }
        return try PlazaMap(rows: rows)
    }

    func testABlockedTileJustBeforeABigBodyStopsTheBallAndHitsNobody() throws {
        let tree = try openMap(trees: [p(10, 12)])
        let big = body(12, 13, 3)   // covers x 11-13, y 11-13: (11,12) is its first tile on the line
        let stopped = PlazaSnowball.aim(from: p(5, 12), facing: .right, bodies: ["g": big], map: tree)
        XCTAssertEqual(stopped?.end, .ground(p(9, 12)), "the ball stops before the tree; nobody is named")
        // The same body with an open line is hit, so the tree is what stopped it.
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 12), facing: .right, bodies: ["g": big], map: try openMap())?.end,
                       .actor(id: "g", tile: p(11, 12)))
        // A body that stands on the blocker itself is not reached either.
        let onTree = try openMap(trees: [p(11, 12)])
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 12), facing: .right, bodies: ["g": big], map: onTree)?.end, .ground(p(10, 12)))
        // Directly in front: no throw at all.
        XCTAssertNil(PlazaSnowball.aim(from: p(9, 12), facing: .right, bodies: ["g": big], map: tree))
    }

    func testTwoBodiesOnTheSameFirstTileTheSmallerIDIsTheTarget() throws {
        let open = try openMap()
        let bodies = ["b": body(12, 13, 3), "a": body(12, 12, 2), "c": body(12, 14, 3)]   // all three cover (11,12)
        let shot = PlazaSnowball.aim(from: p(5, 12), facing: .right, bodies: bodies, map: open)
        XCTAssertEqual(shot?.end, .actor(id: "a", tile: p(11, 12)), "the smaller ID is named in the emote")
        // Each receiver, asked alone, finds the same entry tile; only the named one is ever asked to react.
        for (_, b) in bodies { XCTAssertEqual(PlazaSnowball.hitTile(thrower: p(5, 12), target: b, direction: .right), p(11, 12)) }
        // Without "a", the next smaller ID takes over.
        var rest = bodies; rest["a"] = nil
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 12), facing: .right, bodies: rest, map: open)?.end, .actor(id: "b", tile: p(11, 12)))
    }

    /// Class-3 feet on the top rows and the side edges, thrown at from every side, in all four directions. Whatever the
    /// thrower's `aim` names, the receiver's `hitTile` agrees on the tile, and no tile off the map is ever the end.
    func testEdgeBodiesAgreeInAllFourDirections() throws {
        let open = try openMap()
        let feet = [p(5, 0), p(5, 1), p(20, 0), p(39, 0), p(39, 1), p(39, 15), p(0, 1), p(0, 15), p(0, 29), p(39, 29), p(10, 29), p(2, 0)]
        let dirs: [PlazaDirection] = [.up, .down, .left, .right]
        var hits = 0, directions = Set<PlazaDirection>()
        for foot in feet {
            let target = PlazaBody(foot: foot, size: 3)
            for dx in -12...12 { for dy in -12...12 {
                let from = p(foot.x + dx, foot.y + dy)
                guard open.isWalkable(from) else { continue }
                for d in dirs {
                    let shot = PlazaSnowball.aim(from: from, facing: d, bodies: ["t": target], map: open)
                    if let shot { XCTAssertTrue((0..<open.width).contains(shot.endTile.x) && (0..<open.height).contains(shot.endTile.y), "\(from) \(d)") }
                    guard case .actor(_, let tile)? = shot?.end else { continue }
                    hits += 1; directions.insert(d)
                    XCTAssertTrue((0..<open.width).contains(tile.x) && (0..<open.height).contains(tile.y), "off the map: \(tile)")
                    XCTAssertEqual(PlazaSnowball.hitTile(thrower: from, target: target, direction: d), tile, "\(from) \(d) at \(foot)")
                }
            } }
        }
        XCTAssertGreaterThan(hits, 500)
        XCTAssertEqual(directions, Set(dirs), "every direction must hit somewhere")
    }

    /// A body tile that lies off the map is never hit by a throw from the map: the ball stops at the edge first.
    func testBodyTilesOffTheMapAreNeverHit() throws {
        let open = try openMap()
        let top = PlazaBody(foot: p(5, 0), size: 3)    // covers y -2...0
        XCTAssertNil(PlazaSnowball.aim(from: p(5, 0), facing: .up, bodies: ["t": top], map: open), "the edge is directly ahead")
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 5), facing: .up, bodies: ["t": top], map: open)?.end, .actor(id: "t", tile: p(5, 0)))
        let left = PlazaBody(foot: p(0, 5), size: 3)   // covers x -1...1
        XCTAssertNil(PlazaSnowball.aim(from: p(0, 5), facing: .left, bodies: ["t": left], map: open))
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 5), facing: .left, bodies: ["t": left], map: open)?.end, .actor(id: "t", tile: p(1, 5)))
        let right = PlazaBody(foot: p(39, 5), size: 3)
        XCTAssertNil(PlazaSnowball.aim(from: p(39, 5), facing: .right, bodies: ["t": right], map: open))
        XCTAssertEqual(PlazaSnowball.aim(from: p(30, 5), facing: .right, bodies: ["t": right], map: open)?.end, .actor(id: "t", tile: p(38, 5)))
    }

    /// A small teammate in front is the one the ball hits, even with a big one behind it that has a smaller ID.
    func testTheBallHitsTheSmallOneInFrontNotTheBigOneBehind() throws {
        let open = try openMap()
        let s = body(11, 10, 1), b = body(12, 10, 3)   // "b" < "s", and b's body also covers (11,10)
        let shot = PlazaSnowball.aim(from: p(5, 10), facing: .right, bodies: ["s": s, "b": b], map: open)
        XCTAssertEqual(shot?.end, .actor(id: "s", tile: p(11, 10)))
        // The receiver's rule is unchanged and agrees on the tile for the one named.
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: p(5, 10), target: s, direction: .right), p(11, 10))
        XCTAssertEqual(PlazaSnowball.hitTile(thrower: p(5, 10), target: b, direction: .right), p(11, 10))
        // Two class-1 feet on one tile: the smaller ID, as before.
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 10), facing: .right, bodies: ["y": s, "x": s], map: open)?.end, .actor(id: "x", tile: p(11, 10)))
        // Nothing in front: the big one is hit at its own first tile.
        XCTAssertEqual(PlazaSnowball.aim(from: p(5, 9), facing: .right, bodies: ["b": b], map: open)?.end, .actor(id: "b", tile: p(11, 9)))
    }

    /// Random mixed layouts: whoever `aim` names is hit by their own `hitTile` on the same tile.
    func testTheNamedBodyAgreesInMixedLayouts() throws {
        let open = try openMap()
        var rng = PlazaSplitMix64(seed: 0x71E5)
        func r(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
        let dirs: [PlazaDirection] = [.up, .down, .left, .right]
        var named = 0
        for _ in 0..<10_000 {
            let from = p(14 + r(12), 12 + r(6)), d = dirs[r(4)]
            var bodies: [String: PlazaBody] = [:]
            for id in ["a", "b", "c", "d"].prefix(1 + r(4)) {
                bodies[id] = PlazaBody(foot: p(from.x + r(15) - 7, from.y + r(15) - 7), size: r(3) + 1)
            }
            if case .actor(let named_, let tile)? = PlazaSnowball.aim(from: from, facing: d, bodies: bodies, map: open)?.end, let id = named_ {
                named += 1
                XCTAssertEqual(PlazaSnowball.hitTile(thrower: from, target: bodies[id]!, direction: d), tile)
                for (other, ob) in bodies where other != id && ob.covers(tile) {
                    let mine = abs(bodies[id]!.foot.x - tile.x) + abs(bodies[id]!.foot.y - tile.y)
                    let theirs = abs(ob.foot.x - tile.x) + abs(ob.foot.y - tile.y)
                    XCTAssertTrue(mine < theirs || (mine == theirs && id < other), "\(id) must be the nearest foot, then the smaller ID")
                }
            }
        }
        XCTAssertGreaterThan(named, 500)
    }

    func testTheBigTreeStopsABall() async {
        let a = PlazaSnowball.aim(from: p(14, 10), facing: .right, bodies: [:], map: map)
        XCTAssertEqual(a?.end, .ground(p(15, 10)))
        XCTAssertNil(PlazaSnowball.aim(from: p(15, 10), facing: .right, bodies: [:], map: map))
    }
}
