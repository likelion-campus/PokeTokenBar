import XCTest
@testable import PokeTokenBar

/// Stage 7 D3, the toggle race: a click on the tray icon while the popover is open first takes activation away (the
/// taskbar is clicked), which closes the popover, and only then does the shell report the click. That click must not
/// open it again. Run on both systems.
final class PopoverToggleGuardTests: XCTestCase {
    func testAClickRightAfterADeactivationOnTheIconDoesNotReopen() {
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true)
        XCTAssertFalse(g.opensOnSelect(at: 10.1), "100 ms later: the same click")
        XCTAssertFalse(g.opensOnSelect(at: 10.499))
        XCTAssertTrue(g.opensOnSelect(at: 10.7), "700 ms later: a new click")
        XCTAssertTrue(g.opensOnSelect(at: 10.5), "the window is half-open")
    }

    func testADeactivationWithTheCursorElsewhereDoesNotBlock() {
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: false)   // Alt+Tab, another app, the ^ of the overflow
        XCTAssertTrue(g.opensOnSelect(at: 10.1))
    }

    func testOneClickIsAbsorbedOnce() {
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true)
        XCTAssertFalse(g.opensOnSelect(at: 10.1))
        g.noteSelect()
        XCTAssertTrue(g.opensOnSelect(at: 10.3), "a quick second click opens it again")
    }

    func testALaterDeactivationReplacesTheEarlierOne() {
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true)
        g.noteClosedByDeactivation(at: 20, cursorInAnchor: false)
        XCTAssertTrue(g.opensOnSelect(at: 10.1))
        g.noteClosedByDeactivation(at: 30, cursorInAnchor: true)
        XCTAssertFalse(g.opensOnSelect(at: 30.2))
    }

    func testNothingNotedOpens() {
        XCTAssertTrue(PopoverToggleGuard().opensOnSelect(at: 0))
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true)
        XCTAssertTrue(g.opensOnSelect(at: 9.9), "a select stamped before the close is not its click")
        XCTAssertEqual(PopoverToggleGuard.window, 0.5)
    }
}
