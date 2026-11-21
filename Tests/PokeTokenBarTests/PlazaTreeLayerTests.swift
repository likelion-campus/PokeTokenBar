import XCTest
@testable import PokeTokenBar

/// 큰 나무가 장면에서 하는 일: 자리, 앞뒤, 계절, 사진, 배경 숨김(Task 4). 타격은 Task 6부터.
@MainActor final class PlazaTreeLayerTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func scene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: p(20, 22), zoom: 2, nickname: "me")
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        return s
    }

    /// The real map with the tree layer (it needs `pondVisuals`), in a season, at rest.
    private func treeScene(start: TilePoint = TilePoint(x: 17, y: 12), season: PlazaSeasonChoice = .summer) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2, nickname: "me", pondVisuals: true)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.now = { PlazaFixtureTime.date(hour: 12, minute: 0) }   // noon: no night tint in the photo
        s.seasonChoice = season
        s.update(0)
        return s
    }

    private func solidFrames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: PlazaImage(bitmap: PlazaTestImages.solid(width: 32, height: 48, PlazaRGBA(r: 255, g: 0, b: 0, a: 255))), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, _ x: Int, _ y: Int, facing: PlazaDirection = .down) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: p(x, y), facing: facing, isWalking: false)
    }

    func testAnOldPeerOnTheTrunkIsDrawnThere() async throws {
        let s = scene()
        s.applyMembers([member("a", 17, 10), member("ref", 17, 12)])
        let foot = try XCTUnwrap(s.memberFoot("a"))
        let ref = try XCTUnwrap(s.memberFoot("ref"))
        XCTAssertEqual(foot.x, ref.x, accuracy: 0.001)
        XCTAssertEqual(foot.y, ref.y - 2 * CGFloat(PlazaMap.tileSize), accuracy: 0.001, "drawn on (17,10), not moved to the shelter")
    }

    func testABlockedTileThatIsNotTheTreeStillGoesToTheShelter() async throws {
        let s = scene()
        s.applyMembers([member("a", 15, 4)])   // the bush
        let foot = try XCTUnwrap(s.memberFoot("a"))
        let size = CGFloat(PlazaMap.tileSize)
        let tile = TilePoint(x: Int(foot.x / size), y: Int(foot.y / size))
        XCTAssertTrue(map.shelterTiles.contains(tile), "\(tile)")
    }

    // MARK: Task 4: the tree at rest

    func testTheTreeIsDrawnAtItsRect() async throws {
        let s = treeScene()
        XCTAssertTrue(s.isTreeShown)
        let layer = try XCTUnwrap(s.treeLayer)
        let union = layer.bandWorldRects.dropFirst().reduce(layer.bandWorldRects[0]) { $0.union($1) }
        XCTAssertEqual(union, try XCTUnwrap(PlazaTree.artRect(in: map)))
        XCTAssertEqual(layer.bandWorldRects.map(\.height), [30, 30, 30, 54])
        XCTAssertEqual(s.treeNodeCount, 22, "two roots, four bands, twelve leaves, two dust puffs, the star and the item")
    }

    func testTeammatesInFrontAndBehind() async throws {
        let s = treeScene()
        let ids = ["a", "b", "c", "d", "e"]
        s.applyMembers(zip(ids, [(17, 11), (15, 10), (19, 10), (17, 7), (16, 12)]).map { member($0, $1.0, $1.1) })
        for id in ids { s.setMemberFrames(id, solidFrames()) }
        s.update(1.0 / 60)
        let tree = try XCTUnwrap(s.treeZ)
        XCTAssertEqual(tree, 1.34375, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(s.memberZ("a")), tree)
        XCTAssertGreaterThan(try XCTUnwrap(s.memberZ("e")), tree)
        for id in ["b", "c", "d"] { XCTAssertLessThan(try XCTUnwrap(s.memberZ(id)), tree, id) }
    }

    func testPlatesAndBubblesStayOverTheTree() async throws {
        let s = treeScene()
        s.applyMembers([member("a", 17, 7)])
        s.showChat(memberID: "a", text: "hi")
        XCTAssertEqual(s.memberNamePlateVisible("a"), true, "the tree is not a hiding place")
    }

    func testWeatherAndDaylightLieOverTheTree() async throws {
        let s = treeScene(start: p(35, 17))
        let tree = try XCTUnwrap(s.treeZ)
        XCTAssertLessThan(tree, s.weatherLayer.root.zPosition)
        XCTAssertLessThan(tree, try XCTUnwrap(s.steamLayer).root.zPosition)
        XCTAssertLessThan(tree, 5, "the daylight multiply")
        XCTAssertGreaterThan(try XCTUnwrap(s.treeLayer).fxRoot.zPosition, 5)
    }

    func testSeasonsSwapTheArt() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        func bands(_ season: PlazaSeason) throws -> [[UInt8]] { PlazaTree.bands(try XCTUnwrap(PlazaTree.image(sheet, season: season))).map { $0.pixels.bytes } }
        let s = treeScene(season: .winter)
        let layer = try XCTUnwrap(s.treeLayer)
        XCTAssertEqual(layer.bandImages.map { $0?.pixels.bytes }, try bands(.winter).map { Optional($0) })
        var seen = Set<UInt32>()
        for band in layer.bandImages.prefix(3) {
            let b = try XCTUnwrap(band).pixels.bytes
            for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] == 255 {
                seen.insert((UInt32(b[i]) << 16) | (UInt32(b[i + 1]) << 8) | UInt32(b[i + 2]))
            }
        }
        XCTAssertTrue(seen.isDisjoint(with: PlazaTree.leafColors), "a source leaf colour is left in winter's canopy")
        XCTAssertTrue(seen.isSuperset(of: PlazaTree.seasonLeaves[.winter] ?? []), "winter's leaf colours are drawn")
        s.seasonChoice = .summer
        XCTAssertEqual(layer.bandImages.map { $0?.pixels.bytes }, try bands(.summer).map { Optional($0) })
    }

    func testHidingTheBackgroundHidesTheTreeButKeepsItsWall() async throws {
        let s = treeScene(start: p(17, 11))
        s.setBackgroundHidden(true)
        XCTAssertFalse(s.isTreeShown)
        XCTAssertEqual(s.photoInput()?.props.filter { $0.baseY == 352 }.count, 0, "a hidden tree is not in the photo")
        s.handleKeyDown(keyCode: 126, characters: nil, isRepeat: false)   // up
        for i in 1..<60 { s.update(Double(i) / 60) }
        s.handleKeyUp(keyCode: 126)
        XCTAssertEqual(s.walker.tile, p(17, 11), "the hidden tree still blocks")
        s.setBackgroundHidden(false)
        XCTAssertTrue(s.isTreeShown)
    }

    func testThePhotoCarriesTheTree() async throws {
        let s = treeScene(season: .winter)
        s.zoom = 1
        s.applyMembers([member("a", 17, 7)])
        s.setMemberFrames("a", solidFrames())
        s.update(1.0 / 60)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.props.filter { $0.baseY == 352 }.count, 4, "four bands (the campfire is the fifth prop)")
        let art = try XCTUnwrap(PlazaTree.artRect(in: map))
        let rect = input.visibleRect
        XCTAssertTrue(rect.contains(art), "the camera shows the whole tree: \(rect)")
        let ppw = CGFloat(input.pixelsPerWorld)
        func pixel(_ photo: PlazaBitmap, _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let px = Int((x - rect.minX) * ppw), py = Int((y - rect.minY) * ppw), i = (py * photo.width + px) * 4
            return Array(photo.bytes[i..<i + 4])
        }
        let withMember = try XCTUnwrap(PlazaPhotoRenderer.renderBitmap(input))
        var snow = false
        for y in stride(from: Int(art.minY), to: Int(art.maxY), by: 1) { for x in stride(from: Int(art.minX), to: Int(art.maxX), by: 1) {
            if Array(pixel(withMember, CGFloat(x), CGFloat(y)).prefix(3)) == [0xF4, 0xF8, 0xFC] { snow = true }
        } }
        XCTAssertTrue(snow, "winter's snow leaf is in the photo's tree")
        s.applyMembers([])
        let without = try XCTUnwrap(PlazaPhotoRenderer.renderBitmap(try XCTUnwrap(s.photoInput())))
        XCTAssertEqual(pixel(withMember, 560, 235), pixel(without, 560, 235), "the member behind the canopy is hidden by it")
        XCTAssertNotEqual(pixel(withMember, 560, 206), pixel(without, 560, 206), "above the narrow top the head shows")
    }

    func testAMapWithoutTheTreeHasNoLayer() async throws {
        let bare = try PlazaMap(rows: ["SN..", "...."])
        let s = PlazaScene(map: bare, mapImage: PlazaTileArt.plainGrassImage(bare), start: p(2, 1), zoom: 2, nickname: "me", pondVisuals: true)
        XCTAssertEqual(s.treeNodeCount, 0)
        XCTAssertFalse(s.isTreeShown)
        XCTAssertNil(s.treeZ)
        XCTAssertFalse(s.isTreeBusy)
        XCTAssertEqual(s.treeBandOffsets, [])
        XCTAssertEqual(s.treeStretch, 1)
        XCTAssertEqual(s.treeLeafCount, 0)
        XCTAssertNil(s.treeItemPosition)
        s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)   // no layer: the tackler still lunges, nothing else
        XCTAssertFalse(s.isTreeBusy)
    }

    func testTheSameSeasonWritesNothing() async throws {
        let s = treeScene()
        let layer = try XCTUnwrap(s.treeLayer)
        let before = layer.bandImages.map { $0.map(ObjectIdentifier.init) }
        layer.setSeason(.summer)
        XCTAssertEqual(layer.bandImages.map { $0.map(ObjectIdentifier.init) }, before)
        layer.setSeason(.winter)
        XCTAssertNotEqual(layer.bandImages.map { $0.map(ObjectIdentifier.init) }, before)
        layer.setSeason(.winter)
        layer.setHidden(false)
        XCTAssertTrue(layer.isShown)
    }

    // MARK: Task 6: the hit on screen

    /// A scene with the hitters standing where they can reach the trunk.
    private func hitScene(start: TilePoint = TilePoint(x: 17, y: 11), season: PlazaSeasonChoice = .summer) -> PlazaScene {
        let s = treeScene(start: start, season: season)
        s.applyMembers([member("a", 15, 10, facing: .right), member("b", 19, 10, facing: .left),
                        member("c", 17, 7, facing: .down), member("d", 17, 11, facing: .up)])
        for id in ["a", "b", "c", "d"] { s.setMemberFrames(id, solidFrames()) }
        s.update(1.0 / 60)
        return s
    }

    private var tick: TimeInterval { 1.0 / 60 }

    /// Runs the scene on from `t`, returning the new time.
    @discardableResult private func run(_ s: PlazaScene, from t: TimeInterval, seconds: TimeInterval, step: TimeInterval = 1.0 / 60,
                                        each: (TimeInterval) -> Void = { _ in }) -> TimeInterval {
        var now = t
        let end = t + seconds
        while now < end - 1e-9 {
            now += step
            s.update(now)
            each(now - t)
        }
        return now
    }

    func testThePoolIsMadeOnceAndNeverGrows() async throws {
        let s = hitScene()
        let layer = try XCTUnwrap(s.treeLayer)
        XCTAssertEqual(s.treeNodeCount, 22, "2 roots + 20 sprites, from the first frame")
        XCTAssertTrue(s.root.children.contains { $0 === layer.root } && s.root.children.contains { $0 === layer.fxRoot })
        var t = run(s, from: 1.0 / 60, seconds: 0.2)
        let others = s.root.children.count
        for i in 0..<1000 {
            s.playTreeHit(by: i % 3 == 0 ? nil : ["a", "b", "c", "d"][i % 4], direction: PlazaDirection.allCases[i % 4], level: i % 3 + 1,
                          drop: i % 5 == 0 ? .mint : nil)
            if i % 20 == 0 { t = run(s, from: t, seconds: 0.05) }
            XCTAssertEqual(s.treeNodeCount, 22)
        }
        t = run(s, from: t, seconds: 10)   // the sparkles and the star are gone, the pool is the same
        XCTAssertEqual(s.treeNodeCount, 22)
        XCTAssertEqual(s.root.children.count, others, "no other node of the scene grew either")
        XCTAssertFalse(s.isTreeBusy)
    }

    func testAPausedSceneDoesNothing() async throws {
        let s = hitScene()
        s.isPaused = true
        let nodes = s.root.children.count, tree = s.treeNodeCount
        for _ in 0..<100 { s.playTreeHit(by: "a", direction: .right, level: 3, drop: .mint); s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint) }
        XCTAssertEqual(s.lungeOffset(memberID: "a"), .zero)
        XCTAssertEqual(s.lungeOffset(memberID: nil), .zero)
        XCTAssertFalse(s.isTreeBusy)
        XCTAssertEqual(s.cameraKickOffset, .zero)
        XCTAssertEqual(s.root.children.count, nodes)
        XCTAssertEqual(s.treeNodeCount, tree)
        XCTAssertEqual(s.sparkleCount, 0)
    }

    func testAnIdleTreeWritesNothing() async throws {
        let s = hitScene()
        let layer = try XCTUnwrap(s.treeLayer)
        let rest = layer.spriteStates
        run(s, from: 1.0 / 60, seconds: 10)
        XCTAssertEqual(layer.spriteStates, rest, "600 idle frames: no property moved")
        // After a hit the tree settles back to exactly the resting state.
        s.playTreeHit(by: "a", direction: .right, level: 3, drop: .mint)
        let t = run(s, from: 10, seconds: 6)
        XCTAssertFalse(s.isTreeBusy)
        // A hidden sprite keeps its last position and alpha (nothing draws it), so settled means: shown ones as before, the others hidden.
        XCTAssertEqual(layer.spriteStates.map { $0.hidden ? nil : $0 }, rest.map { $0.hidden ? nil : $0 }, "settled: bands home, leaves, dust, star and item hidden again")
        _ = t
    }

    /// Off screen the clocks run but no node is written; scrolling back shows the right moment.
    func testAnOffscreenHitAdvancesButWritesNothing() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        var images = [PlazaSeason: PlazaImage]()
        for season in PlazaSeason.allCases { images[season] = PlazaTree.image(sheet, season: season) }
        let layer = PlazaTreeLayer(map: map, images: images, worldHeight: map.pixelSize.height)
        let art = try XCTUnwrap(PlazaTree.artRect(in: map))
        let far = CGRect(x: 1000, y: 0, width: 400, height: 300), near = CGRect(x: 400, y: 150, width: 400, height: 300)
        let rest = layer.spriteStates
        layer.hit(direction: .right, level: 2, tacklerFoot: CGPoint(x: 496, y: 348), tacklerHeight: 48, drop: nil)
        var landed = false
        for _ in 0..<12 { landed = layer.update(dt: tick, visible: far, step: 0.25) || landed }   // 0.2 s
        XCTAssertFalse(landed)
        XCTAssertEqual(layer.spriteStates, rest, "nothing written while the tree is out of view")
        XCTAssertTrue(layer.isBusy, "but the clock ran")
        _ = layer.update(dt: 0.05, visible: near, step: 0.25)
        let elapsed = 12 * tick + 0.05
        let hold = PlazaTree.contactAt + PlazaTree.hitStop[1]
        XCTAssertGreaterThan(elapsed, hold)
        let expected = PlazaTree.bandOffsets(bend: PlazaTree.bendAmount(at: elapsed, level: 2))
        XCTAssertEqual(layer.bandOffsets, expected, "the bend is the one at the total elapsed time")
        XCTAssertNotEqual(layer.spriteStates, rest)
        XCTAssertGreaterThan(layer.shownLeafCount, 0, "the burst already happened off screen")
        _ = art
    }

    func testAHorizontalHitShearsAwayAndSettles() async throws {
        let s = hitScene()
        s.playTreeHit(by: "a", direction: .right, level: 2, drop: nil)
        var peak: [CGFloat] = []
        var t = run(s, from: 1.0 / 60, seconds: 0.133) { _ in }
        peak = s.treeBandOffsets
        XCTAssertEqual(peak, [6, 3, 3, 0], "at the hold: away from a hit that moves right")
        t = run(s, from: t, seconds: 1.0) { _ in XCTAssertEqual(s.treeBandOffsets.last, 0, "the trunk never moves") }
        XCTAssertEqual(s.treeBandOffsets, [0, 0, 0, 0], "settled")
        XCTAssertEqual(s.treeStretch, 1)
        s.playTreeHit(by: "b", direction: .left, level: 2, drop: nil)
        t = run(s, from: t, seconds: 0.133)
        XCTAssertEqual(s.treeBandOffsets, [-6, -3, -3, 0], ".left mirrors it")
    }

    func testAVerticalHitStretchesOrSquashes() async throws {
        let s = hitScene()
        XCTAssertEqual(s.treeStretch, 1)
        s.playTreeHit(by: "d", direction: .up, level: 2, drop: nil)
        var t = run(s, from: 1.0 / 60, seconds: 0.133)
        XCTAssertGreaterThan(s.treeStretch, 1, "a hit from the south leans the tree away: taller")
        XCTAssertEqual(s.treeBandOffsets, [0, 0, 0, 0], "a vertical hit shears nothing")
        t = run(s, from: t, seconds: 1.0)
        XCTAssertEqual(s.treeStretch, 1)
        s.playTreeHit(by: "c", direction: .down, level: 2, drop: nil)
        t = run(s, from: t, seconds: 0.133)
        XCTAssertLessThan(s.treeStretch, 1, "a hit from the north leans it toward the viewer: squashed")
    }

    func testHitStopHoldsTheTacklerAndTheTree() async throws {
        let s = hitScene()
        s.playTreeHit(by: "a", direction: .right, level: 2, drop: nil)
        let hold = PlazaTree.contactAt + PlazaTree.hitStop[1]
        var samples: [(CGPoint, [CGFloat])] = []
        run(s, from: 1.0 / 60, seconds: 0.3, step: 1.0 / 240) { dt in
            if dt > PlazaTree.contactAt + 0.01 && dt < hold - 0.01 { samples.append((s.lungeOffset(memberID: "a") ?? .zero, s.treeBandOffsets)) }
        }
        XCTAssertGreaterThan(samples.count, 5)
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.0.x, PlazaTree.lungeDistance[1])
        for sample in samples { XCTAssertEqual(sample.0, first.0); XCTAssertEqual(sample.1, first.1) }
    }

    func testTheBurstGrowsWithTheLevel() async throws {
        for level in 1...3 {
            let s = hitScene()
            s.playTreeHit(by: "a", direction: .right, level: level, drop: nil)
            let hold = PlazaTree.contactAt + PlazaTree.hitStop[level - 1]
            run(s, from: 1.0 / 60, seconds: hold + 0.03)
            XCTAssertEqual(s.treeLeafCount, PlazaTree.leaves[level - 1], "level \(level)")
        }
        let s = hitScene()
        s.playTreeHit(by: "a", direction: .right, level: 3, drop: nil)
        var t = run(s, from: 1.0 / 60, seconds: 0.4)
        XCTAssertEqual(s.treeLeafCount, 8)
        s.playTreeHit(by: "b", direction: .left, level: 3, drop: nil)
        t = run(s, from: t, seconds: 0.4)
        XCTAssertLessThanOrEqual(s.treeLeafCount, PlazaTree.maxFallingLeaves)
        XCTAssertGreaterThan(s.treeLeafCount, 8)
    }

    func testTheDropFallsToTheTacklersFeetAndSparklesOnce() async throws {
        let s = hitScene()
        let foot = s.walker.footPoint
        s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        let start = PlazaTree.itemStart(artRect: try XCTUnwrap(PlazaTree.artRect(in: map)), tacklerFoot: foot)
        var positions: [CGPoint] = [], jumps = 0, previous = 0
        run(s, from: 1.0 / 60, seconds: 1.6) { _ in
            if let p = s.treeItemPosition { positions.append(p) }
            if s.sparkleCount > previous { jumps += 1; XCTAssertEqual(s.sparkleCount - previous, 7, "one sparkle burst") }
            previous = s.sparkleCount
        }
        XCTAssertEqual(jumps, 1, "exactly one sparkle for the landing")
        let first = try XCTUnwrap(positions.first), last = try XCTUnwrap(positions.last)
        XCTAssertLessThan(first.y, foot.y - 40, "it starts in the canopy above the tackler: \(first) vs \(start)")
        XCTAssertEqual(last.x, foot.x, accuracy: 0.6)
        XCTAssertLessThanOrEqual(last.y, foot.y + 0.6)
        XCTAssertTrue(positions.contains { abs($0.x - foot.x) < 0.6 && abs($0.y - foot.y) < 0.6 }, "it reached the feet")
        XCTAssertNil(s.treeItemPosition, "hidden after the bounce")
        // A second hit 0.2 s into a fall restarts it: only its own landing sparkles.
        let s2 = hitScene()
        s2.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        var t = run(s2, from: 1.0 / 60, seconds: PlazaTree.contactAt + PlazaTree.hitStop[2] + PlazaTree.itemDelay + 0.2)
        s2.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        var burst = 0, last2 = 0
        t = run(s2, from: t, seconds: 1.6) { _ in
            if s2.sparkleCount > last2 { burst += 1 }
            last2 = s2.sparkleCount
        }
        XCTAssertEqual(burst, 1, "the cancelled fall never sparkled")
    }

    func testOnlyMyDropKicksTheCamera() async throws {
        let s = hitScene()
        let rest = s.cameraPosition, view = s.visibleWorldRect
        s.playTreeHit(by: nil, direction: .right, level: 3, drop: .mint)
        var atKick: CGPoint?, after: CGPoint?
        run(s, from: 1.0 / 60, seconds: 0.3, step: 1.0 / 120) { dt in
            XCTAssertEqual(s.visibleWorldRect, view, "culling and the photo do not move")
            if abs(dt - (PlazaTree.contactAt + 0.04)) < 0.003 { atKick = s.cameraPosition }
            if dt > PlazaTree.contactAt + PlazaTree.cameraKickDuration + 0.01 { after = s.cameraPosition }
        }
        let kick = try XCTUnwrap(atKick)
        XCTAssertEqual(kick.x - rest.x, 2, accuracy: 0.001, "2 px in the hit direction")
        XCTAssertEqual(kick.y, rest.y, accuracy: 0.001)
        XCTAssertEqual(after, rest, "and back")
        XCTAssertEqual(s.cameraKickOffset, .zero)
        // Every direction kicks the same way: along the hit (scene y points up).
        for (d, expect) in [(PlazaDirection.left, CGPoint(x: -2, y: 0)), (.up, CGPoint(x: 0, y: 2)), (.down, CGPoint(x: 0, y: -2))] {
            let q = hitScene()
            q.playTreeHit(by: nil, direction: d, level: 3, drop: .mint)
            var seen = CGPoint.zero
            run(q, from: 1.0 / 60, seconds: 0.3, step: 1.0 / 120) { _ in if abs(q.cameraKickOffset.x) + abs(q.cameraKickOffset.y) > abs(seen.x) + abs(seen.y) { seen = q.cameraKickOffset } }
            XCTAssertEqual(seen, expect, "\(d)")
        }
        // A teammate's level 3 and my own level 2 never kick.
        for (by, level) in [("a" as String?, 3), (nil, 2), (nil, 1)] {
            let q = hitScene()
            q.playTreeHit(by: by, direction: .right, level: level, drop: level == 3 ? .mint : nil)
            run(q, from: 1.0 / 60, seconds: 0.4, step: 1.0 / 120) { _ in XCTAssertEqual(q.cameraKickOffset, .zero) }
        }
    }

    func testWithTheBackgroundHiddenOnlyTheTacklerAndTheStarPlay() async throws {
        let s = hitScene()
        s.setBackgroundHidden(true)
        s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        var lunged = false, star = false, item = false
        run(s, from: 1.0 / 60, seconds: 0.5) { _ in
            if s.lungeOffset(memberID: nil) != .zero { lunged = true }
            if s.treeLayer?.isImpactShown == true { star = true }
            if s.treeItemPosition != nil { item = true }
            XCTAssertFalse(s.isTreeShown)
        }
        XCTAssertTrue(lunged); XCTAssertTrue(star); XCTAssertTrue(item)
    }

    func testThePhotoFollowsTheBend() async throws {
        let s = hitScene()
        s.zoom = 1
        let rest = try XCTUnwrap(s.photoInput()).props.filter { $0.baseY == 352 }.map(\.particle.origin.x)
        XCTAssertEqual(rest.count, 4)
        s.playTreeHit(by: "a", direction: .right, level: 3, drop: nil)
        run(s, from: 1.0 / 60, seconds: 0.25)
        let props = try XCTUnwrap(s.photoInput()).props.filter { $0.baseY == 352 }
        let bands = props.prefix(4).map(\.particle.origin.x)
        XCTAssertEqual(zip(bands, rest).map { $0 - $1 }, s.treeBandOffsets, "the photo's bands carry the offsets of the screen")
        XCTAssertEqual(props.count, 4 + s.treeLeafCount, "shown leaves are props too")
        XCTAssertGreaterThan(s.treeLeafCount, 0)
    }
}
