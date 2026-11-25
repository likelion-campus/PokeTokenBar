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

/// Where the panel sits. The user picks one from the layout sheet; the other is removed then.
enum PlazaDrawLayout: String, CaseIterable, Sendable {
    /// In the column right of the chat log, under the pills, down to the bottom margin. It covers the minimap and the clock (so it is drawn
    /// above them) and may cover the roster.
    case right
    /// Centred under the pills, down to the chat log's top; clear of the minimap, the clock and the shortcuts guide.
    case top
}

@MainActor @Observable final class PlazaDrawModel {
    /// nil hides the panel.
    var board: PlazaDrawBoard?
    var canvas = PlazaDrawCanvas()
    /// 1...8, or 0 for the eraser.
    var color = 1
    /// 1 or 3; the eraser draws 5 wide.
    var width = 3
    var layout: PlazaDrawLayout = .top
}

/// The drawing quiz's panel: a head line (turn, drawer, time), the canvas, and under it the drawer's tools or a guesser's lines. The canvas
/// is one image layer the hosts enlarge with nearest sampling; its cell is a whole number of device pixels, so the picture is never uneven
/// at 125 % or 150 %. A press on the canvas is captured like a scroller's track (`scrollerContains` / `scrollerMouse`) and each point of the
/// drag becomes a cell. A change of the canvas renders at most 30 times a second and once more after the last change. The panel keeps clear
/// of the chat log (always) and of the other panels above it (per layout) by their real frames, which `neighbours` reports.
@MainActor final class PlazaDrawPanel: PlazaPanel {
    let id = PlazaPanelID.drawBoard
    var onChange: (() -> Void)?
    /// A stroke the user just drew on this machine, already applied to `model.canvas`: canvas points, colour, width.
    var onStroke: ((_ points: [Int], _ color: Int, _ width: Int) -> Void)?
    var onClear: (() -> Void)?
    private let model: PlazaDrawModel
    /// The frames (window points) of the panels in `Self.neighbours` that are shown, for a window size and backing scale.
    private let neighbourFrames: (CGSize, CGFloat) -> [PlazaPanelID: CGRect]
    private var observer: PlazaChangeObserver?

    /// The panels whose frames the layouts read.
    static let neighbours: [PlazaPanelID] = [.pills, .gameCard, .chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker]
    static let padding: CGFloat = 4, rowGap: CGFloat = 3, gap: CGFloat = 8, clear: CGFloat = 4, swatch: CGFloat = 18, swatchGap: CGFloat = 3
    static let buttonPadding = CGSize(width: 6, height: 2), buttonGap: CGFloat = 3, minCell = 2
    private static let cellDivisor = PlazaDrawCanvas.width
    static let minInterval = Duration.milliseconds(33)
    private static let gold = PlazaColor(hex: 0xF2C14E)
    private static let ink = PlazaColor(hex: 0x2B2233)

    init(model: PlazaDrawModel, neighbours: @escaping (CGSize, CGFloat) -> [PlazaPanelID: CGRect]) {
        self.model = model
        neighbourFrames = neighbours
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

    let anchor = PlazaPanelAnchor.topLeading
    let offset = CGPoint.zero

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint { layout(in: viewport, scale: scale, text: text).origin }

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
        /// The panel's top-left corner in the window, in points.
        let origin: CGPoint
        let size: CGSize
        /// False when even the smallest cell does not fit its room: the panel sits at the layout's corner and covers what it must.
        let fits: Bool
        let head: (line: PlazaTextLine, frame: CGRect)
        let time: (line: PlazaTextLine, frame: CGRect)
        let canvas: CGRect
        let cover: [(line: PlazaTextLine, text: String, frame: CGRect)]
        let word: (line: PlazaTextLine, text: String, frame: CGRect)?
        let swatches: [(index: Int, frame: CGRect)]
        let buttons: [Button]
        let lines: [(line: PlazaTextLine, text: String, frame: CGRect)]
    }

    private struct Key: Equatable { let viewport: CGSize, scale: CGFloat, board: PlazaDrawBoard?, color: Int, width: Int, layout: PlazaDrawLayout, engine: String, around: [PlazaPanelID: CGRect] }
    private var laidOut: (key: Key, placed: Placed)?
    /// The layout of the last `size` or `render`: what `hit` and `cell(at:)` read.
    private var placed: Placed? { laidOut?.placed }

    func layout(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> Placed {
        let around = neighbourFrames(viewport, scale)
        let key = Key(viewport: viewport, scale: scale, board: model.board, color: model.color, width: model.width, layout: model.layout,
                      engine: String(describing: type(of: text)), around: around)
        if let laidOut, laidOut.key == key { return laidOut.placed }
        let made = build(viewport: viewport, scale: scale, text: text, around: around)
        laidOut = (key, made)
        return made
    }

    private func build(viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine, around: [PlazaPanelID: CGRect]) -> Placed {
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
        let wordWidth = word.map { width($0.0) } ?? 0
        /// The least width the tools take: the swatches, or two buttons side by side (the buttons wrap into two rows).
        /// The tools' least width: all the buttons in one row (`wide`), or two buttons side by side with the buttons in two rows.
        func toolsMin(_ wide: Bool) -> CGFloat {
            word == nil ? 0 : max(swatchesWidth, wide ? max(buttonsRow, wordWidth) : (buttonWidths.max() ?? 0) * 2 + Self.buttonGap)
        }

        func footLines(_ inner: CGFloat) -> [(PlazaTextLine, String)] {
            guard case .lines(let strings) = board.foot else { return [] }
            return strings.flatMap { s in text.wrappedLines(s, font: font, width: inner).map { ($0, s) } }
        }
        /// The tools' rows at `inner` points wide: the word and the swatches share a row when they fit, the buttons are one row when they fit
        /// and else two rows of two equal buttons.
        func footHeight(_ inner: CGFloat) -> CGFloat {
            if word != nil {
                let sharedRow = wordWidth + Self.gap + swatchesWidth <= inner
                let first = sharedRow ? max(lineH, Self.swatch) : lineH + gap + Self.swatch
                let buttons = buttonsRow <= inner ? buttonH : 2 * buttonH + Self.buttonGap
                return first + gap + buttons
            }
            let n = footLines(inner).count
            return n == 0 ? 0 : CGFloat(n) * lineH + CGFloat(n - 1) * 2
        }
        func canvasSize(_ n: Int) -> CGSize { CGSize(width: CGFloat(PlazaDrawCanvas.width * n) / scale, height: CGFloat(PlazaDrawCanvas.height * n) / scale) }
        func innerWidth(_ n: Int, _ wide: Bool) -> CGFloat { max(canvasSize(n).width, toolsMin(wide)) }
        func panelSize(_ n: Int, _ wide: Bool) -> CGSize {
            let inner = innerWidth(n, wide), foot = footHeight(inner)
            return CGSize(width: PlazaPanelStyle.pixelUp(2 * pad + inner, scale: scale),
                          height: PlazaPanelStyle.pixelUp(2 * pad + lineH + gap + canvasSize(n).height + (foot > 0 ? gap + foot : 0), scale: scale))
        }

        // The window's room for each layout, by the neighbours' real frames. The chat log is never covered.
        let chat = around[.chatLog]
        let topLimit: CGFloat = max(margin, ([PlazaPanelID.pills, .gameCard].compactMap { around[$0]?.maxY }.max()).map { $0 + Self.clear } ?? margin)
        func origin(for size: CGSize) -> (CGPoint, fits: Bool) {
            switch model.layout {
            case .right:
                let x = viewport.width - margin - size.width, y = topLimit
                let fits = x >= (chat.map { $0.maxX + Self.gap } ?? margin) && y + size.height <= viewport.height - margin
                return (CGPoint(x: x, y: y), fits)
            case .top:
                let x = PlazaPanelStyle.pixel((viewport.width - size.width) / 2, scale: scale)
                var top = topLimit, bottom = viewport.height - margin
                let span = (x - Self.gap)...(x + size.width + Self.gap)
                for id in [PlazaPanelID.chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker] {
                    guard let f = around[id], f.maxX >= span.lowerBound, f.minX <= span.upperBound else { continue }
                    if f.midY < viewport.height / 2 { top = max(top, f.maxY + Self.clear) } else { bottom = min(bottom, f.minY - Self.clear) }
                }
                return (CGPoint(x: x, y: top), top + size.height <= bottom)
            }
        }

        // The largest cell, in whole device pixels, whose panel fits its room (the smallest cell when none does).
        var n = Self.minCell, wide = false, fits = false
        var candidate = max(Self.minCell, Int((viewport.width * scale).rounded(.down)) / PlazaDrawPanel.cellDivisor)
        search: while candidate >= Self.minCell {
            for form in [true, false] where origin(for: panelSize(candidate, form)).fits { (n, wide, fits) = (candidate, form, true); break search }
            candidate -= 1
        }
        let size = panelSize(n, wide)
        let raw = origin(for: size).0
        let at = CGPoint(x: PlazaPanelStyle.pixel(raw.x, scale: scale), y: PlazaPanelStyle.pixel(raw.y, scale: scale))
        let inner = innerWidth(n, wide), canvasW = canvasSize(n)
        // A narrow canvas cuts the head short of the time.
        let headRoom = inner - width(time) - Self.gap
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
            let shared = wordWidth + Self.gap + swatchesWidth <= inner
            let swatchX = shared ? pad + inner - swatchesWidth : centered(swatchesWidth, in: inner)
            let rowH = max(lineH, Self.swatch)
            if shared {
                wordPlaced = (word.0, word.1, CGRect(x: pad, y: y + (rowH - lineH) / 2, width: wordWidth, height: lineH))
            } else {
                wordPlaced = (word.0, word.1, CGRect(x: centered(wordWidth, in: inner), y: y, width: wordWidth, height: lineH))
                y += lineH + gap
            }
            var x = swatchX
            for i in 1..<PlazaDraw.palette.count {
                swatches.append((i, CGRect(x: x, y: y + (rowH - Self.swatch) / 2, width: Self.swatch, height: Self.swatch)))
                x += Self.swatch + Self.swatchGap
            }
            y += (shared ? rowH : Self.swatch) + gap
            if buttonsRow <= inner {
                var bx = centered(buttonsRow, in: inner)
                for (b, w) in zip(toolButtons, buttonWidths) {
                    buttons.append(Button(hit: b.hit, label: b.label, line: b.line, frame: CGRect(x: bx, y: y, width: w, height: buttonH), selected: b.selected))
                    bx += w + Self.buttonGap
                }
            } else {
                let cell = (inner - Self.buttonGap) / 2
                for (i, b) in toolButtons.enumerated() {
                    let bx = pad + CGFloat(i % 2) * (cell + Self.buttonGap), by = y + CGFloat(i / 2) * (buttonH + Self.buttonGap)
                    buttons.append(Button(hit: b.hit, label: b.label, line: b.line, frame: CGRect(x: bx, y: by, width: cell, height: buttonH), selected: b.selected))
                }
            }
        } else {
            for (line, s) in footLines(inner) {
                let w = width(line)
                lines.append((line, s, CGRect(x: centered(w, in: inner), y: y, width: w, height: lineH)))
                y += lineH + 2
            }
        }
        return Placed(scale: scale, cell: n, origin: at, size: size, fits: fits, head: (head, headFrame), time: (time, timeFrame), canvas: canvas, cover: cover,
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
                canvas.setStrokeColor(PlazaColor(hex: 0x5FB7BD))
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
                    canvas.setStrokeColor(b.selected ? Self.gold : PlazaColor(hex: 0x5FB7BD))
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
