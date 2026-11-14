import XCTest
@testable import PokeTokenBar

/// The snow recolour checks that read the bundled sheets.
extension PlazaSnowSheetTests {
    func testSnowTilesKeepWaterLiliesAndEveryAlpha() throws {
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tileSheet()))
        let before = Pixels(sheet), after = Pixels(PlazaSnowSheet.tiles(sheet))
        XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
        for cell in [(3, 7), (2, 0), (4, 0), (5, 0)] {
            XCTAssertEqual(before.cellBytes(cell), after.cellBytes(cell), "\(cell)")
        }
        for i in stride(from: 3, to: before.bytes.count, by: 4) {
            if before.bytes[i] != after.bytes[i] { XCTFail("alpha differs at \(i / 4)"); break }
        }
        XCTAssertEqual(after.count(0x3ABE41, cell: (0, 9)), 0)
        XCTAssertGreaterThan(after.count(0xC6DAF0, cell: (0, 9)), 0)
        XCTAssertEqual(after.count(0x2D5B43, cell: (5, 17)), before.count(0x2D5B43, cell: (5, 17)))
        XCTAssertEqual(after.count(0x885040, cell: (34, 2)), before.count(0x885040, cell: (34, 2)))
    }

    func testSnowTallGrassKeepsTheDarkBladesAndOutline() throws {
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tallGrassSheet()))
        let before = Pixels(sheet), after = Pixels(PlazaSnowSheet.tallGrass(sheet))
        XCTAssertEqual(after.count(0x99E550), 0)
        XCTAssertEqual(after.count(0x6ABE30), 0)
        XCTAssertEqual(after.count(0x4B692F), before.count(0x4B692F))
        XCTAssertEqual(after.count(0x222034), before.count(0x222034))
        XCTAssertNotNil(PlazaTallGrassArt(sheet: PlazaSnowSheet.tallGrass(sheet)))
    }
}
