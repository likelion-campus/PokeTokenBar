import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
final class PlazaScheduleWiringTests: XCTestCase {
    private let cal = PlazaWeather.gregorian

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func scene(at date: Date) -> PlazaScene {
        let map = PlazaMapData.map
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.backingOverride = 2
        s.size = CGSize(width: 800, height: 600)
        s.now = { date }
        return s
    }

    private func schedule(_ s: Int, _ e: Int, _ period: PlazaWeather.Period = .day) -> PlazaSchedule {
        PlazaSchedule(coreStart: s, coreEnd: e, seasonPeriod: period.rawValue, changedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      changedBy: "m", changedByName: "민수")
    }

    private func controller(at now: @escaping () -> Date = Date.init, _ current: @escaping () -> PlazaSchedule?) -> PlazaWindowController {
        let suite = "ptb.test.schedule.wiring.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
                                     loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                     nickname: { "나" }, memberID: { "me" },
                                     subject: { .init(speciesID: 25, isShiny: false) }, schedule: current, clock: now)
    }

    func testApplyScheduleMovesTheDawnAndNullFallsBackToStandard() throws {
        var current: PlazaSchedule? = schedule(9, 18)
        let plaza = controller { current }
        plaza.prepareScene()
        let s = try XCTUnwrap(plaza.scene)
        s.now = { self.date(2026, 11, 5, 8, 30) }
        XCTAssertEqual(s.coreTime, PlazaCoreTime(start: 9, end: 18))
        XCTAssertEqual(s.daylightTint, PlazaDaylight.dawn, "08:30 is the dawn peak for core 9-18")
        current = nil
        plaza.applySchedule()
        XCTAssertEqual(s.coreTime, .standard)
        XCTAssertEqual(s.daylightTint, PlazaDaylight.night, "08:30 is night for the default 10-16")
    }

    func testPrepareSceneDrawsTheTeamScheduleFromTheFirstFrame() throws {
        let plaza = controller(at: { self.date(2026, 11, 5, 8, 30) }) { self.schedule(9, 18) }
        plaza.prepareScene()
        let s = try XCTUnwrap(plaza.scene)
        assertTint(s.shownDaylight, PlazaDaylight.dawn)
    }

    private func assertTint(_ got: PlazaDaylight.Tint?, _ want: PlazaDaylight.Tint, _ msg: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let got else { return XCTFail("no tint. \(msg)", file: file, line: line) }
        XCTAssertEqual(got.red, want.red, accuracy: 0.01, msg, file: file, line: line)
        XCTAssertEqual(got.green, want.green, accuracy: 0.01, msg, file: file, line: line)
        XCTAssertEqual(got.blue, want.blue, accuracy: 0.01, msg, file: file, line: line)
    }

    func testSchedulePropertiesRedrawAPausedScene() throws {
        let s = scene(at: date(2026, 11, 9, 8, 30))
        s.update(0)   // 한 번은 그려 화면 영역을 정한 뒤, 멈춘 장면에서 바꾼다
        s.isPaused = true
        s.coreTime = try XCTUnwrap(PlazaCoreTime(start: 9, end: 18))
        assertTint(s.shownDaylight, PlazaDaylight.dawn, "no update call")
        s.coreTime = .standard
        assertTint(s.shownDaylight, PlazaDaylight.night)
        // 하루 주기와 1주일 주기의 날씨가 다른 날을 찾는다.
        let day = try XCTUnwrap((0..<60).map { self.date(2026, 11, 9 + $0 % 20, 12) }.first {
            PlazaWeather.kind(on: $0, period: .day) != PlazaWeather.kind(on: $0, period: .month)
        })
        s.now = { day }
        s.weatherPeriod = .week
        s.weatherPeriod = .day
        XCTAssertEqual(s.weatherKind, PlazaWeather.kind(on: day, period: .day))
        s.weatherPeriod = .month
        XCTAssertEqual(s.weatherKind, PlazaWeather.kind(on: day, period: .month), "a new period shows its weather without update")
    }

    func testWeekPeriodHoldsTheWeatherForTheWholeWeek() {
        let s = scene(at: date(2026, 11, 9))
        s.weatherPeriod = .week
        s.update(0)
        let monday = s.weatherKind
        s.now = { self.date(2026, 11, 15, 23) }
        s.update(0.1)
        XCTAssertEqual(s.weatherKind, monday, "Mon to Sun is one week, and the day cache keys on the period")
        s.weatherPeriod = .day
        s.update(0.1)
        XCTAssertNotEqual(s.weatherKind, monday, "switching the period must not reuse the cached day")
    }

    func testMinimapModelGetsTheCoreTime() {
        let plaza = controller { self.schedule(8, 20) }
        plaza.prepareScene()
        XCTAssertEqual(plaza.minimapCoreTime, PlazaCoreTime(start: 8, end: 20))
    }

    func testLocalizedStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.teamHour(1), "1시")
        XCTAssertEqual(l.teamHour(23), "23시")
        XCTAssertEqual(l.teamScheduleDefaultCaption, "모든 팀원에게 같이 적용돼요 · 앞뒤 1시간은 노을이 져요")
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let when = l.teamScheduleDate(c.date(from: DateComponents(timeZone: c.timeZone, year: 2026, month: 11, day: 5, hour: 14, minute: 2))!,
                                      calendar: c)
        XCTAssertEqual(l.teamScheduleChangedCaption(name: "민수", when: when),
                       "모든 팀원에게 같이 적용돼요 · 민수님이 11월 5일 14:02에 바꿨어요")
        // 같은 포매터를 다시 쓰므로, 다른 시간대가 이전 설정에 묶이지 않는지 본다.
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(l.teamScheduleDate(c.date(from: DateComponents(timeZone: c.timeZone, year: 2026, month: 11, day: 5, hour: 14, minute: 2))!,
                                          calendar: la), "11월 4일 21:02")
        XCTAssertEqual(PlazaWeather.Period.allCases.map(l.teamWeatherPeriodName), ["하루", "1주일", "1개월"])
    }
}
