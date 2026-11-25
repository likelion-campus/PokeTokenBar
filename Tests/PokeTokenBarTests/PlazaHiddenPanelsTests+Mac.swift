import AppKit
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 3: photo mode hides the roster and chat log hosts (`setHiddenPanels`); a hidden host must take no click, and the HUD
/// must not keep drawing (or animating) what nobody sees. Through `NSWindow.sendEvent` on the real window.
@MainActor final class PlazaHiddenPanelsTests: XCTestCase {
    private func people(_ n: Int, presence: PlazaPresence = .online) -> [PlazaRosterEntry] {
        (0..<n).map { PlazaRosterEntry(id: "m\($0)", nickname: "멤버\($0)", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: presence, isMe: false) }
    }
    private func slot(_ i: Int) -> CGPoint {
        let m = PlazaRosterMetrics.self
        return CGPoint(x: m.width / 2, y: m.padding + m.headerHeight + m.listTopPadding + CGFloat(i) * (m.slotHeight + m.slotSpacing) + m.slotHeight / 2)
    }

    func testAHiddenRosterAndChatLogTakeNoClicks() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.overlays.rosterModel.entries = people(8)
        rig.overlays.chatLog.append(time: Date(), name: "팀원", text: "안녕", color: PlazaNameColor.palette[0])
        await rig.flush()
        var actions: [String] = []
        let own = rig.hud.onAction
        rig.hud.onAction = { id, hit in actions.append("\(id) \(hit.action)"); own?(id, hit) }
        let nextArrow = CGPoint(x: PlazaRosterMetrics.width - PlazaRosterMetrics.padding - PlazaRosterMetrics.pagerHitSize / 2,
                                y: PlazaRosterMetrics.padding + PlazaRosterMetrics.headerHeight / 2)
        let logButton = CGPoint(x: 360 - 22, y: 14)
        let rosterHost = try XCTUnwrap(rig.host(.roster)), logHost = try XCTUnwrap(rig.host(.chatLog))
        // Visible: both take their clicks (so the hidden check below means something).
        try rig.click(.roster, at: nextArrow)
        try rig.click(.chatLog, at: logButton)
        XCTAssertEqual(actions, ["roster next", "chatLog toggle"])
        XCTAssertEqual(rig.overlays.rosterModel.page, 1)
        XCTAssertTrue(rig.controller.isChatLogExpanded)
        rig.controller.toggleChatLog()   // fold it again
        rig.overlays.rosterModel.page = 0
        actions.removeAll()
        // Photo mode: the window hides them.
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        await rig.flush()
        XCTAssertTrue(rosterHost.isHidden && logHost.isHidden)
        XCTAssertTrue(try rig.click(.roster, at: nextArrow) !== rosterHost, "a hidden host is not hit")
        XCTAssertTrue(try rig.click(.roster, at: slot(0)) !== rosterHost)
        XCTAssertTrue(try rig.click(.chatLog, at: logButton) !== logHost)
        XCTAssertEqual(actions, [], "nothing was clicked")
        XCTAssertEqual(rig.overlays.rosterModel.page, 0, "no page turned")
        XCTAssertFalse(rig.controller.isChatLogExpanded, "the log did not fold")
        XCTAssertEqual(rig.overlays.rosterModel.entries.count, 8)
        // Shown again: clicks work.
        rig.shell.setHiddenPanels([])
        await rig.flush()
        try rig.click(.roster, at: nextArrow)
        XCTAssertEqual(rig.overlays.rosterModel.page, 1)
    }

    /// The roster's plate was redrawn twice a second in photo mode while nobody saw it (idle cost).
    func testAHiddenRosterIsNotRedrawnOrAnimated() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.overlays.rosterModel.entries = people(3)
        await rig.flush()
        let panel = try XCTUnwrap(rig.panel(.roster, as: PlazaRosterPanel.self))
        XCTAssertTrue(panel.animationClock.isRunning, "online members bounce while the roster shows")
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        await rig.flush()
        let base = rig.hud.renderCounts[.roster] ?? 0
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(rig.hud.renderCounts[.roster] ?? 0, base, "hidden: no renders")
        XCTAssertFalse(panel.animationClock.isRunning, "hidden: the bounce clock is stopped")
        rig.shell.setHiddenPanels([])
        await rig.flush()
        XCTAssertTrue(panel.animationClock.isRunning, "shown again: it bounces again")
    }

    /// The older panels with the same host: the guide, the toggle and the picker hide in photo mode too.
    func testHiddenGuideToggleAndPickerTakeNoClicks() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        await rig.flush()
        var actions: [String] = []
        let own = rig.hud.onAction
        rig.hud.onAction = { id, hit in actions.append("\(id) \(hit.action)"); own?(id, hit) }
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        await rig.flush()
        for id in [PlazaPanelID.shortcuts, .backgroundToggle, .nameColorPicker] {
            let host = try XCTUnwrap(rig.host(id))
            guard let f = rig.frame(id) else { continue }
            let w = NSPoint(x: f.minX + 20, y: rig.container.bounds.height - (f.minY + 14))
            XCTAssertTrue(try rig.click(atWindow: w) !== host, "\(id) hidden")
        }
        XCTAssertEqual(actions, [])
    }
}
