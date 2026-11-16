import Foundation

/// The streak badge (stage 7 D7, Task 12; the Mac's `StreakBadge`, SF symbol `flame.fill`): a flame and the day count,
/// right-aligned in its row, orange once today counts and gray while it does not. The flame is a small drawn shape (the
/// glyph table's emoji cannot be gray). The tooltip and the accessible text are the model's label.
@MainActor final class StreakPart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var model: StreakModel
    private var width: CGFloat = PopoverWindowMetrics.contentWidth
    let drawing = ActivityDrawing()

    static let flameSize = CGSize(width: 9, height: 11)
    static let size: CGFloat = 10

    init(_ model: StreakModel) { self.model = model }

    func update(_ next: StreakModel) {
        guard next != model else { return }
        model = next
        onChange?()
    }

    /// The flame as a closed polygon in a unit square (origin bottom-left): a tip, two licks and a rounded base.
    static let flame: [CGPoint] = [
        CGPoint(x: 0.50, y: 1.00), CGPoint(x: 0.66, y: 0.80), CGPoint(x: 0.82, y: 0.62), CGPoint(x: 0.94, y: 0.40),
        CGPoint(x: 0.92, y: 0.20), CGPoint(x: 0.78, y: 0.05), CGPoint(x: 0.50, y: 0.00), CGPoint(x: 0.22, y: 0.05),
        CGPoint(x: 0.08, y: 0.20), CGPoint(x: 0.06, y: 0.42), CGPoint(x: 0.18, y: 0.62), CGPoint(x: 0.30, y: 0.50),
        CGPoint(x: 0.36, y: 0.68),
    ]

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: ActivityDrawing.lineHeight(Self.size, text: text))
    }

    /// The badge's rectangle at the row's right edge.
    func content(graphics: any PlazaGraphics) -> CGRect {
        let h = ActivityDrawing.lineHeight(Self.size, text: graphics.text)
        let w = Self.flameSize.width + 2 + drawing.width("\(model.days)", size: Self.size, weight: 600, graphics: graphics)
        return CGRect(x: width - w, y: 0, width: w, height: h)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let r = content(graphics: graphics)
        let m = model
        var layers: [PlazaPanelLayer] = []
        let flameKey = "flame-\(m.includesToday)"
        if let image = drawing.picture(flameKey, size: Self.flameSize, scale: scale, graphics: graphics, { canvas, space in
            let color = m.includesToday ? PopoverColorRole.systemOrange.plazaColor() : PopoverColorRole.secondary.plazaColor()
            canvas.setFillColor(color)
            let box = space.canvas(CGRect(origin: .zero, size: Self.flameSize))
            canvas.fillPath(PlazaPath(points: Self.flame.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }, closed: true))
        }) {
            layers.append(.image(image, frame: CGRect(x: r.minX, y: (r.height - Self.flameSize.height) / 2, width: Self.flameSize.width, height: Self.flameSize.height)))
        }
        let number = drawing.text("\(m.days)", size: Self.size, weight: 600, color: PopoverColorRole.secondary.plazaColor(),
                                  at: CGPoint(x: r.minX + Self.flameSize.width + 2, y: 0), scale: scale, graphics: graphics)
        if let layer = number.layer { layers.append(layer) }
        let items = [PlazaAccessibilityItem(frame: r, role: .staticText, label: m.label)]
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: [PlazaTooltip(frame: r, text: m.label)]))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
