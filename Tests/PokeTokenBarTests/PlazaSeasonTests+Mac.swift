import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

private struct SeasonNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaSeasonTests {

    // MARK: 연못

    func testThePondFreezesOnlyInWinter() throws {
        let s = scene(ice: true, iceArt: PlazaIceArt.load())
        s.setIceBreak(nil)
        s.update(0)
        let anchor = try XCTUnwrap(s.frozenPondAnchor)
        XCTAssertTrue(s.isWalkableNow(anchor))
        for choice in [PlazaSeasonChoice.spring, .summer, .autumn] {
            s.seasonChoice = choice
            XCTAssertNil(s.frozenPondAnchor, "\(choice)")
            XCTAssertFalse(s.isWalkableNow(anchor), "\(choice)")
            XCTAssertTrue(s.isWaterNow(anchor), "\(choice)")
            s.seasonChoice = .winter
            XCTAssertEqual(s.frozenPondAnchor, anchor, "back in winter")
        }
    }

    func testAWarmSeasonSetBeforeTheFirstFrameNeverShowsIce() {
        let s = scene(ice: true, iceArt: PlazaIceArt.load())
        s.seasonChoice = .summer
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor)
        s.update(1)
        XCTAssertNil(s.frozenPondAnchor)
    }

    func testAnIceBreakLearnedInAWarmSeasonDoesNotFreezeOrKeepRedrawing() throws {
        let s = scene(ice: true, iceArt: PlazaIceArt.load())
        s.seasonChoice = .summer
        let pond = try XCTUnwrap(PlazaIce.ponds(in: map).first)
        s.setIceBreak(PlazaIceBreak(at: now.timeIntervalSince1970 - 3600, pond: pond.anchor))
        s.update(0)
        let drawn = s.iceDrawCount
        for i in 1...10 { s.update(Double(i) / 60) }
        XCTAssertNil(s.frozenPondAnchor)
        XCTAssertEqual(s.iceDrawCount, drawn, "a refreeze that is long due must not redraw the ice every frame")
    }

    func testThePondFreezesWhenTheCalendarTurnsToWinter() {
        let s = scene(ice: true, iceArt: PlazaIceArt.load())
        s.seasonChoice = .auto
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor, "30 November")
        now = now.addingTimeInterval(1)
        s.update(1)
        XCTAssertNotNil(s.frozenPondAnchor, "1 December")
    }

    func testWhoStandsOnTheIceFallsInWhenTheSeasonTurns() throws {
        let probe = scene(ice: true, iceArt: PlazaIceArt.load())
        probe.setIceBreak(nil)
        let anchor = try XCTUnwrap(probe.frozenPondAnchor)
        let s = scene(ice: true, start: anchor, iceArt: PlazaIceArt.load())
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertTrue(s.isMeOnIce)
        s.seasonChoice = .spring
        XCTAssertFalse(s.isMeOnIce)
        XCTAssertTrue(s.isMeInWater)
    }

    func testSummerThrowsTheWaterBalloonPictureAsItIsAndOnlyInSummer() throws {
        let balloon = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.waterBalloon(), "the bundled picture loads"))
        XCTAssertEqual([balloon.width, balloon.height], [14, 18])
        let summer = PlazaSnowballArt.pieces(.summer, balloon: balloon)
        XCTAssertTrue(summer[0].image === balloon)
        XCTAssertEqual(summer.map(\.scale), [1, 4, 4], "one picture pixel is one world pixel; the droplets keep the grid scale")
        for season in [PlazaSeason.spring, .autumn, .winter] {
            XCTAssertFalse(PlazaSnowballArt.pieces(season, balloon: balloon).contains { $0.image === balloon }, "\(season)")
        }
    }

    // MARK: 색

    func testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone() throws {
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tileSheet()))
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

    func testTallGrassTurnsGoldInAutumnAndStaysGreenInSpringAndSummer() throws {
        let sheet = PlazaImage(cgImage: try XCTUnwrap(PlazaResources.tallGrassSheet()))
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .spring) === sheet)
        XCTAssertTrue(PlazaSeasonSheet.tallGrass(sheet, season: .summer) === sheet)
        let autumn = PlazaSeasonSheet.tallGrass(sheet, season: .autumn)
        XCTAssertTrue(SnowPixels.contains(autumn, rgb: [0xF2C230]))
        XCTAssertFalse(SnowPixels.contains(autumn, rgb: [0x99E550, 0x6ABE30]))
        XCTAssertFalse(SnowPixels.contains(PlazaSeasonSheet.tallGrass(sheet, season: .winter), rgb: [0x99E550, 0x6ABE30]))
    }

    // MARK: 팀 설정

    private func controller(_ current: @escaping () -> PlazaSchedule?) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "ptb.test.season.\(UUID().uuidString)")),
                              loader: PlazaCharacterLoader(fetcher: SeasonNoSprites()),
                              nickname: { "나" }, memberID: { "me" },
                              subject: { .init(speciesID: 25, isShiny: false) }, schedule: current, clock: { [unowned self] in now })
    }

    func testTheTeamsSeasonReachesThePlazaAndNamesWhatVThrows() throws {
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
