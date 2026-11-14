import XCTest
@testable import PokeTokenBar

/// What a HUD shows, in order.
@MainActor final class RecordingPanelHost: PlazaPanelHost {
    enum Call: Equatable { case show(PlazaPanelID, CGRect, CGFloat), hide(PlazaPanelID) }
    private(set) var calls: [Call] = []
    private(set) var images: [PlazaPanelID: PlazaImage] = [:]

    func show(_ id: PlazaPanelID, image: PlazaImage, frame: CGRect, scale: CGFloat) {
        calls.append(.show(id, frame, scale))
        images[id] = image
    }

    func hide(_ id: PlazaPanelID) {
        calls.append(.hide(id))
        images[id] = nil
    }

    func take() -> [Call] {
        defer { calls = [] }
        return calls
    }
}

/// The stub graphics, keeping every canvas it makes so a test can read what was drawn.
final class CanvasKeepingGraphics: PlazaGraphics, @unchecked Sendable {
    private let base = PlazaStubGraphics(log: { _ in })
    private(set) var canvases: [PlazaStubCanvas] = []
    var text: any PlazaTextEngine { base.text }

    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
        guard let canvas = base.makeCanvas(width: width, height: height, colorSpace: colorSpace) as? PlazaStubCanvas else { return nil }
        canvases.append(canvas)
        return canvas
    }

    func assetURL(_ name: String, ext: String) -> URL? { nil }
    func decodeImage(at url: URL) -> PlazaImage? { nil }
    func decodeImage(_ data: Data) -> PlazaImage? { nil }
    func decodeImageFrames(at url: URL) -> [PlazaImage] { [] }
    func encodePNG(_ image: PlazaImage) -> Data? { nil }
}

/// A panel with a click target: a 40×20 panel whose left half is a button.
@MainActor final class ButtonPanel: PlazaPanel {
    let id: PlazaPanelID
    let anchor = PlazaPanelAnchor.topLeading
    let offset = CGPoint(x: 10, y: 10)
    var onChange: (() -> Void)?
    var isVisible = true
    init(_ id: PlazaPanelID = .backgroundToggle) { self.id = id }
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: 40, height: 20) }
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaImage? {
        PlazaImage(bitmap: PlazaBitmap(width: Int(40 * scale), height: Int(20 * scale)))
    }
    func hit(_ point: CGPoint) -> PlazaPanelHit? { point.x < 20 ? PlazaPanelHit(action: "toggle", index: nil) : nil }
}

/// The HUD (Track A Task 14): where panels go, when they render (only on a change, never while the plaza is hidden),
/// and which clicks they take. Stub graphics; runs on Windows.
@MainActor final class PlazaHUDTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    private let stub = PlazaStubGraphics(log: { _ in })

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// The old constraints: the pills' stack 14 below the top, centred (each pill's stroke reaches 1 point outside it);
    /// the clock's trailing edge on the minimap's (14 from the window's), 6 above the minimap, which is 16 above the
    /// bottom and 136 tall. Stub text: 0.6 × size per character, lines 1 × size tall.
    func testPanelsAreAnchoredLikeTheirConstraints() async {
        let model = PlazaOverlayModel()
        model.hint = "안내"
        let pills = PlazaPillsPanel(model: model)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let hud = PlazaHUD(panels: [pills, clock], graphics: stub)
        XCTAssertEqual(PlazaPanelStyle.minimapHeight(worldSize: PlazaMapData.map.pixelSize), 136)
        // hint: 2 × 9 + 2 × 12 = 42 wide, 15 + 2 × 6 = 27 tall, plus 1 around; clock: 7 × 7.2 = 50.4 rounded up to the
        // pixel grid, + 16, by 12 + 10 = 22, plus 1.
        let pillsSize = CGSize(width: 44, height: 29)
        for (viewport, scale) in [(CGSize(width: 600, height: 372), CGFloat(1)), (CGSize(width: 600, height: 372), 2),
                                  (CGSize(width: 960, height: 640), 1), (CGSize(width: 960, height: 640), 2)] {
            let frames = hud.layout(viewport: viewport, scale: scale)
            XCTAssertEqual(frames[.pills], CGRect(origin: CGPoint(x: (viewport.width - 44) / 2, y: 13), size: pillsSize), "\(viewport)@\(scale)")
            let clockFrame = try? XCTUnwrap(frames[.clock])
            XCTAssertEqual(clockFrame?.size, CGSize(width: (scale == 1 ? 51 : 50.5) + 16 + 2, height: 24))
            XCTAssertEqual(clockFrame?.maxX ?? 0, viewport.width - 13, accuracy: 1e-9, "\(viewport)")
            XCTAssertEqual(clockFrame?.maxY, viewport.height - (16 + 136 + 6 - 1), "\(viewport)")
        }
        // An odd width centres on the device-pixel grid: 53 points in 600 start at 273.5 at 2x, rounded to 274 at 1x.
        model.hint = "안내한"
        XCTAssertEqual(hud.layout(viewport: CGSize(width: 600, height: 372), scale: 2)[.pills]?.minX, 273.5)
        XCTAssertEqual(hud.layout(viewport: CGSize(width: 600, height: 372), scale: 1)[.pills]?.minX, 274)
    }

    func testNothingRendersWithoutAHostOrAViewport() async {
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        let hud = PlazaHUD(panels: [clock], graphics: stub)
        clock.update("낮 12:00")
        XCTAssertEqual(hud.renderCount, 0, "no window")
        let host = RecordingPanelHost()
        hud.host = host
        XCTAssertEqual(hud.renderCount, 0, "no size yet")
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        XCTAssertEqual(hud.renderCounts, [.clock: 1])
        XCTAssertEqual(host.take().count, 1)
    }

    /// A resize moves the image it has; a new backing scale or a new size renders again.
    func testAResizeMovesThePanelsWithoutRendering() async throws {
        let model = PlazaOverlayModel()
        model.banner = "배너"
        let pills = PlazaPillsPanel(model: model)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let hud = PlazaHUD(panels: [pills, clock], graphics: stub)
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        XCTAssertEqual(hud.renderCounts, [.pills: 1, .clock: 1])
        let first = try XCTUnwrap(host.images[.pills])
        _ = host.take()
        hud.setViewport(CGSize(width: 1000, height: 700), scale: 2)
        XCTAssertEqual(hud.renderCounts, [.pills: 1, .clock: 1], "moved, not rendered")
        XCTAssertEqual(host.take().count, 2, "both moved")
        XCTAssertTrue(host.images[.pills] === first, "the same image")
        hud.setViewport(CGSize(width: 1000, height: 700), scale: 2)
        XCTAssertEqual(host.take(), [], "same size: nothing")
        hud.setViewport(CGSize(width: 1000, height: 700), scale: 1)
        XCTAssertEqual(hud.renderCounts, [.pills: 2, .clock: 2], "a new backing scale renders again")
        clock.update("밤 21:34")
        XCTAssertEqual(hud.renderCounts[.clock], 2, "the same text is no change")
    }

    func testAHiddenPanelIsHiddenAndNotRendered() async {
        let model = PlazaOverlayModel()
        let pills = PlazaPillsPanel(model: model)
        let hud = PlazaHUD(panels: [pills], graphics: stub)
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        XCTAssertEqual(hud.renderCount, 0, "nothing to show")
        XCTAssertEqual(host.take(), [])
        model.hint = "안내"
        await settle()
        XCTAssertEqual(hud.renderCounts, [.pills: 1])
        model.hint = nil
        await settle()
        XCTAssertEqual(host.take().last, .hide(.pills))
        XCTAssertEqual(hud.renderCounts, [.pills: 1], "hiding is not a render")
    }

    /// Only a panel that reports a hit takes a click; the pills and the clock never do.
    func testOnlyAnInteractivePanelTakesClicks() async throws {
        let model = PlazaOverlayModel()
        model.hint = "안내"
        let pills = PlazaPillsPanel(model: model)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let button = ButtonPanel()
        let hud = PlazaHUD(panels: [pills, clock, button], graphics: stub)
        var actions: [String] = []
        hud.onAction = { actions.append("\($0) \($1.action)") }
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        let frames = hud.layout(viewport: CGSize(width: 960, height: 640), scale: 2)
        for id in [PlazaPanelID.pills, .clock] {
            let f = try XCTUnwrap(frames[id])
            XCTAssertNil(hud.hit(at: CGPoint(x: f.midX, y: f.midY), in: id))
            XCTAssertNil(hud.hit(at: CGPoint(x: f.midX, y: f.midY)))
            XCTAssertFalse(hud.handleMouse(PlazaMouseEvent(kind: .down, location: CGPoint(x: f.midX, y: f.midY))))
        }
        XCTAssertEqual(hud.hit(at: CGPoint(x: 15, y: 15))?.hit, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertNil(hud.hit(at: CGPoint(x: 45, y: 15)), "the panel's other half lets clicks through")
        XCTAssertTrue(hud.handleMouse(PlazaMouseEvent(kind: .down, location: CGPoint(x: 15, y: 15))))
        XCTAssertTrue(hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: 16, y: 16))))
        XCTAssertEqual(actions, ["backgroundToggle toggle"])
        XCTAssertTrue(hud.handleMouse(PlazaMouseEvent(kind: .down, location: CGPoint(x: 15, y: 15))))
        XCTAssertTrue(hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: 300, y: 300))), "released elsewhere")
        XCTAssertEqual(actions.count, 1, "a press released outside is no click")
        XCTAssertFalse(hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: 15, y: 15))), "an up without a down")
        button.isVisible = false
        hud.setNeedsRender(.backgroundToggle)
        XCTAssertNil(hud.hit(at: CGPoint(x: 15, y: 15)), "a hidden panel takes nothing")
    }

    // MARK: through the controller

    private final class Now { var date: Date; init(_ d: Date) { date = d } }

    private func noon(minute: Int, second: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 11, 14, 12, minute, second)
        return Calendar.current.date(from: c)!
    }

    private func controller(_ shell: RecordingPlazaShell, now: Now, focusTickSleep: @escaping @MainActor (Duration) async -> Void) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.hud.\(UUID())")),
                              loader: PlazaCharacterLoader(fetcher: HUDTestNoSprites()),
                              nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                              clock: { now.date }, bannerSleep: Self.park, renderCheckSleep: Self.park, focusTickSleep: focusTickSleep,
                              dittoLoopSleep: Self.park, dittoSeed: { 7 }, shell: shell, chatInput: PlazaStubChatInput())
    }

    func testTheControllerOwnsTheHUDAndHandsItToTheWindow() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, now: Now(noon(minute: 0, second: 0)), focusTickSleep: Self.park)
        c.show()
        let o = try XCTUnwrap(shell.overlays)
        XCTAssertTrue(o.hud === c.hud)
        XCTAssertEqual(c.hud.panels.map(\.id), [.pills, .clock], "bottom first")
        XCTAssertTrue(c.hud.host === shell.panels, "the open window shows the panels")
        XCTAssertEqual(c.hud.renderCounts[.clock], 1, "the clock shows at once")
        await settle()
        XCTAssertTrue(c.hud.renderCounts.values.allSatisfy { $0 == 1 }, "opening renders each visible panel once: \(c.hud.renderCounts)")
        c.handleClose()
        XCTAssertNil(c.hud.host, "the closed window lets go of them")
    }

    /// After `setRendering(false)` nothing renders, whatever changes (a banner, the clock's minute); `true` renders the
    /// panels that changed, once each.
    func testAHiddenPlazaRendersNoPanels() async throws {
        let shell = RecordingPlazaShell()
        let now = Now(noon(minute: 0, second: 30))
        let tick = ShellTestGate()
        let c = controller(shell, now: now, focusTickSleep: { _ in await tick.sleep() })
        c.show()
        for _ in 0..<400 where tick.count == 0 { await Task.yield() }
        await settle()
        let shown = c.hud.renderCounts
        XCTAssertEqual(shown[.clock], 1)
        try XCTUnwrap(shell.events).setRendering(visible: false)
        c.showBanner("배너가 떴어요")
        for second in 31..<95 {
            now.date = noon(minute: second / 60, second: second % 60)
            tick.tick()
            for _ in 0..<400 where tick.count == 0 { await Task.yield() }
        }
        await settle()
        XCTAssertNotNil(c.banner, "the model changed")
        XCTAssertEqual(c.hud.renderCounts, shown, "nothing rendered while hidden")
        try XCTUnwrap(shell.events).setRendering(visible: true)
        XCTAssertEqual(c.hud.renderCounts[.pills, default: 0], shown[.pills, default: 0] + 1, "the banner, once")
        XCTAssertEqual(c.hud.renderCounts[.clock], 2, "the new minute, once")
        try XCTUnwrap(shell.events).setRendering(visible: true)
        XCTAssertEqual(c.hud.renderCounts[.clock], 2)
        c.handleClose()
    }

    /// An idle, visible plaza for 60 seconds: the 1 s tick re-renders the clock once, when its minute changes, and
    /// nothing else renders.
    func testAnIdleMinuteRendersOnlyTheClockOnce() async throws {
        let shell = RecordingPlazaShell()
        let now = Now(noon(minute: 0, second: 30))
        let tick = ShellTestGate()
        let c = controller(shell, now: now, focusTickSleep: { _ in await tick.sleep() })
        c.show()
        for _ in 0..<400 where tick.count == 0 { await Task.yield() }
        await settle()
        let before = c.hud.renderCount
        for second in 31...90 {
            now.date = noon(minute: second / 60, second: second % 60)
            tick.tick()
            for _ in 0..<400 where tick.count == 0 { await Task.yield() }
        }
        await settle()
        XCTAssertEqual(c.hud.renderCount - before, 1, "60 idle seconds: one render")
        XCTAssertEqual(c.hud.renderCounts[.clock], 2)
        c.handleClose()
    }

    /// Closing lets go of the window; the next window renders the panels again, even after closing while hidden.
    func testReopeningShowsThePanelsAgain() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell, now: Now(noon(minute: 0, second: 0)), focusTickSleep: Self.park)
        c.show()
        try XCTUnwrap(shell.events).setRendering(visible: false)
        c.handleClose()
        XCTAssertTrue(c.hud.isRendering, "a new window starts drawing")
        let before = c.hud.renderCounts[.clock] ?? 0
        c.show()
        XCTAssertEqual(c.hud.renderCounts[.clock], before + 1)
        c.handleClose()
    }
}

private struct HUDTestNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}
