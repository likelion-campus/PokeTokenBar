import XCTest
@testable import PokeTokenBar

/// The ice layer's drawing, alone and driven by the scene. Ponds: L (5,13) 10x3, R (32,14) 7x7, B (20,24) 3x3.
@MainActor
final class PlazaIceLayerTests: XCTestCase {
    /// Art with the real shape (12 crack cells, 3 shard frames) and no artist pixels: the bundled files are read by the Mac loader.
    static let fixtureArt = PlazaIceArt(
        gloss: nil,
        cracks: (0..<12).map { _ in PlazaImage(bitmap: PlazaBitmap(width: 16, height: 16, fill: PlazaRGBA(r: 106, g: 151, b: 198, a: 255))) },
        shards: (0..<3).map { _ in PlazaImage(bitmap: PlazaBitmap(width: 64, height: 64, fill: PlazaRGBA(r: 216, g: 234, b: 248, a: 255))) })

    let map = PlazaMapData.map
    var nowSeconds = 1_800_000_000.0
    var t: TimeInterval = 0
    func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    var L: TilePoint { p(5, 13) }
    var R: TilePoint { p(32, 14) }
    var B: TilePoint { p(20, 24) }
    func brk(_ pond: TilePoint, ago: Double = 0) -> PlazaIceBreak { PlazaIceBreak(at: nowSeconds - ago, pond: pond) }

    func layer(art: PlazaIceArt = PlazaIceLayerTests.fixtureArt, image: PlazaImage? = nil) -> PlazaIceLayer {
        PlazaIceLayer(ponds: PlazaIce.ponds(in: map), art: art, mapImage: image ?? PlazaTileArt.plainGrassImage(map),
                      worldHeight: map.pixelSize.height)
    }

    func testOnlyTheFrozenPondShowsIce() async {
        let l = layer()
        l.show(frozen: 1, alpha: 1, breaking: nil)
        XCTAssertEqual(l.iceAlpha(pond: 1), 1)
        XCTAssertNil(l.iceAlpha(pond: 0))
        XCTAssertNil(l.iceAlpha(pond: 2))
    }

    func testTheBreakDrawsTheTimeline() async {
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

    func testBreaksReuseTheirNodes() async {
        let l = layer()
        for _ in 0..<10 {
            for k in 0...14 { l.show(frozen: nil, alpha: 1, breaking: (1, p(32, 17), Double(k) * 0.05)) }
            l.show(frozen: 1, alpha: 1, breaking: nil)
        }
        XCTAssertLessThanOrEqual(l.nodeCount, 3 + 49 + 6)
    }

    func testWithoutArtTheIceStillShowsAndBreaks() async {
        let l = layer(art: .none)
        l.show(frozen: 0, alpha: 1, breaking: nil)
        XCTAssertEqual(l.iceAlpha(pond: 0), 1)
        l.show(frozen: nil, alpha: 1, breaking: (1, p(32, 17), 0.45))
        XCTAssertEqual(l.shownCrackCount, 0)
        XCTAssertEqual(l.shownShardCount, 0)
        XCTAssertEqual(l.nodeCount, 3)
    }

    func testALayerWithoutPondsHasNoNodesAndAnswersNilForAnyPond() async {
        let l = PlazaIceLayer(ponds: [], art: PlazaIceArt.none, mapImage: PlazaTileArt.plainGrassImage(map), worldHeight: map.pixelSize.height)
        l.show(frozen: nil, alpha: 1, breaking: nil)
        XCTAssertEqual(l.nodeCount, 0)
        XCTAssertNil(l.iceAlpha(pond: 0))
        XCTAssertNil(l.iceTextureID(pond: 0))
        XCTAssertNil(layer().iceAlpha(pond: 99))
        XCTAssertNil(layer().iceTextureID(pond: 99))
    }
}
