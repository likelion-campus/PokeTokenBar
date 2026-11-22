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
        // The fixture clock is KST; the scene reads the hour through Calendar.current. Pin the process zone to the fixture's, or noon here is
        // 03:00 on a UTC runner (Windows CI) and the photo gets the night tint (the snow leaf was never its own colour there).
        let pin = PlazaFixtureTime.pin()
        addTeardownBlock { pin.restore() }
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
        XCTAssertEqual(union, try XCTUnwrap(PlazaTree.artRect(of: PlazaTree.runs(in: map)[0])))
        XCTAssertEqual(layer.bandWorldRects.map(\.height), [30, 30, 30, 54])
        XCTAssertEqual(s.treeLayers.count, 2, "one layer per tree")
        XCTAssertEqual(s.treeNodeCount, 64, "per tree: two roots, four bands, twenty leaves, two dust puffs, the star, the item and two landing puffs")
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
        let art = try XCTUnwrap(PlazaTree.artRect(of: PlazaTree.runs(in: map)[0]))
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
        XCTAssertEqual(s.treeNodeCount, 64, "2 trees x (2 roots + 30 sprites), from the first frame")
        XCTAssertTrue(s.root.children.contains { $0 === layer.root } && s.root.children.contains { $0 === layer.fxRoot })
        var t = run(s, from: 1.0 / 60, seconds: 0.2)
        let others = s.root.children.count
        for i in 0..<1000 {
            s.playTreeHit(by: i % 3 == 0 ? nil : ["a", "b", "c", "d"][i % 4], direction: PlazaDirection.allCases[i % 4], level: i % 3 + 1,
                          drop: i % 5 == 0 ? .mint : nil)
            if i % 20 == 0 { t = run(s, from: t, seconds: 0.05) }
            XCTAssertEqual(s.treeNodeCount, 64)
        }
        t = run(s, from: t, seconds: 10)   // the sparkles and the star are gone, the pool is the same
        XCTAssertEqual(s.treeNodeCount, 64)
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
        let rest = layer.spriteStates, secondRest = s.treeLayers[1].spriteStates
        run(s, from: 1.0 / 60, seconds: 10)
        XCTAssertEqual(layer.spriteStates, rest, "600 idle frames: no property moved")
        XCTAssertEqual(s.treeLayers[1].spriteStates, secondRest, "the second tree writes nothing either")
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
        let layer = PlazaTreeLayer(map: map, run: PlazaTree.runs(in: map)[0], images: images, worldHeight: map.pixelSize.height)
        let art = try XCTUnwrap(PlazaTree.artRect(of: PlazaTree.runs(in: map)[0]))
        let far = CGRect(x: 1000, y: 0, width: 400, height: 300), near = CGRect(x: 400, y: 150, width: 400, height: 300)
        let rest = layer.spriteStates
        layer.hit(direction: .right, level: 2, tacklerFoot: CGPoint(x: 496, y: 348), tacklerHeight: 48, drop: nil, landing: CGPoint(x: 560, y: 380))
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
        XCTAssertEqual(peak, [12, 9, 3, 0], "at the hold: away from a hit that moves right")
        t = run(s, from: t, seconds: 1.0) { _ in XCTAssertEqual(s.treeBandOffsets.last, 0, "the trunk never moves") }
        XCTAssertEqual(s.treeBandOffsets, [0, 0, 0, 0], "settled")
        XCTAssertEqual(s.treeStretch, 1)
        s.playTreeHit(by: "b", direction: .left, level: 2, drop: nil)
        t = run(s, from: t, seconds: 0.133)
        XCTAssertEqual(s.treeBandOffsets, [-12, -9, -3, 0], ".left mirrors it")
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
        XCTAssertEqual(s.treeLeafCount, PlazaTree.leaves[2], "level 3 uses the whole pool")
        XCTAssertEqual(s.treeLeafCount, PlazaTree.maxFallingLeaves)
        s.playTreeHit(by: "b", direction: .left, level: 3, drop: nil)
        t = run(s, from: t, seconds: 0.4)
        XCTAssertEqual(s.treeLeafCount, PlazaTree.maxFallingLeaves, "a new hit recycles the pool, it never grows")
    }

    private var itemTotal: TimeInterval { PlazaTree.contactAt + PlazaTree.hitStop[2] + PlazaTree.itemDelay + PlazaTreeItemFall.length }

    /// The mint pops out of the canopy, hops to the tile two to the side of the hitter, bounces once, rests there, then comes to the hitter's feet and sparkles once.
    func testTheDropBouncesOutRestsAndComesToTheTacklersFeetAndSparklesOnce() async throws {
        let s = hitScene()
        let foot = s.walker.footPoint
        let landing = PlazaTree.footPoint(of: p(19, 11))
        s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        var positions: [CGPoint] = [], sparklesWhileInAir = 0, previous = 0, sparkleAt: TimeInterval?, goneAt: TimeInterval?
        var landDust = false
        run(s, from: 1.0 / 60, seconds: 2.6) { t in
            if let p = s.treeItemPosition { positions.append(p) } else if !positions.isEmpty, goneAt == nil { goneAt = t }
            if s.treeLayer?.shownLandDustCount ?? 0 > 0 { landDust = true }
            if s.sparkleCount > previous {
                XCTAssertEqual(s.sparkleCount - previous, 7, "one sparkle burst")
                sparkleAt = t
                if s.treeItemPosition != nil { sparklesWhileInAir += 1 }
            }
            previous = s.sparkleCount
        }
        XCTAssertNotNil(sparkleAt, "exactly one sparkle, at the pick-up")
        XCTAssertEqual(sparklesWhileInAir, 0, "no sparkle while the item is still drawn")
        XCTAssertEqual(s.sparkleCount, 7)
        XCTAssertLessThan(abs(try XCTUnwrap(sparkleAt) - itemTotal), 0.1, "the pick-up is \(itemTotal) s after the hit")
        let first = try XCTUnwrap(positions.first), last = try XCTUnwrap(positions.last)
        XCTAssertLessThan(first.y, foot.y - 40, "it starts in the canopy above the tackler: \(first)")
        XCTAssertEqual(positions.filter { abs($0.x - landing.x) < 0.6 && abs($0.y - landing.y) < 0.6 }.count, Int(PlazaTree.itemRest * 60), accuracy: 4,
                       "it rests on the landing tile for itemRest")
        XCTAssertTrue(positions.contains { $0.y < landing.y - PlazaTree.itemBounce / 2 && abs($0.x - landing.x) < 0.6 }, "and bounces on it first")
        XCTAssertTrue(positions.contains { $0.y < (first.y + landing.y) / 2 - PlazaTree.itemArc / 2 }, "the hop arcs above the straight line")
        XCTAssertLessThan(abs(last.x - foot.x), 8, "then it comes to the hitter's feet: \(last)")
        XCTAssertTrue(landDust, "the landing puffs dust")
        XCTAssertNil(s.treeItemPosition, "hidden once collected")
        XCTAssertEqual(s.treeLayer?.shownLandDustCount, 0)
    }

    /// The pick-up goes to where the hitter is when it happens, not where they stood at the hit.
    func testTheItemFollowsAHitterWhoWalksAway() async throws {
        let s = hitScene()
        s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
        var t = run(s, from: 1.0 / 60, seconds: 1.0)
        s.handleKeyDown(keyCode: 125, characters: nil, isRepeat: false)   // down
        t = run(s, from: t, seconds: 0.5)
        s.handleKeyUp(keyCode: 125)
        let end = s.walker.footPoint
        XCTAssertGreaterThan(end.y, PlazaWalker.footPoint(from: p(17, 11), to: p(17, 11), progress: 0).y + 20, "test precondition: the hitter walked south")
        var last: CGPoint?
        run(s, from: t, seconds: 1.2) { _ in if let p = s.treeItemPosition { last = p } }
        XCTAssertEqual(try XCTUnwrap(last).y, end.y, accuracy: 20, "the hop ends at the hitter's feet now")
    }

    /// Another hit restarts the shake, the leaves and the dust, but my mint's flight and its sparkle play to the end, even when a teammate's drop arrives.
    func testAnotherHitDuringMyMintsFlightDoesNotCancelIt() async throws {
        for other in [(drop: ItemKind?.none, level: 2), (.mint, 3)] {
            let s = hitScene()
            s.playTreeHit(by: nil, direction: .up, level: 3, drop: .mint)
            let t = run(s, from: 1.0 / 60, seconds: PlazaTree.contactAt + PlazaTree.hitStop[2] + PlazaTree.itemDelay + PlazaTree.itemFall + 0.3)
            let resting = try XCTUnwrap(s.treeItemPosition, "test precondition: my mint is on the ground")
            s.playTreeHit(by: "a", direction: .right, level: other.level, drop: other.drop)
            var seen: [CGPoint] = [], jumps = 0, previous = 0
            run(s, from: t, seconds: 2.0) { _ in
                if let p = s.treeItemPosition { seen.append(p) }
                if s.sparkleCount > previous { jumps += 1 }
                previous = s.sparkleCount
            }
            XCTAssertEqual(jumps, 1, "\(other): one sparkle")
            XCTAssertTrue(seen.contains { abs($0.x - resting.x) < 0.6 && abs($0.y - resting.y) < 0.6 }, "\(other): my mint kept resting where it fell")
            XCTAssertNil(s.treeItemPosition)
        }
    }

    // MARK: the second tree

    func testTheSecondTreeIsDrawnAtItsRectAndInFrontOfTheOne() async throws {
        let s = treeScene(start: p(42, 28))
        XCTAssertEqual(s.treeLayers.count, 2)
        let second = try XCTUnwrap(s.treeLayers.last)
        let union = second.bandWorldRects.dropFirst().reduce(second.bandWorldRects[0]) { $0.union($1) }
        XCTAssertEqual(union, try XCTUnwrap(PlazaTree.artRect(of: PlazaTree.runs(in: map)[1])))
        XCTAssertEqual(second.root.zPosition, 1 + 896.0 / 1024, accuracy: 1e-6)
        XCTAssertGreaterThan(second.root.zPosition, try XCTUnwrap(s.treeZ))
        s.applyMembers([member("a", 42, 24), member("b", 42, 28), member("c", 44, 26)])
        for id in ["a", "b", "c"] { s.setMemberFrames(id, solidFrames()) }
        s.update(1.0 / 60)
        XCTAssertLessThan(try XCTUnwrap(s.memberZ("a")), second.root.zPosition, "behind the trunk row")
        XCTAssertGreaterThan(try XCTUnwrap(s.memberZ("b")), second.root.zPosition, "in front of the trunk row")
    }

    /// Hitting one tree moves only that tree; the other writes nothing and stays at rest.
    func testHittingOneTreeLeavesTheOtherAtRest() async throws {
        let s = treeScene(start: p(42, 28))
        s.applyMembers([member("a", 15, 10, facing: .right), member("b", 42, 28, facing: .up)])
        for id in ["a", "b"] { s.setMemberFrames(id, solidFrames()) }
        s.update(1.0 / 60)
        let firstRest = s.treeLayers[0].spriteStates, secondRest = s.treeLayers[1].spriteStates
        s.playTreeHit(tree: 1, by: "b", direction: .up, level: 3, drop: .mint)
        run(s, from: 1.0 / 60, seconds: 0.15)
        XCTAssertGreaterThan(s.treeLayers[1].stretch, 1)
        run(s, from: 0.2, seconds: 0.4)
        XCTAssertEqual(s.treeLayers[0].spriteStates, firstRest, "the first tree did not move")
        XCTAssertFalse(s.treeLayers[0].isBusy)
        XCTAssertNotEqual(s.treeLayers[1].spriteStates, secondRest)
        XCTAssertTrue(s.treeLayers[1].isBusy)
        run(s, from: 1, seconds: 4)
        XCTAssertFalse(s.isTreeBusy)
        // And the other way round.
        s.playTreeHit(tree: 0, by: "a", direction: .right, level: 2, drop: nil)
        run(s, from: 5, seconds: 0.2)
        XCTAssertTrue(s.treeLayers[0].isBusy)
        XCTAssertFalse(s.treeLayers[1].isBusy)
    }

    func testBothTreesAreInThePhotoAndHideWithTheBackground() async throws {
        let s = treeScene(start: p(42, 28))
        s.zoom = 1
        let props = try XCTUnwrap(s.photoInput()).props
        XCTAssertEqual(props.filter { $0.baseY == 352 }.count, 4, "the first tree's four bands")
        XCTAssertEqual(props.filter { $0.baseY == 896 }.count, 4, "the second tree's four bands")
        s.setBackgroundHidden(true)
        XCTAssertFalse(s.isTreeShown)
        XCTAssertEqual(s.photoInput()?.props.filter { $0.baseY == 352 || $0.baseY == 896 }.count, 0)
        s.setBackgroundHidden(false)
        XCTAssertTrue(s.treeLayers.allSatisfy(\.isShown))
    }

    func testBothTreesWearTheSeason() async throws {
        let s = treeScene(season: .autumn)
        let a = s.treeLayers[0].bandImages.map { $0?.pixels.bytes }, b = s.treeLayers[1].bandImages.map { $0?.pixels.bytes }
        XCTAssertEqual(a, b, "the same pine in the same season")
        XCTAssertEqual(s.treeLayers[1].season, .autumn)
        s.seasonChoice = .winter
        XCTAssertEqual(s.treeLayers[1].season, .winter)
    }

    func testTheSecondTreesWallBlocksAndItsRowsAreReachable() async throws {
        let s = treeScene(start: p(42, 28))
        s.handleKeyDown(keyCode: 126, characters: nil, isRepeat: false)   // up
        for i in 1..<60 { s.update(Double(i) / 60) }
        s.handleKeyUp(keyCode: 126)
        XCTAssertEqual(s.walker.tile, p(42, 28), "the trunk row blocks from the south")
    }

    /// A photo taken in the middle of a bend: the bands stack without a gap or an overlap and the tree is as tall as the stretch says.
    func testTheBandRectsFollowTheStretchOnce() async throws {
        for (id, direction) in [("d", PlazaDirection.up), ("c", .down)] {
            let s = hitScene()
            let layer = try XCTUnwrap(s.treeLayer)
            let art = try XCTUnwrap(PlazaTree.artRect(of: PlazaTree.runs(in: map)[0]))
            s.playTreeHit(by: id, direction: direction, level: 3, drop: nil)
            run(s, from: 1.0 / 60, seconds: 0.15)
            XCTAssertNotEqual(s.treeStretch, 1, "test precondition: mid-bend")
            let rects = layer.bandWorldRects
            XCTAssertEqual(rects.last?.maxY ?? 0, art.maxY, accuracy: 1e-3, "the trunk base stays put")
            for (upper, lower) in zip(rects, rects.dropFirst()) { XCTAssertEqual(upper.maxY, lower.minY, accuracy: 1e-3, "\(direction): no gap, no overlap") }
            XCTAssertEqual(rects[0].minY, art.maxY - art.height * s.treeStretch, accuracy: 1e-3, "\(direction): as tall as the stretch")
            let props = try XCTUnwrap(s.photoInput()).props.filter { $0.baseY == art.maxY }.prefix(4)
            XCTAssertEqual(props.map(\.particle.size.height), rects.map(\.height), "the photo draws the same bands")
        }
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

    /// Direct2D and SpriteKit pick different texels when a nearest-neighbour sample lands exactly on a texel edge (a pixel centre on a tree-pixel
    /// boundary). At 3x the tree's pixel edges are 3 world px apart, so at a device scale of 2.5 px per world px (zoom 2, backing 1.25) every second
    /// edge is on a pixel centre: Windows CI saw 1-px seams on every such row. The layer nudges the whole tree by a sixty-fourth of a device pixel so no edge
    /// sits on a centre, in the rest pose and in a stretched one, at every zoom and backing scale.
    func testNoTreePixelEdgeSitsOnADevicePixelCentre() async throws {
        for zoom in [1, 2, 3] {
            for backing in [1.0, 1.25, 1.5, 2.0] {
                for stretched in [false, true] {
                    let s = treeScene(start: p(17, 11))
                    s.zoom = zoom
                    s.backingOverride = CGFloat(backing)
                    s.applyMembers([member("d", 17, 11, facing: .up)])
                    s.setMemberFrames("d", solidFrames())
                    if stretched { s.playTreeHit(by: "d", direction: .up, level: 3, drop: nil) }
                    run(s, from: 1.0 / 60, seconds: stretched ? 0.15 : 0.05)
                    let layer = try XCTUnwrap(s.treeLayer)
                    let view = s.visibleWorldRect
                    let k = CGFloat(zoom) * CGFloat(backing)
                    func centreDistance(_ v: CGFloat) -> CGFloat { abs((v * k).truncatingRemainder(dividingBy: 1) - 0.5) }
                    for r in layer.bandDrawRects {
                        let columns = Int((r.width / PlazaTree.scale).rounded()), rows = Int((r.height / (PlazaTree.scale * s.treeStretch)).rounded())
                        for c in 0...columns {
                            XCTAssertGreaterThan(centreDistance(r.minX + CGFloat(c) * r.width / CGFloat(columns) - view.minX), 0.005, "x edge \(c): zoom \(zoom) backing \(backing) stretched \(stretched)")
                        }
                        for row in 0...rows {
                            XCTAssertGreaterThan(centreDistance(r.minY + CGFloat(row) * r.height / CGFloat(rows) - view.minY), 0.005, "y edge \(row): zoom \(zoom) backing \(backing) stretched \(stretched)")
                        }
                    }
                    s.isPaused = false
                }
            }
        }
    }
}
