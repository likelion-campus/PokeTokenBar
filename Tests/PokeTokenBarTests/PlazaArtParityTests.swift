import SpriteKit
import XCTest
@testable import PokeTokenBar

/// Legacy oracles (D5): the converted art builders give the Mac the very bytes the old builders gave it.
final class PlazaArtParityTests: XCTestCase {
    /// Every shadow size the size rule can produce (widths 20…140, even), plus odd and extreme sizes it does not.
    func testGroundShadowIsByteIdentical() {
        var sizes = Set<[Int]>()
        for spriteWidth in 0...260 {
            let s = PlazaGroundShadow.size(forSpriteWidth: spriteWidth)
            sizes.insert([s.width, s.height])
        }
        XCTAssertEqual(sizes.map { $0[0] }.min(), 20)
        XCTAssertEqual(sizes.map { $0[0] }.max(), 140)
        sizes.formUnion([[21, 7], [1, 1], [3, 9], [141, 46], [Int(PlazaSnowball.shadowSize.width), Int(PlazaSnowball.shadowSize.height)]])
        for s in sizes.sorted(by: { ($0[0], $0[1]) < ($1[0], $1[1]) }) {
            PlazaArtParity.assertIdentical(LegacyPlazaGroundShadow.image(width: s[0], height: s[1]),
                                           PlazaGroundShadow.image(width: s[0], height: s[1]), "shadow \(s[0])x\(s[1])")
        }
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 75).width, LegacyPlazaGroundShadow.size(forSpriteWidth: 75).width)
    }

    func testPondArtIsByteIdentical() {
        PlazaArtParity.assertIdentical(LegacyPlazaPondArt.droplet(), PlazaPondArt.droplet(), "droplet")
        PlazaArtParity.assertIdentical(LegacyPlazaPondArt.bubble(), PlazaPondArt.bubble(), "bubble")
        PlazaArtParity.assertIdentical(LegacyPlazaPondArt.swimRing(), PlazaPondArt.swimRing(), "swimRing")
        // ring(radius:) clamps below 2; the layer asks for 2…12 (PlazaPondLayer.ringFromRadius … toRadius).
        for radius in 0...14 {
            PlazaArtParity.assertIdentical(LegacyPlazaPondArt.ring(radius: radius), PlazaPondArt.ring(radius: radius), "ring \(radius)")
        }
        for scale in [CGFloat(1), 2, 3, 4] {
            PlazaArtParity.assertIdentical(LegacyPlazaPondArt.wetImage(scale: scale), PlazaPondArt.wetImage(scale: scale),
                                           "wetImage @\(scale)")
        }
    }

    /// The water tint: `waterColor.skColor` (ghost sprite) and the photo's `CGColor` carry the legacy components.
    func testWaterColorKeepsItsComponents() throws {
        let legacy = try XCTUnwrap(LegacyPlazaPondArt.waterColor.usingColorSpace(.sRGB))
        let new = try XCTUnwrap(PlazaPondArt.waterColor.skColor.usingColorSpace(.sRGB))
        XCTAssertEqual([new.redComponent, new.greenComponent, new.blueComponent, new.alphaComponent],
                       [legacy.redComponent, legacy.greenComponent, legacy.blueComponent, legacy.alphaComponent])
        XCTAssertEqual(LegacyPlazaPondArt.waterColor.redComponent, PlazaPondArt.waterColor.red)
        XCTAssertEqual(LegacyPlazaPondArt.waterColor.greenComponent, PlazaPondArt.waterColor.green)
        XCTAssertEqual(LegacyPlazaPondArt.waterColor.blueComponent, PlazaPondArt.waterColor.blue)
        XCTAssertEqual(LegacyPlazaPondArt.waterColor.alphaComponent, PlazaPondArt.waterColor.alpha)
        XCTAssertEqual(PlazaPondArt.submergedBlend, LegacyPlazaPondArt.submergedBlend)
        XCTAssertEqual(PlazaPondArt.submergedAlpha, LegacyPlazaPondArt.submergedAlpha)
        XCTAssertEqual(PlazaPondArt.submergedEggAlpha, LegacyPlazaPondArt.submergedEggAlpha)
    }

    /// The parity check itself notices a one-byte change and a format change.
    func testParityNoticesOneByteAndTheFormat() {
        let a = Array(repeating: UInt8(7), count: 32)
        var b = a
        b[13] = 8
        XCTAssertEqual(PlazaArtParity.firstDifference(a, b, bytesPerRow: 16),
                       "1 bytes differ; first at pixel (3, 0) channel g: legacy 7, new 8")
        XCTAssertNil(PlazaArtParity.firstDifference(a, a, bytesPerRow: 16))
        var premultiplied = PlazaBitmap(width: 2, height: 2)
        premultiplied[0, 0] = PlazaRGBA(r: 1, g: 2, b: 3, a: 255)
        var skip = premultiplied
        skip.alpha = .noneSkipLast
        XCTAssertNotEqual(PlazaArtParity.describe(PlazaImage(bitmap: premultiplied).cgImage),
                          PlazaArtParity.describe(PlazaImage(bitmap: skip).cgImage))
    }
}
