import AppKit
import XCTest
@testable import PokeTokenBar

private struct RigNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// The real plaza window (`PlazaMacWindow`, never ordered in, never key) over a real controller, for the Task 17w tests that drive
/// a panel through its host the way the mouse does: clicks, wheel, VoiceOver children, the chat field's focus.
@MainActor final class PlazaWindowRig {
    let controller: PlazaWindowController
    let shell: PlazaMacWindow
    let overlays: PlazaOverlayBindings
    private let name = "PlazaWindowRig.\(UUID())"

    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    /// True for the env-gated rig (`PTB_PLAZA_LIVE_WINDOW`), whose clicks go through the real `NSWindow.sendEvent`.
    let live: Bool
    private var frontmostAtStart: pid_t?

    /// `feed`: the team's news feed (nil: no board). The DEFAULT rig puts NO window on the window server: the real `PlazaMacWindow` and its real
    /// view tree are built and driven, but never ordered in; mouse events are delivered to the view AppKit's own `hitTest` finds. `live: true`
    /// (only with `PTB_PLAZA_LIVE_WINDOW` set, no screen reaching the off-screen frame, the frontmost app recorded and checked again at the end)
    /// orders the borderless, never-key window in far off every screen so true `sendEvent` dispatch can be exercised.
    init(feed: TeamFeedStore? = nil, icons: any PlazaIconSource = PlazaStubIconSource(), live: Bool = false) throws {
        self.live = live
        let offscreen = NSPoint(x: -30000, y: -30000)
        if live {
            guard ProcessInfo.processInfo.environment["PTB_PLAZA_LIVE_WINDOW"] != nil else { throw XCTSkip("PTB_PLAZA_LIVE_WINDOW not set (puts a window on the window server; needs the user's hands-off time)") }
            let reach = NSRect(origin: offscreen, size: NSSize(width: 1920, height: 1200))
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(reach) }) { throw XCTSkip("a screen (\(screen.localizedName)) reaches the off-screen frame") }
            frontmostAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        // The controller drives the REAL shell, so `setChatLogAboveInput`, `setHUDHidden`, `focusScene` and the rest reach the window the way
        // the app's calls do. A borderless window cannot become key; the front closure never activates anything.
        let shell = PlazaMacWindow(autosaveName: name, styleMask: [.borderless], front: { _ in })
        self.shell = shell
        let controller = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.rig.\(UUID())")),
                                           loader: PlazaCharacterLoader(fetcher: RigNoSprites()),
                                           nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                           feed: feed, renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                                           shell: shell, icons: icons)
        self.controller = controller
        controller.show()
        overlays = controller.overlayBindings
        if live {
            window.setFrameOrigin(offscreen)
            window.orderFront(nil)   // not key, not main, never activated
        }
        container.layoutSubtreeIfNeeded()
    }

    func close() {
        if live {
            window.orderOut(nil)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostAtStart, "the frontmost app never changed")
        }
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

    /// Waits for `condition`, up to `seconds`. A hosted runner renders several times slower than a Mac, so a fade that ends 1.1 s after the
    /// last scroll there ends later here; a test about "it does end" waits for the end instead of sleeping for the Mac's duration.
    /// Then it flushes: a clock's last beat stops the clock and only schedules its render (`PlazaHUD.setNeedsRender` runs it in a later
    /// main-actor task), so a caller that reads `renderCounts` right after the condition holds could miss that render and see it land later.
    func wait(upTo seconds: Double = 10, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await flush()
    }

    /// The window follows the system's scroller style, and a Mac with no trackpad (a CI runner) answers "always show scroll bars":
    /// the thumb then stays and no hold/fade timer ever runs. A test about those timers pins the overlay scrollers a trackpad Mac has.
    func useOverlayScrollers() {
        for case let panel as any PlazaScrollIndicating in hud.panels { panel.scrollIndicator.alwaysVisible = false }
    }

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

    /// What AppKit's `hitTest` finds at a window point: the descent through every host in z order, hidden views and our overrides included.
    func viewAt(_ w: NSPoint) -> NSView? { window.contentView?.hitTest(w) }

    /// What `NSView.hitTest` finds at a panel point.
    func hitView(_ id: PlazaPanelID, _ p: CGPoint) -> NSView? {
        guard let w = windowPoint(id, p) else { return nil }
        return viewAt(w)
    }

    private func mouse(_ kind: NSEvent.EventType, _ w: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: w, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                         pressure: kind == .leftMouseUp ? 0 : 1))
    }

    /// A click (down and up) at a panel point. Returns the view `hitTest` finds.
    @discardableResult
    func click(_ id: PlazaPanelID, at p: CGPoint) throws -> NSView? {
        try click(atWindow: try XCTUnwrap(windowPoint(id, p)))
    }

    /// A click at a window point (y up): the events go to the view AppKit's `hitTest` finds (`mouseDown`, `mouseUp`), as the window would deliver
    /// them; in the live rig through `NSWindow.sendEvent` itself.
    @discardableResult
    func click(atWindow w: NSPoint) throws -> NSView? {
        if live {
            let target = viewAt(w)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { window.sendEvent(try mouse(kind, w)) }
            return target
        }
        let target = viewAt(w)
        target?.mouseDown(with: try mouse(.leftMouseDown, w))
        target?.mouseUp(with: try mouse(.leftMouseUp, w))
        return target
    }

    /// A press, drags and a release as one gesture: the drags and the release go to the view the press found, wherever the pointer is.
    func drag(from start: NSPoint, through points: [NSPoint], release end: NSPoint? = nil) throws {
        let target = viewAt(start)
        if live { window.sendEvent(try mouse(.leftMouseDown, start)) } else { target?.mouseDown(with: try mouse(.leftMouseDown, start)) }
        for p in points {
            if live { window.sendEvent(try mouse(.leftMouseDragged, p)) } else { target?.mouseDragged(with: try mouse(.leftMouseDragged, p)) }
        }
        let last = end ?? points.last ?? start
        if live { window.sendEvent(try mouse(.leftMouseUp, last)) } else { target?.mouseUp(with: try mouse(.leftMouseUp, last)) }
    }

    /// A scroll of `dy` at a panel point, delivered to the view AppKit's `hitTest` finds there (`scrollWheel`): the host forwards it to the HUD,
    /// which gives it to the panel; one the panel does not take goes up the responder chain.
    func scroll(_ id: PlazaPanelID, at p: CGPoint, dy: CGFloat, precise: Bool = true) throws {
        let w = try XCTUnwrap(windowPoint(id, p))
        viewAt(w)?.scrollWheel(with: MockScrollEvent(at: w, dy: dy, precise: precise))
    }

    /// The same decision without the chain: true when the panel takes the scroll (it goes no further).
    func panelTakesScroll(_ id: PlazaPanelID, at p: CGPoint, dy: CGFloat) throws -> Bool {
        let f = try XCTUnwrap(frame(id))
        return hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: dy), location: CGPoint(x: f.minX + p.x, y: f.minY + p.y)), in: id)
    }
}
