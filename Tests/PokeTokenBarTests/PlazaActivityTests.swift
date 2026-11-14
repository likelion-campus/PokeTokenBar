import XCTest
@testable import PokeTokenBar

/// Today's plaza activity: the counters, the day it belongs to, what a teammate may send, and the roster hover that shows it.
@MainActor
final class PlazaActivityTests: XCTestCase {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: - The pure counters

    func testDayKeyIsTheLocalDateAndRollsAtLocalMidnight() async {
        XCTAssertEqual(PlazaActivity.dayKey(date(13, 0, 0, 0), calendar: Self.calendar), "2026-11-13")
        XCTAssertEqual(PlazaActivity.dayKey(date(13, 23, 59, 59), calendar: Self.calendar), "2026-11-13")
        XCTAssertEqual(PlazaActivity.dayKey(date(14, 0, 0, 0), calendar: Self.calendar), "2026-11-14")
        XCTAssertEqual(PlazaActivity.dayKey(date(5, 9), calendar: Self.calendar), "2026-11-05", "padded, so it compares as text")
    }

    func testEachKindCountsItsOwnNumber() async {
        var a = PlazaActivity(day: "2026-11-13")
        for kind in [PlazaActivity.Kind.iceBreak, .firework, .tackle, .snowballHit, .greeting, .pickup] { a.record(kind) }
        a.record(.tackle)
        a.record(.pickup)
        a.record(.pickup)
        XCTAssertEqual([a.iceBreaks, a.fireworks, a.tackles, a.snowballHits, a.greetings, a.pickups], [1, 1, 2, 1, 1, 3])
        XCTAssertEqual(a.seconds, 0)
    }

    func testCountsAndTimeStopAtTheirCeilings() async {
        var a = PlazaActivity(day: "d")
        a.iceBreaks = PlazaActivity.maxCount
        a.record(.iceBreak)
        XCTAssertEqual(a.iceBreaks, PlazaActivity.maxCount)
        a.seconds = PlazaActivity.maxSeconds - 1
        a.addSeconds(5)
        XCTAssertEqual(a.seconds, PlazaActivity.maxSeconds)
        a.addSeconds(-1_000_000)
        XCTAssertEqual(a.seconds, PlazaActivity.maxSeconds, "time only grows")
    }

    func testANewDayStartsFromZeroAndTheSameDayKeepsEverything() async {
        var a = PlazaActivity(day: "2026-11-13")
        a.record(.firework)
        a.addSeconds(90)
        XCTAssertEqual(a.rolled(to: "2026-11-13"), a)
        let next = a.rolled(to: "2026-11-14")
        XCTAssertEqual(next, PlazaActivity(day: "2026-11-14"))
        XCTAssertEqual(next.fireworks, 0)
        XCTAssertEqual(next.seconds, 0)
    }

    func testReceivedValuesAreClamped() async {
        var a = PlazaActivity(day: "d")
        a.seconds = .max
        a.iceBreaks = .min
        a.fireworks = PlazaActivity.maxCount + 1
        a.tackles = -1
        a.snowballHits = .max
        a.greetings = 7
        a.pickups = PlazaActivity.maxCount
        let b = a.bounded
        XCTAssertEqual(b.seconds, PlazaActivity.maxSeconds)
        XCTAssertEqual([b.iceBreaks, b.fireworks, b.tackles, b.snowballHits, b.greetings, b.pickups],
                       [0, PlazaActivity.maxCount, 0, PlazaActivity.maxCount, 7, PlazaActivity.maxCount])
        a.seconds = -5
        XCTAssertEqual(a.bounded.seconds, 0)
        XCTAssertEqual(b.day, "d")
    }

    func testOnlyTodaysNumbersAreShown() async {
        var a = PlazaActivity(day: "2026-11-13")
        a.record(.greeting)
        XCTAssertEqual(a.shown(on: "2026-11-13"), a)
        XCTAssertNil(a.shown(on: "2026-11-14"), "yesterday's numbers are no record")
        XCTAssertNil(a.shown(on: "2026-11-12"), "a sender whose clock is a day behind is no record either")
    }

    func testCountsMatchIgnoresTimeOnly() async {
        var a = PlazaActivity(day: "d")
        var b = a
        b.addSeconds(60)
        XCTAssertTrue(a.countsMatch(b))
        b.record(.pickup)
        XCTAssertFalse(a.countsMatch(b))
        a.record(.pickup)
        XCTAssertTrue(a.countsMatch(b))
        XCTAssertFalse(a.countsMatch(PlazaActivity(day: "e")), "a new day is a change")
    }

    // MARK: - Rows

    func testRowsListTheSevenItemsInOrderWithReadableValues() async {
        var a = PlazaActivity(day: "d")
        a.seconds = 3_600 + 23 * 60 + 59
        a.iceBreaks = 4; a.fireworks = 12; a.tackles = 0; a.snowballHits = 7; a.greetings = 30; a.pickups = 2
        XCTAssertEqual(PlazaActivity.rows(a), [
            .init(label: "접속시간", value: "1시간 23분"),
            .init(label: "얼음 깬 횟수", value: "4"),
            .init(label: "폭죽", value: "12"),
            .init(label: "몸통박치기", value: "0"),
            .init(label: "던져서 맞힌 횟수", value: "7"),
            .init(label: "인사", value: "30"),
            .init(label: "주운 아이템", value: "2"),
        ])
    }

    func testTimeUnderAnHourShowsMinutesOnly() async {
        func time(_ seconds: Int) -> String {
            var a = PlazaActivity(day: "d")
            a.seconds = seconds
            return PlazaActivity.rows(a).first?.value ?? ""
        }
        XCTAssertEqual(time(12 * 60 + 30), "12분")
        XCTAssertEqual(time(59), "0분")
        XCTAssertEqual(time(3_599), "59분")
        XCTAssertEqual(time(3_600), "1시간 0분")
        XCTAssertEqual(time(PlazaActivity.maxSeconds), "24시간 0분")
    }

    func testNoActivityHasNoRows() async {
        XCTAssertTrue(PlazaActivity.rows(nil).isEmpty)
    }

    // MARK: - The roster slot

    func entry(_ id: String, activity: PlazaActivity? = nil, me: Bool = false) -> PlazaRosterEntry {
        PlazaRosterEntry(id: id, nickname: id, speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false,
                         presence: .online, isMe: me, activity: activity)
    }

    func testHoveringASlotSelectsItAndLeavingClearsIt() async {
        let model = PlazaRosterModel()
        XCTAssertNil(model.hoveredID)
        model.hover("a", inside: true)
        XCTAssertEqual(model.hoveredID, "a")
        model.hover("a", inside: false)
        XCTAssertNil(model.hoveredID, "the mouse-out collapses it")
    }

    func testALateLeaveFromTheOldSlotDoesNotCollapseTheNewOne() async {
        let model = PlazaRosterModel()
        model.hover("a", inside: true)
        model.hover("b", inside: true)
        model.hover("a", inside: false)
        XCTAssertEqual(model.hoveredID, "b")
    }

    func testTurningThePageDropsTheHover() async {
        let model = PlazaRosterModel()
        model.entries = (0..<8).map { entry("m\($0)") }
        model.hover("m0", inside: true)
        model.turnPage(by: 1)
        XCTAssertNil(model.hoveredID)
    }

    func testEntriesShowTodaysActivityAndNoRecordForOtherDaysAndOldVersions() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = PlazaActivity.dayKey(now)
        var fresh = PlazaActivity(day: today); fresh.record(.greeting)
        let stale = PlazaActivity(day: "1999-01-01")
        func member(_ id: String, _ a: PlazaActivity?) -> TeamMemberState {
            var m = TeamMemberState(memberID: id, nickname: id, character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "P", gender: nil),
                                    inPlaza: true, tile: nil, facing: nil, isWalking: false)
            m.activity = a
            return m
        }
        let list = PlazaRoster.entries(me: entry("me", me: true), myActivity: fresh,
                                       members: [member("a", fresh), member("b", stale), member("c", nil)], now: now)
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.activity) })
        XCTAssertEqual(byID["me"] ?? nil, fresh)
        XCTAssertEqual(byID["a"] ?? nil, fresh)
        XCTAssertNil(byID["b"] ?? nil, "another day")
        XCTAssertNil(byID["c"] ?? nil, "an earlier version")
        let mineStale = PlazaRoster.entries(me: entry("me", me: true), myActivity: stale, members: [], now: now)
        XCTAssertNil(mineStale.first?.activity, "mine from before midnight, not yet rolled")
    }

    // MARK: - The expanded slot stays above the minimap

    func shortList() -> [PlazaRosterEntry] {
        var a = PlazaActivity(day: "d")
        a.record(.pickup)
        return (0..<4).map { entry("m\($0)", activity: a) }
    }

    func testHoveringTheLastSlotOfAShortWindowScrollsItsRowsIntoView() async {
        let m = PlazaRosterMetrics.self, list = shortList()
        let limit = PlazaRoster.maxListHeight(forHeight: 460)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 460), 4, "test precondition")
        let rest = PlazaRoster.listLayout(list, hovered: nil, maxHeight: limit)
        XCTAssertEqual(rest.scroll, 0)
        let last = PlazaRoster.listLayout(list, hovered: "m3", maxHeight: limit)
        let bottom = 4 * m.slotHeight + 3 * m.slotSpacing + m.activityHeight(rows: 7)
        XCTAssertGreaterThan(bottom, limit, "test precondition: it would run past the minimap")
        XCTAssertEqual(last.height, limit, "the list never grows past the minimap")
        XCTAssertEqual(bottom - last.scroll, limit, accuracy: 0.01, "the hovered slot's bottom sits on the limit")
        let first = PlazaRoster.listLayout(list, hovered: "m0", maxHeight: limit)
        XCTAssertEqual(first.scroll, 0, "room below: nothing moves")
    }
}
