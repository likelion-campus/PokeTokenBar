#if os(Windows)
import Foundation
import WinSDK

/// One line of several controls in one row of a page (stage 7 Task 5): the Mac's `HStack` of a label, a value and a
/// button. A child pane holds them, so the row sees one control (`.full`) and Tab goes through the children in creation
/// order. The leading ones sit at the left, the trailing ones at the right, everything vertically centred; when the line
/// is too narrow the first leading control (`flexible`) gives way, a label cut with an ellipsis. A child's text or
/// visibility changing re-places the children only (`arrange()`), never the page.
@MainActor final class WinComposite {
    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    private(set) var leading: [WinControl]
    private(set) var trailing: [WinControl]
    private var hidden: Set<ObjectIdentifier> = []
    private var rect = RECT()
    private(set) var arranges = 0

    /// `build` makes the children (as children of the pane window it is given), in reading order.
    init?(parent: HWND, ctx: WinUIContext, build: (HWND) -> (leading: [WinControl], trailing: [WinControl])) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        let parts = build(made.hwnd)
        leading = parts.leading
        trailing = parts.trailing
        // The control's callbacks hold the composite (nothing else does) until the control is destroyed.
        control = WinControls.drawn(made.hwnd, size: .zero, ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        remeasure()
    }

    var children: [WinControl] { leading + trailing }

    /// The line's height: its tallest shown child.
    func remeasure() {
        let height = children.filter { !hidden.contains(ObjectIdentifier($0)) }.map(\.preferredSize.height).max() ?? 0
        control.preferredSize = CGSize(width: 0, height: height)
    }

    func setShown(_ child: WinControl, _ shown: Bool) {
        let was = !hidden.contains(ObjectIdentifier(child))
        guard was != shown else { return }
        if shown { hidden.remove(ObjectIdentifier(child)) } else { hidden.insert(ObjectIdentifier(child)) }
        child.setVisible(shown)
        arrange()
    }

    /// A one-line label's text changed: its size, then the line.
    func setText(_ child: WinControl, _ text: String) {
        guard child.text != text else { return }
        child.text = text
        let s = ctx.measure(text, font: child.font)
        child.preferredSize = CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy))
        arrange()
    }

    private func place(_ r: RECT) {
        rect = r
        WinKit.move(pane.hwnd, r)
        arrange()
    }

    func arrange() {
        arranges += 1
        let width = rect.right - rect.left, height = rect.bottom - rect.top
        guard width > 0 else { return }
        let gap = ctx.px(8)
        let shownLeading = leading.filter { !hidden.contains(ObjectIdentifier($0)) }
        let shownTrailing = trailing.filter { !hidden.contains(ObjectIdentifier($0)) }
        func w(_ c: WinControl) -> Int32 { Int32(c.preferredSize.width.rounded(.up)) }
        func h(_ c: WinControl) -> Int32 { Int32(c.preferredSize.height.rounded(.up)) }
        var lw = shownLeading.map(w), tw = shownTrailing.map(w)
        let between = (shownLeading.isEmpty || shownTrailing.isEmpty) ? Int32(0) : gap
        let gaps = gap * Int32(max(0, shownLeading.count - 1) + max(0, shownTrailing.count - 1)) + between
        var overflow = max(0, lw.reduce(0, +) + tw.reduce(0, +) + gaps - width)
        // Too narrow (long words, Windows' text size): the first leading label gives way down to a stub, then the first
        // trailing one; labels are one line with an ellipsis, so nothing overlaps.
        if overflow > 0, !lw.isEmpty {
            let cut = min(overflow, max(0, lw[0] - ctx.px(48)))
            lw[0] -= cut
            overflow -= cut
        }
        if overflow > 0, !tw.isEmpty {
            let cut = min(overflow, max(0, tw[0] - ctx.px(24)))
            tw[0] -= cut
            overflow -= cut
        }
        var right = width
        for (c, cw) in zip(shownTrailing, tw).reversed() {
            let x = right - cw
            c.frame(RECT(left: x, top: (height - h(c)) / 2, right: right, bottom: (height - h(c)) / 2 + h(c)))
            right = x - gap
        }
        var left: Int32 = 0
        for (c, cw) in zip(shownLeading, lw) {
            c.frame(RECT(left: left, top: (height - h(c)) / 2, right: left + cw, bottom: (height - h(c)) / 2 + h(c)))
            left += cw + gap
        }
    }

    private func destroyChildren() {
        control.onFrame = nil  // the cycle ends here
        for c in children { c.destroy() }
        leading = []
        trailing = []
        pane.destroy()
    }
}
#endif
