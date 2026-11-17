#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 14: the Advanced group's selftest checks (`settings.advanced*`, `settings.sessionKey*`, …). The Settings page opens
// in a popover of its own over a FIXTURE store: its session keys are the real `SessionKeyLimitsProvider` and `SessionKeyStore`
// (so the file really goes through DPAPI) in a temporary folder, its claude.ai is `AdvancedFixtureHTTP` (no network), its
// Claude folders are temporary folders. Every key is a fixture made for this run; none is ever printed: the checks print
// lengths and yes/no, and `settings.keyLeak` looks for every one of them in the log, the window texts, the tooltips and the
// control trees written with the captures. Real keys (`SendInput`) and the clipboard only on the runner (`CI`).

/// claude.ai for the fixture store: two organisations (one with usage), their usage, 401 for any other key. Records request
/// paths only.
final class AdvancedFixtureHTTP: SessionKeyHTTPClient, @unchecked Sendable {
    static let validPrefix = "sk-ant-sid02-FIXTUREOK-"
    private let lock = NSLock()
    private var waitSeconds: TimeInterval = 0
    private var rejecting = false
    private var paths: [String] = []

    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return waitSeconds }
        set { lock.lock(); waitSeconds = newValue; lock.unlock() }
    }
    /// Every key is refused from now on (a key that expired).
    var rejectAll: Bool {
        get { lock.lock(); defer { lock.unlock() }; return rejecting }
        set { lock.lock(); rejecting = newValue; lock.unlock() }
    }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return paths.count }

    /// Records the request; what to do now (the lock is not taken from an async context).
    private func note(_ path: String) -> (wait: TimeInterval, refuse: Bool) {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
        return (waitSeconds, rejecting)
    }

    func get(_ url: URL, sessionKey: String) async throws -> SessionKeyHTTPResponse {
        let (wait, refuse) = note(url.path)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard !refuse, sessionKey.hasPrefix(Self.validPrefix) else { return SessionKeyHTTPResponse(status: 401, data: Data(), retryAfter: nil) }
        if url.path.hasSuffix("/organizations") {
            let body = #"[{"uuid":"org-fixture-team","name":"Fixture Team","capabilities":["chat"]},"#
                + #"{"uuid":"org-fixture-personal","name":"Fixture Personal","capabilities":["chat"]}]"#
            return SessionKeyHTTPResponse(status: 200, data: Data(body.utf8), retryAfter: nil)
        }
        let used = url.path.contains("org-fixture-personal")
        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        let body = used ? #"{"five_hour":{"utilization":37,"resets_at":"\#(reset)"},"seven_day":{"utilization":52,"resets_at":"\#(reset)"}}"#
            : #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}"#
        return SessionKeyHTTPResponse(status: 200, data: Data(body.utf8), retryAfter: nil)
    }
}

private struct AdvFixtureUsage: UsageProvider {
    let id: String
    let displayName: String
    func fetchDaily() async throws -> DailyUsage? { HomeFixtures.day(1_200) }
    func fetchEnrichment() async -> ProviderEnrichment {
        ProviderEnrichment(activeBlock: nil, blocksOK: true, weekTotal: nil, monthTotal: nil, periodsOK: true)
    }
}
/// The default login's sign-in file path when no key is saved: no credential on this PC (Windows' "no item", P14).
private struct AdvNoCredential: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus {
        try? await Task.sleep(nanoseconds: 400_000_000)   // long enough for the check to see the button's spinner
        throw LimitsError.keychainUnavailable(errSecItemNotFound)
    }
}
/// The additional folder's own login.
private struct AdvAccountLimits: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus {
        HomeFixtures.limitStatus(five: 21, fiveReset: 3600, seven: 30, email: "work@fixture.example")
    }
}
private struct AdvNoCodex: CodexLimitsProviding { func fetch() async throws -> CodexRateLimitStatus? { nil } }
private struct AdvNoAntigravity: AntigravityLimitsProviding {
    var hasTokenFile: Bool { false }
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw LimitsError.keychainAccessDisabled }
}
private struct AdvNoCursor: CursorLimitsProviding { func fetch() async throws -> CursorRateLimitStatus? { nil } }
private struct AdvNoOpenCode: OpenCodeGoLimitsProviding { func fetch() async throws -> OpenCodeGoRateLimitStatus? { nil } }
private struct AdvNoGrok: GrokLimitsProviding { func fetch() async throws -> GrokCreditStatus? { nil } }
private struct AdvNoStatuses: ProviderStatusProviding { func fetch() async -> [String: ProviderStatus] { [:] } }

/// The fixture store and its folders.
@MainActor final class AdvancedFixture {
    let dir: URL
    let work: URL
    let http: AdvancedFixtureHTTP
    let store: UsageStore
    let defaults: UserDefaults
    let suite: String
    var keyFile: URL { dir.appendingPathComponent("session-key.json") }

    init(suite: String, language: AppLanguage, withAccount: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-advanced-\(UUID().uuidString)")
        let work = dir.appendingPathComponent(".claude-work", isDirectory: true)
        let http = AdvancedFixtureHTTP()
        self.dir = dir
        self.work = work
        self.http = http
        for folder in [work, dir.appendingPathComponent("second-claude"), dir.appendingPathComponent("with space"),
                       dir.appendingPathComponent("한글 폴더"), dir.appendingPathComponent("logs/proj-a"), dir.appendingPathComponent("logs/proj-b")] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The folder's own login, as Claude Code writes it: its tab keeps the email after the folder's key is saved (the usage
        // a session key answers carries none; the store names the account from this file then).
        try? Data(#"{"oauthAccount":{"emailAddress":"work@fixture.example","organizationUuid":"org-fixture-personal"}}"#.utf8)
            .write(to: work.appendingPathComponent(".claude.json"))
        self.suite = suite
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        self.defaults = defaults
        defaults.set(withAccount ? work.path : "", forKey: ClaudeAccountRoots.defaultsKey)
        // Manual refresh: a store arms its polling timer in `init` (whatever `autoRefresh` says) and nothing invalidates it,
        // so every fixture store left a 120 s timer behind that woke the main thread in the idle window after this group.
        defaults.set(0.0, forKey: "refreshInterval")
        let keys = SessionKeyLimitsProvider(store: SessionKeyStore(fileURL: dir.appendingPathComponent("session-key.json")), http: http)
        store = UsageStore(
            providers: [AdvFixtureUsage(id: "claude_code", displayName: "Claude Code"), AdvFixtureUsage(id: "codex", displayName: "Codex")],
            claudeLimitsProvider: ChainedLimitsProvider(primary: keys, fallback: AdvNoCredential()),
            additionalClaudeLimitsProvider: { ChainedLimitsProvider.forConfigRoot($0, sessionKeyDirectory: dir, http: http, fallback: AdvAccountLimits()) },
            discoverClaudeConfigDirs: { [] },
            readDefaultIdentity: { withAccount ? AccountIdentity(email: "main@fixture.example", organizationName: nil) : nil },
            readLastPrompt: { _ in nil }, claudeUsageEntries: { _ in [] }, readPromptHistory: { _ in [:] },
            codexLimitsProvider: AdvNoCodex(), antigravityLimitsProvider: AdvNoAntigravity(), cursorLimitsProvider: AdvNoCursor(),
            openCodeGoLimitsProvider: AdvNoOpenCode(), grokLimitsProvider: AdvNoGrok(), statusProvider: AdvNoStatuses(),
            sessionKeys: keys, accountSessionKeys: { SessionKeyLimitsProvider(store: .forConfigRoot($0, directory: dir), http: http) },
            autoRefresh: false, defaults: defaults, displaysAsleep: { false })
        store.localizationLanguage = language
        assert(!store.isPollingTimerScheduled)
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

@MainActor enum WindowsSelftestAdvanced {
    static let names = ["settings.advancedRows", "settings.sessionKeyPaste", "settings.sessionKeySave", "settings.sessionKeyCommit",
                        "settings.sessionKeyOrg", "settings.sessionKeyErrors", "settings.sessionKeyDelete", "settings.accountKey",
                        "settings.reloadSignIn", "settings.scanFolders", "settings.additionalFolders", "settings.trackedAccount",
                        "settings.sessionKeyRoute", "settings.keyFileUnreadable", "settings.keyLeak"]

    static func run(_ t: SettingsRun) async {
        let a = AdvancedRun(t)
        await a.all()
    }
}

/// One run of the Advanced checks (inside the Settings group's run, which holds the probe window and the helpers).
@MainActor final class AdvancedRun {
    let t: SettingsRun
    var r: WindowsSelftest.Recorder { t.r }
    var l: L { t.app.companion.l }
    /// Every fixture key of this run (never printed).
    var keys: [String] = []
    /// Window texts and tooltips seen while checks ran (the key field's own text excluded while it was being typed).
    var seenTexts: [String] = []
    var trees: [URL] = []
    var fixtures: [AdvancedFixture] = []

    init(_ t: SettingsRun) { self.t = t }

    func newKey(valid: Bool) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        let tail = String((0..<48).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        let key = (valid ? AdvancedFixtureHTTP.validPrefix : "sk-ant-sid02-FIXTURENO-") + tail
        keys.append(key)
        t.secrets.append(key)   // `settings.secret` looks for these in the log too
        return key
    }

    func fixture(_ name: String, withAccount: Bool = true, refresh: Bool = true) async -> AdvancedFixture {
        let f = AdvancedFixture(suite: "\(t.suite).adv.\(name)", language: t.app.companion.language, withAccount: withAccount)
        fixtures.append(f)
        if refresh { await f.store.refresh(scheduleEmptyRetry: false) }
        return f
    }

    /// Settings over the fixture store, in a popover of its own (the tray menu's "Settings…"), Advanced expanded.
    @discardableResult
    func open(_ f: AdvancedFixture, expand: Bool = true, home: Bool = false) async -> Bool {
        t.close()
        let host = WinPopoverHost(store: f.store, companion: t.app.companion, updater: nil, team: t.newTeam("adv", enabled: false),
                                  session: nil, feed: nil, tray: nil, loginItem: t.loginItem(), openPlaza: {})
        host.owner = t.app.sink.hwnd
        let p = WinPopover(host: host)
        p.makePage = WinSettingsPage.routed
        p.state.providerID = "claude_code"   // Home shows Claude's limits section (the notice and the (?))
        t.popover = p
        WindowsSelftest.forceForeground(t.probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == self.t.probe.hwnd }
        p.present(.secondLaunch) { $0.showSettings = !home }
        let up = await t.waitFor(2) {
            guard let h = p.hwndForTesting else { return false }
            return IsWindowVisible(h) && GetForegroundWindow() == h && (home ? p.pageForTesting is WinHomePage : p.pageForTesting is WinSettingsPage)
        }
        await t.pause(0.3)
        if expand, let adv = section, !adv.draftsForTesting.expanded {
            t.click(adv.disclosureForTesting)
            _ = await t.waitFor(1) { self.t.shown(adv.key.fieldRow) }
        }
        record()
        return up
    }

    var section: WinAdvancedSection? { t.page?.advancedForTesting }

    /// Every window text and tooltip of the popover now (the password field's text is the key being typed: not recorded).
    func record() {
        guard let hwnd = t.hwnd else { return }
        for h in SettingsRun.descendants(hwnd) {
            let style = GetWindowLongW(h, -16)
            if WinKit.className(h) == "Edit", style & 0x0020 /* ES_PASSWORD */ != 0 { continue }
            seenTexts.append(WinKit.text(of: h))
            if let c = WinControl.control(h), let tip = c.tooltip { seenTexts.append(tip) }
        }
    }

    func paste(_ text: String, into field: WinControl?) async {
        guard let field else { return }
        _ = t.clipboard(text)
        await t.focus(field)
        WinKit.send(field.hwnd, 0x00B1 /* EM_SETSEL */, 0, -1)
        _ = SendMessageW(field.hwnd, 0x0302 /* WM_PASTE */, 0, 0)
    }

    /// Replaces a multi-line field's text the way typing does (`EM_REPLACESEL` sends `EN_CHANGE`; `WM_SETTEXT` would not).
    func type(_ text: String, into field: WinControl?) async {
        guard let field else { return }
        await t.focus(field)
        WinKit.send(field.hwnd, 0x00B1 /* EM_SETSEL */, 0, -1)
        WinKit.send(field.hwnd, 0x00C2 /* EM_REPLACESEL */, 1, text: text)
    }

    func cue(_ field: WinControl?) -> String {
        guard let field else { return "" }
        var buffer = [UInt16](repeating: 0, count: 64)
        _ = buffer.withUnsafeMutableBufferPointer { WinKit.send(field.hwnd, 0x1502 /* EM_GETCUEBANNER */, Int(bitPattern: $0.baseAddress), 64) }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    func isPassword(_ field: WinControl?) -> Bool { field.map { GetWindowLongW($0.hwnd, -16) & 0x0020 != 0 } ?? false }

    /// The key's file holds no plain key and decrypts here to the JSON with it.
    func encryptedOnDisk(_ url: URL, key: String) -> (exists: Bool, plain: Bool, decrypts: Bool) {
        guard let raw = try? Data(contentsOf: url) else { return (false, false, false) }
        let plain = raw.range(of: Data(key.utf8)) != nil || WinSecret.isPlainJSON(raw)
        let json = WinSecret.unprotect(raw).flatMap { try? JSONDecoder().decode(SessionKeyCredential.self, from: $0) }
        return (true, plain, json?.key == key)
    }

    // MARK: the run

    func all() async {
        await rowsCheck()
        await pasteCheck()
        await saveCheck()
        await commitCheck()
        await orgCheck()
        await errorsCheck()
        await deleteCheck()
        await accountCheck()
        await reloadCheck()
        await scanCheck()
        await additionalCheck()
        await trackedCheck()
        await routeCheck()
        if let dir = WindowsSelftestPopoverWindow.dumpDirectory().map({ $0.deletingLastPathComponent().appendingPathComponent("settings", isDirectory: true) }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await captureCheck(dir)
        }
        unreadableCheck()
        t.close()
        leakCheck()
        for f in fixtures {
            f.remove()
            UserDefaults.standard.removePersistentDomain(forName: f.suite)
        }
        WinSecret.resetReportsForTesting()
    }

    // MARK: settings.advancedRows

    func rowsCheck() async {
        let f = await fixture("rows")
        guard await open(f, expand: false), let page = t.page, let adv = section else { r.add("settings.advancedRows", false, "no page"); return }
        let collapsed = !t.shown(adv.key.fieldRow) && !t.shown(adv.rowsForTesting.scanField) && t.isShown(adv.disclosureForTesting)
        let glyphBefore = adv.disclosureForTesting?.pillGlyph
        t.click(adv.disclosureForTesting)
        let opened = await t.waitFor(1) { self.t.shown(adv.key.fieldRow) }
        let glyphAfter = adv.disclosureForTesting?.pillGlyph
        record()
        let texts = t.visibleTexts()
        let model = SettingsModel.advanced(SettingsModel.advancedInput(f.store, language: l.lang), facts: PlatformCompat.popoverFacts)
        let wanted = [l.advancedSectionTitle.uppercased(), l.advancedDisclosureLabel, l.sessionKeyLabel, l.save, l.winRefreshLimitToken, l.winOnlyOnPress,
                      l.additionalClaudeAccountsLabel, l.winAdditionalClaudeAccountsHint, l.customScanRootsLabel, l.customScanRootsHint,
                      l.customScanProviderLabel, l.aggregationNote, l.accountSessionKeyLabel("work@fixture.example"), l.trackedAccountLabel]
        let missing = wanted.filter { !t.contains(texts, $0) }
        let hintShown = t.contains(texts, l.winSessionKeyHint)
        let macOnly = [l.disableKeychain, l.refreshLimitToken, "Keychain", "키체인", l.sessionKeyStorageNote, l.trackedAccountHint].filter { t.contains(texts, $0) }
        let field = adv.key.field
        let saveOff = adv.key.save?.isEnabled == false
        let deleteHidden = !t.isShown(adv.key.delete)
        let refreshOn = adv.rowsForTesting.refresh.control?.isEnabled == true
        let providers = adv.rowsForTesting.scanProvider.control.map { WinKit.send($0.hwnd, 0x0146 /* CB_GETCOUNT */) } ?? 0
        t.click(adv.disclosureForTesting)
        let closedAgain = await t.waitFor(1) { !self.t.shown(adv.key.fieldRow) && !self.t.shown(adv.rowsForTesting.aggregation) }
        let ok = collapsed && opened && missing.isEmpty && hintShown && macOnly.isEmpty && isPassword(field) && saveOff && deleteHidden && refreshOn
            && providers == f.store.registeredProviders.count && closedAgain && glyphBefore != glyphAfter && model.accounts.count == 1
        r.add("settings.advancedRows", ok,
              "collapsed at open=\(collapsed); expanded=\(opened) (chevron changed=\(glyphBefore != glyphAfter)); missing \(missing); Windows key hint shown=\(hintShown); "
                + "Mac-only texts shown \(macOnly) (no Keychain switch); key field ES_PASSWORD=\(isPassword(field)) cue is the new-key placeholder=\(cue(field) == SettingsModel.newKeyPlaceholder), Save off while empty=\(saveOff), "
                + "Delete hidden without a key=\(deleteHidden); '\(l.winRefreshLimitToken)' on=\(refreshOn); scan providers \(providers) of \(f.store.registeredProviders.count); "
                + "account rows \(model.accounts.count); collapsed again=\(closedAgain); page rebuilds \(page.rebuildsForTesting)")
        t.close()
    }

    // MARK: settings.sessionKeyPaste

    func pasteCheck() async {
        let f = await fixture("paste")
        guard await open(f), let adv = section, let field = adv.key.field else { r.add("settings.sessionKeyPaste", false, "no page"); return }
        let key = newKey(valid: true)
        await paste("  \r\n" + key + "\r\n \t", into: field)
        let viaMessage = field.text == key
        let saveOn = await t.waitFor(1) { adv.key.save?.isEnabled == true }
        field.text = ""
        _ = t.clipboard("\n" + key + "\n")
        await t.focus(field)
        t.key(0x56 /* V */, ctrl: true)
        let viaKeys = await t.waitFor(1) { field.text == key }
        _ = t.clipboard("unchanged")
        WinKit.send(field.hwnd, 0x00B1 /* EM_SETSEL */, 0, -1)
        _ = SendMessageW(field.hwnd, 0x0301 /* WM_COPY */, 0, 0)   // an ES_PASSWORD edit refuses it
        let copyRefused = WinClipboardText.read() == "unchanged"
        field.text = ""
        t.clearClipboard()
        r.add("settings.sessionKeyPaste", viaMessage && viaKeys && saveOn && copyRefused,
              "a fixture key with spaces and line breaks around it (\(key.count) characters): the edit's Paste (WM_PASTE) -> exactly the key=\(viaMessage), "
                + "Save on=\(saveOn); real Ctrl+V of \"\\n<key>\\n\" -> exactly the key=\(viaKeys); Copy out of the field refused (clipboard unchanged)=\(copyRefused)")
        t.close()
    }

    // MARK: settings.sessionKeySave

    func saveCheck() async {
        let f = await fixture("save")
        guard await open(f), let adv = section, let field = adv.key.field else { r.add("settings.sessionKeySave", false, "no page"); return }
        let key = newKey(valid: true)
        await paste(key, into: field)
        f.http.delay = 0.8
        t.click(adv.key.save)
        let spinner = await t.waitFor(0.5) {
            self.t.isShown(adv.key.progress) && adv.key.progress?.isMarqueeOn == true && adv.key.save?.isEnabled == false && adv.key.save?.text == self.l.save
        }
        record()
        let saved = await t.waitFor(5) { f.store.sessionKeyConfigured && !f.store.isValidatingSessionKey && field.text.isEmpty }
        f.http.delay = 0
        await t.pause(0.3)
        record()
        let stopped = !t.isShown(adv.key.progress) && adv.key.progress?.isMarqueeOn == false
        let badge = adv.key.badge?.text ?? ""
        // The Mac's row (Task 14 review, "the Mac is the reference"): field, Save, Delete on one line in English at 100 %; the
        // badge right after the label.
        func screen(_ c: WinControl?) -> RECT { var r = RECT(); if let c { _ = GetWindowRect(c.hwnd, &r) }; return r }
        let fr = screen(field), sr = screen(adv.key.save), dr = screen(adv.key.delete), tr = screen(adv.key.title), br = screen(adv.key.badge)
        let oneLine = adv.key.oneLine && fr.right <= sr.left && sr.right <= dr.left && fr.top < sr.bottom && sr.top < fr.bottom && sr.top < dr.bottom
        let badgeAfter = br.left >= tr.right && br.left - tr.right <= 16 && br.top < tr.bottom && tr.top < br.bottom
        let disk = encryptedOnDisk(f.keyFile, key: key)
        let orgRow = adv.key.orgRow
        let orgs = orgRow?.control.map { WinKit.send($0.hwnd, 0x0146 /* CB_GETCOUNT */) } ?? 0
        let chosen = orgRow?.control?.selection ?? -1
        let note = adv.key.noteRow?.hint?.text ?? ""
        let ok = spinner && stopped && oneLine && badgeAfter && saved && badge == l.sessionKeySaved && cue(field) == SettingsModel.savedKeyPlaceholder && t.isShown(adv.key.delete)
            && t.shown(orgRow) && orgs == 2 && chosen == 1 && t.shown(adv.key.noteRow) && note == l.winSessionKeyStorageNote
            && disk.exists && !disk.plain && disk.decrypts && !t.shown(adv.key.errorRow)
        r.add("settings.sessionKeySave", ok,
              "pasted a fixture key, Save: marquee beside Save (off) while claude.ai answered=\(spinner), stopped and hidden after=\(stopped); "
                + "field, Save, Delete on one line=\(oneLine) (field \(fr.left)-\(fr.right), Save \(sr.left)-\(sr.right), Delete \(dr.left)-\(dr.right)); "
                + "badge right after the label=\(badgeAfter) (label ends \(tr.right), badge starts \(br.left)); saved=\(saved), field emptied=\(field.text.isEmpty), "
                + "cue now the saved dots=\(cue(field) == SettingsModel.savedKeyPlaceholder), badge '\(badge)', Delete shown=\(t.isShown(adv.key.delete)); organisation picker shown=\(t.shown(orgRow)) with \(orgs) "
                + "(the one with usage chosen: index \(chosen)); storage note (Windows wording)=\(note == l.winSessionKeyStorageNote); key file exists=\(disk.exists) "
                + "plain=\(disk.plain) decrypts for this account to the key=\(disk.decrypts); fixture requests \(f.http.requests)")
        t.close()
    }

    // MARK: settings.sessionKeyCommit

    func commitCheck() async {
        let f = await fixture("commit")
        guard await open(f), let adv = section, let field = adv.key.field else { r.add("settings.sessionKeyCommit", false, "no page"); return }
        let key = newKey(valid: true)
        await t.focus(field)
        t.chars(key, to: field.hwnd)
        _ = await t.waitFor(1) { field.text == key }
        let typed = field.text == key
        let before = f.http.requests
        await t.focus(adv.rowsForTesting.refresh.control)   // the focus leaves the field: no save (the Mac saves on Enter and Save only)
        await t.pause(0.4)
        let notOnFocusLoss = f.http.requests == before && !f.store.sessionKeyConfigured && field.text == key
        await t.focus(field)
        t.key(0x0D /* VK_RETURN */)
        let onEnter = await t.waitFor(4) { f.store.sessionKeyConfigured && field.text.isEmpty }
        let fieldHandle = field.hwnd
        await paste(key, into: field)
        t.close()   // the page closes with a key typed: the field goes with it, nothing is saved
        let gone = !IsWindow(fieldHandle)
        r.add("settings.sessionKeyCommit", typed && notOnFocusLoss && onEnter && gone,
              "typed a fixture key (\(key.count) WM_CHARs)=\(typed); focus moved away: no request, not saved, the key still in the field=\(notOnFocusLoss); "
                + "real Enter in the field -> saved and the field emptied=\(onEnter); page closed with a key in the field -> the field window gone=\(gone)")
    }

    // MARK: settings.sessionKeyOrg

    func orgCheck() async {
        let f = await fixture("org")
        await f.store.saveSessionKey(newKey(valid: true))
        guard await open(f), let adv = section, let combo = adv.key.orgRow?.control else { r.add("settings.sessionKeyOrg", false, "no picker"); return }
        let shown = t.shown(adv.key.orgRow)
        t.choose(combo, 0)
        let switched = await t.waitFor(3) { f.store.sessionKeySelectedOrgID == "org-fixture-team" }
        let file = SessionKeyStore(fileURL: f.keyFile).load()?.organizationID
        r.add("settings.sessionKeyOrg", shown && switched && file == "org-fixture-team" && combo.selection == 0,
              "two organisations: picker shown=\(shown); chose 'Fixture Team' -> the store's organisation switched=\(switched), the key file's organisation=\(file ?? "nil"), picker shows it=\(combo.selection == 0)")
        t.close()
    }

    // MARK: settings.sessionKeyErrors

    func errorsCheck() async {
        let f = await fixture("errors")
        guard await open(f), let adv = section, let field = adv.key.field else { r.add("settings.sessionKeyErrors", false, "no page"); return }
        let before = f.http.requests
        await paste("not-a-session-key-FIXTURE", into: field)
        t.click(adv.key.save)
        let malformed = await t.waitFor(2) { adv.key.errorRow.hint?.text == self.l.sessionKeyMalformedError && self.t.shown(adv.key.errorRow) }
        let kept = !field.text.isEmpty
        let noRequest = f.http.requests == before
        let bad = newKey(valid: false)
        await paste(bad, into: field)
        t.click(adv.key.save)
        let rejected = await t.waitFor(3) { adv.key.errorRow.hint?.text == self.l.sessionKeyExpiredError && !f.store.isValidatingSessionKey }
        let keptBad = field.text == bad
        let orange = adv.key.errorRow.hint?.role == .warning
        let noFile = !FileManager.default.fileExists(atPath: f.keyFile.path)
        record()
        field.text = ""
        r.add("settings.sessionKeyErrors", malformed && kept && noRequest && rejected && keptBad && orange && noFile,
              "a malformed paste, Save -> the malformed-key error (orange=\(orange))=\(malformed), claude.ai not asked=\(noRequest), "
                + "text kept to fix=\(kept); a refused fixture key -> the expired-key error=\(rejected), kept=\(keptBad); no key file written=\(noFile)")
        t.close()
    }

    // MARK: settings.sessionKeyDelete

    func deleteCheck() async {
        let f = await fixture("delete")
        await f.store.saveSessionKey(newKey(valid: true))
        guard await open(f), let adv = section, let field = adv.key.field else { r.add("settings.sessionKeyDelete", false, "no page"); return }
        let had = FileManager.default.fileExists(atPath: f.keyFile.path) && t.isShown(adv.key.delete)
        t.click(adv.key.delete)
        let cleared = await t.waitFor(2) { !f.store.sessionKeyConfigured && !self.t.isShown(adv.key.delete) }
        let gone = !FileManager.default.fileExists(atPath: f.keyFile.path)
        let badge = adv.key.badge?.text.trimmingCharacters(in: .whitespaces) ?? "?"
        r.add("settings.sessionKeyDelete", had && cleared && gone && badge.isEmpty && cue(field) == SettingsModel.newKeyPlaceholder
                && !t.shown(adv.key.noteRow) && !t.shown(adv.key.orgRow),
              "a saved key: file and Delete there=\(had); Delete -> not configured, Delete hidden=\(cleared), file removed=\(gone), badge '\(badge)', cue back to the new-key placeholder=\(cue(field) == SettingsModel.newKeyPlaceholder), "
                + "storage note hidden=\(!t.shown(adv.key.noteRow)), picker hidden=\(!t.shown(adv.key.orgRow))")
        t.close()
    }

    // MARK: settings.accountKey

    func accountCheck() async {
        let f = await fixture("account")
        guard await open(f), let first = section?.accounts.first, let field = first.field, let path = first.path else {
            r.add("settings.accountKey", false, "no account rows"); return
        }
        let label = first.title?.text ?? ""
        let folder = first.labelRow.hint?.text ?? ""
        let keyFile = SessionKeyStore.forConfigRoot(URL(fileURLWithPath: path), directory: f.dir).fileURL   // as the store names it
        let key = newKey(valid: true)
        await paste(key, into: field)
        t.click(first.save)
        let saved = await t.waitFor(4) { f.store.accountSessionKeyPaths.contains(path) && field.text.isEmpty }
        // The save refreshes the store; read the rows the page shows now (a rebuild would make new ones).
        let badged = await t.waitFor(2) { self.section?.accounts.first?.badge?.text == self.l.sessionKeySaved }
        let account = section?.accounts.first
        let badge = account?.badge?.text ?? ""
        let disk = encryptedOnDisk(keyFile, key: key)
        let note = section.map { t.shown($0.rowsForTesting.accountsNote) } ?? false
        t.click(account?.delete)
        let deleted = await t.waitFor(2) { !f.store.accountSessionKeyPaths.contains(path) && !FileManager.default.fileExists(atPath: keyFile.path) }
        r.add("settings.accountKey", label == l.accountSessionKeyLabel("work@fixture.example") && !folder.isEmpty && saved && badged
                && disk.exists && !disk.plain && disk.decrypts && note && deleted,
              "the fixture folder's own key: label '\(label)', folder shown=\(!folder.isEmpty); pasted + Save -> saved and emptied=\(saved), badge '\(badge)'; "
                + "its file encrypted=\(disk.exists && !disk.plain) decrypts=\(disk.decrypts); storage note once under the accounts=\(note); Delete -> gone=\(deleted)")
        t.close()
    }

    // MARK: settings.reloadSignIn

    func reloadCheck() async {
        let f = await fixture("reload")
        guard await open(f), let adv = section, let button = adv.rowsForTesting.refresh.control else { r.add("settings.reloadSignIn", false, "no page"); return }
        t.click(button)
        let spinner = await t.waitFor(0.4) { button.text == self.l.winRefreshLimitToken + "…" && !button.isEnabled }
        let message = await t.waitFor(3) { self.t.shown(adv.rowsForTesting.refreshMessage) && button.isEnabled }
        let text = adv.rowsForTesting.refreshMessage.hint?.text ?? ""
        record()
        r.add("settings.reloadSignIn", spinner && message && text.contains(l.limitRefreshNoCredential),
              "'\(l.winRefreshLimitToken)' with no Claude sign-in file: spinner ('…', off)=\(spinner); then the message '\(text)' (the Windows wording for a missing credential, P14)=\(text.contains(l.limitRefreshNoCredential))")
        t.close()
    }

    // MARK: settings.scanFolders

    func scanCheck() async {
        let f = await fixture("scan")
        guard await open(f), let adv = section, let field = adv.rowsForTesting.scanField.control, let combo = adv.rowsForTesting.scanProvider.control else {
            r.add("settings.scanFolders", false, "no page"); return
        }
        let native = { (rest: String) in WinPath.native(f.dir.appendingPathComponent(rest)) }
        var lines = [native("with space"), native("한글 폴더") + "\\", native("logs") + "/proj-*", native("missing")]
        var unc: String?
        let n = native("logs")
        if n.count > 3, Array(n)[1] == ":" {
            let share = "\\\\localhost\\\(Array(n)[0])$" + String(n.dropFirst(2)) + "\\proj-a"
            if FileManager.default.fileExists(atPath: share) { unc = share; lines.append(share) }
        }
        let draft = lines.joined(separator: "\r\n")
        let expected = CustomScanRoots.survivingExtraCount(defaults: CustomScanRoots.curatedRoots(for: "claude_code"), extraRaw: draft)
        let startedAt = Date()
        await type(draft, into: field)
        let early = t.shown(adv.rowsForTesting.scanMatches) && adv.rowsForTesting.scanMatches.hint?.text == l.customScanRootsMatches(expected)
        let counted = await t.waitFor(3) { adv.rowsForTesting.scanMatches.hint?.text == self.l.customScanRootsMatches(expected) && self.t.shown(adv.rowsForTesting.scanMatches) }
        let after = Date().timeIntervalSince(startedAt)
        await t.focus(combo)   // focus loss commits
        let committed = await t.waitFor(1) { f.store.customScanRoots(for: "claude_code") == draft }
        let codex = f.store.registeredProviders.firstIndex { $0.id == "codex" } ?? 1
        t.choose(combo, codex)
        let switched = await t.waitFor(1) { field.text == f.store.customScanRoots(for: "codex") && !self.t.shown(adv.rowsForTesting.scanMatches) }
        let claudeKept = f.store.customScanRoots(for: "claude_code") == draft
        t.choose(combo, 0)
        let back = await t.waitFor(1) { field.text == draft }
        await type(draft + "\r\n" + native("with space"), into: field)
        t.click(adv.disclosureForTesting)   // collapsing commits
        let collapsedCommit = await t.waitFor(1) { f.store.customScanRoots(for: "claude_code") == draft + "\r\n" + native("with space") }
        f.store.setCustomScanRoots("", for: "claude_code")
        let uncFound = unc.map { CustomScanRoots.expand($0).count == 1 } ?? true
        r.add("settings.scanFolders", counted && !early && committed && switched && claudeKept && back && collapsedCommit && expected >= 4 && uncFound,
              "draft of \(lines.count) folders (spaces, Hangul, a trailing \\, mixed separators with a wildcard, a missing one\(unc == nil ? "" : ", a UNC share \\\\localhost\\…, found=\(uncFound)")): "
                + "count '\(l.customScanRootsMatches(expected))' (= CustomScanRoots.survivingExtraCount for the same text, \(expected)) shown after \(String(format: "%.2f", after)) s, "
                + "not at once=\(!early); focus loss committed=\(committed); provider -> Codex: field shows Codex's folders=\(switched), Claude's kept=\(claudeKept); back=\(back); "
                + "collapse committed=\(collapsedCommit); counts landed \(adv.counts)")
        t.close()
    }

    // MARK: settings.additionalFolders

    func additionalCheck() async {
        let f = await fixture("additional")
        guard await open(f), let page = t.page, let adv = section, let field = adv.rowsForTesting.additionalField.control else {
            r.add("settings.additionalFolders", false, "no page"); return
        }
        let loaded = field.text == f.work.path
        let draft = WinPath.native(f.work) + "\r\n" + WinPath.native(f.dir.appendingPathComponent("second-claude")) + "\\"
        await type(draft, into: field)
        let found = await t.waitFor(3) { adv.rowsForTesting.additionalFound.hint?.text == self.l.additionalClaudeAccountsFound(2) }
        let rebuildsBefore = page.rebuildsForTesting
        t.key(0x0D /* VK_RETURN */)   // Enter commits (Ctrl+Enter would be a new line)
        let committed = await t.waitFor(2) { f.store.additionalClaudeConfigDirs == draft }
        let rows = await t.waitFor(5) { (self.section?.accounts.count ?? 0) == 2 }
        r.add("settings.additionalFolders", loaded && found && committed && rows && page.rebuildsForTesting > rebuildsBefore,
              "field loaded from the store=\(loaded); two folders typed -> '\(l.additionalClaudeAccountsFound(2))'=\(found); Enter committed=\(committed); "
                + "the page built again with 2 account key rows=\(rows) (rebuilds \(rebuildsBefore) -> \(page.rebuildsForTesting))")
        t.close()
    }

    // MARK: settings.trackedAccount

    func trackedCheck() async {
        let f = await fixture("tracked")
        guard await open(f, expand: false), let row = t.page?.trackedAccountForTesting?.row, let combo = row.control else {
            r.add("settings.trackedAccount", false, "no row"); return
        }
        let shown = t.shown(row)
        let count = WinKit.send(combo.hwnd, 0x0146 /* CB_GETCOUNT */)
        let hint = row.hint?.text ?? ""
        t.choose(combo, 1)
        let highest = await t.waitFor(1) { f.store.claudeTrackedAccountMode == .highest }
        t.choose(combo, count - 1)
        let pinned = await t.waitFor(1) { if case .account = f.store.claudeTrackedAccountMode { return true }; return false }
        let single = await fixture("tracked-single", withAccount: false)
        await open(single, expand: false)
        let hiddenWithOne = !(t.page?.trackedAccountForTesting.map { t.shown($0.row) } ?? true)
        r.add("settings.trackedAccount", shown && count == 4 && hint == l.winTrackedAccountHint && highest && pinned && hiddenWithOne,
              "two Claude accounts: row shown=\(shown) with \(count) choices (automatic, highest, each account), hint is the Windows wording=\(hint == l.winTrackedAccountHint); "
                + "highest chosen=\(highest); the additional account pinned=\(pinned); one account: row hidden=\(hiddenWithOne)")
        t.close()
    }

    // MARK: settings.sessionKeyRoute

    /// The two ways into the key field from Home: the (?)'s "Register session key" (no key yet) and the expired notice's
    /// Settings button. Each opens Settings with Advanced expanded, scrolled to it, the key field focused.
    func routeCheck() async {
        var notes: [String] = []
        var ok = true
        func landed(_ what: String) async {
            let up = await t.waitFor(3) { (self.t.page?.advancedForTesting?.draftsForTesting.expanded ?? false) && GetFocus() == self.section?.key.field?.hwnd }
            await t.pause(0.3)
            var inView = false
            if let field = section?.key.field, let area = t.page?.areaForTesting {
                let r = WinKit.rect(field.hwnd, in: area.viewport.hwnd)
                var client = RECT()
                _ = GetClientRect(area.viewport.hwnd, &client)
                inView = r.top >= 0 && r.bottom <= client.bottom
            }
            let topped = (t.page?.areaForTesting?.offset ?? 0) > 0
            ok = ok && up && inView && topped
            notes.append("\(what): Settings with Advanced expanded and the key field focused=\(up), field in view=\(inView), scrolled down to Advanced=\(topped)")
        }
        func button(_ title: String, ownerDrawn: Bool) -> HWND? {
            guard let hwnd = t.hwnd else { return nil }
            return SettingsRun.descendants(hwnd).first {
                WinKit.className($0) == "Button" && WinKit.text(of: $0) == title && IsWindowVisible($0)
                    && ((GetWindowLongW($0, -16) & 0xF) == 0xB) == ownerDrawn
            }
        }
        // (a) no key: the (?) next to "Limits (official)".
        let f = await fixture("route-help", withAccount: false)
        if await open(f, expand: false, home: true), let help = button(l.winClaudeCredentialHelpTooltip, ownerDrawn: true) {
            WinKit.send(help, 0x00F5 /* BM_CLICK */)
            _ = await t.waitFor(1) { button(self.l.registerSessionKey, ownerDrawn: false) != nil }
            record()
            if let register = button(l.registerSessionKey, ownerDrawn: false) {
                WinKit.send(register, 0x00F5)
                await landed("(?) -> '\(l.registerSessionKey)'")
            } else { ok = false; notes.append("no '\(l.registerSessionKey)' button under the note") }
        } else { ok = false; notes.append("no Home page with the (?)") }
        // (b) a saved key that claude.ai now refuses: the expired notice.
        let e = await fixture("route-expired", withAccount: false)
        await e.store.saveSessionKey(newKey(valid: true))
        e.http.rejectAll = true
        await e.store.refresh(scheduleEmptyRetry: false)
        let expired = e.store.limitsAuthExpiry == .sessionKey
        if expired, await open(e, expand: false, home: true), let settings = button(l.settings, ownerDrawn: false) {
            record()
            WinKit.send(settings, 0x00F5)
            await landed("expired notice -> '\(l.settings)'")
            let badge = section?.key.badge?.text ?? ""
            ok = ok && badge == l.sessionKeyExpiredBadge
            notes.append("badge '\(badge)'")
            _ = t.page?.escape()
            let back = await t.waitFor(2) { self.t.popover?.pageForTesting is WinHomePage && self.t.popover?.state.expandAdvancedOnOpen == false }
            ok = ok && back
            notes.append("Back -> Home, the route flag reset=\(back)")
        } else { ok = false; notes.append("expired state=\(expired); no Settings button in the notice") }
        r.add("settings.sessionKeyRoute", ok, notes.joined(separator: "; "))
        t.close()
    }

    // MARK: captures (FIXTURE data, the runner's popover window)

    func captureCheck(_ dir: URL) async {
        var wrote: [String] = [], failed: [String] = []
        let original = t.app.companion.language
        for language in [AppLanguage.en, .ko] {
            t.app.companion.setLanguage(language)
            let f = await fixture("cap-\(language.rawValue)")
            f.store.localizationLanguage = language
            await f.store.saveSessionKey(newKey(valid: true))
            guard await open(f), let adv = section else { failed.append("open \(language.rawValue)"); continue }
            await shoot(at: adv.top ?? 0, "advanced-\(language.rawValue)-saved.png", dir, &wrote, &failed)
            if let field = adv.key.field {
                await paste("not-a-session-key-FIXTURE", into: field)
                t.click(adv.key.save)
                _ = await t.waitFor(2) { self.t.shown(adv.key.errorRow) }
                field.text = ""
            }
            await shoot(at: adv.top ?? 0, "advanced-\(language.rawValue)-error.png", dir, &wrote, &failed)
            if let scan = adv.rowsForTesting.scanField.control {
                await type(WinPath.native(f.dir.appendingPathComponent("with space")) + "\r\n" + WinPath.native(f.dir.appendingPathComponent("logs")) + "\\proj-*", into: scan)
                _ = await t.waitFor(3) { self.t.shown(adv.rowsForTesting.scanMatches) }
                let y = t.page?.areaForTesting.map { WinKit.rect(adv.rowsForTesting.additional.label?.hwnd ?? scan.hwnd, in: $0.content.hwnd).top } ?? 0
                await shoot(at: y - 8, "advanced-\(language.rawValue)-folders.png", dir, &wrote, &failed)
                f.store.setCustomScanRoots("", for: "claude_code")
            }
            trees.append(writeTree(dir.appendingPathComponent("advanced-\(language.rawValue)-tree.json")))
            t.close()
        }
        t.app.companion.setLanguage(original)
        r.add("settings.advancedCapture", failed.isEmpty && wrote.count == 6,
              "sample capture, Windows CI runner, FIXTURE store and keys (a saved key shows only as dots): \(wrote.joined(separator: ", ")) and the control trees; failures \(failed)")
    }

    func shoot(at y: Int32, _ name: String, _ dir: URL, _ wrote: inout [String], _ failed: inout [String]) async {
        guard let hwnd = t.hwnd, let area = t.page?.areaForTesting else { failed.append(name); return }
        area.scroll(to: max(0, y))
        await t.pause(0.35)
        record()
        _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        await t.pause(0.2)
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &w, &h, &out) == 0, let out else { failed.append(name); return }
        defer { ptb_plaza_free(out) }
        let bitmap = WinUIDump.Bitmap(width: Int(w), height: Int(h), bgra: Array(UnsafeBufferPointer(start: out, count: Int(w * h) * 4)))
        if WinUIDump.write(bitmap, to: dir.appendingPathComponent(name)) == 0 { wrote.append(name) } else { failed.append(name) }
    }

    /// The popover's control tree as the kit's dump writes it: a password field's text is masked.
    func writeTree(_ url: URL) -> URL {
        struct Node: Codable { var cls: String; var text: String; var visible: Bool }
        var nodes: [Node] = []
        if let hwnd = t.hwnd {
            for h in SettingsRun.descendants(hwnd) {
                let cls = WinKit.className(h)
                let text = WinKit.text(of: h)
                let masked = cls == "Edit" && GetWindowLongW(h, -16) & 0x0020 != 0
                nodes.append(Node(cls: cls, text: masked ? "(masked, \(text.count) characters)" : text, visible: IsWindowVisible(h)))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? (try? encoder.encode(nodes))?.write(to: url)
        return url
    }

    // MARK: settings.keyFileUnreadable

    func unreadableCheck() {
        WinSecret.resetReportsForTesting()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-unreadable-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "session-key-unreadable-\(UUID().uuidString.prefix(8)).json"
        let url = dir.appendingPathComponent(name)
        let key = newKey(valid: true)
        let foreign = WinSecret.protect((try? JSONEncoder().encode(SessionKeyCredential(key: key, organizationID: nil))) ?? Data(),
                                        entropy: Data("not this app".utf8)) ?? Data()
        try? foreign.write(to: url)
        let store = SessionKeyStore(fileURL: url)
        let first = store.load(), second = store.load()
        AppLog.flush()
        let log = (try? String(contentsOf: AppLog.logFileURL, encoding: .utf8)) ?? ""
        let lines = log.components(separatedBy: "\n").filter { $0.contains(name) }
        r.add("settings.keyFileUnreadable", first == nil && second == nil && lines.count == 1 && !lines.joined().contains("sk-ant-"),
              "a key file DPAPI cannot decrypt here (made for another entropy: a copy from another app, PC or account) read twice: no key both times=\(first == nil && second == nil); "
                + "log lines naming it \(lines.count) (expected 1): \(lines.first.map { line in String(line.drop { ch in ch != "]" }.dropFirst()) } ?? "none")")
    }

    // MARK: settings.keyLeak

    func leakCheck() {
        AppLog.flush()
        let log = (try? String(contentsOf: AppLog.logFileURL, encoding: .utf8)) ?? ""
        let treeText = trees.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        // A key cut anywhere still shows one of these: the whole key, its first 16 random characters after the fixture prefix,
        // its last 24. And nothing in the app or this selftest logs the key prefix itself (no check line prints a placeholder or
        // an error text that holds it), so any "sk-ant-" in the log is a leak.
        let needles = keys.flatMap { key -> [String] in
            let random = key.dropFirst(AdvancedFixtureHTTP.validPrefix.count)
            return [key, String(random.prefix(16)), String(key.suffix(24))]
        }
        let inLog = needles.filter { log.contains($0) }.count
        let prefixInLog = log.components(separatedBy: "sk-ant-").count - 1
        let inTexts = needles.filter { n in seenTexts.contains { $0.contains(n) } }.count
        let inTrees = needles.filter { treeText.contains($0) }.count
        let dumped = WindowsSelftestPopoverWindow.dumpDirectory() != nil
        r.add("settings.keyLeak", inLog == 0 && prefixInLog == 0 && inTexts == 0 && inTrees == 0 && !keys.isEmpty && (trees.isEmpty != dumped),
              "\(keys.count) fixture keys (whole, the first 16 random characters, the last 24) looked for: in the \(log.utf8.count)-byte log \(inLog) "
                + "(and the key prefix itself \(prefixInLog) times), in \(seenTexts.count) window texts and tooltips recorded during the group \(inTexts), "
                + "in \(trees.count) control trees written with the captures \(inTrees)")
    }
}

#endif
