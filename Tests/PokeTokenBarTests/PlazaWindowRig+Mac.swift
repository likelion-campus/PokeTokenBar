import AppKit
import XCTest
@testable import PokeTokenBar

private struct RigNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// The real plaza window (`PlazaMacWindow`, never shown, never key) over a real controller, for the Task 17w tests that drive
/// a panel through its host the way the mouse does: clicks, wheel, VoiceOver children, the chat field's focus.
@MainActor final class PlazaWindowRig {
    let controller: PlazaWindowController
    let shell: PlazaMacWindow
    let overlays: PlazaOverlayBindings
    private let name = "PlazaWindowRig.\(UUID())"

    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    /// `feed`: the team's news feed (nil: no board).
    init(feed: TeamFeedStore? = nil) throws {
        controller = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.rig.\(UUID())")),
                                           loader: PlazaCharacterLoader(fetcher: RigNoSprites()),
                                           nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                           feed: feed, renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                                           shell: RecordingPlazaShell())
        controller.prepareScene()
        shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("the rig never brings a window forward") })
        overlays = controller.overlayBindings
        shell.open(stage: try XCTUnwrap(controller.scene).stage, title: "t", overlays: overlays)
        container.layoutSubtreeIfNeeded()
    }

    func close() {
        shell.stopPresenting()
        shell.dismantle()
        controller.handleClose()
        NSWindow.removeFrame(usingName: name)
    }

    var window: NSWindow { shell.windowForTesting! }
    var container: NSView { window.contentView! }
    var skView: NSView { shell.skViewForTesting! }
    var hud: PlazaHUD { controller.hud }

    func flush() async { for _ in 0..<20 { await Task.yield() } }

    func host(_ id: PlazaPanelID) -> PlazaPanelHostView? {
        container.subviews.compactMap { $0 as? PlazaPanelHostView }.first { $0.panelID == id }
    }
    func panel<P: PlazaPanel>(_ id: PlazaPanelID, as type: P.Type = P.self) -> P? { hud.panels.first { $0.id == id } as? P }

    /// The panel's frame in window points, origin top-left (the HUD's).
    func frame(_ id: PlazaPanelID) -> CGRect? { hud.layout(viewport: hud.viewport, scale: hud.scale)[id] }

    /// The point in the window (y up) of a panel point (y down).
    func windowPoint(_ id: PlazaPanelID, _ p: CGPoint) -> NSPoint? {
        guard let f = frame(id) else { return nil }
        return NSPoint(x: f.minX + p.x, y: container.bounds.height - (f.minY + p.y))
    }

    /// What `NSView.hitTest` finds at a panel point, asked of the container as AppKit asks it (its own coordinates).
    func hitView(_ id: PlazaPanelID, _ p: CGPoint) -> NSView? {
        guard let w = windowPoint(id, p) else { return nil }
        return container.hitTest(container.convert(w, from: nil))
    }

    /// A click (down and up) at a panel point, delivered to the view `hitTest` finds there, as the window would.
    @discardableResult
    func click(_ id: PlazaPanelID, at p: CGPoint) throws -> NSView? {
        let w = try XCTUnwrap(windowPoint(id, p))
        let target = container.hitTest(container.convert(w, from: nil))
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: w, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
            if kind == .leftMouseDown { target?.mouseDown(with: e) } else { target?.mouseUp(with: e) }
        }
        return target
    }

    /// A click at a window point (y up).
    @discardableResult
    func click(atWindow w: NSPoint) throws -> NSView? {
        let target = container.hitTest(container.convert(w, from: nil))
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: w, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
            if kind == .leftMouseDown { target?.mouseDown(with: e) } else { target?.mouseUp(with: e) }
        }
        return target
    }

    /// A scroll of `dy` at a panel point delivered to the panel's own host, as the window delivers it (`scrollWheel`): the host
    /// forwards it to the HUD, which gives it to the panel; one the panel does not take goes up the responder chain.
    func scroll(_ id: PlazaPanelID, at p: CGPoint, dy: CGFloat, precise: Bool = true) throws {
        let host = try XCTUnwrap(host(id))
        host.scrollWheel(with: MockScrollEvent(at: try XCTUnwrap(windowPoint(id, p)), dy: dy, precise: precise))
    }

    /// The same decision without the chain: true when the panel takes the scroll (it goes no further).
    func panelTakesScroll(_ id: PlazaPanelID, at p: CGPoint, dy: CGFloat) throws -> Bool {
        let f = try XCTUnwrap(frame(id))
        return hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: dy), location: CGPoint(x: f.minX + p.x, y: f.minY + p.y)), in: id)
    }
}
