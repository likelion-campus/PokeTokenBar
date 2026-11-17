import Foundation

// MARK: Task 20 — drawing helpers shared by the Pokédex grid and the catch log parts

/// Measures and draws what the Collection parts are made of: cached text lines, capsules, badges and glyphs, in the Mac's
/// sizes. One instance per part; it holds no picture.
@MainActor final class DexPainter {
    struct Key: Hashable { var text: String; var font: PlazaFont }
    private var lines: [Key: PlazaTextLine] = [:]
    let text: any PlazaTextEngine
    weak var glyphs: (any PopoverGlyphRaster)?
    let scale: CGFloat

    init(text: any PlazaTextEngine, glyphs: (any PopoverGlyphRaster)?, scale: CGFloat) {
        self.text = text
        self.glyphs = glyphs
        self.scale = scale
    }

    func line(_ s: String, _ font: PlazaFont) -> PlazaTextLine {
        let key = Key(text: s, font: font)
        if let hit = lines[key] { return hit }
        if lines.count > 600 { lines.removeAll() }
        let made = text.line(s, font: font)
        lines[key] = made
        return made
    }

    func metrics(_ font: PlazaFont) -> (height: CGFloat, ascender: CGFloat) { CompanionHeaderPart.lineHeight(font, text) }

    /// Draws `s` with its left edge at `x`, vertically centred on `centerY` (part coordinates).
    func draw(_ s: String, _ font: PlazaFont, color: PlazaColor, x: CGFloat, centerY: CGFloat, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let l = line(s, font)
        let m = metrics(font)
        canvas.setFillColor(color)
        canvas.draw(l, at: space.canvas(CGPoint(x: x, y: centerY - m.height / 2 + m.ascender)))
    }

    /// A glyph picture (a symbol), nil when the host has none.
    func glyph(_ symbol: String, size: CGFloat, bold: Bool, color: PlazaColor) -> PlazaImage? {
        glyphs?.image(symbol: symbol, pointSize: size, bold: bold, color: color, scale: scale)
    }

    /// Draws a glyph centred in `rect`, or `fallback` text when there is none.
    func drawGlyph(_ symbol: String, fallback: String, size: CGFloat, bold: Bool, color: PlazaColor, in rect: CGRect,
                   canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        if let image = glyph(symbol, size: size, bold: bold, color: color) {
            let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
            canvas.draw(image, in: space.canvas(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)))
        } else {
            let font = PlazaFont.system(size: size, weight: bold ? .bold : .regular)
            let l = line(fallback, font)
            let m = metrics(font)
            canvas.setFillColor(color)
            canvas.draw(l, at: space.canvas(CGPoint(x: rect.midX - l.width / 2, y: rect.midY - m.height / 2 + m.ascender)))
        }
    }

    /// A capsule: filled, with an outline of `lineWidth` inside its edge.
    func capsule(_ r: CGRect, fill: PlazaColor?, stroke: PlazaColor?, lineWidth: CGFloat, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        if let fill {
            canvas.setFillColor(fill)
            canvas.fillRoundedRect(space.canvas(r), radius: r.height / 2)
        }
        if let stroke {
            canvas.setStrokeColor(stroke)
            canvas.strokeRoundedRect(space.canvas(r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)), radius: max(0, r.height / 2 - lineWidth / 2),
                                     lineWidth: lineWidth)
        }
    }

    func roundedRect(_ r: CGRect, radius: CGFloat, fill: PlazaColor?, stroke: PlazaColor?, lineWidth: CGFloat, canvas: any PlazaCanvas,
                     space: PlazaPanelSpace) {
        if let fill {
            canvas.setFillColor(fill)
            canvas.fillRoundedRect(space.canvas(r), radius: radius)
        }
        if let stroke {
            canvas.setStrokeColor(stroke)
            canvas.strokeRoundedRect(space.canvas(r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)), radius: max(0, radius - lineWidth / 2),
                                     lineWidth: lineWidth)
        }
    }

    /// The Mac's `Badge` at `size` pt (`padding(.horizontal, 5).padding(.vertical, 1)`): its size for `s`.
    func badgeSize(_ s: String, size: CGFloat) -> CGSize {
        let font = PlazaFont.system(size: size, weight: .bold)
        return CGSize(width: ceil(line(s, font).width) + 10, height: metrics(font).height + 2)
    }

    /// A badge in `r`: `.solid` white on the tint, `.tinted` the tint on a faint tint.
    func badge(_ s: String, size: CGFloat, tint: PlazaColor, solid: Bool, in r: CGRect, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let font = PlazaFont.system(size: size, weight: .bold)
        capsule(r, fill: solid ? tint : PlazaColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha * 0.14), stroke: nil,
                lineWidth: 0, canvas: canvas, space: space)
        draw(s, font, color: solid ? .white : tint, x: r.minX + 5, centerY: r.midY, canvas: canvas, space: space)
    }

    /// `color` at `fraction` of its own alpha.
    static func tint(_ c: PlazaColor, _ fraction: Double) -> PlazaColor {
        PlazaColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha * fraction)
    }

    /// The Mac's `.regularMaterial` where it sits under a small label: a light translucent plate (no blur on Windows).
    static let material = PlazaColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 0.86)

    /// `s` wrapped to at most `maxLines` lines of `width`, the last one cut with an ellipsis (`lineLimit`).
    func wrapped(_ s: String, _ font: PlazaFont, width: CGFloat, maxLines: Int) -> [PlazaTextLine] {
        var lines = text.wrappedLines(s, font: font, width: width)
        guard lines.count > maxLines else { return lines }
        var chars = Array(s)
        while !chars.isEmpty {
            chars.removeLast()
            lines = text.wrappedLines(String(chars).trimmingCharacters(in: .whitespaces) + "…", font: font, width: width)
            if lines.count <= maxLines { break }
        }
        return lines
    }
}

/// One chip (`RarityTally`, `RegionTally`): a capsule with a colour dot or an emoji, a label, a count and a check mark when
/// selected. `accent` colours the fill, the ring and the check.
struct DexChipSpec: Equatable {
    var dot: PlazaColor?
    var emoji: String?
    var label: String
    var count: String
    var countColor: PlazaColor
    var accent: PlazaColor
    var selected: Bool
    /// The fill's opacity of the accent when not selected (selected is always 0.22).
    var fill: Double
    var ring: Double = 0.35
    var opacity: Double
}

extension DexPainter {
    static let chipFont: CGFloat = 11
    static let chipGap: CGFloat = 3
    static let chipPadH: CGFloat = 6
    static let chipPadV: CGFloat = 2

    private func chipFonts(_ spec: DexChipSpec) -> (label: PlazaFont, count: PlazaFont, emoji: PlazaFont) {
        (.system(size: Self.chipFont, weight: spec.selected ? .semibold : .regular), .system(size: Self.chipFont, weight: .bold), .emoji(size: 10))
    }

    func chipSize(_ spec: DexChipSpec) -> CGSize {
        let f = chipFonts(spec)
        var w = Self.chipPadH * 2
        var parts: [CGFloat] = []
        if spec.dot != nil { parts.append(6) }
        if let e = spec.emoji { parts.append(ceil(line(e, f.emoji).width)) }
        parts.append(ceil(line(spec.label, f.label).width))
        parts.append(ceil(line(spec.count, f.count).width))
        if spec.selected { parts.append(9) }
        w += parts.reduce(0, +) + CGFloat(parts.count - 1) * Self.chipGap
        return CGSize(width: w, height: metrics(.system(size: Self.chipFont, weight: .bold)).height + Self.chipPadV * 2)
    }

    func drawChip(_ spec: DexChipSpec, in r: CGRect, canvas: any PlazaCanvas, space: PlazaPanelSpace) {
        let f = chipFonts(spec)
        canvas.saveState()
        canvas.setAlpha(spec.opacity)
        capsule(r, fill: Self.tint(spec.accent, spec.selected ? 0.22 : spec.fill),
                stroke: spec.selected ? spec.accent : Self.tint(spec.accent, spec.ring), lineWidth: spec.selected ? 1.5 : 0.5, canvas: canvas, space: space)
        var x = r.minX + Self.chipPadH
        let cy = r.midY
        if let dot = spec.dot {
            canvas.setFillColor(dot)
            canvas.fillEllipse(in: space.canvas(CGRect(x: x, y: cy - 3, width: 6, height: 6)))
            x += 6 + Self.chipGap
        }
        if let e = spec.emoji {
            draw(e, f.emoji, color: .white, x: x, centerY: cy, canvas: canvas, space: space)
            x += ceil(line(e, f.emoji).width) + Self.chipGap
        }
        draw(spec.label, f.label, color: PopoverColorRole.primary.plazaColor(), x: x, centerY: cy, canvas: canvas, space: space)
        x += ceil(line(spec.label, f.label).width) + Self.chipGap
        draw(spec.count, f.count, color: spec.countColor, x: x, centerY: cy, canvas: canvas, space: space)
        x += ceil(line(spec.count, f.count).width) + Self.chipGap
        if spec.selected {
            drawGlyph("checkmark", fallback: "✓", size: 9, bold: true, color: spec.accent, in: CGRect(x: x, y: cy - 5, width: 9, height: 10),
                      canvas: canvas, space: space)
        }
        canvas.restoreState()
    }

    /// The chip of a rarity (`RarityTally`).
    static func spec(_ chip: DexRarityChipModel) -> DexChipSpec {
        let c = CompanionBadges.rarityColor(chip.rarity).plazaColor()
        return DexChipSpec(dot: c, emoji: nil, label: chip.label, count: "\(chip.count)", countColor: PopoverColorRole.primary.plazaColor(),
                           accent: c, selected: chip.isSelected, fill: 0.12, opacity: chip.count == 0 ? 0.4 : 1)
    }

    /// The chip of a region (`RegionTally`).
    static func spec(_ chip: DexRegionChipModel) -> DexChipSpec {
        let accent = chip.isComplete ? PopoverColorRole.systemGreen.plazaColor() : PopoverColorRole.secondary.plazaShapeColor()
        let secondary = PopoverColorRole.secondary.plazaColor()
        return DexChipSpec(dot: nil, emoji: chip.isShinyComplete ? "✨" : (chip.isComplete ? "🏅" : nil), label: chip.label,
                           count: "\(chip.owned)/\(chip.total)", countColor: chip.isComplete ? accent : secondary, accent: accent,
                           selected: chip.isSelected, fill: chip.isComplete ? 0.14 : 0.08, opacity: chip.owned == 0 ? 0.5 : 1)
    }
}
