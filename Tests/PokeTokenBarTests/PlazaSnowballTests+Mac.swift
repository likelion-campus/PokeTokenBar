import XCTest
import CoreGraphics
@testable import PokeTokenBar

extension PlazaSnowballTests {

    func testSnowballArtUsesOnlySnowColours() {
        let allowed: Set<UInt32> = [0xF6FAFF, 0xC6DAF0, 0x8DA3BF]
        let pieces = PlazaSnowballArt.pieces().map(\.image.cgImage)
        XCTAssertEqual(PlazaSnowballArt.pieces().map(\.scale), [4, 4, 4])
        XCTAssertEqual(pieces.count, 3)
        for image in pieces {
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<(w * h) where data[i * 4 + 3] != 0 {
                XCTAssertEqual(data[i * 4 + 3], 255)
                let rgb = UInt32(data[i * 4]) << 16 | UInt32(data[i * 4 + 1]) << 8 | UInt32(data[i * 4 + 2])
                XCTAssertTrue(allowed.contains(rgb), String(rgb, radix: 16))
            }
        }
        let ball = pieces[0]
        XCTAssertEqual(ball.width, 4)
        XCTAssertEqual(ball.height, 4)
        var data = [UInt8](repeating: 0, count: 64)
        let ctx = CGContext(data: &data, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(ball, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let shade = (0..<16).filter { data[$0 * 4 + 3] == 255 && data[$0 * 4] == 0x8D && data[$0 * 4 + 1] == 0xA3 && data[$0 * 4 + 2] == 0xBF }
        XCTAssertEqual(shade.count, 5)
    }
}
