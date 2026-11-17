import XCTest
@testable import PokeTokenBar

/// The 💧 image is drawn by the platform's text engine (Apple Color Emoji on the Mac, DirectWrite on Windows).
extension PlazaPondLayerTests {
    func testWetImageHasContentAtBothScales() async {
        for scale in [CGFloat(1), 2] {
            let image = PlazaPondArt.wetImage(scale: scale)
            XCTAssertEqual(image.width, Int(16 * scale))
            XCTAssertEqual(image.height, Int(16 * scale))
            XCTAssertTrue(stride(from: 3, to: image.pixels.bytes.count, by: 4).contains { image.pixels.bytes[$0] > 0 })
        }
    }
}
