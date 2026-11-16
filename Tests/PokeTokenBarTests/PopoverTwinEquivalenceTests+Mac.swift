import XCTest
@testable import PokeTokenBar

/// Each shared twin of logic that stays in an upstream `UI/` file behaves as the original (stage 7, D8). Mac only: the
/// originals are Mac-only. The text side of the same promise is `PopoverParityScanTests.testTwinsMatchTheirOriginals`.
///
/// Private `PopoverView` members cannot be called, so `MacPopoverOracle` below holds verbatim copies of them (twins.txt
/// holds each copy to the Mac's body), reading a captured `HomeInput` as the view's `store`. The tests drive the copies
/// and the shared twins over the same inputs; for the view bodies, the Home model is compared with the Mac body's own
/// expressions evaluated on a fixture store.
@MainActor
final class PopoverTwinEquivalenceTests: XCTestCase {
    /// A fixed generator so a failure replays.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private enum Action: CaseIterable {
        case reset, openSessionKeySettings, openDexEntry, openRepresentativeDex
        case setTab, setShowSettings, setShowingRecap, toggleCollectionLog, setCollectionLogSame
        case setProvider, setAccount, setExpandAdvanced, setDexDetail
    }

    private static let tabs: [(PopoverTab, PopoverState.Tab)] = [(.home, .home), (.shop, .shop), (.bag, .bag), (.collection, .collection)]

    private func fields(_ n: PopoverNavigation) -> [String] {
        [String(n.showSettings), "\(Self.tabs.firstIndex { $0.0 == n.tab }!)", String(n.showingCollectionLog), String(n.showingRecap),
         n.dexDetailCollectionID ?? "-", n.providerID ?? "-", n.claudeAccountID ?? "-", String(n.expandAdvancedOnOpen)]
    }

    private func fields(_ s: PopoverState) -> [String] {
        [String(s.showSettings), "\(Self.tabs.firstIndex { $0.1 == s.tab }!)", String(s.showingCollectionLog), String(s.showingRecap),
         s.dexDetailCollectionID ?? "-", s.providerID ?? "-", s.claudeAccountID ?? "-", String(s.expandAdvancedOnOpen)]
    }

    /// 200 random sequences of 1…40 actions (every route, every setter, every didSet path) leave both with equal fields
    /// after each step.
    func testPopoverStateFollowsPopoverNavigation() async {
        var rng = SplitMix(state: 0x5EED_0007)
        var steps = 0
        for sequence in 0..<200 {
            let mac = PopoverNavigation(), twin = PopoverState()
            for step in 0..<Int.random(in: 1...40, using: &rng) {
                let action = Action.allCases.randomElement(using: &rng)!
                let flag = Bool.random(using: &rng)
                let id = ["25", "133", "6-mega-x", nil].randomElement(using: &rng)!
                switch action {
                case .reset: mac.reset(); twin.reset()
                case .openSessionKeySettings: mac.openSessionKeySettings(); twin.openSessionKeySettings()
                case .openDexEntry: mac.openDexEntry(collectionID: id ?? "1"); twin.openDexEntry(collectionID: id ?? "1")
                case .openRepresentativeDex: mac.openRepresentativeDex(); twin.openRepresentativeDex()
                case .setTab:
                    let t = Self.tabs.randomElement(using: &rng)!
                    mac.tab = t.0; twin.tab = t.1
                case .setShowSettings: mac.showSettings = flag; twin.showSettings = flag
                case .setShowingRecap: mac.showingRecap = flag; twin.showingRecap = flag
                case .toggleCollectionLog: mac.showingCollectionLog.toggle(); twin.showingCollectionLog.toggle()
                case .setCollectionLogSame: mac.showingCollectionLog = mac.showingCollectionLog; twin.showingCollectionLog = twin.showingCollectionLog
                case .setProvider: mac.providerID = id; twin.providerID = id
                case .setAccount: mac.claudeAccountID = id; twin.claudeAccountID = id
                case .setExpandAdvanced: mac.expandAdvancedOnOpen = flag; twin.expandAdvancedOnOpen = flag
                case .setDexDetail: mac.dexDetailCollectionID = id; twin.dexDetailCollectionID = id
                }
                steps += 1
                XCTAssertEqual(fields(twin), fields(mac), "sequence \(sequence) step \(step) after \(action)")
                if fields(twin) != fields(mac) { return }
            }
        }
        XCTAssertGreaterThan(steps, 2_000)
    }

    /// The open-plaza action is a stored closure on both; it survives every route.
    func testTheOpenPlazaActionSurvivesTheRoutesOnBoth() async {
        let mac = PopoverNavigation(), twin = PopoverState()
        var calls = (mac: 0, twin: 0)
        mac.onOpenPlaza = { calls.mac += 1 }
        twin.onOpenPlaza = { calls.twin += 1 }
        mac.reset(); twin.reset()
        mac.openDexEntry(collectionID: "25"); twin.openDexEntry(collectionID: "25")
        mac.onOpenPlaza?(); twin.onOpenPlaza?()
        XCTAssertEqual(calls.mac, 1)
        XCTAssertEqual(calls.twin, 1)
    }

    // MARK: - PopoverFormat and the limits gate, against verbatim copies of the Mac

    private static let thresholds: [(warn: Double, crit: Double)] = [(80, 95), (50, 80)]
    private static let paces: [Double?] = [nil, 0, 0.05, 0.099, 0.1, 0.25, 0.5, 0.9, 1]
    private static let utilizations: [Double] = (0...120).map(Double.init) + [0.04, 33.35, 79.96, 88.35, 99.95, 100.05]

    private func oracle(_ store: HomeInput, providerID: String? = nil, accountID: String? = nil) -> MacPopoverOracle {
        MacPopoverOracle(store: store, nav: .init(providerID: providerID, claudeAccountID: accountID),
                         companion: .init(language: store.language))
    }

    /// Utilizations 0…120 (and a few fractions) × both display modes × 9 paces × 2 threshold pairs × 8 languages: the
    /// percentage, the tooltip, the marker and the row model's own percentage, fill, marker and tooltip equal the Mac's.
    func testTheLimitRowFollowsTheMac() async {
        var checked = 0
        for language in AppLanguage.allCases {
            let l = L(language)
            for mode in UsageStore.LimitDisplayMode.allCases {
                for t in Self.thresholds {
                    var input = HomeInput()
                    input.language = language
                    input.limitDisplayMode = mode
                    input.warnThreshold = t.warn
                    input.critThreshold = t.crit
                    let mac = oracle(input)
                    // One injected `now` for the row model and the expected values; the Mac's copy reads its own clock, so its
                    // value is only held between the pace at `now` and the pace right after the call (no tolerance on wall time).
                    let now = Date()
                    let builder = LimitsBuilder(store: input, facts: .mac, now: now)
                    for u in Self.utilizations {
                        XCTAssertEqual(PopoverFormat.limitPercentText(u, mode: mode, l: l), mac.limitPercentText(u), "\(language) \(mode) \(u)")
                        for pace in Self.paces {
                            let tier = PaceTier.tier(utilization: u, pace: pace, critThreshold: t.crit)
                            let help = PopoverFormat.paceHelp(pace: pace, tier: tier, utilization: u, mode: mode, l: l)
                            XCTAssertEqual(help, mac.paceHelp(pace, tier: tier, utilization: u), "\(language) \(mode) \(u) \(String(describing: pace))")
                            XCTAssertEqual(PopoverFormat.markerFraction(pace: pace, mode: mode),
                                           LimitProgressBar.markerFraction(pace: pace, mode: mode))
                            checked += 1
                        }
                        // The row reads the same rules through its own pace: a reset `pace` of a 5-hour window ago.
                        let pace = 0.5, span = LimitWindowSpan.fiveHour
                        let reset = now.addingTimeInterval(span * (1 - pace))
                        let row = builder.quotaRow(name: "x", utilization: u, reset: reset, span: span)
                        let macPace = mac.paceFraction(reset: reset, span: span)
                        let after = Date()
                        let paceNow = UsageStore.paceFraction(resetsAt: reset, span: span, now: now)
                        let paceAfter = UsageStore.paceFraction(resetsAt: reset, span: span, now: after)
                        XCTAssertEqual(row.percentText, mac.limitPercentText(u))
                        XCTAssertEqual(row.fillPercent, min(100, max(0, input.limitDisplayPercent(u))), "LimitProgressBar.body's fill")
                        XCTAssertEqual(try XCTUnwrap(row.paceMarker), try XCTUnwrap(LimitProgressBar.markerFraction(pace: paceNow, mode: mode)),
                                       "the row's marker is the Mac's marker rule on the pace at the injected now")
                        guard let held = macPace else { XCTFail("the Mac's pace is nil for a reset with a span"); continue }
                        XCTAssertTrue(min(paceNow ?? 0, paceAfter ?? 0) <= held && held <= max(paceNow ?? 0, paceAfter ?? 0),
                                      "the Mac's own pace lies between the pace at now and after the call")
                        let macTier = PaceTier.tier(utilization: u, pace: paceNow, critThreshold: t.crit)
                        XCTAssertEqual(row.help, mac.paceHelp(paceNow, tier: macTier, utilization: u))
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 30_000)
    }

    /// Resets from a minute ago to 9 days ahead × 4 time zones × 8 languages: the clock suffix equals the Mac's, which
    /// reads the default time zone, `Calendar.current` and `Date()`.
    func testTheResetClockFollowsTheMac() async throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        let offsets: [TimeInterval] = [-60, -1, 30, 60, 3600, 4 * 3600, 6 * 3600 - 30, 6 * 3600 + 30, 7 * 3600, 12 * 3600,
                                       18 * 3600, 23 * 3600, 25 * 3600, 2 * 86_400, 3 * 86_400 + 5000, 5 * 86_400,
                                       7 * 86_400, 9 * 86_400]
        var checked = 0, nearby = 0
        for zone in ["Asia/Seoul", "America/New_York", "Europe/Berlin", "Asia/Kolkata"] {
            let tz = try XCTUnwrap(TimeZone(identifier: zone))
            NSTimeZone.default = tz
            // `TimeZone.current` stays the system zone; what the Mac's copy reads follows the default zone.
            XCTAssertEqual(Calendar.current.timeZone, tz, "the Mac's Calendar.current follows the default zone")
            XCTAssertEqual(DateFormatter().timeZone, tz, "and so does a default DateFormatter")
            for language in AppLanguage.allCases {
                let mac = oracle({ var i = HomeInput(); i.language = language; return i }())
                for offset in offsets {
                    let now = Date()
                    let reset = now.addingTimeInterval(offset)
                    let expected = mac.resetClockSuffix(reset).string
                    let twin = PopoverFormat.resetClockSuffix(reset, now: now, language: language, calendar: Calendar.current)
                    XCTAssertEqual(twin, expected, "\(zone) \(language) \(offset)")
                    if !expected.contains(where: { $0.isLetter }) { nearby += 1 }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 4 * 8 * offsets.count)
        XCTAssertGreaterThan(nearby, 0, "both forms were compared")
        XCTAssertLessThan(nearby, checked, "both forms were compared")
    }

    /// The pace line's fraction, with the Mac's `Date()` and the twin's `now` a moment apart (so no reset sits exactly
    /// on the window's end, where that moment decides).
    func testThePaceFractionFollowsTheMac() async {
        let mac = oracle(HomeInput())
        for span in [nil, 0, LimitWindowSpan.fiveHour, LimitWindowSpan.sevenDay] as [TimeInterval?] {
            for left in [nil, -10, 1, 60, 3600, 4 * 3600, 5 * 3600, 6 * 3600, 6 * 86_400] as [TimeInterval?] {
                let now = Date()
                let reset = left.map { now.addingTimeInterval($0) }
                let twin = PopoverFormat.paceFraction(reset: reset, span: span, now: now)
                let original = mac.paceFraction(reset: reset, span: span)
                let after = Date()
                let twinAfter = PopoverFormat.paceFraction(reset: reset, span: span, now: after)
                XCTAssertEqual(twin == nil, original == nil, "\(String(describing: span)) \(String(describing: left))")
                // the Mac's copy reads its own clock: its value is between the twin's at `now` and right after the call
                if let twin, let original, let twinAfter {
                    XCTAssertTrue(min(twin, twinAfter) <= original && original <= max(twin, twinAfter), "\(String(describing: span)) \(String(describing: left))")
                }
            }
        }
    }

    private static let invisible = (
        claude: LimitStatus(),
        codex: CodexRateLimitStatus(rateLimits: CodexRateLimitSnapshot()),
        antigravity: AntigravityRateLimitStatus(groups: [AntigravityQuotaGroup(displayName: "Gemini")]),
        cursor: CursorRateLimitStatus(planUsage: CursorPlanUsage()),
        openCode: OpenCodeGoRateLimitStatus(),
        grok: GrokCreditStatus())
    private static let visible = (
        codex: CodexRateLimitStatus(rateLimits: CodexRateLimitSnapshot(primary: CodexRateLimitWindow(usedPercent: 10))),
        antigravity: AntigravityRateLimitStatus(groups: [AntigravityQuotaGroup(
            displayName: "Gemini", buckets: [AntigravityQuotaBucket(bucketId: "5h", displayName: "5h", remainingFraction: 0.5)])]),
        cursor: CursorRateLimitStatus(planUsage: CursorPlanUsage(totalPercentUsed: 40)),
        openCode: OpenCodeGoRateLimitStatus(rolling: OpenCodeGoWindow(percent: 30)),
        grok: GrokCreditStatus(creditUsagePercent: 20))

    /// Every combination of the 14 flags the gate reads (twice: with visible and with empty statuses) for every provider
    /// with a section, an unknown one and none: the Mac facts give exactly the Mac's predicate; the Windows facts give
    /// the Mac's predicate with the Keychain allowed, and no Antigravity section.
    func testTheLimitsGateFollowsTheMacOnEveryFlag() async {
        let providers: [String?] = LimitsSource.allCases.map(\.rawValue) + ["gemini", nil]
        let windows = PopoverPlatformFacts.windows(regionLocale: Locale(identifier: "en_US"), regionCalendar: Calendar(identifier: .gregorian))
        var shown = (mac: 0, windows: 0), checked = 0
        for showsValues in [true, false] {
            for mask in 0..<(1 << 14) {
                func on(_ bit: Int) -> Bool { mask & (1 << bit) != 0 }
                var input = HomeInput()
                input.disableKeychainAccess = on(0)
                input.limits = on(1) ? Self.invisible.claude : nil
                input.limitsAuthExpiry = on(2) ? .oauth : nil
                input.additionalLimits = on(3) ? [AdditionalClaudeLimits(rootPath: "/tmp/work", status: LimitStatus())] : []
                input.codexLimits = on(4) ? (showsValues ? Self.visible.codex : Self.invisible.codex) : nil
                input.antigravityHasTokenFile = on(5)
                input.antigravityLimits = on(6) ? (showsValues ? Self.visible.antigravity : Self.invisible.antigravity) : nil
                input.antigravityLimitsAuthExpired = on(7)
                input.cursorLimits = on(8) ? (showsValues ? Self.visible.cursor : Self.invisible.cursor) : nil
                input.cursorLimitsAuthExpired = on(9)
                input.openCodeGoLimits = on(10) ? (showsValues ? Self.visible.openCode : Self.invisible.openCode) : nil
                input.openCodeGoLimitsAuthExpired = on(11)
                input.grokLimits = on(12) ? (showsValues ? Self.visible.grok : Self.invisible.grok) : nil
                input.grokLimitsAuthExpired = on(13)
                var keychainOn = input
                keychainOn.disableKeychainAccess = false
                for provider in providers {
                    input.snapshots = [provider ?? "gemini", "codex"].map { ProviderSnapshot(providerID: $0, displayName: $0, fetchedAt: Date()) }
                    if provider == nil { input.snapshots = [] }
                    keychainOn.snapshots = input.snapshots
                    let mac = oracle(input).selectedProviderHasLimits
                    let onMac = LimitsBuilder(store: input, facts: .mac, now: Date()).selectedProviderHasLimits
                    XCTAssertEqual(onMac, mac, "mac \(String(describing: provider)) mask \(mask) values \(showsValues)")
                    let onWindows = LimitsBuilder(store: input, facts: windows, now: Date()).selectedProviderHasLimits
                    let expected = provider == LimitsSource.antigravity.rawValue ? false : oracle(keychainOn).selectedProviderHasLimits
                    XCTAssertEqual(onWindows, expected, "windows \(String(describing: provider)) mask \(mask) values \(showsValues)")
                    if onMac != mac || onWindows != expected { return }
                    shown.mac += mac ? 1 : 0
                    shown.windows += onWindows ? 1 : 0
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2 * (1 << 14) * providers.count)
        XCTAssertGreaterThan(shown.mac, shown.windows, "the facts hide sections on Windows")
        XCTAssertGreaterThan(shown.windows, 0)
    }

    func testTheSelectedSnapshotAndAccountFollowTheMac() async {
        var input = HomeInput()
        let ids = ["claude_code", "codex", "gemini"]
        for count in 0...3 {
            input.snapshots = ids.prefix(count).map { ProviderSnapshot(providerID: $0, displayName: $0, fetchedAt: Date()) }
            input.claudeAccounts = ["default", "a1", "b2"].prefix(count).map {
                ClaudeAccountLimits.defaultAccount(LimitStatus()).with(id: $0)
            }
            for chosen in ids + ["gone", nil] as [String?] {
                input.providerID = chosen
                input.claudeAccountID = chosen == "codex" ? "a1" : chosen
                let mac = oracle(input, providerID: chosen, accountID: input.claudeAccountID)
                let builder = LimitsBuilder(store: input, facts: .mac, now: Date())
                XCTAssertEqual(builder.selectedSnapshot?.providerID, mac.selectedSnapshot?.providerID)
                XCTAssertEqual(HomeBuilder(store: input, facts: .mac).selectedSnapshot?.providerID, mac.selectedSnapshot?.providerID)
                XCTAssertEqual(builder.selectedClaudeAccount(in: input.claudeAccounts)?.id,
                               mac.selectedClaudeAccount(in: input.claudeAccounts)?.id)
            }
        }
    }

    /// Two constants of `PopoverView` are stored lets, which the scan's twins cannot name: their text is pinned here.
    func testTheMacConstantsTheTwinsCopyAreUnchanged() throws {
        let source = try XCTUnwrap(PopoverParityScanTests.read("UI/PopoverView.swift"))
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("private static let resetClockWindow: TimeInterval = 6 * 3600"),
                      "PopoverView.resetClockWindow changed: change PopoverFormat.resetClockWindow and MacPopoverOracle")
        XCTAssertTrue(flat.contains("private static let timeFormatter: DateFormatter = { let f = DateFormatter() f.dateFormat = \"HH:mm\" return f }()"),
                      "PopoverView.timeFormatter changed: change PopoverFormat.forecastTime")
        XCTAssertEqual(PopoverFormat.resetClockWindow, 6 * 3600)
    }

    // MARK: - The Home model against the Mac body's own expressions, on a fixture store

    /// Three providers (one without cost, one with three models), status checks, and the Mac's own expressions from
    /// `header`, `periodLabel`, `providerTabBar`, `providerRow`, `providerStatusBanner` and `footer` evaluated on the
    /// store: the model built with the Mac facts says the same, in three languages.
    func testTheHomeModelSaysWhatTheMacBodySays() async throws {
        let fixture = try await PopoverFixtures.threeProviders(suite: "popover.twins.home")
        let store = fixture.store
        for language in [AppLanguage.ko, .en, .ja] {
            fixture.companion.setLanguage(language)
            let l = fixture.companion.l
            for chosen in ["codex", "claude_code", nil] as [String?] {
                fixture.state.providerID = chosen
                let model = HomeModel.make(store: store, companion: fixture.companion, updater: nil, team: fixture.team,
                                           feed: nil, state: fixture.state, facts: .mac, now: Date())
                // PopoverView.header
                XCTAssertEqual(model.header.caption, l.todayTokens)
                XCTAssertEqual(model.header.total, TokenFormatter.compact(store.todayTotalTokens))
                XCTAssertEqual(model.header.grouped, store.todayTotalTokens >= 1_000 ? TokenFormatter.grouped(store.todayTotalTokens) : nil)
                XCTAssertEqual(model.header.cost, store.showsCost ? store.todayUsageCost.text(l) : nil)
                // PopoverView.periodLabels / periodLabel
                XCTAssertEqual(model.header.week, PeriodPair(name: l.thisWeek, tokens: TokenFormatter.compact(store.weekTotalTokens),
                                                             cost: store.showsCost ? store.weekUsageCost.text(l) : nil))
                XCTAssertEqual(model.header.month, PeriodPair(name: l.thisMonth, tokens: TokenFormatter.compact(store.monthTotalTokens),
                                                              cost: store.showsCost ? store.monthUsageCost.text(l) : nil))
                // PopoverView.providerTabBar / ProviderTabBar.body
                let selected = store.snapshot(preferring: fixture.state.providerID)
                XCTAssertEqual(model.providerTabs.map(\.id), store.snapshots.count > 1 ? store.snapshots.map(\.providerID) : [])
                XCTAssertEqual(model.providerTabs.map(\.title), store.snapshots.count > 1 ? store.snapshots.map(\.displayName) : [])
                XCTAssertEqual(model.selectedProviderID, selected?.providerID)
                // PopoverView.providerRow / tokenTypeLabel
                let snap = try XCTUnwrap(selected), today = try XCTUnwrap(snap.today)
                let row = try XCTUnwrap(model.providerRow)
                XCTAssertEqual(row.name, snap.displayName)
                XCTAssertEqual(row.tokens, TokenFormatter.compact(today.totalTokens))
                XCTAssertEqual(row.cost, snap.reportsCost ? today.usageCost.text(l) : nil)
                XCTAssertEqual([row.input, row.output, row.cacheWrite, row.cacheRead],
                               [(l.tokenInput, today.inputTokens), (l.tokenOutput, today.outputTokens),
                                (l.tokenCacheWrite, today.cacheCreationTokens), (l.tokenCacheRead, today.cacheReadTokens)]
                                .map { PeriodPair(name: $0.0, tokens: TokenFormatter.compact($0.1)) })
                if let models = today.models, models.count > 1 {
                    XCTAssertEqual(row.models.map(\.name), models.sorted(by: { $0.value > $1.value })
                        .map { model, _ in model.split(separator: "/").last.map(String.init) ?? model })
                    XCTAssertEqual(row.models.map(\.tokens), models.sorted(by: { $0.value > $1.value }).map { TokenFormatter.compact($0.value) })
                } else {
                    XCTAssertEqual(row.models, [])
                }
                // PopoverView.providerStatusBanner
                if let status = store.providerStatus(for: snap.providerID), status.indicator.hasIssue {
                    XCTAssertEqual(model.statusBanner?.label, l.providerStatusLabel(status.indicator))
                    XCTAssertEqual(model.statusBanner?.description, status.description.isEmpty ? nil : status.description)
                } else {
                    XCTAssertNil(model.statusBanner)
                }
                // PopoverView.footer
                XCTAssertEqual(model.footer.usage?.updated, store.lastUpdated.map { RelativeText(prefix: "\(l.updated) ", date: $0) })
                XCTAssertEqual(model.footer.usage?.error, store.lastErrorDescription != nil ? (store.lastErrorMessage(l) ?? "") : nil)
                XCTAssertEqual(model.footer.petToggle?.label, store.floatingPetEnabled ? l.floatingPetHideLabel : l.floatingPetEnableLabel)
                XCTAssertEqual(model.footer.settingsHelp, l.settings)
                XCTAssertEqual(model.footer.quitHelp, l.quit)
            }
        }
        XCTAssertNotNil(HomeModel.make(store: store, companion: fixture.companion, updater: nil, team: fixture.team, feed: nil,
                                       state: { fixture.state.providerID = "codex"; return fixture.state }(), facts: .mac,
                                       now: Date()).statusBanner, "the codex incident shows")
    }

    /// Stage 7 Task 3: the Windows kit's popover metrics are the Mac's (`PopoverMetrics`, twinned as `PopoverWindowMetrics`).
    func testThePopoverMetricsTwinHasTheMacsNumbers() async {
        XCTAssertEqual(PopoverWindowMetrics.width, PopoverMetrics.width)
        XCTAssertEqual(PopoverWindowMetrics.padding, PopoverMetrics.padding)
        XCTAssertEqual(PopoverWindowMetrics.contentWidth, PopoverMetrics.contentWidth)
        XCTAssertEqual(PopoverWindowMetrics.scrollerInset, PopoverMetrics.scrollerInset)
        XCTAssertEqual(PopoverWindowMetrics.scrollContentWidth, PopoverMetrics.scrollContentWidth)
    }
}

// MARK: - Verbatim copies of private PopoverView members (twins.txt holds each body to the Mac's)

/// `Text` for the copies: the Mac's `Text(" (…)")` keeps its string.
private struct Text: Equatable {
    let string: String
    init(_ string: String) { self.string = string }
}

/// The view's environment as the copies name it.
struct OracleNavigation { var providerID: String?; var claudeAccountID: String? }
struct OracleCompanion { var language: AppLanguage }

/// `PopoverView`'s private members, copied verbatim, over a captured `HomeInput` as the view's `store`.
struct MacPopoverOracle {
    let store: HomeInput
    let nav: OracleNavigation
    let companion: OracleCompanion
    var l: L { L(companion.language) }
    private static let resetClockWindow: TimeInterval = 6 * 3600

    var selectedSnapshot: ProviderSnapshot? {
        store.snapshot(preferring: nav.providerID)
    }

    var selectedProviderHasLimits: Bool {
        switch selectedSnapshot?.providerID {
        // Keychain 이 꺼져있지 않으면 한도가 아직 없어도 섹션을 노출한다 — 그래야 최초 실행에
        // claudeLimitsRefreshRow("탭해서 로드")가 보여, 설정까지 안 들어가도 원탭으로 켤 수 있다.
        // (자동 Keychain 읽기는 팝업 방지로 여전히 안 함 — 발견성만 살린다.)
        case "claude_code": return !store.disableKeychainAccess || store.limits != nil || store.limitsAuthExpired
            || !store.additionalLimits.isEmpty
        case "codex": return store.codexLimits?.hasVisibleLimit == true
        case "antigravity": return !store.disableKeychainAccess || store.antigravityHasTokenFile || store.antigravityLimits?.hasVisibleLimit == true || store.antigravityLimitsAuthExpired
        case "cursor": return store.cursorLimits?.hasVisibleLimit == true || store.cursorLimitsAuthExpired
        case "opencode": return store.openCodeGoLimits?.hasVisibleLimit == true || store.openCodeGoLimitsAuthExpired
        case "grok": return store.grokLimits?.hasVisibleLimit == true || store.grokLimitsAuthExpired
        default: return false
        }
    }

    fileprivate func limitPercentText(_ utilization: Double) -> String {
        let text = TokenFormatter.percent(store.limitDisplayPercent(utilization))
        return store.limitDisplayMode == .remaining ? l.percentRemaining(text) : text
    }

    fileprivate func resetClockSuffix(_ reset: Date) -> Text {
        let f = DateFormatter()
        f.locale = companion.language.displayLocale
        let nearby = Calendar.current.isDateInToday(reset)
            || reset.timeIntervalSinceNow <= Self.resetClockWindow
        f.setLocalizedDateFormatFromTemplate(nearby ? "HHmm" : "EEEEdHHmm")
        return Text(" (\(f.string(from: reset)))")
    }

    func paceFraction(reset: Date?, span: TimeInterval?) -> Double? {
        guard let reset, let span else { return nil }
        return UsageStore.paceFraction(resetsAt: reset, span: span, now: Date())
    }

    func paceHelp(_ pace: Double?, tier: PaceTier?, utilization: Double) -> String? {
        guard let pace else { return nil }
        let hint = l.paceHint(TokenFormatter.percent(store.limitDisplayPercent(pace * 100)))
        guard let tier else { return hint }
        var head = l.paceTier(tier)
        if let delta = l.paceDelta(PaceTier.roundedDelta(utilization: utilization, pace: pace)) {
            head += " · " + delta
        }
        return head + "\n" + hint
    }

    func selectedClaudeAccount(in accounts: [ClaudeAccountLimits]) -> ClaudeAccountLimits? {
        accounts.first { $0.id == nav.claudeAccountID } ?? accounts.first
    }
}

private extension ClaudeAccountLimits {
    func with(id: String) -> ClaudeAccountLimits {
        ClaudeAccountLimits(id: id, windowKeyPrefix: "claude.\(id)", fallbackTitle: "~/.\(id)", status: status,
                            isDefault: id == ClaudeAccountLimits.defaultID, isExpired: isExpired)
    }
}
