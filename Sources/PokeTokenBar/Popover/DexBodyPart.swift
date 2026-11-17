import Foundation

// MARK: Task 20 — the Pokédex page as a drawn part (the Mac's `DexGridView`: header, region and rarity chips, the 4 × 4 grid,
// the footer, the no-results state)

/// What a key on a grid cell does (`DexBodyPart.key`): the focus goes to another cell, or the page turns.
enum DexKeyMove: Equatable {
    case focusCell(Int)
    case page(Int)
}

/// The Pokédex grid page, one picture and its button items. Cells, chips, the footer's buttons and the page arrows are
/// button items (a Tab stop each; their press is the item's hit); the sprites are slots left to the host's animator (still,
/// 56 pt, as the Mac's "static so a full page does not animate"). The page is one `PopoverPart`, so a full dex costs one
/// window plus at most 16 cells and the chips, whatever the dex holds: paging is the virtualisation.
///
/// Hits (`PlazaPanelHit.action`): `dex.cell` (index = the cell on this page), `dex.region`, `dex.rarity` (index = the chip),
/// `dex.prev`, `dex.next`, `dex.rep`, `dex.clear`.
@MainActor final class DexBodyPart: PopoverPart {
    static let cellAction = "dex.cell", regionAction = "dex.region", rarityAction = "dex.rarity"
    static let prevAction = "dex.prev", nextAction = "dex.next", repAction = "dex.rep", clearAction = "dex.clear"
    static let thumb: CGFloat = 56
    static let rowGap: CGFloat = 5          // header VStack(spacing: 5)
    static let gridGap: CGFloat = 6         // the page's VStack(spacing: 6)
    static let footerHeight: CGFloat = 18
    static let pageButton: CGFloat = 28     // DexPageButton.hitSize
    static let pageEdgeInset: CGFloat = 10  // DexPageButton.edgeInset
    static let hoverScale: CGFloat = 1.04

    var onChange: (() -> Void)?
    private(set) var model: DexBodyModel
    /// The part's height (DIP): what the page leaves under the segment and the filter bar.
    var height: CGFloat
    weak var glyphs: (any PopoverGlyphRaster)?
    var accent: PlazaColor
    private(set) var hoverCell: Int?
    private(set) var regionScroll: CGFloat = 0, rarityScroll: CGFloat = 0
    private(set) var laid: Layout?
    /// The region a hover changes (DIP), for the host's partial repaint; consumed by `render`.
    private var pendingDirty: CGRect?

    init(_ model: DexBodyModel, height: CGFloat, accent: PlazaColor = PopoverColorRole.accent.plazaColor(), glyphs: (any PopoverGlyphRaster)? = nil) {
        self.model = model
        self.height = height
        self.accent = accent
        self.glyphs = glyphs
    }

    func update(_ next: DexBodyModel) {
        guard next != model else { return }
        let oldCells = model.cells.count
        model = next
        if next.cells.count != oldCells || hoverCell.map({ $0 >= next.cells.count }) == true { hoverCell = nil }
        pendingDirty = nil
        onChange?()
    }

    // MARK: layout

    struct Strip {
        var viewport: CGRect
        var chips: [CGRect]      // already scrolled, not clipped
        var contentWidth: CGFloat
        var maxScroll: CGFloat { max(0, contentWidth - viewport.width) }
    }

    struct Layout {
        var size: CGSize
        var title: CGRect, total: CGRect
        var medals: [CGRect]
        var regions: Strip, rarities: Strip
        var gridTop: CGFloat
        var cells: [CGRect]
        var footerTop: CGFloat
        var selection: CGRect?, rep: CGRect?
        var prev: CGRect?, next: CGRect?, pageText: CGRect?
        var emptyIcon: CGRect?, emptyText: CGRect?, emptyButton: CGRect?
    }

    private func fonts() -> (title: PlazaFont, total: PlazaFont, medal: PlazaFont, sel: PlazaFont, page: PlazaFont, empty: PlazaFont, button: PlazaFont) {
        (.system(size: 12, weight: .semibold), .system(size: 10, weight: .regular), .emoji(size: 12), .system(size: 11, weight: .regular),
         .system(size: 12, weight: .semibold), .system(size: 12, weight: .semibold), .system(size: 11, weight: .regular))
    }

    func layout(width: CGFloat, painter p: DexPainter) -> Layout {
        let f = fonts()
        let titleLine = p.line(model.title, f.title), totalLine = p.line(model.total, f.total)
        let titleH = p.metrics(f.title).height, totalH = p.metrics(f.total).height
        let medalH = p.metrics(f.medal).height + 4
        let rowH = max(titleH, totalH, model.medals.isEmpty ? 0 : medalH)
        var y: CGFloat = 0
        let title = CGRect(x: 0, y: y + (rowH - titleH) / 2, width: ceil(titleLine.width), height: titleH)
        let total = CGRect(x: title.maxX + 6, y: y + (rowH - totalH) / 2, width: ceil(totalLine.width), height: totalH)
        var medals: [CGRect] = []
        var mx = width
        for m in model.medals.reversed() {
            let w = ceil(p.line(m.emoji, f.medal).width) + 10
            mx -= w
            medals.insert(CGRect(x: mx, y: y + (rowH - medalH) / 2, width: w, height: medalH), at: 0)
            mx -= 3
        }
        y += rowH + Self.rowGap
        func strip(_ specs: [DexChipSpec], scroll: CGFloat) -> Strip {
            var x: CGFloat = 0
            var sizes: [CGSize] = []
            for s in specs { sizes.append(p.chipSize(s)) }
            let h = sizes.map(\.height).max() ?? 0
            var raw: [CGRect] = []
            for s in sizes { raw.append(CGRect(x: x, y: y, width: s.width, height: s.height)); x += s.width + DexPainter.chipGap + 1 }
            let content = max(0, x - DexPainter.chipGap - 1)
            let viewport = CGRect(x: 0, y: y, width: width, height: h)
            let clamped = min(max(0, scroll), max(0, content - width))
            return Strip(viewport: viewport, chips: raw.map { $0.offsetBy(dx: -clamped, dy: 0) }, contentWidth: content)
        }
        let regionStrip = strip(model.regions.map { DexPainter.spec($0) }, scroll: regionScroll)
        y += regionStrip.viewport.height + Self.rowGap
        let rarityStrip = strip(model.rarities.map { DexPainter.spec($0) }, scroll: rarityScroll)
        y += rarityStrip.viewport.height
        let gridTop = y + Self.gridGap
        var out = Layout(size: CGSize(width: width, height: height), title: title, total: total, medals: medals, regions: regionStrip,
                         rarities: rarityStrip, gridTop: gridTop, cells: [], footerTop: height - Self.footerHeight)
        if model.isEmpty {
            // VStack { Spacer; icon 24, text callout.medium, bordered small button; Spacer }
            let iconH: CGFloat = 24
            let textLine = p.line(model.noResults, f.empty)
            let textH = p.metrics(f.empty).height
            let bw = ceil(p.line(model.clearFilters, f.button).width) + 20, bh = p.metrics(f.button).height + 8
            let total = iconH + 8 + textH + 8 + bh
            let top = gridTop + (height - gridTop - total) / 2
            out.emptyIcon = CGRect(x: (width - 24) / 2, y: top, width: 24, height: iconH)
            out.emptyText = CGRect(x: (width - ceil(textLine.width)) / 2, y: top + iconH + 8, width: ceil(textLine.width), height: textH)
            out.emptyButton = CGRect(x: (width - bw) / 2, y: top + iconH + 8 + textH + 8, width: bw, height: bh)
            return out
        }
        let gridH = out.footerTop - Self.gridGap - gridTop
        let cw = (width - CGFloat(DexPaging.columns - 1) * DexPaging.spacing) / CGFloat(DexPaging.columns)
        let ch = (gridH - CGFloat(DexPaging.rows - 1) * DexPaging.spacing) / CGFloat(DexPaging.rows)
        out.cells = model.cells.indices.map { i in
            CGRect(x: CGFloat(i % DexPaging.columns) * (cw + DexPaging.spacing), y: gridTop + CGFloat(i / DexPaging.columns) * (ch + DexPaging.spacing),
                   width: cw, height: ch)
        }
        // the footer
        let ft = out.footerTop
        var pagerLeft = width
        if let text = model.footer.pageText {
            let pageLine = p.line(text, f.page)
            let tw = ceil(pageLine.width), th = p.metrics(f.page).height
            let bw = Self.pageButton
            let total = bw + tw + bw
            let x0 = width - total + Self.pageEdgeInset
            let cy = ft + Self.footerHeight / 2
            out.prev = CGRect(x: x0, y: cy - bw / 2, width: bw, height: bw)
            out.pageText = CGRect(x: x0 + bw, y: cy - th / 2, width: tw, height: th)
            out.next = CGRect(x: x0 + bw + tw, y: cy - bw / 2, width: bw, height: bw)
            pagerLeft = x0
        }
        if let sel = model.footer.selection {
            var x: CGFloat = 0
            let repW: CGFloat = 24
            let hasRep = sel.representativeTitle != nil
            let room = max(20, pagerLeft - 4 - (hasRep ? repW + 8 : 0) - 8)
            let line = p.line(sel.text, f.sel)
            let w = min(ceil(line.width), room)
            let th = p.metrics(f.sel).height
            out.selection = CGRect(x: x, y: ft + (Self.footerHeight - th) / 2, width: w, height: th)
            x += w + 8
            if hasRep { out.rep = CGRect(x: x, y: ft + (Self.footerHeight - 18) / 2, width: repW, height: 18) }
        }
        return out
    }

    // MARK: PopoverPart

    private var width: CGFloat = 332

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: height)
    }

    private struct Content { var sprite: CGRect; var name: CGRect; var lines: [PlazaTextLine]; var lineHeight: CGFloat; var ascender: CGFloat }

    private func content(_ cell: CGRect, _ model: DexCellModel, _ p: DexPainter) -> Content {
        let font = PlazaFont.system(size: 12, weight: .regular)
        let m = p.metrics(font)
        let lines = p.wrapped(model.label, font, width: cell.width - 4, maxLines: 2)
        let total = Self.thumb + 1 + 2 * m.height
        let top = cell.minY + (cell.height - total) / 2
        return Content(sprite: CGRect(x: cell.midX - Self.thumb / 2, y: top, width: Self.thumb, height: Self.thumb),
                       name: CGRect(x: cell.minX + 2, y: top + Self.thumb + 1, width: cell.width - 4, height: 2 * m.height),
                       lines: lines, lineHeight: m.height, ascender: m.ascender)
    }

    var spriteSlots: [SpriteSlot] {
        guard let lay = laid, lay.cells.count == model.cells.count else { return [] }
        return model.cells.enumerated().map { i, cell in
            let cellRect = lay.cells[i]
            var sprite = CGRect(x: cellRect.midX - Self.thumb / 2, y: contentTop(cellRect), width: Self.thumb, height: Self.thumb)
            if hoverCell == i {   // scaleEffect(1.04) about the cell's centre
                let s = Self.hoverScale
                let c = CGPoint(x: cellRect.midX + (sprite.midX - cellRect.midX) * s, y: cellRect.midY + (sprite.midY - cellRect.midY) * s)
                sprite = CGRect(x: c.x - sprite.width * s / 2, y: c.y - sprite.height * s / 2, width: sprite.width * s, height: sprite.height * s)
            }
            return SpriteSlot(frame: sprite, subject: PlazaSpriteSubjectKey(speciesID: cell.number, shiny: cell.spriteShiny, form: nil, back: false),
                              bob: false, animated: false)
        }
    }

    private var lineH: CGFloat = 15
    private func contentTop(_ cell: CGRect) -> CGFloat {
        cell.minY + (cell.height - (Self.thumb + 1 + 2 * lineH)) / 2
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let p = DexPainter(text: graphics.text, glyphs: glyphs, scale: scale)
        lineH = p.metrics(.system(size: 12, weight: .regular)).height
        let lay = layout(width: width, painter: p)
        laid = lay
        let f = fonts()
        let space = PlazaPanelSpace(content: lay.size, room: 0)
        let primary = PopoverColorRole.primary.plazaColor(), secondary = PopoverColorRole.secondary.plazaColor()
        let accent = self.accent
        let model = self.model
        var items: [PlazaAccessibilityItem] = [], tips: [PlazaTooltip] = []
        let picture = space.image(scale: scale, graphics: graphics) { canvas in MainActor.assumeIsolated {
            // header
            p.draw(model.title, f.title, color: primary, x: lay.title.minX, centerY: lay.title.midY, canvas: canvas, space: space)
            p.draw(model.total, f.total, color: secondary, x: lay.total.minX, centerY: lay.total.midY, canvas: canvas, space: space)
            let yellow = PopoverColorRole.systemYellow.plazaColor()
            for (m, r) in zip(model.medals, lay.medals) {
                p.capsule(r, fill: DexPainter.tint(yellow, 0.14), stroke: DexPainter.tint(yellow, 0.5), lineWidth: 0.5, canvas: canvas, space: space)
                p.draw(m.emoji, f.medal, color: .white, x: r.minX + 5, centerY: r.midY, canvas: canvas, space: space)
            }
            @MainActor func chips(_ strip: Strip, _ specs: [DexChipSpec]) {
                canvas.saveState()
                canvas.clip(to: space.canvas(strip.viewport))
                for (spec, r) in zip(specs, strip.chips) where r.maxX > 0 && r.minX < lay.size.width { p.drawChip(spec, in: r, canvas: canvas, space: space) }
                canvas.restoreState()
            }
            chips(lay.regions, model.regions.map { DexPainter.spec($0) })
            chips(lay.rarities, model.rarities.map { DexPainter.spec($0) })
            if model.isEmpty {
                if let r = lay.emptyIcon {
                    p.drawGlyph("magnifyingglass", fallback: "⌕", size: 24, bold: false, color: PopoverColorRole.tertiary.plazaColor(), in: r, canvas: canvas, space: space)
                }
                if let r = lay.emptyText { p.draw(model.noResults, f.empty, color: secondary, x: r.minX, centerY: r.midY, canvas: canvas, space: space) }
                if let r = lay.emptyButton {
                    p.roundedRect(r, radius: 5, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9),
                                  stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                    let w = ceil(p.line(model.clearFilters, f.button).width)
                    p.draw(model.clearFilters, f.button, color: primary, x: r.midX - w / 2, centerY: r.midY, canvas: canvas, space: space)
                }
                return
            }
            // the hovered cell last: its lift and shadow lie over its neighbours
            let order = model.cells.indices.filter { $0 != hoverCell } + (hoverCell.map { [$0] } ?? [])
            for i in order { self.drawCell(i, lay, p, canvas: canvas, space: space, accent: accent) }
            // footer
            if let r = lay.selection, let sel = model.footer.selection {
                var line = p.line(sel.text, f.sel)
                if line.width > r.width, let cut = p.text.truncated(line, width: r.width, ellipsis: p.line("…", f.sel)) { line = cut }
                canvas.setFillColor(secondary)
                let m = p.metrics(f.sel)
                canvas.draw(line, at: space.canvas(CGPoint(x: r.minX, y: r.minY + m.ascender)))
            }
            if let r = lay.rep, let sel = model.footer.selection {
                p.roundedRect(r, radius: 5, fill: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9),
                              stroke: PopoverColorRole.secondary.plazaShapeColor(alpha: 0.4), lineWidth: 0.5, canvas: canvas, space: space)
                p.drawGlyph(sel.isRepresentative ? "arrow.triangle.2.circlepath" : "star", fallback: sel.isRepresentative ? "↻" : "☆", size: 10, bold: false,
                            color: primary, in: r, canvas: canvas, space: space)
            }
            if let r = lay.pageText, let text = model.footer.pageText {
                p.draw(text, f.page, color: secondary, x: r.minX, centerY: r.midY, canvas: canvas, space: space)
                let fp = model.footer
                for (rect, forward, enabled) in [(lay.prev, false, fp.current > 0), (lay.next, true, fp.current < fp.pageCount - 1)] {
                    guard let rect else { continue }
                    p.drawGlyph(forward ? "chevron.right" : "chevron.left", fallback: forward ? "›" : "‹", size: 13, bold: true,
                                color: enabled ? primary : PopoverColorRole.tertiary.plazaColor(), in: rect, canvas: canvas, space: space)
                }
            }
        } }
        // overlays: the tags over the sprites
        let overlay = model.isEmpty ? nil : space.image(scale: scale, graphics: graphics) { canvas in MainActor.assumeIsolated {
            for i in model.cells.indices { self.drawCellOverlay(i, lay, p, canvas: canvas, space: space, accent: accent) }
        } }
        // items
        func clamp(_ r: CGRect) -> CGRect { r.intersection(CGRect(x: 0, y: -100, width: lay.size.width, height: lay.size.height + 200)) }
        items.append(PlazaAccessibilityItem(frame: lay.title, role: .staticText, label: model.title))
        items.append(PlazaAccessibilityItem(frame: lay.total, role: .staticText, label: model.total))
        for (m, r) in zip(model.medals, lay.medals) {
            items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: m.help))
            tips.append(PlazaTooltip(frame: r, text: m.help))
        }
        for (i, (chip, r)) in zip(model.regions, lay.regions.chips).enumerated() {
            let v = r.intersection(lay.regions.viewport)
            guard !v.isNull, v.width > 2 else { continue }
            items.append(PlazaAccessibilityItem(frame: v, role: .button, label: "\(chip.label) \(chip.owned)/\(chip.total)", value: chip.isSelected ? "✓" : nil,
                                                action: PlazaPanelHit(action: Self.regionAction, index: i), key: "region-\(chip.region.rawValue)", isEnabled: chip.isEnabled))
            tips.append(PlazaTooltip(frame: v, text: chip.help))
        }
        for (i, (chip, r)) in zip(model.rarities, lay.rarities.chips).enumerated() {
            let v = r.intersection(lay.rarities.viewport)
            guard !v.isNull, v.width > 2 else { continue }
            items.append(PlazaAccessibilityItem(frame: v, role: .button, label: "\(chip.label) \(chip.count)", value: chip.isSelected ? "✓" : nil,
                                                action: PlazaPanelHit(action: Self.rarityAction, index: i), key: "rarity-\(chip.rarity.rawValue)", isEnabled: chip.isEnabled))
            tips.append(PlazaTooltip(frame: v, text: chip.help))
        }
        if model.isEmpty {
            if let r = lay.emptyText { items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: model.noResults)) }
            if let r = lay.emptyButton {
                items.append(PlazaAccessibilityItem(frame: r, role: .button, label: model.clearFilters, action: PlazaPanelHit(action: Self.clearAction, index: nil), key: "clear"))
            }
        } else {
            for (i, cell) in model.cells.enumerated() {
                let r = lay.cells[i]
                items.append(PlazaAccessibilityItem(frame: r, role: .button, label: cell.tooltip, action: PlazaPanelHit(action: Self.cellAction, index: i),
                                                    key: "cell-\(cell.collectionID)"))
                tips.append(PlazaTooltip(frame: r, text: cell.tooltip))
            }
            if let r = lay.selection, let sel = model.footer.selection { items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: sel.text)) }
            if let r = lay.rep, let title = model.footer.selection?.representativeTitle {
                items.append(PlazaAccessibilityItem(frame: r, role: .button, label: title, action: PlazaPanelHit(action: Self.repAction, index: nil), key: "rep"))
                tips.append(PlazaTooltip(frame: r, text: title))
            }
            if let r = lay.prev {
                items.append(PlazaAccessibilityItem(frame: clamp(r), role: .button, label: model.footer.previousLabel, action: PlazaPanelHit(action: Self.prevAction, index: nil),
                                                    key: "prev", isEnabled: model.footer.current > 0))
            }
            if let r = lay.pageText, let label = model.footer.pageLabel { items.append(PlazaAccessibilityItem(frame: r, role: .staticText, label: label)) }
            if let r = lay.next {
                items.append(PlazaAccessibilityItem(frame: clamp(r), role: .button, label: model.footer.nextLabel, action: PlazaPanelHit(action: Self.nextAction, index: nil),
                                                    key: "next", isEnabled: model.footer.current < model.footer.pageCount - 1))
            }
        }
        let layers: [PlazaPanelLayer] = picture.map { [.image($0, frame: CGRect(origin: .zero, size: lay.size))] } ?? []
        var d = PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips), spriteSlots: spriteSlots,
                               overlays: overlay.map { [.image($0, frame: CGRect(origin: .zero, size: lay.size))] } ?? [])
        d.dirty = pendingDirty
        pendingDirty = nil
        return d
    }

    // MARK: cells

    private func lifted(_ i: Int, _ lay: Layout, canvas: any PlazaCanvas, space: PlazaPanelSpace, _ body: () -> Void) {
        canvas.saveState()
        if hoverCell == i {
            let c = space.canvas(CGPoint(x: lay.cells[i].midX, y: lay.cells[i].midY))
            canvas.translate(x: c.x, y: c.y)
            canvas.scale(x: Self.hoverScale, y: Self.hoverScale)
            canvas.translate(x: -c.x, y: -c.y)
        }
        body()
        canvas.restoreState()
    }

    private func drawCell(_ i: Int, _ lay: Layout, _ p: DexPainter, canvas: any PlazaCanvas, space: PlazaPanelSpace, accent: PlazaColor) {
        let cell = model.cells[i], r = lay.cells[i]
        lifted(i, lay, canvas: canvas, space: space) {
            if hoverCell == i {   // the card's shadow, under the card only
                canvas.saveState()
                canvas.setShadow(PlazaShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)))
                canvas.setFillColor(PlazaColor.white)
                canvas.fillRoundedRect(space.canvas(r), radius: 8)
                canvas.restoreState()
            }
            let fill = cell.isRepresentative ? DexPainter.tint(accent, 0.16)
                : PopoverColorRole.secondary.plazaShapeColor(alpha: cell.isSelected ? 0.16 : 0.06)
            p.roundedRect(r, radius: 8, fill: fill, stroke: cell.isSelected ? accent : nil, lineWidth: 1.5, canvas: canvas, space: space)
            let c = content(r, cell, p)
            let font = PlazaFont.system(size: 12, weight: .regular)
            canvas.setFillColor(PopoverColorRole.primary.plazaColor())
            for (n, line) in c.lines.prefix(2).enumerated() {
                let x = c.name.midX - line.width / 2
                canvas.draw(line, at: space.canvas(CGPoint(x: x, y: c.name.minY + CGFloat(n) * c.lineHeight + c.ascender)))
            }
            _ = font
        }
    }

    private func drawCellOverlay(_ i: Int, _ lay: Layout, _ p: DexPainter, canvas: any PlazaCanvas, space: PlazaPanelSpace, accent: PlazaColor) {
        let cell = model.cells[i], r = lay.cells[i]
        lifted(i, lay, canvas: canvas, space: space) {
            // the number tag, top leading (the rarity's colour, a star when it is the representative)
            let tagFont = PlazaFont.system(size: 10, weight: .semibold)
            let numberLine = p.line("#\(cell.number)", tagFont)
            let tm = p.metrics(tagFont)
            let starW: CGFloat = cell.isRepresentative ? 8 + 2 : 0
            let tagW = ceil(numberLine.width) + starW + 4, tagH = tm.height
            let tag = CGRect(x: r.minX + 2, y: r.minY + 2, width: tagW, height: tagH)
            p.capsule(tag, fill: DexPainter.material, stroke: nil, lineWidth: 0, canvas: canvas, space: space)
            canvas.setFillColor(CompanionBadges.rarityColor(cell.rarity).plazaColor())
            canvas.draw(numberLine, at: space.canvas(CGPoint(x: tag.minX + 2, y: tag.minY + tm.ascender)))
            if cell.isRepresentative {
                p.drawGlyph("star.fill", fallback: "★", size: 8, bold: true, color: accent,
                            in: CGRect(x: tag.minX + 2 + ceil(numberLine.width) + 2, y: tag.minY, width: 8, height: tagH), canvas: canvas, space: space)
            }
            // ✨, top trailing
            if cell.isShiny {
                let ef = PlazaFont.emoji(size: 10)
                let ew = ceil(p.line("✨", ef).width) + 4, eh = p.metrics(ef).height
                let e = CGRect(x: r.maxX - 2 - ew, y: r.minY + 2, width: ew, height: eh)
                p.capsule(e, fill: DexPainter.material, stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                p.draw("✨", ef, color: .white, x: e.minX + 2, centerY: e.midY, canvas: canvas, space: space)
            }
            // RAISING, over the sprite's bottom
            if cell.isRaising {
                let text = raisingText
                let size = p.badgeSize(text, size: 10)
                let sprite = CGRect(x: r.midX - Self.thumb / 2, y: contentTop(r), width: Self.thumb, height: Self.thumb)
                let b = CGRect(x: sprite.midX - size.width / 2, y: sprite.maxY - size.height, width: size.width, height: size.height)
                p.capsule(b, fill: DexPainter.material, stroke: nil, lineWidth: 0, canvas: canvas, space: space)
                p.badge(text, size: 10, tint: accent, solid: false, in: b, canvas: canvas, space: space)
            }
        }
    }

    /// The RAISING badge's text (uppercased `dexRaising`), set by the host from the language.
    var raisingText = "RAISING"

    // MARK: input

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        guard let lay = laid else { return nil }
        if model.isEmpty {
            if let r = lay.emptyButton, r.contains(point) { return PlazaPanelHit(action: Self.clearAction, index: nil) }
            return nil
        }
        for (i, r) in lay.regions.chips.enumerated() where r.contains(point) && lay.regions.viewport.contains(point) && model.regions[i].isEnabled {
            return PlazaPanelHit(action: Self.regionAction, index: i)
        }
        for (i, r) in lay.rarities.chips.enumerated() where r.contains(point) && lay.rarities.viewport.contains(point) && model.rarities[i].isEnabled {
            return PlazaPanelHit(action: Self.rarityAction, index: i)
        }
        if let i = cellIndex(at: point) { return PlazaPanelHit(action: Self.cellAction, index: i) }
        if let r = lay.rep, r.contains(point) { return PlazaPanelHit(action: Self.repAction, index: nil) }
        if let r = lay.prev, r.contains(point), model.footer.current > 0 { return PlazaPanelHit(action: Self.prevAction, index: nil) }
        if let r = lay.next, r.contains(point), model.footer.current < model.footer.pageCount - 1 { return PlazaPanelHit(action: Self.nextAction, index: nil) }
        return nil
    }

    func cellIndex(at point: CGPoint) -> Int? {
        guard let lay = laid else { return nil }
        return lay.cells.firstIndex { $0.contains(point) }
    }

    /// The pointer over the part (DIP; nil: left): the cell under it lifts.
    func setPointer(_ point: CGPoint?) {
        let next = point.flatMap { cellIndex(at: $0) }
        guard next != hoverCell else { return }
        var dirty = CGRect.null
        if let lay = laid {
            for i in [hoverCell, next].compactMap({ $0 }) where i < lay.cells.count { dirty = dirty.union(lay.cells[i].insetBy(dx: -8, dy: -8)) }
        }
        hoverCell = next
        pendingDirty = dirty.isNull ? nil : dirty
        onChange?()
    }

    /// Scrolls the chip strip under `point` sideways by `dx` DIP (the wheel's horizontal part, or Shift + wheel); true when it moved.
    @discardableResult
    func scrollChips(at point: CGPoint, by dx: CGFloat) -> Bool {
        guard let lay = laid else { return false }
        if lay.regions.viewport.contains(point) {
            let next = min(max(0, regionScroll + dx), lay.regions.maxScroll)
            guard next != regionScroll else { return false }
            regionScroll = next
        } else if lay.rarities.viewport.contains(point) {
            let next = min(max(0, rarityScroll + dx), lay.rarities.maxScroll)
            guard next != rarityScroll else { return false }
            rarityScroll = next
        } else { return false }
        pendingDirty = nil
        onChange?()
        return true
    }

    /// Brings chip `index` of a strip fully into view (keyboard focus on a clipped chip).
    func reveal(region index: Int) { reveal(index, strip: true) }
    func reveal(rarity index: Int) { reveal(index, strip: false) }
    private func reveal(_ index: Int, strip regions: Bool) {
        guard let lay = laid else { return }
        let s = regions ? lay.regions : lay.rarities
        guard s.chips.indices.contains(index) else { return }
        let r = s.chips[index]
        var dx: CGFloat = 0
        if r.minX < 0 { dx = r.minX } else if r.maxX > s.viewport.width { dx = r.maxX - s.viewport.width }
        guard dx != 0 else { return }
        if regions { regionScroll = min(max(0, regionScroll + dx), s.maxScroll) } else { rarityScroll = min(max(0, rarityScroll + dx), s.maxScroll) }
        pendingDirty = nil
        onChange?()
    }

    /// The Mac has no keyboard model for the grid (each cell is a Button); on Windows the arrows move between the cells of the
    /// page, Home and End go to the first and last, Page Up and Page Down turn the page.
    func key(_ vk: Int, from index: Int) -> DexKeyMove? {
        let n = model.cells.count
        guard n > 0, (0..<n).contains(index) else { return nil }
        let columns = DexPaging.columns
        switch vk {
        case 0x25: return index % columns == 0 ? nil : .focusCell(index - 1)                       // VK_LEFT
        case 0x27: return index % columns == columns - 1 || index + 1 >= n ? nil : .focusCell(index + 1)   // VK_RIGHT
        case 0x26: return index - columns < 0 ? nil : .focusCell(index - columns)                  // VK_UP
        case 0x28: return index + columns >= n ? nil : .focusCell(index + columns)                 // VK_DOWN
        case 0x24: return .focusCell(0)                                                            // VK_HOME
        case 0x23: return .focusCell(n - 1)                                                        // VK_END
        case 0x21: return model.footer.current > 0 ? .page(-1) : nil                               // VK_PRIOR
        case 0x22: return model.footer.current < model.footer.pageCount - 1 ? .page(1) : nil       // VK_NEXT
        default: return nil
        }
    }
}
