import XCTest
@testable import PokeTokenBar

/// The shared open/close rule (both systems), on the two sequences that failed the old fixed budget and on leaks.
final class PopoverResourceRuleTests: XCTestCase {
    private func s(_ gdi: Int, _ user: Int, _ handles: Int) -> PopoverResourceRule.Sample { .init(gdi: gdi, user: user, handles: handles) }

    func testNoisyHandlesWithFlatGDIAndUserPass() {
        // home.openClose3, run 43871634049 and the chat-line light run: the jump and the drop are the process's, not the page's.
        let v = PopoverResourceRule.judge([s(32, 14, 1323), s(32, 14, 1323), s(32, 14, 1375), s(32, 14, 1349)])
        XCTAssertTrue(v.ok, v.summary)
        XCTAssertFalse(v.handlesRose)
        // the earlier 1305 -> 1284 -> 1284 sequence, and a late drop of GDI/USER
        XCTAssertTrue(PopoverResourceRule.judge([s(28, 16, 1305), s(28, 16, 1284), s(28, 16, 1284), s(27, 15, 1284)]).ok)
    }

    func testAGDIObjectLeakedPerOpenFails() {
        let v = PopoverResourceRule.judge([s(30, 14, 1300), s(31, 14, 1301), s(32, 14, 1300), s(33, 14, 1300)])
        XCTAssertFalse(v.gdiFlat)
        XCTAssertFalse(v.ok, v.summary)
        // a single late GDI object above the warm-up fails too
        XCTAssertFalse(PopoverResourceRule.judge([s(30, 14, 1300), s(30, 14, 1300), s(30, 14, 1300), s(31, 14, 1300)]).ok)
    }

    func testAUSERObjectLeakedPerOpenFailsAndTheSlackIsOptIn() {
        XCTAssertFalse(PopoverResourceRule.judge([s(30, 14, 1300), s(30, 15, 1300), s(30, 15, 1300)]).ok)
        XCTAssertTrue(PopoverResourceRule.judge([s(30, 14, 1300), s(30, 15, 1300), s(30, 14, 1300)], userSlack: 1).ok)
        XCTAssertFalse(PopoverResourceRule.judge([s(30, 14, 1300), s(30, 16, 1300)], userSlack: 1).ok)
    }

    func testAHandleLeakedPerOpenFailsOnlyWhenItRisesEveryCycle() {
        let leak = PopoverResourceRule.judge([s(30, 14, 1300), s(30, 14, 1304), s(30, 14, 1308), s(30, 14, 1312)])
        XCTAssertTrue(leak.handlesRose)
        XCTAssertFalse(leak.ok)
        XCTAssertTrue(PopoverResourceRule.judge([s(30, 14, 1300), s(30, 14, 1304), s(30, 14, 1304), s(30, 14, 1312)]).ok, "one flat step is not a leak per open")
    }

    func testTooFewCyclesFailAndTheSummaryListsEveryCycle() {
        XCTAssertFalse(PopoverResourceRule.judge([s(1, 1, 1)]).ok)
        let v = PopoverResourceRule.judge([s(30, 14, 1300), s(30, 14, 1301), s(30, 14, 1299)])
        XCTAssertTrue(v.summary.contains("warm-up gdi=30") && v.summary.contains("#2 gdi=30 user=14 handles=1299"), v.summary)
    }
}
