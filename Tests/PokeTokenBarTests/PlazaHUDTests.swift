import XCTest
@testable import PokeTokenBar

/// What a HUD shows, in order.
@MainActor final class RecordingPanelHost: PlazaPanelHost {
    enum Call: Equatable { case show(PlazaPanelID, CGRect, CGFloat), hide(PlazaPanelID) }
    private(set) var calls: [Call] = []
    private(set) var drawings: [PlazaPanelID: PlazaPanelDrawing] = [:]

    /// The first image layer of the panel's drawing.
    var images: [PlazaPanelID: PlazaImage] {
        drawings.compactMapValues { d in
            d.layers.lazy.compactMap { layer -> PlazaImage? in
                if case .image(let i, _) = layer { return i }
                return nil
            }.first
        }
    }

    func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
        calls.append(.show(id, frame, scale))
        drawings[id] = drawing
    }

    func hide(_ id: PlazaPanelID) {
        calls.append(.hide(id))
        drawings[id] = nil
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

/// A panel with a click target: a 40×20 panel at (10, 10) whose left half is a button (one accessibility item). With
/// `tracksMouse` it records the hover and press the HUD gives it.
@MainActor final class ButtonPanel: PlazaPanel {
    let id: PlazaPanelID
    let anchor = PlazaPanelAnchor.topLeading
    let offset: CGPoint
    var onChange: (() -> Void)?
    var isVisible = true
    let tracksMouse: Bool
    private(set) var interactions: [PlazaPanelInteraction] = []
    var interaction = PlazaPanelInteraction() { didSet { interactions.append(interaction) } }
    static let toggle = PlazaPanelHit(action: "toggle", index: nil)

    init(_ id: PlazaPanelID = .backgroundToggle, at offset: CGPoint = CGPoint(x: 10, y: 10), tracksMouse: Bool = false) {
        self.id = id
        self.offset = offset
        self.tracksMouse = tracksMouse
    }
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: 40, height: 20) }
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        PlazaPanelDrawing(layers: [.image(PlazaImage(bitmap: PlazaBitmap(width: Int(40 * scale), height: Int(20 * scale))),
                                          frame: CGRect(x: 0, y: 0, width: 40, height: 20))],
                          accessibility: [PlazaAccessibilityItem(frame: CGRect(x: 0, y: 0, width: 20, height: 20), role: .button,
                                                                 label: "토글", action: Self.toggle)],
                          tracksMouse: tracksMouse)
    }
    func hit(_ point: CGPoint) -> PlazaPanelHit? { point.x < 20 ? Self.toggle : nil }
}

/// A full-window panel that draws nothing and takes every click: the tap-outside-to-cancel area of an open menu.
@MainActor final class ClickCatcherPanel: PlazaPanel {
    let id = PlazaPanelID.menu
    let anchor = PlazaPanelAnchor.fill
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    let isVisible = true
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { viewport }
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing { PlazaPanelDrawing() }
    func hit(_ point: CGPoint) -> PlazaPanelHit? { PlazaPanelHit(action: "cancel", index: nil) }
}

/// The photo frame's shape (Task 15 builds the real one): everything dimmed except a rectangle 24 points in, as four
/// colour rectangles, and a small image per corner bracket.
@MainActor final class DimPanel: PlazaPanel {
    let id = PlazaPanelID.photoFrame
    let anchor = PlazaPanelAnchor.fill
    let offset = CGPoint.zero
    var onChange: (() -> Void)?
    let isVisible = true
    static let inset: CGFloat = 24, bracket: CGFloat = 12
    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { viewport }
    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        let w = viewport.width, h = viewport.height, i = Self.inset, b = Self.bracket
        let dim = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        let space = PlazaPanelSpace(content: CGSize(width: b, height: b), room: 0)
        let corner = space.image(scale: scale, graphics: graphics) { canvas in
            canvas.setFillColor(.white)
            canvas.fill(space.canvas(CGRect(x: 0, y: 0, width: b, height: 3)))
            canvas.fill(space.canvas(CGRect(x: 0, y: 0, width: 3, height: b)))
        }
        var layers: [PlazaPanelLayer] = [
            .color(dim, frame: CGRect(x: 0, y: 0, width: w, height: i)), .color(dim, frame: CGRect(x: 0, y: h - i, width: w, height: i)),
            .color(dim, frame: CGRect(x: 0, y: i, width: i, height: h - 2 * i)), .color(dim, frame: CGRect(x: w - i, y: i, width: i, height: h - 2 * i)),
        ]
        if let corner {
            for origin in [CGPoint(x: i, y: i), CGPoint(x: w - i - b, y: i), CGPoint(x: i, y: h - i - b), CGPoint(x: w - i - b, y: h - i - b)] {
                layers.append(.image(corner, frame: CGRect(origin: origin, size: CGSize(width: b, height: b))))
            }
        }
        return PlazaPanelDrawing(layers: layers)
    }
    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}

/// The HUD (Track A Task 14): where panels go, when they render (only on a change, never while the plaza is hidden),
/// which clicks they take and what VoiceOver reads. Stub graphics; runs on Windows.
@MainActor final class PlazaHUDTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    private let stub = PlazaStubGraphics(log: { _ in })
    private let window = CGSize(width: 960, height: 640)

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func down(_ x: CGFloat, _ y: CGFloat) -> PlazaMouseEvent { PlazaMouseEvent(kind: .down, location: CGPoint(x: x, y: y)) }
    private func up(_ x: CGFloat, _ y: CGFloat) -> PlazaMouseEvent { PlazaMouseEvent(kind: .up, location: CGPoint(x: x, y: y)) }
    private func moved(_ x: CGFloat, _ y: CGFloat) -> PlazaMouseEvent { PlazaMouseEvent(kind: .moved, location: CGPoint(x: x, y: y)) }

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
        await settle()
        XCTAssertEqual(hud.renderCount, 0, "no window")
        let host = RecordingPanelHost()
        hud.host = host
        XCTAssertEqual(hud.renderCount, 0, "no size yet")
        hud.setViewport(window, scale: 2)
        XCTAssertEqual(hud.renderCounts, [.clock: 1])
        XCTAssertEqual(host.take().count, 1)
    }

    /// A resize moves the drawing it has; a new backing scale or a new size renders again.
    func testAResizeMovesThePanelsWithoutRendering() async throws {
        let model = PlazaOverlayModel()
        model.banner = "배너"
        let pills = PlazaPillsPanel(model: model)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let hud = PlazaHUD(panels: [pills, clock], graphics: stub)
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(window, scale: 2)
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
        await settle()
        XCTAssertEqual(hud.renderCounts[.clock], 2, "the same text is no change")
    }

    func testAHiddenPanelIsHiddenAndNotRendered() async {
        let model = PlazaOverlayModel()
        let pills = PlazaPillsPanel(model: model)
        let hud = PlazaHUD(panels: [pills], graphics: stub)
        let host = RecordingPanelHost()
        hud.host = host
        hud.setViewport(window, scale: 2)
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

    /// Reports in one turn of the main actor render once; while hidden, none render, and showing renders once.
    func testReportsInOneTurnRenderOnce() async {
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let hud = PlazaHUD(panels: [clock], graphics: stub)
        let host = RecordingPanelHost()
        hud.setViewport(window, scale: 2)
        hud.host = host
        XCTAssertEqual(hud.renderCounts[.clock], 1)
        clock.update("밤 21:35")
        clock.update("밤 21:36")
        hud.setNeedsRender(.clock)
        XCTAssertEqual(hud.renderCounts[.clock], 1, "not before the next turn")
        await settle()
        XCTAssertEqual(hud.renderCounts[.clock], 2, "three reports, one render")
        hud.isRendering = false
        clock.update("밤 21:37")
        clock.update("밤 21:38")
        await settle()
        XCTAssertEqual(hud.renderCounts[.clock], 2, "hidden: none")
        hud.isRendering = true
        XCTAssertEqual(hud.renderCounts[.clock], 3, "shown: once, at once")
        await settle()
        XCTAssertEqual(hud.renderCounts[.clock], 3)
    }

    /// Only a panel that reports a hit takes a click; the pills and the clock never do. A click is a down and an up on
    /// the same hit of the panel whose view got them.
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
        hud.setViewport(window, scale: 2)
        let frames = hud.layout(viewport: window, scale: 2)
        for id in [PlazaPanelID.pills, .clock] {
            let f = try XCTUnwrap(frames[id])
            XCTAssertNil(hud.hit(at: CGPoint(x: f.midX, y: f.midY), in: id))
            XCTAssertNil(hud.hit(at: CGPoint(x: f.midX, y: f.midY)))
            XCTAssertFalse(hud.handleMouse(down(f.midX, f.midY), in: id))
        }
        XCTAssertEqual(hud.hit(at: CGPoint(x: 15, y: 15))?.hit, ButtonPanel.toggle)
        XCTAssertNil(hud.hit(at: CGPoint(x: 45, y: 15)), "the panel's other half lets clicks through")
        XCTAssertTrue(hud.handleMouse(down(15, 15), in: .backgroundToggle))
        XCTAssertTrue(hud.handleMouse(up(16, 16), in: .backgroundToggle))
        XCTAssertEqual(actions, ["backgroundToggle toggle"])
        XCTAssertTrue(hud.handleMouse(down(15, 15), in: .backgroundToggle))
        XCTAssertTrue(hud.handleMouse(up(300, 300), in: .backgroundToggle), "released elsewhere")
        XCTAssertEqual(actions.count, 1, "a press released outside is no click")
        XCTAssertFalse(hud.handleMouse(up(15, 15), in: .backgroundToggle), "an up without a down")
        button.isVisible = false
        hud.setNeedsRender(.backgroundToggle)
        await settle()
        XCTAssertNil(hud.hit(at: CGPoint(x: 15, y: 15)), "a hidden panel takes nothing")
    }

    /// The window decides which panel's view gets an event; the HUD delivers it to that panel, whatever its own order.
    /// Two buttons on the same spot, the HUD's order the opposite of the views'.
    func testClicksGoToThePanelWhoseViewGotThem() async {
        let lower = ButtonPanel(.backgroundToggle), upper = ButtonPanel(.nameColorPicker)
        let hud = PlazaHUD(panels: [upper, lower], graphics: stub)   // "wrong" order: lower is last, on top for the HUD
        var actions: [PlazaPanelID] = []
        hud.onAction = { id, _ in actions.append(id) }
        hud.setViewport(window, scale: 2)
        let host = RecordingPanelHost()   // the HUD holds its host weakly: keep it alive
        hud.host = host
        XCTAssertEqual(hud.hit(at: CGPoint(x: 15, y: 15))?.id, .backgroundToggle, "the HUD's own top")
        XCTAssertTrue(hud.handleMouse(down(15, 15), in: .nameColorPicker))
        XCTAssertTrue(hud.handleMouse(up(15, 15), in: .nameColorPicker))
        XCTAssertEqual(actions, [.nameColorPicker], "the panel whose view the window picked")
    }

    /// A panel that draws nothing is still shown and takes clicks where `hit` says (the full-window tap-outside area).
    func testAPanelThatDrawsNothingStillTakesClicks() async throws {
        let catcher = ClickCatcherPanel()
        let hud = PlazaHUD(panels: [catcher], graphics: stub)
        var actions: [String] = []
        hud.onAction = { actions.append($1.action) }
        let host = RecordingPanelHost()
        hud.setViewport(window, scale: 2)
        hud.host = host
        XCTAssertEqual(host.take(), [.show(.menu, CGRect(origin: .zero, size: window), 2)])
        XCTAssertEqual(host.drawings[.menu]?.layers.count, 0, "no image, no layer")
        XCTAssertEqual(hud.hit(at: CGPoint(x: 900, y: 600), in: .menu), PlazaPanelHit(action: "cancel", index: nil))
        XCTAssertTrue(hud.handleMouse(down(500, 300), in: .menu))
        XCTAssertTrue(hud.handleMouse(up(500, 300), in: .menu))
        XCTAssertEqual(actions, ["cancel"])
    }

    /// A full-window panel is drawn from colour rectangles and small images: resizing from the smallest window to a 5K
    /// one makes no bitmap bigger than its drawn content (a corner bracket), and the dim covers the new window.
    func testAFullWindowPanelAllocatesNoWindowSizedBitmap() async throws {
        let graphics = CanvasKeepingGraphics()
        let dim = DimPanel()
        let model = PlazaOverlayModel()
        model.countdown = "단체 사진 5"
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let hud = PlazaHUD(panels: [dim, PlazaPillsPanel(model: model), clock], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 600, height: 372), scale: 2)
        hud.host = host
        for size in [CGSize(width: 900, height: 600), CGSize(width: 1600, height: 1000), CGSize(width: 2560, height: 1440)] {
            hud.setViewport(size, scale: 2)
        }
        let frames = hud.layout(viewport: CGSize(width: 2560, height: 1440), scale: 2)
        for canvas in graphics.canvases {
            let ok = [DimPanel.bracket * 2, (frames[.pills]?.width ?? 0) * 2, (frames[.clock]?.width ?? 0) * 2].contains(CGFloat(canvas.width))
            XCTAssertTrue(ok, "a \(canvas.width)×\(canvas.height) bitmap is no panel's drawn content")
        }
        XCTAssertLessThanOrEqual(graphics.canvases.map { $0.width * $0.height }.max() ?? 0, 1000 * 100, "nothing near window size")
        let layers = try XCTUnwrap(host.drawings[.photoFrame]).layers
        let colours = layers.compactMap { layer -> CGRect? in
            if case .color(_, let f) = layer { return f }
            return nil
        }
        let dimmed: CGFloat = colours.reduce(0) { $0 + $1.width * $1.height }
        let window: CGFloat = 2560 * 1440, hole: CGFloat = (2560 - 48) * (1440 - 48)
        XCTAssertEqual(dimmed, window - hole, "dim all but the frame")
        XCTAssertEqual(hud.renderCounts[.pills], 1, "the pills only moved")
    }

    /// Hover and press reach a panel whose drawing tracks the mouse; leaving clears them.
    func testHoverAndPressReachATrackingPanel() async {
        let button = ButtonPanel(tracksMouse: true)
        let hud = PlazaHUD(panels: [button], graphics: stub)
        hud.setViewport(window, scale: 2)
        let host = RecordingPanelHost()   // the HUD holds its host weakly: keep it alive
        hud.host = host
        let id = PlazaPanelID.backgroundToggle
        _ = hud.handleMouse(moved(15, 15), in: id)
        XCTAssertEqual(button.interaction, PlazaPanelInteraction(hovered: ButtonPanel.toggle, pressed: nil))
        _ = hud.handleMouse(moved(45, 15), in: id)
        XCTAssertEqual(button.interaction, PlazaPanelInteraction(), "off the button")
        _ = hud.handleMouse(down(15, 15), in: id)
        XCTAssertEqual(button.interaction, PlazaPanelInteraction(hovered: ButtonPanel.toggle, pressed: ButtonPanel.toggle))
        _ = hud.handleMouse(up(15, 15), in: id)
        XCTAssertEqual(button.interaction, PlazaPanelInteraction(hovered: ButtonPanel.toggle, pressed: nil))
        _ = hud.handleMouse(PlazaMouseEvent(kind: .exited, location: CGPoint(x: 60, y: 15)), in: id)
        XCTAssertEqual(button.interaction, PlazaPanelInteraction())
        XCTAssertEqual(button.interactions.count, 5, "set only when it changed")
    }

    /// No panel takes the scroll wheel (the scrolling panels stay SwiftUI): the window passes it on.
    func testNoPanelTakesTheScrollWheel() async {
        let hud = PlazaHUD(panels: [ButtonPanel()], graphics: stub)
        hud.setViewport(window, scale: 2)
        let host = RecordingPanelHost()   // the HUD holds its host weakly: keep it alive
        hud.host = host
        XCTAssertFalse(hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 3), location: CGPoint(x: 15, y: 15)), in: .backgroundToggle))
    }

    /// VoiceOver's press on an item is the same as a click on its hit.
    func testAnAccessibilityPressIsAClick() async throws {
        let button = ButtonPanel()
        let hud = PlazaHUD(panels: [button], graphics: stub)
        var actions: [PlazaPanelHit] = []
        hud.onAction = { actions.append($1) }
        let host = RecordingPanelHost()
        hud.setViewport(window, scale: 2)
        hud.host = host
        let item = try XCTUnwrap(host.drawings[.backgroundToggle]?.accessibility.first)
        XCTAssertEqual(item.role, .button)
        hud.press(try XCTUnwrap(item.action), in: .backgroundToggle)
        XCTAssertEqual(actions, [ButtonPanel.toggle])
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
