import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

@MainActor private final class RecordingEvents: PlazaWindowEvents {
    var log: [String] = []
    func contentHeightDidChange(_ height: CGFloat) { log.append("height \(Int(height))") }
    func setRendering(visible: Bool) { log.append("visible \(visible)") }
    func didResignKey() { log.append("resign") }
    func didBecomeKey() { log.append("become") }
    func handleClose() { log.append("close") }
}

@MainActor private final class Written { var pngs: [Data] = [] }

/// The Mac shell (`PlazaMacWindow`, Track A Task 12) builds today's window: the same views in the same order with the same
/// constraints, the `SKView` presenting the stage's `SKScene`, and it forwards the window's events. The windows here are
/// never ordered on screen and nothing is activated.
@MainActor final class PlazaWindowMacShellTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    private func controller(shell: (any PlazaWindowShell)?, photoWriter: @escaping (Data) -> Bool = { _ in false }) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.macshell.\(UUID())")),
                              loader: PlazaCharacterLoader(fetcher: NoSprites()),
                              nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                              photoWriter: photoWriter,
                              renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                              shell: shell)
    }

    private func describe(_ c: NSLayoutConstraint, _ names: [ObjectIdentifier: String]) -> String? {
        guard String(describing: type(of: c)) != "NSAutoresizingMaskLayoutConstraint", c.relation == .equal,
              let first = c.firstItem as? NSView, let a = names[ObjectIdentifier(first)] else { return nil }
        func attr(_ x: NSLayoutConstraint.Attribute) -> String {
            switch x {
            case .top: "top"
            case .bottom: "bottom"
            case .leading: "leading"
            case .trailing: "trailing"
            case .width: "width"
            case .height: "height"
            default: "attr\(x.rawValue)"
            }
        }
        let k = String(format: "%g", c.constant)
        guard let secondItem = c.secondItem else { return "\(a).\(attr(c.firstAttribute)) = \(k)" }
        guard let second = secondItem as? NSView, let b = names[ObjectIdentifier(second)] else { return nil }
        return "\(a).\(attr(c.firstAttribute)) = \(b).\(attr(c.secondAttribute)) + \(k)"
    }

    /// The window `show()` built before the split, view by view and constraint by constraint (copied from its code).
    func testMacShellBuildsTheSameViewStack() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = controller(shell: RecordingPlazaShell())
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("this test never brings a window forward") })
        let overlays = c.overlayBindings
        shell.open(stage: scene.stage, title: "팀 광장 · 개발팀", overlays: overlays)
        let w = try XCTUnwrap(shell.windowForTesting)
        let view = try XCTUnwrap(shell.skViewForTesting)
        let chat = try XCTUnwrap(overlays.chatInput as? PlazaChatInput)
        XCTAssertFalse(w.isVisible, "never ordered on screen")

        XCTAssertEqual(w.styleMask, [.titled, .closable, .miniaturizable, .resizable])
        XCTAssertEqual(w.title, "팀 광장 · 개발팀")
        XCTAssertEqual(w.contentMinSize, NSSize(width: 600, height: 372))
        XCTAssertFalse(w.isReleasedWhenClosed)
        XCTAssertEqual(w.level, .normal)
        XCTAssertTrue(w.delegate === shell)
        XCTAssertTrue(w.firstResponder === view, "the scene takes the keys")
        XCTAssertTrue(view.ignoresSiblingOrder)
        XCTAssertTrue(view.allowsTransparency)
        XCTAssertEqual(view.autoresizingMask, [.width, .height])
        XCTAssertTrue(view.scene === (scene.stage as? SpriteKitStage)?.skScene, "the stage's SKScene is presented")
        XCTAssertTrue(shell.renderLoop === view)
        let container = try XCTUnwrap(w.contentView)
        XCTAssertEqual(view.frame, container.bounds)

        let subs = container.subviews
        XCTAssertEqual(subs.map { String(describing: type(of: $0)) },
                       ["SKView", "PlazaRosterHostingView", "PlazaOverlayHostingView", "PlazaChatLogHostingView",
                        "PlazaMinimapHostingView", "PlazaClockHostingView", "PlazaShortcutGuideHostingView",
                        "PlazaBackgroundToggleHostingView", "PlazaNameColorPickerHostingView", "NSView"], "bottom first, as show() added them")
        guard subs.count == 10 else { return }
        XCTAssertTrue(subs[9] === chat.view, "the chat field's bar is on top")
        for v in subs.dropFirst() { XCTAssertFalse(v.translatesAutoresizingMaskIntoConstraints) }
        let named = ["roster", "overlay", "chatLog", "map", "clock", "shortcuts", "toggle", "colorPicker", "chatBar"]
        var names = [ObjectIdentifier(container): "container"]
        for (i, n) in named.enumerated() { names[ObjectIdentifier(subs[i + 1])] = n }
        func installed() -> (between: [String], own: Set<String>) {
            let all = ([container] + subs).flatMap(\.constraints).compactMap { describe($0, names) }
            return (all.filter { $0.contains(" + ") }.sorted(), Set(all.filter { !$0.contains(" + ") }))
        }
        let m = String(format: "%g", PlazaRosterMetrics.margin)
        let atBottom = "chatLog.bottom = container.bottom + -16", aboveInput = "chatLog.bottom = chatBar.top + -8"
        let expected = [
            "roster.top = container.top + \(m)", "roster.trailing = container.trailing + -\(m)",
            "overlay.top = container.top + 0", "overlay.bottom = container.bottom + 0",
            "overlay.leading = container.leading + 0", "overlay.trailing = container.trailing + 0",
            "chatBar.bottom = container.bottom + -16", "chatBar.leading = container.leading + 16",
            "chatLog.leading = container.leading + 16", atBottom,
            "map.trailing = container.trailing + -\(m)", "map.bottom = container.bottom + -16",
            "clock.trailing = map.trailing + 0", "clock.bottom = map.top + -6",
            "toggle.top = container.top + \(m)", "toggle.leading = container.leading + \(m)",
            "shortcuts.top = toggle.bottom + 6", "shortcuts.leading = toggle.leading + 0",
            "colorPicker.top = toggle.top + 0", "colorPicker.leading = toggle.trailing + 8",
        ]
        XCTAssertEqual(installed().between, expected.sorted())
        XCTAssertTrue(installed().own.isSuperset(of: ["roster.width = \(String(format: "%g", PlazaRosterMetrics.width))",
                                                      "chatBar.width = \(String(format: "%g", PlazaChatLog.width))"]),
                      "\(installed().own)")

        shell.setChatLogAboveInput(true)
        XCTAssertTrue(installed().between.contains(aboveInput))
        XCTAssertFalse(installed().between.contains(atBottom))
        shell.setChatLogAboveInput(false)
        XCTAssertEqual(installed().between, expected.sorted())

        chat.open()
        shell.setHUDHidden(true)
        XCTAssertEqual(subs.map(\.isHidden), [false, true, false, true, true, true, true, true, true, false],
                       "photo mode hides the roster, chat log, map, clock, guide and both toggles; not the scene, the overlay or the open field")
        shell.setHUDHidden(false)
        XCTAssertEqual(subs.map(\.isHidden), Array(repeating: false, count: 10))
        shell.focusChatInput()
        XCTAssertFalse(w.firstResponder === view, "the field takes the keys")
        shell.focusScene()
        XCTAssertTrue(w.firstResponder === view)
        chat.close()

        shell.setTransparent(true)
        XCTAssertFalse(w.isOpaque)
        XCTAssertEqual(w.backgroundColor, .clear)
        XCTAssertFalse(w.hasShadow)
        shell.setTransparent(false)
        XCTAssertTrue(w.isOpaque)
        XCTAssertEqual(w.backgroundColor, .windowBackgroundColor)
        XCTAssertTrue(w.hasShadow)
        shell.setTitle("팀 광장")
        XCTAssertEqual(w.title, "팀 광장")
        XCTAssertFalse(shell.isFrontmost)
        XCTAssertFalse(shell.isInLiveResize)
        XCTAssertEqual(shell.diagnostics.isKey, false)

        shell.stopPresenting()
        XCTAssertNil(view.scene)
        XCTAssertNil(shell.renderLoop)
        shell.dismantle()
        XCTAssertNil(w.delegate)
        XCTAssertNil(w.contentView)
        XCTAssertNil(shell.windowForTesting)
        shell.setHUDHidden(true)
        XCTAssertFalse(subs[1].isHidden, "a dismantled window's views are let go of")
        c.handleClose()
    }

    /// Through `show()`: the window's `SKView` presents the scene's stage and its key and frame events reach the
    /// controller's scene; closing stops the presentation, then the scene and its `SKScene` are freed.
    func testTheMacShellPresentsTheStageUntilTheSceneIsLetGo() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in })
        let c = controller(shell: shell)
        weak var scene: PlazaScene?
        weak var host: PlazaSKScene?
        var view: SKView?
        do {
            c.show()
            let v = try XCTUnwrap(shell.skViewForTesting)
            let sk = try XCTUnwrap(v.scene as? PlazaSKScene)
            XCTAssertTrue(sk === (c.scene?.stage as? SpriteKitStage)?.skScene)
            XCTAssertTrue(sk.stage?.delegate === c.scene, "frames and keys reach the controller's scene")
            XCTAssertTrue(c.renderLoop === v)
            XCTAssertFalse(try XCTUnwrap(shell.windowForTesting).isVisible)
            scene = c.scene
            host = sk
            view = v
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(scene, "presented: the controller keeps the scene")
        XCTAssertNotNil(host?.stage?.delegate, "the presented SKScene still reaches its scene")
        c.handleClose()
        XCTAssertNil(view?.scene, "the view presents nothing once closed")
        XCTAssertNil(shell.windowForTesting)
        view = nil
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(scene)
        XCTAssertNil(host, "the old SKScene is freed")
    }

    func testTheMacShellIsInertWithoutAWindow() async {
        let shell = PlazaMacWindow(autosaveName: "unused", front: { _ in XCTFail("nothing to bring forward") })
        shell.focusScene()
        shell.focusChatInput()
        shell.setTitle("x")
        shell.setTransparent(true)
        shell.setHUDHidden(true)
        shell.setChatLogAboveInput(true)
        shell.requestClose()
        shell.stopPresenting()
        shell.dismantle()
        XCTAssertNil(shell.renderLoop)
        XCTAssertFalse(shell.isFrontmost)
        XCTAssertFalse(shell.isInLiveResize)
        XCTAssertNil(shell.diagnostics.occlusionVisible)
        XCTAssertNil(shell.diagnostics.isKey)
    }

    /// Every delegate call becomes one event, unchanged; a resize before the window exists (restoring the saved frame) is
    /// not reported, as before.
    func testTheMacShellForwardsItsWindowEvents() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = controller(shell: RecordingPlazaShell())
        c.prepareScene()
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in })
        let events = RecordingEvents()
        shell.events = events
        let note = Notification(name: NSWindow.didResizeNotification)
        shell.windowDidResize(note)
        XCTAssertEqual(events.log, [], "no window yet")
        shell.open(stage: try XCTUnwrap(c.scene).stage, title: "t", overlays: c.overlayBindings)
        let w = try XCTUnwrap(shell.windowForTesting)
        events.log = []
        shell.windowDidResize(note)
        shell.windowDidMiniaturize(note)
        shell.windowDidDeminiaturize(note)
        shell.windowDidChangeOcclusionState(note)
        shell.windowDidResignKey(note)
        shell.windowDidBecomeKey(note)
        shell.windowWillClose(note)
        let height = Int(try XCTUnwrap(w.contentView).bounds.height)
        XCTAssertEqual(events.log, ["height \(height)", "visible false", "visible true",
                                    "visible \(w.occlusionState.contains(.visible))", "resign", "become", "close"])
        shell.stopPresenting()
        shell.dismantle()
        c.handleClose()
    }

    /// The photo goes to the injected writer (never the real pasteboard) and the banner says so; the only window call is
    /// photo mode hiding the HUD.
    func testAPhotoGoesToTheWriterWithoutAWindowCall() async throws {
        let shell = RecordingPlazaShell()
        let written = Written()
        let c = controller(shell: shell, photoWriter: { written.pngs.append($0); return true })
        c.show()
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        scene.handleKeyDown(keyCode: PlazaKeyCode.p, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: PlazaKeyCode.p)
        scene.handleKeyDown(keyCode: PlazaKeyCode.p, characters: nil, isRepeat: false)
        XCTAssertEqual(written.pngs.count, 1)
        XCTAssertEqual(written.pngs.first.map { Array($0.prefix(4)) }, [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertEqual(c.banner, L(.ko).plazaPhotoCopied)
        XCTAssertEqual(shell.take(), [.setHUDHidden(true)])
        c.handleClose()
    }
}
