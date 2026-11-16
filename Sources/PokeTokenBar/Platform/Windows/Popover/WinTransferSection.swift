#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// What the Difficulty and Backup & transfer rows keep while the page is open and must keep when the page is built again (a
/// language change rebuilds it; the Mac's `DifficultySettingsSection` holds the draft as `@State` and the history header's
/// expansion lives in `SettingsView`).
@MainActor final class WinTransferDrafts {
    var difficulty: PopoverDifficultyDraft?
    var snapshotsExpanded = false
}

/// The dialogs of the Backup & transfer flows on Windows: the common file dialogs and the task dialog, owned by the popover
/// (the owner is the popover's window, so they stay above it and the popover does not close when they take the activation).
@MainActor final class WinTransferDialogs: TransferDialogs {
    private let owner: () -> HWND?
    private let language: () -> L
    /// Explorer with the exported file selected (the selftest replaces it).
    var revealFile: (URL) -> Void = { WindowsShell.revealInExplorer($0) }

    init(owner: @escaping () -> HWND?, language: @escaping () -> L) {
        self.owner = owner
        self.language = language
    }

    func chooseSaveFile(title: String, suggestedName: String) -> URL? {
        WinFileDialog.choose(save: true, owner: owner(), title: title, suggestedName: suggestedName, filterName: language().winSaveFileFilterName)
    }

    func chooseOpenFile(title: String) -> URL? {
        WinFileDialog.choose(save: false, owner: owner(), title: title, suggestedName: nil, filterName: language().winSaveFileFilterName)
    }

    /// Replace first, Cancel second and the default (`ImportConfirmPolicy`): Enter and Esc cancel.
    func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String) -> Bool {
        var buttons = ["", ""]
        buttons[ImportConfirmPolicy.replaceButtonIndex] = confirmTitle
        buttons[ImportConfirmPolicy.cancelButtonIndex] = cancelTitle
        return WinTaskDialog.show(owner: owner(), heading: title, content: message, icon: .warning, buttons: buttons,
                                  defaultIndex: ImportConfirmPolicy.cancelButtonIndex) == ImportConfirmPolicy.replaceButtonIndex
    }

    func inform(title: String, message: String, isError: Bool) {
        _ = WinTaskDialog.show(owner: owner(), heading: title, content: message, icon: isError ? .error : .information,
                               buttons: [language().close], defaultIndex: 0)
    }

    func reveal(_ file: URL) { revealFile(file) }
}

/// The Difficulty (G9) and Backup & transfer (G16) rows of the Settings page (stage 7 Task 15). The page adds the two blocks
/// where the Mac's page has them (`addDifficulty` after General, `addTransfer` after Updates) and calls `apply()` with every
/// refresh.
///
/// Difficulty: the Mac's draft and Save flow exactly (`PopoverDifficultyDraft`): the sliders show and edit a draft, Save appears
/// only while the draft differs from the store, and Save writes both values (the store rescales the banked growth progress).
/// There is no confirmation on the Mac and none here. A trackbar position is the Mac slider's position over 200 steps
/// (`PopoverDifficultySlider`); the value text beside it is the draft's, and the same text is the slider's accessible value.
///
/// Transfer: export, import, create snapshot, the history disclosure with a row per snapshot and Restore, all through
/// `SaveTransferFlow` with `WinTransferDialogs`. While a flow runs (a dialog is open) `isBusy` holds the page's rebuilds back.
@MainActor final class WinTransferSection {
    private let host: WinPopoverHost
    private let drafts: WinTransferDrafts
    private let owner: () -> HWND?
    private let fetcher: any PlazaSpriteFetching
    /// Asks the page to refresh its rows / to build itself again.
    private let changed: () -> Void
    private let rebuild: () -> Void
    private(set) var flow: SaveTransferFlow!
    private var l: L { host.companion.l }
    private var companion: CompanionStore { host.companion }

    /// A flow is running (a dialog is open): the page does not rebuild itself under it.
    private(set) var isBusy = false
    /// What to do once the flow ends (a rebuild the page held back).
    var afterBusy: (() -> Void)?
    private var applying = false

    private var growthRow: WinRow?
    private var growthBar: WinControl?
    private var shopBar: WinControl?
    private var shopRow: WinRow?
    private var saveRow: WinRow?
    private var exportRow: WinRow?
    private var importRow: WinRow?
    private var snapshotRow: WinRow?
    private var historyRow: WinRow?
    private var snapshotRows: [WinRow] = []
    /// The snapshots the page was built for: another list (an automatic snapshot, a created one) builds the page again.
    private var builtSnapshotIDs: [String] = []
    private var transferBuilt = false

    // What the selftest reads.
    private(set) var flows = 0
    private(set) var lastOutcome: SaveTransferFlow.Outcome?
    private(set) var applied = 0

    init(host: WinPopoverHost, drafts: WinTransferDrafts, owner: @escaping () -> HWND?, dialogs: (any TransferDialogs)? = nil,
         spriteFetcher: any PlazaSpriteFetching = PlatformPlaza.spriteFetcher(), changed: @escaping () -> Void, rebuild: @escaping () -> Void) {
        self.host = host
        self.drafts = drafts
        self.owner = owner
        self.fetcher = spriteFetcher
        self.changed = changed
        self.rebuild = rebuild
        let store = host.store
        flow = SaveTransferFlow(companion: host.companion, usage: { SaveImportTool.Usage.running(store) }, dialogs: dialogs ?? WinTransferDialogs(owner: owner, language: { [weak host] in host?.companion.l ?? L(.en) }),
                                appVersion: WinSettingsPage.appVersion, deviceName: ProcessInfo.processInfo.hostName)
        flow.onApplied = { [weak self] in self?.applied += 1 }
    }

    // MARK: difficulty (G9)

    func addDifficulty(to s: WinStack) {
        let l = self.l
        let draft = drafts.difficulty ?? PopoverDifficultyDraft(companion: companion)
        drafts.difficulty = draft
        let section = s.addSection(l.difficultySectionTitle)
        // The Mac's row: the name (76 pt), the slider, the value (52 pt), and under them the low and high words at the track's ends.
        func slider(_ label: String, low: String, high: String, value: Double, set: @escaping (inout PopoverDifficultyDraft, Double) -> Void) -> (row: WinRow, bar: WinControl?) {
            var lead: WinDifficultyLead?
            let row = section.addStyledRow(label: nil, style: .full) { p, c in
                lead = WinDifficultyLead(parent: p, ctx: c, name: label, low: low, high: high,
                                         bar: { pane in
                                             WinControls.trackbar(range: PopoverDifficultySlider.range, step: 1, value: PopoverDifficultySlider.position(of: value),
                                                                  format: { l.difficultyValue(PopoverDifficultySlider.value(atPosition: $0)) }, in: pane, ctx: c)
                                         })
                return lead?.control
            }
            if let bar = lead?.bar {
                _ = WinKit.send(bar.parts[0], 0x0415 /* TBM_SETPAGESIZE */, 0, PopoverDifficultySlider.page)
                showValue(bar, l.difficultyValue(value))
                bar.onValue = { [weak self, weak bar] position in
                    guard let self, let bar, !self.applying else { return }
                    var next = self.drafts.difficulty ?? PopoverDifficultyDraft(companion: self.companion)
                    set(&next, PopoverDifficultySlider.value(atPosition: position))
                    self.drafts.difficulty = next
                    self.showAccessibleValue(bar, l.difficultyValue(PopoverDifficultySlider.value(atPosition: position)))
                    self.changed()
                }
            }
            return (row, lead?.bar)
        }
        let g = slider(l.difficultyGrowthLabel, low: l.difficultyGrowthLowLabel, high: l.difficultyGrowthHighLabel, value: draft.growth) { $0.growth = $1 }
        let sh = slider(l.difficultyShopLabel, low: l.difficultyShopLowLabel, high: l.difficultyShopHighLabel, value: draft.shop) { $0.shop = $1 }
        growthRow = g.row; growthBar = g.bar; shopRow = sh.row; shopBar = sh.bar
        let actions = s.addSection(nil, card: false)
        saveRow = actions.addRow(nil) { p, c in WinControls.button(l.save, in: p, ctx: c) }
        saveRow?.control?.onClick = { [weak self] in self?.saveDifficulty() }
        saveRow?.isVisible = draft.differs(from: companion)
    }

    /// The text beside the slider and the accessible value (a trackbar reads its position, not the percent it stands for).
    private func showValue(_ bar: WinControl, _ text: String) {
        WinKit.setText(bar.parts[1], text)
        showAccessibleValue(bar, text)
    }

    private func showAccessibleValue(_ bar: WinControl, _ text: String) {
        _ = WinStr.w(text).withUnsafeBufferPointer { ptb_acc_set_value(UnsafeMutableRawPointer(bar.parts[0]), $0.baseAddress) }
    }

    private func saveDifficulty() {
        guard var draft = drafts.difficulty else { return }
        draft.save(to: companion)   // the store rescales the banked growth progress (`setGrowthDifficulty`)
        drafts.difficulty = draft
        showDraft()
        changed()
    }

    /// The sliders and their texts from the draft (after a save).
    private func showDraft() {
        guard let draft = drafts.difficulty else { return }
        applying = true
        defer { applying = false }
        for (bar, value) in [(growthBar, draft.growth), (shopBar, draft.shop)] {
            guard let bar else { continue }
            bar.value = PopoverDifficultySlider.position(of: value)
            showValue(bar, l.difficultyValue(value))
        }
    }

    // MARK: backup and transfer (G16)

    func addTransfer(to s: WinStack) {
        companion.refreshSnapshots()   // the Mac's onAppear
        let l = self.l
        let section = s.addSection(l.transferSectionTitle)
        exportRow = section.addRow(l.exportSaveLabel, hint: l.exportSaveHint) { p, c in WinControls.button(l.exportSaveButton, in: p, ctx: c) }
        exportRow?.control?.onClick = { [weak self] in self?.run { $0.export() } }
        importRow = section.addRow(l.importSaveLabel, hint: l.winImportSaveHint) { p, c in WinControls.button(l.importSaveButton, in: p, ctx: c) }
        importRow?.control?.onClick = { [weak self] in self?.run { $0.importSave() } }
        snapshotRow = section.addStyledRow(label: { p, c in WinControls.label(l.createSnapshotHint, style: .caption2, role: .tertiary, in: p, ctx: c) }) { p, c in
            WinControls.button(l.createSnapshotButton, in: p, ctx: c)
        }
        snapshotRow?.control?.onClick = { [weak self] in self?.run { $0.createSnapshot() } }
        let expanded = drafts.snapshotsExpanded
        historyRow = section.addRow(l.snapshotsSectionTitle) { p, c in
            WinControls.glyphButton(symbol: expanded ? "chevron.down" : "chevron.right", label: l.snapshotsSectionTitle, in: p, ctx: c)
        }
        if let toggle = historyRow?.control {
            let state = l.snapshotHistoryState(expanded: expanded)
            _ = WinStr.w(state).withUnsafeBufferPointer { ptb_acc_set_value(UnsafeMutableRawPointer(toggle.hwnd), $0.baseAddress) }
            toggle.tooltip = state
            toggle.onClick = { [weak self] in
                guard let self else { return }
                drafts.snapshotsExpanded.toggle()
                rebuild()
            }
        }
        let snapshots = companion.availableSnapshots
        builtSnapshotIDs = snapshots.map(\.id)
        transferBuilt = true
        guard expanded else { return }
        if snapshots.isEmpty {
            snapshotRows.append(section.addRow(nil, hint: l.noSnapshotsYet) { _, _ in nil })
            return
        }
        for snapshot in snapshots {
            let row = section.addStyledRow(label: { [weak self] p, c in
                guard let self else { return nil }
                return WinSnapshotLead(parent: p, ctx: c, snapshot: snapshot, language: companion.language, fetcher: fetcher)?.control
            }) { p, c in WinControls.button(l.restoreSnapshotButton, in: p, ctx: c) }
            row.control?.onClick = { [weak self] in self?.run { $0.restore(snapshot) } }
            snapshotRows.append(row)
        }
    }

    /// One flow (a click): the dialogs inside it run nested loops, so the page waits until it ends before it builds itself
    /// again, and a second click cannot start another (the owner is disabled while a dialog is open).
    private func run(_ action: (SaveTransferFlow) -> SaveTransferFlow.Outcome) {
        guard !isBusy else { return }
        isBusy = true
        let outcome = action(flow)
        isBusy = false
        flows += 1
        lastOutcome = outcome
        changed()
        if let after = afterBusy {
            afterBusy = nil
            after()
        }
    }

    // MARK: refresh

    /// Save only while the draft differs from the store; the page builds itself again when the list of snapshots changed.
    func apply() {
        saveRow?.isVisible = drafts.difficulty.map { $0.differs(from: companion) } ?? false
        if transferBuilt, builtSnapshotIDs != companion.availableSnapshots.map(\.id), !isBusy { rebuild() }
    }

    // MARK: for the selftest

    var difficultyRowsForTesting: (growth: WinControl?, shop: WinControl?, save: WinRow?, growthRow: WinRow?, shopRow: WinRow?) {
        (growthBar, shopBar, saveRow, growthRow, shopRow)
    }
    var transferRowsForTesting: (export: WinRow?, import: WinRow?, snapshot: WinRow?, history: WinRow?, snapshots: [WinRow]) {
        (exportRow, importRow, snapshotRow, historyRow, snapshotRows)
    }
    var draftForTesting: PopoverDifficultyDraft? { drafts.difficulty }
    /// Replaces the dialogs of the page that is built (the selftest scripts or drives them).
    func useDialogs(_ dialogs: any TransferDialogs) { flow.dialogs = dialogs }
}

/// One difficulty row as the Mac lays it out (`DifficultySettingsSection.row`): the name in a 76 pt column, the slider with its
/// value (52 pt) to the right, and under them the low and high words, inset 86 pt from the left and 62 pt from the right so each
/// sits under its end of the track. One child window of the page holding all of them, placed as one control.
@MainActor final class WinDifficultyLead {
    private let pane: WinPane
    private var name: WinControl?
    private(set) var bar: WinControl?
    private var low: WinControl?
    private var high: WinControl?
    let control: WinControl
    private let ctx: WinUIContext

    init?(parent: HWND, ctx: WinUIContext, name: String, low: String, high: String, bar makeBar: (HWND) -> WinControl?) {
        guard let pane = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 1, bottom: 1)) else { return nil }
        self.pane = pane
        self.ctx = ctx
        let card = ctx.colors.palette.card
        pane.paint = { dc, rect in
            var r = rect
            _ = FillRect(dc, &r, ctx.colors.brush(card))
        }
        // The name first: the static before a slider is its accessible name.
        self.name = WinControls.label(name, wraps: false, in: pane.hwnd, ctx: ctx)
        self.bar = makeBar(pane.hwnd)
        self.low = WinControls.label(low, style: .caption2, role: .secondary, wraps: false, in: pane.hwnd, ctx: ctx)
        self.high = WinControls.label(high, style: .caption2, role: .secondary, wraps: false, in: pane.hwnd, ctx: ctx)
        for c in [self.name, self.bar, self.low, self.high] { c?.background = card }
        control = WinControls.drawn(pane.hwnd, size: CGSize(width: 100, height: CGFloat(Self.height(ctx, name: self.name, bar: self.bar, low: self.low))), ctx: ctx) { _ in }
        control.onFrame = { r in self.place(r) }
        control.onDestroy = { self.destroy() }
    }

    private static func height(_ ctx: WinUIContext, name: WinControl?, bar: WinControl?, low: WinControl?) -> Int32 {
        let top = max(Int32(name?.preferredSize.height ?? 0), Int32(bar?.preferredSize.height ?? 0))
        return top + ctx.px(2) + Int32(low?.preferredSize.height ?? 0)
    }

    private func place(_ r: RECT) {
        pane.move(r)
        let w = r.right - r.left
        let nameH = Int32(name?.preferredSize.height ?? 0), barH = Int32(bar?.preferredSize.height ?? 0)
        let top = max(nameH, barH)
        let nameW = ctx.px(76), gap = ctx.px(10)
        name?.frame(RECT(left: 0, top: (top - nameH) / 2, right: nameW, bottom: (top - nameH) / 2 + nameH))
        bar?.frame(RECT(left: nameW + gap, top: (top - barH) / 2, right: w, bottom: (top - barH) / 2 + barH))
        let capY = top + ctx.px(2)
        if let low {
            let x = ctx.px(86)
            low.frame(RECT(left: x, top: capY, right: x + Int32(low.preferredSize.width), bottom: capY + Int32(low.preferredSize.height)))
        }
        if let high {
            let right = w - ctx.px(62), x = right - Int32(high.preferredSize.width)
            high.frame(RECT(left: x, top: capY, right: right, bottom: capY + Int32(high.preferredSize.height)))
        }
    }

    private func destroy() {
        for c in [name, bar, low, high] { c?.destroy() }
        name = nil; bar = nil; low = nil; high = nil
        pane.destroy()
    }
}

/// The left side of a snapshot row (the Mac's `snapshotRow`): the 28 pt sprite, the date and the "Pokédex n · tokens" line. One
/// child window of the page holding the sprite's drawn view and two labels, placed as one control.
@MainActor final class WinSnapshotLead {
    private let pane: WinPane
    private var sprite: WinDrawnView?
    private var date: WinControl?
    private var counts: WinControl?
    let control: WinControl
    private let ctx: WinUIContext
    private let gap: Int32

    init?(parent: HWND, ctx: WinUIContext, snapshot: SaveSnapshot, language: AppLanguage, fetcher: any PlazaSpriteFetching) {
        guard let pane = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 1, bottom: 1)) else { return nil }
        self.pane = pane
        self.ctx = ctx
        gap = ctx.px(8)
        let l = L(language)
        let card = ctx.colors.palette.card
        pane.paint = { dc, rect in
            var r = rect
            _ = FillRect(dc, &r, ctx.colors.brush(card))
        }
        let side = ctx.px(SnapshotSpritePart.side)
        if let view = try? WinDrawnView(parent: pane.hwnd, ctx: ctx) {
            view.background = card
            view.sprites = WinSpriteAnimator(fetcher: fetcher)
            view.host(SnapshotSpritePart(speciesID: snapshot.currentSpeciesID, shiny: snapshot.currentIsShiny, form: snapshot.currentForm),
                      width: SnapshotSpritePart.side)
            sprite = view
        }
        date = WinControls.label(PopoverTransferFormat.exportedAtText(snapshot.date, language: language), style: .caption, wraps: false,
                                 in: pane.hwnd, ctx: ctx)
        counts = WinControls.label(l.snapshotDexAndTokens(dex: snapshot.dexCount, tokens: TokenFormatter.compact(snapshot.lifetimeTokens)),
                                   style: .caption2, role: .secondary, wraps: false, in: pane.hwnd, ctx: ctx)
        date?.background = card
        counts?.background = card
        let textW = Int32(max(date?.preferredSize.width ?? 0, counts?.preferredSize.width ?? 0))
        let textH = Int32((date?.preferredSize.height ?? 0) + (counts?.preferredSize.height ?? 0)) + ctx.px(2)
        let size = CGSize(width: CGFloat(side + gap + textW), height: CGFloat(max(side, textH)))
        control = WinControls.drawn(pane.hwnd, size: size, ctx: ctx) { _ in }
        // Strong on purpose: the control is the lead's only owner. `WinControl.destroy` drops both callbacks.
        control.onFrame = { r in self.place(r) }
        control.onDestroy = { self.destroy() }
    }

    private func place(_ r: RECT) {
        pane.move(r)
        let h = r.bottom - r.top
        let side = ctx.px(SnapshotSpritePart.side)
        sprite?.control.frame(RECT(left: 0, top: (h - side) / 2, right: side, bottom: (h - side) / 2 + side))
        let dh = Int32(date?.preferredSize.height ?? 0), ch = Int32(counts?.preferredSize.height ?? 0)
        let top = (h - (dh + ch + ctx.px(2))) / 2
        let x = side + gap
        if let date { date.frame(RECT(left: x, top: top, right: x + Int32(date.preferredSize.width), bottom: top + dh)) }
        if let counts {
            let y = top + dh + ctx.px(2)
            counts.frame(RECT(left: x, top: y, right: x + Int32(counts.preferredSize.width), bottom: y + ch))
        }
    }

    private func destroy() {
        sprite?.destroy()
        date?.destroy()
        counts?.destroy()
        sprite = nil
        date = nil
        counts = nil
        pane.destroy()
    }
}
#endif
