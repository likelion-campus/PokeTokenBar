#if os(Windows)
import Foundation
import WinSDK

/// What the Advanced group keeps while the page is built again (a language change, a new team, a DPI change, a new list of
/// Claude folders): the Mac's `@State` of `SettingsView` (`advancedExpanded`, the scan folders' draft and the provider it
/// describes, the additional folders' draft). Never a session key: a typed key goes with the field (a rebuild clears it).
@MainActor final class WinAdvancedDrafts {
    var expanded = false
    /// `didApplyStartExpanded`: the session-key route (`PopoverState.expandAdvancedOnOpen`) opens Advanced once per visit.
    var appliedStartExpanded = false
    /// The provider picker (`selectedScanProviderID`) and the provider the draft describes (`customScanDraftOwnerID`): a
    /// picker change is seen before the field's focus loss, and the draft must go to the provider it was typed for.
    var scanProviderID = "claude_code"
    var scanDraftOwnerID = "claude_code"
    var scanDraft = ""
    var additionalDraft = ""
    /// The drafts were read from the store (the Mac's `onAppear` of the rows): only then are they committed back.
    var loaded = false
}

/// The Settings page's Advanced group (stage 7 Task 14, G17): the Mac's `SettingsView.advancedGroup` row for row — the
/// disclosure, the claude.ai session key (badge, hint, masked field, Save with its check, Delete, the organisation picker,
/// the error or the storage note), each additional Claude folder's own key, "Reload Claude sign-in" and its message, the
/// additional Claude folders, the custom scan folders with their match count, the aggregation note. "Disable Keychain access"
/// is not on Windows (`SettingsModel.visibility`). Every rule is `SettingsModel.advanced` (shared, tested on both systems);
/// every action is the store's own (`saveSessionKey`, `refreshLimitTokenFromKeychain`, `setCustomScanRoots`, …), so the
/// network goes through the store's providers and the WinHTTP seam.
///
/// A session key is a secret: the field is `ES_PASSWORD` (the edit refuses Copy and Cut, `WM_GETTEXT` from another process
/// and Narrator get nothing), its value is never put back after a save (the grey dots say "saved"), it is cleared after a
/// successful save, on Delete and when the page closes or is built again, and no log line, window title, tooltip or model holds
/// it (`SettingsModel` reads only "is a key saved"). Focus loss does not save a key (the Mac saves on Enter and Save only).
///
/// Nothing here has a timer: the match counts are counted off the main thread 250 ms after the last change of a field (the
/// Mac's debounce), once, on one serial queue (`counting`).
@MainActor final class WinAdvancedSection {
    /// One key's rows, as the Mac's: the label with its badge right after it and the hint or the folder under them; the
    /// field, Save (a small marquee beside it while the key is checked) and Delete on one line when the field keeps room at
    /// the page's width and text size, else the field over the buttons; the organisation picker (the default key only), the
    /// error, the storage note.
    @MainActor final class KeyControls {
        let path: String?
        let labelRow: WinRow
        let fieldRow: WinRow
        let errorRow: WinRow
        var labelLine: WinComposite?
        var title: WinControl?
        var badge: WinControl?
        /// The line holding Save, the marquee and Delete (the field's line when they share one).
        var buttons: WinComposite?
        var buttonsRow: WinRow?
        var field: WinControl?
        var save: WinControl?
        var progress: WinControl?
        var delete: WinControl?
        var orgRow: WinRow?
        var noteRow: WinRow?
        /// The organisation names the picker holds, and the field's grey text now.
        var orgNames: [String] = []
        var placeholder = ""

        init(path: String?, labelRow: WinRow, fieldRow: WinRow, errorRow: WinRow) {
            self.path = path
            self.labelRow = labelRow
            self.fieldRow = fieldRow
            self.errorRow = errorRow
        }

        var oneLine: Bool { buttonsRow == nil }
        var rows: [WinRow] { [labelRow, fieldRow] + [buttonsRow, orgRow, noteRow].compactMap { $0 } + [errorRow] }
    }

    private let host: WinPopoverHost
    private let drafts: WinAdvancedDrafts
    private let facts: PopoverPlatformFacts
    private let l: L
    private var store: UsageStore { host.store }
    /// The page shows the settings again (after an action observation does not see).
    private let changed: () -> Void
    /// The list of Claude folders the rows were built for changed: the page is built again.
    private let rebuild: () -> Void
    /// A text changed outside the page's own pass (a count landed): the page lays out again.
    private let relayout: () -> Void
    /// Set before the page's controls are destroyed: a key field's last commit saves nothing.
    var isClosing = false

    let section: WinSectionCard
    private let disclosureRow: WinRow
    /// The chevron before the disclosure's label (the Mac's row: chevron, label).
    private let chevron: WinControl?
    let key: KeyControls
    private(set) var accounts: [KeyControls] = []
    private let accountsNoteRow: WinRow
    private let refreshRow: WinRow
    private let refreshMessageRow: WinRow
    private let additionalRow: WinRow
    private let detectedRow: WinRow
    private let additionalFieldRow: WinRow
    private let additionalFoundRow: WinRow
    private let scanRow: WinRow
    private let scanProviderRow: WinRow
    private let scanFieldRow: WinRow
    private let scanMatchesRow: WinRow
    private let aggregationRow: WinRow
    /// The additional Claude folders the account rows were built for, with their labels and folder lines (a title that
    /// arrives with the account's limits adds the folder line: the page is built again then).
    let builtRoots: [String]
    private let builtSignature: [String]

    private static func signature(_ model: SettingsModel.AdvancedRows) -> [String] {
        model.accounts.map { $0.path + "\u{1}" + $0.rows.label + "\u{1}" + ($0.rows.detail ?? "") }
    }
    private let providers: [(id: String, displayName: String)]

    private var applying = false
    private var textChanged = false
    private var scanCount = 0, scanGeneration = 0, additionalCount = 0, additionalGeneration = 0
    /// Both counts run on one serial queue, the newest draft per count replacing older ones that have not started: a share
    /// that stopped answering blocks one file call for its SMB timeout and nothing interrupts it, so a cancellable task per
    /// pause would leave a blocked thread per pause (review of Task 14, Minor 6).
    static let counting = LatestOnlyWork(label: "poketokenbar.settings.counts")
    /// The key field takes the keyboard when the page opens (the session-key route).
    private(set) var focusKeyOnOpen = false
    private(set) var saves = 0, deletes = 0, scanCommits = 0, additionalCommits = 0, counts = 0

    init(section: WinSectionCard, host: WinPopoverHost, drafts: WinAdvancedDrafts, facts: PopoverPlatformFacts, startExpanded: Bool,
         changed: @escaping () -> Void, relayout: @escaping () -> Void, rebuild: @escaping () -> Void) {
        self.section = section
        self.relayout = relayout
        self.host = host
        self.drafts = drafts
        self.facts = facts
        self.changed = changed
        self.rebuild = rebuild
        let store = host.store
        let l = host.companion.l
        self.l = l
        if startExpanded, !drafts.appliedStartExpanded {
            drafts.appliedStartExpanded = true
            drafts.expanded = true
            focusKeyOnOpen = true
        }
        let model = SettingsModel.advanced(SettingsModel.advancedInput(store, language: l.lang), facts: facts)
        builtRoots = model.accounts.map(\.path)
        builtSignature = Self.signature(model)
        let providerList = store.registeredProviders
        providers = providerList

        var chevron: WinControl?
        disclosureRow = section.addRow(nil, style: .full) { p, c in
            let line = WinComposite(parent: p, ctx: c) { child in
                chevron = WinControls.glyphButton(symbol: drafts.expanded ? "chevron.down" : "chevron.forward", label: l.advancedDisclosureLabel,
                                                  size: 10, in: child, ctx: c)
                let parts = [chevron, WinControls.label(l.advancedDisclosureLabel, wraps: false, in: child, ctx: c)].compactMap { $0 }
                Self.onRow(parts, section: section, ctx: c)
                return (parts, [])
            }
            Self.paintOnRow(line, section: section, ctx: c)
            return line?.control
        }
        self.chevron = chevron
        key = Self.keyControls(path: nil, model.sessionKey, organizations: true, in: section, l: l)
        accounts = model.accounts.map { Self.keyControls(path: $0.path, $0.rows, organizations: false, in: section, l: l) }
        accountsNoteRow = section.addRow(nil, hint: model.accountsStorageNote ?? " ") { _, _ in nil }
        refreshRow = section.addRow(model.refreshLabel, hint: model.refreshHint) { p, c in WinControls.button(model.refreshLabel, in: p, ctx: c) }
        refreshMessageRow = section.addRow(nil, hint: model.refreshMessage ?? " ") { _, _ in nil }
        additionalRow = section.addRow(l.additionalClaudeAccountsLabel, hint: model.additionalHint) { _, _ in nil }
        detectedRow = section.addRow(nil, hint: model.detected ?? " ") { _, _ in nil }
        additionalFieldRow = section.addRow(nil, style: .full, accessibleName: l.additionalClaudeAccountsLabel) { p, c in
            WinControls.edit(.multiLine(lines: 3, cue: l.additionalClaudeAccountsPlaceholder), text: drafts.additionalDraft, width: nil, in: p, ctx: c)
        }
        additionalFoundRow = section.addRow(nil, hint: " ") { _, _ in nil }
        scanRow = section.addRow(l.customScanRootsLabel, hint: l.customScanRootsHint) { _, _ in nil }
        let selectedProvider = providerList.firstIndex { $0.id == drafts.scanProviderID } ?? 0
        scanProviderRow = section.addRow(l.customScanProviderLabel) { p, c in
            WinControls.combo(providerList.map(\.displayName), selected: selectedProvider, in: p, ctx: c)
        }
        scanFieldRow = section.addRow(nil, style: .full, accessibleName: l.customScanRootsLabel) { p, c in
            WinControls.edit(.multiLine(lines: 3, cue: l.customScanRootsPlaceholder), text: drafts.scanDraft, width: nil, in: p, ctx: c)
        }
        scanMatchesRow = section.addRow(nil, hint: " ") { _, _ in nil }
        aggregationRow = section.addRow(nil, hint: l.aggregationNote) { _, _ in nil }

        for row in [refreshMessageRow] { row.hint?.role = .warning }
        detectedRow.hint?.role = .secondary
        wire()
        if drafts.expanded { appeared(reload: !drafts.loaded) }
        apply()
    }

    private static func keyControls(path: String?, _ m: SettingsModel.KeyRows, organizations: Bool, in section: WinSectionCard, l: L) -> KeyControls {
        var labelLine: WinComposite?, title: WinControl?, badge: WinControl?, ctx: WinUIContext?
        let labelRow = section.addStyledRow(label: { p, c in
            ctx = c
            labelLine = WinComposite(parent: p, ctx: c) { child in
                title = WinControls.label(m.label, wraps: false, in: child, ctx: c)
                badge = WinControls.label(" ", style: .caption2, wraps: false, in: child, ctx: c)   // its text is set by `apply`
                let parts = [title, badge].compactMap { $0 }
                onRow(parts, section: section, ctx: c)
                return (parts, [])
            }
            paintOnRow(labelLine, section: section, ctx: c)
            return labelLine?.control
        }, hint: m.detail)
        var field: WinControl?, save: WinControl?, progress: WinControl?, delete: WinControl?, buttons: WinComposite?
        func line(_ p: HWND, _ c: WinUIContext, name: String?, withField: Bool) -> WinControl? {
            buttons = WinComposite(parent: p, ctx: c, accessibleName: name) { child in
                if withField { field = WinControls.edit(.password(cue: m.placeholder), text: "", width: 220, in: child, ctx: c) }
                save = WinControls.button(l.save, in: child, ctx: c)
                progress = WinControls.marquee(in: child, ctx: c)
                delete = WinControls.button(l.delete, in: child, ctx: c)
                return ([field, save, progress, delete].compactMap { $0 }, [])
            }
            if let progress { buttons?.setShown(progress, false) }
            paintOnRow(buttons, section: section, ctx: c)
            return buttons?.control
        }
        let oneLine = ctx.map { fitsOneLine(section: section, ctx: $0, l: l) } ?? false
        let fieldRow: WinRow, buttonsRow: WinRow?
        if oneLine {
            fieldRow = section.addRow(nil, style: .full) { p, c in line(p, c, name: m.label, withField: true) }
            buttonsRow = nil
        } else {
            fieldRow = section.addRow(nil, style: .full, accessibleName: m.label) { p, c in
                field = WinControls.edit(.password(cue: m.placeholder), text: "", width: nil, in: p, ctx: c)
                return field
            }
            buttonsRow = section.addRow(nil, style: .full) { p, c in line(p, c, name: nil, withField: false) }
        }
        var orgRow: WinRow?, noteRow: WinRow?
        if organizations {
            orgRow = section.addRow(l.sessionKeyOrganizationLabel) { p, c in
                WinControls.combo(m.organizations.map(\.name), selected: m.selectedOrganization ?? -1, in: p, ctx: c)
            }
            noteRow = section.addRow(nil, hint: m.storageNote ?? " ") { _, _ in nil }
        }
        let errorRow = section.addRow(nil, hint: m.error ?? " ") { _, _ in nil }
        errorRow.hint?.role = .warning
        let k = KeyControls(path: path, labelRow: labelRow, fieldRow: fieldRow, errorRow: errorRow)
        k.labelLine = labelLine
        k.title = title
        k.badge = badge
        k.buttons = buttons
        k.buttonsRow = buttonsRow
        k.field = field
        k.save = save
        k.progress = progress
        k.delete = delete
        k.orgRow = orgRow
        k.noteRow = noteRow
        k.orgNames = m.organizations.map(\.name)
        k.placeholder = m.placeholder
        if let badge { labelLine?.setShown(badge, false) }
        sizeLabelLine(k)
        return k
    }

    /// The Mac's key row (`SecureField` up to 220 pt, Save, Delete, in one `HStack`) on one line when the field keeps at least
    /// the room to show its cue ("sk-ant-sid…") beside Save, the marquee and Delete at the page's width and text size; else
    /// the field over the buttons, the kit's way of stacking a row that does not fit (larger text, longer button titles).
    static func fitsOneLine(section: WinSectionCard, ctx c: WinUIContext, l: L) -> Bool {
        let font = c.fonts.font(.body)
        func button(_ title: String) -> Int32 { c.measure(title, font: font).cx + c.px(24) }
        let gap = c.px(8)
        let buttons = button(l.save) + gap + c.px(28) + gap + button(l.delete) + gap
        let fieldLeast = max(c.px(72), c.measure("sk-ant-sid…", font: font).cx + c.px(12))
        let inner = section.pageWidth - 2 * Int32(c.metrics.pagePadding) - 2 * Int32(c.metrics.rowPaddingH)
        return inner - buttons >= fieldLeast
    }

    /// Texts and glyphs inside a line paint their own background: the row's (the card's), not the window's they are made with.
    private static func onRow(_ parts: [WinControl], section: WinSectionCard, ctx c: WinUIContext) {
        for part in parts { part.background = section.card ? c.colors.palette.card : c.colors.palette.window }
    }

    /// A line's pane fills the row's colour (the card's) behind its controls: a pane paints the window colour unless told.
    private static func paintOnRow(_ line: WinComposite?, section: WinSectionCard, ctx c: WinUIContext) {
        let card = section.card
        line?.pane.paint = { dc, r in
            var rr = r
            _ = FillRect(dc, &rr, c.colors.brush(card ? c.colors.palette.card : c.colors.palette.window))
        }
    }

    /// The label line's width: the label, then the badge 8 px after it when there is one.
    private static func sizeLabelLine(_ k: KeyControls) {
        guard let line = k.labelLine, let title = k.title else { return }
        let badge = k.badge.map { $0.text.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : $0.preferredSize.width + CGFloat(line.ctx.px(8)) } ?? 0
        line.control.preferredSize.width = title.preferredSize.width + badge
    }

    /// A button sized for its longest title ("Save…" while the key is checked), so the spinner's text never clips.
    private static func fitButton(_ c: WinControl, longest: String) {
        let s = c.ctx.measure(longest, font: c.ctx.fonts.font(.body))
        c.preferredSize.width = max(c.preferredSize.width, CGFloat(s.cx + c.ctx.px(24)))
    }

    // MARK: wiring

    private func wire() {
        chevron?.onClick = { [weak self] in self?.toggle() }
        wireKey(key)
        for account in accounts { wireKey(account) }
        key.orgRow?.control?.onSelect = { [weak self] index in
            guard let self, !applying else { return }
            let orgs = store.sessionKeyOrganizations
            guard orgs.indices.contains(index) else { return }
            let id = orgs[index].id
            let store = self.store
            Task { await store.selectSessionOrganization(id) }
        }
        if let refresh = refreshRow.control {
            Self.fitButton(refresh, longest: (refreshRow.label?.text ?? "") + "…")
            refresh.onClick = { [weak self] in
                guard let store = self?.store else { return }
                Task { await store.refreshLimitTokenFromKeychain() }
            }
        }
        additionalFieldRow.control?.onChange = { [weak self] text in
            guard let self, !applying else { return }
            drafts.additionalDraft = text
            scheduleAdditionalCount()
        }
        // Enter, focus loss and closing commit (the Mac's onSubmit, focus and onDisappear).
        additionalFieldRow.control?.onCommit = { [weak self] _ in self?.commitAdditional() }
        scanFieldRow.control?.onChange = { [weak self] text in
            guard let self, !applying else { return }
            drafts.scanDraft = text
            scheduleScanCount()
        }
        scanFieldRow.control?.onCommit = { [weak self] _ in self?.commitScanDraft() }
        scanProviderRow.control?.onSelect = { [weak self] index in self?.providerChosen(index) }
    }

    private func wireKey(_ k: KeyControls) {
        let path = k.path
        k.field?.onChange = { [weak self] _ in self?.applyButtons() }
        // Enter saves (the Mac's onSubmit). The kit also commits a field on focus loss and on close: a key is not saved then.
        k.field?.onCommit = { [weak self] text in
            guard let self, !isClosing, GetKeyState(0x0D /* VK_RETURN */) < 0 else { return }
            submit(text, path: path)
        }
        if let field = k.field {
            // The field holds the key while it is typed or pasted: blanked when the page closes or is built again.
            field.onDestroy = { [weak field] in field?.text = "" }
        }
        k.save?.onClick = { [weak self, weak k] in
            guard let self, let text = k?.field?.text else { return }
            submit(text, path: path)
        }
        k.delete?.onClick = { [weak self, weak k] in
            guard let self else { return }
            k?.field?.text = ""
            deletes += 1
            if let path { store.clearAccountSessionKey(for: path) } else { store.clearSessionKey() }
            changed()
        }
    }

    // MARK: actions

    /// The Mac's `submitSessionKey` / `submitAccountSessionKey`: the store checks the key (it lists the organisations) and saves
    /// it; the field is emptied when that worked, and keeps the text to fix otherwise.
    private func submit(_ text: String, path: String?) {
        guard !text.isEmpty else { return }
        saves += 1
        let store = self.store
        Task { @MainActor [weak self] in
            if let path { await store.saveAccountSessionKey(text, for: path) } else { await store.saveSessionKey(text) }
            guard let self, !self.isClosing else { return }
            if let path {
                if store.accountSessionKeyError(for: path) == nil { self.accounts.first { $0.path == path }?.field?.text = "" }
            } else if store.sessionKeyError == nil {
                self.key.field?.text = ""
            }
            self.changed()
        }
    }

    private func toggle() {
        drafts.expanded.toggle()
        chevron?.setGlyph(symbol: drafts.expanded ? "chevron.down" : "chevron.forward")
        if drafts.expanded { appeared(reload: true) } else { disappeared() }
        changed()
    }

    /// The rows inside `if advancedExpanded` appearing: the organisation list is filled once (it lives in memory only), the
    /// drafts come from the store, the counts start.
    private func appeared(reload: Bool) {
        let store = self.store
        Task { await store.refreshSessionOrganizations() }
        if reload {
            drafts.loaded = true
            drafts.additionalDraft = store.additionalClaudeConfigDirs
            drafts.scanDraftOwnerID = drafts.scanProviderID
            drafts.scanDraft = store.customScanRoots(for: drafts.scanProviderID)
            applying = true
            additionalFieldRow.control?.text = drafts.additionalDraft
            scanFieldRow.control?.text = drafts.scanDraft
            applying = false
        }
        scheduleScanCount()
        scheduleAdditionalCount()
    }

    /// Collapsing (and closing): the drafts are committed, the counts stop.
    private func disappeared() {
        commitScanDraft()
        commitAdditional()
        Self.counting.cancel(key: "scan")
        Self.counting.cancel(key: "additional")
    }

    private func commitScanDraft() {
        guard drafts.loaded else { return }
        scanCommits += 1
        store.setCustomScanRoots(drafts.scanDraft, for: drafts.scanDraftOwnerID)
    }

    private func commitAdditional() {
        guard drafts.loaded else { return }
        additionalCommits += 1
        store.additionalClaudeConfigDirs = drafts.additionalDraft
    }

    /// The Mac's `onChange(of: selectedScanProviderID)`: the draft goes to the provider it was typed for, then the field shows
    /// the new provider's folders.
    private func providerChosen(_ index: Int) {
        guard !applying, drafts.loaded, providers.indices.contains(index) else { return }
        let id = providers[index].id
        guard id != drafts.scanProviderID else { return }
        store.setCustomScanRoots(drafts.scanDraft, for: drafts.scanDraftOwnerID)
        drafts.scanProviderID = id
        drafts.scanDraftOwnerID = id
        drafts.scanDraft = store.customScanRoots(for: id)
        applying = true
        scanFieldRow.control?.text = drafts.scanDraft
        applying = false
        scheduleScanCount()
    }

    /// The Mac's `scheduleCustomScanMatchCount`: 250 ms after the last change, off the main thread, the newest draft only.
    private func scheduleScanCount() {
        scanGeneration += 1
        let generation = scanGeneration
        let raw = drafts.scanDraft
        let providerID = drafts.scanProviderID
        Self.counting.submit(key: "scan", after: SettingsModel.scanCountDelay) { [weak self] in
            let count = CustomScanRoots.survivingExtraCount(defaults: CustomScanRoots.curatedRoots(for: providerID), extraRaw: raw)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isClosing, generation == self.scanGeneration else { return }
                    self.scanCount = count
                    self.landed()
                }
            }
        }
    }

    /// The additional folders' "found" count, the same way. (The Mac counts it in the view body, on the main thread; here it
    /// waits like the scan count, since a folder on a network share can take seconds to answer.)
    private func scheduleAdditionalCount() {
        additionalGeneration += 1
        let generation = additionalGeneration
        let raw = drafts.additionalDraft
        Self.counting.submit(key: "additional", after: SettingsModel.scanCountDelay) { [weak self] in
            let count = ClaudeAccountRoots.roots(from: raw).count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isClosing, generation == self.additionalGeneration else { return }
                    self.additionalCount = count
                    self.landed()
                }
            }
        }
    }

    private func landed() {
        counts += 1
        textChanged = false
        applyCounts()
        if textChanged { relayout() }
    }

    // MARK: showing

    /// Shows what the store says now. Never touches a field's text (a draft or a key being typed); true when a text changed
    /// (the page lays out again).
    @discardableResult
    func apply() -> Bool {
        guard !isClosing else { return false }
        textChanged = false
        applying = true
        defer { applying = false }
        let model = SettingsModel.advanced(SettingsModel.advancedInput(store, language: l.lang), facts: facts)
        if Self.signature(model) != builtSignature {
            rebuild()
            return false
        }
        let open = drafts.expanded
        applyKey(key, model.sessionKey, open: open)
        for (controls, account) in zip(accounts, model.accounts) { applyKey(controls, account.rows, open: open) }
        set(accountsNoteRow.hint, model.accountsStorageNote)
        accountsNoteRow.isVisible = open && model.accountsStorageNote != nil
        refreshRow.isVisible = open
        if let button = refreshRow.control {
            setTitle(button, model.refreshLabel + (model.refreshInProgress ? "…" : ""))
            if button.isEnabled != model.refreshEnabled { button.isEnabled = model.refreshEnabled }
        }
        set(refreshMessageRow.hint, model.refreshMessage)
        refreshMessageRow.isVisible = open && model.refreshMessage != nil
        additionalRow.isVisible = open
        set(detectedRow.hint, model.detected)
        detectedRow.isVisible = open && model.detected != nil
        for row in [additionalFieldRow, scanRow, scanProviderRow, scanFieldRow, aggregationRow] { row.isVisible = open }
        applyCounts()
        applyButtons()
        return textChanged
    }

    private func applyKey(_ k: KeyControls, _ m: SettingsModel.KeyRows, open: Bool) {
        for row in k.rows { row.isVisible = open }
        setBadge(k, m.badge)
        if m.detail != nil { set(k.labelRow.hint, m.detail) }
        if let field = k.field, k.placeholder != m.placeholder {
            WinKit.send(field.hwnd, 0x1501 /* EM_SETCUEBANNER */, 1, text: m.placeholder)
            k.placeholder = m.placeholder
        }
        if let delete = k.delete { k.buttons?.setShown(delete, m.showsDelete) }
        if let row = k.orgRow, let combo = row.control {
            let names = m.organizations.map(\.name)
            if names != k.orgNames {
                WinKit.send(combo.hwnd, 0x014B /* CB_RESETCONTENT */)
                for name in names { WinKit.send(combo.hwnd, 0x0143 /* CB_ADDSTRING */, 0, text: name) }
                k.orgNames = names
            }
            let selected = m.selectedOrganization ?? -1
            if combo.selection != selected { combo.selection = selected }
            row.isVisible = open && m.showsOrganizations
        }
        set(k.errorRow.hint, m.error)
        k.errorRow.isVisible = open && m.error != nil
        if let note = k.noteRow {
            set(note.hint, m.storageNote)
            note.isVisible = open && m.error == nil && m.storageNote != nil
        }
    }

    /// Save is on while its field holds text and no key is being checked; the marquee beside it runs while this one is (the
    /// Mac's small ProgressView in the button).
    private func applyButtons() {
        let model = SettingsModel.advanced(SettingsModel.advancedInput(store, language: l.lang), facts: facts)
        let pairs = [(key, model.sessionKey)] + zip(accounts, model.accounts.map(\.rows)).map { ($0, $1) }
        for (k, m) in pairs {
            guard let save = k.save else { continue }
            let on = !(k.field?.text.isEmpty ?? true) && !m.isValidating && !m.saveBlocked
            if save.isEnabled != on { save.isEnabled = on }
            if let progress = k.progress {
                if !m.isValidating { progress.setMarquee(false) }
                k.buttons?.setShown(progress, m.isValidating)
                if m.isValidating { progress.setMarquee(true) }
            }
        }
    }

    private func applyCounts() {
        let open = drafts.expanded
        let found = SettingsModel.additionalFound(draft: drafts.additionalDraft, count: additionalCount, l: l)
        set(additionalFoundRow.hint, found)
        additionalFoundRow.isVisible = open && found != nil
        let matches = SettingsModel.scanMatches(draft: drafts.scanDraft, count: scanCount, l: l)
        set(scanMatchesRow.hint, matches)
        scanMatchesRow.isVisible = open && matches != nil
    }

    private func set(_ c: WinControl?, _ text: String?) {
        guard let c, let text, c.text != text else { return }
        c.text = text
        textChanged = true
    }

    private func setTitle(_ c: WinControl, _ title: String) {
        guard c.text != title else { return }
        c.text = title
    }

    /// The badge right after the key's label: orange "expired", green "saved", or nothing.
    private func setBadge(_ k: KeyControls, _ badge: SettingsModel.KeyBadge?) {
        guard let c = k.badge else { return }
        let text: String
        let role: PopoverColorRole
        switch badge {
        case .expired?: text = l.sessionKeyExpiredBadge; role = .systemOrange
        case .saved?: text = l.sessionKeySaved; role = .systemGreen
        case nil: text = " "; role = .tertiary
        }
        let v = role.macValue(.light)
        func byte(_ d: Double) -> UInt8 { UInt8(max(0, min(255, (d * 255).rounded()))) }
        c.textColor = WinUIColors.rgb(byte(v.red), byte(v.green), byte(v.blue))
        guard c.text != text else { return }
        k.labelLine?.setText(c, text)
        k.labelLine?.setShown(c, badge != nil)
        Self.sizeLabelLine(k)
        textChanged = true
    }

    // MARK: the page

    /// Where the keyboard starts when the session-key route opened the page: the key field.
    var initialFocus: HWND? { focusKeyOnOpen ? key.field?.hwnd : nil }

    /// The top of the group in the page's content (its caption), for the route's scroll.
    var top: Int32? {
        guard let caption = section.caption, let content = GetParent(caption.hwnd) else { return nil }
        return WinKit.rect(caption.hwnd, in: content).top
    }

    /// What `apply` reads, for the page's observation pass.
    static func touch(_ store: UsageStore) {
        _ = SettingsModel.advancedInput(store)
        _ = store.additionalClaudeConfigDirs
    }

    /// Closing or a rebuild: the drafts are committed (onDisappear), the counts stop. Before the controls are destroyed.
    func close() {
        guard !isClosing else { return }
        if drafts.expanded { disappeared() }
        isClosing = true
        Self.counting.cancel(key: "scan")
        Self.counting.cancel(key: "additional")
    }

    // MARK: for the selftest

    var disclosureForTesting: WinControl? { chevron }
    var rowsForTesting: (refresh: WinRow, refreshMessage: WinRow, additional: WinRow, detected: WinRow, additionalField: WinRow,
                         additionalFound: WinRow, scan: WinRow, scanProvider: WinRow, scanField: WinRow, scanMatches: WinRow,
                         aggregation: WinRow, accountsNote: WinRow) {
        (refreshRow, refreshMessageRow, additionalRow, detectedRow, additionalFieldRow, additionalFoundRow, scanRow, scanProviderRow,
         scanFieldRow, scanMatchesRow, aggregationRow, accountsNoteRow)
    }
    var draftsForTesting: WinAdvancedDrafts { drafts }
}

/// The tracked-account picker of the General group (stage 7 Task 14, G7): the Mac's `SettingsView.trackedAccountRow`, shown
/// with two Claude accounts or more (`SettingsModel.trackedAccount`). The label is stacked over the picker (account emails make
/// it too wide to sit beside the label).
@MainActor final class WinTrackedAccountRow {
    private let store: UsageStore
    private let facts: PopoverPlatformFacts
    private let language: AppLanguage
    let row: WinRow
    private var titles: [String]
    private var applying = false

    init(section: WinSectionCard, store: UsageStore, facts: PopoverPlatformFacts, language: AppLanguage) {
        self.store = store
        self.facts = facts
        self.language = language
        let l = L(language)
        let model = SettingsModel.trackedAccount(store, facts: facts, language: language)
        let initial = model?.titles ?? []
        titles = initial
        row = section.addRow(l.trackedAccountLabel, hint: model?.hint ?? (facts.hasKeychain ? l.trackedAccountHint : l.winTrackedAccountHint),
                             style: .stacked) { p, c in
            WinControls.combo(initial, selected: model?.selected ?? 0, in: p, ctx: c)
        }
        row.control?.onSelect = { [weak self] index in
            guard let self, !applying, let model = SettingsModel.trackedAccount(store, facts: facts, language: language),
                  model.modes.indices.contains(index) else { return }
            store.claudeTrackedAccountMode = model.modes[index]
        }
        apply()
    }

    func apply() {
        applying = true
        defer { applying = false }
        let model = SettingsModel.trackedAccount(store, facts: facts, language: language)
        row.isVisible = model != nil
        guard let model, let combo = row.control else { return }
        if model.titles != titles {
            WinKit.send(combo.hwnd, 0x014B /* CB_RESETCONTENT */)
            for title in model.titles { WinKit.send(combo.hwnd, 0x0143 /* CB_ADDSTRING */, 0, text: title) }
            titles = model.titles
        }
        if combo.selection != model.selected { combo.selection = model.selected }
    }

    static func touch(_ store: UsageStore) {
        _ = store.claudeAccounts
        _ = store.claudeTrackedAccountMode
    }
}
#endif
