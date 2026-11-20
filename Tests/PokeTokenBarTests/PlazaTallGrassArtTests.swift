import XCTest
@testable import PokeTokenBar

final class PlazaTallGrassArtTests: XCTestCase {
    private func pixels(_ image: PlazaImage) -> [UInt8] { image.pixels.bytes }

    /// A synthetic 208x144 sheet where every pixel differs, so a slice that reads the wrong cell cannot pass.
    private static let sheet = PlazaImage(bitmap: PlazaTestImages.patterned(width: 208, height: 144))
    private func art() throws -> PlazaTallGrassArt { try XCTUnwrap(PlazaTallGrassArt(sheet: Self.sheet)) }
    private let allSlices = (0...2).flatMap { c in (0...2).map { PlazaTallGrassSlice(col: c, row: $0) } }

    func testInitRejectsAnotherSheet() throws {
        XCTAssertNil(PlazaTallGrassArt(sheet: PlazaImage(bitmap: PlazaBitmap(width: 16, height: 16))))
        XCTAssertNotNil(PlazaTallGrassArt(sheet: Self.sheet))
    }

    func testEachSliceIsItsSheetCell() throws {
        let sheet = Self.sheet
        let sheetPx = pixels(sheet), art = try art()
        for s in allSlices {
            let t = pixels(art.tile(s))
            XCTAssertEqual(t.count, 16 * 16 * 4)
            for y in 0..<16 {
                for x in 0..<16 {
                    let si = ((PlazaTallGrass.sheetRowOffset + s.row) * 16 + y) * sheet.width * 4 + (s.col * 16 + x) * 4
                    XCTAssertEqual(Array(t[(y * 16 + x) * 4..<(y * 16 + x) * 4 + 4]), Array(sheetPx[si..<si + 4]), "\(s) (\(x),\(y))")
                }
            }
        }
    }

    func testFrontKeepsOnlyTheLowBand() throws {
        let art = try art()
        for s in allSlices {
            let f = pixels(art.front(s)), t = pixels(art.tile(s))
            for y in 0..<16 {
                for x in 0..<16 {
                    let i = (y * 16 + x) * 4
                    if y < PlazaTallGrass.frontFromRow {
                        XCTAssertEqual(f[i + 3], 0, "\(s) (\(x),\(y))")
                    } else {
                        XCTAssertEqual(Array(f[i..<i + 4]), Array(t[i..<i + 4]), "\(s) (\(x),\(y))")
                    }
                }
            }
        }
    }

    func testTopKeepsOnlySwayRows() throws {
        let art = try art()
        for s in allSlices {
            let f = pixels(art.top(s)), t = pixels(art.tile(s))
            for y in 0..<16 {
                for x in 0..<16 {
                    let i = (y * 16 + x) * 4
                    if y < PlazaTallGrass.swayRows {
                        XCTAssertEqual(Array(f[i..<i + 4]), Array(t[i..<i + 4]), "\(s) (\(x),\(y))")
                    } else {
                        XCTAssertEqual(f[i + 3], 0, "\(s) (\(x),\(y))")
                    }
                }
            }
        }
    }

    func testLeavesUseOnlyThePackGreens() throws {
        let art = try art()
        XCTAssertEqual(art.leaves.count, 2)
        let allowed: Set<[UInt8]> = [[0x99, 0xE5, 0x50], [0x6A, 0xBE, 0x30], [0x22, 0x20, 0x34]]
        for leaf in art.leaves {
            XCTAssertEqual(leaf.width, 4); XCTAssertEqual(leaf.height, 4)
            let px = pixels(leaf)
            var opaque = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 {
                opaque += 1
                XCTAssertEqual(px[i + 3], 255)
                XCTAssertTrue(allowed.contains(Array(px[i..<i + 3])), "\(Array(px[i..<i + 3]))")
            }
            XCTAssertGreaterThan(opaque, 4)
        }
    }
}
