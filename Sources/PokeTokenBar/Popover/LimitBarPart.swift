import Foundation

extension PopoverColorRole {
    /// The role's colour in the plaza canvas's colour type (light now; dark with Task 16): the Mac's value, except Windows'
    /// readable secondary and tertiary (`displayValue`).
    func plazaColor(_ appearance: PopoverAppearance = .light, alpha: Double = 1) -> PlazaColor {
        let v = displayValue(appearance, windows: PopoverPlatform.isWindows)
        return PlazaColor(srgbRed: v.red, green: v.green, blue: v.blue, alpha: v.alpha * alpha)
    }

    /// The Mac's value on every platform, for SHAPES drawn from a label colour at a fraction of its alpha (bars, tracks, dots,
    /// tints): only text and glyphs follow Windows' raised secondary/tertiary (`plazaColor`), the Mac's proportions stay.
    func plazaShapeColor(_ appearance: PopoverAppearance = .light, alpha: Double = 1) -> PlazaColor {
        let v = macValue(appearance)
        return PlazaColor(srgbRed: v.red, green: v.green, blue: v.blue, alpha: v.alpha * alpha)
    }
}

/// The limit row's bar (stage 7, D7; the Mac's `LimitProgressBar`): a 6 pt track in a 12 pt line, the fill from
/// `fillPercent` in the role's colour, and the pace marker, a 2.5 × 10 pt rounded tick centred on the track and kept inside
/// the bar at both ends (`(width − 2.5) × fraction`, so it never hangs half over). Everything is drawn through the plaza
/// canvas, so the Mac (for the PR images) and Windows draw the same pixels. The accessible text is "<name> <percent>" and
/// the tooltip is the row's help (tier, delta, pace hint).
@MainActor final class LimitBarPart: PopoverPart {
    struct Model: Equatable {
        var name: String
        var percentText: String
        /// 0…100, in the display mode (clamped here like the Mac's `ProgressView(value:total:)`).
        var fillPercent: Double
        var tint: PopoverColorRole
        /// 0…1 along the bar, nil without a pace (`LimitRowModel.paceMarker`).
        var paceMarker: Double?
        var help: String?
        /// Values from before an expiry: half opacity, as the Mac dims them.
        var dimmed: Bool
    }

    static let trackHeight: CGFloat = 6
    static let markerWidth: CGFloat = 2.5
    static let markerHeight: CGFloat = 10
    /// The Mac's layout cell (`GeometryReader` height 12): the track and the marker sit centred in it.
    static let lineHeight: CGFloat = 12

    var onChange: (() -> Void)?
    private(set) var model: Model
    private var width: CGFloat = PopoverWindowMetrics.contentWidth

    init(_ model: Model) { self.model = model }

    /// Shows another row; the host renders again only when something differs.
    func update(_ next: Model) {
        guard next != model else { return }
        model = next
        onChange?()
    }

    // MARK: geometry (DIP, part coordinates; the tests read these)

    static func fillWidth(percent: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(min(100, max(0, percent)) / 100)
    }

    static func trackRect(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: (lineHeight - trackHeight) / 2, width: width, height: trackHeight)
    }

    static func markerRect(fraction: Double, width: CGFloat) -> CGRect {
        let f = CGFloat(min(1, max(0, fraction)))
        return CGRect(x: (width - markerWidth) * f, y: (lineHeight - markerHeight) / 2, width: markerWidth, height: markerHeight)
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: Self.lineHeight)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let m = model, w = width
        let space = PlazaPanelSpace(content: CGSize(width: w, height: Self.lineHeight), room: 0)
        var layers: [PlazaPanelLayer] = []
        if let image = space.image(scale: scale, graphics: graphics, { canvas in
            canvas.setAlpha(m.dimmed ? 0.5 : 1)
            let track = Self.trackRect(width: w)
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1))
            canvas.fillRoundedRect(space.canvas(track), radius: Self.trackHeight / 2)
            let fill = Self.fillWidth(percent: m.fillPercent, width: w)
            if fill > 0 {
                canvas.saveState()
                canvas.clip(toRoundedRect: space.canvas(track), radius: Self.trackHeight / 2)
                canvas.setFillColor(m.tint.plazaColor())
                canvas.fill(space.canvas(CGRect(x: 0, y: track.minY, width: fill, height: track.height)))
                canvas.restoreState()
            }
            if let pace = m.paceMarker {
                canvas.setFillColor(PopoverColorRole.primary.plazaColor(alpha: 0.55))
                canvas.fillRoundedRect(space.canvas(Self.markerRect(fraction: pace, width: w)), radius: Self.markerWidth / 2)
            }
        }) {
            layers.append(.image(image, frame: CGRect(x: 0, y: 0, width: w, height: Self.lineHeight)))
        }
        let whole = CGRect(x: 0, y: 0, width: w, height: Self.lineHeight)
        let drawing = PlazaPanelDrawing(
            layers: layers,
            accessibility: [PlazaAccessibilityItem(frame: whole, role: .staticText, label: "\(m.name) \(m.percentText)")],
            tooltips: m.help.map { [PlazaTooltip(frame: whole, text: $0)] } ?? [])
        return PopoverDrawing(drawing: drawing)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
