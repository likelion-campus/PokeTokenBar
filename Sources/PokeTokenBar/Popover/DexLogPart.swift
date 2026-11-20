import Foundation

// MARK: Task 20 — the catch log as a drawn part (the Mac's `DexSummaryHeader` and the lazy list of `DexEntryRow`s)

/// The catch log: the summary header (title, total, the rarity chips) pinned on top and the entries under it as a list that
/// scrolls by wheel, keys and its own scroll thumb. Only the rows in the viewport are laid out into the picture and only
/// their sprites are slots, so a log of hundreds of entries costs what a screenful does. Each row is the Mac's card
/// (badges, nature, the evolution chain with names, the caught time); a chain node of a species in the dex is a button item
/// that opens its Pokédex page (`DexEntryLink`).
///
/// Hits: `log.rarity` (index), `log.node` (index = the entry's index in the model's rows, `target` = the dex cell),
/// `log.thumb`, `log.clear`.
@MainActor final class DexLogPart: PopoverPart {
    static let rarityAction = "log.rarity", nodeAction = "log.node", thumbAction = "log.thumb", clearAction = "log.clear"
    static let cardPadding: CGFloat = 8
    static let rowGap: CGFloat = 8
    static let thumb: CGFloat = 68
    static let lane: CGFloat = PopoverWindowMetrics.scrollerInset
    static let headerGap: CGFloat = 6

    var onChange: (() -> Void)?
    private(set) var model: DexLogModel
    var height: CGFloat
    weak var glyphs: (any PopoverGlyphRaster)?
    var accent: PlazaColor
    var language: AppLanguage
    var now: () -> Date = { Date() }
    private(set) var scrollY: CGFloat = 0
    private(set) var rarityScroll: CGFloat = 0
    private(set) var hoverNode: (row: Int, node: Int)?
    private var dragStart: (pointY: CGFloat, scrollY: CGFloat)?
    private var pendingDirty: CGRect?
    private var width: CGFloat = 332

    struct RowLayout {
        var y: CGFloat, height: CGFloat
        var badges: CGFloat, nameLines: [[PlazaTextLine]], namesHeight: CGFloat, chainHeight: CGFloat
    }
    struct Layout {
        var size: CGSize
        var title: CGRect, total: CGRect
        var chips: [CGRect], viewport: CGRect, chipViewport: CGRect, chipContent: CGFloat
        var rows: [RowLayout]
        var contentHeight: CGFloat
        var empty: (icon: CGRect, text: CGRect, button: CGRect)?
    }
    private(set) var laid: Layout?
    private var laidKey = ""

    init(_ model: DexLogModel, height: CGFloat, language: AppLanguage, accent: PlazaColor = PopoverColorRole.accent.plazaColor(),
         glyphs: (any PopoverGlyphRaster)? = nil) {
        self.model = model
        self.height = height
        self.language = language
        self.accent = accent
        self.glyphs = glyphs
    }

    func update(_ next: DexLogModel) {
        guard next != model else { return }
        model = next
        laid = nil
        hoverNode = nil
        pendingDirty = nil
        onChange?()
    }

    /// Back to the top (a changed filter, search or sort shows the new result from its start).
    func scrollToTop() {
        guard scrollY != 0 else { return }
        scrollY = 0
        pendingDirty = nil
        onChange?()
    }

    // MARK: layout

    private struct Fonts {
        let title = PlazaFont.system(size: 12, weight: .semibold), total = PlazaFont.system(size: 10, weight: .regular)
        let badge = PlazaFont.system(size: 10, weight: .bold), nature = PlazaFont.system(size: 11, weight: .regular)
        let name = PlazaFont.system(size: 11, weight: .regular), shiny = PlazaFont.system(size: 10, weight: .regular)
        let empty = PlazaFont.system(size: 12, weight: .semibold), button = PlazaFont.system(size: 11, weight: .regular)
    }

    private func layout(width: CGFloat, painter p: DexPainter) -> Layout {
        let f = Fonts()
        let titleH = p.metrics(f.title).height, totalH = p.metrics(f.total).height
        let rowH = max(titleH, totalH)
        let title = CGRect(x: 0, y: (rowH - titleH) / 2, width: ceil(p.line(model.title, f.title).width), height: titleH)
        let total = CGRect(x: title.maxX + 6, y: (rowH - totalH) / 2, width: ceil(p.line(model.total, f.total).width), height: totalH)
        var y = rowH + DexBodyPart.rowGap
        var x: CGFloat = 0
        var chips: [CGRect] = []
        var chipH: CGFloat = 0
        for chip in model.rarities {
            let s = p.chipSize(DexPainter.spec(chip))
            chips.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + DexPainter.chipGap + 1
            chipH = max(chipH, s.height)
        }
        let content = max(0, x - DexPainter.chipGap - 1)
        let shift = min(max(0, rarityScroll), max(0, content - width))
        chips = chips.map { $0.offsetBy(dx: -shift, dy: 0) }
        let chipViewport = CGRect(x: 0, y: y, width: width, height: chipH)
        y += chipH + Self.headerGap
        let viewport = CGRect(x: 0, y: y, width: width, height: max(0, height - y))
        var out = Layout(size: CGSize(width: width, height: height), title: title, total: total, chips: chips, viewport: viewport,
                         chipViewport: chipViewport, chipContent: content, rows: [], contentHeight: 0)
        if model.rows.isEmpty {
            let textLine = p.line(model.noResults, f.empty)
            let textH = p.metrics(f.empty).height
            let bw = ceil(p.line(model.clearFilters, f.button).width) + 20, bh = p.metrics(f.button).height + 8
            let total = 24 + 8 + textH + 8 + bh
            let top = viewport.minY + (viewport.height - total) / 2
            out.empty = (CGRect(x: (width - 24) / 2, y: top, width: 24, height: 24),
                         CGRect(x: (width - ceil(textLine.width)) / 2, y: top + 32, width: ceil(textLine.width), height: textH),
                         CGRect(x: (width - bw) / 2, y: top + 32 + textH + 8, width: bw, height: bh))
            return out
        }
        let cardW = width - Self.lane
        let colW = Self.thumb + DexLayoutConstants.nameSlack
        let nameH = p.metrics(f.name).height
        let badgeH = p.metrics(f.badge).height + 2
        var rowY: CGFloat = 0
        for row in model.rows {
            let badges = max(badgeH, p.metrics(f.nature).height)
            var names: [[PlazaTextLine]] = []
            var namesMax: CGFloat = 0
            for node in row.nodes {
                let lines = p.wrapped(node.name, f.name, width: colW, maxLines: 2)
                names.append(lines)
                namesMax = max(namesMax, CGFloat(lines.count) * nameH)
            }
            let chain = Self.thumb + 1 + namesMax
            var h = Self.cardPadding * 2 + badges + 3 + chain
            if row.caughtAt != nil { h += 3 + p.metrics(f.nature).height }
            out.rows.append(RowLayout(y: rowY, height: h, badges: badges, nameLines: names, namesHeight: namesMax, chainHeight: chain))
            rowY += h + Self.rowGap
        }
        out.contentHeight = max(0, rowY - Self.rowGap)
        _ = cardW
        return out
    }

    var maxScroll: CGFloat { max(0, (laid?.contentHeight ?? 0) - (laid?.viewport.height ?? 0)) }

    private func nodeX(_ row: DexLogRowModel, _ i: Int, cardX: CGFloat) -> CGFloat {
        // the chain is centred? No: HStack leading, inside the card's padding
        cardX + Self.cardPadding + CGFloat(i) * (Self.thumb + DexLayoutConstants.nameSlack + Self.thumb * EvoLineLayout.arrowRatio + EvoLineLayout.spacing * 2)
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        if width != self.width { laid = nil }
        self.width = width
        return CGSize(width: width, height: height)
    }

    /// The visible rows: indices with their top in part coordinates.
    private func visibleRows(_ lay: Layout) -> [(index: Int, top: CGFloat)] {
        var out: [(Int, CGFloat)] = []
        for (i, r) in lay.rows.enumerated() {
            let top = lay.viewport.minY + r.y - scrollY
            if top + r.height < lay.viewport.minY { continue }
            if top > lay.viewport.maxY { break }
            out.append((i, top))
        }
        return out
    }

    private func sprite(_ lay: Layout, row: Int, node: Int, top: CGFloat) -> CGRect {
        let m = model.rows[row]
        let x = nodeX(m, node, cardX: 0) + DexLayoutConstants.nameSlack / 2
        return CGRect(x: x, y: top + Self.cardPadding + lay.rows[row].badges + 3, width: Self.thumb, height: Self.thumb)
    }

    private func column(_ lay: Layout, row: Int, node: Int, top: CGFloat) -> CGRect {
        let m = model.rows[row]
        return CGRect(x: nodeX(m, node, cardX: 0), y: top + Self.cardPadding + lay.rows[row].badges + 3,
                      width: Self.thumb + DexLayoutConstants.nameSlack, height: lay.rows[row].chainHeight)
    }

    var spriteSlots: [SpriteSlot] {
        guard let lay = laid, !model.rows.isEmpty else { return [] }
        var slots: [SpriteSlot] = []
        for (i, top) in visibleRows(lay) {
            let row = model.rows[i]
            for (n, node) in row.nodes.enumerated() {
                let r = sprite(lay, row: i, node: n, top: top)
                guard r.maxY > lay.viewport.minY, r.minY < lay.viewport.maxY else { continue }
                slots.append(SpriteSlot(frame: r, subject: PlazaSpriteSubjectKey(speciesID: node.speciesID, shiny: row.isShiny, form: row.form, back: false),
                                        bob: false, animated: false))
            }
        }
        return slots
    }

    /// The next instant a visible caught-time text reads differently (the host arms its clock there); nil: none visible.
    func nextDeadline() -> Date? {
        guard let lay = laid else { return nil }
        let current = now()
        return visibleRows(lay).compactMap { model.rows[$0.index].caughtAt }.map { RelativeTimeText.nextChange(for: $0, now: current, coarse: true) }.min()
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let p = DexPainter(text: graphics.text, glyphs: glyphs, scale: scale)
        let lay = laid ?? layout(width: width, painter: p)
        laid = lay
        scrollY = min(max(0, scrollY), maxScroll)
        let f = Fonts()
        let space = PlazaPanelSpace(content: lay.size, room: 0)
        let primary = PopoverColorRole.primary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        let accent = self.accent
        let model = self.model
        let current = now()
        let language = self.language
        let visible = visibleRows(lay)
        var items: [PlazaAccessibilityItem] = [], tips: [PlazaTooltip] = []
        let hoverNode = self.hoverNode
        let picture = space.image(scale: scale, graphics: graphics) { canvas in MainActor.assumeIsolated {
            p.draw(model.title, f.title, color: primary, x: lay.title.minX, centerY: lay.title.midY, canvas: canvas, space: space)
            p.draw(model.total, f.total, color: secondary, x: lay.total.minX, centerY: lay.total.midY, canvas: canvas, space: space)
            canvas.saveState()
            canvas.clip(to: space.canvas(lay.chipViewport))
            for (chip, r) in zip(model.rarities, lay.chips) where r.maxX > 0 && r.minX < lay.size.width {
                p.drawChip(DexPainter.spec(chip), in: r, canvas: canvas, space: space)
            }
            canvas.restoreState()
            if let e = lay.empty {
                p.drawGlyph("magnifyingglass", fallback: "⌕", size: 24, bold: false, color: PopoverColorRole.tertiary.plazaColor(), in: e.icon, canvas: canvas, space: space)
                p.draw(model.noResults, f.empty, color: secondary, x: e.text.minX, centerY: e.text.midY, canvas: canvas, space: space)
                p.roundedRect(e.button, radius: 5, fill: PopoverAppearance.current.controlFill(alpha: 0.9),
                              stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                let w = ceil(p.line(model.clearFilters, f.button).width)
                p.draw(model.clearFilters, f.button, color: primary, x: e.button.midX - w / 2, centerY: e.button.midY, canvas: canvas, space: space)
                return
            }
            canvas.saveState()
            canvas.clip(to: space.canvas(lay.viewport))
            let cardW = lay.size.width - Self.lane
            for (i, top) in visible {
                let row = model.rows[i], rl = lay.rows[i]
                let card = CGRect(x: 0, y: top, width: cardW, height: rl.height)
                p.roundedRect(card, radius: 10, fill: PopoverColorRole.secondary.plazaTileColor(alpha: 0.06), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                // badges
                var x = card.minX + Self.cardPadding
                let cy = card.minY + Self.cardPadding + rl.badges / 2
                @MainActor func badge(_ text: String, tint: PlazaColor, solid: Bool) {
                    let s = p.badgeSize(text, size: 10)
                    p.badge(text, size: 10, tint: tint, solid: solid, in: CGRect(x: x, y: cy - s.height / 2, width: s.width, height: s.height), canvas: canvas, space: space)
                    x += s.width + 8
                }
                badge(row.rarityText, tint: CompanionBadges.rarityColor(row.rarity).plazaColor(), solid: true)
                if row.isRaising { badge(row.raisingText, tint: accent, solid: false) }
                else if row.isReleased { badge(row.releasedText, tint: PopoverColorRole.secondary.plazaColor(), solid: false) }
                if row.isShiny { p.draw("✨", .emoji(size: 10), color: .white, x: x, centerY: cy, canvas: canvas, space: space) }
                if let nature = row.nature {
                    let w = ceil(p.line(nature, f.nature).width)
                    p.draw(nature, f.nature, color: secondary, x: card.maxX - Self.cardPadding - w, centerY: cy, canvas: canvas, space: space)
                }
                // the chain
                let nameH = p.metrics(f.name).height, nameA = p.metrics(f.name).ascender
                for (n, node) in row.nodes.enumerated() {
                    let col = self.column(lay, row: i, node: n, top: top)
                    if hoverNode?.row == i, hoverNode?.node == n, node.link != nil {
                        p.roundedRect(col, radius: 6, fill: PopoverColorRole.primary.plazaShapeColor(alpha: 0.1), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                    }
                    if n > 0 {
                        let cell = Self.thumb * EvoLineLayout.arrowRatio
                        let ax = col.minX - EvoLineLayout.spacing - cell
                        p.drawGlyph("arrow.right", fallback: "→", size: Self.thumb * 0.2, bold: false, color: PopoverColorRole.tertiary.plazaColor(),
                                    in: CGRect(x: ax, y: col.minY + Self.thumb * 0.4, width: cell, height: Self.thumb * 0.2 + 4), canvas: canvas, space: space)
                    }
                    canvas.setFillColor(secondary)
                    for (k, line) in rl.nameLines[n].enumerated() {
                        let lx = col.midX - line.width / 2
                        canvas.draw(line, at: space.canvas(CGPoint(x: lx, y: col.minY + Self.thumb + 1 + CGFloat(k) * nameH + nameA)))
                    }
                }
                if let at = row.caughtAt {
                    let text = RelativeTimeText.text(for: at, now: current, language: language, coarse: true)
                    p.draw(text, f.nature, color: secondary, x: card.minX + Self.cardPadding, centerY: card.maxY - Self.cardPadding - p.metrics(f.nature).height / 2,
                           canvas: canvas, space: space)
                }
            }
            canvas.restoreState()
            // the scroll thumb in the lane
            if let t = self.thumbRect(lay) {
                p.capsule(t, fill: PopoverColorRole.primary.plazaShapeColor(alpha: self.dragStart == nil ? 0.28 : 0.45), stroke: nil, lineWidth: 0, canvas: canvas, space: space)
            }
        } }
        // items
        items.append(PlazaAccessibilityItem(frame: lay.title, role: .staticText, label: model.title))
        items.append(PlazaAccessibilityItem(frame: lay.total, role: .staticText, label: model.total))
        for (i, (chip, r)) in zip(model.rarities, lay.chips).enumerated() {
            let v = r.intersection(lay.chipViewport)
            guard !v.isNull, v.width > 2 else { continue }
            items.append(PlazaAccessibilityItem(frame: v, role: .button, label: "\(chip.label) \(chip.count)", value: chip.isSelected ? "✓" : nil,
                                                action: PlazaPanelHit(action: Self.rarityAction, index: i), key: "lrarity-\(chip.rarity.rawValue)", isEnabled: chip.isEnabled))
            tips.append(PlazaTooltip(frame: v, text: chip.help))
        }
        if let e = lay.empty {
            items.append(PlazaAccessibilityItem(frame: e.text, role: .staticText, label: model.noResults))
            items.append(PlazaAccessibilityItem(frame: e.button, role: .button, label: model.clearFilters, action: PlazaPanelHit(action: Self.clearAction, index: nil), key: "lclear"))
        } else {
            for (i, top) in visible {
                let row = model.rows[i]
                for (n, node) in row.nodes.enumerated() {
                    let col = column(lay, row: i, node: n, top: top).intersection(lay.viewport)
                    guard let target = node.link, !col.isNull, col.height > 4 else { continue }
                    items.append(PlazaAccessibilityItem(frame: col, role: .button, label: "\(node.name), \(row.openHint)",
                                                        action: PlazaPanelHit(action: Self.nodeAction, index: i, target: target), key: "node-\(row.id)-\(n)"))
                    tips.append(PlazaTooltip(frame: col, text: row.openHint))
                }
            }
        }
        let layers: [PlazaPanelLayer] = picture.map { [.image($0, frame: CGRect(origin: .zero, size: lay.size))] } ?? []
        var d = PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips), spriteSlots: spriteSlots)
        d.dirty = pendingDirty
        pendingDirty = nil
        return d
    }

    // MARK: input

    func thumbRect(_ lay: Layout) -> CGRect? {
        let max = maxScroll
        guard max > 0, lay.viewport.height > 0 else { return nil }
        let track = lay.viewport.height
        let h = Swift.max(24, track * lay.viewport.height / lay.contentHeight)
        let y = lay.viewport.minY + (track - h) * (scrollY / max)
        return CGRect(x: lay.size.width - 7, y: y, width: 4, height: h)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let lay = laid else { return nil }
        if let e = lay.empty { return e.button.contains(point) ? PlazaPanelHit(action: Self.clearAction, index: nil) : nil }
        if let t = thumbRect(lay), t.insetBy(dx: -4, dy: 0).contains(point) {
            if dragStart == nil { dragStart = (point.y, scrollY) }
            return PlazaPanelHit(action: Self.thumbAction, index: nil)
        }
        for (i, r) in lay.chips.enumerated() where r.contains(point) && lay.chipViewport.contains(point) && model.rarities[i].isEnabled {
            return PlazaPanelHit(action: Self.rarityAction, index: i)
        }
        if let (row, node) = node(at: point), let target = model.rows[row].nodes[node].link {
            return PlazaPanelHit(action: Self.nodeAction, index: row, target: target)
        }
        return nil
    }

    /// The button released (the host reports every press); ends a thumb drag.
    func endDrag() { dragStart = nil }

    func node(at point: CGPoint) -> (row: Int, node: Int)? {
        guard let lay = laid, lay.viewport.contains(point), lay.empty == nil else { return nil }
        for (i, top) in visibleRows(lay) {
            for n in model.rows[i].nodes.indices where column(lay, row: i, node: n, top: top).contains(point) { return (i, n) }
        }
        return nil
    }

    func setPointer(_ point: CGPoint?) {
        if let start = dragStart, let point, let lay = laid, maxScroll > 0 {
            let track = lay.viewport.height
            let h = Swift.max(24, track * lay.viewport.height / lay.contentHeight)
            let ratio = (point.y - start.pointY) / Swift.max(1, track - h)
            let next = min(max(0, start.scrollY + ratio * maxScroll), maxScroll)
            if next != scrollY { scrollY = next; pendingDirty = nil; onChange?() }
            return
        }
        let found = point.flatMap { node(at: $0) }
        let linked = found.flatMap { model.rows[$0.row].nodes[$0.node].link != nil ? $0 : nil }
        guard linked?.row != hoverNode?.row || linked?.node != hoverNode?.node else { return }
        var dirty = CGRect.null
        if let lay = laid {
            for h in [hoverNode, linked].compactMap({ $0 }) {
                if let top = visibleRows(lay).first(where: { $0.index == h.row })?.top { dirty = dirty.union(column(lay, row: h.row, node: h.node, top: top).insetBy(dx: -2, dy: -2)) }
            }
        }
        hoverNode = linked
        pendingDirty = dirty.isNull ? nil : dirty
        onChange?()
    }

    /// Scrolls the list by `dy` DIP (positive: down); true when it moved.
    @discardableResult
    func scroll(by dy: CGFloat) -> Bool {
        let next = min(max(0, scrollY + dy), maxScroll)
        guard next != scrollY else { return false }
        scrollY = next
        hoverNode = nil
        pendingDirty = nil
        onChange?()
        return true
    }

    /// Scrolls the rarity chips sideways when the pointer is over them.
    @discardableResult
    func scrollChips(at point: CGPoint, by dx: CGFloat) -> Bool {
        guard let lay = laid, lay.chipViewport.contains(point) else { return false }
        let next = min(max(0, rarityScroll + dx), max(0, lay.chipContent - lay.chipViewport.width))
        guard next != rarityScroll else { return false }
        rarityScroll = next
        laid = nil
        pendingDirty = nil
        onChange?()
        return true
    }

    func isOverList(_ point: CGPoint) -> Bool { laid?.viewport.contains(point) ?? false }
    var viewportHeight: CGFloat { laid?.viewport.height ?? 0 }

    /// A key on a chain node's button: the list scrolls (the Mac's `ScrollView` keys).
    func key(_ vk: Int) -> Bool {
        let page = max(40, viewportHeight - 40)
        switch vk {
        case 0x26: return scroll(by: -40)       // VK_UP
        case 0x28: return scroll(by: 40)        // VK_DOWN
        case 0x21: return scroll(by: -page)     // VK_PRIOR
        case 0x22: return scroll(by: page)      // VK_NEXT
        case 0x24: return scroll(by: -.greatestFiniteMagnitude)   // VK_HOME
        case 0x23: return scroll(by: .greatestFiniteMagnitude)    // VK_END
        default: return false
        }
    }

    /// Scrolls so the entry `id` is centred (Back from a detail page: `scrollTo(anchor, .center)`).
    func reveal(entryID id: String) {
        guard let lay = laid, let i = model.rows.firstIndex(where: { $0.id == id }) else { return }
        let r = lay.rows[i]
        let next = min(max(0, r.y + r.height / 2 - lay.viewport.height / 2), maxScroll)
        guard next != scrollY else { return }
        scrollY = next
        pendingDirty = nil
        onChange?()
    }
}

/// The evolution line's constants the log's chain shares with `EvoLineLayout` (its private `nameSlack`).
enum DexLayoutConstants {
    static let nameSlack: CGFloat = EvoLineLayout.nameSlack
}
