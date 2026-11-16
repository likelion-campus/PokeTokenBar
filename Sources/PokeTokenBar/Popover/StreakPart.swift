import Foundation

/// The streak badge (stage 7 D7, Task 12; the Mac's `StreakBadge`, SF symbol `flame.fill`): a flame and the day count,
/// right-aligned in its row. The flame is the glyph table's mapping for `flame.fill` (no acceptable icon-font glyph: the 🔥
/// emoji as text), drawn through the canvas's colour text path (Segoe UI Emoji, DirectWrite colour layers). The Mac tints the
/// symbol orange once today counts and secondary gray while it does not; an emoji takes no tint, so the same glyph is drawn at
/// the secondary label's opacity while today has no usage. The tooltip and the accessible text are the model's label.
@MainActor final class StreakPart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var model: StreakModel
    private var width: CGFloat = PopoverWindowMetrics.contentWidth
    let drawing = ActivityDrawing()

    static let size: CGFloat = 10
    /// `PopoverGlyphTable`'s fallback for `flame.fill`.
    static let flame = "\u{1F525}"

    init(_ model: StreakModel) { self.model = model }

    func update(_ next: StreakModel) {
        guard next != model else { return }
        model = next
        onChange?()
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        let flame = text.metrics(.emoji(size: Self.size))
        return CGSize(width: width, height: max(ActivityDrawing.lineHeight(Self.size, text: text), (flame.ascender - flame.descender).rounded()))
    }

    /// The badge's rectangle at the row's right edge.
    func content(graphics: any PlazaGraphics) -> CGRect {
        let h = size(width: width, scale: 1, text: graphics.text).height
        let glyph = graphics.text.line(Self.flame, font: .emoji(size: Self.size)).width
        let w = glyph + 2 + drawing.width("\(model.days)", size: Self.size, weight: 600, graphics: graphics)
        return CGRect(x: width - w, y: 0, width: w, height: h)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let r = content(graphics: graphics)
        let m = model
        var layers: [PlazaPanelLayer] = []
        let flame = drawing.emoji(Self.flame, size: Self.size, alpha: m.includesToday ? 1 : PopoverLabelOpacity.secondary,
                                  at: CGPoint(x: r.minX, y: (r.height - ActivityDrawing.lineHeight(Self.size, text: graphics.text)) / 2), scale: scale, graphics: graphics)
        if let layer = flame.layer { layers.append(layer) }
        let number = drawing.text("\(m.days)", size: Self.size, weight: 600, color: PopoverColorRole.secondary.plazaColor(),
                                  at: CGPoint(x: r.minX + flame.width + 2, y: (r.height - ActivityDrawing.lineHeight(Self.size, text: graphics.text)) / 2), scale: scale, graphics: graphics)
        if let layer = number.layer { layers.append(layer) }
        let items = [PlazaAccessibilityItem(frame: r, role: .staticText, label: m.label)]
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: [PlazaTooltip(frame: r, text: m.label)]))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
