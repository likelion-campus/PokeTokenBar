#if os(Windows)
import CPlazaD2D
import CWinShim
import Foundation
import WinSDK

// Stage 7 Task 15: the Difficulty and Backup & transfer rows of the Settings page (`settings.difficulty*`, `settings.dialog*`,
// `settings.exportImport`, `settings.importCancelDefault`, `settings.snapshots`, `settings.transferCapture`). The page opens in a
// popover of its own over FIXTURE stores in a temp profile (the app's store, companion and the real settings are not touched). The
// REAL dialogs are opened by the page's own buttons (a click is a window message, as in the app) and a helper thread drives
// them: it finds the dialog by its owner (the popover), sets the file name, presses a button with `TDM_CLICK_BUTTON` or posts a
// key, while main-queue blocks count that the main queue keeps running. A person is needed for nothing here, and none of it
// runs without `CI` (real keys, the foreground).

extension WindowsSelftest {
    @MainActor static func popoverTransferChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestTransfer.run(r, app)
    }
}

/// A sprite fetcher that has nothing (the snapshot rows show the egg glyph): the fixture rows must not ask the network.
private struct TransferNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Answers the file dialogs from a script (or opens the real one when the answer is nil) and always uses the real task dialogs.
@MainActor final class TransferHybridDialogs: TransferDialogs {
    let real: WinTransferDialogs
    var scriptedOpen: URL?
    var scriptedSave: URL?
    var scriptedConfirm: Bool?
    private(set) var informs: [(title: String, message: String, isError: Bool)] = []
    private(set) var revealed: [URL] = []
    /// Everything is scripted, nothing real opens (the page-level checks).
    var allScripted = false
    private(set) var confirms = 0

    init(real: WinTransferDialogs) {
        self.real = real
        real.revealFile = { [weak self] in self?.revealed.append($0) }
    }

    func chooseSaveFile(title: String, suggestedName: String) -> URL? {
        if allScripted || scriptedSave != nil { return scriptedSave }
        return real.chooseSaveFile(title: title, suggestedName: suggestedName)
    }

    func chooseOpenFile(title: String) -> URL? {
        if allScripted || scriptedOpen != nil { return scriptedOpen }
        return real.chooseOpenFile(title: title)
    }

    func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String) -> Bool {
        confirms += 1
        if let scriptedConfirm { return scriptedConfirm }
        return real.confirm(title: title, message: message, confirmTitle: confirmTitle, cancelTitle: cancelTitle)
    }

    func inform(title: String, message: String, isError: Bool) {
        informs.append((title, message, isError))
        if !allScripted { real.inform(title: title, message: message, isError: isError) }
    }

    func reveal(_ file: URL) { real.reveal(file) }
}

/// Drives the dialogs of one flow from a helper thread, step by step. Nothing here touches app state except posting main-queue
/// blocks and window messages; the facts it reads (owner, visibility, the thread) are plain Win32 queries.
final class TransferDialogDriver: @unchecked Sendable {
    enum Step {
        /// A file dialog: type this path into the file name box and press Save / Open.
        case typePath(String)
        /// A file dialog: close it as a cancel (`IFileDialog::Close`, from the main queue).
        case cancelFile
        /// A task dialog: press the custom button with this index.
        case click(Int)
        /// A task dialog: send this key to the dialog (Enter presses the default button, Esc cancels).
        case key(UInt16)
        /// A task dialog: close it as a cancel (from the main queue).
        case cancelTask
        /// A dialog (file or task): copy the dialog's rectangle off the screen to this PNG, then press Esc (a cancel).
        case captureThenEscape(URL)
    }

    struct Fact: Sendable {
        var step: String
        var found = false
        var owned = false
        var visible = false
        var onMainThread = false
        var ownerAlive = false
        var ranWhileOpen = 0
        var closed = false
        var note = ""
    }

    private let ownerBits: Int
    private let mainThread: DWORD
    private let steps: [Step]
    private let lock = NSLock()
    private var facts: [Fact] = []
    private var finished = false
    private var ran = 0
    private var watchdogFired = false

    init(ownerBits: Int, mainThread: DWORD, steps: [Step]) {
        self.ownerBits = ownerBits
        self.mainThread = mainThread
        self.steps = steps
    }

    var results: [Fact] { lock.lock(); defer { lock.unlock() }; return facts }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var watchdog: Bool { lock.lock(); defer { lock.unlock() }; return watchdogFired }

    func start() {
        Thread { [self] in run() }.start()
        // Nothing may leave the main thread inside a modal loop: after 90 s every dialog of the popover is closed, again and again.
        Thread { [self] in
            let end = Date(timeIntervalSinceNow: 90)
            while Date() < end { if isFinished { return }; Thread.sleep(forTimeInterval: 0.5) }
            lock.lock(); watchdogFired = true; lock.unlock()
            for _ in 0..<60 where !isFinished { closeEverything(); Thread.sleep(forTimeInterval: 1) }
        }.start()
    }

    // MARK: Win32 queries (any thread)

    /// The visible top-level dialogs owned by the popover (the file dialog and the task dialog are both `#32770`).
    static func owned(by ownerBits: Int) -> [Int] {
        var out: [Int] = []
        var previous: HWND?
        let cls = WinStr.w("#32770")
        while let h = FindWindowExW(nil, previous, cls, nil) {
            previous = h
            guard IsWindowVisible(h), let owner = GetWindow(h, UINT(GW_OWNER)), Int(bitPattern: owner) == ownerBits else { continue }
            out.append(Int(bitPattern: h))
        }
        return out
    }

    static func descendants(of root: HWND) -> [HWND] {
        var out: [HWND] = []
        func walk(_ parent: HWND) {
            var child = GetWindow(parent, UINT(GW_CHILD))
            while let h = child {
                out.append(h)
                walk(h)
                child = GetWindow(h, UINT(GW_HWNDNEXT))
            }
        }
        walk(root)
        return out
    }

    private func waitForDialog(excluding handled: Set<Int>, timeout: TimeInterval) -> Int? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let found = Self.owned(by: ownerBits).first(where: { !handled.contains($0) }) {
                Thread.sleep(forTimeInterval: 0.6)   // let it finish drawing and take the focus
                return found
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func closeEverything() {
        for bits in Self.owned(by: ownerBits) {
            guard let h = HWND(bitPattern: bits) else { continue }
            _ = PostMessageW(h, 0x0466 /* TDM_CLICK_BUTTON */, 2 /* IDCANCEL */, 0)
            _ = PostMessageW(h, UINT(WM_CLOSE), 0, 0)
        }
    }

    private func sendKey(_ vk: UInt16) {
        var inputs: [INPUT] = []
        func ki(up: Bool) -> INPUT {
            var i = INPUT()
            i.type = DWORD(INPUT_KEYBOARD)
            i.ki.wVk = vk
            i.ki.dwFlags = up ? DWORD(KEYEVENTF_KEYUP) : 0
            return i
        }
        inputs = [ki(up: false), ki(up: true)]
        _ = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    private func run() {
        var handled = Set<Int>()
        for (index, step) in steps.enumerated() {
            var fact = Fact(step: "\(index + 1):\(String(describing: step).prefix(24))")
            guard let bits = waitForDialog(excluding: handled, timeout: 25), let dialog = HWND(bitPattern: bits) else {
                fact.note = "no dialog owned by the popover appeared within 25 s"
                record(fact)
                lock.lock(); watchdogFired = true; lock.unlock()
                closeEverything()   // never leave the main thread inside a modal loop nobody ends
                finish()
                return
            }
            handled.insert(bits)
            fact.found = true
            fact.owned = true
            fact.visible = IsWindowVisible(dialog)
            fact.onMainThread = GetWindowThreadProcessId(dialog, nil) == mainThread
            fact.ownerAlive = IsWindow(HWND(bitPattern: ownerBits))
            // The main queue keeps running while the dialog is open: ten blocks, 20 ms apart, each counted when it runs.
            lock.lock(); ran = 0; lock.unlock()
            for _ in 0..<10 {
                DispatchQueue.main.async { [self] in lock.lock(); ran += 1; lock.unlock() }
                Thread.sleep(forTimeInterval: 0.02)
            }
            Thread.sleep(forTimeInterval: 0.3)
            lock.lock(); fact.ranWhileOpen = ran; lock.unlock()
            var cancelWait: TimeInterval = 10
            switch step {
            case .typePath(let path):
                let edit = Self.descendants(of: dialog).first { WinKit.className($0) == "Edit" && IsWindowVisible($0) }
                if let edit {
                    var result: DWORD_PTR = 0
                    _ = WinStr.w(path).withUnsafeBufferPointer {
                        SendMessageTimeoutW(edit, UINT(WM_SETTEXT), 0, LPARAM(Int(bitPattern: $0.baseAddress)), UINT(SMTO_ABORTIFHUNG), 3000, &result)
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                    // Save / Open is the button with the id 1; without it Enter in the file name box does the same.
                    let button = Self.descendants(of: dialog).first { WinKit.className($0) == "Button" && GetDlgCtrlID($0) == 1 }
                    if let button {
                        _ = PostMessageW(button, 0x00F5 /* BM_CLICK */, 0, 0)
                    } else {
                        _ = PostMessageW(edit, UINT(WM_KEYDOWN), WPARAM(VK_RETURN), 0)
                        _ = PostMessageW(edit, UINT(WM_KEYUP), WPARAM(VK_RETURN), LPARAM(Int(bitPattern: UInt(0xC000_0001))))
                    }
                    var how = button == nil ? "Enter posted to the box" : "the id-1 button clicked"
                    let wait = Date(timeIntervalSinceNow: 2.5)
                    while IsWindow(dialog), Date() < wait { Thread.sleep(forTimeInterval: 0.05) }
                    if IsWindow(dialog) {
                        _ = SetForegroundWindow(dialog)
                        Thread.sleep(forTimeInterval: 0.2)
                        sendKey(UInt16(VK_RETURN))
                        how += ", then a real Enter"
                    }
                    fact.note = "typed \(path.count) characters into the file name box (\(how))"
                } else {
                    fact.note = "no file name box found"
                    closeEverything()
                }
            case .cancelFile:
                DispatchQueue.main.async { WinFileDialog.closeOpenDialog() }
                cancelWait = 3
            case .click(let index):
                _ = PostMessageW(dialog, 0x0466 /* TDM_CLICK_BUTTON */, WPARAM(1000 + index), 0)
            case .key(let vk):
                _ = SetForegroundWindow(dialog)
                Thread.sleep(forTimeInterval: 0.2)
                fact.note = "foreground is the dialog: \(GetForegroundWindow() == dialog)"
                sendKey(vk)
            case .cancelTask:
                DispatchQueue.main.async { WinTaskDialog.closeOpenDialog() }
                cancelWait = 3
            case .captureThenEscape(let file):
                var rect = RECT()
                _ = GetWindowRect(dialog, &rect)
                let w = Int(rect.right - rect.left), h = Int(rect.bottom - rect.top)
                if w > 0, h > 0, let bitmap = WinUIDump.screenshot(x: Int(rect.left), y: Int(rect.top), w: w, h: h) {
                    fact.note = "captured \(w)x\(h) write=\(WinUIDump.write(bitmap, to: file))"
                } else {
                    fact.note = "capture failed"
                }
                _ = SetForegroundWindow(dialog)
                Thread.sleep(forTimeInterval: 0.2)
                sendKey(UInt16(VK_ESCAPE))
            }
            // The dialog goes away.
            let deadline = Date(timeIntervalSinceNow: cancelWait)
            while IsWindow(dialog), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            fact.closed = !IsWindow(dialog)
            if !fact.closed {
                if cancelWait < 10 { fact.note += " the close posted to the main queue was not served within \(Int(cancelWait)) s;" }
                closeEverything()
            }
            record(fact)
            Thread.sleep(forTimeInterval: 0.3)
        }
        finish()
    }

    private func record(_ fact: Fact) { lock.lock(); facts.append(fact); lock.unlock() }
    private func finish() { lock.lock(); finished = true; lock.unlock() }
}

@MainActor enum WindowsSelftestTransfer {
    static let names = ["settings.difficulty", "settings.difficultyKeys", "settings.dialogKeepsPopover", "settings.exportImport",
                        "settings.importCancelDefault", "settings.dialogExit", "settings.snapshots", "settings.transferA11y"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            for name in names { r.add(name, true, "skipped: CI not set (the page takes the foreground; real keys and real dialogs)") }
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("settings.difficulty", false, "no probe window: \(GetLastError())")
            return
        }
        defer { probe.destroy() }
        let t = await TransferRun(r: r, app: app, probe: probe)
        await t.difficultyCheck()
        await t.difficultyKeysCheck()
        await t.dialogKeepsPopoverCheck()
        await t.exportImportCheck()
        await t.importCancelDefaultCheck()
        await t.dialogExitCheck()
        await t.snapshotsCheck()
        await t.a11yCheck()
        if let dir = WindowsSelftestPopoverWindow.dumpDirectory().map({ $0.deletingLastPathComponent().appendingPathComponent("settings", isDirectory: true) }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await t.captureChecks(dir)
        }
        t.cleanUp()
    }
}

@MainActor final class TransferRun {
    let r: WindowsSelftest.Recorder
    let app: WindowsAppDelegate
    let probe: WinSinkWindow
    var stores: HomeStores
    var popover: WinPopover?
    var hybrid: TransferHybridDialogs?
    let work: URL
    let loginKey = #"Software\PokeTokenBarSelftest\Transfer\Run"#, approvedKey = #"Software\PokeTokenBarSelftest\Transfer\Approved"#
    var page: WinSettingsPage? { popover?.pageForTesting as? WinSettingsPage }
    var hwnd: HWND? { popover?.hwndForTesting }
    var section: WinTransferSection? { page?.transferForTesting }
    var l: L { stores.companion.l }
    var companion: CompanionStore { stores.companion }

    init(r: WindowsSelftest.Recorder, app: WindowsAppDelegate, probe: WinSinkWindow) async {
        self.r = r
        self.app = app
        self.probe = probe
        stores = await HomeStores.make(language: .en)
        // A folder with a space and Korean characters in its name: the user's profile folder can be named so.
        work = FileManager.default.temporaryDirectory.appendingPathComponent("ptb transfer 한글 \(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func cleanUp() {
        close()
        stores.companion.setGrowthDifficulty(1)
        stores.companion.setShopDifficulty(1)
        stores.remove()
        try? FileManager.default.removeItem(at: work)
    }

    func pause(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }
    func waitFor(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool { await WindowsSelftest.waitUntil(timeout: timeout, condition) }

    func fixtureLoginItem() -> WindowsLoginItem {
        WindowsLoginItem(runKey: loginKey, approvedKey: approvedKey, valueName: "PokeTokenBarTransfer",
                         command: WindowsLoginItem.command(forExecutable: #"C:\Fixture\PokeTokenBar.exe"#))
    }

    // MARK: opening

    @discardableResult
    func open(language: AppLanguage? = nil, allScripted: Bool = false, expanded: Bool = false) async -> Bool {
        close()
        if let language { stores.companion.setLanguage(language) }
        let host = WinPopoverHost(store: stores.store, companion: stores.companion, updater: nil, team: stores.team, session: nil, feed: nil, tray: nil,
                                  loginItem: fixtureLoginItem(), openPlaza: {})
        host.owner = app.sink.hwnd
        let p = WinPopover(host: host)
        var made: TransferHybridDialogs?
        p.makePage = { pop in
            let routed = WinSettingsPage.routed(pop)
            guard let page = routed as? WinSettingsPage else { return routed }
            let real = WinTransferDialogs(owner: { [weak pop] in pop?.hwndForTesting }, language: { [weak pop] in pop?.host.companion.l ?? L(.en) })
            let dialogs = TransferHybridDialogs(real: real)
            dialogs.allScripted = allScripted
            made = dialogs
            page.transferDialogs = dialogs
            page.transferSpriteFetcher = TransferNoSprites()
            return page
        }
        popover = p
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await waitFor(1) { GetForegroundWindow() == self.probe.hwnd }
        p.present(.secondLaunch) { $0.showSettings = true }
        let up = await waitFor(3) {
            guard let h = p.hwndForTesting else { return false }
            return IsWindowVisible(h) && GetForegroundWindow() == h && p.pageForTesting is WinSettingsPage
        }
        await pause(0.3)
        hybrid = made
        if expanded, let section, let history = section.transferRowsForTesting.history?.control {
            click(history)
            _ = await waitFor(2) { self.section?.transferRowsForTesting.history?.control !== history && self.section != nil }
            await pause(0.5)
            hybrid = page?.transferDialogs as? TransferHybridDialogs
        }
        return up
    }

    func close() {
        popover?.close(.destroyed)
        popover = nil
    }

    func click(_ control: WinControl?) {
        guard let control else { return }
        WinKit.send(control.hwnd, 0x00F5 /* BM_CLICK */)
    }

    /// A click that arrives as a window message, as a user's does: the modal loop of a dialog must not start inside a main-queue
    /// item (a Task such as this check), where libdispatch's serial main queue serves nothing else (the kit's `ui.kit.menuKeys`).
    func post(_ control: WinControl?) {
        guard let control else { return }
        _ = PostMessageW(control.hwnd, 0x00F5 /* BM_CLICK */, 0, 0)
    }

    func choose(_ combo: WinControl?, _ index: Int) {
        guard let combo, let parent = GetParent(combo.hwnd) else { return }
        WinKit.send(combo.hwnd, 0x014E /* CB_SETCURSEL */, index)
        let id = Int(GetDlgCtrlID(combo.hwnd))
        _ = SendMessageW(parent, UINT(WM_COMMAND), WPARAM(UInt(id & 0xFFFF) | (1 << 16) /* CBN_SELCHANGE */), LPARAM(Int(bitPattern: UnsafeMutableRawPointer(combo.hwnd))))
    }

    func slide(_ bar: WinControl?, to value: Int) {
        guard let bar, let parent = GetParent(bar.parts[0]) else { return }
        WinKit.send(bar.parts[0], 0x0405 /* TBM_SETPOS */, 1, value)
        _ = SendMessageW(parent, 0x0114 /* WM_HSCROLL */, 8 /* SB_ENDSCROLL */, LPARAM(Int(bitPattern: UnsafeMutableRawPointer(bar.parts[0]))))
    }

    func trackPosition(_ bar: WinControl?) -> Int { bar.map { WinKit.send($0.parts[0], 0x0400 /* TBM_GETPOS */) } ?? -1 }
    func valueText(_ bar: WinControl?) -> String { bar.map { WinKit.text(of: $0.parts[1]) } ?? "" }
    func shown(_ row: WinRow?) -> Bool { row.map { IsWindowVisible($0.control?.hwnd ?? $0.label?.hwnd) } ?? false }

    func describe(_ control: WinControl?) -> (name: String, value: String, hr: Int32) {
        guard let control else { return ("", "", -1) }
        var name = [UInt16](repeating: 0, count: 256), value = [UInt16](repeating: 0, count: 256)
        let hr = name.withUnsafeMutableBufferPointer { n in
            value.withUnsafeMutableBufferPointer { v in
                ptb_acc_describe(UnsafeMutableRawPointer(control.parts[0]), n.baseAddress, 256, v.baseAddress, 256)
            }
        }
        func text(_ b: [UInt16]) -> String { String(decoding: b[0..<(b.firstIndex(of: 0) ?? b.count)], as: UTF16.self) }
        return (text(name), text(value), hr)
    }

    func key(_ vk: UInt16) {
        var inputs: [INPUT] = []
        for up in [false, true] {
            var i = INPUT()
            i.type = DWORD(INPUT_KEYBOARD)
            i.ki.wVk = vk
            i.ki.dwFlags = up ? DWORD(KEYEVENTF_KEYUP) : 0
            inputs.append(i)
        }
        _ = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    func focus(_ control: WinControl?) async {
        guard let control else { return }
        _ = SetFocus(control.hwnd)
        _ = await waitFor(0.5) { GetFocus() == control.hwnd }
    }

    // MARK: settings.difficulty

    func difficultyCheck() async {
        stores.companion.setGrowthDifficulty(1)
        stores.companion.setShopDifficulty(1)
        guard await open(), let page, let section = section else { r.add("settings.difficulty", false, "no page"); return }
        let rows = section.difficultyRowsForTesting
        let growth = rows.growth?.control, shop = rows.shop?.control
        let startPositions = (trackPosition(growth), trackPosition(shop))
        let expectedStart = PopoverDifficultySlider.position(of: 1)
        let startText = (valueText(growth), valueText(shop))
        let saveHiddenAtStart = !shown(rows.save)
        // Drag the growth slider: the draft changes, the store does not, Save appears, the text follows.
        slide(growth, to: 100)
        await pause(0.3)
        let draftGrowth = section.draftForTesting?.growth ?? -1
        let expectedGrowth = PopoverDifficultySlider.value(atPosition: 100)
        let storeUntouched = stores.companion.growthDifficulty == 1 && stores.companion.shopDifficulty == 1
        let saveShown = shown(rows.save)
        let draftText = valueText(growth)
        let a11y = describe(growth)
        // Save writes both values and Save goes away again.
        let eggBefore = stores.companion.state.eggUsage
        click(rows.save?.control)
        await pause(0.3)
        let saved = stores.companion.growthDifficulty == expectedGrowth && stores.companion.shopDifficulty == 1
        let saveGone = !shown(rows.save)
        // A draft survives the page being built again (a language change), as the Mac's @State does; a page closed and opened again
        // starts from the store (the draft is discarded: "cancel").
        slide(shop, to: 60)
        await pause(0.2)
        let shopDraft = PopoverDifficultySlider.value(atPosition: 60)
        choose(page.rowsForTesting.language?.control, AppLanguage.allCases.firstIndex(of: .ja) ?? 0)
        let rebuilt = await waitFor(3) { self.page?.rowsForTesting.language?.control !== page.rowsForTesting.language?.control || self.page?.rebuildsForTesting ?? 0 > 0 }
        await pause(0.6)
        let afterRebuild = self.section?.difficultyRowsForTesting
        let keptDraft = (self.section?.draftForTesting?.shop ?? -1) == shopDraft && PopoverDifficultySlider.value(atPosition: trackPosition(afterRebuild?.shop?.control)) == shopDraft && shown(afterRebuild?.save)
        stores.companion.setLanguage(.en)
        close()
        _ = await open()
        let reopened = self.section?.difficultyRowsForTesting
        let discarded = trackPosition(reopened?.shop?.control) == PopoverDifficultySlider.position(of: 1) && !shown(reopened?.save)
            && valueText(reopened?.growth?.control) == l.difficultyValue(expectedGrowth)
        r.add("settings.difficulty",
              startPositions == (expectedStart, expectedStart) && startText == (l.difficultyValue(1), l.difficultyValue(1)) && saveHiddenAtStart
                && draftGrowth == expectedGrowth && storeUntouched && saveShown && draftText == l.difficultyValue(expectedGrowth)
                && a11y.value == l.difficultyValue(expectedGrowth) && !a11y.name.isEmpty && saved && saveGone && rebuilt && keptDraft && discarded,
              "positions at start \(startPositions) (expected \(expectedStart)) text \(startText); Save hidden=\(saveHiddenAtStart); dragged growth to 100 -> draft \(draftGrowth) "
                + "(expected \(expectedGrowth)), store untouched=\(storeUntouched), Save shown=\(saveShown), text '\(draftText)', accessible name '\(a11y.name)' value '\(a11y.value)' hr=\(a11y.hr); "
                + "Save -> store growth \(stores.companion.growthDifficulty) shop \(stores.companion.shopDifficulty) saved=\(saved), Save gone=\(saveGone), egg progress \(eggBefore) -> \(stores.companion.state.eggUsage); "
                + "shop draft kept across a language rebuild=\(keptDraft) (rebuilt=\(rebuilt)); page closed and opened again shows the store=\(discarded)")
        close()
    }

    // MARK: settings.difficultyKeys

    func difficultyKeysCheck() async {
        stores.companion.setGrowthDifficulty(1)
        stores.companion.setShopDifficulty(1)
        guard await open(), let section = section, let bar = section.difficultyRowsForTesting.growth?.control else { r.add("settings.difficultyKeys", false, "no slider"); return }
        await focus(bar)
        func press(_ vk: Int32) async -> Int {
            key(UInt16(vk))
            await pause(0.25)
            return trackPosition(bar)
        }
        let max = PopoverDifficultySlider.resolution
        let home = await press(VK_HOME)
        let end = await press(VK_END)
        let left = await press(VK_LEFT)
        let right = await press(VK_RIGHT)
        let pageUp = await press(VK_PRIOR)
        let pageDown = await press(VK_NEXT)
        let draft = section.draftForTesting?.growth ?? -1
        let follows = draft == PopoverDifficultySlider.value(atPosition: pageDown) && valueText(bar) == l.difficultyValue(draft)
        let page = PopoverDifficultySlider.page
        r.add("settings.difficultyKeys",
              home == 0 && end == max && left == max - 1 && right == max && abs(pageUp - max) == page && pageDown == max && follows,
              "focused growth slider: Home -> \(home) (expected 0), End -> \(end) (expected \(max)), Left -> \(left) (expected \(max - 1)), Right -> \(right), PageUp -> \(pageUp) "
                + "(a page is \(page)), PageDown -> \(pageDown); the draft and the text follow the position=\(follows) (draft \(draft), text '\(valueText(bar))')")
        close()
    }

    // MARK: settings.dialogKeepsPopover

    /// Runs one click of the page under a driver; returns the facts and what the popover looked like afterwards.
    func driven(_ steps: [TransferDialogDriver.Step], click action: () -> Void) async -> (facts: [TransferDialogDriver.Fact], watchdog: Bool, open: Bool, foreground: Bool, closes: Int) {
        guard let hwnd, let popover else { return ([], false, false, false, 0) }
        let driver = TransferDialogDriver(ownerBits: Int(bitPattern: hwnd), mainThread: GetCurrentThreadId(), steps: steps)
        let closesBefore = popover.stats.closes
        driver.start()
        action()   // posts the control's click: a window message, the dialog's modal loop runs inside it
        _ = await waitFor(100) { driver.isFinished }
        let back = await waitFor(3) { GetForegroundWindow() == hwnd }
        return (driver.results, driver.watchdog, IsWindowVisible(hwnd) && self.popover?.pageForTesting != nil, back, popover.stats.closes - closesBefore)
    }

    func dialogKeepsPopoverCheck() async {
        guard await open(), let section = section, let hybrid else { r.add("settings.dialogKeepsPopover", false, "no page"); return }
        let rows = section.transferRowsForTesting
        let pageBefore = popover?.pageForTesting.map { ObjectIdentifier($0) }
        let opensBefore = WinFileDialog.opened, tasksBefore = WinTaskDialog.shown
        let ticksBefore = WinModalPump.ticks, hookBefore = WinModalPump.hookTicks, skippedBefore = WinModalPump.ticksSkippedForInput
        // The save dialog, the open dialog and the import confirmation, each closed as a cancel.
        let save = await driven([.cancelFile]) { self.post(rows.export?.control) }
        let open = await driven([.cancelFile]) { self.post(rows.import?.control) }
        // A scripted choice of a (valid) file makes the real confirmation appear: Esc cancels it.
        let file = work.appendingPathComponent("confirm.json")
        let envelope = try? SaveTransfer.encode(state: CompanionState(), appVersion: "2.5.0", deviceName: "Fixture", now: Date())
        if let envelope { try? PlatformCompat.atomicWrite(envelope, to: file) }
        hybrid.scriptedOpen = file
        let confirm = await driven([.cancelTask]) { self.post(rows.import?.control) }
        hybrid.scriptedOpen = nil
        let all = [("save", save), ("open", open), ("confirm", confirm)]
        let ok = all.allSatisfy { _, x in
            x.facts.count == 1 && !x.watchdog && x.facts[0].found && x.facts[0].owned && x.facts[0].visible && x.facts[0].onMainThread && x.facts[0].ownerAlive
                && x.facts[0].ranWhileOpen >= 8 && x.facts[0].closed && x.open && x.foreground && x.closes == 0
        }
        let samePage = popover?.pageForTesting.map { ObjectIdentifier($0) } == pageBefore
        let outcomes = section.lastOutcome
        func line(_ name: String, _ x: (facts: [TransferDialogDriver.Fact], watchdog: Bool, open: Bool, foreground: Bool, closes: Int)) -> String {
            guard let f = x.facts.first else { return "\(name): no facts" }
            return "\(name): found=\(f.found) owned by the popover=\(f.owned) visible=\(f.visible) on the main thread=\(f.onMainThread) main-queue blocks run while open=\(f.ranWhileOpen)/10 "
                + "closed=\(f.closed) popover still open=\(x.open) focus back=\(x.foreground) popover closes=\(x.closes) \(f.note)"
        }
        r.add("settings.dialogKeepsPopover", ok && samePage && outcomes == .cancelled && WinFileDialog.opened == opensBefore + 2 && WinTaskDialog.shown == tasksBefore + 1,
              "each real dialog opened by the page's own button, driven from a helper thread: \(line("save", save)); \(line("open", open)); \(line("import confirmation", confirm)); "
                + "same page object=\(samePage); last outcome \(String(describing: outcomes)); file dialogs +\(WinFileDialog.opened - opensBefore), task dialogs +\(WinTaskDialog.shown - tasksBefore); "
                + "pump ticks +\(WinModalPump.ticks - ticksBefore) of which from the hook +\(WinModalPump.hookTicks - hookBefore), skipped for input +\(WinModalPump.ticksSkippedForInput - skippedBefore); notes \(save.facts.map { $0.note } + open.facts.map { $0.note } + confirm.facts.map { $0.note })")
        close()
    }

    // MARK: settings.exportImport

    /// A state of this fixture companion: a save with `dex` Pokédex entries, applied through the same function the import uses.
    func setState(dex: Int, tokens: Int) throws {
        var s = CompanionState()
        s.usedSinceInstall = tokens
        s.dex = (0..<dex).map { DexEntry(baseID: 1 + $0 * 3, finalID: 3 + $0 * 3, chainOrder: [1 + $0 * 3, 3 + $0 * 3], rarity: .common, caughtAt: Date()) }
        let data = try SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Fixture", now: Date())
        try SaveImportTool.apply(try SaveTransfer.decode(data), to: stores.companion, usage: .none)
    }

    func exportImportCheck() async {
        do { try setState(dex: 2, tokens: 123_456) } catch { r.add("settings.exportImport", false, "fixture: \(error)"); return }
        guard await open(), let section = section, let hybrid else { r.add("settings.exportImport", false, "no page"); return }
        let rows = section.transferRowsForTesting
        let exported = stores.companion.transferSummary
        let target = work.appendingPathComponent("my save – 백업.json")
        // 1. Export through the real save dialog: the path typed into its file name box, Save pressed.
        let export = await driven([.typePath(WinPath.native(target))]) { self.post(rows.export?.control) }
        let written = (try? SaveTransfer.decode(Data(contentsOf: target))).map { SaveSummary(state: $0.state) }
        let revealedOK = hybrid.revealed.map { WinPath.native($0).lowercased() } == [WinPath.native(target).lowercased()]
        let exportDone = hybrid.informs.isEmpty
        // 2. Another state on this PC, then import the exported file through the real open dialog and the real confirmation
        //    (Replace pressed) and the real "done" dialog (Close pressed).
        do { try setState(dex: 5, tokens: 99) } catch { r.add("settings.exportImport", false, "fixture 2: \(error)"); return }
        let other = stores.companion.transferSummary
        await pause(0.3)
        let importing = await driven([.typePath(WinPath.native(target)), .click(0), .click(0)]) { self.post(section.transferRowsForTesting.import?.control) }
        let after = stores.companion.transferSummary
        let confirmShown = WinTaskDialog.last
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: stores.directory.path).filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }) ?? []
        let doneText = hybrid.informs.last?.message
        let expectedDone = l.importSaveDone(dex: exported.dexCount, tokens: TokenFormatter.compact(exported.lifetimeTokens))
        let rowOK = { (x: (facts: [TransferDialogDriver.Fact], watchdog: Bool, open: Bool, foreground: Bool, closes: Int), n: Int) in
            x.facts.count == n && !x.watchdog && x.facts.allSatisfy { $0.found && $0.owned && $0.closed } && x.open
        }
        r.add("settings.exportImport",
              rowOK(export, 1) && written == exported && revealedOK && exportDone && rowOK(importing, 3) && other != exported && after == exported
                && !backups.isEmpty && doneText == expectedDone && section.applied == 1,
              "folder '\(work.lastPathComponent)' (a space and Korean): export through the real save dialog -> file decodes to \(String(describing: written)) (expected \(exported)), "
                + "Explorer asked to select it=\(revealedOK), no error shown=\(exportDone); the PC then held \(other); import through the real open dialog + confirmation (Replace) + done dialog -> \(after) "
                + "(expected \(exported)), backup files \(backups.count), done text matches=\(doneText == expectedDone), imports applied \(section.applied); "
                + "confirmation buttons \(confirmShown?.buttons ?? []) default \(confirmShown?.defaultIndex ?? -1); steps \(export.facts.map { $0.note } + importing.facts.map { $0.note })")
        close()
    }

    // MARK: settings.importCancelDefault

    func importCancelDefaultCheck() async {
        do { try setState(dex: 3, tokens: 777) } catch { r.add("settings.importCancelDefault", false, "fixture: \(error)"); return }
        guard await open(), let section = section, let hybrid else { r.add("settings.importCancelDefault", false, "no page"); return }
        var s = CompanionState()
        s.usedSinceInstall = 5
        let file = work.appendingPathComponent("other computer.json")
        if let data = try? SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Other", now: Date()) { try? PlatformCompat.atomicWrite(data, to: file) }
        hybrid.scriptedOpen = file
        let before = stores.companion.transferSummary
        let stateBefore = try? Data(contentsOf: stores.directory.appendingPathComponent("companion.json"))
        let backupsBefore = (try? FileManager.default.contentsOfDirectory(atPath: stores.directory.path).filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }.count) ?? 0
        // Enter on the confirmation presses its default button, which is Cancel: nothing is replaced. Then Esc: the same.
        let enter = await driven([.key(UInt16(VK_RETURN))]) { self.post(section.transferRowsForTesting.import?.control) }
        let enterOutcome = section.lastOutcome
        let shown = WinTaskDialog.last
        let afterEnter = stores.companion.transferSummary
        let esc = await driven([.key(UInt16(VK_ESCAPE))]) { self.post(section.transferRowsForTesting.import?.control) }
        let escOutcome = section.lastOutcome
        let after = stores.companion.transferSummary
        let stateAfter = try? Data(contentsOf: stores.directory.appendingPathComponent("companion.json"))
        let backupsAfter = (try? FileManager.default.contentsOfDirectory(atPath: stores.directory.path).filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }.count) ?? 0
        let cancelIndex = ImportConfirmPolicy.cancelButtonIndex
        r.add("settings.importCancelDefault",
              enter.facts.count == 1 && enter.facts[0].closed && !enter.watchdog && esc.facts.count == 1 && esc.facts[0].closed && !esc.watchdog
                && enterOutcome == .cancelled && escOutcome == .cancelled && afterEnter == before && after == before && stateBefore == stateAfter
                && backupsBefore == backupsAfter && shown?.defaultIndex == cancelIndex && shown?.buttons.count == 2 && shown?.icon == .warning,
              "import confirmation shown by the real task dialog with buttons \(shown?.buttons ?? []), default index \(shown?.defaultIndex ?? -1) (Cancel is \(cancelIndex)); Enter -> outcome \(String(describing: enterOutcome)), "
                + "summary \(afterEnter) (before \(before)); Esc -> outcome \(String(describing: escOutcome)); state file unchanged=\(stateBefore == stateAfter), backups \(backupsBefore) -> \(backupsAfter); "
                + "notes: \(enter.facts.map { $0.note } + esc.facts.map { $0.note })")
        hybrid.scriptedOpen = nil
        close()
    }

    // MARK: settings.dialogExit

    /// The exit path (`WinModalPump.cancelModalLoops`) ends an open dialog as a cancel and the process goes on: no crash, no window left.
    func dialogExitCheck() async {
        guard await open(), let section = section, let hybrid else { r.add("settings.dialogExit", false, "no page"); return }
        var reports: [String] = []
        var good = true
        // The task dialog (the confirmation of a scripted file) and the file dialog, each ended by the exit path from a main-queue block.
        let file = work.appendingPathComponent("exit.json")
        if let data = try? SaveTransfer.encode(state: CompanionState(), appVersion: "2.5.0", deviceName: "Fixture", now: Date()) { try? PlatformCompat.atomicWrite(data, to: file) }
        for (name, scripted) in [("task dialog", file as URL?), ("file dialog", nil)] {
            hybrid.scriptedOpen = scripted
            guard let hwnd else { good = false; break }
            let ownerBits = Int(bitPattern: hwnd)
            let button = name == "task dialog" ? section.transferRowsForTesting.import?.control : section.transferRowsForTesting.export?.control
            let watcher = ExitWatcher(ownerBits: ownerBits)
            watcher.start()
            post(button)
            _ = await waitFor(30) { watcher.done }
            reports.append("\(name): appeared=\(watcher.appeared) ended by cancelModalLoops=\(watcher.closedAfterCancel) windows left \(TransferDialogDriver.owned(by: ownerBits).count) outcome \(String(describing: section.lastOutcome))")
            good = good && watcher.appeared && watcher.closedAfterCancel && TransferDialogDriver.owned(by: ownerBits).isEmpty && section.lastOutcome == .cancelled
        }
        hybrid.scriptedOpen = nil
        r.add("settings.dialogExit", good && IsWindowVisible(hwnd) && WinModalPump.depth == 0,
              "the exit path's WinModalPump.cancelModalLoops() while a dialog of the popover is open: \(reports.joined(separator: "; ")); popover alive=\(hwnd.map { IsWindowVisible($0) } ?? false); pump depth \(WinModalPump.depth)")
        close()
    }

    // MARK: settings.snapshots

    func snapshotsCheck() async {
        try? setState(dex: 4, tokens: 4_000)
        guard await open(language: .en, allScripted: true), let section = section, let hybrid else { r.add("settings.snapshots", false, "no page"); return }
        // Create a snapshot (an announcement), then show the history: one row with Restore; a cancelled restore changes nothing.
        let before = stores.companion.availableSnapshots.count
        click(section.transferRowsForTesting.snapshot?.control)
        await pause(0.8)
        let created = stores.companion.availableSnapshots.count == before + 1 && hybrid.informs.last?.message == l.snapshotCreatedToast
        let collapsed = (self.section?.transferRowsForTesting.snapshots.count ?? -1) == 0
        click(self.section?.transferRowsForTesting.history?.control)
        _ = await waitFor(3) { (self.section?.transferRowsForTesting.snapshots.count ?? 0) > 0 }
        await pause(0.5)
        let rows = self.section?.transferRowsForTesting.snapshots ?? []
        let expanded = rows.count == stores.companion.availableSnapshots.count && !rows.isEmpty
        let describedHistory = describe(self.section?.transferRowsForTesting.history?.control)
        try? setState(dex: 1, tokens: 1)
        let state1 = stores.companion.transferSummary
        guard let hybrid2 = page?.transferDialogs as? TransferHybridDialogs else { r.add("settings.snapshots", false, "dialogs lost on rebuild"); return }
        hybrid2.scriptedConfirm = false
        click(rows.first?.control)
        await pause(0.5)
        let cancelled = stores.companion.transferSummary == state1 && hybrid2.confirms == 1
        hybrid2.scriptedConfirm = true
        click(self.section?.transferRowsForTesting.snapshots.first?.control)
        await pause(0.8)
        let restored = stores.companion.state.dex.count == 4 && hybrid2.informs.last?.message == l.restoreDoneMessage(dex: 4, tokens: TokenFormatter.compact(4_000))
        // Rows of a snapshot without a species show the egg slot: a drawn view with one slot is inside each row.
        r.add("settings.snapshots", created && collapsed && expanded && cancelled && restored,
              "created a snapshot (\(before) -> \(stores.companion.availableSnapshots.count)) with the announcement=\(created); history collapsed at first=\(collapsed); expanded -> \(rows.count) row(s) for \(stores.companion.availableSnapshots.count) snapshot(s)=\(expanded) "
                + "(history button accessible value '\(describedHistory.value)'); Restore cancelled changes nothing=\(cancelled); Restore confirmed -> \(stores.companion.state.dex.count) entries (expected 4)=\(restored)")
        close()
    }

    // MARK: settings.transferA11y

    func a11yCheck() async {
        stores.companion.setGrowthDifficulty(1)
        stores.companion.setShopDifficulty(1)
        guard await open(), let section = section else { r.add("settings.transferA11y", false, "no page"); return }
        var problems: [String] = []
        // Every interactive control of the new rows has a name, the sliders also a value in percent.
        func check(_ label: String, _ control: WinControl?, value: String? = nil) {
            let d = describe(control)
            if d.name.isEmpty || d.name.contains("\u{0}") { problems.append("\(label): no name (hr \(d.hr))") }
            if let value, d.value != value { problems.append("\(label): value '\(d.value)' expected '\(value)'") }
        }
        let rows = section.difficultyRowsForTesting, t = section.transferRowsForTesting
        check("growth", rows.growth?.control, value: l.difficultyValue(1))
        check("shop", rows.shop?.control, value: l.difficultyValue(1))
        check("export", t.export?.control)
        check("import", t.import?.control)
        check("snapshot", t.snapshot?.control)
        check("history", t.history?.control, value: l.snapshotHistoryState(expanded: false))
        // The controls are inside the window and in reading order (Tab order is the z-order of the page).
        let controls = page?.stackForTesting?.controls ?? []
        let index = { (c: WinControl?) in controls.firstIndex { $0 === c } ?? -1 }
        let ordered = index(rows.growth?.control) < index(rows.shop?.control) && index(rows.shop?.control) < index(t.export?.control)
            && index(t.export?.control) < index(t.import?.control) && index(t.import?.control) < index(t.snapshot?.control) && index(t.snapshot?.control) < index(t.history?.control)
        r.add("settings.transferA11y", problems.isEmpty && ordered,
              "difficulty sliders, export, import, snapshot and history controls through MSAA (the screen reader's view): problems \(problems); reading order growth < shop < export < import < snapshot < history=\(ordered)")
        close()
    }

    // MARK: captures

    func captureChecks(_ dir: URL) async {
        var wrote: [String] = [], failed: [String] = []
        let original = stores.companion.language
        try? setState(dex: 4, tokens: 12_345_678)
        _ = try? stores.companion.createManualSnapshot()
        for language in [AppLanguage.en, .ko] {
            let tag = language.rawValue
            if await open(language: language) {
                slide(section?.difficultyRowsForTesting.growth?.control, to: 120)
                await pause(0.3)
                await shoot(titled: l.difficultySectionTitle, name: "difficulty-\(tag).png", dir: dir, wrote: &wrote, failed: &failed)
                await shoot(titled: l.transferSectionTitle, name: "transfer-collapsed-\(tag).png", dir: dir, wrote: &wrote, failed: &failed)
                click(section?.transferRowsForTesting.history?.control)
                await pause(0.9)
                await shoot(titled: l.transferSectionTitle, name: "transfer-history-\(tag).png", dir: dir, wrote: &wrote, failed: &failed)
                // The real dialogs, copied off the screen: the import confirmation and the open dialog.
                if let section, let hybrid = page?.transferDialogs as? TransferHybridDialogs, let hwnd {
                    var s = CompanionState()
                    s.usedSinceInstall = 9_876_543_210
                    s.dex = [DexEntry(baseID: 1, finalID: 3, chainOrder: [1, 3], rarity: .common, caughtAt: Date())]
                    let file = work.appendingPathComponent("capture-\(tag).json")
                    if let data = try? SaveTransfer.encode(state: s, appVersion: "2.5.0", deviceName: "Sample PC", now: Date(timeIntervalSince1970: 1_800_000_000)) { try? PlatformCompat.atomicWrite(data, to: file) }
                    hybrid.scriptedOpen = file
                    let driver = TransferDialogDriver(ownerBits: Int(bitPattern: hwnd), mainThread: GetCurrentThreadId(),
                                                      steps: [.captureThenEscape(dir.appendingPathComponent("confirm-dialog-\(tag).png"))])
                    driver.start()
                    post(section.transferRowsForTesting.import?.control)
                    _ = await waitFor(60) { driver.isFinished }
                    wrote.append("confirm-dialog-\(tag).png")
                    hybrid.scriptedOpen = nil
                    let open = TransferDialogDriver(ownerBits: Int(bitPattern: hwnd), mainThread: GetCurrentThreadId(),
                                                    steps: [.captureThenEscape(dir.appendingPathComponent("open-dialog-\(tag).png"))])
                    open.start()
                    post(section.transferRowsForTesting.import?.control)
                    _ = await waitFor(60) { open.isFinished }
                    wrote.append("open-dialog-\(tag).png")
                    if driver.watchdog || open.watchdog { failed.append("dialog capture \(tag)") }
                }
            } else { failed.append("open \(tag)") }
            close()
        }
        stores.companion.setLanguage(original)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        r.add("settings.transferCapture", failed.isEmpty && files.contains { $0.hasPrefix("difficulty-en") } && files.contains { $0.hasPrefix("transfer-history-ko") },
              "sample capture, Windows CI runner, FIXTURE state (a sample save from 'Sample PC'): \(files.sorted().joined(separator: ", ")); failures: \(failed)")
    }

    func shoot(titled title: String, name: String, dir: URL, wrote: inout [String], failed: inout [String]) async {
        guard let hwnd, let page, let area = page.areaForTesting, let frames = page.stackForTesting?.frames else { failed.append(name); return }
        let caption = title.uppercased()
        var y: CGFloat = 0
        if let index = page.stackForTesting?.sections.firstIndex(where: { $0.caption?.text == caption }), index < frames.sections.count, let s = frames.sections[index] {
            y = (s.caption?.minY ?? s.card?.minY ?? 0) - 8
        }
        area.scroll(to: Int32(max(0, y)))
        await pause(0.4)
        _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        await pause(0.2)
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &w, &h, &out) == 0, let out else { failed.append(name); return }
        defer { ptb_plaza_free(out) }
        let bitmap = WinUIDump.Bitmap(width: Int(w), height: Int(h), bgra: Array(UnsafeBufferPointer(start: out, count: Int(w * h) * 4)))
        if WinUIDump.write(bitmap, to: dir.appendingPathComponent(name)) == 0 { wrote.append(name) } else { failed.append(name) }
    }
}

/// Watches for a dialog of the popover, then calls the exit path's `cancelModalLoops` from the main queue and notes that the dialog
/// ended afterwards.
final class ExitWatcher: @unchecked Sendable {
    private let ownerBits: Int
    private let lock = NSLock()
    private var _appeared = false, _closed = false, _done = false
    init(ownerBits: Int) { self.ownerBits = ownerBits }
    var appeared: Bool { lock.lock(); defer { lock.unlock() }; return _appeared }
    var closedAfterCancel: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }

    func start() {
        Thread { [self] in
            let deadline = Date(timeIntervalSinceNow: 20)
            var dialog: Int?
            while Date() < deadline, dialog == nil {
                dialog = TransferDialogDriver.owned(by: ownerBits).first
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard let dialog, let hwnd = HWND(bitPattern: dialog) else {
                lock.lock(); _done = true; lock.unlock()
                return
            }
            lock.lock(); _appeared = true; lock.unlock()
            Thread.sleep(forTimeInterval: 0.6)
            DispatchQueue.main.async { MainActor.assumeIsolated { WinModalPump.cancelModalLoops() } }
            let end = Date(timeIntervalSinceNow: 10)
            while IsWindow(hwnd), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            lock.lock(); _closed = !IsWindow(hwnd); _done = true; lock.unlock()
            if IsWindow(hwnd) { _ = PostMessageW(hwnd, UINT(WM_CLOSE), 0, 0) }
        }.start()
    }
}
#endif
