import XCTest
@testable import PokeTokenBar

/// `PlazaPremultiply` is CoreGraphics' rounding, so a decoder that is not CoreGraphics gives the Mac's bytes. The Mac
/// measures the table (`PlazaParityGoldensMacTests`); both OSes check the shared formula against its golden.
final class PlazaPremultiplyTests: XCTestCase {
    private func formulaTable() -> [UInt8] {
        var table = [UInt8]()
        table.reserveCapacity(65_536)
        for a in 0..<256 { for c in 0..<256 { table.append(PlazaPremultiply.premultiplied(UInt8(c), alpha: UInt8(a))) } }
        return table
    }

    func testTheStraightToPremultipliedTableIsTheOneCoreGraphicsMade() throws {
        let golden = try PlazaParityGoldens.load(PlazaPremultiplyGolden.self, "premultiply.json")
        let table = formulaTable()
        XCTAssertEqual(PlazaParityGoldens.sha256Hex(table), golden.tableSHA256, "all 65,536 (colour, alpha) pairs")
        XCTAssertFalse(golden.rows.isEmpty)
        for (alpha, hex) in golden.rows {
            let a = try XCTUnwrap(Int(alpha))
            XCTAssertEqual(PlazaParityGoldens.hex(Array(table[a * 256..<(a + 1) * 256])), hex, "alpha \(a)")
        }
    }

    /// Values the Mac measured through ImageIO's PNG writer (premultiplied → straight), pinned by hand.
    func testStraightIsWhatImageIOWrites() {
        XCTAssertEqual((0...3).map { PlazaPremultiply.straight(UInt8($0), alpha: 3) }, [0, 85, 170, 255])
        XCTAssertEqual((0...3).map { PlazaPremultiply.straight(UInt8($0), alpha: 2) }.prefix(3), [0, 128, 255])
        XCTAssertEqual((0...7).map { PlazaPremultiply.straight(UInt8($0), alpha: 127) }, [0, 2, 4, 6, 8, 10, 12, 14])
        XCTAssertEqual((0...7).map { PlazaPremultiply.straight(UInt8($0), alpha: 254) }, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(PlazaPremultiply.straight(5, alpha: 0), 0)
        XCTAssertEqual(PlazaPremultiply.straight(255, alpha: 255), 255)
    }

    func testBitmapAndStraightRoundTripOnWholePixels() {
        // opaque and fully transparent pixels survive both ways exactly
        let straight: [UInt8] = [255, 128, 0, 255, 9, 9, 9, 0, 17, 34, 51, 255]
        let bitmap = PlazaPremultiply.bitmap(straight: straight, width: 3, height: 1)
        XCTAssertEqual(bitmap.bytes, [255, 128, 0, 255, 0, 0, 0, 0, 17, 34, 51, 255])
        XCTAssertEqual(PlazaPremultiply.straight(bitmap), [255, 128, 0, 255, 0, 0, 0, 0, 17, 34, 51, 255])
        var opaque = bitmap
        opaque.alpha = .noneSkipLast
        opaque.bytes[3] = 7   // the skipped byte is not alpha: a PNG of an opaque image writes 255
        XCTAssertEqual(PlazaPremultiply.straight(opaque)[3], 255)
        // a half-transparent pixel: 200 at alpha 100 premultiplies to 78 and comes back as 195 (rounding is lossy)
        let half = PlazaPremultiply.bitmap(straight: [200, 100, 50, 100], width: 1, height: 1)
        XCTAssertEqual(half.bytes, [78, 39, 20, 100])
        XCTAssertEqual(PlazaPremultiply.straight(half), [199, 99, 51, 100])
    }
}
