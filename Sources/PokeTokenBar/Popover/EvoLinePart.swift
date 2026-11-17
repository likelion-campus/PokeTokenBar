import Foundation

/// Draws an SF Symbol as the host's glyph into a picture (Windows: the Segoe Fluent Icons / MDL2 glyph of
/// `PopoverGlyphTable`, through GDI). Without one, parts draw a text stand-in (the Mac's PR renders).
@MainActor protocol PopoverGlyphRaster: AnyObject {
    func image(symbol: String, pointSize: CGFloat, bold: Bool, color: PlazaColor, scale: CGFloat) -> PlazaImage?
}

/// The evolution line under the header (stage 7 Task 9; the Mac's `EvoLineView` as `CompanionHeader` calls it, pinned in
/// twins.txt): one 40 pt column per node, an `arrow.right` glyph (8 pt, tertiary) between them, the current node's accent
/// dot under it, future nodes at 32 % opacity and 40 % saturation, the unknown branch as a bold "?". Sprites are slots
/// (still pictures: the Mac's line does not animate). Wider than `maxWidth` (the Mac's 320 pt) the line scrolls: the side
/// with more content fades out over 24 pt and shows a chevron button (16 pt circle) that moves one screen of columns
/// (`EvoLineLayout`, the Mac's statics). The chevrons are button items (Tab, Enter, Narrator) whose press is `hit`; a press
/// moves the line over 0.25 s as the Mac's `withAnimation(.easeInOut(duration: 0.25))` (the host's clock calls `advance`), and
/// the wheel or a touchpad's horizontal swipe moves it directly (`scroll(by:)`), as the Mac's horizontal `ScrollView`.
@MainActor final class EvoLinePart: PopoverPart {
    static let thumb: CGFloat = 40
    static let maxWidth: CGFloat = PopoverWindowMetrics.scrollContentWidth
    static let dotSize: CGFloat = 4
    /// The column plus the dot that hangs 2 pt under it.
    static let height: CGFloat = thumb + 2
    static let chevronSize: CGFloat = 16
    static let backAction = "evo.back", forwardAction = "evo.forward"
    static let futureOpacity = 0.32, futureSaturation = 0.4

    var onChange: (() -> Void)?
    private(set) var model: EvoLineModel
    private(set) var layout: EvoLineLayout
    /// What is behind the line (the fade blends into it).
    var background: PlazaColor
    /// The current node's dot (`Color.accentColor`: the user's Windows accent).
    var accent: PlazaColor
    weak var glyphs: (any PopoverGlyphRaster)?
    private(set) var presses = 0
    // --- stage 7 Task 9: the chevron's eased move, the wheel (begin) ---
    static let moveDuration: TimeInterval = 0.25
    static let frameInterval: TimeInterval = 1.0 / 60
    /// A press moves over `moveDuration` (the host turns this off when Windows' "show animations" is: the line jumps).
    var animatesMoves = false
    var now: () -> Date = { Date() }
    /// The chevron's move in progress: from, to (scroll offsets) and when it started.
    private(set) var move: (from: CGFloat, to: CGFloat, start: Date)?
    // --- stage 7 Task 9 (end) ---

    init(_ model: EvoLineModel, background: PlazaColor, accent: PlazaColor = PopoverColorRole.accent.plazaColor(),
         glyphs: (any PopoverGlyphRaster)? = nil) {
        self.model = model
        self.background = background
        self.accent = accent
        self.glyphs = glyphs
        layout = EvoLineLayout(nodes: model.nodes, thumb: Self.thumb, maxWidth: Self.maxWidth)
    }

    /// Shows another line; a line with other nodes starts at its beginning again.
    func update(_ next: EvoLineModel) {
        guard next != model else { return }
        if next.nodes != model.nodes { layout.scrollX = 0; move = nil }
        model = next
        layout.nodes = next.nodes
        onChange?()
    }

    /// Where the chevrons sit (part coordinates): leading and trailing, centred on the sprites.
    var backChevron: CGRect {
        CGRect(x: 1, y: max(0, Self.thumb / 2 - Self.chevronSize / 2), width: Self.chevronSize, height: Self.chevronSize)
    }
    var forwardChevron: CGRect {
        CGRect(x: layout.visibleWidth - 1 - Self.chevronSize, y: max(0, Self.thumb / 2 - Self.chevronSize / 2),
               width: Self.chevronSize, height: Self.chevronSize)
    }

    /// A chevron press: one screen of columns back or forward, from where the line is now (mid-move too, as the Mac's
    /// `pageTarget` reads the live offset). With `animatesMoves` the move starts (`advance` draws it), else the line jumps.
    @discardableResult
    func press(_ hit: PlazaPanelHit) -> Bool {
        let forward: Bool
        switch hit.action {
        case Self.forwardAction where layout.canScrollForward: forward = true
        case Self.backAction where layout.canScrollBack: forward = false
        default: return false
        }
        let next = layout.scrolled(forward: forward)
        guard next != layout.scrollX else { return false }
        presses += 1
        if animatesMoves {
            move = (layout.scrollX, next, now())
        } else {
            move = nil
            layout.scrollX = next
            onChange?()
        }
        return true
    }

    /// Draws the chevron's move at `time` (`.easeInOut` over 0.25 s); true when the line moved. The last call lands on the target.
    @discardableResult
    func advance(to time: Date) -> Bool {
        guard let m = move else { return false }
        let t = time.timeIntervalSince(m.start) / Self.moveDuration
        let x: CGFloat
        if t >= 1 - 1e-6 {
            x = m.to
            move = nil
        } else {
            x = m.from + (m.to - m.from) * CGFloat(PopoverMotion.easeInOut(max(0, t)))
        }
        guard x != layout.scrollX else { return false }
        layout.scrollX = min(layout.maxScrollX, max(0, x))
        onChange?()
        return true
    }

    /// When the line moves next by itself: the next frame (1/60 s) of a chevron's move, its end at the latest; nil otherwise.
    func nextDue(after time: Date) -> Date? {
        guard let m = move else { return nil }
        return min(time.addingTimeInterval(Self.frameInterval), m.start.addingTimeInterval(Self.moveDuration))
    }

    /// The wheel or a touchpad's horizontal swipe: moves the line by `dx` points (positive: forward), clamped to the content;
    /// ends a chevron's move where it is. True when it moved.
    @discardableResult
    func scroll(by dx: CGFloat) -> Bool {
        guard layout.scrolls else { return false }
        move = nil
        let next = min(layout.maxScrollX, max(0, layout.scrollX + dx))
        guard next != layout.scrollX else { return false }
        layout.scrollX = next
        onChange?()
        return true
    }

    /// A wheel message over the line as its move in device pixels (positive: forward), whole pixels with the fraction kept in
    /// `wheel`: `WM_MOUSEHWHEEL` (`horizontal`: a touchpad's sideways swipe or a tilted wheel, positive to the right) or a
    /// Shift-held `WM_MOUSEWHEEL` (positive away from the user: back); `chars` a notch (`SPI_GETWHEELSCROLLCHARS`) of AppKit's
    /// 10-point line, as the plaza's wheel.
    static func wheelMove(_ wheel: inout PopoverWheel, delta: Int, horizontal: Bool, chars: UInt32, scale: CGFloat, page: CGFloat) -> CGFloat {
        let change = wheel.offsetChange(delta: delta, lines: chars, lineHeight: 10 * scale, page: page * scale)
        return horizontal ? -change : change
    }

    /// Sets the scroll offset directly (the selftest's "scrolled" capture).
    func scroll(to x: CGFloat) {
        move = nil
        layout.scrollX = min(layout.maxScrollX, max(0, x))
        onChange?()
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        layout.maxWidth = min(Self.maxWidth, width)
        layout.contentWidth = EvoLineLayout.rowWidth(count: layout.nodes.count, thumb: Self.thumb, hasNames: false)
        layout.scrollX = min(layout.scrollX, layout.maxScrollX)
        return CGSize(width: layout.visibleWidth, height: Self.height)
    }

    /// The node slots (the sprites), part coordinates.
    var spriteSlots: [SpriteSlot] {
        layout.nodes.enumerated().compactMap { i, node in
            guard case .species(let id) = node.content else { return nil }
            let future = node.state == .future
            return SpriteSlot(frame: CGRect(x: layout.columnX(i) - layout.scrollX, y: 0, width: Self.thumb, height: Self.thumb),
                              subject: PlazaSpriteSubjectKey(speciesID: id, shiny: model.shiny, form: model.form, back: false),
                              bob: false, animated: false, opacity: future ? Self.futureOpacity : 1, saturation: future ? Self.futureSaturation : 1)
        }
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let text = graphics.text
        let lay = layout
        let size = CGSize(width: lay.visibleWidth, height: Self.height)
        let space = PlazaPanelSpace(content: size, room: 0)
        let arrow = glyphs?.image(symbol: "arrow.right", pointSize: Self.thumb * 0.2, bold: false,
                                  color: PopoverColorRole.tertiary.plazaColor(), scale: scale)
        let mysteryFont = PlazaFont.system(size: Self.thumb * 0.55, weight: .bold)
        let mysteryLine = text.line("?", font: mysteryFont)
        let mysteryMetrics = CompanionHeaderPart.lineHeight(mysteryFont, text)
        let arrowFont = PlazaFont.system(size: Self.thumb * 0.2, weight: .regular)
        let arrowLine = text.line("→", font: arrowFont)
        let arrowMetrics = CompanionHeaderPart.lineHeight(arrowFont, text)
        let accent = self.accent
        var items: [PlazaAccessibilityItem] = []
        let picture = space.image(scale: scale, graphics: graphics) { canvas in
            for (i, node) in lay.nodes.enumerated() {
                let x = lay.columnX(i) - lay.scrollX
                if i > 0 {
                    let cellW = Self.thumb * EvoLineLayout.arrowRatio
                    let cellX = lay.arrowX(i) - lay.scrollX
                    if let arrow {   // .frame(width: thumb * 0.25).padding(.top, thumb * 0.4), centred in its cell
                        let w = CGFloat(arrow.width) / scale, h = CGFloat(arrow.height) / scale
                        let r = CGRect(x: cellX + (cellW - w) / 2, y: Self.thumb * 0.4 + max(0, (arrowMetrics.height - h) / 2), width: w, height: h)
                        canvas.draw(arrow, in: space.canvas(r))
                    } else {
                        canvas.setFillColor(PopoverColorRole.tertiary.plazaColor())
                        canvas.draw(arrowLine, at: space.canvas(CGPoint(x: cellX + (cellW - arrowLine.width) / 2, y: Self.thumb * 0.4 + arrowMetrics.ascender)))
                    }
                }
                if case .mystery = node.content {
                    let alpha = node.state == .future ? Self.futureOpacity : 1
                    canvas.setFillColor(PopoverColorRole.primary.plazaColor(alpha: alpha))
                    let top = (Self.thumb - mysteryMetrics.height) / 2
                    canvas.draw(mysteryLine, at: space.canvas(CGPoint(x: x + (Self.thumb - mysteryLine.width) / 2, y: top + mysteryMetrics.ascender)))
                }
                if node.state == .current {   // Circle().fill(.accentColor) 4 × 4 at the bottom, offset 2 pt down
                    canvas.setFillColor(accent)
                    canvas.fillEllipse(in: space.canvas(CGRect(x: x + (Self.thumb - Self.dotSize) / 2, y: Self.thumb - Self.dotSize / 2,
                                                              width: Self.dotSize, height: Self.dotSize)))
                }
            }
        }
        for (i, node) in lay.nodes.enumerated() where node.content == .mystery {
            items.append(PlazaAccessibilityItem(frame: CGRect(x: lay.columnX(i) - lay.scrollX, y: 0, width: Self.thumb, height: Self.thumb),
                                                role: .staticText, label: model.mysteryLabel))
        }
        var overlays: [PlazaPanelLayer] = []
        if lay.scrolls {
            if let fade = Self.fade(back: lay.canScrollBack, forward: lay.canScrollForward, size: size, background: background, scale: scale, graphics: graphics) {
                overlays.append(fade)
            }
            for (forward, rect, label) in [(false, backChevron, model.previousLabel), (true, forwardChevron, model.nextLabel)]
            where forward ? lay.canScrollForward : lay.canScrollBack {
                if let chevron = chevronImage(forward: forward, scale: scale, graphics: graphics) { overlays.append(.image(chevron, frame: rect)) }
                items.append(PlazaAccessibilityItem(frame: rect, role: .button, label: label,
                                                    action: PlazaPanelHit(action: forward ? Self.forwardAction : Self.backAction, index: nil)))
            }
        }
        let layers: [PlazaPanelLayer] = picture.map { [.image($0, frame: CGRect(origin: .zero, size: size))] } ?? []
        let tips = items.filter { $0.role == .button }.map { PlazaTooltip(frame: $0.frame, text: $0.label) }
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips),
                              spriteSlots: spriteSlots, overlays: overlays)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard layout.scrolls else { return nil }
        if layout.canScrollBack, backChevron.contains(point) { return PlazaPanelHit(action: Self.backAction, index: nil) }
        if layout.canScrollForward, forwardChevron.contains(point) { return PlazaPanelHit(action: Self.forwardAction, index: nil) }
        return nil
    }

    // MARK: drawing

    /// The Mac's edge mask over a solid background: the background laid over the fading side, opaque at the edge and clear
    /// 24 pt in (`LinearGradient` stops `clear → black` over `fadeWidth / maxWidth`).
    nonisolated static func fade(back: Bool, forward: Bool, size: CGSize, background: PlazaColor, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaPanelLayer? {
        guard back || forward else { return nil }
        let space = PlazaPanelSpace(content: size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            let px = max(1, Int((EvoLineLayout.fadeWidth * scale).rounded()))
            for i in 0..<px {
                let alpha = 1 - (Double(i) + 0.5) / Double(px)
                canvas.setFillColor(PlazaColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: alpha * background.alpha))
                let x = CGFloat(i) / scale, w = 1 / scale
                if back { canvas.fill(space.canvas(CGRect(x: x, y: 0, width: w, height: size.height))) }
                if forward { canvas.fill(space.canvas(CGRect(x: size.width - x - w, y: 0, width: w, height: size.height))) }
            }
        }) else { return nil }
        return .image(image, frame: CGRect(origin: .zero, size: size))
    }

    /// A chevron button: a 16 pt circle (`.regularMaterial`, drawn as a light translucent disc: no blur on Windows) with a
    /// 12 % primary ring and the 9 pt bold chevron in the secondary colour.
    private func chevronImage(forward: Bool, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaImage? {
        let side = Self.chevronSize
        let space = PlazaPanelSpace(content: CGSize(width: side, height: side), room: 0)
        let glyph = glyphs?.image(symbol: forward ? "chevron.right" : "chevron.left", pointSize: 9, bold: true,
                                  color: PopoverColorRole.secondary.plazaColor(), scale: scale)
        let font = PlazaFont.system(size: 11, weight: .bold)
        let fallback = graphics.text.line(forward ? "›" : "‹", font: font)
        let metrics = CompanionHeaderPart.lineHeight(font, graphics.text)
        return space.image(scale: scale, graphics: graphics) { canvas in
            let whole = space.canvas(CGRect(x: 0, y: 0, width: side, height: side))
            canvas.setFillColor(PopoverAppearance.current.chipColor(light: 0.97, alpha: 0.92))
            canvas.fillEllipse(in: whole)
            canvas.setStrokeColor(PopoverColorRole.primary.plazaColor(alpha: 0.12))
            canvas.strokeEllipse(in: whole.insetBy(dx: 0.5, dy: 0.5), lineWidth: 1)
            if let glyph {
                let w = CGFloat(glyph.width) / scale, h = CGFloat(glyph.height) / scale
                canvas.draw(glyph, in: space.canvas(CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)))
            } else {
                canvas.setFillColor(PopoverColorRole.secondary.plazaColor())
                canvas.draw(fallback, at: space.canvas(CGPoint(x: (side - fallback.width) / 2, y: (side - metrics.height) / 2 + metrics.ascender)))
            }
        }
    }
}
