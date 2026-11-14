import XCTest
import SwiftUI
import AppKit
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

    func testDayKeyIsTheLocalDateAndRollsAtLocalMidnight() {
        XCTAssertEqual(PlazaActivity.dayKey(date(13, 0, 0, 0), calendar: Self.calendar), "2026-11-13")
        XCTAssertEqual(PlazaActivity.dayKey(date(13, 23, 59, 59), calendar: Self.calendar), "2026-11-13")
        XCTAssertEqual(PlazaActivity.dayKey(date(14, 0, 0, 0), calendar: Self.calendar), "2026-11-14")
        XCTAssertEqual(PlazaActivity.dayKey(date(5, 9), calendar: Self.calendar), "2026-11-05", "padded, so it compares as text")
    }

    func testEachKindCountsItsOwnNumber() {
        var a = PlazaActivity(day: "2026-11-13")
        for kind in [PlazaActivity.Kind.iceBreak, .firework, .tackle, .snowballHit, .greeting, .pickup] { a.record(kind) }
        a.record(.tackle)
        a.record(.pickup)
        a.record(.pickup)
        XCTAssertEqual([a.iceBreaks, a.fireworks, a.tackles, a.snowballHits, a.greetings, a.pickups], [1, 1, 2, 1, 1, 3])
        XCTAssertEqual(a.seconds, 0)
    }

    func testCountsAndTimeStopAtTheirCeilings() {
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

    func testANewDayStartsFromZeroAndTheSameDayKeepsEverything() {
        var a = PlazaActivity(day: "2026-11-13")
        a.record(.firework)
        a.addSeconds(90)
        XCTAssertEqual(a.rolled(to: "2026-11-13"), a)
        let next = a.rolled(to: "2026-11-14")
        XCTAssertEqual(next, PlazaActivity(day: "2026-11-14"))
        XCTAssertEqual(next.fireworks, 0)
        XCTAssertEqual(next.seconds, 0)
    }

    func testReceivedValuesAreClamped() {
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

    func testOnlyTodaysNumbersAreShown() {
        var a = PlazaActivity(day: "2026-11-13")
        a.record(.greeting)
        XCTAssertEqual(a.shown(on: "2026-11-13"), a)
        XCTAssertNil(a.shown(on: "2026-11-14"), "yesterday's numbers are no record")
        XCTAssertNil(a.shown(on: "2026-11-12"), "a sender whose clock is a day behind is no record either")
    }

    func testCountsMatchIgnoresTimeOnly() {
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

    func testRowsListTheSevenItemsInOrderWithReadableValues() {
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

    func testTimeUnderAnHourShowsMinutesOnly() {
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

    func testNoActivityHasNoRows() {
        XCTAssertTrue(PlazaActivity.rows(nil).isEmpty)
    }

    // MARK: - The roster slot

    private func entry(_ id: String, activity: PlazaActivity? = nil, me: Bool = false) -> PlazaRosterEntry {
        PlazaRosterEntry(id: id, nickname: id, speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false,
                         presence: .online, isMe: me, activity: activity)
    }

    func testEntriesShowTodaysActivityAndNoRecordForOtherDaysAndOldVersions() {
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

    // MARK: - The member card's 오늘 광장 section

    private func member(_ id: String, _ a: PlazaActivity?) -> TeamMemberState {
        var m = TeamMemberState(memberID: id, nickname: id, character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "P", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        m.activity = a
        return m
    }

    func testCardShowsTheSevenValuesOfATeammateWithTodaysActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var a = PlazaActivity(day: PlazaActivity.dayKey(now))
        a.seconds = 3_660; a.record(.iceBreak); a.record(.firework); a.record(.tackle); a.record(.snowballHit); a.record(.greeting); a.record(.pickup)
        let state = PlazaCardState.loading(member("지아", a))
        XCTAssertEqual(state.todayActivity(now: now), a)
        XCTAssertEqual(PlazaActivity.rows(state.todayActivity(now: now)).map(\.label),
                       ["접속시간", "얼음 깬 횟수", "폭죽", "몸통박치기", "던져서 맞힌 횟수", "인사", "주운 아이템"])
        XCTAssertEqual(PlazaActivity.rows(state.todayActivity(now: now)).first?.value, "1시간 1분")
    }

    func testCardSaysNoRecordWithoutActivityOrFromAnotherDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(PlazaCardState.failed(member("민수", nil)).todayActivity(now: now), "an older version")
        XCTAssertNil(PlazaCardState.failed(member("서연", PlazaActivity(day: "1999-01-01"))).todayActivity(now: now), "another day")
        XCTAssertEqual(L(.ko).plazaActivityNone, "기록 없음")
    }

    /// The card is an overlay with a fixed panel: the section's height must not depend on how many rows it has.
    @MainActor func testCardHeightDoesNotDependOnTheActivity() {
        let now = Date()
        var a = PlazaActivity(day: PlazaActivity.dayKey(now)); a.record(.pickup)
        func height(_ a: PlazaActivity?) -> CGFloat {
            NSHostingView(rootView: PlazaCardView(state: .failed(member("지아", a)))).fittingSize.height
        }
        XCTAssertEqual(height(a), height(nil), accuracy: 0.5)
    }
}
