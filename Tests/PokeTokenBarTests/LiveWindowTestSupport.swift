import AppKit
import XCTest

/// The one place an older rendering/hit-test test may order a window in. Off by default: the test renders and hit-tests
/// the hosted view WITHOUT the window server, so nothing appears on the user's screen and focus is never taken.
/// With `PTB_LIVE_WINDOW_TESTS` set (CI, a hands-off run) the window is ordered in, but still off every screen, below
/// normal level, never key and never activating the app. `NoWindowsOrderedInScanTests` forbids any other ordering call.
extension NSWindow {
    static var liveWindowTestsEnabled: Bool { ProcessInfo.processInfo.environment["PTB_LIVE_WINDOW_TESTS"] != nil }

    /// For tests whose event routing or OCR needs a window on the window server (`sendEvent` hit-testing, rendered-text reads).
    static func requireLiveWindowTests() throws {
        guard liveWindowTestsEnabled else {
            throw XCTSkip("PTB_LIVE_WINDOW_TESTS not set (needs a window on the window server; off-screen, non-key, never activates)")
        }
    }

    func orderInForTest() {
        guard Self.liveWindowTestsEnabled else { return }
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        setFrameOrigin(NSPoint(x: -10000, y: -10000))
        orderFront(nil)   // not key, not main, never activated
    }
}
