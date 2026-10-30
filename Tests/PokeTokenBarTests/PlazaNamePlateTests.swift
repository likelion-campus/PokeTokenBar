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

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}
