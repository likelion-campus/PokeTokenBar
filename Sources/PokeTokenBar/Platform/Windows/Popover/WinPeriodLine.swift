#if os(Windows)
import Foundation
import WinSDK

/// The Home header's week and month line (stage 7 Tasks 12 and 13; the Mac's `ViewThatFits` of `periodTotals`, the streak badge
/// and the recap button): when everything fits one line, the totals sit at the left and the streak and "Details" at the right
/// (spacing 14); when it does not, the totals take a line of their own and the streak and "Details" go below, right-aligned
/// (spacing 6), as the Mac's second layout does. The page measures it at the row's width (`fitWidth`) and lays out again when
/// the totals, the streak or the width change; nothing else moves.
@MainActor final class WinPeriodLine {
    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    let label: WinControl
    private(set) var button: WinControl?
    private(set) var streak: WinControl?
    private var streakShown = false
    private var width: Int32 = 0
    private(set) var arranges = 0, twoLines = false

    init?(parent: HWND, ctx: WinUIContext, text: String, makeButton: (HWND) -> WinControl?, makeStreak: (HWND) -> WinControl?) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)),
              let periods = WinControls.label(text, style: .callout, role: .secondary, wraps: true, in: made.hwnd, ctx: ctx) else { return nil }
        pane = made
        self.ctx = ctx
        label = periods
        streak = makeStreak(made.hwnd)
        button = makeButton(made.hwnd)
        control = WinControls.drawn(made.hwnd, size: .zero, ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        control.fitWidth = { [self] px in self.fit(px) }
        streak?.setVisible(false)
    }

    private var gap: Int32 { ctx.px(14) }
    private var rowGap: Int32 { ctx.px(6) }

    private func size(_ c: WinControl?, shown: Bool = true) -> CGSize { shown ? (c?.preferredSize ?? .zero) : .zero }

    /// Height and layout mode at `w` pixels.
    private func measure(_ w: Int32) -> (height: Int32, twoLines: Bool, labelHeight: Int32) {
        let one = label.size(width: 0x7FFF)
        let streakSize = size(streak, shown: streakShown), buttonSize = size(button)
        let group = (streakShown ? Int32(streakSize.width) + gap : 0) + Int32(buttonSize.width)
        let groupHeight = Int32(max(streakShown ? streakSize.height : 0, buttonSize.height))
        if Int32(one.width) + gap + group <= w { return (max(Int32(one.height), groupHeight), false, Int32(one.height)) }
        let wrapped = Int32(label.size(width: max(1, w)).height)
        return (wrapped + rowGap + groupHeight, true, wrapped)
    }

    /// The page asks the line's height at its row width; true when it changed.
    private func fit(_ px: Int32) -> Bool {
        width = px
        let h = measure(px).height
        let changed = Int32(control.preferredSize.height) != h
        control.preferredSize = CGSize(width: 0, height: CGFloat(h))
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
        let m = measure(width)
        twoLines = m.twoLines
        let streakSize = size(streak, shown: streakShown), buttonSize = size(button)
        let sh = Int32(streakSize.height), bh = Int32(buttonSize.height)
        let groupHeight = max(streakShown ? sh : 0, bh)
        let groupTop = m.twoLines ? m.labelHeight + rowGap : (m.height - groupHeight) / 2
        var right = width
        if let button {
            let bw = Int32(buttonSize.width)
            button.frame(RECT(left: right - bw, top: groupTop + (groupHeight - bh) / 2, right: right, bottom: groupTop + (groupHeight - bh) / 2 + bh))
            right -= bw + gap
        }
        if let streak, streakShown {
            let sw = Int32(streakSize.width)
            streak.frame(RECT(left: right - sw, top: groupTop + (groupHeight - sh) / 2, right: right, bottom: groupTop + (groupHeight - sh) / 2 + sh))
            right -= sw + gap
        }
        let labelHeight = m.labelHeight
        let top = m.twoLines ? 0 : (m.height - labelHeight) / 2
        let labelRight = m.twoLines ? width : max(1, right)  // `right` is now the group's left edge less one gap
        label.frame(RECT(left: 0, top: top, right: labelRight, bottom: top + labelHeight))
    }

    /// The totals changed: measured again; the page lays out again only when the height changed.
    func setText(_ text: String) {
        guard label.text != text else { return }
        label.text = text
        relayout()
    }

    func setStreak(shown: Bool) {
        guard streakShown != shown else { return }
        streakShown = shown
        streak?.setVisible(shown)
        relayout()
    }

    /// The streak's size changed (more digits).
    func relayout() {
        if fit(width) { control.onSizeChange?() }
        arrange()
    }

    private func destroyChildren() {
        control.onFrame = nil
        control.fitWidth = nil
        label.destroy()
        button?.destroy()
        streak?.destroy()
        pane.destroy()
    }
}

extension WinHomePage {
    /// The week and month line: the totals, the streak's drawn view (hidden until a streak shows) and "Details" (`WinPeriodLine`).
    func makePeriodLine(_ pane: HWND, _ ctx: WinUIContext, _ text: String) -> WinPeriodLine? {
        var view: WinDrawnView?
        let line = WinPeriodLine(parent: pane, ctx: ctx, text: text, makeButton: { self.makeRecapButton(in: $0, ctx: ctx) }, makeStreak: { child in
            view = try? WinDrawnView(parent: child, ctx: ctx)
            return view?.control
        })
        if let line, let view, let control = view.control { streakSlot = WinActivitySection.StreakSlot(view: view, line: line, control: control) }
        return line
    }
}
#endif
