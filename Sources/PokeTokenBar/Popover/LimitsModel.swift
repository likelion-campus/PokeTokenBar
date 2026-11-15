import Foundation

// The Home page's official-limits section as plain values (stage 7, D8, P15–P28): what `PopoverView.limitsSection` and
// the private functions it calls show, top to bottom, for the selected provider. Built by `LimitsBuilder`, whose
// functions are named after the Mac's, one each; `twins.txt` pins every Mac body so a Mac change fails the parity scan
// until the twin has it too (a view body cannot be compared as text). Texts are final (app language); colours are
// roles; times that count down or up are `RelativeText` (the page formats them with `RelativeTimeText`).

/// "prefix" + the time between `date` and now (`RelativeTimeText`) + "suffix": the Mac's `Text(date, style: .relative)`
/// with what it is concatenated with.
struct RelativeText: Equatable, Sendable {
    var prefix: String
    var date: Date
    var suffix: String = ""
}

/// One quota row (`PopoverView.quotaRow`): name, optional detail, reset countdown + clock or the idle hint, the
/// percentage in the display mode and its colour, the bar (fill in the display mode, tint, pace marker) and the tooltip.
struct LimitRowModel: Equatable, Sendable {
    var name: String
    var detail: String?
    var reset: Date?
    /// " (19:26)" after the countdown (`PopoverFormat.resetClockSuffix`); set with `reset`.
    var resetClock: String?
    /// Shown instead of a reset when there is none.
    var idleHint: String?
    var percentText: String
    var percentColor: PopoverColorRole
    /// 0…100, in the display mode (`LimitProgressBar`).
    var fillPercent: Double
    var tint: PopoverColorRole
    /// 0…1 along the bar, nil without a pace.
    var paceMarker: Double?
    /// The tooltip, nil for none (`helpIfPresent`).
    var help: String?

    /// The countdown text the row shows: the relative time, then the clock.
    var resetText: RelativeText? { reset.map { RelativeText(prefix: "", date: $0, suffix: resetClock ?? "") } }
}

/// A capsule tab (`CapsuleTabBar.Item`): provider tabs and Claude account tabs.
struct CapsuleTab: Equatable, Sendable {
    var id: String
    var title: String
    var help: String?
    /// A dot before the title (the tracked Claude account).
    var marked: Bool = false
}

/// "name value [cost]" (`PopoverView.periodLabel`), and the token-type labels of the provider row (no cost).
struct PeriodPair: Equatable, Sendable {
    var name: String
    var tokens: String
    var cost: String?
}

/// What a page does when a control is used (the Mac's button actions); `HomeModel.perform` runs it.
enum HomeAction: Hashable, Sendable {
    case skipUpdate, applyUpdate
    case openPlaza
    case selectProvider(String)
    case selectClaudeAccount(String)
    /// `UsageStore.refreshLimitTokenFromKeychain()`: the user's Claude limits refresh (Windows reads the credentials file).
    case refreshClaudeLimits
    case refreshAntigravityLimits
    case openSessionKeySettings
    case refresh
    case toggleFloatingPet
    case showSettings
    /// The host ends the app (the Mac: `NSApplication.terminate`; Windows: `WindowsApp.exit`).
    case quit
}

struct NoticeButton: Equatable, Sendable {
    var label: String
    var action: HomeAction
    /// A spinner instead of the label, and disabled.
    var inProgress: Bool = false
}

/// An orange notice. `banner`: semibold title with the button on its right, orange 12 % on an 8 pt card (Claude's
/// session and session-key notices). `card`: medium-weight title, the button (if any) under the hint, orange 10 % on a
/// 6 pt card (Cursor, OpenCode Go, Grok, Antigravity).
struct NoticeModel: Equatable, Sendable {
    enum Style: Equatable, Sendable { case banner, card }
    var style: Style
    /// SF Symbol name (Task 3's glyph table maps it).
    var symbol: String
    var title: String
    var hint: String
    var button: NoticeButton?
}

/// The refresh row: "Load official limits" or "Stale · <relative>", a Refresh button, and an error under it.
struct RefreshRowModel: Equatable, Sendable {
    enum Status: Equatable, Sendable { case tapToLoad(String), stale(RelativeText) }
    var status: Status
    var button: NoticeButton
    var error: String?
}

/// The (?) next to the caption and its popover (`PopoverView.claudeKeychainHelpButton`).
struct HelpModel: Equatable, Sendable {
    var tooltip: String
    var title: String
    var body: String
    var button: NoticeButton
}

/// The 5-hour forecast line (`PopoverView.forecastRow`): orange with a warning glyph when the limit is reached before
/// the reset, tertiary with a check otherwise.
struct ForecastModel: Equatable, Sendable {
    var symbol: String
    var text: String
    var warning: Bool
    var dimmed: Bool
}

/// "Claude current 5h block  12.3K   Reset <relative> (19:26)".
struct CurrentBlockModel: Equatable, Sendable {
    var label: String
    var tokens: String
    var reset: RelativeText
    var dimmed: Bool
}

/// Codex's meta line: plan, "limit reached" (red), stale badge, on one line (`PopoverView.codexMetaRow`).
struct CodexMetaModel: Equatable, Sendable {
    var plan: String?
    var limitReached: String?
    var stale: RelativeText?
}

/// The section, top to bottom, as the Mac's body lays it out. `dimmed` = the Mac's half opacity for values from before
/// an expiry.
enum LimitsBlock: Equatable, Sendable {
    case caption(String, help: HelpModel?)
    case notice(NoticeModel)
    case refreshRow(RefreshRowModel)
    case accountTabs([CapsuleTab], selected: String?)
    case plan(String)
    case accountLabel(String)
    case accountUsage(PeriodPair, PeriodPair)
    case codexMeta(CodexMetaModel)
    case bucketLabel(String)
    case groupTitle(String, dimmed: Bool)
    case row(LimitRowModel, dimmed: Bool)
    case forecast(ForecastModel)
    case currentBlock(CurrentBlockModel)
    case stale(RelativeText)
    case message(String)
    case remainingSpend(String, dimmed: Bool)
    case products(String, dimmed: Bool)
    case unattributed(String)
}

/// The providers with an official-limits section, by provider id: the one place this provider-specific path names them
/// (extension rule: only provider-specific features branch on the id).
enum LimitsSource: String, CaseIterable, Sendable {
    case claude = "claude_code", codex, antigravity, cursor, openCode = "opencode", grok
}

/// Builds the section. Each function is the twin of the `PopoverView` function of the same name (`twins.txt` pins the
/// Mac body); `store` is the captured `HomeInput`, `now` replaces the Mac's `Date()`, the facts replace what the Mac
/// takes for granted.
struct LimitsBuilder {
    let store: HomeInput
    let l: L
    let facts: PopoverPlatformFacts
    let now: Date

    init(store: HomeInput, facts: PopoverPlatformFacts, now: Date) {
        self.store = store
        self.l = L(store.language)
        self.facts = facts
        self.now = now
    }

    private var source: LimitsSource? { selectedSnapshot.flatMap { LimitsSource(rawValue: $0.providerID) } }

    /// Twin of `PopoverView.selectedSnapshot`.
    var selectedSnapshot: ProviderSnapshot? { store.snapshot(preferring: store.providerID) }

    /// The Mac's `!store.disableKeychainAccess`: a user refresh may read the token. Without a Keychain there is no switch
    /// and the refresh reads the credentials file, so it always may.
    var keychainAllowed: Bool { !facts.hasKeychain || !store.disableKeychainAccess }

    /// Twin of `PopoverView.selectedProviderHasLimits`, with the facts: Antigravity shows only where its limits have a
    /// source, and the Keychain switch counts only where there is a Keychain.
    var selectedProviderHasLimits: Bool {
        switch source {
        case .claude: return keychainAllowed || store.limits != nil || store.limitsAuthExpired
            || !store.additionalLimits.isEmpty
        case .codex: return store.codexLimits?.hasVisibleLimit == true
        case .antigravity: return facts.antigravityLimitsAvailable
            && (keychainAllowed || store.antigravityHasTokenFile || store.antigravityLimits?.hasVisibleLimit == true
                || store.antigravityLimitsAuthExpired)
        case .cursor: return store.cursorLimits?.hasVisibleLimit == true || store.cursorLimitsAuthExpired
        case .openCode: return store.openCodeGoLimits?.hasVisibleLimit == true || store.openCodeGoLimitsAuthExpired
        case .grok: return store.grokLimits?.hasVisibleLimit == true || store.grokLimitsAuthExpired
        case nil: return false
        }
    }

    /// Twin of `PopoverView.limitsSection`: the caption, then the selected provider's blocks.
    var limitsSection: [LimitsBlock] {
        var out: [LimitsBlock] = [.caption(l.limitsOfficial,
                                           help: source == .claude && !store.sessionKeyConfigured ? claudeKeychainHelpButton : nil)]
        if source == .claude, store.limitsAuthExpiry == .sessionKey {
            out.append(.notice(sessionKeyExpiredNotice))
        } else if source == .claude, store.limitsAuthExpired {
            out.append(.notice(claudeAuthExpiredNotice))
        } else if source == .claude, keychainAllowed,
                  store.claudeLimitsMissing || store.claudeLimitsStale || store.additionalLimitsPending
                    || store.additionalLimitsStale {
            out.append(.refreshRow(claudeLimitsRefreshRow))
        }
        if source == .claude {
            out += claudeAccountsContent
        }
        if source == .codex, let codexStatus = store.codexLimits, codexStatus.hasVisibleLimit {
            let buckets = codexStatus.visibleSnapshots
            out += codexMetaRow(codexStatus)
            for bucket in buckets {
                if buckets.count > 1 { out.append(.bucketLabel(bucket.bucketDisplayName)) }
                out += codexLimitRow(name: l.codexWindow(bucket.primary?.windowDurationMins), window: bucket.primary)
                out += codexLimitRow(name: l.codexWindow(bucket.secondary?.windowDurationMins), window: bucket.secondary)
                out += codexSpendLimitRow(bucket.individualLimit)
            }
        }
        if source == .antigravity { out += antigravityLimitsContent }
        if source == .cursor { out += cursorLimitsContent }
        if source == .openCode { out += openCodeGoLimitsContent }
        if source == .grok { out += grokLimitsContent }
        return out
    }

    /// Twin of `PopoverView.cursorLimitsContent`.
    var cursorLimitsContent: [LimitsBlock] {
        var out: [LimitsBlock] = []
        if store.cursorLimitsAuthExpired { out.append(.notice(cursorAuthExpiredNotice)) }
        guard let status = store.cursorLimits, status.hasVisibleLimit else { return out }
        if store.cursorLimitsStale { out += staleBadge(updatedAt: store.cursorLimitsUpdatedAt) }
        if let message = status.displayMessage, !message.isEmpty { out.append(.message(message)) }
        let dimmed = store.cursorLimitsAuthExpired
        if let usage = status.planUsage, let used = usage.usedPercent {
            out.append(.row(cursorLimitRow(name: l.cursorMonthlyIncluded, utilization: used, reset: status.billingCycleEndDate),
                            dimmed: dimmed))
            if let remaining = usage.remainingDollars {
                out.append(.remainingSpend(l.cursorRemainingSpend(TokenFormatter.cost(remaining)), dimmed: dimmed))
            }
        }
        if let auto = status.planUsage?.autoPercentUsed {
            out.append(.row(cursorLimitRow(name: l.cursorAutoUsage, utilization: auto, reset: nil), dimmed: dimmed))
        }
        if let api = status.planUsage?.apiPercentUsed {
            out.append(.row(cursorLimitRow(name: l.cursorApiUsage, utilization: api, reset: nil), dimmed: dimmed))
        }
        return out
    }

    /// Twin of `PopoverView.cursorLimitRow`: the billing cycle has no fixed span, so no pace marker.
    func cursorLimitRow(name: String, utilization: Double, reset: Date?) -> LimitRowModel {
        quotaRow(name: name, utilization: utilization, reset: reset)
    }

    /// Twin of `PopoverView.openCodeGoLimitsContent`.
    var openCodeGoLimitsContent: [LimitsBlock] {
        var out: [LimitsBlock] = []
        if store.openCodeGoLimitsAuthExpired {
            out.append(.notice(authExpiredNotice(title: l.openCodeGoAuthExpiredTitle, hint: l.openCodeGoAuthExpiredHint)))
        }
        guard let status = store.openCodeGoLimits, status.hasVisibleLimit else { return out }
        if store.openCodeGoLimitsStale { out += staleBadge(updatedAt: store.openCodeGoLimitsUpdatedAt) }
        let dimmed = store.openCodeGoLimitsAuthExpired
        let rows = [
            openCodeGoLimitRow(name: l.fiveHourSession, window: status.rolling, span: LimitWindowSpan.fiveHour,
                               notStartedHint: l.fiveHourNotStarted),
            openCodeGoLimitRow(name: l.weekly, window: status.weekly, span: LimitWindowSpan.sevenDay),
            openCodeGoLimitRow(name: l.openCodeGoMonthly, window: status.monthly, span: nil),
        ]
        return out + rows.compactMap { $0.map { .row($0, dimmed: dimmed) } }
    }

    /// Twin of `PopoverView.openCodeGoLimitRow`: an ended window counts 0 and shows the idle hint.
    func openCodeGoLimitRow(name: String, window: OpenCodeGoWindow?, span: TimeInterval?,
                            notStartedHint: String? = nil) -> LimitRowModel? {
        guard let window, let utilization = window.utilization(now: now) else { return nil }
        return quotaRow(name: name, utilization: utilization, reset: window.activeReset(now: now), span: span,
                        idleHint: window.hasEnded(now: now) ? notStartedHint : nil)
    }

    /// Twin of `PopoverView.grokLimitsContent`.
    var grokLimitsContent: [LimitsBlock] {
        var out: [LimitsBlock] = []
        if store.grokLimitsAuthExpired {
            out.append(.notice(authExpiredNotice(title: l.grokAuthExpiredTitle, hint: l.grokAuthExpiredHint)))
        }
        guard let status = store.grokLimits, status.hasVisibleLimit else { return out }
        if store.grokLimitsStale { out += staleBadge(updatedAt: store.grokLimitsUpdatedAt) }
        let dimmed = store.grokLimitsAuthExpired
        if let utilization = status.utilization(now: now) {
            out.append(.row(quotaRow(name: l.grokCreditPeriod(weekly: status.isWeekly, monthly: status.isMonthly),
                                     utilization: utilization, reset: status.activeReset(now: now), span: status.periodSpan),
                            dimmed: dimmed))
        }
        let products = status.usedProducts(now: now)
        if !products.isEmpty {
            out.append(.products(products.map {
                "\(PopoverFormat.grokProductName($0.product)) \(TokenFormatter.percent($0.usagePercent ?? 0))"
            }.joined(separator: " · "), dimmed: dimmed))
        }
        return out
    }

    /// Twin of both `PopoverView.authExpiredNotice` functions; this one is `(title:hint:)`, the plain card.
    func authExpiredNotice(title: String, hint: String) -> NoticeModel {
        NoticeModel(style: .card, symbol: "exclamationmark.triangle.fill", title: title, hint: hint, button: nil)
    }

    /// Twin of `PopoverView.cursorAuthExpiredNotice`.
    var cursorAuthExpiredNotice: NoticeModel {
        authExpiredNotice(title: l.cursorAuthExpiredTitle, hint: l.cursorAuthExpiredHint)
    }

    /// Twin of `PopoverView.antigravityLimitsContent` (shown only where the facts give Antigravity a source).
    var antigravityLimitsContent: [LimitsBlock] {
        var out: [LimitsBlock] = []
        if store.antigravityLimitsAuthExpired {
            out.append(.notice(antigravityAuthExpiredNotice))
        } else if keychainAllowed && (store.antigravityLimits == nil || store.antigravityLimitsStale) {
            out.append(.refreshRow(antigravityRefreshRow))
        }
        guard let status = store.antigravityLimits, status.hasVisibleLimit else { return out }
        let dimmed = store.antigravityLimitsAuthExpired
        for group in status.groups {
            out.append(.groupTitle(l.antigravityGroupTitle(group.displayName), dimmed: dimmed))
            for bucket in group.buckets { out.append(.row(antigravityBucketRow(bucket), dimmed: dimmed)) }
        }
        return out
    }

    /// Twin of `PopoverView.antigravityBucketRow`.
    func antigravityBucketRow(_ bucket: AntigravityQuotaBucket) -> LimitRowModel {
        quotaRow(name: l.antigravityWindow(window: bucket.window, bucketId: bucket.bucketId),
                 utilization: bucket.usedPercent, reset: bucket.resetDate, span: bucket.windowSpan)
    }

    /// Twin of `PopoverView.antigravityRefreshRow` (no error line on the Mac).
    var antigravityRefreshRow: RefreshRowModel {
        RefreshRowModel(
            status: store.antigravityLimits == nil
                ? .tapToLoad(l.limitsTapToLoad)
                : .stale(RelativeText(prefix: l.staleLimits + " · ", date: store.antigravityLimitsUpdatedAt ?? now)),
            button: NoticeButton(label: l.refresh, action: .refreshAntigravityLimits,
                                 inProgress: store.isRefreshingAntigravityLimits),
            error: nil)
    }

    /// Twin of `PopoverView.antigravityAuthExpiredNotice`: the card with Retry under the hint (no spinner on the Mac).
    var antigravityAuthExpiredNotice: NoticeModel {
        NoticeModel(style: .card, symbol: "exclamationmark.triangle.fill", title: l.antigravityAuthExpiredTitle,
                    hint: l.antigravityAuthExpiredHint, button: NoticeButton(label: l.retry, action: .refreshAntigravityLimits))
    }

    /// Twin of `PopoverView.limitRow`: a window with a utilization; the idle hint only before it started.
    func limitRow(name: String, window: LimitWindow?, span: TimeInterval?, notStartedHint: String? = nil) -> LimitRowModel? {
        guard let window, let utilization = window.utilization else { return nil }
        return quotaRow(name: name, utilization: utilization, reset: window.resetDate, span: span,
                        idleHint: window.hasNotStarted ? notStartedHint : nil)
    }

    /// Twin of `PopoverView.quotaRow` (with `resetLabel`, `helpIfPresent` and `LimitProgressBar.body`): the tier colour
    /// from the pace when there is one, else the absolute thresholds (`PaceTier.gauge`, the menu bar's rule).
    func quotaRow(name: String, utilization: Double, reset: Date?, span: TimeInterval? = nil, detail: String? = nil,
                  idleHint: String? = nil) -> LimitRowModel {
        let pace = PopoverFormat.paceFraction(reset: reset, span: span, now: now)
        let tier = PaceTier.tier(utilization: utilization, pace: pace, critThreshold: store.critThreshold)
        let gauge = PaceTier.gauge(utilization: utilization, pace: pace,
                                   warnThreshold: store.warnThreshold, critThreshold: store.critThreshold)
        return LimitRowModel(
            name: name, detail: detail,
            reset: reset, resetClock: reset.map(resetClockSuffix),
            idleHint: reset == nil ? idleHint : nil,
            percentText: PopoverFormat.limitPercentText(utilization, mode: store.limitDisplayMode, l: l),
            percentColor: PopoverFormat.percentColor(gauge),
            fillPercent: min(100, max(0, store.limitDisplayPercent(utilization))),
            tint: PopoverFormat.paceColor(gauge),
            paceMarker: PopoverFormat.markerFraction(pace: pace, mode: store.limitDisplayMode),
            help: PopoverFormat.paceHelp(pace: pace, tier: tier, utilization: utilization, mode: store.limitDisplayMode, l: l))
    }

    /// `PopoverView.resetClockSuffix` in the app language, the facts' calendar, at `now`.
    func resetClockSuffix(_ reset: Date) -> String {
        PopoverFormat.resetClockSuffix(reset, now: now, language: store.language, calendar: facts.regionCalendar)
    }

    /// Twin of `PopoverView.codexMetaRow`: the plan is the account's (top level), whatever the bucket filter.
    func codexMetaRow(_ status: CodexRateLimitStatus) -> [LimitsBlock] {
        let planType = status.rateLimits.planType ?? status.visibleSnapshots.first?.planType
        let reached = status.visibleSnapshots.contains { $0.rateLimitReachedType != nil }
        guard planType != nil || reached || store.codexLimitsStale else { return [] }
        return [.codexMeta(CodexMetaModel(
            plan: planType.map { l.plan($0) },
            limitReached: reached ? l.limitReached : nil,
            stale: store.codexLimitsStale ? staleText(store.codexLimitsUpdatedAt) : nil))]
    }

    /// Twin of `PopoverView.sessionKeyExpiredNotice`: a dead session key is fixed in Settings, not by a retry.
    var sessionKeyExpiredNotice: NoticeModel {
        NoticeModel(style: .banner, symbol: "key.slash.fill", title: l.sessionKeyExpiredTitle,
                    hint: l.sessionKeyExpiredNoticeHint,
                    button: NoticeButton(label: l.settings, action: .openSessionKeySettings))
    }

    /// Twin of `PopoverView.claudeAuthExpiredNotice`.
    var claudeAuthExpiredNotice: NoticeModel { authExpiredNotice(hint: l.claudeAuthExpiredHint) }

    /// Twin of both `PopoverView.authExpiredNotice` functions; this one is `(hint:)`, the banner with Retry: the default
    /// account above the tabs, an additional account inside its tab.
    func authExpiredNotice(hint: String) -> NoticeModel {
        NoticeModel(style: .banner, symbol: "exclamationmark.triangle.fill", title: l.claudeAuthExpiredTitle, hint: hint,
                    button: NoticeButton(label: l.retry, action: .refreshClaudeLimits,
                                         inProgress: store.isRefreshingLimitToken))
    }

    /// Twin of `PopoverView.claudeKeychainHelpButton`. Its words explain the Mac Keychain, so it shows only where there
    /// is one; the Windows wording (a credentials-file note, D13) comes with Task 5 / 14.
    var claudeKeychainHelpButton: HelpModel? {
        guard facts.hasKeychain else { return nil }
        return HelpModel(tooltip: l.claudeKeychainHelpTooltip, title: l.claudeKeychainHelpTitle,
                         body: l.claudeKeychainHelpBody,
                         button: NoticeButton(label: l.registerSessionKey, action: .openSessionKeySettings))
    }

    /// Twin of `PopoverView.claudeAccountsContent`: one tab per account when there are several (default login first).
    var claudeAccountsContent: [LimitsBlock] {
        var out: [LimitsBlock] = []
        let accounts = store.claudeAccounts
        if accounts.count > 1 {
            let trackedID = store.trackedClaudeAccountID
            out.append(.accountTabs(accounts.map {
                CapsuleTab(id: $0.id, title: $0.title, help: $0.status.accountDisplay, marked: $0.id == trackedID)
            }, selected: selectedClaudeAccount(in: accounts)?.id))
        }
        if let account = selectedClaudeAccount(in: accounts) {
            out += claudeAccountLimits(account, showsUsage: accounts.count > 1)
        }
        // Tab totals do not add up to the header when some sessions belong to no login's history.
        if accounts.count > 1, store.unattributedClaudeUsage.monthTokens > 0 {
            out.append(.unattributed(l.unattributedClaudeUsage(TokenFormatter.compact(store.unattributedClaudeUsage.monthTokens))))
        }
        return out
    }

    /// Twin of `PopoverView.selectedClaudeAccount(in:)`.
    func selectedClaudeAccount(in accounts: [ClaudeAccountLimits]) -> ClaudeAccountLimits? {
        accounts.first { $0.id == store.claudeAccountID } ?? accounts.first
    }

    /// Twin of `PopoverView.claudeAccountLimits(_:showsUsage:)`.
    func claudeAccountLimits(_ account: ClaudeAccountLimits, showsUsage: Bool) -> [LimitsBlock] {
        var out: [LimitsBlock] = []
        let limits = account.status
        if account.isExpired, !account.isDefault {
            // A dead session key is fixed in Settings; the retry banner would only read the token again.
            out.append(.notice(account.sessionKeyExpired
                ? sessionKeyExpiredNotice : authExpiredNotice(hint: l.additionalAccountExpiredHint(account.fallbackTitle))))
        } else if !account.isDefault, account.isStale(now: now) {
            // The default account's stale label lives in the refresh row above the tabs.
            out += staleBadge(updatedAt: account.updatedAt)
        }
        if let plan = limits.planDisplay { out.append(.plan(l.plan(plan))) }
        if let accountLabel = limits.accountDisplay { out.append(.accountLabel(l.limitsAccount(accountLabel))) }
        if showsUsage, let usage = store.claudeAccountUsage[account.id], !usage.isEmpty {
            out.append(.accountUsage(
                HomeModel.periodLabel(l.today, tokens: usage.todayTokens, cost: store.showsCost ? usage.todayCost : nil, l: l),
                HomeModel.periodLabel(l.thisMonth, tokens: usage.monthTokens, cost: store.showsCost ? usage.monthCost : nil, l: l)))
        }
        // Values from before an expiry are dimmed: "not the current value".
        let dimmed = account.isExpired
        func row(_ model: LimitRowModel?) { if let model { out.append(.row(model, dimmed: dimmed)) } }
        row(limitRow(name: l.fiveHourSession, window: limits.fiveHour, span: LimitWindowSpan.fiveHour,
                     notStartedHint: l.fiveHourNotStarted))
        // The forecast follows the tracked account (it combines that account's utilization with local usage).
        if account.id == store.trackedClaudeAccountID, let forecast = forecastRow(dimmed: dimmed) { out.append(.forecast(forecast)) }
        row(limitRow(name: l.weekly, window: limits.sevenDay, span: LimitWindowSpan.sevenDay))
        row(limitRow(name: l.weeklyOpus, window: limits.sevenDayOpus, span: LimitWindowSpan.sevenDay))
        row(limitRow(name: l.weeklySonnet, window: limits.sevenDaySonnet, span: LimitWindowSpan.sevenDay))
        for entry in limits.scopedLimitEntries {
            row(limitRow(name: l.claudeLimitEntry(kind: entry.kind, model: entry.scope?.model?.displayName),
                         window: LimitWindow(utilization: entry.percent, resetsAt: entry.resetsAt),
                         span: entry.windowSpan))
        }
        if let block = store.claudeCurrentBlock(for: account), let end = block.endDate {
            out.append(.currentBlock(CurrentBlockModel(
                label: l.claudeCurrentBlock, tokens: TokenFormatter.compact(block.totalTokens),
                reset: RelativeText(prefix: "\(l.reset) ", date: end, suffix: resetClockSuffix(end)), dimmed: dimmed)))
        }
        return out
    }

    /// Twin of `PopoverView.claudeLimitsRefreshRow`: the user's one-tap refresh (automatic polls never read the token).
    var claudeLimitsRefreshRow: RefreshRowModel {
        RefreshRowModel(
            // The row also shows for another account's pending refresh: only call the values stale when the default
            // account's own values are.
            status: store.limits != nil && store.claudeLimitsStale
                ? .stale(RelativeText(prefix: l.staleLimits + " · ", date: store.limitsUpdatedAt ?? now))
                : .tapToLoad(l.limitsTapToLoad),
            button: NoticeButton(label: l.refresh, action: .refreshClaudeLimits, inProgress: store.isRefreshingLimitToken),
            error: store.isRefreshingLimitToken ? nil : store.limitTokenRefreshMessage)
    }

    /// Twin of `PopoverView.staleBadge(updatedAt:)`: nothing without a date.
    func staleBadge(updatedAt: Date?) -> [LimitsBlock] {
        staleText(updatedAt).map { [.stale($0)] } ?? []
    }

    private func staleText(_ updatedAt: Date?) -> RelativeText? {
        updatedAt.map { RelativeText(prefix: l.staleLimits + " · ", date: $0) }
    }

    /// Twin of `PopoverView.codexLimitRow`.
    func codexLimitRow(name: String, window: CodexRateLimitWindow?) -> [LimitsBlock] {
        guard let window else { return [] }
        return [.row(quotaRow(name: name, utilization: Double(window.usedPercent), reset: window.resetDate,
                              span: window.windowSpan), dimmed: false)]
    }

    /// Twin of `PopoverView.codexSpendLimitRow`: no window length, so no pace marker.
    func codexSpendLimitRow(_ limit: CodexSpendControlLimit?) -> [LimitsBlock] {
        guard let limit else { return [] }
        return [.row(quotaRow(name: l.personalSpendLimit, utilization: Double(limit.usedPercent),
                              reset: limit.resetDate, detail: "\(limit.used) / \(limit.limit)"), dimmed: false)]
    }

    /// Twin of `PopoverView.forecastRow`: the 5-hour limit's depletion time at the current burn rate.
    func forecastRow(dimmed: Bool) -> ForecastModel? {
        guard let forecast = store.fiveHourForecast else { return nil }
        return ForecastModel(
            symbol: forecast.beforeReset ? "exclamationmark.triangle.fill" : "checkmark.circle",
            text: forecast.beforeReset
                ? l.forecastReach(PopoverFormat.forecastTime(forecast.depletionDate, locale: facts.regionLocale,
                                                             timeZone: facts.regionCalendar.timeZone))
                : l.forecastNoReach,
            warning: forecast.beforeReset, dimmed: dimmed)
    }
}
