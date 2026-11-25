import XCTest
@testable import PokeTokenBar

/// The drawing quiz panel: when it shows, how big a canvas cell is, where the pointer lands, what a drag draws and what the tools do.
@MainActor
final class PlazaDrawPanelTests: XCTestCase {
    private let wide = CGSize(width: 960, height: 640), narrow = CGSize(width: 600, height: 372)

    private func board(foot: PlazaDrawBoard.Foot = .tools(word: "사과"), cover: String? = nil, canDraw: Bool = true) -> PlazaDrawBoard {
        PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 민수", time: "⏱ 52", cover: cover, foot: foot, canDraw: canDraw)
    }

    @MainActor final class HUDBox { weak var hud: PlazaHUD? }

    /// The panel in a HUD, with a real host. `full`: the other panels as the app has them (roster, pills, chat log, minimap, clock, guide, toggle,
    /// picker) in the stack's order, so the panel finds its neighbours' real frames; else only the pills.
    @MainActor struct Rig {
        let model = PlazaDrawModel()
        let overlay = PlazaOverlayModel()
        let log = PlazaChatLog()
        let guide = PlazaShortcutGuideModel()
        let panel: PlazaDrawPanel
        let hud: PlazaHUD
        let host = RecordingPanelHost()
        let strokes = Box<[[Int]]>([])

        init(viewport: CGSize, scale: CGFloat, layout: PlazaDrawLayout = .top, board: PlazaDrawBoard?, full: Bool = false, chatLines: Int = 6, guideFolded: Bool = false,
             hint: String? = nil, canvas: PlazaDrawCanvas = PlazaDrawCanvas()) {
            let box = HUDBox()
            panel = PlazaDrawPanel(model: model, neighbours: { v, s in box.hud?.frames(of: PlazaDrawPanel.neighbours, viewport: v, scale: s) ?? [:] })
            let pills = PlazaPillsPanel(model: overlay)
            var panels: [any PlazaPanel] = [panel, pills]
            if full {
                let bg = PlazaBackgroundModel()
                let toggle = PlazaBackgroundTogglePanel(model: bg)
                guide.isFolded = guideFolded
                let names = ["지은", "도윤", "민수"], texts = ["집인가?", "ㅋㅋㅋ 지붕이 귀엽다", "사과!", "나무도 있네", "태양 같은데", "정답은 오두막!"]
                for i in 0..<chatLines { log.append(time: Date(), name: names[i % 3], text: texts[i % 6], color: PlazaColor(hex: 0xFF8A80)) }
                let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
                clock.update("낮 14:20")
                let map = PlazaImage(bitmap: PlazaBitmap(width: 48, height: 32, fill: PlazaRGBA(r: 110, g: 186, b: 84, a: 255)))
                let roster = PlazaRosterModel()
                roster.entries = [PlazaRosterEntry(id: "me", nickname: "나", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: .online, isMe: true)]
                panels = [PlazaRosterPanel(model: roster, icons: PlazaStubIconSource()), panel, pills, PlazaChatLogPanel(log: log),
                          PlazaMinimapPanel(model: PlazaMinimapModel(), background: bg, worldSize: PlazaMapData.map.pixelSize, mapImage: { map }), clock,
                          PlazaShortcutGuidePanel(model: guide, toggle: toggle), toggle,
                          PlazaNameColorPickerPanel(model: PlazaNameColorModel(), toggle: toggle, background: bg)]
            }
            hud = PlazaHUD(panels: panels)
            box.hud = hud
            overlay.hint = hint
            model.canvas = canvas
            model.layout = layout
            model.board = board
            let strokes = strokes
            panel.onStroke = { points, _, _ in strokes.value.append(points) }
            hud.setViewport(viewport, scale: scale)
            hud.host = host
        }

        var frame: CGRect { hud.layout(viewport: hud.viewport, scale: hud.scale)[.drawBoard] ?? .zero }

        /// The canvas layer's frame in panel points: the one image that is the canvas's size.
        var canvasFrame: CGRect {
            for case .image(let image, let f) in host.drawings[.drawBoard]?.layers ?? [] where image.width == PlazaDrawCanvas.width { return f }
            for case .color(_, let f) in host.drawings[.drawBoard]?.layers ?? [] where abs(f.width / f.height - 1.5) < 0.001 { return f }
            return .zero
        }

        var canvasBitmap: PlazaBitmap? {
            for case .image(let image, _) in host.drawings[.drawBoard]?.layers ?? [] where image.width == PlazaDrawCanvas.width { return image.bitmap }
            return nil
        }

        /// The window point over cell (x, y)'s middle at the current size.
        func point(cellX x: Int, y: Int) -> CGPoint {
            let c = canvasFrame, f = frame, n = c.width * hud.scale / CGFloat(PlazaDrawCanvas.width)
            return CGPoint(x: f.minX + c.minX + (CGFloat(x) + 0.5) * n / hud.scale, y: f.minY + c.minY + (CGFloat(y) + 0.5) * n / hud.scale)
        }

        func mouse(_ kind: PlazaMouseEvent.Kind, _ at: CGPoint) -> Bool { hud.handleMouse(PlazaMouseEvent(kind: kind, location: at), in: .drawBoard) }
    }

    @MainActor final class Box<T> { var value: T; init(_ v: T) { value = v } }

    func testThePanelShowsOnlyWithABoard() async {
        let r = Rig(viewport: wide, scale: 2, board: nil)
        XCTAssertFalse(r.panel.isVisible)
        XCTAssertNil(r.hud.layout(viewport: wide, scale: 2)[.drawBoard])
        r.model.board = board()
        XCTAssertTrue(r.panel.isVisible)
        XCTAssertNotNil(r.hud.layout(viewport: wide, scale: 2)[.drawBoard])
        r.model.board = nil
        XCTAssertFalse(r.panel.isVisible)
    }

    func testACellIsAWholeNumberOfDevicePixels() async {
        for layout in PlazaDrawLayout.allCases {
            for viewport in [narrow, wide] {
                for scale in [CGFloat(1), 1.25, 1.5, 2] {
                    let r = Rig(viewport: viewport, scale: scale, layout: layout, board: board())
                    let width = r.canvasFrame.width * scale
                    let cells = width / CGFloat(PlazaDrawCanvas.width)
                    let tag = "\(layout) \(viewport) @\(scale)"
                    XCTAssertEqual(width.truncatingRemainder(dividingBy: 96) < 0.001 || 96 - width.truncatingRemainder(dividingBy: 96) < 0.001, true, "\(tag): \(width) px")
                    XCTAssertGreaterThanOrEqual(width, 192 - 0.001, tag)
                    XCTAssertEqual(r.canvasFrame.height * scale, cells * 64, accuracy: 0.001, tag)
                    // the canvas sits on whole device pixels too
                    let at = r.canvasFrame.origin
                    XCTAssertEqual(at.x * scale, (at.x * scale).rounded(), accuracy: 0.001, tag)
                    XCTAssertEqual(at.y * scale, (at.y * scale).rounded(), accuracy: 0.001, tag)
                }
            }
        }
    }

    /// Review Focus 1: the window is resized, or sits at its smallest, while a stroke is under way.
    func testACellUnderThePointerIsTheSameAtEveryWindowSize() async throws {
        for scale in [CGFloat(1), 2] {
            for layout in PlazaDrawLayout.allCases {
                let r = Rig(viewport: narrow, scale: scale, layout: layout, board: board())
                for viewport in [narrow, wide, narrow] {
                    r.hud.setViewport(viewport, scale: scale)
                    let c = r.canvasFrame, tag = "\(layout) \(viewport) @\(scale)"
                    let mid = r.panel.cell(at: CGPoint(x: c.midX, y: c.midY))
                    XCTAssertEqual(mid?.x, 48, tag); XCTAssertEqual(mid?.y, 32, tag)
                    let corner = r.panel.cell(at: CGPoint(x: c.minX, y: c.minY))
                    XCTAssertEqual(corner?.x, 0, tag); XCTAssertEqual(corner?.y, 0, tag)
                    let last = r.panel.cell(at: CGPoint(x: c.maxX - 0.01, y: c.maxY - 0.01))
                    XCTAssertEqual(last?.x, 95, tag); XCTAssertEqual(last?.y, 63, tag)
                    XCTAssertNil(r.panel.cell(at: CGPoint(x: c.minX - 1, y: c.midY)), tag)
                    XCTAssertNil(r.panel.cell(at: CGPoint(x: c.maxX + 1, y: c.midY)), tag)
                    XCTAssertNil(r.panel.cell(at: CGPoint(x: c.midX, y: c.minY - 1)), tag)
                    XCTAssertNil(r.panel.cell(at: CGPoint(x: c.midX, y: c.maxY + 1)), tag)
                    // the window's own point for a cell lands on that cell
                    let p = r.point(cellX: 70, y: 20), f = r.frame
                    let cell = r.panel.cell(at: CGPoint(x: p.x - f.minX, y: p.y - f.minY))
                    XCTAssertEqual(cell?.x, 70, tag); XCTAssertEqual(cell?.y, 20, tag)
                }
                // a stroke begun at one size and continued at the other draws a connected line between the two cells
                XCTAssertTrue(r.mouse(.down, r.point(cellX: 10, y: 10)))
                r.hud.setViewport(wide, scale: scale)
                XCTAssertTrue(r.mouse(.moved, r.point(cellX: 30, y: 20)), "\(layout) @\(scale)")
                r.hud.setViewport(narrow, scale: scale)
                XCTAssertTrue(r.mouse(.up, r.point(cellX: 50, y: 30)))
                for (x, y) in [(10, 10), (20, 15), (30, 20), (40, 25), (50, 30)] {
                    XCTAssertNotEqual(r.model.canvas[x, y], 0, "\(layout) @\(scale): cell (\(x), \(y)) is on the line")
                }
                XCTAssertEqual(r.strokes.value, [[10, 10], [10, 10, 30, 20], [30, 20, 50, 30]], "\(layout) @\(scale)")
            }
        }
    }

    func testALongHeadIsCutShortOfTheTime() async throws {
        let r = Rig(viewport: narrow, scale: 1, layout: .right, board: PlazaDrawBoard(head: String(repeating: "그림 퀴즈 ", count: 12), time: "⏱ 52", cover: nil, foot: .lines(["a"]), canDraw: false))
        let items = try XCTUnwrap(r.host.drawings[.drawBoard]).accessibility
        let head = try XCTUnwrap(items.first), time = try XCTUnwrap(items.dropFirst().first)
        XCTAssertLessThanOrEqual(head.frame.maxX, time.frame.minX)
    }

    func testAPressAndDragDrawAndReport() async {
        let r = Rig(viewport: wide, scale: 2, board: board())
        r.model.color = 2
        XCTAssertTrue(r.mouse(.down, r.point(cellX: 10, y: 10)))
        XCTAssertTrue(r.mouse(.moved, r.point(cellX: 20, y: 10)))
        XCTAssertTrue(r.mouse(.moved, r.point(cellX: 20, y: 20)))
        XCTAssertTrue(r.mouse(.up, r.point(cellX: 20, y: 20)))
        XCTAssertEqual(r.model.canvas[10, 10], 2)
        XCTAssertEqual(r.model.canvas[15, 10], 2)
        XCTAssertEqual(r.model.canvas[20, 15], 2)
        XCTAssertEqual(r.model.canvas[50, 50], 0)
        XCTAssertEqual(r.strokes.value, [[10, 10], [10, 10, 20, 10], [20, 10, 20, 20]], "the up on the cell the pointer is on adds nothing")
        // the eraser is five wide and paper
        r.strokes.value = []
        r.model.color = 0
        _ = r.mouse(.down, r.point(cellX: 15, y: 10))
        _ = r.mouse(.up, r.point(cellX: 15, y: 10))
        XCTAssertEqual(r.model.canvas[15, 10], 0)
        XCTAssertEqual(r.model.canvas[15, 12], 0, "five wide")
        XCTAssertEqual(r.model.canvas[17, 10], 0)
        XCTAssertEqual(r.model.canvas[18, 10], 2)
    }

    func testNothingIsDrawnWhenTheBoardDoesNotLetMeDraw() async {
        let r = Rig(viewport: wide, scale: 2, board: board(canDraw: false))
        let before = r.model.canvas
        _ = r.mouse(.down, r.point(cellX: 10, y: 10))
        _ = r.mouse(.moved, r.point(cellX: 30, y: 30))
        _ = r.mouse(.up, r.point(cellX: 30, y: 30))
        XCTAssertEqual(r.model.canvas, before)
        XCTAssertEqual(r.strokes.value, [])
        XCTAssertFalse(r.panel.scrollerContains(CGPoint(x: r.canvasFrame.midX, y: r.canvasFrame.midY)))
        // the turn ends under the pen: what comes after draws nothing
        r.model.board = board(canDraw: true)
        _ = r.mouse(.down, r.point(cellX: 10, y: 10))
        r.model.board = board(canDraw: false)
        _ = r.mouse(.moved, r.point(cellX: 30, y: 30))
        _ = r.mouse(.up, r.point(cellX: 30, y: 30))
        XCTAssertEqual(r.strokes.value, [[10, 10]])
        XCTAssertEqual(r.model.canvas[30, 30], 0)
    }

    func testLeavingTheCanvasEndsTheStrokeAndComingBackStartsANewOne() async {
        let r = Rig(viewport: wide, scale: 2, board: board())
        r.model.width = 1
        _ = r.mouse(.down, r.point(cellX: 10, y: 10))
        _ = r.mouse(.moved, r.point(cellX: 20, y: 10))
        // a lost capture on Windows reports a point that is outside every frame
        XCTAssertTrue(r.mouse(.moved, CGPoint(x: -100_000, y: -100_000)))
        _ = r.mouse(.moved, r.point(cellX: 60, y: 40))
        _ = r.mouse(.moved, r.point(cellX: 70, y: 40))
        _ = r.mouse(.up, r.point(cellX: 70, y: 40))
        XCTAssertEqual(r.strokes.value, [[10, 10], [10, 10, 20, 10], [60, 40], [60, 40, 70, 40]])
        XCTAssertEqual(r.model.canvas[40, 25], 0, "no line joins the two parts")
        XCTAssertNotEqual(r.model.canvas[15, 10], 0)
        XCTAssertNotEqual(r.model.canvas[65, 40], 0)
        // the release outside ends it, and the next press is a new stroke
        r.strokes.value = []
        _ = r.mouse(.down, r.point(cellX: 5, y: 5))
        _ = r.mouse(.up, CGPoint(x: -100_000, y: -100_000))
        _ = r.mouse(.down, r.point(cellX: 80, y: 60))
        XCTAssertEqual(r.strokes.value, [[5, 5], [80, 60]])
    }

    func testToolClicksChangeTheModel() async throws {
        let r = Rig(viewport: wide, scale: 2, board: board())
        var cleared = 0
        r.panel.onClear = { cleared += 1 }
        let items = try XCTUnwrap(r.host.drawings[.drawBoard]).accessibility
        func click(_ label: String) throws {
            let item = try XCTUnwrap(items.first { $0.label == label }, label)
            let hit = try XCTUnwrap(r.panel.hit(CGPoint(x: item.frame.midX, y: item.frame.midY)), label)
            XCTAssertEqual(hit, item.action, label)
            r.panel.clicked(hit)
        }
        let l = L(.ko)
        try click(l.plazaDrawColorName(5))
        XCTAssertEqual(r.model.color, 5)
        try click(l.plazaDrawToolThinPen)
        XCTAssertEqual(r.model.width, 1)
        try click(l.plazaDrawToolThickPen)
        XCTAssertEqual(r.model.width, 3)
        try click(l.plazaDrawToolEraser)
        XCTAssertEqual(r.model.color, 0)
        try click(l.plazaDrawToolThinPen)
        XCTAssertEqual(r.model.color, 5, "a pen again: back to the colour it had")
        XCTAssertEqual(r.model.width, 1)
        XCTAssertEqual(cleared, 0)
        r.model.canvas.stroke(points: [3, 3, 9, 9], color: 2, width: 3)
        try click(l.plazaDrawToolClear)
        XCTAssertEqual(r.model.canvas, PlazaDrawCanvas())
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(items.filter { $0.role == .button }.count, 12, "eight colours and four tools")
        // a click through the HUD (a press and a release on the same hit) reaches the panel's click handler
        var actions: [PlazaPanelHit] = []
        r.hud.onAction = { _, hit in actions.append(hit) }
        let swatch = try XCTUnwrap(items.first { $0.label == l.plazaDrawColorName(3) }), f = r.frame
        let at = CGPoint(x: f.minX + swatch.frame.midX, y: f.minY + swatch.frame.midY)
        _ = r.mouse(.down, at)
        _ = r.mouse(.up, at)
        XCTAssertEqual(actions, [PlazaPanelHit(action: "color", index: 3)])
    }

    func testToolsDoNothingWhenTheBoardDoesNotLetMeDraw() async {
        let r = Rig(viewport: wide, scale: 2, board: board(canDraw: false))
        r.model.canvas.stroke(points: [3, 3, 9, 9], color: 2, width: 3)
        r.panel.clicked(PlazaPanelHit(action: "color", index: 6))
        r.panel.clicked(PlazaPanelHit(action: "clear", index: nil))
        XCTAssertEqual(r.model.color, 1)
        XCTAssertNotEqual(r.model.canvas[5, 5], 0)
    }

    func testOnlyTheDrawerSeesTools() async throws {
        let r = Rig(viewport: wide, scale: 2, board: board(foot: .lines(["민수님이 그리는 중", "Enter로 답을 말해요"])))
        let drawing = try XCTUnwrap(r.host.drawings[.drawBoard])
        XCTAssertEqual(drawing.accessibility.filter { $0.role == .button }.count, 0)
        let f = r.canvasFrame, size = r.frame.size
        for y in stride(from: f.maxY + 1, to: size.height, by: 3) {
            for x in stride(from: CGFloat(0), to: size.width, by: 3) {
                let hit = r.panel.hit(CGPoint(x: x, y: y))
                XCTAssertEqual(hit, PlazaPanelHit(action: "board", index: nil), "(\(x), \(y)) under the canvas is the plate")
            }
        }
        XCTAssertEqual(r.panel.hit(CGPoint(x: f.midX, y: f.midY)), PlazaPanelHit(action: "canvas", index: nil))
        XCTAssertNil(r.panel.hit(CGPoint(x: -1, y: 5)), "outside the plate the click goes on to the plaza")
        XCTAssertTrue(drawing.accessibility.contains { $0.label == "Enter로 답을 말해요" })
    }

    func testACoverHidesTheCanvasAndTakesNoStrokes() async throws {
        let r = Rig(viewport: wide, scale: 2, board: board(cover: "민수님이 제시어를 정하고 있어요"))
        r.model.canvas.stroke(points: [3, 3, 9, 9], color: 2, width: 3)
        let c = r.canvasFrame
        XCTAssertFalse(r.panel.scrollerContains(CGPoint(x: c.midX, y: c.midY)))
        let layers = try XCTUnwrap(r.host.drawings[.drawBoard]).layers
        XCTAssertFalse(layers.contains { if case .image(let i, _) = $0 { return i.width == PlazaDrawCanvas.width } else { return false } },
                       "the canvas's picture is not drawn under the cover")
        XCTAssertTrue(try XCTUnwrap(r.host.drawings[.drawBoard]).accessibility.contains { $0.label == "민수님이 제시어를 정하고 있어요" })
    }

    func testAChangeOfTheCanvasRendersAtMostThirtyTimesASecondAndOnceMoreAtTheEnd() async throws {
        let r = Rig(viewport: wide, scale: 2, board: board())
        try await Task.sleep(for: .milliseconds(60))
        let base = r.hud.renderCounts[.drawBoard] ?? 0
        for i in 0..<20 {
            r.model.canvas.stroke(points: [i, i], color: 2, width: 1)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(15))
        let during = (r.hud.renderCounts[.drawBoard] ?? 0) - base
        XCTAssertLessThanOrEqual(during, 2, "a burst renders once at its start, not 20 times")
        try await Task.sleep(for: .milliseconds(150))
        let after = (r.hud.renderCounts[.drawBoard] ?? 0) - base
        XCTAssertGreaterThanOrEqual(after, 2, "and once more after the last change")
        XCTAssertLessThanOrEqual(after, 3)
        // the last render holds the last stroke
        let bitmap = try XCTUnwrap(r.canvasBitmap)
        XCTAssertEqual(bitmap[19, 19], PlazaDraw.palette[2])
    }

    func testTheLayoutsKeepTheirPlace() async throws {
        for viewport in [narrow, wide] {
            let withPills = Rig(viewport: viewport, scale: 1, layout: .top, board: board())
            withPills.overlay.hint = "안내"
            let pillsFrame = try XCTUnwrap(withPills.hud.layout(viewport: viewport, scale: 1)[.pills])
            let top = try XCTUnwrap(withPills.hud.layout(viewport: viewport, scale: 1)[.drawBoard])
            XCTAssertGreaterThanOrEqual(top.minY, pillsFrame.maxY, "under the pills")
            XCTAssertEqual(top.midX, viewport.width / 2, accuracy: 1, "centred")
            let right = Rig(viewport: viewport, scale: 1, layout: .right, board: board()).frame
            XCTAssertEqual(right.maxX, viewport.width - PlazaRosterMetrics.margin, accuracy: 1, "against the right margin")
        }
    }

    /// The panel keeps clear of the panels above it, by their real frames: the chat log (6 lines) is never covered; `right` covers the minimap
    /// and the clock on purpose (it is drawn above them); `top` keeps clear of those and of the guide, with the HUD in the state it needs at
    /// the smallest window (chat log of 3 lines, guide folded).
    func testNoLayoutIsCoveredByThePanelsAboveIt() async throws {
        for viewport in [narrow, wide] {
            for scale in [CGFloat(1), 1.25, 1.5, 2] {
                for layout in PlazaDrawLayout.allCases {
                    let small = viewport == narrow && layout == .top
                    let r = Rig(viewport: viewport, scale: scale, layout: layout, board: board(), full: true, chatLines: small ? 3 : 6, guideFolded: small, hint: "안내")
                    let tag = "\(layout) \(viewport) @\(scale)"
                    let frames = r.hud.layout(viewport: viewport, scale: scale)
                    let mine = try XCTUnwrap(frames[.drawBoard], tag)
                    let placed = r.panel.layout(in: viewport, scale: scale, text: PlatformPlaza.graphics.text)
                    XCTAssertGreaterThanOrEqual(placed.cell, 2, tag)
                    // Known limit, measured: centred under the pills, `top` has no room at 600x372 at 1x and 1.25x even with the 3-line log and the
                    // folded guide (the minimap and the clock take the right of the middle, the log the bottom): it keeps the smallest cell and says so.
                    if layout == .top && viewport == narrow && scale < 1.5 {
                        XCTAssertFalse(placed.fits, "\(tag): if this fits now, drop the exception")
                        continue
                    }
                    XCTAssertTrue(placed.fits, "\(tag): the smallest cell fits")
                    let chat = try XCTUnwrap(frames[.chatLog], tag)
                    XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(mine), "\(tag): inside the window \(mine)")
                    XCTAssertFalse(mine.intersects(chat), "\(tag): the chat log is clear \(mine) \(chat)")
                    if layout == .top {
                        for id in [PlazaPanelID.minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker, .pills] {
                            XCTAssertFalse(mine.intersects(try XCTUnwrap(frames[id], "\(tag) \(id)")), "\(tag): \(id) is clear")
                        }
                    }
                    // every tool and the canvas are inside the panel (so inside the window), and no tool is under 14 points tall
                    let items = try XCTUnwrap(r.host.drawings[.drawBoard], tag).accessibility
                    for item in items where item.role == .button { XCTAssertGreaterThanOrEqual(item.frame.height, 14, tag) }
                    for item in items { XCTAssertTrue(CGRect(origin: .zero, size: mine.size).insetBy(dx: -0.001, dy: -0.001).contains(item.frame), "\(tag): \(item.label) inside the panel") }
                }
            }
        }
    }
}
