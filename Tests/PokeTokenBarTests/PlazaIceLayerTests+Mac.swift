import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// The scene-driven ice tests (they use the bundled ice art): `PlazaScene` is a SpriteKit scene until the plaza stage lands.
extension PlazaIceLayerTests {
    private func scene(start: TilePoint = PlazaMapData.map.spawn) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true, iceArt: PlazaIceArt.load())
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.now = { [unowned self] in Date(timeIntervalSince1970: self.nowSeconds) }
        t = 0
        return s
    }

    private func run(_ s: PlazaScene, _ seconds: TimeInterval) {
        let frames = Int((seconds / 0.01).rounded())
        for _ in 0..<frames { t += 0.01; s.update(t) }
    }

    /// R frozen, one frame drawn, then R breaks at `hit`.
    private func breakR(_ s: PlazaScene, hit: TilePoint) {
        s.setIceBreak(brk(L, ago: 100))
        s.update(t)
        s.setIceBreak(brk(R), hit: hit)
    }

    func testAFreezeFadesInByTheClockFromAtPlusAMinute() throws {
        let s = scene()
        s.setIceBreak(brk(L))
        s.update(0)
        XCTAssertNil(s.iceAlpha(pondAnchor: R))
        nowSeconds += 60.25
        s.update(1)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 0.25, accuracy: 1e-6)
        nowSeconds += 1
        s.update(2)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: B)), 1, accuracy: 1e-6)
    }

    func testAFreezeLongAgoShowsAtFullOpacity() throws {
        let s = scene()
        s.setIceBreak(brk(L, ago: 600))
        s.update(0)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: R)), 1, accuracy: 1e-6)
    }

    func testAnIdleFrozenPondDoesNoWorkPerFrame() {
        let s = scene()
        s.setIceBreak(brk(L, ago: 100))
        s.update(0)
        let draws = s.iceDrawCount, nodes = s.iceLayerNodeCount
        let id = s.iceTextureID(pondAnchor: R)
        for i in 1...60 { s.update(Double(i) * 0.01) }
        XCTAssertEqual(s.iceDrawCount, draws)
        XCTAssertEqual(s.iceLayerNodeCount, nodes)
        XCTAssertEqual(s.iceTextureID(pondAnchor: R), id)
        XCTAssertNotNil(id)
    }

    func testAHiddenBackgroundHidesTheIceButNotTheRules() throws {
        let s = scene()
        s.update(0)
        XCTAssertFalse(try XCTUnwrap(s.photoInput()).ice.isEmpty)
        s.setBackgroundHidden(true)
        XCTAssertTrue(try XCTUnwrap(s.photoInput()).ice.isEmpty)
        XCTAssertTrue(s.isWalkableNow(p(6, 14)))
    }

    func testANewMapPictureRebuildsTheIce() {
        nowSeconds = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!.timeIntervalSince1970
        let s = scene()
        let plain = PlazaTileArt.plainGrassImage(map)
        s.seasonLook = { _ in PlazaSnowLook(mapImage: plain, tallGrass: nil) }
        let before = layerTextureID(s)
        s.refreshSnowDay()
        XCTAssertNotEqual(layerTextureID(s), before)
    }

    private func layerTextureID(_ s: PlazaScene) -> ObjectIdentifier? { s.iceTextureID(pondAnchor: L) }

    func testTheSceneDrivesTheBreakByFrames() {
        let s = scene()
        breakR(s, hit: p(33, 17))
        run(s, 0.32)
        XCTAssertEqual(s.shownCrackCount, 49)
        XCTAssertEqual(s.shownShardCount, 2)
    }

    func testThePhotoShowsTheIceAndFadingCracksButNoShards() throws {
        let s = scene()
        s.update(0)
        let frozen = try XCTUnwrap(s.photoInput()).ice
        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].alpha, 1)
        let b = scene()
        breakR(b, hit: p(33, 17))
        run(b, 0.55)
        let ice = try XCTUnwrap(b.photoInput()).ice
        XCTAssertEqual(ice.count, 1 + 49)
        let expected = PlazaIce.iceAlpha(elapsed: 0.55)
        for particle in ice { XCTAssertEqual(particle.alpha, expected, accuracy: 0.02) }
        XCTAssertFalse(ice.contains { $0.size.width == 64 })
    }
}
