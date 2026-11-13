import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// The ice layer's drawing, alone and driven by the scene. Ponds: L (5,13) 10x3, R (32,14) 7x7, B (20,24) 3x3.
@MainActor
final class PlazaIceLayerTests: XCTestCase {
    private let map = PlazaMapData.map
    private static let turn = 9_960_000
    private var nowSeconds = Double(PlazaIceLayerTests.turn) * 180 + 60
    private var t: TimeInterval = 0
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private var L: TilePoint { p(5, 13) }
    private var R: TilePoint { p(32, 14) }
    private func brk(_ pond: TilePoint, _ turn: Int = PlazaIceLayerTests.turn) -> PlazaIceBreak { PlazaIceBreak(pond: pond, turn: turn) }

    private func layer(art: PlazaIceArt = PlazaIceArt.load(), image: CGImage? = nil) -> PlazaIceLayer {
        PlazaIceLayer(ponds: PlazaIce.ponds(in: map), art: art, mapImage: image ?? PlazaTileArt.plainGrassImage(map),
                      worldHeight: map.pixelSize.height)
    }

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
        s.setIceBreak(brk(L, Self.turn - 1))
        s.update(t)
        s.setIceBreak(brk(R), hit: hit)
    }

    func testOnlyTheFrozenPondShowsIce() {
        let l = layer()
        l.show(frozen: 1, alpha: 1, breaking: nil)
        XCTAssertEqual(l.iceAlpha(pond: 1), 1)
        XCTAssertNil(l.iceAlpha(pond: 0))
        XCTAssertNil(l.iceAlpha(pond: 2))
    }

    func testTheBreakDrawsTheTimeline() {
        let l = layer()
        let hit = p(32, 17)
        func at(_ e: TimeInterval) { l.show(frozen: nil, alpha: 1, breaking: (1, hit, e)) }
        at(0.03); XCTAssertEqual(l.shownCrackCount, 1); XCTAssertEqual(l.shownShardCount, 0)
        at(0.06); XCTAssertEqual(l.shownCrackCount, 6); XCTAssertEqual(l.shownShardCount, 0)
        at(0.12); XCTAssertEqual(l.shownCrackCount, 15); XCTAssertEqual(l.shownShardCount, 0)
        at(0.335); XCTAssertEqual(l.shownCrackCount, 49); XCTAssertEqual(l.shownShardCount, 2)
        at(0.45); XCTAssertEqual(l.shownCrackCount, 49); XCTAssertEqual(l.shownShardCount, 5)
        at(0.50); XCTAssertEqual(l.shownShardCount, 5)
        at(0.575); XCTAssertEqual(try XCTUnwrap(l.iceAlpha(pond: 1)), 0.5, accuracy: 1e-6)
        at(0.66); XCTAssertEqual(l.shownCrackCount, 0); XCTAssertEqual(l.shownShardCount, 1); XCTAssertNil(l.iceAlpha(pond: 1))
        at(0.70); XCTAssertEqual(l.shownCrackCount, 0); XCTAssertEqual(l.shownShardCount, 0)
    }

    func testBreaksReuseTheirNodes() {
        let l = layer()
        for _ in 0..<10 {
            for k in 0...14 { l.show(frozen: nil, alpha: 1, breaking: (1, p(32, 17), Double(k) * 0.05)) }
            l.show(frozen: 1, alpha: 1, breaking: nil)
        }
        XCTAssertLessThanOrEqual(l.nodeCount, 3 + 49 + 6)
    }

    func testWithoutArtTheIceStillShowsAndBreaks() {
        let l = layer(art: .none)
        l.show(frozen: 0, alpha: 1, breaking: nil)
        XCTAssertEqual(l.iceAlpha(pond: 0), 1)
        l.show(frozen: nil, alpha: 1, breaking: (1, p(32, 17), 0.45))
        XCTAssertEqual(l.shownCrackCount, 0)
        XCTAssertEqual(l.shownShardCount, 0)
        XCTAssertEqual(l.nodeCount, 3)
    }

    func testAFreezeFadesInByTheClock() {
        let s = scene()
        s.setIceBreak(brk(L))
        s.update(0)
        nowSeconds = Double(Self.turn + 1) * 180 + 0.25
        s.update(1)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: R)), 0.25, accuracy: 1e-6)
        nowSeconds += 1
        s.update(2)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: R)), 1, accuracy: 1e-6)
    }

    func testAFreezeLongAgoShowsAtFullOpacity() {
        nowSeconds = Double(Self.turn + 1) * 180 + 600
        let s = scene()
        s.setIceBreak(brk(L))
        s.update(0)
        XCTAssertEqual(try XCTUnwrap(s.iceAlpha(pondAnchor: R)), 1, accuracy: 1e-6)
    }

    func testAnIdleFrozenPondDoesNoWorkPerFrame() {
        let s = scene()
        s.setIceBreak(brk(L, Self.turn - 1))
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
        s.snowLook = { PlazaSnowLook(mapImage: plain, tallGrass: nil) }
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
