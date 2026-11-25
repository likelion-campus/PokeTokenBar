import XCTest
@testable import PokeTokenBar

/// The background toggle's four modes (shown, UI hidden, background hidden, both hidden): the order a click steps through them, what each
/// hides, the hint line, that both flags are remembered, how photo mode meets them, and that the chat line still opens. Recording shell, so they
/// run on Windows too; the Mac's real hosts are in `PlazaToggleModesTests+Mac`.
@MainActor final class PlazaToggleModesTests: XCTestCase {
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
    private func clickToggle(_ c: PlazaWindowController) { c.hud.press(PlazaPanelHit(action: "toggle", index: nil), in: .backgroundToggle) }
    private func key(_ scene: PlazaScene, _ code: UInt16) {
        scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false, modifiers: [])
        scene.handleKeyUp(keyCode: code)
    }

    /// (UI hidden, background hidden) after 0 to 4 clicks, and the label the pill shows.
    private static let modes: [(ui: Bool, background: Bool, label: String)] = [
        (false, false, "모두 표시"), (true, false, "UI 숨기기"), (false, true, "배경 숨기기"), (true, true, "UI·배경 숨김"), (false, false, "모두 표시"),
    ]

    func testTheUIHiddenSetIsPinnedAndInsidePhotoMode() async {
        XCTAssertEqual(PlazaPanelID.hiddenWithUI, [.roster, .chatLog, .minimap, .clock, .shortcuts, .nameColorPicker])
        XCTAssertTrue(PlazaPanelID.hiddenWithUI.isSubset(of: PlazaPanelID.hiddenInPhotoMode), "what the UI mode hides photo mode hides too")
        for kept in [PlazaPanelID.backgroundToggle, .pills, .menu, .board, .card, .gameCard, .gameTitle, .photoFrame] {
            XCTAssertFalse(PlazaPanelID.hiddenWithUI.contains(kept), "\(kept) stays")
        }
        XCTAssertTrue(PlazaPanelID.hiddenInPhotoMode.contains(.backgroundToggle), "photo mode hides the pill itself")
    }

    /// In the smallest window a banner (360 wide, centred) shares the top row with the pill, which is drawn over it. In no mode may the pill
    /// reach the banner's text: only the banner's side padding may lie under it ("UI·배경 숨기기" reached 5 pt into the text). Not checked
    /// here: the name colour pill and the guide, which lie over a banner's left end in windows under about 750 wide and did so before.
    func testInTheSmallestWindowThePillNeverCoversABannersText() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        let viewport = PlazaWindowController.minContentSize
        let bannerText = (viewport.width - PlazaPanelStyle.bannerWidth) / 2 + PlazaPanelStyle.banner.padding.width
        for step in 0...3 {
            if step > 0 {
                clickToggle(c)
                await Task.yield()
            }
            let frame = try XCTUnwrap(c.hud.frames(of: [.backgroundToggle], viewport: viewport, scale: 2)[.backgroundToggle])
            XCTAssertLessThanOrEqual(frame.maxX - PlazaPanelStyle.strokeRoom, bannerText, "\(Self.modes[step].label): the pill's right edge")
        }
    }

    func testFourClicksStepThroughTheModesInOrderAndTheFifthIsTheFirst() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        _ = shell.take()
        func label() throws -> String? { try XCTUnwrap(shell.panels.drawings[.backgroundToggle]).accessibility.first?.label }
        XCTAssertEqual(try label(), Self.modes[0].label)
        for step in 1...4 {
            clickToggle(c)
            await Task.yield()
            let m = Self.modes[step]
            XCTAssertEqual(c.isUIHidden, m.ui, "click \(step)")
            XCTAssertEqual(c.isBackgroundHidden, m.background, "click \(step)")
            XCTAssertEqual(c.scene?.isBackgroundHidden, m.background, "click \(step): the scene's background")
            XCTAssertEqual(try label(), m.label, "click \(step)")
            XCTAssertNotNil(shell.panels.drawings[.backgroundToggle], "the pill is drawn in every mode")
            let calls = shell.take()
            XCTAssertEqual(calls.first, .setHiddenPanels(m.ui ? PlazaPanelID.hiddenWithUI : []), "click \(step): the panels")
            XCTAssertEqual(calls.contains(.setTransparent(true)), m.background && !Self.modes[step - 1].background, "click \(step): the window goes see-through once")
            XCTAssertEqual(calls.contains(.setTransparent(false)), !m.background && Self.modes[step - 1].background, "click \(step)")
            XCTAssertEqual(calls.last, .focusScene, "the keys go back to the scene")
        }
        c.handleClose()
    }

    func testTheHintLineShowsInAllFourModes() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        c.refreshHintForTesting()
        let shown = c.hint
        XCTAssertNotNil(shown, "an egg standing in the plaza is told how to pray")
        for step in 1...3 {
            clickToggle(c)
            c.refreshHintForTesting()
            XCTAssertEqual(c.hint, shown, "mode \(step + 1)")
        }
        c.handleClose()
    }

    func testBannersShowInEveryMode() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        c.overlayBindings.overlayModel.banner = "소식"
        for step in 0...3 {
            await Task.yield()
            XCTAssertNotNil(shell.panels.drawings[.pills], "mode \(step + 1): the banner pill is drawn")
            XCTAssertFalse(PlazaPanelID.hiddenWithUI.contains(.pills))
            clickToggle(c)
        }
        c.handleClose()
    }

    func testAnOpenColourPaletteComesBackOpenAsAfterPhotoMode() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: defaults())
        c.show()
        c.toggleNameColorPicker()
        clickToggle(c)
        clickToggle(c)
        XCTAssertTrue(c.isNameColorPickerOpen, "hiding the UI leaves the palette as photo mode does")
        c.handleClose()
    }

    func testBothFlagsAreSavedAndAppliedOnTheNextOpen() async {
        for step in 0...3 {
            let saved = defaults()
            let first = RecordingPlazaShell()
            let c = controller(first, defaults: saved)
            c.show()
            for _ in 0..<step { clickToggle(c) }
            c.handleClose()
            let second = RecordingPlazaShell()
            let d = controller(second, defaults: saved)
            d.show()
            let m = Self.modes[step]
            XCTAssertEqual(d.isUIHidden, m.ui, "mode \(step + 1)")
            XCTAssertEqual(d.isBackgroundHidden, m.background, "mode \(step + 1)")
            XCTAssertEqual(d.scene?.isBackgroundHidden, m.background)
            XCTAssertEqual(second.take().contains(.setHiddenPanels(PlazaPanelID.hiddenWithUI)), m.ui, "mode \(step + 1): the window opens with the UI hidden")
            d.handleClose()
        }
    }

    func testAnOldSaveWithOnlyTheBackgroundHiddenOpensInModeThree() async {
        let saved = defaults()
        PlazaPreferences(defaults: saved).isBackgroundHidden = true   // what a version before the UI flag wrote
        let shell = RecordingPlazaShell()
        let c = controller(shell, defaults: saved)
        c.show()
        XCTAssertTrue(c.isBackgroundHidden)
        XCTAssertFalse(c.isUIHidden)
        XCTAssertEqual(try? XCTUnwrap(shell.panels.drawings[.backgroundToggle]).accessibility.first?.label, "배경 숨기기")
        c.handleClose()
    }

    func testPhotoModeKeepsTheUIHiddenInModesTwoAndFour() async throws {
        for clicks in [1, 3] {
            let shell = RecordingPlazaShell()
            let c = controller(shell, defaults: defaults())
            c.show()
            for _ in 0..<clicks { clickToggle(c) }
            _ = shell.take()
            let scene = try XCTUnwrap(c.scene)
            key(scene, PlazaKeyCode.p)
            XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)], "mode \(clicks + 1)")
            key(scene, PlazaKeyCode.escape)
            XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenWithUI)], "mode \(clicks + 1): back to UI hidden, not to shown")
            c.handleClose()
        }
    }

    func testPhotoModeInModeOneAndThreeRestoresEverything() async throws {
        for clicks in [0, 2] {
            let shell = RecordingPlazaShell()
            let c = controller(shell, defaults: defaults())
            c.show()
            for _ in 0..<clicks { clickToggle(c) }
            _ = shell.take()
            let scene = try XCTUnwrap(c.scene)
            key(scene, PlazaKeyCode.p)
            XCTAssertEqual(shell.take(), [.setHiddenPanels(PlazaPanelID.hiddenInPhotoMode)])
            key(scene, PlazaKeyCode.escape)
            XCTAssertEqual(shell.take(), [.setHiddenPanels([])], "mode \(clicks + 1)")
            c.handleClose()
        }
    }

    func testTheChatLineStillOpensWithEnterInModeTwo() async throws {
        let shell = RecordingPlazaShell()
        let chat = PlazaStubChatInput()
        let c = controller(shell, defaults: defaults(), chat: chat)
        c.show()
        clickToggle(c)
        XCTAssertTrue(c.isUIHidden)
        key(try XCTUnwrap(c.scene), PlazaKeyCode.returnKey)
        XCTAssertTrue(chat.isOpen)
        c.handleClose()
    }
}
