#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 12: the activity panel and the streak (`home.activity*`). Panels are shown in a kit window (no activation) from
// FIXTURE inputs: every number, provider and day below is sample data made here; nothing is read from this PC. With
// `--dump-ui <dir>` every state goes to `<dir>/activity/` as a PNG and a control-tree JSON ("Sample-data capture, Windows CI
// runner"), and the hover card as `activity-card-*.png`.

extension WindowsSelftest {
    @MainActor static func popoverActivityChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverActivity.run(r, app)
    }
}

// --- stage 7 Task 12: fixtures (begin) ---
private struct ActivityFixtureProvider: UsageProvider {
    let id: String
    let displayName: String
    let reportsCost: Bool
    let days: [DailyUsage]
    func fetchDaily() async throws -> DailyUsage? { days.last }
    func fetchEnrichment() async -> ProviderEnrichment {
        ProviderEnrichment(activeBlock: nil, blocksOK: true, weekTotal: PeriodUsage(period: "w", totalTokens: 9_000_000, totalCost: 80),
                           monthTotal: PeriodUsage(period: "m", totalTokens: 30_000_000, totalCost: 250), monthDaily: days, periodsOK: true)
    }
}

enum ActivityFixtures {
    enum Kind { case one, three, quiet, heat, empty }

    static func facts(firstWeekday: Int) -> PopoverPlatformFacts {
        let locale = Locale(identifier: firstWeekday == 1 ? "en_US" : "ko_KR")
        return .windows(regionLocale: locale, regionCalendar: RegionFormat.calendar(timeZone: .current, firstWeekday: firstWeekday, locale: locale))
    }

    static func usage(_ date: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: date, inputTokens: tokens / 2, outputTokens: tokens - tokens / 2, cacheCreationTokens: 0, cacheReadTokens: 0,
                   totalTokens: tokens, totalCost: Double(tokens) / 2_000_000)
    }

    /// Day keys from `back` days ago to today, with a weekday habit (quiet weekends), a gap and a spike.
    static func days(back: Int, now: Date, scale: Int = 1) -> [DailyUsage] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let f = LocalUsageReader.localDayFormatter()
        return (0...back).reversed().compactMap { offset -> DailyUsage? in
            guard let d = cal.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let weekend = cal.isDateInWeekend(d)
            var tokens = (weekend ? 40_000 : 600_000) * scale + (offset * 7_919) % 90_000
            if offset % 11 == 5 { tokens = 0 }
            if offset == 6 { tokens = 9_500_000 * scale }
            return usage(f.string(from: d), tokens)
        }
    }

    static func thisMonth(_ all: [DailyUsage], now: Date) -> [DailyUsage] {
        let prefix = String(LocalUsageReader.localDayFormatter().string(from: now).prefix(7))
        return all.filter { $0.date.hasPrefix(prefix) }
    }

    static func input(_ kind: Kind, language: AppLanguage = .en, firstWeekday: Int = 2, now: Date = Date(), streak: UsageStreak = UsageStreak(days: 5, includesToday: true)) -> ActivityInput {
        var i = ActivityInput()
        i.language = language
        i.facts = facts(firstWeekday: firstWeekday)
        i.today = LocalUsageReader.localDayFormatter().string(from: now)
        i.window = .month
        i.showsCost = true
        i.providerOrder = ["claude_code", "codex", "cursor"]
        i.streak = streak
        let year = days(back: 120, now: now)
        let month = thisMonth(year, now: now)
        switch kind {
        case .empty:
            i.streak = .none
        case .one:
            i.series = month
            i.providers = [DailyTrendStack.ProviderSeries(id: "claude_code", name: "Claude Code", days: month, reportsCost: true)]
        case .three:
            i.series = month
            i.providers = [
                DailyTrendStack.ProviderSeries(id: "claude_code", name: "Claude Code", days: month.map { usage($0.date, $0.totalTokens * 5 / 10) }, reportsCost: true),
                DailyTrendStack.ProviderSeries(id: "codex", name: "Codex", days: month.map { usage($0.date, $0.totalTokens * 3 / 10) }, reportsCost: true),
                DailyTrendStack.ProviderSeries(id: "cursor", name: "Cursor", days: month.map { usage($0.date, $0.totalTokens * 2 / 10) }, reportsCost: false),
            ]
        case .quiet:
            let today = [usage(i.today, 12_345)]
            i.series = [usage(String(i.today.prefix(8)) + "01", 0)] + today
            i.streak = UsageStreak(days: 3, includesToday: false)
        case .heat:
            i.series = month
            i.heatmapSeries = month
            var ledger = UsageLedger()
            ledger.merge(year.filter { !month.map(\.date).contains($0.date) })
            i.history = ledger
            i.visualization = .recentHeatmap
        }
        if kind != .heat { i.heatmapSeries = i.series }
        return i
    }
}
// --- stage 7 Task 12: fixtures (end) ---

/// A panel in a kit window, fed a fixed model (or the stores it is given).
@MainActor final class ActivityHarness {
    final class Box { var section: WinActivitySection? }
    private let box = Box()
    private(set) var window: KitWindow!
    var section: WinActivitySection { box.section! }
    var cycles = 0
    var chosen: [DailyTrendWindow] = []

    init?(input: ActivityInput?, store: UsageStore? = nil, companion: CompanionStore? = nil, dpi: UINT? = nil, facts: PopoverPlatformFacts = .mac,
          customize: ((WinActivitySection) -> Void)? = nil) {
        let box = self.box
        let made = KitWindow(heightDIP: 200, dpi: dpi, register: true, origin: POINT(x: 600, y: 100), build: { _, stack in
            let card = stack.addSection(nil, card: false)
            let s = WinActivitySection(stack: stack, section: card, store: store, companion: companion, facts: input?.facts ?? facts)
            if let input { s.modelOverride = { _ in ActivityPanelModel.make(input) } }
            customize?(s)
            box.section = s
            s.observe()
        })
        guard let made, box.section != nil else { return nil }
        window = made
        window.fitToContent()
        window.show(activate: false)
        _ = RedrawWindow(window.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
    }

    func destroy() {
        box.section?.destroy()
        window.destroy()
    }
}

@MainActor enum WindowsSelftestPopoverActivity {
    static let names = ["home.activityCapture", "home.activityHover", "home.activityKeyboard", "home.activityCycle", "home.heatmapWeekStart",
                        "home.activityStreakLine", "home.activityOpenClose"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        clearSettings()  // earlier groups' fixtures must not leave a streak or a heatmap behind for the Home captures
        let start = KitResources.now()
        let liveWindows = WinSinkWindow.liveCount
        await captureCheck(r)
        await hoverCheck(r)
        await keyboardCheck(r)
        await cycleCheck(r)
        await weekStartCheck(r)
        clearSettings()  // the cycle check's month of fixture days is in the ledger: the streak below must be this check's own
        await streakLineCheck(r)
        clearSettings()
        await openCloseCheck(r, windowsBefore: liveWindows, start: start)
    }

    /// A warm-up and three cycles of opening a chart, showing its hover card and closing it (bars, then the heatmap), judged by the
    /// shared rule (`PopoverResourceRule`): GDI and USER not above the warm-up on any cycle, kernel handles only when they rise on every one.
    private static func openCloseCheck(_ r: WindowsSelftest.Recorder, windowsBefore: Int, start: KitResources) async {
        var cycles: [KitResources] = []
        for _ in 0..<4 {
            cursor(over: nil)
            let input = ActivityFixtures.input(.three)
            if let h = ActivityHarness(input: input), let bars = h.section.bars, let view = h.section.panelView, let item = view.items.last,
               let target = input.series.max(by: { $0.totalTokens < $1.totalTokens })?.date, let p = point(of: target, bars) {
                let band = bars.titleRect(graphics: PlatformPlaza.graphics).maxY
                cursor(over: item.hwnd, Int((p.x * h.window.ctx.scale).rounded()), Int(((p.y - band) * h.window.ctx.scale).rounded()))
                await wait(0.3)  // the card window exists
                cursor(over: nil)
                h.destroy()
            }
            if let h = ActivityHarness(input: ActivityFixtures.input(.heat)) { await wait(0.1); h.destroy() }
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) })
        let last = cycles.last
        let windowsAfter = WinSinkWindow.liveCount
        r.add("home.activityOpenClose", verdict.ok && last?.controls == start.controls && windowsAfter <= windowsBefore,
              "before the group: \(start); \(verdict.summary); kit controls back to the start (last: \(last?.description ?? "-")); sink windows \(windowsBefore) -> \(windowsAfter)")
    }


    /// The fixture stores write the ledger, the visualization and the trend window into the selftest's settings suite (shared by the
    /// Home checks that follow): put them back to a first run.
    private static func clearSettings() {
        guard let suite = WinDefaultsSync.selftestSuiteName.flatMap({ UserDefaults(suiteName: $0) }) else { return }
        for key in ["dailyTokenLedger", "dailyTokenLedgerSince", "activityVisualization", "dailyTrendWindow"] { suite.removeObject(forKey: key) }
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("activity", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    private static func capture(_ w: KitWindow) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(w.hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    /// The real cursor over client pixel (x, y) of `item` (`nil`: away from every window of ours). A synthetic WM_MOUSEMOVE would be
    /// undone at once: `TrackMouseEvent` posts WM_MOUSELEAVE for a window the cursor is not in.
    private static func cursor(over item: HWND?, _ x: Int = 0, _ y: Int = 0) {
        guard let item else { _ = SetCursorPos(2, 2); return }
        var at = POINT(x: Int32(x), y: Int32(y))
        _ = ClientToScreen(item, &at)
        _ = SetCursorPos(at.x, at.y)
    }

    private static func ticks() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private static func lparam(_ x: Int, _ y: Int) -> LPARAM { LPARAM((y << 16) | (x & 0xFFFF)) }

    /// The point (DIP) over `date` in the bars' band.
    private static func point(of date: String, _ part: TrendBarsPart) -> CGPoint? {
        let graphics = PlatformPlaza.graphics
        let height = part.size(width: PopoverWindowMetrics.contentWidth, scale: 1, text: graphics.text).height
        for y in stride(from: CGFloat(0), to: height, by: 1) {
            for x in stride(from: CGFloat(0), to: 400, by: 1) where part.date(at: CGPoint(x: x, y: y), graphics: graphics) == date { return CGPoint(x: x, y: y) }
        }
        return nil
    }

    /// The card's premultiplied picture over the window colour, as an opaque bitmap (the pop-up itself is not in a window print).
    private static func cardBitmap(_ card: WinHoverCard) -> WinUIDump.Bitmap? {
        let w = Int(card.lastSize.cx), h = Int(card.lastSize.cy)
        guard w > 0, h > 0, card.lastPixels.count >= w * h * 4 else { return nil }
        var out = card.lastPixels
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let keep = 255 - Int(out[i + 3])
            out[i] = UInt8(min(255, Int(out[i]) + 236 * keep / 255)); out[i + 1] = UInt8(min(255, Int(out[i + 1]) + 236 * keep / 255))
            out[i + 2] = UInt8(min(255, Int(out[i + 2]) + 236 * keep / 255)); out[i + 3] = 255
        }
        return WinUIDump.Bitmap(width: w, height: h, bgra: out)
    }

    private static func inked(_ card: WinHoverCard) -> Int {
        stride(from: 3, to: card.lastPixels.count, by: 4).filter { card.lastPixels[$0] > 0 }.count
    }

    // MARK: home.activityCapture: every data state, the tree, the sizes, the first paint

    private struct Variant {
        var name: String
        var kind: ActivityFixtures.Kind
        var language: AppLanguage = .en
        var firstWeekday = 2
        var dpi: UINT?
        var streak = UsageStreak(days: 5, includesToday: true)
        var hover = false
    }

    private static func captureCheck(_ r: WindowsSelftest.Recorder) async {
        let dir = dumpDirectory()
        let variants = [
            Variant(name: "bars-one", kind: .one),
            Variant(name: "bars-three", kind: .three, hover: true),
            Variant(name: "bars-quiet", kind: .quiet),
            Variant(name: "bars-three-ko", kind: .three, language: .ko, hover: true),
            Variant(name: "bars-three-150", kind: .three, dpi: 144),
            Variant(name: "heatmap-monday", kind: .heat, firstWeekday: 2),
            Variant(name: "heatmap-sunday", kind: .heat, firstWeekday: 1),
            Variant(name: "heatmap-ko", kind: .heat, language: .ko, firstWeekday: 1),
            Variant(name: "heatmap-150", kind: .heat, dpi: 144),
            Variant(name: "empty", kind: .empty),
        ]
        var lines: [String] = []
        var allOK = true
        for v in variants {
            let input = ActivityFixtures.input(v.kind, language: v.language, firstWeekday: v.firstWeekday, streak: v.streak)
            cursor(over: nil)
            let t0 = ticks()
            guard let h = ActivityHarness(input: input, dpi: v.dpi) else {
                lines.append("\(v.name): no window")
                allOK = false
                continue
            }
            let firstPaint = ticks() - t0  // the harness is built, shown and painted once when its init returns
            await wait(0.3)
            let w = h.window!
            let s = h.section
            var ok = true
            var note = ""
            if v.kind == .empty {
                let hidden = !s.section.isVisible && s.panelRow?.isVisible == false && s.streakRow?.isVisible == false
                ok = hidden
                note = "no rows shown=\(hidden)"
            } else {
                let tree = KitTree.collect(w)
                let checks = tree.check(w)
                let names = tree.nodes.filter(\.visible).map(\.text)
                let l = L(v.language)
                let title = v.kind == .heat ? l.recentHeatmap : l.title(for: .month)
                let panelNamed = names.contains { $0.contains(title) && $0.contains(l.activitySwitchHint) }
                let streakNamed = names.contains(l.streakDays(5)) || names.contains(l.streakDaysPending(3))
                let menuNamed = v.kind == .heat || names.contains { $0.contains(l.dailyTrendPeriod) }
                let view = s.panelView
                let bytes = view.map { Int($0.pixelSize.cx) * Int($0.pixelSize.cy) * 4 } ?? 0
                note = "panel named=\(panelNamed) streak named=\(streakNamed) menu item=\(menuNamed) picture \(view?.pixelSize.cx ?? 0)x\(view?.pixelSize.cy ?? 0) px = \(bytes / 1024) KiB, "
                    + "first paint \(String(format: "%.0f", firstPaint)) ms, \(tree.nodes.count) windows, \(checks.summary)"
                ok = checks.ok && panelNamed && streakNamed && menuNamed && bytes > 0
                let target = input.series.max { $0.totalTokens < $1.totalTokens }?.date ?? input.today  // the tallest bar: a floor tick is two pixels to hit
                if v.hover, let bars = s.bars, let p = point(of: target, bars), let item = s.panelView?.items.last {
                    cursor(over: item.hwnd, Int((p.x * w.ctx.scale).rounded()), Int((p.y * w.ctx.scale).rounded()) - Int((bars.titleRect(graphics: PlatformPlaza.graphics).maxY * w.ctx.scale).rounded()))
                    await wait(0.4)
                    if let card = s.card, card.isShown, inked(card) > 500 {
                        if let dir, let bmp = cardBitmap(card) { _ = WinUIDump.write(bmp, to: dir.appendingPathComponent("activity-card-\(v.name).png")) }
                        note += ", card \(card.lastSize.cx)x\(card.lastSize.cy) px inked \(inked(card))"
                    } else { ok = false; note += ", NO CARD" }
                    // the capture shows the selected day's bar
                }
                if let dir {
                    let png = capture(w).map { WinUIDump.write($0, to: dir.appendingPathComponent("activity-\(v.name).png")) } ?? -1
                    let json = tree.write(to: dir.appendingPathComponent("activity-tree-\(v.name).json"))
                    note += ", png=\(png == 0 ? "ok" : "FAILED \(png)") tree=\(json)"
                    if png != 0 { ok = false }
                }
            }
            allOK = allOK && ok
            lines.append("\(v.name) (dpi \(w.ctx.dpi), \(v.language)): \(note)")
            h.destroy()
        }
        r.add("home.activityCapture", allOK, "sample-data panels, Windows CI runner: " + lines.joined(separator: " | "))
    }

    // MARK: home.activityHover: a hover shows the card, redraws the columns only, makes no text

    private static func hoverCheck(_ r: WindowsSelftest.Recorder) async {
        cursor(over: nil)
        let input = ActivityFixtures.input(.three)
        guard let h = ActivityHarness(input: input), let bars = h.section.bars, let view = h.section.panelView, let item = view.items.last,
              let title = view.items.first else {
            r.add("home.activityHover", false, "no panel")
            return
        }
        defer { h.destroy(); cursor(over: nil) }
        await wait(0.3)
        let target = input.series.max { $0.totalTokens < $1.totalTokens }?.date ?? input.today
        guard let p = point(of: target, bars) else { r.add("home.activityHover", false, "no point over \(target)"); return }
        let scale = h.window.ctx.scale
        let band = bars.titleRect(graphics: PlatformPlaza.graphics).maxY  // the panel item starts under the caption
        let px = Int((p.x * scale).rounded()), py = Int(((p.y - band) * scale).rounded())
        let before = view.stats
        bars.drawing.resetCounts()
        let t0 = ticks()
        cursor(over: item.hwnd, px, py)
        await wait(0.4)
        let hoverMs = ticks() - t0
        let after = view.stats
        let card = h.section.card
        let selected = bars.selectedDate
        let shown = card?.isShown == true && selected == target
        let cardOK = card.map { inked($0) > 500 } ?? false
        let partial = after.partialPaints - before.partialPaints
        let made = bars.drawing.madeTexts
        let bars_made = bars.drawing.made
        let pixelsPainted = after.paintPixels - before.paintPixels
        let whole = Int(view.pixelSize.cx) * Int(view.pixelSize.cy)
        let rendersBefore = view.stats.renders
        let statsBefore = view.stats
        cursor(over: item.hwnd, px + 1, py)  // the same column again
        await wait(0.3)
        let noRepeat = view.stats.renders == rendersBefore
        // what a repeat was: where the pointer was, who was under it, what the card covered, what the view did (shown only when it repeats)
        var repeatNote = ""
        if !noRepeat {
            var pos = POINT(), cardRect = RECT(), itemRect = RECT()
            _ = GetCursorPos(&pos)
            if let c = h.section.card?.hwnd { _ = GetWindowRect(c, &cardRect) }
            _ = GetWindowRect(item.hwnd, &itemRect)
            let under = WindowFromPoint(pos).map { WinKit.className($0) } ?? "-"
            let st = view.stats
            repeatNote = " [repeat: pointer (\(pos.x),\(pos.y)) item \(itemRect.left),\(itemRect.top)-\(itemRect.right),\(itemRect.bottom) card \(cardRect.left),\(cardRect.top)-\(cardRect.right),\(cardRect.bottom) "
                + "under=\(under) selected=\(bars.selectedDate ?? "-") renders +\(st.renders - statsBefore.renders) hits +\(st.hits - statsBefore.hits) paints +\(st.paints - statsBefore.paints) "
                + "partial +\(st.partialPaints - statsBefore.partialPaints) px=\(px),\(py) point=\(p.x),\(p.y) scale=\(scale)]"
        }
        // over the caption's title (its own button): no day
        cursor(over: title.hwnd, 3, 3)
        await wait(0.3)
        let caption = bars.selectedDate == nil && h.section.card?.isShown == false
        // the pointer leaves: nothing is selected, and then nothing runs on its own
        cursor(over: item.hwnd, px, py)
        await wait(0.3)
        let again = bars.selectedDate == target
        cursor(over: nil)
        await wait(0.4)
        let gone = bars.selectedDate == nil && h.section.card?.isShown == false
        let quietStart = view.stats
        await wait(1.0)
        let quiet = view.stats == quietStart
        r.add("home.activityHover", shown && cardOK && partial >= 1 && made == 0 && bars_made <= 2 && pixelsPainted < whole / 2 && noRepeat && caption && again && gone && quiet,
              "pointer over \(target): selected=\(selected ?? "-") card shown=\(shown) inked=\(cardOK); repaints: partial +\(partial) (expected >= 1), the chart made \(made) texts (expected 0) and \(bars_made) pictures (the bars it changes, <= 2) again "
              + ", painted \(pixelsPainted) px of \(whole); the same column again re-rendered=\(!noRepeat)\(repeatNote); over the title selects nothing=\(caption); back on the column=\(again); "
              + "left: selection and card gone=\(gone); one second later nothing ran=\(quiet); the hover took \(String(format: "%.0f", hoverMs)) ms incl. the 400 ms wait")
    }

    // MARK: home.activityKeyboard: the arrow keys select a day, the accessible name follows

    private static func keyboardCheck(_ r: WindowsSelftest.Recorder) async {
        let input = ActivityFixtures.input(.three)
        guard let h = ActivityHarness(input: input), let bars = h.section.bars, let view = h.section.panelView, let item = view.items.last else {
            r.add("home.activityKeyboard", false, "no panel")
            return
        }
        defer { h.destroy() }
        await wait(0.3)
        func key(_ vk: Int32) { _ = SendMessageW(item.hwnd, UINT(WM_KEYDOWN), WPARAM(vk), 0) }
        var msg = MSG()
        msg.message = UINT(WM_KEYDOWN)
        msg.wParam = WPARAM(VK_LEFT)
        let code = withUnsafeMutablePointer(to: &msg) { Int(SendMessageW(item.hwnd, 0x0087 /* WM_GETDLGCODE */, WPARAM(VK_LEFT), LPARAM(Int(bitPattern: $0)))) }
        let arrows = code & 0x0001 != 0
        let nameBefore = WinKit.text(of: item.hwnd)
        let before = view.stats
        key(VK_LEFT)
        await wait(0.2)
        let first = bars.keyboardDate
        key(VK_LEFT)
        await wait(0.2)
        let second = bars.keyboardDate
        let nameAfter = WinKit.text(of: item.hwnd)
        let after = view.stats
        let renamed = nameAfter != nameBefore && nameAfter.contains(bars.accessibleName.split(separator: ",").first.map(String.init) ?? "?")
        let inPlace = after.itemBuilds == before.itemBuilds && after.itemRenames > before.itemRenames
        let card = h.section.card?.isShown == true
        key(VK_HOME)
        await wait(0.1)
        let home = bars.keyboardDate == input.series.first?.date || bars.keyboardDate == String(input.today.prefix(8)) + "01"
        // Escape: claimed while a day is selected, then cleared; with none selected the popover's own Escape runs
        var esc = MSG()
        esc.message = UINT(WM_KEYDOWN)
        esc.wParam = WPARAM(VK_ESCAPE)
        let claims = withUnsafeMutablePointer(to: &esc) { Int(SendMessageW(item.hwnd, 0x0087, WPARAM(VK_ESCAPE), LPARAM(Int(bitPattern: $0)))) } & 0x0004 != 0
        key(VK_ESCAPE)
        await wait(0.2)
        let cleared = bars.keyboardDate == nil && h.section.card?.isShown == false
        let leaves = withUnsafeMutablePointer(to: &esc) { Int(SendMessageW(item.hwnd, 0x0087, WPARAM(VK_ESCAPE), LPARAM(Int(bitPattern: $0)))) } & 0x0004 == 0
        r.add("home.activityKeyboard", arrows && first == input.today && second != nil && second != first && renamed && inPlace && card && home && claims && cleared && leaves,
              "the item takes the arrow keys=\(arrows); first Left selects today=\(first == input.today) (\(first ?? "-")), the second the day before (\(second ?? "-")); the accessible name changed in place "
              + "(renames +\(after.itemRenames - before.itemRenames), rebuilds +\(after.itemBuilds - before.itemBuilds))=\(renamed && inPlace): '\(nameAfter)'; card shown=\(card); Home selects the first day=\(home); "
              + "Escape claimed while selected=\(claims), cleared=\(cleared), left to the popover with nothing selected=\(leaves)")
    }

    // MARK: home.activityCycle: a click cycles and persists, the window menu chooses the trend window

    private static func cycleCheck(_ r: WindowsSelftest.Recorder) async {
        let now = Date()
        let month = ActivityFixtures.thisMonth(ActivityFixtures.days(back: 40, now: now), now: now)
        let provider = ActivityFixtureProvider(id: "claude_code", displayName: "Claude Code", reportsCost: true, days: month)
        let stores = await HomeStores.make(language: .en, providers: [provider], refresh: true)
        defer { stores.remove() }
        stores.store.activityVisualization = .monthlyBars
        stores.store.dailyTrendWindow = .month
        guard let h = ActivityHarness(input: nil, store: stores.store, companion: stores.companion, facts: PopoverPlatformFacts.current, customize: { s in
            s.menu = { items, _, _ in items.firstIndex { $0?.title == L(.en).title(for: .d7) } }
        }), let view = h.section.panelView else {
            r.add("home.activityCycle", false, "no panel")
            return
        }
        defer { h.destroy() }
        await wait(0.5)
        let startsAsBars = h.section.active == .bars && h.section.bars != nil
        func press(title: Bool) { if let item = title ? view.items.first : view.items.last { _ = SendMessageW(item.hwnd, 0x00F5 /* BM_CLICK */, 0, 0) } }
        press(title: false)
        await wait(0.5)
        let toHeatmap = stores.store.activityVisualization == .recentHeatmap && h.section.active == .heatmap
        let persisted = WinDefaultsSync.selftestSuiteName.flatMap { UserDefaults(suiteName: $0) }?.string(forKey: "activityVisualization") == "recentHeatmap"
        press(title: false)
        await wait(0.5)
        let back = stores.store.activityVisualization == .monthlyBars && h.section.active == .bars
        // the title's item opens the menu; the stand-in picks "Last 7 days"
        let menusBefore = h.section.menus
        press(title: true)
        await wait(0.5)
        let menuOpened = h.section.menus == menusBefore + 1
        let chose = stores.store.dailyTrendWindow == .d7 && h.section.bars?.model.title == L(.en).title(for: .d7)
        r.add("home.activityCycle", startsAsBars && toHeatmap && persisted && back && menuOpened && chose,
              "started on the bars=\(startsAsBars); one click -> heatmap=\(toHeatmap), stored 'recentHeatmap' in the settings=\(persisted); a second click -> bars=\(back); "
              + "the caption's title item opened the window menu=\(menuOpened) and its choice 'Last 7 days' set the store's window=\(chose) (title now '\(h.section.bars?.model.title ?? "-")')")
    }

    // MARK: home.heatmapWeekStart: the first weekday of the region starts the rows

    private static func weekStartCheck(_ r: WindowsSelftest.Recorder) async {
        var seen: [Int: (first: String, last: String, columns: [String])] = [:]
        var ok = true
        for first in [1, 2] {
            let input = ActivityFixtures.input(.heat, language: .en, firstWeekday: first)
            guard let h = ActivityHarness(input: input), let part = h.section.heat else { ok = false; continue }
            let labels = part.model.weekdayLabels
            // the grid's first column starts on that weekday: the first cell of the last (current) week is `first`
            var cal = RegionFormat.calendar(timeZone: .current, firstWeekday: first, locale: Locale(identifier: "en_US"))
            cal.timeZone = .current
            let f = LocalUsageReader.localDayFormatter()
            let startsOn = part.model.columns.last?.first.flatMap { f.date(from: $0.date) }.map { cal.component(.weekday, from: $0) }
            seen[first] = (labels.first ?? "-", labels.last ?? "-", labels)
            ok = ok && startsOn == first
            h.destroy()
        }
        let differ = seen[1]?.columns != seen[2]?.columns
        ok = ok && seen[1]?.first == "S" && seen[2]?.first == "M" && differ
        r.add("home.heatmapWeekStart", ok, "firstWeekday 1 (Sunday): rows \(seen[1]?.columns.joined() ?? "-"); firstWeekday 2 (Monday): rows \(seen[2]?.columns.joined() ?? "-"); "
              + "first row label differs=\(differ); the grid's columns start on the region's weekday; PlatformCompat.firstWeekday here = \(PlatformCompat.firstWeekday)")
    }

    // MARK: home.activityStreakLine: the streak and "Details" share the week and month line, as on the Mac

    private static func streakLineCheck(_ r: WindowsSelftest.Recorder) async {
        cursor(over: nil)
        let now = Date()
        let days = ActivityFixtures.days(back: 5, now: now).map { ActivityFixtures.usage($0.date, 250_000) }
        let provider = ActivityFixtureProvider(id: "claude_code", displayName: "Claude Code", reportsCost: true, days: days)
        var lines: [String] = []
        var ok = true
        for language in [AppLanguage.en, .ko] {
            let stores = await HomeStores.make(language: language, providers: [provider], refresh: true)
            guard let h = HomeHarness(stores: stores) else { r.add("home.activityStreakLine", false, "no window"); stores.remove(); return }
            h.window.fitToContent()
            h.window.show(activate: false)
            await wait(0.8)
            h.window.fitToContent()
            await wait(0.3)
            let panel = h.page.activityPanel
            let slot = h.page.streakSlot
            let button = h.page.recapButton
            var detail = "no slot or button"
            if let slot, let button {
                var sv = RECT(), bv = RECT()
                _ = GetWindowRect(slot.view.hwnd, &sv)
                _ = GetWindowRect(button.hwnd, &bv)
                let sameParent = GetParent(slot.view.hwnd) == GetParent(button.hwnd)
                let shown = IsWindowVisible(slot.view.hwnd) && IsWindowVisible(button.hwnd)
                let sameLine = max(sv.top, bv.top) < min(sv.bottom, bv.bottom)
                let leftOf = sv.right <= bv.left
                let ownRow = panel?.streakRow == nil
                let streakText = slot.view.items.first.map { WinKit.text(of: $0.hwnd) } ?? "-"
                let named = (2...40).contains { streakText == L(language).streakDays($0) }
                let tree = KitTree.collect(h.window)
                let checks = tree.check(h.window)
                detail = "streak and Details: one parent=\(sameParent), both shown=\(shown), same line=\(sameLine) (streak y \(sv.top)-\(sv.bottom), button y \(bv.top)-\(bv.bottom)), "
                    + "streak left of the button=\(leftOf), no row of its own=\(ownRow), streak named '\(streakText)'=\(named); \(checks.summary)"
                ok = ok && sameParent && shown && sameLine && leftOf && ownRow && named && checks.ok
                if let dir = dumpDirectory() {
                    let png = capture(h.window).map { WinUIDump.write($0, to: dir.appendingPathComponent("activity-home-streak-details-\(language == .ko ? "ko" : "en").png")) } ?? -1
                    detail += ", png=\(png == 0 ? "ok" : "FAILED \(png)")"
                    if png != 0 { ok = false }
                }
            } else { ok = false }
            lines.append("\(language): \(detail)")
            h.destroy()
        }
        r.add("home.activityStreakLine", ok, lines.joined(separator: " | "))
    }

    // MARK: --popover-activity-idle-probe bars|heatmap (the idle gate)

    static var idleProbe: ActivityHarness?

    /// A chart open and left alone: it must add no timer (the numbers are the gate's).
    static func startIdleProbe(mode: String) {
        guard WindowsSelftest.onCI else {
            AppLog.write("popover activity idle probe: CI not set; nothing opened")
            return
        }
        Task { @MainActor in
            await wait(3)
            let input = ActivityFixtures.input(mode == "heatmap" ? .heat : .three)
            guard let h = ActivityHarness(input: input) else {
                AppLog.write("popover activity idle probe: no window")
                return
            }
            idleProbe = h
            await wait(1)
            let view = h.section.panelView
            AppLog.write("popover activity idle probe: mode=\(mode) picture \(view?.pixelSize.cx ?? 0)x\(view?.pixelSize.cy ?? 0) px renders=\(view?.stats.renders ?? -1) "
                         + "paints=\(view?.stats.paints ?? -1) \(KitResources.now())")
        }
    }
}
#endif
