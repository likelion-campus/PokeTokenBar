import XCTest
@testable import PokeTokenBar

final class PlazaGroundShadowTests: XCTestCase {
    func testShadowSizeRule() {
        func size(_ w: Int) -> [Int] { let r = PlazaGroundShadow.size(forSpriteWidth: w); return [r.width, r.height] }
        XCTAssertEqual(size(75), [54, 17])
        XCTAssertEqual(size(10), [20, 6])
        XCTAssertEqual(size(300), [140, 45])
    }

    func testSoftEllipseSizeAlphaAndCorners() {
        let image = PlazaGroundShadow.image(width: 40, height: 12)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 12)
        // premultiplied sRGB, row 0 at the top: what drawing it into such a context gave before
        let data = image.pixels.bytes
        func alpha(_ x: Int, _ y: Int) -> Int { Int(data[(y * 40 + x) * 4 + 3]) }
        XCTAssertEqual(Double(alpha(20, 6)), 0.30 * 255, accuracy: 3)
        for (x, y) in [(0, 0), (39, 0), (0, 11), (39, 11)] { XCTAssertEqual(alpha(x, y), 0) }
        // Stepped (8-bit) falloff: never rises toward the edge, and clearly drops every few pixels.
        for x in 20..<39 { XCTAssertLessThanOrEqual(alpha(x + 1, 6), alpha(x, 6), "alpha must not rise toward the edge at x=\(x)") }
        for x in stride(from: 20, to: 36, by: 4) { XCTAssertLessThan(alpha(x + 4, 6), alpha(x, 6), "alpha must fall from x=\(x)") }
        XCTAssertEqual(Int(data[(6 * 40 + 20) * 4]), 0, "premultiplied black")
    }
}
