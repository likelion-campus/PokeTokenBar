import XCTest
@testable import PokeTokenBar

final class PlazaBitmapTests: XCTestCase {
    func testBitmapRowZeroIsTheTop() {
        var b = PlazaBitmap(width: 3, height: 2)
        XCTAssertEqual(b.bytes, [UInt8](repeating: 0, count: 3 * 2 * 4))
        XCTAssertEqual(b.alpha, .premultipliedLast)
        XCTAssertEqual(b.colorSpace, .sRGB)
        b[0, 0] = PlazaRGBA(r: 1, g: 2, b: 3, a: 4)
        b[2, 1] = PlazaRGBA(r: 5, g: 6, b: 7, a: 8)
        XCTAssertEqual(Array(b.bytes[0..<4]), [1, 2, 3, 4], "(0, 0) is the first pixel of the first row")
        XCTAssertEqual(Array(b.bytes[20..<24]), [5, 6, 7, 8], "(2, 1) is the last pixel of the second row")
        XCTAssertEqual(b[2, 1], PlazaRGBA(r: 5, g: 6, b: 7, a: 8))
        XCTAssertEqual(b[1, 0], PlazaRGBA(r: 0, g: 0, b: 0, a: 0))
        let filled = PlazaBitmap(width: 2, height: 2, fill: PlazaRGBA(r: 9, g: 8, b: 7, a: 255))
        XCTAssertEqual(filled.bytes, Array([[UInt8]](repeating: [9, 8, 7, 255], count: 4).joined()))
    }

    func testBitmapCropCopiesRows() {
        let b = PlazaTestImages.patterned(width: 7, height: 5)
        let c = b.cropped(to: PlazaPixelRect(x: 2, y: 1, width: 3, height: 2))
        XCTAssertEqual(c.width, 3)
        XCTAssertEqual(c.height, 2)
        for y in 0..<2 { for x in 0..<3 { XCTAssertEqual(c[x, y], b[x + 2, y + 1], "(\(x), \(y))") } }
        var skip = PlazaTestImages.patterned(width: 4, height: 4, alpha: .noneSkipLast)
        skip.colorSpace = .deviceRGB
        let kept = skip.cropped(to: PlazaPixelRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(kept.alpha, .noneSkipLast)
        XCTAssertEqual(kept.colorSpace, .deviceRGB)
    }

    /// Like `CGImage.cropping(to:)`: the rectangle is clipped to the bitmap.
    func testBitmapCropClipsToTheBitmap() {
        let b = PlazaTestImages.patterned(width: 4, height: 3)
        let c = b.cropped(to: PlazaPixelRect(x: -1, y: 2, width: 3, height: 5))
        XCTAssertEqual([c.width, c.height], [2, 1])
        XCTAssertEqual(c[0, 0], b[0, 2])
        XCTAssertEqual(c[1, 0], b[1, 2])
        let outside = b.cropped(to: PlazaPixelRect(x: 4, y: 0, width: 2, height: 2))
        XCTAssertEqual([outside.width, outside.height], [0, 2], "x is outside, rows 0…1 are inside")
        XCTAssertTrue(outside.bytes.isEmpty)
    }

    func testEqualityComparesBytesAndLayout() {
        let a = PlazaTestImages.patterned(width: 3, height: 3)
        var b = a
        XCTAssertEqual(a, b)
        b.alpha = .noneSkipLast
        XCTAssertNotEqual(a, b)
        var c = a
        c[1, 1] = PlazaRGBA(r: 0, g: 0, b: 0, a: 0)
        XCTAssertNotEqual(a, c)
    }
}
