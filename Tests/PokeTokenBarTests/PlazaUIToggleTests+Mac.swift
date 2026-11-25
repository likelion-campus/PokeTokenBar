import AppKit
import XCTest
@testable import PokeTokenBar

/// The UI toggle on the real window: a click on its host hides exactly the hosts of `hiddenWithUI` (they take no click) and keeps the
/// button, the banner and what the user opens; photo mode hides the button too and leaving it keeps the UI hidden.
@MainActor final class PlazaUIToggleTests: XCTestCase {
    private let inside = CGPoint(x: 20, y: 14)

    func testAClickOnTheButtonHidesExactlyTheSetAndKeepsTheButtonAndBanner() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.overlays.overlayModel.banner = "소식"
        rig.overlays.chatLog.append(time: Date(), name: "팀원", text: "안녕", color: PlazaNameColor.palette[0])
        await rig.flush()
        let button = try XCTUnwrap(rig.host(.uiToggle))
        XCTAssertTrue(PlazaPanelID.hiddenWithUI.allSatisfy { rig.host($0)?.isHidden == false }, "all shown before")
        XCTAssertTrue(try rig.click(.uiToggle, at: inside) === button)
        await rig.flush()
        XCTAssertTrue(rig.controller.isUIHidden)
        XCTAssertTrue(PlazaPanelID.hiddenWithUI.allSatisfy { rig.host($0)?.isHidden == true }, "the set is hidden")
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(rig.hud.hiddenPanels, PlazaPanelID.hiddenWithUI)
        XCTAssertTrue(rig.hud.isShown(.pills), "the banner stays")
        XCTAssertTrue(rig.hud.isShown(.uiToggle))
        // the button still works while the rest is gone
        XCTAssertTrue(try rig.click(.uiToggle, at: inside) === button)
        await rig.flush()
        XCTAssertFalse(rig.controller.isUIHidden)
        XCTAssertTrue(PlazaPanelID.hiddenWithUI.allSatisfy { rig.host($0)?.isHidden == false }, "all back")
    }

    func testAMenuTheUserOpenedStaysWhileTheUIIsHidden() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.controller.toggleUI()
        rig.overlays.overlayModel.content = .campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: [10, 25], selection: 0))
        await rig.flush()
        XCTAssertTrue(rig.hud.isShown(.menu))
    }

    func testPhotoModeHidesTheButtonToo() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        let button = try XCTUnwrap(rig.host(.uiToggle))
        rig.shell.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(rig.hud.isShown(.uiToggle))
        rig.shell.setHiddenPanels([])
        XCTAssertFalse(button.isHidden)
    }
}
