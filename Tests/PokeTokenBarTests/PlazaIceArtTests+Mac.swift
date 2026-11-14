import XCTest
@testable import PokeTokenBar

/// The ice art checks that read the bundled files.
extension PlazaIceArtTests {
    func testTheGlossCellKeepsItsThreeLightColours() throws {
        let sheet = try XCTUnwrap(PlazaResources.iceGlossSheet(in: PlazaResources.resourceBundle()).map(PlazaImage.init(cgImage:)))
        let gloss = PlazaIceArt.gloss(fromSheet: sheet)
        XCTAssertEqual([gloss.width, gloss.height], [16, 16])
        let c = counts(gloss)
        XCTAssertEqual(c[0xB5D3EF], 97)
        XCTAssertEqual(c[0xC0DBF3], 45)
        XCTAssertEqual(c[0xD0E5F8], 15)
        XCTAssertEqual(c[nil], 99)
    }

    func testCracksKeepOnlyTheCrackPixelsAndMirrorTheSecondSix() throws {
        let sheet = try XCTUnwrap(PlazaResources.iceCrackSheet(in: PlazaResources.resourceBundle()).map(PlazaImage.init(cgImage:)))
        let cracks = PlazaIceArt.cracks(fromSheet: sheet)
        XCTAssertEqual(cracks.count, 12)
        XCTAssertTrue(cracks.allSatisfy { $0.width == 16 && $0.height == 16 })
        for (i, expected) in [59, 59, 58, 48, 62, 47].enumerated() {
            let c = counts(cracks[i])
            XCTAssertEqual(c[0x6A97C6], expected, "cell \(i)")
            XCTAssertEqual(c[nil, default: 0] + expected, 256, "cell \(i): everything else is clear")
        }
        for i in 0..<6 {
            let a = rgba(cracks[i]), b = rgba(cracks[6 + i])
            for y in 0..<16 { for x in 0..<16 {
                XCTAssertEqual(pixel(b, 16, x, y), pixel(a, 16, 15 - x, y), "cell \(i) (\(x),\(y))")
            } }
        }
    }

    func testShardsAreFramesTwoToFourRecoloured() throws {
        let frames = PlazaResources.iceShatterFrames(in: PlazaResources.resourceBundle()).map(PlazaImage.init(cgImage:))
        let shards = PlazaIceArt.shards(fromFrames: frames)
        XCTAssertEqual(shards.count, 3)
        XCTAssertTrue(shards.allSatisfy { $0.width == 32 && $0.height == 32 })
        let opaque = shards.map { 1024 - counts($0)[nil, default: 0] }
        XCTAssertEqual(opaque, [205, 97, 12])
        let first = counts(shards[0])
        XCTAssertEqual(first[0x6A98C8], 99)
        XCTAssertEqual(first[0x8FB7DE], 58)
        XCTAssertEqual(first[0xD8EAF8], 39)
        XCTAssertEqual(first[0xF4FAFF], 9)
        XCTAssertEqual(counts(shards[2])[0x6A98C8], 12)
        XCTAssertEqual(PlazaIceArt.shards(fromFrames: Array(frames.prefix(3))).count, 0)
    }

    func snowMap() throws -> PlazaImage {
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tileSheet()))
        let art = PlazaResources.tallGrassSheet().map { PlazaSnowSheet.tallGrass(PlazaImage(cgImage: $0)) }.flatMap(PlazaTallGrassArt.init(sheet:))
        return PlazaTileArt.mapImage(PlazaMapData.map, sheet: PlazaSnowSheet.tiles(sheet), tallGrass: art)
    }

    func testTheOverlaysMatchTheApprovedMock() throws {
        let map = PlazaMapData.map
        let image = try snowMap()
        let gloss = PlazaIceArt.load().gloss
        XCTAssertNotNil(gloss)
        let expected: [TilePoint: (w: Int, h: Int, c: [UInt32: Int], clear: Int)] = [
            TilePoint(x: 32, y: 14): (288, 288, [0xADCDEC: 51797, 0xB5D3EF: 2038, 0x94B9DF: 1040, 0xC0DBF3: 900,
                                                0xC8DEF4: 420, 0xD0E5F8: 297], 26452),
            TilePoint(x: 5, y: 13): (384, 160, [0xADCDEC: 33180, 0xB5D3EF: 1213, 0x94B9DF: 1460, 0xC0DBF3: 531,
                                               0xC8DEF4: 408, 0xD0E5F8: 172], 24476),
            TilePoint(x: 20, y: 24): (160, 160, [0xADCDEC: 11012, 0xB5D3EF: 223, 0x94B9DF: 480, 0xC0DBF3: 89,
                                                0xC8DEF4: 212, 0xD0E5F8: 28], 13556)
        ]
        let ponds = PlazaIce.ponds(in: map)
        XCTAssertEqual(Set(ponds.map(\.anchor)), Set(expected.keys))
        for pond in ponds {
            let e = try XCTUnwrap(expected[pond.anchor])
            let overlay = PlazaIceArt.overlay(mapImage: image, pond: pond, gloss: gloss)
            XCTAssertEqual([overlay.width, overlay.height], [e.w, e.h], "\(pond.anchor)")
            let c = counts(overlay)
            for (color, n) in e.c { XCTAssertEqual(c[color], n, "\(pond.anchor) #\(String(color, radix: 16))") }
            XCTAssertEqual(c[nil], e.clear, "\(pond.anchor) clear")
            XCTAssertEqual(c.values.reduce(0, +), e.w * e.h, "\(pond.anchor) has no other colours")
        }
    }

    func testWithoutTheFilesThePiecesAreEmptyAndTheOverlayStillBuilds() throws {
        let none = PlazaIceArt.load(bundle: nil)
        XCTAssertNil(none.gloss)
        XCTAssertEqual(none.cracks.count, 0)
        XCTAssertEqual(none.shards.count, 0)
        let pond = try XCTUnwrap(PlazaIce.ponds(in: PlazaMapData.map).first { $0.anchor == TilePoint(x: 32, y: 14) })
        let c = counts(PlazaIceArt.overlay(mapImage: try snowMap(), pond: pond, gloss: nil))
        for color in PlazaIceArt.glossColors { XCTAssertNil(c[color]) }
        XCTAssertEqual(c[0xADCDEC], 51797 + 3235)
    }
}
