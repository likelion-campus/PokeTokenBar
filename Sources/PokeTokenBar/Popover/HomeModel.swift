import Foundation

/// What the Home page reads from the stores, captured once per build (stage 7, D8, D10). Field and member names are the
/// stores' own, so the model code reads like the Mac view's; the computed members the Mac calls with an argument are
/// captured for every value the page can ask for (`providerStatus(for:)` per snapshot, `claudeCurrentBlock(for:)` per
/// account). Built on the main actor inside the page's observation tracking, it registers every store member the Home
/// page depends on; the model itself is then a plain value.
struct HomeInput: Sendable {
    // UsageStore
    var snapshots: [ProviderSnapshot] = []
    var todayTotalTokens = 0
    var showsCost = false
    var todayUsageCost = UsageCost()
    var weekTotalTokens = 0
    var weekUsageCost = UsageCost()
    var monthTotalTokens = 0
    var monthUsageCost = UsageCost()
    var providerStatuses: [String: ProviderStatus] = [:]
    var updateNotificationsEnabled = true
    var limitDisplayMode: UsageStore.LimitDisplayMode = .used
    var warnThreshold: Double = 80
    var critThreshold: Double = 95
    var disableKeychainAccess = false
    var sessionKeyConfigured = false
    var limits: LimitStatus?
    var limitsUpdatedAt: Date?
    var limitsAuthExpiry: UsageStore.LimitsAuthExpiry?
    var additionalLimits: [AdditionalClaudeLimits] = []
    var additionalLimitsPending = false
    var additionalLimitsStale = false
    var claudeLimitsMissing = false
    var claudeLimitsStale = false
    var isRefreshingLimitToken = false
    var limitTokenRefreshMessage: String?
    var claudeAccounts: [ClaudeAccountLimits] = []
    var trackedClaudeAccountID: String?
    var claudeAccountUsage: [String: ClaudeAccountUsage] = [:]
    var unattributedClaudeUsage = ClaudeAccountUsage()
    var claudeCurrentBlocks: [String: BlockUsage] = [:]
    var fiveHourForecast: UsageStore.FiveHourForecast?
    var codexLimits: CodexRateLimitStatus?
    var codexLimitsStale = false
    var codexLimitsUpdatedAt: Date?
    var antigravityLimits: AntigravityRateLimitStatus?
    var antigravityLimitsAuthExpired = false
    var antigravityHasTokenFile = false
    var antigravityLimitsStale = false
    var antigravityLimitsUpdatedAt: Date?
    var isRefreshingAntigravityLimits = false
    var cursorLimits: CursorRateLimitStatus?
    var cursorLimitsAuthExpired = false
    var cursorLimitsStale = false
    var cursorLimitsUpdatedAt: Date?
    var openCodeGoLimits: OpenCodeGoRateLimitStatus?
    var openCodeGoLimitsAuthExpired = false
    var openCodeGoLimitsStale = false
    var openCodeGoLimitsUpdatedAt: Date?
    var grokLimits: GrokCreditStatus?
    var grokLimitsAuthExpired = false
    var grokLimitsStale = false
    var grokLimitsUpdatedAt: Date?
    var lastUpdated: Date?
    var lastErrorDescription: String?
    /// `UsageStore.lastErrorMessage(_:)` in the app language.
    var lastErrorMessage: String?
    var floatingPetEnabled = false
    // CompanionStore
    var language: AppLanguage = .en
    // UpdateChecker
    var updateAvailable: UpdateChecker.Available?
    var isUpdating = false
    var currentVersion = ""
    // TeamSettings, TeamFeedStore (nil feed: no unread count)
    var teamReady = false
    var unreadCount: Int?
    // PopoverState
    var tab: PopoverState.Tab = .home
    var providerID: String?
    var claudeAccountID: String?

    init() {}

    @MainActor
    init(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings, feed: TeamFeedStore?,
         state: PopoverState) {
        language = companion.language
        snapshots = store.snapshots
        todayTotalTokens = store.todayTotalTokens
        showsCost = store.showsCost
        todayUsageCost = store.todayUsageCost
        weekTotalTokens = store.weekTotalTokens
        weekUsageCost = store.weekUsageCost
        monthTotalTokens = store.monthTotalTokens
        monthUsageCost = store.monthUsageCost
        for snapshot in store.snapshots {
            if let status = store.providerStatus(for: snapshot.providerID) { providerStatuses[snapshot.providerID] = status }
        }
        updateNotificationsEnabled = store.updateNotificationsEnabled
        limitDisplayMode = store.limitDisplayMode
        warnThreshold = store.warnThreshold
        critThreshold = store.critThreshold
        disableKeychainAccess = store.disableKeychainAccess
        sessionKeyConfigured = store.sessionKeyConfigured
        limits = store.limits
        limitsUpdatedAt = store.limitsUpdatedAt
        limitsAuthExpiry = store.limitsAuthExpiry
        additionalLimits = store.additionalLimits
        additionalLimitsPending = store.additionalLimitsPending
        additionalLimitsStale = store.additionalLimitsStale
        claudeLimitsMissing = store.claudeLimitsMissing
        claudeLimitsStale = store.claudeLimitsStale
        isRefreshingLimitToken = store.isRefreshingLimitToken
        limitTokenRefreshMessage = store.limitTokenRefreshMessage
        claudeAccounts = store.claudeAccounts
        trackedClaudeAccountID = store.trackedClaudeAccount?.id
        claudeAccountUsage = store.claudeAccountUsage
        unattributedClaudeUsage = store.unattributedClaudeUsage
        for account in claudeAccounts where claudeCurrentBlocks[account.id] == nil {
            if let block = store.claudeCurrentBlock(for: account) { claudeCurrentBlocks[account.id] = block }
        }
        fiveHourForecast = store.fiveHourForecast
        codexLimits = store.codexLimits
        codexLimitsStale = store.codexLimitsStale
        codexLimitsUpdatedAt = store.codexLimitsUpdatedAt
        antigravityLimits = store.antigravityLimits
        antigravityLimitsAuthExpired = store.antigravityLimitsAuthExpired
        antigravityHasTokenFile = store.antigravityHasTokenFile
        antigravityLimitsStale = store.antigravityLimitsStale
        antigravityLimitsUpdatedAt = store.antigravityLimitsUpdatedAt
        isRefreshingAntigravityLimits = store.isRefreshingAntigravityLimits
        cursorLimits = store.cursorLimits
        cursorLimitsAuthExpired = store.cursorLimitsAuthExpired
        cursorLimitsStale = store.cursorLimitsStale
        cursorLimitsUpdatedAt = store.cursorLimitsUpdatedAt
        openCodeGoLimits = store.openCodeGoLimits
        openCodeGoLimitsAuthExpired = store.openCodeGoLimitsAuthExpired
        openCodeGoLimitsStale = store.openCodeGoLimitsStale
        openCodeGoLimitsUpdatedAt = store.openCodeGoLimitsUpdatedAt
        grokLimits = store.grokLimits
        grokLimitsAuthExpired = store.grokLimitsAuthExpired
        grokLimitsStale = store.grokLimitsStale
        grokLimitsUpdatedAt = store.grokLimitsUpdatedAt
        lastUpdated = store.lastUpdated
        lastErrorDescription = store.lastErrorDescription
        lastErrorMessage = store.lastErrorMessage(companion.l)
        floatingPetEnabled = store.floatingPetEnabled
        updateAvailable = updater?.available
        isUpdating = updater?.isUpdating ?? false
        currentVersion = updater?.currentVersion ?? ""
        teamReady = team.isReady
        unreadCount = feed?.unreadCount
        tab = state.tab
        providerID = state.providerID
        claudeAccountID = state.claudeAccountID
    }

    var limitsAuthExpired: Bool { limitsAuthExpiry != nil }

    /// `UsageStore.snapshot(preferring:)`: the preferred provider while it has a snapshot, else the first.
    func snapshot(preferring id: String?) -> ProviderSnapshot? {
        if let id, let s = snapshots.first(where: { $0.providerID == id }) { return s }
        return snapshots.first
    }

    /// `UsageStore.limitDisplayPercent(_:)`.
    func limitDisplayPercent(_ utilization: Double) -> Double {
        UsageStore.displayPercent(utilization, mode: limitDisplayMode)
    }

    /// `UsageStore.providerStatus(for:)` (nil while status checks are off).
    func providerStatus(for providerID: String) -> ProviderStatus? { providerStatuses[providerID] }

    /// `UsageStore.claudeCurrentBlock(for:)`.
    func claudeCurrentBlock(for account: ClaudeAccountLimits) -> BlockUsage? { claudeCurrentBlocks[account.id] }
}

/// "vX available (current vY)", then Skip and Update, or "Updating…" with a spinner.
struct UpdateBannerModel: Equatable, Sendable {
    var text: String
    var isUpdating: Bool
    var updatingLabel: String
    var skipButton: NoticeButton
    var updateButton: NoticeButton
}

/// The map glyph that opens the plaza (team ready only), with a red dot while the board has unread posts.
struct PlazaButtonModel: Equatable, Sendable {
    var symbol: String
    var label: String
    var unreadDot: Bool
    var action: HomeAction
}

/// Today's caption and total (28 pt bold), the grouped digits from 1,000, today's cost, and the week and month totals.
struct HeaderModel: Equatable, Sendable {
    var caption: String
    var total: String
    var grouped: String?
    var cost: String?
    var week: PeriodPair
    var month: PeriodPair
}

/// The selected provider's row: name, today's tokens and cost, the four token types, and the per-model lines (more
/// than one model; biggest first, the last path part of the name, truncated in the middle by the page).
struct ProviderRowModel: Equatable, Sendable {
    struct ModelLine: Equatable, Sendable {
        var name: String
        var tokens: String
    }
    var name: String
    var tokens: String
    var cost: String?
    var input: PeriodPair
    var output: PeriodPair
    var cacheWrite: PeriodPair
    var cacheRead: PeriodPair
    var models: [ModelLine]
}

/// The selected provider's incident: a coloured dot, the indicator's label and the description.
struct StatusBannerModel: Equatable, Sendable {
    var dot: PopoverColorRole
    var label: String
    var description: String?
}

/// The footer: Refresh, "Updated <relative>" and the error triangle (Home only), the floating pet's eye (where it
/// exists), Settings and Quit.
struct FooterModel: Equatable, Sendable {
    struct Usage: Equatable, Sendable {
        var refreshHelp: String
        var updated: RelativeText?
        /// The triangle's tooltip; nil = no triangle.
        var error: String?
    }
    struct PetToggle: Equatable, Sendable {
        var symbol: String
        var label: String
    }
    var usage: Usage?
    var petToggle: PetToggle?
    var settingsHelp: String
    var quitHelp: String
}

/// The Home page above and below the companion header (P1, P3, P5, P6, P12–P24, P26–P29), as plain values. The page
/// rebuilds it when an observed store member changes and applies what differs (D10).
struct HomeModel: Equatable, Sendable {
    var updateBanner: UpdateBannerModel?
    var plazaButton: PlazaButtonModel?
    var header: HeaderModel
    /// Empty with one provider or none.
    var providerTabs: [CapsuleTab]
    /// The tab shown as selected: the chosen provider while it has a snapshot, else the first.
    var selectedProviderID: String?
    var providerRow: ProviderRowModel?
    var statusBanner: StatusBannerModel?
    /// nil: no limits section for the selected provider (`selectedProviderHasLimits`).
    var limits: [LimitsBlock]?
    var footer: FooterModel

    @MainActor
    static func make(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings,
                     feed: TeamFeedStore?, state: PopoverState, facts: PopoverPlatformFacts, now: Date) -> HomeModel {
        make(input: HomeInput(store: store, companion: companion, updater: updater, team: team, feed: feed, state: state),
             facts: facts, now: now)
    }

    static func make(input: HomeInput, facts: PopoverPlatformFacts, now: Date) -> HomeModel {
        let home = HomeBuilder(store: input, facts: facts)
        let limits = LimitsBuilder(store: input, facts: facts, now: now)
        return HomeModel(updateBanner: home.updateBanner, plazaButton: home.plazaButton, header: home.header,
                         providerTabs: home.providerTabBar, selectedProviderID: home.selectedProviderID,
                         providerRow: home.providerRow,
                         statusBanner: home.providerStatusBanner,
                         limits: limits.selectedProviderHasLimits ? limits.limitsSection : nil, footer: home.footer)
    }

    /// Twin of `PopoverView.periodLabel(_:tokens:cost:)`.
    static func periodLabel(_ name: String, tokens: Int, cost: UsageCost?, l: L) -> PeriodPair {
        PeriodPair(name: name, tokens: TokenFormatter.compact(tokens), cost: cost.map { $0.text(l) })
    }

    /// What each Home control does (the Mac's button actions). `quit` is the host's (`NSApplication.terminate` on the
    /// Mac, `WindowsApp.exit` on Windows).
    @MainActor
    static func perform(_ action: HomeAction, store: UsageStore, updater: UpdateChecker?, state: PopoverState,
                        quit: () -> Void) {
        switch action {
        case .skipUpdate: updater?.skipCurrent()
        case .applyUpdate: updater?.applyUpdate()
        case .openPlaza: state.onOpenPlaza?()
        case .selectProvider(let id): state.providerID = id
        case .selectClaudeAccount(let id): state.claudeAccountID = id
        case .refreshClaudeLimits: Task { await store.refreshLimitTokenFromKeychain() }
        case .refreshAntigravityLimits: Task { await store.refreshAntigravityLimitsFromKeychain() }
        case .openSessionKeySettings: state.openSessionKeySettings()
        case .refresh: Task { await store.refresh() }
        case .toggleFloatingPet: store.floatingPetEnabled.toggle()
        case .showSettings: state.showSettings = true
        case .quit: quit()
        }
    }
}

/// Builds the Home blocks outside the limits section. Each member is the twin of the `PopoverView` member of the same
/// name (`twins.txt` pins the Mac body).
struct HomeBuilder {
    let store: HomeInput
    let l: L
    let facts: PopoverPlatformFacts

    init(store: HomeInput, facts: PopoverPlatformFacts) {
        self.store = store
        self.l = L(store.language)
        self.facts = facts
    }

    /// Twin of `PopoverView.updateBanner`: only with update notifications on.
    var updateBanner: UpdateBannerModel? {
        guard let update = store.updateAvailable, store.updateNotificationsEnabled else { return nil }
        return UpdateBannerModel(text: l.updateAvailable(update.version, current: store.currentVersion),
                                 isUpdating: store.isUpdating, updatingLabel: l.updating,
                                 skipButton: NoticeButton(label: l.skipThisVersion, action: .skipUpdate),
                                 updateButton: NoticeButton(label: l.updateButton, action: .applyUpdate))
    }

    /// Twin of the plaza button in `PopoverView.mainContent`: team ready only; the dot while the board has unread posts.
    var plazaButton: PlazaButtonModel? {
        guard store.teamReady else { return nil }
        return PlazaButtonModel(symbol: "map", label: l.plazaOpen, unreadDot: (store.unreadCount ?? 0) > 0, action: .openPlaza)
    }

    /// Twin of `PopoverView.header` (with `periodTotals` and `periodLabels`): grouped digits from 1,000 in the region's
    /// grouping; the costs only while a provider reports cost.
    var header: HeaderModel {
        HeaderModel(caption: l.todayTokens, total: TokenFormatter.compact(store.todayTotalTokens),
                    grouped: store.todayTotalTokens >= 1_000
                        ? TokenFormatter.grouped(store.todayTotalTokens, locale: facts.regionLocale) : nil,
                    cost: store.showsCost ? store.todayUsageCost.text(l) : nil,
                    week: HomeModel.periodLabel(l.thisWeek, tokens: store.weekTotalTokens,
                                                cost: store.showsCost ? store.weekUsageCost : nil, l: l),
                    month: HomeModel.periodLabel(l.thisMonth, tokens: store.monthTotalTokens,
                                                 cost: store.showsCost ? store.monthUsageCost : nil, l: l))
    }

    /// Twin of `PopoverView.selectedSnapshot`: the chosen tab, or the first when it has gone.
    var selectedSnapshot: ProviderSnapshot? { store.snapshot(preferring: store.providerID) }

    /// Twin of `PopoverView.providerTabBar` (`ProviderTabBar`): tabs only with more than one provider.
    var providerTabBar: [CapsuleTab] {
        guard store.snapshots.count > 1 else { return [] }
        return store.snapshots.map { CapsuleTab(id: $0.providerID, title: $0.displayName) }
    }

    /// The selected tab's id (`ProviderTabBar.selectedID`).
    var selectedProviderID: String? { selectedSnapshot?.providerID }

    /// Twin of `PopoverView.providerRow(snapshot:today:)` and `tokenTypeLabel`.
    var providerRow: ProviderRowModel? {
        guard let snapshot = selectedSnapshot, let today = snapshot.today else { return nil }
        func label(_ name: String, _ value: Int) -> PeriodPair { PeriodPair(name: name, tokens: TokenFormatter.compact(value)) }
        var models: [ProviderRowModel.ModelLine] = []
        if let byModel = today.models, byModel.count > 1 {
            // Biggest first; equal ones by name (the Mac leaves their order to the dictionary).
            models = byModel.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { model, tokens in
                ProviderRowModel.ModelLine(name: model.split(separator: "/").last.map(String.init) ?? model,
                                           tokens: TokenFormatter.compact(tokens))
            }
        }
        return ProviderRowModel(name: snapshot.displayName, tokens: TokenFormatter.compact(today.totalTokens),
                                cost: snapshot.reportsCost ? today.usageCost.text(l) : nil,
                                input: label(l.tokenInput, today.inputTokens), output: label(l.tokenOutput, today.outputTokens),
                                cacheWrite: label(l.tokenCacheWrite, today.cacheCreationTokens),
                                cacheRead: label(l.tokenCacheRead, today.cacheReadTokens), models: models)
    }

    /// Twin of `PopoverView.providerStatusBanner`: only with an incident on the selected provider.
    var providerStatusBanner: StatusBannerModel? {
        guard let id = selectedSnapshot?.providerID, let status = store.providerStatus(for: id), status.indicator.hasIssue
        else { return nil }
        return StatusBannerModel(dot: PopoverFormat.statusColor(status.indicator), label: l.providerStatusLabel(status.indicator),
                                 description: status.description.isEmpty ? nil : status.description)
    }

    /// Twin of `PopoverView.footer`: the usage controls on Home only; the eye only where the floating pet exists.
    var footer: FooterModel {
        FooterModel(
            usage: store.tab == .home
                ? FooterModel.Usage(refreshHelp: l.refreshNow,
                                    updated: store.lastUpdated.map { RelativeText(prefix: "\(l.updated) ", date: $0) },
                                    error: store.lastErrorDescription != nil ? (store.lastErrorMessage ?? "") : nil)
                : nil,
            petToggle: facts.floatingPetAvailable
                ? FooterModel.PetToggle(symbol: store.floatingPetEnabled ? "eye" : "eye.slash",
                                        label: store.floatingPetEnabled ? l.floatingPetHideLabel : l.floatingPetEnableLabel)
                : nil,
            settingsHelp: l.settings, quitHelp: l.quit)
    }
}
