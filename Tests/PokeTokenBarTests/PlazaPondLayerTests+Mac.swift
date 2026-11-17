import CoreGraphics
import XCTest
@testable import PokeTokenBar

/// The 💧 image is drawn by the platform's text engine (Apple Color Emoji); the Windows stub draws nothing until stage 6.
extension PlazaPondLayerTests {
    func testWetImageHasContentAtBothScales() {
        for scale in [CGFloat(1), 2] {
            let image = PlazaPondArt.wetImage(scale: scale)
            XCTAssertEqual(image.width, Int(16 * scale))
            XCTAssertEqual(image.height, Int(16 * scale))
            XCTAssertTrue(hasAnyAlpha(image.cgImage))
        }
    }

    private func hasAnyAlpha(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 }
    }
}
