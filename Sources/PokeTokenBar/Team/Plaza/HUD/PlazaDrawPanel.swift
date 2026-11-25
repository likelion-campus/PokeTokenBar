import Foundation
import Observation

/// What the drawing quiz panel shows right now; the controller derives it on every game step.
struct PlazaDrawBoard: Equatable {
    /// "그림 퀴즈 3/6 · 그리는 사람 민수"
    var head: String
    /// "⏱ 52"
    var time: String
    /// Text over an empty canvas (the word is being entered); nil shows the canvas.
    var cover: String?
    enum Foot: Equatable {
        /// The drawer's: the word and the colour and tool buttons.
        case tools(word: String)
        /// A guesser's (or a result's): plain lines.
        case lines([String])
    }
    var foot: Foot
    /// The canvas takes strokes and the tool buttons act.
    var canDraw: Bool
}

/// Where the panel sits. The user picks one from the layout sheet; the others are removed then.
enum PlazaDrawLayout: String, CaseIterable, Sendable { case center, top, side }

@MainActor @Observable final class PlazaDrawModel {
    /// nil hides the panel.
    var board: PlazaDrawBoard?
    var canvas = PlazaDrawCanvas()
    /// 1...8, or 0 for the eraser.
    var color = 1
    /// 1 or 3; the eraser draws 5 wide.
    var width = 3
    var layout: PlazaDrawLayout = .center
}

/// The drawing quiz's panel: a head line (turn, drawer, time), the canvas, and under it the drawer's tools or a guesser's lines. The canvas
/// is one image layer the hosts enlarge with nearest sampling; its cell is a whole number of device pixels, so the picture is never uneven
/// at 125 % or 150 %. A press on the canvas is captured like a scroller's track (`scrollerContains` / `scrollerMouse`) and each point of the
/// drag becomes a cell. A change of the canvas renders at most 30 times a second and once more after the last change.
@MainActor final class PlazaDrawPanel: PlazaPanel {
    let id = PlazaPanelID.drawBoard
    var onChange: (() -> Void)?
    /// A stroke the user just drew on this machine, already applied to `model.canvas`: canvas points, colour, width.
    var onStroke: ((_ points: [Int], _ color: Int, _ width: Int) -> Void)?
    var onClear: (() -> Void)?
    private let model: PlazaDrawModel
    private let pills: PlazaPillsPanel
    private var observer: PlazaChangeObserver?

    static let padding = PlazaMenuPanel.padding, rowGap: CGFloat = 6, toolGap: CGFloat = 4, swatch: CGFloat = 20, swatchGap: CGFloat = 6
    static let buttonPadding = CGSize(width: 10, height: 4), buttonGap: CGFloat = 6, minCell = 2
    /// What a window of the side layout leaves under the panel for the clock and the minimap (their frames are the controller's).
    static let sideBottomReserve: CGFloat = 190
    static let minInterval = Duration.milliseconds(33)
    private static let gold = PlazaColor(hex: 0xF2C14E)
    private static let ink = PlazaColor(hex: 0x2B2233)

    init(model: PlazaDrawModel, pills: PlazaPillsPanel) {
        self.model = model
        self.pills = pills
        observer = PlazaChangeObserver(track: { _ = model.board; _ = model.canvas; _ = model.color; _ = model.width; _ = model.layout },
                                       changed: { [weak self] in self?.modelChanged() })
    }

    // MARK: change reports

    private struct Look: Equatable { let board: PlazaDrawBoard?, color: Int, width: Int, layout: PlazaDrawLayout }
    private var look: Look { Look(board: model.board, color: model.color, width: model.width, layout: model.layout) }
    private var reported: Look?
    private var lastReport: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?

    private func modelChanged() {
        let now = look
        if now != reported {   // a tool, the board or the layout: shown at once
            reported = now
            report()
            return
        }
        // only the canvas: at most 30 times a second, and once more when the burst ends
        let clock = ContinuousClock()
        if let last = lastReport, clock.now - last < Self.minInterval {
            guard trailing == nil else { return }
            let wait = Self.minInterval - (clock.now - last)
            trailing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                self?.report()
            }
            return
        }
        report()
    }

    private func report() {
        trailing = nil
        lastReport = ContinuousClock().now
        onChange?()
    }

    // MARK: place

    var anchor: PlazaPanelAnchor {
        switch model.layout {
        case .center: .center
        case .top: .topCenter
        case .side: .topTrailing
        }
    }

    var offset: CGPoint { .zero }

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint {
        let margin = PlazaRosterMetrics.margin
        let pillsHeight = pills.stack(in: viewport, scale: scale, text: text).size.height
        let top = margin + (pillsHeight > 0 ? pillsHeight + PlazaPanelStyle.pillSpacing : 0)
        switch model.layout {
        case .center: return .zero
        case .top: return CGPoint(x: 0, y: top)
        case .side:
            // Bottom edge a reserve above the window's, but never higher than under the pills.
            let height = layout(in: viewport, scale: scale, text: text).size.height
            return CGPoint(x: margin, y: PlazaPanelStyle.pixel(max(top, viewport.height - Self.sideBottomReserve - height), scale: scale))
        }
    }

    var isVisible: Bool { model.board != nil }

    // MARK: layout

    struct Button {
        let hit: PlazaPanelHit
        let label: String
        let line: PlazaTextLine
        let frame: CGRect
        let selected: Bool
    }

    struct Placed {
        let scale: CGFloat
        /// The canvas cell, in device pixels.
        let cell: Int
        let size: CGSize
        let head: (line: PlazaTextLine, frame: CGRect)
        let time: (line: PlazaTextLine, frame: CGRect)
        let canvas: CGRect
        let cover: [(line: PlazaTextLine, text: String, frame: CGRect)]
        let word: (line: PlazaTextLine, text: String, frame: CGRect)?
        let swatches: [(index: Int, frame: CGRect)]
        let buttons: [Button]
        let lines: [(line: PlazaTextLine, text: String, frame: CGRect)]
    }

    private struct Key: Equatable { let viewport: CGSize, scale: CGFloat, board: PlazaDrawBoard?, color: Int, width: Int, layout: PlazaDrawLayout, engine: String, pillsHeight: CGFloat }
    private var laidOut: (key: Key, placed: Placed)?
    /// The layout of the last `size` or `render`: what `hit` and `cell(at:)` read.
    private var placed: Placed? { laidOut?.placed }

    func layout(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> Placed {
        let key = Key(viewport: viewport, scale: scale, board: model.board, color: model.color, width: model.width, layout: model.layout,
                      engine: String(describing: type(of: text)), pillsHeight: model.layout == .center ? 0 : pills.stack(in: viewport, scale: scale, text: text).size.height)
        if let laidOut, laidOut.key == key { return laidOut.placed }
        let made = build(viewport: viewport, scale: scale, text: text, pillsHeight: key.pillsHeight)
        laidOut = (key, made)
        return made
    }

    private func build(viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine, pillsHeight: CGFloat) -> Placed {
        let l = L(.ko)
        let font = PlazaFont.plaza(.body)
        let metrics = text.metrics(font)
        let lineH = (metrics.ascender - metrics.descender).rounded()
        let pad = Self.padding, gap = Self.rowGap, margin = PlazaRosterMetrics.margin
        let board = model.board ?? PlazaDrawBoard(head: "", time: "", cover: nil, foot: .lines([]), canDraw: false)
        func width(_ line: PlazaTextLine) -> CGFloat { PlazaPanelStyle.pixelUp(line.width, scale: scale) }
        func centered(_ rowWidth: CGFloat, in inner: CGFloat) -> CGFloat { pad + PlazaPanelStyle.pixel((inner - rowWidth) / 2, scale: scale) }

        var head = text.line(board.head, font: font)
        let time = text.line(board.time, font: font)
        let buttonH = lineH + 2 * Self.buttonPadding.height

        // What the foot needs, and (for the tools) the least width it takes.
        var word: (PlazaTextLine, String)?
        var toolButtons: [(hit: PlazaPanelHit, label: String, line: PlazaTextLine, selected: Bool)] = []
        var toolsWidth: CGFloat = 0
        var swatchesWidth: CGFloat = 0
        if case .tools(let w) = board.foot {
            let shown = "\(l.plazaDrawWord) \(w)"
            word = (text.line(shown, font: font), shown)
            let pen = model.color != 0
            toolButtons = [
                (PlazaPanelHit(action: "width", index: 1), l.plazaDrawToolThinPen, text.line(l.plazaDrawToolThinPen, font: font), pen && model.width == 1),
                (PlazaPanelHit(action: "width", index: 3), l.plazaDrawToolThickPen, text.line(l.plazaDrawToolThickPen, font: font), pen && model.width == 3),
                (PlazaPanelHit(action: "erase", index: nil), l.plazaDrawToolEraser, text.line(l.plazaDrawToolEraser, font: font), !pen),
                (PlazaPanelHit(action: "clear", index: nil), l.plazaDrawToolClear, text.line(l.plazaDrawToolClear, font: font), false),
            ]
            let buttonsWidth = toolButtons.map { PlazaPanelStyle.pixelUp($0.line.width, scale: scale) + 2 * Self.buttonPadding.width }.reduce(0, +)
                + CGFloat(toolButtons.count - 1) * Self.buttonGap
            swatchesWidth = CGFloat(PlazaDraw.palette.count - 1) * Self.swatch + CGFloat(PlazaDraw.palette.count - 2) * Self.swatchGap
            toolsWidth = max(buttonsWidth, swatchesWidth, width(word!.0))
        }

        func footLines(_ innerWidth: CGFloat) -> [(PlazaTextLine, String)] {
            guard case .lines(let strings) = board.foot else { return [] }
            return strings.flatMap { s in text.wrappedLines(s, font: font, width: innerWidth).map { ($0, s) } }
        }
        func footHeight(_ innerWidth: CGFloat) -> CGFloat {
            if word != nil { return lineH + 2 * Self.toolGap + Self.swatch + buttonH }
            let n = footLines(innerWidth).count
            return n == 0 ? 0 : CGFloat(n) * lineH + CGFloat(n - 1) * 3
        }
        func canvasSize(_ n: Int) -> CGSize { CGSize(width: CGFloat(PlazaDrawCanvas.width * n) / scale, height: CGFloat(PlazaDrawCanvas.height * n) / scale) }
        func innerWidth(_ n: Int) -> CGFloat { max(canvasSize(n).width, toolsWidth) }
        func panelSize(_ n: Int) -> CGSize {
            let inner = innerWidth(n), foot = footHeight(inner)
            return CGSize(width: PlazaPanelStyle.pixelUp(2 * pad + inner, scale: scale),
                          height: PlazaPanelStyle.pixelUp(2 * pad + lineH + gap + canvasSize(n).height + (foot > 0 ? gap + foot : 0), scale: scale))
        }

        // The largest cell, in whole device pixels, that fits the layout's room.
        let top = margin + (pillsHeight > 0 ? pillsHeight + PlazaPanelStyle.pillSpacing : 0)
        let room: CGSize
        switch model.layout {
        case .center: room = CGSize(width: viewport.width - 2 * margin, height: viewport.height - 2 * margin)
        case .top: room = CGSize(width: viewport.width - 2 * margin, height: viewport.height - top - margin)
        case .side: room = CGSize(width: (viewport.width - 2 * margin) / 2, height: viewport.height - top - Self.sideBottomReserve)
        }
        var n = Self.minCell
        var candidate = max(Self.minCell, Int((room.width * scale).rounded(.down)) / PlazaDrawCanvas.width)
        while candidate > Self.minCell {
            let s = panelSize(candidate)
            if s.width <= room.width, s.height <= room.height { n = candidate; break }
            candidate -= 1
        }

        let size = panelSize(n)
        let inner = innerWidth(n), canvasW = canvasSize(n)
        // A narrow canvas cuts the head short of the time.
        let headRoom = inner - width(time) - 2 * gap
        if width(head) > headRoom { head = text.truncated(head, width: max(0, headRoom), ellipsis: text.line("…", font: font)) ?? head }
        var y = pad
        let headFrame = CGRect(x: pad, y: y, width: width(head), height: lineH)
        let timeFrame = CGRect(x: pad + inner - width(time), y: y, width: width(time), height: lineH)
        y += lineH + gap
        let canvasY = PlazaPanelStyle.pixel(y, scale: scale)
        let canvas = CGRect(x: centered(canvasW.width, in: inner), y: canvasY, width: canvasW.width, height: canvasW.height)
        y = canvas.maxY + gap

        var cover: [(PlazaTextLine, String, CGRect)] = []
        if let text0 = board.cover {
            let lines = text.wrappedLines(text0, font: font, width: max(1, canvas.width - 2 * pad))
            let block = CGFloat(lines.count) * lineH
            var cy = canvas.minY + max(0, (canvas.height - block) / 2)
            for line in lines {
                let w = width(line)
                cover.append((line, text0, CGRect(x: canvas.minX + (canvas.width - w) / 2, y: cy, width: w, height: lineH)))
                cy += lineH
            }
        }

        var wordPlaced: (PlazaTextLine, String, CGRect)?
        var swatches: [(Int, CGRect)] = []
        var buttons: [Button] = []
        var lines: [(PlazaTextLine, String, CGRect)] = []
        if let word {
            let w = width(word.0)
            wordPlaced = (word.0, word.1, CGRect(x: centered(w, in: inner), y: y, width: w, height: lineH))
            y += lineH + Self.toolGap
            var x = centered(swatchesWidth, in: inner)
            for i in 1..<PlazaDraw.palette.count {
                swatches.append((i, CGRect(x: x, y: y, width: Self.swatch, height: Self.swatch)))
                x += Self.swatch + Self.swatchGap
            }
            y += Self.swatch + Self.toolGap
            let widths = toolButtons.map { PlazaPanelStyle.pixelUp($0.line.width, scale: scale) + 2 * Self.buttonPadding.width }
            x = centered(widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.buttonGap, in: inner)
            for (b, w) in zip(toolButtons, widths) {
                buttons.append(Button(hit: b.hit, label: b.label, line: b.line, frame: CGRect(x: x, y: y, width: w, height: buttonH), selected: b.selected))
                x += w + Self.buttonGap
            }
        } else {
            for (line, s) in footLines(inner) {
                let w = width(line)
                lines.append((line, s, CGRect(x: centered(w, in: inner), y: y, width: w, height: lineH)))
                y += lineH + 3
            }
        }
        return Placed(scale: scale, cell: n, size: size, head: (head, headFrame), time: (time, timeFrame), canvas: canvas, cover: cover, word: wordPlaced,
                      swatches: swatches, buttons: buttons, lines: lines)
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        guard model.board != nil else { return .zero }
        return layout(in: viewport, scale: scale, text: text).size
    }

    // MARK: drawing

    private var plate: (key: String, image: PlazaImage?) = ("", nil)

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        guard let board = model.board else { return PlazaPanelDrawing() }
        let text = graphics.text
        let p = layout(in: viewport, scale: scale, text: text)
        let font = PlazaFont.plaza(.body)
        let m = text.metrics(font)
        let space = PlazaPanelSpace(content: p.size, room: 0)
        let l = L(.ko)

        // The plate and everything on it but the canvas changes with the board and the tools only, not with every stroke.
        let key = "\(p.size) \(scale) \(String(describing: type(of: text))) \(board) \(model.color) \(model.width) \(model.layout) \(p.canvas)"
        if plate.key != key {
            plate = (key, space.image(scale: scale, graphics: graphics) { canvas in
                PlazaMenuBackground.draw(on: canvas, rect: space.canvas(CGRect(origin: .zero, size: p.size)))
                func draw(_ line: PlazaTextLine, in frame: CGRect, _ color: PlazaColor) {
                    canvas.setFillColor(color)
                    canvas.draw(line, at: space.canvas(CGPoint(x: frame.minX, y: frame.minY + m.ascender)))
                }
                canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
                canvas.draw(p.head.line, at: space.canvas(CGPoint(x: p.head.frame.minX + 1, y: p.head.frame.minY + m.ascender + 1)))
                draw(p.head.line, in: p.head.frame, Self.gold)
                draw(p.time.line, in: p.time.frame, .white)
                canvas.setFillColor(PlazaColor(hex: 0x1D4F55))
                canvas.fill(space.canvas(p.canvas.insetBy(dx: -3, dy: -3)))
                if let w = p.word { draw(w.line, in: w.frame, .white) }
                for l in p.lines { draw(l.line, in: l.frame, .white) }
                canvas.saveState()
                if !board.canDraw { canvas.setAlpha(0.45) }
                for s in p.swatches {
                    let c = PlazaDraw.palette[s.index]
                    let r = space.canvas(s.frame)
                    if model.color == s.index {
                        canvas.setFillColor(.white)
                        canvas.fill(r.insetBy(dx: -3, dy: -3))
                    }
                    canvas.setFillColor(PlazaColor(hex: 0x1D4F55))
                    canvas.fill(r.insetBy(dx: -1, dy: -1))
                    canvas.setFillColor(PlazaColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
                    canvas.fill(r)
                }
                for b in p.buttons {
                    let r = space.canvas(b.frame)
                    canvas.setFillColor(b.selected ? PlazaColor(hex: 0x2D7F87) : PlazaColor(hex: 0x1D4F55))
                    canvas.fillRoundedRect(r, radius: 6)
                    canvas.setStrokeColor(b.selected ? Self.gold : PlazaColor(hex: 0x5FB7BD))
                    canvas.strokeRoundedRect(r, radius: 6, lineWidth: b.selected ? 2 : 1)
                    draw(b.line, in: CGRect(x: b.frame.minX + Self.buttonPadding.width, y: b.frame.minY + Self.buttonPadding.height,
                                            width: b.line.width, height: b.frame.height), .white)
                }
                canvas.restoreState()
            })
        }
        var layers: [PlazaPanelLayer] = []
        if let image = plate.image { layers.append(.image(image, frame: CGRect(origin: .zero, size: p.size))) }
        var items = [PlazaAccessibilityItem(frame: p.head.frame, role: .staticText, label: board.head),
                     PlazaAccessibilityItem(frame: p.time.frame, role: .staticText, label: board.time)]
        if board.cover == nil {
            layers.append(.image(PlazaImage(bitmap: model.canvas.bitmap(palette: PlazaDraw.palette)), frame: p.canvas))
        } else {
            let paper = PlazaDraw.palette[0]
            layers.append(.color(PlazaColor(srgbRed: CGFloat(paper.r) / 255, green: CGFloat(paper.g) / 255, blue: CGFloat(paper.b) / 255, alpha: 1), frame: p.canvas))
            for c in p.cover {
                if let image = PlazaPanelSpace(content: c.frame.size, room: 0).image(scale: scale, graphics: graphics, { canvas in
                    canvas.setFillColor(Self.ink)
                    canvas.draw(c.line, at: CGPoint(x: 0, y: c.frame.height - m.ascender))
                }) { layers.append(.image(image, frame: c.frame)) }
            }
            items.append(PlazaAccessibilityItem(frame: p.canvas, role: .staticText, label: board.cover ?? ""))
        }
        if let w = p.word { items.append(PlazaAccessibilityItem(frame: w.frame, role: .staticText, label: w.text)) }
        for s in p.swatches {
            items.append(PlazaAccessibilityItem(frame: s.frame, role: .button, label: l.plazaDrawColorName(s.index),
                                                action: PlazaPanelHit(action: "color", index: s.index), isEnabled: board.canDraw))
        }
        for b in p.buttons { items.append(PlazaAccessibilityItem(frame: b.frame, role: .button, label: b.label, action: b.hit, isEnabled: board.canDraw)) }
        for line in p.lines { items.append(PlazaAccessibilityItem(frame: line.frame, role: .staticText, label: line.text)) }
        return PlazaPanelDrawing(layers: layers, accessibility: items)
    }

    // MARK: input

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let p = placed, CGRect(origin: .zero, size: p.size).contains(point) else { return nil }
        if let s = p.swatches.first(where: { $0.frame.insetBy(dx: -Self.swatchGap / 2, dy: -Self.toolGap).contains(point) }) {
            return PlazaPanelHit(action: "color", index: s.index)
        }
        if let b = p.buttons.first(where: { $0.frame.contains(point) }) { return b.hit }
        if p.canvas.contains(point) { return PlazaPanelHit(action: "canvas", index: nil) }
        return PlazaPanelHit(action: "board", index: nil)
    }

    /// A click the HUD reported on this panel (`PlazaWindowController.panelClicked` passes every `.drawBoard` hit here). The tools act only while the
    /// board lets me draw.
    private var penColor = 1
    func clicked(_ hit: PlazaPanelHit) {
        guard model.board?.canDraw == true else { return }
        switch hit.action {
        case "color":
            guard let i = hit.index, (1..<PlazaDrawCanvas.colorCount).contains(i) else { return }
            model.color = i
            penColor = i
        case "width":
            guard let i = hit.index, i == 1 || i == 3 else { return }
            if model.color == 0 { model.color = penColor }
            model.width = i
        case "erase":
            if model.color != 0 { penColor = model.color }
            model.color = 0
        case "clear":
            model.canvas.clear()
            onClear?()
        default: break
        }
    }

    /// The cell under a panel point, nil outside the canvas.
    func cell(at point: CGPoint) -> (x: Int, y: Int)? {
        guard let p = placed, p.canvas.contains(point) else { return nil }
        // the cell is `p.cell` device pixels; the small bias keeps a point on a cell's edge from falling into the one before it
        let x = Int(((point.x - p.canvas.minX) * p.scale / CGFloat(p.cell) + 1e-6).rounded(.down))
        let y = Int(((point.y - p.canvas.minY) * p.scale / CGFloat(p.cell) + 1e-6).rounded(.down))
        guard (0..<PlazaDrawCanvas.width).contains(x), (0..<PlazaDrawCanvas.height).contains(y) else { return nil }
        return (x, y)
    }

    func scrollerContains(_ point: CGPoint) -> Bool {
        guard let board = model.board, board.canDraw, board.cover == nil, let p = placed else { return false }
        return p.canvas.contains(point)
    }

    private var last: (x: Int, y: Int)?

    func scrollerMouse(_ phase: PlazaScrollerPhase, at point: CGPoint) {
        guard model.board?.canDraw == true else { last = nil; return }
        if phase == .down { last = nil }
        extend(to: cell(at: point))
        if phase == .up { last = nil }
    }

    /// One segment from the last cell (or a dot) to `cell`; outside the canvas ends the stroke.
    private func extend(to cell: (x: Int, y: Int)?) {
        guard let cell else { last = nil; return }
        if let last, last == cell { return }
        let points = last.map { [$0.x, $0.y, cell.x, cell.y] } ?? [cell.x, cell.y]
        last = cell
        let color = model.color, width = color == 0 ? 5 : model.width
        guard model.canvas.stroke(points: points, color: color, width: width) else { return }
        onStroke?(points, color, width)
    }
}
