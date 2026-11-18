#if os(Windows)
import Foundation
import WinSDK

/// The Shop's and Bag's card (stage 7 Task 19): the Mac's `.padding(10).background(Color.secondary.opacity(0.06))` on a 10 pt
/// rounded rectangle around a `VStack` of lines, the first lines beside a 30 pt icon (`HStack(alignment: .top, spacing: 10)`).
/// A child pane paints the card and holds the icon, labels, steppers and buttons; the page measures it at its row's width
/// (`fitWidth`) and lays out again when the width or a text changes.
///
/// A line is `leading` controls, one `flexible` label that takes the rest of the line and wraps, `trailing` controls at the
/// right, or a `center` group (the empty bag). `top` is the space above the line (the Mac's stack spacing), `indent` puts the
/// line beside the icon. When a line is too narrow its first leading control gives way (a label cut with an ellipsis).
@MainActor final class WinCardView {
    struct Line {
        var leading: [WinControl] = []
        var flexible: WinControl?
        var trailing: [WinControl] = []
        var center: [WinControl] = []
        var top: CGFloat = 0
        var indent = false
        var gap: CGFloat = 8
        /// A symbol before everything else on the line (the Mac's `Image(systemName:)`), drawn by the card in `color`.
        var glyph: (symbol: String, color: COLORREF)?
        /// Controls that take no room (a zero-size static: the accessible name of the stepper after the owned count).
        var unseen: [WinControl] = []

        var all: [WinControl] { leading + [flexible].compactMap { $0 } + trailing + center + unseen }
    }

    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    private(set) var lines: [Line] = []
    private(set) var icon: WinControl?
    private let tinted: Bool
    private let paddingDIP: CGFloat
    private let paddingVDIP: CGFloat
    private let radiusDIP: CGFloat
    private let iconSide: CGFloat
    private let iconGap: CGFloat
    private(set) var tint: COLORREF
    private var width: Int32 = 0
    private(set) var arranges = 0
    private var glyphRects: [Int: RECT] = [:]

    /// `build` makes the children (in reading order, the icon first) as children of the pane window it is given and the colour
    /// they sit on.
    init?(parent: HWND, ctx: WinUIContext, tinted: Bool = true, padding: CGFloat = 10, verticalPadding: CGFloat? = nil, radius: CGFloat = 10, iconSide: CGFloat = 30,
          iconGap: CGFloat = 10, build: (HWND, WinUIContext, COLORREF) -> (icon: WinControl?, lines: [Line])) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        self.tinted = tinted
        paddingDIP = padding
        paddingVDIP = verticalPadding ?? padding
        radiusDIP = radius
        self.iconSide = iconSide
        self.iconGap = iconGap
        let pal = ctx.colors.palette
        // The tile is the card token in both appearances (K1): white on the grey base in light, lighter than the window in dark.
        // (It was 3 % black over the window, which in dark mode darkened the tile where the Mac's `secondary.opacity(0.06)`
        // lightens it.)
        tint = ctx.highContrast || !tinted ? pal.window : pal.card
        let built = build(made.hwnd, ctx, tint)
        icon = built.icon
        lines = built.lines
        icon?.background = tint
        for line in lines { line.all.forEach { $0.background = tint } }
        control = WinControls.drawn(made.hwnd, size: .zero, ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        control.fitWidth = { [self] px in self.fit(px) }
        made.paint = { [weak self] dc, r in self?.paintCard(dc, r) }
    }

    private var padding: Int32 { ctx.px(paddingDIP) }
    private var paddingV: Int32 { ctx.px(paddingVDIP) }
    private var iconBlock: Int32 { icon == nil ? 0 : ctx.px(iconSide) + ctx.px(iconGap) }

    private func w(_ c: WinControl) -> Int32 { Int32(c.preferredSize.width.rounded(.up)) }
    private func h(_ c: WinControl) -> Int32 { Int32(c.preferredSize.height.rounded(.up)) }

    /// The glyph as drawn: text in the icon font, or an emoji where the fonts have no glyph.
    private func glyphShape(_ line: Line) -> (text: String, font: HFONT?)? {
        guard let symbol = line.glyph?.symbol else { return nil }
        if let text = WinGlyphs.text(symbol: symbol, fluent: ctx.fonts.iconIsFluent) { return (text, ctx.fonts.icon(size: 10)) }
        if let text = WinGlyphs.fallback(symbol: symbol) { return (text, ctx.fonts.emoji(size: 10)) }
        return nil
    }

    private func glyphSlot(_ line: Line) -> Int32 {
        guard let shape = glyphShape(line) else { return 0 }
        return ctx.measure(shape.text, font: shape.font).cx + ctx.px(5)
    }

    private struct Geometry {
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0
        var flexibleWidth: Int32 = 0
        var flexibleHeight: Int32 = 0
    }

    /// Every line's place and the card's height at `px` pixels wide.
    private func geometry(_ px: Int32) -> (lines: [Geometry], height: Int32) {
        let inner = max(1, px - 2 * padding)
        var y = paddingV
        var out: [Geometry] = []
        var inBlock = false  // the lines beside the icon end no higher than the icon does
        for line in lines {
            if line.indent {
                inBlock = true
            } else if inBlock {
                y = max(y, paddingV + ctx.px(iconSide))
                inBlock = false
            }
            y += ctx.px(line.top)
            let slot = glyphSlot(line)
            let x = padding + (line.indent ? iconBlock : 0) + slot
            let room = max(1, inner - (line.indent ? iconBlock : 0) - slot)
            let gap = ctx.px(line.gap)
            let fixed = line.leading + line.trailing + line.center
            let parts = fixed.count + (line.flexible == nil ? 0 : 1)
            let used = fixed.map(w).reduce(0, +) + gap * Int32(max(0, parts - 1))
            let flexW = max(1, room - used)
            let flexH = line.flexible.map { Int32($0.size(width: flexW).height.rounded(.up)) } ?? 0
            let height = max(flexH, fixed.map(h).max() ?? 0)
            out.append(Geometry(x: x, y: y, width: room, height: height, flexibleWidth: flexW, flexibleHeight: flexH))
            y += height
        }
        if inBlock { y = max(y, paddingV + ctx.px(iconSide)) }
        return (out, y + paddingV)
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
        icon?.frame(RECT(left: padding, top: paddingV, right: padding + ctx.px(iconSide), bottom: paddingV + ctx.px(iconSide)))
        glyphRects = [:]
        for (index, (line, g)) in zip(lines, geo.lines).enumerated() {
            let gap = ctx.px(line.gap)
            for c in line.unseen { c.frame(RECT()) }
            if let shape = glyphShape(line) {
                let size = ctx.measure(shape.text, font: shape.font)
                let left = g.x - glyphSlot(line)
                glyphRects[index] = RECT(left: left, top: g.y + (g.height - size.cy) / 2, right: left + size.cx, bottom: g.y + (g.height - size.cy) / 2 + size.cy)
            }
            if !line.center.isEmpty {
                let total = line.center.map(w).reduce(0, +) + gap * Int32(max(0, line.center.count - 1))
                var left = g.x + max(0, (g.width - total) / 2)
                for c in line.center {
                    let cw = w(c), ch = h(c)
                    c.frame(RECT(left: left, top: g.y + (g.height - ch) / 2, right: left + cw, bottom: g.y + (g.height - ch) / 2 + ch))
                    left += cw + gap
                }
                continue
            }
            // Too narrow: the first leading control gives way down to a stub (labels are one line with an ellipsis).
            var lw = line.leading.map(w), tw = line.trailing.map(w)
            let parts = line.leading.count + line.trailing.count + (line.flexible == nil ? 0 : 1)
            let used = lw.reduce(0, +) + tw.reduce(0, +) + gap * Int32(max(0, parts - 1))
            var overflow = line.flexible == nil ? max(0, used - g.width) : 0
            if overflow > 0, !lw.isEmpty {
                let cut = min(overflow, max(0, lw[0] - ctx.px(48)))
                lw[0] -= cut
                overflow -= cut
            }
            var right = g.x + g.width
            for (c, cw) in zip(line.trailing, tw).reversed() {
                let ch = h(c)
                c.frame(RECT(left: right - cw, top: g.y + (g.height - ch) / 2, right: right, bottom: g.y + (g.height - ch) / 2 + ch))
                right -= cw + gap
            }
            var left = g.x
            for (c, cw) in zip(line.leading, lw) {
                let ch = h(c)
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

    /// The card on the page colour (high contrast: an outline, as the notice cards).
    private func paintCard(_ dc: HDC, _ r: RECT) {
        let pal = ctx.colors.palette
        var all = RECT()
        _ = GetClientRect(pane.hwnd, &all)
        var rr = r
        _ = FillRect(dc, &rr, ctx.colors.brush(pal.window))
        defer { paintGlyphs(dc) }
        guard tinted, tint != pal.window || ctx.highContrast else { return }
        // The card's hairline (white on the grey base needs it; high contrast draws an outline in the text colour).
        WinPaint.roundedRect(dc, all, radius: ctx.px(radiusDIP), fill: WinPaint.Ink(color: tint),
                             stroke: WinPaint.Ink(color: ctx.highContrast ? pal.text : pal.cardBorder), strokeWidth: max(1, ctx.px(1)),
                             under: pal.window, ctx: ctx, clip: r)
    }

    private func paintGlyphs(_ dc: HDC) {
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        for (index, line) in lines.enumerated() {
            guard let shape = glyphShape(line), var box = glyphRects[index], let color = line.glyph?.color else { continue }
            let old = SelectObject(dc, UnsafeMutableRawPointer(shape.font))
            _ = SetTextColor(dc, ctx.highContrast ? ctx.colors.palette.text : color)
            _ = WinStr.w(shape.text).withUnsafeBufferPointer {
                DrawTextW(dc, $0.baseAddress, -1, &box, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            _ = SelectObject(dc, old)
        }
    }

    private func destroyChildren() {
        control.onFrame = nil
        control.fitWidth = nil
        pane.paint = nil
        icon?.destroy()
        for line in lines { line.all.forEach { $0.destroy() } }
        icon = nil
        lines = []
        pane.destroy()
    }
}
#endif
