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

private struct CollectionFixturePoke: PokeProviding, PokemonDetailProviding {
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(speciesID: speciesID, name: "species-\(speciesID)", height: 7, weight: 69, baseExperience: 64, genderRate: 1, types: ["grass", "poison"],
                       baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
                       abilities: [PokemonAbilityOption(name: "overgrow", slot: 1, isHidden: false), PokemonAbilityOption(name: "chlorophyll", slot: 3, isHidden: true)],
                       moves: (0..<80).map { PokemonMoveOption(name: "move-\($0)", learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: $0), PokemonMoveLearnMethod(method: "machine", level: 0)]) })
    }
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw LimitsError.keychainAccessDisabled }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// Fixture names for the detail page (no network in the selftest).
private struct CollectionFixtureNames: PokemonNameProviding {
    func names(for resource: PokemonNameResource) async throws -> [String: String] {
        ["en": "Fixture \(resource.name)", "ko": "예시 \(resource.name)"]
    }
}

@MainActor enum WindowsSelftestPopoverCollection {
    static let names = ["collection.grid", "collection.paging", "collection.filters", "collection.representative", "collection.empty",
                        "collection.homeLinks", "collection.detail", "collection.openClose"]

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
        let companion = CompanionStore(provider: CollectionFixturePoke(), detailProvider: CollectionFixturePoke(), fileURL: file, defaults: WinDefaultsSync.makeAppDefaults())
        return HomeStores(store: base.store, companion: companion, team: base.team, state: base.state, directory: base.directory)
    }

    private static func harness(_ count: Int, language: AppLanguage, log: Bool = false, dpi: UINT? = nil) async -> (HomeHarness, WinCollectionPage)? {
        let stores = await seeded(count, language: language)
        stores.state.tab = .collection
        stores.state.showingCollectionLog = log
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }, dpi: dpi, heightDIP: 700),
              let page = h.page.tabContent as? WinCollectionPage else { return nil }
        // The window is as tall as the page (update offer + the Mac's 520 pt scroller + footer), as the popover sizes itself: a fixed
        // 700 DIP left the scroller 519 px when the offer grew by a pixel with the K1 type ramp, which brought the page's native bar back.
        h.window.fitToContent()
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

    /// WCAG ratio of the pixel farthest from the fill (the glyph's ink) against the fill, inside a window rectangle.
    static func glyphRatio(_ shot: WinUIDump.Bitmap, fillAt: (x: Int, y: Int), x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (min(max(0, y), shot.height - 1) * shot.width + min(max(0, x), shot.width - 1)) * 4
            return (Int(shot.bgra[i + 2]), Int(shot.bgra[i + 1]), Int(shot.bgra[i]))
        }
        func lum(_ c: (Int, Int, Int)) -> Double {
            func ch(_ v: Int) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
        }
        let fill = rgb(fillAt.x, fillAt.y)
        var best = fill, far = 0
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) {
            let p = rgb(x, y)
            let d = abs(p.0 - fill.0) + abs(p.1 - fill.1) + abs(p.2 - fill.2)
            if d > far { far = d; best = p }
        } }
        return (max(lum(best), lum(fill)) + 0.05) / (min(lum(best), lum(fill)) + 0.05)
    }

    /// The share of pixels in a window rectangle that differ from the rectangle's most common colour: 0 for a blank surface, a few
    /// percent for text and bars. The drawn parts' own checks read models and window texts, never pixels, so an opaque tile painted
    /// over its content (the detail card went blank white in K1 and every check stayed green) was invisible to them.
    static func inkFraction(_ shot: WinUIDump.Bitmap, x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        var counts: [UInt32: Int] = [:]
        var total = 0
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * shot.width + x) * 4
            return (Int(shot.bgra[i]), Int(shot.bgra[i + 1]), Int(shot.bgra[i + 2]))
        }
        let xs = max(0, x0)..<min(shot.width, x1), ys = max(0, y0)..<min(shot.height, y1)
        for y in ys { for x in xs {
            let p = pixel(x, y)
            counts[UInt32(p.0) << 16 | UInt32(p.1) << 8 | UInt32(p.2), default: 0] += 1
            total += 1
        } }
        guard total > 0, let common = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let b0 = Int(common >> 16), g0 = Int(common >> 8 & 0xFF), r0 = Int(common & 0xFF)
        var ink = 0
        for y in ys { for x in xs {
            let p = pixel(x, y)
            if abs(p.0 - b0) + abs(p.1 - g0) + abs(p.2 - r0) > 60 { ink += 1 }
        } }
        return Double(ink) / Double(total)
    }

    /// Ink in a band of a window child (`fromY`...`toY` of its height, the middle 76 % of its width), in percent; nil without a capture.
    private static func ink(of child: HWND, in window: HWND, fromY: Int, toY: Int) -> Double? {
        guard let shot = capture(window) else { return nil }
        let r = WinKit.rect(child, in: window)
        let w = Int(r.right - r.left), h = Int(r.bottom - r.top)
        return inkFraction(shot, x0: Int(r.left) + w * 12 / 100, y0: Int(r.top) + h * fromY / 100, x1: Int(r.left) + w * 88 / 100, y1: Int(r.top) + h * toY / 100) * 100
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
        await hoverCostCheck(r)
        await filtersCheck(r)
        await representativeCheck(r)
        await emptyCheck(r)
        await homeLinksCheck(r)
        await detailCheck(r)
        await captures150()
        await openCloseCheck(r, start: start)
    }

    /// K0: the grid and the detail page at 150 % (a context at 144 dpi), en and ko; captures only, no check of their own.
    private static func captures150() async {
        for language in [AppLanguage.en, .ko] {
            if let (h, _) = await harness(120, language: language, dpi: 144) {
                dump(h, "grid-\(language.rawValue)-150")
                h.destroy()
            }
            if let (h, page) = await harness(20, language: language, dpi: 144) {
                page.nameProvider = CollectionFixtureNames()
                page.openEntry("7")
                _ = await WindowsSelftest.waitUntil(timeout: 4) {
                    if case .details? = page.detailPart.map({ $0.model.content }) { return page.detailPart?.model.identity.types.first?.text.contains("…") == false }
                    return false
                }
                await wait(0.4)
                dump(h, "detail-top-\(language.rawValue)-150")
                h.destroy()
            }
        }
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
            // the page is the Mac's 520 pt: the scroller does not scroll, and its native bar is not on the screen (the lane stays empty)
            if let area = h.window.scroll, area.contentHeight > area.viewportHeight + 2 { problems.append("\(language): content \(area.contentHeight) > viewport \(area.viewportHeight)") }
            if let area = h.window.scroll, area.barVisible != PopoverScrollMath.showsBar(content: CGFloat(area.contentHeight), viewport: CGFloat(area.viewportHeight)) { problems.append("\(language): the native scroll bar is \(area.barVisible ? "shown" : "hidden") with the content at (\(area.contentHeight) px in \(area.viewportHeight))") }
            // a click on a cell selects it and opens its entry
            if let first = cells.first { press(first) }
            await wait(0.2)
            let opened = page.stats.opened == ["1"] && h.stores.state.dexDetailCollectionID == "1" && page.browser.selectedID == "1" && page.isShowingDetail
            if !opened { problems.append("\(language): click opened \(page.stats.opened), detail \(String(describing: h.stores.state.dexDetailCollectionID)), showing \(page.isShowingDetail)") }
            await wait(0.3)
            page.closeDetail()   // Back: the grid again, on that species' page
            await wait(0.3)
            if page.isShowingDetail || page.dexRow?.isVisible != true { problems.append("\(language): Back did not return to the grid") }
            dump(h, "grid-\(language.rawValue)")
            // a Pokédex cell shows its number, picture and name on its tile
            if cells.count > 4, let percent = ink(of: cells[4].hwnd, in: h.window.hwnd, fromY: 10, toY: 90) {
                notes.append("\(language): ink in a Pokédex cell \(Double(Int(percent * 10)) / 10) %")
                if percent < 3 { problems.append("\(language): the Pokédex cell is blank (ink \(percent) %)") }
            } else { problems.append("\(language): no capture for a cell's ink") }
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

    /// Field report 2026-11-19 (a real PC): the Pokédex flickers and is slow. Every render of the grid (a hover frame, a sprite) repainted all of
    /// its ~40 item windows (erase and paint each), and a model change made them all again. Moving the pointer across twelve cells must repaint
    /// only the windows near the pointer: the paint and erase messages of the popover's windows are counted (drawn views left out), the item
    /// windows must not be made again, and the windows the pointer never touched must not repaint.
    private static func hoverCostCheck(_ r: WindowsSelftest.Recorder) async {
        guard let (h, page) = await harness(120, language: .en), let view = page.dexView, let part = page.dexPart else { r.add("collection.hoverCost", false, "no page"); return }
        defer { h.destroy() }
        h.window.show(activate: true)
        await wait(0.5)
        let cells = items(view, DexBodyPart.cellAction)
        let all = view.items.count
        guard cells.count >= 12 else { r.add("collection.hoverCost", false, "\(cells.count) cells"); return }
        let builds0 = view.stats.itemBuilds, moves0 = view.stats.itemMoves
        WinPaintSpy.start(h.window.hwnd)
        for cell in cells.prefix(12) {
            var rect = RECT()
            _ = GetWindowRect(cell.hwnd, &rect)
            var at = POINT(x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2)
            _ = ScreenToClient(view.hwnd, &at)
            part.setPointer(CGPoint(x: CGFloat(at.x) / view.ctx.scale, y: CGFloat(at.y) / view.ctx.scale))
            await wait(0.08)
        }
        await wait(0.3)
        let counts = WinPaintSpy.counts
        WinPaintSpy.stop()
        let messages = counts.sent + counts.queued
        // 12 moves, each repainting the two cells it touches and the item windows over them: about 7 windows, 3 messages each (erase, non-client
        // paint, paint). Before the fix every move repainted every item window: \(all) x 3 per move (computed, not measured).
        let budget = 12 * 25   // measured 250 on the runner (about 7 windows per move, 3 messages each); a full repaint is 12 x 29 x 3 = 1044
        let ok = view.stats.itemBuilds == builds0 && messages <= budget
        r.add("collection.hoverCost", ok,
              "12 hovers over the grid with \(all) item windows: paint/erase messages to the popover's windows (drawn views left out) \(messages) (budget \(budget); a full repaint per move would be \(12 * all * 3)), "
              + "item rebuilds +\(view.stats.itemBuilds - builds0), frames with a paint \(counts.frames), item moves \(view.stats.itemMoves - moves0)"
              + (ok ? "" : "; OVER BUDGET"))
    }

    private static func pagingCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        guard let (h, page) = await harness(120, language: .en), let view = page.dexView else { r.add("collection.paging", false, "no page"); return }
        defer { h.destroy() }
        func footer() -> String { page.dexPart?.model.footer.pageText ?? "-" }
        dump(h, "pager-first")   // page 1 of 8: the previous arrow is the disabled one
        // what is on the real window, not what the part would draw: the enabled arrow's pixels against the window (the user's report was
        // about this, and the offscreen check in popover.glyphContrast could not see a paint path that hides the arrow)
        func liveArrow(_ action: String, _ label: String) {
            guard let item = items(view, action).first, let shot = capture(h.window.hwnd) else { problems.append("\(label): no item or capture"); return }
            let rc = WinKit.rect(item.hwnd, in: h.window.hwnd), inView = WinKit.rect(item.hwnd, in: view.hwnd)
            let ratio = glyphRatio(shot, fillAt: (Int(rc.left) + 2, Int(rc.top) + 2), x0: Int(rc.left) + 2, y0: Int(rc.top) + 2, x1: Int(rc.right) - 2, y1: Int(rc.bottom) - 2)
            notes.append("live \(label) \(String(format: "%.1f", ratio)):1 (window box \(rc.left),\(rc.top)-\(rc.right),\(rc.bottom); picture pixels there \(view.pictureInk(inView)))")
            // DIAGNOSTICS (why the picture's ink is not on the window): which item windows cover the arrow's box, the item painted alone, and the
            // view painted with the item hidden
            var covering: [String] = []
            for other in view.items {
                let o = WinKit.rect(other.hwnd, in: view.hwnd)
                if o.left < inView.right, o.right > inView.left, o.top < inView.bottom, o.bottom > inView.top {
                    covering.append("\(other.text) [\(o.left),\(o.top)-\(o.right),\(o.bottom)] visible=\(IsWindowVisible(other.hwnd)) z=\(GetWindow(other.hwnd, 3 /* GW_HWNDPREV */) == nil ? "top" : "behind")")
                }
            }
            var alone = "n/a"
            var w: UInt32 = 0, ht: UInt32 = 0
            var out: UnsafeMutablePointer<UInt8>?
            if ptb_window_print(UnsafeMutableRawPointer(item.hwnd), &w, &ht, &out) == 0, let out {
                let bmp = WinUIDump.Bitmap(width: Int(w), height: Int(ht), bgra: Array(UnsafeBufferPointer(start: out, count: Int(w * ht) * 4)))
                ptb_plaza_free(out)
                alone = String(format: "%.2f", glyphRatio(bmp, fillAt: (2, 2), x0: 2, y0: 2, x1: Int(w) - 2, y1: Int(ht) - 2))
            }
            _ = ShowWindow(item.hwnd, 0 /* SW_HIDE */)
            _ = InvalidateRect(view.hwnd, nil, false)
            _ = UpdateWindow(view.hwnd)
            var without = "n/a"
            if let shot2 = capture(h.window.hwnd) {
                without = String(format: "%.2f", glyphRatio(shot2, fillAt: (Int(rc.left) + 2, Int(rc.top) + 2), x0: Int(rc.left) + 2, y0: Int(rc.top) + 2, x1: Int(rc.right) - 2, y1: Int(rc.bottom) - 2))
            }
            _ = ShowWindow(item.hwnd, 5 /* SW_SHOW */)
            notes.append("DIAG \(label): covering \(covering); item alone \(alone):1; view with the item hidden \(without):1")
            if ratio < 3 { problems.append("the \(label) arrow is \(String(format: "%.2f", ratio)):1 on the real window (picture pixels in its box: \(view.pictureInk(inView)))") }
        }
        liveArrow(DexBodyPart.nextAction, "next (page 1)")
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
        dump(h, "pager-middle")   // page 3 of 8: both arrows enabled
        var guardCount = 0
        while footer() != "8 / 8", guardCount < 10 { press(items(view, DexBodyPart.nextAction).first); await wait(0.15); guardCount += 1 }
        if footer() != "8 / 8" { problems.append("last page: \(footer())") }
        dump(h, "pager-last")     // page 8 of 8: the next arrow is the disabled one
        liveArrow(DexBodyPart.prevAction, "previous (page 8)")
        press(items(view, DexBodyPart.prevAction).first)
        await wait(0.2)
        if footer() != "7 / 8" { problems.append("previous: \(footer())") }
        for _ in 0..<5 { press(items(view, DexBodyPart.prevAction).first); await wait(0.1) }
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
        // the detail page's button: a click on the cell opens it, its button follows the current Pokémon again
        press(items(view, DexBodyPart.cellAction).dropFirst(2).first)
        await wait(0.5)
        press(items(page.detailView, DexDetailPart.repAction).first)
        await wait(0.3)
        if store.representativeSpeciesID != nil { problems.append("detail button: representative \(String(describing: store.representativeSpeciesID))") }
        page.closeDetail()
        await wait(0.3)
        // the footer button: select a cell with the keyboard-free path (the model), then the footer's button sets it
        page.select("4")
        await wait(0.2)
        press(items(page.dexView, DexBodyPart.repAction).first)
        await wait(0.3)
        if store.representativeSpeciesID != 4 { problems.append("footer button: representative \(String(describing: store.representativeSpeciesID))") }
        notes.append("context menu sets species 3; the detail page's button gives it back; the footer button sets species 4")
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


    // MARK: collection.detail (D7)

    private static func detailCheck(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        for language in [AppLanguage.en, .ko] {
            guard let (h, page) = await harness(20, language: language) else { problems.append("no page \(language)"); continue }
            defer { h.destroy() }
            page.nameProvider = CollectionFixtureNames()
            let drawn0 = WinKit.drawnOnce
            let began = Date()
            page.openEntry("7")   // species 7: shiny only (every 7th), one individual
            _ = await WindowsSelftest.waitUntil(timeout: 4) {
                if case .details? = page.detailPart.map({ $0.model.content }) { return page.detailPart?.model.identity.types.first?.text.contains("…") == false }
                return false
            }
            let opened = Date().timeIntervalSince(began)
            guard let view = page.detailView, let part = page.detailPart else { problems.append("\(language): no detail view"); continue }
            let swaps = WinKit.drawnOnce - drawn0
            if !page.isShowingDetail || page.dexRow?.isVisible == true || page.toolbarRow?.isVisible == true { problems.append("\(language): rows: detail \(page.isShowingDetail)") }
            if swaps < 1 { problems.append("\(language): the swap was not drawn once through WinKit.drawingOnce (\(swaps))") }
            let model = part.model
            guard case .details(let individual, _, _, let moves) = model.content else { problems.append("\(language): no details: \(model.content)"); continue }
            if model.identity.speciesID != 7 || individual == nil || moves.moves.count != 80 { problems.append("\(language): identity \(model.identity.speciesID), moves \(moves.moves.count)") }
            if model.identity.types.first?.text.contains("…") != false { problems.append("\(language): type names not loaded: \(model.identity.types.map(\.text))") }
            if view.spriteSlots.first(where: { $0.frame.width == 104 })?.animated != true { problems.append("\(language): no animated 104 pt sprite") }
            let windows = descendants(h.window.hwnd)
            let slots = view.spriteSlots.count
            if windows > 80 || slots > 12 { problems.append("\(language): \(windows) child windows, \(slots) sprite slots") }
            // the top of the page as it opens (identity, stats): captured with its names loaded
            dump(h, "detail-top-\(language.rawValue)")
            // the representative star / arrow: its glyph ink against its own box (K4 glyph contrast; it was near-white on white in dark mode)
            func starContrast(_ state: String) {
                guard let item = items(view, DexDetailPart.repAction).first, let shot = capture(h.window.hwnd) else {
                    problems.append("\(language): no capture of the detail button (\(state))"); return
                }
                let rc = WinKit.rect(item.hwnd, in: h.window.hwnd)
                let ratio = glyphRatio(shot, fillAt: (Int(rc.left) + 3, Int(rc.top + rc.bottom) / 2), x0: Int(rc.left) + 3, y0: Int(rc.top) + 3, x1: Int(rc.right) - 3, y1: Int(rc.bottom) - 3)
                notes.append("\(language): detail \(state) glyph \(String(format: "%.2f", ratio)):1")
                if ratio < 3 { problems.append("\(language): the detail button's glyph (\(state)) is \(String(format: "%.2f", ratio)):1 against its box") }
            }
            starContrast("not representative")
            // the card under "Individual / Actual stats / Known moves" has its text and bars on it (not a blank tile)
            if let percent = ink(of: view.hwnd, in: h.window.hwnd, fromY: 35, toY: 70) {
                notes.append("\(language): ink in the detail card \(Double(Int(percent * 10)) / 10) %")
                if percent < 2 { problems.append("\(language): the detail card is blank (ink \(percent) % of a band inside it)") }
            } else { problems.append("\(language): no capture for the detail card's ink") }
            // one scroller, as the Mac's: the page's own thumb (drawn, it scrolls its rows under the pinned Back line); the native bar is not there
            if let area = h.window.scroll {
                if area.barVisible || area.contentHeight > area.viewportHeight + 2 {
                    problems.append("\(language): a second scroller on the detail page: overlay thumb shown=\(area.barVisible), content \(area.contentHeight) px in \(area.viewportHeight)")
                }
                if part.maxScroll <= 0 { problems.append("\(language): the detail page's own scroller has nothing to scroll (\(part.maxScroll))") }
                notes.append("\(language): scrollers on the detail page: overlay thumb \(area.barVisible ? "shown" : "hidden") (content \(area.contentHeight)/\(area.viewportHeight) px), own thumb for \(Int(part.maxScroll)) pt")
            }
            // the wheel scrolls it and names are asked for what comes into view only
            _ = SendMessageW(view.hwnd, 0x020A, WPARAM(UInt(bitPattern: Int(-120)) << 16), 0)
            if !(await WindowsSelftest.waitUntil(timeout: 3) { part.scrollY > 0 }) { problems.append("\(language): the wheel did not scroll") }
            _ = part.scroll(by: .greatestFiniteMagnitude)
            // the names of the rows in view arrive (waited for, not slept for): the capture and the count read them
            let shown = PokemonNameDisplayStore.shared
            _ = await WindowsSelftest.waitUntil(timeout: 5) {
                !part.visibleMoveKeys().isEmpty && part.visibleMoveKeys().allSatisfy { shown.names[PokemonNameResource(kind: .move, name: $0)] != nil }
            }
            _ = await WindowsSelftest.waitUntil(timeout: 1) { part.model.content != model.content }   // the model with those names is drawn
            await wait(0.3)
            let seen = part.visibleMoveKeys()
            let named = PokemonNameDisplayStore.shared.names.keys.filter { $0.kind == .move }.count
            if seen.count >= 80 || !seen.contains("move-79") { problems.append("\(language): visible moves \(seen.count)") }
            if named >= 80 + 2 { problems.append("\(language): \(named) move names loaded: all of them, not what is in view") }
            dump(h, "detail-\(language.rawValue)")
            _ = part.scroll(by: -.greatestFiniteMagnitude)
            // the representative button: its item exists once the page is drawn at the top again
            _ = await WindowsSelftest.waitUntil(timeout: 3) { !items(view, DexDetailPart.repAction).isEmpty }
            press(items(view, DexDetailPart.repAction).first)
            _ = await WindowsSelftest.waitUntil(timeout: 3) { h.stores.companion.representativeSpeciesID == 7 }
            if h.stores.companion.representativeSpeciesID != 7 { problems.append("\(language): the button did not set the representative") }
            await wait(0.4)
            starContrast("representative")
            // Back returns to the grid on that species' page
            press(items(view, DexDetailPart.backAction).first)
            await wait(0.3)
            if page.isShowingDetail || h.stores.state.dexDetailCollectionID != nil || page.dexRow?.isVisible != true { problems.append("\(language): Back") }
            notes.append("\(language): opened in \(Int(opened * 1000)) ms (details and names loaded), swap drawn once x\(swaps), \(windows) child windows, \(slots) sprites, \(seen.count) of 80 moves in view after scrolling, \(named) move names loaded")
        }
        // The catch log: its own drawn thumb is the page's scroller; no native bar beside it
        if let (h, page) = await harness(120, language: .en, log: true) {
            defer { h.destroy() }
            if let area = h.window.scroll, let log = page.logPart {
                if area.barVisible || area.contentHeight > area.viewportHeight + 2 {
                    problems.append("catch log: a second scroller: overlay thumb shown=\(area.barVisible), content \(area.contentHeight) px in \(area.viewportHeight)")
                }
                if log.maxScroll <= 0 { problems.append("catch log: its own scroller has nothing to scroll (\(log.maxScroll))") }
                dump(h, "log-scroller-en")
                notes.append("catch log: overlay thumb \(area.barVisible ? "shown" : "hidden"), own thumb for \(Int(log.maxScroll)) pt")
            } else { problems.append("catch log: no scroll area or log part") }
        }
        // Back from a species of a later page lands on that page
        if let (h, page) = await harness(40, language: .en) {
            defer { h.destroy() }
            page.nameProvider = CollectionFixtureNames()
            page.openEntry("40")
            await wait(0.5)
            page.closeDetail()
            await wait(0.3)
            if page.dexPart?.model.footer.pageText != "3 / 3" { problems.append("Back from species 40: \(page.dexPart?.model.footer.pageText ?? "-")") }
            else { notes.append("Back from species 40 lands on page 3 / 3") }
        }
        r.add("collection.detail", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
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
