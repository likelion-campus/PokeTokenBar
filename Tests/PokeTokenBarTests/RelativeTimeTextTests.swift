import XCTest
@testable import PokeTokenBar

/// The popover's relative times (stage 7, D10), on both systems.
final class RelativeTimeTextTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    private func shown(_ offset: TimeInterval) -> Int { RelativeTimeText.displayedSeconds(for: now.addingTimeInterval(offset), now: now) }
    private func wait(_ offset: TimeInterval) -> TimeInterval {
        RelativeTimeText.nextChange(for: now.addingTimeInterval(offset), now: now).timeIntervalSince(now)
    }

    func testPassedTimeRoundsDownAndCutsToTwoUnits() {
        XCTAssertEqual(shown(0), 0)
        XCTAssertEqual(shown(-0.4), 0)
        XCTAssertEqual(shown(-45.7), 45)
        XCTAssertEqual(shown(-190.9), 190, "3 min 10 s")
        XCTAssertEqual(shown(-3599.9), 3599)
        XCTAssertEqual(shown(-3600), 3600)
        XCTAssertEqual(shown(-3725.5), 3720, "1 h 2 min: the seconds go once it is an hour")
        XCTAssertEqual(shown(-90_061), 90_000, "1 day 1 h: the minutes go once it is a day")
    }

    func testTimeLeftRoundsUpSoACountdownNeverSaysZeroEarly() {
        XCTAssertEqual(shown(0.3), 1)
        XCTAssertEqual(shown(190.2), 191)
        XCTAssertEqual(shown(3599.5), 3600, "1 hour")
        XCTAssertEqual(shown(3600.4), 3660, "1 h 1 min")
        XCTAssertEqual(shown(7505), 7560, "2 h 6 min")
        XCTAssertEqual(shown(86_400.5), 90_000, "1 day 1 h")
    }

    func testNextChangeAtTheSecondsAndMinutesBoundaries() {
        XCTAssertEqual(wait(0), 1, accuracy: 0.0005)
        XCTAssertEqual(wait(-45.3), 0.7, accuracy: 0.0005)
        XCTAssertEqual(wait(-3599.5), 0.5, accuracy: 0.0005, "into the first minute-granular value")
        XCTAssertEqual(wait(-3725.5), 54.5, accuracy: 0.0005, "the next minute")
        XCTAssertEqual(wait(-90_061), 3539, accuracy: 0.0005, "the next hour once it is a day")
        XCTAssertEqual(wait(190.2), 0.2, accuracy: 0.0005)
        XCTAssertEqual(wait(0.3), 0.3, accuracy: 0.0005, "a countdown reaches 0 at the moment itself")
        XCTAssertEqual(wait(3599.5), 0.5, accuracy: 0.0005, "1 hour → 59 min 59 s, not the next minute")
        XCTAssertEqual(wait(7505), 5, accuracy: 0.0005, "2 h 6 min → 2 h 5 min at 7500 s left")
    }

    /// For any date, the text holds until `nextChange` and differs at it.
    func testNextChangeIsTheFirstInstantTheTextChanges() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let offset = Double(Int.random(in: -200_000...200_000, using: &rng)) + Double(Int.random(in: 0..<1000, using: &rng)) / 1000
            let date = now.addingTimeInterval(offset)
            let next = RelativeTimeText.nextChange(for: date, now: now)
            XCTAssertGreaterThan(next, now, "\(offset)")
            let before = RelativeTimeText.displayedSeconds(for: date, now: next.addingTimeInterval(-0.002))
            XCTAssertEqual(before, RelativeTimeText.displayedSeconds(for: date, now: now), "\(offset): changed before nextChange")
            XCTAssertNotEqual(RelativeTimeText.displayedSeconds(for: date, now: next), before, "\(offset): unchanged at nextChange")
        }
    }

    func testEveryLanguageWritesTheTwoUnits() {
        for language in AppLanguage.allCases {
            for offset in [-45.0, -190, -7505, 190, 90_061] {
                let text = RelativeTimeText.text(for: now.addingTimeInterval(offset), now: now, language: language)
                XCTAssertFalse(text.isEmpty, "\(language) \(offset)")
                XCTAssertTrue(text.contains { $0.isNumber }, "\(language) \(offset): \(text)")
            }
        }
        XCTAssertEqual(RelativeTimeText.text(for: now.addingTimeInterval(-190), now: now, language: .ko), "3분 10초")
        XCTAssertEqual(RelativeTimeText.text(for: now.addingTimeInterval(-7505), now: now, language: .ko), "2시간 5분")
        XCTAssertEqual(RelativeTimeText.text(for: now.addingTimeInterval(-45), now: now, language: .ja), "45秒")
    }

    func testEnglishWording() {
        XCTAssertEqual(RelativeTimeText.text(for: now.addingTimeInterval(-190), now: now, language: .en), "3 minutes, 10 seconds")
        XCTAssertEqual(RelativeTimeText.text(for: now.addingTimeInterval(-7200), now: now, language: .en), "2 hours", "a zero unit is left out")
        XCTAssertEqual(RelativeTimeText.text(for: now, now: now, language: .en), "0 seconds")
    }
}
