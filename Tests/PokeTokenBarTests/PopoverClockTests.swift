import XCTest
@testable import PokeTokenBar

/// The popover's relative-time clock (stage 7 Task 5, D10): one timer at the earliest deadline, none without deadlines.
@MainActor
final class PopoverClockTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheEarliestOfTheDeadlinesWinsAndNoneMeansNoTimer() async {
        XCTAssertNil(PopoverClock.earliest([]))
        XCTAssertEqual(PopoverClock.earliest([now.addingTimeInterval(90), now.addingTimeInterval(30)]), now.addingTimeInterval(30))
        let clock = PopoverClock(now: { Date() })
        XCTAssertFalse(clock.isArmed)
        clock.setDeadlines([])
        XCTAssertFalse(clock.isArmed, "nothing relative on screen: no timer")
        clock.setDeadlines([Date().addingTimeInterval(3600), Date().addingTimeInterval(1800)])
        XCTAssertTrue(clock.isArmed)
        XCTAssertEqual(clock.armedFor.map { $0.timeIntervalSinceNow.rounded() }, 1800)
        XCTAssertEqual(clock.arms, 1)
        clock.stop()
        XCTAssertFalse(clock.isArmed)
        XCTAssertNil(clock.armedFor)
    }

    func testTheSameInstantKeepsTheTimerAndANewOneReplacesIt() async {
        let clock = PopoverClock()
        let a = Date().addingTimeInterval(600), b = Date().addingTimeInterval(900)
        clock.setDeadlines([a])
        clock.setDeadlines([a, b])
        XCTAssertEqual(clock.arms, 1, "the earliest did not change")
        clock.setDeadlines([b])
        XCTAssertEqual(clock.arms, 2)
        XCTAssertEqual(clock.armedFor, b)
        clock.setDeadlines([])
        XCTAssertFalse(clock.isArmed)
        clock.stop()
    }

    func testMinuteAndSecondBoundariesComeFromTheRelativeText() async {
        // Past 2 min 10 s the text changes every second; past 2 h 5 min every minute... the clock gets what the text says.
        let updated = now.addingTimeInterval(-130)
        let seconds = RelativeTimeText.nextChange(for: updated, now: now)
        XCTAssertEqual(seconds.timeIntervalSince(now), 1, accuracy: 0.001)
        let long = now.addingTimeInterval(-7500)
        XCTAssertEqual(RelativeTimeText.nextChange(for: long, now: now).timeIntervalSince(now), 60, accuracy: 0.001)
    }

    func testItFiresOnceAndTheOwnerArmsItAgain() async {
        let clock = PopoverClock()
        let fired = expectation(description: "tick")
        var ticks = 0
        clock.onTick = {
            ticks += 1
            fired.fulfill()
        }
        clock.setDeadlines([Date().addingTimeInterval(0.05)])
        await fulfillment(of: [fired], timeout: 3)
        XCTAssertEqual(ticks, 1)
        XCTAssertFalse(clock.isArmed, "one shot: the page decides whether another is needed")
        XCTAssertEqual(clock.ticks, 1)
    }

    func testAPastDeadlineFiresAtOnce() async {
        let clock = PopoverClock()
        let fired = expectation(description: "tick")
        clock.onTick = { fired.fulfill() }
        clock.setDeadlines([Date().addingTimeInterval(-5)])
        await fulfillment(of: [fired], timeout: 3)
        XCTAssertFalse(clock.isArmed)
    }
}
