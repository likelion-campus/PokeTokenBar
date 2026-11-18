#if os(Windows)
import Foundation
import WinSDK

// MARK: stage 7 parity — the Collection's search field as the Mac's (a rounded frame, the magnifier inside, the clear button inside)

/// The Mac's `filterToolbar` field: a 6 pt rounded frame in the control-background colour with a hairline border, a magnifier on the
/// left, the borderless text field, and the clear button (✕) on the right while there is text. The frame is the pane's own painting
/// (owner drawn, from the palette's roles, so it follows the colour scheme); the field is a native borderless `EDIT` with its cue
/// banner, the clear button a kit glyph button. One control in the toolbar line; its height follows the field's.
@MainActor final class WinSearchBox {
    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    private(set) var edit: WinControl?
    private(set) var clear: WinControl?
    private var nameLabel: WinControl?
    private var rect = RECT()
    private var glyph: (text: String, font: HFONT?)?

    init?(parent: HWND, ctx: WinUIContext, cue: String, clearLabel: String) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        // the static right before the field is its accessible name
        nameLabel = WinControls.label(cue, wraps: false, in: made.hwnd, ctx: ctx)
        nameLabel?.frame(RECT())
        edit = WinControls.edit(.text(cue: cue), bordered: false, in: made.hwnd, ctx: ctx)
        clear = WinControls.glyphButton(symbol: "xmark.circle.fill", label: clearLabel, size: 13, in: made.hwnd, ctx: ctx)
        if let g = WinGlyphs.text(symbol: "magnifyingglass", fluent: ctx.fonts.iconIsFluent) { glyph = (g, ctx.fonts.icon(size: 13)) }
        let line = ctx.lineHeight(edit?.font)
        control = WinControls.drawn(made.hwnd, size: CGSize(width: 100_000, height: CGFloat(line + 2 * ctx.px(5))), ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        pane.paint = { [weak self] dc, dirty in self?.draw(dc, dirty) }
    }

    private func place(_ r: RECT) {
        rect = r
        WinKit.move(pane.hwnd, r)
        let w = r.right - r.left, h = r.bottom - r.top
        let line = ctx.lineHeight(edit?.font)
        let iconW = ctx.px(16), pad = ctx.px(8)
        var right = w - ctx.px(2)
        if let clear {
            let side = Int32(clear.preferredSize.width.rounded(.up))
            clear.frame(RECT(left: right - side, top: (h - side) / 2, right: right, bottom: (h - side) / 2 + side))
            right -= side
        }
        let left = pad + iconW + ctx.px(4)
        edit?.frame(RECT(left: left, top: (h - line) / 2, right: max(left + 10, right - ctx.px(2)), bottom: (h - line) / 2 + line))
        _ = InvalidateRect(pane.hwnd, nil, false)
    }

    /// The frame and the magnifier, drawn under the children.
    private func draw(_ dc: HDC, _ dirty: RECT) {
        let colors = ctx.colors
        var r = dirty
        _ = FillRect(dc, &r, colors.brush(colors.palette.window))
        let w = rect.right - rect.left, h = rect.bottom - rect.top
        guard w > 0, h > 0 else { return }
        let pen = CreatePen(0 /* PS_SOLID */, max(1, ctx.px(1) / 2), colors.palette.cardBorder)
        let oldPen = SelectObject(dc, UnsafeMutableRawPointer(pen))
        let oldBrush = SelectObject(dc, UnsafeMutableRawPointer(colors.brush(colors.palette.field)))  // the edit's own colour (white in light)
        let radius = 2 * ctx.px(6)
        _ = RoundRect(dc, 0, 0, w, h, radius, radius)
        _ = SelectObject(dc, oldBrush)
        _ = SelectObject(dc, oldPen)
        _ = DeleteObject(UnsafeMutableRawPointer(pen))
        if let glyph {
            let old = SelectObject(dc, UnsafeMutableRawPointer(glyph.font))
            _ = SetBkMode(dc, 1 /* TRANSPARENT */)
            _ = SetTextColor(dc, colors.palette.secondaryText)
            var box = RECT(left: ctx.px(8), top: 0, right: ctx.px(8) + ctx.px(16), bottom: h)
            _ = WinStr.w(glyph.text).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &box, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX)) }
            _ = SelectObject(dc, old)
        }
    }

    private func destroyChildren() {
        control.onFrame = nil
        edit?.destroy()
        clear?.destroy()
        nameLabel?.destroy()
        pane.paint = nil
        pane.destroy()
    }
}
#endif
