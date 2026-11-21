// PlazaSeasonTests+Bundled: the water balloon picture, the recoloured bundled sheets and the V line of the shortcut guide
import XCTest
@testable import PokeTokenBar

extension PlazaSeasonTests {
    /// 지금 앱이 여름·겨울·봄에 그리는 지도와 풀숲(PlazaWindowController.seasonLook 과 같은 조립).
    func bundledLook(_ season: PlazaSeason) throws -> (map: PlazaImage, grass: PlazaImage) {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let look = PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grassSheet, season: season)
        return (look.mapImage, PlazaSeasonSheet.tallGrass(grassSheet, season: season))
    }

    static let pinnedLooks: [PlazaSeason: (map: String, grass: String)] = [
        .summer: (map: "949e959dca07032e73fc0843305a40c4bca7514195ffdf201dba83371c2f9ffb", grass: "6a3c1c6329d9029f65e6303e24b00c537686505d6dc52eb9cdd4434a094824de"),
        .winter: (map: "d889e407fd03342b2e9aa0ddf860e01d907b42a057a3c3e3406974486f5e0ee5", grass: "fede76052d863a299d449e9167dded7865c4df4d464999a3ea3ff67dd6144a8a"),
        .spring: (map: "7fcc5153081c42df66328ce4884fe5cbcfe0b0c1409e1c918f60372de0ac86f5", grass: "6a3c1c6329d9029f65e6303e24b00c537686505d6dc52eb9cdd4434a094824de"),
    ]

    func testSummerWinterAndSpringLooksAreUnchanged() async throws {
        for season in [PlazaSeason.summer, .winter, .spring] {
            let look = try bundledLook(season)
            let map = PlazaParityGoldens.sha256Hex(look.map.pixels.bytes), grass = PlazaParityGoldens.sha256Hex(look.grass.pixels.bytes)
            XCTAssertEqual(map, Self.pinnedLooks[season]?.map, "\(season) map \(map)")
            XCTAssertEqual(grass, Self.pinnedLooks[season]?.grass, "\(season) grass \(grass)")
        }
    }

    func testSummerThrowsTheWaterBalloonPictureAsItIsAndOnlyInSummer() async throws {
        let balloon = try XCTUnwrap(BundledArt.image(PlazaResources.waterBalloonName), "the bundled picture loads")
        XCTAssertEqual([balloon.width, balloon.height], [14, 18])
        let art = PlazaSnowballArt.art(.summer, ball: balloon)
        XCTAssertTrue(art.ball.image === balloon)
        XCTAssertEqual(art.ball.scale, 1, "one picture pixel is one world pixel")
        XCTAssertFalse(art.burst.contains { $0.image === balloon })
        XCTAssertEqual(art.burst.map { $0.image.pixels.bytes }, PlazaSnowballArt.art(.summer).burst.map { $0.image.pixels.bytes })
        XCTAssertEqual(PlazaResources.ballName(.summer), PlazaResources.waterBalloonName)
    }

    func testEachSeasonNamesItsOwnBallFile() async {
        let names = PlazaSeason.allCases.map { PlazaResources.ballName($0) }
        XCTAssertEqual(PlazaResources.ballName(.winter), "plaza-snowball")
        XCTAssertEqual(PlazaResources.ballName(.spring), "plaza-petal-ball")
        XCTAssertEqual(PlazaResources.ballName(.summer), "plaza-water-balloon")
        XCTAssertEqual(PlazaResources.ballName(.autumn), "plaza-leaf-ball")
        XCTAssertEqual(Set(names).count, 4)
    }

    /// 장면이 처음 보이는 계절은 여름이다. 팀이 다른 계절을 골라 둔 광장을 열어도(첫 라운드는 고른 적 없는 겨울)
    /// 처음 던지는 공부터 그 계절 것이어야 한다. 파일이 없는 계절은 눈 격자 공이다.
    func testEachSeasonThrowsItsBundledPictureOrItsGrid() async throws {
        let s = scene()
        s.refreshSnowDay()
        s.update(0)
        for (i, season) in [PlazaSeason.winter, .spring, .summer, .autumn].enumerated() {
            if i > 0 {
                s.seasonChoice = PlazaSeasonChoice(rawValue: season.rawValue) ?? .summer
            }
            XCTAssertEqual(s.shownSeason, season)
            s.playSnowball(by: nil, shot: PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))) {}
            let want = PlazaSnowballArt.art(season, ball: BundledArt.image(PlazaResources.ballName(season))).ball
            XCTAssertEqual(s.snowballBallImages.last?.pixels.bytes, want.image.pixels.bytes, "\(season)")
            XCTAssertEqual(s.snowballBallSizes.last, CGSize(width: CGFloat(want.image.width) * want.scale, height: CGFloat(want.image.height) * want.scale), "\(season)")
        }
    }

    func testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        XCTAssertTrue(PlazaSeasonSheet.tiles(sheet, season: .summer) === sheet)
        let spring = PlazaSeasonSheet.tiles(sheet, season: .spring), autumn = PlazaSeasonSheet.tiles(sheet, season: .autumn)
        XCTAssertTrue(SnowPixels.contains(spring, rgb: [0xF8BBCF, 0xFDDCE6, 0xE88DAC]), "pink trees")
        XCTAssertTrue(SnowPixels.contains(spring, rgb: [0xF2A0BC]), "pink flowers")
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0x8E9A44]), "olive ground")
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xB4462A]), "rust bushes")
        XCTAssertFalse(SnowPixels.contains(sheet, rgb: [0xF8BBCF, 0x8E9A44, 0xB4462A, 0xC8402A, 0xE07A2A, 0xF2A0BC]), "none of these is in the original")
        // 모든 조각의 바꿀 색이 실제로 그 칸에 있어야 한다. 없는 색은 조용히 아무것도 안 바꾼다.
        for season in [PlazaSeason.spring, .autumn] {
            for piece in PlazaSeasonSheet.tilePieces(season) {
                let only = PlazaSnowSheet.recolored(sheet, pieces: [piece])
                for to in Set(piece.colors.values) where !SnowPixels.contains(sheet, rgb: [to]) {
                    XCTAssertTrue(SnowPixels.contains(only, rgb: [to]), "\(season) \(String(to, radix: 16))")
                }
            }
        }
        let crop = try XCTUnwrap(sheet.cropping(to: PlazaPixelRect(x: 80, y: 256, width: 32, height: 32)))
        for colors in PlazaSeasonSheet.treeColors(.autumn) {
            let only = PlazaSnowSheet.recolored(crop, pieces: [(colors, [(0, 0), (1, 0), (0, 1), (1, 1)])])
            for to in Set(colors.values) where !SnowPixels.contains(crop, rgb: [to]) {
                XCTAssertTrue(SnowPixels.contains(only, rgb: [to]), "autumn tree \(String(to, radix: 16))")
            }
        }
    }

    func testTallGrassDriesBrownInAutumnAndStaysGreenInSpringAndSummer() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .spring) === sheet)
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .summer) === sheet)
        let autumn = PlazaSeasonSheet.tallGrass(sheet, season: .autumn)
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xC8A050, 0x9A6A2C, 0x5E4220]))
        XCTAssertFalse(SnowPixels.contains(autumn, rgb: [0x99E550, 0x6ABE30, 0x4B692F]))
        XCTAssertFalse(SnowPixels.contains(PlazaSeasonSheet.tallGrass(sheet, season: .winter), rgb: [0x99E550, 0x6ABE30]))
    }

    // MARK: 가을 표(스펙 5.2 + 계획의 판정 1~3)가 시험쪽 기준표다

    private typealias Table = (colors: [UInt32: UInt32], cells: [(col: Int, row: Int)])
    private static let autumnGroundTable: [UInt32: UInt32] = [0x3ABE41: 0x8E9A44, 0x6ADD4B: 0xA8B052, 0x328E41: 0x6E7634, 0x29973B: 0x6E7634, 0x315740: 0x4A4626]
    private static let autumnTables: [(String, Table)] = [
        ("ground", (autumnGroundTable, PlazaTileArt.grassCells + PlazaTileArt.lilyCells)),
        ("shore", (autumnGroundTable.merging([0x266433: 0x4A4626]) { $1 }, PlazaPond.shoreCells)),
        ("flowers", ([0x328E41: 0x6E7634, 0xE8F8D0: 0xF6E7B0, 0x60D0C0: 0xD98A2A], PlazaTileArt.flowerCells)),
        ("bush", ([0x2ECA35: 0xB4462A, 0x62EB3D: 0xD86A34, 0x29973B: 0x7E3020, 0x2D5B3F: 0x4E1A12], [PlazaTileArt.bushCell])),
        ("sign", ([0x2ECA35: 0xB4462A, 0x29973B: 0x7E3020], [PlazaTileArt.signCell])),
    ]
    private static let autumnTreeTables: [[UInt32: UInt32]] = [
        [0x2ECA5C: 0xC8402A, 0x50EB6C: 0xE86A3A, 0x299750: 0x8E2A1C, 0x328E53: 0x7A2418, 0x2B7D4A: 0x6A2016, 0x2D5B43: 0x4E1A12],
        [0x2ECA5C: 0xE07A2A, 0x50EB6C: 0xF2A03C, 0x299750: 0xA8501A, 0x328E53: 0x96441A, 0x2B7D4A: 0x7E3A16, 0x2D5B43: 0x5A2A10],
        [0x2ECA5C: 0xD9A72A, 0x50EB6C: 0xF2C840, 0x299750: 0xA0741A, 0x328E53: 0x8C6418, 0x2B7D4A: 0x74521A, 0x2D5B43: 0x523A12],
    ]
    private static let autumnGrassTable: [UInt32: UInt32] = [0x99E550: 0xC8A050, 0x6ABE30: 0x9A6A2C, 0x4B692F: 0x5E4220]

    private func rgb(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) }

    /// `region` 안에서 표대로가 아닌 픽셀 수. 키 색의 불투명 픽셀은 값이 되고 나머지는 그대로여야 한다.
    private func mismatches(original: PlazaImage, recoloured: PlazaImage, colors: [UInt32: UInt32], region: (x: Int, y: Int, w: Int, h: Int)) -> Int {
        let o = original.pixels.bytes, r = recoloured.pixels.bytes
        var bad = 0
        for y in region.y..<(region.y + region.h) {
            for x in region.x..<(region.x + region.w) {
                let i = (y * original.width + x) * 4
                let want = o[i + 3] == 255 ? (colors[rgb(o, i)] ?? rgb(o, i)) : rgb(o, i)
                if r[i + 3] != o[i + 3] || rgb(r, i) != want { bad += 1 }
            }
        }
        return bad
    }

    func testAutumnRecoloursEveryCellByTheTable() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let tiles = PlazaSeasonSheet.tiles(sheet, season: .autumn)
        for (name, table) in Self.autumnTables {
            for c in table.cells {
                XCTAssertEqual(mismatches(original: sheet, recoloured: tiles, colors: table.colors, region: (c.col * 16, c.row * 16, 16, 16)), 0, "\(name) \(c)")
            }
        }
        let crop = try XCTUnwrap(sheet.cropping(to: PlazaPixelRect(x: 80, y: 256, width: 32, height: 32)))
        let trees = try XCTUnwrap(PlazaSeasonSheet.trees(sheet, season: .autumn))
        XCTAssertEqual(trees.count, 3)
        for (i, tree) in trees.enumerated() {
            XCTAssertEqual([tree.width, tree.height], [32, 32])
            XCTAssertEqual(mismatches(original: crop, recoloured: tree, colors: Self.autumnTreeTables[i], region: (0, 0, 32, 32)), 0, "tree \(i)")
        }
        let grass = PlazaSeasonSheet.tallGrass(grassSheet, season: .autumn)
        XCTAssertEqual(mismatches(original: grassSheet, recoloured: grass, colors: Self.autumnGrassTable, region: (0, 0, grassSheet.width, grassSheet.height)), 0, "tall grass")
        XCTAssertNil(PlazaSeasonSheet.trees(sheet, season: .spring))
        XCTAssertNil(PlazaSeasonSheet.trees(sheet, season: .winter))
    }

    /// 스펙 5.4: 땅·연잎·물가·꽃·덤불·팻말·나무·쓰는 풀숲 칸에 여름 초록이 한 픽셀도 남지 않는다.
    /// 여름 초록 = 원본 칸의 불투명 색 중 g > r, g > b 이고 (g − min(r, b)) × 10 ≥ g × 3 인 색(줄기 회색과 E8F8D0 제외).
    func testAutumnLeavesNoSummerGreen() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        func greens(_ image: PlazaImage, _ region: (x: Int, y: Int, w: Int, h: Int)) -> Set<UInt32> {
            let b = image.pixels.bytes
            var out = Set<UInt32>()
            for y in region.y..<(region.y + region.h) {
                for x in region.x..<(region.x + region.w) {
                    let i = (y * image.width + x) * 4
                    guard b[i + 3] == 255 else { continue }
                    let (r, g, bl) = (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
                    if g > r, g > bl, (g - min(r, bl)) * 10 >= g * 3 { out.insert(rgb(b, i)) }
                }
            }
            return out
        }
        let tiles = PlazaSeasonSheet.tiles(sheet, season: .autumn)
        let cells = PlazaTileArt.grassCells + PlazaTileArt.lilyCells + PlazaPond.shoreCells + PlazaTileArt.flowerCells
            + [PlazaTileArt.bushCell, PlazaTileArt.signCell]
        for c in cells {
            let region = (c.col * 16, c.row * 16, 16, 16)
            let left = greens(tiles, region).intersection(greens(sheet, region))
            XCTAssertEqual(left, [], "cell \(c) keeps summer green")
        }
        let crop = try XCTUnwrap(sheet.cropping(to: PlazaPixelRect(x: 80, y: 256, width: 32, height: 32)))
        let originalGreens = greens(crop, (0, 0, 32, 32))
        for (i, tree) in try XCTUnwrap(PlazaSeasonSheet.trees(sheet, season: .autumn)).enumerated() {
            XCTAssertEqual(greens(tree, (0, 0, 32, 32)).intersection(originalGreens), [], "maple/orange/ginkgo tree \(i) keeps summer green")
        }
        let grass = PlazaSeasonSheet.tallGrass(grassSheet, season: .autumn)
        let used = (0..<3).flatMap { col in (6..<9).map { (col: col, row: $0) } }
        for c in used {
            let region = (c.col * 16, c.row * 16, 16, 16)
            XCTAssertEqual(greens(grass, region).intersection(greens(grassSheet, region)), [], "tall grass \(c) keeps summer green")
        }
    }

    func testTheRealAutumnMapMixesAllThreeTrees() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        let look = PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grassSheet, season: .autumn)
        XCTAssertTrue(SnowPixels.contains(look.mapImage, rgb: [0xC8402A]), "maple")
        XCTAssertTrue(SnowPixels.contains(look.mapImage, rgb: [0xE07A2A]), "orange")
        XCTAssertTrue(SnowPixels.contains(look.mapImage, rgb: [0xD9A72A]), "ginkgo")
        XCTAssertFalse(SnowPixels.contains(look.mapImage, rgb: [0x2ECA5C, 0x50EB6C, 0x299750, 0x328E53, 0x2B7D4A, 0x2D5B43]), "no summer tree")
        let again = PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grassSheet, season: .autumn)
        XCTAssertEqual(look.mapImage.pixels.bytes, again.mapImage.pixels.bytes)
    }

    func testTheTeamsSeasonReachesThePlazaAndNamesWhatVThrows() async throws {
        var current: PlazaSchedule? = schedule("summer")
        let plaza = controller { current }
        plaza.prepareScene()
        let s = try XCTUnwrap(plaza.scene)
        XCTAssertEqual(s.shownSeason, .summer)
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertEqual(plaza.shortcutThrowLabel, "물풍선")
        s.update(0)
        s.handleKeyDown(keyCode: 9, characters: "v", isRepeat: false)
        XCTAssertEqual(s.snowballFlightCount, 1, "V throws in summer too")
        XCTAssertFalse(plaza.minimapShowsSnow)
        current = schedule("auto")
        plaza.applySchedule()
        XCTAssertEqual(s.shownSeason, .autumn)
        for word in ["winter", "week", "anything"] {
            current = schedule("spring")
            plaza.applySchedule()
            XCTAssertEqual(s.shownSeason, .spring)
            current = schedule(word)
            plaza.applySchedule()
            XCTAssertEqual(s.shownSeason, .winter, word)
            XCTAssertEqual(plaza.shortcutThrowLabel, "눈뭉치", word)
            XCTAssertTrue(plaza.minimapShowsSnow, word)
        }
        current = nil
        plaza.applySchedule()
        XCTAssertEqual(s.shownSeason, .winter, "never chosen")
        plaza.handleClose()
    }
}

extension PlazaSeasonTests {
    /// 장면이 처음 보이는 계절은 여름(원본 지도)이다. 팀이 여름을 골라 둔 광장을 열면 계절이 "바뀌지" 않으므로,
    /// 던지는 것도 처음부터 여름 것이어야 한다.
    func testAPlazaOpenedInSummerThrowsTheBalloonFromTheStart() async {
        let s = scene()
        s.seasonChoice = .summer
        s.refreshSnowDay()
        s.update(0)
        s.playSnowball(by: nil, shot: PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))) {}
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 14, height: 18)])
    }

    func testTheFlyingThingChangesWithTheSeason() async throws {
        let s = scene()
        s.refreshSnowDay()
        s.update(0)
        func ballSize() throws -> CGSize {
            let shot = PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))
            let before = Set(s.snowballBallSizes.map { "\($0)" })
            s.playSnowball(by: nil, shot: shot) {}
            return try XCTUnwrap(s.snowballBallSizes.first { !before.contains("\($0)") } ?? s.snowballBallSizes.last)
        }
        XCTAssertEqual(try ballSize(), CGSize(width: 16, height: 16), "a snowball is a 4×4 grid of 4-pixel cells")
        s.seasonChoice = .summer
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 14, height: 18)], "the ball already in the air turns too")
        XCTAssertEqual(try ballSize(), CGSize(width: 14, height: 18))
        s.seasonChoice = .autumn
        XCTAssertEqual(Set(s.snowballBallSizes.map { "\($0)" }).count, 1)
        XCTAssertEqual(s.snowballBallSizes.first, CGSize(width: 16, height: 16))
    }
}
