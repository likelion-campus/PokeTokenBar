#if os(Windows)
import Foundation
import Observation
import WinSDK

/// The Settings page of the popover (stage 7 Task 6): the Mac's `SettingsView` for what a Windows user needs on day one —
/// language, refresh interval, limit display, launch at login, back view, the Claude credential help, tracked providers,
/// the team (join with a code, nickname, on and off, copy the code), notifications, updates, report a problem, about.
/// Header (Back and title) and footer (version and links) stay; the body scrolls. Rows the Mac shows that mean nothing on
/// Windows are left out (`SettingsModel.visibility`: menu bar group, Keychain switch, floating pet group); the rest of the
/// Mac's page (difficulty, backup, advanced) is later tasks.
///
/// Every setting writes through the store's, the companion's or the team's own property, the same defaults keys the Mac
/// writes. The page observes them while it is open (`withObservationTracking`, coalesced to one pass per main-queue turn) and
/// shows a change from elsewhere (the tray menu's back view, the team session's incompatible-peer flag). Nothing here has a
/// timer. Built when the popover opens or rebuilds (a DPI or text size change) and freed by `destroy()`; closing commits a
/// changed field (the kit's third commit point).
@MainActor final class WinSettingsPage: WinPopoverPage {
    let host: WinPopoverHost
    private weak var popover: WinPopover?
    /// What Back and Escape do (the Mac's `onClose`: leave Settings); the popover swaps the page in place.
    var onBack: () -> Void
    /// "Report a problem" and the footer links open through this (the shell; the selftest records instead).
    var openURL: @MainActor (URL) -> Bool = { WindowsShell().openReturning($0) }
    /// "Explorer": the log file selected in Explorer.
    var revealLog: @MainActor (URL) -> Void = { WindowsShell.revealInExplorer($0) }

    private var l: L { host.companion.l }
    private var store: UsageStore { host.store }

    private var window: WinSinkWindow?
    private var ctx: WinUIContext?
    private var header: WinPane?
    private var footer: WinPane?
    private var backLink: WinControl?
    private var titleLabel: WinControl?
    private var footerControls: [WinControl] = []
    private var area: WinScrollArea?
    private var stack: WinStack?
    private var team: WinTeamSection?
    private var lastClient = RECT()
    private var destroyed = false
    private var rebuildPending = false
    private var refreshPending = false
    private var observationGeneration = 0

    // Controls the refresh and the selftest read.
    private var languageRow: WinRow?
    private var refreshRow: WinRow?
    private var limitDisplayRow: WinRow?
    private var loginRow: WinRow?
    private var backViewRow: WinRow?
    private var helpRow: WinRow?
    private var helpBodyRow: WinRow?
    private var providerRows: [(row: WinRow, id: String)] = []
    private var limitAlertsRow: WinRow?
    private var warnRow: WinRow?
    private var critRow: WinRow?
    private var companionAlertsRow: WinRow?
    private var statusChecksRow: WinRow?
    private var updateNotificationsRow: WinRow?
    private var checkNowRow: WinRow?
    private var updateOfferRow: WinRow?
    private var updateSkippedRow: WinRow?
    private var updateCurrentRow: WinRow?
    private var reportRow: WinRow?
    private var logRow: WinRow?
    private var fallbackRow: WinRow?
    private var isCheckingUpdate = false
    private var didCheckUpdate = false
    private var helpOpen = false
    private var reportFailed = false
    private var loginState: TrayMenuModel.LoginState = .unavailable
    private var applying = false

    private(set) var languageRebuilds = 0, refreshes = 0, pageRebuilds = 0

    init(host: WinPopoverHost, popover: WinPopover?, onBack: @escaping () -> Void) {
        self.host = host
        self.popover = popover
        self.onBack = onBack
    }

    /// The page `popover.state` asks for: Settings, else (until the Home page is wired in) the empty page. Back leaves Settings
    /// in place, the Mac's `onClose`.
    static func routed(_ popover: WinPopover) -> WinPopoverPage {
        guard popover.state.showSettings else { return WinPopoverEmptyPage() }
        return WinSettingsPage(host: popover.host, popover: popover) { [weak popover] in
            popover?.state.showSettings = false
            popover?.replacePage()
        }
    }

    /// The Mac's `.frame(height: 460)`.
    var heightDIP: CGFloat { 460 }

    var initialFocus: HWND? { nil }

    func escape() -> Bool {
        onBack()
        return true
    }

    // MARK: building

    func build(in window: WinSinkWindow, ctx: WinUIContext, client: RECT) {
        self.window = window
        self.ctx = ctx
        destroyed = false
        buildContents(client: client)
        observe()
    }

    func layout(client: RECT) {
        lastClient = client
        placeChrome(client)
    }

    private func buildContents(client: RECT) {
        guard let window, let ctx else { return }
        lastClient = client
        let l = self.l
        loginState = host.loginItem.state

        // Header, body, footer: creation order is Tab order.
        let head = try? WinPane(parent: window.hwnd, ctx: ctx, rect: client)
        header = head
        if let head {
            head.paint = { [weak self, weak head] dc, rect in
                if let head { self?.paintChrome(head, dc, rect, line: .bottom) }
            }
            let back = WinControls.link("‹ " + l.back, in: head.hwnd, ctx: ctx)
            back?.onClick = { [weak self] in self?.onBack() }
            backLink = back
            titleLabel = WinControls.label(l.settings, style: .headline, wraps: false, in: head.hwnd, ctx: ctx)
        }
        guard let made = try? WinScrollArea(parent: window.hwnd, ctx: ctx, rect: client) else {
            AppLog.write("settings: no scroll area (\(GetLastError()))")
            return
        }
        area = made
        let page = WinStack(pane: made.content, width: made.contentWidth)
        page.onHeight = { [weak made] h in made?.setContentHeight(h) }
        stack = page
        buildSections(page)

        let foot = try? WinPane(parent: window.hwnd, ctx: ctx, rect: client)
        footer = foot
        if let foot { buildFooter(foot, l) }

        placeChrome(client)
        page.layout()
        sync()
    }

    private func buildFooter(_ foot: WinPane, _ l: L) {
        guard let ctx else { return }
        foot.paint = { [weak self, weak foot] dc, rect in
            if let foot { self?.paintChrome(foot, dc, rect, line: .top) }
        }
        func text(_ s: String) -> WinControl? {
            let c = WinControls.label(s, style: .caption2, role: .tertiary, wraps: false, in: foot.hwnd, ctx: ctx)
            c?.background = ctx.colors.palette.window
            return c
        }
        func link(_ title: String, _ url: String) -> WinControl? {
            let c = WinControls.link(title, in: foot.hwnd, ctx: ctx)
            c?.background = ctx.colors.palette.window
            c?.tooltip = url
            c?.onClick = { [weak self] in
                if let target = URL(string: url) { _ = self?.openURL(target) }
            }
            return c
        }
        footerControls = [
            text("v\(Self.appVersion)"), text("·"), link("GitHub", "https://github.com/chattymin/PokeTokenBar"), text("·"),
            link(l.website, "https://chattymin.github.io/PokeTokenBar/"), text("·"),
            link("♥ " + l.sponsor, "https://github.com/sponsors/chattymin"),
        ].compactMap { $0 }
    }

    private enum Line { case top, bottom }

    private func paintChrome(_ pane: WinPane, _ dc: HDC, _ dirty: RECT, line: Line) {
        guard let ctx else { return }
        var r = dirty
        _ = FillRect(dc, &r, ctx.colors.brush(ctx.colors.palette.window))
        var client = RECT()
        _ = GetClientRect(pane.hwnd, &client)
        let thickness = max(1, ctx.px(1))
        var divider = line == .bottom ? RECT(left: 0, top: client.bottom - thickness, right: client.right, bottom: client.bottom)
                                      : RECT(left: 0, top: 0, right: client.right, bottom: thickness)
        _ = FillRect(dc, &divider, ctx.colors.brush(ctx.colors.palette.divider))
    }

    /// Header on top, footer at the bottom, the scrolling body between (the Mac's `header`, `footer` and `ScrollView`).
    private func placeChrome(_ client: RECT) {
        guard let ctx else { return }
        let width = client.right - client.left
        let line = max(1, ctx.px(1))
        let pad = ctx.px(14)
        let titleH = Int32(titleLabel?.preferredSize.height ?? 0), backH = Int32(backLink?.preferredSize.height ?? 0)
        let headerH = max(titleH, backH) + 2 * ctx.px(10) + line
        let footH = Int32(footerControls.map { $0.preferredSize.height }.max() ?? 0) + 2 * ctx.px(10) + line
        header?.move(RECT(left: 0, top: 0, right: width, bottom: headerH))
        footer?.move(RECT(left: 0, top: client.bottom - footH, right: width, bottom: client.bottom))
        area?.move(RECT(left: 0, top: headerH, right: width, bottom: client.bottom - footH))
        if let stack, let area {
            stack.width = area.contentWidth
            stack.layout()
        }
        let bar = headerH - line
        if let back = backLink {
            let w = Int32(back.preferredSize.width), h = Int32(back.preferredSize.height)
            back.frame(RECT(left: pad, top: (bar - h) / 2, right: pad + w, bottom: (bar - h) / 2 + h))
        }
        if let title = titleLabel {
            let w = Int32(title.preferredSize.width), h = Int32(title.preferredSize.height)
            let x = max(pad, (width - w) / 2)
            title.frame(RECT(left: x, top: (bar - h) / 2, right: x + w, bottom: (bar - h) / 2 + h))
        }
        var x = pad
        for c in footerControls {
            let w = Int32(c.preferredSize.width), h = Int32(c.preferredSize.height)
            let y = line + (footH - line - h) / 2
            c.frame(RECT(left: x, top: y, right: x + w, bottom: y + h))
            x += w + ctx.px(5)
        }
    }

    // MARK: the sections

    private func buildSections(_ s: WinStack) {
        let l = self.l
        let store = self.store

        // General (G1, G3, G5, G8, G12b)
        let general = s.addSection(l.generalSectionTitle)
        languageRow = general.addRow(l.language) { p, c in
            WinControls.combo(AppLanguage.allCases.map(\.label), selected: AppLanguage.allCases.firstIndex(of: self.host.companion.language) ?? 0,
                              in: p, ctx: c)
        }
        languageRow?.control?.onSelect = { [weak self] i in self?.languageChosen(i) }
        let presets = UsageStore.intervalPresets
        refreshRow = general.addRow(l.refreshInterval) { p, c in
            WinControls.combo(presets.map { l.intervalLabel($0.value) },
                              selected: presets.firstIndex { $0.value == store.refreshInterval } ?? -1, in: p, ctx: c)
        }
        refreshRow?.control?.onSelect = { i in
            if presets.indices.contains(i) { store.refreshInterval = presets[i].value }
        }
        limitDisplayRow = general.addRow(l.limitDisplayModeLabel) { p, c in
            WinControls.radioGroup([l.limitDisplayUsed, l.limitDisplayRemaining], selected: store.limitDisplayMode == .used ? 0 : 1, in: p, ctx: c)
        }
        limitDisplayRow?.control?.onSelect = { i in store.limitDisplayMode = i == 0 ? .used : .remaining }
        let loginHint: String? = loginState == .disabledByUser ? l.disabledInTaskManager : nil
        loginRow = general.addToggle(l.launchAtLogin, hint: loginHint, isOn: loginState == .on)
        loginRow?.control?.isEnabled = loginState == .on || loginState == .off
        loginRow?.control?.onToggle = { [weak self] on in self?.setLaunchAtLogin(on) }
        backViewRow = general.addToggle(l.backViewLabel, hint: l.winBackViewHint, isOn: store.alwaysFacesBack)
        backViewRow?.control?.onToggle = { on in store.alwaysFacesBack = on }
        helpRow = general.addRow(l.winClaudeCredentialHelpTitle) { p, c in
            WinControls.glyphButton(symbol: "questionmark.circle", label: l.winClaudeCredentialHelpTooltip, in: p, ctx: c)
        }
        helpRow?.control?.tooltip = l.winClaudeCredentialHelpTooltip
        helpRow?.control?.onClick = { [weak self] in
            guard let self else { return }
            helpOpen.toggle()
            helpBodyRow?.isVisible = helpOpen
        }
        helpBodyRow = general.addRow(nil, hint: l.winClaudeCredentialHelpBody) { _, _ in nil }
        helpBodyRow?.hint?.role = .secondary
        helpBodyRow?.isVisible = helpOpen
        // Left out on Windows (`SettingsModel.visibility`): animation quality and the pet group (they wait for the pet, T22), the
        // menu bar group and the Keychain switch (no such things here). The Mac's representative, trend and tracked-account rows are T20, T12, T14.

        // Tracked providers (G11)
        let providers = s.addSection(l.trackedProvidersSectionTitle)
        providerRows = store.registeredProviders.map { provider in
            let row = providers.addToggle(provider.displayName, isOn: store.isProviderEnabled(provider.id))
            row.control?.onToggle = { on in store.setProviderEnabled(provider.id, on) }
            return (row, provider.id)
        }
        let providerHint = s.addSection(nil, card: false)
        providerHint.addRow(nil, hint: l.trackedProvidersHint) { _, _ in nil }

        // Team (G13): Korean, as the Mac's
        let teamSection = s.addSection(L(.ko).teamSectionTitle)
        team = WinTeamSection(section: teamSection, host: host,
                              changed: { [weak self] in self?.scheduleRefresh() },
                              rebuild: { [weak self] in self?.scheduleRebuild() })

        // Notifications (G14)
        let notifications = s.addSection(l.notificationsSection)
        limitAlertsRow = notifications.addToggle(l.limitNotificationsLabel, isOn: store.limitNotifications)
        limitAlertsRow?.control?.onToggle = { [weak self] on in
            store.limitNotifications = on
            self?.scheduleRefresh()
        }
        warnRow = notifications.addRow(l.warning) { p, c in
            WinControls.trackbar(range: 50...95, step: 5, value: Int(store.warnThreshold), format: { TokenFormatter.percent(Double($0)) }, in: p, ctx: c)
        }
        warnRow?.control?.onValue = { [weak self] v in
            store.warnThreshold = Double(v)
            self?.scheduleRefresh()   // the critical slider may have been pushed along
        }
        critRow = notifications.addRow(l.critical) { p, c in
            WinControls.trackbar(range: 80...100, step: 5, value: Int(store.critThreshold), format: { TokenFormatter.percent(Double($0)) }, in: p, ctx: c)
        }
        critRow?.control?.onValue = { [weak self] v in
            store.critThreshold = Double(v)
            self?.scheduleRefresh()
        }
        companionAlertsRow = notifications.addToggle(l.companionNotificationsLabel, isOn: store.companionNotifications)
        companionAlertsRow?.control?.onToggle = { on in store.companionNotifications = on }
        statusChecksRow = notifications.addToggle(l.statusChecksLabel, hint: l.statusChecksHint, isOn: store.statusChecksEnabled)
        statusChecksRow?.control?.onToggle = { on in store.statusChecksEnabled = on }

        // Updates (G15)
        let updates = s.addSection(l.updateSectionTitle)
        updateNotificationsRow = updates.addToggle(l.updateNotificationsLabel, isOn: store.updateNotificationsEnabled)
        updateNotificationsRow?.control?.onToggle = { on in store.updateNotificationsEnabled = on }
        if host.updater != nil {
            checkNowRow = updates.addRow(l.checkForUpdatesLabel) { p, c in WinControls.button(l.checkNowButton, in: p, ctx: c) }
            checkNowRow?.control?.onClick = { [weak self] in self?.checkNow() }
            updateOfferRow = updates.addRow("") { p, c in WinControls.button(l.updateButton, in: p, ctx: c) }
            updateOfferRow?.label?.role = .warning
            updateOfferRow?.control?.onClick = { [weak self] in self?.host.updater?.applyUpdate() }
            updateSkippedRow = updates.addRow("") { p, c in WinControls.button(l.showSkippedAgain, in: p, ctx: c) }
            updateSkippedRow?.label?.role = .warning
            updateSkippedRow?.control?.onClick = { [weak self] in
                self?.host.updater?.showSkippedAgain()
                self?.scheduleRefresh()
            }
            updateCurrentRow = updates.addRow(l.upToDate(Self.appVersion)) { _, _ in nil }
            updateCurrentRow?.label?.role = .secondary
        }

        // About & support (G18)
        let about = s.addSection(l.aboutSupportSectionTitle)
        reportRow = about.addRow(l.reportProblem, hint: l.reportAttachHint) { p, c in WinControls.button(l.reportProblem, in: p, ctx: c) }
        reportRow?.control?.onClick = { [weak self] in self?.reportProblem() }
        logRow = about.addRow(l.showLogFile) { p, c in WinControls.button(l.winExplorerButton, in: p, ctx: c) }
        logRow?.control?.onClick = { [weak self] in self?.revealLog(AppLog.logFileURL) }
        fallbackRow = about.addRow(nil, hint: l.reportMailFallback(SupportMail.address)) { p, c in
            WinControls.edit(.text(cue: nil), text: SupportMail.address, width: nil, in: p, ctx: c)
        }
        fallbackRow?.hint?.role = .warning
        if let edit = fallbackRow?.control {
            WinKit.send(edit.hwnd, 0x00CF /* EM_SETREADONLY */, 1)   // selectable, not editable
        }
    }

    static var appVersion: String { WindowsInstall.version ?? "—" }

    // MARK: showing the settings' state

    /// Values and visibility from the settings now. Touches only what differs, never a control being typed in.
    private func sync() {
        guard !destroyed else { return }
        applying = true
        defer { applying = false }
        refreshes += 1
        let store = self.store
        let language = AppLanguage.allCases.firstIndex(of: host.companion.language) ?? 0
        if let c = languageRow?.control, c.selection != language { c.selection = language }
        let presets = UsageStore.intervalPresets
        let interval = presets.firstIndex { $0.value == store.refreshInterval } ?? -1
        if let c = refreshRow?.control, c.selection != interval { c.selection = interval }
        let limit = store.limitDisplayMode == .used ? 0 : 1
        if let c = limitDisplayRow?.control, c.selection != limit { c.selection = limit }
        loginState = host.loginItem.state
        setOn(loginRow?.control, loginState == .on)
        setOn(backViewRow?.control, store.alwaysFacesBack)
        for (row, id) in providerRows { setOn(row.control, store.isProviderEnabled(id)) }
        setOn(limitAlertsRow?.control, store.limitNotifications)
        warnRow?.isVisible = store.limitNotifications
        critRow?.isVisible = store.limitNotifications
        if let c = warnRow?.control, c.value != Int(store.warnThreshold) { c.value = Int(store.warnThreshold) }
        if let c = critRow?.control, c.value != Int(store.critThreshold) { c.value = Int(store.critThreshold) }
        setOn(companionAlertsRow?.control, store.companionNotifications)
        setOn(statusChecksRow?.control, store.statusChecksEnabled)
        setOn(updateNotificationsRow?.control, store.updateNotificationsEnabled)
        syncUpdates()
        fallbackRow?.isVisible = reportFailed
        var relayout = team?.apply() ?? false
        relayout = relayout || updateTextChanged
        if relayout { stack?.setNeedsLayout() }
    }

    private var updateTextChanged = false

    private func setOn(_ c: WinControl?, _ on: Bool) {
        if let c, c.isOn != on { c.isOn = on }
    }

    private func syncUpdates() {
        updateTextChanged = false
        guard let updater = host.updater, checkNowRow != nil else { return }
        let l = self.l
        let shown = didCheckUpdate && !isCheckingUpdate
        var offer = false, skipped = false, current = false
        if shown {
            switch updater.settingsNotice {
            case .offer(let version):
                offer = true
                updateTextChanged = setText(updateOfferRow?.label, l.updateFound(version)) || updateTextChanged
            case .skipped(let version):
                skipped = true
                updateTextChanged = setText(updateSkippedRow?.label, l.skippedVersion(version)) || updateTextChanged
            case .current:
                current = true
            }
        }
        updateOfferRow?.isVisible = offer
        updateSkippedRow?.isVisible = skipped
        updateCurrentRow?.isVisible = current
        checkNowRow?.control?.isEnabled = !isCheckingUpdate
    }

    private func setText(_ c: WinControl?, _ text: String) -> Bool {
        guard let c, c.text != text else { return false }
        c.text = text
        return true
    }

    // MARK: actions

    private func languageChosen(_ index: Int) {
        guard !applying, AppLanguage.allCases.indices.contains(index) else { return }
        let language = AppLanguage.allCases[index]
        guard language != host.companion.language else { return }
        host.companion.setLanguage(language)
        store.localizationLanguage = language
        languageRebuilds += 1
        scheduleRebuild()   // every text of the open page, in the new language (not inside the combo box's own message)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard !applying else { return }
        _ = host.loginItem.setEnabled(on)   // read back below; a failure is in the log (WindowsLoginItem)
        scheduleRefresh()
    }

    private func checkNow() {
        guard let updater = host.updater, !isCheckingUpdate else { return }
        isCheckingUpdate = true
        syncUpdates()
        let generation = observationGeneration
        Task { @MainActor [weak self] in
            await updater.check(minInterval: 0)   // a manual check skips the rate limit (the Mac's)
            guard let self, !destroyed, generation == observationGeneration else { return }
            isCheckingUpdate = false
            didCheckUpdate = true
            sync()
        }
    }

    private func reportProblem() {
        let version = Self.appVersion
        let subject = l.reportMailSubject(version)
        let body = l.winReportMailBody(version: version, os: ProcessInfo.processInfo.operatingSystemVersionString)
        if let url = SupportMail.mailtoURL(subject: subject, body: body), openURL(url) {
            reportFailed = false
        } else {
            reportFailed = true
        }
        scheduleRefresh()
    }

    // MARK: refresh, rebuild, observation

    private func scheduleRefresh() {
        guard !destroyed, !refreshPending else { return }
        refreshPending = true
        let generation = observationGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == observationGeneration else { return }
                refreshPending = false
                sync()
            }
        }
    }

    /// The page again from the settings: a new language, or a changed list of saved teams. Keeps the scroll position and the
    /// place of the keyboard focus. Runs from the main queue, never inside a control's own notification.
    private func scheduleRebuild() {
        guard !destroyed, !rebuildPending else { return }
        rebuildPending = true
        let generation = observationGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == observationGeneration else { return }
                rebuildPending = false
                rebuildNow()
            }
        }
    }

    private func rebuildNow() {
        guard !destroyed, let window, ctx != nil else { return }
        pageRebuilds += 1
        let offset = area?.offset ?? 0
        let focused = stack?.controls.firstIndex { $0.parts.contains { $0 == GetFocus() } }
        let hadForeground = GetForegroundWindow() == window.hwnd
        let client = lastClient
        freeContents()
        buildContents(client: client)
        area?.scroll(to: offset)
        if hadForeground, let focused, let controls = stack?.controls, controls.indices.contains(focused) {
            _ = SetFocus(controls[focused].hwnd)
        }
        stack?.setNeedsLayout()
    }

    private func observe() {
        guard !destroyed else { return }
        let generation = observationGeneration
        withObservationTracking {
            touchSettings()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == observationGeneration, !destroyed else { return }
                    sync()
                    observe()
                }
            }
        }
    }

    /// What the page shows from observable settings (the registrations of one tracking pass).
    private func touchSettings() {
        let store = self.store
        _ = store.refreshInterval
        _ = store.limitDisplayMode
        _ = store.alwaysFacesBack
        _ = store.limitNotifications
        _ = store.warnThreshold
        _ = store.critThreshold
        _ = store.companionNotifications
        _ = store.statusChecksEnabled
        _ = store.updateNotificationsEnabled
        _ = host.companion.language
        _ = host.updater?.settingsNotice
        let team = host.team
        _ = team.isEnabled
        _ = team.code
        _ = team.savedTeams
        _ = team.nickname
        _ = team.notificationsEnabled
        _ = team.schedule
        _ = host.session?.hasIncompatiblePeer
    }

    // MARK: closing

    private func freeContents() {
        team?.isClosing = true
        stack?.destroy()   // commits a changed nickname or team name
        area?.destroy()
        for c in footerControls { c.destroy() }
        footerControls = []
        footer?.destroy()
        backLink?.destroy()
        titleLabel?.destroy()
        header?.destroy()
        team = nil
        stack = nil
        area = nil
        footer = nil
        header = nil
        backLink = nil
        titleLabel = nil
        languageRow = nil; refreshRow = nil; limitDisplayRow = nil; loginRow = nil; backViewRow = nil; helpRow = nil; helpBodyRow = nil
        limitAlertsRow = nil; warnRow = nil; critRow = nil; companionAlertsRow = nil; statusChecksRow = nil; updateNotificationsRow = nil
        checkNowRow = nil; updateOfferRow = nil; updateSkippedRow = nil; updateCurrentRow = nil; reportRow = nil; logRow = nil
        fallbackRow = nil
        providerRows = []
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        observationGeneration += 1   // stale observers and queued passes do nothing
        freeContents()
        window = nil
        ctx = nil
    }

    // MARK: for the selftest

    var teamForTesting: WinTeamSection? { team }
    var stackForTesting: WinStack? { stack }
    var areaForTesting: WinScrollArea? { area }
    var rowsForTesting: (language: WinRow?, refresh: WinRow?, limitDisplay: WinRow?, login: WinRow?, backView: WinRow?, help: WinRow?,
                         helpBody: WinRow?, limitAlerts: WinRow?, warn: WinRow?, crit: WinRow?, companionAlerts: WinRow?, statusChecks: WinRow?,
                         updateNotifications: WinRow?, checkNow: WinRow?, updateOffer: WinRow?, updateSkipped: WinRow?, updateCurrent: WinRow?,
                         report: WinRow?, log: WinRow?, fallback: WinRow?) {
        (languageRow, refreshRow, limitDisplayRow, loginRow, backViewRow, helpRow, helpBodyRow, limitAlertsRow, warnRow, critRow, companionAlertsRow,
         statusChecksRow, updateNotificationsRow, checkNowRow, updateOfferRow, updateSkippedRow, updateCurrentRow, reportRow, logRow, fallbackRow)
    }
    var providerRowsForTesting: [WinRow] { providerRows.map(\.row) }
    var backLinkForTesting: WinControl? { backLink }
    var footerControlsForTesting: [WinControl] { footerControls }
    func refreshNowForTesting() { sync() }
    var rebuildsForTesting: Int { pageRebuilds }
}
#endif
