import XCTest
@testable import PokeTokenBar

/// The Home page's limits section as values (stage 7, D8), on both systems: the blocks the Mac's `limitsSection` shows,
/// in its order, for captured store states (`HomeInput`) and for fixture stores.
@MainActor
final class LimitsModelTests: XCTestCase {
    private let now = Date()
    private let l = L(.en)
    private static let windows = PopoverPlatformFacts.windows(regionLocale: Locale(identifier: "en_US"),
                                                              regionCalendar: Calendar(identifier: .gregorian))

    private func input(_ provider: String, _ configure: (inout HomeInput) -> Void = { _ in }) -> HomeInput {
        var i = HomeInput()
        i.language = .en
        i.snapshots = [ProviderSnapshot(providerID: provider, displayName: provider, fetchedAt: now)]
        configure(&i)
        return i
    }

    private func blocks(_ i: HomeInput, facts: PopoverPlatformFacts = .mac) -> [LimitsBlock]? {
        HomeModel.make(input: i, facts: facts, now: now).limits
    }

    private func rows(_ blocks: [LimitsBlock]?) -> [(LimitRowModel, Bool)] {
        (blocks ?? []).compactMap { if case .row(let r, let d) = $0 { return (r, d) } else { return nil } }
    }

    private func window(_ utilization: Double?, resetIn: TimeInterval?) -> LimitWindow {
        LimitWindow(utilization: utilization, resetsAt: resetIn.map { ISO8601DateFormatter().string(from: now.addingTimeInterval($0)) })
    }

    private var staleLabel: String { l.staleLimits + " · " }

    // MARK: Claude

    func testClaudeFirstRunOffersTheOneTapLoadOnBothSystems() async {
        let first = input("claude_code") { $0.claudeLimitsMissing = true }
        let help = HelpModel(tooltip: l.claudeKeychainHelpTooltip, title: l.claudeKeychainHelpTitle, body: l.claudeKeychainHelpBody,
                             button: NoticeButton(label: l.registerSessionKey, action: .openSessionKeySettings))
        let load = RefreshRowModel(status: .tapToLoad(l.limitsTapToLoad),
                                   button: NoticeButton(label: l.refresh, action: .refreshClaudeLimits), error: nil)
        XCTAssertEqual(blocks(first), [.caption(l.limitsOfficial, help: help), .refreshRow(load)])
        // Windows: the same (?) and button, explaining Claude's sign-in file instead of the Keychain (stage 7 Task 14, P15h).
        let winHelp = HelpModel(tooltip: l.winClaudeCredentialHelpTooltip, title: l.winClaudeCredentialHelpTitle, body: l.winClaudeCredentialHelpBody,
                                button: NoticeButton(label: l.registerSessionKey, action: .openSessionKeySettings))
        XCTAssertEqual(blocks(first, facts: Self.windows), [.caption(l.limitsOfficial, help: winHelp), .refreshRow(load)],
                       "Windows: the sign-in file's help; the refresh reads the credentials file")
        var keychainOff = first
        keychainOff.disableKeychainAccess = true
        XCTAssertNil(blocks(keychainOff), "the Mac with the Keychain off and nothing loaded: no section")
        XCTAssertEqual(blocks(keychainOff, facts: Self.windows), [.caption(l.limitsOfficial, help: winHelp), .refreshRow(load)],
                       "Windows has no Keychain switch: a stored value does not hide the section")
        var keyed = first
        keyed.sessionKeyConfigured = true
        XCTAssertEqual(blocks(keyed)?.first, .caption(l.limitsOfficial, help: nil), "no help with a session key")
        XCTAssertEqual(blocks(keyed, facts: Self.windows)?.first, .caption(l.limitsOfficial, help: nil), "nor on Windows")
    }

    func testClaudeStaleValuesAndTheRefreshError() async {
        let updated = now.addingTimeInterval(-20 * 60)
        let stale = input("claude_code") {
            $0.limits = PopoverFixtures.limitStatus(fiveHour: 50, resetIn: 3600)
            $0.limitsUpdatedAt = updated
            $0.claudeLimitsStale = true
            $0.limitTokenRefreshMessage = "Rate limited"
            $0.claudeAccounts = [.defaultAccount($0.limits!, updatedAt: updated)]
        }
        let b = blocks(stale)
        XCTAssertEqual(b?[1], .refreshRow(RefreshRowModel(
            status: .stale(RelativeText(prefix: staleLabel, date: updated)),
            button: NoticeButton(label: l.refresh, action: .refreshClaudeLimits), error: "Rate limited")))
        var refreshing = stale
        refreshing.isRefreshingLimitToken = true
        XCTAssertEqual(blocks(refreshing)?[1], .refreshRow(RefreshRowModel(
            status: .stale(RelativeText(prefix: staleLabel, date: updated)),
            button: NoticeButton(label: l.refresh, action: .refreshClaudeLimits, inProgress: true), error: nil)),
                       "the spinner replaces the label and the old error goes")
        XCTAssertEqual(rows(b).map(\.0.name), [l.fiveHourSession])
        XCTAssertFalse(rows(b)[0].1, "stale values are not dimmed")
    }

    func testClaudeExpiredSessionsShowTheirNotices() async {
        let limits = PopoverFixtures.limitStatus(fiveHour: 80, resetIn: 1800, sevenDay: 40)
        let expired = input("claude_code") {
            $0.limits = limits
            $0.limitsAuthExpiry = .oauth
            $0.claudeAccounts = [.defaultAccount(limits, isExpired: true)]
        }
        let b = blocks(expired)
        XCTAssertEqual(b?[1], .notice(NoticeModel(style: .banner, symbol: "exclamationmark.triangle.fill",
                                                  title: l.claudeAuthExpiredTitle, hint: l.claudeAuthExpiredHint,
                                                  button: NoticeButton(label: l.retry, action: .refreshClaudeLimits))))
        XCTAssertEqual(rows(b).map(\.1), [true, true], "values from before the expiry are dimmed")
        var keyExpired = expired
        keyExpired.limitsAuthExpiry = .sessionKey
        XCTAssertEqual(blocks(keyExpired)?[1], .notice(NoticeModel(style: .banner, symbol: "key.slash.fill",
                                                                   title: l.sessionKeyExpiredTitle, hint: l.sessionKeyExpiredNoticeHint,
                                                                   button: NoticeButton(label: l.settings, action: .openSessionKeySettings))))
    }

    func testClaudeAccountRowsForecastBlockAndScopedEntries() async throws {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20},
         "seven_day_opus":{"utilization":30},
         "limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Fable"}}}]}
        """
        var limits = try JSONDecoder().decode(LimitStatus.self, from: Data(json.utf8))
        limits.planDisplayName = "Max"
        limits.accountEmail = "me@example.com"
        let end = now.addingTimeInterval(3 * 3600)
        let block = BlockUsage(id: "b", startTime: "", endTime: ISO8601DateFormatter().string(from: end), isActive: true,
                               totalTokens: 12_345, costUSD: 0, tokensPerMinute: nil)
        let i = input("claude_code") {
            $0.limits = limits
            $0.claudeAccounts = [.defaultAccount(limits)]
            $0.trackedClaudeAccountID = ClaudeAccountLimits.defaultID
            $0.fiveHourForecast = UsageStore.FiveHourForecast(depletionDate: end, beforeReset: false)
            $0.claudeCurrentBlocks = [ClaudeAccountLimits.defaultID: block]
        }
        let b = try XCTUnwrap(blocks(i))
        XCTAssertEqual(b[1], .plan(l.plan("Max")))
        XCTAssertEqual(b[2], .accountLabel(l.limitsAccount("me@example.com")))
        XCTAssertEqual(rows(b).map(\.0.name), [l.fiveHourSession, l.weekly, l.weeklyOpus, l.claudeLimitEntry(kind: "weekly_scoped", model: "Fable")])
        XCTAssertEqual(rows(b)[0].0.idleHint, nil, "10% is running, not 'starts with your next message'")
        XCTAssertEqual(b[4], .forecast(ForecastModel(symbol: "checkmark.circle", text: l.forecastNoReach, warning: false, dimmed: false)),
                       "after the 5-hour row, for the tracked account")
        let resetLine = try XCTUnwrap(b.last)
        guard case .currentBlock(let current) = resetLine else { return XCTFail("the current block comes last") }
        XCTAssertEqual(current.label, l.claudeCurrentBlock)
        XCTAssertEqual(current.tokens, "12.3K")
        XCTAssertEqual(current.reset.prefix, l.reset + " ")
        XCTAssertEqual(current.reset.suffix, PopoverFormat.resetClockSuffix(end, now: now, language: .en, calendar: .current))
        var untracked = i
        untracked.trackedClaudeAccountID = "other"
        XCTAssertFalse(blocks(untracked)!.contains { if case .forecast = $0 { return true } else { return false } })
        var reaching = i
        reaching.fiveHourForecast = UsageStore.FiveHourForecast(depletionDate: end, beforeReset: true)
        let warning = try XCTUnwrap(blocks(reaching)?[4])
        guard case .forecast(let f) = warning else { return XCTFail() }
        XCTAssertTrue(f.warning)
        XCTAssertEqual(f.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(f.text, l.forecastReach(PopoverFormat.forecastTime(end, locale: .current, timeZone: .current)))
    }

    func testTwoClaudeAccountsWithAnExpiredOneAsCapturedValues() async throws {
        let main = PopoverFixtures.limitStatus(fiveHour: 25, resetIn: 3600, email: "main@example.com")
        let work = AdditionalClaudeLimits(rootPath: "/Users/example/.claude-work", status: LimitStatus(), isExpired: true)
        let keyed = AdditionalClaudeLimits(rootPath: "/Users/example/.claude-keyed", status: LimitStatus(), isExpired: true,
                                           sessionKeyExpired: true)
        let staleOne = AdditionalClaudeLimits(rootPath: "/Users/example/.claude-old",
                                              status: PopoverFixtures.limitStatus(fiveHour: 5, resetIn: 600, email: "old@example.com"),
                                              updatedAt: now.addingTimeInterval(-30 * 60))
        var i = input("claude_code") {
            $0.limits = main
            $0.additionalLimits = [work, keyed, staleOne]
            $0.claudeAccounts = [.defaultAccount(main)] + [work, keyed, staleOne].map(ClaudeAccountLimits.additional)
            $0.trackedClaudeAccountID = ClaudeAccountLimits.defaultID
            $0.showsCost = true
            $0.claudeAccountUsage = [ClaudeAccountLimits.defaultID: ClaudeAccountUsage(todayTokens: 1_500, todayCost: UsageCost(amount: 1.5, coverage: .source),
                                                                                       monthTokens: 20_000, monthCost: UsageCost(amount: 9, coverage: .source))]
            $0.unattributedClaudeUsage = ClaudeAccountUsage(monthTokens: 4_200)
        }
        var b = try XCTUnwrap(blocks(i))
        let tabs = i.claudeAccounts.map { CapsuleTab(id: $0.id, title: $0.title, help: $0.status.accountDisplay, marked: $0.id == "default") }
        XCTAssertEqual(b[1], .accountTabs(tabs, selected: "default"))
        XCTAssertEqual(tabs.map(\.title).first, "main@example.com")
        XCTAssertTrue(b.contains(.accountUsage(PeriodPair(name: l.today, tokens: "1.5K", cost: "$1.50"),
                                               PeriodPair(name: l.thisMonth, tokens: "20K", cost: "$9.00"))))
        XCTAssertEqual(b.last, .unattributed(l.unattributedClaudeUsage("4.2K")))

        i.claudeAccountID = work.key
        b = try XCTUnwrap(blocks(i))
        XCTAssertEqual(b[2], .notice(NoticeModel(style: .banner, symbol: "exclamationmark.triangle.fill",
                                                 title: l.claudeAuthExpiredTitle,
                                                 hint: l.additionalAccountExpiredHint(PlatformCompat.abbreviatingWithTilde(work.rootPath)),
                                                 button: NoticeButton(label: l.retry, action: .refreshClaudeLimits))))
        XCTAssertEqual(rows(b).count, 0, "an expired folder shown without values has no rows")

        i.claudeAccountID = keyed.key
        guard case .notice(let keyNotice) = try XCTUnwrap(blocks(i))[2] else { return XCTFail() }
        XCTAssertEqual(keyNotice.symbol, "key.slash.fill", "its own session key died: Settings, not Retry")

        i.claudeAccountID = staleOne.key
        b = try XCTUnwrap(blocks(i))
        XCTAssertEqual(b[2], .stale(RelativeText(prefix: staleLabel, date: staleOne.updatedAt!)))
        XCTAssertEqual(rows(b).map(\.0.percentText), ["5%"])
    }

    func testTwoClaudeAccountsWithAnExpiredOneFromAFixtureStore() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("popover-limits-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let f = try await PopoverFixtures.make(
            suite: "popover.limits.accounts",
            providers: [PopoverFixtureUsage(id: "claude_code", displayName: "Claude Code", reportsCost: true,
                                            today: PopoverFixtures.day(5_000, cost: 1))],
            claude: .success(PopoverFixtures.limitStatus(fiveHour: 25, resetIn: 3600, email: "main@example.com")),
            additionalRoots: [work], additional: .failure(.httpStatus(401)))
        f.companion.setLanguage(.en)
        XCTAssertEqual(f.store.claudeAccounts.count, 2)
        let model = HomeModel.make(store: f.store, companion: f.companion, updater: nil, team: f.team, feed: nil,
                                   state: f.state, facts: Self.windows, now: Date())
        let b = try XCTUnwrap(model.limits)
        guard case .accountTabs(let tabs, let selected) = b[1] else { return XCTFail("tabs first: \(b)") }
        XCTAssertEqual(tabs.map(\.title), f.store.claudeAccounts.map(\.title))
        XCTAssertEqual(tabs.first?.title, "main@example.com")
        XCTAssertEqual(tabs.map(\.marked), [true, false], "the tracked account has the dot")
        XCTAssertEqual(selected, "default")
        f.state.claudeAccountID = f.store.claudeAccounts[1].id
        let expired = try XCTUnwrap(HomeModel.make(store: f.store, companion: f.companion, updater: nil, team: f.team, feed: nil,
                                                   state: f.state, facts: Self.windows, now: Date()).limits)
        guard case .notice(let notice) = expired[2] else { return XCTFail("the expired folder's notice: \(expired)") }
        XCTAssertEqual(notice.title, l.claudeAuthExpiredTitle)
        XCTAssertEqual(notice.hint, l.additionalAccountExpiredHint(f.store.claudeAccounts[1].fallbackTitle))
    }

    func testARateLimitedRefreshSaysSoUnderTheButton() async throws {
        let f = try await PopoverFixtures.make(
            suite: "popover.limits.ratelimited",
            providers: [PopoverFixtureUsage(id: "claude_code", displayName: "Claude Code", reportsCost: true,
                                            today: PopoverFixtures.day(2_000, cost: 0.5))],
            claude: .failure(.rateLimited(retryAfter: nil)))
        f.companion.setLanguage(.ko)
        f.store.localizationLanguage = .ko
        await f.store.refreshLimitTokenFromKeychain()
        let model = HomeModel.make(store: f.store, companion: f.companion, updater: nil, team: f.team, feed: nil,
                                   state: f.state, facts: Self.windows, now: Date())
        let ko = L(.ko)
        let help = HelpModel(tooltip: ko.winClaudeCredentialHelpTooltip, title: ko.winClaudeCredentialHelpTitle, body: ko.winClaudeCredentialHelpBody,
                             button: NoticeButton(label: ko.registerSessionKey, action: .openSessionKeySettings))
        XCTAssertEqual(model.limits, [.caption(ko.limitsOfficial, help: help), .refreshRow(RefreshRowModel(
            status: .tapToLoad(ko.limitsTapToLoad), button: NoticeButton(label: ko.refresh, action: .refreshClaudeLimits),
            error: ko.limitRefreshRateLimited))])
    }

    // MARK: Codex, Cursor, OpenCode Go, Grok, Antigravity

    func testCodexTwoBucketsWithPlanLimitReachedAndSpendLimit() async throws {
        let reset = Int(now.timeIntervalSince1970) + 3600
        let status = CodexRateLimitStatus(
            rateLimits: CodexRateLimitSnapshot(limitId: "codex",
                                               primary: CodexRateLimitWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: reset),
                                               secondary: CodexRateLimitWindow(usedPercent: 40, windowDurationMins: 10_080),
                                               planType: "pro", rateLimitReachedType: "primary"),
            rateLimitsByLimitId: ["codex_other": CodexRateLimitSnapshot(
                limitId: "codex_other", primary: CodexRateLimitWindow(usedPercent: 7, windowDurationMins: 300),
                individualLimit: CodexSpendControlLimit(limit: "$50", remainingPercent: 70, resetsAt: reset, used: "$15"))])
        let b = try XCTUnwrap(blocks(input("codex") { $0.codexLimits = status }))
        XCTAssertEqual(b[1], .codexMeta(CodexMetaModel(plan: l.plan("pro"), limitReached: l.limitReached, stale: nil)))
        XCTAssertEqual(b[2], .bucketLabel("Codex"))
        XCTAssertTrue(b.contains(.bucketLabel("Codex other")))
        XCTAssertEqual(rows(b).map(\.0.name), [l.codexWindow(300), l.codexWindow(10_080), l.codexWindow(300), l.personalSpendLimit])
        let spend = rows(b)[3].0
        XCTAssertEqual(spend.detail, "$15 / $50")
        XCTAssertEqual(spend.percentText, "30%")
        XCTAssertNil(spend.paceMarker, "no window length, no pace marker")
        XCTAssertEqual(rows(b)[0].0.percentColor, .systemRed)
        let single = try XCTUnwrap(blocks(input("codex") {
            $0.codexLimits = CodexRateLimitStatus(rateLimits: CodexRateLimitSnapshot(primary: CodexRateLimitWindow(usedPercent: 3)))
            $0.codexLimitsStale = true
            $0.codexLimitsUpdatedAt = now.addingTimeInterval(-3600)
        }))
        XCTAssertEqual(single[1], .codexMeta(CodexMetaModel(plan: nil, limitReached: nil,
                                                            stale: RelativeText(prefix: staleLabel, date: now.addingTimeInterval(-3600)))))
        XCTAssertFalse(single.contains { if case .bucketLabel = $0 { return true } else { return false } }, "one bucket, no label")
        XCTAssertNil(blocks(input("codex")), "no Codex values, no section")
    }

    func testCursorNoticeMessageRowsAndRemainingSpend() async throws {
        let status = CursorRateLimitStatus(billingCycleEnd: String(Int(now.timeIntervalSince1970 * 1000) + 86_400_000),
                                           planUsage: CursorPlanUsage(remaining: 1250, limit: 2000, autoPercentUsed: 12,
                                                                      apiPercentUsed: 3, totalPercentUsed: 37.5),
                                           displayMessage: "You are on Pro")
        let b = try XCTUnwrap(blocks(input("cursor") {
            $0.cursorLimits = status
            $0.cursorLimitsAuthExpired = true
        }))
        XCTAssertEqual(b[1], .notice(NoticeModel(style: .card, symbol: "exclamationmark.triangle.fill",
                                                 title: l.cursorAuthExpiredTitle, hint: l.cursorAuthExpiredHint, button: nil)))
        XCTAssertEqual(b[2], .message("You are on Pro"))
        XCTAssertEqual(rows(b).map(\.0.name), [l.cursorMonthlyIncluded, l.cursorAutoUsage, l.cursorApiUsage])
        XCTAssertEqual(rows(b).map(\.1), [true, true, true])
        XCTAssertEqual(b[4], .remainingSpend(l.cursorRemainingSpend("$12.50"), dimmed: true), "under the monthly row")
        XCTAssertNotNil(rows(b)[0].0.reset, "the billing cycle's end")
        XCTAssertNil(rows(b)[0].0.paceMarker, "the cycle has no fixed span")
        XCTAssertEqual(blocks(input("cursor") { $0.cursorLimitsAuthExpired = true }),
                       [.caption(l.limitsOfficial, help: nil), .notice(NoticeModel(style: .card, symbol: "exclamationmark.triangle.fill",
                                                                                   title: l.cursorAuthExpiredTitle, hint: l.cursorAuthExpiredHint, button: nil))],
                       "expired with nothing loaded: the notice alone")
    }

    func testOpenCodeGoEndedWindowCountsZeroWithTheIdleHint() async throws {
        let iso = ISO8601DateFormatter()
        let status = OpenCodeGoRateLimitStatus(
            rolling: OpenCodeGoWindow(percent: 64, resetsAt: iso.string(from: now.addingTimeInterval(-60))),
            weekly: OpenCodeGoWindow(percent: 20, resetsAt: iso.string(from: now.addingTimeInterval(3 * 86_400))),
            monthly: OpenCodeGoWindow(percent: 9))
        let b = try XCTUnwrap(blocks(input("opencode") { $0.openCodeGoLimits = status }))
        let r = rows(b).map(\.0)
        XCTAssertEqual(r.map(\.name), [l.fiveHourSession, l.weekly, l.openCodeGoMonthly])
        XCTAssertEqual(r[0].percentText, "0%")
        XCTAssertNil(r[0].reset)
        XCTAssertEqual(r[0].idleHint, l.fiveHourNotStarted)
        XCTAssertNotNil(r[1].paceMarker, "a weekly window has a pace")
        XCTAssertNil(r[2].paceMarker, "the monthly window follows the subscription date")
    }

    func testGrokCreditRowAndProducts() async throws {
        let iso = ISO8601DateFormatter()
        let status = GrokCreditStatus(
            currentPeriod: .init(type: "USAGE_PERIOD_TYPE_WEEKLY", start: iso.string(from: now.addingTimeInterval(-2 * 86_400)),
                                 end: iso.string(from: now.addingTimeInterval(5 * 86_400))),
            creditUsagePercent: 33.3,
            productUsage: [.init(product: "GrokBot", usagePercent: 20), .init(product: "Api", usagePercent: 13.3),
                           .init(product: "Idle", usagePercent: 0)])
        let b = try XCTUnwrap(blocks(input("grok") { $0.grokLimits = status }))
        XCTAssertEqual(rows(b).map(\.0.name), [l.grokCreditPeriod(weekly: true, monthly: false)])
        XCTAssertEqual(b.last, .products("Grok 20% · API 13.3%", dimmed: false))
    }

    func testAntigravityShowsOnTheMacAndNotOnWindows() async throws {
        let status = AntigravityRateLimitStatus(groups: [AntigravityQuotaGroup(displayName: "Gemini", buckets: [
            AntigravityQuotaBucket(bucketId: "gemini-5h", displayName: "5h", window: "5h", remainingFraction: 0.25)])])
        let i = input("antigravity") { $0.antigravityLimits = status }
        let b = try XCTUnwrap(blocks(i))
        XCTAssertEqual(b[1], .groupTitle(l.antigravityGroupTitle("Gemini"), dimmed: false))
        XCTAssertEqual(rows(b).map(\.0.percentText), ["75%"])
        XCTAssertNil(blocks(i, facts: Self.windows), "no Antigravity limits source on Windows")
        XCTAssertEqual(blocks(input("antigravity"))?[1], .refreshRow(RefreshRowModel(
            status: .tapToLoad(l.limitsTapToLoad), button: NoticeButton(label: l.refresh, action: .refreshAntigravityLimits), error: nil)))
    }

    // MARK: The quota row

    func testTheQuotaRowFollowsTheDisplayModeAndThresholds() async throws {
        let span = LimitWindowSpan.fiveHour
        let reset = now.addingTimeInterval(span / 2)   // half the window passed: pace 0.5
        let used = LimitsBuilder(store: input("x") { $0.warnThreshold = 80; $0.critThreshold = 95 }, facts: .mac, now: now)
        var row = used.quotaRow(name: "5h", utilization: 62, reset: reset, span: span)
        XCTAssertEqual(row.percentText, "62%")
        XCTAssertEqual(row.fillPercent, 62)
        XCTAssertEqual(try XCTUnwrap(row.paceMarker), 0.5, accuracy: 1e-9)
        XCTAssertEqual(row.tint, .systemYellow, "12 points over pace: slightly fast")
        XCTAssertEqual(row.percentColor, .primary, "yellow text does not read: primary")
        XCTAssertEqual(row.help, l.paceTier(.slightlyOver) + " · " + l.paceDelta(12)! + "\n" + l.paceHint("50%"))
        XCTAssertEqual(row.resetClock, PopoverFormat.resetClockSuffix(reset, now: now, language: .en, calendar: .current))
        XCTAssertEqual(row.resetText, RelativeText(prefix: "", date: reset, suffix: row.resetClock!))
        XCTAssertNil(row.idleHint)

        let remaining = LimitsBuilder(store: input("x") { $0.limitDisplayMode = .remaining }, facts: .mac, now: now)
        row = remaining.quotaRow(name: "5h", utilization: 120, reset: nil, idleHint: "idle")
        XCTAssertEqual(row.percentText, l.percentRemaining("0%"))
        XCTAssertEqual(row.fillPercent, 0)
        XCTAssertNil(row.paceMarker)
        XCTAssertNil(row.help, "no pace, no tooltip")
        XCTAssertEqual(row.tint, .systemRed, "over the critical threshold without a pace")
        XCTAssertEqual(row.idleHint, "idle", "the idle hint shows only without a reset")
        XCTAssertEqual(remaining.quotaRow(name: "w", utilization: 85, reset: nil).tint, .systemOrange, "from the warning threshold")
        XCTAssertEqual(remaining.quotaRow(name: "w", utilization: 10, reset: nil).tint, .systemGreen)
    }
}
