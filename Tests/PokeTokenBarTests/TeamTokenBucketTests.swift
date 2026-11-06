import XCTest
@testable import PokeTokenBar

final class TeamTokenBucketTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testStartsFullAndRunsOut() {
        var b = TeamTokenBucket(capacity: 3, perSecond: 1)
        XCTAssertTrue(b.take(now: t0))
        XCTAssertTrue(b.take(now: t0))
        XCTAssertTrue(b.take(now: t0))
        XCTAssertFalse(b.take(now: t0))
    }

    func testRefillsWithTime() {
        var b = TeamTokenBucket(capacity: 1, perSecond: 0.5)
        XCTAssertTrue(b.take(now: t0))
        XCTAssertFalse(b.take(now: t0.addingTimeInterval(1.9)))
        XCTAssertTrue(b.take(now: t0.addingTimeInterval(2)))
    }

    func testNeverHoldsMoreThanItsCapacity() {
        var b = TeamTokenBucket(capacity: 2, perSecond: 1)
        XCTAssertTrue(b.take(now: t0))
        let later = t0.addingTimeInterval(3600)
        XCTAssertTrue(b.take(2, now: later))
        XCTAssertFalse(b.take(now: later))
    }

    func testARefusedTakeSpendsNothing() {
        var b = TeamTokenBucket(capacity: 5, perSecond: 0)
        XCTAssertFalse(b.take(6, now: t0))
        XCTAssertTrue(b.take(5, now: t0))
    }

    func testAClockGoingBackGivesNothingAndTakesNothing() {
        var b = TeamTokenBucket(capacity: 2, perSecond: 1)
        XCTAssertTrue(b.take(2, now: t0))
        XCTAssertFalse(b.take(now: t0.addingTimeInterval(-100)))
    }
}
