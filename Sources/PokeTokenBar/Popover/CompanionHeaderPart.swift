import Foundation

/// The companion header's top block (stage 7 Task 9; the Mac's `CompanionHeader` `HStack`, pinned in twins.txt): the
/// sprite box (76 pt, a rounded backdrop, the sprite as a slot the host animates) and, 12 pt beside it and centred on it,
/// the column of lines from `CompanionHeaderModel` (4 pt apart): name with ✨ and the rarity badge, type badges, the form
/// note, stage and nature with the boost badge, the growth bar, the captions, the status line. Text is drawn through the
/// plaza canvas, so emoji in it (✨, 🥚, ⏳) are in colour on both systems. Sizes are the Mac's points; Windows' text size
/// scales the text (not the sprite box).
///
/// Celebrations (`CompanionArtEffects`) change only the sprite box: the backdrop and the slot scale and turn with it, the
/// flash and the bursts are `overlays` (over the sprite), and `dirty` names the box so the host repaints just that. The
/// column's picture is kept between those renders. The growth bar is its own layer: a hover grows it (`setBarLook`,
/// `renderBarFrame`, whose `dirty` is the bar's line).
@MainActor final class CompanionHeaderPart: PopoverPart {
    nonisolated static let spriteBox: CGFloat = 76
    nonisolated static let cornerRadius: CGFloat = 12
    nonisolated static let columnGap: CGFloat = 12
    nonisolated static let lineGap: CGFloat = 4
    /// Room around the box that a celebration draws into (its dirty region).
    nonisolated static let effectRoom: CGFloat = 26

    var onChange: (() -> Void)?
    private(set) var model: CompanionHeaderModel
    private(set) var effects = CompanionArtEffects.rest
    private(set) var barLook = GrowthBarHover.Look.rest  // stage 7 Task 9
    let textScale: CGFloat
    private var width: CGFloat = PopoverWindowMetrics.scrollContentWidth
    private var laidOut: Layout?
    private var column: (key: String, image: PlazaImage?)?
    /// Pictures kept between renders (stage 7 Task 9): the backdrop per scale, size and angle (the wiggle's three poses are
    /// drawn once, not once a pose), the bar's layer per look. Emptied with the layout.
    private var backdrops: [String: PlazaPanelLayer] = [:]
    private var barLayer: (key: String, layers: [PlazaPanelLayer])?

    init(_ model: CompanionHeaderModel, textScale: CGFloat = 1) {
        self.model = model
        self.textScale = textScale
    }

    /// Shows another model; the host measures and renders again only when something differs.
    func update(_ next: CompanionHeaderModel) {
        guard next != model else { return }
        model = next
        laidOut = nil
        column = nil
        backdrops = [:]
        barLayer = nil
        onChange?()
    }

    // --- stage 7 Task 20: the sprite opens its Pokédex page (C2) (begin) ---
    /// The hit the sprite reports (`target` = the dex cell's collection ID).
    nonisolated static let dexAction = "header.dex"
    /// The page the sprite opens, with the tooltip: nil for an egg or a species not in the dex (the Mac's `target: nil`), then the
    /// sprite is no button and has no hover look.
    var dexLink: (target: String, hint: String)? {
        didSet {
            guard dexLink?.target != oldValue?.target || dexLink?.hint != oldValue?.hint else { return }
            laidOut = nil
            if dexLink == nil { linkHover = false }
            onChange?()
        }
    }
    private(set) var linkHover = false
    private var hoverLayer: (key: String, layer: PlazaPanelLayer?)?

    /// The pointer is over the sprite box (the host tells from `onPointer`): the box gets the 10 % hover background.
    func setLinkHover(_ over: Bool) {
        let next = over && dexLink != nil
        guard next != linkHover else { return }
        linkHover = next
        onChange?()
    }

    /// The sprite box (part coordinates), for the host's pointer test.
    var spriteBoxFrame: CGRect? { laidOut?.box }
    // --- stage 7 Task 20 (end) ---

    /// The celebration's look now. The host renders right after (`render`, whose `dirty` is the box).
    func setEffects(_ e: CompanionArtEffects) { effects = e }

    // --- stage 7 Task 9: the growth bar's hover (begin) ---
    /// The growth bar's hover look now. The host renders right after (`renderBarFrame`).
    func setBarLook(_ look: GrowthBarHover.Look) { barLook = look }

    /// The growth bar's line (part coordinates): the hover's area (the Mac's `.contentShape(Rectangle())` of the 12 pt line).
    var barFrame: CGRect? { laidOut?.bars.first?.frame }

    /// The region a hover frame changes: the bar's layer.
    var barRegion: CGRect? { laidOut?.bars.first.map { Self.barLayerFrame($0.frame, scale: 1) } }

    /// A render that changes only the growth bar (a hover frame): the same drawing with `dirty` set.
    func renderBarFrame(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        var d = render(scale: scale, graphics: graphics)
        d.dirty = laidOut?.bars.first.map { Self.barLayerFrame($0.frame, scale: scale) }
        return d
    }

    /// The bar's layer: its line with room for the spring's overshoot, out to whole device pixels (so the bar lands on the
    /// pixels it had inside the column's picture).
    nonisolated static func barLayerFrame(_ line: CGRect, scale: CGFloat) -> CGRect {
        let r = line.insetBy(dx: 0, dy: -GrowthBarPart.overshootRoom)
        let x0 = (r.minX * scale).rounded(.down) / scale, y0 = (r.minY * scale).rounded(.down) / scale
        let x1 = (r.maxX * scale).rounded(.up) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func barLayers(_ lay: Layout, scale: CGFloat, graphics: any PlazaGraphics) -> [PlazaPanelLayer] {
        let look = barLook
        return lay.bars.compactMap { bar in
            var readout: (line: PlazaTextLine, height: CGFloat, ascender: CGFloat)?
            if look.label > 0.001 {
                let line = GrowthBarPart.readoutLine(bar.detail, width: bar.frame.width, textScale: textScale, text: graphics.text)
                readout = (line, line.ascent + line.descent + line.leading, line.ascent)
            }
            let frame = Self.barLayerFrame(bar.frame, scale: scale)
            let space = PlazaPanelSpace(content: frame.size, room: 0)
            let line = bar.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            guard let image = space.image(scale: scale, graphics: graphics, { canvas in
                GrowthBarPart.draw(value: bar.value, line: line, look: look, readout: readout, canvas: canvas, space: space)
            }) else { return nil }
            return .image(image, frame: frame)
        }
    }
    // --- stage 7 Task 9 (end) ---

    // MARK: fonts (the Mac's text styles, in points)

    struct Fonts {
        let title, caption, badge, shiny: PlazaFont
        init(scale ts: CGFloat) {
            title = .system(size: 12 * ts, weight: .semibold)       // .callout.weight(.semibold)
            caption = .system(size: 10 * ts, weight: .regular)      // .caption2
            badge = .system(size: 8 * ts, weight: .bold)            // Badge: .system(size: 8, weight: .bold)
            shiny = .emoji(size: 11 * ts)                           // Text("✨").font(.system(size: 11))
        }
    }

    // MARK: layout

    struct TextBlock {
        var lines: [PlazaTextLine]
        var frame: CGRect
        var lineHeight: CGFloat
        var ascender: CGFloat
        var color: PlazaColor
    }

    struct BadgeBlock {
        var line: PlazaTextLine
        var frame: CGRect
        var ascender: CGFloat
        var badge: CompanionHeaderModel.Badge
    }

    struct Layout {
        var size: CGSize
        /// The sprite box (unscaled, part coordinates).
        var box: CGRect
        var column: CGRect
        var texts: [TextBlock] = []
        var badges: [BadgeBlock] = []
        var bars: [(frame: CGRect, value: Double, detail: String)] = []
        var items: [PlazaAccessibilityItem] = []
        var tooltips: [PlazaTooltip] = []
    }

    /// The badge's capsule size around its text (`padding(.horizontal, 5).padding(.vertical, 1)`).
    static func badgeSize(textWidth: CGFloat, lineHeight: CGFloat) -> CGSize {
        CGSize(width: textWidth + 10, height: lineHeight + 2)
    }

    nonisolated static func lineHeight(_ font: PlazaFont, _ text: any PlazaTextEngine) -> (height: CGFloat, ascender: CGFloat) {
        let m = text.metrics(font)
        return (m.ascender - m.descender + m.leading, m.ascender)
    }

    func layout(width: CGFloat, text: any PlazaTextEngine) -> Layout {
        let fonts = Fonts(scale: textScale)
        let box = Self.spriteBox
        let colX = box + Self.columnGap
        let colW = max(40, width - colX)
        var y: CGFloat = 0
        var texts: [TextBlock] = [], badges: [BadgeBlock] = [], bars: [(frame: CGRect, value: Double, detail: String)] = []
        var items: [PlazaAccessibilityItem] = [], tips: [PlazaTooltip] = []
        let (badgeH, badgeA) = Self.lineHeight(fonts.badge, text)

        func badge(_ b: CompanionHeaderModel.Badge) -> (PlazaTextLine, CGSize) {
            let line = text.line(b.text, font: fonts.badge)
            return (line, Self.badgeSize(textWidth: ceil(line.width), lineHeight: badgeH))
        }
        /// An `HStack` of a wrapping text and fixed pieces after it, centred on each other; returns its height.
        func row(_ s: String, font: PlazaFont, color: PlazaColor, spacing: CGFloat, fixed: [(width: CGFloat, height: CGFloat, place: (CGRect) -> Void)]) -> CGFloat {
            let (h, a) = Self.lineHeight(font, text)
            let fixedW = fixed.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(fixed.count) * spacing
            let lines = text.wrappedLines(s, font: font, width: max(10, colW - fixedW))
            let textW = ceil(lines.map(\.width).max() ?? 0)
            let textH = CGFloat(lines.count) * h
            let rowH = max(textH, fixed.map(\.height).max() ?? 0)
            let frame = CGRect(x: colX, y: y + (rowH - textH) / 2, width: textW, height: textH)
            texts.append(TextBlock(lines: lines, frame: frame, lineHeight: h, ascender: a, color: color))
            items.append(PlazaAccessibilityItem(frame: frame, role: .staticText, label: s))
            var x = colX + textW
            for f in fixed {
                x += spacing
                f.place(CGRect(x: x, y: y + (rowH - f.height) / 2, width: f.width, height: f.height))
                x += f.width
            }
            return rowH
        }
        func badgePiece(_ b: CompanionHeaderModel.Badge) -> (width: CGFloat, height: CGFloat, place: (CGRect) -> Void) {
            let (line, size) = badge(b)
            return (size.width, size.height, { r in
                badges.append(BadgeBlock(line: line, frame: r, ascender: badgeA, badge: b))
                items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: b.text))
            })
        }

        for (i, line) in model.lines.enumerated() {
            if i > 0 { y += Self.lineGap }
            switch line {
            case .title(let name, let shiny, let rarity):
                var fixed: [(width: CGFloat, height: CGFloat, place: (CGRect) -> Void)] = []
                if shiny {
                    let mark = text.line("✨", font: fonts.shiny)
                    let (h, a) = Self.lineHeight(fonts.shiny, text)
                    fixed.append((ceil(mark.width), h, { r in
                        texts.append(TextBlock(lines: [mark], frame: r, lineHeight: h, ascender: a, color: PopoverColorRole.primary.plazaColor()))
                        items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: "✨"))
                    }))
                }
                if let rarity { fixed.append(badgePiece(rarity)) }
                y += row(name, font: fonts.title, color: PopoverColorRole.primary.plazaColor(), spacing: 6, fixed: fixed)
            case .types(let list):
                var x = colX
                for b in list {
                    let (lineT, size) = badge(b)
                    let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                    badges.append(BadgeBlock(line: lineT, frame: r, ascender: badgeA, badge: b))
                    items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: b.text))
                    x += size.width + 5
                }
                y += badgeH + 2
            case .note(let s):
                y += row(s, font: fonts.caption, color: PopoverColorRole.secondary.plazaColor(), spacing: 0, fixed: [])
            case .stage(let s, let boost):
                y += row(s, font: fonts.caption, color: PopoverColorRole.secondary.plazaColor(), spacing: 5,
                         fixed: boost.map { [badgePiece($0)] } ?? [])
            case .egg(let s, let imminent, let guarantee):
                y += row(s, font: fonts.caption, color: (imminent ? PopoverColorRole.systemOrange : .secondary).plazaColor(), spacing: 6,
                         fixed: guarantee.map { [badgePiece($0)] } ?? [])
            case .bar(let value, let detail):
                let r = CGRect(x: colX, y: y, width: colW, height: GrowthBarPart.expandedHeight)
                bars.append((r, value, detail))
                // The Mac's bar is one element whose value is the detail: one text here (the kit reads "label, value").
                items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: detail))
                tips.append(PlazaTooltip(frame: r, text: detail))
                y += GrowthBarPart.expandedHeight
            case .caption(let s, let color):
                y += row(s, font: fonts.caption, color: color.plazaColor(), spacing: 0, fixed: [])
            case .status(let s):
                y += row(s, font: fonts.caption, color: PopoverColorRole.secondary.plazaColor(), spacing: 0, fixed: [])
            }
        }
        let colH = y
        let height = max(box, colH)
        let boxY = (height - box) / 2, colY = (height - colH) / 2
        // The column is centred on the box (HStack alignment .center): move it down by its offset.
        let shift = colY
        texts = texts.map { var t = $0; t.frame.origin.y += shift; return t }
        badges = badges.map { var b = $0; b.frame.origin.y += shift; return b }
        bars = bars.map { (frame: $0.frame.offsetBy(dx: 0, dy: shift), value: $0.value, detail: $0.detail) }
        items = items.map { var it = $0; it.frame.origin.y += shift; return it }
        tips = tips.map { var t = $0; t.frame.origin.y += shift; return t }
        let boxRect = CGRect(x: 0, y: boxY, width: box, height: box)
        // --- stage 7 Task 20: C2 (begin) ---
        if let link = dexLink {   // DexEntryLink: a button named "<name>, <hint>" with the hint as its tooltip
            items.insert(PlazaAccessibilityItem(frame: boxRect, role: .button, label: "\(model.spriteLabel), \(link.hint)",
                                                action: PlazaPanelHit(action: Self.dexAction, index: nil, target: link.target), key: "header-dex"), at: 0)
            tips.append(PlazaTooltip(frame: boxRect, text: link.hint))
        } else {
            items.insert(PlazaAccessibilityItem(frame: boxRect, role: .staticText, label: model.spriteLabel), at: 0)
        }
        // --- stage 7 Task 20 (end) ---
        return Layout(size: CGSize(width: width, height: ceil(height)), box: boxRect, column: CGRect(x: colX, y: colY, width: colW, height: colH),
                      texts: texts, badges: badges, bars: bars, items: items, tooltips: tips)
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        if laidOut == nil || abs(self.width - width) > 0.01 {
            self.width = width
            laidOut = layout(width: width, text: text)
            column = nil
            backdrops = [:]
            barLayer = nil
        }
        return laidOut?.size ?? .zero
    }

    /// The sprite slot at the current effects: the box scaled about its centre, turned by the wiggle.
    var spriteSlot: SpriteSlot {
        let box = laidOut?.box ?? CGRect(x: 0, y: 0, width: Self.spriteBox, height: Self.spriteBox)
        let s = CGFloat(effects.scale)
        let frame = CGRect(x: box.midX - box.width * s / 2, y: box.midY - box.height * s / 2, width: box.width * s, height: box.height * s)
        return SpriteSlot(frame: frame, subject: model.sprite, bob: true, animated: true, rotation: effects.rotation)
    }

    /// The region a celebration frame changes.
    var effectRegion: CGRect {
        let box = laidOut?.box ?? .zero
        return box.insetBy(dx: -Self.effectRoom, dy: -Self.effectRoom).intersection(CGRect(origin: .zero, size: laidOut?.size ?? .zero))
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let text = graphics.text
        if laidOut == nil { laidOut = layout(width: width, text: text) }
        guard let lay = laidOut else { return PopoverDrawing(drawing: PlazaPanelDrawing()) }
        let key = "\(scale)"
        if column?.key != key { column = (key, Self.drawColumn(lay, scale: scale, graphics: graphics)) }
        var layers: [PlazaPanelLayer] = []
        let backdropKey = "\(scale)|\(effects.scale)|\(effects.rotation)"
        if let kept = backdrops[backdropKey] {
            layers.append(kept)
        } else if let art = Self.drawBackdrop(lay.box, effects: effects, scale: scale, graphics: graphics) {
            if backdrops.count >= 8 { backdrops = [:] }   // a celebration's pop scales through many sizes: keep only a few
            backdrops[backdropKey] = art
            layers.append(art)
        }
        // --- stage 7 Task 20: the link's hover background (begin) ---
        if linkHover {
            let hkey = "\(scale)"
            if hoverLayer?.key != hkey {
                let space = PlazaPanelSpace(content: lay.box.size, room: 0)
                let img = space.image(scale: scale, graphics: graphics) { canvas in
                    canvas.setFillColor(PopoverColorRole.primary.plazaShapeColor(alpha: 0.1))
                    canvas.fillRoundedRect(space.canvas(CGRect(origin: .zero, size: lay.box.size)), radius: 12)
                }
                hoverLayer = (hkey, img.map { .image($0, frame: lay.box) })
            }
            if let layer = hoverLayer?.layer { layers.append(layer) }
        }
        // --- stage 7 Task 20 (end) ---
        if let image = column?.image { layers.append(.image(image, frame: CGRect(origin: .zero, size: lay.size))) }
        let barKey = "\(scale)|\(barLook.expand)|\(barLook.label)"
        if barLayer?.key != barKey { barLayer = (barKey, barLayers(lay, scale: scale, graphics: graphics)) }
        layers += barLayer?.layers ?? []
        let overlays = Self.drawOverlays(lay.box, effects: effects, scale: scale, graphics: graphics, bounds: lay.size)
        let drawing = PlazaPanelDrawing(layers: layers, accessibility: lay.items, tooltips: lay.tooltips)
        return PopoverDrawing(drawing: drawing, spriteSlots: [spriteSlot], overlays: overlays)
    }

    /// A render that changes only the sprite box (a celebration frame): the same drawing with `dirty` set.
    func renderEffectFrame(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        var d = render(scale: scale, graphics: graphics)
        d.dirty = effectRegion
        return d
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }

    // MARK: drawing

    nonisolated private static func drawColumn(_ lay: Layout, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaImage? {
        let space = PlazaPanelSpace(content: lay.size, room: 0)
        return space.image(scale: scale, graphics: graphics) { canvas in
            for t in lay.texts {
                canvas.setFillColor(t.color)
                for (i, line) in t.lines.enumerated() {
                    canvas.draw(line, at: space.canvas(CGPoint(x: t.frame.minX, y: t.frame.minY + CGFloat(i) * t.lineHeight + t.ascender)))
                }
            }
            for b in lay.badges { drawBadge(b, canvas: canvas, space: space) }
        }
    }

    /// The Mac's `Badge`: the capsule (solid tint, or the tint at 14 %), the text white (a type badge with a faint shadow)
    /// or in the tint.
    nonisolated static func drawBadge(_ b: BadgeBlock, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let tint = b.badge.tint.color
        let solid = b.badge.style == .solid
        canvas.setFillColor(solid ? tint : PlazaColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha * 0.14))
        canvas.fillRoundedRect(space.canvas(b.frame), radius: b.frame.height / 2)
        let base = space.canvas(CGPoint(x: b.frame.minX + 5, y: b.frame.minY + 1 + b.ascender))
        if b.badge.tint.isType {
            canvas.saveState()
            canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -0.5), blur: 0.5, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35)))
        }
        canvas.setFillColor(solid ? PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : tint)
        canvas.draw(b.line, at: base)
        if b.badge.tint.isType { canvas.restoreState() }
    }

    /// The backdrop (`.secondary` at 6 %, 12 pt corners), scaled and turned with the sprite.
    nonisolated private static func drawBackdrop(_ box: CGRect, effects: CompanionArtEffects, scale: CGFloat, graphics: any PlazaGraphics) -> PlazaPanelLayer? {
        let room = effectRoom
        let frame = box.insetBy(dx: -room, dy: -room)
        let space = PlazaPanelSpace(content: frame.size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            let local = CGRect(x: room, y: room, width: box.width, height: box.height)
            let c = space.canvas(local)
            canvas.translate(x: c.midX, y: c.midY)
            // SwiftUI turns clockwise for positive degrees; the canvas's y axis points up, so clockwise is a negative angle.
            canvas.rotate(by: -CGFloat(effects.rotation) * .pi / 180)
            canvas.scale(x: CGFloat(effects.scale), y: CGFloat(effects.scale))
            canvas.setFillColor(PopoverColorRole.secondary.plazaShapeColor(alpha: 0.06))
            canvas.fillRoundedRect(CGRect(x: -c.width / 2, y: -c.height / 2, width: c.width, height: c.height), radius: cornerRadius)
        }) else { return nil }
        return .image(image, frame: frame)
    }

    /// The flash and the bursts over the sprite (the Mac's `.overlay`s, in their order).
    nonisolated private static func drawOverlays(_ box: CGRect, effects e: CompanionArtEffects, scale: CGFloat, graphics: any PlazaGraphics, bounds: CGSize) -> [PlazaPanelLayer] {
        var out: [PlazaPanelLayer] = []
        let text = graphics.text
        func image(_ frame: CGRect, _ draw: (any PlazaCanvas, PlazaPanelSpace) -> Void) {
            let space = PlazaPanelSpace(content: frame.size, room: 0)
            if let img = space.image(scale: scale, graphics: graphics, { draw($0, space) }) { out.append(.image(img, frame: frame)) }
        }
        /// An emoji drawn at `size` pt with its centre at `center`, scaled and faded by `burst`.
        func emoji(_ s: String, size: CGFloat, center: CGPoint, _ burst: CompanionArtEffects.Burst) {
            guard burst.scale > 0.01, burst.opacity > 0.01 else { return }
            let font = PlazaFont.emoji(size: size)
            let line = text.line(s, font: font)
            let (h, a) = lineHeight(font, text)
            let w = ceil(line.width), k = CGFloat(burst.scale)
            let side = max(w, h) * max(1, k) + 4
            let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            image(frame) { canvas, space in
                canvas.setAlpha(CGFloat(burst.opacity))
                let c = space.canvas(CGRect(x: 0, y: 0, width: side, height: side))
                canvas.translate(x: c.midX, y: c.midY)
                canvas.scale(x: k, y: k)
                canvas.setFillColor(PopoverColorRole.primary.plazaColor())
                canvas.draw(line, at: CGPoint(x: -w / 2, y: -(h / 2 - (h - a))))
            }
        }
        if e.flash > 0.001 {
            image(box) { canvas, space in
                canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: e.flash))
                canvas.fillRoundedRect(space.canvas(CGRect(origin: .zero, size: box.size)), radius: cornerRadius)
            }
        }
        if let b = e.shiny {   // .overlay(alignment: .topTrailing) { Text("✨") 22 pt }.offset(x: 6, y: -6)
            let line = text.line("✨", font: .emoji(size: 22))
            let (h, _) = lineHeight(.emoji(size: 22), text)
            emoji("✨", size: 22, center: CGPoint(x: box.maxX - ceil(line.width) / 2 + 6, y: box.minY + h / 2 - 6), b)
        }
        if let b = e.ditto {   // .overlay(alignment: .top) { Text("🎭") 26 pt }.offset(y: -12)
            let (h, _) = lineHeight(.emoji(size: 26), text)
            emoji("🎭", size: 26, center: CGPoint(x: box.midX, y: box.minY + h / 2 - 12), b)
        }
        if let c = e.candy, c.opacity > 0.01 {   // .overlay(alignment: .top) { "+N XP" capsule }.offset(y: -16)
            let font = PlazaFont.system(size: 10, weight: .bold)
            let line = text.line(c.text, font: font)
            let (h, a) = lineHeight(font, text)
            let size = CGSize(width: ceil(line.width) + 12, height: h + 4)
            let top = box.minY - 16 + CGFloat(c.drop) * size.height
            let frame = CGRect(x: box.midX - size.width / 2, y: top, width: size.width, height: size.height)
            image(frame) { canvas, space in
                canvas.setAlpha(CGFloat(c.opacity))
                let whole = space.canvas(CGRect(origin: .zero, size: size))
                // .regularMaterial: a light translucent capsule (no blur behind it on Windows; listed difference).
                canvas.setFillColor(PlazaColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 0.92))
                canvas.fillRoundedRect(whole, radius: size.height / 2)
                canvas.setFillColor(PopoverColorRole.systemOrange.plazaColor())
                canvas.draw(line, at: space.canvas(CGPoint(x: 6, y: 2 + a)))
            }
        }
        if let b = e.mint {    // .overlay { three ✨ at (-11,-9) 22 pt, (13,5) 15 pt, (1,13) 12 pt }
            for (size, dx, dy) in [(CGFloat(22), CGFloat(-11), CGFloat(-9)), (15, 13, 5), (12, 1, 13)] {
                emoji("✨", size: size, center: CGPoint(x: box.midX + dx * CGFloat(b.scale), y: box.midY + dy * CGFloat(b.scale)), b)
            }
        }
        return out.filter {
            guard case .image(_, let f) = $0 else { return true }
            return f.intersects(CGRect(origin: .zero, size: bounds))
        }
    }
}

/// One wrapping caption line in a colour (the header's "X graduated → …", orange): a part so its emoji and arrow are drawn
/// like the rest of the header.
@MainActor final class CompanionNotePart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var text: String
    let color: PopoverColorRole
    let textScale: CGFloat
    private var width: CGFloat = 200
    private var lines: [PlazaTextLine] = []
    private var lineHeight: CGFloat = 0
    private var ascender: CGFloat = 0

    init(_ text: String, color: PopoverColorRole, textScale: CGFloat = 1) {
        self.text = text
        self.color = color
        self.textScale = textScale
    }

    func update(_ next: String) {
        guard next != text else { return }
        text = next
        onChange?()
    }

    func size(width: CGFloat, scale: CGFloat, text engine: any PlazaTextEngine) -> CGSize {
        self.width = width
        let font = PlazaFont.system(size: 10 * textScale, weight: .regular)
        (lineHeight, ascender) = CompanionHeaderPart.lineHeight(font, engine)
        lines = engine.wrappedLines(text, font: font, width: width)
        return CGSize(width: width, height: ceil(CGFloat(lines.count) * lineHeight))
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let size = CGSize(width: width, height: ceil(CGFloat(lines.count) * lineHeight))
        let space = PlazaPanelSpace(content: size, room: 0)
        var layers: [PlazaPanelLayer] = []
        let (lines, lh, asc, color) = (self.lines, lineHeight, ascender, self.color)
        if let image = space.image(scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(color.plazaColor())
            for (i, line) in lines.enumerated() { canvas.draw(line, at: space.canvas(CGPoint(x: 0, y: CGFloat(i) * lh + asc))) }
        }) {
            layers.append(.image(image, frame: CGRect(origin: .zero, size: size)))
        }
        let item = PlazaAccessibilityItem(frame: CGRect(origin: .zero, size: size), role: .staticText, label: text)
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: [item]))
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}
