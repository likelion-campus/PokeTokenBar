import Foundation

/// The growth bar (stage 7 Task 9; the Mac's `LabeledProgressBar`, pinned in twins.txt): a 6 pt capsule track
/// (`.secondary` at 20 %) in a 12 pt line, the orange fill clipped to it. The Mac grows the bar to 12 pt after a 300 ms hover
/// and shows "X / Y · Z%" inside; Windows shows the same text as the bar's tooltip (600 ms, the app's delay) and as its
/// accessible text, and the bar does not grow (a listed difference). Drawn by `CompanionHeaderPart` inside the header and
/// testable alone.
@MainActor final class GrowthBarPart: PopoverPart {
    struct Model: Equatable {
        var value: Double
        var detail: String
    }

    nonisolated static let collapsedHeight: CGFloat = 6
    nonisolated static let expandedHeight: CGFloat = 12

    var onChange: (() -> Void)?
    private(set) var model: Model
    private var width: CGFloat = 200

    init(_ model: Model) { self.model = model }

    func update(_ next: Model) {
        guard next != model else { return }
        model = next
        onChange?()
    }

    /// The track inside a line `width` wide (part coordinates, the line's top at 0).
    nonisolated static func trackRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: (expandedHeight - collapsedHeight) / 2, width: width, height: collapsedHeight)
    }

    nonisolated static func fillWidth(value: Double, width: CGFloat) -> CGFloat { width * CGFloat(min(1, max(0, value))) }

    nonisolated static let trackColor = PopoverColorRole.secondary.plazaColor(alpha: 0.2)
    nonisolated static let fillColor = PopoverColorRole.systemOrange.plazaColor()

    /// Draws the bar whose line is `line` (DIP, the space's coordinates).
    nonisolated static func draw(value: Double, line: CGRect, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let track = trackRect(width: line.width).offsetBy(dx: line.minX, dy: line.minY)
        let radius = collapsedHeight / 2
        canvas.setFillColor(trackColor)
        canvas.fillRoundedRect(space.canvas(track), radius: radius)
        let fill = fillWidth(value: value, width: line.width)
        guard fill > 0 else { return }
        canvas.saveState()
        canvas.clip(toRoundedRect: space.canvas(track), radius: radius)
        canvas.setFillColor(fillColor)
        canvas.fillRoundedRect(space.canvas(CGRect(x: track.minX, y: track.minY, width: fill, height: track.height)),
                               radius: min(radius, fill / 2))
        canvas.restoreState()
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: Self.expandedHeight)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let m = model, w = width
        let space = PlazaPanelSpace(content: CGSize(width: w, height: Self.expandedHeight), room: 0)
        let whole = CGRect(x: 0, y: 0, width: w, height: Self.expandedHeight)
        var layers: [PlazaPanelLayer] = []
        if let image = space.image(scale: scale, graphics: graphics, { canvas in
            Self.draw(value: m.value, line: whole, canvas: canvas, space: space)
        }) {
            layers.append(.image(image, frame: whole))
        }
        let drawing = PlazaPanelDrawing(layers: layers,
                                        accessibility: [PlazaAccessibilityItem(frame: whole, role: .staticText, label: m.detail, value: m.detail)],
                                        tooltips: [PlazaTooltip(frame: whole, text: m.detail)])
        return PopoverDrawing(drawing: drawing)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
