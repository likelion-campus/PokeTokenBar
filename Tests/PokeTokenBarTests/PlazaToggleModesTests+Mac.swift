import AppKit
import XCTest
@testable import PokeTokenBar

/// The background toggle's modes on the real window: in each mode exactly the right hosts are hidden (they take no click) and the pill, the
/// banner and what the user opens stay; photo mode hides the pill too.
@MainActor final class PlazaToggleModesMacTests: XCTestCase {
    private let inside = CGPoint(x: 20, y: 14)

    func testEachModeHidesExactlyItsHostsAndKeepsThePill() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.overlays.overlayModel.banner = "소식"
        rig.overlays.chatLog.append(time: Date(), name: "팀원", text: "안녕", color: PlazaNameColor.palette[0])
        await rig.flush()
        let pill = try XCTUnwrap(rig.host(.backgroundToggle))
        for (step, ui) in [false, true, false, true, false].enumerated() {
            if step > 0 {
                XCTAssertTrue(try rig.click(.backgroundToggle, at: inside) === pill, "the pill takes its click in mode \(step)")
                await rig.flush()
            }
            XCTAssertEqual(rig.controller.isUIHidden, ui, "click \(step)")
            for id in PlazaPanelID.hiddenWithUI { XCTAssertEqual(rig.host(id)?.isHidden, ui, "click \(step): \(id)") }
            XCTAssertFalse(pill.isHidden)
            XCTAssertEqual(rig.hud.hiddenPanels, ui ? PlazaPanelID.hiddenWithUI : [])
            XCTAssertTrue(rig.hud.isShown(.pills), "the banner stays")
            XCTAssertTrue(rig.hud.isShown(.backgroundToggle))
            XCTAssertEqual(rig.controller.isBackgroundHidden, step == 2 || step == 3)
        }
    }

    func testAMenuTheUserOpenedStaysWhileTheUIIsHidden() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        _ = try rig.click(.backgroundToggle, at: inside)
        rig.overlays.overlayModel.content = .campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: [10, 25], selection: 0))
        await rig.flush()
        XCTAssertTrue(rig.controller.isUIHidden)
        XCTAssertTrue(rig.hud.isShown(.menu))
    }

    func testPhotoModeHidesThePillToo() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        let pill = try XCTUnwrap(rig.host(.backgroundToggle))
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        XCTAssertTrue(pill.isHidden)
        XCTAssertFalse(rig.hud.isShown(.backgroundToggle))
        rig.shell.setHiddenPanels([])
        XCTAssertFalse(pill.isHidden)
    }
}
