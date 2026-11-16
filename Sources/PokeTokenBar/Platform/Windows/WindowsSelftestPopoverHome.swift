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

    static func make(language: AppLanguage, providers: [any UsageProvider] = [], refresh: Bool = false) async -> HomeStores {
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
        let companion = CompanionStore(provider: HomeFixturePoke(), fileURL: directory.appendingPathComponent("companion.json"), defaults: defaults)
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
          recordActions: Bool = true) {
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
        guard let w = KitWindow(heightDIP: 600, dpi: dpi, textScale: textScale, register: true, origin: POINT(x: 0, y: 0), build: { _, stack in
            made.attach(stack: stack)
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
    static let names = ["home.capture", "home.updatesOnRefresh", "home.relativeClock", "home.keyboard", "home.openClose3", "home.firstPaint"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        let start = KitResources.now()
        await captureChecks(r)
        await updatesCheck(r)
        await clockCheck(r)
        await keyboardCheck(r)
        await openCloseCheck(r, start: start)
        await firstPaintCheck(r, app)
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("home", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

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
        // the provider tabs: the arrow keys move inside the group and press the next tab
        if focus("Claude Code") {
            WindowsSelftestPopover.tap(0x27)  // VK_RIGHT
            await wait(0.3)
            let pressed = h.recordedActions.contains(.selectProvider("codex"))
            ok = ok && pressed
            notes.append("Right on the Claude Code tab -> select codex=\(pressed)")
        } else { ok = false; notes.append("no Claude Code tab stop") }
        // the plaza button: Enter
        if let plaza = model.plazaButton, focus(plaza.label) {
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.3)
            let pressed = h.recordedActions.contains(.openPlaza)
            ok = ok && pressed
            notes.append("Enter on '\(plaza.label)' -> openPlaza=\(pressed)")
        } else { ok = false; notes.append("no plaza button") }
        // the update banner: Enter on Update, then Space on Skip
        if let banner = model.updateBanner, focus(banner.updateButton.label) {
            WindowsSelftestPopover.tap(0x0D)
            await wait(0.2)
            let pressed = h.recordedActions.contains(.applyUpdate)
            ok = ok && pressed
            notes.append("Enter on Update -> applyUpdate=\(pressed)")
            WindowsSelftestPopover.tap(0x09)  // Tab: Skip follows Update
            WindowsSelftestPopover.tap(0x20)
            await wait(0.2)
            let skipped = h.recordedActions.contains(.skipUpdate)
            ok = ok && skipped
            notes.append("Tab then Space -> skipUpdate=\(skipped)")
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
        guard cycles.count == 4, let warm = cycles.first, let last = cycles.last else {
            r.add("home.openClose3", false, "only \(cycles.count) of 4 cycles")
            return
        }
        let ok = last.gdi - warm.gdi <= 5 && last.user - warm.user <= 5 && last.handles - warm.handles <= 10 && last.controls == 0
            && last.dialogs == start.dialogs && last.pumpDepth == 0 && !armedAfter
        r.add("home.openClose3", ok, "before the group: \(start); after a warm-up open/close: \(warm); after 3 more: \(cycles.dropFirst().map { "\($0)" }.joined(separator: " / ")); "
              + "clock armed after a close=\(armedAfter) (budget over the warm-up: GDI +5, USER +5, handles +10; kit controls and dialog registrations back to the start)")
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
