import XCTest
@testable import PokeTokenBar

// MARK: - Fixture stores (sample data only; nothing reads this machine's logs, Keychain or network)

struct PopoverFixtureUsage: UsageProvider {
    let id: String
    let displayName: String
    let reportsCost: Bool
    var today: DailyUsage?
    var week: PeriodUsage?
    var month: PeriodUsage?

    func fetchDaily() async throws -> DailyUsage? { today }
    func fetchEnrichment() async -> ProviderEnrichment {
        ProviderEnrichment(activeBlock: nil, blocksOK: true, weekTotal: week, monthTotal: month, periodsOK: true)
    }
}

struct PopoverFixtureClaudeLimits: ClaudeLimitsProviding {
    var result: Result<LimitStatus, LimitsError>
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus { try result.get() }
}

struct PopoverFixtureCodexLimits: CodexLimitsProviding {
    var status: CodexRateLimitStatus?
    func fetch() async throws -> CodexRateLimitStatus? { status }
}

private struct NoAntigravityLimits: AntigravityLimitsProviding {
    var hasTokenFile: Bool { false }
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw LimitsError.keychainAccessDisabled }
}
private struct NoCursorLimits: CursorLimitsProviding { func fetch() async throws -> CursorRateLimitStatus? { nil } }
private struct NoOpenCodeGoLimits: OpenCodeGoLimitsProviding { func fetch() async throws -> OpenCodeGoRateLimitStatus? { nil } }
private struct NoGrokLimits: GrokLimitsProviding { func fetch() async throws -> GrokCreditStatus? { nil } }
private struct FixtureStatuses: ProviderStatusProviding {
    var statuses: [String: ProviderStatus]
    func fetch() async -> [String: ProviderStatus] { statuses }
}
private struct NoSessionKeys: SessionKeyManaging {
    func credential() -> SessionKeyCredential? { nil }
    func organizations(sessionKey: String) async throws -> [SessionKeyOrganization] { [] }
    func save(key: String, organizationID: String?) throws {}
    func clear() {}
}

/// Stores for the Home model tests, built from sample providers and limits and refreshed once.
@MainActor
enum PopoverFixtures {
    struct Fixture {
        let store: UsageStore
        let companion: CompanionStore
        let team: TeamSettings
        let state: PopoverState
        let directory: URL
    }

    static func day(_ tokens: Int, cost: Double = 0, models: [String: Int]? = nil) -> DailyUsage {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: tokens / 2, outputTokens: tokens / 4,
                   cacheCreationTokens: tokens / 8, cacheReadTokens: tokens - tokens / 2 - tokens / 4 - tokens / 8,
                   totalTokens: tokens, totalCost: cost, models: models, costCoverage: cost > 0 ? .source : .empty)
    }

    static func limitStatus(fiveHour: Double?, resetIn: TimeInterval? = nil, sevenDay: Double? = nil,
                            email: String? = nil, plan: String? = nil) -> LimitStatus {
        var parts: [String] = []
        if let fiveHour {
            let reset = resetIn.map { "\"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)))\"" } ?? "null"
            parts.append("\"five_hour\":{\"utilization\":\(fiveHour),\"resets_at\":\(reset)}")
        }
        if let sevenDay { parts.append("\"seven_day\":{\"utilization\":\(sevenDay)}") }
        var status = try! JSONDecoder().decode(LimitStatus.self, from: Data("{\(parts.joined(separator: ","))}".utf8))
        status.accountEmail = email
        status.planDisplayName = plan
        return status
    }

    static func make(suite: String, providers: [any UsageProvider],
                     claude: Result<LimitStatus, LimitsError> = .failure(.keychainAccessDisabled),
                     additionalRoots: [URL] = [],
                     additional: Result<LimitStatus, LimitsError> = .failure(.httpStatus(401)),
                     codex: CodexRateLimitStatus? = nil, statuses: [String: ProviderStatus] = [:]) async throws -> Fixture {
        let defaults = TestDefaults.make(suite: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = UsageStore(
            providers: providers,
            claudeLimitsProvider: PopoverFixtureClaudeLimits(result: claude),
            additionalClaudeLimitsProvider: { _ in PopoverFixtureClaudeLimits(result: additional) },
            discoverClaudeConfigDirs: { additionalRoots },
            readDefaultIdentity: { nil },
            readLastPrompt: { _ in nil },
            claudeUsageEntries: { _ in [] },
            readPromptHistory: { _ in [:] },
            codexLimitsProvider: PopoverFixtureCodexLimits(status: codex),
            antigravityLimitsProvider: NoAntigravityLimits(),
            cursorLimitsProvider: NoCursorLimits(),
            openCodeGoLimitsProvider: NoOpenCodeGoLimits(),
            grokLimitsProvider: NoGrokLimits(),
            statusProvider: FixtureStatuses(statuses: statuses),
            sessionKeys: NoSessionKeys(),
            accountSessionKeys: { _ in NoSessionKeys() },
            autoRefresh: false, defaults: defaults,
            displaysAsleep: { false })
        await store.refresh(scheduleEmptyRetry: false)
        let companion = CompanionStore(fileURL: directory.appendingPathComponent("companion.json"), defaults: defaults)
        return Fixture(store: store, companion: companion, team: TeamSettings(defaults: defaults), state: PopoverState(),
                       directory: directory)
    }

    /// Claude Code (cost, three models, limits), Codex (incident, one bucket) and Gemini (no cost).
    static func threeProviders(suite: String) async throws -> Fixture {
        try await make(suite: suite, providers: [
            PopoverFixtureUsage(id: "claude_code", displayName: "Claude Code", reportsCost: true,
                                today: day(1_234_567, cost: 12.5, models: ["anthropic/claude-opus-4": 900_000,
                                                                          "claude-sonnet-4": 300_000, "haiku": 34_567]),
                                week: PeriodUsage(period: "w", totalTokens: 9_000_000, totalCost: 80),
                                month: PeriodUsage(period: "m", totalTokens: 30_000_000, totalCost: 250)),
            PopoverFixtureUsage(id: "codex", displayName: "Codex", reportsCost: true, today: day(56_000, cost: 1.25),
                                week: PeriodUsage(period: "w", totalTokens: 400_000, totalCost: 4),
                                month: PeriodUsage(period: "m", totalTokens: 900_000, totalCost: 9)),
            PopoverFixtureUsage(id: "gemini", displayName: "Gemini", reportsCost: false, today: day(800)),
        ], claude: .success(limitStatus(fiveHour: 42, resetIn: 2 * 3600, sevenDay: 61, email: "me@example.com", plan: "Max")),
           codex: CodexRateLimitStatus(rateLimits: CodexRateLimitSnapshot(
               limitId: "codex", primary: CodexRateLimitWindow(usedPercent: 30, windowDurationMins: 300),
               secondary: CodexRateLimitWindow(usedPercent: 12, windowDurationMins: 10_080), planType: "plus")),
           statuses: ["codex": ProviderStatus(indicator: .major, description: "Codex API"),
                      "claude_code": ProviderStatus(indicator: .operational, description: "")])
    }
}

// MARK: - The Home model on fixture stores (both systems)

@MainActor
final class HomeModelTests: XCTestCase {
    private func model(_ f: PopoverFixtures.Fixture, updater: UpdateChecker? = nil, feed: TeamFeedStore? = nil,
                       facts: PopoverPlatformFacts = .mac) -> HomeModel {
        HomeModel.make(store: f.store, companion: f.companion, updater: updater, team: f.team, feed: feed, state: f.state,
                       facts: facts, now: Date())
    }

    private static let windows = PopoverPlatformFacts.windows(regionLocale: Locale(identifier: "de_DE"),
                                                              regionCalendar: Calendar(identifier: .gregorian))

    func testZeroUsageShowsZerosAndNoProviderParts() async throws {
        let f = try await PopoverFixtures.make(suite: "popover.home.zero", providers: [])
        f.companion.setLanguage(.en)
        let m = model(f)
        XCTAssertEqual(m.header, HeaderModel(caption: "Today's tokens", total: "0", grouped: nil, cost: nil,
                                             week: PeriodPair(name: "This week", tokens: "0", cost: nil),
                                             month: PeriodPair(name: "This month", tokens: "0", cost: nil)))
        XCTAssertEqual(m.providerTabs, [])
        XCTAssertNil(m.selectedProviderID)
        XCTAssertNil(m.providerRow)
        XCTAssertNil(m.statusBanner)
        XCTAssertNil(m.limits, "no provider, no section")
        XCTAssertNil(m.updateBanner)
        XCTAssertNil(m.plazaButton)
        XCTAssertEqual(m.footer.usage?.refreshHelp, "Refresh now")
        XCTAssertNotNil(m.footer.usage?.updated, "the refresh ran")
        XCTAssertNil(m.footer.usage?.error)
    }

    func testOneProviderHasARowButNoTabs() async throws {
        let f = try await PopoverFixtures.make(suite: "popover.home.one", providers: [
            PopoverFixtureUsage(id: "gemini", displayName: "Gemini", reportsCost: false, today: PopoverFixtures.day(950)),
        ])
        f.companion.setLanguage(.ko)
        let m = model(f)
        XCTAssertEqual(m.providerTabs, [])
        XCTAssertEqual(m.selectedProviderID, "gemini")
        XCTAssertEqual(m.header.total, "950")
        XCTAssertNil(m.header.grouped, "under 1,000")
        XCTAssertNil(m.header.cost, "no provider reports cost")
        let row = try XCTUnwrap(m.providerRow)
        XCTAssertEqual(row.name, "Gemini")
        XCTAssertNil(row.cost)
        XCTAssertEqual(row.input, PeriodPair(name: "입력", tokens: "475"))
        XCTAssertEqual(row.models, [])
        XCTAssertNil(m.limits, "Gemini has no official limits")
    }

    func testThreeProvidersTabsRowStatusAndRegionGrouping() async throws {
        let f = try await PopoverFixtures.threeProviders(suite: "popover.home.three")
        f.companion.setLanguage(.en)
        f.state.providerID = "claude_code"
        var m = model(f, facts: Self.windows)
        XCTAssertEqual(m.providerTabs.map(\.id), ["claude_code", "codex", "gemini"])
        XCTAssertEqual(m.providerTabs.map(\.title), ["Claude Code", "Codex", "Gemini"])
        XCTAssertEqual(m.header.total, "1.3M")
        XCTAssertEqual(m.header.grouped, "1.291.367", "the region's grouping (de_DE), not the app language's")
        XCTAssertEqual(m.header.cost, "$13.75")
        XCTAssertEqual(m.header.week, PeriodPair(name: "This week", tokens: "9.4M", cost: "$84.00"))
        let row = try XCTUnwrap(m.providerRow)
        XCTAssertEqual(row.cost, "$12.50")
        XCTAssertEqual(row.models.map(\.name), ["claude-opus-4", "claude-sonnet-4", "haiku"], "biggest first, last path part")
        XCTAssertEqual(row.models.map(\.tokens), ["900K", "300K", "34.6K"])
        XCTAssertNil(m.statusBanner, "operational is no incident")
        XCTAssertEqual(m.footer.petToggle, FooterModel.PetToggle(symbol: "eye.slash", label: L(.en).floatingPetEnableLabel),
                       "the floating pet's eye on Windows too (stage 7 Task 22), off by default")

        f.state.providerID = "codex"
        m = model(f, facts: Self.windows)
        XCTAssertEqual(m.statusBanner, StatusBannerModel(dot: .systemOrange, label: L(.en).providerStatusLabel(.major),
                                                         description: "Codex API"))
        f.state.providerID = "gone"
        XCTAssertEqual(model(f).selectedProviderID, "claude_code", "a provider that left falls back to the first")
    }

    func testAnUpdateOfferShowsTheBannerUntilSkipped() async throws {
        let f = try await PopoverFixtures.make(suite: "popover.home.update", providers: [])
        f.companion.setLanguage(.ja)
        let updater = UpdateChecker(currentVersion: "2.5.0", defaults: TestDefaults.make(suite: "popover.home.update.u"),
                                    fetchLatest: { nil }, brewLocator: { nil })
        updater.consider(latest: "v2.6.0", url: "https://github.com/likelion-campus/PokeTokenBar/releases/tag/v2.6.0")
        let l = L(.ja)
        XCTAssertEqual(model(f, updater: updater).updateBanner,
                       UpdateBannerModel(text: l.updateAvailable("2.6.0", current: "2.5.0"), isUpdating: false,
                                         updatingLabel: l.updating,
                                         skipButton: NoticeButton(label: l.skipThisVersion, action: .skipUpdate),
                                         updateButton: NoticeButton(label: l.updateButton, action: .applyUpdate)))
        f.store.updateNotificationsEnabled = false
        XCTAssertNil(model(f, updater: updater).updateBanner, "update notifications off")
        f.store.updateNotificationsEnabled = true
        HomeModel.perform(.skipUpdate, store: f.store, updater: updater, state: f.state, quit: {})
        XCTAssertNil(model(f, updater: updater).updateBanner, "skipped")
    }

    func testTheTeamReadyWithUnreadPostsShowsTheDot() async throws {
        let f = try await PopoverFixtures.make(suite: "popover.home.team", providers: [])
        XCTAssertNil(model(f).plazaButton, "no team")
        f.team.isEnabled = true
        var rng = SystemRandomNumberGenerator()
        f.team.code = TeamCode.generate(using: &rng)
        f.team.nickname = "Ash"
        XCTAssertTrue(f.team.isReady)
        let feed = TeamFeedStore(fileURL: f.directory.appendingPathComponent("team-feed.json"), myMemberID: "me")
        XCTAssertEqual(model(f, feed: feed).plazaButton?.unreadDot, false)
        XCTAssertTrue(feed.insert(TeamEvent(id: "e1", authorID: "misty", authorNickname: "Misty", kind: .hatch, speciesID: 25,
                                            fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil, form: nil,
                                            isShiny: false, nature: nil, rarity: .common, day: LocalUsageReader.todayKey(),
                                            occurredAt: Date())))
        XCTAssertGreaterThan(feed.unreadCount, 0)
        let button = try XCTUnwrap(model(f, feed: feed).plazaButton)
        XCTAssertEqual(button, PlazaButtonModel(symbol: "map", label: f.companion.l.plazaOpen, unreadDot: true, action: .openPlaza))
        var opened = 0
        f.state.onOpenPlaza = { opened += 1 }
        HomeModel.perform(button.action, store: f.store, updater: nil, state: f.state, quit: {})
        XCTAssertEqual(opened, 1)
    }

    func testTheInputCapturesTheStoresAsTheyAre() async throws {
        let f = try await PopoverFixtures.threeProviders(suite: "popover.home.input")
        f.state.providerID = "codex"
        f.state.claudeAccountID = "default"
        f.state.tab = .bag
        let input = HomeInput(store: f.store, companion: f.companion, updater: nil, team: f.team, feed: nil, state: f.state)
        XCTAssertEqual(input.snapshots.map(\.providerID), f.store.snapshots.map(\.providerID))
        XCTAssertEqual(input.todayTotalTokens, f.store.todayTotalTokens)
        XCTAssertEqual(input.todayUsageCost, f.store.todayUsageCost)
        XCTAssertEqual(input.weekUsageCost, f.store.weekUsageCost)
        XCTAssertEqual(input.monthTotalTokens, f.store.monthTotalTokens)
        for id in ["claude_code", "codex", "gemini", "gone"] as [String?] + [nil] {
            XCTAssertEqual(input.snapshot(preferring: id)?.providerID, f.store.snapshot(preferring: id)?.providerID)
        }
        for id in ["claude_code", "codex", "gemini"] {
            XCTAssertEqual(input.providerStatus(for: id), f.store.providerStatus(for: id))
        }
        XCTAssertEqual(input.limits?.fiveHour?.utilization, 42)
        XCTAssertEqual(input.limitsUpdatedAt, f.store.limitsUpdatedAt)
        XCTAssertEqual(input.claudeAccounts.map(\.id), f.store.claudeAccounts.map(\.id))
        XCTAssertEqual(input.trackedClaudeAccountID, f.store.trackedClaudeAccount?.id)
        XCTAssertEqual(input.codexLimits?.rateLimits.primary?.usedPercent, 30)
        XCTAssertEqual(input.lastUpdated, f.store.lastUpdated)
        XCTAssertEqual(input.lastErrorMessage, f.store.lastErrorMessage(f.companion.l))
        XCTAssertEqual(input.language, f.companion.language)
        XCTAssertEqual(input.tab, .bag)
        XCTAssertEqual(input.providerID, "codex")
        XCTAssertEqual(input.claudeAccountID, "default")
        XCTAssertNil(input.unreadCount, "no feed")
        XCTAssertNil(HomeModel.make(input: input, facts: .mac, now: Date()).footer.usage, "the usage controls are Home's only")
    }

    func testTheActionsDoWhatTheMacButtonsDo() async throws {
        let f = try await PopoverFixtures.make(suite: "popover.home.actions", providers: [])
        var quits = 0
        func run(_ action: HomeAction) { HomeModel.perform(action, store: f.store, updater: nil, state: f.state, quit: { quits += 1 }) }
        run(.selectProvider("codex"))
        XCTAssertEqual(f.state.providerID, "codex")
        run(.selectClaudeAccount("a1b2"))
        XCTAssertEqual(f.state.claudeAccountID, "a1b2")
        let pet = f.store.floatingPetEnabled
        run(.toggleFloatingPet)
        XCTAssertEqual(f.store.floatingPetEnabled, !pet)
        run(.showSettings)
        XCTAssertTrue(f.state.showSettings)
        XCTAssertFalse(f.state.expandAdvancedOnOpen)
        f.state.reset()
        run(.openSessionKeySettings)
        XCTAssertTrue(f.state.showSettings)
        XCTAssertTrue(f.state.expandAdvancedOnOpen)
        run(.quit)
        XCTAssertEqual(quits, 1)
        run(.skipUpdate)   // no updater: nothing to skip
        run(.applyUpdate)
    }
}
