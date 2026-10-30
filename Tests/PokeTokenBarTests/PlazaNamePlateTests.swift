import AppKit
import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaNamePlateTests: XCTestCase {
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testPlateUsesRequestedFillColorAndDarkOutline() {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let a = PlazaNamePlate.image(text: "도토리", color: red, scale: 2)
        let b = PlazaNamePlate.image(text: "도토리", color: blue, scale: 2)
        let pa = pixels(a), pb = pixels(b)
        XCTAssertNotEqual(pa, pb)
        var fillRed = 0, fillBlue = 0, outline = 0, fillLeft = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            if pa[i] == 255 && pa[i + 1] == 0 && pa[i + 2] == 0 && pa[i + 3] == 255 && (i / 4) % a.width < a.width / 2 { fillLeft += 1 }
            if pa[i] == 255 && pa[i + 1] == 0 && pa[i + 2] == 0 && pa[i + 3] == 255 { fillRed += 1 }
            if pb[i] == 0 && pb[i + 1] == 0 && pb[i + 2] == 255 && pb[i + 3] == 255 { fillBlue += 1 }
            // #14161F outline, opaque
            if abs(Int(pa[i]) - 0x14) < 8 && abs(Int(pa[i + 1]) - 0x16) < 8 && abs(Int(pa[i + 2]) - 0x1F) < 8 && pa[i + 3] == 255 { outline += 1 }
        }
        XCTAssertGreaterThan(fillRed, 10); XCTAssertGreaterThan(fillBlue, 10); XCTAssertGreaterThan(outline, 20)
        XCTAssertGreaterThan(fillLeft, 10, "fill must sit on the glyphs, not shifted off them")
        for (x, y) in [(0, 0), (a.width - 1, 0), (0, a.height - 1), (a.width - 1, a.height - 1)] {
            XCTAssertEqual(pa[(y * a.width + x) * 4 + 3], 0, "corner must be transparent")
        }
    }
    func testWidthGrowsWithTextAndScale() {
        let short = PlazaNamePlate.image(text: "나", color: white, scale: 2)
        let long = PlazaNamePlate.image(text: "도토리도토리", color: white, scale: 2)
        XCTAssertGreaterThan(long.width, short.width)
        let oneX = PlazaNamePlate.image(text: "도토리도토리", color: white, scale: 1)
        XCTAssertLessThanOrEqual(abs(long.width - 2 * oneX.width), 2)
        XCTAssertLessThanOrEqual(abs(long.height - 2 * oneX.height), 2)
    }

    func testPlainTextHasShadowAndNoPlate() {
        let image = PlazaNamePlate.image(text: "도토리", color: white, scale: 2)
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

    func testNameFontIs15Bold() {
        XCTAssertEqual(PlazaNamePlate.fontSize, 15)
        let image = PlazaNamePlate.image(text: "Name", color: white, scale: 1)
        let font12 = NSFont.systemFont(ofSize: 12, weight: .bold)
        let font15 = NSFont.systemFont(ofSize: 15, weight: .bold)
        let lineHeight12 = (font12.ascender - font12.descender).rounded(.up)
        let lineHeight15 = (font15.ascender - font15.descender).rounded(.up)
        XCTAssertGreaterThan(lineHeight15, lineHeight12)
        // The plate is taller than a 12 pt plate would be: line height + 2 * pad.
        XCTAssertGreaterThanOrEqual(CGFloat(image.height), lineHeight15 + 2 * PlazaNamePlate.pad - 1)
        XCTAssertGreaterThan(CGFloat(image.height), lineHeight12 + 2 * PlazaNamePlate.pad)
    }
}
