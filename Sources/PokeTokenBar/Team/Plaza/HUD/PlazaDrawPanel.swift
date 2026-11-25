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

@MainActor @Observable final class PlazaDrawModel {
    /// nil hides the panel.
    var board: PlazaDrawBoard?
    var canvas = PlazaDrawCanvas()
    /// 1...8, or 0 for the eraser.
    var color = 1
    /// 1 or 3; the eraser draws 5 wide.
    var width = 3
}

/// The drawing quiz's panel: a head line (turn, drawer, time), the canvas, and under it the drawer's tools or a guesser's lines. It sits under the
/// pills, as near the window's middle as the other panels allow: the chat log is never covered, and it slides sideways just enough to clear the
/// minimap, the clock and the shortcuts guide. The canvas is one image layer the hosts enlarge with nearest sampling; its cell is a whole number
/// of device pixels, so the picture is never uneven at 125 % or 150 %. A press on the canvas is captured like a scroller's track
/// (`scrollerContains` / `scrollerMouse`) and each point of the drag becomes a cell. A change of the canvas renders at most 30 times a second and
/// once more after the last change.
@MainActor final class PlazaDrawPanel: PlazaPanel {
    let id = PlazaPanelID.drawBoard
    var onChange: (() -> Void)?
    /// A stroke the user just drew on this machine, already applied to `model.canvas`: canvas points, colour, width.
    var onStroke: ((_ points: [Int], _ color: Int, _ width: Int) -> Void)?
    var onClear: (() -> Void)?
    /// The panel was laid out with a cell under 2 points: it asks for room (called once per such layout, on the main actor's next turn).
    var onNeedsRoom: (() -> Void)?
    private let model: PlazaDrawModel
    /// The frames (window points) of the panels in `Self.neighbours` that are shown, for a window size and backing scale.
    private let neighbourFrames: (CGSize, CGFloat) -> [PlazaPanelID: CGRect]
    private var observer: PlazaChangeObserver?

    /// The panels whose frames the layout reads.
    static let neighbours: [PlazaPanelID] = [.pills, .gameCard, .chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker]
    static let padding: CGFloat = 4, rowGap: CGFloat = 3, clear: CGFloat = 4, swatch: CGFloat = 16, swatchGap: CGFloat = 2
    static let buttonPadding = CGSize(width: 3, height: 2), buttonGap: CGFloat = 2
    /// The smallest cell: 2 device pixels. Before it asks for room the panel wants 2 points (a cell of 2 pixels at 2x would make a 96-point canvas).
    static let minCell = 2
    static func roomyCell(scale: CGFloat) -> Int { max(minCell, Int((2 * scale).rounded(.up))) }
    static let minInterval = Duration.milliseconds(33)
    private static let gold = PlazaPanelStyle.countdown.stroke
    private static let line = PlazaPanelStyle.banner.stroke
    private static let ink = PlazaColor(hex: 0x2B2233)

    init(model: PlazaDrawModel, neighbours: @escaping (CGSize, CGFloat) -> [PlazaPanelID: CGRect]) {
        self.model = model
        neighbourFrames = neighbours
        observer = PlazaChangeObserver(track: { _ = model.board; _ = model.canvas; _ = model.color; _ = model.width },
                                       changed: { [weak self] in self?.modelChanged() })
    }

    // MARK: change reports

    private struct Look: Equatable { let board: PlazaDrawBoard?, color: Int, width: Int }
    private var look: Look { Look(board: model.board, color: model.color, width: model.width) }
    private var reported: Look?
    private var lastReport: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?

    private func modelChanged() {
        let now = look
        // A stroke does not outlive the board, the right to draw or the canvas's cover.
        if now.board?.canDraw != true || now.board?.cover != nil { endStroke() }
        if now != reported {   // a tool or the board: shown at once
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

    let anchor = PlazaPanelAnchor.topLeading
    let offset = CGPoint.zero

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint { layout(in: viewport, scale: scale, text: text).origin }

    var isVisible: Bool { model.board != nil }

    func didAppear() { endStroke() }

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
        /// The panel's top-left corner in the window, in points.
        let origin: CGPoint
        let size: CGSize
        /// False when even the smallest cell does not fit: the panel sits under the pills in the middle and covers what it must.
        let fits: Bool
        /// The cell is at least 2 points: nothing needs to make room. False asks the controller for room (`onNeedsRoom`).
        let isRoomy: Bool
        let head: (line: PlazaTextLine, frame: CGRect)
        let time: (line: PlazaTextLine, frame: CGRect)
        let canvas: CGRect
        let cover: [(line: PlazaTextLine, text: String, frame: CGRect)]
        let word: (line: PlazaTextLine, text: String, frame: CGRect)?
        let swatches: [(index: Int, frame: CGRect)]
        let buttons: [Button]
        let lines: [(line: PlazaTextLine, text: String, frame: CGRect)]
    }

    private struct Key: Equatable { let viewport: CGSize, scale: CGFloat, board: PlazaDrawBoard?, color: Int, width: Int, engine: String, around: [PlazaPanelID: CGRect] }
    private var laidOut: (key: Key, placed: Placed)?
    /// The layout of the last `size` or `render`: what `hit` and `cell(at:)` read.
    private var placed: Placed? { laidOut?.placed }

    func layout(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> Placed {
        let around = neighbourFrames(viewport, scale)
        let key = Key(viewport: viewport, scale: scale, board: model.board, color: model.color, width: model.width,
                      engine: String(describing: type(of: text)), around: around)
        if let laidOut, laidOut.key == key { return laidOut.placed }
        let made = build(viewport: viewport, scale: scale, text: text, around: around)
        laidOut = (key, made)
        if !made.isRoomy, model.board != nil { Task { @MainActor [weak self] in self?.onNeedsRoom?() } }
        return made
    }

    private func build(viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine, around: [PlazaPanelID: CGRect]) -> Placed {
        let l = L(.ko)
        let font = PlazaFont.plaza(.body)
        let metrics = text.metrics(font)
        let lineH = (metrics.ascender - metrics.descender).rounded()
        let pad = Self.padding, gap = Self.rowGap, margin = PlazaRosterMetrics.margin, clear = Self.clear
        let board = model.board ?? PlazaDrawBoard(head: "", time: "", cover: nil, foot: .lines([]), canDraw: false)
        func width(_ line: PlazaTextLine) -> CGFloat { PlazaPanelStyle.pixelUp(line.width, scale: scale) }
        func centered(_ rowWidth: CGFloat, in inner: CGFloat) -> CGFloat { pad + PlazaPanelStyle.pixel((inner - rowWidth) / 2, scale: scale) }

        var head = text.line(board.head, font: font)
        let time = text.line(board.time, font: font)
        let buttonH = lineH + 2 * Self.buttonPadding.height

        var word: (PlazaTextLine, String)?
        var toolButtons: [(hit: PlazaPanelHit, label: String, line: PlazaTextLine, selected: Bool)] = []
        let swatchesWidth = CGFloat(PlazaDraw.palette.count - 1) * Self.swatch + CGFloat(PlazaDraw.palette.count - 2) * Self.swatchGap
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
        }
        let buttonWidths = toolButtons.map { PlazaPanelStyle.pixelUp($0.line.width, scale: scale) + 2 * Self.buttonPadding.width }
        let buttonsRow = buttonWidths.reduce(0, +) + CGFloat(max(0, buttonWidths.count - 1)) * Self.buttonGap

        func footLines(_ inner: CGFloat) -> [(PlazaTextLine, String)] {
            guard case .lines(let strings) = board.foot else { return [] }
            return strings.flatMap { s in text.wrappedLines(s, font: font, width: inner).map { ($0, s) } }
        }
        /// The tools: the word and the swatches in one row, the buttons in the next; the guesser's lines otherwise.
        func footHeight(_ inner: CGFloat) -> CGFloat {
            if word != nil { return max(lineH, Self.swatch) + gap + buttonH }
            let n = footLines(inner).count
            return n == 0 ? 0 : CGFloat(n) * lineH + CGFloat(n - 1) * 2
        }
        func canvasSize(_ n: Int) -> CGSize { CGSize(width: CGFloat(PlazaDrawCanvas.width * n) / scale, height: CGFloat(PlazaDrawCanvas.height * n) / scale) }
        func innerWidth(_ n: Int) -> CGFloat { max(canvasSize(n).width, buttonsRow) }
        func panelSize(_ n: Int) -> CGSize {
            let inner = innerWidth(n), foot = footHeight(inner)
            return CGSize(width: PlazaPanelStyle.pixelUp(2 * pad + inner, scale: scale),
                          height: PlazaPanelStyle.pixelUp(2 * pad + lineH + gap + canvasSize(n).height + (foot > 0 ? gap + foot : 0), scale: scale))
        }

        // Under the pills and the game card; as near the middle as the panels around allow. The chat log is never covered.
        let top = PlazaPanelStyle.pixelUp(max(margin, ([PlazaPanelID.pills, .gameCard].compactMap { around[$0]?.maxY }.max()).map { $0 + clear } ?? margin), scale: scale)
        let obstacles = [PlazaPanelID.chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker].compactMap { around[$0] }
        func place(_ size: CGSize) -> (origin: CGPoint, fits: Bool) {
            let middle = PlazaPanelStyle.pixel((viewport.width - size.width) / 2, scale: scale)
            let low = margin, high = viewport.width - margin - size.width
            guard top + size.height <= viewport.height - margin, high >= low else { return (CGPoint(x: middle, y: top), false) }
            func free(_ x: CGFloat) -> Bool {
                !obstacles.contains { o in
                    x < o.maxX + clear - 0.001 && x + size.width > o.minX - clear + 0.001 && top < o.maxY + clear - 0.001 && top + size.height > o.minY - clear + 0.001
                }
            }
            // The middle, or flush against the side of a panel it would meet.
            var xs = [min(max(middle, low), high)]
            for o in obstacles {
                xs.append(((o.maxX + clear) * scale).rounded(.up) / scale)
                xs.append(((o.minX - clear - size.width) * scale).rounded(.down) / scale)
            }
            let best = xs.filter { $0 >= low - 0.001 && $0 <= high + 0.001 && free($0) }.min { abs($0 - middle) < abs($1 - middle) }
            return (CGPoint(x: best ?? middle, y: top), best != nil)
        }

        // The largest cell, in whole device pixels, whose panel fits: of at least 2 points if possible, else down to 2 pixels.
        var n = Self.minCell, fits = false, roomy = false
        let widest = max(Self.minCell, Int((viewport.width * scale).rounded(.down)) / PlazaDrawCanvas.width)
        search: for floor in [Self.roomyCell(scale: scale), Self.minCell] {
            var candidate = widest
            while candidate >= floor {
                if place(panelSize(candidate)).fits { (n, fits, roomy) = (candidate, true, floor == Self.roomyCell(scale: scale)); break search }
                candidate -= 1
            }
        }
        let size = panelSize(n)
        let at = place(size).origin
        let inner = innerWidth(n), canvasW = canvasSize(n)
        // A narrow canvas cuts the head short of the time.
        let headRoom = inner - width(time) - 2 * clear
        if width(head) > headRoom { head = text.truncated(head, width: max(0, headRoom), ellipsis: text.line("…", font: font)) ?? head }
        var y = pad
        let headFrame = CGRect(x: pad, y: y, width: width(head), height: lineH)
        let timeFrame = CGRect(x: pad + inner - width(time), y: y, width: width(time), height: lineH)
        y += lineH + gap
        // On whole device pixels in the window, so the cells are even.
        let canvasY = PlazaPanelStyle.pixel(at.y + y, scale: scale) - at.y
        let canvas = CGRect(x: PlazaPanelStyle.pixel(at.x + centered(canvasW.width, in: inner), scale: scale) - at.x, y: canvasY, width: canvasW.width, height: canvasW.height)
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
            // The word at the left (cut short of the swatches when it is long), the swatches at the right.
            let rowH = max(lineH, Self.swatch)
            var wordLine = word.0
            let wordRoom = inner - swatchesWidth - 2 * clear
            if width(wordLine) > wordRoom { wordLine = text.truncated(wordLine, width: max(0, wordRoom), ellipsis: text.line("…", font: font)) ?? wordLine }
            wordPlaced = (wordLine, word.1, CGRect(x: pad, y: y + (rowH - lineH) / 2, width: width(wordLine), height: lineH))
            var x = pad + inner - swatchesWidth
            for i in 1..<PlazaDraw.palette.count {
                swatches.append((i, CGRect(x: x, y: y + (rowH - Self.swatch) / 2, width: Self.swatch, height: Self.swatch)))
                x += Self.swatch + Self.swatchGap
            }
            y += rowH + gap
            var bx = centered(buttonsRow, in: inner)
            for (b, w) in zip(toolButtons, buttonWidths) {
                buttons.append(Button(hit: b.hit, label: b.label, line: b.line, frame: CGRect(x: bx, y: y, width: w, height: buttonH), selected: b.selected))
                bx += w + Self.buttonGap
            }
        } else {
            for (line, s) in footLines(inner) {
                let w = width(line)
                lines.append((line, s, CGRect(x: centered(w, in: inner), y: y, width: w, height: lineH)))
                y += lineH + 2
            }
        }
        return Placed(scale: scale, cell: n, origin: at, size: size, fits: fits, isRoomy: roomy, head: (head, headFrame), time: (time, timeFrame), canvas: canvas, cover: cover,
                      word: wordPlaced, swatches: swatches, buttons: buttons, lines: lines)
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
        let key = "\(p.size) \(scale) \(String(describing: type(of: text))) \(board) \(model.color) \(model.width) \(p.canvas) \(p.buttons.map(\.frame))"
        if plate.key != key {
            plate = (key, space.image(scale: scale, graphics: graphics) { canvas in
                let all = space.canvas(CGRect(origin: .zero, size: p.size))
                canvas.setFillColor(PlazaColor(hex: 0x1D4F55, alpha: 0.96))
                canvas.fillRoundedRect(all, radius: 8)
                canvas.setStrokeColor(Self.line)
                canvas.strokeRoundedRect(all.insetBy(dx: 1, dy: 1), radius: 7, lineWidth: 2)
                func draw(_ line: PlazaTextLine, in frame: CGRect, _ color: PlazaColor) {
                    canvas.setFillColor(color)
                    canvas.draw(line, at: space.canvas(CGPoint(x: frame.minX, y: frame.minY + m.ascender)))
                }
                draw(p.head.line, in: p.head.frame, Self.gold)
                draw(p.time.line, in: p.time.frame, .white)
                canvas.setFillColor(PlazaColor(hex: 0x0B2326))
                canvas.fill(space.canvas(p.canvas.insetBy(dx: -2, dy: -2)))
                if let w = p.word { draw(w.line, in: w.frame, .white) }
                for l in p.lines { draw(l.line, in: l.frame, .white) }
                canvas.saveState()
                if !board.canDraw { canvas.setAlpha(0.45) }
                for s in p.swatches {
                    let c = PlazaDraw.palette[s.index]
                    let r = space.canvas(s.frame)
                    if model.color == s.index {
                        canvas.setFillColor(.white)
                        canvas.fill(r.insetBy(dx: -2, dy: -2))
                    }
                    canvas.setFillColor(PlazaColor(hex: 0x0B2326))
                    canvas.fill(r.insetBy(dx: -1, dy: -1))
                    canvas.setFillColor(PlazaColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1))
                    canvas.fill(r)
                }
                for b in p.buttons {
                    let r = space.canvas(b.frame)
                    canvas.setFillColor(b.selected ? PlazaColor(hex: 0x2D7F87) : PlazaColor(hex: 0x14393D))
                    canvas.fillRoundedRect(r, radius: 5)
                    canvas.setStrokeColor(b.selected ? Self.gold : Self.line)
                    canvas.strokeRoundedRect(r, radius: 5, lineWidth: b.selected ? 2 : 1)
                    draw(b.line, in: CGRect(x: b.frame.minX + (b.frame.width - b.line.width) / 2, y: b.frame.minY + Self.buttonPadding.height,
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
            layers.append(.color(PlazaColor(srgbRed: Double(paper.r) / 255, green: Double(paper.g) / 255, blue: Double(paper.b) / 255, alpha: 1), frame: p.canvas))
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
        if let s = p.swatches.first(where: { $0.frame.insetBy(dx: -Self.swatchGap / 2, dy: -Self.rowGap / 2).contains(point) }) {
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

    /// The cell the pen is on while a stroke is under way, and whether the press that began it is still held (a drag with no press draws nothing).
    private var last: (x: Int, y: Int)?
    private var isPressed = false

    private func endStroke() { last = nil; isPressed = false }

    func scrollerMouse(_ phase: PlazaScrollerPhase, at point: CGPoint) {
        // Without the right to draw, or under a cover, nothing is drawn and no stroke goes on.
        guard let board = model.board, board.canDraw, board.cover == nil else { endStroke(); return }
        switch phase {
        case .down:
            isPressed = true
            last = nil
        case .drag:
            guard isPressed else { return }
        case .up:
            guard isPressed else { return }
        }
        extend(to: cell(at: point))
        if phase == .up { endStroke() }
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
