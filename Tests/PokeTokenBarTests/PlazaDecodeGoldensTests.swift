import XCTest
@testable import PokeTokenBar

/// The decode goldens hang together on both OSes: the straight bytes of the mid-range fixture, premultiplied with the shared
/// `PlazaPremultiply`, are the bytes the Mac's ImageIO + CoreGraphics made (`PlazaDecodeGoldensMacTests` re-measures those on the
/// Mac). A different rounding (floor, ceiling) changes 43 of the fixture's 96 colour bytes, so this fails for it.
final class PlazaDecodeGoldensTests: XCTestCase {
    func testMidRangeFixtureStraightBytesPremultiplyToTheMacsBytes() {
        let size = PlazaDecodeGoldens.fixture2Size
        let made = PlazaPremultiply.bitmap(straight: PlazaDecodeGoldens.fixture2Straight, width: size.width, height: size.height)
        XCTAssertEqual(made.bytes, PlazaDecodeGoldens.fixture2Premultiplied)
    }

    func testAFlooringPremultiplyWouldNotPassTheFixture() {
        var floored = PlazaDecodeGoldens.fixture2Straight
        for i in stride(from: 0, to: floored.count, by: 4) {
            for k in 0..<3 { floored[i + k] = UInt8(Int(floored[i + k]) * Int(floored[i + 3]) / 255) }
        }
        XCTAssertEqual(zip(floored, PlazaDecodeGoldens.fixture2Premultiplied).filter { $0 != $1 }.count, 43)
    }

    func testTheSmallFixtureIsTheTraysAndIsInsideItsOwnTable() {
        XCTAssertEqual(PlazaDecodeGoldens.fixturePremultiplied.count, PlazaDecodeGoldens.fixtureSize * PlazaDecodeGoldens.fixtureSize * 4)
        XCTAssertEqual(PlazaDecodeGoldens.fixture2Premultiplied.count, PlazaDecodeGoldens.fixture2Size.width * PlazaDecodeGoldens.fixture2Size.height * 4)
        XCTAssertEqual(PlazaDecodeGoldens.fixture2Straight.count, PlazaDecodeGoldens.fixture2Premultiplied.count)
    }
}
