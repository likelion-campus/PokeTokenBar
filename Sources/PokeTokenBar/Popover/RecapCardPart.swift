import Foundation

/// The recap card (stage 7 Task 13, D7; the Mac's `RecapCard`): a Pokédex readout in a red shell with a dark LCD, monospaced
/// digits and eight-segment meters. Its colours are fixed, as the Mac's are (`.environment(\.colorScheme, .light)`), so the card
/// looks the same in every appearance. Everything is drawn through the plaza canvas (rectangles, ellipses and text: UI chrome),
/// so the Mac (for the PR images and the tests) and Windows draw the same card; the digits use `PlazaFont.mono`. The companion
/// and the graduates are sprite slots the host fills.
///
/// Differences from the SwiftUI card, all in the shell's finish: the shell's vertical gradient is drawn as one-point stripes, the
/// lens's radial gradient as concentric discs, and the LCD's faint radial glow (7 % green in the corner) is left out.
///
/// Accessibility: the title, the total, the chip, each readout and the strip are static texts; each meter is one static text
/// with the bucket's description ("Thursday, Sep 10, 12,345" / "no data") that is also its tooltip, as the Mac's meters are.
@MainActor final class RecapCardPart: PopoverPart {
    // The Mac card's colours (explicit sRGB there too).
    static let shellTop = PlazaColor(srgbRed: 0.84, green: 0.21, blue: 0.18, alpha: 1)
    static let shellBottom = PlazaColor(srgbRed: 0.66, green: 0.12, blue: 0.11, alpha: 1)
    static let screenInk = PlazaColor(srgbRed: 0.05, green: 0.07, blue: 0.08, alpha: 1)
    static let lcd = PlazaColor(srgbRed: 0.51, green: 0.98, blue: 0.62, alpha: 1)
    static let amber = PlazaColor(srgbRed: 1.0, green: 0.73, blue: 0.28, alpha: 1)

    /// Where everything is (DIP, origin top-left, the card's own coordinates): one function for the size and the drawing, and
    /// what the tests read. Positions follow the SwiftUI stacks: padding 12, spacing 8, the screen's padding 10 and spacing 7.
    struct Layout {
        var size: CGSize
        var lens: CGRect
        var leds: [CGRect]
        /// The title's room, right-aligned in it.
        var titleRoom: CGRect
        var titleBaseline: CGFloat
        var screen: CGRect
        var totalOrigin: CGFloat, totalBaseline: CGFloat
        var totalWidth: CGFloat, unitWidth: CGFloat
        var chip: CGRect?
        var chipTextWidth: CGFloat
        /// Per bucket: the meter's column (blocks and label under them).
        var columns: [CGRect]
        var blockRects: [[CGRect]]
        var labelBaseline: CGFloat
        /// Four readouts: best day, best streak (left); active days, graduates (right).
        var readouts: [CGRect]
        var readoutBaselines: [CGFloat]
        var strip: CGRect
        var companion: CGRect
        var separator: CGRect
        var noGraduatesRoom: CGRect
        var chips: [(box: CGRect, sprite: CGRect, name: CGRect, nameSize: CGFloat)]
    }

    var onChange: (() -> Void)?
    private(set) var model: RecapCardModel
    private var width: CGFloat = PopoverWindowMetrics.contentWidth

    init(_ model: RecapCardModel) { self.model = model }

    /// Shows another period; the host renders again only when something differs.
    func update(_ next: RecapCardModel) {
        guard next != model else { return }
        model = next
        onChange?()
    }

    // MARK: fonts

    static func mono(_ size: CGFloat, _ weight: PlazaFontWeight = .regular) -> PlazaFont { .mono(size: size, weight: weight) }

    // MARK: layout

    static let padding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let screenPadding: CGFloat = 10
    static let screenSpacing: CGFloat = 7
    static let blockHeight: CGFloat = 4
    static let blockSpacing: CGFloat = 2
    static let labelSpacing: CGFloat = 3
    static let labelHeight: CGFloat = 10
    static let spriteSize: CGFloat = 18
    static let trackingTitle: CGFloat = 1.2

    private static func lineHeight(_ text: any PlazaTextEngine, _ font: PlazaFont) -> CGFloat {
        let m = text.metrics(font)
        return m.ascender - m.descender + m.leading
    }

    /// A text's advance with `tracking` added after every character (SwiftUI's `.tracking`).
    static func trackedWidth(_ s: String, font: PlazaFont, tracking: CGFloat, text: any PlazaTextEngine) -> CGFloat {
        s.reduce(0) { $0 + text.line(String($1), font: font).width + tracking }
    }

    /// The size a text takes when it must fit `room` (SwiftUI's `minimumScaleFactor(0.7)`): the base size, or smaller down to 70 %.
    static func fittedSize(_ s: String, base: CGFloat, weight: PlazaFontWeight, room: CGFloat, text: any PlazaTextEngine) -> CGFloat {
        let natural = text.line(s, font: mono(base, weight)).width
        guard natural > room, natural > 0 else { return base }
        return max(base * 0.7, base * room / natural)
    }

    func layout(width: CGFloat, text: any PlazaTextEngine) -> Layout {
        let m = model
        let pad = Self.padding
        let size = CGSize(width: width, height: PopoverRecapMetrics.cardHeight)
        // Header: the lens, three LEDs, the title at the right (spacing 6; 2 more at the left).
        let headerTop = pad, headerHeight: CGFloat = 16
        let lens = CGRect(x: pad + 2, y: headerTop, width: 16, height: 16)
        let leds = (0..<3).map { CGRect(x: lens.maxX + 6 + CGFloat($0) * 12, y: headerTop + 5, width: 6, height: 6) }
        let titleLeft = (leds.last?.maxX ?? lens.maxX) + 6 + 4
        let titleRoom = CGRect(x: titleLeft, y: headerTop, width: max(0, width - pad - titleLeft), height: headerHeight)
        let titleMetrics = text.metrics(Self.mono(10, .bold))
        let titleBaseline = headerTop + headerHeight / 2 - (titleMetrics.ascender - titleMetrics.descender) / 2 + titleMetrics.ascender

        // Screen.
        let screenX = pad + 2
        let screenWidth = width - 2 * pad - 4
        let inner = screenWidth - 2 * Self.screenPadding
        let left = screenX + Self.screenPadding
        let screenTop = headerTop + headerHeight + Self.spacing
        let totalFont = Self.mono(24, .bold)
        let totalMetrics = text.metrics(totalFont)
        let totalLine = text.line(m.total, font: totalFont)
        let rowTop = screenTop + Self.screenPadding
        let rowHeight = totalMetrics.ascender - totalMetrics.descender + totalMetrics.leading
        let totalBaseline = rowTop + totalMetrics.ascender
        let unitWidth = text.line(m.unit, font: Self.mono(7, .semibold)).width + CGFloat(m.unit.count) * 0.6
        var chip: CGRect?
        var chipText: CGFloat = 0
        if let delta = m.delta {
            chipText = text.line(delta.text, font: Self.mono(9, .bold)).width
            let chipMetrics = text.metrics(Self.mono(9, .bold))
            let h = chipMetrics.ascender - chipMetrics.descender + 4
            let w = chipText + 10
            chip = CGRect(x: left + inner - w, y: totalBaseline - chipMetrics.ascender - 2, width: w, height: h)
        }

        // Meters.
        let metersTop = rowTop + rowHeight + Self.screenSpacing
        let count = max(1, m.meters.count)
        let spacing = PopoverRecapMetrics.meterSpacing(m.scope)
        let columnWidth = (inner - spacing * CGFloat(count - 1)) / CGFloat(count)
        let blocks = PopoverRecapMetrics.meterBlocks
        let meterHeight = CGFloat(blocks) * Self.blockHeight + CGFloat(blocks - 1) * Self.blockSpacing
        let columnHeight = meterHeight + Self.labelSpacing + Self.labelHeight
        var columns: [CGRect] = [], blockRects: [[CGRect]] = []
        for i in 0..<m.meters.count {
            let x = left + CGFloat(i) * (columnWidth + spacing)
            columns.append(CGRect(x: x, y: metersTop, width: columnWidth, height: columnHeight))
            blockRects.append((0..<blocks).map {
                CGRect(x: x, y: metersTop + CGFloat($0) * (Self.blockHeight + Self.blockSpacing), width: columnWidth, height: Self.blockHeight)
            })
        }
        let labelMetrics = text.metrics(Self.mono(PopoverRecapMetrics.labelSize(m.scope), .regular))
        let labelTop = metersTop + meterHeight + Self.labelSpacing
        let labelBaseline = labelTop + Self.labelHeight / 2 - (labelMetrics.ascender - labelMetrics.descender) / 2 + labelMetrics.ascender

        // Readouts: two columns of two rows (spacing 10 between the columns, 3 between the rows).
        let readoutsTop = metersTop + columnHeight + Self.screenSpacing
        let valueMetrics = text.metrics(Self.mono(9.5, .bold))
        let readoutHeight = valueMetrics.ascender - valueMetrics.descender + valueMetrics.leading
        let readoutWidth = (inner - 10) / 2
        var readouts: [CGRect] = [], baselines: [CGFloat] = []
        for index in 0..<4 {
            let column = index / 2, row = index % 2
            let y = readoutsTop + CGFloat(row) * (readoutHeight + 3)
            readouts.append(CGRect(x: left + CGFloat(column) * (readoutWidth + 10), y: y, width: readoutWidth, height: readoutHeight))
            baselines.append(y + valueMetrics.ascender)
        }
        let screenHeight = readoutsTop + 2 * readoutHeight + 3 + Self.screenPadding - screenTop
        let screen = CGRect(x: screenX, y: screenTop, width: screenWidth, height: screenHeight)

        // Strip: the companion, a rule, then the notice or up to four graduate chips (spacing 5).
        let stripTop = screen.maxY + Self.spacing
        let stripX = pad + 2
        let sprite = Self.spriteSize
        let chipHeight = sprite + 4
        let stripHeight = chipHeight
        let strip = CGRect(x: stripX, y: stripTop, width: width - pad - stripX, height: stripHeight)
        let companion = CGRect(x: stripX, y: stripTop + (stripHeight - sprite) / 2, width: sprite, height: sprite)
        let separator = CGRect(x: companion.maxX + 10, y: stripTop + (stripHeight - 14) / 2, width: 1, height: 14)
        let after = separator.maxX + 6   // the Mac's SpriteView takes a little more room than its 18 pt picture
        let room = max(0, strip.maxX - after)
        let noGraduatesRoom = CGRect(x: after, y: stripTop, width: room, height: stripHeight)
        var chips: [(box: CGRect, sprite: CGRect, name: CGRect, nameSize: CGFloat)] = []
        if !m.graduates.isEmpty {
            // Four chips share the row: names shrink to 70 % first, then are cut (SwiftUI's lineLimit(1).minimumScaleFactor(0.7)).
            let chrome: CGFloat = 8 + sprite + 2
            let gaps = 5 * CGFloat(m.graduates.count - 1)
            let nameRoom = max(0, room - gaps - chrome * CGFloat(m.graduates.count))
            let natural = m.graduates.map { text.line($0.name, font: Self.mono(8, .semibold)).width }
            let total = natural.reduce(0, +)
            let scale: CGFloat = total > nameRoom && total > 0 ? max(0.7, nameRoom / total) : 1
            var x = after
            for i in m.graduates.indices {
                let nameSize = 8 * scale
                let wanted = natural[i] * scale
                // What is left over from the shorter names goes to the longer ones.
                let share = nameRoom * (natural[i] / max(total, 1))
                let w = total > nameRoom ? min(wanted, max(share, 0)) : wanted
                let box = CGRect(x: x, y: stripTop, width: chrome + w, height: chipHeight)
                let spriteRect = CGRect(x: x + 4, y: stripTop + (chipHeight - sprite) / 2, width: sprite, height: sprite)
                let name = CGRect(x: spriteRect.maxX + 2, y: stripTop, width: w, height: chipHeight)
                chips.append((box, spriteRect, name, nameSize))
                x = box.maxX + 5
            }
        }
        return Layout(size: size, lens: lens, leds: leds, titleRoom: titleRoom, titleBaseline: titleBaseline, screen: screen,
                      totalOrigin: left, totalBaseline: totalBaseline, totalWidth: totalLine.width, unitWidth: unitWidth, chip: chip,
                      chipTextWidth: chipText, columns: columns, blockRects: blockRects, labelBaseline: labelBaseline,
                      readouts: readouts, readoutBaselines: baselines, strip: strip, companion: companion, separator: separator,
                      noGraduatesRoom: noGraduatesRoom, chips: chips)
    }

    // MARK: PopoverPart

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: PopoverRecapMetrics.cardHeight)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let m = model, w = width
        let text = graphics.text
        let l = layout(width: w, text: text)
        let space = PlazaPanelSpace(content: l.size, room: 0)
        let whole = CGRect(origin: .zero, size: l.size)
        var layers: [PlazaPanelLayer] = []
        if let image = space.image(scale: scale, graphics: graphics, { canvas in Self.draw(m, l, space: space, canvas: canvas, text: text) }) {
            layers.append(.image(image, frame: whole))
        }

        var items: [PlazaAccessibilityItem] = []
        var tips: [PlazaTooltip] = []
        func staticText(_ frame: CGRect, _ label: String) {
            items.append(PlazaAccessibilityItem(frame: frame, role: .staticText, label: label))
        }
        staticText(l.titleRoom, m.title)
        staticText(CGRect(x: l.totalOrigin, y: l.screen.minY + Self.screenPadding, width: l.totalWidth + 5 + l.unitWidth, height: 29),
                   "\(m.total) \(m.unit)")
        if let chip = l.chip, let delta = m.delta { staticText(chip, delta.text) }
        for (index, meter) in m.meters.enumerated() where index < l.columns.count {
            // The meter is plain rectangles, so assistive technology would otherwise read the label alone: the bucket's own
            // description is its text and its tooltip.
            items.append(PlazaAccessibilityItem(frame: l.columns[index], role: .staticText, label: meter.description))
            tips.append(PlazaTooltip(frame: l.columns[index], text: meter.description))
        }
        for (index, readout) in m.readouts.enumerated() where index < l.readouts.count {
            staticText(l.readouts[index], "\(readout.label) \(readout.value)")
        }
        if m.graduates.isEmpty {
            staticText(l.noGraduatesRoom, m.noGraduates)
        } else {
            // the name only: the chip's own box also covers its sprite, which the host paints over the picture
            for (index, g) in m.graduates.enumerated() where index < l.chips.count { staticText(l.chips[index].name, g.name) }
        }

        var slots = [SpriteSlot(frame: l.companion, subject: PlazaSpriteSubjectKey(speciesID: m.companionSpeciesID, shiny: m.companionShiny,
                                                                                    form: m.companionForm),
                                bob: false, animated: false)]
        for (index, g) in m.graduates.enumerated() where index < l.chips.count {
            slots.append(SpriteSlot(frame: l.chips[index].sprite,
                                    subject: PlazaSpriteSubjectKey(speciesID: g.speciesID, shiny: g.isShiny, form: g.form),
                                    bob: false, animated: false))
        }
        return PopoverDrawing(drawing: PlazaPanelDrawing(layers: layers, accessibility: items, tooltips: tips), spriteSlots: slots)
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }

    // MARK: drawing

    private static func color(_ c: PlazaColor, alpha: Double) -> PlazaColor {
        PlazaColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha * alpha)
    }

    private static func mix(_ a: PlazaColor, _ b: PlazaColor, _ t: Double) -> PlazaColor {
        PlazaColor(srgbRed: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                   blue: a.blue + (b.blue - a.blue) * t, alpha: 1)
    }

    /// One line at a baseline, `x` its left edge (card coordinates, top-left origin).
    private static func put(_ s: String, font: PlazaFont, color: PlazaColor, x: CGFloat, baseline: CGFloat, space: PlazaPanelSpace,
                            canvas: any PlazaCanvas, text: any PlazaTextEngine) {
        guard !s.isEmpty else { return }
        canvas.setFillColor(color)
        canvas.draw(text.line(s, font: font), at: space.canvas(CGPoint(x: x, y: baseline)))
    }

    /// A line cut to `room` with an ellipsis when it still does not fit.
    private static func putFitted(_ s: String, font: PlazaFont, color: PlazaColor, x: CGFloat, baseline: CGFloat, room: CGFloat,
                                  space: PlazaPanelSpace, canvas: any PlazaCanvas, text: any PlazaTextEngine, alignRight: Bool = false) {
        guard !s.isEmpty, room > 0 else { return }
        var line = text.line(s, font: font)
        if line.width > room + 0.01, let cut = text.truncated(line, width: room, ellipsis: text.line("…", font: font)) { line = cut }
        canvas.setFillColor(color)
        let startX = alignRight ? x + room - line.width : x
        canvas.draw(line, at: space.canvas(CGPoint(x: startX, y: baseline)))
    }

    private static func draw(_ m: RecapCardModel, _ l: Layout, space: PlazaPanelSpace, canvas: any PlazaCanvas, text: any PlazaTextEngine) {
        let whole = CGRect(origin: .zero, size: l.size)
        // The shell: the gradient as one-point stripes, clipped to the case, with the hinge side darker.
        canvas.saveState()
        canvas.clip(toRoundedRect: space.canvas(whole), radius: 10)
        let rows = Int(l.size.height.rounded(.up))
        for row in 0..<rows {
            canvas.setFillColor(mix(shellTop, shellBottom, Double(row) / Double(max(1, rows - 1))))
            canvas.fill(space.canvas(CGRect(x: 0, y: CGFloat(row), width: l.size.width, height: 1)))
        }
        canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        canvas.fill(space.canvas(CGRect(x: 0, y: 0, width: 5, height: l.size.height)))
        canvas.restoreState()

        // The lens: a radial gradient from its upper left (centre 35 % / 30 %, radius 11) as concentric discs, a white rim and a
        // highlight.
        canvas.saveState()
        canvas.clip(toRoundedRect: space.canvas(l.lens), radius: l.lens.width / 2)
        let light = PlazaColor(srgbRed: 0.72, green: 0.88, blue: 1.0, alpha: 1), dark = PlazaColor(srgbRed: 0.15, green: 0.45, blue: 0.85, alpha: 1)
        let focus = CGPoint(x: l.lens.minX + l.lens.width * 0.35, y: l.lens.minY + l.lens.height * 0.3)
        var radius: CGFloat = 11
        while radius > 0 {
            canvas.setFillColor(mix(light, dark, Double(radius / 11)))
            canvas.fillEllipse(in: space.canvas(CGRect(x: focus.x - radius, y: focus.y - radius, width: 2 * radius, height: 2 * radius)))
            radius -= 0.5
        }
        canvas.restoreState()
        canvas.setStrokeColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        canvas.strokeEllipse(in: space.canvas(l.lens.insetBy(dx: 0.75, dy: 0.75)), lineWidth: 1.5)
        canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75))
        canvas.fillEllipse(in: space.canvas(CGRect(x: l.lens.midX - 3 - 2, y: l.lens.midY - 3 - 2, width: 4, height: 4)))
        let ledColors = [PlazaColor(srgbRed: 0.95, green: 0.35, blue: 0.35, alpha: 1), PlazaColor(srgbRed: 0.98, green: 0.82, blue: 0.35, alpha: 1),
                         PlazaColor(srgbRed: 0.45, green: 0.88, blue: 0.5, alpha: 1)]
        for (led, color) in zip(l.leds, ledColors) {
            canvas.setFillColor(color)
            canvas.fillEllipse(in: space.canvas(led))
            canvas.setStrokeColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            canvas.strokeEllipse(in: space.canvas(led.insetBy(dx: 0.25, dy: 0.25)), lineWidth: 0.5)
        }

        // The title: upper case, bold mono 10, tracking 1.2, right-aligned, shrunk to 70 % to fit.
        let titleSize = fittedTitleSize(m.title, room: l.titleRoom.width, text: text)
        let titleFont = mono(titleSize, .bold)
        let tracking = trackingTitle * titleSize / 10
        let titleWidth = trackedWidth(m.title, font: titleFont, tracking: tracking, text: text)
        var x = l.titleRoom.maxX - titleWidth
        canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        for ch in m.title {
            let line = text.line(String(ch), font: titleFont)
            if x + line.width > l.titleRoom.minX - 0.01 { canvas.draw(line, at: space.canvas(CGPoint(x: x, y: l.titleBaseline))) }
            x += line.width + tracking
        }

        // The screen.
        canvas.setFillColor(screenInk)
        canvas.fillRoundedRect(space.canvas(l.screen), radius: 6)
        canvas.setStrokeColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        canvas.strokeRoundedRect(space.canvas(l.screen.insetBy(dx: 1, dy: 1)), radius: 5, lineWidth: 2)

        put(m.total, font: mono(24, .bold), color: lcd, x: l.totalOrigin, baseline: l.totalBaseline, space: space, canvas: canvas, text: text)
        let unitX = l.totalOrigin + l.totalWidth + 5
        let unitFont = mono(7, .semibold)
        var ux = unitX
        canvas.setFillColor(color(lcd, alpha: 0.5))
        for ch in m.unit {
            let line = text.line(String(ch), font: unitFont)
            canvas.draw(line, at: space.canvas(CGPoint(x: ux, y: l.totalBaseline)))
            ux += line.width + 0.6
        }
        if let chip = l.chip, let delta = m.delta {
            let tint = delta.up ? lcd : amber
            canvas.setStrokeColor(color(tint, alpha: 0.6))
            canvas.strokeRoundedRect(space.canvas(chip.insetBy(dx: 0.5, dy: 0.5)), radius: 2, lineWidth: 1)
            put(delta.text, font: mono(9, .bold), color: tint, x: chip.minX + 5, baseline: l.totalBaseline, space: space, canvas: canvas, text: text)
        }

        // The meters: eight blocks, the lit ones from the bottom; the current bucket is full strength, an unknown one dims even its grid.
        let labelFont = { (current: Bool) in mono(PopoverRecapMetrics.labelSize(m.scope), current ? .bold : .regular) }
        for (index, meter) in m.meters.enumerated() where index < l.blockRects.count {
            let blocks = l.blockRects[index]
            for (i, rect) in blocks.enumerated() {
                let litBlock = i >= blocks.count - meter.lit
                let alpha = litBlock ? (meter.isCurrent ? 1 : 0.55) : (meter.hasData ? 0.09 : 0.035)
                canvas.setFillColor(color(lcd, alpha: alpha))
                canvas.fill(space.canvas(rect))
            }
            if !meter.label.isEmpty {
                // A zero-width frame centred on the column: a month's "15" is wider than its column and must not widen it.
                let font = labelFont(meter.isCurrent)
                let line = text.line(meter.label, font: font)
                canvas.setFillColor(color(lcd, alpha: meter.isCurrent ? 1 : 0.45))
                canvas.draw(line, at: space.canvas(CGPoint(x: l.columns[index].midX - line.width / 2, y: l.labelBaseline)))
            }
        }

        // The readouts: a small upper-case label, the value at the right of its column.
        for (index, readout) in m.readouts.enumerated() where index < l.readouts.count {
            let box = l.readouts[index]
            let valueSize = fittedSize(readout.value, base: 9.5, weight: .bold, room: box.width * 0.6, text: text)
            let valueLine = text.line(readout.value, font: mono(valueSize, .bold))
            let labelRoom = max(0, box.width - valueLine.width - 4 - 2)
            let labelSize = fittedSize(readout.label, base: 7, weight: .semibold, room: labelRoom, text: text)
            putFitted(readout.label, font: mono(labelSize, .semibold), color: color(lcd, alpha: 0.5), x: box.minX,
                      baseline: l.readoutBaselines[index], room: labelRoom, space: space, canvas: canvas, text: text)
            canvas.setFillColor(lcd)
            canvas.draw(valueLine, at: space.canvas(CGPoint(x: box.maxX - valueLine.width, y: l.readoutBaselines[index])))
        }

        // The strip under the screen: a rule, then the notice or the graduates.
        canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
        canvas.fill(space.canvas(l.separator))
        if m.graduates.isEmpty {
            let font = mono(8, .regular)
            let lines = text.wrappedLines(m.noGraduates, font: font, width: l.noGraduatesRoom.width)
            let metrics = text.metrics(font)
            let lineHeight = metrics.ascender - metrics.descender + metrics.leading
            let shown = Array(lines.prefix(2))
            let top = l.noGraduatesRoom.midY - lineHeight * CGFloat(shown.count) / 2
            canvas.setFillColor(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
            for (i, line) in shown.enumerated() {
                var drawn = line
                if i == 1, lines.count > 2, let cut = text.truncated(line, width: l.noGraduatesRoom.width, ellipsis: text.line("…", font: font)) { drawn = cut }
                canvas.draw(drawn, at: space.canvas(CGPoint(x: l.noGraduatesRoom.minX, y: top + CGFloat(i) * lineHeight + metrics.ascender)))
            }
        } else {
            for (index, g) in m.graduates.enumerated() where index < l.chips.count {
                let chip = l.chips[index]
                canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
                canvas.fillRoundedRect(space.canvas(chip.box), radius: 3)
                let font = mono(chip.nameSize, .semibold)
                let metrics = text.metrics(font)
                let baseline = chip.name.midY - (metrics.ascender - metrics.descender) / 2 + metrics.ascender
                putFitted(g.name, font: font, color: PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), x: chip.name.minX, baseline: baseline,
                          room: chip.name.width, space: space, canvas: canvas, text: text)
                if g.isShiny {
                    // A badge on the sprite rather than after the name: a trailing sparkle cut "Charizard" to "Chariza…".
                    let sparkle = text.line("✨", font: .emoji(size: 7))
                    canvas.draw(sparkle, at: space.canvas(CGPoint(x: chip.sprite.maxX - sparkle.width + 3, y: chip.sprite.minY - 2 + 7)))
                }
            }
        }
    }

    /// The title's font size: 10, or smaller down to 70 % when the tracked text does not fit its room.
    static func fittedTitleSize(_ s: String, room: CGFloat, text: any PlazaTextEngine) -> CGFloat {
        let natural = trackedWidth(s, font: mono(10, .bold), tracking: trackingTitle, text: text)
        guard natural > room, natural > 0 else { return 10 }
        return max(7, 10 * room / natural)
    }
}
