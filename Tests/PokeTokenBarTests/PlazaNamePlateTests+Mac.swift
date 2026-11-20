import XCTest
import AppKit
import CoreGraphics
@testable import PokeTokenBar

extension PlazaNamePlateTests {

    private func pixels(_ plaza: PlazaImage) -> [UInt8] {
        let image = plaza.cgImage
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// 글자 채움(순수한 빨강) 픽셀의 x 범위. `rows`는 위에서부터 센 줄이다.
    private func fillSpan(_ image: PlazaImage, rows: Range<Int>) -> ClosedRange<Int>? {
        let data = pixels(image)
        var low: Int?, high: Int?
        for y in rows {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if data[i] == 255, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 255 {
                    low = min(low ?? x, x); high = max(high ?? x, x)
                }
            }
        }
        guard let low, let high else { return nil }
        return low...high
    }

    func testTitleLeavesTheNameWhereItWas() throws {
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "아주긴닉네임입니다요", color: red, scale: 2))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "아주긴닉네임입니다요", title: "수줍은", color: red, scale: 2))
        XCTAssertEqual(titled.width, plain.width, "a narrower title does not widen the plate")
        XCTAssertGreaterThan(titled.height, plain.height)
        // 이름표는 아래가 기준이라 아래쪽 줄이 그대로면 이름이 움직이지 않은 것이다. 위쪽은 성격의 그림자가 번진다.
        let rowBytes = plain.width * 4
        let lower = plain.height / 2
        XCTAssertEqual(Array(pixels(titled).suffix(lower * rowBytes)), Array(pixels(plain).suffix(lower * rowBytes)))
    }

    func testTitleDrawsAboveTheNameInTheNameColour() throws {
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "나", color: red, scale: 2))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "나", title: "수줍은", color: red, scale: 2))
        XCTAssertNotNil(fillSpan(titled, rows: 0..<(titled.height - plain.height + 6)))
    }

    func testAWideTitleCentresBothLines() throws {
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "나", color: red, scale: 2))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "나", title: "무사태평한", color: red, scale: 2))
        XCTAssertGreaterThan(titled.width, plain.width)
        let split = titled.height - plain.height
        let top = try XCTUnwrap(fillSpan(titled, rows: 0..<split))
        let bottom = try XCTUnwrap(fillSpan(titled, rows: (split + 12)..<titled.height))
        for span in [top, bottom] {
            XCTAssertEqual(Double(span.lowerBound + span.upperBound) / 2, Double(titled.width) / 2, accuracy: 6)
        }
    }

    func testANarrowTitleSitsCentredOverTheName() throws {
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "아주긴닉네임입니다요", color: red, scale: 2))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "아주긴닉네임입니다요", title: "수줍은", color: red, scale: 2))
        let title = try XCTUnwrap(fillSpan(titled, rows: 0..<(titled.height - plain.height)))
        XCTAssertEqual(Double(title.lowerBound + title.upperBound) / 2, Double(titled.width) / 2, accuracy: 6)
    }

    func testTheTitleIsSmallerThanTheName() throws {
        let plain = try XCTUnwrap(PlazaNamePlate.image(text: "수줍은수줍은", color: red, scale: 2))
        let titled = try XCTUnwrap(PlazaNamePlate.image(text: "수줍은수줍은", title: "수줍은수줍은", color: red, scale: 2))
        let split = titled.height - plain.height
        let title = try XCTUnwrap(fillSpan(titled, rows: 0..<split))
        let name = try XCTUnwrap(fillSpan(titled, rows: (split + 12)..<titled.height))
        XCTAssertLessThan(title.count, name.count * 9 / 10)
    }

    func testPlateUsesRequestedFillColorAndDarkOutline() throws {
        let red = PlazaColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), blue = PlazaColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let a = try XCTUnwrap(PlazaNamePlate.image(text: "도토리", color: red, scale: 2))
        let b = try XCTUnwrap(PlazaNamePlate.image(text: "도토리", color: blue, scale: 2))
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

    func testPlainTextHasShadowAndNoPlate() throws {
        let image = try XCTUnwrap(PlazaNamePlate.image(text: "도토리", color: white, scale: 2))
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
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

    func testNameFontIs15Bold() throws {
        XCTAssertEqual(PlazaNamePlate.fontSize, 15)
        let image = try XCTUnwrap(PlazaNamePlate.image(text: "Name", color: white, scale: 1))
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
