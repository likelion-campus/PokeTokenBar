#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 13: the recap page's selftest group (`recap.*`). Every number below is SAMPLE data made here (a usage series
// from a fixture provider; nothing is read from this PC): the pages are shown in a kit window and, with `--dump-ui <dir>`, go
// to `<dir>/recap/` as PNG and a control-tree JSON ("Sample-data capture, Windows CI runner"). The sprite slots show the
// egg glyph: the fixture fetcher has no pictures.

extension WindowsSelftest {
    @MainActor static func popoverRecapChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverRecap.run(r, app)
    }
}

/// A provider whose month series is a made-up one: the ledger is filled by the store's own refresh, as in the app.
private struct RecapFixtureProvider: UsageProvider {
    let id = "claude_code"
    let displayName = "Claude Code"
    let reportsCost = false
    let series: [DailyUsage]
    func fetchDaily() async throws -> DailyUsage? { series.last }
    func fetchEnrichment() async -> ProviderEnrichment {
        var e = ProviderEnrichment()
        e.periodsOK = true
        e.monthDaily = series
        return e
    }
}

/// A recap page in a kit window over fixture stores.
@MainActor final class RecapHarness {
    let page: WinRecapPage
    private(set) var window: KitWindow!
    let stores: HomeStores
    private(set) var backs = 0

    /// `days` days of usage ending today (0: an empty ledger, no provider).
    static func series(days: Int, now: Date = Date()) -> [DailyUsage] {
        let calendar = RecapPeriod.calendar()
        let formatter = LocalUsageReader.localDayFormatter()
        let pattern = [0, 1_200_000, 340_000, 2_800_000, 0, 95_000, 560_000, 4_100_000, 780_000, 15_000, 12_345_678]
        return (0..<days).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)) ?? now
            let n = days - back
            let tokens = pattern[n % pattern.count] * (1 + n / 40 % 3)
            return DailyUsage(date: formatter.string(from: day), inputTokens: tokens / 2, outputTokens: tokens / 4, cacheCreationTokens: tokens / 8,
                              cacheReadTokens: tokens - tokens / 2 - tokens / 4 - tokens / 8, totalTokens: tokens, totalCost: 0, costCoverage: .empty)
        }
    }

    static func stores(language: AppLanguage, days: Int) async -> HomeStores {
        WindowsSelftestPopoverRecap.cleanUp()  // the fixtures share the selftest's settings suite: no ledger left from an earlier page
        guard days > 0 else { return await HomeStores.make(language: language) }
        return await HomeStores.make(language: language, providers: [RecapFixtureProvider(series: series(days: days))], refresh: true)
    }

    init?(stores: HomeStores, navigation: RecapNavigation = RecapNavigation(), dpi: UINT? = nil, textScale: Double? = nil) {
        self.stores = stores
        let made = WinRecapPage(store: stores.store, companion: stores.companion, onBack: {})
        made.navigation = navigation
        made.makeSprites = { WinSpriteAnimator(fetcher: PlazaStubSpriteFetcher(log: { _ in }), animationsEnabled: { false }) }
        page = made
        guard let w = KitWindow(heightDIP: 420, dpi: dpi, textScale: textScale, register: true, origin: POINT(x: 0, y: 0), build: { _, stack in
            made.attach(stack: stack)
        }) else { return nil }
        window = w
    }

    func destroy() {
        page.destroy()
        window.destroy()
        stores.remove()
    }
}

@MainActor enum WindowsSelftestPopoverRecap {
    static let names = ["recap.capture", "recap.navigation", "recap.card", "recap.roundTrip"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        await captureChecks(r)
        await navigationCheck(r)
        await cardCheck(r)
        await roundTripCheck(r, app)
        cleanUp()
    }

    /// The fixtures' refreshes wrote a ledger into the selftest's settings suite; later stores would read it.
    static func cleanUp() {
        let defaults = WinDefaultsSync.makeAppDefaults()
        defaults.removeObject(forKey: UsageLedger.defaultsKey)
        defaults.removeObject(forKey: UsageLedger.coverageKey)
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("recap", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    private static func print(_ hwnd: HWND) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    private static func findButton(_ root: HWND, text: String) -> HWND? {
        var child = GetWindow(root, 5 /* GW_CHILD */)
        while let c = child {
            if WinKit.className(c) == "Button", WinKit.text(of: c) == text { return c }
            if let inner = findButton(c, text: text) { return inner }
            child = GetWindow(c, 2 /* GW_HWNDNEXT */)
        }
        return nil
    }

    // MARK: recap.capture: every state, the tree checks, the texts

    private struct Variant {
        var name: String
        var language: AppLanguage = .en
        var days: Int
        var scope: RecapScope = .week
        var offset = 0
        var dpi: UINT?
        var textScale: Double?
    }

    private static var variants: [Variant] {
        [
            Variant(name: "week", days: 120),
            Variant(name: "week-previous", days: 120, offset: -1),
            Variant(name: "month", days: 120, scope: .month),
            Variant(name: "year", days: 400, scope: .year),
            Variant(name: "empty", days: 0),
            Variant(name: "empty-ko", language: .ko, days: 0),
            Variant(name: "first-week", days: 3),
            Variant(name: "week-ko", language: .ko, days: 120),
            Variant(name: "month-ja", language: .ja, days: 120, scope: .month),
            Variant(name: "year-ru", language: .ru, days: 400, scope: .year),
            Variant(name: "week-de", language: .de, days: 120),
            Variant(name: "week-text150", days: 120, textScale: 1.5),
            Variant(name: "week-150", days: 120, dpi: 144),
        ]
    }

    /// The texts a page must show, from the model it was built from.
    private static func expectedTexts(_ m: RecapPageModel) -> [String] {
        var out = [m.back, m.previous, m.current, m.next, m.card.title, "\(m.card.total) \(m.card.unit)"]
        out += m.scopeNames
        out += m.card.meters.map(\.description)
        out += m.card.readouts.map { "\($0.label) \($0.value)" }
        if let d = m.card.delta { out.append(d.text) }
        if m.card.graduates.isEmpty { out.append(m.card.noGraduates) }
        out += [m.bestDayLine, m.compareSoFar].compactMap { $0 }
        return out
    }

    private static func captureChecks(_ r: WindowsSelftest.Recorder) async {
        let dir = dumpDirectory()
        var lines: [String] = []
        var allOK = true
        for v in variants {
            let stores = await RecapHarness.stores(language: v.language, days: v.days)
            var nav = RecapNavigation()
            nav.select(v.scope)
            nav.offset = v.offset
            guard let h = RecapHarness(stores: stores, navigation: nav, dpi: v.dpi, textScale: v.textScale), let model = h.page.last else {
                lines.append("\(v.name): no window or no model")
                allOK = false
                stores.remove()
                continue
            }
            let w = h.window!
            w.fitToContent()
            w.show(activate: false)
            _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
            await wait(0.5)
            let tree = KitTree.collect(w)
            let checks = tree.check(w)
            let shown = Set(tree.nodes.filter(\.visible).map(\.text))
            let missing = expectedTexts(model).filter { !$0.isEmpty && !shown.contains($0) }
            let unnamed = zip(tree.nodes, tree.handles).filter { $0.0.tabStop && $0.0.visible && $0.0.text.isEmpty && !KitTree.containers.contains($0.0.cls) }
                .map { $0.0.cls }
            let heightDIP = Int((CGFloat(h.page.stack?.frames?.height ?? 0) / w.ctx.scale).rounded())
            var wrote = "no --dump-ui"
            var ok = checks.ok && missing.isEmpty && unnamed.isEmpty
            if let dir {
                let png = print(w.hwnd).map { WinUIDump.write($0, to: dir.appendingPathComponent("recap-\(v.name).png")) } ?? -1
                let json = tree.write(to: dir.appendingPathComponent("recap-tree-\(v.name).json"))
                wrote = "png=\(png == 0 ? "recap-\(v.name).png" : "FAILED \(png)") tree=\(json)"
                if png != 0 { ok = false }
            }
            allOK = allOK && ok
            lines.append("\(v.name) (dpi \(w.ctx.dpi), text x\(w.ctx.textScale), \(v.language)): title '\(model.card.title)', total \(model.card.total), chip \(model.card.delta?.text ?? "none"), "
                         + "content \(heightDIP) DIP, \(tree.nodes.count) windows, missing texts \(missing), unnamed Tab stops \(unnamed); \(checks.summary); \(wrote)")
            h.destroy()
        }
        r.add("recap.capture", allOK, "sample-data pages, Windows CI runner: " + lines.joined(separator: " | "))
    }

    // MARK: recap.navigation: stepping, its limits, the scope group, Back

    private static func navigationCheck(_ r: WindowsSelftest.Recorder) async {
        let stores = await RecapHarness.stores(language: .en, days: 120)
        guard let h = RecapHarness(stores: stores) else {
            r.add("recap.navigation", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.4)
        var parts: [String] = []
        func control(_ name: String) -> WinControl? { h.page.controls[name] }
        func press(_ name: String) { control(name)?.onClick?() }
        func state() -> String {
            let m = h.page.last
            return "offset \(h.page.navigation.offset) scope \(h.page.navigation.scope) prev=\(control("previous")?.isEnabled ?? false) "
                + "current=\(control("current")?.isEnabled ?? false) next=\(control("next")?.isEnabled ?? false) title '\(m?.card.title ?? "?")'"
        }
        let all = ["back", "scope", "previous", "current", "next"].allSatisfy { control($0) != nil }
        let start = state()
        let startOK = h.page.navigation == RecapNavigation() && control("previous")?.isEnabled == true && control("current")?.isEnabled == false
            && control("next")?.isEnabled == false
        parts.append("start: \(start)")
        let firstTitle = h.page.last?.card.title
        press("previous")
        let afterPrev = h.page.navigation.offset == -1 && control("next")?.isEnabled == true && control("current")?.isEnabled == true
            && h.page.last?.card.title != firstTitle
        parts.append("previous: \(state())")
        press("next")
        let backAgain = h.page.navigation.offset == 0 && h.page.last?.card.title == firstTitle && control("next")?.isEnabled == false
        parts.append("next: \(state())")
        // To the limit of the ledger: Previous goes grey exactly when the model says no earlier day is covered.
        var steps = 0
        while control("previous")?.isEnabled == true, steps < 100 {
            press("previous")
            steps += 1
        }
        let limit = h.page.last?.canGoBack == false && control("previous")?.isEnabled == false && steps >= 10 && steps < 100
        parts.append("stepped back \(steps) weeks to the limit: \(state())")
        let before = h.page.navigation.offset
        press("previous")
        let stays = h.page.navigation.offset == before
        press("current")
        let toCurrent = h.page.navigation.offset == 0 && h.page.last?.card.title == firstTitle
        // The scope group resets the offset; choosing the scope already shown changes nothing.
        press("previous")
        control("scope")?.onSelect?(1)
        let month = h.page.navigation.scope == .month && h.page.navigation.offset == 0 && h.page.last?.current == L(.en).thisMonth
        let monthTitle = h.page.last?.card.title ?? ""
        press("previous")
        control("scope")?.onSelect?(1)
        let sameScope = h.page.navigation.offset == -1
        control("scope")?.onSelect?(2)
        let year = h.page.navigation.scope == .year && h.page.navigation.offset == 0 && h.page.last?.card.meters.count == 12
        parts.append("scope: month title '\(monthTitle)', year meters \(h.page.last?.card.meters.count ?? 0)")
        // The page equals a fresh model of its navigation.
        let fresh = RecapPageModel.make(store: h.stores.store, companion: h.stores.companion, navigation: h.page.navigation)
        let same = h.page.last == fresh
        // Back and Escape.
        var backs = 0
        h.page.onBack = { backs += 1 }
        let escaped = h.page.escape()
        control("back")?.onClick?()
        let backOK = escaped && backs == 2
        // A page that is not touched renders nothing again.
        let before2 = h.page.renders
        if let m = h.page.last { h.page.apply(m) }
        let still = h.page.renders == before2
        r.add("recap.navigation", all && startOK && afterPrev && backAgain && limit && stays && toCurrent && month && sameScope && year && same && backOK && still,
              "controls present=\(all); start ok=\(startOK); previous -> -1 ok=\(afterPrev); next -> 0 ok=\(backAgain); limit reached after \(steps) steps ok=\(limit), "
              + "a press at the limit stays=\(stays); current resets=\(toCurrent); scope Month resets the offset and names '\(L(.en).thisMonth)'=\(month); the same scope again "
              + "keeps the offset=\(sameScope); Year has 12 meters=\(year); page equals a fresh model=\(same); Back and Escape both leave=\(backOK); re-applying the same model renders nothing=\(still); "
              + parts.joined(separator: "; "))
    }

    // MARK: recap.card: the drawn pixels (lit and unknown meters, the shell)

    private static func cardCheck(_ r: WindowsSelftest.Recorder) async {
        let stores = await RecapHarness.stores(language: .en, days: 120)
        guard let h = RecapHarness(stores: stores) else {
            r.add("recap.card", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.4)
        guard let view = h.page.cardView, let part = h.page.cardPart else {
            r.add("recap.card", false, "no card")
            return
        }
        let scale = h.window.ctx.scale
        let layout = part.layout(width: CGFloat(view.pixelSize.cx) / scale, text: PlatformPlaza.graphics.text)
        let model = part.model
        func pixel(_ p: CGPoint) -> [UInt8] { view.pixel(x: Int((p.x * scale).rounded()), y: Int((p.y * scale).rounded())) ?? [] }
        // premultiplied BGRA; the card's pixels are opaque inside the case
        func rgb(_ p: [UInt8]) -> (r: Int, g: Int, b: Int) { p.count == 4 ? (Int(p[2]), Int(p[1]), Int(p[0])) : (-1, -1, -1) }
        let top = model.meters.indices.max { model.meters[$0].lit < model.meters[$1].lit }
        var litOK = false, litText = "no meter"
        if let i = top {
            let block = layout.blockRects[i].last!
            let c = rgb(pixel(CGPoint(x: block.midX, y: block.midY)))
            // the day's meter is lit from the bottom: green at least 0.55 of the LCD over the ink
            litOK = model.meters[i].lit == PopoverRecapMetrics.meterBlocks && c.g > 120 && c.r < 140
            litText = "bucket \(i) lit \(model.meters[i].lit)/8, bottom block rgb(\(c.r),\(c.g),\(c.b))"
        }
        var darkOK = true, darkText = "no unknown bucket this week (today is its last day)"
        if let i = model.meters.firstIndex(where: { !$0.hasData }) {
            let c = rgb(pixel(CGPoint(x: layout.blockRects[i][0].midX, y: layout.blockRects[i][0].midY)))
            darkOK = c.g < 40 && c.r < 40
            darkText = "unknown bucket \(i) top block rgb(\(c.r),\(c.g),\(c.b))"
        }
        let shell = rgb(pixel(CGPoint(x: layout.size.width / 2, y: 4)))
        let shellOK = shell.r > 180 && shell.g < 90 && shell.b < 90   // the case is red at the top
        let inkOK: Bool = {
            let c = rgb(pixel(CGPoint(x: layout.screen.midX, y: layout.screen.minY + 4)))
            return c.r < 40 && c.g < 40 && c.b < 40
        }()
        let slots = view.spriteSlots.count == 1 + model.graduates.count
        let items = view.items.count
        let tips = view.drawing?.drawing.tooltips.count ?? 0
        let tipsOK = tips == model.meters.count
        r.add("recap.card", litOK && darkOK && shellOK && inkOK && slots && tipsOK,
              "\(litText) ok=\(litOK); \(darkText) ok=\(darkOK); shell at the top rgb(\(shell.r),\(shell.g),\(shell.b)) red=\(shellOK); LCD ink=\(inkOK); "
              + "sprite slots \(view.spriteSlots.count) (companion + \(model.graduates.count) graduates) ok=\(slots); accessibility items \(items); tooltips \(tips) = meters \(model.meters.count): \(tipsOK)")
    }

    // MARK: recap.roundTrip: Home -> the recap -> Back, in the app's real popover (CI: the popover takes the foreground)

    private static func roundTripCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("recap.roundTrip", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let popover = app.popover, let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("recap.roundTrip", false, "no popover or probe window")
            return
        }
        defer { probe.destroy() }
        popover.close(.destroyed)
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
        guard await WindowsSelftest.waitUntil(timeout: 3, { popover.isOpen }), let hwnd = popover.hwndForTesting else {
            r.add("recap.roundTrip", false, "the popover did not open")
            return
        }
        await wait(0.4)
        let dir = dumpDirectory()
        let isHome = popover.pageForTesting is WinHomePage
        let l = L(app.companion.language)
        guard let button = findButton(hwnd, text: l.recapOpen) else {
            r.add("recap.roundTrip", false, "home=\(isHome); no button named '\(l.recapOpen)'")
            popover.close(.destroyed)
            return
        }
        let tip = WinControl.control(button)?.tooltip
        WinKit.send(button, 0x00F5 /* BM_CLICK */)
        await wait(0.8)
        let onRecap = popover.pageForTesting is WinRecapPage && popover.state.showingRecap
        let height = popover.pageForTesting?.heightDIP ?? 0
        if let dir, let h2 = popover.hwndForTesting, let shot = print(h2) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("recap-live.png")) }
        let wentBack = popover.pageForTesting?.escape() ?? false
        await wait(0.8)
        let backHome = popover.pageForTesting is WinHomePage && !popover.state.showingRecap && popover.isOpen
        let details = popover.hwndForTesting.flatMap { findButton($0, text: l.recapOpen) } != nil
        // Reopening starts on Home even when the recap was up.
        popover.state.showingRecap = true
        popover.replacePage()
        await wait(0.4)
        let upAgain = popover.pageForTesting is WinRecapPage
        popover.close(.destroyed)
        _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
        _ = await WindowsSelftest.waitUntil(timeout: 3) { popover.isOpen }
        await wait(0.4)
        let reopenedHome = popover.pageForTesting is WinHomePage && !popover.state.showingRecap
        popover.close(.destroyed)
        r.add("recap.roundTrip", isHome && onRecap && wentBack && backHome && details && upAgain && reopenedHome && tip == l.recapOpen,
              "opened on Home=\(isHome); the 'Details' button (tooltip '\(tip ?? "-")') -> recap page=\(onRecap) (\(Int(height)) DIP); Escape handled=\(wentBack) -> Home again=\(backHome) "
              + "with its Details button=\(details); recap up then closed and reopened -> Home=\(reopenedHome) (recap was up again=\(upAgain)); capture recap-live.png")
    }

    // MARK: --popover-recap-idle-probe (the idle gate)

    static var idleProbe: RecapHarness?

    /// A recap page open and left alone (sample data in a kit window). CI only: it opens a window.
    static func startIdleProbe() {
        guard WindowsSelftest.onCI else {
            AppLog.write("popover recap idle probe: CI not set; nothing opened")
            return
        }
        Task { @MainActor in
            await wait(3)
            let stores = await RecapHarness.stores(language: .en, days: 120)
            guard let h = RecapHarness(stores: stores) else {
                AppLog.write("popover recap idle probe: no window")
                return
            }
            h.window.fitToContent()
            h.window.show(activate: false)
            idleProbe = h
            await wait(1)
            AppLog.write("popover recap idle probe: meters=\(h.page.last?.card.meters.count ?? 0) \(KitResources.now())")
        }
    }
}
#endif
