import AppKit
import XCTest
@testable import PokeTokenBar

/// The TRUE `NSWindow.sendEvent` variants of the window tests. They put a (borderless, never-key) window on the window server, far off every
/// screen, so they run ONLY with `PTB_PLAZA_LIVE_WINDOW` set (the user's hands-off time), skip when a screen reaches the off-screen frame, check
/// that the frontmost application never changed, never activate, and always order the window out. By default they skip.
@MainActor final class PlazaLiveSendEventTests: XCTestCase {
    private func people(_ n: Int) -> [PlazaRosterEntry] {
        (0..<n).map { PlazaRosterEntry(id: "m\($0)", nickname: "멤버\($0)", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: .idle, isMe: false) }
    }
    private var nextArrow: CGPoint {
        CGPoint(x: PlazaRosterMetrics.width - PlazaRosterMetrics.padding - PlazaRosterMetrics.pagerHitSize / 2, y: PlazaRosterMetrics.padding + PlazaRosterMetrics.headerHeight / 2)
    }

    func testARosterArrowAndAHiddenRosterThroughRealSendEvent() async throws {
        let rig = try PlazaWindowRig(live: true)
        defer { rig.close() }
        rig.overlays.rosterModel.entries = people(8)
        await rig.flush()
        try rig.click(.roster, at: nextArrow)
        XCTAssertEqual(rig.overlays.rosterModel.page, 1, "a click through sendEvent turned the page")
        rig.overlays.rosterModel.page = 0
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        await rig.flush()
        try rig.click(.roster, at: nextArrow)
        XCTAssertEqual(rig.overlays.rosterModel.page, 0, "a hidden roster is not clicked through sendEvent either")
        XCTAssertFalse(NSApp.isActive, "never activated")
    }
}
