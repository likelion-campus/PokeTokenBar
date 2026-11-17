#if os(Windows)
import Foundation
import Observation
import WinSDK

// MARK: Task 20 — the Collection tab (the Mac's `CollectionView`: the Pokédex grid and the catch log)
//
// Built for `PopoverState.tab == .collection` by `WinTabPages` (stage 7 Task 19). One column of rows in the scroller (the
// Mac's `VStack(spacing: 6)`, 520 pt tall in all): the segment (Pokédex | Catch log), the filter bar (a search field with its
// cue banner and a clear button, the shiny-only toggle, the sort menu) and the body, which is ONE drawn view whatever the
// dex holds: `DexBodyPart` (header, chips, the 4 × 4 page, the footer) or `DexLogPart` (the summary and the virtualised
// list). So a full dex is a window or two plus at most 16 cell items, never hundreds of child windows. The empty dex shows
// `DexEmptyPart` alone, as the Mac does.
//
// What the user does: a cell opens its Pokédex page (`openEntry`, see below), a region or rarity chip filters, the wheel or a
// touchpad swipe turns the page (`DexWheelPager`), the arrow keys move between cells, Page Up / Page Down turn the page, the
// context menu of a cell sets or clears the representative (or, for a species with forms, opens the form picker).
//
// The detail page (Task 21): `openEntry(_:)` records `PopoverState.dexDetailCollectionID` as the Mac's grid does and calls
// `onOpenEntry`. Until Task 21 sets that, the Collection keeps showing the grid with that cell selected, on its page (the Mac's
// Back landing); nothing else changes. Task 21 replaces the grid with its page while `state.dexDetailCollectionID` is set and,
// on Back, builds this page again with `returnAnchor` (`DexBrowserState.returnAnchor`).
//
// Timers: none of its own but one `PopoverClock` while the log is shown (the caught-time texts: one one-shot timer at the next
// change of a visible text); stopped by the segment switch and `destroy()`. The sprites are still, so the animator holds no
// timer either; the empty state's Pikachu is the one GIF.
@MainActor final class WinCollectionPage: WinTabContent {
    let host: WinTabHost
    /// The part's names for the selftest and the dump.
    struct Stats: Equatable { var builds = 0, refreshes = 0, hits = 0, pageTurns = 0, wheelSteps = 0, menus = 0, opened: [String] = [] }
    private(set) var stats = Stats()

    private(set) var browser = DexBrowserState()
    private(set) var emptyRow: WinRow?, segmentRow: WinRow?, toolbarRow: WinRow?, dexRow: WinRow?, logRow: WinRow?
    private(set) var emptyView: WinDrawnView?, dexView: WinDrawnView?, logView: WinDrawnView?
    private(set) var emptyPart: DexEmptyPart?, dexPart: DexBodyPart?, logPart: DexLogPart?
    private(set) var segment: WinControl?, search: WinControl?, clear: WinControl?, shiny: WinControl?, sort: WinControl?
    private var toolbar: WinComposite?
    private var section: WinSectionCard?
    private var raster: WinGlyphRaster?
    private var epoch = 0
    private var bodyHeight: CGFloat = 0
    private var wheel = DexWheelPager()
    private var listWheel = PopoverWheel()
    private var chipWheel = PopoverWheel()
    private var resolved: [String: [Int: String]] = [:]
    private var requested: Set<String> = []
    private var lastScrollKey: [String] = []
    private var tasks: [Task<Void, Never>] = []
    private let clock = PopoverClock()
    private(set) var isDestroyed = false
    /// The selftest reads whether the clock holds a timer.
    var isClockArmedForTesting: Bool { clock.isArmed }

    /// What opening a Pokédex page does (Task 21 sets it): the collection ID of the cell.
    var onOpenEntry: ((String) -> Void)?
    /// The cell menu and the sort menu: the real popup, or a stand-in in the selftest. (items, where, owner) -> chosen index.
    var menu: @MainActor ([TrayMenuModel.Item?], POINT, HWND) -> Int? = { items, point, owner in
        WinPopupMenu.run(items, at: point, owner: owner, below: true)
    }
    var animationsEnabled: @MainActor () -> Bool = { WinSpriteAnimator.systemAnimationsEnabled() }
    /// The page's content height is the Mac's fixed 520.
    static let contentHeight: CGFloat = PopoverStackMetrics.homeScrollerHeight

    init(host: WinTabHost) {
        self.host = host
    }

    private var ctx: WinUIContext { host.ctx }
    private var store: CompanionStore { host.companion }
    private var l: L { host.l }
    private var showingLog: Bool { host.state.showingCollectionLog }
    private var widthDIP: CGFloat { CGFloat(host.innerWidth) / ctx.scale }

    // MARK: build

    func build() {
        stats.builds += 1
        let stack = host.stack
        stack.useMetrics(.collection)
        let section = stack.addSection(nil, card: false)
        self.section = section
        raster = WinGlyphRaster(fonts: ctx.fonts)
        if let id = host.state.dexDetailCollectionID {   // a link from Home, or Back from the detail page
            browser.returnAnchor = id
            browser.selectedID = id
        }
        // the empty Pokédex
        emptyRow = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
            guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            view.sprites = WinSpriteAnimator(fetcher: WinCompanionSection.fetcher(), animationsEnabled: animationsEnabled)
            let part = DexEmptyPart(title: l.dexEmptyTitle, hint: l.dexEmptyHint)
            view.host(part, width: widthDIP)
            emptyView = view
            emptyPart = part
            return view.control
        }
        // the segment
        segmentRow = section.addRow(nil, style: .full, accessibleName: nil) { [self] pane, ctx in
            segment = WinControls.radioGroup([l.dexTitle, l.catchLogTitle], selected: showingLog ? 1 : 0, in: pane, ctx: ctx)
            segment?.onSelect = { [weak self] i in self?.selectSegment(i) }
            return segment
        }
        // the filter bar
        toolbarRow = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
            toolbar = WinComposite(parent: pane, ctx: ctx, accessibleName: l.dexSearchPlaceholder) { child in
                search = WinControls.edit(.text(cue: l.dexSearchPlaceholder), in: child, ctx: ctx)
                clear = WinControls.glyphButton(symbol: "xmark.circle.fill", label: l.clearFilters, size: 13, in: child, ctx: ctx)
                shiny = WinControls.glyphButton(symbol: "sparkles", label: l.filterShinyOnly, size: 13, in: child, ctx: ctx)
                sort = WinControls.glyphButton(symbol: "arrow.up.arrow.down", label: l.sortTitle, size: 13, in: child, ctx: ctx)
                return ([search, clear].compactMap { $0 }, [shiny, sort].compactMap { $0 })
            }
            return toolbar?.control
        }
        search?.onChange = { [weak self] text in self?.searchChanged(text) }
        clear?.tooltip = l.clearFilters
        clear?.onClick = { [weak self] in self?.clearSearch() }
        shiny?.tooltip = l.filterShinyOnly
        shiny?.onClick = { [weak self] in
            guard let self else { return }
            self.browser.toggleShinyOnly()
            self.refresh()
        }
        sort?.tooltip = l.sortTitle
        sort?.onClick = { [weak self] in self?.openSortMenu() }
        if let clear { toolbar?.setShown(clear, false) }
        let segH = (segment?.preferredSize.height ?? 0) / ctx.scale
        let barH = (toolbar?.control.preferredSize.height ?? 0) / ctx.scale
        bodyHeight = max(160, Self.contentHeight - segH - barH - 2 * 6)
        // the Pokédex
        dexRow = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
            guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            view.sprites = WinSpriteAnimator(fetcher: WinCompanionSection.fetcher(), animationsEnabled: animationsEnabled)
            let part = DexBodyPart(DexBodyModel.make(store: store, state: browser), height: bodyHeight,
                                   accent: Self.plaza(ctx.colors.palette.accent), glyphs: raster)
            wire(view, part)
            view.host(part, width: widthDIP)
            dexView = view
            dexPart = part
            return view.control
        }
        refresh()
        started()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        epoch += 1
        clock.stop()
        clock.onTick = nil
        for t in tasks { t.cancel() }
        tasks = []
        onOpenEntry = nil
        // the controls, views and sprite animators go with the stack (`WinStack.destroy`)
        dexPart = nil
        logPart = nil
        emptyPart = nil
    }

    private static func plaza(_ c: COLORREF) -> PlazaColor {
        PlazaColor(srgbRed: Double(c & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double((c >> 16) & 0xFF) / 255)
    }

    // MARK: model and observation

    private func started() {
        tasks.append(Task { @MainActor [weak self] in await self?.store.backfillMissingDexNames() })
    }

    /// Computes what the page shows (inside the observation) and applies it.
    func refresh() {
        guard !isDestroyed else { return }
        epoch += 1
        let mine = epoch
        stats.refreshes += 1
        let log = showingLog
        let made = withObservationTracking { () -> (Bool, DexBodyModel?, DexLogModel?, L) in
            let empty = store.dexEntries.isEmpty
            if empty { return (true, nil, nil, store.l) }
            return (false, log ? nil : DexBodyModel.make(store: store, state: browser),
                    log ? DexLogModel.make(store: store, state: browser, resolved: resolved) : nil, store.l)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == mine, !self.isDestroyed else { return }
                self.refresh()
            }
        }
        apply(empty: made.0, body: made.1, log: made.2)
    }

    private func apply(empty: Bool, body: DexBodyModel?, log: DexLogModel?) {
        let stack = host.stack
        var layoutNeeded = false
        func show(_ row: WinRow?, _ on: Bool) {
            guard let row, row.isVisible != on else { return }
            row.isVisible = on
            layoutNeeded = true
        }
        show(emptyRow, empty)
        show(segmentRow, !empty)
        show(toolbarRow, !empty)
        if empty {
            show(dexRow, false)
            show(logRow, false)
            clock.stop()
            if layoutNeeded { stack.layout() }
            return
        }
        if let l = log { ensureLog(l) }
        show(dexRow, body != nil)
        show(logRow, log != nil)
        if let body, let dexPart {
            dexPart.raisingText = self.l.dexRaising.uppercased()
            dexPart.update(body)
        }
        if let log, let logPart {
            logPart.language = store.language
            if browser.logScrollKey != lastScrollKey { logPart.scrollToTop() }
            lastScrollKey = browser.logScrollKey
            logPart.update(log)
            resolveNames()
        }
        if log == nil { clock.stop() } else { armClock() }
        updateToolbar()
        if segment?.selection != (showingLog ? 1 : 0) { segment?.selection = showingLog ? 1 : 0 }
        if layoutNeeded { stack.layout() }
    }

    private func ensureLog(_ model: DexLogModel) {
        guard logRow == nil, let section else { return }
        logRow = section.addStyledRow(label: nil, style: .full) { [self] pane, ctx in
            guard let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            view.sprites = WinSpriteAnimator(fetcher: WinCompanionSection.fetcher(), animationsEnabled: animationsEnabled)
            let part = DexLogPart(model, height: bodyHeight, language: store.language, accent: Self.plaza(ctx.colors.palette.accent), glyphs: raster)
            wireLog(view, part)
            view.host(part, width: widthDIP)
            logView = view
            logPart = part
            return view.control
        }
        logRow?.isVisible = false
        clock.onTick = { [weak self] in
            guard let self, !self.isDestroyed else { return }
            self.logPart?.onChange?()
            self.armClock()
        }
    }

    private func armClock() {
        clock.setDeadlines([logPart?.nextDeadline()].compactMap { $0 })
    }

    /// The names of entries from an older save (the Mac's per-row `.task`), once per entry.
    private func resolveNames() {
        for entry in store.dexEntries where store.dexStoredChainNames(entry) == nil && !requested.contains(entry.id) {
            requested.insert(entry.id)
            tasks.append(Task { @MainActor [weak self] in
                guard let self else { return }
                let names = await self.store.dexResolveChainNames(entry)
                self.host.whenCurrent {
                    guard !self.isDestroyed else { return }
                    self.resolved[entry.id] = names
                    self.refresh()
                }
            })
        }
    }

    // MARK: the filter bar

    private func updateToolbar() {
        let palette = ctx.colors.palette
        let window = palette.window
        if let shiny {
            let on = browser.shinyOnly
            shiny.background = on ? Self.blend(window, with: 0x0000_CCFF, 0.18) : window
            _ = InvalidateRect(shiny.hwnd, nil, false)
        }
        if let sort {
            let custom = browser.isCustomSortActive(showingLog: showingLog)
            sort.glyphColor = custom ? palette.accent : nil
            sort.background = custom ? Self.blend(window, with: palette.accent, 0.12) : window
            _ = InvalidateRect(sort.hwnd, nil, false)
        }
        if let clear, let toolbar { toolbar.setShown(clear, !browser.searchText.isEmpty) }
        if let search, search.text != browser.searchText { search.text = browser.searchText }
    }

    /// `over` at `fraction` over `base` (COLORREF 0x00BBGGRR).
    static func blend(_ base: COLORREF, with over: COLORREF, _ fraction: Double) -> COLORREF {
        func mix(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xFF), o = Double((over >> shift) & 0xFF)
            return UInt32((b + (o - b) * fraction).rounded()) & 0xFF
        }
        return COLORREF(mix(0) | mix(8) << 8 | mix(16) << 16)
    }

    private func searchChanged(_ text: String) {
        guard text != browser.searchText else { return }
        browser.setSearch(text)
        refresh()
    }

    private func clearSearch() {
        search?.text = ""
        browser.setSearch("")
        refresh()
        if let search { _ = SetFocus(search.hwnd) }
    }

    private func selectSegment(_ index: Int) {
        let log = index == 1
        guard log != showingLog else { return }
        host.state.showingCollectionLog = log   // also drops an open detail page (`PopoverState`)
        browser.returnAnchor = nil
        refresh()
    }

    private func openSortMenu() {
        guard let sort else { return }
        let items: [TrayMenuModel.Item?]
        let log = showingLog
        if log {
            items = CompanionStore.CatchLogSortOption.allCases.map {
                TrayMenuModel.Item(title: l.label(for: $0), enabled: true, checked: browser.logSort == $0, action: .none)
            }
        } else {
            items = CompanionStore.DexSortOption.allCases.map {
                TrayMenuModel.Item(title: l.label(for: $0), enabled: true, checked: browser.dexSort == $0, action: .none)
            }
        }
        var r = RECT()
        _ = GetWindowRect(sort.hwnd, &r)
        stats.menus += 1
        guard let chosen = menu(items, POINT(x: r.left, y: r.bottom), GetAncestor(sort.hwnd, 2 /* GA_ROOT */) ?? sort.hwnd) else { return }
        applySort(chosen, log: log)
    }

    /// The sort chosen at position `index` of the menu.
    func applySort(_ index: Int, log: Bool) {
        if log {
            let all = CompanionStore.CatchLogSortOption.allCases
            guard index >= 0, index < all.count else { return }
            browser.setLogSort(all[index])
        } else {
            let all = CompanionStore.DexSortOption.allCases
            guard index >= 0, index < all.count else { return }
            browser.setDexSort(all[index])
        }
        refresh()
    }

    // MARK: the Pokédex view

    private func wire(_ view: WinDrawnView, _ part: DexBodyPart) {
        view.onPointer = { [weak part] p in part?.setPointer(p) }
        view.onHit = { [weak self] hit in self?.dexHit(hit) }
        view.onKey = { [weak self, weak view] vk in
            guard let self, let view else { return false }
            return self.dexKey(vk, view)
        }
        view.onFocus = { [weak self, weak view] focused in
            guard focused, let self, let view, let hit = Self.focusedHit(view) else { return }
            if hit.action == DexBodyPart.regionAction, let i = hit.index { self.dexPart?.reveal(region: i) }
            if hit.action == DexBodyPart.rarityAction, let i = hit.index { self.dexPart?.reveal(rarity: i) }
        }
        view.onContextMenu = { [weak self] hit, point in self?.cellMenu(hit, point) }
        for message: UINT in [0x020E, 0x020A] {   // WM_MOUSEHWHEEL, WM_MOUSEWHEEL
            view.window.on(message) { [weak self, weak view] wParam, lParam in
                guard let self, let view else { return nil }
                return self.dexWheel(message, wParam, lParam, view)
            }
        }
    }

    /// The hit of the focused item of a drawn view.
    static func focusedHit(_ view: WinDrawnView) -> PlazaPanelHit? {
        guard let focus = GetFocus(), let i = view.items.firstIndex(where: { $0.hwnd == focus }) else { return nil }
        let items = (view.drawing?.drawing.accessibility ?? []).filter { $0.role != .scrollArea }
        return i < items.count ? items[i].action : nil
    }

    /// Puts the keyboard on the item whose hit is `action` / `index`.
    private static func focus(_ view: WinDrawnView, action: String, index: Int?) {
        let items = (view.drawing?.drawing.accessibility ?? []).filter { $0.role != .scrollArea }
        guard let i = items.firstIndex(where: { $0.action?.action == action && $0.action?.index == index }), i < view.items.count else { return }
        _ = SetFocus(view.items[i].hwnd)
    }

    func dexHit(_ hit: PlazaPanelHit) {
        stats.hits += 1
        guard let model = dexPart?.model else { return }
        switch hit.action {
        case DexBodyPart.cellAction:
            guard let i = hit.index, model.cells.indices.contains(i) else { return }
            browser.selectedID = model.cells[i].collectionID
            refresh()
            openEntry(model.cells[i].collectionID)
        case DexBodyPart.regionAction:
            guard let i = hit.index, model.regions.indices.contains(i) else { return }
            browser.toggleRegion(model.regions[i].region)
            refresh()
        case DexBodyPart.rarityAction:
            guard let i = hit.index, model.rarities.indices.contains(i) else { return }
            browser.toggleRarity(model.rarities[i].rarity)
            refresh()
        case DexBodyPart.prevAction: turnPage(to: model.footer.current - 1, model)
        case DexBodyPart.nextAction: turnPage(to: model.footer.current + 1, model)
        case DexBodyPart.repAction:
            guard let sel = model.footer.selection, sel.representativeTitle != nil else { return }
            toggleRepresentative(speciesID: sel.speciesID, isRepresentative: sel.isRepresentative)
        case DexBodyPart.clearAction:
            browser.resetFilters()
            refresh()
        default: break
        }
    }

    private func turnPage(to page: Int, _ model: DexBodyModel) {
        let next = DexPaging.pageAfterScroll(current: model.footer.current, pageCount: model.footer.pageCount, step: page - model.footer.current)
        guard next != model.footer.current else { return }
        browser.page = next
        browser.selectedID = nil
        stats.pageTurns += 1
        refresh()
    }

    private func toggleRepresentative(speciesID: Int, isRepresentative: Bool) {
        _ = store.setRepresentativeSpeciesID(isRepresentative ? nil : speciesID)
        refresh()
    }

    /// The seam of the detail page (Task 21): records the Mac's `dexDetailCollectionID` and tells `onOpenEntry`.
    func openEntry(_ collectionID: String) {
        stats.opened.append(collectionID)
        host.state.dexDetailCollectionID = collectionID
        onOpenEntry?(collectionID)
    }

    private func dexKey(_ vk: Int, _ view: WinDrawnView) -> Bool {
        guard let part = dexPart, let hit = Self.focusedHit(view), hit.action == DexBodyPart.cellAction, let i = hit.index,
              let move = part.key(vk, from: i) else { return false }
        switch move {
        case .focusCell(let n): Self.focus(view, action: DexBodyPart.cellAction, index: n)
        case .page(let d): turnPage(to: part.model.footer.current + d, part.model)
        }
        return true
    }

    private func cellMenu(_ hit: PlazaPanelHit?, _ point: POINT) {
        guard let hit, hit.action == DexBodyPart.cellAction, let i = hit.index, let model = dexPart?.model, model.cells.indices.contains(i) else { return }
        let cell = model.cells[i]
        let title: String
        if cell.formCount != nil {
            title = l.chooseForm
        } else {
            title = cell.isRepresentative ? l.representativeFollowCurrent : l.representativeSet
        }
        let owner = dexView.map { GetAncestor($0.hwnd, 2) ?? $0.hwnd } ?? host.stack.pane.hwnd
        stats.menus += 1
        guard let chosen = menu([TrayMenuModel.Item(title: title, enabled: true, checked: false, action: .none)], point, owner), chosen == 0 else { return }
        // The item is rebuilt by what the choice changes, and it is the window the menu came from: act after the message returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if cell.formCount != nil { self.openEntry(cell.collectionID) } else {
                self.toggleRepresentative(speciesID: cell.number, isRepresentative: cell.isRepresentative)
            }
        }
    }

    /// The wheel over the Pokédex: a notch (or a touchpad swipe's worth) turns the page; the chip rows scroll sideways with the
    /// horizontal wheel or Shift + wheel.
    private func dexWheel(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ view: WinDrawnView) -> LRESULT? {
        guard let part = dexPart else { return nil }
        var p = POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
        _ = ScreenToClient(view.hwnd, &p)
        let point = CGPoint(x: CGFloat(p.x) / ctx.scale, y: CGFloat(p.y) / ctx.scale)
        let delta = WinKit.signedHiWord(wParam)
        let horizontal = message == 0x020E
        if horizontal || WinKit.loWord(wParam) & 0x0004 /* MK_SHIFT */ != 0 {
            let dx = chipWheel.offsetChange(delta: horizontal ? -delta : delta, lines: 3, lineHeight: 10, page: 100)
            return part.scrollChips(at: point, by: dx) ? 0 : nil
        }
        guard !part.model.isEmpty else { return nil }
        // DexScrollPager: one page per notch; a touchpad's small deltas add up (24 points, a notch is 120 units = 40 points)
        let step = wheel.step(deltaY: CGFloat(delta) / 3, precise: abs(delta) < 120)
        if step != 0 {
            stats.wheelSteps += 1
            turnPage(to: part.model.footer.current + step, part.model)
        }
        return 0
    }

    // MARK: the catch log view

    private func wireLog(_ view: WinDrawnView, _ part: DexLogPart) {
        view.onPointer = { [weak part] p in part?.setPointer(p) }
        view.onHit = { [weak self] hit in self?.logHit(hit) }
        view.onKey = { [weak part] vk in part?.key(vk) ?? false }
        for message: UINT in [0x020E, 0x020A] {
            view.window.on(message) { [weak self, weak view] wParam, lParam in
                guard let self, let view, let part = self.logPart else { return nil }
                var p = POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
                _ = ScreenToClient(view.hwnd, &p)
                let point = CGPoint(x: CGFloat(p.x) / self.ctx.scale, y: CGFloat(p.y) / self.ctx.scale)
                let delta = WinKit.signedHiWord(wParam)
                if message == 0x020E || WinKit.loWord(wParam) & 0x0004 != 0 {
                    let dx = self.chipWheel.offsetChange(delta: message == 0x020E ? -delta : delta, lines: 3, lineHeight: 10, page: 100)
                    return part.scrollChips(at: point, by: dx) ? 0 : nil
                }
                var lines: UINT = 3
                _ = SystemParametersInfoW(0x0068 /* SPI_GETWHEELSCROLLLINES */, 0, &lines, 0)
                let dy = self.listWheel.offsetChange(delta: delta, lines: lines, lineHeight: 16, page: part.viewportHeight)
                _ = part.scroll(by: dy)
                return 0
            }
        }
    }

    func logHit(_ hit: PlazaPanelHit) {
        stats.hits += 1
        guard let model = logPart?.model else { return }
        switch hit.action {
        case DexLogPart.rarityAction:
            guard let i = hit.index, model.rarities.indices.contains(i) else { return }
            browser.toggleRarity(model.rarities[i].rarity)
            refresh()
        case DexLogPart.nodeAction:
            if let target = hit.target { openEntry(target) }
        case DexLogPart.thumbAction:
            logPart?.endDrag()
        case DexLogPart.clearAction:
            browser.resetFilters()
            refresh()
        default: break
        }
    }
}

extension WinHomePage {
    /// A sprite of Home opens its Pokédex page (`PopoverState.openDexEntry`: the Collection tab with that cell's detail
    /// requested); the page for the tab is built in place.
    func openDexEntry(_ collectionID: String) {
        state.openDexEntry(collectionID: collectionID)
        syncTab()
    }
}
// MARK: end Task 20
#endif
