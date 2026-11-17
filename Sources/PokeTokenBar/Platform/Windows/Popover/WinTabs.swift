#if os(Windows)
import Foundation
import WinSDK

/// The popover's main tabs (stage 7 Task 19; the Mac's `Picker` over `nav.tab` in `PopoverView.mainContent`).
///
/// The Mac has one frame for all four tabs: the update offer, the tab strip (with the plaza button), a 520 pt content area, the
/// footer. `WinHomePage` is that frame on Windows (its pinned top pane, scroller and pinned footer), built for `PopoverState.tab`:
/// Home fills the scroller with its own regions, every other tab with the content registered for it here. Picking a tab sets
/// `state.tab` and the popover builds the page for it in place (`WinPopover.replacePage`), as Settings and the recap do.
///
/// How a tab plugs in: a class conforming to `WinTabContent` that adds its sections to `host.stack` in `build()` and lists
/// itself in `WinTabPages.content(for:host:)`. It owns what it makes (controls through the stack, observation, clocks,
/// async loads) and gives all of it back in `destroy()`; async work lands through `host.whenCurrent`.
@MainActor protocol WinTabContent: AnyObject {
    /// Adds the tab's sections and rows to `host.stack` (the scroller's page), applies its model once, starts observing.
    func build()
    /// Before the page goes (a tab switch, a rebuild, the popover closing): stop observing and clocks, free what it holds.
    func destroy()
}

/// What a tab's content works with.
@MainActor final class WinTabHost {
    /// The page the content sits in (nil once it is destroyed).
    private(set) weak var page: WinHomePage?
    /// The scroller's page: add sections here. Its metrics are `.homeScroll` (14 pt sides, 12 pt between regions); a tab with
    /// other spacing calls `stack.useMetrics(_:)`.
    let stack: WinStack
    let state: PopoverState
    let store: UsageStore
    let companion: CompanionStore
    /// The popover's generation when the page was built (async work lands only while it is current).
    let generation: Int?
    private weak var popover: WinPopover?

    var ctx: WinUIContext { stack.ctx }
    var language: AppLanguage { companion.language }
    var l: L { companion.l }
    /// The page's inner width in pixels (what a `.full` row gets).
    var innerWidth: Int32 { stack.width - 2 * Int32(stack.metrics.pagePadding) }

    init(page: WinHomePage, stack: WinStack, popover: WinPopover?) {
        self.page = page
        self.stack = stack
        state = page.state
        store = page.store
        companion = page.companion
        self.popover = popover
        generation = popover?.generation
    }

    /// True while the content's page exists and (in the app) the popover has not been rebuilt or closed since.
    var isCurrent: Bool {
        guard let page, !page.isDestroyed else { return false }
        guard let popover, let generation else { return true }
        return popover.isCurrent(generation)
    }

    /// Runs `body` only while the content's page is current (a completion that arrives after a close or a tab switch is dropped).
    func whenCurrent(_ body: () -> Void) {
        if isCurrent { body() }
    }

    /// Goes to another tab (the Mac's `nav.tab = …`): the page for it is built in place.
    func open(_ tab: PopoverState.Tab) {
        page?.openTab(tab)
    }
}

/// The content registered for each tab (Home is the page itself).
@MainActor enum WinTabPages {
    static func content(for tab: PopoverState.Tab, host: WinTabHost) -> WinTabContent? {
        switch tab {
        case .home: nil
        case .shop: WinShopPage(host: host)
        case .bag: WinBagPage(host: host)
        case .collection: WinCollectionPage(host: host)
        }
    }
}

/// The keyboard after a tab switch: picking a tab replaces the page, and the new page puts the keyboard back on the strip so the
/// arrow keys go on working (consumed by the page that is built next).
@MainActor enum WinTabFocus {
    private static var pending = false
    static func request() { pending = true }
    static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}

extension WinHomePage {
    /// The tab strip and the plaza button on one line (the Mac's `HStack(spacing: 8)` over the segmented picker and the map
    /// button). The strip fills what the button leaves, as the Mac's picker does.
    func makeTabLine(_ tabs: PopoverTabsModel, plaza: PlazaButtonModel?, in pane: HWND, ctx: WinUIContext) -> WinComposite? {
        WinComposite(parent: pane, ctx: ctx) { child in
            let strip = WinControls.radioGroup(tabs.titles, selected: tabs.selected, in: child, ctx: ctx)
            strip?.onSelect = { [weak self] i in self?.selectTab(at: i) }
            tabStrip = strip
            var trailing: [WinControl] = []
            if let p = plaza {
                if p.unreadDot, let dot = WinControls.label("●", style: .callout, wraps: false, in: child, ctx: ctx) {
                    self.paint(dot, .systemRed)
                    trailing.append(dot)
                }
                if let button = self.glyph(p.symbol, p.label, in: child, ctx: ctx, action: p.action) { trailing.append(button) }
            }
            if let strip {
                let gap = ctx.px(8)
                let used = trailing.reduce(Int32(0)) { $0 + Int32($1.preferredSize.width.rounded(.up)) + gap }
                let room = self.topInnerWidth - used
                if CGFloat(room) > strip.preferredSize.width { strip.preferredSize = CGSize(width: CGFloat(room), height: strip.preferredSize.height) }
            }
            return ([strip].compactMap { $0 }, trailing)
        }
    }

    /// The strip's position was picked (a click, or an arrow key inside the group).
    func selectTab(at index: Int) {
        guard let tab = PopoverTabsModel.tab(at: index), tab != state.tab else { return }
        WinTabFocus.request()
        openTab(tab)
    }

    /// Sets the tab and has the page for it built, after the control that asked has returned.
    func openTab(_ tab: PopoverState.Tab) {
        state.tab = tab
        syncTab()
    }

    /// The page shows `builtTab`; when `state.tab` says otherwise (the strip, another page's button, a route) the popover builds
    /// the page for it. A window without a popover (a test) reports through `tabChanged`.
    func syncTab() {
        guard !isDestroyed, state.tab != builtTab, !tabSwitchPending else { return }
        tabSwitchPending = true
        let tab = state.tab
        guard let popover = tabPopover else {
            tabChanged?(tab)
            return
        }
        DispatchQueue.main.async { [weak popover, weak self] in
            guard let self, !self.isDestroyed else { return }
            popover?.replacePage()
        }
    }

    /// The strip's selected button, for the keyboard.
    var tabStripFocus: HWND? {
        guard let strip = tabStrip, !strip.parts.isEmpty else { return nil }
        return strip.parts[max(0, min(strip.parts.count - 1, strip.selection))]
    }

    /// The page's tab content, started after the page's own regions are made (not on Home).
    func startTabContent(stack page: WinStack) {
        guard builtTab != .home else { return }
        let host = WinTabHost(page: self, stack: page, popover: tabPopover)
        tabContent = WinTabPages.content(for: builtTab, host: host)
        if let content = tabContent { configureTabContent?(content) }  // a harness sets what the content does before it builds
        tabContent?.build()
    }
}
#endif
