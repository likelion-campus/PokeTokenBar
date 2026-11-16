#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The Home page's activity panel and streak (stage 7 Task 12; the Mac's `ActivityPanel` and `StreakBadge`): a row for the
/// streak (flame and days, right-aligned, shown from two days) and a row for the chart, a drawn part (`TrendBarsPart` or
/// `HeatmapPart`) that is also one button item ("<readout>, switch view"): a click or Enter cycles the visualization
/// (persisted by the store), the caption's window title opens the window menu, the pointer or the arrow keys select a day
/// (the bars show its card in a pop-up, the heatmap its readout in the caption), Escape clears the selection. With no
/// usage at all both rows are hidden, as the Mac draws nothing.
///
/// It reads the stores through its own observation (`ActivityPanelModel.make` inside `withObservationTracking`; one rebuild
/// per main-queue turn), so the page's model and the Home regions are untouched. Nothing here has a timer: the picture
/// changes with the data, the size, or the selection; a hover redraws the columns only.
@MainActor final class WinActivitySection {
    enum Active { case none, bars, heatmap }

    /// The streak's view where the Home page's period line holds it (beside the recap button, as on the Mac).
    struct StreakSlot {
        var view: WinDrawnView
        var composite: WinComposite
        var control: WinControl
    }

    let store: UsageStore?
    let companion: CompanionStore?
    let facts: PopoverPlatformFacts
    let section: WinSectionCard
    private let stack: WinStack
    var now: () -> Date = { Date() }
    /// A fixed model instead of the stores' (the selftest's sample panels); nothing is observed then.
    var modelOverride: ((Date) -> ActivityPanelModel)?
    /// What a click does (the store's `activityVisualization.next` by default; the selftest records instead).
    var cycle: () -> Void
    var chooseWindow: (DailyTrendWindow) -> Void
    /// The window menu: the real popup, or a stand-in in the selftest. (items, where, owner) -> chosen index.
    var menu: @MainActor ([TrayMenuModel.Item?], POINT, HWND) -> Int? = { items, point, owner in
        WinPopupMenu.run(items, at: point, owner: owner, below: true)
    }

    private(set) var model = ActivityPanelModel()
    private(set) var streakRow: WinRow?, panelRow: WinRow?
    private(set) var streakView: WinDrawnView?, panelView: WinDrawnView?
    private(set) var streakPart: StreakPart?, bars: TrendBarsPart?, heat: HeatmapPart?
    private(set) var active = Active.none
    private(set) var card: WinHoverCard?
    private var epoch = 0
    private(set) var observes = 0, applies = 0, menus = 0, cycles = 0
    private(set) var isDestroyed = false

    private var slot: StreakSlot?

    init(stack: WinStack, section: WinSectionCard, store: UsageStore?, companion: CompanionStore?, facts: PopoverPlatformFacts, streak: StreakSlot? = nil) {
        self.stack = stack
        self.section = section
        self.store = store
        self.companion = companion
        self.facts = facts
        cycle = { if let store { store.activityVisualization = store.activityVisualization.next } }
        chooseWindow = { w in store?.dailyTrendWindow = w }
        var sv: WinDrawnView?, pv: WinDrawnView?
        if let streak {
            slot = streak
            sv = streak.view
            streak.control.onSizeChange = { [weak composite = streak.composite] in composite?.remeasure(); composite?.arrange() }
        } else {
            streakRow = section.addStyledRow(label: nil, style: .trailing) { pane, ctx in  // no Home line to share (a lone panel)
                sv = try? WinDrawnView(parent: pane, ctx: ctx)
                return sv?.control
            }
        }
        panelRow = section.addStyledRow(label: nil, style: .full) { pane, ctx in
            pv = try? WinDrawnView(parent: pane, ctx: ctx)
            return pv?.control
        }
        streakView = sv
        panelView = pv
        streakRow?.isVisible = false
        panelRow?.isVisible = false
        section.isVisible = false
        wire()
    }

    var ctx: WinUIContext { stack.ctx }

    /// The row's width in DIP (the page's inner width).
    private var widthDIP: CGFloat { CGFloat(stack.width - 2 * Int32(ctx.metrics.pagePadding)) / ctx.scale }

    private func wire() {
        guard let view = panelView else { return }
        view.onPointer = { [weak self] p in self?.pointer(p) }
        view.onKey = { [weak self] key in self?.key(key) ?? false }
        view.onFocus = { [weak self] focused in self?.focus(focused) }
        view.claimsEscape = { [weak self] in (self?.bars?.keyboardDate ?? self?.heat?.keyboardDate) != nil }
        view.onHit = { [weak self] hit in self?.hit(hit) }
    }

    // MARK: observing

    func observe() {
        guard !isDestroyed else { return }
        observes += 1
        if let modelOverride {
            apply(modelOverride(now()))
            return
        }
        guard let store, let companion else { return }
        let mine = epoch
        let facts = self.facts
        let made = withObservationTracking {
            ActivityPanelModel.make(ActivityInput(store: store, companion: companion, facts: facts, today: LocalUsageReader.localDayFormatter().string(from: now())))
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine, !self.isDestroyed else { return }
                self.observe()
            }
        }
        apply(made)
    }

    func apply(_ m: ActivityPanelModel) {
        guard !isDestroyed else { return }
        applies += 1
        model = m
        // the streak
        if let s = m.streak, let view = streakView {
            if let part = streakPart {
                part.update(s)
            } else {
                let part = StreakPart(s)
                streakPart = part
                view.host(part, width: widthDIP)
            }
            streakRow?.isVisible = true
            if let slot { slot.composite.setShown(slot.control, true); slot.composite.arrange() }
        } else {
            streakRow?.isVisible = false
            if let slot { slot.composite.setShown(slot.control, false) }
        }
        // the chart
        switch m.content {
        case .bars(let b)?:
            if let part = bars {
                part.update(b, cardInfo: m.cardInfo)
            } else {
                let part = TrendBarsPart(b, cardInfo: m.cardInfo)
                part.onSelection = { [weak self] in self?.updateCard() }
                bars = part
            }
            if let part = bars {
                part.accent = Self.plazaColor(ctx.colors.palette.accent)
                part.cardBackground = Self.plazaColor(ctx.colors.palette.window)
                if active != .bars, let view = panelView { view.host(part, width: widthDIP); active = .bars; hideCard() }
            }
            panelRow?.isVisible = true
        case .heatmap(let h)?:
            if let part = heat {
                part.update(h, readout: m.heatReadout)
            } else {
                heat = HeatmapPart(h, readout: m.heatReadout)
            }
            if let part = heat, active != .heatmap, let view = panelView { view.host(part, width: widthDIP); active = .heatmap; hideCard() }
            panelRow?.isVisible = true
        case nil:
            panelRow?.isVisible = false
            hideCard()
        }
        section.isVisible = (streakRow?.isVisible ?? false) || (panelRow?.isVisible ?? false)  // the streak in the period line needs no section
    }

    // MARK: pointer, keys, hits

    private func pointer(_ p: CGPoint?) {
        switch active {
        case .bars: bars?.pointerMoved(p)
        case .heatmap: heat?.pointerMoved(p)
        case .none: break
        }
    }

    private func key(_ vk: Int) -> Bool {
        switch active {
        case .bars: return bars?.key(vk) ?? false
        case .heatmap: return heat?.key(vk) ?? false
        case .none: return false
        }
    }

    private func focus(_ focused: Bool) {
        switch active {
        case .bars: bars?.focusChanged(focused)
        case .heatmap: heat?.focusChanged(focused)
        case .none: break
        }
    }

    private func hit(_ hit: PlazaPanelHit) {
        switch hit.action {
        case "cycle":
            cycles += 1
            hideCard()
            cycle()
        case "window": showWindowMenu()
        default: break
        }
    }

    /// The window menu under the caption's title (the Mac's `Menu`): a popup the user picks the trend window from.
    func showWindowMenu() {
        guard active == .bars, let part = bars, let view = panelView else { return }
        hideCard()
        menus += 1
        let items: [TrayMenuModel.Item?] = part.model.choices.map { TrayMenuModel.Item(title: $0.title, enabled: true, checked: $0.checked, action: .none) }
        let rect = part.titleRect(graphics: PlatformPlaza.graphics)
        var at = POINT(x: Int32((rect.minX * ctx.scale).rounded()), y: Int32((rect.maxY * ctx.scale).rounded()) + ctx.px(2))
        _ = ClientToScreen(view.hwnd, &at)
        let owner = GetAncestor(view.hwnd, UINT(GA_ROOT)) ?? view.hwnd
        if let i = menu(items, at, owner), part.model.choices.indices.contains(i) { chooseWindow(part.model.choices[i].window) }
    }

    // MARK: the card

    /// Shows, moves or hides the day's card to match the selection.
    func updateCard() {
        guard !isDestroyed, let part = bars, active == .bars, let view = panelView,
              let c = part.card(scale: ctx.scale, graphics: PlatformPlaza.graphics) else { hideCard(); return }
        var at = POINT(x: Int32((c.frame.minX * ctx.scale).rounded()), y: Int32((c.frame.minY * ctx.scale).rounded()))
        _ = ClientToScreen(view.hwnd, &at)
        if card == nil { card = WinHoverCard(owner: GetAncestor(view.hwnd, UINT(GA_ROOT)) ?? view.hwnd) }
        card?.show(c.drawing, size: c.frame.size, scale: ctx.scale, at: at)
    }

    private func hideCard() { card?.hide() }

    static func plazaColor(_ c: COLORREF) -> PlazaColor {
        PlazaColor(srgbRed: Double(c & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double((c >> 16) & 0xFF) / 255)
    }

    // MARK: closing

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        card?.destroy()
        card = nil
        bars = nil
        heat = nil
        streakPart = nil
        // The views free their pictures when destroyed (the rows' controls would do it too, but only while the view is alive
        // to be told): destroy them here, before the page forgets them.
        panelView?.destroy()
        if slot == nil { streakView?.destroy() }  // the header's controls own a slot's view
        panelView?.onPointer = nil
        panelView?.onKey = nil
        panelView?.onFocus = nil
        panelView?.claimsEscape = nil
        panelView?.onHit = nil
        streakView = nil
        panelView = nil
    }
}

extension WinHomePage {
    /// The control at the right end of the week and month line (the Mac's `periodTotals` ... `StreakBadge`, `recapButton`): the
    /// streak's drawn view (hidden until a streak shows) and the "Details" button, in one line.
    func makePeriodTrailing(_ pane: HWND, _ ctx: WinUIContext) -> WinControl? {
        var view: WinDrawnView?, button: WinControl?
        let composite = WinComposite(parent: pane, ctx: ctx) { child in
            view = try? WinDrawnView(parent: child, ctx: ctx)
            button = self.makeRecapButton(in: child, ctx: ctx)
            return ([], [view?.control, button].compactMap { $0 })
        }
        guard let composite else { return nil }
        if let view, let control = view.control {
            streakSlot = WinActivitySection.StreakSlot(view: view, composite: composite, control: control)
            composite.setShown(control, false)
        }
        return composite.control
    }
}
#endif
