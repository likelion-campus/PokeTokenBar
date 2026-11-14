import XCTest
@testable import PokeTokenBar

private struct SeasonNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

@MainActor
final class PlazaSeasonTests: XCTestCase {
    let map = PlazaMapData.map
    var now = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 59, second: 59))!

    func scene(ice: Bool = false, start: TilePoint? = nil, iceArt: PlazaIceArt? = nil) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start ?? map.spawn, zoom: 2, nickname: "나",
                           pondVisuals: ice, iceArt: iceArt)
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        s.now = { [unowned self] in now }
        return s
    }

    // MARK: 모습

    func testEachSeasonShowsItsOwnMapAndWeatherAndSummerIsTheOriginal() async {
        let s = scene()
        let original = s.shownMapImage
        var looks: [PlazaSeason: PlazaImage] = [:]
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

    func testAutoTurnsWithTheCalendarWhileThePlazaIsOpen() async {
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

    func testFootprintsAreLeftOnlyInWinter() async {
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

    // MARK: 던지는 것

    private func colours(_ image: PlazaImage) -> Set<UInt32> {
        let raw = image.pixels.bytes
        var found = Set<UInt32>()
        for i in stride(from: 0, to: raw.count, by: 4) where raw[i + 3] == 255 {
            found.insert(UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]))
        }
        return found
    }

    func testEachSeasonThrowsItsOwnColoursInTheSnowballsShapes() async {
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

    func schedule(_ word: String) -> PlazaSchedule {
        PlazaSchedule(coreStart: 10, coreEnd: 16, seasonPeriod: word, changedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      changedBy: "m", changedByName: "민수")
    }

    func testChoosingASeasonIsStoredAsItsWordAndStampedOnce() async {
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
