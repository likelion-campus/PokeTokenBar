import Foundation
import Observation

/// The look of the chat log, copied from `PlazaChatLogView` (SwiftUI): colours, paddings, spacings, corner radius.
enum PlazaChatLogStyle {
    static let ink = PlazaColor(hex: 0xF8F8F0)
    static let dimmed = PlazaColor(hex: 0xF8F8F0, alpha: 0.6)
    static let loud = PlazaColor(hex: 0xFFE060)
    static let background = PlazaColor(hex: 0x1D4F5C, alpha: 0.8)
    static let cornerRadius: CGFloat = 6
    static let padding = CGSize(width: 10, height: 8)
    /// Between the header and the lines, and between two lines.
    static let headerGap: CGFloat = 4, rowGap: CGFloat = 3
    /// Where the log sits: this far from the window's left and bottom edge, 8 above the chat field while it is open.
    static let margin: CGFloat = 16, aboveInputGap: CGFloat = 8
    static let headerFont = PlazaFont.plaza(.small)
    static let rowFont = PlazaFont.plaza(.body)
}

/// The chat log at the window's bottom left (`PlazaChatLogView`, SwiftUI, replaced by this panel on the Mac and kept in Tests/Legacy): a header with the
/// title and the fold button, and under it the last `PlazaChatLog.visibleCount` lines, or, unfolded, a
/// `PlazaChatLog.expandedHeight` window onto all the kept lines that scrolls (`PlazaScrollState`). A line is one wrapped
/// paragraph of runs: time (dimmed), a loud line's 📢, "name: " in the member's colour, the text. Nothing shows while the
/// log is empty. Only the visible lines are drawn: one image per line, cut at the viewport's edges, never the whole
/// content. A click anywhere on the log is taken (nothing passes through to the scene); the header button toggles.
@MainActor final class PlazaChatLogPanel: PlazaPanel, PlazaScrollIndicating {
    let id = PlazaPanelID.chatLog
    let anchor = PlazaPanelAnchor.bottomLeading
    var onChange: (() -> Void)?
    private let log: PlazaChatLog
    private var observer: PlazaChangeObserver?

    /// The chat field's height while it is open (the log sits above it), nil while it is closed.
    var inputHeight: CGFloat? {
        didSet { if inputHeight != oldValue { onChange?() } }
    }

    var offset: CGPoint {
        CGPoint(x: PlazaChatLogStyle.margin,
                y: inputHeight.map { PlazaChatLogStyle.margin + $0 + PlazaChatLogStyle.aboveInputGap } ?? PlazaChatLogStyle.margin)
    }

    /// Pressed on the header button: its text is drawn dimmed (`.buttonStyle(.plain)`).
    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaNameColorPickerPanel.held(oldValue) != PlazaNameColorPickerPanel.held(interaction) { onChange?() } }
    }

    private(set) var scrollState = PlazaScrollState()
    let scrollIndicator = PlazaScrollIndicator()
    /// Unfolding and a new last line scroll to the end (SwiftUI's `onAppear` and `onChange(of: last id)`: always, whatever
    /// the user had scrolled to); it happens when the panel next lays out.
    private var scrollToEnd = true

    private struct Observed: Equatable { let first: Int?, last: Int?, count: Int, expanded: Bool, shown: Int }
    private var observed: Observed { Observed(first: log.lines.first?.id, last: log.lines.last?.id, count: log.lines.count, expanded: log.showsExpanded, shown: log.visible.count) }
    private var rendered: Observed?

    init(log: PlazaChatLog) {
        self.log = log
        scrollIndicator.onChange = { [weak self] in self?.onChange?() }
        observer = PlazaChangeObserver(track: { _ = log.lines; _ = log.showsExpanded; _ = log.isReduced }, changed: { [weak self] in self?.modelChanged() })
    }

    private func modelChanged() {
        let now = observed
        guard now != rendered else { return }
        if now.expanded, now.last != rendered?.last || !(rendered?.expanded ?? false) { scrollToEnd = true }
        onChange?()
    }

    var isVisible: Bool { !log.lines.isEmpty }

    // MARK: layout

    struct Row {
        let id: Int
        let lines: [PlazaTextLine]
        let baselines: [CGFloat]
        let frame: CGRect          // in the body's points: x 0, y from the body's top
        let label: String          // what VoiceOver reads: the line's whole text
    }

    @MainActor struct Layout {
        let size: CGSize            // the panel
        let headerHeight: CGFloat
        let title: PlazaTextLine
        let button: PlazaTextLine
        let buttonWidth: CGFloat
        let rows: [Row]
        let bodyTop: CGFloat        // from the panel's top
        let bodyHeight: CGFloat     // the viewport (expanded) or the lines' height
        let content: CGFloat        // all the lines' height
        let expanded: Bool
        static var innerWidth: CGFloat { PlazaChatLog.width - 2 * PlazaChatLogStyle.padding.width }
        var buttonFrame: CGRect {   // panel points: the label's text, right-aligned in the header
            CGRect(x: PlazaChatLogStyle.padding.width + Layout.innerWidth - buttonWidth, y: PlazaChatLogStyle.padding.height,
                   width: buttonWidth, height: headerHeight)
        }
    }

    private struct LayoutKey: Equatable { let observed: Observed, scale: CGFloat, engine: String, reserved: CGFloat }
    private var laidOut: (key: LayoutKey, layout: Layout)?
    /// The wrapping of each line (the costly part, TextKit on the Mac), kept while its line is in the log.
    private var wrapped: (engine: String, width: CGFloat, lines: [Int: [PlazaTextLine]]) = ("", 0, [:])

    static func runs(_ line: PlazaChatLog.Line) -> [PlazaTextRun] {
        let font = PlazaChatLogStyle.rowFont
        var runs = [PlazaTextRun(text: PlazaChatLog.timeText(line.time) + " ", font: font, color: PlazaChatLogStyle.dimmed)]
        if line.isLoud { runs.append(PlazaTextRun(text: "📢 ", font: font, color: PlazaChatLogStyle.ink)) }
        runs.append(PlazaTextRun(text: line.name + ": ", font: font, color: line.color))
        runs.append(PlazaTextRun(text: line.text, font: font, color: line.isLoud ? PlazaChatLogStyle.loud : PlazaChatLogStyle.ink))
        return runs
    }

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let engine = String(describing: type(of: text))
        let key = LayoutKey(observed: observed, scale: scale, engine: engine, reserved: scrollIndicator.reservedWidth)
        if let laidOut, laidOut.key == key { return laidOut.layout }
        let small = text.metrics(PlazaChatLogStyle.headerFont), body = text.metrics(PlazaChatLogStyle.rowFont)
        let headerHeight = (small.ascender - small.descender).rounded(), lineHeight = (body.ascender - body.descender).rounded()
        let l = L(.ko)
        let expanded = log.showsExpanded
        let shown = expanded ? log.lines : log.visible
        func build(width: CGFloat) -> (rows: [Row], height: CGFloat) {
            if wrapped.engine != engine || wrapped.width != width { wrapped = (engine, width, [:]) }
            var keep: [Int: [PlazaTextLine]] = [:]
            var rows: [Row] = []
            var y: CGFloat = 0
            for line in shown {
                if !rows.isEmpty { y += PlazaChatLogStyle.rowGap }
                let runs = Self.runs(line)
                let lines = wrapped.lines[line.id] ?? text.wrappedLines(runs, width: width)
                keep[line.id] = lines
                let height = CGFloat(lines.count) * lineHeight
                rows.append(Row(id: line.id, lines: lines, baselines: lines.indices.map { CGFloat($0) * lineHeight + body.ascender },
                                frame: CGRect(x: 0, y: y, width: width, height: height), label: runs.map(\.text).joined()))
                y += height
            }
            wrapped.lines = keep
            return (rows, y)
        }
        // "Always show scroll bars": the legacy scroller takes its width from the scrolling window when the lines overflow it (as the SwiftUI
        // `ScrollView` did: the lines wrap narrower).
        var built = build(width: Layout.innerWidth)
        if expanded, scrollIndicator.reservedWidth > 0, built.height > PlazaChatLog.expandedHeight { built = build(width: Layout.innerWidth - scrollIndicator.reservedWidth) }
        let rows = built.rows, y = built.height
        let bodyHeight = expanded ? PlazaChatLog.expandedHeight : y
        let button = text.line(expanded ? l.plazaChatLogCollapse : l.plazaChatLogExpand, font: PlazaChatLogStyle.headerFont)
        let bodyTop = PlazaChatLogStyle.padding.height + headerHeight + PlazaChatLogStyle.headerGap
        let size = CGSize(width: PlazaChatLog.width, height: bodyTop + bodyHeight + PlazaChatLogStyle.padding.height)
        let result = Layout(size: size, headerHeight: headerHeight, title: text.line(l.plazaChatLogTitle, font: PlazaChatLogStyle.headerFont),
                            button: button, buttonWidth: PlazaPanelStyle.pixelUp(button.width, scale: scale), rows: rows,
                            bodyTop: bodyTop, bodyHeight: bodyHeight, content: y, expanded: expanded)
        laidOut = (key, result)
        return result
    }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        layout(scale: scale, text: text).size
    }

    // MARK: drawing

    private var rowImages: (key: String, images: [Int: PlazaImage]) = ("", [:])
    private var backgroundImage: (key: String, image: PlazaImage?) = ("", nil)

    private func image(_ size: CGSize, scale: CGFloat, graphics: any PlazaGraphics, _ draw: (any PlazaCanvas) -> Void) -> PlazaImage? {
        guard let canvas = graphics.makeCanvas(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                               colorSpace: .sRGB) else { return nil }
        canvas.scale(x: scale, y: scale)
        draw(canvas)
        return canvas.makeImage()
    }

    /// The offset the content is drawn at: on the device-pixel grid.
    private func drawnOffset(scale: CGFloat) -> CGFloat { PlazaPanelStyle.pixel(scrollState.offset, scale: scale) }

    /// The backing scale of the last render (the scroller's knob sits on its device pixels).
    private var renderedScale: CGFloat = 1

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        renderedScale = scale
        rendered = observed
        let l = layout(scale: scale, text: graphics.text)
        scrollState.setMetrics(content: l.content, viewport: l.bodyHeight)
        if scrollToEnd {
            let before = scrollState.offset
            scrollState.scrollToBottom()
            scrollToEnd = false
            if scrollState.offset != before { scrollIndicator.scrolled() }
        }
        let pad = PlazaChatLogStyle.padding
        var layers: [PlazaPanelLayer] = []
        var items: [PlazaAccessibilityItem] = []

        let bgKey = "\(l.size.width)x\(l.size.height)@\(scale)"
        if backgroundImage.key != bgKey {
            backgroundImage = (bgKey, image(l.size, scale: scale, graphics: graphics) { canvas in
                canvas.setFillColor(PlazaChatLogStyle.background)
                canvas.fillRoundedRect(CGRect(origin: .zero, size: l.size), radius: PlazaChatLogStyle.cornerRadius)
            })
        }
        if let bg = backgroundImage.image { layers.append(.image(bg, frame: CGRect(origin: .zero, size: l.size))) }

        // Header: the title (dimmed) at the left, the button at the right (dimmed while pressed).
        let headerSize = CGSize(width: Layout.innerWidth, height: l.headerHeight)
        let ascender = graphics.text.metrics(PlazaChatLogStyle.headerFont).ascender
        let pressed = PlazaNameColorPickerPanel.held(interaction)?.action == "toggle"
        if let header = image(headerSize, scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(PlazaChatLogStyle.dimmed)
            canvas.draw(l.title, at: CGPoint(x: 0, y: headerSize.height - ascender))
            canvas.setFillColor(PlazaChatLogStyle.ink)
            if pressed { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
            canvas.draw(l.button, at: CGPoint(x: headerSize.width - l.buttonWidth, y: headerSize.height - ascender))
        }) {
            layers.append(.image(header, frame: CGRect(origin: CGPoint(x: pad.width, y: pad.height), size: headerSize)))
        }
        items.append(PlazaAccessibilityItem(frame: CGRect(x: pad.width, y: pad.height, width: PlazaPanelStyle.pixelUp(l.title.width, scale: scale), height: l.headerHeight),
                                            role: .staticText, label: L(.ko).plazaChatLogTitle))
        items.append(PlazaAccessibilityItem(frame: l.buttonFrame, role: .button, label: l.expanded ? L(.ko).plazaChatLogCollapse : L(.ko).plazaChatLogExpand,
                                            action: PlazaPanelHit(action: "toggle", index: nil)))

        // Rows: only the ones in the viewport, each cut at the viewport's edges.
        let offset = drawnOffset(scale: scale)
        let key = "\(scale) \(String(describing: type(of: graphics.text)))"
        if rowImages.key != key { rowImages = (key, [:]) }
        var kept: [Int: PlazaImage] = [:]
        let visible = scrollState.visibleRows(l.rows.map(\.frame))
        for i in visible {
            let row = l.rows[i]
            guard let shown = scrollState.visible(row.frame, offset: offset) else { continue }
            let full: PlazaImage? = rowImages.images[row.id] ?? image(row.frame.size, scale: scale, graphics: graphics) { canvas in
                for (line, baseline) in zip(row.lines, row.baselines) {
                    canvas.draw(line, at: CGPoint(x: 0, y: row.frame.height - baseline))
                }
            }
            guard var picture = full else { continue }
            kept[row.id] = picture
            if shown.height < row.frame.height {
                let top = max(0, offset - row.frame.minY)
                guard let cut = picture.cropping(to: PlazaPixelRect(x: 0, y: Int((top * scale).rounded()), width: picture.width,
                                                                    height: Int((shown.height * scale).rounded()))) else { continue }
                picture = cut
            }
            layers.append(.image(picture, frame: shown.offsetBy(dx: pad.width, dy: l.bodyTop)))
        }
        rowImages.images = kept
        layers += scrollIndicator.layers(state: scrollState, offset: offset,
                                         viewport: CGRect(x: pad.width, y: l.bodyTop, width: Layout.innerWidth, height: l.bodyHeight),
                                         scale: scale, graphics: graphics)
        // VoiceOver: the unfolded log is a scroll area; every line is an element (keyed by the line's id, so the cursor keeps its place when
        // lines arrive) at its true place, which is outside the window for the lines scrolled out.
        accessibilityContent = [:]
        if l.expanded {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: pad.width, y: l.bodyTop, width: Layout.innerWidth, height: l.bodyHeight), role: .scrollArea,
                                                label: L(.ko).plazaChatLogTitle, key: "scroll"))
        }
        for row in l.rows {
            if l.expanded { accessibilityContent[items.count] = row.frame }
            items.append(PlazaAccessibilityItem(frame: row.frame.offsetBy(dx: pad.width, dy: l.bodyTop - (l.expanded ? offset : 0)), role: .staticText, label: row.label,
                                                key: "line-\(row.id)", inScrollArea: l.expanded))
        }
        return PlazaPanelDrawing(layers: layers, accessibility: items)
    }

    /// Accessibility item index -> the item's rectangle in the scrolling content (for `scrollAccessibilityItemIntoView`).
    private var accessibilityContent: [Int: CGRect] = [:]

    func scrollAccessibilityItemIntoView(_ index: Int) -> Bool {
        guard let rect = accessibilityContent[index], scrollState.scrollToVisible(rect) else { return false }
        scrollIndicator.scrolled()
        return true
    }


    // MARK: the legacy scroller as a control

    private func scrollerViewport() -> CGRect? { guard let l = laidOut?.layout, l.expanded else { return nil }; return CGRect(x: PlazaChatLogStyle.padding.width, y: l.bodyTop, width: Layout.innerWidth, height: l.bodyHeight) }

    func scrollerContains(_ point: CGPoint) -> Bool {
        guard let v = scrollerViewport() else { return false }
        return scrollIndicator.tracks(point, state: scrollState, viewport: v)
    }

    func scrollerMouse(_ phase: PlazaScrollerPhase, at point: CGPoint) {
        guard let v = scrollerViewport() else { return }
        let scale = renderedScale
        let moved: Bool
        switch phase {
        case .down: moved = scrollIndicator.scrollerDown(at: point, state: &scrollState, viewport: v, scale: scale)
        case .drag: moved = scrollIndicator.scrollerDrag(to: point, state: &scrollState, viewport: v, scale: scale)
        case .up: scrollIndicator.scrollerUp(); moved = false
        }
        if moved { onChange?() }
    }

    // MARK: input

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let l = laidOut?.layout, CGRect(origin: .zero, size: l.size).contains(point) else { return nil }
        return l.buttonFrame.contains(point) ? PlazaPanelHit(action: "toggle", index: nil) : PlazaPanelHit(action: "log", index: nil)
    }

    /// Only the scrolling window takes the wheel (SwiftUI's `ScrollView`): over the header or the padding it goes on.
    func scroll(dx: CGFloat, dy: CGFloat, at point: CGPoint) -> Bool {
        guard isVisible, let l = laidOut?.layout, l.expanded,
              CGRect(x: PlazaChatLogStyle.padding.width, y: l.bodyTop, width: Layout.innerWidth, height: l.bodyHeight).contains(point),
              scrollState.scroll(deltaY: dy) else { return false }
        scrollIndicator.scrolled()
        onChange?()
        return true
    }
}
