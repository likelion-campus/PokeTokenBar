import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaNamePlateTests: XCTestCase {
    func testPlateGrowsWithTextAndScale() {
        let short = PlazaNamePlate.image(text: "나", isMe: true, scale: 2)
        let long = PlazaNamePlate.image(text: "도토리도토리", isMe: true, scale: 2)
        XCTAssertGreaterThan(long.width, short.width)
        let oneX = PlazaNamePlate.image(text: "도토리도토리", isMe: true, scale: 1)
        XCTAssertLessThanOrEqual(abs(long.width - 2 * oneX.width), 2)
        XCTAssertLessThanOrEqual(abs(long.height - 2 * oneX.height), 2)
    }

    func testMeAndOthersUseDifferentBorderColor() {
        let me = PlazaNamePlate.image(text: "나", isMe: true, scale: 2)
        let other = PlazaNamePlate.image(text: "나", isMe: false, scale: 2)
        // x = 1pt is inside the 2 pt left border; the vertical middle avoids the rounded corners.
        let meColor = pixel(me, x: 2, y: me.height / 2)
        let otherColor = pixel(other, x: 2, y: other.height / 2)
        XCTAssertEqual(meColor, [0xD0, 0x48, 0x48, 0xFF])
        XCTAssertEqual(otherColor, [0x58, 0x60, 0x78, 0xFF])
    }

    /// Pixel-font text must land on the pixel grid: no blended (partially covered) pixels inside the text rectangle. The interior is opaque, so "partial" means neither the plate nor the text color.
    func testTextRectangleHasNoPartiallyTransparentPixels() {
        let scale = 2
        let image = PlazaNamePlate.image(text: "도토리 ABC", isMe: true, scale: CGFloat(scale))
        let (partial, textPixels) = partiallyTransparentPixelCount(image, scale: scale)
        XCTAssertGreaterThan(textPixels, 20, "the text must actually be drawn")
        print("PLATE partial-alpha pixels in text rect: \(partial)")
        XCTAssertEqual(partial, 0)
    }

    private func partiallyTransparentPixelCount(_ image: CGImage, scale: Int) -> (blended: Int, text: Int) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Rows run top-down; the shadow strip is at the bottom, so the body starts at row 0.
        let inset = PlazaNamePlate.border + PlazaNamePlate.padX
        let insetY = PlazaNamePlate.border + PlazaNamePlate.padY
        let x0 = Int(inset) * scale, x1 = image.width - Int(inset) * scale
        let y0 = Int(insetY) * scale
        let y1 = image.height - Int(PlazaNamePlate.shadow + insetY) * scale
        var count = 0, text = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let i = (y * image.width + x) * 4
            let rgba = Array(data[i..<i + 4])
            // The plate interior is opaque, so antialiasing shows up as blended colors rather than as alpha.
            if rgba == [0x30, 0x38, 0x48, 0xFF] { text += 1 }
            let pure = rgba == [0xF8, 0xF8, 0xF0, 0xFF] || rgba == [0x30, 0x38, 0x48, 0xFF]
            if !pure { count += 1 }
        } }
        return (count, text)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}
