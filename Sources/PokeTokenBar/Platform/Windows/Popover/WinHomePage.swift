#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The Home page of the Windows popover (stage 7 Task 5): the Mac's Home, built from the shared `HomeModel` with the native
/// kit. Nothing here calculates or formats a number: every text, colour role and enable state comes from the model; this
/// file only places it (D6) and applies what changed (D10).
///
/// Data flow: the page builds the model inside `withObservationTracking`; a change schedules one rebuild per main-queue turn
/// (the tracking is one-shot, so changes within a turn coalesce). `apply` compares the new model with the last, region by
/// region: a region whose part of the model is equal is left alone; the header and the footer update their texts in place;
/// the other regions make their rows again, keeping the keyboard focus on the same row. `renders` counts each region's
/// renders (the selftest's evidence that an unrelated change re-renders nothing else).
///
/// The "x minutes ago" text and the reset countdowns tick through one `PopoverClock`, armed only while one of them is on
/// screen and only while the page exists: a closed popover has no timer.
///
/// Regions, top to bottom: update banner, plaza button, today's header, provider tabs, provider row, status banner,
/// official limits (`WinLimitsSection.swift`), footer.
@MainActor final class WinHomePage: WinPopoverPage {
    /// A relative text on screen: the control showing it, what it is made of, and the line it sits in.
    struct RelativeBinding {
        var control: WinControl
        var text: RelativeText
        var composite: WinComposite?
    }

    let store: UsageStore
    let companion: CompanionStore
    let updater: UpdateChecker?
    let team: TeamSettings
    let feed: TeamFeedStore?
    let state: PopoverState
    let facts: PopoverPlatformFacts
    var now: () -> Date
    /// What a control does; `HomeModel.perform` by default (the selftest records instead).
    var performAction: (HomeAction) -> Void
    /// A fixed model instead of the stores' (the selftest's sample pages); nothing is observed then.
    var modelOverride: ((Date) -> HomeModel)?
    let heightDIP: CGFloat = 600
    // MARK: Task 13 — the recap button's action (the Mac's `nav.showingRecap = true`)
    /// Swaps the recap page in (set by the app's page; a kit window has no popover to swap).
    var openRecap: (() -> Void)?
    var recapButton: WinControl?
    // MARK: end Task 13

    private(set) var stack: WinStack?
    private var area: WinScrollArea?
    var ctx: WinUIContext!
    let clock: PopoverClock
    private(set) var isDestroyed = false
    private var epoch = 0
    /// The provider whose limits are being rendered (a provider-specific section may add its own help) and the help's state.
    var providerID: String?
    var credentialHelpOpen = false
    private(set) var last: HomeModel?
    /// Renders per region, and how often the model was applied (the selftest's render counts).
    private(set) var renders: [String: Int] = [:]
    private(set) var applies = 0
    private(set) var observes = 0

    struct Sections {
        var banner: WinSectionCard, plaza: WinSectionCard, header: WinSectionCard
        var activity: WinSectionCard  // stage 7 Task 12 (WinActivitySection.swift): the streak and the chart, between the totals and the tabs
        var tabs: WinSectionCard
        var provider: WinSectionCard, status: WinSectionCard, limits: WinSectionCard, footer: WinSectionCard
        /// The Mac's three `Divider()`s: under the companion header, under the totals group, under the limits.
        var ruleCompanion: WinSectionCard, ruleTotals: WinSectionCard, ruleLimits: WinSectionCard
    }
    var sections: Sections?
    private var headerParts: HeaderParts?
    /// The streak and the chart (stage 7 Task 12); the selftest reads it.
    private(set) var activityPanel: WinActivitySection?
    /// The streak's drawn view and the line it shares with the recap button (made with the header; `makePeriodTrailing`).
    var streakSlot: WinActivitySection.StreakSlot?
    private var footerParts: FooterParts?
    var relative: [String: [RelativeBinding]] = [:]
    /// The limit bars' drawn views (their pictures are freed with their rows).
    var bars: [WinDrawnView] = []
    /// Stage 7 Task 9: the companion header (`WinCompanionSection.swift`), and what a harness sets on it before it starts
    /// (a fixed input, the animation switch).
    private(set) var companionSection: WinCompanionSection?
    var configureCompanion: ((WinCompanionSection) -> Void)?

    struct HeaderParts {
        var caption: WinControl, total: WinControl, grouped: WinControl, cost: WinControl
        var periodsLine: WinPeriodLine
        var line: WinComposite
        var hint: WinRow
    }

    struct FooterParts {
        var refresh: WinControl, updated: WinControl, error: WinControl, settings: WinControl, quit: WinControl
        var pet: WinControl?
        var line: WinComposite
    }

    init(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings, feed: TeamFeedStore?,
         state: PopoverState, facts: PopoverPlatformFacts, openPlaza: (() -> Void)? = nil, perform: ((HomeAction) -> Void)? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.companion = companion
        self.updater = updater
        self.team = team
        self.feed = feed
        self.state = state
        self.facts = facts
        self.now = now
        clock = PopoverClock(now: now)
        performAction = perform ?? { action in
            HomeModel.perform(action, store: store, updater: updater, state: state, quit: { WindowsApp.exit(0, .menu) })
        }
        if let openPlaza { state.onOpenPlaza = openPlaza }
        clock.onTick = { [weak self] in self?.tick() }
    }

    /// The app's page: the host's stores, the popover's navigation state, the plaza button opening the plaza (the popover
    /// closes first: `WindowsAppDelegate.openPlaza`). Settings (and the session-key route) swap the page in place: the state
    /// says `showSettings`, and the popover builds the page it asks for (`WinSettingsPage.routed`), after the click has returned.
    convenience init(host: WinPopoverHost, state: PopoverState, popover: WinPopover? = nil) {
        let store = host.store, updater = host.updater
        self.init(store: store, companion: host.companion, updater: updater, team: host.team, feed: host.feed,
                  state: state, facts: PopoverPlatformFacts.current, openPlaza: { host.openPlaza() },
                  perform: { [weak popover] action in
                      HomeModel.perform(action, store: store, updater: updater, state: state, quit: { WindowsApp.exit(0, .menu) })
                      if state.showSettings, let popover {
                          DispatchQueue.main.async { popover.replacePage() }  // not inside the button that was pressed
                      }
                  })
        // MARK: Task 13 — the recap button
        openRecap = { [weak popover] in
            state.showingRecap = true
            DispatchQueue.main.async { popover?.replacePage() }  // not inside the button that was pressed
        }
        // MARK: end Task 13
    }

    // MARK: WinPopoverPage

    func build(in window: WinSinkWindow, ctx: WinUIContext, client: RECT) {
        guard let made = try? WinScrollArea(parent: window.hwnd, ctx: ctx, rect: client) else {
            AppLog.write("home page: no scroll area (\(GetLastError()))")
            return
        }
        let page = WinStack(pane: made.content, width: made.contentWidth)
        page.onHeight = { [weak made] h in made?.setContentHeight(h) }
        area = made
        attach(stack: page)
    }

    /// Builds the page into `page` (the popover's own, or a test window's), applies the model once and starts observing.
    func attach(stack page: WinStack) {
        isDestroyed = false  // a rebuilt page (a DPI or text-size change) is built again on the same object
        last = nil
        epoch += 1
        clock.onTick = { [weak self] in self?.tick() }
        stack = page
        ctx = page.ctx
        page.useMetrics(.home)  // the Mac's 14 pt padding and 12 pt spacing (Settings keeps 16 / 18)
        let banner = page.addSection(nil, card: false), plaza = page.addSection(nil, card: false)
        // --- stage 7 Task 9: the companion header, first in Home's content as on the Mac (begin) ---
        companionSection = WinCompanionSection(companion: companion, section: page.addSection(nil, card: false), page: self)
        if let made = companionSection { configureCompanion?(made) }
        // --- stage 7 Task 9 (end) ---
        let ruleCompanion = page.addRule()
        let header = page.addSection(nil, card: false), activity = page.addSection(nil, card: false), tabs = page.addSection(nil, card: false)
        let provider = page.addSection(nil, card: false)
        // The header group is one `VStack(spacing: 6)` on the Mac; the tabs sit 6 further down (`.padding(.top, 6)`), the
        // provider row's lines 3 apart, the limits' rows 8 apart.
        activity.spacingAbove = 6
        tabs.spacingAbove = 12
        provider.spacingAbove = 6
        provider.rowSpacing = 3
        let ruleTotals = page.addRule()
        let status = page.addSection(nil, card: false), limits = page.addSection(nil, card: false)
        limits.rowSpacing = 8
        let ruleLimits = page.addRule()
        sections = Sections(banner: banner, plaza: plaza, header: header, activity: activity, tabs: tabs, provider: provider, status: status,
                            limits: limits, footer: page.addSection(nil, card: false), ruleCompanion: ruleCompanion, ruleTotals: ruleTotals,
                            ruleLimits: ruleLimits)
        observe()  // makes the header, whose period line holds the streak's view (Task 12)
        // --- stage 7 Task 12: the activity panel and the streak (begin) ---
        if let sections {
            let panel = WinActivitySection(stack: page, section: sections.activity, store: store, companion: companion, facts: facts, streak: streakSlot)
            panel.now = now
            activityPanel = panel
            panel.observe()
        }
        // --- stage 7 Task 12 (end) ---
        companionSection?.start()  // stage 7 Task 9
        page.layout()
    }

    func layout(client: RECT) {
        guard let area, let stack else { return }
        area.move(client)
        stack.width = area.contentWidth
        stack.layout()
    }

    var initialFocus: HWND? { nil }

    func escape() -> Bool { false }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        clock.onTick = nil
        clock.stop()
        companionSection?.destroy()  // stage 7 Task 9: its clocks and loads stop before the rows go
        companionSection = nil
        activityPanel?.destroy()  // stage 7 Task 12
        activityPanel = nil
        streakSlot = nil
        stack?.destroy()
        area?.destroy()
        bars = []
        relative = [:]
        headerParts = nil
        footerParts = nil
        sections = nil
        stack = nil
        area = nil
    }

    // MARK: observing

    /// Makes the model inside the tracking, applies it, and asks to be called again when anything it read changes.
    func observe() {
        guard !isDestroyed else { return }
        observes += 1
        if let modelOverride {
            apply(modelOverride(now()))
            return
        }
        let mine = epoch
        let model = withObservationTracking {
            HomeModel.make(store: store, companion: companion, updater: updater, team: team, feed: feed, state: state, facts: facts,
                           now: now())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine else { return }  // a tracking of a page that was destroyed or built again
                self.observe()
            }
        }
        apply(model)
    }

    func perform(_ action: HomeAction) { performAction(action) }

    // MARK: applying a model

    func apply(_ m: HomeModel) {
        guard !isDestroyed, let s = sections else { return }
        applies += 1
        let was = last
        let first = was == nil
        if first || was?.updateBanner != m.updateBanner { renderBanner(m.updateBanner, s.banner) }
        if first || was?.plazaButton != m.plazaButton { renderPlaza(m.plazaButton, s.plaza) }
        updateHeader(m, s.header, first: first, was: was)
        if first || was?.providerTabs != m.providerTabs || was?.selectedProviderID != m.selectedProviderID {
            renderTabs(m.providerTabs, selected: m.selectedProviderID, s.tabs, name: "tabs") { .selectProvider($0) }
        }
        if first || was?.providerRow != m.providerRow { renderProvider(m.providerRow, s.provider) }
        if first || was?.statusBanner != m.statusBanner { renderStatus(m.statusBanner, s.status) }
        providerID = m.selectedProviderID
        if first || !Self.sameLimits(was?.limits, m.limits) { renderLimits(m.limits, s.limits) }
        s.ruleLimits.isVisible = s.limits.isVisible
        updateFooter(m.footer, s.footer, first: first, was: was?.footer)
        last = m
        armClock()
    }

    /// The limits section is the same unless something but the pace marker's drift changed: the marker moves with the clock
    /// (the Mac moves it only on a refresh or a reopen), so a build a minute later is not a reason to make every row again.
    static func sameLimits(_ a: [LimitsBlock]?, _ b: [LimitsBlock]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x == y { continue }
            guard case .row(var rx, let dx) = x, case .row(let ry, let dy) = y, dx == dy else { return false }
            if let px = rx.paceMarker, let py = ry.paceMarker, abs(px - py) < 0.01 { rx.paceMarker = py }
            if rx != ry { return false }
        }
        return true
    }

    /// Makes a region's rows again, keeping the keyboard where it was: on the same row of the new rows.
    func rebuild(_ name: String, _ section: WinSectionCard, _ body: () -> Void) {
        let mark = focusRow(in: section)
        section.removeRows()
        if name == "limits" { bars = [] }
        relative[name] = []
        body()
        renders[name, default: 0] += 1
        if let mark { restoreFocus(in: section, row: mark) }
    }

    private func focusRow(in section: WinSectionCard) -> Int? {
        guard let focus = GetFocus() else { return nil }
        for (i, row) in section.rows.enumerated() {
            guard let c = row.control else { continue }
            if c.parts.contains(where: { $0 == focus || IsChild($0, focus) }) { return i }
        }
        return nil
    }

    private func restoreFocus(in section: WinSectionCard, row: Int) {
        let rows = section.rows
        guard row < rows.count, let c = rows[row].control else { return }
        let target: HWND?
        switch c.kind {
        case .radioGroup: target = c.parts[max(0, min(c.parts.count - 1, c.selection))]
        case .drawn: target = GetNextDlgTabItem(c.hwnd, nil, false)
        default: target = c.hwnd
        }
        if let target { _ = SetFocus(target) }
    }

    // MARK: building blocks

    /// A label maker for `addStyledRow` and composites.
    func text(_ s: String, _ style: PopoverTextStyle = .body, weight: Int? = nil, role: WinUIColors.Role = .primary,
              color: PopoverColorRole? = nil, wraps: Bool = true) -> (HWND, WinUIContext) -> WinControl? {
        { pane, ctx in
            let c = WinControls.label(s, style: style, weight: weight, role: role, wraps: wraps, in: pane, ctx: ctx)
            if let c, let color { self.paint(c, color) }
            return c
        }
    }

    /// A label in a model colour role: primary, secondary and tertiary are the page's text colours, the rest the Mac's value.
    func paint(_ c: WinControl, _ role: PopoverColorRole) {
        switch role {
        case .primary: c.role = .primary; c.textColor = nil
        case .secondary: c.role = .secondary; c.textColor = nil
        case .tertiary: c.role = .tertiary; c.textColor = nil
        case .accent: c.textColor = ctx.colors.palette.accent
        default:
            let v = role.macValue(.light)
            func byte(_ d: Double) -> UInt8 { UInt8(max(0, min(255, (d * 255).rounded()))) }
            c.textColor = WinUIColors.rgb(byte(v.red), byte(v.green), byte(v.blue))
        }
    }

    func button(_ b: NoticeButton, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        guard let c = WinControls.button(b.label + (b.inProgress ? "…" : ""), in: pane, ctx: ctx) else { return nil }
        c.isEnabled = !b.inProgress
        let action = b.action
        c.onClick = { [weak self] in self?.perform(action) }
        return c
    }

    /// A button the Mac draws borderless or prominent (`WinControls.pillButton`), doing what `b` says.
    func pill(_ b: NoticeButton, style: WinPill.Style, secondary: Bool = false, in pane: HWND, ctx: WinUIContext) -> WinControl? {
        let title = b.label + (b.inProgress ? "…" : "")
        guard let c = WinControls.pillButton(WinPill(style: style, title: title, secondary: secondary, textStyle: .callout), in: pane, ctx: ctx)
        else { return nil }
        c.isEnabled = !b.inProgress
        let action = b.action
        c.onClick = { [weak self] in self?.perform(action) }
        return c
    }

    func glyph(_ symbol: String, _ label: String, in pane: HWND, ctx: WinUIContext, action: HomeAction) -> WinControl? {
        guard let c = WinControls.glyphButton(symbol: symbol, label: label, in: pane, ctx: ctx) else { return nil }
        c.tooltip = label
        c.onClick = { [weak self] in self?.perform(action) }
        return c
    }

    /// The page's inner width in pixels (what a `.full` row gets).
    var innerWidth: Int32 {
        guard let stack else { return 0 }
        return stack.width - 2 * Int32(stack.metrics.pagePadding)
    }

    /// Capsule tabs (`CapsuleTabBar`: accent 18 % and semibold when selected, secondary 8 % otherwise), 8 px apart, one line per
    /// group of tabs that fit (the Mac scrolls its strip sideways): a row each, in `section`.
    func addTabs(_ tabs: [CapsuleTab], selected: String?, to section: WinSectionCard, action: @escaping (String) -> HomeAction) {
        let titles = tabs.map { ($0.marked ? "● " : "") + $0.title }
        let gap = ctx.px(8)
        func width(_ i: Int, _ bold: Bool) -> Int32 { ctx.measure(titles[i], font: ctx.fonts.font(.caption, weight: bold ? 600 : nil)).cx + 2 * ctx.px(10) }
        var start = 0
        while start < tabs.count {
            var end = start + 1
            var used = width(start, tabs[start].id == selected)
            while end < tabs.count, used + gap + width(end, tabs[end].id == selected) <= innerWidth {
                used += gap + width(end, tabs[end].id == selected)
                end += 1
            }
            let range = start..<end
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                WinComposite(parent: pane, ctx: ctx) { child in
                    var pills: [WinControl] = []
                    for i in range {
                        let isSelected = tabs[i].id == selected
                        let pill = WinPill(style: .tab, title: titles[i], selected: isSelected, bold: isSelected)
                        guard let c = WinControls.pillButton(pill, label: tabs[i].title, in: child, ctx: ctx) else { continue }
                        c.tooltip = tabs[i].help
                        let id = tabs[i].id
                        c.onClick = { [weak self] in self?.perform(action(id)) }
                        pills.append(c)
                    }
                    return (pills, [])
                }?.control
            }
            start = end
        }
    }

    func bind(_ name: String, _ control: WinControl, _ text: RelativeText, in composite: WinComposite? = nil) {
        relative[name, default: []].append(RelativeBinding(control: control, text: text, composite: composite))
    }

    // MARK: regions

    /// The update offer (`PopoverView.updateBanner`): an accent 12 % card on an 8 pt corner, the text in `caption`, then Skip (a
    /// borderless secondary button) and Update (the prominent one) at the right, or "Updating…" while it runs.
    private func renderBanner(_ b: UpdateBannerModel?, _ section: WinSectionCard) {
        rebuild("banner", section) {
            guard let b else { section.isVisible = false; return }
            section.isVisible = true
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                WinNoticeCard(parent: pane, ctx: ctx, tint: .accent, alpha: 0.12, radius: 8, spacing: 6, symbol: nil) { child, ctx, tint in
                    var message = WinNoticeCard.Line()
                    message.flexible = WinControls.label(b.text, style: .caption, in: child, ctx: ctx)
                    var actions = WinNoticeCard.Line()
                    if b.isUpdating {
                        actions.trailing = [WinControls.label(b.updatingLabel, style: .caption2, role: .secondary, wraps: false, in: child, ctx: ctx)]
                            .compactMap { $0 }
                    } else {
                        actions.trailing = [self.pill(b.skipButton, style: .borderless, secondary: true, in: child, ctx: ctx),
                                            self.pill(b.updateButton, style: .prominent, in: child, ctx: ctx)].compactMap { $0 }
                    }
                    for c in [message.flexible].compactMap({ $0 }) + actions.trailing where c.kind == .label { c.background = tint }
                    return [message, actions]
                }?.control
            }
        }
    }

    private func renderPlaza(_ p: PlazaButtonModel?, _ section: WinSectionCard) {
        rebuild("plaza", section) {
            guard let p else { section.isVisible = false; return }
            section.isVisible = true
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                WinComposite(parent: pane, ctx: ctx) { child in
                    var trailing: [WinControl] = []
                    if p.unreadDot, let dot = WinControls.label("●", style: .callout, wraps: false, in: child, ctx: ctx) {
                        self.paint(dot, .systemRed)
                        trailing.append(dot)
                    }
                    if let button = self.glyph(p.symbol, p.label, in: child, ctx: ctx, action: p.action) { trailing.append(button) }
                    return ([], trailing)
                }?.control
            }
        }
    }

    /// Today's caption and totals, the week and month line, and (first run) the line that says what fills the page: made
    /// once, then only their texts change.
    private func updateHeader(_ m: HomeModel, _ section: WinSectionCard, first: Bool, was: HomeModel?) {
        let h = m.header
        let empty = m.selectedProviderID == nil
        let periods = [h.week, h.month]
        if headerParts == nil {
            var caption: WinControl?, total: WinControl?, grouped: WinControl?, cost: WinControl?
            var line: WinComposite?
            section.addStyledRow(label: { pane, ctx in
                caption = WinControls.label(h.caption, style: .caption, role: .secondary, in: pane, ctx: ctx)
                return caption
            }, style: .trailing)
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                line = WinComposite(parent: pane, ctx: ctx) { child in
                    total = WinControls.label(h.total, style: .largeBold, wraps: false, in: child, ctx: ctx)
                    grouped = WinControls.label(h.grouped ?? "", style: .caption, role: .secondary, wraps: false, in: child, ctx: ctx)
                    cost = WinControls.label(h.cost ?? "", style: .callout, role: .secondary, wraps: false, in: child, ctx: ctx)
                    return ([total, grouped].compactMap { $0 }, [cost].compactMap { $0 })
                }
                return line?.control
            }
            var periodsLine: WinPeriodLine?
            section.addStyledRow(label: nil, style: .full) { pane, ctx in  // Tasks 12 and 13: the totals, the streak and "Details" in the Mac's one line (WinPeriodLine.swift)
                periodsLine = self.makePeriodLine(pane, ctx, periods)
                return periodsLine?.control
            }
            var hintRow: WinRow?
            hintRow = section.addStyledRow(label: { pane, ctx in
                WinControls.label(L(self.companion.language).winNoUsageYet, style: .callout, role: .tertiary, in: pane, ctx: ctx)
            }, style: .trailing)
            guard let caption, let total, let grouped, let cost, let periodsLine, let line, let hintRow else {
                AppLog.write("home page: the header's controls were not made")
                return
            }
            headerParts = HeaderParts(caption: caption, total: total, grouped: grouped, cost: cost, periodsLine: periodsLine, line: line, hint: hintRow)
            line.setShown(grouped, h.grouped != nil)
            line.setShown(cost, h.cost != nil)
            hintRow.isVisible = empty
            renders["header", default: 0] += 1
            return
        }
        guard let parts = headerParts, first || was?.header != h || was?.selectedProviderID != m.selectedProviderID else { return }
        var relayout = false
        func setWrapped(_ c: WinControl, _ s: String) {
            if c.text != s { c.text = s; relayout = true }
        }
        setWrapped(parts.caption, h.caption)
        parts.periodsLine.setPeriods(periods)  // Tasks 12 and 13: a line of its own (the page lays out again when its height changed)
        parts.line.setText(parts.total, h.total)
        parts.line.setText(parts.grouped, h.grouped ?? "")
        parts.line.setText(parts.cost, h.cost ?? "")
        parts.line.setShown(parts.grouped, h.grouped != nil)
        parts.line.setShown(parts.cost, h.cost != nil)
        parts.line.remeasure()
        if parts.hint.isVisible != empty { parts.hint.isVisible = empty }
        if relayout { stack?.setNeedsLayout() }
        renders["header", default: 0] += 1
    }

    func renderTabs(_ tabs: [CapsuleTab], selected: String?, _ section: WinSectionCard, name: String,
                    action: @escaping (String) -> HomeAction) {
        rebuild(name, section) {
            guard !tabs.isEmpty else { section.isVisible = false; return }
            section.isVisible = true
            addTabs(tabs, selected: selected, to: section, action: action)
        }
    }

    private func renderProvider(_ p: ProviderRowModel?, _ section: WinSectionCard) {
        rebuild("provider", section) {
            guard let p else { section.isVisible = false; return }
            section.isVisible = true
            let total = [p.tokens, p.cost].compactMap { $0 }.joined(separator: "  ")
            section.addStyledRow(label: text(p.name, .headline), style: .trailing) { pane, ctx in
                WinControls.label(total, style: .callout, role: .secondary, wraps: false, in: pane, ctx: ctx)
            }
            let types = [p.input, p.output, p.cacheWrite, p.cacheRead].map { "\($0.name) \($0.tokens)" }.joined(separator: "    ")
            section.addStyledRow(label: text(types, .caption, role: .secondary), style: .trailing)
            for line in p.models {
                section.addStyledRow(label: text(line.name, .caption, role: .secondary, wraps: false), style: .trailing) { pane, ctx in
                    WinControls.label(line.tokens, style: .caption, role: .secondary, wraps: false, in: pane, ctx: ctx)
                }
            }
        }
    }

    private func renderStatus(_ b: StatusBannerModel?, _ section: WinSectionCard) {
        rebuild("status", section) {
            guard let b else { section.isVisible = false; return }
            section.isVisible = true
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                WinComposite(parent: pane, ctx: ctx) { child in
                    var parts: [WinControl] = []
                    if let dot = WinControls.label("●", style: .callout, wraps: false, in: child, ctx: ctx) {
                        self.paint(dot, b.dot)
                        parts.append(dot)
                    }
                    if let label = WinControls.label(b.label, style: .callout, wraps: false, in: child, ctx: ctx) { parts.append(label) }
                    return (parts, [])
                }?.control
            }
            if let description = b.description {
                section.addStyledRow(label: text(description, .caption, role: .secondary), style: .trailing)
            }
        }
    }

    /// Refresh, "Updated <relative>", the error triangle, (the pet's eye,) Settings and Quit: made once, then texts and
    /// visibility change in place.
    private func updateFooter(_ f: FooterModel, _ section: WinSectionCard, first: Bool, was: FooterModel?) {
        if footerParts == nil {
            var refresh: WinControl?, updated: WinControl?, error: WinControl?, settings: WinControl?, quit: WinControl?, pet: WinControl?
            var line: WinComposite?
            section.addStyledRow(label: nil, style: .full) { pane, ctx in
                line = WinComposite(parent: pane, ctx: ctx) { child in
                    refresh = self.glyph("arrow.clockwise", f.usage?.refreshHelp ?? f.settingsHelp, in: child, ctx: ctx, action: .refresh)
                    updated = WinControls.label("", style: .caption, role: .tertiary, wraps: false, in: child, ctx: ctx)
                    // The Mac's orange `exclamationmark.triangle` with the message as its help.
                    error = WinControls.glyphButton(symbol: "exclamationmark.triangle", label: f.usage?.error ?? "!", size: 12, in: child, ctx: ctx)
                    error?.glyphColor = WinUIColors.rgb(255, 149, 0)
                    if let toggle = f.petToggle {
                        pet = self.glyph(toggle.symbol, toggle.label, in: child, ctx: ctx, action: .toggleFloatingPet)
                    }
                    settings = self.glyph("gearshape", f.settingsHelp, in: child, ctx: ctx, action: .showSettings)
                    quit = self.glyph("power", f.quitHelp, in: child, ctx: ctx, action: .quit)
                    return ([refresh, updated, error].compactMap { $0 }, [pet, settings, quit].compactMap { $0 })
                }
                return line?.control
            }
            guard let refresh, let updated, let error, let settings, let quit, let line else {
                AppLog.write("home page: the footer's controls were not made")
                return
            }
            footerParts = FooterParts(refresh: refresh, updated: updated, error: error, settings: settings, quit: quit, pet: pet, line: line)
        }
        guard let parts = footerParts, first || was != f else { return }
        let usage = f.usage
        parts.line.setShown(parts.refresh, usage != nil)
        parts.refresh.tooltip = usage?.refreshHelp
        if let updatedText = usage?.updated {
            parts.line.setShown(parts.updated, true)
            relative["footer"] = []
            parts.updated.text = ""
            bind("footer", parts.updated, updatedText, in: parts.line)
            parts.line.setText(parts.updated, relativeString(updatedText))
        } else {
            parts.line.setShown(parts.updated, false)
            relative["footer"] = []
        }
        parts.line.setShown(parts.error, usage?.error != nil)
        parts.error.tooltip = usage?.error
        if let message = usage?.error, !message.isEmpty { parts.error.text = message }
        parts.line.remeasure()
        renders["footer", default: 0] += 1
    }

    // MARK: the clock

    func relativeString(_ t: RelativeText) -> String {
        t.prefix + RelativeTimeText.text(for: t.date, now: now(), language: companion.language, coarse: true) + t.suffix
    }

    /// Writes one relative text again; a line of the page lays out again only when a wrapped text changed its height.
    func refresh(_ b: RelativeBinding) {
        let s = relativeString(b.text)
        guard b.control.text != s else { return }
        if let composite = b.composite {
            composite.setText(b.control, s)
            return
        }
        b.control.text = s
        let r = WinKit.rect(b.control.hwnd, in: GetParent(b.control.hwnd))
        let need = b.control.size(width: r.right - r.left)
        if Int32(need.height.rounded(.up)) != r.bottom - r.top { stack?.setNeedsLayout() }
    }

    private func tick() {
        guard !isDestroyed else { return }
        for b in relative.values.joined() { refresh(b) }
        armClock()
    }

    /// One timer at the earliest instant any relative text on screen reads differently; none when nothing relative shows.
    func armClock() {
        guard !isDestroyed else { return }
        let current = now()
        clock.setDeadlines(relative.values.joined().map { RelativeTimeText.nextChange(for: $0.text.date, now: current, coarse: true) })
    }
}
#endif
