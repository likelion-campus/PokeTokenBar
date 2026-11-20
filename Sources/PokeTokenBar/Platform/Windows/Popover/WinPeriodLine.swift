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
    /// The week's and the month's name, tokens and cost labels (the Mac's `periodLabel`: name tertiary, tokens semibold, cost
    /// secondary, 4 pt apart; the periods 14 pt apart). The cost label of a period without a cost is hidden.
    private(set) var items: [[WinControl]] = []
    private var costShown: [Bool] = []
    private(set) var button: WinControl?
    private(set) var streak: WinControl?
    private var streakShown = false
    private var width: Int32 = 0
    private(set) var arranges = 0, twoLines = false

    private enum Mode { case oneRow, periodsOnTop, stacked }

    init?(parent: HWND, ctx: WinUIContext, periods: [PeriodPair], makeButton: (HWND) -> WinControl?, makeStreak: (HWND) -> WinControl?) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        for p in periods {
            var row: [WinControl] = []
            if let c = WinControls.label(p.name, style: .caption, role: .tertiary, wraps: false, in: made.hwnd, ctx: ctx) { row.append(c) }
            if let c = WinControls.label(p.tokens, style: .caption, weight: 600, wraps: false, in: made.hwnd, ctx: ctx) { row.append(c) }
            if let c = WinControls.label(p.cost ?? "", style: .caption, role: .secondary, wraps: false, in: made.hwnd, ctx: ctx) { row.append(c) }
            items.append(row)
            costShown.append(p.cost != nil)
        }
        streak = makeStreak(made.hwnd)
        button = makeButton(made.hwnd)
        control = WinControls.drawn(made.hwnd, size: .zero, ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
        control.fitWidth = { [self] px in self.fit(px) }
        streak?.setVisible(false)
        for (i, row) in items.enumerated() where row.count == 3 && !costShown[i] { row[2].setVisible(false) }
    }

    private var gap: Int32 { ctx.px(14) }
    private var rowGap: Int32 { ctx.px(6) }
    private var itemGap: Int32 { ctx.px(4) }

    private func size(_ c: WinControl?, shown: Bool = true) -> CGSize { shown ? (c?.preferredSize ?? .zero) : .zero }

    private func shownItems(_ i: Int) -> [WinControl] { items[i].enumerated().filter { $0.offset < 2 || costShown[i] }.map(\.element) }

    private func periodWidth(_ i: Int) -> Int32 {
        let parts = shownItems(i)
        return parts.map { Int32($0.preferredSize.width.rounded(.up)) }.reduce(0, +) + itemGap * Int32(max(0, parts.count - 1))
    }

    private var lineHeight: Int32 { Int32(items.flatMap { $0 }.map { $0.preferredSize.height }.max() ?? 0) }

    private var oneLineWidth: Int32 {
        items.indices.map(periodWidth).reduce(0, +) + gap * Int32(max(0, items.count - 1))
    }

    private func mode(_ w: Int32) -> Mode {
        let streakSize = size(streak, shown: streakShown), buttonSize = size(button)
        let group = (streakShown ? Int32(streakSize.width) + gap : 0) + Int32(buttonSize.width)
        if oneLineWidth + gap + group <= w { return .oneRow }
        return oneLineWidth <= w ? .periodsOnTop : .stacked
    }

    /// Height and layout mode at `w` pixels.
    private func measure(_ w: Int32) -> (height: Int32, mode: Mode) {
        let streakSize = size(streak, shown: streakShown), buttonSize = size(button)
        let groupHeight = Int32(max(streakShown ? streakSize.height : 0, buttonSize.height))
        let line = lineHeight
        switch mode(w) {
        case .oneRow: return (max(line, groupHeight), .oneRow)
        case .periodsOnTop: return (line + rowGap + groupHeight, .periodsOnTop)
        case .stacked:
            let n = Int32(items.count)
            return (n * line + itemGap * max(0, n - 1) + rowGap + groupHeight, .stacked)
        }
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
        twoLines = m.mode != .oneRow
        let streakSize = size(streak, shown: streakShown), buttonSize = size(button)
        let sh = Int32(streakSize.height), bh = Int32(buttonSize.height)
        let groupHeight = max(streakShown ? sh : 0, bh)
        let line = lineHeight
        let periodsHeight: Int32
        switch m.mode {
        case .oneRow: periodsHeight = line
        case .periodsOnTop: periodsHeight = line
        case .stacked: periodsHeight = Int32(items.count) * line + itemGap * Int32(max(0, items.count - 1))
        }
        let groupTop = m.mode == .oneRow ? (m.height - groupHeight) / 2 : periodsHeight + rowGap
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
        var x: Int32 = 0
        var y: Int32 = m.mode == .oneRow ? (m.height - line) / 2 : 0
        for i in items.indices {
            for c in items[i] { if !shownItems(i).contains(where: { $0 === c }) { c.setVisible(false) } }
            for c in shownItems(i) {
                let cw = Int32(c.preferredSize.width.rounded(.up)), ch = Int32(c.preferredSize.height.rounded(.up))
                c.frame(RECT(left: x, top: y + (line - ch) / 2, right: x + cw, bottom: y + (line - ch) / 2 + ch))
                c.setVisible(true)
                x += cw + itemGap
            }
            if m.mode == .stacked { x = 0; y += line + itemGap } else { x += gap - itemGap }
        }
    }

    /// The totals changed: measured again; the page lays out again only when the height changed.
    func setPeriods(_ periods: [PeriodPair]) {
        guard periods.count == items.count else { return }
        for (i, p) in periods.enumerated() {
            let texts = [p.name, p.tokens, p.cost ?? ""]
            costShown[i] = p.cost != nil
            for (c, t) in zip(items[i], texts) where c.text != t {
                c.text = t
                let s = ctx.measure(t, font: c.font)
                c.preferredSize = CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy))
            }
        }
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
        items.flatMap { $0 }.forEach { $0.destroy() }
        items = []
        button?.destroy()
        streak?.destroy()
        pane.destroy()
    }
}

extension WinHomePage {
    /// The week and month line: the totals, the streak's drawn view (hidden until a streak shows) and "Details" (`WinPeriodLine`).
    func makePeriodLine(_ pane: HWND, _ ctx: WinUIContext, _ periods: [PeriodPair]) -> WinPeriodLine? {
        var view: WinDrawnView?
        let line = WinPeriodLine(parent: pane, ctx: ctx, periods: periods, makeButton: { self.makeRecapButton(in: $0, ctx: ctx) }, makeStreak: { child in
            view = try? WinDrawnView(parent: child, ctx: ctx)
            return view?.control
        })
        if let line, let view, let control = view.control { streakSlot = WinActivitySection.StreakSlot(view: view, line: line, control: control) }
        return line
    }
}
#endif
