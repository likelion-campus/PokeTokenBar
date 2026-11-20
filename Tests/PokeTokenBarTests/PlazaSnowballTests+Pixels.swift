import XCTest
@testable import PokeTokenBar

extension PlazaSnowballTests {

    func testSnowballArtUsesOnlySnowColours() async {
        let allowed: Set<UInt32> = [0xF6FAFF, 0xC6DAF0, 0x8DA3BF]
        let pieces = PlazaSnowballArt.pieces().map(\.image)
        XCTAssertEqual(PlazaSnowballArt.pieces().map(\.scale), [4, 4, 4])
        XCTAssertEqual(pieces.count, 3)
        for image in pieces {
            let data = image.pixels.bytes
            for i in 0..<(image.width * image.height) where data[i * 4 + 3] != 0 {
                XCTAssertEqual(data[i * 4 + 3], 255)
                let rgb = UInt32(data[i * 4]) << 16 | UInt32(data[i * 4 + 1]) << 8 | UInt32(data[i * 4 + 2])
                XCTAssertTrue(allowed.contains(rgb), String(rgb, radix: 16))
            }
        }
        let ball = pieces[0]
        XCTAssertEqual(ball.width, 4)
        XCTAssertEqual(ball.height, 4)
        let data = ball.pixels.bytes
        let shade = (0..<16).filter { data[$0 * 4 + 3] == 255 && data[$0 * 4] == 0x8D && data[$0 * 4 + 1] == 0xA3 && data[$0 * 4 + 2] == 0xBF }
        XCTAssertEqual(shade.count, 5)
    }
}
