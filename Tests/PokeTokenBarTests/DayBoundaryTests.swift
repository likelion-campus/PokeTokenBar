import XCTest
@testable import PokeTokenBar

final class DayBoundaryTests: XCTestCase {
    private func calendar(_ id: String) throws -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = try XCTUnwrap(TimeZone(identifier: id))
        return c
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), iso)
    }

    func testNextMidnightAcrossDSTAndMonthEnd() throws {
        let ny = try calendar("America/New_York")
        // Spring forward (2026-03-08, a 23 h day) and fall back (2026-11-01, a 25 h day).
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-03-07T17:00:00Z"), calendar: ny), try date("2026-03-08T05:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-03-08T05:00:01Z"), calendar: ny), try date("2026-03-09T04:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-10-31T16:00:00Z"), calendar: ny), try date("2026-11-01T04:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-11-01T04:00:01Z"), calendar: ny), try date("2026-11-02T05:00:00Z"))
        // Month end, year end, leap day.
        let utc = try calendar("UTC")
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-01-31T23:59:59Z"), calendar: utc), try date("2026-02-01T00:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-12-31T12:00:00Z"), calendar: utc), try date("2027-01-01T00:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2028-02-28T10:00:00Z"), calendar: utc), try date("2028-02-29T00:00:00Z"))
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2028-02-29T10:00:00Z"), calendar: utc), try date("2028-03-01T00:00:00Z"))
        // Exactly at midnight the next one is a day later (strictly after).
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: try date("2026-06-01T00:00:00Z"), calendar: utc), try date("2026-06-02T00:00:00Z"))
    }

    func testNextMidnightFollowsTheTimeZone() throws {
        let instant = try date("2026-06-01T23:30:00Z")
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: instant, calendar: try calendar("UTC")), try date("2026-06-02T00:00:00Z"))
        // 08:30 on June 2 in Tokyo: the next local midnight is 15:00Z the same UTC day.
        XCTAssertEqual(DayBoundary.nextLocalMidnight(after: instant, calendar: try calendar("Asia/Tokyo")), try date("2026-06-02T15:00:00Z"))
    }

    func testMidnightThatDoesNotExistResolvesToTheFirstInstantOfTheDay() throws {
        // Brazil skipped 00:00 on 2018-11-04 (DST began at midnight).
        let sp = try calendar("America/Sao_Paulo")
        let after = try date("2018-11-03T15:00:00Z")
        let next = DayBoundary.nextLocalMidnight(after: after, calendar: sp)
        XCTAssertGreaterThan(next, after)
        XCTAssertEqual(DayBoundary.dayKey(next, calendar: sp), "2018-11-04")
        XCTAssertEqual(next, sp.startOfDay(for: next))
    }

    func testDayKeyMatchesLocalUsageReaderTodayKey() {
        let before = LocalUsageReader.todayKey()
        let key = DayBoundary.dayKey(Date(), calendar: .current)
        let after = LocalUsageReader.todayKey()
        XCTAssertTrue(key == before || key == after, "\(key) vs \(before)/\(after)")
    }
}
