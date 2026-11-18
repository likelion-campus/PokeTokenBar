import Foundation

// MARK: Task 21 — the Pokémon detail page as one drawn part (the Mac's `PokemonDetailView`)

/// The detail page: the Back line pinned on top, then the content scrolling under it (wheel, keys, the thumb in the 12 pt lane).
/// Everything is one picture and its button items; only what is in the viewport is drawn, has items and has sprite slots, so a move
/// list of hundreds of rows costs what a screenful does. The Mac's `ScrollView` of `VStack(spacing: 12)`: form picker, appearance
/// picker, identity header, individual picker, then the cards (individual or base stats, species data, the complete move list).
///
/// Hits (`PlazaPanelHit.action`): `detail.back`, `detail.form` (index into the model's cells), `detail.appearance` (index 0 normal,
/// 1 shiny), `detail.individual` (opens the host's menu), `detail.rep`, `detail.retry`, `detail.thumb`.
@MainActor final class DexDetailPart: PopoverPart {
    static let backAction = "detail.back", formAction = "detail.form", appearanceAction = "detail.appearance"
    static let individualAction = "detail.individual", repAction = "detail.rep", retryAction = "detail.retry", thumbAction = "detail.thumb"
    static let lane = PopoverWindowMetrics.scrollerInset
    static let spacing: CGFloat = 12
    static let headerGap: CGFloat = 8
    static let card: CGFloat = 9

    var onChange: (() -> Void)?
    private(set) var model: DexDetailModel
    var height: CGFloat
    weak var glyphs: (any PopoverGlyphRaster)?
    var accent: PlazaColor
    private(set) var scrollY: CGFloat = 0
    private var width: CGFloat = 332
    private var dragStart: (pointY: CGFloat, scrollY: CGFloat)?
    private var pendingDirty: CGRect?

    struct Laid {
        var size: CGSize
        var back: CGRect, id: CGRect
        var viewport: CGRect
        var contentHeight: CGFloat
        var ops: [Op]
        var items: [PlazaAccessibilityItem]   // content coordinates
        var tips: [PlazaTooltip]
        var slots: [SpriteSlot]
        var moveRows: [(key: String, y: CGFloat, h: CGFloat)]
    }
    struct Op {
        var y: CGFloat, h: CGFloat
        var draw: @MainActor (_ canvas: any PlazaCanvas, _ space: PlazaPanelSpace, _ off: CGFloat) -> Void
    }
    private(set) var laid: Laid?
    private var laidScale: CGFloat = 0
    /// The layout is out of date (the model or the width changed) but still describes the page for scrolling until the next render
    /// lays it out again: a wheel turn that lands in between must not find a page without a height.
    private var laidStale = false

    init(_ model: DexDetailModel, height: CGFloat, accent: PlazaColor = PopoverColorRole.accent.plazaColor(), glyphs: (any PopoverGlyphRaster)? = nil) {
        self.model = model
        self.height = height
        self.accent = accent
        self.glyphs = glyphs
    }

    func update(_ next: DexDetailModel) {
        guard next != model else { return }
        // another species or form starts at the top; a name arriving keeps the place
        if next.identity.speciesID != model.identity.speciesID || next.identity.form != model.identity.form || next.selectedInstanceID != model.selectedInstanceID {
            scrollY = 0
        }
        model = next
        laidStale = true
        pendingDirty = nil
        onChange?()
    }

    // MARK: layout

    private struct Fonts {
        let callout = PlazaFont.system(size: 12, weight: .regular), calloutBold = PlazaFont.system(size: 12, weight: .semibold)
        let title3 = PlazaFont.system(size: 15, weight: .bold), caption2 = PlazaFont.system(size: 10, weight: .regular)
        let small = PlazaFont.system(size: 11, weight: .regular), smallBold = PlazaFont.system(size: 11, weight: .semibold)
        let stat = PlazaFont.system(size: 12, weight: .regular), badge = PlazaFont.system(size: 11, weight: .bold)
    }

    private func layout(width: CGFloat, painter p: DexPainter) -> Laid {
        let f = Fonts()
        let model = self.model
        let accent = self.accent
        let primary = PopoverColorRole.primary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        let cw = width - Self.lane
        var ops: [Op] = [], items: [PlazaAccessibilityItem] = [], tips: [PlazaTooltip] = [], slots: [SpriteSlot] = []
        var moveRows: [(key: String, y: CGFloat, h: CGFloat)] = []
        var y: CGFloat = 0

        // the pinned line
        let backFont = PlazaFont.system(size: 13, weight: .regular)
        let backH = p.metrics(backFont).height + 6
        let backW = 14 + 4 + ceil(p.line(model.back, backFont).width) + 10
        let back = CGRect(x: 0, y: 0, width: backW, height: max(22, backH))
        let idLine = p.line(model.idText, f.callout)
        let idRect = CGRect(x: width - ceil(idLine.width), y: (back.height - p.metrics(f.callout).height) / 2, width: ceil(idLine.width), height: p.metrics(f.callout).height)
        let viewport = CGRect(x: 0, y: back.height + Self.headerGap, width: width, height: max(0, height - back.height - Self.headerGap))

        // helpers (content coordinates, x from 0)
        func text(_ s: String, _ font: PlazaFont, _ color: PlazaColor, x: CGFloat, y: CGFloat, width w: CGFloat, align: PlazaTextAlignment = .natural, maxLines: Int = 99) -> CGFloat {
            let lines = maxLines == 99 ? p.text.wrappedLines(s, font: font, width: max(10, w)) : p.wrapped(s, font, width: max(10, w), maxLines: maxLines)
            let m = p.metrics(font)
            let top = y
            ops.append(Op(y: top, h: CGFloat(lines.count) * m.height) { canvas, space, off in
                canvas.setFillColor(color)
                for (i, l) in lines.enumerated() {
                    let lx = align == .center ? x + (w - l.width) / 2 : x
                    canvas.draw(l, at: space.canvas(CGPoint(x: lx, y: top + off + CGFloat(i) * m.height + m.ascender)))
                }
            })
            return CGFloat(lines.count) * m.height
        }
        func pair(_ pr: DexDetailModel.Pair, x: CGFloat, y: CGFloat) -> (w: CGFloat, h: CGFloat) {
            let lw = ceil(p.line(pr.label, f.small).width), vw = ceil(p.line(pr.value, f.calloutBold).width)
            let h1 = p.metrics(f.small).height, h2 = p.metrics(f.calloutBold).height
            _ = text(pr.label, f.small, secondary, x: x, y: y, width: lw + 2)
            _ = text(pr.value, f.calloutBold, primary, x: x, y: y + h1 + 1, width: vw + 2)
            return (max(lw, vw), h1 + 1 + h2)
        }
        func button(_ rect: CGRect, label: String, action: PlazaPanelHit, key: String, value: String? = nil, enabled: Bool = true, tip: String? = nil) {
            items.append(PlazaAccessibilityItem(frame: rect, role: .button, label: label, value: value, action: action, key: key, isEnabled: enabled))
            if let tip { tips.append(PlazaTooltip(frame: rect, text: tip)) }
        }
        func cardBackground(_ top: CGFloat, _ h: CGFloat) {
            // First, under everything the card holds. It is called once the card's height is known, after its content was laid out;
            // while the Mac's tint was translucent (7 %) painting it over the content hid nothing, but Windows' card fill is opaque
            // (`plazaTileColor`) and would cover the text and bars (the K1 detail page went blank white).
            ops.insert(Op(y: top, h: h) { canvas, space, off in
                p.roundedRect(CGRect(x: 0, y: top + off, width: cw, height: h), radius: 9, fill: PopoverColorRole.secondary.plazaTileColor(alpha: 0.07), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
            }, at: 0)
        }
        func statRow(_ s: DexDetailModel.Stat, scale: Int, x: CGFloat, y: CGFloat, width w: CGFloat) -> CGFloat {
            let h = max(20, p.metrics(f.stat).height)   // ProgressView's own height sets the Mac row's
            let ivW: CGFloat = s.iv != nil ? 38 : 0, valueW: CGFloat = 30
            let barX = x + 74 + 6, barW = max(10, w - 74 - 6 - 6 - valueW - (s.iv != nil ? 6 + ivW : 0))
            _ = text(s.label, f.stat, primary, x: x, y: y + (h - p.metrics(f.stat).height) / 2, width: 74, maxLines: 1)
            ops.append(Op(y: y, h: h) { canvas, space, off in
                let bar = CGRect(x: barX, y: y + off + h / 2 - 3, width: barW, height: 6)
                p.capsule(bar, fill: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.2), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                let fraction = min(1, max(0, Double(s.value) / Double(max(1, scale))))
                if fraction > 0 { p.capsule(CGRect(x: bar.minX, y: bar.minY, width: max(6, bar.width * fraction), height: 6), fill: accent, stroke: nil, lineWidth: 0, canvas: canvas, space: space) }
                let v = p.line("\(s.value)", f.stat)
                canvas.setFillColor(primary)
                canvas.draw(v, at: space.canvas(CGPoint(x: barX + barW + 6 + valueW - v.width, y: y + off + (h - p.metrics(f.stat).height) / 2 + p.metrics(f.stat).ascender)))
                if let iv = s.iv {
                    let t = p.line("IV \(iv)", f.stat)
                    canvas.setFillColor(secondary)
                    canvas.draw(t, at: space.canvas(CGPoint(x: x + w - t.width, y: y + off + (h - p.metrics(f.stat).height) / 2 + p.metrics(f.stat).ascender)))
                }
            })
            return h
        }

        // 1. the form picker
        if let forms = model.forms {
            let titleH = text(forms.title, f.calloutBold, primary, x: 0, y: y, width: cw)
            var gy = y + titleH + 6
            let n = forms.columns
            let cellW = (cw - CGFloat(n - 1) * 3) / CGFloat(n)
            let lineH = p.metrics(f.smallBold).height
            let labelLines = n > 4 ? 1 : 2
            let cellH = 3 + 36 + CGFloat(labelLines) * lineH + 3
            for (i, cell) in forms.cells.enumerated() {
                let col = i % n, row = i / n
                let r = CGRect(x: CGFloat(col) * (cellW + 3), y: gy + CGFloat(row) * (cellH + 4), width: cellW, height: cellH)
                let font = PlazaFont.system(size: 11, weight: .semibold)
                var label = cell.label
                var lines: [PlazaTextLine]
                if n > 4 {   // lineLimit(1) with minimumScaleFactor(0.6)
                    let natural = p.line(label, font).width
                    let scale = natural > cellW - 4 ? max(0.6, (cellW - 4) / natural) : 1
                    let scaled = PlazaFont.system(size: 11 * scale, weight: .semibold)
                    lines = [p.line(label, scaled)]
                    if lines[0].width > cellW - 4, let cut = p.text.truncated(lines[0], width: cellW - 4, ellipsis: p.line("…", scaled)) { lines = [cut] }
                } else {
                    lines = p.wrapped(label, font, width: cellW - 4, maxLines: 2)
                }
                label = cell.label
                let cellCopy = cell
                ops.append(Op(y: r.minY, h: r.height) { canvas, space, off in
                    canvas.saveState()
                    let rr = r.offsetBy(dx: 0, dy: off)
                    p.roundedRect(rr, radius: 6, fill: cellCopy.isRepresentative && cellCopy.owned ? DexPainter.tint(accent, 0.16) : PopoverColorRole.secondary.plazaShapeColor(alpha: 0.06),
                                  stroke: cellCopy.isSelected ? accent : nil, lineWidth: 1.5, canvas: canvas, space: space)
                    canvas.setAlpha(cellCopy.owned ? 1 : 0.25)
                    canvas.setFillColor(primary)
                    for l in lines {
                        canvas.draw(l, at: space.canvas(CGPoint(x: rr.midX - l.width / 2, y: rr.minY + 3 + 36 + lineH * 0 + p.metrics(font).ascender)))
                    }
                    canvas.restoreState()
                    if cellCopy.isShiny {
                        p.draw("✨", .emoji(size: 11), color: .white, x: rr.midX + 18 - 14, centerY: rr.minY + 3 + 7, canvas: canvas, space: space)
                    }
                })
                slots.append(SpriteSlot(frame: CGRect(x: r.midX - 18, y: r.minY + 3, width: 36, height: 36),
                                        subject: PlazaSpriteSubjectKey(speciesID: forms.speciesID, shiny: cell.isShiny, form: cell.form, back: false),
                                        bob: false, animated: false, opacity: cell.owned ? 1 : 0.25))
                button(r, label: cell.accessibleName, action: PlazaPanelHit(action: Self.formAction, index: i), key: "form-\(cell.form.rawValue)", value: cell.accessibleValue.isEmpty ? nil : cell.accessibleValue,
                       enabled: cell.owned)
            }
            let rows = (forms.cells.count + n - 1) / n
            gy += CGFloat(rows) * cellH + CGFloat(max(0, rows - 1)) * 4
            y = gy + Self.spacing
        }
        // 2. the appearance picker
        if let a = model.appearance {
            let h: CGFloat = 24
            let r = CGRect(x: 0, y: y, width: cw, height: h)
            let segs = [(a.normal, !a.isShiny), (a.shiny, a.isShiny)]
            ops.append(Op(y: y, h: h) { canvas, space, off in
                let rr = r.offsetBy(dx: 0, dy: off)
                p.roundedRect(rr, radius: 6, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9), stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.3), lineWidth: 0.5, canvas: canvas, space: space)
                for (i, (title, on)) in segs.enumerated() {
                    let sr = CGRect(x: rr.minX + CGFloat(i) * rr.width / 2, y: rr.minY, width: rr.width / 2, height: rr.height).insetBy(dx: 1.5, dy: 1.5)
                    if on { p.roundedRect(sr, radius: 5, fill: DexPainter.tint(accent, 0.18), stroke: accent, lineWidth: 1, canvas: canvas, space: space) }
                    let font = PlazaFont.system(size: 12, weight: on ? .semibold : .regular)
                    let l = p.line(title, font)
                    canvas.setFillColor(primary)
                    canvas.draw(l, at: space.canvas(CGPoint(x: sr.midX - l.width / 2, y: sr.midY - p.metrics(font).height / 2 + p.metrics(font).ascender)))
                }
            })
            for (i, (title, on)) in segs.enumerated() {
                button(CGRect(x: CGFloat(i) * cw / 2, y: y, width: cw / 2, height: h), label: "\(a.title): \(title)", action: PlazaPanelHit(action: Self.appearanceAction, index: i),
                       key: "appearance-\(i)", value: on ? "✓" : nil)
            }
            y += h + Self.spacing
        }
        // 3. the identity header
        do {
            let id = model.identity
            let sprite: CGFloat = 104, gap: CGFloat = 14
            let colX = sprite + gap, colW = cw - colX
            var cy: CGFloat = 0
            var col: [Op] = []
            _ = col
            // the right column is measured first (centred on the sprite)
            let rarityW = ceil(p.line(id.rarity, f.calloutBold).width)
            let nameLines = p.text.wrappedLines(id.name, font: f.title3, width: max(10, colW - rarityW - 8))
            let nameH = CGFloat(nameLines.count) * p.metrics(f.title3).height
            cy += max(nameH, p.metrics(f.calloutBold).height) + 5
            var typeRects: [CGRect] = []
            if !id.types.isEmpty {
                var x: CGFloat = 0
                let bf = f.badge
                let bh = p.metrics(bf).height + 4
                for t in id.types {
                    let w = ceil(p.line(t.text, bf).width) + 14
                    typeRects.append(CGRect(x: x, y: cy, width: w, height: bh))
                    x += w + 5
                }
                cy += bh + 5
            }
            let noteLines = id.formNote.map { p.text.wrappedLines($0, font: f.caption2, width: colW) } ?? []
            let noteStart = cy
            cy += CGFloat(noteLines.count) * p.metrics(f.caption2).height + (noteLines.isEmpty ? 0 : 5)
            let shinyStart = cy
            if id.shinyLine != nil { cy += p.metrics(f.callout).height + 5 }
            let raisingStart = cy
            if id.raising != nil { cy += p.metrics(f.callout).height + 5 }
            let repStart = cy
            let repH: CGFloat = 20
            cy += repH
            let colH = cy
            let blockH = max(sprite, colH)
            let top = y
            let colTop = top + (blockH - colH) / 2
            ops.append(Op(y: top, h: blockH) { canvas, space, off in
                let ox = colX
                canvas.setFillColor(primary)
                for (i, l) in nameLines.enumerated() {
                    canvas.draw(l, at: space.canvas(CGPoint(x: ox, y: colTop + off + CGFloat(i) * p.metrics(f.title3).height + p.metrics(f.title3).ascender)))
                }
                p.draw(id.rarity, f.calloutBold, color: secondary, x: ox + colW - rarityW, centerY: colTop + off + p.metrics(f.title3).height / 2, canvas: canvas, space: space)
                for (t, r) in zip(id.types, typeRects) {
                    let rr = CGRect(x: ox + r.minX, y: colTop + off + r.minY, width: r.width, height: r.height)
                    p.capsule(rr, fill: t.tint.color, stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                    p.draw(t.text, f.badge, color: .white, x: rr.minX + 7, centerY: rr.midY, canvas: canvas, space: space)
                }
                canvas.setFillColor(secondary)
                for (i, l) in noteLines.enumerated() {
                    canvas.draw(l, at: space.canvas(CGPoint(x: ox, y: colTop + off + noteStart + CGFloat(i) * p.metrics(f.caption2).height + p.metrics(f.caption2).ascender)))
                }
                if let s = id.shinyLine { p.draw(s, f.callout, color: primary, x: ox, centerY: colTop + off + shinyStart + p.metrics(f.callout).height / 2, canvas: canvas, space: space) }
                if let s = id.raising { p.draw(s, f.callout, color: accent, x: ox, centerY: colTop + off + raisingStart + p.metrics(f.callout).height / 2, canvas: canvas, space: space) }
                let rb = CGRect(x: ox, y: colTop + off + repStart, width: 26, height: repH)
                p.roundedRect(rb, radius: 5, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9), stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                p.drawGlyph(id.isRepresentative ? "arrow.triangle.2.circlepath" : "star", fallback: id.isRepresentative ? "↻" : "☆", size: 11, bold: false, color: primary, in: rb, canvas: canvas, space: space)
            })
            slots.append(SpriteSlot(frame: CGRect(x: 0, y: top + (blockH - sprite) / 2, width: sprite, height: sprite),
                                    subject: PlazaSpriteSubjectKey(speciesID: id.speciesID, shiny: id.shinySprite, form: id.form, back: false), bob: true, animated: true))
            let rep = CGRect(x: colX, y: colTop + repStart, width: 26, height: repH)
            button(rep, label: id.repTitle, action: PlazaPanelHit(action: Self.repAction, index: nil), key: "rep", tip: id.repTitle)
            items.append(PlazaAccessibilityItem(frame: CGRect(x: colX, y: colTop, width: colW, height: nameH), role: .staticText, label: "\(id.name), \(id.rarity)"))
            y = top + blockH + Self.spacing
        }
        // 4. the individual picker
        if model.individualPicker.count > 1 {
            let current = model.individualPicker.first { $0.selected }?.label ?? model.individualPicker[0].label
            let font = PlazaFont.system(size: 12, weight: .regular)
            let h: CGFloat = 24
            let w = min(cw, ceil(p.line(current, font).width) + 34)
            let r = CGRect(x: 0, y: y, width: w, height: h)
            ops.append(Op(y: y, h: h) { canvas, space, off in
                let rr = r.offsetBy(dx: 0, dy: off)
                p.roundedRect(rr, radius: 5, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9), stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                var l = p.line(current, font)
                if l.width > w - 30, let cut = p.text.truncated(l, width: w - 30, ellipsis: p.line("…", font)) { l = cut }
                canvas.setFillColor(primary)
                canvas.draw(l, at: space.canvas(CGPoint(x: rr.minX + 9, y: rr.midY - p.metrics(font).height / 2 + p.metrics(font).ascender)))
                p.drawGlyph("chevron.down", fallback: "⌄", size: 10, bold: true, color: secondary, in: CGRect(x: rr.maxX - 22, y: rr.minY, width: 16, height: rr.height), canvas: canvas, space: space)
            })
            button(r, label: model.individualPickerTitle, action: PlazaPanelHit(action: Self.individualAction, index: nil), key: "individual", value: current)
            y += h + Self.spacing
        }
        // 5. the preview note
        if let note = model.preview {
            y += text(note, f.callout, secondary, x: 0, y: y, width: cw) + Self.spacing
        }
        // 6. the content
        switch model.content {
        case .loading(let s):
            y += 30
            y += text(s, f.callout, secondary, x: 0, y: y, width: cw, align: .center)
            y += 30
        case .unavailable(let s, let retry):
            y += 24
            y += text(s, f.callout, secondary, x: 0, y: y, width: cw, align: .center) + 8
            let bf = PlazaFont.system(size: 12, weight: .regular)
            let bw = ceil(p.line(retry, bf).width) + 24, bh: CGFloat = 24
            let r = CGRect(x: (cw - bw) / 2, y: y, width: bw, height: bh)
            ops.append(Op(y: y, h: bh) { canvas, space, off in
                let rr = r.offsetBy(dx: 0, dy: off)
                p.roundedRect(rr, radius: 5, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9), stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                p.draw(retry, bf, color: primary, x: rr.midX - ceil(p.line(retry, bf).width) / 2, centerY: rr.midY, canvas: canvas, space: space)
            })
            button(r, label: retry, action: PlazaPanelHit(action: Self.retryAction, index: nil), key: "retry")
            y += bh + 24
        case .details(let individual, let base, let species, let moves):
            let inner = cw - 2 * Self.card
            let x0 = Self.card
            if let ind = individual {
                let top = y
                var cy = top + Self.card
                cy += text(ind.title, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 8
                var px = x0
                var rowH: CGFloat = 0
                for pr in ind.pairs {
                    let m = pair(pr, x: px, y: cy)
                    px += m.w + 12
                    rowH = max(rowH, m.h)
                }
                cy += rowH + 8
                if let prayer = ind.prayer {
                    cy += text(prayer, f.callout, primary, x: x0, y: cy, width: inner) + 2
                    if let note = ind.prayerNote { cy += text(note, f.caption2, secondary, x: x0, y: cy, width: inner) }
                    cy += 8
                }
                let ah = p.metrics(f.small).height
                _ = text(ind.abilityLabel, f.small, secondary, x: x0, y: cy, width: inner)
                cy += ah + 1
                cy += text(ind.ability, f.calloutBold, primary, x: x0, y: cy, width: inner, maxLines: 2) + 8
                cy += text(ind.statsTitle, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 5
                for s in ind.stats { cy += statRow(s, scale: ind.scaleMaximum, x: x0, y: cy, width: inner) + 5 }
                cy += 3
                cy += text(ind.movesTitle, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 8
                if let none = ind.noMoves {
                    cy += text(none, f.callout, secondary, x: x0, y: cy, width: inner)
                } else {
                    for m in ind.moves {
                        let lv = ceil(p.line(m.detail, f.callout).width)
                        let h = text(m.name, f.callout, primary, x: x0, y: cy, width: inner - lv - 8)
                        _ = text(m.detail, f.callout, secondary, x: x0 + inner - lv, y: cy, width: lv + 2)
                        cy += h + 8
                    }
                    cy -= 8
                }
                cy += Self.card
                cardBackground(top, cy - top)
                y = cy + Self.spacing
            } else if let base {
                let top = y
                var cy = top + Self.card
                cy += text(base.title, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 6
                for s in base.stats { cy += statRow(s, scale: base.scaleMaximum, x: x0, y: cy, width: inner) + 6 }
                cy += Self.card - 6
                cardBackground(top, cy - top)
                y = cy + Self.spacing
            }
            // species data
            do {
                let top = y
                var cy = top + Self.card
                cy += text(species.title, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 7
                var px = x0
                var rowH: CGFloat = 0
                for pr in species.pairs {
                    let m = pair(pr, x: px, y: cy)
                    px += m.w + 14
                    rowH = max(rowH, m.h)
                }
                cy += rowH + 7
                cy += text(species.abilitiesTitle, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 7
                cy += text(species.abilities, f.callout, secondary, x: x0, y: cy, width: inner)
                cy += Self.card
                cardBackground(top, cy - top)
                y = cy + Self.spacing
            }
            // the complete move list
            do {
                let top = y
                var cy = top + Self.card
                cy += text(moves.title, f.calloutBold, secondary, x: x0, y: cy, width: inner) + 6
                for (i, m) in moves.moves.enumerated() {
                    let dw = min(inner * 0.55, ceil(p.line(m.detail, f.callout).width))
                    let nameLines = p.text.wrappedLines(m.name, font: f.callout, width: max(10, inner - dw - 8))
                    let detailLines = p.text.wrappedLines(m.detail, font: f.callout, width: max(10, dw + 2))
                    let lh = p.metrics(f.callout).height
                    let h = max(CGFloat(nameLines.count), CGFloat(detailLines.count)) * lh
                    let ry = cy
                    let last = i == moves.moves.count - 1
                    ops.append(Op(y: ry, h: h + 7) { canvas, space, off in
                        canvas.setFillColor(primary)
                        for (k, l) in nameLines.enumerated() { canvas.draw(l, at: space.canvas(CGPoint(x: x0, y: ry + off + CGFloat(k) * lh + p.metrics(f.callout).ascender))) }
                        canvas.setFillColor(secondary)
                        for (k, l) in detailLines.enumerated() { canvas.draw(l, at: space.canvas(CGPoint(x: x0 + inner - l.width, y: ry + off + CGFloat(k) * lh + p.metrics(f.callout).ascender))) }
                        if !last {
                            canvas.setFillColor(PopoverColorRole.primary.plazaShapeColor(alpha: 0.098))
                            canvas.fill(space.canvas(CGRect(x: x0, y: ry + off + h + 3, width: inner, height: 1)))
                        }
                    })
                    moveRows.append((m.key, ry, h))
                    cy += h + 7
                }
                if !moves.moves.isEmpty { cy -= 7 }
                cy += Self.card
                cardBackground(top, cy - top)
                y = cy + Self.spacing
            }
        }
        let contentHeight = max(0, y - Self.spacing + 8)
        return Laid(size: CGSize(width: width, height: height), back: back, id: idRect, viewport: viewport, contentHeight: contentHeight, ops: ops, items: items,
                    tips: tips, slots: slots, moveRows: moveRows)
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        if width != self.width { laidStale = true }
        self.width = width
        return CGSize(width: width, height: height)
    }

    var maxScroll: CGFloat { max(0, (laid?.contentHeight ?? 0) - (laid?.viewport.height ?? 0)) }

    private func shift(_ r: CGRect, _ lay: Laid) -> CGRect { r.offsetBy(dx: 0, dy: lay.viewport.minY - scrollY) }

    var spriteSlots: [SpriteSlot] {
        guard let lay = laid else { return [] }
        return lay.slots.compactMap { s in
            var s = s
            s.frame = shift(s.frame, lay)
            return s.frame.maxY > lay.viewport.minY && s.frame.minY < lay.viewport.maxY ? s : nil
        }
    }

    /// The move names in view (and a screen around it): the host loads what is missing, as the Mac's lazy rows do.
    func visibleMoveKeys() -> [String] {
        guard let lay = laid else { return [] }
        let from = scrollY - lay.viewport.height, to = scrollY + 2 * lay.viewport.height
        return lay.moveRows.filter { $0.y + $0.h >= from && $0.y <= to }.map(\.key)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let p = DexPainter(text: graphics.text, glyphs: glyphs, scale: scale)
        if scale != laidScale { laidStale = true }
        laidScale = scale
        let lay: Laid
        if let kept = laid, !laidStale { lay = kept } else { lay = layout(width: width, painter: p) }
        laid = lay
        laidStale = false
        scrollY = min(max(0, scrollY), maxScroll)
        let space = PlazaPanelSpace(content: lay.size, room: 0)
        let primary = PopoverColorRole.primary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        let model = self.model
        let off = lay.viewport.minY - scrollY
        let vp = lay.viewport
        let picture = space.image(scale: scale, graphics: graphics) { canvas in MainActor.assumeIsolated {
            // the pinned line
            let backFont = PlazaFont.system(size: 13, weight: .regular)
            p.drawGlyph("chevron.left", fallback: "‹", size: 12, bold: true, color: primary, in: CGRect(x: lay.back.minX, y: lay.back.minY, width: 14, height: lay.back.height), canvas: canvas, space: space)
            p.draw(model.back, backFont, color: primary, x: lay.back.minX + 18, centerY: lay.back.midY, canvas: canvas, space: space)
            p.draw(model.idText, PlazaFont.system(size: 12, weight: .regular), color: secondary, x: lay.id.minX, centerY: lay.id.midY, canvas: canvas, space: space)
            canvas.saveState()
            canvas.clip(to: space.canvas(vp))
            for op in lay.ops where op.y + off + op.h >= vp.minY && op.y + off <= vp.maxY { op.draw(canvas, space, off) }
            canvas.restoreState()
            if let t = self.thumbRect(lay) {
                p.capsule(t, fill: PopoverColorRole.primary.plazaShapeColor(alpha: self.dragStart == nil ? 0.28 : 0.45), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
            }
        } }
        var items: [PlazaAccessibilityItem] = [
            PlazaAccessibilityItem(frame: lay.back, role: .button, label: model.back, action: PlazaPanelHit(action: Self.backAction, index: nil), key: "back"),
            PlazaAccessibilityItem(frame: lay.id, role: .staticText, label: model.idText),
        ]
        var tips: [PlazaTooltip] = []
        for it in lay.items {
            let r = shift(it.frame, lay).intersection(vp)
            guard !r.isNull, r.height > 2 else { continue }
            var c = it
            c.frame = r
            items.append(c)
        }
        for t in lay.tips {
            let r = shift(t.frame, lay).intersection(vp)
            if !r.isNull, r.height > 2 { tips.append(PlazaTooltip(frame: r, text: t.text)) }
        }
        let layers: [PlazaPanelLayer] = picture.map { [.image($0, frame: CGRect(origin: .zero, size: lay.size))] } ?? []
        var d = PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips), spriteSlots: spriteSlots)
        d.dirty = pendingDirty
        pendingDirty = nil
        return d
    }

    // MARK: input

    func thumbRect(_ lay: Laid) -> CGRect? {
        let mx = maxScroll
        guard mx > 0, lay.viewport.height > 0 else { return nil }
        let track = lay.viewport.height
        let h = Swift.max(24, track * lay.viewport.height / lay.contentHeight)
        return CGRect(x: lay.size.width - 7, y: lay.viewport.minY + (track - h) * (scrollY / mx), width: 4, height: h)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let lay = laid else { return nil }
        if lay.back.contains(point) { return PlazaPanelHit(action: Self.backAction, index: nil) }
        if let t = thumbRect(lay), t.insetBy(dx: -4, dy: 0).contains(point) {
            if dragStart == nil { dragStart = (point.y, scrollY) }
            return PlazaPanelHit(action: Self.thumbAction, index: nil)
        }
        guard lay.viewport.contains(point) else { return nil }
        for it in lay.items where it.role == .button && it.isEnabled && shift(it.frame, lay).contains(point) { return it.action }
        return nil
    }

    func endDrag() { dragStart = nil }

    func setPointer(_ point: CGPoint?) {
        guard let start = dragStart, let point, let lay = laid, maxScroll > 0 else { return }
        let track = lay.viewport.height
        let h = Swift.max(24, track * lay.viewport.height / lay.contentHeight)
        let next = min(max(0, start.scrollY + (point.y - start.pointY) / Swift.max(1, track - h) * maxScroll), maxScroll)
        if next != scrollY { scrollY = next; pendingDirty = nil; onChange?() }
    }

    @discardableResult
    func scroll(by dy: CGFloat) -> Bool {
        let next = min(max(0, scrollY + dy), maxScroll)
        guard next != scrollY else { return false }
        scrollY = next
        pendingDirty = nil
        onChange?()
        return true
    }

    var viewportHeight: CGFloat { laid?.viewport.height ?? 0 }

    func key(_ vk: Int) -> Bool {
        let page = max(40, viewportHeight - 40)
        switch vk {
        case 0x26: return scroll(by: -40)
        case 0x28: return scroll(by: 40)
        case 0x21: return scroll(by: -page)
        case 0x22: return scroll(by: page)
        case 0x24: return scroll(by: -.greatestFiniteMagnitude)
        case 0x23: return scroll(by: .greatestFiniteMagnitude)
        default: return false
        }
    }

    /// Brings a focused item into view (keyboard focus on a button under the fold).
    func reveal(itemKey key: String) {
        guard let lay = laid, let it = lay.items.first(where: { $0.key == key }) else { return }
        let top = it.frame.minY - 4, bottom = it.frame.maxY + 4
        if top < scrollY { _ = scroll(by: top - scrollY) } else if bottom > scrollY + lay.viewport.height { _ = scroll(by: bottom - scrollY - lay.viewport.height) }
    }
}
