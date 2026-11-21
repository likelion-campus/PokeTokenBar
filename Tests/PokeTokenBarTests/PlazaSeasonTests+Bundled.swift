// PlazaSeasonTests+Bundled: the water balloon picture, the recoloured bundled sheets and the V line of the shortcut guide
import XCTest
@testable import PokeTokenBar

extension PlazaSeasonTests {
    /// 지금 앱이 여름·겨울·봄에 그리는 지도와 풀숲(PlazaWindowController.seasonLook 과 같은 조립).
    func bundledLook(_ season: PlazaSeason) throws -> (map: PlazaImage, grass: PlazaImage) {
        let sheet = try XCTUnwrap(PlatformPlaza.tileSheet()), grassSheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        if season == .summer {
            return (PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet, tallGrass: PlatformPlaza.tallGrassArt()), grassSheet)
        }
        let grass = PlazaSeasonSheet.tallGrass(grassSheet, season: season)
        let art = PlazaTallGrassArt(sheet: grass)
        return (PlazaTileArt.mapImage(PlazaMapData.map, sheet: PlazaSeasonSheet.tiles(sheet, season: season), tallGrass: art), grass)
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
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xE8832A, 0xC4521E]), "orange trees")
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xC9B458]), "straw ground")
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xD9A72A]), "golden bushes")
        XCTAssertFalse(SnowPixels.contains(sheet, rgb: [0xF8BBCF, 0xE8832A, 0xC9B458, 0xD9A72A, 0xF2A0BC]), "none of these is in the original")
        // 모든 조각의 바꿀 색이 실제로 그 칸에 있어야 한다. 없는 색은 조용히 아무것도 안 바꾼다.
        for season in [PlazaSeason.spring, .autumn] {
            for piece in PlazaSeasonSheet.tilePieces(season) {
                let only = PlazaSnowSheet.recolored(sheet, pieces: [piece])
                for to in Set(piece.colors.values) where !SnowPixels.contains(sheet, rgb: [to]) {
                    XCTAssertTrue(SnowPixels.contains(only, rgb: [to]), "\(season) \(String(to, radix: 16))")
                }
            }
        }
    }

    func testTallGrassTurnsGoldInAutumnAndStaysGreenInSpringAndSummer() async throws {
        let sheet = try XCTUnwrap(PlatformPlaza.tallGrassSheet())
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .spring) === sheet)
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .summer) === sheet)
        let autumn = PlazaSeasonSheet.tallGrass(sheet, season: .autumn)
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xF2C230]))
        XCTAssertFalse(SnowPixels.contains(autumn, rgb: [0x99E550, 0x6ABE30]))
        XCTAssertFalse(SnowPixels.contains(PlazaSeasonSheet.tallGrass(sheet, season: .winter), rgb: [0x99E550, 0x6ABE30]))
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
