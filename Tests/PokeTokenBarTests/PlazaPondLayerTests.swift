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
            + (2...14).map { PlazaPondArt.ring(radius: $0) }
        for image in images {
            let colours = opaqueColours(image)
            XCTAssertFalse(colours.isEmpty)
            XCTAssertTrue(colours.isSubset(of: allowed), "\(colours.subtracting(allowed))")
        }
        XCTAssertEqual(PlazaPondArt.droplet().width, 3)
        XCTAssertEqual(PlazaPondArt.droplet().height, 3)
        XCTAssertEqual(PlazaPondArt.bubble().width, 3)
        XCTAssertEqual(PlazaPondArt.swimRing().width, 12)
    }

    func testSmallAndBigSplash() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: false)
        XCTAssertEqual(layer.dropletCount, PlazaPondLayer.smallDroplets)
        XCTAssertEqual(layer.ringCount, 1)
        layer.update(dt: 0.61)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)

        layer.splash(at: tile, big: true)
        XCTAssertEqual(layer.dropletCount, PlazaPondLayer.bigDroplets)
        XCTAssertEqual(layer.ringCount, 1)
        layer.update(dt: 0.12)
        XCTAssertEqual(layer.ringCount, 2)
        layer.update(dt: 0.7)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
    }

    private var waterline: CGFloat {
        CGFloat(PlazaMapData.map.height * PlazaMap.tileSize) - PlazaWalker.footPoint(from: tile, to: tile, progress: 0).y
    }
    private var waterlineX: CGFloat { PlazaWalker.footPoint(from: tile, to: tile, progress: 0).x }

    private func visible(_ layer: PlazaPondLayer, z: CGFloat) -> [SKNode] {
        layer.children.filter { !$0.isHidden && abs($0.zPosition - z) < 0.001 }
    }

    func testBigSplashFansOutAndRises() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        layer.update(dt: 0.25)
        let drops = visible(layer, z: 2.5)
        XCTAssertEqual(drops.count, PlazaPondLayer.bigDroplets)
        let ys = drops.map(\.position.y), xs = drops.map(\.position.x)
        XCTAssertGreaterThanOrEqual(ys.max()! - ys.min()!, 30)
        XCTAssertGreaterThanOrEqual(ys.max()! - waterline, 50, "the top droplet clears the sprite's face")
        XCTAssertGreaterThanOrEqual(xs.max()! - xs.min()!, 30)
        XCTAssertGreaterThanOrEqual(Set(ys).count, 5)
        layer.update(dt: 0.26)
        XCTAssertEqual(layer.dropletCount, 0)
    }

    func testSmallSplashStaysLowerThanABigOne() {
        func top(big: Bool) -> CGFloat {
            let layer = PlazaPondLayer()
            layer.splash(at: tile, big: big)
            layer.update(dt: 0.25)
            return visible(layer, z: 2.5).map(\.position.y).max()! - waterline
        }
        XCTAssertLessThan(top(big: false), top(big: true) - 20)
        XCTAssertLessThanOrEqual(top(big: false), 24)
    }

    func testRingsSitOnTheWaterlineAndGrow() {
        func width(big: Bool) -> (y: CGFloat, w: CGFloat) {
            let layer = PlazaPondLayer()
            layer.splash(at: tile, big: big)
            layer.update(dt: 0.5)   // late in a 0.6 s life
            let ring = visible(layer, z: 0.06).first as! SKSpriteNode
            return (ring.position.y, ring.size.width)
        }
        let big = width(big: true), small = width(big: false)
        XCTAssertEqual(big.y, waterline, accuracy: 2)
        XCTAssertEqual(small.y, waterline, accuracy: 2)
        XCTAssertGreaterThan(big.w, 40)
        XCTAssertLessThan(small.w, 32)
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        XCTAssertEqual((visible(layer, z: 0.06).first as! SKSpriteNode).position.x, waterlineX, accuracy: 2)
    }

    func testDropletNodesAreSixWorldPixels() {
        let layer = PlazaPondLayer()
        layer.splash(at: tile, big: true)
        layer.update(dt: 1)
        layer.splash(at: tile, big: false)   // reused nodes
        let sizes = visible(layer, z: 2.5).map { ($0 as! SKSpriteNode).size }
        XCTAssertEqual(sizes.count, PlazaPondLayer.smallDroplets)
        XCTAssertTrue(sizes.allSatisfy { $0 == CGSize(width: 6, height: 6) })
    }

    func testBubblesRiseAndFade() {
        let layer = PlazaPondLayer()
        for _ in 0..<3 { layer.bubble(at: tile) }
        XCTAssertEqual(layer.bubbleCount, 3)
        let nodes = visible(layer, z: 2.4)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertGreaterThan(nodes[0].zPosition, 2)
        XCTAssertEqual(Set(nodes.map(\.position.x)).count, 3, "bubbles do not stack in one column")
        let startY = nodes.map(\.position.y), startAlpha = nodes.map(\.alpha)
        layer.update(dt: 0.3)
        for (i, n) in nodes.enumerated() {
            XCTAssertGreaterThan(n.position.y, startY[i])
            XCTAssertLessThan(n.alpha, startAlpha[i])
        }
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
        layer.bubble(at: tile)
        XCTAssertEqual(layer.pendingCount, 1)
        layer.setHidden(true)
        XCTAssertEqual(layer.pendingCount, 0)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
        XCTAssertEqual(layer.bubbleCount, 0)
        layer.splash(at: tile, big: true)
        layer.bubble(at: tile)
        layer.update(dt: 2)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.bubbleCount, 0)
        layer.setHidden(false)
        layer.update(dt: 2)   // the queued ring dropped at hide must not come back
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
        layer.splash(at: tile, big: false)
        XCTAssertEqual(layer.dropletCount, PlazaPondLayer.smallDroplets)
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

    func testQueuedSplashesAreBoundedWholeAndDrain() {
        let layer = PlazaPondLayer()
        for _ in 0..<100 { layer.splash(at: tile, big: true) }
        XCTAssertLessThanOrEqual(layer.pendingCount, PlazaPondLayer.maxPending)
        for _ in 0..<22 {   // ~1.5 s
            layer.update(dt: 0.07)
            XCTAssertLessThanOrEqual(layer.dropletCount, PlazaPondLayer.maxDroplets)
            XCTAssertLessThanOrEqual(layer.ringCount, PlazaPondLayer.maxRings)
            XCTAssertLessThanOrEqual(layer.pendingCount, PlazaPondLayer.maxPending)
        }
        XCTAssertEqual(layer.pendingCount, 0)
        XCTAssertEqual(layer.dropletCount, 0)
        XCTAssertEqual(layer.ringCount, 0)
    }

    func testWetImageHasContentAtBothScales() {
        for scale in [CGFloat(1), 2] {
            let image = PlazaPondArt.wetImage(scale: scale)
            XCTAssertEqual(image.width, Int(16 * scale))
            XCTAssertEqual(image.height, Int(16 * scale))
            XCTAssertTrue(hasAnyAlpha(image))
        }
    }

    private func hasAnyAlpha(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 }
    }
}
