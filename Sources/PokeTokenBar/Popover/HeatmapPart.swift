import Foundation

/// The 16-week grid (stage 7 D7, Task 12; the Mac's `ActivityHeatmap`): a caption (title, the readout of the hovered day or
/// today, the peak, the switch dots) over seven rows of weekday letters (from the region's first weekday) and one column per
/// week, one green per level 0...4, today outlined. The cells are one cached picture; the pointer (or the arrow keys) only
/// changes the caption's readout, so a hover redraws one text and repaints the caption's rectangle.
@MainActor final class HeatmapPart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var model: HeatmapModel
    private var readoutFor: (String) -> String
    private(set) var pointerDate: String?
    private(set) var keyboardDate: String?
    private var width: CGFloat = PopoverWindowMetrics.contentWidth
    private var fullRender = true
    private var renderedSelection: String?
    let drawing = ActivityDrawing()

    init(_ model: HeatmapModel, readout: @escaping (String) -> String = { _ in "" }) {
        self.model = model
        readoutFor = readout
    }

    func update(_ next: HeatmapModel, readout: @escaping (String) -> String) {
        readoutFor = readout
        guard next != model else { return }
        model = next
        fullRender = true
        let valid = Set(next.columns.joined().filter { $0.level >= 0 }.map(\.date))
        if let d = keyboardDate, !valid.contains(d) { keyboardDate = nil }
        if let d = pointerDate, !valid.contains(d) { pointerDate = nil }
        onChange?()
    }

    var selectedDate: String? { pointerDate ?? keyboardDate }

    // MARK: geometry

    static let top: CGFloat = 4
    static let gap: CGFloat = 3
    static let labelSize: CGFloat = 8
    static let captionSize: CGFloat = 10

    struct Layout {
        var captionTop: CGFloat, captionHeight: CGFloat
        var gridTop: CGFloat, gridLeft: CGFloat, cellWidth: CGFloat
        var height: CGFloat
    }

    private func layout(width: CGFloat, graphics: any PlazaGraphics) -> Layout {
        let caption = ActivityDrawing.lineHeight(Self.captionSize, text: graphics.text)
        let labelWidth = model.weekdayLabels.map { drawing.width($0, size: Self.labelSize, graphics: graphics) }.max() ?? 0
        let left = labelWidth + PopoverHeatmapMetrics.spacing + 2
        let n = CGFloat(max(1, model.columns.count))
        let cell = (width - left - PopoverHeatmapMetrics.spacing * (n - 1)) / n
        let gridTop = Self.top + caption + Self.gap
        let rows = CGFloat(model.weekdayLabels.count)
        return Layout(captionTop: Self.top, captionHeight: caption, gridTop: gridTop, gridLeft: left, cellWidth: cell,
                      height: gridTop + rows * PopoverHeatmapMetrics.cell + (rows - 1) * PopoverHeatmapMetrics.spacing)
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: layout(width: width, graphics: PlatformPlaza.graphics).height)
    }

    func cellRect(column: Int, row: Int, _ l: Layout) -> CGRect {
        CGRect(x: l.gridLeft + CGFloat(column) * (l.cellWidth + PopoverHeatmapMetrics.spacing),
               y: l.gridTop + CGFloat(row) * (PopoverHeatmapMetrics.cell + PopoverHeatmapMetrics.spacing),
               width: l.cellWidth, height: PopoverHeatmapMetrics.cell)
    }

    // MARK: hits and selection

    func hit(_ point: CGPoint) -> PlazaPanelHit? { PlazaPanelHit(action: "cycle", index: nil) }

    /// The (column, row) under `point`, nil in a gap, a label or a cell outside the range (not a hover target on the Mac).
    func cell(at point: CGPoint, graphics: any PlazaGraphics) -> (column: Int, row: Int)? {
        let l = layout(width: width, graphics: graphics)
        let stepX = l.cellWidth + PopoverHeatmapMetrics.spacing, stepY = PopoverHeatmapMetrics.cell + PopoverHeatmapMetrics.spacing
        guard point.x >= l.gridLeft, point.y >= l.gridTop else { return nil }
        let c = Int((point.x - l.gridLeft) / stepX), r = Int((point.y - l.gridTop) / stepY)
        guard model.columns.indices.contains(c), model.columns[c].indices.contains(r), cellRect(column: c, row: r, l).contains(point),
              model.columns[c][r].level >= 0 else { return nil }
        return (c, r)
    }

    func pointerMoved(_ point: CGPoint?) {
        let next = point.flatMap { p in cell(at: p, graphics: PlatformPlaza.graphics).map { model.columns[$0.column][$0.row].date } }
        guard next != pointerDate else { return }
        pointerDate = next
        onChange?()
    }

    func focusChanged(_ focused: Bool) {
        guard !focused, keyboardDate != nil else { return }
        keyboardDate = nil
        onChange?()
    }

    private func position(of date: String) -> (column: Int, row: Int)? {
        for (c, column) in model.columns.enumerated() {
            if let r = column.firstIndex(where: { $0.date == date }) { return (c, r) }
        }
        return nil
    }

    /// Arrow keys move over the days of the range (left and right by week, up and down by weekday); Escape clears.
    func key(_ vk: Int) -> Bool {
        if vk == PopoverKey.escape {
            guard keyboardDate != nil else { return false }
            keyboardDate = nil
            onChange?()
            return true
        }
        let steps: [Int: (Int, Int)] = [PopoverKey.left: (-1, 0), PopoverKey.right: (1, 0), PopoverKey.up: (0, -1), PopoverKey.down: (0, 1)]
        guard let (dc, dr) = steps[vk] else { return false }
        var at = keyboardDate.flatMap(position(of:)) ?? model.columns.joined().first(where: \.isToday).flatMap { position(of: $0.date) }
        if keyboardDate == nil, let start = at {
            keyboardDate = model.columns[start.column][start.row].date
            onChange?()
            return true
        }
        guard var p = at else { return true }
        while true {
            p = (p.column + dc, p.row + dr)
            guard model.columns.indices.contains(p.column), model.columns[p.column].indices.contains(p.row) else { return true }
            if model.columns[p.column][p.row].level >= 0 { break }
        }
        at = p
        keyboardDate = model.columns[p.column][p.row].date
        onChange?()
        return true
    }

    /// The caption's readout for the selected day, else today.
    var shownReadout: String { selectedDate.map(readoutFor) ?? model.readout }

    var accessibleName: String {
        var parts = [model.title]
        let r = shownReadout
        if !r.isEmpty { parts.append(r) }
        if selectedDate == nil, let label = model.peakLabel, let peak = model.peakText { parts.append("\(label) \(peak)") }
        return parts.joined(separator: ", ")
    }

    // MARK: render

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let l = layout(width: width, graphics: graphics)
        let m = model, w = width
        let tertiary = PopoverColorRole.tertiary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        var layers: [PlazaPanelLayer] = []
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
        // The title gives way first (an ellipsis); the readout, the number people open the popover for, stays whole.
        let readout = shownReadout
        let readoutWidth = drawing.width(readout, size: 10, weight: 600, graphics: graphics)
        let titleMax = max(0, rightEdge - readoutWidth - 5)
        let titleWidth = drawing.width(m.title, size: 10, graphics: graphics)
        let title = drawing.text(m.title, size: 10, color: tertiary, at: CGPoint(x: 0, y: l.captionTop), maxWidth: titleWidth > titleMax ? titleMax : nil,
                                 scale: scale, graphics: graphics)
        if let layer = title.layer { layers.append(layer) }
        let readoutX = title.width + 5
        let readoutLayer = drawing.text(readout, size: 10, weight: 600, color: secondary, at: CGPoint(x: readoutX, y: l.captionTop),
                                        maxWidth: max(0, rightEdge - readoutX), scale: scale, graphics: graphics)
        if let layer = readoutLayer.layer { layers.append(layer) }
        for (row, label) in m.weekdayLabels.enumerated() {
            let y = l.gridTop + CGFloat(row) * (PopoverHeatmapMetrics.cell + PopoverHeatmapMetrics.spacing)
            let lh = ActivityDrawing.lineHeight(Self.labelSize, text: graphics.text)
            if let layer = drawing.text(label, size: Self.labelSize, color: tertiary, at: CGPoint(x: 0, y: y + (PopoverHeatmapMetrics.cell - lh) / 2), scale: scale, graphics: graphics).layer {
                layers.append(layer)
            }
        }
        let cellsFrame = CGRect(x: l.gridLeft, y: l.gridTop, width: w - l.gridLeft, height: l.height - l.gridTop)
        let key = "grid-\(m.columns.map { $0.map { "\($0.level)\($0.isToday ? "t" : "")" }.joined() }.joined(separator: "|"))-\(Int(w * 10))"
        if let image = drawing.picture(key, size: cellsFrame.size, scale: scale, graphics: graphics, { canvas, space in
            for (c, column) in m.columns.enumerated() {
                for (r, cell) in column.enumerated() {
                    let rect = cellRect(column: c, row: r, l).offsetBy(dx: -l.gridLeft, dy: -l.gridTop)
                    if cell.level >= 0 {
                        canvas.setFillColor(PopoverColorRole.heatmap(level: cell.level).plazaColor())
                        canvas.fillRoundedRect(space.canvas(rect), radius: 2)
                    }
                    if cell.isToday {
                        canvas.setStrokeColor(PopoverColorRole.primary.plazaColor(alpha: 0.55))
                        canvas.strokeRoundedRect(space.canvas(rect.insetBy(dx: 0.5, dy: 0.5)), radius: 2, lineWidth: 1)
                    }
                }
            }
        }) { layers.append(.image(image, frame: cellsFrame)) }
        let whole = CGRect(x: 0, y: 0, width: w, height: l.height)
        let items = [PlazaAccessibilityItem(frame: whole, role: .button, label: accessibleName, value: m.switchHint,
                                            action: PlazaPanelHit(action: "cycle", index: nil), key: "panel")]
        var dirty: CGRect?
        if !fullRender, renderedSelection != selectedDate {
            dirty = CGRect(x: 0, y: l.captionTop, width: rightEdge, height: l.captionHeight)
        }
        fullRender = false
        renderedSelection = selectedDate
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: [PlazaTooltip(frame: whole, text: m.switchHint)]),
                              dirty: dirty)
    }
}
