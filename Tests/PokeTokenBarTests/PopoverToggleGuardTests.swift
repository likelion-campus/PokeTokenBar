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

    /// The taskbar takes the activation on the press and the shell reports the click on the release: a slow click (or
    /// ClickLock) holds the button longer than 0.5 s, so a press still down at the close gets the longer window.
    func testAPressStillDownAtTheCloseIsWaitedForLonger() {
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true, buttonDown: true)
        XCTAssertFalse(g.opensOnSelect(at: 10.7), "released 0.7 s later: still the closing click")
        XCTAssertFalse(g.opensOnSelect(at: 12.9))
        XCTAssertTrue(g.opensOnSelect(at: 13.1), "past 3 s: a new click")
        XCTAssertEqual(PopoverToggleGuard.heldWindow, 3)
        // Released before the close (a quick click whose release came first, or a key): the short window.
        var q = PopoverToggleGuard()
        q.noteClosedByDeactivation(at: 10, cursorInAnchor: true, buttonDown: false)
        XCTAssertTrue(q.opensOnSelect(at: 10.7))
        // The button down but the cursor elsewhere (a press on another window): nothing absorbed.
        var e = PopoverToggleGuard()
        e.noteClosedByDeactivation(at: 10, cursorInAnchor: false, buttonDown: true)
        XCTAssertTrue(e.opensOnSelect(at: 10.1))
        // A later close without the button replaces the held one.
        g.noteClosedByDeactivation(at: 20, cursorInAnchor: true, buttonDown: false)
        XCTAssertTrue(g.opensOnSelect(at: 20.7))
    }

    func testNothingNotedOpens() {
        XCTAssertTrue(PopoverToggleGuard().opensOnSelect(at: 0))
        var g = PopoverToggleGuard()
        g.noteClosedByDeactivation(at: 10, cursorInAnchor: true)
        XCTAssertTrue(g.opensOnSelect(at: 9.9), "a select stamped before the close is not its click")
        XCTAssertEqual(PopoverToggleGuard.window, 0.5)
    }
}
