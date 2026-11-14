import XCTest
import AppKit
import SpriteKit
import SwiftUI
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
                       ["SKView", "PlazaRosterHostingView", "PlazaOverlayHostingView", "PlazaPanelHostView", "PlazaPanelHostView",
                        "PlazaPanelHostView", "PlazaChatLogHostingView", "PlazaPanelHostView", "PlazaPanelHostView",
                        "PlazaPanelHostView", "PlazaPanelHostView", "PlazaPanelHostView", "NSView"],
                       "bottom first, as show() added them; the photo frame's, the menu's and the pills' hosts right above the overlay, the minimap's, the clock's, the guide's, the toggle's and the picker's hosts where their hosting views were")
        guard subs.count == 13 else { return }
        XCTAssertEqual(subs.compactMap { ($0 as? PlazaPanelHostView)?.panelID },
                       [.photoFrame, .menu, .pills, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker])
        XCTAssertTrue(subs[12] === chat.view, "the chat field's bar is on top")
        for v in subs.dropFirst() { XCTAssertFalse(v.translatesAutoresizingMaskIntoConstraints) }
        let named = ["roster", "overlay", "photoFrame", "menu", "pills", "chatLog", "map", "clock", "shortcuts", "toggle", "colorPicker", "chatBar"]
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
            // The panel hosts cover the window; the HUD places the clock on the minimap (PlazaHUDTests).
            "pills.top = container.top + 0", "pills.bottom = container.bottom + 0",
            "pills.leading = container.leading + 0", "pills.trailing = container.trailing + 0",
            "clock.top = container.top + 0", "clock.bottom = container.bottom + 0",
            "clock.leading = container.leading + 0", "clock.trailing = container.trailing + 0",
            // The HUD places the guide under the toggle and the picker beside it (PlazaHUDControlsTests).
            "menu.top = container.top + 0", "menu.bottom = container.bottom + 0",
            "menu.leading = container.leading + 0", "menu.trailing = container.trailing + 0",
            "map.top = container.top + 0", "map.bottom = container.bottom + 0",
            "map.leading = container.leading + 0", "map.trailing = container.trailing + 0",
            "photoFrame.top = container.top + 0", "photoFrame.bottom = container.bottom + 0",
            "photoFrame.leading = container.leading + 0", "photoFrame.trailing = container.trailing + 0",
            "shortcuts.top = container.top + 0", "shortcuts.bottom = container.bottom + 0",
            "shortcuts.leading = container.leading + 0", "shortcuts.trailing = container.trailing + 0",
            "toggle.top = container.top + 0", "toggle.bottom = container.bottom + 0",
            "toggle.leading = container.leading + 0", "toggle.trailing = container.trailing + 0",
            "colorPicker.top = container.top + 0", "colorPicker.bottom = container.bottom + 0",
            "colorPicker.leading = container.leading + 0", "colorPicker.trailing = container.trailing + 0",
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
        XCTAssertEqual(subs.map(\.isHidden), [false, true, false, false, false, false, true, true, true, true, true, true, false],
                       "photo mode hides the roster, chat log, map, clock, guide and both toggles; not the scene, the overlay, its frame and pills or the open field")
        shell.setHUDHidden(false)
        XCTAssertEqual(subs.map(\.isHidden), Array(repeating: false, count: 13))
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

    /// While a menu is open its panel catches every click the controls above it do not take: the guide, toggle and picker (and
    /// the chat log) take theirs first, the minimap and the clock (no clicks) let them through to the catcher, and it sits
    /// above the roster and the scene. Nothing catches clicks while no menu is open.
    func testAnOpenMenuCatchesClicksBelowTheControls() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = controller(shell: RecordingPlazaShell())
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("this test never brings a window forward") })
        let overlays = c.overlayBindings
        shell.open(stage: scene.stage, title: "t", overlays: overlays)
        let container = try XCTUnwrap(shell.windowForTesting?.contentView)
        container.layoutSubtreeIfNeeded()
        let subs = container.subviews
        func hosts(at p: CGPoint) -> PlazaPanelID? { (container.hitTest(NSPoint(x: p.x, y: container.bounds.height - p.y)) as? PlazaPanelHostView)?.panelID }
        let size = container.bounds.size
        let frames = c.hud.layout(viewport: c.hud.viewport, scale: c.hud.scale)
        func mid(_ id: PlazaPanelID, dy: CGFloat = 0.5) -> CGPoint { let f = frames[id]!; return CGPoint(x: f.midX, y: f.minY + f.height * dy) }
        XCTAssertNil(hosts(at: CGPoint(x: size.width / 2, y: size.height / 2)), "no menu: the scene gets the click")
        overlays.overlayModel.content = .memberMenu(PlazaMemberMenu(memberID: "m", nickname: "민수"))
        for _ in 0..<20 { await Task.yield() }
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosts(at: CGPoint(x: size.width / 2, y: size.height - 80)), .menu, "far from everything: the catcher")
        XCTAssertEqual(hosts(at: CGPoint(x: size.width - 100, y: 60)), .menu, "over the roster: the catcher is above it")
        let toggle = frames[.backgroundToggle]!
        XCTAssertEqual(hosts(at: CGPoint(x: toggle.midX, y: toggle.midY)), .backgroundToggle, "the toggle takes its click first")
        let minimap = frames[.minimap]!
        XCTAssertEqual(hosts(at: CGPoint(x: minimap.midX, y: minimap.midY)), .menu, "the minimap takes no clicks: they reach the catcher")
        XCTAssertLessThan(try XCTUnwrap(subs.firstIndex { ($0 as? PlazaPanelHostView)?.panelID == .menu }),
                          try XCTUnwrap(subs.firstIndex { ($0 as? PlazaPanelHostView)?.panelID == .shortcuts }))
        overlays.overlayModel.content = .none
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(hosts(at: CGPoint(x: size.width / 2, y: size.height - 80)), "closed again: the click goes to the scene")
        shell.stopPresenting()
        shell.dismantle()
        c.handleClose()
    }

    /// Each SwiftUI view gets its own action: the no-argument closures all have the same type, so a swap would still compile.
    func testEachOverlayViewCallsItsOwnAction() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = controller(shell: RecordingPlazaShell())
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("this test never brings a window forward") })
        shell.open(stage: scene.stage, title: "t", overlays: c.overlayBindings)
        let subs = try XCTUnwrap(shell.windowForTesting?.contentView).subviews
        guard subs.count == 13 else { return XCTFail("\(subs)") }
        let roster = try XCTUnwrap(subs[1] as? PlazaRosterHostingView)
        let overlay = try XCTUnwrap(subs[2] as? PlazaOverlayHostingView)
        let chatLog = try XCTUnwrap(subs[6] as? PlazaChatLogHostingView)
        func state() -> [Bool] { [c.isChatLogExpanded, c.areShortcutsFolded, c.isBackgroundHidden, c.isNameColorPickerOpen] }
        func click(_ index: Int, _ id: PlazaPanelID, _ point: (CGRect) -> CGPoint) throws {
            // A click on the panel's host view: the HUD's frame for the panel, the point in it, down and up through the host.
            let host = try XCTUnwrap(subs[index] as? PlazaPanelHostView)
            XCTAssertEqual(host.panelID, id)
            host.superview?.layoutSubtreeIfNeeded()
            let frame = try XCTUnwrap(c.hud.layout(viewport: c.hud.viewport, scale: c.hud.scale)[id])
            let p = point(frame)
            let local = NSPoint(x: p.x, y: host.bounds.height - p.y)
            XCTAssertTrue(host.hitTest(host.convert(local, to: host.superview)) === host, "\(id): the host takes the click")
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: host.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if kind == .leftMouseDown { host.mouseDown(with: e) } else { host.mouseUp(with: e) }
            }
        }
        XCTAssertEqual(state(), [false, false, false, false])
        chatLog.rootView.toggle()
        XCTAssertEqual(state(), [true, false, false, false], "the chat log's button expands the log")
        try click(9, .shortcuts, { CGPoint(x: $0.minX + 20, y: $0.minY + 14) })
        XCTAssertEqual(state(), [true, true, false, false], "the guide's header folds the guide")
        try click(10, .backgroundToggle, { CGPoint(x: $0.midX, y: $0.midY) })
        XCTAssertEqual(state(), [true, true, true, false], "the eye button hides the background")
        try click(11, .nameColorPicker, { CGPoint(x: $0.minX + 20, y: $0.minY + 14) })
        XCTAssertEqual(state(), [true, true, true, true], "the colour button opens the palette")
        for _ in 0..<20 { await Task.yield() }   // the HUD draws the palette on the main actor's next turn
        let picker = try XCTUnwrap(c.hud.panels.first { $0.id == .nameColorPicker } as? PlazaNameColorPickerPanel)
        let swatch = picker.render(scale: 2, viewport: c.hud.viewport, graphics: c.hud.graphics).accessibility[3].frame
        try click(11, .nameColorPicker, { CGPoint(x: $0.minX + swatch.midX, y: $0.minY + swatch.midY) })
        XCTAssertEqual(c.shownNameColor, PlazaNameColor.hexes[2])
        XCTAssertFalse(c.isNameColorPickerOpen)
        _ = overlay
        c.rosterModel.entries = (0..<7).map {
            PlazaRosterEntry(id: "m\($0)", nickname: "m\($0)", speciesID: 25, speciesName: "피카츄", gender: nil,
                             isShiny: false, presence: .idle, isMe: false)
        }
        roster.rootView.onTurn(1)
        XCTAssertEqual(c.rosterModel.page, 1, "the roster's arrows turn its page")
        shell.stopPresenting()
        shell.dismantle()
        c.handleClose()
    }

    /// `open` centres the window before restoring the saved frame, so a saved position wins. Observable on a window that
    /// is never shown: the saved frame is applied when the autosave name is set.
    func testASavedFrameWinsOverCentring() async throws {
        let name = "PlazaWindowMacShellTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let saved = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 700, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        saved.isReleasedWhenClosed = false
        saved.saveFrame(usingName: name)
        let c = controller(shell: RecordingPlazaShell())
        c.prepareScene()
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("this test never brings a window forward") })
        shell.open(stage: try XCTUnwrap(c.scene).stage, title: "t", overlays: c.overlayBindings)
        let w = try XCTUnwrap(shell.windowForTesting)
        XCTAssertEqual(w.frame, saved.frame, "the saved frame, not the centred one")
        let centred = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        centred.isReleasedWhenClosed = false
        centred.center()
        XCTAssertNotEqual(saved.frame.origin, centred.frame.origin, "the fixture tells the two apart")
        XCTAssertEqual(c.rosterModel.capacity, PlazaRoster.capacity(forHeight: 500), "the roster fits the restored height")
        shell.stopPresenting()
        shell.dismantle()
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

    /// With no window, bringing the plaza forward does nothing: the activation (the injected `front`) is never reached, so a
    /// stray caller can't steal focus. Nothing is really activated here.
    func testBringToFrontWithoutAWindowDoesNotActivate() async {
        var activations = 0
        let shell = PlazaMacWindow(autosaveName: "unused", front: { _ in activations += 1 })
        shell.bringToFront()
        XCTAssertEqual(activations, 0)
        let c = controller(shell: shell)
        c.closeIfOpen()
        shell.bringToFront()
        XCTAssertEqual(activations, 0, "a controller that never showed the plaza brings nothing forward")
    }

    func testTheMacShellIsInertWithoutAWindow() async {
        let shell = PlazaMacWindow(autosaveName: "unused", front: { _ in XCTFail("nothing to bring forward") })
        shell.bringToFront()
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

extension PlazaWindowTests {
    func testRosterCapacityUsesTheRestoredWindowHeight() async {
        let name = "PlazaWindowTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let rect = { (height: CGFloat) in NSRect(x: 100, y: 100, width: 960, height: height) }
        NSWindow(contentRect: rect(320), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            .saveFrame(usingName: name)
        let w = NSWindow(contentRect: rect(640), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let model = PlazaRosterModel()
        PlazaMacWindow.restoreFrame(w, into: model, autosaveName: name)
        XCTAssertEqual(w.contentView?.bounds.height, 320, "the fixture must restore the saved size")
        XCTAssertEqual(model.capacity, PlazaRoster.capacity(forHeight: 320))
        XCTAssertNotEqual(model.capacity, PlazaRoster.capacity(forHeight: 640), "the fixture must tell the sizes apart")
    }

    /// With the background hidden the minimap is a dim, see-through panel; the dots stay as they are.
    func testMinimapDimsWhenTheBackgroundIsHidden() async throws {
        let map = PlazaImage(bitmap: PlazaBitmap(width: 48, height: 32, fill: PlazaRGBA(r: 110, g: 186, b: 84, a: 255)))
        func meanAlpha(hidden: Bool) throws -> Double {
            let background = PlazaBackgroundModel()
            background.isHidden = hidden
            let panel = PlazaMinimapPanel(model: PlazaMinimapModel(), background: background, worldSize: PlazaMapData.map.pixelSize,
                                          mapImage: { map })
            let drawing = panel.render(scale: 1, viewport: .zero, graphics: PlatformPlaza.graphics)
            guard case .image(let image, _)? = drawing.layers.first else { throw XCTSkip("no plate") }
            let px = image.pixels
            return Double(stride(from: 3, to: px.bytes.count, by: 4).reduce(0) { $0 + Int(px.bytes[$1]) }) / Double(px.bytes.count / 4) / 255
        }
        let shown = try meanAlpha(hidden: false), dimmed = try meanAlpha(hidden: true)
        XCTAssertGreaterThan(shown, 0.9, "opaque while the map is shown")
        XCTAssertLessThan(dimmed, 0.7, "see-through while the background is hidden")
    }

    /// Each status reads and looks different, and a roster with all three lays out one row per teammate.
    func testRosterShowsThreeDistinctStatuses() async {
        let badges = [PlazaPresence.online, .idle, .asleep].map(\.badge)
        XCTAssertEqual(badges.map(\.text), ["접속", "자리비움", "잠"])
        XCTAssertEqual(Set(badges.map(\.color)).count, 3)
        func entry(_ id: String, _ p: PlazaPresence, me: Bool = false) -> PlazaRosterEntry {
            PlazaRosterEntry(id: id, nickname: id, speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false,
                             presence: p, isMe: me)
        }
        let model = PlazaRosterModel()
        let view = PlazaRosterHostingView(rootView: PlazaRosterView(model: model))
        model.entries = [entry("me", .online, me: true)]
        let one = view.fittingSize.height
        model.entries = [entry("me", .idle, me: true), entry("a", .online), entry("b", .idle), entry("c", .asleep)]
        view.layoutSubtreeIfNeeded()
        let slot = PlazaRosterMetrics.slotHeight + PlazaRosterMetrics.slotSpacing
        XCTAssertEqual(view.fittingSize.height - one, 3 * slot, accuracy: 1)
    }

    /// A new view per case: without a window, macOS 15 does not refresh `fittingSize` after a second change to the model.
    func testRosterPanelHoldsOnePage() async {
        func height(people count: Int, page: Int = 0) -> CGFloat {
            let model = PlazaRosterModel()
            model.entries = (0..<count).map {
                PlazaRosterEntry(id: "m\($0)", nickname: "m\($0)", speciesID: 25, speciesName: "피카츄", gender: nil,
                                 isShiny: false, presence: .idle, isMe: false)
            }
            model.page = page
            return PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
        }
        let six = height(people: 6)
        XCTAssertEqual(height(people: 7), six, accuracy: 1, "the seventh person goes to the next page")
        let slot = PlazaRosterMetrics.slotHeight + PlazaRosterMetrics.slotSpacing
        XCTAssertEqual(six - height(people: 7, page: 1), 5 * slot, accuracy: 1)
    }

    /// The roster draws under the minimap and the clock, so its reserve must cover both as they really measure.
    func testRosterClearanceCoversTheMinimapAndTheClock() async {
        let map = NSHostingView(rootView: LegacyPlazaMinimapView(model: PlazaMinimapModel(), mapImage: NSImage(size: NSSize(width: 1, height: 1)),
                                                                 worldSize: PlazaMapData.map.pixelSize))
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update(PlazaDaylight.clockText(Date(), core: .standard))
        // The clock panel's image keeps 1 point of stroke room above and below the pill.
        let clockHeight = clock.size(in: CGSize(width: 960, height: 640), scale: 2, text: PlatformPlaza.graphics.text).height - 2 * PlazaPanelStyle.strokeRoom
        XCTAssertEqual(map.fittingSize.height, PlazaPanelStyle.minimapHeight(worldSize: PlazaMapData.map.pixelSize), "the clock sits on this")
        // 16 below the map and 6 between the map and the clock, as the window lays them out.
        XCTAssertLessThanOrEqual(16 + map.fittingSize.height + 6 + clockHeight, PlazaRosterMetrics.bottomClearance)
    }

    func testRosterPageTurnsFromTheControllerAndResetsOnClose() async {
        let c = controller(defaults())
        c.prepareScene()
        c.rosterModel.entries = (0..<7).map {
            PlazaRosterEntry(id: "m\($0)", nickname: "m\($0)", speciesID: 25, speciesName: "피카츄", gender: nil,
                             isShiny: false, presence: .idle, isMe: false)
        }
        c.rosterView().onTurn(1)
        XCTAssertEqual(c.rosterModel.page, 1, "the arrows are wired to the window's list")
        c.handleClose()
        XCTAssertEqual(c.rosterModel.page, 0, "reopening starts from the first page")
    }

    /// The roster takes clicks so a teammate can be chosen, but never the keyboard.
    func testRosterTakesClicksButNotKeys() async {
        let model = PlazaRosterModel()
        model.entries = [PlazaRosterEntry(id: "m", nickname: "민수", speciesID: 25, speciesName: "피카츄", gender: nil,
                                          isShiny: false, presence: .online, isMe: false)]
        let view = PlazaRosterHostingView(rootView: PlazaRosterView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: PlazaRosterMetrics.width, height: 120)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.hitTest(NSPoint(x: 100, y: 60)))
        XCTAssertFalse(view.acceptsFirstResponder)
    }
}
