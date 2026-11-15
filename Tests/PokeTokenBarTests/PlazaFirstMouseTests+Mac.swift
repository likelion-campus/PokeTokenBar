import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 14: the first click in an INACTIVE window. AppKit's default for a hosting view is "only activate the window"
/// (`acceptsFirstMouse` false); the panel hosts leave the same default, so the first click behaves as the deleted views' did.
/// (A borderless off-screen window cannot become key, so a click through `sendEvent` is always delivered: the real activation click needs a
/// person: hands-on checklist item 7.)
@MainActor final class PlazaFirstMouseTests: XCTestCase {
    func testPanelHostsDoWhatSwiftUIHostingViewsDidWithTheFirstClickOfAnInactiveWindow() async throws {
        let hosting = NSHostingView(rootView: Button("x") {})
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        for id in [PlazaPanelID.roster, .board, .card, .chatLog, .menu, .shortcuts, .backgroundToggle, .nameColorPicker] {
            XCTAssertEqual(try XCTUnwrap(rig.host(id)).acceptsFirstMouse(for: nil), hosting.acceptsFirstMouse(for: nil), "\(id)")
        }
    }
}
