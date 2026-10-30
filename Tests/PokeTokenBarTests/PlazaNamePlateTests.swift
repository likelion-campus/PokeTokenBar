import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaNamePlateTests: XCTestCase {
    func testWidthGrowsWithTextAndScale() {
        let short = PlazaNamePlate.image(text: "나", scale: 2)
        let long = PlazaNamePlate.image(text: "도토리도토리", scale: 2)
        XCTAssertGreaterThan(long.width, short.width)
        let oneX = PlazaNamePlate.image(text: "도토리도토리", scale: 1)
        XCTAssertLessThanOrEqual(abs(long.width - 2 * oneX.width), 2)
        XCTAssertLessThanOrEqual(abs(long.height - 2 * oneX.height), 2)
    }

    func testPlainTextHasShadowAndNoPlate() {
        let image = PlazaNamePlate.image(text: "도토리", scale: 2)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func rgba(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * image.width + x) * 4; return Array(data[i..<i + 4]) }
        for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
            XCTAssertEqual(rgba(x, y)[3], 0, "corner (\(x),\(y)) must be transparent: no plate")
        }
        var white = 0, translucentDark = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let p = rgba(x, y)
            if p == [255, 255, 255, 255] { white += 1 }
            if p[3] > 0 && p[3] < 200 && p[0] < 40 { translucentDark += 1 }
        } }
        XCTAssertGreaterThan(white, 10, "white text pixels")
        XCTAssertGreaterThan(translucentDark, 10, "soft dark shadow pixels")
    }

    func testNameFontIs14() {
        XCTAssertEqual(PlazaNamePlate.fontSize, 14)
        let image = PlazaNamePlate.image(text: "Name", scale: 1)
        // 14pt semibold text is taller than the old 12pt plate (ascent+descent of 12pt is below 16, plus 2 * pad).
        XCTAssertGreaterThanOrEqual(image.height, 24)
    }
}
