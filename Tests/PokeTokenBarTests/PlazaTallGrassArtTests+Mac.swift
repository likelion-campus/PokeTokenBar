import XCTest
@testable import PokeTokenBar

extension PlazaTallGrassArtTests {
    func testTheBundledSheetLoadsAndEverySliceIsItsCell() throws {
        let art = try XCTUnwrap(PlazaTallGrassArt.load())
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tallGrassSheet()))
        let sheetPx = sheet.pixels.bytes
        for c in 0...2 {
            for r in 0...2 {
                let s = PlazaTallGrassSlice(col: c, row: r)
                let t = art.tile(s).pixels.bytes
                for y in 0..<16 {
                    let si = ((PlazaTallGrass.sheetRowOffset + s.row) * 16 + y) * sheet.width * 4 + s.col * 16 * 4
                    XCTAssertEqual(Array(t[y * 64..<(y + 1) * 64]), Array(sheetPx[si..<si + 64]), "\(s) row \(y)")
                }
            }
        }
    }
}
