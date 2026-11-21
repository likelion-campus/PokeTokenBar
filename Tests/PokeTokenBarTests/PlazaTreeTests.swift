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
        XCTAssertEqual(PlazaTree.tiles(in: map), block(16...18, 8...10))
        XCTAssertEqual(PlazaTree.artRect(in: map), CGRect(x: 497, y: 208, width: 126, height: 144))
        XCTAssertEqual(PlazaTree.coveredTiles(in: map), block(16...18, 7...10))
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
        XCTAssertEqual(trunk.count, 9)
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
        // The drawn box (x15...19 × y6...10) lies over open ground and flowers only.
        let art = try XCTUnwrap(PlazaTree.artRect(in: map)), tile = CGFloat(PlazaMap.tileSize)
        for y in Int(art.minY / tile)..<Int((art.maxY / tile).rounded(.up)) {
            for x in Int(art.minX / tile)..<Int((art.maxX / tile).rounded(.up)) {
                XCTAssertTrue([.grass, .flowers, .bigTree].contains(map.tile(at: p(x, y))), "\(p(x, y)) is \(map.tile(at: p(x, y)))")
            }
        }
        let features: [(String, [TilePoint])] = [
            ("border tree", [p(10, 2), p(16, 2), p(0, 9)]),
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

    // MARK: Task 5: reach, strength, the hit timeline, the leaves and the falling item

    private var trunk: Set<TilePoint> { PlazaTree.tiles(in: map) }
    private func body(_ x: Int, _ y: Int, _ size: Int = 1) -> PlazaBody { PlazaBody(foot: p(x, y), size: size) }

    func testClassOneHitsTheFacedTile() async {
        XCTAssertTrue(PlazaTree.isFacing(body(17, 11), facing: .up, tiles: trunk))
        XCTAssertTrue(PlazaTree.isFacing(body(15, 9), facing: .right, tiles: trunk))
        XCTAssertTrue(PlazaTree.isFacing(body(16, 7), facing: .down, tiles: trunk))
        XCTAssertFalse(PlazaTree.isFacing(body(17, 11), facing: .left, tiles: trunk))
        XCTAssertFalse(PlazaTree.isFacing(body(14, 10), facing: .right, tiles: trunk))
        XCTAssertFalse(PlazaTree.isFacing(body(17, 10), facing: .up, tiles: trunk), "an old peer standing in the trunk faces no tree tile from outside it")
    }

    func testABigBodyHitsWithItsBody() async {
        XCTAssertFalse(trunk.contains(PlazaWalker.offset(p(15, 11), .right)), "B only: the foot's faced tile is not a tree tile")
        XCTAssertTrue(PlazaTree.isFacing(body(15, 11, 3), facing: .right, tiles: trunk))
        XCTAssertTrue(PlazaTree.isFacing(body(17, 12, 2), facing: .up, tiles: trunk))
        XCTAssertTrue(PlazaTree.isFacing(body(19, 11, 2), facing: .left, tiles: trunk))
    }

    func testTouchingButFacingAwayDoesNotHit() async {
        let big = body(19, 11, 2)
        XCTAssertTrue(PlazaTree.touches(big, tiles: trunk))
        XCTAssertFalse(PlazaTree.isFacing(big, facing: .down, tiles: trunk))
        XCTAssertFalse(PlazaTree.isFacing(big, facing: .right, tiles: trunk))
        XCTAssertFalse(PlazaTree.touches(body(21, 11, 2), tiles: trunk))
    }

    func testNoSwimmerCanFaceOrTouchTheTree() async {
        var water = 0
        for y in 0..<map.height { for x in 0..<map.width where map.isWater(p(x, y)) {
            water += 1
            for size in 1...3 {
                XCTAssertFalse(PlazaTree.touches(body(x, y, size), tiles: trunk), "(\(x),\(y)) class \(size)")
                for d in PlazaDirection.allCases { XCTAssertFalse(PlazaTree.isFacing(body(x, y, size), facing: d, tiles: trunk), "(\(x),\(y)) class \(size) \(d)") }
            }
        } }
        XCTAssertGreaterThan(water, 80, "the ponds and the spring were looked at")
    }

    func testHitDirection() async {
        XCTAssertEqual(PlazaTree.hitDirection(body(17, 11), facing: .up, tiles: trunk), .up, "facing wins when facing")
        XCTAssertEqual(PlazaTree.hitDirection(body(15, 9), facing: .down, tiles: trunk), .right)
        XCTAssertEqual(PlazaTree.hitDirection(body(19, 10), facing: .down, tiles: trunk), .left)
        XCTAssertEqual(PlazaTree.hitDirection(body(17, 7), facing: .left, tiles: trunk), .down)
        XCTAssertEqual(PlazaTree.hitDirection(body(17, 11), facing: .left, tiles: trunk), .up)
    }

    func testOnlyTheDropIsLevelThree() async {
        let drops = [false, false, true, false, false, false]
        XCTAssertEqual((1...6).map { PlazaTree.level(hits: $0, drops: drops[$0 - 1]) }, [1, 2, 3, 1, 2, 2])
        XCTAssertEqual(PlazaTree.level(hits: 3, drops: false), 2)
    }

    func testTheBendStartsAwayHoldsThenSwingsToRest() async {
        for level in 1...3 {
            let l = level - 1
            let holdEnd = PlazaTree.contactAt + PlazaTree.hitStop[l]
            XCTAssertEqual(PlazaTree.bendAmount(at: 0, level: level), 0)
            XCTAssertEqual(PlazaTree.bendAmount(at: PlazaTree.contactAt - 0.001, level: level), 0, "nothing before contact")
            XCTAssertEqual(PlazaTree.bendAmount(at: PlazaTree.contactAt, level: level), PlazaTree.bend[l], "snapped to full bend away from the hit")
            XCTAssertEqual(PlazaTree.bendAmount(at: holdEnd - 0.001, level: level), PlazaTree.bend[l], "held through the hit-stop")
            XCTAssertGreaterThan(PlazaTree.bendAmount(at: holdEnd + 0.01, level: level), 0)
            XCTAssertLessThan(PlazaTree.bendAmount(at: holdEnd + PlazaTree.swingPeriod / 2, level: level), 0, "it swings back past rest")
            XCTAssertLessThan(abs(PlazaTree.bendAmount(at: holdEnd + PlazaTree.swingLength - 0.001, level: level)), 0.5)
            XCTAssertEqual(PlazaTree.bendAmount(at: holdEnd + PlazaTree.swingLength + 0.001, level: level), 0)
            XCTAssertEqual(PlazaTree.bendAmount(at: 99, level: level), 0)
        }
    }

    func testBandsAndStretch() async {
        XCTAssertEqual(PlazaTree.bandOffsets(bend: 3), [3, 3, 0, 0])
        XCTAssertEqual(PlazaTree.bandOffsets(bend: 6), [6, 3, 3, 0])
        XCTAssertEqual(PlazaTree.bandOffsets(bend: 9), [9, 6, 3, 0])
        XCTAssertEqual(PlazaTree.bandOffsets(bend: -4.7), [-6, -3, -3, 0])
        for bend in stride(from: CGFloat(-9), through: 9, by: 0.37) {
            for o in PlazaTree.bandOffsets(bend: bend) { XCTAssertEqual(o.truncatingRemainder(dividingBy: PlazaTree.scale), 0, "bend \(bend)") }
        }
        XCTAssertEqual(PlazaTree.stretch(bend: 9), 1.0625)
        XCTAssertEqual(PlazaTree.stretch(bend: -4.7), 1 - 6 / 144)
        XCTAssertEqual(PlazaTree.stretch(bend: 0), 1)
    }

    func testTheTacklerHoldsAtContactThenRecoils() async {
        for level in 1...3 {
            let l = level - 1
            let holdEnd = PlazaTree.contactAt + PlazaTree.hitStop[l]
            XCTAssertEqual(PlazaTree.lungeOffset(at: 0, level: level), 0)
            var last: CGFloat = 0
            for k in 0..<Int(PlazaTree.contactAt * 240) {
                let v = PlazaTree.lungeOffset(at: Double(k) / 240, level: level)
                XCTAssertGreaterThanOrEqual(v, last, "it eases out toward the trunk")
                last = v
            }
            XCTAssertEqual(PlazaTree.lungeOffset(at: PlazaTree.contactAt, level: level), PlazaTree.lungeDistance[l])
            for k in Int(PlazaTree.contactAt * 240)...Int((holdEnd - 0.001) * 240) {
                XCTAssertEqual(PlazaTree.lungeOffset(at: Double(k) / 240, level: level), PlazaTree.lungeDistance[l], "held through the hit-stop (\(k))")
            }
            XCTAssertLessThan(PlazaTree.lungeOffset(at: holdEnd + PlazaTree.recoilDuration / 2, level: level), PlazaTree.lungeDistance[l])
            XCTAssertEqual(PlazaTree.lungeOffset(at: holdEnd + PlazaTree.recoilDuration, level: level), -PlazaTree.recoil[l], accuracy: 1e-9)
            XCTAssertEqual(PlazaTree.lungeLength(level: level), holdEnd + PlazaTree.recoilDuration + PlazaTree.returnDuration, accuracy: 1e-12)
            XCTAssertEqual(PlazaTree.lungeOffset(at: PlazaTree.lungeLength(level: level), level: level), 0)
            XCTAssertEqual(PlazaTree.lungeOffset(at: 99, level: level), 0)
        }
    }

    func testEveryLevelIsStrongerThanTheOneBefore() async {
        func rises<T: Comparable>(_ a: [T], _ name: String) {
            XCTAssertEqual(a.count, 3, name)
            XCTAssertTrue(zip(a, a.dropFirst()).allSatisfy { $0 < $1 }, name)
        }
        rises(PlazaTree.hitStop, "hitStop"); rises(PlazaTree.lungeDistance, "lungeDistance"); rises(PlazaTree.recoil, "recoil")
        rises(PlazaTree.bend, "bend"); rises(PlazaTree.leaves, "leaves"); rises(PlazaTree.dustSpread, "dustSpread")
        rises(PlazaTree.impactScale, "impactScale")
    }

    func testTheCameraKickIsLevelThreeOnly() async {
        for level in 1...2 { for k in 0...100 { XCTAssertEqual(PlazaTree.cameraKick(at: Double(k) / 100, level: level), 0) } }
        let start = PlazaTree.contactAt, length = PlazaTree.cameraKickDuration
        XCTAssertEqual(PlazaTree.cameraKick(at: start - 0.01, level: 3), 0)
        XCTAssertEqual(PlazaTree.cameraKick(at: start, level: 3), 0, accuracy: 1e-9)
        XCTAssertEqual(PlazaTree.cameraKick(at: start + length / 2, level: 3), PlazaTree.cameraKick, accuracy: 1e-9)
        XCTAssertEqual(PlazaTree.cameraKick(at: start + length, level: 3), 0, accuracy: 1e-9)
        XCTAssertEqual(PlazaTree.cameraKick(at: start + length + 0.5, level: 3), 0)
        for k in 0...100 { XCTAssertLessThanOrEqual(PlazaTree.cameraKick(at: start + length * Double(k) / 100, level: 3), PlazaTree.cameraKick + 1e-9) }
    }

    func testTheImpactSitsBetweenTacklerAndTrunk() async {
        let foot = CGPoint(x: 560, y: 380)
        for height: CGFloat in [10, 24, 48, 90] {
            let lift = max(height, 24) * 0.55
            XCTAssertEqual(PlazaTree.impactPoint(tacklerFoot: foot, direction: .up, height: height), CGPoint(x: 560, y: 364 - lift))
            XCTAssertEqual(PlazaTree.impactPoint(tacklerFoot: foot, direction: .down, height: height), CGPoint(x: 560, y: 396 - lift))
            XCTAssertEqual(PlazaTree.impactPoint(tacklerFoot: foot, direction: .left, height: height), CGPoint(x: 544, y: 380 - lift))
            XCTAssertEqual(PlazaTree.impactPoint(tacklerFoot: foot, direction: .right, height: height), CGPoint(x: 576, y: 380 - lift))
        }
    }

    // MARK: leaves

    private func canopyPoints() throws -> (points: [CGPoint], rect: CGRect) {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let image = try XCTUnwrap(PlazaTree.image(sheet, season: .summer))
        let rect = try XCTUnwrap(PlazaTree.artRect(in: map))
        return (PlazaTree.canopySpawnPoints(image, artRect: rect), rect)
    }

    func testABurstScattersAwayAndUpThenFallsAndRests() async throws {
        let (points, rect) = try canopyPoints()
        let baseY = rect.maxY
        var field = PlazaTreeLeaves(spawnPoints: points, baseY: baseY)
        XCTAssertTrue(field.leaves.isEmpty)
        field.burst(count: 8, direction: .right, grids: [0, 1, 2, 3])
        XCTAssertEqual(field.leaves.count, 8)
        XCTAssertEqual(field.bursts, 1)
        let start = field.leaves
        for leaf in start {
            XCTAssertTrue(points.contains(CGPoint(x: leaf.x, y: leaf.y)), "starts on an opaque canopy pixel")
            XCTAssertTrue([0, 1, 2, 3].contains(leaf.image))
            XCTAssertTrue((baseY...(baseY + 18)).contains(leaf.groundY), "lands 0...18 px below the trunk base")
            XCTAssertNil(leaf.restedAt)
            XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), 1)
        }
        field.advance(by: 0.1, kind: .greenLeaves)
        XCTAssertEqual(field.leaves.count, 8)
        for (a, b) in zip(start, field.leaves) {
            XCTAssertGreaterThan(b.x, a.x, "away from the hit")
            XCTAssertLessThan(b.y, a.y, "and up")
        }
        var t = 0.1
        while t < PlazaTree.leafLife + 0.5 {
            field.advance(by: 1.0 / 60, kind: .greenLeaves)
            t += 1.0 / 60
            for leaf in field.leaves {
                XCTAssertTrue((0...1).contains(PlazaTreeLeaves.alpha(leaf)))
                XCTAssertLessThan(t, PlazaTree.leafLife + 1.0 / 60, "no leaf outlives leafLife")
            }
        }
        XCTAssertTrue(field.leaves.isEmpty, "all gone by leafLife")
    }

    /// The hit must feel impactful: after the pop the leaves rain down faster than the weather and EVERY leaf of a burst lands, rests and fades
    /// inside leafLife (none vanishes in the air), for every burst seed, every direction and every season's kind.
    func testEveryLeafOfEveryBurstLandsBeforeItFades() async throws {
        let (points, rect) = try canopyPoints()
        XCTAssertTrue((60...90).contains(PlazaTree.leafFall), "faster than the weather's 14...24, as the user asked: 60...90")
        XCTAssertGreaterThan(PlazaTree.leafFall, CGFloat(PlazaWeather.Kind.allCases.map { PlazaWeather.motion($0).fall }.max()!) * 2)
        for kind in [PlazaWeather.Kind.greenLeaves, .leaves, .snow] {
            var field = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY)
            var landed = 0, maxFall: CGFloat = 0, lastLanding = 0.0
            for n in 0..<60 {
                field.burst(count: PlazaTree.maxFallingLeaves, direction: PlazaDirection.allCases[n % 4], grids: [0, 1])
                var t = 0.0
                while !field.leaves.isEmpty {
                    let before = field.leaves
                    field.advance(by: 1.0 / 60, kind: kind)
                    t += 1.0 / 60
                    maxFall = max(maxFall, field.leaves.map(\.vy).max() ?? 0)
                    var j = 0, goneLeaves: [PlazaTreeLeaf] = []   // survivors keep their order; a leaf is the same one by its seeded groundY and phase
                    for b in before {
                        if j < field.leaves.count, field.leaves[j].groundY == b.groundY, field.leaves[j].phase == b.phase { j += 1 } else { goneLeaves.append(b) }
                    }
                    for gone in goneLeaves {
                        // it left the field in this step: it must have been resting, never airborne
                        XCTAssertNotNil(gone.restedAt, "\(kind) burst \(n): a leaf vanished in the air at t=\(t)")
                        landed += 1
                        lastLanding = max(lastLanding, gone.restedAt ?? 0)
                    }
                    XCTAssertLessThan(t, PlazaTree.leafLife + 1.0 / 60, "\(kind) burst \(n)")
                    if t > 10 { break }
                }
            }
            XCTAssertEqual(landed, 60 * PlazaTree.maxFallingLeaves, "\(kind): every leaf of every burst landed")
            XCTAssertLessThanOrEqual(lastLanding, PlazaTree.leafLife - PlazaTree.leafRest, "\(kind): the slowest leaf is down before the end-of-life fade")
            XCTAssertGreaterThan(maxFall, PlazaTree.leafFall * 0.95, "\(kind): they really fall at leafFall")
            XCTAssertLessThanOrEqual(maxFall, PlazaTree.leafFall + 1e-6)
        }
    }

    /// The pine's low boughs drop a leaf to the ground inside leafLife: it lands on groundY, lies still, fades over leafRest and goes.
    func testALowLeafReachesTheGroundRestsFadesAndGoes() async throws {
        let rect = try XCTUnwrap(PlazaTree.artRect(in: map))
        var field = PlazaTreeLeaves(spawnPoints: [CGPoint(x: 560, y: rect.maxY - 3)], baseY: rect.maxY)
        field.burst(count: 4, direction: .left, grids: [0, 1, 2])
        var seen = Set<CGFloat>()   // groundY is different for every leaf
        var t = 0.0
        while !field.leaves.isEmpty, t < PlazaTree.leafLife + 0.5 {
            field.advance(by: 1.0 / 60, kind: .snow)
            t += 1.0 / 60
            for leaf in field.leaves {
                guard let at = leaf.restedAt else { continue }
                seen.insert(leaf.groundY)
                XCTAssertLessThan(at, PlazaTree.leafLife - PlazaTree.leafRest, "it landed before the end-of-life fade began")
                XCTAssertEqual(leaf.y, leaf.groundY, accuracy: 1e-9, "it lies on the ground")
                XCTAssertEqual(leaf.vx, 0); XCTAssertEqual(leaf.vy, 0)
                XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), CGFloat(max(0, 1 - (leaf.age - at) / PlazaTree.leafRest)), accuracy: 1e-9)
            }
        }
        XCTAssertEqual(seen.count, 4, "every low leaf landed")
        XCTAssertTrue(field.leaves.isEmpty)
        XCTAssertLessThan(t, PlazaTree.leafLife + 1.0 / 60)
    }

    func testARestingLeafFadesOverLeafRest() async {
        var leaf = PlazaTreeLeaf(x: 0, y: 0, vx: 0, vy: 0, age: 1, restedAt: nil, groundY: 0, image: 0, phase: 0)
        XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), 1)
        leaf.restedAt = 1
        XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), 1, "just landed")
        leaf.age = 1 + PlazaTree.leafRest / 2
        XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), 0.5, accuracy: 1e-9)
        leaf.age = 1 + PlazaTree.leafRest
        XCTAssertEqual(PlazaTreeLeaves.alpha(leaf), 0, accuracy: 1e-9)
    }

    func testTheFieldNeverHoldsMoreThanTheCap() async throws {
        let (points, rect) = try canopyPoints()
        var field = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY)
        for n in 0..<1000 {
            field.burst(count: 8, direction: PlazaDirection.allCases[n % 4], grids: [0, 1, 4, 5])
            XCTAssertLessThanOrEqual(field.leaves.count, PlazaTree.maxFallingLeaves, "burst \(n)")
            field.advance(by: 1.0 / 60, kind: .leaves)
            XCTAssertLessThanOrEqual(field.leaves.count, PlazaTree.maxFallingLeaves, "advance \(n)")
        }
        XCTAssertEqual(field.bursts, 1000)
        XCTAssertEqual(field.leaves.count, PlazaTree.maxFallingLeaves, "a flood keeps the pool full")
    }

    func testTheSameBurstNumberGivesTheSameLeaves() async throws {
        let (points, rect) = try canopyPoints()
        var a = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY), b = a
        for n in 0..<5 {
            a.burst(count: 5, direction: .left, grids: [0, 1, 2]); b.burst(count: 5, direction: .left, grids: [0, 1, 2])
            a.advance(by: 0.04, kind: .snow); b.advance(by: 0.04, kind: .snow)
            XCTAssertEqual(a.leaves, b.leaves, "step \(n)")
        }
        var c = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY)
        c.burst(count: 5, direction: .left, grids: [0, 1, 2])
        var d = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY)
        d.burst(count: 5, direction: .left, grids: [0, 1, 2]); d.advance(by: 1, kind: .snow); d.burst(count: 5, direction: .left, grids: [0, 1, 2])
        XCTAssertNotEqual(c.leaves.map(\.x), d.leaves.map(\.x), "burst n is seeded by n")
    }

    // MARK: the falling item

    func testTheItemStartsAboveTheTackler() async throws {
        let rect = try XCTUnwrap(PlazaTree.artRect(in: map))
        XCTAssertEqual(PlazaTree.itemStart(artRect: rect, tacklerFoot: CGPoint(x: 560, y: 380)), CGPoint(x: 560, y: 298))
        XCTAssertEqual(PlazaTree.itemStart(artRect: rect, tacklerFoot: CGPoint(x: 496, y: 348)), CGPoint(x: 521, y: 298), "clamped 24 px inside the art")
        XCTAssertEqual(PlazaTree.itemStart(artRect: rect, tacklerFoot: CGPoint(x: 700, y: 348)), CGPoint(x: 599, y: 298))
        XCTAssertEqual(PlazaTree.itemStart(artRect: rect, tacklerFoot: CGPoint(x: 560, y: 252)), CGPoint(x: 560, y: 204), "48 px above feet behind the tree")
    }

    func testTheItemFallsFromTheCanopyToTheFeet() async throws {
        let rect = try XCTUnwrap(PlazaTree.artRect(in: map))
        let feet = CGPoint(x: 540, y: 380)
        let from = PlazaTree.itemStart(artRect: rect, tacklerFoot: feet)
        let fall = PlazaTreeItemFall(from: from, to: feet)
        XCTAssertEqual(fall.position(at: 0), from)
        XCTAssertEqual(fall.position(at: PlazaTree.itemFall), feet)
        for k in 0...45 {
            let t = PlazaTree.itemFall * Double(k) / 45
            let at = try XCTUnwrap(fall.position(at: t))
            let line = from.y + (feet.y - from.y) * CGFloat(t / PlazaTree.itemFall)
            XCTAssertLessThanOrEqual(at.y, feet.y + 1e-9)
            XCTAssertLessThanOrEqual(at.y, line + 1e-9, "above the straight line: the arc")
            XCTAssertGreaterThanOrEqual(at.y, from.y - PlazaTree.itemArc - 1e-9)
        }
        var top: CGFloat = 0
        for k in 1..<10 {
            let at = try XCTUnwrap(fall.position(at: PlazaTree.itemFall + PlazaTree.itemBounceDuration * Double(k) / 10))
            XCTAssertEqual(at.x, feet.x)
            XCTAssertLessThanOrEqual(at.y, feet.y + 1e-9)
            top = max(top, feet.y - at.y)
        }
        XCTAssertEqual(top, PlazaTree.itemBounce, accuracy: 0.2, "it bounces itemBounce high")
        XCTAssertNil(fall.position(at: PlazaTree.itemFall + PlazaTree.itemBounceDuration))
        XCTAssertNil(fall.position(at: 5))
        XCTAssertNil(fall.position(at: -0.01))
    }

    // MARK: the day count (Task 7)

    func testTheThirdHitDropsAndTheFourthDoesNot() async {
        var day = PlazaTreeDay(day: "2026-11-21")
        let drops = (0..<6).map { _ in day.hit(on: "2026-11-21") }
        XCTAssertEqual(drops, [false, false, true, false, false, false])
        XCTAssertEqual(day.dropped, 1)
        XCTAssertEqual(day.hits, 6)
    }

    func testANewDayDropsAgain() async {
        var day = PlazaTreeDay(day: "2026-11-21")
        for _ in 0..<3 { _ = day.hit(on: "2026-11-21") }
        XCTAssertEqual([day.hit(on: "2026-11-22"), day.hit(on: "2026-11-22"), day.hit(on: "2026-11-22")], [false, false, true])
        XCTAssertEqual(day.day, "2026-11-22")
        XCTAssertEqual(day.hits, 3, "a later day starts over")
    }

    func testTheDayTurnsAtLocalMidnight() async throws {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        func at(_ h: Int, _ m: Int, _ sec: Int, day: Int = 21) -> Date {
            seoul.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: sec))!
        }
        func key(_ d: Date) -> String { PlazaActivity.dayKey(d, calendar: seoul) }
        XCTAssertNotEqual(key(at(23, 59, 59)), key(at(0, 0, 0, day: 22)))
        XCTAssertEqual(key(at(0, 0, 0, day: 22)), key(at(0, 0, 1, day: 22)))
        var day = PlazaTreeDay(day: "")
        XCTAssertFalse(day.hit(on: key(at(23, 59, 58))))
        XCTAssertFalse(day.hit(on: key(at(23, 59, 59))))
        XCTAssertFalse(day.hit(on: key(at(0, 0, 0, day: 22))), "the third hit is on a new day: it counts as the first")
        XCTAssertFalse(day.hit(on: key(at(0, 0, 1, day: 22))))
        XCTAssertTrue(day.hit(on: key(at(0, 0, 2, day: 22))))
    }

    func testAClockSetBackGivesNoSecondMint() async {
        var day = PlazaTreeDay(day: "2026-11-22")
        XCTAssertEqual([day.hit(on: "2026-11-22"), day.hit(on: "2026-11-22"), day.hit(on: "2026-11-22")], [false, false, true])
        for _ in 0..<3 { XCTAssertFalse(day.hit(on: "2026-11-21"), "an earlier day keeps counting on the saved one") }
        XCTAssertEqual(day.day, "2026-11-22")
        XCTAssertEqual(day.dropped, 1)
        _ = day.hit(on: "2026-11-23"); _ = day.hit(on: "2026-11-23")
        XCTAssertTrue(day.hit(on: "2026-11-23"))
    }

    func testHitsStopAtTheCap() async {
        var day = PlazaTreeDay(day: "d")
        day.hits = PlazaTreeDay.maxHits
        _ = day.hit(on: "d")
        XCTAssertEqual(day.hits, PlazaTreeDay.maxHits)
    }

    func testTheTreeDaySurvivesARestart() async throws {
        let suite = "plaza.test.tree.\(UUID())"
        let defaults = try XCTUnwrap(TestDefaults.make(suite: suite))
        let first = PlazaPreferences(defaults: defaults)
        XCTAssertNil(first.tree)
        var day = PlazaTreeDay(day: "2026-11-21")
        _ = day.hit(on: "2026-11-21"); _ = day.hit(on: "2026-11-21")
        first.tree = day
        let second = PlazaPreferences(defaults: defaults)
        XCTAssertEqual(second.tree, day)
        second.tree = nil
        XCTAssertNil(PlazaPreferences(defaults: defaults).tree)
        defaults.set(Data("not json".utf8), forKey: "team.plaza.tree")
        XCTAssertNil(PlazaPreferences(defaults: defaults).tree, "garbage reads as nothing")
    }

    func testTheBannerNamesEachItemKindAsTheSubject() async {
        XCTAssertEqual(L(.ko).plazaTreeDropped(.mint), "나무에서 민트가 떨어졌어요! 가방에 넣었어요")
        XCTAssertEqual(L(.ko).plazaTreeDropped(.rareCandy), "나무에서 이상한 사탕이 떨어졌어요! 가방에 넣었어요")
        XCTAssertEqual(L(.ko).plazaTreeDropped(.shinyCharm), "나무에서 이로치 부적이 떨어졌어요! 가방에 넣었어요")
    }

    /// The tuned look (the user found the first bend barely visible and the burst thin): top-band travel 6/12/18 world px, 8/12/20 leaves,
    /// and a pool of 20. Every band offset stays a whole tree pixel, so the bands move as solid slabs.
    func testTheTunedBendAndBurst() async {
        XCTAssertEqual(PlazaTree.bend, [6, 12, 18])
        XCTAssertEqual(PlazaTree.leaves, [8, 12, 20])
        XCTAssertEqual(PlazaTree.maxFallingLeaves, 20)
        XCTAssertEqual(PlazaTree.leaves.last, PlazaTree.maxFallingLeaves, "level 3 uses the whole pool")
        XCTAssertEqual(PlazaTree.bend.map { PlazaTree.bandOffsets(bend: $0) }, [[6, 3, 3, 0], [12, 9, 3, 0], [18, 12, 6, 0]])
        for b in PlazaTree.bend {
            let offsets = PlazaTree.bandOffsets(bend: b)
            for o in offsets { XCTAssertEqual(o.truncatingRemainder(dividingBy: PlazaTree.scale), 0) }
            for (upper, lower) in zip(offsets, offsets.dropFirst()) {
                XCTAssertLessThanOrEqual(upper - lower, 3 * PlazaTree.scale, "the step between two bands stays small: the seam shows as a stair, not a tear")
            }
        }
    }

    /// A burst takes one leaf from each equal-sized slice of the canopy (the opaque pixels sorted by x), so it spreads across the whole width.
    func testABurstSpreadsAcrossTheWholeCanopy() async throws {
        let (points, rect) = try canopyPoints()
        let xs = points.map(\.x).sorted()
        for count in PlazaTree.leaves {
            var field = PlazaTreeLeaves(spawnPoints: points, baseY: rect.maxY)
            field.burst(count: count, direction: .up, grids: [0])
            func check(_ leaves: ArraySlice<PlazaTreeLeaf>, _ n: Int, _ what: String) {
                for (k, leaf) in leaves.enumerated() {
                    let lo = xs[k * xs.count / n], hi = xs[(k + 1) * xs.count / n - 1]
                    XCTAssertTrue((lo...hi).contains(leaf.x), "\(what) leaf \(k) of \(n): \(leaf.x) not in \(lo)...\(hi)")
                }
            }
            check(field.leaves[...], count, "first burst")
            XCTAssertLessThan(field.leaves.map(\.x).min()!, rect.minX + rect.width * 0.2)
            XCTAssertGreaterThan(field.leaves.map(\.x).max()!, rect.maxX - rect.width * 0.2)
            if count + 8 <= PlazaTree.maxFallingLeaves {
                field.burst(count: 8, direction: .up, grids: [0])
                check(field.leaves[count...], 8, "second burst")
            }
        }
    }
}
