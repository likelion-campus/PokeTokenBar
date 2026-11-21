// PlazaTreeTests+Bundled: the big tree's art as cut from the bundled tall-grass sheet (shared: the sheet loads through PlatformPlaza)
import XCTest
@testable import PokeTokenBar

extension PlazaTreeTests {
    private func rgbKey(_ b: [UInt8], _ i: Int) -> UInt32 { (UInt32(b[i]) << 16) | (UInt32(b[i + 1]) << 8) | UInt32(b[i + 2]) }

    private func grassSheet() throws -> PlazaImage { try XCTUnwrap(PlatformPlaza.tallGrassSheet()) }

    private func treeImage(_ season: PlazaSeason) throws -> PlazaImage {
        try XCTUnwrap(PlazaTree.image(try grassSheet(), season: season), "\(season)")
    }

    /// Opaque pixel colours of `rows`, counted.
    private func colors(_ image: PlazaImage, rows: Range<Int>) -> [UInt32: Int] {
        let b = image.pixels.bytes
        var out: [UInt32: Int] = [:]
        for y in rows { for x in 0..<image.width where b[(y * image.width + x) * 4 + 3] == 255 { out[rgbKey(b, (y * image.width + x) * 4), default: 0] += 1 } }
        return out
    }

    func testTheCropIsThePineAsShipped() async throws {
        let sheet = try grassSheet()
        let summer = try treeImage(.summer)
        XCTAssertEqual(PlazaResources.treeCrop, PlazaPixelRect(x: 83, y: 48, width: 42, height: 48))
        XCTAssertEqual(summer.width, 42); XCTAssertEqual(summer.height, 48)
        XCTAssertEqual(summer.pixels.bytes, sheet.pixels.cropped(to: PlazaResources.treeCrop).bytes)
        XCTAssertEqual(colors(summer, rows: 0..<48).values.reduce(0, +), 1464)
        XCTAssertEqual(colors(summer, rows: 0..<38), [0x4B692F: 437, 0x6ABE30: 309, 0x222034: 170, 0x524B24: 162, 0x99E550: 80])
        XCTAssertEqual(colors(summer, rows: 38..<39), [0x222034: 12, 0x524B24: 12, 0x6ABE30: 6, 0x4B692F: 2])
        XCTAssertEqual(colors(summer, rows: 39..<48), [0x6ABE30: 140, 0x4B692F: 44, 0x222034: 32, 0x663931: 26, 0x8F563B: 18, 0x45283C: 14])
        // Not the 208×144 sheet: no tree.
        XCTAssertNil(PlazaTree.image(PlazaImage(bitmap: PlazaBitmap(width: 16, height: 16)), season: .summer))
    }

    func testLeafColoursNeverTouchTheTrunk() async throws {
        let summer = try treeImage(.summer)
        let leaves: Set<UInt32> = [0x99E550, 0x6ABE30, 0x4B692F, 0x524B24, 0x222034]
        let trunk: Set<UInt32> = [0x663931, 0x8F563B, 0x45283C]
        XCTAssertEqual(Set(colors(summer, rows: PlazaTree.canopyRows).keys), leaves)
        XCTAssertTrue(leaves.isDisjoint(with: trunk))
        XCTAssertTrue(Set(colors(summer, rows: PlazaTree.canopyRows).keys).isDisjoint(with: trunk))
        XCTAssertEqual(Set(colors(summer, rows: PlazaTree.groundRows).keys).intersection(trunk), trunk)
    }

    func testEachSeasonSwapsOnlyItsBand() async throws {
        let summer = try treeImage(.summer)
        let base = summer.pixels.bytes
        let w = summer.width
        for season in PlazaSeason.allCases {
            let image = try treeImage(season)
            let b = image.pixels.bytes
            XCTAssertEqual(b.count, base.count)
            let canopy = PlazaTree.canopyColors(season), ground = PlazaTree.groundColors(season)
            for y in 0..<48 { for x in 0..<w {
                let i = (y * w + x) * 4
                XCTAssertEqual(b[i + 3], base[i + 3], "alpha \(season) (\(x),\(y))")
                guard base[i + 3] == 255 else { continue }
                let was = rgbKey(base, i)
                if [0x663931, 0x8F563B, 0x45283C, 0x222034].contains(was) { XCTAssertEqual(rgbKey(b, i), was, "\(season) kept (\(x),\(y))") }
                let table = PlazaTree.canopyRows.contains(y) ? canopy : ground
                XCTAssertEqual(rgbKey(b, i), table[was] ?? was, "\(season) (\(x),\(y))")
            } }
            if season == .spring || season == .summer { XCTAssertEqual(b, base, "\(season) is the sheet's pine") }
            if season == .autumn {
                XCTAssertEqual(Array(b[0..<(PlazaTree.canopyRows.upperBound * w * 4)]), Array(base[0..<(PlazaTree.canopyRows.upperBound * w * 4)]), "autumn's canopy")
                XCTAssertNotEqual(b, base)
            }
            if season == .winter {
                let c = colors(image, rows: PlazaTree.canopyRows)
                XCTAssertNil(c[0x99E550]); XCTAssertNil(c[0x6ABE30])
                XCTAssertNotNil(c[0xF6FAFF]); XCTAssertNotNil(c[0xC6DAF0])
                XCTAssertNil(colors(image, rows: PlazaTree.groundRows)[0x6ABE30])
            }
        }
    }

    func testTheBandsTileTheImage() async throws {
        for season in PlazaSeason.allCases {
            let image = try treeImage(season)
            let bands = PlazaTree.bands(image)
            XCTAssertEqual(bands.map(\.height), [10, 10, 10, 18])
            XCTAssertTrue(bands.allSatisfy { $0.width == 42 })
            XCTAssertEqual(bands.flatMap { $0.pixels.bytes }, image.pixels.bytes, "\(season)")
        }
    }

    func testEveryMapImageIsUnchanged() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grass = try grassSheet()
        let old = try PlazaMap(rows: PlazaMapData.rows.map { $0.replacingOccurrences(of: "B", with: ".") })
        for season in PlazaSeason.allCases {
            let a = PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grass, season: season)
            let b = PlazaSeasonSheet.look(old, sheet: sheet, tallGrassSheet: grass, season: season)
            XCTAssertEqual(a.mapImage.pixels.bytes, b.mapImage.pixels.bytes, "\(season)")
        }
        let tg = PlatformPlaza.tallGrassArt()
        XCTAssertEqual(PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet, tallGrass: tg).pixels.bytes,
                       PlazaTileArt.mapImage(old, sheet: sheet, tallGrass: tg).pixels.bytes)
    }

    func testTheMinimapShowsTheTreeInEverySeason() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grass = try grassSheet()
        let rect = try XCTUnwrap(PlazaTree.artRect(in: PlazaMapData.map))
        let (x0, y0, k) = (Int(rect.minX), Int(rect.minY), Int(PlazaTree.scale))
        let (rw, rh) = (Int(rect.width), Int(rect.height))
        for season in PlazaSeason.allCases {
            let mapImage = PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grass, season: season).mapImage
            let tree = try treeImage(season)
            let out = PlazaTree.baked(mapImage, tree: tree, at: rect)
            XCTAssertEqual(out.width, mapImage.width); XCTAssertEqual(out.height, mapImage.height)
            let m = mapImage.pixels.bytes, o = out.pixels.bytes, t = tree.pixels.bytes
            let w = mapImage.width
            for y in 0..<mapImage.height { for x in 0..<w {
                let i = (y * w + x) * 4
                let inside = x >= x0 && x < x0 + rw && y >= y0 && y < y0 + rh
                if !inside { XCTAssertEqual(Array(o[i..<i + 4]), Array(m[i..<i + 4]), "outside (\(x),\(y)) \(season)"); continue }
                let ti = (((y - y0) / k) * 42 + (x - x0) / k) * 4
                if t[ti + 3] == 0 { XCTAssertEqual(Array(o[i..<i + 4]), Array(m[i..<i + 4]), "transparent (\(x),\(y)) \(season)") }
                else { XCTAssertEqual(Array(o[i..<i + 4]), Array(t[ti..<ti + 4]), "tree (\(x),\(y)) \(season)") }
            } }
        }
    }
}
