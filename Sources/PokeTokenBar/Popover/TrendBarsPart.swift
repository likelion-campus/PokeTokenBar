import Foundation

/// The month bars (stage 7 D7, Task 12; the Mac's `MonthDailyTrend`): a caption (the window title, today's readout, the
/// peak, the switch dots), one bar per day (today in the accent, stacked by provider with several providers, empty days
/// dimmed, future days blank), weekend ticks, axis labels and the provider legend. Geometry, colours and texts come from
/// `TrendBarsModel` (the twins), so the Mac test compares numbers.
///
/// Interaction: the pointer over a day (or the arrow keys, with the panel focused) selects it. The selection redraws the
/// bars only (colour layers) and shows the day's card (`card`, a small drawing the host puts in a popup window above the
/// bars); no text is drawn again, and the render says which part of the picture changed (`PopoverDrawing.dirty`).
/// Everything else is static: no timer.
@MainActor final class TrendBarsPart: PopoverPart {
    var onChange: (() -> Void)?
    /// Called when the selected day changes (the host shows, moves or hides the card).
    var onSelection: (() -> Void)?
    private(set) var model: TrendBarsModel
    private var cardInfo: (String) -> PopoverTrendHover.Info?
    /// The user's accent (the Mac's accent colour); the host sets it from the system.
    var accent = PopoverColorRole.accent.plazaColor() { didSet { if oldValue != accent { fullRender = true; onChange?() } } }
    /// What is behind the card.
    var cardBackground = PlazaColor(srgbRed: 0.93, green: 0.93, blue: 0.93)
    private(set) var pointerDate: String?
    private(set) var keyboardDate: String?
    private var width: CGFloat = PopoverWindowMetrics.contentWidth
    private var fullRender = true
    private var renderedSelection: String?
    private var laidOut: (width: CGFloat, key: String, layout: Layout)?
    let drawing = ActivityDrawing()
    /// The card's texts (made once per day shown); apart from `drawing` so the chart's own cost is what a hover is measured by.
    let cardDrawing = ActivityDrawing()

    init(_ model: TrendBarsModel, cardInfo: @escaping (String) -> PopoverTrendHover.Info? = { _ in nil }) {
        self.model = model
        self.cardInfo = cardInfo
    }

    /// New data: the host renders again only when the picture would differ (the card's lookup is always the newest).
    func update(_ next: TrendBarsModel, cardInfo: @escaping (String) -> PopoverTrendHover.Info?) {
        self.cardInfo = cardInfo
        guard next != model else { return }
        model = next
        fullRender = true
        laidOut = nil
        if let d = keyboardDate, !next.columns.contains(where: { $0.date == d && !$0.isFuture }) { keyboardDate = nil }
        if let d = pointerDate, !next.columns.contains(where: { $0.date == d && !$0.isFuture }) { pointerDate = nil }
        onChange?()
    }

    /// The selected day: the pointer's, else the keyboard's.
    var selectedDate: String? { pointerDate ?? keyboardDate }

    // MARK: geometry (DIP, part coordinates)

    static let top: CGFloat = 4
    static let gap: CGFloat = 3
    static let tickHeight = PopoverTrendMetrics.tickHeight
    static let captionSize: CGFloat = 10
    /// The menu's chevron after the title (the Mac's borderless `Menu` draws one): a gap and a 7 x 4 "v".
    static let chevronSize = CGSize(width: 7, height: 4)
    static let chevronAdvance: CGFloat = 3 + 7 + 2

    struct Layout {
        var captionTop: CGFloat, captionHeight: CGFloat
        var barsTop: CGFloat, tickTop: CGFloat, axisTop: CGFloat, axisHeight: CGFloat
        var legendTop: CGFloat, legend: [CGRect]
        var height: CGFloat
        var columnWidth: CGFloat, step: CGFloat
    }

    private func layout(width: CGFloat, graphics: any PlazaGraphics) -> Layout {
        let key = "\(model.columns.count)-\(model.showsBars)-\(model.legend.map(\.name))"
        if let laidOut, laidOut.width == width, laidOut.key == key { return laidOut.layout }
        let text = graphics.text
        let caption = ActivityDrawing.lineHeight(Self.captionSize, text: text)
        let axis = ActivityDrawing.lineHeight(Self.captionSize, text: text)
        var l = Layout(captionTop: Self.top, captionHeight: caption, barsTop: 0, tickTop: 0, axisTop: 0, axisHeight: axis,
                       legendTop: 0, legend: [], height: Self.top + caption, columnWidth: 0, step: 0)
        if model.showsBars {
            let n = CGFloat(max(1, model.columns.count))
            l.columnWidth = (width - PopoverTrendMetrics.spacing * (n - 1)) / n
            l.step = l.columnWidth + PopoverTrendMetrics.spacing
            l.barsTop = l.captionTop + caption + Self.gap
            l.tickTop = l.barsTop + PopoverTrendMetrics.track + Self.gap
            l.axisTop = l.tickTop + Self.tickHeight + Self.gap
            l.height = l.axisTop + axis
            if model.stacked {
                // swatch 6 + 3 + the name (caption2), one item per provider, wrapped as `WrappingHStack` (spacing 8, lines 2)
                let sizes = model.legend.map { CGSize(width: 6 + 3 + drawing.width($0.name, size: Self.captionSize, graphics: graphics), height: axis) }
                let frames = PopoverWrapLayout.arrange(sizes, width: width, spacing: 8, lineSpacing: 2)
                l.legendTop = l.axisTop + axis + Self.gap + 2
                l.legend = frames.map { $0.offsetBy(dx: 0, dy: l.legendTop) }
                l.height = l.legendTop + PopoverWrapLayout.size(of: frames).height
            }
        }
        laidOut = (width, key, l)
        return l
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: layout(width: width, graphics: PlatformPlaza.graphics).height)
    }

    /// The caption's title (the window menu's label).
    func titleRect(graphics: any PlazaGraphics) -> CGRect {
        let l = layout(width: width, graphics: graphics)
        let w = drawing.width(model.title, size: Self.captionSize, graphics: graphics)
        return CGRect(x: 0, y: l.captionTop, width: w + Self.chevronAdvance, height: l.captionHeight)
    }

    // MARK: hits and selection

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        let graphics = PlatformPlaza.graphics
        if titleRect(graphics: graphics).contains(point) { return PlazaPanelHit(action: "window", index: nil) }
        return PlazaPanelHit(action: "cycle", index: nil)
    }

    /// The day under `point` (the bar itself, as the Mac's `onHover` on the bar), nil elsewhere and over a future day.
    func date(at point: CGPoint, graphics: any PlazaGraphics) -> String? {
        guard model.showsBars else { return nil }
        let l = layout(width: width, graphics: graphics)
        guard point.x >= 0, point.x <= width, l.step > 0 else { return nil }
        let i = min(model.columns.count - 1, max(0, Int(point.x / l.step)))
        let c = model.columns[i]
        // As the Mac: the target is the bar itself (its column's width, its own height, bottom-aligned in the track), not the
        // whole track and not the gap between columns.
        let bottom = l.barsTop + PopoverTrendMetrics.track
        guard !c.isFuture, point.x <= CGFloat(i) * l.step + l.columnWidth, point.y <= bottom, point.y >= bottom - c.height else { return nil }
        return c.date
    }

    /// The pointer moved to `point` (nil: it left the part).
    func pointerMoved(_ point: CGPoint?) {
        let next = point.flatMap { date(at: $0, graphics: PlatformPlaza.graphics) }
        guard next != pointerDate else { return }
        pointerDate = next
        selectionChanged()
    }

    func focusChanged(_ focused: Bool) {
        guard !focused, keyboardDate != nil else { return }
        keyboardDate = nil
        selectionChanged()
    }

    /// Arrow keys select a day (Home and End the first and the last), Escape clears the selection. True when handled.
    func key(_ vk: Int) -> Bool {
        guard model.showsBars else { return false }
        let selectable = model.columns.map { !$0.isFuture }
        let current = keyboardDate.flatMap { d in model.columns.firstIndex { $0.date == d } }
        let today = model.columns.firstIndex { $0.isToday } ?? selectable.lastIndex(of: true)
        var next: Int?
        switch vk {
        case PopoverKey.left: next = ActivityKeys.move(selectable, from: current, by: -1, start: today)
        case PopoverKey.right: next = ActivityKeys.move(selectable, from: current, by: 1, start: today)
        case PopoverKey.home: next = selectable.firstIndex(of: true)
        case PopoverKey.end: next = selectable.lastIndex(of: true)
        case PopoverKey.escape:
            guard keyboardDate != nil else { return false }
            keyboardDate = nil
            selectionChanged()
            return true
        default: return false
        }
        guard let next, model.columns.indices.contains(next) else { return true }
        if keyboardDate != model.columns[next].date {
            keyboardDate = model.columns[next].date
            selectionChanged()
        }
        return true
    }

    private func selectionChanged() {
        onChange?()
        onSelection?()
    }

    // MARK: the card

    struct Card {
        var drawing: PlazaPanelDrawing
        /// In part coordinates, the room around the card included.
        var frame: CGRect
    }

    static let cardRoom: CGFloat = 6

    /// The selected day's card (`MonthDailyTrend.tooltipCard`): the date, tokens and cost, then a row per provider when the
    /// bars stack; centred on the day and clamped to the row, its bottom 4 DIP above the bars.
    func card(scale: CGFloat, graphics: any PlazaGraphics) -> Card? {
        guard let day = selectedDate, let index = model.columns.firstIndex(where: { $0.date == day }),
              let info = cardInfo(day) else { return nil }
        let l = layout(width: width, graphics: graphics)
        let text = graphics.text
        let h1 = ActivityDrawing.lineHeight(10, text: text), h2 = ActivityDrawing.lineHeight(10, text: text)
        let d = ActivityDrawing()
        func w(_ s: String, _ weight: Int = 400) -> CGFloat { d.width(s, size: 10, weight: weight, graphics: graphics) }
        var header = w(info.stamp, 600) + 5 + w(info.tokens)
        if let cost = info.cost { header += 5 + w(cost) }
        var rowsWidth: CGFloat = 0
        for r in info.providers {
            rowsWidth = max(rowsWidth, 6 + 4 + w(r.name) + 8 + 4 + w(r.tokens) + (r.cost.map { 4 + w($0) } ?? 0))
        }
        let content = CGSize(width: max(header, rowsWidth), height: h1 + CGFloat(info.providers.count) * (h2 + 2) )
        let cardSize = CGSize(width: content.width + 14, height: content.height + 10)
        let space = PlazaPanelSpace(content: cardSize, room: Self.cardRoom)
        let center = l.step * (CGFloat(index) + 0.5)
        let x = min(max(center - cardSize.width / 2, 0), max(0, width - cardSize.width))
        let y = l.barsTop - 4 - cardSize.height
        let frame = CGRect(x: x - Self.cardRoom, y: y - Self.cardRoom, width: space.size.width, height: space.size.height)
        let accentless = PopoverColorRole.secondary.plazaColor()
        let primary = PopoverColorRole.primary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        var layers: [PlazaPanelLayer] = []
        if let image = space.image(scale: scale, graphics: graphics, { canvas in
            let box = space.canvas(CGRect(x: 0, y: 0, width: cardSize.width, height: cardSize.height))
            canvas.saveState()
            canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)))
            canvas.setFillColor(cardBackground)
            canvas.fillRoundedRect(box, radius: 6)
            canvas.restoreState()
            canvas.setStrokeColor(PlazaColor(srgbRed: accentless.red, green: accentless.green, blue: accentless.blue, alpha: 0.5 * 0.35))
            canvas.strokeRoundedRect(box, radius: 6, lineWidth: 0.5)
        }) { layers.append(.image(image, frame: CGRect(x: 0, y: 0, width: space.size.width, height: space.size.height))) }
        let ox = Self.cardRoom + 7, oy = Self.cardRoom + 5
        var cx = ox
        for (s, weight, color) in [(info.stamp, 600, primary), (info.tokens, 400, primary)] + (info.cost.map { [($0, 400, secondary)] } ?? []) {
            let made = cardDrawing.text(s, size: 10, weight: weight, color: color, at: CGPoint(x: cx, y: oy), scale: scale, graphics: graphics)
            if let layer = made.layer { layers.append(layer) }
            cx += made.width + 5
        }
        var ry = oy + h1 + 2
        let right = ox + content.width
        for r in info.providers {
            let color = PopoverColorRole.palette(model.legend.first { $0.name == r.name }?.colorIndex ?? 0).plazaColor()
            layers.append(.color(color, frame: CGRect(x: ox, y: ry + (h2 - 6) / 2, width: 6, height: 6)))
            let name = cardDrawing.text(r.name, size: 10, color: secondary, at: CGPoint(x: ox + 10, y: ry), scale: scale, graphics: graphics)
            if let layer = name.layer { layers.append(layer) }
            var rx = right
            if let cost = r.cost {
                let cw = w(cost)
                rx -= cw
                if let layer = cardDrawing.text(cost, size: 10, color: secondary, at: CGPoint(x: rx, y: ry), scale: scale, graphics: graphics).layer { layers.append(layer) }
                rx -= 4
            }
            let tw = w(r.tokens)
            if let layer = cardDrawing.text(r.tokens, size: 10, color: primary, at: CGPoint(x: rx - tw, y: ry), scale: scale, graphics: graphics).layer { layers.append(layer) }
            ry += h2 + 2
        }
        return Card(drawing: PlazaPanelDrawing(layers: layers), frame: frame)
    }

    /// What a screen reader says about the panel: the title, today's readout and the peak; for a selected day, that day.
    var accessibleName: String {
        if let day = selectedDate, let info = cardInfo(day) {
            let parts = [info.stamp, info.tokens, info.cost].compactMap { $0 }.joined(separator: " ")
            return ([parts] + info.providers.map { [$0.name, $0.tokens, $0.cost].compactMap { $0 }.joined(separator: " ") }).joined(separator: ", ")
        }
        var parts = [model.title]
        if !model.readout.isEmpty { parts.append(model.readout) }
        if let label = model.peakLabel, let peak = model.peakText { parts.append("\(label) \(peak)") }
        return parts.joined(separator: ", ")
    }

    // MARK: render

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let l = layout(width: width, graphics: graphics)
        let m = model, w = width
        let tertiary = PopoverColorRole.tertiary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        var layers: [PlazaPanelLayer] = []
        // caption: title, readout, (spacer), peak label, peak, dots
        let dotsX = w - ActivityDrawing.dotsWidth(m.dotCount)
        if let dots = drawing.dots(count: m.dotCount, current: m.dotIndex, at: CGPoint(x: dotsX, y: l.captionTop + (l.captionHeight - ActivityDrawing.dot) / 2),
                                   scale: scale, graphics: graphics) { layers.append(dots) }
        var rightEdge = dotsX - 5
        if let label = m.peakLabel, let peak = m.peakText {
            let pw = drawing.width(peak, size: 10, weight: 600, graphics: graphics)
            if let layer = drawing.text(peak, size: 10, weight: 600, color: secondary, at: CGPoint(x: rightEdge - pw, y: l.captionTop), scale: scale, graphics: graphics).layer { layers.append(layer) }
            rightEdge -= pw + 5
            let lw = drawing.width(label, size: 10, graphics: graphics)
            if let layer = drawing.text(label, size: 10, color: tertiary, at: CGPoint(x: rightEdge - lw, y: l.captionTop), scale: scale, graphics: graphics).layer { layers.append(layer) }
            rightEdge -= lw + 5
        }
        let title = drawing.text(m.title, size: 10, color: tertiary, at: CGPoint(x: 0, y: l.captionTop), scale: scale, graphics: graphics)
        if let layer = title.layer { layers.append(layer) }
        if let chevron = drawing.picture("chevron", size: Self.chevronSize, scale: scale, graphics: graphics, { canvas, space in
            canvas.setStrokeColor(tertiary)
            let box = space.canvas(CGRect(origin: .zero, size: Self.chevronSize))
            canvas.strokePath(PlazaPath(points: [CGPoint(x: box.minX + 0.5, y: box.maxY - 0.5), CGPoint(x: box.midX, y: box.minY + 0.5),
                                                 CGPoint(x: box.maxX - 0.5, y: box.maxY - 0.5)]), lineWidth: 1, cap: .round)
        }) { layers.append(.image(chevron, frame: CGRect(x: title.width + 3, y: l.captionTop + (l.captionHeight - Self.chevronSize.height) / 2, width: 7, height: 4))) }
        let readoutX = title.width + Self.chevronAdvance + 5
        if let layer = drawing.text(m.readout, size: 10, weight: 600, color: secondary, at: CGPoint(x: readoutX, y: l.captionTop),
                                    maxWidth: max(0, rightEdge - readoutX), scale: scale, graphics: graphics).layer { layers.append(layer) }
        if m.showsBars { layers += bars(l, scale: scale, graphics: graphics) }
        // The caption's title is its own button (the window menu); the chart's button is everything else: the band under the
        // caption, or the caption right of the title when there are no bars. They touch and never overlap; a click on the
        // caption outside both reaches the host's own click path (`hit`).
        let titleFrame = CGRect(x: 0, y: l.captionTop, width: title.width + Self.chevronAdvance, height: l.captionHeight)
        let panelFrame = m.showsBars ? CGRect(x: 0, y: l.captionTop + l.captionHeight, width: w, height: l.height - l.captionTop - l.captionHeight)
                                     : CGRect(x: titleFrame.maxX, y: l.captionTop, width: max(1, w - titleFrame.maxX), height: l.captionHeight)
        let whole = CGRect(x: 0, y: 0, width: w, height: l.height)
        let items = [PlazaAccessibilityItem(frame: titleFrame, role: .button, label: m.windowLabel, value: m.title,
                                            action: PlazaPanelHit(action: "window", index: nil), key: "window"),
                     PlazaAccessibilityItem(frame: panelFrame, role: .button, label: accessibleName, value: m.switchHint,
                                            action: PlazaPanelHit(action: "cycle", index: nil), key: "panel")]
        var dirty: CGRect?
        if !fullRender {
            var rect = CGRect.null
            for day in [renderedSelection, selectedDate].compactMap({ $0 }) {
                if let i = m.columns.firstIndex(where: { $0.date == day }) {
                    rect = rect.union(CGRect(x: CGFloat(i) * l.step - 1, y: l.barsTop, width: l.columnWidth + 2, height: PopoverTrendMetrics.track))
                }
            }
            dirty = rect.isNull ? nil : rect
            if renderedSelection == selectedDate { dirty = nil }
        }
        fullRender = false
        renderedSelection = selectedDate
        let result = PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: [PlazaTooltip(frame: whole, text: m.switchHint)])
        return PopoverDrawing(drawing: result, dirty: dirty)
    }

    /// The bars, ticks, axis labels and legend of the picture as layers.
    private func bars(_ l: Layout, scale: CGFloat, graphics: any PlazaGraphics) -> [PlazaPanelLayer] {
        let m = model
        var layers: [PlazaPanelLayer] = []
        let secondary = PopoverColorRole.secondary
        for (i, c) in m.columns.enumerated() {
            let x = CGFloat(i) * l.step
            if !c.isFuture {
                let hovered = c.date == selectedDate
                let bottom = l.barsTop + PopoverTrendMetrics.track
                let origin = { (h: CGFloat) in CGPoint(x: x, y: bottom - h) }
                if c.segments.isEmpty {
                    let color = c.isToday ? accent : secondary.plazaShapeColor(alpha: hovered ? 0.8 : (c.isEmpty ? 0.18 : 0.45))
                    if let layer = drawing.bar(width: l.columnWidth, height: c.height, color: color, segments: [], at: origin(c.height), scale: scale, graphics: graphics) { layers.append(layer) }
                } else {
                    let alpha = (c.isToday || hovered) ? 1.0 : 0.55
                    // segments run bottom to top, as `DailyTrendStack.segments`
                    let parts = c.segments.map { (PopoverColorRole.palette($0.colorIndex).plazaColor(alpha: alpha), $0.height) }
                    if let layer = drawing.bar(width: l.columnWidth, height: c.height, color: accent, segments: parts, at: origin(c.height), scale: scale, graphics: graphics) { layers.append(layer) }
                }
            }
            if c.weekendTick {
                layers.append(.color(secondary.plazaShapeColor(alpha: 0.5), frame: CGRect(x: x, y: l.tickTop, width: l.columnWidth, height: Self.tickHeight)))
            }
            if let label = c.axisLabel {
                let color = c.isToday ? accent : (c.isFuture ? PopoverColorRole.tertiary.plazaColor() : secondary.plazaColor())
                let lw = drawing.width(label, size: 10, graphics: graphics)
                if let layer = drawing.text(label, size: 10, color: color, at: CGPoint(x: x + l.columnWidth / 2 - lw / 2, y: l.axisTop), scale: scale, graphics: graphics).layer {
                    layers.append(layer)
                }
            }
        }
        for (item, frame) in zip(m.legend, l.legend) {
            layers.append(.color(PopoverColorRole.palette(item.colorIndex).plazaColor(), frame: CGRect(x: frame.minX, y: frame.minY + (frame.height - 6) / 2, width: 6, height: 6)))
            if let layer = drawing.text(item.name, size: 10, color: PopoverColorRole.tertiary.plazaColor(), at: CGPoint(x: frame.minX + 9, y: frame.minY), scale: scale, graphics: graphics).layer {
                layers.append(layer)
            }
        }
        return layers
    }
}
