import XCTest
import SpriteKit
@testable import PokeTokenBar

@MainActor
final class PlazaPondLayerTests: XCTestCase {
    private let tile = TilePoint(x: 5, y: 8)

    private func opaqueColours(_ image: CGImage) -> Set<UInt32> {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var set = Set<UInt32>()
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] == 255 {
            set.insert(UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]))
        }
        return set
    }

    func testArtUsesOnlyPondColours() {
        let allowed: Set<UInt32> = [0x1E7CB8, 0x2996DB, 0x5AAEE4, 0xFFFFFF, 0x165C88]
        let images = [PlazaPondArt.droplet(), PlazaPondArt.bubble(), PlazaPondArt.swimRing()]
            + (2...7).map { PlazaPondArt.ring(radius: $0) }
        for image in images {
            let colours = opaqueColours(image)
            XCTAssertFalse(colours.isEmpty)
            XCTAssertTrue(colours.isSubset(of: allowed), "\(colours.subtracting(allowed))")
        }
        XCTAssertEqual(PlazaPondArt.droplet().width, 2)
        XCTAssertEqual(PlazaPondArt.bubble().width, 3)
        XCTAssertEqual(PlazaPondArt.swimRing().width, 12)
    }

    func testSmallAndBigSplash() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: false)
        XCTAssertEqual(layer.dropletCount, 4)
        XCTAssertEqual(layer.ringCount, 1)
        layer.update(dt: 0.61)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)

        layer.splash(at: tile, big: true)
        XCTAssertEqual(layer.dropletCount, 10)
        XCTAssertEqual(layer.ringCount, 1)
        layer.update(dt: 0.12)
        XCTAssertEqual(layer.ringCount, 2)
        layer.update(dt: 0.7)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
    }

    func testDelayedSplashStartsLater() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true, delay: 0.36)
        layer.update(dt: 0.3)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
        layer.update(dt: 0.1)
        XCTAssertEqual(layer.dropletCount, 10)
    }

    func testBubblesRiseAndFade() {
        let layer = PlazaPondLayer()
        for _ in 0..<3 { layer.bubble(at: tile) }
        XCTAssertEqual(layer.bubbleCount, 3)
        layer.update(dt: 0.7)
        XCTAssertEqual(layer.bubbleCount, 0)
    }

    func testCapsHoldUnderABurst() {
        let layer = PlazaPondLayer()
        for _ in 0..<20 { layer.splash(at: tile, big: true) }
        for _ in 0..<20 { layer.bubble(at: tile) }
        for _ in 0..<5 {
            XCTAssertLessThanOrEqual(layer.dropletCount, PlazaPondLayer.maxDroplets)
            XCTAssertLessThanOrEqual(layer.ringCount, PlazaPondLayer.maxRings)
            XCTAssertLessThanOrEqual(layer.bubbleCount, PlazaPondLayer.maxBubbles)
            layer.update(dt: 0.1)
        }
        layer.update(dt: 1)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
        XCTAssertEqual(layer.bubbleCount, 0)
    }

    func testHidingDropsEverything() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        layer.splash(at: tile, big: true, delay: 1)
        layer.bubble(at: tile)
        layer.setHidden(true)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
        XCTAssertEqual(layer.bubbleCount, 0)
        layer.splash(at: tile, big: true)
        layer.bubble(at: tile)
        layer.update(dt: 2)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.bubbleCount, 0)
        layer.setHidden(false)
        layer.update(dt: 2)   // the delayed splash dropped at hide must not come back
        XCTAssertEqual(layer.dropletCount, 0)
        layer.splash(at: tile, big: false)
        XCTAssertEqual(layer.dropletCount, 4)
    }

    func testNodesAreReused() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        layer.bubble(at: tile)
        layer.update(dt: 0.2)   // both rings are out now
        let first = layer.children.count
        layer.update(dt: 1)
        layer.splash(at: tile, big: true)
        layer.bubble(at: tile)
        layer.update(dt: 0.2)
        XCTAssertEqual(layer.children.count, first)
    }

    func testPositionsSnapToTwoPixelGrid() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        layer.bubble(at: tile)
        layer.update(dt: 0.2)
        for node in layer.children where !node.isHidden {
            XCTAssertEqual(node.position.x.truncatingRemainder(dividingBy: 2), 0)
            XCTAssertEqual(node.position.y.truncatingRemainder(dividingBy: 2), 0)
        }
    }
}
