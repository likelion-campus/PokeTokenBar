#if os(Windows)
import Foundation
import WinSDK

/// What the team section keeps while the user types or waits, and must keep when the page is built again (a new team in the
/// saved list rebuilds it; the Mac's section holds the same as `@State`).
@MainActor final class WinTeamDrafts {
    var nickname: String?
    var teamName: String?
    var joinFailed = false
    /// Joined by code but no nickname yet: the plaza opens when the nickname is set (the Mac's `openPlazaWhenReady`).
    var openPlazaWhenReady = false
}

/// The team section of the Settings page (stage 7 Task 6, G13): the Mac's `TeamSettingsSection`, row for row, in Korean as
/// the Mac's is (P6). Every rule is the shared one (`TeamSetup.join` / `committedDraft` / `masked`, `TeamSettings`,
/// `SettingsModel.team`); this class only turns them into kit controls.
///
/// All rows are built once and shown or hidden by `apply()` (the kit lays the page out again on a visibility change, so a
/// field that is being typed in is never rebuilt). The only structure that can change is the list of saved teams (rows of
/// "enter" in the no-code state): `savedKeys` says which list the page was built for, and the page rebuilds when the list
/// of teams changes (a join, a create or a leave), never for a rename.
///
/// The team code is the team's shared key: it is never logged, never in a window title or tooltip, shown masked, copied only
/// by the Copy button, and the join field is blanked once it is used and when the page closes.
@MainActor final class WinTeamSection {
    private let host: WinPopoverHost
    private let l = L(.ko)
    private var team: TeamSettings { host.team }
    /// The page re-applies after an action (observation does not see a draft).
    private let changed: () -> Void
    /// The saved-team list the page was built for changed.
    private let rebuild: () -> Void

    /// The Mac's drafts: what is typed, until it is committed.
    private let drafts: WinTeamDrafts
    /// Programmatic text changes must not count as typing.
    private var applying = false
    /// Set before the page's controls are destroyed (their last commit still stores a valid nickname).
    var isClosing = false

    private let enableRow: WinRow
    private let codeRow: WinRow
    private let leaveRow: WinRow
    private let nameRow: WinRow
    private let switchRow: WinRow
    private let createRow: WinRow
    private let joinRow: WinRow
    private let joinButtonRow: WinRow
    private let joinErrorRow: WinRow
    private var savedRows: [(row: WinRow, key: String)] = []
    private let nicknameRow: WinRow
    private let nicknameErrorRow: WinRow
    private let notificationsRow: WinRow
    private let coreStartRow: WinRow
    private let coreEndRow: WinRow
    private let seasonRow: WinRow
    private let captionRow: WinRow
    private let reportRow: WinRow
    private let incompatibleRow: WinRow
    /// The `start` the end combo's items were made for.
    private var endItemsStart = -1

    /// The saved teams the rows were built for (their codes: identity only, never shown).
    let savedKeys: [String]

    /// The switch menu: the real popup menu, or a stand-in in the selftest. (items, where, owner) → chosen index.
    var menu: @MainActor ([TrayMenuModel.Item?], POINT, HWND) -> Int? = { items, point, owner in
        WinPopupMenu.run(items, at: point, owner: owner)
    }
    /// What puts the team code on the clipboard (the selftest observes it without a real clipboard).
    var copyToClipboard: @MainActor (String, HWND?) -> Bool = { text, owner in WinTextClipboard.write(text, secret: true, owner: owner) }
    private(set) var copies = 0, joins = 0

    init(section: WinSectionCard, host: WinPopoverHost, drafts: WinTeamDrafts, changed: @escaping () -> Void, rebuild: @escaping () -> Void) {
        self.host = host
        self.drafts = drafts
        self.changed = changed
        self.rebuild = rebuild
        let l = L(.ko)
        let team = host.team
        savedKeys = team.savedTeams.map(\.code)
        let rows = SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: false)

        enableRow = section.addToggle(l.teamEnable, isOn: team.isEnabled)
        // With a code: masked code + Copy, Leave, name, switch.
        codeRow = section.addRow(rows.maskedCode ?? " ") { p, c in WinControls.button(l.teamCopyCode, in: p, ctx: c) }
        leaveRow = section.addRow(nil) { p, c in WinControls.button(l.teamLeave, in: p, ctx: c) }
        nameRow = section.addRow(l.teamName) { p, c in WinControls.edit(.text(cue: nil), text: rows.teamName, width: 140, in: p, ctx: c) }
        switchRow = section.addRow(l.teamSwitch) { p, c in
            WinControls.button(rows.teamName.isEmpty ? l.teamSwitch : rows.teamName, in: p, ctx: c)
        }
        // Without one: create, join, the saved teams.
        createRow = section.addRow(nil) { p, c in WinControls.button(l.teamCreate, in: p, ctx: c) }
        joinRow = section.addRow(l.teamJoin, style: .stacked) { p, c in
            WinControls.edit(.code(cue: l.teamCodePlaceholder), text: "", width: nil, in: p, ctx: c)
        }
        joinButtonRow = section.addRow(nil) { p, c in WinControls.button(l.teamJoin, in: p, ctx: c) }
        joinErrorRow = section.addRow(nil, hint: l.teamCodeInvalid) { _, _ in nil }
        var built: [(row: WinRow, key: String)] = []
        for saved in team.savedTeams {
            let row = section.addRow("\(l.teamSaved) · \(saved.name)") { p, c in WinControls.button(l.teamEnterSaved, in: p, ctx: c) }
            built.append((row, saved.code))
        }
        savedRows = built
        nicknameRow = section.addRow(l.teamNickname) { p, c in WinControls.edit(.text(cue: nil), text: team.nickname, width: 140, in: p, ctx: c) }
        nicknameErrorRow = section.addRow(nil, hint: l.teamNicknameInvalid) { _, _ in nil }
        notificationsRow = section.addToggle(l.teamNotifications, isOn: team.notificationsEnabled)
        coreStartRow = section.addRow(l.teamCoreTime) { p, c in
            WinControls.combo(SettingsModel.coreStarts.map { l.teamHour($0) }, selected: rows.coreStart - 1, in: p, ctx: c)
        }
        coreEndRow = section.addRow(l.teamCoreTime + " ~") { p, c in
            let ends = Array(SettingsModel.coreEnds(start: rows.coreStart))
            return WinControls.combo(ends.map { l.teamHour($0) }, selected: ends.firstIndex(of: rows.coreEnd) ?? 0, in: p, ctx: c)
        }
        endItemsStart = rows.coreStart
        seasonRow = section.addRow(l.teamSeason) { p, c in
            WinControls.combo(PlazaSeasonChoice.allCases.map { l.teamSeasonName($0) },
                              selected: PlazaSeasonChoice.allCases.firstIndex(of: rows.season) ?? 0, in: p, ctx: c)
        }
        captionRow = section.addRow(nil, hint: rows.scheduleCaption) { _, _ in nil }
        reportRow = section.addRow(nil, hint: SettingsModel.usageReportCaption(lastSent: host.usageReporter?.lastSentAt)) { _, _ in nil }
        incompatibleRow = section.addRow(nil, hint: l.teamIncompatiblePeer) { _, _ in nil }
        for row in [joinErrorRow, nicknameErrorRow, incompatibleRow] { row.hint?.role = .error }
        captionRow.hint?.role = .secondary
        reportRow.hint?.role = .secondary
        wire()
        apply()
    }

    // MARK: wiring

    private func wire() {
        enableRow.control?.onToggle = { [weak self] on in
            guard let self else { return }
            team.isEnabled = on
            changed()
        }
        codeRow.control?.onClick = { [weak self] in self?.copyCode() }
        leaveRow.control?.onClick = { [weak self] in
            guard let self else { return }
            team.leaveTeam()
            afterTeamChange()
        }
        nameRow.control?.onChange = { [weak self] text in
            guard let self, !applying else { return }
            drafts.teamName = text
        }
        nameRow.control?.onCommit = { [weak self] _ in self?.commitTeamName() }
        switchRow.control?.onClick = { [weak self] in self?.openSwitchMenu() }
        createRow.control?.onClick = { [weak self] in
            guard let self else { return }
            var rng = SystemRandomNumberGenerator()
            team.code = TeamCode.generate(using: &rng)
            afterTeamChange()
        }
        // Enter in the code field joins (the Mac's onSubmit); losing focus does not: a click on "코드로 참여" must find the code
        // still in the field. The kit commits a field on Enter and on focus loss alike; the Enter key is down only for Enter.
        joinRow.control?.onCommit = { [weak self] _ in
            if GetKeyState(0x0D /* VK_RETURN */) < 0 { self?.join() }
        }
        joinButtonRow.control?.onClick = { [weak self] in self?.join() }
        for (row, key) in savedRows {
            row.control?.onClick = { [weak self] in
                guard let self, let saved = team.savedTeams.first(where: { $0.code == key }) else { return }
                switchTo(saved)
            }
        }
        nicknameRow.control?.onChange = { [weak self] text in
            guard let self, !applying else { return }
            drafts.nickname = text
            apply()   // the red line follows the typing, as on the Mac
        }
        nicknameRow.control?.onCommit = { [weak self] _ in self?.commitNickname() }
        notificationsRow.control?.onToggle = { [weak self] on in self?.team.notificationsEnabled = on }
        coreStartRow.control?.onSelect = { [weak self] i in
            guard let self else { return }
            let rows = model()
            let start = SettingsModel.coreStarts.lowerBound + i
            team.changeSchedule(coreStart: start, coreEnd: rows.coreEnd, season: rows.season, now: Date())
            changed()
        }
        coreEndRow.control?.onSelect = { [weak self] i in
            guard let self else { return }
            let rows = model()
            let end = SettingsModel.coreEnds(start: rows.coreStart).lowerBound + i
            team.changeSchedule(coreStart: rows.coreStart, coreEnd: end, season: rows.season, now: Date())
            changed()
        }
        seasonRow.control?.onSelect = { [weak self] i in
            guard let self, PlazaSeasonChoice.allCases.indices.contains(i) else { return }
            let rows = model()
            team.changeSchedule(coreStart: rows.coreStart, coreEnd: rows.coreEnd, season: PlazaSeasonChoice.allCases[i], now: Date())
            changed()
        }
        // The join field holds the team's key while it is typed or pasted: it is blanked when the page closes.
        if let join = joinRow.control {
            join.onDestroy = { [weak join] in join?.text = "" }
        }
    }

    private func model() -> SettingsModel.TeamRows {
        SettingsModel.team(team, nicknameDraft: drafts.nickname, incompatiblePeer: host.session?.hasIncompatiblePeer ?? false)
    }

    // MARK: showing

    /// Shows what the settings say now: which rows, their texts, their values. Never touches a field that has the focus.
    @discardableResult
    func apply() -> Bool {
        guard !isClosing else { return false }
        textChanged = false
        let rows = model()
        let on = rows.showsDetails, inTeam = on && rows.hasCode, noCode = on && !rows.hasCode
        applying = true
        defer { applying = false }
        if enableRow.control?.isOn != rows.isEnabled { enableRow.control?.isOn = rows.isEnabled }
        for row in [codeRow, leaveRow, nameRow, switchRow] { row.isVisible = inTeam }
        for row in [createRow, joinRow, joinButtonRow] { row.isVisible = noCode }
        joinErrorRow.isVisible = noCode && drafts.joinFailed
        for (row, _) in savedRows { row.isVisible = noCode }
        nicknameRow.isVisible = on
        nicknameErrorRow.isVisible = on && rows.nicknameInvalid
        notificationsRow.isVisible = on
        for row in [coreStartRow, coreEndRow, seasonRow, captionRow] { row.isVisible = on && rows.showsSchedule }
        reportRow.isVisible = on && team.isReady
        incompatibleRow.isVisible = on && rows.incompatiblePeer

        set(codeRow.label, rows.maskedCode ?? " ")
        set(switchRow.control, rows.teamName.isEmpty ? l.teamSwitch : rows.teamName)
        if let name = nameRow.control, GetFocus() != name.hwnd { set(name, drafts.teamName ?? rows.teamName) }
        if let nick = nicknameRow.control, GetFocus() != nick.hwnd { set(nick, drafts.nickname ?? team.nickname) }
        for (row, key) in savedRows {
            if let saved = team.savedTeams.first(where: { $0.code == key }) { set(row.label, "\(l.teamSaved) · \(saved.name)") }
        }
        if notificationsRow.control?.isOn != rows.notificationsEnabled { notificationsRow.control?.isOn = rows.notificationsEnabled }
        if let start = coreStartRow.control, start.selection != rows.coreStart - 1 { start.selection = rows.coreStart - 1 }
        if let end = coreEndRow.control {
            if endItemsStart != rows.coreStart {
                end.setItems(SettingsModel.coreEnds(start: rows.coreStart).map { l.teamHour($0) })
                endItemsStart = rows.coreStart
            }
            let target = rows.coreEnd - (rows.coreStart + 1)
            if end.selection != target { end.selection = target }
        }
        let seasonIndex = PlazaSeasonChoice.allCases.firstIndex(of: rows.season) ?? 0
        if let season = seasonRow.control, season.selection != seasonIndex { season.selection = seasonIndex }
        set(captionRow.hint, rows.scheduleCaption)
        set(reportRow.hint, SettingsModel.usageReportCaption(lastSent: host.usageReporter?.lastSentAt))
        if team.savedTeams.map(\.code) != savedKeys { rebuild() }
        return textChanged
    }

    /// A label whose text changed may wrap differently: the caller lays the page out again.
    private var textChanged = false

    private func set(_ c: WinControl?, _ text: String) {
        guard let c, c.text != text else { return }
        c.text = text
        if c.kind == .label { textChanged = true }
    }

    // MARK: actions

    private func afterTeamChange() {
        drafts.teamName = nil
        changed()
    }

    private func copyCode() {
        guard let code = team.code else { return }
        copies += 1
        let owner = codeRow.control.flatMap { GetAncestor($0.hwnd, 2 /* GA_ROOT */) }
        if !copyToClipboard(code.display, owner) { AppLog.write("settings: the team code could not be copied") }
    }

    private func join() {
        let text = joinRow.control?.text ?? ""
        joins += 1
        let result = TeamSetup.join(text, into: team)
        drafts.joinFailed = result == .invalid
        guard result != .invalid else {
            changed()
            return
        }
        joinRow.control?.text = ""
        if result == .openPlaza { openPlazaSoon() } else { drafts.openPlazaWhenReady = true }
        afterTeamChange()
    }

    /// The plaza closes the popover (D3), which destroys the controls whose handler is running: after it returns.
    private func openPlazaSoon() {
        let open = host.openPlaza
        DispatchQueue.main.async { open() }
    }

    private func commitNickname() {
        drafts.nickname = TeamSetup.committedDraft(drafts.nickname, into: team)
        if drafts.openPlazaWhenReady && team.isReady {
            drafts.openPlazaWhenReady = false
            openPlazaSoon()
        }
        if !isClosing { changed() }
    }

    private func commitTeamName() {
        guard let draft = drafts.teamName else { return }
        if team.renameCurrentTeam(draft) { drafts.teamName = nil }
        if !isClosing { changed() }
    }

    private func switchTo(_ saved: TeamSettings.SavedTeam) {
        commitTeamName()
        drafts.teamName = nil
        team.switchTo(saved)
        afterTeamChange()
    }

    private func openSwitchMenu() {
        guard let button = switchRow.control, let current = team.code?.normalized else { return }
        let saved = team.savedTeams
        var items: [TrayMenuModel.Item?] = saved.map {
            TrayMenuModel.Item(title: $0.name, enabled: $0.code != current, checked: false, action: .none)
        }
        items.append(nil)
        items.append(TrayMenuModel.Item(title: l.teamStepOut, enabled: true, checked: false, action: .none))
        var r = RECT()
        _ = GetWindowRect(button.hwnd, &r)
        guard let owner = GetAncestor(button.hwnd, 2 /* GA_ROOT */),
              let chosen = menu(items, POINT(x: r.left, y: r.top), owner) else { return }
        if chosen < saved.count {
            switchTo(saved[chosen])
        } else {
            team.stepOut()
            afterTeamChange()
        }
    }

    // MARK: for the selftest

    var rowsForTesting: (enable: WinRow, code: WinRow, leave: WinRow, name: WinRow, switcher: WinRow, create: WinRow, join: WinRow,
                         joinButton: WinRow, nickname: WinRow, nicknameError: WinRow, joinError: WinRow) {
        (enableRow, codeRow, leaveRow, nameRow, switchRow, createRow, joinRow, joinButtonRow, nicknameRow, nicknameErrorRow, joinErrorRow)
    }
    var savedRowsForTesting: [WinRow] { savedRows.map(\.row) }
    var coreRowsForTesting: [WinRow] { [coreStartRow, coreEndRow, seasonRow, captionRow] }
    var incompatibleRowForTesting: WinRow { incompatibleRow }
    func joinForTesting() { join() }
}
#endif
