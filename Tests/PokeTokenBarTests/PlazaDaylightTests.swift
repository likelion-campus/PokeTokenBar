import XCTest
@testable import PokeTokenBar

@MainActor
final class PlazaDaylightTests: XCTestCase {
    typealias D = PlazaDaylight

    func at(_ hour: Int, _ minute: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
    }

    func testTintAtTheKeyTimes() async {
        XCTAssertEqual(D.tint(minute: 12 * 60), .none, "noon is untinted")
        XCTAssertEqual(D.tint(minute: 2 * 60), D.night)
        XCTAssertEqual(D.tint(minute: 23 * 60 + 59), D.night)
        // 코어타임(10~16시)은 내내 밝다.
        XCTAssertEqual(D.tint(minute: 10 * 60), .none, "bright from 10:00")
        XCTAssertEqual(D.tint(minute: 16 * 60), .none, "still bright at 16:00; the evening glow starts fading in")
        XCTAssertEqual(D.tint(minute: 16 * 60 + 30), D.dusk, "orange at its deepest at 16:30")
        let five = D.tint(minute: 17 * 60)
        for (got, want) in [(five.red, D.night.red), (five.green, D.night.green), (five.blue, D.night.blue)] {
            XCTAssertEqual(got, want, accuracy: 1e-9, "dark from 17:00")
        }
        XCTAssertEqual(D.tint(minute: 9 * 60), D.night, "still dark at 9:00")
        XCTAssertEqual(D.tint(minute: 9 * 60 + 30), D.dawn, "the morning glow is deepest at 9:30")
        XCTAssertEqual(D.tint(minute: 7 * 60), D.night, "dark before the morning glow")
        XCTAssertEqual(D.tint(minute: 0), D.tint(minute: 24 * 60), "midnight meets itself")
    }

    /// Each glow fades in and out over half an hour, so a quarter past is halfway between.
    func testFadeIsHalfwayAtTheQuarterHour() async {
        let half = D.tint(minute: 16 * 60 + 15)
        XCTAssertEqual(half.red, (1 + D.dusk.red) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.blue, (1 + D.dusk.blue) / 2, accuracy: 1e-9)
        let morning = D.tint(minute: 9 * 60 + 45)
        XCTAssertEqual(morning.green, (D.dawn.green + 1) / 2, accuracy: 1e-9)
    }

    /// Night is the darkest time and the evening is warm: red is kept more than blue.
    func testNightIsDarkestAndEveningIsWarm() async {
        let all = (0..<(24 * 60)).map { D.tint(minute: Double($0)) }
        let darkest = all.min { $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue }
        XCTAssertEqual(darkest, D.night)
        XCTAssertGreaterThan(D.dusk.red, D.dusk.blue)
        XCTAssertGreaterThan(D.night.blue, D.night.red, "night is blue")
    }

    /// No jumps: a minute later is never much darker or lighter. The steepest fade (evening glow to night over half an
    /// hour) moves the three channels by about 0.035 a minute.
    func testTintChangesSmoothlyAllDay() async {
        var last = D.tint(minute: 0)
        for m in 1...(24 * 60) {
            let t = D.tint(minute: Double(m))
            XCTAssertLessThan(abs(t.red - last.red) + abs(t.green - last.green) + abs(t.blue - last.blue), 0.04, "minute \(m)")
            last = t
        }
    }

    /// The minimap loses colour toward night, smoothly, and is untouched by day.
    func testMinimapSaturationFollowsTheTime() async {
        XCTAssertEqual(D.minimapSaturation(minute: 12 * 60), 1)
        XCTAssertEqual(D.minimapSaturation(minute: 22 * 60), 0.65)
        XCTAssertEqual(D.minimapSaturation(minute: 16 * 60 + 30), 0.95)
        XCTAssertEqual(D.minimapSaturation(minute: 17 * 60), 0.65)
        XCTAssertEqual(D.minimapSaturation(minute: 9 * 60 + 30), 0.85)
        let all = (0...(24 * 60)).map { D.minimapSaturation(minute: Double($0)) }
        XCTAssertEqual(all.min(), 0.65, "night is the greyest")
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { abs($0 - $1) < 0.011 }, "no jumps")
    }

    func testPhaseBoundaries() async {
        let cases: [(Int, Int, D.Phase)] = [(8, 59, .night), (9, 0, .dawn), (9, 59, .dawn), (10, 0, .day), (15, 59, .day),
                                             (16, 0, .dusk), (16, 59, .dusk), (17, 0, .night), (0, 0, .night), (7, 0, .night)]
        for (h, m, phase) in cases {
            XCTAssertEqual(D.phase(minute: Double(h * 60 + m)), phase, "\(h):\(m)")
        }
    }

    func testClockTextShowsThePhaseAndTwentyFourHourTime() async {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(D.clockText(at(21, 34, calendar: seoul), calendar: seoul), "밤 21:34")
        XCTAssertEqual(D.clockText(at(10, 5, calendar: seoul), calendar: seoul), "낮 10:05")
        XCTAssertEqual(D.clockText(at(9, 30, calendar: seoul), calendar: seoul), "아침 09:30")
        XCTAssertEqual(D.clockText(at(16, 30, calendar: seoul), calendar: seoul), "저녁 16:30")
        XCTAssertEqual(D.clockText(at(17, 0, calendar: seoul), calendar: seoul), "밤 17:00")
        XCTAssertEqual(D.clockText(at(7, 5, calendar: seoul), calendar: seoul), "밤 07:05")
    }

    private func scene(at date: Date) -> PlazaScene {
        let map = PlazaMapData.map
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.size = CGSize(width: 400, height: 300)
        s.now = { date }
        return s
    }

    /// The plaza is tinted by this Mac's time, and not at all while the background is hidden (the window shows the
    /// desktop then, which a tint would darken).
    func testSceneTintFollowsTheTimeAndSkipsAHiddenBackground() async {
        let night = scene(at: at(22, 0))
        night.update(0)
        func close(_ a: D.Tint?, _ b: D.Tint) -> Bool {
            guard let a else { return false }
            return abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue) < 0.01
        }
        XCTAssertTrue(close(night.shownDaylight, D.night))
        night.setBackgroundHidden(true)
        XCTAssertNil(night.shownDaylight)
        XCTAssertEqual(night.daylightTint, .none, "and the photo is not tinted either")
        night.setBackgroundHidden(false)
        XCTAssertTrue(close(night.shownDaylight, D.night))
        let noon = scene(at: at(12, 0))
        noon.update(0)
        XCTAssertNil(noon.shownDaylight)
    }

    func testPhotoOfANightPlazaIsTintedToo() async throws {
        let s = scene(at: at(22, 0))
        s.update(0)
        XCTAssertEqual(try XCTUnwrap(s.photoInput()).tint, D.night)
    }

    // MARK: 코어타임 변경

    func testCustomCoreTimeMovesTheGlows() async throws {
        let core = try XCTUnwrap(PlazaCoreTime(start: 9, end: 18))
        XCTAssertEqual(D.tint(minute: 8 * 60 + 30, core: core), D.dawn)
        XCTAssertEqual(D.tint(minute: 9 * 60, core: core), .none)
        XCTAssertEqual(D.tint(minute: 18 * 60 + 30, core: core), D.dusk)
        let seven = D.tint(minute: 19 * 60, core: core)
        for (got, want) in [(seven.red, D.night.red), (seven.green, D.night.green), (seven.blue, D.night.blue)] {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
        XCTAssertEqual(D.tint(minute: 8 * 60, core: core), D.night)
        XCTAssertEqual(D.phase(minute: 8 * 60, core: core), .dawn)
        XCTAssertEqual(D.phase(minute: 9 * 60, core: core), .day)
        XCTAssertEqual(D.phase(minute: 17 * 60 + 59, core: core), .day)
        XCTAssertEqual(D.phase(minute: 18 * 60, core: core), .dusk)
        XCTAssertEqual(D.phase(minute: 19 * 60, core: core), .night)
    }

    func testEdgeCoreTimesStayInsideTheDay() async throws {
        for (s, e) in [(1, 23), (1, 2)] {
            let core = try XCTUnwrap(PlazaCoreTime(start: s, end: e))
            for m in stride(from: 0.0, through: 1440, by: 15) {
                let t = D.tint(minute: m, core: core)
                XCTAssertTrue([t.red, t.green, t.blue, D.minimapSaturation(minute: m, core: core)].allSatisfy(\.isFinite), "\(s)-\(e) at \(m)")
            }
        }
        let narrow = try XCTUnwrap(PlazaCoreTime(start: 1, end: 2))
        XCTAssertEqual(D.tint(minute: 0, core: narrow), D.night)
        XCTAssertEqual(D.tint(minute: 30, core: narrow), D.dawn)
        for m in [60.0, 90, 120] { XCTAssertEqual(D.tint(minute: m, core: narrow), .none, "at \(m)") }
        XCTAssertEqual(D.tint(minute: 150, core: narrow), D.dusk)
        let three = D.tint(minute: 180, core: narrow)   // the fade ends here, up to rounding
        XCTAssertEqual(three.red, D.night.red, accuracy: 1e-9)
        XCTAssertEqual(three.green, D.night.green, accuracy: 1e-9)
        XCTAssertEqual(three.blue, D.night.blue, accuracy: 1e-9)
        let wide = try XCTUnwrap(PlazaCoreTime(start: 1, end: 23))
        XCTAssertEqual(D.tint(minute: 0, core: wide), D.night)
        XCTAssertEqual(D.tint(minute: 30, core: wide), D.dawn)
        XCTAssertEqual(D.tint(minute: 23 * 60 + 30, core: wide), D.dusk)
    }

    func testCoreTimeRejectsBadRanges() async {
        XCTAssertNil(PlazaCoreTime(start: 0, end: 5))
        XCTAssertNil(PlazaCoreTime(start: 5, end: 5))
        XCTAssertNil(PlazaCoreTime(start: 6, end: 5))
        XCTAssertNil(PlazaCoreTime(start: 22, end: 24))
        XCTAssertNotNil(PlazaCoreTime(start: 22, end: 23))
        XCTAssertNotNil(PlazaCoreTime(start: 1, end: 2))
    }

    func testClockTextUsesTheCoreTime() async throws {
        let core = try XCTUnwrap(PlazaCoreTime(start: 9, end: 18))
        let seoul = Calendar(identifier: .gregorian)
        XCTAssertEqual(D.clockText(at(8, 30, calendar: seoul), calendar: seoul, core: core), "아침 08:30")
        XCTAssertEqual(D.clockText(at(17, 30, calendar: seoul), calendar: seoul, core: core), "낮 17:30")
    }
}
