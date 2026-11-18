#if os(Windows)
import Foundation
import WinSDK

/// The Mac's tinted card (parity pass): an orange notice (`PopoverView.authExpiredNotice`, `sessionKeyExpiredNotice`,
/// `antigravityAuthExpiredNotice`: orange 10 % or 12 % on a 6 or 8 pt card, `.padding(8)`, a warning glyph before a caption title,
/// the hint in `caption2` secondary, the button right of the title or under the hint) and the update offer (accent 12 % on an
/// 8 pt card). A child pane paints the card and the glyph (no control, so nothing for a screen reader to read twice) and holds the
/// labels and buttons; the page measures it at its row's width (`fitWidth`) and lays out again when the width or a text changes.
/// A line is `leading` controls, one `flexible` label that takes the rest of the line and wraps, and `trailing` controls at the
/// right; the first line may reserve a slot for the glyph. Colours: the tint is blended over the page colour; high contrast
/// draws no tint.
@MainActor final class WinNoticeCard {
    struct Line {
        var leading: [WinControl] = []
        var flexible: WinControl?
        var trailing: [WinControl] = []
        /// Space above the line (SwiftUI's `.padding(.top, 2)` on the button under the hint).
        var top: CGFloat = 0
        /// The first line only: the glyph's slot comes before everything else.
        var hasGlyph = false
    }

    enum Tint { case orange, accent }

    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    private(set) var lines: [Line] = []
    private let tint: Tint
    private let alpha: Double
    private let radiusDIP: CGFloat
    private let lineSpacing: CGFloat
    private let glyph: (text: String, font: HFONT?)?
    private var tintColor: COLORREF
    private var width: Int32 = 0
    private var glyphRect = RECT()
    private(set) var arranges = 0

    /// `build` makes the children (in reading order) as children of the pane window it is given.
    init?(parent: HWND, ctx: WinUIContext, tint: Tint, alpha: Double, radius: CGFloat, spacing: CGFloat, symbol: String?,
          build: (HWND, WinUIContext, COLORREF) -> [Line]) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        self.tint = tint
        self.alpha = alpha
        radiusDIP = radius
        lineSpacing = spacing
        let pal = ctx.colors.palette
        let base: COLORREF
        switch tint {
        case .orange: base = ctx.colors.statusOrange
        case .accent: base = pal.accent
        }
        tintColor = ctx.highContrast ? pal.window : WinUIColors.blend(pal.window, base, alpha)
        var shape: (String, HFONT?)?
        if let symbol {
            if let text = WinGlyphs.text(symbol: symbol, fluent: ctx.fonts.iconIsFluent) {
                shape = (text, ctx.fonts.icon(size: 13))
            } else if let text = WinGlyphs.fallback(symbol: symbol) {
                shape = (text, ctx.fonts.emoji(size: 13))
            }
        }
        glyph = shape.map { (text: $0.0, font: $0.1) }
        lines = build(made.hwnd, ctx, tintColor)
        // Everything on the card is drawn over the tint, not over the page colour.
        for line in lines { (line.leading + [line.flexible].compactMap { $0 } + line.trailing).forEach { $0.background = tintColor } }
        control = WinControls.drawn(made.hwnd, size: .zero, ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        control.fitWidth = { [self] px in self.fit(px) }
        made.paint = { [weak self] dc, r in self?.paintCard(dc, r) }
    }

    private var padding: Int32 { ctx.px(8) }
    private var gap: Int32 { ctx.px(6) }
    private var glyphSlot: Int32 {
        guard let glyph else { return 0 }
        return ctx.measure(glyph.text, font: glyph.font).cx + gap
    }

    private func w(_ c: WinControl) -> Int32 { Int32(c.preferredSize.width.rounded(.up)) }
    private func h(_ c: WinControl) -> Int32 { Int32(c.preferredSize.height.rounded(.up)) }

    private struct Geometry {
        var y: Int32 = 0
        var height: Int32 = 0
        var flexibleWidth: Int32 = 0
        var flexibleHeight: Int32 = 0
    }

    /// Every line's top, height and flexible width at `px` pixels, and the card's height.
    private func geometry(_ px: Int32) -> (lines: [Geometry], height: Int32) {
        let inner = max(1, px - 2 * padding)
        var y = padding
        var out: [Geometry] = []
        for (i, line) in lines.enumerated() {
            if i > 0 { y += ctx.px(lineSpacing) + ctx.px(line.top) }
            let fixed = line.leading + line.trailing
            let slot = line.hasGlyph ? glyphSlot : 0
            let parts = fixed.count + (line.flexible == nil ? 0 : 1)
            let used = fixed.map(w).reduce(0, +) + slot + gap * Int32(max(0, parts - 1))
            let flexW = max(1, inner - used)
            let flexH = line.flexible.map { Int32($0.size(width: flexW).height.rounded(.up)) } ?? 0
            let glyphH = line.hasGlyph ? (glyph.map { ctx.measure($0.text, font: $0.font).cy } ?? 0) : 0
            let height = max(flexH, fixed.map(h).max() ?? 0, glyphH)
            out.append(Geometry(y: y, height: height, flexibleWidth: flexW, flexibleHeight: flexH))
            y += height
        }
        return (out, y + padding)
    }

    private func fit(_ px: Int32) -> Bool {
        width = px
        let height = geometry(px).height
        let changed = Int32(control.preferredSize.height) != height
        control.preferredSize = CGSize(width: 0, height: CGFloat(height))
        return changed
    }

    private func place(_ r: RECT) {
        width = r.right - r.left
        WinKit.move(pane.hwnd, r)
        arrange()
    }

    func arrange() {
        arranges += 1
        guard width > 0 else { return }
        let geo = geometry(width)
        let inner = width - 2 * padding
        for (line, g) in zip(lines, geo.lines) {
            var left = padding
            if line.hasGlyph, let glyph {
                let size = ctx.measure(glyph.text, font: glyph.font)
                glyphRect = RECT(left: left, top: g.y + (g.height - size.cy) / 2, right: left + size.cx, bottom: g.y + (g.height - size.cy) / 2 + size.cy)
                left += glyphSlot
            }
            var right = padding + inner
            for c in line.trailing.reversed() {
                let cw = w(c), ch = h(c)
                c.frame(RECT(left: right - cw, top: g.y + (g.height - ch) / 2, right: right, bottom: g.y + (g.height - ch) / 2 + ch))
                right -= cw + gap
            }
            for c in line.leading {
                let cw = w(c), ch = h(c)
                c.frame(RECT(left: left, top: g.y + (g.height - ch) / 2, right: left + cw, bottom: g.y + (g.height - ch) / 2 + ch))
                left += cw + gap
            }
            if let f = line.flexible {
                f.frame(RECT(left: left, top: g.y + (g.height - g.flexibleHeight) / 2, right: left + g.flexibleWidth,
                             bottom: g.y + (g.height - g.flexibleHeight) / 2 + g.flexibleHeight))
            }
        }
        pane.invalidate()
    }

    /// The card, then the glyph in the tint's own colour (orange; the accent has none).
    private func paintCard(_ dc: HDC, _ r: RECT) {
        let pal = ctx.colors.palette
        var all = RECT()
        _ = GetClientRect(pane.hwnd, &all)
        var rr = r
        _ = FillRect(dc, &rr, ctx.colors.brush(pal.window))
        if tintColor != pal.window || ctx.highContrast {  // a tinted card needs no hairline (high contrast: an outline)
            WinPaint.roundedRect(dc, all, radius: ctx.px(radiusDIP), fill: WinPaint.Ink(color: tintColor),
                                 stroke: ctx.highContrast ? WinPaint.Ink(color: pal.text) : nil, strokeWidth: max(1, ctx.px(1)),
                                 under: pal.window, ctx: ctx)
        }
        if let glyph, glyphRect.right > glyphRect.left {
            let old = SelectObject(dc, UnsafeMutableRawPointer(glyph.font))
            _ = SetBkMode(dc, 1 /* TRANSPARENT */)
            _ = SetTextColor(dc, tint == .orange && !ctx.highContrast ? ctx.colors.statusOrange : pal.text)
            var box = glyphRect
            _ = WinStr.w(glyph.text).withUnsafeBufferPointer {
                DrawTextW(dc, $0.baseAddress, -1, &box, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            _ = SelectObject(dc, old)
        }
    }

    private func destroyChildren() {
        control.onFrame = nil
        control.fitWidth = nil
        pane.paint = nil
        for line in lines { (line.leading + [line.flexible].compactMap { $0 } + line.trailing).forEach { $0.destroy() } }
        lines = []
        pane.destroy()
    }
}
#endif
