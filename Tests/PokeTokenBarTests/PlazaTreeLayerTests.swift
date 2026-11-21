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

    private func member(_ id: String, _ x: Int, _ y: Int) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: false, tile: p(x, y), facing: .down, isWalking: false)
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
        XCTAssertEqual(s.treeNodeCount, 6, "two roots and four bands")
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
}
