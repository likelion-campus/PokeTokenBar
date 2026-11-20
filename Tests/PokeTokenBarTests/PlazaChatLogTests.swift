import XCTest
@testable import PokeTokenBar

/// The chat log model (moved out of PlazaChatTests.swift so it runs on Windows too).
@MainActor
final class PlazaChatLogTests: XCTestCase {
    func testLogKeepsTheLatestLinesAndShowsTheLastFew() async {
        let log = PlazaChatLog()
        let color = PlazaNameColor.palette[0]
        for i in 0..<(PlazaChatLog.capacity + 5) {
            log.append(time: Date(timeIntervalSince1970: 0), name: "a", text: "\(i)", color: color)
        }
        XCTAssertEqual(log.lines.count, PlazaChatLog.capacity)
        XCTAssertEqual(log.lines.first?.text, "5")
        XCTAssertEqual(log.visible.map(\.text), (49..<55).map(String.init))
        XCTAssertEqual(Set(log.lines.map(\.id)).count, log.lines.count)
    }

    func testTimeIsTwentyFourHour() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 14, minute: 5))!
        XCTAssertEqual(PlazaChatLog.timeText(afternoon, calendar: calendar), "14:05")
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 0))!
        XCTAssertEqual(PlazaChatLog.timeText(morning, calendar: calendar), "09:00")
    }
}
