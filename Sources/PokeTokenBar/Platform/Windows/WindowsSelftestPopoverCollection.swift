#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 20: the Collection tab's selftest group (`collection.*`). The real Home page frame in a kit window on the Collection
// tab, fed FIXTURE dexes (species 1…N named "Species n", every 7th shiny; no real names or saves); sprites from the fixture folder
// (or the 🥚 when there is none). With `--dump-ui <dir>` the states go to `<dir>/collection/` as PNGs.

extension WindowsSelftest {
    @MainActor static func popoverCollectionChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverCollection.run(r, app)
    }
}

private struct CollectionFixturePoke: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw LimitsError.keychainAccessDisabled }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor enum WindowsSelftestPopoverCollection {
    static let names = ["collection.grid", "collection.paging", "collection.filters", "collection.representative", "collection.empty",
                        "collection.homeLinks", "collection.openClose"]

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    private static func seeded(_ count: Int, language: AppLanguage) async -> HomeStores {
        let base = await HomeStores.make(language: language)
        var state = CompanionState()
        state.language = language
        let rarities: [Rarity] = [.common, .uncommon, .rare, .legendary]
        state.dex = (1..<(count + 1)).map { id in
            DexEntry(id: "fixture-\(id)", baseID: id, finalID: id, chainOrder: [id], rarity: rarities[id % 4],
                     caughtAt: Date(timeIntervalSinceNow: -Double(id) * 5400), isShiny: id % 7 == 0,
                     names: [id: ["en": "Species \(id)", "ko": "종 \(id)"]])
        }
        if count == 0 { state.dex = [] }
        let file = base.directory.appendingPathComponent("collection-\(UUID().uuidString).json")
        try? JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(provider: CollectionFixturePoke(), fileURL: file, defaults: WinDefaultsSync.makeAppDefaults())
        return HomeStores(store: base.store, companion: companion, team: base.team, state: base.state, directory: base.directory)
    }

    private static func harness(_ count: Int, language: AppLanguage, log: Bool = false) async -> (HomeHarness, WinCollectionPage)? {
        let stores = await seeded(count, language: language)
        stores.state.tab = .collection
        stores.state.showingCollectionLog = log
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }, heightDIP: 700),
              let page = h.page.tabContent as? WinCollectionPage else { return nil }
        h.window.show(activate: false)
        await wait(0.3)
        return (h, page)
    }

    private static func descendants(_ root: HWND) -> Int {
        var n = 0
        var child = GetWindow(root, 5 /* GW_CHILD */)
        while let c = child {
            n += 1 + descendants(c)
            child = GetWindow(c, 2 /* GW_HWNDNEXT */)
        }
        return n
    }

    private static func capture(_ hwnd: HWND) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    private static func dump(_ h: HomeHarness, _ name: String) {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("collection", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let shot = capture(h.window.hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("collection-\(name).png")) }
    }

    private static func items(_ view: WinDrawnView?, _ action: String) -> [WinControl] {
        guard let view else { return [] }
        let list = (view.drawing?.drawing.accessibility ?? []).filter { $0.role != .scrollArea }
        return zip(view.items, list).filter { $0.1.action?.action == action }.map(\.0)
    }

    private static func press(_ c: WinControl?) { if let c { WinKit.send(c.hwnd, 0x00F5 /* BM_CLICK */) } }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        WinCompanionSection.spriteFetcherOverride = WindowsSelftestPopoverCompanion.fixtureFetcher()
        let start = KitResources.now()
        await gridCheck(r)
        await pagingCheck(r)
        await filtersCheck(r)
        await representativeCheck(r)
        await emptyCheck(r)
        await homeLinksCheck(r)
        await openCloseCheck(r, start: start)
    }

    // MARK: collection.grid

    private static func gridCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        for language in [AppLanguage.en, .ko] {
            let began = Date()
            guard let (h, page) = await harness(120, language: language) else { problems.append("no page \(language)"); continue }
            defer { h.destroy() }
            let built = Date().timeIntervalSince(began)
            guard let view = page.dexView, let part = page.dexPart else { problems.append("no dex view \(language)"); continue }
            let cells = items(view, DexBodyPart.cellAction)
            let slots = view.spriteSlots.count
            let windows = descendants(h.window.hwnd)
            let model = part.model
            if cells.count != 16 || model.cells.count != 16 { problems.append("\(language): \(cells.count) cell items, \(model.cells.count) cells") }
            if slots != 16 { problems.append("\(language): \(slots) sprite slots") }
            if windows > 90 { problems.append("\(language): \(windows) child windows for a full dex") }
            if model.footer.pageText != "1 / 8" { problems.append("\(language): footer \(model.footer.pageText ?? "nil")") }
            if page.logRow != nil { problems.append("\(language): the log was built before it was asked for") }
            let tips = view.drawing?.drawing.tooltips.count ?? 0
            if tips < 16 { problems.append("\(language): \(tips) tooltips") }
            // the page is the Mac's 520 pt: the scroller does not scroll
            if let area = h.window.scroll, area.contentHeight > area.viewportHeight + 2 { problems.append("\(language): content \(area.contentHeight) > viewport \(area.viewportHeight)") }
            // a click on a cell selects it and opens its entry
            if let first = cells.first { press(first) }
            await wait(0.2)
            let opened = page.stats.opened == ["1"] && h.stores.state.dexDetailCollectionID == "1" && page.browser.selectedID == "1"
            if !opened { problems.append("\(language): click opened \(page.stats.opened), detail \(String(describing: h.stores.state.dexDetailCollectionID))") }
            await wait(0.2)
            dump(h, "grid-\(language.rawValue)")
            // more captures for the sheets: the second page (shiny entries 21 and 28), a search with no result, the log
            press(items(view, DexBodyPart.nextAction).first)
            await wait(0.3)
            dump(h, "grid-page2-\(language.rawValue)")
            page.search?.text = "zzz"
            await wait(0.3)
            dump(h, "search-none-\(language.rawValue)")
            page.resetFilters()
            h.stores.state.showingCollectionLog = true
            page.refresh()
            await wait(0.5)
            dump(h, "log-\(language.rawValue)")
            notes.append("\(language): built in \(Int(built * 1000)) ms, \(windows) child windows (\(cells.count) cells, \(view.items.count) items, \(slots) sprites), footer \(model.footer.pageText ?? "-"), click opened=\(opened)")
        }
        r.add("collection.grid", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.paging

    private static func pagingCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        guard let (h, page) = await harness(120, language: .en), let view = page.dexView else { r.add("collection.paging", false, "no page"); return }
        defer { h.destroy() }
        func footer() -> String { page.dexPart?.model.footer.pageText ?? "-" }
        // the wheel: a notch down (negative delta) is the next page
        _ = SendMessageW(view.hwnd, 0x020A, WPARAM(UInt(bitPattern: Int(-120)) << 16), 0)
        await wait(0.2)
        let afterWheel = footer()
        if afterWheel != "2 / 8" { problems.append("wheel: \(afterWheel)") }
        // the arrows
        press(items(view, DexBodyPart.nextAction).first)
        await wait(0.2)
        let afterNext = footer()
        if afterNext != "3 / 8" { problems.append("next: \(afterNext)") }
        press(items(view, DexBodyPart.prevAction).first)
        await wait(0.2)
        if footer() != "2 / 8" { problems.append("previous: \(footer())") }
        // the keyboard: focus a cell, End, Page Down
        h.window.show(activate: true)
        await wait(0.3)
        if let cell = items(view, DexBodyPart.cellAction).first {
            _ = SetFocus(cell.hwnd)
            let handled = cell.onKey?(0x23) ?? false   // VK_END
            await wait(0.2)
            let focusOn = items(view, DexBodyPart.cellAction).last.map { GetFocus() == $0.hwnd } ?? false
            if !handled || !focusOn { problems.append("End: handled=\(handled) focus on the last cell=\(focusOn)") }
            let paged = items(view, DexBodyPart.cellAction).last?.onKey?(0x22) ?? false  // VK_NEXT
            await wait(0.2)
            if !paged || footer() != "3 / 8" { problems.append("Page Down: handled=\(paged) \(footer())") }
        } else { problems.append("no cell") }
        // a filter or a search starts on page 1 again (the Mac's onChange)
        page.search?.text = "Species 1"
        await wait(0.3)
        if page.dexPart?.model.footer.current != 0 { problems.append("a search did not start on page 1") }
        notes.append("wheel -> \(afterWheel), next -> \(afterNext), previous, End/Page Down by key, search resets the page")
        r.add("collection.paging", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.filters

    private static func filtersCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        guard let (h, page) = await harness(120, language: .en), let view = page.dexView else { r.add("collection.filters", false, "no page"); return }
        defer { h.destroy() }
        func shown() -> Int { page.dexPart?.model.visibleIDs.count ?? -1 }
        page.search?.text = "Species 11"
        await wait(0.3)
        let searched = shown()   // 11, 110…119
        if searched != 11 { problems.append("search 'Species 11': \(searched)") }
        if page.clear?.isVisibleForTesting != true { problems.append("the clear button is not shown with text") }
        press(page.clear)
        await wait(0.3)
        if shown() != 120 || page.search?.text != "" { problems.append("clear: \(shown())") }
        press(page.shiny)
        await wait(0.3)
        let shiny = shown()
        if shiny != 17 { problems.append("shiny only: \(shiny)") }   // every 7th of 120
        press(page.shiny)
        await wait(0.3)
        press(items(view, DexBodyPart.rarityAction).first)   // Legendary
        await wait(0.3)
        let legendary = shown()
        if legendary != 30 { problems.append("legendary: \(legendary)") }
        page.resetFilters()
        page.search?.text = "zzz"
        await wait(0.3)
        let none = page.dexPart?.model.isEmpty == true && !items(view, DexBodyPart.clearAction).isEmpty
        if !none { problems.append("no results state missing") }
        dump(h, "search-none")
        press(items(view, DexBodyPart.clearAction).first)
        await wait(0.3)
        if shown() != 120 { problems.append("reset filters: \(shown())") }
        // sort (stand-in menu): the second entry is "number, descending"
        page.menu = { items, _, _ in items.count > 1 ? 1 : nil }
        press(page.sort)
        await wait(0.3)
        if page.dexPart?.model.cells.first?.number != 120 { problems.append("sort descending: first \(page.dexPart?.model.cells.first?.number ?? 0)") }
        // the segment: the catch log, virtualised
        page.resetFilters()
        page.segment?.selection = 1
        h.stores.state.showingCollectionLog = true
        page.refresh()
        await wait(0.5)
        let logSlots = page.logView?.spriteSlots.count ?? -1
        let logRows = page.logPart?.model.rows.count ?? -1
        if logRows != 120 || logSlots < 1 || logSlots > 14 { problems.append("log rows \(logRows), slots in view \(logSlots)") }
        if page.dexRow?.isVisible == true { problems.append("the grid stays visible over the log") }
        dump(h, "log")
        _ = SendMessageW(page.logView?.hwnd, 0x020A, WPARAM(UInt(bitPattern: Int(-120)) << 16), 0)
        await wait(0.2)
        if (page.logPart?.scrollY ?? 0) <= 0 { problems.append("the wheel did not scroll the log") }
        notes.append("search 11→\(searched), shiny \(shiny), legendary \(legendary), no-results state \(none), sort, log \(logRows) rows with \(logSlots) sprites in view")
        r.add("collection.filters", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.representative

    private static func representativeCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        guard let (h, page) = await harness(40, language: .en), let view = page.dexView else { r.add("collection.representative", false, "no page"); return }
        defer { h.destroy() }
        let store = h.stores.companion
        page.menu = { _, _, _ in 0 }
        guard let cell = items(view, DexBodyPart.cellAction).dropFirst(2).first else { r.add("collection.representative", false, "no cell"); return }
        _ = SendMessageW(cell.hwnd, 0x007B /* WM_CONTEXTMENU */, WPARAM(UInt(bitPattern: cell.hwnd)), LPARAM(-1))
        await wait(0.4)
        if store.representativeSpeciesID != 3 { problems.append("context menu: representative \(String(describing: store.representativeSpeciesID))") }
        if page.dexPart?.model.cells[2].isRepresentative != true { problems.append("the cell does not show the star") }
        dump(h, "representative")
        // the footer button: select the cell, then the button follows the current Pokémon again
        press(items(view, DexBodyPart.cellAction).dropFirst(2).first)
        await wait(0.3)
        press(items(view, DexBodyPart.repAction).first)
        await wait(0.3)
        if store.representativeSpeciesID != nil { problems.append("footer button: representative \(String(describing: store.representativeSpeciesID))") }
        notes.append("context menu sets species 3; the footer button gives it back (follow current)")
        r.add("collection.representative", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.empty

    private static func emptyCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        for language in [AppLanguage.en, .ko] {
            guard let (h, page) = await harness(0, language: language) else { problems.append("no page"); continue }
            defer { h.destroy() }
            let l = L(language)
            if page.emptyRow?.isVisible != true || page.dexRow?.isVisible == true || page.toolbarRow?.isVisible == true { problems.append("\(language): rows wrong") }
            // the Mac's empty Pokédex is as short as its content: the window is shorter than with a dex (520 pt scroller)
            if !page.contentIsShort { problems.append("\(language): the empty state is not short content") }
            else if language == .en, let (full, _) = await harness(20, language: .en) {
                defer { full.destroy() }
                if h.page.heightDIP + 100 >= full.page.heightDIP { problems.append("the empty state's page is \(h.page.heightDIP) DIP tall, with a dex \(full.page.heightDIP)") }
                else { notes.append("page height empty \(h.page.heightDIP) DIP, with a dex \(full.page.heightDIP) DIP") }
            }
            let slots = page.emptyView?.spriteSlots ?? []
            if slots.count != 1 || slots[0].subject?.speciesID != 25 || slots[0].animated != true { problems.append("\(language): Pikachu slot \(slots)") }
            let texts = (page.emptyView?.drawing?.drawing.accessibility ?? []).map(\.label)
            if !texts.contains(l.dexEmptyTitle) || !texts.contains(l.dexEmptyHint) { problems.append("\(language): texts \(texts)") }
            dump(h, "empty-\(language.rawValue)")
            notes.append("\(language): title and hint shown, \(slots.count) animated sprite")
        }
        r.add("collection.empty", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.homeLinks (C2)

    private static func homeLinksCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        let stores = await seeded(5, language: .en)
        stores.state.tab = .home
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }, heightDIP: 700) else { r.add("collection.homeLinks", false, "no window"); return }
        defer { h.destroy() }
        h.window.show(activate: false)
        await wait(0.3)
        if let section = h.page.companionSection {
            let nodes = [EvoLineItem(.species(1), .done), EvoLineItem(.species(2), .current), EvoLineItem(.species(3), .future)]
            section.inputOverride = { WindowsSelftestPopoverCompanion.mon(.en, id: 2, path: [1, 2, 3], stage: 2, name: "Species 2", progress: 0.5, nodes: nodes) }
            section.dexLinksOverride = [1: "1", 2: "2"]
            section.reload()
            await wait(0.3)
            let linked = (section.line?.view.drawing?.drawing.accessibility ?? []).filter { $0.action?.action == EvoLinePart.dexAction }
            let headerLink = section.header?.part.dexLink?.target
            notes.append("evolution line: \(linked.count) button items (species 1 and 2 are in the dex, 3 is not), header sprite links to \(headerLink ?? "nothing")")
            if linked.count != 2 || headerLink != "2" { problems.append("links: line \(linked.count), header \(String(describing: headerLink))") }
            let headerItems = (section.header?.view.drawing?.drawing.accessibility ?? []).filter { $0.action?.action == CompanionHeaderPart.dexAction }
            if headerItems.count != 1 { problems.append("header link items \(headerItems.count)") }
            press(items(section.header?.view, CompanionHeaderPart.dexAction).first)
            await wait(0.3)
            if stores.state.tab != .collection || stores.state.dexDetailCollectionID != "2" {
                problems.append("click: tab \(stores.state.tab) detail \(String(describing: stores.state.dexDetailCollectionID))")
            }
        } else { problems.append("no companion section") }
        r.add("collection.homeLinks", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: collection.openClose

    private static func openCloseCheck(_ r: WindowsSelftest.Recorder, start: KitResources) async {
        var cycles: [KitResources] = []
        var armed = false
        for _ in 0..<4 {
            guard let (h, page) = await harness(120, language: .en, log: cycles.count % 2 == 1) else { break }
            page.refresh()
            await wait(0.2)
            h.destroy()
            armed = armed || page.isClockArmedForTesting
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        guard cycles.count == 4, let last = cycles.last else { r.add("collection.openClose", false, "only \(cycles.count) of 4 cycles"); return }
        let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) }, userSlack: 1)
        let ok = verdict.ok && last.controls == 0 && last.pumpDepth == 0 && !armed
        r.add("collection.openClose", ok, "open/close x4 (grid, log, grid, log): \(verdict.summary); clock armed after close=\(armed); \(last)")
    }
}
#endif
