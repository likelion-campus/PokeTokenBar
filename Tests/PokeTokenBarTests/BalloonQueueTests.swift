import XCTest
@testable import PokeTokenBar

final class BalloonQueueTests: XCTestCase {
    private func item(_ id: String) -> BalloonQueue.Item {
        .init(id: id, title: "t\(id)", body: "b\(id)", sound: true, kind: .app)
    }

    func testFirstItemShowsAtOnce() {
        var q = BalloonQueue()
        XCTAssertEqual(q.offer(item("1")), item("1"))
        XCTAssertEqual(q.inFlight, item("1"))
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testSecondWaitsUntilTheFirstFinishes() {
        var q = BalloonQueue()
        _ = q.offer(item("1"))
        XCTAssertNil(q.offer(item("2")))
        XCTAssertNil(q.offer(item("3")))
        XCTAssertEqual(q.finished(), item("2"), "arrival order")
        XCTAssertEqual(q.finished(), item("3"))
        XCTAssertNil(q.finished())
        XCTAssertNil(q.inFlight)
        XCTAssertEqual(q.offer(item("4")), item("4"), "idle again: shows at once")
    }

    func testCapacityDropsTheOldestPending() {
        var q = BalloonQueue(capacity: 2)
        _ = q.offer(item("1"))
        for id in ["2", "3", "4"] { XCTAssertNil(q.offer(item(id))) }
        XCTAssertEqual(q.dropped, 1)
        XCTAssertEqual(q.pendingCount, 2)
        XCTAssertEqual(q.finished(), item("3"), "2 was the oldest waiting one")
        XCTAssertEqual(q.finished(), item("4"))
        XCTAssertEqual(q.inFlight, item("4"))
    }

    func testClippingKeepsKoreanGraphemesWhole() {
        let korean = String(repeating: "한", count: 100)
        let cut = BalloonQueue.clipped(korean, limit: BalloonQueue.titleLimit)
        XCTAssertEqual(cut.utf16.count, BalloonQueue.titleLimit)
        XCTAssertEqual(cut, String(repeating: "한", count: 62) + "…")
        // Decomposed Hangul (conjoining jamo): one syllable is three scalars and must not be split.
        let jamo = String(repeating: "\u{1112}\u{1161}\u{11AB}", count: 40)  // 한 as L+V+T, 120 units
        let jamoCut = BalloonQueue.clipped(jamo, limit: BalloonQueue.titleLimit)
        XCTAssertLessThanOrEqual(jamoCut.utf16.count, BalloonQueue.titleLimit)
        XCTAssertTrue(jamoCut.dropLast().allSatisfy { $0 == Character("\u{1112}\u{1161}\u{11AB}") })
        // A surrogate pair straddling the limit goes whole; so does a ZWJ emoji sequence.
        let emoji = String(repeating: "a", count: 253) + "😀😀"
        XCTAssertEqual(BalloonQueue.clipped(emoji, limit: BalloonQueue.bodyLimit), String(repeating: "a", count: 253) + "…")
        let family = "👨‍👩‍👧"  // 8 units, one character
        let cutFamily = BalloonQueue.clipped(String(repeating: "a", count: 250) + family, limit: BalloonQueue.bodyLimit)
        XCTAssertEqual(cutFamily, String(repeating: "a", count: 250) + "…")
        XCTAssertEqual(BalloonQueue.clipped("short", limit: 63), "short")
        XCTAssertEqual(BalloonQueue.clipped(String(repeating: "x", count: 63), limit: 63).utf16.count, 63, "exactly at the limit is kept")
    }
}
