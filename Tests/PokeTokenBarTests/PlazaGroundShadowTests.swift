import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaGroundShadowTests: XCTestCase {
    func testSizeRuleFromSpriteWidth() {
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 50).width, 30)
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 50).height, 9)
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 10).width, 14)
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 10).height, 4)
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 200).width, 80)
        XCTAssertEqual(PlazaGroundShadow.size(forSpriteWidth: 200).height, 24)
    }

    func testEllipseSizeAlphaAndCorners() {
        let image = PlazaGroundShadow.image(width: 40, height: 12)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 12)
        var data = [UInt8](repeating: 0, count: 40 * 12 * 4)
        let context = CGContext(data: &data, width: 40, height: 12, bitsPerComponent: 8, bytesPerRow: 40 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 12))
        func alpha(_ x: Int, _ y: Int) -> Int { Int(data[(y * 40 + x) * 4 + 3]) }
        XCTAssertEqual(Double(alpha(20, 6)), 0.22 * 255, accuracy: 3)
        for (x, y) in [(0, 0), (39, 0), (0, 11), (39, 11)] { XCTAssertEqual(alpha(x, y), 0) }
        let values = Set((0..<12).flatMap { y in (0..<40).map { alpha($0, y) } })
        XCTAssertEqual(values.subtracting([0]).count, 1, "crisp edge: only one non-zero alpha level, got \(values)")
    }
}
