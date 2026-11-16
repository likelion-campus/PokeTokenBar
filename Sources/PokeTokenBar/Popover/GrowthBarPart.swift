import Foundation

/// The growth bar (stage 7 Task 9; the Mac's `LabeledProgressBar`, pinned in twins.txt): a 6 pt capsule track
/// (`.secondary` at 20 %) in a 12 pt line, the orange fill clipped to it. After a 300 ms hover it grows to 12 pt with a
/// spring and shows "X / Y · Z%" inside (`GrowthBarHover`, `draw(… expand:readout:)`), as the Mac's; the same text is the
/// bar's tooltip and its accessible text. Drawn by `CompanionHeaderPart` inside the header and testable alone.
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
        draw(value: value, line: line, look: .rest, readout: nil, canvas: canvas, space: space)
    }

    // --- stage 7 Task 9: the hover's growth and readout (begin) ---
    /// The readout's font (`.system(size: 9, weight: .semibold)`, times the text size) and its room: the bar less 6 pt a side.
    nonisolated static func readoutFont(textScale: CGFloat) -> PlazaFont { .system(size: 9 * textScale, weight: .semibold) }
    nonisolated static let readoutPadding: CGFloat = 6
    /// How far a spring's overshoot reaches past the 12 pt line, each side (the spring peaks near 12.8 pt).
    nonisolated static let overshootRoom: CGFloat = 1

    /// The readout line fitted to a bar `width` wide: `.lineLimit(1).minimumScaleFactor(0.7)` (smaller down to 70 %, then
    /// clipped by the capsule).
    static func readoutLine(_ s: String, width: CGFloat, textScale: CGFloat, text: any PlazaTextEngine) -> PlazaTextLine {
        let room = max(1, width - 2 * readoutPadding)
        let full = text.line(s, font: readoutFont(textScale: textScale))
        guard full.width > room else { return full }
        let k = max(0.7, room / full.width)
        return text.line(s, font: .system(size: 9 * textScale * k, weight: .semibold))
    }

    /// Draws the bar at a hover's `look`: the capsule `6 + 6 × expand` pt high, centred in the line, and the readout in
    /// `.primary` at the look's label opacity, centred and clipped to the capsule.
    nonisolated static func draw(value: Double, line: CGRect, look: GrowthBarHover.Look, readout: (line: PlazaTextLine, height: CGFloat, ascender: CGFloat)?,
                                 canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let h = collapsedHeight + (expandedHeight - collapsedHeight) * CGFloat(max(0, look.expand))
        let track = CGRect(x: line.minX, y: line.minY + (expandedHeight - h) / 2, width: line.width, height: h)
        let radius = h / 2
        canvas.setFillColor(trackColor)
        canvas.fillRoundedRect(space.canvas(track), radius: radius)
        let fill = fillWidth(value: value, width: line.width)
        let showsLabel = look.label > 0.001 && readout != nil
        guard fill > 0 || showsLabel else { return }
        canvas.saveState()
        canvas.clip(toRoundedRect: space.canvas(track), radius: radius)
        if fill > 0 {
            canvas.setFillColor(fillColor)
            canvas.fillRoundedRect(space.canvas(CGRect(x: track.minX, y: track.minY, width: fill, height: track.height)),
                                   radius: min(radius, fill / 2))
        }
        if showsLabel, let r = readout {
            canvas.setFillColor(PopoverColorRole.primary.plazaColor(alpha: look.label))
            canvas.draw(r.line, at: space.canvas(CGPoint(x: track.midX - r.line.width / 2, y: track.midY - r.height / 2 + r.ascender)))
        }
        canvas.restoreState()
    }
    // --- stage 7 Task 9 (end) ---

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
                                        accessibility: [PlazaAccessibilityItem(frame: whole, role: .staticText, label: m.detail)],
                                        tooltips: [PlazaTooltip(frame: whole, text: m.detail)])
        return PopoverDrawing(drawing: drawing)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}

/// The growth bar's hover (stage 7 Task 9; the Mac's `LabeledProgressBar.onHover`): 300 ms after the pointer comes over the
/// bar it grows from 6 to 12 pt with `.spring(response: 0.3, dampingFraction: 0.55)` and its readout fades in
/// (`.easeIn(duration: 0.12).delay(0.12)`); leaving shrinks it at once (`.easeOut(duration: 0.18)`, the readout
/// `.easeOut(duration: 0.06)`); leaving within the 300 ms changes nothing. Without animation (Windows' "show animations"
/// off) the bar jumps to its look. A value; the host's clock samples `look(at:)` at `nextDue(after:)`.
struct GrowthBarHover {
    /// 0 = 6 pt, 1 = 12 pt (above 1 in the spring's overshoot); the readout's opacity.
    struct Look: Equatable, Sendable {
        var expand: Double
        var label: Double
        static let rest = Look(expand: 0, label: 0)
        static let open = Look(expand: 1, label: 1)
    }

    static let delay: TimeInterval = 0.3
    static let grow = PopoverMotion.Spring(response: 0.3, dampingFraction: 0.55)
    static let labelDelay: TimeInterval = 0.12, labelDuration: TimeInterval = 0.12
    static let shrinkDuration: TimeInterval = 0.18, labelOutDuration: TimeInterval = 0.06
    static let frameInterval: TimeInterval = 1.0 / 60
    /// How far before a moment a tick still counts as at it (rounding of `Date` sums).
    static let slack: TimeInterval = 1e-6

    var animates = true
    /// When the growth starts (the 300 ms after the pointer came; nil: not hovered).
    private(set) var growStart: Date?
    /// A shrink in progress: when, and the look it started from.
    private(set) var shrink: (start: Date, from: Look)?

    init(animates: Bool = true) { self.animates = animates }

    var isHovered: Bool { growStart != nil }

    /// The pointer came over the bar (`true`) or left it.
    mutating func setHovering(_ on: Bool, at time: Date) {
        if on {
            if growStart == nil { growStart = time.addingTimeInterval(Self.delay) }
            return
        }
        guard let g = growStart else { return }
        if time.addingTimeInterval(Self.slack) >= g { shrink = (time, look(at: time)) }   // it had grown: it shrinks from here
        growStart = nil
    }

    func look(at time: Date) -> Look {
        if let g = growStart, time.addingTimeInterval(Self.slack) >= g {
            guard animates else { return .open }
            // A shrink is over by then (0.18 s < 0.3 s), so the growth starts from the thin bar.
            let t = time.timeIntervalSince(g) + Self.slack
            let label = t < Self.labelDelay ? 0
                : t >= Self.labelDelay + Self.labelDuration ? 1 : PopoverMotion.easeIn((t - Self.labelDelay) / Self.labelDuration)
            return Look(expand: t >= Self.grow.settleTime ? 1 : Self.grow.value(t), label: label)
        }
        if let s = shrink, animates {
            let t = time.timeIntervalSince(s.start) + Self.slack
            guard t < Self.shrinkDuration else { return .rest }
            let l = t >= Self.labelOutDuration ? 1 : PopoverMotion.easeOut(t / Self.labelOutDuration)
            return Look(expand: s.from.expand * (1 - PopoverMotion.easeOut(t / Self.shrinkDuration)), label: s.from.label * (1 - l))
        }
        return .rest
    }

    /// When the look changes next: the growth's start, every 1/60 s while it grows or shrinks, nil once it holds still.
    func nextDue(after time: Date) -> Date? {
        let frame = time.addingTimeInterval(Self.frameInterval)
        if let g = growStart {
            if time.addingTimeInterval(Self.slack) < g { return g }
            guard animates else { return nil }
            let end = g.addingTimeInterval(max(Self.grow.settleTime, Self.labelDelay + Self.labelDuration))
            return time.addingTimeInterval(Self.slack) < end ? min(frame, end) : nil
        }
        if let s = shrink, animates {
            let end = s.start.addingTimeInterval(Self.shrinkDuration)
            return time.addingTimeInterval(Self.slack) < end ? min(frame, end) : nil
        }
        return nil
    }
}
