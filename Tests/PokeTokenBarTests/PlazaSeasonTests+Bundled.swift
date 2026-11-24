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

    /// PR 4: the right pond is the hot spring; outside it the maps are unchanged (`PlazaTileArtTests.testOnlyTheHotSpringChangedTheMap`).
    static let pinnedLooks: [PlazaSeason: (map: String, grass: String)] = [
        .summer: (map: "5a2a7c4537d79d1d5907248978890e0be939c92d7486d67861d291b722a80b71", grass: "6a3c1c6329d9029f65e6303e24b00c537686505d6dc52eb9cdd4434a094824de"),
        .winter: (map: "6409e791a81e549e7d9af7617ab415b5c384fa9cea7267a82a9ee46838898102", grass: "fede76052d863a299d449e9167dded7865c4df4d464999a3ea3ff67dd6144a8a"),
        .spring: (map: "a4865d531b88015ac2da345db542487184ec6bd6542314c793acaa9e98802920", grass: "6a3c1c6329d9029f65e6303e24b00c537686505d6dc52eb9cdd4434a094824de"),
    ]

    /// 여름 초록의 정의(스펙 5.4)에 드는 불투명 색.
    private func stoneGreens(_ image: PlazaImage, _ c: (col: Int, row: Int)) -> Set<UInt32> {
        let b = image.pixels.bytes
        var out = Set<UInt32>()
        for y in (c.row * 16)..<(c.row * 16 + 16) { for x in (c.col * 16)..<(c.col * 16 + 16) {
            let i = (y * image.width + x) * 4
            guard b[i + 3] == 255 else { continue }
            let (r, g, bl) = (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
            if g > r, g > bl, (g - min(r, bl)) * 10 >= g * 3 { out.insert(UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])) }
        } }
        return out
    }

    func testTheHotSpringStonesKeepNoSummerGreenInWinter() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        let winter = PlazaSeasonSheet.tiles(sheet, season: .winter)
        for c in PlazaHotSpring.bankStoneCells {
            XCTAssertFalse(stoneGreens(sheet, c).isEmpty, "the stone \(c) is green in the original")
            XCTAssertEqual(stoneGreens(winter, c).intersection(stoneGreens(sheet, c)), [], "winter stone \(c)")
        }
    }

    func testSpringAndSummerStonesStayGreenLikeTheGround() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        for season in [PlazaSeason.spring, .summer] {
            let tiles = PlazaSeasonSheet.tiles(sheet, season: season)
            for c in PlazaHotSpring.bankStoneCells {
                for y in (c.row * 16)..<(c.row * 16 + 16) { for x in (c.col * 16)..<(c.col * 16 + 16) {
                    let i = (y * sheet.width + x) * 4
                    XCTAssertEqual(Array(tiles.pixels.bytes[i..<i + 4]), Array(sheet.pixels.bytes[i..<i + 4]), "\(season) stone \(c)")
                } }
            }
        }
    }

    func testSummerWinterAndSpringLooksAreUnchanged() async throws {
        for season in [PlazaSeason.summer, .winter, .spring] {
            let look = try bundledLook(season)
            let map = PlazaParityGoldens.sha256Hex(look.map.pixels.bytes), grass = PlazaParityGoldens.sha256Hex(look.grass.pixels.bytes)
            XCTAssertEqual(map, Self.pinnedLooks[season]?.map, "\(season) map \(map)")
            XCTAssertEqual(grass, Self.pinnedLooks[season]?.grass, "\(season) grass \(grass)")
        }
    }

    func testSummerThrowsTheFiveBalloonsAsTheyAre() async throws {
        let sheet = try XCTUnwrap(BundledArt.image(PlazaResources.balloonSheetName), "the bundled strip loads")
        XCTAssertEqual([sheet.width, sheet.height], [80, 21])
        let sources = PlazaResources.ballSources(.summer)
        XCTAssertEqual(sources.map(\.name), Array(repeating: "plaza-balloons", count: 5))
        XCTAssertEqual(sources.map(\.crop), (0..<5).map { PlazaPixelRect(x: 16 * $0, y: 0, width: 16, height: 21) })
        let cells = try sources.map { try XCTUnwrap(sheet.cropping(to: try XCTUnwrap($0.crop))) }
        XCTAssertEqual(Set(cells.map { PlazaParityGoldens.sha256Hex($0.pixels.bytes) }).count, 5, "five different balloons")
        // Each cell is one whole balloon: its body colour fills the middle, and nothing of a neighbour is in it.
        let bodies: [(r: UInt8, g: UInt8, b: UInt8)] = cells.map { let p = $0.pixels.bytes, i = (10 * 16 + 5) * 4; return (p[i], p[i + 1], p[i + 2]) }
        XCTAssertTrue(bodies[0].r > 200 && bodies[0].g < 80 && bodies[0].b < 80, "red \(bodies[0])")
        XCTAssertTrue(bodies[1].b > 200 && bodies[1].r < 80, "blue \(bodies[1])")
        XCTAssertTrue(bodies[2].g > 200 && bodies[2].r < 80 && bodies[2].b < 80, "green \(bodies[2])")
        XCTAssertTrue(bodies[3].r > 200 && bodies[3].g > 180 && bodies[3].b < 80, "yellow \(bodies[3])")
        XCTAssertTrue(bodies[4].b > 200 && bodies[4].r > 80 && bodies[4].g < 80, "purple \(bodies[4])")
        XCTAssertEqual(sources.map(\.scale), [2, 2, 2, 2, 2], "one picture pixel is two world pixels")
        let art = PlazaSnowballArt.art(.summer, balls: cells.map { ($0, 2) })
        XCTAssertTrue(zip(art.balls, cells).allSatisfy { $0.image === $1 })
        XCTAssertEqual(art.balls.map(\.scale), [2, 2, 2, 2, 2])
        XCTAssertFalse(art.burst.contains { piece in cells.contains { $0 === piece.image } })
        XCTAssertEqual(art.burst.map { $0.image.pixels.bytes }, PlazaSnowballArt.art(.summer).burst.map { $0.image.pixels.bytes })
    }

    func testEachSeasonHasItsBallSource() async {
        XCTAssertTrue(PlazaResources.ballSources(.winter).isEmpty, "winter keeps the grid snowball")
        let spring = PlazaResources.ballSources(.spring)
        XCTAssertEqual(spring.map(\.name), ["plaza-sakura"])
        XCTAssertEqual(spring.map(\.crop), [nil], "the whole file")
        XCTAssertEqual(spring.map(\.scale) + PlazaResources.ballSources(.autumn).map(\.scale), [1, 1], "one picture pixel is one world pixel")
        let autumn = PlazaResources.ballSources(.autumn)
        XCTAssertEqual(autumn.map(\.name), ["plaza-leaf-sheet"])
        XCTAssertEqual(autumn.map(\.crop), [PlazaPixelRect(x: 33, y: 33, width: 17, height: 15)])
    }

    /// 번들 그림에서 얻은 봄·가을 공의 픽셀 SHA-256(파일이나 자를 영역이 바뀌면 걸린다).
    static let pinnedCuts: [PlazaSeason: String] = [
        .spring: "cb2efa9a4751bc63218cc1bbbeae03030ec782682780b49dca021befcbb73ba3",
        .autumn: "74e7449c94e216ff0b62536fbba0edefbb15e88f0ee6044aa4c9e5103e695d7c",
    ]

    func testEverySeasonThrowsItsOwnBundledPicture() async throws {
        let grid = PlazaSnowballArt.art(.winter).ball
        XCTAssertEqual([grid.image.width, grid.image.height], [4, 4], "winter keeps the grid snowball")
        var cuts: [PlazaSeason: PlazaImage] = [:]
        for (season, size) in [(PlazaSeason.spring, [38, 34]), (.autumn, [17, 15])] {
            let sources = PlazaResources.ballSources(season)
            XCTAssertEqual(sources.count, 1, "\(season)")
            let file = try XCTUnwrap(BundledArt.image(sources[0].name), "\(season): the file is bundled")
            let cut = try XCTUnwrap(sources[0].crop.map { file.cropping(to: $0) } ?? file)
            XCTAssertEqual([cut.width, cut.height], size, "\(season)")
            XCTAssertEqual(PlazaParityGoldens.sha256Hex(cut.pixels.bytes), Self.pinnedCuts[season], "\(season) cut")
            XCTAssertTrue(PlazaSnowballArt.art(season, balls: [(cut, 1)]).ball.image === cut)
            cuts[season] = cut
        }
        // The blossom is only its two pinks: no outline, nothing see-through.
        let blossom = try XCTUnwrap(cuts[.spring]).pixels.bytes
        var colours = Set<[UInt8]>()
        for i in stride(from: 0, to: blossom.count, by: 4) where blossom[i + 3] > 0 { colours.insert(Array(blossom[i..<i + 4])) }
        XCTAssertEqual(colours, [[242, 184, 190, 255], [242, 84, 139, 255], [242, 23, 107, 255]])
        let balloons = try XCTUnwrap(BundledArt.image(PlazaResources.balloonSheetName))
        let balls = [grid.image] + cuts.values + PlazaResources.balloonFrames.compactMap { balloons.cropping(to: $0) }
        for season in PlazaSeason.allCases {
            for piece in PlazaSnowballArt.art(season).burst {
                XCTAssertFalse(balls.contains { $0.pixels.bytes == piece.image.pixels.bytes && $0 !== grid.image }, "\(season) burst piece equals a ball")
            }
        }
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
            // 기대하는 공은 ballSources 를 거치지 않고, 시험이 적은 파일 이름과 자를 영역으로 직접 만든다.
            // 겨울은 파일이 없다: 번들에 눈뭉치 파일이 있어도 격자 공이 그대로여야 한다.
            let balloons = BundledArt.image("plaza-balloons")
            let files: [PlazaImage?] = switch season {
            case .winter: []
            case .spring: [BundledArt.image("plaza-sakura")]
            case .summer: (0..<5).map { balloons?.cropping(to: PlazaPixelRect(x: 16 * $0, y: 0, width: 16, height: 21)) }
            case .autumn: [BundledArt.image("plaza-leaf-sheet")?.cropping(to: PlazaPixelRect(x: 33, y: 33, width: 17, height: 15))]
            }
            let want = PlazaSnowballArt.art(season, balls: try files.map { (try XCTUnwrap($0, "\(season)"), season == .summer ? 2 : 1) }).balls
            // 그림이 여럿인 계절은 던질 때마다 다음 그림이고, 다 쓰면 처음으로 돌아간다. 차례는 계절을 넘어 이어진다.
            let before = s.snowballBallImages.count
            for _ in 0...want.count {
                s.playSnowball(by: nil, shot: PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))) {}
            }
            let thrown = Array(s.snowballBallImages.dropFirst(before)), sizes = Array(s.snowballBallSizes.dropFirst(before))
            XCTAssertEqual(thrown.count, want.count + 1, "\(season)")
            let first = try XCTUnwrap(want.firstIndex { $0.image.pixels.bytes == thrown[0].pixels.bytes }, "\(season)")
            for (k, image) in thrown.enumerated() {
                let piece = want[(first + k) % want.count]
                XCTAssertEqual(image.pixels.bytes, piece.image.pixels.bytes, "\(season) throw \(k)")
                XCTAssertEqual(sizes[k], CGSize(width: CGFloat(piece.image.width) * piece.scale, height: CGFloat(piece.image.height) * piece.scale), "\(season) throw \(k)")
            }
        }
    }

    func testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        XCTAssertTrue(PlazaSeasonSheet.tiles(sheet, season: .summer) === sheet)
        let spring = PlazaSeasonSheet.tiles(sheet, season: .spring), autumn = PlazaSeasonSheet.tiles(sheet, season: .autumn)
        XCTAssertTrue(SnowPixels.containsAll(spring, rgb: [0xF8BBCF, 0xFDDCE6, 0xE88DAC]), "pink trees")
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
        XCTAssertTrue(SnowPixels.containsAll(autumn, rgb: [0xC8A050, 0x9A6A2C, 0x5E4220]))
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
            + [PlazaTileArt.bushCell, PlazaTileArt.signCell] + PlazaHotSpring.bankStoneCells
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

    /// 여름 초록의 정의(스펙 5.4): g > r, g > b 이고 (g − min(r, b)) × 10 ≥ g × 3.
    private func summerGreens(_ image: PlazaImage) -> Set<UInt32> {
        let b = image.pixels.bytes
        var out = Set<UInt32>()
        for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] == 255 {
            let (r, g, bl) = (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
            if g > r, g > bl, (g - min(r, bl)) * 10 >= g * 3 { out.insert(rgb(b, i)) }
        }
        return out
    }

    /// 지도 전체 점검: 여름 지도가 그리는 초록이 가을 지도와 가을 풀숲 그림에 하나도 남지 않는다.
    /// 칸 목록에 없는데 `mapImage` 가 그리는 초록(목록 누락)이 여기서 걸린다. 허용 예외는 아래 `allowed` 에 칸과 이유를 적는다.
    func testTheWholeAutumnMapHasNoSummerGreen() async throws {
        let grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        // 온천의 청록 물(`PlazaHotSpring.waterColors` 의 값 둘)은 계절마다 같고 여름 초록의 정의에 들지만 원본 시트의 색이 아니다.
        let allowed: Set<UInt32> = [0x4FA8A0, 0x2F7C78]
        XCTAssertEqual(summerGreens(try XCTUnwrap(PlatformPlaza.tileSheet())).intersection(allowed), [], "the allowed colours are not the sheet's summer greens")
        let summer = try bundledLook(.summer), autumn = try bundledLook(.autumn)
        XCTAssertGreaterThan(summerGreens(summer.map).count, 5, "the summer map has greens to look for")
        XCTAssertEqual(summerGreens(autumn.map).intersection(summerGreens(summer.map)).subtracting(allowed).map { String($0, radix: 16) }.sorted(), [], "map")
        XCTAssertEqual(summerGreens(autumn.grass).intersection(summerGreens(grassSheet)).subtracting(allowed).map { String($0, radix: 16) }.sorted(), [], "tall grass sheet")
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
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 32, height: 42)])
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
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 32, height: 42)], "the ball already in the air turns too")
        XCTAssertEqual(try ballSize(), CGSize(width: 32, height: 42))
        s.seasonChoice = .autumn
        XCTAssertEqual(Set(s.snowballBallSizes.map { "\($0)" }).count, 1)
        XCTAssertEqual(s.snowballBallSizes.first, CGSize(width: 17, height: 15), "autumn throws the leaf clump")
    }

    /// The small map shows the tree (baked once per season) and still reads "snow" only in a snowy season.
    func testTheMinimapImageHasTheTreeAndKeepsTheSnowFlag() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet())
        let rects = PlazaTree.runs(in: PlazaMapData.map).compactMap { PlazaTree.artRect(of: $0) }
        XCTAssertEqual(rects.count, 2, "both trees are on the small map")
        var current: PlazaSchedule? = schedule("summer")
        let plaza = controller { current }
        plaza.prepareScene()
        let plain = PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet, tallGrass: PlatformPlaza.tallGrassArt())
        let summer = plaza.minimapImage(for: .summer)
        XCTAssertEqual(summer.width, plain.width)
        let (a, b, w) = (summer.pixels.bytes, plain.pixels.bytes, plain.width)
        var changed = [0, 0]
        for y in 0..<plain.height { for x in 0..<w where Array(a[(y * w + x) * 4..<(y * w + x) * 4 + 4]) != Array(b[(y * w + x) * 4..<(y * w + x) * 4 + 4]) {
            guard let i = rects.firstIndex(where: { $0.contains(CGPoint(x: x, y: y)) }) else { XCTFail("(\(x),\(y)) is outside both trees' rects"); continue }
            changed[i] += 1
        } }
        XCTAssertGreaterThan(changed[0], 1000, "the first pine is drawn")
        XCTAssertGreaterThan(changed[1], 1000, "the second pine is drawn")
        XCTAssertTrue(plaza.minimapImage(for: .summer) === summer, "baked once")
        XCTAssertNil(plaza.minimapSeasonImage)
        XCTAssertFalse(plaza.minimapShowsSnow)
        current = schedule("winter")
        plaza.applySchedule()
        XCTAssertTrue(plaza.minimapSeasonImage === plaza.minimapImage(for: .winter))
        XCTAssertTrue(plaza.minimapShowsSnow)
        // Only the current season's full-size picture is held (6 MB each), and the same pixels come back when another season was asked in between.
        let winter = plaza.minimapImage(for: .winter)
        _ = plaza.minimapImage(for: .summer)
        let again = plaza.minimapImage(for: .winter)
        XCTAssertFalse(again === winter, "the winter picture was released when summer was asked for")
        XCTAssertEqual(again.pixels.bytes, winter.pixels.bytes, "and baking it again gives the same pixels")
        // Closing the plaza releases the picture the small map held.
        plaza.handleClose()
        XCTAssertNil(plaza.minimapSeasonImage)
    }
}
