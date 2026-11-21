// PlazaTreeTests+Bundled: the big tree's art as cut from the bundled tall-grass sheet (shared: the sheet loads through PlatformPlaza)
import XCTest
@testable import PokeTokenBar

extension PlazaTreeTests {
    private func rgbKey(_ b: [UInt8], _ i: Int) -> UInt32 { (UInt32(b[i]) << 16) | (UInt32(b[i + 1]) << 8) | UInt32(b[i + 2]) }

    private func grassSheet() throws -> PlazaImage { try XCTUnwrap(PlatformPlaza.tallGrassSheet()) }

    /// The sheet's pine before any swap.
    private func rawCrop() throws -> PlazaImage { try XCTUnwrap(try grassSheet().cropping(to: PlazaResources.treeCrop)) }

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
        let raw = try rawCrop()
        XCTAssertEqual(PlazaResources.treeCrop, PlazaPixelRect(x: 83, y: 48, width: 42, height: 48))
        XCTAssertEqual(raw.width, 42); XCTAssertEqual(raw.height, 48)
        XCTAssertEqual(raw.pixels.bytes, sheet.pixels.cropped(to: PlazaResources.treeCrop).bytes)
        XCTAssertEqual(colors(raw, rows: 0..<48).values.reduce(0, +), 1464)
        XCTAssertEqual(colors(raw, rows: 0..<38), [0x4B692F: 437, 0x6ABE30: 309, 0x222034: 170, 0x524B24: 162, 0x99E550: 80])
        XCTAssertEqual(colors(raw, rows: 38..<39), [0x222034: 12, 0x524B24: 12, 0x6ABE30: 6, 0x4B692F: 2])
        XCTAssertEqual(colors(raw, rows: 39..<48), [0x6ABE30: 140, 0x4B692F: 44, 0x222034: 32, 0x663931: 26, 0x8F563B: 18, 0x45283C: 14])
        // Summer keeps the leaves as drawn, and every trunk and outline pixel in every season.
        let summer = try treeImage(.summer)
        let rowBytes = 42 * 4
        XCTAssertEqual(Array(summer.pixels.bytes[0..<(PlazaTree.canopyRows.upperBound * rowBytes)]),
                       Array(raw.pixels.bytes[0..<(PlazaTree.canopyRows.upperBound * rowBytes)]))
        // Not the 208×144 sheet: no tree.
        XCTAssertNil(PlazaTree.image(PlazaImage(bitmap: PlazaBitmap(width: 16, height: 16)), season: .summer))
    }

    func testLeafColoursNeverTouchTheTrunk() async throws {
        let summer = try rawCrop()
        let leaves: Set<UInt32> = [0x99E550, 0x6ABE30, 0x4B692F, 0x524B24, 0x222034]
        let trunk: Set<UInt32> = [0x663931, 0x8F563B, 0x45283C]
        XCTAssertEqual(Set(colors(summer, rows: PlazaTree.canopyRows).keys), leaves)
        XCTAssertTrue(leaves.isDisjoint(with: trunk))
        XCTAssertTrue(Set(colors(summer, rows: PlazaTree.canopyRows).keys).isDisjoint(with: trunk))
        XCTAssertEqual(Set(colors(summer, rows: PlazaTree.groundRows).keys).intersection(trunk), trunk)
    }

    func testEachSeasonSwapsOnlyItsBand() async throws {
        let raw = try rawCrop()
        let base = raw.pixels.bytes
        let w = raw.width
        let outline: UInt32 = 0x222034
        let trunk: Set<UInt32> = [0x663931, 0x8F563B, 0x45283C]
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
                if trunk.contains(was) || was == outline { XCTAssertEqual(rgbKey(b, i), was, "\(season) kept (\(x),\(y))") }
                let table = PlazaTree.canopyRows.contains(y) ? canopy : ground
                XCTAssertEqual(rgbKey(b, i), table[was] ?? was, "\(season) (\(x),\(y))")
            } }
            // The leaves are exactly the season's four colours (summer: the sheet's) plus the outline.
            let expected = Set(PlazaTree.seasonLeaves[season] ?? PlazaTree.leafColors).union([outline])
            XCTAssertEqual(Set(colors(image, rows: PlazaTree.canopyRows).keys), expected, "\(season)")
            if season != .summer {
                let left = Set(colors(image, rows: PlazaTree.canopyRows).keys).intersection(PlazaTree.leafColors)
                XCTAssertTrue(left.isEmpty, "\(season) still has source leaf colours \(left)")
            }
        }
    }

    func testTheSkirtTakesTheSeasonsGroundShade() async throws {
        let tiles = try XCTUnwrap(PlatformPlaza.tileSheet())
        let trunk: Set<UInt32> = [0x663931, 0x8F563B, 0x45283C]
        let expected: [PlazaSeason: Set<UInt32>] = [
            .summer: [0x328E41, 0x315740], .spring: [0x328E41, 0x315740], .autumn: [0x6E7634, 0x4A4626], .winter: [0xB2C7E0, 0x8DA3BF]]
        for season in PlazaSeason.allCases {
            let image = try treeImage(season)
            // The band's colours but the trunk, the outline and the canopy's last shade (row 38's #524B24, mapped with the leaves).
            let leafShade = PlazaTree.seasonLeaves[season]?[3] ?? 0x524B24
            let skirt = Set(colors(image, rows: PlazaTree.groundRows).keys).subtracting(trunk).subtracting([0x222034, leafShade])
            XCTAssertEqual(skirt, expected[season], "\(season)")
            XCTAssertTrue(skirt.isDisjoint(with: [PlazaTree.skirt.disc, PlazaTree.skirt.ring]), "\(season) keeps a source skirt colour")
            // Both are colours of that season's grass cells.
            let seasonTiles = PlazaSeasonSheet.tiles(tiles, season: season)
            var grass = Set<UInt32>()
            for cell in PlazaTileArt.grassCells {
                guard let cut = seasonTiles.cropping(to: PlazaPixelRect(x: cell.col * 16, y: cell.row * 16, width: 16, height: 16)) else { continue }
                grass.formUnion(colors(cut, rows: 0..<16).keys)
            }
            XCTAssertTrue(skirt.isSubset(of: grass), "\(season): \(skirt.subtracting(grass)) is not a grass colour")
        }
    }

    func testTheBurstMatchesTheTreesLook() async throws {
        for season in [PlazaSeason.summer, .spring] {
            let art = PlazaTree.burstArt(season)
            XCTAssertEqual(art.kind, .greenLeaves); XCTAssertEqual(art.grids, [0, 1, 2, 3])
        }
        XCTAssertEqual(PlazaTree.burstArt(.autumn).kind, .leaves); XCTAssertEqual(PlazaTree.burstArt(.autumn).grids, [0, 1, 4, 5])
        XCTAssertEqual(PlazaTree.burstArt(.winter).kind, .snow); XCTAssertEqual(PlazaTree.burstArt(.winter).grids, [0, 1, 2])
        for season in PlazaSeason.allCases {
            let art = PlazaTree.burstArt(season)
            let grids = PlazaWeatherArt.grids(art.kind)
            for i in art.grids {
                XCTAssertTrue(grids.indices.contains(i), "\(season) grid \(i)")
                if season == .autumn { XCTAssertFalse(grids[i].joined().contains { $0 == "R" || $0 == "r" }, "a larch has no red") }
            }
        }
    }

    func testTheCanopySpawnPointsAreOpaqueCanopyPixels() async throws {
        let image = try treeImage(.summer)
        let rect = try XCTUnwrap(PlazaTree.artRect(in: PlazaMapData.map))
        let points = PlazaTree.canopySpawnPoints(image, artRect: rect)
        let b = image.pixels.bytes
        var opaque = 0
        for y in 4..<34 { for x in 0..<42 where b[(y * 42 + x) * 4 + 3] == 255 { opaque += 1 } }
        XCTAssertEqual(points.count, opaque)
        for pt in points {
            XCTAssertTrue(rect.contains(pt), "\(pt)")
            let c = Int((pt.x - rect.minX) / PlazaTree.scale), r = Int((pt.y - rect.minY) / PlazaTree.scale)
            XCTAssertTrue((4..<34).contains(r)); XCTAssertEqual(b[(r * 42 + c) * 4 + 3], 255, "\(pt)")
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

    /// The bake clips at the map's edge (a rectangle that runs off it) and leaves everything else alone.
    func testTheBakedMinimapClipsAtTheMapEdge() async throws {
        let tree = try treeImage(.summer)
        let map = PlazaImage(bitmap: PlazaBitmap(width: 100, height: 100, fill: PlazaRGBA(r: 10, g: 20, b: 30, a: 255)))
        let out = PlazaTree.baked(map, tree: tree, at: CGRect(x: -30, y: -30, width: 126, height: 144)).pixels.bytes
        let t = tree.pixels.bytes, m = map.pixels.bytes
        let k = Int(PlazaTree.scale)
        for y in 0..<100 { for x in 0..<100 {
            let i = (y * 100 + x) * 4, ti = (((y + 30) / k) * 42 + (x + 30) / k) * 4
            let expected = (x + 30 < 126 && y + 30 < 144 && t[ti + 3] == 255) ? Array(t[ti..<ti + 4]) : Array(m[i..<i + 4])
            XCTAssertEqual(Array(out[i..<i + 4]), expected, "(\(x),\(y))")
        } }
        XCTAssertNotEqual(out, m, "something of the tree is drawn")
    }
}
