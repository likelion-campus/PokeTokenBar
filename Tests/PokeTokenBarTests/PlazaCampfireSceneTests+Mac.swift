import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaCampfireSceneTests {

    /// The light texture holds `multiplier / 2` per ring, neutral grey outside the ellipse, laid out on the 2 px block grid.
    func testLightTextureHoldsTheRingsOnTheBlockGrid() throws {
        let scene = newScene()
        scene.now = { self.at(hour: 21) }
        scene.campfireLit = true
        scene.update(0)
        let tint = scene.daylightTint
        let image = try XCTUnwrap(scene.campfireLightImage?.cgImage)
        let radii = PlazaCampfireLight.radii(phase: 0)
        let n = PlazaCampfireLight.blockCounts(radii: radii)
        XCTAssertEqual(image.width, n.w)
        XCTAssertEqual(image.height, n.h)
        var data = [UInt8](repeating: 0, count: n.w * n.h * 4)
        let ctx = CGContext(data: &data, width: n.w, height: n.h, bitsPerComponent: 8, bytesPerRow: n.w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n.w, height: n.h))
        func texel(_ i: Int, _ j: Int) -> [Int] { (0..<3).map { Int(data[(j * n.w + i) * 4 + $0]) } }   // j = 0 is the top row
        func expected(_ mix: Double) -> [Int] {
            let m = PlazaCampfireLight.multiplier(tint: tint, mix: mix)
            return [m.r, m.g, m.b].map { Int(($0 / 2 * 255).rounded()) }
        }
        func assertTexel(_ i: Int, _ j: Int, mix: Double, _ what: String) {
            for (got, want) in zip(texel(i, j), expected(mix)) { XCTAssertEqual(got, want, accuracy: 2, what) }
        }
        let mid = n.w / 2
        assertTexel(mid, n.h / 2, mix: 1, "centre texel is ring 1")
        assertTexel(mid, n.h / 2 - 1, mix: 1, "the texel just above the centre is ring 1")
        assertTexel(0, 0, mix: 0, "the corner is outside the ellipse, so neutral")
        XCTAssertEqual(texel(0, 0), [128, 128, 128].map { $0 }, "neutral is 0.5")
        assertTexel(mid, 0, mix: PlazaCampfireLight.blockMix(i: mid, j: 0, radii: radii), "top middle follows the maths")
        XCTAssertEqual(PlazaCampfireLight.blockMix(i: mid, j: 0, radii: radii), 0.26, "top middle sits in ring 4")
        // World placement: the box is centred on the light centre, 2 world px per texel.
        let center = try XCTUnwrap(PlazaCampfireLight.center(campfireTiles: map.campfireTiles))
        let frame = scene.campfireLightFrame
        XCTAssertEqual(frame.width, CGFloat(2 * n.w))
        XCTAssertEqual(frame.height, CGFloat(2 * n.h))
        XCTAssertEqual(frame.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(map.pixelSize.height - frame.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(map.pixelSize.height - frame.maxY, center.y - CGFloat(n.h), accuracy: 0.001, "the top row is the north edge")
    }
}
