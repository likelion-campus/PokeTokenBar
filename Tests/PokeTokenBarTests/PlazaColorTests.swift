import XCTest
@testable import PokeTokenBar

final class PlazaColorTests: XCTestCase {
    /// The name palette is the hex list, each byte divided by 255 (the components CGColor(srgbRed:) got before).
    func testPaletteMatchesTheHexList() {
        XCTAssertEqual(PlazaNameColor.palette.count, PlazaNameColor.hexes.count)
        for (color, hex) in zip(PlazaNameColor.palette, PlazaNameColor.hexes) {
            XCTAssertEqual(color, PlazaColor(hex: hex))
            XCTAssertEqual(color.red, Double((hex >> 16) & 0xFF) / 255)
            XCTAssertEqual(color.green, Double((hex >> 8) & 0xFF) / 255)
            XCTAssertEqual(color.blue, Double(hex & 0xFF) / 255)
            XCTAssertEqual(color.alpha, 1)
        }
        XCTAssertEqual(PlazaNameColor.color(forMemberID: "a"), PlazaNameColor.palette[PlazaNameColor.index(forMemberID: "a")])
        let picked = PlazaNameColor.hexes[3]
        XCTAssertEqual(PlazaNameColor.color(forMemberID: "a", chosen: picked), PlazaColor(hex: picked))
    }

    func testHexRoundTrip() {
        func hex(_ c: PlazaColor) -> UInt32 {
            UInt32((c.red * 255).rounded()) << 16 | UInt32((c.green * 255).rounded()) << 8 | UInt32((c.blue * 255).rounded())
        }
        for value in PlazaNameColor.hexes + [0x000000, 0x010203, 0x1E7CB8, 0xFEFDFC] {
            XCTAssertEqual(hex(PlazaColor(hex: value)), value)
        }
        XCTAssertEqual(PlazaColor(hex: 0x123456, alpha: 0.25).alpha, 0.25)
        XCTAssertEqual(PlazaColor(hex: 0xFF000000 | 0x123456), PlazaColor(hex: 0x123456), "only the low 24 bits are colour")
    }

    func testColorEqualityIsComponentwise() {
        XCTAssertEqual(PlazaColor(srgbRed: 1, green: 0, blue: 0), PlazaColor(hex: 0xFF0000))
        XCTAssertNotEqual(PlazaColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), PlazaColor(hex: 0xFF0000))
        XCTAssertNotEqual(PlazaColor(srgbRed: 1, green: 0, blue: 0), PlazaColor(srgbRed: 1, green: 0, blue: 0.0001))
        XCTAssertEqual(Set([PlazaColor.white, PlazaColor(hex: 0xFFFFFF), .black, .clear]).count, 3)
        XCTAssertEqual(PlazaColor.white, PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(PlazaColor.black, PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(PlazaColor.clear, PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
    }
}
