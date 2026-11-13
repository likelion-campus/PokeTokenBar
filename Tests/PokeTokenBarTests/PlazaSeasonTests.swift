import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

private struct SeasonNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
final class PlazaSeasonTests: XCTestCase {
    private let map = PlazaMapData.map
    private var now = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 59, second: 59))!

    private func scene(ice: Bool = false, start: TilePoint? = nil) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start ?? map.spawn, zoom: 2, nickname: "나",
                           pondVisuals: ice, iceArt: ice ? PlazaIceArt.load() : nil)
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        s.now = { [unowned self] in now }
        return s
    }

    // MARK: 모습

    func testEachSeasonShowsItsOwnMapAndWeatherAndSummerIsTheOriginal() {
        let s = scene()
        let original = s.shownMapImage
        var looks: [PlazaSeason: CGImage] = [:]
        for season in [PlazaSeason.spring, .autumn, .winter] { looks[season] = PlazaTileArt.plainGrassImage(map) }
        var seen: [PlazaSeason] = []
        s.seasonLook = { season in looks[season].map { PlazaSnowLook(mapImage: $0, tallGrass: nil) } }
        s.onSeasonChange = { seen.append($0) }
        s.refreshSnowDay()
        s.update(0)
        XCTAssertTrue(s.shownMapImage === looks[.winter], "a team that never chose stays in winter")
        XCTAssertEqual(s.weatherKind, .snow)
        for (choice, season, weather) in [(PlazaSeasonChoice.spring, PlazaSeason.spring, PlazaWeather.Kind.petals),
                                          (.summer, .summer, .greenLeaves), (.autumn, .autumn, .leaves), (.winter, .winter, .snow)] {
            s.seasonChoice = choice
            XCTAssertEqual(s.shownSeason, season)
            XCTAssertTrue(s.shownMapImage === (looks[season] ?? original), "\(season)")
            XCTAssertEqual(s.weatherKind, weather, "\(season)")
            XCTAssertEqual(s.isSnowShown, season == .winter)
        }
        XCTAssertEqual(seen, [.winter, .spring, .summer, .autumn, .winter])
    }

    func testAutoTurnsWithTheCalendarWhileThePlazaIsOpen() {
        let s = scene()
        s.seasonChoice = .auto
        s.update(0)
        XCTAssertEqual(s.shownSeason, .autumn, "30 November")
        XCTAssertEqual(s.weatherKind, .leaves)
        now = now.addingTimeInterval(1)
        s.update(1)
        XCTAssertEqual(s.shownSeason, .winter, "1 December")
        XCTAssertEqual(s.weatherKind, .snow)
    }

    func testFootprintsAreLeftOnlyInWinter() {
        let s = scene(start: TilePoint(x: 4, y: 14))
        s.refreshSnowDay()
        s.update(0)
        var t: TimeInterval = 0
        func step(_ key: UInt16) {
            s.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
            s.handleKeyUp(keyCode: key)
            for _ in 0..<4 { t += 0.05; s.update(t) }
        }
        step(126)
        XCTAssertEqual(s.footprintCount, 2)
        s.seasonChoice = .autumn
        XCTAssertEqual(s.footprintCount, 0, "the prints go with the snow")
        step(125)
        XCTAssertEqual(s.footprintCount, 0)
    }

    // MARK: 연못

    func testThePondFreezesOnlyInWinter() throws {
        let s = scene(ice: true)
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
        let s = scene(ice: true)
        s.seasonChoice = .summer
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor)
        s.update(1)
        XCTAssertNil(s.frozenPondAnchor)
    }

    func testAnIceBreakLearnedInAWarmSeasonDoesNotFreezeOrKeepRedrawing() throws {
        let s = scene(ice: true)
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
        let s = scene(ice: true)
        s.seasonChoice = .auto
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertNil(s.frozenPondAnchor, "30 November")
        now = now.addingTimeInterval(1)
        s.update(1)
        XCTAssertNotNil(s.frozenPondAnchor, "1 December")
    }

    func testWhoStandsOnTheIceFallsInWhenTheSeasonTurns() throws {
        let probe = scene(ice: true)
        probe.setIceBreak(nil)
        let anchor = try XCTUnwrap(probe.frozenPondAnchor)
        let s = scene(ice: true, start: anchor)
        s.setIceBreak(nil)
        s.update(0)
        XCTAssertTrue(s.isMeOnIce)
        s.seasonChoice = .spring
        XCTAssertFalse(s.isMeOnIce)
        XCTAssertTrue(s.isMeInWater)
    }

    // MARK: 던지는 것

    private func colours(_ image: CGImage) -> Set<UInt32> {
        let (w, h) = (image.width, image.height)
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var found = Set<UInt32>()
        for i in stride(from: 0, to: raw.count, by: 4) where raw[i + 3] == 255 {
            found.insert(UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]))
        }
        return found
    }

    func testEachSeasonThrowsItsOwnColoursInTheSnowballsShapes() {
        let snow = PlazaSnowballArt.pieces(.winter)
        let want: [PlazaSeason: Set<UInt32>] = [.spring: [0xFDDCE6, 0xF2A0BC, 0xB85A80], .summer: [0xD6F0FF, 0x6CB8F0, 0x2E78C0],
                                                .autumn: [0xF2A63C, 0xC4521E, 0x6E3A10], .winter: [0xF6FAFF, 0xC6DAF0, 0x8DA3BF]]
        for season in PlazaSeason.allCases {
            let pieces = PlazaSnowballArt.pieces(season)
            XCTAssertEqual(pieces.map(\.scale), [4, 4, 4])
            XCTAssertEqual(pieces.map(\.image.width), snow.map(\.image.width), "\(season)")
            XCTAssertEqual(pieces.map(\.image.height), snow.map(\.image.height), "\(season)")
            XCTAssertEqual(pieces.map { colours($0.image) }.reduce(Set()) { $0.union($1) }, want[season], "\(season)")
        }
    }

    func testSummerThrowsTheWaterBalloonPictureAsItIsAndOnlyInSummer() throws {
        let balloon = try XCTUnwrap(PlazaResources.waterBalloon(), "the bundled picture loads")
        XCTAssertEqual([balloon.width, balloon.height], [14, 18])
        let summer = PlazaSnowballArt.pieces(.summer, balloon: balloon)
        XCTAssertTrue(summer[0].image === balloon)
        XCTAssertEqual(summer.map(\.scale), [1, 4, 4], "one picture pixel is one world pixel; the droplets keep the grid scale")
        for season in [PlazaSeason.spring, .autumn, .winter] {
            XCTAssertFalse(PlazaSnowballArt.pieces(season, balloon: balloon).contains { $0.image === balloon }, "\(season)")
        }
    }

    /// 장면이 처음 보이는 계절은 여름(원본 지도)이다. 팀이 여름을 골라 둔 광장을 열면 계절이 "바뀌지" 않으므로,
    /// 던지는 것도 처음부터 여름 것이어야 한다.
    func testAPlazaOpenedInSummerThrowsTheBalloonFromTheStart() {
        let s = scene()
        s.seasonChoice = .summer
        s.refreshSnowDay()
        s.update(0)
        s.playSnowball(by: nil, shot: PlazaSnowballShot(from: map.spawn, direction: .up, end: .ground(TilePoint(x: map.spawn.x, y: map.spawn.y - 3)))) {}
        XCTAssertEqual(s.snowballBallSizes, [CGSize(width: 14, height: 18)])
    }

    func testTheFlyingThingChangesWithTheSeason() throws {
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

    // MARK: 색

    func testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone() throws {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
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
        let sheet = try XCTUnwrap(PlazaResources.tallGrassSheet())
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

    private func schedule(_ word: String) -> PlazaSchedule {
        PlazaSchedule(coreStart: 10, coreEnd: 16, seasonPeriod: word, changedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      changedBy: "m", changedByName: "민수")
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

    func testChoosingASeasonIsStoredAsItsWordAndStampedOnce() {
        let s = TeamSettings(defaults: TestDefaults.make(suite: "ptb.test.season.settings.\(UUID().uuidString)"))
        var rng = SystemRandomNumberGenerator()
        s.code = TeamCode.generate(using: &rng)
        s.changeSchedule(coreStart: 10, coreEnd: 16, season: .winter, now: Date(timeIntervalSince1970: 1))
        XCTAssertNil(s.schedule, "winter with the standard hours is what a team that never chose has")
        s.changeSchedule(coreStart: 10, coreEnd: 16, season: .auto, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(s.schedule?.seasonPeriod, "auto")
        XCTAssertEqual(s.schedule?.season, .auto)
        let stamp = s.schedule?.changedAt
        s.changeSchedule(coreStart: 10, coreEnd: 16, season: .auto, now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(s.schedule?.changedAt, stamp)
        s.changeSchedule(coreStart: 10, coreEnd: 16, season: .autumn, now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(s.schedule?.seasonPeriod, "autumn")
        XCTAssertNotEqual(s.schedule?.changedAt, stamp)
    }
}
