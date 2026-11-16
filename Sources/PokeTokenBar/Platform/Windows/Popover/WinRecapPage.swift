#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The usage recap page of the popover (stage 7 Task 13): the Mac's `RecapScreen` built from the shared `RecapPageModel`.
/// Nothing here calculates or formats: every text, number and enable state comes from the model (`PopoverRecapContent` is the
/// twin of the Mac's `RecapContent`), this file only places it.
///
/// Top to bottom, as the Mac stacks it: Back and the Week | Month | Year group; Previous, the running period's button and Next;
/// the card (a drawn part, `RecapCardPart`: fixed colours, monospaced digits, per-meter accessibility and tooltips); the best-day
/// line and the "compared so far" note when there are any. Back and Escape leave the page (the popover swaps Home in place, like
/// Settings: `WinSettingsPage.routed`). Choosing a scope starts at the running period; Previous is disabled where the ledger
/// has no earlier day, Next at the running period.
///
/// The page is static: no timer and no clock. It observes the stores while it exists (one-shot tracking, re-armed per change)
/// so a refresh that fills the ledger shows. The buttons are made again when what they say or allow changes (the keyboard stays
/// on the same button); the card is updated in place.
@MainActor final class WinRecapPage: WinPopoverPage {
    let store: UsageStore
    let companion: CompanionStore
    private weak var popover: WinPopover?
    /// What Back and Escape do (the Mac's `onBack`).
    var onBack: () -> Void
    var now: () -> Date
    var calendar: () -> Calendar
    /// The sprites in the card's slots; the selftest injects a fixture fetcher.
    var makeSprites: () -> WinSpriteAnimator? = { WinSpriteAnimator() }

    /// The period shown (the selftest sets the start before the page is built).
    var navigation = RecapNavigation()
    private(set) var last: RecapPageModel?
    private(set) var heightDIP: CGFloat = 420
    private(set) var stack: WinStack?
    private var area: WinScrollArea?
    private var ctx: WinUIContext!
    private var epoch = 0
    private(set) var isDestroyed = false

    private struct Sections {
        var top: WinSectionCard, nav: WinSectionCard, card: WinSectionCard, notes: WinSectionCard
    }
    private var sections: Sections?
    /// The controls the selftest and the focus keeper read, by action name: back, scope, previous, current, next.
    private(set) var controls: [String: WinControl] = [:]
    private(set) var cardView: WinDrawnView?
    private(set) var cardPart: RecapCardPart?
    private var composites: [WinComposite] = []
    private(set) var renders: [String: Int] = [:]

    init(store: UsageStore, companion: CompanionStore, popover: WinPopover? = nil, now: @escaping () -> Date = { Date() },
         calendar: @escaping () -> Calendar = { RecapPeriod.calendar() }, onBack: @escaping () -> Void) {
        self.store = store
        self.companion = companion
        self.popover = popover
        self.now = now
        self.calendar = calendar
        self.onBack = onBack
    }

    /// The page `popover.state` asks for when the recap is up: Back leaves it in place (the Mac's `nav.showingRecap = false`).
    static func routed(_ popover: WinPopover) -> WinPopoverPage {
        WinRecapPage(store: popover.host.store, companion: popover.host.companion, popover: popover) { [weak popover] in
            popover?.state.showingRecap = false
            popover?.replacePage()
        }
    }

    // MARK: WinPopoverPage

    func build(in window: WinSinkWindow, ctx: WinUIContext, client: RECT) {
        guard let made = try? WinScrollArea(parent: window.hwnd, ctx: ctx, rect: client) else {
            AppLog.write("recap page: no scroll area (\(GetLastError()))")
            return
        }
        let page = WinStack(pane: made.content, width: made.contentWidth)
        page.onHeight = { [weak self, weak made] h in
            made?.setContentHeight(h)
            self?.contentHeightChanged(h)
        }
        area = made
        attach(stack: page)
    }

    /// Builds the page into `page` (the popover's own, or a test window's), applies the model and starts observing.
    func attach(stack page: WinStack) {
        isDestroyed = false
        last = nil
        epoch += 1
        stack = page
        ctx = page.ctx
        sections = Sections(top: page.addSection(nil, card: false), nav: page.addSection(nil, card: false),
                            card: page.addSection(nil, card: false), notes: page.addSection(nil, card: false))
        observe()
        page.layout()
        // The Mac's `.task { await companion.backfillMissingDexNames() }`: the graduates' names, filled in once; the page
        // follows through its observation.
        let companion = self.companion
        Task { @MainActor in await companion.backfillMissingDexNames() }
    }

    func layout(client: RECT) {
        guard let area, let stack else { return }
        area.move(client)
        stack.width = area.contentWidth
        stack.layout()
    }

    var initialFocus: HWND? { nil }

    func escape() -> Bool {
        onBack()
        return true
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        stack?.destroy()   // destroys every control, the drawn view (and its sprites) with them
        area?.destroy()
        composites = []
        controls = [:]
        cardView = nil
        cardPart = nil
        sections = nil
        stack = nil
        area = nil
    }

    // MARK: height

    /// "Recap fits its content" (D2): the window is as tall as the page, within what the work area allows (the popover clamps).
    private func contentHeightChanged(_ pixels: Int32) {
        guard let ctx, ctx.scale > 0 else { return }
        let next = min(640, max(260, (CGFloat(pixels) / ctx.scale).rounded(.up)))
        guard abs(next - heightDIP) >= 1 else { return }
        heightDIP = next
        let generation = popover?.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDestroyed, let popover = self.popover, popover.generation == generation else { return }
            popover.pageSizeChanged()
        }
    }

    // MARK: observing

    func observe() {
        guard !isDestroyed else { return }
        let mine = epoch
        let nav = navigation
        let model = withObservationTracking {
            RecapPageModel.make(store: store, companion: companion, navigation: nav, now: now(), calendar: calendar())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine else { return }
                self.observe()
            }
        }
        apply(model)
    }

    /// The model of the current navigation, without arming the observation again (a button was pressed).
    private func refresh() {
        guard !isDestroyed else { return }
        apply(RecapPageModel.make(store: store, companion: companion, navigation: navigation, now: now(), calendar: calendar()))
    }

    // MARK: applying a model

    private struct Chrome: Equatable {
        var back: String, scopeNames: [String], selectedScope: Int, previous: String, canGoBack: Bool, current: String
        var canGoToCurrent: Bool, next: String, canGoForward: Bool
        init(_ m: RecapPageModel) {
            back = m.back; scopeNames = m.scopeNames; selectedScope = m.selectedScope; previous = m.previous; canGoBack = m.canGoBack
            current = m.current; canGoToCurrent = m.canGoToCurrent; next = m.next; canGoForward = m.canGoForward
        }
    }

    func apply(_ m: RecapPageModel) {
        guard !isDestroyed, let s = sections else { return }
        let first = last == nil
        if first || Chrome(last!) != Chrome(m) { renderChrome(m, s) }
        if first { renderCard(m, s.card) } else { cardPart?.update(m.card) }
        if first || last!.bestDayLine != m.bestDayLine || last!.compareSoFar != m.compareSoFar { renderNotes(m, s.notes) }
        last = m
    }

    private func focusedName() -> String? {
        guard let focus = GetFocus() else { return nil }
        for (name, c) in controls where c.parts.contains(where: { $0 == focus || IsChild($0, focus) }) { return name }
        return nil
    }

    private func restoreFocus(_ name: String?) {
        guard let name else { return }
        // A button that became disabled cannot keep it: Back takes it, so Escape and Tab still start somewhere sensible.
        let target = controls[name].flatMap { $0.isEnabled ? $0 : nil } ?? controls["back"]
        guard let c = target else { return }
        let hwnd: HWND? = c.kind == .radioGroup ? c.parts[max(0, min(c.parts.count - 1, c.selection))] : c.hwnd
        if let hwnd { _ = SetFocus(hwnd) }
    }

    private func renderChrome(_ m: RecapPageModel, _ s: Sections) {
        let kept = focusedName()
        s.top.removeRows()
        s.nav.removeRows()
        composites = []
        controls = [:]
        let nav = m.navigation
        s.top.addStyledRow(label: nil, style: .full) { pane, ctx in
            let line = WinComposite(parent: pane, ctx: ctx) { child in
                let back = WinControls.link("‹ " + m.back, in: child, ctx: ctx)
                back?.onClick = { [weak self] in self?.onBack() }
                let scope = WinControls.radioGroup(m.scopeNames, selected: m.selectedScope, in: child, ctx: ctx)
                scope?.onSelect = { [weak self] i in
                    guard let self, i < RecapScope.allCases.count else { return }
                    self.navigation.select(RecapScope.allCases[i])
                    self.refresh()
                }
                if let back { self.controls["back"] = back }
                if let scope { self.controls["scope"] = scope }
                return ([back].compactMap { $0 }, [scope].compactMap { $0 })
            }
            if let line { self.composites.append(line) }
            return line?.control
        }
        s.nav.addStyledRow(label: nil, style: .full) { pane, ctx in
            let line = WinComposite(parent: pane, ctx: ctx) { child in
                let previous = WinControls.button("‹ " + m.previous, in: child, ctx: ctx)
                previous?.isEnabled = m.canGoBack
                previous?.onClick = { [weak self] in
                    guard let self else { return }
                    self.navigation.goBack(canGoBack: self.last?.canGoBack ?? false)
                    self.refresh()
                }
                let current = WinControls.button(m.current, in: child, ctx: ctx)
                current?.isEnabled = m.canGoToCurrent
                current?.onClick = { [weak self] in
                    self?.navigation.goToCurrent()
                    self?.refresh()
                }
                let next = WinControls.button(m.next + " ›", in: child, ctx: ctx)
                next?.isEnabled = nav.canGoForward
                next?.onClick = { [weak self] in
                    self?.navigation.goForward()
                    self?.refresh()
                }
                if let previous { self.controls["previous"] = previous }
                if let current { self.controls["current"] = current }
                if let next { self.controls["next"] = next }
                return ([previous].compactMap { $0 }, [current, next].compactMap { $0 })
            }
            if let line { self.composites.append(line) }
            return line?.control
        }
        renders["chrome", default: 0] += 1
        restoreFocus(kept)
    }

    private func renderCard(_ m: RecapPageModel, _ section: WinSectionCard) {
        let widthDIP = CGFloat(innerWidth) / ctx.scale
        let sprites = makeSprites()
        section.addStyledRow(label: nil, style: .full) { pane, ctx in
            guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            let part = RecapCardPart(m.card)
            view.host(part, width: widthDIP)
            view.sprites = sprites
            self.cardView = view
            self.cardPart = part
            return view.control
        }
        renders["card", default: 0] += 1
    }

    private func renderNotes(_ m: RecapPageModel, _ section: WinSectionCard) {
        section.removeRows()
        let lines = [m.bestDayLine, m.compareSoFar].compactMap { $0 }
        section.isVisible = !lines.isEmpty
        for line in lines {
            section.addStyledRow(label: { pane, ctx in
                WinControls.label(line, style: .caption, role: .secondary, in: pane, ctx: ctx)
            }, style: .trailing)
        }
        renders["notes", default: 0] += 1
    }

    /// The page's inner width in pixels (what a `.full` row gets).
    private var innerWidth: Int32 {
        guard let stack else { return 0 }
        return stack.width - 2 * Int32(ctx.metrics.pagePadding)
    }
}

extension WinHomePage {
    /// The recap button under the week and month line: "Details", its tooltip "Usage recap" (the Mac's chart button, `help`
    /// and accessibility label). A row of its own at the right; Task 12's streak badge shares this line on the Mac.
    func addRecapButton(to section: WinSectionCard) {
        let l = L(companion.language)
        section.addStyledRow(label: nil, style: .trailing) { pane, ctx in
            guard let c = WinControls.button(l.recapDetails, in: pane, ctx: ctx) else { return nil }
            c.tooltip = l.recapOpen
            c.onClick = { [weak self] in self?.openRecap?() }
            self.recapButton = c
            return c
        }
    }
}
#endif
