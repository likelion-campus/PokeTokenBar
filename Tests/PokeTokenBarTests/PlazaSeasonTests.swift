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

    func testEachSeasonsGridBallAndBurstUseOnlyArtThePlazaHas() async {
        let snow = PlazaWeatherArt.grids(.snow)
        let petals = PlazaWeatherArt.images(.petals), leaves = PlazaWeatherArt.images(.leaves)
        for season in PlazaSeason.allCases {
            let art = PlazaSnowballArt.art(season)
            let grid = PlazaWeatherArt.image(PlazaSnowballArt.shaded(snow[0]), palette: PlazaSnowballArt.palette(season))
            XCTAssertEqual(art.ball.image.pixels.bytes, grid.pixels.bytes, "\(season) ball")
            XCTAssertEqual(art.ball.scale, 4)
            let want: [PlazaImage] = switch season {
            case .winter, .summer: snow.map { PlazaWeatherArt.image(PlazaSnowballArt.shaded($0), palette: PlazaSnowballArt.palette(season)) }
            case .spring: [petals[0], petals[1], petals[0]]
            case .autumn: [leaves[0], leaves[2], leaves[4]]
            }
            XCTAssertEqual(art.burst.map { $0.image.pixels.bytes }, want.map { $0.pixels.bytes }, "\(season) burst")
            XCTAssertEqual(art.burst.map(\.scale), [4, 4, 4])
        }
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
