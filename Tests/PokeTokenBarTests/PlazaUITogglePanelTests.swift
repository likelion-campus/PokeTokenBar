import XCTest
@testable import PokeTokenBar

/// The button that hides all of the plaza's panels at once: what a click asks the window to hide, the hint line, that the choice is
/// remembered, how it meets photo mode, and that the chat line still opens. Recording shell, so they run on Windows too; the Mac's
/// real hosts are in `PlazaUIToggleTests+Mac`.
@MainActor final class PlazaUITogglePanelTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    private struct NoSprites: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
        func egg() async -> PlazaImage? { nil }
    }

    private func controller(_ shell: RecordingPlazaShell, defaults: UserDefaults, chat: PlazaStubChatInput = PlazaStubChatInput()) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: defaults), loader: PlazaCharacterLoader(fetcher: NoSprites()),
                              nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: nil, isShiny: false) },
                              teamName: { "개발팀" }, renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park,
                              dittoSeed: { 7 }, shell: shell, chatInput: chat)
    }

    private func defaults() -> UserDefaults { TestDefaults.make(suite: "plaza.uitoggle.\(UUID())") }
    private func clickToggle(_ c: PlazaWindowController) { c.hud.press(PlazaPanelHit(action: "toggle", index: nil), in: .uiToggle) }
    private func key(_ scene: PlazaScene, _ code: UInt16) {
        scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false, modifiers: [])
        scene.handleKeyUp(keyCode: code)
    }

    func testTheSetTheButtonHidesLeavesTheButtonAndTheOpenThings() async {
        // Pinned: the roster, chat log, minimap, clock, guide, both top-left pills; never the button, the banner pills or what the user opens.
        XCTAssertEqual(PlazaPanelID.hiddenWithUI, [.roster, .chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker])
        XCTAssertEqual(PlazaPanelID.hiddenInPhotoMode, PlazaPanelID.hiddenWithUI.union([.uiToggle]))
        for kept in [PlazaPanelID.pills, .menu, .board, .card, .gameCard, .gameTitle, .photoFrame, .uiToggle] {
            XCTAssertFalse(PlazaPanelID.hiddenWithUI.contains(kept), "\(kept) stays")
        }
    }

    func testAClickHidesTheSetAndASecondClickBringsItBack() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        _ = shell.take()
        clickToggle(c)
        XCTAssertTrue(c.isUIHidden)
        XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenWithUI), .focusScene], "the keys go back to the scene")
        clickToggle(c)
        XCTAssertFalse(c.isUIHidden)
        XCTAssertEqual(shell.take(), [.setHiddenPanels([]), .focusScene])
        c.handleClose()
    }

    func testTheButtonSaysWhatAClickDoes() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        func label() throws -> String? { try XCTUnwrap(shell.panels.drawings[.uiToggle]).accessibility.first?.label }
        XCTAssertEqual(try label(), L(.ko).plazaUIHide)
        clickToggle(c)
        await Task.yield()
        XCTAssertEqual(try label(), L(.ko).plazaUIShow)
        XCTAssertNotNil(shell.panels.drawings[.uiToggle], "the button is drawn while the UI is hidden")
        c.handleClose()
    }

    func testTheHintLineIsEmptyWhileHiddenAndReturnsAfter() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        c.refreshHintForTesting()
        let shown = c.hint
        XCTAssertNotNil(shown, "an egg standing in the plaza is told how to pray")
        clickToggle(c)
        XCTAssertNil(c.hint)
        c.refreshHintForTesting()
        XCTAssertNil(c.hint, "a refresh does not bring a hint back")
        clickToggle(c)
        XCTAssertEqual(c.hint, shown)
        c.handleClose()
    }

    func testAnOpenColourPaletteClosesWhenTheUIIsHidden() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        c.toggleNameColorPicker()
        XCTAssertTrue(c.isNameColorPickerOpen)
        clickToggle(c)
        XCTAssertFalse(c.isNameColorPickerOpen)
        clickToggle(c)
        XCTAssertFalse(c.isNameColorPickerOpen, "it does not come back open")
        c.handleClose()
    }

    func testTheChoiceIsSavedAndAppliedOnTheNextOpen() async {
        let saved = defaults()
        let first = RecordingPlazaShell()
        let c = controller(first, defaults: saved)
        c.show()
        clickToggle(c)
        c.handleClose()
        let second = RecordingPlazaShell()
        let d = controller(second, defaults: saved)
        d.show()
        XCTAssertTrue(d.isUIHidden)
        XCTAssertTrue(second.take().contains(.setHiddenPanels(PlazaPanelID.hiddenWithUI)), "the window opens with the UI hidden")
        d.handleClose()
        let third = RecordingPlazaShell()
        let e = controller(third, defaults: defaults())
        e.show()
        XCTAssertFalse(e.isUIHidden, "a fresh preference shows the UI")
        e.handleClose()
    }

    func testPhotoModeEnteredWhileHiddenAndLeftKeepsTheUIHidden() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        clickToggle(c)
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        key(scene, PlazaKeyCode.p)
        XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)])
        key(scene, PlazaKeyCode.escape)
        XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenWithUI)], "back to hidden, not to shown")
        c.handleClose()
    }

    func testPhotoModeEnteredWhileShownHidesTheButtonAndRestoresIt() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        key(scene, PlazaKeyCode.p)
        let photo = shell.take()
        XCTAssertEqual(photo, [.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)])
        XCTAssertTrue(PlazaPanelID.hiddenInPhotoMode.contains(.uiToggle))
        key(scene, PlazaKeyCode.escape)
        XCTAssertEqual(shell.take(), [.setHiddenPanels([])])
        c.handleClose()
    }

    func testTheChatLineStillOpensWithEnterWhileHidden() async throws {
        let shell = RecordingPlazaShell()
        let chat = PlazaStubChatInput()
        let c = controller(shell, defaults: defaults(), chat: chat)
        c.show()
        clickToggle(c)
        key(try XCTUnwrap(c.scene), PlazaKeyCode.returnKey)
        XCTAssertTrue(chat.isOpen)
        c.handleClose()
    }
}
