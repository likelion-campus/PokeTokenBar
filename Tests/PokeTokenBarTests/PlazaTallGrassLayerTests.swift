import XCTest
import SpriteKit
@testable import PokeTokenBar

@MainActor
final class PlazaTallGrassLayerTests: XCTestCase {
    private let map = PlazaMapData.map
    private var H: CGFloat { CGFloat(map.height * PlazaMap.tileSize) }
    private let a = TilePoint(x: 6, y: 6)

    private func makeLayer() throws -> PlazaTallGrassLayer {
        PlazaTallGrassLayer(map: map, art: try XCTUnwrap(PlazaTallGrassArt.load()))
    }

    private func cue(_ kind: PlazaRustleKind, strong: Bool = true, delay: TimeInterval = 0, at t: TilePoint? = nil) -> PlazaRustleCue {
        PlazaRustleCue(tile: t ?? a, kind: kind, strong: strong, delay: delay)
    }

    func testOneBandPerGrassTileBetweenItsRowAndTheNext() throws {
        let layer = try makeLayer()
        XCTAssertEqual(layer.bandCount, 111)
        let z = try XCTUnwrap(layer.bandZ(at: a))
        XCTAssertGreaterThan(z, 1 + (6 * 32 + 28) / H)
        XCTAssertLessThan(z, 1 + (7 * 32 + 28) / H)
    }

    func testSwayLeansTheTipsThenSpringsBack() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.sway(1)))
        layer.update(dt: 0.05)
        XCTAssertEqual(layer.overlayOffset(at: a), CGPoint(x: 2, y: 0))
        layer.update(dt: 0.1)
        XCTAssertEqual(layer.overlayOffset(at: a), CGPoint(x: -2, y: 0))
        XCTAssertEqual(layer.bandOffset(at: a), .zero)
        layer.update(dt: 0.1)
        XCTAssertEqual(layer.overlayOffset(at: a), CGPoint(x: 0, y: 0))
        layer.update(dt: 0.1)
        XCTAssertNil(layer.overlayOffset(at: a))
        XCTAssertTrue(layer.activeRustles.isEmpty)
        XCTAssertEqual(layer.bandOffset(at: a), .zero)
    }

    func testBounceLiftsTheTileAndItsBand() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.bounce))
        layer.update(dt: 0.05)
        XCTAssertEqual(layer.overlayOffset(at: a), CGPoint(x: 0, y: 2))
        XCTAssertEqual(layer.bandOffset(at: a), CGPoint(x: 0, y: 2))
        layer.update(dt: 0.15)
        XCTAssertNil(layer.overlayOffset(at: a))
        XCTAssertEqual(layer.bandOffset(at: a), .zero)
    }

    func testDelayedCueStartsLater() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.sway(1), strong: false, delay: 0.05))
        layer.update(dt: 0.03)
        XCTAssertTrue(layer.activeRustles.isEmpty)
        layer.update(dt: 0.03)
        XCTAssertEqual(layer.activeRustles.count, 1)
    }

    func testAStrongRustleThrowsThreeLeavesThatSettle() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.sway(1)))
        layer.update(dt: 0.01)
        XCTAssertEqual(layer.leafCount, 3)
        layer.update(dt: 0.6)
        XCTAssertEqual(layer.leafCount, 0)
        layer.rustle(cue(.sway(1), strong: false))
        layer.update(dt: 0.01)
        XCTAssertEqual(layer.leafCount, 0)
    }

    func testRunningAcrossGrassStaysUnderTheCaps() throws {
        let layer = try makeLayer()
        var tiles: [TilePoint] = []
        for y in 0..<map.height { for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .tallGrass { tiles.append(TilePoint(x: x, y: y)) } }
        XCTAssertGreaterThanOrEqual(tiles.count, 40)
        for t in tiles.prefix(40) {
            layer.rustle(cue(.sway(1), at: t))
            layer.update(dt: 0.075)
            XCTAssertLessThanOrEqual(layer.activeRustles.count, PlazaTallGrassLayer.maxRustles)
            XCTAssertLessThanOrEqual(layer.leafCount, PlazaTallGrassLayer.maxLeaves)
        }
        layer.update(dt: 1)
        XCTAssertEqual(layer.activeRustles.count, 0)
        XCTAssertEqual(layer.leafCount, 0)
        XCTAssertTrue(tiles.allSatisfy { layer.overlayOffset(at: $0) == nil })
    }

    func testBurstOverTheRustleCapEndsTheOldestAndRestoresItsBand() throws {
        let layer = try makeLayer()
        var tiles: [TilePoint] = []
        for y in 0..<map.height { for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .tallGrass { tiles.append(TilePoint(x: x, y: y)) } }
        let n = PlazaTallGrassLayer.maxRustles + 6
        for t in tiles.prefix(n) { layer.rustle(cue(.bounce, at: t)) }
        layer.update(dt: 0.01)
        XCTAssertEqual(layer.activeRustles.count, PlazaTallGrassLayer.maxRustles)
        XCTAssertLessThanOrEqual(layer.leafCount, PlazaTallGrassLayer.maxLeaves)
        XCTAssertNil(layer.overlayOffset(at: tiles[0]))
        XCTAssertEqual(layer.bandOffset(at: tiles[0]), .zero)
        XCTAssertNotNil(layer.overlayOffset(at: tiles[n - 1]))
    }

    func testFinishedOverlaysAndLeavesAreReusedNotRebuilt() throws {
        let layer = try makeLayer()
        for _ in 0..<50 {
            layer.rustle(cue(.sway(1)))
            layer.update(dt: 0.7)
        }
        XCTAssertEqual(layer.children.count, layer.bandCount + 1 + 3)
    }

    func testHidingDropsEverything() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.bounce))
        layer.rustle(cue(.sway(1), delay: 0.5, at: TilePoint(x: 7, y: 6)))
        layer.update(dt: 0.05)
        layer.setHidden(true)
        XCTAssertTrue(layer.activeRustles.isEmpty)
        XCTAssertEqual(layer.leafCount, 0)
        XCTAssertFalse(layer.isGrass(a))
        XCTAssertTrue(layer.children.filter { $0.zPosition >= 1 && $0.zPosition < 2 }.allSatisfy(\.isHidden))
        layer.rustle(cue(.bounce))
        layer.update(dt: 1)
        XCTAssertTrue(layer.activeRustles.isEmpty)
        layer.setHidden(false)
        XCTAssertTrue(layer.isGrass(a))
        XCTAssertTrue(layer.children.filter { $0.zPosition >= 1 && $0.zPosition < 2 }.allSatisfy { !$0.isHidden })
        XCTAssertEqual(layer.bandOffset(at: a), .zero)
        XCTAssertNil(layer.overlayOffset(at: a))
        layer.update(dt: 1)
        XCTAssertTrue(layer.activeRustles.isEmpty)
    }

    func testCuesOffTheGrassAreIgnored() throws {
        let layer = try makeLayer()
        layer.rustle(cue(.bounce, at: TilePoint(x: 0, y: 0)))
        layer.update(dt: 0.05)
        XCTAssertTrue(layer.activeRustles.isEmpty)
        XCTAssertEqual(layer.leafCount, 0)
        XCTAssertNil(layer.overlayOffset(at: TilePoint(x: 0, y: 0)))
    }
}
