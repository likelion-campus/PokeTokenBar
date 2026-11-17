#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 5: the Home page's selftest group (`home.*`). Each check prints one PASS/FAIL line with what it measured. Pages
// are shown in a kit window (no activation unless the check needs the keyboard, CI only) from FIXTURE inputs: every number,
// name and date below is sample data made here, nothing is read from this PC. With `--dump-ui <dir>` every fixture page goes
// to `<dir>/home/` as a PNG and a control-tree JSON ("Sample-data capture, Windows CI runner").

extension WindowsSelftest {
    @MainActor static func popoverHomeChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverHome.run(r, app)
    }
}

// --- stage 7 Task 5: fixtures (begin) ---
private struct HomeFixtureUsage: UsageProvider {
    let id: String
    let displayName: String
    let reportsCost: Bool
    let value: HomeFixtureValue
    func fetchDaily() async throws -> DailyUsage? { HomeFixtures.day(value.tokens, cost: reportsCost ? 1.25 : 0) }
    func fetchEnrichment() async -> ProviderEnrichment {
        ProviderEnrichment(activeBlock: nil, blocksOK: true, weekTotal: PeriodUsage(period: "w", totalTokens: 9_000_000, totalCost: 80),
                           monthTotal: PeriodUsage(period: "m", totalTokens: 30_000_000, totalCost: 250), periodsOK: true)
    }
}

/// A provider's today total that a check changes between refreshes.
private final class HomeFixtureValue: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int
    init(_ tokens: Int) { current = tokens }
    var tokens: Int {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

private struct HomeFixtureClaudeLimits: ClaudeLimitsProviding {
    /// Made once: a real provider answers the same reset instants again, and a new one each refresh would be a changed row.
    static let status = HomeFixtures.limitStatus(five: 42, fiveReset: 7200, seven: 61)
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus { Self.status }
}
private struct HomeFixtureCodexLimits: CodexLimitsProviding { func fetch() async throws -> CodexRateLimitStatus? { nil } }
private struct HomeFixtureAntigravity: AntigravityLimitsProviding {
    var hasTokenFile: Bool { false }
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw LimitsError.keychainAccessDisabled }
}
private struct HomeFixtureCursor: CursorLimitsProviding { func fetch() async throws -> CursorRateLimitStatus? { nil } }
private struct HomeFixtureOpenCode: OpenCodeGoLimitsProviding { func fetch() async throws -> OpenCodeGoRateLimitStatus? { nil } }
private struct HomeFixtureGrok: GrokLimitsProviding { func fetch() async throws -> GrokCreditStatus? { nil } }
private struct HomeFixtureStatuses: ProviderStatusProviding { func fetch() async -> [String: ProviderStatus] { [:] } }
private struct HomeFixtureSessionKeys: SessionKeyManaging {
    func credential() -> SessionKeyCredential? { nil }
    func organizations(sessionKey: String) async throws -> [SessionKeyOrganization] { [] }
    func save(key: String, organizationID: String?) throws {}
    func clear() {}
}

/// A Pokémon provider that answers nothing and asks no network: the fixture companions must not start PokéAPI requests (they
/// woke worker threads in the idle window that follows these checks).
private struct HomeFixturePoke: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw LimitsError.keychainAccessDisabled }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// The stores a page reads (sample providers; nothing reads this PC's logs, credentials or network).
@MainActor struct HomeStores {
    let store: UsageStore
    let companion: CompanionStore
    let team: TeamSettings
    let state: PopoverState
    let directory: URL

    /// One defaults object for every fixture (a new synced one per store would keep its own watchers).
    private static let sharedDefaults = WinDefaultsSync.makeAppDefaults()

    // MARK: Task 19 — a companion state file and provider of the caller's (the Shop and Bag fixtures)
    static func make(language: AppLanguage, providers: [any UsageProvider] = [], refresh: Bool = false, companionJSON: String? = nil,
                     poke: (any PokeProviding)? = nil) async -> HomeStores {
        await make(language: language, providers: providers, refresh: refresh, seed: (companionJSON, poke))
    }
    // MARK: end Task 19

    private static func make(language: AppLanguage, providers: [any UsageProvider], refresh: Bool, seed: (json: String?, poke: (any PokeProviding)?)) async -> HomeStores {
        let defaults = sharedDefaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-home-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = UsageStore(
            providers: providers, claudeLimitsProvider: HomeFixtureClaudeLimits(),
            additionalClaudeLimitsProvider: { _ in HomeFixtureClaudeLimits() }, discoverClaudeConfigDirs: { [] },
            readDefaultIdentity: { nil }, readLastPrompt: { _ in nil }, claudeUsageEntries: { _ in [] }, readPromptHistory: { _ in [:] },
            codexLimitsProvider: HomeFixtureCodexLimits(), antigravityLimitsProvider: HomeFixtureAntigravity(),
            cursorLimitsProvider: HomeFixtureCursor(), openCodeGoLimitsProvider: HomeFixtureOpenCode(), grokLimitsProvider: HomeFixtureGrok(),
            statusProvider: HomeFixtureStatuses(), sessionKeys: HomeFixtureSessionKeys(), accountSessionKeys: { _ in HomeFixtureSessionKeys() },
            autoRefresh: false, defaults: defaults, displaysAsleep: { false })
        if refresh { await store.refresh(scheduleEmptyRetry: false) }
        if let json = seed.json { try? Data(json.utf8).write(to: directory.appendingPathComponent("companion.json")) }  // Task 19
        let companion = CompanionStore(provider: seed.poke ?? HomeFixturePoke(), fileURL: directory.appendingPathComponent("companion.json"), defaults: defaults)
        companion.setLanguage(language)
        return HomeStores(store: store, companion: companion, team: TeamSettings(defaults: defaults), state: PopoverState(), directory: directory)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Plain `HomeInput` values for every state of the page (what `HomeModel.make(input:facts:now:)` takes): the page shows the
/// model, so a state is made by saying what the stores would say.
enum HomeFixtures {
    static func day(_ tokens: Int, cost: Double = 0, models: [String: Int]? = nil) -> DailyUsage {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: tokens / 2, outputTokens: tokens / 4, cacheCreationTokens: tokens / 8,
                   cacheReadTokens: tokens - tokens / 2 - tokens / 4 - tokens / 8, totalTokens: tokens, totalCost: cost, models: models,
                   costCoverage: cost > 0 ? .source : .empty)
    }

    static func limitStatus(five: Double?, fiveReset: TimeInterval? = nil, seven: Double? = nil, opus: Double? = nil, email: String? = nil,
                            plan: String? = nil) -> LimitStatus {
        var parts: [String] = []
        if let five {
            let reset = fiveReset.map { "\"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)))\"" } ?? "null"
            parts.append("\"five_hour\":{\"utilization\":\(five),\"resets_at\":\(reset)}")
        }
        if let seven {
            let reset = "\"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86_400)))\""
            parts.append("\"seven_day\":{\"utilization\":\(seven),\"resets_at\":\(reset)}")
        }
        if let opus { parts.append("\"seven_day_opus\":{\"utilization\":\(opus)}") }
        var status = (try? JSONDecoder().decode(LimitStatus.self, from: Data("{\(parts.joined(separator: ","))}".utf8))) ?? (try! JSONDecoder().decode(LimitStatus.self, from: Data("{}".utf8)))
        status.accountEmail = email
        status.planDisplayName = plan
        return status
    }

    static func base(_ language: AppLanguage, now: Date) -> HomeInput {
        var i = HomeInput()
        i.language = language
        i.lastUpdated = now.addingTimeInterval(-125)
        i.currentVersion = "2.5.0"
        return i
    }

    static let models = ["anthropic/claude-opus-4": 900_000, "claude-sonnet-4": 300_000, "haiku": 34_567]

    private static func claude(_ today: Int = 1_234_567) -> ProviderSnapshot {
        ProviderSnapshot(providerID: "claude_code", displayName: "Claude Code", today: day(today, cost: 12.5, models: models), fetchedAt: Date())
    }

    private static func withTotals(_ i: inout HomeInput) {
        i.todayTotalTokens = i.snapshots.reduce(0) { $0 + $1.todayTotalTokens }
        i.showsCost = true
        i.todayUsageCost = UsageCost(amount: 13.75, coverage: .source)
        i.weekTotalTokens = 9_400_000
        i.weekUsageCost = UsageCost(amount: 84, coverage: .source)
        i.monthTotalTokens = 31_000_000
        i.monthUsageCost = UsageCost(amount: 259, coverage: .source)
    }

    /// No usage yet: what a first run shows.
    static func empty(_ language: AppLanguage, now: Date) -> HomeInput { base(language, now: now) }

    /// One provider, Claude, official limits not loaded yet (the first-run "Load official limits" row).
    static func claudeFirstRun(_ language: AppLanguage, now: Date) -> HomeInput {
        var i = base(language, now: now)
        i.snapshots = [claude(48_200)]
        withTotals(&i)
        i.claudeLimitsMissing = true
        return i
    }

    /// Claude with its limits, the forecast and the current block.
    static func claudeLimits(_ language: AppLanguage, now: Date) -> HomeInput {
        var i = base(language, now: now)
        i.snapshots = [claude()]
        withTotals(&i)
        let status = limitStatus(five: 42, fiveReset: 2 * 3600 + 300, seven: 61, opus: 18, email: "me@example.com", plan: "Max")
        i.limits = status
        i.limitsUpdatedAt = now
        i.claudeAccounts = [.defaultAccount(status, updatedAt: now)]
        i.trackedClaudeAccountID = ClaudeAccountLimits.defaultID
        let end = now.addingTimeInterval(2 * 3600 + 300)
        i.fiveHourForecast = UsageStore.FiveHourForecast(depletionDate: end, beforeReset: false)
        i.claudeCurrentBlocks = [ClaudeAccountLimits.defaultID: BlockUsage(id: "b", startTime: "", endTime: ISO8601DateFormatter().string(from: end),
                                                                          isActive: true, totalTokens: 12_345, costUSD: 0, tokensPerMinute: nil)]
        return i
    }

    /// Three providers with tabs; Claude with two accounts (tabs, the tracked dot); Codex has an incident.
    static func three(_ language: AppLanguage, now: Date, selected: String = "claude_code", team: Bool = false) -> HomeInput {
        var i = claudeLimits(language, now: now)
        i.snapshots = [claude(),
                       ProviderSnapshot(providerID: "codex", displayName: "Codex", today: day(56_000, cost: 1.25), fetchedAt: now),
                       ProviderSnapshot(providerID: "gemini", displayName: "Gemini", today: day(800), fetchedAt: now, reportsCost: false)]
        withTotals(&i)
        i.providerID = selected
        let work = limitStatus(five: 71, fiveReset: 3600, seven: 33, email: "work@example.com")
        i.claudeAccounts.append(ClaudeAccountLimits(id: "work", windowKeyPrefix: "claude.work", fallbackTitle: "~/work", status: work,
                                                    isDefault: false, isExpired: false, updatedAt: now))
        i.providerStatuses = ["codex": ProviderStatus(indicator: .major, description: "Codex API errors"),
                              "claude_code": ProviderStatus(indicator: .operational, description: "")]
        i.codexLimits = CodexRateLimitStatus(rateLimits: CodexRateLimitSnapshot(
            limitId: "codex", primary: CodexRateLimitWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: Int(now.timeIntervalSince1970) + 3600),
            secondary: CodexRateLimitWindow(usedPercent: 12, windowDurationMins: 10_080), planType: "plus", rateLimitReachedType: "primary"),
            rateLimitsByLimitId: ["codex_other": CodexRateLimitSnapshot(
                limitId: "codex_other", primary: CodexRateLimitWindow(usedPercent: 7, windowDurationMins: 300),
                individualLimit: CodexSpendControlLimit(limit: "$50", remainingPercent: 70, resetsAt: Int(now.timeIntervalSince1970) + 3600, used: "$15"))])
        i.teamReady = team
        i.unreadCount = team ? 3 : nil
        return i
    }

    /// Claude's limits are old and the last refresh was refused (rate limited); the footer says the refresh failed.
    static func stale(_ language: AppLanguage, now: Date) -> HomeInput {
        var i = claudeLimits(language, now: now)
        let old = now.addingTimeInterval(-3600)
        let status = i.limits!
        i.limitsUpdatedAt = old
        i.claudeLimitsStale = true
        i.claudeAccounts = [.defaultAccount(status, updatedAt: old)]
        i.limitTokenRefreshMessage = L(language).limitRefreshRateLimited
        i.lastErrorDescription = "HTTP 429"
        i.lastErrorMessage = L(language).limitRefreshRateLimited
        return i
    }

    /// Claude's session key and its sign-in have expired (the two orange banners), with the update offer above.
    static func notices(_ language: AppLanguage, now: Date, sessionKey: Bool) -> HomeInput {
        var i = update(language, now: now)
        i.limitsAuthExpiry = sessionKey ? .sessionKey : .oauth
        return i
    }

    /// An update is offered (and the team is ready, with unread posts, so the plaza button and its dot show).
    static func update(_ language: AppLanguage, now: Date) -> HomeInput {
        var i = three(language, now: now, team: true)
        i.updateAvailable = UpdateChecker.Available(version: "2.6.0", url: "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.6.0")
        return i
    }
}
// --- stage 7 Task 5: fixtures (end) ---

// --- stage 7 Task 5: the page in a window (begin) ---
/// A Home page in a kit window, fed a fixed model (`modelOverride`) or the stores it is given.
@MainActor final class HomeHarness {
    let page: WinHomePage
    private(set) var window: KitWindow!
    let stores: HomeStores
    private let recorder: Recorded

    final class Recorded { var actions: [HomeAction] = []; var plaza = 0 }

    init?(stores: HomeStores, input: ((AppLanguage, Date) -> HomeInput)? = nil, dpi: UINT? = nil, textScale: Double? = nil,
          recordActions: Bool = true, heightDIP: CGFloat = 600, configure: ((WinHomePage) -> Void)? = nil) {
        self.stores = stores
        let recorder = Recorded()
        self.recorder = recorder
        let facts = PopoverPlatformFacts.current
        let language = stores.companion.language
        let perform: ((HomeAction) -> Void)? = recordActions ? { recorder.actions.append($0) } : nil
        let made = WinHomePage(store: stores.store, companion: stores.companion, updater: nil, team: stores.team, feed: nil, state: stores.state,
                               facts: facts, openPlaza: { recorder.plaza += 1 }, perform: perform)
        if let input { made.modelOverride = { now in HomeModel.make(input: input(language, now), facts: facts, now: now) } }
        page = made
        configure?(made)  // Task 19: a tab's content is configured before the window builds it
        guard let w = KitWindow(heightDIP: heightDIP, dpi: dpi, textScale: textScale, register: true, origin: POINT(x: 0, y: 0), build: { kit, stack in
            // The Mac's panes: the update offer and plaza button above, the footer below, the scroller between.
            made.attach(stack: stack, area: kit.scroll, client: kit.clientRect)
            kit.onLayout = { [weak made] client in made?.layout(client: client) }
            kit.fitHeightDIP = { [weak made] in made?.fullContentHeightDIP }
        }) else { return nil }
        window = w
    }

    var recordedActions: [HomeAction] { recorder.actions }
    var plazaCount: Int { recorder.plaza }

    func destroy() {
        page.destroy()
        window.destroy()
        stores.remove()
    }
}
// --- stage 7 Task 5: the page in a window (end) ---

@MainActor enum WindowsSelftestPopoverHome {
    static let names = ["home.capture", "home.updatesOnRefresh", "home.relativeClock", "home.keyboard", "home.openClose3", "home.firstPaint", "home.settingsRoundTrip", "home.pinned"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        let start = KitResources.now()
        await captureChecks(r)
        await updatesCheck(r)
        await clockCheck(r)
        await keyboardCheck(r)
        await openCloseCheck(r, start: start)
        await firstPaintCheck(r, app)
        await settingsRoundTripCheck(r, app)
        await pinnedCheck(r)
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("home", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    // MARK: home.pinned: the update offer, the plaza button and the footer stay while the middle scrolls (the Mac's mainContent)

    /// A tab stop's rectangle in the window's client pixels.
    private static func rect(_ hwnd: HWND, in window: HWND) -> RECT { WinKit.rect(hwnd, in: window) }

    private static func pinnedCheck(_ r: WindowsSelftest.Recorder) async {
        let stores = await HomeStores.make(language: .en)
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }, heightDIP: 420), let model = h.page.last,
              let area = h.window.scroll, let banner = model.updateBanner, let usage = model.footer.usage else {
            r.add("home.pinned", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.show(activate: false)
        await wait(0.6)
        let w = h.window.hwnd
        let tree = KitTree.collect(h.window)
        func find(_ text: String) -> HWND? { zip(tree.nodes, tree.handles).first { $0.0.text == text && $0.0.cls == "Button" }?.1 }
        guard let update = find(banner.updateButton.label), let refresh = find(usage.refreshHelp), let quit = find(model.footer.quitHelp) else {
            r.add("home.pinned", false, "update / refresh / quit button missing")
            return
        }
        let view = rect(area.viewport.hwnd, in: w)
        let updateBefore = rect(update, in: w), refreshBefore = rect(refresh, in: w), quitBefore = rect(quit, in: w)
        var problems: [String] = []
        // above the scroller and below it, outside it
        if updateBefore.bottom > view.top { problems.append("the update offer is not above the scroller (\(updateBefore.bottom) > \(view.top))") }
        if refreshBefore.top < view.bottom { problems.append("the footer is not below the scroller (\(refreshBefore.top) < \(view.bottom))") }
        // the content is taller than the scroller here, so it scrolls; the panes do not move
        let scrolls = area.contentHeight > (view.bottom - view.top)
        area.scroll(to: area.contentHeight)
        await wait(0.2)
        let moved = area.offset > 0
        let updateAfter = rect(update, in: w), refreshAfter = rect(refresh, in: w), quitAfter = rect(quit, in: w)
        let still = updateAfter.top == updateBefore.top && refreshAfter.top == refreshBefore.top && quitAfter.top == quitBefore.top
        if !scrolls || !moved { problems.append("the middle did not scroll (content \(area.contentHeight), viewport \(view.bottom - view.top), offset \(area.offset))") }
        if !still { problems.append("a pinned button moved while the middle scrolled") }
        // keyboard: a control below the visible part is brought into view; the footer's button takes the focus without scrolling
        area.scroll(to: 0)
        let hidden = Array(zip(tree.nodes, tree.handles)).filter { $0.0.tabStop && IsChild(area.viewport.hwnd, $0.1) && rect($0.1, in: w).top > view.bottom }
            .max { rect($0.1, in: w).top < rect($1.1, in: w).top }
        var keyboard = "no control below the fold"
        if let hidden {
            _ = SetFocus(hidden.1)
            await wait(0.2)
            let revealed = area.offset > 0
            let offsetAfter = area.offset
            _ = SetFocus(refresh)
            await wait(0.2)
            let footerKeepsScroll = area.offset == offsetAfter
            keyboard = "focus below the fold scrolled=\(revealed), focus on the footer left the scroll alone=\(footerKeepsScroll)"
            if !revealed || !footerKeepsScroll { problems.append(keyboard) }
        } else {
            problems.append(keyboard)
        }
        // Tab order is the reading order across the three panes
        // (what the scroller clips is not on screen: only what shows takes part)
        area.scroll(to: 0)
        await wait(0.1)
        let order = tree.tabOrder.filter { !(IsChild(area.viewport.hwnd, $0) && rect($0, in: w).top >= view.bottom) }
        let rects = order.map { hwnd -> CGRect in
            let r = rect(hwnd, in: w)
            return CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.right - r.left), height: CGFloat(r.bottom - r.top))
        }
        let inOrder = PopoverStackLayout.isReadingOrder(rects)
        if !inOrder || rects.count < 6 { problems.append("Tab order across the panes is not the reading order (\(rects.count) stops)") }
        // the Mac's `.frame(height: 520)`: the window is as tall whatever the content (an empty page as tall as a full one)
        let scale = h.window.ctx.scale
        let expected = CGFloat(h.page.pinnedHeights.top + h.page.pinnedHeights.bottom + h.window.ctx.px(PopoverStackMetrics.homeScrollerHeight)) / scale
        let heightOK = abs(h.page.heightDIP - expected.rounded(.up)) < 1.5
        if !heightOK { problems.append("heightDIP \(h.page.heightDIP) != top + 520 + footer \(expected)") }
        var emptyHeight = CGFloat(0), fullHeight = CGFloat(0)
        let emptyStores = await HomeStores.make(language: .en)
        if let e = HomeHarness(stores: emptyStores, input: HomeFixtures.empty) { emptyHeight = e.page.heightDIP; e.destroy() }
        let fullStores = await HomeStores.make(language: .en)
        if let f = HomeHarness(stores: fullStores, input: { HomeFixtures.three($0, now: $1) }) { fullHeight = f.page.heightDIP; f.destroy() }
        if emptyHeight == 0 || emptyHeight != fullHeight { problems.append("window height depends on the content: empty \(emptyHeight) DIP, full \(fullHeight) DIP") }
        r.add("home.pinned", problems.isEmpty,
              "Tab order top, scroller, footer=\(inOrder); update offer y \(updateBefore.top)-\(updateBefore.bottom) above the scroller y \(view.top)-\(view.bottom), footer y \(refreshBefore.top) below it; scrolled to offset \(area.offset) of content "
              + "\(area.contentHeight): update/refresh/quit unmoved=\(still); \(keyboard); window \(h.page.heightDIP) DIP = top + 520 pt scroller + footer, empty page \(emptyHeight) = full page \(fullHeight) DIP"
              + (problems.isEmpty ? "" : "; PROBLEMS: " + problems.joined(separator: "; ")))
    }

    // MARK: home.capture: every state, the tree checks, the texts

    private struct Variant {
        var name: String
        var language: AppLanguage = .en
        var input: (AppLanguage, Date) -> HomeInput
        var dpi: UINT?
        var textScale: Double?
    }

    private static var variants: [Variant] {
        [
            Variant(name: "empty", input: HomeFixtures.empty),
            Variant(name: "empty-ko", language: .ko, input: HomeFixtures.empty),
            Variant(name: "claude-first-run", input: HomeFixtures.claudeFirstRun),
            Variant(name: "claude", input: HomeFixtures.claudeLimits),
            Variant(name: "three", input: { HomeFixtures.three($0, now: $1) }),
            Variant(name: "codex", input: { HomeFixtures.three($0, now: $1, selected: "codex") }),
            Variant(name: "stale", input: HomeFixtures.stale),
            Variant(name: "update", input: HomeFixtures.update),
            Variant(name: "notice-session-key", input: { HomeFixtures.notices($0, now: $1, sessionKey: true) }),
            Variant(name: "notice-sign-in", input: { HomeFixtures.notices($0, now: $1, sessionKey: false) }),
            Variant(name: "three-ko", language: .ko, input: { HomeFixtures.three($0, now: $1, team: true) }),
            Variant(name: "three-ja", language: .ja, input: { HomeFixtures.three($0, now: $1) }),
            Variant(name: "three-ru", language: .ru, input: { HomeFixtures.three($0, now: $1) }),
            Variant(name: "three-text150", input: { HomeFixtures.three($0, now: $1) }, textScale: 1.5),
            Variant(name: "three-150", input: { HomeFixtures.three($0, now: $1) }, dpi: 144),
        ]
    }

    /// The texts a page must show, from the model it was built from.
    private static func expectedTexts(_ m: HomeModel) -> [String] {
        var out = [m.header.total, m.header.caption]
        out += m.providerTabs.map(\.title)
        if let row = m.providerRow { out.append(row.name) }
        if let b = m.statusBanner { out.append(b.label) }
        for block in m.limits ?? [] {
            if case .row(let r, _) = block { out += [r.name, r.percentText] }
            if case .notice(let n) = block { out += [n.title, n.hint] + [n.button?.label].compactMap { $0 } }
        }
        return out
    }

    private static func captureChecks(_ r: WindowsSelftest.Recorder) async {
        let dir = dumpDirectory()
        var lines: [String] = []
        var allOK = true
        for v in variants {
            let stores = await HomeStores.make(language: v.language)
            guard let h = HomeHarness(stores: stores, input: v.input, dpi: v.dpi, textScale: v.textScale), let model = h.page.last else {
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
            let look = macLook(h, model, w)
            ok = ok && look.ok
            if !look.ok { wrote = "MAC LOOK: " + look.detail }
            if let dir {
                let png = capture(w).map { WinUIDump.write($0, to: dir.appendingPathComponent("home-\(v.name).png")) } ?? -1
                let json = tree.write(to: dir.appendingPathComponent("home-tree-\(v.name).json"))
                wrote = "png=\(png == 0 ? "home-\(v.name).png" : "FAILED \(png)") tree=\(json)"
                if png != 0 { ok = false }
            }
            allOK = allOK && ok
            lines.append("\(v.name) (dpi \(w.ctx.dpi), text x\(w.ctx.textScale), \(v.language)): client \(w.clientSize.cx)x\(w.clientSize.cy) px, content \(heightDIP) DIP, "
                         + "\(tree.nodes.count) windows, missing texts \(missing), unnamed Tab stops \(unnamed); \(checks.summary); \(wrote)")
            h.destroy()
        }
        r.add("home.capture", allOK, "sample-data pages, Windows CI runner: " + lines.joined(separator: " | "))
    }

    /// The Mac's look of the page (parity pass): three `Divider()`s where the Mac has them (under the companion header, under the
    /// totals group, and under the limits only when there are limits), the update offer and the orange notices as tinted cards
    /// (a pixel inside the card is the tint, not the page colour), the provider tabs as capsule buttons, Details as a capsule.
    private static func macLook(_ h: HomeHarness, _ model: HomeModel, _ w: KitWindow) -> (ok: Bool, detail: String) {
        guard let frames = h.page.stack?.frames else { return (false, "no frames") }
        let rules = frames.sections.compactMap { $0 }.filter { $0.caption == nil && $0.card == nil && $0.rows.isEmpty && $0.dividers.count == 1 }.count
        let wantRules = model.limits == nil ? 2 : 3
        var problems: [String] = []
        if rules != wantRules { problems.append("\(rules) rules, expected \(wantRules)") }
        let tree = KitTree.collect(w)
        if model.providerTabs.count > 1 {
            let tabs = zip(tree.nodes, tree.handles).filter { n in model.providerTabs.contains { $0.title == n.0.text } && n.0.cls == "Button" }
            if tabs.count != model.providerTabs.count || tabs.contains(where: { WinControl.control($0.1)?.isPill != true }) {
                problems.append("\(tabs.count) tab buttons of \(model.providerTabs.count)")
            }
        }
        // the update offer's buttons are the kit's pills (Skip borderless, Update prominent), in the Mac's order
        if let banner = model.updateBanner, !banner.isUpdating {
            func pill(_ text: String) -> WinControl? {
                zip(tree.nodes, tree.handles).first { $0.0.text == text && $0.0.cls == "Button" }.flatMap { WinControl.control($0.1) }
            }
            if pill(banner.skipButton.label)?.isPill != true || pill(banner.updateButton.label)?.isPill != true { problems.append("the update offer's buttons are not pills") }
        }
        // Details is the capsule with the chart glyph
        if let details = zip(tree.nodes, tree.handles).first(where: { $0.0.text == L(h.stores.companion.language).recapOpen && $0.0.cls == "Button" }),
           WinControl.control(details.1)?.pillGlyph != "chart.bar.xaxis" { problems.append("Details is not the chart capsule") }
        return (problems.isEmpty, "rules \(rules)/\(wantRules); " + (problems.isEmpty ? "ok" : problems.joined(separator: ", ")))
    }

    private static func capture(_ w: KitWindow) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(w.hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    // MARK: home.updatesOnRefresh: a store change re-renders only what changed

    private static func updatesCheck(_ r: WindowsSelftest.Recorder) async {
        let claudeValue = HomeFixtureValue(1_000_000)
        let providers: [any UsageProvider] = [
            HomeFixtureUsage(id: "claude_code", displayName: "Claude Code", reportsCost: true, value: claudeValue),
            HomeFixtureUsage(id: "codex", displayName: "Codex", reportsCost: true, value: HomeFixtureValue(56_000)),
        ]
        let stores = await HomeStores.make(language: .en, providers: providers, refresh: true)
        stores.state.providerID = "claude_code"
        guard let h = HomeHarness(stores: stores) else {
            r.add("home.updatesOnRefresh", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.6)
        let before = h.page.renders
        let observesBefore = h.page.observes
        // 1: the same model applied again renders nothing
        if let m = h.page.last { h.page.apply(m) }
        let sameModel = h.page.renders == before
        // 2: Claude's total changes and the store refreshes
        claudeValue.tokens = 1_500_000
        await stores.store.refresh(scheduleEmptyRetry: false)
        await wait(0.8)
        let after = h.page.renders
        func delta(_ name: String) -> Int { after[name, default: 0] - before[name, default: 0] }
        let moved = ["header", "provider", "footer"].allSatisfy { delta($0) == 1 }
        let still = ["banner", "plaza", "tabs", "status", "limits"].allSatisfy { delta($0) == 0 }
        let totalNow = h.page.last?.header.total ?? "?"
        // 3: a provider tab press changes the selection: the tabs, the row and the limits section are made again, the header is not
        let tabsBefore = h.page.renders
        stores.state.providerID = "codex"
        await wait(0.6)
        let afterTab = h.page.renders
        let tabMoved = afterTab["tabs", default: 0] - tabsBefore["tabs", default: 0] == 1 && afterTab["provider", default: 0] - tabsBefore["provider", default: 0] == 1
        r.add("home.updatesOnRefresh", sameModel && moved && still && tabMoved && h.page.observes > observesBefore,
              "same model applied again: renders unchanged=\(sameModel); a store refresh with a new total (\(totalNow)): header +\(delta("header")) provider +\(delta("provider")) "
              + "footer +\(delta("footer")) (each expected +1), banner +\(delta("banner")) plaza +\(delta("plaza")) tabs +\(delta("tabs")) status +\(delta("status")) "
              + "limits +\(delta("limits")) (each expected +0); selecting Codex: tabs +\(afterTab["tabs", default: 0] - tabsBefore["tabs", default: 0]) provider "
              + "+\(afterTab["provider", default: 0] - tabsBefore["provider", default: 0]) header +\(afterTab["header", default: 0] - tabsBefore["header", default: 0]); "
              + "observations \(observesBefore) -> \(h.page.observes)")
    }

    // MARK: home.relativeClock: one clock, armed only while a relative text shows, stopped on close

    private static func clockCheck(_ r: WindowsSelftest.Recorder) async {
        var parts: [String] = []
        var ok = true
        // minutes: updated 2 h ago, a reset in 2 h 5 min: armed at the earliest minute boundary of the two
        let minutes = await HomeStores.make(language: .en)
        guard let h = HomeHarness(stores: minutes, input: { lang, now in
            var i = HomeFixtures.claudeLimits(lang, now: now)
            i.lastUpdated = now.addingTimeInterval(-7200)
            return i
        }) else {
            r.add("home.relativeClock", false, "no window")
            return
        }
        h.window.fitToContent()
        h.window.show(activate: false)
        await wait(0.4)
        let now = Date()
        let dates = h.page.relative.values.joined().map(\.text.date)
        let expected = dates.map { RelativeTimeText.nextChange(for: $0, now: now, coarse: true) }.min()
        let armed = h.page.clock.armedFor
        let delta = (armed != nil && expected != nil) ? abs(armed!.timeIntervalSince(expected!)) : -1
        let minuteBoundary = armed.map { $0.timeIntervalSince(now) <= 60.5 && $0.timeIntervalSince(now) > 0 } ?? false
        let ok1 = !dates.isEmpty && h.page.clock.isArmed && delta >= 0 && delta < 0.25 && minuteBoundary
        ok = ok && ok1
        parts.append("minutes: \(dates.count) relative texts on screen, armed in \(armed.map { String(format: "%.1f", $0.timeIntervalSince(now)) } ?? "nil") s, "
                     + "earliest change differs by \(String(format: "%.3f", delta)) s, within a minute=\(minuteBoundary)")
        h.page.destroy()
        let stopped = !h.page.clock.isArmed
        ok = ok && stopped
        parts.append("after the page is destroyed armed=\(h.page.clock.isArmed)")
        h.window.destroy()
        minutes.remove()
        // nothing relative on screen: no timer
        let quiet = await HomeStores.make(language: .en)
        if let q = HomeHarness(stores: quiet, input: { lang, now in
            var i = HomeFixtures.empty(lang, now: now)
            i.lastUpdated = nil
            return i
        }) {
            await wait(0.3)
            let idle = !q.page.clock.isArmed && q.page.relative.values.joined().isEmpty
            ok = ok && idle
            parts.append("nothing relative on screen: armed=\(q.page.clock.isArmed), arms=\(q.page.clock.arms)")
            q.destroy()
        } else {
            ok = false
            parts.append("no quiet window")
        }
        // first minute: updated 10 s ago; the coarse text changes at 30 s
        let ticking = await HomeStores.make(language: .en)
        if let t = HomeHarness(stores: ticking, input: { lang, now in
            var i = HomeFixtures.empty(lang, now: now)
            i.lastUpdated = now.addingTimeInterval(-28.5)
            return i
        }) {
            t.window.fitToContent()
            t.window.show(activate: false)
            await wait(0.2)
            let first = KitTree.collect(t.window).nodes.map(\.text).first { $0.hasPrefix(L(.en).updated) } ?? "?"
            await wait(2.3)
            let second = KitTree.collect(t.window).nodes.map(\.text).first { $0.hasPrefix(L(.en).updated) } ?? "?"
            let ticks = t.page.clock.ticks
            let ok3 = ticks >= 1 && first != second && t.page.clock.isArmed
            ok = ok && ok3
            parts.append("first minute (updated 28.5 s ago, the text moves at 30 s): ticks in 2.5 s=\(ticks) (>= 1), text '\(first)' -> '\(second)'")
            t.destroy()
        } else {
            ok = false
            parts.append("no ticking window")
        }
        r.add("home.relativeClock", ok, parts.joined(separator: "; "))
    }

    // MARK: home.keyboard: Tab order, arrows in the tabs, Enter and Space on the buttons (CI: real keys)

    private static func keyboardCheck(_ r: WindowsSelftest.Recorder) async {
        guard WindowsSelftest.onCI else {
            r.add("home.keyboard", true, "skipped: CI not set (the check sends real keys to a window it activates)")
            return
        }
        let stores = await HomeStores.make(language: .en)
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }), let model = h.page.last else {
            r.add("home.keyboard", false, "no window")
            return
        }
        defer { h.destroy() }
        h.window.fitToContent()
        h.window.show(activate: true)
        await wait(0.6)
        let foreground = GetForegroundWindow() == h.window.hwnd
        let tree = KitTree.collect(h.window)
        func handle(_ text: String) -> HWND? { zip(tree.nodes, tree.handles).first { $0.0.text == text && $0.0.tabStop }?.1 }
        func focus(_ text: String) -> Bool {
            guard let hwnd = handle(text) else { return false }
            _ = SetFocus(hwnd)
            return GetFocus() == hwnd
        }
        var notes: [String] = []
        var ok = foreground
        // the provider tabs (capsule buttons, as the Mac's): Tab moves to the next one, Space presses it
        if focus("Claude Code") {
            WindowsSelftestPopover.tap(0x09)  // VK_TAB
            WindowsSelftestPopover.tap(0x20)  // VK_SPACE
            await wait(0.3)
            let pressed = h.recordedActions.contains(.selectProvider("codex"))
            ok = ok && pressed
            notes.append("Tab, Space on the Claude Code tab -> select codex=\(pressed)")
        } else { ok = false; notes.append("no Claude Code tab stop") }
        // the plaza button: Enter
        if let plaza = model.plazaButton, focus(plaza.label) {
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.3)
            let pressed = h.recordedActions.contains(.openPlaza)
            ok = ok && pressed
            notes.append("Enter on '\(plaza.label)' -> openPlaza=\(pressed)")
        } else { ok = false; notes.append("no plaza button") }
        // the update banner (the Mac's order: Skip, then Update): Space on Skip, Tab, Enter on Update
        if let banner = model.updateBanner, focus(banner.skipButton.label) {
            WindowsSelftestPopover.tap(0x20)
            await wait(0.2)
            let skipped = h.recordedActions.contains(.skipUpdate)
            ok = ok && skipped
            notes.append("Space on Skip -> skipUpdate=\(skipped)")
            WindowsSelftestPopover.tap(0x09)  // Tab: Update follows Skip
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.2)
            let pressed = h.recordedActions.contains(.applyUpdate)
            ok = ok && pressed
            notes.append("Tab then Enter -> applyUpdate=\(pressed)")
        } else { ok = false; notes.append("no update banner") }
        // the footer: Enter on Refresh, Tab + Space on Settings, Tab + Enter on Quit (recorded, never run)
        if let usage = model.footer.usage, focus(usage.refreshHelp) {
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.2)
            let refreshed = h.recordedActions.contains(.refresh)
            WindowsSelftestPopover.tap(0x09)
            await wait(0.2)
            let afterRefresh = WinKit.text(of: GetFocus())
            WindowsSelftestPopover.tap(0x20)
            await wait(0.2)
            let settings = h.recordedActions.contains(.showSettings)
            WindowsSelftestPopover.tap(0x09)
            await wait(0.2)
            let afterSettings = WinKit.text(of: GetFocus())
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.2)
            let quit = h.recordedActions.contains(.quit)
            ok = ok && refreshed && settings && quit && afterRefresh == model.footer.settingsHelp && afterSettings == model.footer.quitHelp
            notes.append("footer: Enter on Refresh -> refresh=\(refreshed); Tab -> '\(afterRefresh)', Space -> showSettings=\(settings); Tab -> '\(afterSettings)', Enter -> quit=\(quit)")
        } else { ok = false; notes.append("no footer refresh button") }
        let names = zip(tree.nodes, tree.handles).filter { $0.0.tabStop && $0.0.visible && !KitTree.containers.contains($0.0.cls) }
        let unnamed = names.filter { $0.0.text.isEmpty }.count
        ok = ok && unnamed == 0
        r.add("home.keyboard", ok, "foreground=\(foreground); \(names.count) Tab stops, \(unnamed) unnamed; " + notes.joined(separator: "; ")
              + "; in the page: \(h.recordedActions.count) actions recorded, plaza openings \(h.plazaCount)")
    }

    // MARK: home.openClose3: nothing left behind

    private static func openCloseCheck(_ r: WindowsSelftest.Recorder, start: KitResources) async {
        var cycles: [KitResources] = []
        var armedAfter = false
        for _ in 0..<4 {
            let stores = await HomeStores.make(language: .en)
            guard let h = HomeHarness(stores: stores, input: { HomeFixtures.three($0, now: $1, team: true) }) else { break }
            h.window.fitToContent()
            h.window.show(activate: false)
            await wait(0.3)
            let armed = h.page.clock.isArmed
            h.destroy()
            armedAfter = armedAfter || h.page.clock.isArmed
            _ = armed
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        guard cycles.count == 4, let last = cycles.last else {
            r.add("home.openClose3", false, "only \(cycles.count) of 4 cycles")
            return
        }
        // userSlack 1: this check opens the real popover window, whose USER count moves by one between cycles on the runner
        // (17/18/17/18; see popover.openClose3). A USER object leaked per open still fails: it passes warm-up + 1 on the second cycle.
        let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) }, userSlack: 1)
        let ok = verdict.ok && last.controls == 0 && last.dialogs == start.dialogs && last.pumpDepth == 0 && !armedAfter
        r.add("home.openClose3", ok, "before the group: \(start); \(verdict.summary); clock armed after a close=\(armedAfter); kit controls and dialog registrations back to the start (last: \(last))")
    }

    // MARK: home.firstPaint: the first frame after open is the page, not a white window

    /// Non-background pixels of a window's own picture (PrintWindow): the page's text and bars, not the empty frame and its bar.
    private static func inkPixels(_ hwnd: HWND) -> Int? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        var ink = 0
        for i in stride(from: 0, to: Int(width * height) * 4, by: 4) where Int(out[i]) + Int(out[i + 1]) + Int(out[i + 2]) < 450 { ink += 1 }
        return ink
    }

    private static func firstPaintCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("home.firstPaint", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let popover = app.popover, let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("home.firstPaint", false, "no popover or probe window")
            return
        }
        defer { probe.destroy() }
        popover.close(.destroyed)
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
        let opened = await WindowsSelftest.waitUntil(timeout: 3) { popover.isOpen }
        await wait(0.25)
        guard opened, let hwnd = popover.hwndForTesting, let early = inkPixels(hwnd) else {
            r.add("home.firstPaint", false, "opened=\(opened), no picture of the popover")
            popover.close(.destroyed)
            return
        }
        await wait(1.5)
        let late = hwnd == popover.hwndForTesting ? inkPixels(hwnd) ?? 0 : 0
        popover.close(.destroyed)
        r.add("home.firstPaint", early >= 300 && early * 10 >= late * 8,
              "a capture 0.25 s after the popover opened has \(early) text pixels, 1.75 s after \(late) (a white empty page has about 0; needs >= 300 and >= 80 % of the later one)")
    }

    // MARK: home.settingsRoundTrip: Home -> Settings (the footer's button) -> Back -> Home, in the real popover

    private static func findButton(_ root: HWND, text: String) -> HWND? {
        var child = GetWindow(root, 5 /* GW_CHILD */)
        while let c = child {
            if WinKit.className(c) == "Button", WinKit.text(of: c) == text { return c }
            if let inner = findButton(c, text: text) { return inner }
            child = GetWindow(c, 2 /* GW_HWNDNEXT */)
        }
        return nil
    }

    private static func print(_ hwnd: HWND) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    private static func settingsRoundTripCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("home.settingsRoundTrip", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let popover = app.popover, let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("home.settingsRoundTrip", false, "no popover or probe window")
            return
        }
        defer { probe.destroy() }
        popover.close(.destroyed)
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
        guard await WindowsSelftest.waitUntil(timeout: 3, { popover.isOpen }), let hwnd = popover.hwndForTesting else {
            r.add("home.settingsRoundTrip", false, "the popover did not open")
            return
        }
        await wait(0.4)
        let dir = dumpDirectory()
        let isHome = popover.pageForTesting is WinHomePage
        let l = L(app.companion.language)
        if let dir, let shot = print(hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("home-live-open.png")) }
        // Home -> Settings: the footer's button (a click message, as a mouse or Enter gives it)
        guard let button = findButton(hwnd, text: l.settings) else {
            r.add("home.settingsRoundTrip", false, "home=\(isHome); no footer button named '\(l.settings)'")
            popover.close(.destroyed)
            return
        }
        WinKit.send(button, 0x00F5 /* BM_CLICK */)
        await wait(0.6)
        let onSettings = popover.pageForTesting is WinSettingsPage && popover.state.showSettings
        let heightSettings = popover.pageForTesting?.heightDIP ?? 0
        if let dir, let shot = print(hwnd) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("home-live-settings.png")) }
        // Back (Escape on the page): Home again, with the footer there
        let wentBack = popover.pageForTesting?.escape() ?? false
        await wait(0.6)
        let backHome = popover.pageForTesting is WinHomePage && !popover.state.showSettings && popover.isOpen
        let footer = popover.hwndForTesting.flatMap { findButton($0, text: l.settings) } != nil
        let heightHome = popover.pageForTesting?.heightDIP ?? 0
        if let dir, let h2 = popover.hwndForTesting, let shot = print(h2) { _ = WinUIDump.write(shot, to: dir.appendingPathComponent("home-live-back.png")) }
        popover.close(.destroyed)
        r.add("home.settingsRoundTrip", isHome && onSettings && wentBack && backHome && footer,
              "opened on Home=\(isHome); the footer's Settings button -> Settings page=\(onSettings) (\(Int(heightSettings)) DIP); Back -> escape handled=\(wentBack), Home page again=\(backHome) "
              + "(\(Int(heightHome)) DIP) with its footer=\(footer); captures home-live-open/settings/back.png")
    }

    // MARK: --popover-home-idle-probe seconds|minutes|still (the idle gate)

    static var idleProbe: HomeHarness?

    /// A Home page open and left alone: `seconds` shows "Updated 28 seconds" (the clock ticks at 30 s, then each minute), `minutes` shows
    /// texts that change each minute, `still` has nothing relative. CI only (it opens a window).
    static func startIdleProbe(mode: String) {
        guard WindowsSelftest.onCI else {
            AppLog.write("popover home idle probe: CI not set; nothing opened")
            return
        }
        Task { @MainActor in
            await wait(3)
            let stores = await HomeStores.make(language: .en)
            let input: (AppLanguage, Date) -> HomeInput = { lang, now in
                var i = HomeFixtures.claudeLimits(lang, now: now)
                switch mode {
                case "seconds": i.lastUpdated = now.addingTimeInterval(-28.5)
                case "minutes": i.lastUpdated = now.addingTimeInterval(-7200)
                default: i.lastUpdated = nil; i.limits = nil; i.claudeAccounts = []; i.claudeLimitsMissing = false
                }
                return i
            }
            guard let h = HomeHarness(stores: stores, input: input) else {
                AppLog.write("popover home idle probe: no window")
                return
            }
            h.window.fitToContent()
            h.window.show(activate: false)
            idleProbe = h
            await wait(1)
            AppLog.write("popover home idle probe: mode=\(mode) relative texts=\(h.page.relative.values.joined().count) clock armed=\(h.page.clock.isArmed) "
                         + "\(KitResources.now())")
        }
    }
}
#endif
