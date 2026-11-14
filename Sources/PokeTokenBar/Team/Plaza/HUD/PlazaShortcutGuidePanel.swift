import Foundation
import Observation

/// The shortcut guide under the background toggle (`PlazaShortcutGuide`, the SwiftUI view, before Track A Task 15): a header
/// line "단축키" with a chevron that folds and unfolds it, and one row per key: the key in a rounded chip, then what it
/// does. Only the header line takes clicks; the keys stay with the scene.
@MainActor final class PlazaShortcutGuidePanel: PlazaPanel {
    let id = PlazaPanelID.shortcuts
    let anchor = PlazaPanelAnchor.topLeading
    var onChange: (() -> Void)?
    private let model: PlazaShortcutGuideModel
    private let toggle: PlazaBackgroundTogglePanel
    private var observer: PlazaChangeObserver?

    /// Pressed on the header: the header's title and chevron are drawn dimmed (the button's label).
    var interaction = PlazaPanelInteraction() {
        didSet { if PlazaBackgroundTogglePanel.isPressed(oldValue) != PlazaBackgroundTogglePanel.isPressed(interaction) { onChange?() } }
    }

    /// The chevrons' advance in the header (`chevron.right` measured; `chevron.down` is wider).
    static let chevronWidth: CGFloat = 7.125, chevronDownWidth: CGFloat = 10.5
    static let chipMinWidth: CGFloat = 16, chipHeight: CGFloat = 16, rowGap: CGFloat = 4

    init(model: PlazaShortcutGuideModel, toggle: PlazaBackgroundTogglePanel) {
        self.model = model
        self.toggle = toggle
        observer = PlazaChangeObserver(track: { _ = model.isFolded; _ = model.season }, changed: { [weak self] in self?.modelChanged() })
    }

    private var rendered: String?
    private var state: String { "\(model.isFolded) \(model.season)" }
    private func modelChanged() { if rendered != state { onChange?() } }

    var isVisible: Bool { true }
    var offset: CGPoint { CGPoint(x: PlazaControlStyle.margin - PlazaPanelStyle.strokeRoom, y: 0) }

    func offset(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGPoint {
        let host = toggle.layout(scale: scale, text: text).host
        return CGPoint(x: offset.x, y: PlazaControlStyle.margin + host.height + PlazaControlStyle.guideGap - PlazaPanelStyle.strokeRoom)
    }

    struct Row { let key: PlazaTextLine, label: PlazaTextLine, keyText: String, labelText: String, chip: CGRect, labelX: CGFloat, y: CGFloat }
    struct Layout {
        let size: CGSize
        let title: PlazaTextLine
        let header: CGRect
        let rows: [Row]
        let folded: Bool
    }

    private var cache: (key: String, layout: Layout)?

    func layout(scale: CGFloat, text: any PlazaTextEngine) -> Layout {
        let folded = model.isFolded, season = model.season
        let key = "\(folded) \(season) \(scale) \(String(describing: type(of: text)))"
        if let cache, cache.key == key { return cache.layout }
        let font = PlazaControlStyle.pill.font
        let lineH = PlazaControlStyle.lineHeight(text)
        let title = text.line(L(.ko).plazaShortcutsTitle, font: font)
        let titleW = PlazaPanelStyle.pixelUp(title.width, scale: scale)
        let chevron = folded ? Self.chevronWidth : Self.chevronDownWidth
        let headerRect = CGRect(x: 8, y: 6, width: titleW + 4 + chevron, height: lineH)
        var width = headerRect.width
        var rows: [Row] = []
        var y = headerRect.maxY
        if !folded {
            for entry in PlazaShortcutGuide.entries(season: season) {
                y += Self.rowGap
                let k = text.line(entry.key, font: font), l = text.line(entry.label, font: font)
                let chipW = max(Self.chipMinWidth, PlazaPanelStyle.pixelUp(k.width, scale: scale) + 6)
                let rowH = max(Self.chipHeight, lineH)
                let chip = CGRect(x: 8, y: y + (rowH - Self.chipHeight) / 2, width: chipW, height: Self.chipHeight)
                rows.append(Row(key: k, label: l, keyText: entry.key, labelText: entry.label, chip: chip, labelX: 8 + chipW + 6, y: y + (rowH - lineH) / 2))
                width = max(width, chipW + 6 + PlazaPanelStyle.pixelUp(l.width, scale: scale))
                y += rowH
            }
        }
        let result = Layout(size: CGSize(width: width + 16, height: y + 6), title: title, header: headerRect, rows: rows, folded: folded)
        cache = (key, result)
        return result
    }

    /// The hosting view's size: whole points (the widest row rounded up).
    private func host(_ l: Layout) -> CGSize { CGSize(width: l.size.width.rounded(.up), height: l.size.height.rounded(.up)) }

    func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        PlazaPanelSpace(content: host(layout(scale: scale, text: text))).size
    }

    func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
        rendered = state
        let l = layout(scale: scale, text: graphics.text)
        let h = host(l)
        let space = PlazaPanelSpace(content: h)
        let o = CGPoint(x: (h.width - l.size.width) / 2, y: (h.height - l.size.height) / 2)
        let style = PlazaControlStyle.pill
        let m = graphics.text.metrics(style.font)
        var items: [PlazaAccessibilityItem] = []
        let image = space.image(scale: scale, graphics: graphics) { canvas in
            func at(_ x: CGFloat, _ top: CGFloat) -> CGPoint {
                space.canvas(PlazaControlStyle.snapped(CGPoint(x: o.x + x, y: o.y + top + m.ascender), scale: scale))
            }
            let pill = space.canvas(PlazaControlStyle.snapped(CGRect(origin: o, size: l.size), scale: scale))
            canvas.setFillColor(style.fill)
            canvas.fillRoundedRect(pill, radius: style.cornerRadius)
            canvas.saveState()
            if PlazaBackgroundTogglePanel.isPressed(interaction) { canvas.setAlpha(PlazaPanelStyle.pressedOpacity) }
            canvas.setFillColor(style.text)
            canvas.draw(l.title, at: at(l.header.minX, l.header.minY))
            canvas.setStrokeColor(style.text)
            canvas.setLineJoin(.round)
            let cx = l.header.minX + PlazaPanelStyle.pixelUp(l.title.width, scale: scale) + 4
            canvas.strokePath(PlazaControlStyle.canvasPath(PlazaControlStyle.chevron(folded: l.folded, at: cx, centreY: l.header.midY),
                                                           in: space, origin: o), lineWidth: 1.5, cap: .round)
            canvas.restoreState()
            for row in l.rows {
                let chip = space.canvas(PlazaControlStyle.snapped(row.chip.offsetBy(dx: o.x, dy: o.y), scale: scale))
                canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15))
                canvas.fillRoundedRect(chip, radius: 3)
                canvas.setFillColor(style.text)
                canvas.draw(row.key, at: at(row.chip.minX + (row.chip.width - row.key.width) / 2, row.y))
                canvas.draw(row.label, at: at(row.labelX, row.y))
                canvas.setStrokeColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6))
                canvas.strokeRoundedRect(chip, radius: 3, lineWidth: 1)
            }
            canvas.setStrokeColor(style.stroke)
            canvas.strokeRoundedRect(pill, radius: style.cornerRadius, lineWidth: style.lineWidth)
        }
        items.append(PlazaAccessibilityItem(frame: space.panel(l.header.offsetBy(dx: o.x, dy: o.y)), role: .button,
                                            label: L(.ko).plazaShortcutsTitle, action: PlazaPanelHit(action: "toggle", index: nil)))
        for row in l.rows {
            items.append(PlazaAccessibilityItem(frame: space.panel(row.chip.offsetBy(dx: o.x, dy: o.y)), role: .staticText, label: row.keyText))
            items.append(PlazaAccessibilityItem(frame: space.panel(CGRect(x: row.labelX + o.x, y: row.y + o.y, width: row.label.width,
                                                                          height: PlazaControlStyle.lineHeight(graphics.text))),
                                                role: .staticText, label: row.labelText))
        }
        return PlazaPanelDrawing(layers: image.map { [.image($0, frame: CGRect(origin: .zero, size: space.size))] } ?? [],
                                 accessibility: items)
    }

    /// Only the header line (the button's `contentShape`), not the guide's padding or its rows.
    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let l = cache?.layout else { return nil }
        let h = host(l), space = PlazaPanelSpace(content: h)
        let o = CGPoint(x: (h.width - l.size.width) / 2, y: (h.height - l.size.height) / 2)
        return space.panel(l.header.offsetBy(dx: o.x, dy: o.y)).contains(point) ? PlazaPanelHit(action: "toggle", index: nil) : nil
    }
}
