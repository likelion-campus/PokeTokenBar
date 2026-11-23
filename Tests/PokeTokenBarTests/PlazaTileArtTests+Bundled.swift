import XCTest
@testable import PokeTokenBar

/// The tile art checks against the bundled sheet.
extension PlazaTileArtTests {
    /// The full map is rendered once per class; tests that only inspect the result reuse it.
    private static let sharedMapImage: PlazaImage? = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0) }
    private func sharedMap() throws -> PlazaImage { try XCTUnwrap(Self.sharedMapImage) }

    private func sheet() throws -> PlazaImage { try XCTUnwrap(PlatformPlaza.tileSheet()) }

    /// 2x2 보드와 쉼터 한 칸이 있는 작은 지도. 왼쪽 위 2x2는 나무다.
    private func smallMap(_ at: String = ".") throws -> PlazaMap {
        try PlazaMap(rows: ["TT" + at + "...", "TT.NN.", "...NN.", "..S..."])
    }

    func testPondAndShoreAreBaked() throws {
        let sheet = try sheet()
        let sp = pixels(sheet)
        // 8x6: water at x 2-3, y 2-3. (2,1) is land north of water; (4,2) land east of water.
        func rows(_ flower: Bool) -> [String] {
            ["........", flower ? "..f....." : "........", "..ww....", "..ww....", "........", "T..NN.S."]
        }
        let w = 8 * 32
        let img = pixels(PlazaTileArt.mapImage(try PlazaMap(rows: rows(false)), sheet: sheet))
        // water = sheet (3,7) doubled
        let waterTile = tile(img, 2, 2, width: w)
        var expectedWater: [UInt8] = []
        for r in 0..<32 { for c in 0..<32 {
            expectedWater += pixel(sp, 3 * 16 + c / 2, 7 * 16 + r / 2, width: sheet.width)
        } }
        XCTAssertEqual(waterTile, expectedWater)
        // north shore (2,1) = grass variant with sheet (3,6) over it; (2,1) has water to the south.
        let grassOnly = pixels(PlazaTileArt.mapImage(try PlazaMap(rows: ["........", "........", "........", "........", "........", "T..NN.S."]), sheet: sheet))
        var expectedShore = tile(grassOnly, 2, 1, width: w)
        for r in 0..<32 { for c in 0..<32 {
            let px = pixel(sp, 3 * 16 + c / 2, 6 * 16 + r / 2, width: sheet.width)
            if px[3] == 0 { continue }
            let a = Int(px[3]), i = (r * 32 + c) * 4
            for k in 0..<3 { expectedShore[i + k] = UInt8(min(255, Int(px[k]) + Int(expectedShore[i + k]) * (255 - a) / 255)) }
            expectedShore[i + 3] = 255
        } }
        // cell (2,1) north of water at x=2 has water S and no other orthogonal; diagonal (3,2) is also water, so S only.
        XCTAssertEqual(tile(img, 2, 1, width: w), expectedShore)
        // flowers on a shore cell are not drawn
        let withFlower = pixels(PlazaTileArt.mapImage(try PlazaMap(rows: rows(true)), sheet: sheet))
        XCTAssertEqual(tile(withFlower, 2, 1, width: w), tile(img, 2, 1, width: w))
    }

    /// One pad in each pond (not the hot spring) is really baked: its opaque sheet pixels land on the water tile (doubled), and a bare water tile stays plain.
    func testLilyPadsAreBakedInEachPond() throws {
        let sheet = try sheet(), sp = pixels(sheet)
        let img = pixels(try sharedMap())
        let w = 48 * 32
        let bare = tile(img, 8, 14, width: w)   // left pond, no pad (the east pond is the hot spring now: no pads at all)
        var expectedWater: [UInt8] = []
        for r in 0..<32 { for c in 0..<32 { expectedWater += pixel(sp, 3 * 16 + c / 2, 7 * 16 + r / 2, width: sheet.width) } }
        XCTAssertEqual(bare, expectedWater)
        // (tile, sheet cell): the single pads of the two ponds that are ponds. No pair is drawn anywhere any more.
        let pads: [(x: Int, y: Int, col: Int)] = [(14, 13, 2), (21, 25, 2)]
        for pad in pads {
            let baked = tile(img, pad.x, pad.y, width: w)
            XCTAssertNotEqual(baked, expectedWater, "pad at (\(pad.x),\(pad.y)) not drawn")
            var opaque = 0
            for r in 0..<32 { for c in 0..<32 {
                let px = pixel(sp, pad.col * 16 + c / 2, r / 2, width: sheet.width)
                guard px[3] == 255 else { continue }
                opaque += 1
                XCTAssertEqual(Array(baked[(r * 32 + c) * 4..<(r * 32 + c) * 4 + 4]), px, "pad (\(pad.x),\(pad.y)) pixel \(c),\(r)")
            } }
            XCTAssertGreaterThan(opaque, 0)
        }
    }

    func testMapImageSize() throws {
        let img = try sharedMap()
        XCTAssertEqual(img.width, 48 * 32); XCTAssertEqual(img.height, 32 * 32)
    }

    func testDeterministic() throws {
        let sheet = try sheet()
        let a = pixels(try sharedMap())
        let b = pixels(PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet))
        XCTAssertEqual(a.count, 48 * 32 * 32 * 32 * 4)
        XCTAssertEqual(a, b)
    }

    func testFlowerCellDiffersFromPlainGrassAndTreeCellIsNotGrass() throws {
        let sheet = try sheet()
        // 같은 위치 (2,0): 잔디 변형이 같으니 꽃이 있는 쪽만 달라야 한다.
        let plain = pixels(PlazaTileArt.mapImage(try smallMap("."), sheet: sheet))
        let flower = pixels(PlazaTileArt.mapImage(try smallMap("f"), sheet: sheet))
        XCTAssertNotEqual(tile(plain, 2, 0, width: 6 * 32), tile(flower, 2, 0, width: 6 * 32))

        // 나무 칸 (0,0)의 가운데 픽셀은 잔디 변형 8종의 같은 위치 색과 모두 다르다.
        let tree = pixels(PlazaTileArt.mapImage(try smallMap("."), sheet: sheet))
        let treeColor = pixel(tree, 16, 16, width: 6 * 32)
        let sheetPx = pixels(sheet)
        for (c, r) in [(0, 9), (1, 9), (0, 10), (1, 10), (5, 9), (8, 9), (5, 10), (8, 10)] {
            let grass = pixel(sheetPx, c * 16 + 8, r * 16 + 8, width: sheet.width)
            XCTAssertNotEqual(treeColor, grass, "variant (\(c),\(r))")
        }
    }

    func testTallGrassIsBakedOnlyWithTheArt() throws {
        let sheet = try sheet()
        let art = try XCTUnwrap(PlatformPlaza.tallGrassArt())
        let w = 6 * 32
        let plain = tile(pixels(PlazaTileArt.mapImage(try smallMap("."), sheet: sheet)), 2, 0, width: w)
        let baked = tile(pixels(PlazaTileArt.mapImage(try smallMap("g"), sheet: sheet, tallGrass: art)), 2, 0, width: w)
        let without = tile(pixels(PlazaTileArt.mapImage(try smallMap("g"), sheet: sheet, tallGrass: nil)), 2, 0, width: w)
        XCTAssertNotEqual(baked, plain)
        XCTAssertEqual(without, plain)
    }

    func testArtIsUpscaledTwiceWithoutSmoothing() throws {
        let px = pixels(PlazaTileArt.mapImage(try smallMap(), sheet: try sheet()))
        let w = 6 * 32
        for by in stride(from: 0, to: 4 * 32, by: 2) {
            for bx in stride(from: 0, to: w, by: 2) {
                let c = pixel(px, bx, by, width: w)
                XCTAssertEqual(pixel(px, bx + 1, by, width: w), c)
                XCTAssertEqual(pixel(px, bx, by + 1, width: w), c)
                XCTAssertEqual(pixel(px, bx + 1, by + 1, width: w), c)
            }
        }
    }

    /// The board is drawn as one big signpost made from the sheet's small sign, covering the 2x2 board tiles.
    func testBoardIsDrawnAsTheSignpost() throws {
        let sheet = try sheet(), sheetPx = pixels(sheet), map = PlazaMapData.map
        let mapPx = pixels(try sharedMap()), width = map.width * 32
        XCTAssertEqual(PlazaTileArt.signSize * 2, 2 * PlazaMap.tileSize, "the sign covers the 2x2 board tiles")
        var compared = 0
        for sy in 0..<PlazaTileArt.signSize {
            for sx in 0..<PlazaTileArt.signSize {
                let src = PlazaTileArt.signSource(x: sx, y: sy)
                XCTAssertTrue((0..<16).contains(src.x) && (0..<16).contains(src.y), "(\(sx),\(sy)) stays in the sign cell")
                let s = pixel(sheetPx, PlazaTileArt.signCell.col * 16 + src.x, PlazaTileArt.signCell.row * 16 + src.y, width: sheet.width)
                guard s[3] == 255 else { continue }
                let m = pixel(mapPx, map.boardTile.x * 32 + sx * 2, map.boardTile.y * 32 + sy * 2, width: width)
                XCTAssertEqual(Array(m[0..<3]), Array(s[0..<3]), "(\(sx),\(sy))")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 400, "the sign has opaque pixels to compare")
    }

    /// One board, not two side by side: the plank runs across the middle with no grass showing through.
    func testSignBoardIsOnePiece() throws {
        let sheetPx = pixels(try sheet()), sheetWidth = try sheet().width
        for sy in 0...18 {
            for sx in 1..<(PlazaTileArt.signSize - 1) {
                let src = PlazaTileArt.signSource(x: sx, y: sy)
                let s = pixel(sheetPx, PlazaTileArt.signCell.col * 16 + src.x, PlazaTileArt.signCell.row * 16 + src.y, width: sheetWidth)
                XCTAssertEqual(s[3], 255, "(\(sx),\(sy))")
            }
        }
    }

    func testEveryPixelIsOpaque() throws {
        let px = pixels(try sharedMap())
        XCTAssertFalse(stride(from: 3, to: px.count, by: 4).contains { px[$0] != 255 })
    }

    private func pixels(_ image: PlazaImage) -> [UInt8] { image.pixels.bytes }

    func testCampfireTilesAreDrawnAsGrass() throws {
        let sheet = try sheet()
        let swapped = try PlazaMap(rows: PlazaMapData.rows.map { $0.replacingOccurrences(of: "F", with: ".") })
        let a = pixels(try sharedMap()), b = pixels(PlazaTileArt.mapImage(swapped, sheet: sheet))
        XCTAssertEqual(tile(a, 36, 23, width: 48 * 32), tile(b, 36, 23, width: 48 * 32))
    }

    // MARK: The hot spring

    private static let oldRows = PlazaMapData.rowsBeforeTheStall.map { $0.replacingOccurrences(of: "h", with: "w") }
    private func oldMap() throws -> PlazaMap { try PlazaMap(rows: Self.oldRows) }
    private func looks(_ map: PlazaMap, _ season: PlazaSeason) throws -> PlazaImage {
        let sheet = try sheet(), grass = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        return PlazaSeasonSheet.look(map, sheet: sheet, tallGrassSheet: grass, season: season).mapImage
    }
    private var allSeasons: [PlazaSeason] { [.summer, .spring, .autumn, .winter] }

    func testTheSpringIsJadeInEverySeason() throws {
        let map = PlazaMapData.map
        let blue: Set<[UInt8]> = [[0x1E, 0x7C, 0xB8], [0x16, 0x5C, 0x88], [0x5A, 0xAE, 0xE4]]
        for season in allSeasons {
            let img = pixels(try looks(map, season))
            let w = 48 * 32
            for y in 0..<map.height { for x in 0..<map.width where PlazaHotSpring.usesSpringWater(TilePoint(x: x, y: y), in: map) {
                let t = tile(img, x, y, width: w)
                for i in stride(from: 0, to: t.count, by: 4) where t[i + 3] == 255 {
                    XCTAssertFalse(blue.contains(Array(t[i..<i + 3])), "\(season) tile (\(x),\(y)) keeps a pond colour")
                }
            } }
            XCTAssertEqual(Set(stride(from: 0, to: 32 * 32 * 4, by: 4).map { Array(tile(img, 36, 18, width: w)[$0..<$0 + 4]) }),
                           [[0x4F, 0xA8, 0xA0, 255]], "\(season) bare spring tile")
        }
    }

    /// Ruling 2: the stones' 0x66 shadow blends over jade. A swap on the finished map would leave these blends blue.
    func testNoBlueShadowIsLeftInTheSpring() throws {
        let sp = pixels(try sheet()), sw = try sheet().width
        var shadow: [UInt8]?
        for y in 0..<16 { for x in 0..<16 {
            let px = pixel(sp, 12 * 16 + x, 10 * 16 + y, width: sw)
            if px[3] == 0x66 { shadow = px }
        } }
        let s = try XCTUnwrap(shadow, "cell (12,10) has a 0x66 shadow pixel")
        var stale: Set<[UInt8]> = []
        for water in [[0x1E, 0x7C, 0xB8], [0x16, 0x5C, 0x88], [0x5A, 0xAE, 0xE4]] as [[Int]] {
            stale.insert((0..<3).map { UInt8(min(255, Int(s[$0]) + water[$0] * (255 - Int(s[3])) / 255)) })
        }
        XCTAssertEqual(stale.count, 3)
        for season in allSeasons {
            let img = pixels(try looks(PlazaMapData.map, season))
            for i in stride(from: 0, to: img.count, by: 4) {
                XCTAssertFalse(stale.contains(Array(img[i..<i + 3])), "\(season): a pond-blue shadow blend at pixel \(i / 4)")
                if stale.contains(Array(img[i..<i + 3])) { return }
            }
        }
    }

    func testTheHotSpringHasNoLilyPads() throws {
        let img = pixels(try sharedMap()), w = 48 * 32
        let bare = tile(img, 36, 18, width: w)
        for (x, y) in [(33, 18), (35, 16), (36, 16)] { XCTAssertEqual(tile(img, x, y, width: w), bare, "(\(x),\(y))") }
    }

    func testOnlyTheHotSpringChangedTheMap() throws {
        let map = try PlazaMap(rows: PlazaMapData.rowsBeforeTheStall), old = try oldMap()   // the fortune stall came later
        let b = try XCTUnwrap(PlazaHotSpring.artBounds(in: map))
        let w = 48 * 32
        for season in allSeasons {
            let a = pixels(try looks(map, season)), o = pixels(try looks(old, season))
            var bad = 0, inside = 0
            for row in 0..<(32 * 32) {
                for tx in 0..<48 {
                    let start = (row * w + tx * 32) * 4
                    let same = a[start..<start + 128] == o[start..<start + 128]
                    if (b.minX...b.maxX).contains(tx) && (b.minY...b.maxY).contains(row / 32) { if !same { inside += 1 } } else if !same { bad += 1 }
                }
            }
            XCTAssertEqual(bad, 0, "\(season): pixels changed outside the spring's art")
            XCTAssertGreaterThan(inside, 0, "\(season): the spring is drawn")
        }
    }

    /// The pre-PR summer map hash (`PlazaSeasonTests.pinnedLooks[.summer].map` before PR 4): a map without 'h' draws today's pond.
    static let preSpringSummerMap = "949e959dca07032e73fc0843305a40c4bca7514195ffdf201dba83371c2f9ffb"

    func testAMapWithoutTheSpringDrawsTheOldPond() throws {
        let hash = PlazaParityGoldens.sha256Hex(pixels(try looks(try oldMap(), .summer)))
        XCTAssertEqual(hash, Self.preSpringSummerMap)
    }
}
