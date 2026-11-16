#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 6: the Settings page's selftest group (`settings.*`). The page opens in a popover of its own over fixtures (the
// app's store and companion, a fixture team, update checker and login-item key) so the runner's real tray menu and Run key
// are not touched; `settings.teamTransport` uses the app's real team runtime behind a popover whose plaza button is a
// counter (the real plaza would load Direct3D). Real keys (`SendInput`) and the clipboard only on the runner (`CI`). The
// team code is a secret even here: no check prints a code, a code never appears in a window text outside the join field
// while it is typed, and the log is read at the end for it. Captures (`--dump-ui <dir>`) go to `<dir>/settings/` with
// FIXTURE data only.

extension WindowsSelftest {
    @MainActor static func settingsChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestSettings.run(r, app)
    }

    /// The page over the app's real team runtime. After the idle window: a stopped team transport keeps its socket loop thread
    /// (only the listener and the advertisement go), and `team.offWithoutCode` and the idle window expect no loop at all.
    @MainActor static func settingsTransportChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestSettings.runTransport(r, app)
    }
}

@MainActor enum WindowsSelftestSettings {
    static let names = ["settings.page", "settings.language", "settings.refreshInterval", "settings.launchAtLogin", "settings.keys",
                        "settings.teamJoin", "settings.joinErrors", "settings.nicknameHangul", "settings.openPlazaAfterNickname",
                        "settings.teamTransport", "settings.teamCopy", "settings.updates", "settings.report", "settings.escape",
                        "settings.secret", "settings.openClose"]

    static func runTransport(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI, let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("settings.teamTransport", true, "skipped: CI not set")
            return
        }
        defer { probe.destroy() }
        let t = SettingsRun(r: r, app: app, probe: probe)
        await t.transportCheck()
        t.cleanUp()
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            for name in names where name != "settings.teamTransport" { r.add(name, true, "skipped: CI not set (the page takes the foreground; real keys and the clipboard are used)") }
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("settings.page", false, "no probe window: \(GetLastError())")
            return
        }
        defer { probe.destroy() }
        let t = SettingsRun(r: r, app: app, probe: probe)
        let start = PopoverResources.now()
        await t.pageCheck()
        await t.languageCheck()
        await t.refreshCheck()
        await t.loginCheck()
        await t.keysCheck()
        await t.teamJoinCheck()
        await t.joinErrorsCheck()
        await t.hangulCheck()
        await t.openPlazaCheck()
        await t.copyCheck()
        await t.updatesCheck()
        await t.reportCheck()
        await t.escapeCheck()
        if let dir = WindowsSelftestPopoverWindow.dumpDirectory().map({ $0.deletingLastPathComponent().appendingPathComponent("settings", isDirectory: true) }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await t.captureChecks(dir)
        }
        await t.openCloseCheck(start: start)
        t.secretCheck()
        t.cleanUp()
    }
}

/// One run of the group.
@MainActor final class SettingsRun {
    let r: WindowsSelftest.Recorder
    let app: WindowsAppDelegate
    let probe: WinSinkWindow
    let suite = "ptb.selftest.settings.\(UUID().uuidString.prefix(8))"
    let loginKey = #"Software\PokeTokenBarSelftest\Settings\Run"#, approvedKey = #"Software\PokeTokenBarSelftest\Settings\Approved"#
    let loginName = "PokeTokenBarSettings"
    var plazaOpens = 0
    var popover: WinPopover?
    /// Every fixture team code of the run, to look for in the log at the end (never printed).
    var secrets: [String] = []
    var urls: [URL] = []
    var logged: [URL] = []

    init(r: WindowsSelftest.Recorder, app: WindowsAppDelegate, probe: WinSinkWindow) {
        self.r = r
        self.app = app
        self.probe = probe
    }

    var page: WinSettingsPage? { popover?.pageForTesting as? WinSettingsPage }
    var hwnd: HWND? { popover?.hwndForTesting }
    var l: L { app.companion.l }

    func defaults(_ name: String) -> UserDefaults { UserDefaults(suiteName: "\(suite).\(name)") ?? .standard }

    func loginItem() -> WindowsLoginItem {
        WindowsLoginItem(runKey: loginKey, approvedKey: approvedKey, valueName: loginName,
                         command: WindowsLoginItem.command(forExecutable: #"C:\Fixture\PokeTokenBar.exe"#))
    }

    func newTeam(_ name: String, enabled: Bool = true, code: TeamCode? = nil, nickname: String = "") -> TeamSettings {
        let team = TeamSettings(defaults: defaults(name))
        team.isEnabled = enabled
        if let code { team.code = code; secrets.append(code.display); secrets.append(code.normalized) }
        team.nickname = nickname
        return team
    }

    func fixtureCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        secrets.append(code.display)
        secrets.append(code.normalized)
        return code
    }

    func updater(latest: String?, name: String) -> UpdateChecker {
        UpdateChecker(currentVersion: "2.5.613", defaults: defaults(name), fetchLatest: {
            latest.map { UpdateChecker.LatestRelease(tag: $0, url: "https://github.com/\(UpdateChecker.releaseRepo)/releases/tag/\($0)") }
        }, brewLocator: { nil })
    }

    // MARK: opening

    /// Settings in a popover of its own (the fixture host), opened as the tray menu's "Settings…" does.
    @discardableResult
    func open(team: TeamSettings? = nil, updater: UpdateChecker? = nil, session: TeamSession? = nil, feed: TeamFeedStore? = nil,
              login: WindowsLoginItem? = nil) async -> Bool {
        close()
        let host = WinPopoverHost(store: app.store, companion: app.companion, updater: updater, team: team ?? newTeam("default", enabled: false),
                                  session: session, feed: feed, tray: nil, loginItem: login ?? loginItem(),
                                  openPlaza: { [weak self] in self?.plazaOpens += 1 })
        host.owner = app.sink.hwnd
        let p = WinPopover(host: host)
        p.makePage = WinSettingsPage.routed
        popover = p
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == self.probe.hwnd }
        p.present(.secondLaunch) { $0.showSettings = true }
        let up = await WindowsSelftest.waitUntil(timeout: 2) {
            guard let h = p.hwndForTesting else { return false }
            return IsWindowVisible(h) && GetForegroundWindow() == h && p.pageForTesting is WinSettingsPage
        }
        await pause(0.25)
        page?.openURL = { [weak self] url in self?.urls.append(url); return true }
        page?.revealLog = { [weak self] url in self?.logged.append(url) }
        return up
    }

    func close() {
        popover?.close(.destroyed)
        popover = nil
    }

    typealias TeamRowSet = (enable: WinRow, code: WinRow, leave: WinRow, name: WinRow, switcher: WinRow, create: WinRow, join: WinRow,
                            joinButton: WinRow, nickname: WinRow, nicknameError: WinRow, joinError: WinRow)

    /// The team rows NOW: joining, creating or leaving a team changes the saved list and the page builds itself again, so a row
    /// set kept from before is dead (its windows are destroyed).
    func rows() -> TeamRowSet { page!.teamForTesting!.rowsForTesting }

    /// Time for a rebuild the page queued (it runs from the main queue).
    func settle() async { await pause(0.5) }

    /// The clipboard holds `text`; the join field takes it with all of its own text selected (what a user's Ctrl+A, Ctrl+V does),
    /// through `WM_PASTE`, the message the edit's right-click Paste sends.
    func paste(_ text: String) async {
        _ = clipboard(text)
        guard let e = rows().join.control else { return }
        await focus(e)
        WinKit.send(e.hwnd, 0x00B1 /* EM_SETSEL */, 0, -1)
        _ = SendMessageW(e.hwnd, 0x0302 /* WM_PASTE */, 0, 0)
    }

    func pause(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    // MARK: driving controls (the messages a user's click or choice sends)

    func click(_ control: WinControl?, part: Int = 0) {
        guard let control, control.parts.indices.contains(part) else { return }
        WinKit.send(control.parts[part], 0x00F5 /* BM_CLICK */)
    }

    /// A click on a text link: `SysLink` tells its parent with `NM_CLICK` (a `BM_CLICK` does nothing to it).
    func clickLink(_ control: WinControl?) {
        guard let control, let parent = GetParent(control.hwnd) else { return }
        let id = UINT_PTR(GetDlgCtrlID(control.hwnd))
        var header = NMHDR(hwndFrom: control.hwnd, idFrom: id, code: UINT(bitPattern: -2))
        _ = withUnsafeMutablePointer(to: &header) { SendMessageW(parent, 0x004E /* WM_NOTIFY */, WPARAM(id), LPARAM(Int(bitPattern: $0))) }
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

    func focus(_ control: WinControl?) async {
        guard let control else { return }
        _ = SetFocus(control.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { GetFocus() == control.hwnd }
    }

    func chars(_ text: String, to edit: HWND) {
        for unit in text.utf16 { _ = PostMessageW(edit, UINT(WM_CHAR), WPARAM(unit), 1) }
    }

    func key(_ vk: UInt16, ctrl: Bool = false) {
        var inputs: [INPUT] = []
        func ki(_ code: UInt16, up: Bool) -> INPUT {
            var i = INPUT()
            i.type = DWORD(INPUT_KEYBOARD)
            i.ki.wVk = code
            i.ki.dwFlags = up ? DWORD(KEYEVENTF_KEYUP) : 0
            return i
        }
        if ctrl { inputs.append(ki(0x11, up: false)) }
        inputs.append(ki(vk, up: false))
        inputs.append(ki(vk, up: true))
        if ctrl { inputs.append(ki(0x11, up: true)) }
        _ = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    func clipboard(_ text: String) -> Bool { WinTextClipboard.write(text, secret: true, owner: probe.hwnd) }

    func clearClipboard() {
        if OpenClipboard(probe.hwnd) { _ = EmptyClipboard(); _ = CloseClipboard() }
    }

    // MARK: reading the window

    static func descendants(_ root: HWND) -> [HWND] {
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

    func visibleTexts() -> [String] {
        guard let hwnd else { return [] }
        return Self.descendants(hwnd).filter { IsWindowVisible($0) }.map { WinKit.text(of: $0) }.filter { !$0.isEmpty }
    }

    func isShown(_ control: WinControl?) -> Bool { control.map { IsWindowVisible($0.hwnd) } ?? false }

    func shown(_ row: WinRow?) -> Bool { isShown(row?.control) || isShown(row?.hint) || isShown(row?.label) }

    func waitFor(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        await WindowsSelftest.waitUntil(timeout: timeout, condition)
    }

    func contains(_ texts: [String], _ needle: String) -> Bool { texts.contains { $0.contains(needle) } }

    // MARK: settings.page

    func pageCheck() async {
        let up = await open()
        guard up, let page, let hwnd else { r.add("settings.page", false, "open=\(up)"); return }
        let texts = visibleTexts()
        let l = self.l, ko = L(.ko)
        let wanted = [l.generalSectionTitle.uppercased(), l.language, l.refreshInterval, l.limitDisplayModeLabel, l.dailyTrendPeriod, l.launchAtLogin, l.backViewLabel,
                      l.trackedProvidersSectionTitle.uppercased(), ko.teamSectionTitle.uppercased(), ko.teamEnable, l.notificationsSection.uppercased(),
                      l.updateSectionTitle.uppercased(), l.aboutSupportSectionTitle.uppercased(), l.reportProblem, l.showLogFile, l.winExplorerButton,
                      l.settings, l.back]
        let missing = wanted.filter { !contains(texts, $0) }
        // Rows of the Mac that mean nothing on Windows, and the team details while the team is off.
        let forbidden = [l.menuBarSectionTitle.uppercased(), l.disableKeychain, l.todayTokensShort, "Finder", "Keychain", ko.teamCreate, ko.teamJoin, ko.teamNickname,
                         l.animationQualityLabel, l.floatingPetSectionTitle.uppercased()]
        let present = forbidden.filter { contains(texts, $0) }
        // The keyboard order is the reading order: the focusable controls of the body from top to bottom.
        let body = page.stackForTesting?.controls.filter { c in
            c.parts.contains { IsWindowVisible($0) && (GetWindowLongW($0, -16) & 0x0001_0000) != 0 }
        } ?? []
        var tops: [Int32] = []
        for c in body { if let area = page.areaForTesting { tops.append(WinKit.rect(c.hwnd, in: area.content.hwnd).top) } }
        let ordered = zip(tops, tops.dropFirst()).allSatisfy { $0 <= $1 }
        let foregrounded = GetForegroundWindow() == hwnd
        r.add("settings.page", missing.isEmpty && present.isEmpty && ordered && body.count >= 15 && foregrounded,
              "opened as the tray menu's Settings…; foreground=\(foregrounded); height \(popover?.stats.lastFrame.bottom ?? 0) - \(popover?.stats.lastFrame.top ?? 0) px; "
                + "visible texts \(texts.count), missing \(missing), Mac-only shown \(present); \(body.count) focusable body controls in reading order=\(ordered)")
        close()
    }

    // MARK: settings.language

    func languageCheck() async {
        let original = app.companion.language
        let target: AppLanguage = original == .ja ? .ko : .ja
        guard await open(), let page else { r.add("settings.language", false, "no page"); return }
        let index = AppLanguage.allCases.firstIndex(of: target) ?? 0
        choose(page.rowsForTesting.language?.control, index)
        let switched = await waitFor(3) { self.visibleTexts().contains(L(target).settings) }
        let texts = visibleTexts()
        let l = L(target)
        let stale = [L(original).settings, L(original).generalSectionTitle.uppercased(), L(original).refreshInterval].filter {
            texts.contains($0) && ![l.settings, l.generalSectionTitle.uppercased(), l.refreshInterval].contains($0)
        }
        let tray = app.tray?.menuItems().compactMap { $0?.title } ?? []
        let trayOK = tray.contains(l.settings + "…") && tray.contains(l.backViewLabel) && tray.contains(l.launchAtLogin)
        let state = app.companion.language == target && app.store.localizationLanguage == target
        r.add("settings.language", switched && state && trayOK && stale.isEmpty && page.languageRebuilds == 1 && contains(texts, l.refreshInterval),
              "chose \(target.rawValue) in the combo box: open page now says '\(l.settings)' (switched=\(switched)), stale texts of \(original.rawValue) \(stale), companion/store language "
                + "\(app.companion.language.rawValue)/\(app.store.localizationLanguage.rawValue), tray menu in \(target.rawValue)=\(trayOK) (\(tray.prefix(3).joined(separator: " | "))), rebuilds \(page.languageRebuilds)")
        app.companion.setLanguage(original)
        app.store.localizationLanguage = original
        close()
    }

    // MARK: settings.refreshInterval

    func refreshCheck() async {
        let original = app.store.refreshInterval
        guard await open(), let page else { r.add("settings.refreshInterval", false, "no page"); return }
        let presets = UsageStore.intervalPresets
        let two = presets.firstIndex { $0.value == 120 } ?? 2, manual = presets.firstIndex { $0.value == 0 } ?? 0
        choose(page.rowsForTesting.refresh?.control, two)
        let scheduled = app.store.refreshInterval == 120 && app.store.isPollingTimerScheduled
        let key = app.defaults.double(forKey: "refreshInterval")
        choose(page.rowsForTesting.refresh?.control, manual)
        let stopped = app.store.refreshInterval == 0 && !app.store.isPollingTimerScheduled
        let shows = page.rowsForTesting.refresh?.control?.selection == manual
        r.add("settings.refreshInterval", scheduled && key == 120 && stopped && shows,
              "2 min chosen: store \(120), timer scheduled=\(scheduled), defaults key refreshInterval=\(key); Manual chosen: timer stopped=\(stopped); combo shows Manual=\(shows)")
        app.store.refreshInterval = original
        close()
    }

    // MARK: settings.launchAtLogin

    func loginCheck() async {
        WinRegistry.deleteTree(#"Software\PokeTokenBarSelftest"#)
        defer { WinRegistry.deleteTree(#"Software\PokeTokenBarSelftest"#) }
        let item = loginItem()
        guard await open(login: item), let page, let box = page.rowsForTesting.login?.control else { r.add("settings.launchAtLogin", false, "no page"); return }
        let offAtOpen = !box.isOn && box.isEnabled && item.state == .off
        click(box)
        let on = item.state == .on && box.isOn
        click(box)
        let off = item.state == .off && !box.isOn
        // Task Manager turned it off: read on page open, the box is disabled and says why.
        _ = item.setEnabled(true)
        _ = WinRegistry.setBytes(approvedKey, loginName, [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let reopened = await open(login: item)
        let hint = l.disabledInTaskManager
        let blocked = reopened && !(self.page?.rowsForTesting.login?.control?.isEnabled ?? true) && contains(visibleTexts(), hint) && item.state == .disabledByUser
        r.add("settings.launchAtLogin", offAtOpen && on && off && blocked,
              "closed at open=\(offAtOpen); click -> Run value written and read back=\(on); click -> removed=\(off); Task Manager's off bit set, page reopened: box disabled with '\(hint)'=\(blocked)")
        close()
    }

    // MARK: settings.keys

    func keysCheck() async {
        let store = app.store!
        let saved = (store.alwaysFacesBack, store.limitDisplayMode, store.limitNotifications, store.warnThreshold, store.critThreshold,
                     store.companionNotifications, store.statusChecksEnabled, store.updateNotificationsEnabled)
        guard await open(), let page else { r.add("settings.keys", false, "no page"); return }
        var notes: [String] = []
        var ok = true
        func step(_ name: String, _ pass: Bool) { ok = ok && pass; if !pass { notes.append("\(name) FAILED") } }
        let rows = page.rowsForTesting
        let d = app.defaults!
        click(rows.backView?.control)
        step("backView", store.alwaysFacesBack == !saved.0 && d.bool(forKey: "alwaysFacesBack") == !saved.0)
        click(rows.limitDisplay?.control, part: 1)
        step("limitDisplay", store.limitDisplayMode == .remaining && d.string(forKey: "limitDisplayMode") == "remaining")
        click(rows.limitDisplay?.control, part: 0)
        step("limitDisplayBack", store.limitDisplayMode == .used)
        // Notifications: the sliders show only with the alerts on, the push-along of the two thresholds shows in the other slider.
        if !store.limitNotifications { click(rows.limitAlerts?.control) }
        await pause(0.2)
        step("sliders shown", shown(rows.warn) && shown(rows.crit))
        slide(rows.warn?.control, to: 95)
        await pause(0.2)
        step("warn", store.warnThreshold == 95 && d.double(forKey: "warnThreshold") == 95)
        step("crit pushed to 100 and shown", store.critThreshold == 100 && rows.crit?.control?.value == 100 && d.double(forKey: "critThreshold") == 100)
        slide(rows.warn?.control, to: 60)
        slide(rows.crit?.control, to: 85)
        step("crit", store.critThreshold == 85 && d.double(forKey: "critThreshold") == 85 && store.warnThreshold == 60)
        click(rows.limitAlerts?.control)
        await pause(0.2)
        step("limit alerts off", !store.limitNotifications && d.object(forKey: "limitNotifications") as? Bool == false && !shown(rows.warn) && !shown(rows.crit))
        click(rows.companionAlerts?.control)
        step("companion", store.companionNotifications == !saved.5 && d.bool(forKey: "companionNotifications") == !saved.5)
        click(rows.statusChecks?.control)
        step("statusChecks", store.statusChecksEnabled == !saved.6 && d.bool(forKey: "statusChecksEnabled") == !saved.6)
        click(rows.updateNotifications?.control)
        step("updateNotifications", store.updateNotificationsEnabled == !saved.7 && d.bool(forKey: "updateNotificationsEnabled") == !saved.7)
        // A provider: off and on again, in the same defaults key.
        let providers = page.providerRowsForTesting
        if let first = providers.first, let id = store.registeredProviders.first?.id {
            click(first.control)
            let off = !store.isProviderEnabled(id) && (d.stringArray(forKey: UsageStore.disabledProvidersKey) ?? []).contains(id)
            click(first.control)
            step("provider", off && store.isProviderEnabled(id))
        } else { step("provider rows", false) }
        // A change from elsewhere (the tray menu) shows in the open page.
        store.alwaysFacesBack = saved.0
        let followed = await waitFor(1) { rows.backView?.control?.isOn == saved.0 }
        step("change from elsewhere shown", followed)
        // Put everything back.
        store.limitNotifications = saved.2
        store.critThreshold = saved.4
        store.warnThreshold = saved.3
        store.companionNotifications = saved.5
        store.statusChecksEnabled = saved.6
        store.updateNotificationsEnabled = saved.7
        r.add("settings.keys", ok, "\(providers.count) provider switches; back view, limit display, alerts, both sliders (push-along), companion, status checks, update notifications and a provider "
              + "written to the Mac's defaults keys and read back; a change from elsewhere shown; \(notes.isEmpty ? "no failures" : notes.joined(separator: ", "))")
        close()
    }

    // MARK: settings.teamJoin

    func teamJoinCheck() async {
        let team = newTeam("join", nickname: "")
        let code = fixtureCode()
        guard await open(team: team), let page, let section = page.teamForTesting else { r.add("settings.teamJoin", false, "no page"); return }
        guard let edit = rows().join.control else { r.add("settings.teamJoin", false, "no join field"); return }
        let visibleBefore = shown(rows().join) && shown(rows().joinButton) && shown(rows().create)
        // Ctrl+V of " PTB-…\r\n" (a pasted line with its white space).
        let wrote = clipboard(" \(code.display)\r\n")
        await focus(edit)
        WinKit.send(edit.hwnd, 0x00B1, 0, -1)
        key(0x56, ctrl: true)
        let pasted = await waitFor(2) { edit.text == code.display }
        let shownMasked = !visibleTexts().contains { $0.contains(code.display) && $0 != edit.text }
        key(0x0D)   // Enter joins
        let joined = await waitFor(2) { team.code == code }
        let cleared = edit.text.isEmpty
        let noPlaza = plazaOpens == 0   // no nickname yet: the plaza waits for it
        await settle()
        let masked = shown(rows().code) && rows().code.label?.text == TeamSetup.masked(code) && !visibleTexts().contains { $0.contains(code.display) }
        // Leave, then the right-click menu's Paste (WM_PASTE is what its item sends) and the Join button.
        click(rows().leave.control)
        let left = await waitFor(2) { team.code == nil }
        await settle()
        await paste("\r\n\(code.display) ")
        let pasted2 = await waitFor(1) { rows().join.control?.text == code.display }
        click(rows().joinButton.control)
        let rejoined = await waitFor(2) { team.code == code }
        clearClipboard()
        r.add("settings.teamJoin", wrote && visibleBefore && pasted && shownMasked && joined && cleared && noPlaza && masked && left && pasted2 && rejoined,
              "Ctrl+V of ' <code>\\r\\n': field holds exactly the code=\(pasted), nothing else shows it=\(shownMasked); Enter -> joined=\(joined), field cleared=\(cleared), plaza waits for a nickname=\(noPlaza), "
                + "masked row shows only the masked code=\(masked); Leave -> left=\(left); WM_PASTE of '\\r\\n<code> ' (the context menu's Paste) -> field=\(pasted2); Join button -> joined=\(rejoined)")
        close()
    }

    // MARK: settings.joinErrors

    func joinErrorsCheck() async {
        let team = newTeam("errors", nickname: "다람")
        guard await open(team: team), let page, let section = page.teamForTesting else { r.add("settings.joinErrors", false, "no page"); return }
        await paste("PTB-nope")
        click(rows().joinButton.control)
        let shownError = await waitFor(1) { self.shown(rows().joinError) }
        let text = rows().joinError.hint?.text ?? ""
        let noCode = team.code == nil
        let red = rows().joinError.hint?.role == .error
        clearClipboard()
        // A paste with no text on the clipboard changes nothing (the kit's rule), the typed selection stays.
        r.add("settings.joinErrors", shownError && text == L(.ko).teamCodeInvalid && noCode && red,
              "'PTB-nope' + Join: error row shown=\(shownError) with the Mac's text '\(text)' in the error colour=\(red); no team joined=\(noCode)")
        close()
    }

    // MARK: settings.nicknameHangul

    func hangulCheck() async {
        let team = newTeam("hangul", code: fixtureCode(), nickname: "")
        guard await open(team: team), let page, let section = page.teamForTesting else { r.add("settings.nicknameHangul", false, "no page"); return }
        guard let nick = rows().nickname.control else { r.add("settings.nicknameHangul", false, "no nickname field"); return }
        let errorBefore = await waitFor(1) { self.shown(rows().nicknameError) }
        await focus(nick)
        chars("다람", to: nick.hwnd)                                   // posted WM_CHAR
        _ = PostMessageW(nick.hwnd, 0x0286 /* WM_IME_CHAR */, WPARAM(0xD55C), 1)   // what a composition's result is: 한
        await pause(0.2)
        WindowsSelftestPopover.typeUnicode(0xAE00)                     // real typed U+AE00 (글)
        let typed = await waitFor(1) { nick.text == "다람한글" }
        let draftText = nick.text
        let errorGone = await waitFor(1) { !self.shown(rows().nicknameError) }
        let before = team.nickname.isEmpty   // not committed while typing
        // Focus loss commits: the focus goes to another control of the page.
        await focus(section.rowsForTesting.enable.control)
        let committed = await waitFor(1) { team.nickname == "다람한글" }
        r.add("settings.nicknameHangul", errorBefore && typed && errorGone && before && committed,
              "empty nickname shows the red line=\(errorBefore); posted WM_CHAR 다람 + WM_IME_CHAR 한 + typed 글 -> field exactly 4 syllables once=\(typed) (\(draftText.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))); "
                + "line gone while typing=\(errorGone); stored only after focus loss (empty before=\(before), after=\(committed))")
        close()
    }

    // MARK: settings.openPlazaAfterNickname

    func openPlazaCheck() async {
        let code = fixtureCode()
        // Joined without a nickname: the plaza opens when the nickname is committed (Enter), once.
        let team = newTeam("plaza", nickname: "")
        plazaOpens = 0
        guard await open(team: team), let page, let section = page.teamForTesting else { r.add("settings.openPlazaAfterNickname", false, "no page"); return }
        await paste(code.display)
        click(rows().joinButton.control)
        _ = await waitFor(1) { team.code == code }
        await settle()
        let waiting = plazaOpens == 0 && !team.isReady
        await focus(rows().nickname.control)
        if let nick = rows().nickname.control { chars("가나", to: nick.hwnd) }
        await pause(0.2)
        key(0x0D)
        let opened = await waitFor(2) { self.plazaOpens == 1 }
        await pause(0.4)
        let once = plazaOpens == 1
        // A nickname already there: joining opens the plaza at once.
        team.leaveTeam()
        team.isEnabled = true
        _ = await waitFor(1) { self.shown(rows().join) }
        await settle()
        await paste(code.display)
        click(rows().joinButton.control)
        let direct = await waitFor(2) { self.plazaOpens == 2 }
        clearClipboard()
        r.add("settings.openPlazaAfterNickname", waiting && opened && once && direct && team.nickname == "가나",
              "joined with no nickname: plaza waits=\(waiting); nickname 가나 + Enter -> the plaza opened=\(opened) exactly once=\(once) (opens \(plazaOpens)); "
                + "joined again with the nickname set -> opened at once=\(direct)")
        close()
    }

    // MARK: settings.teamCopy

    func copyCheck() async {
        let code = fixtureCode()
        let team = newTeam("copy", code: code, nickname: "다람")
        clearClipboard()
        guard await open(team: team), let page, let section = page.teamForTesting else { r.add("settings.teamCopy", false, "no page"); return }
        let maskedOnly = rows().code.label?.text == TeamSetup.masked(code) && !visibleTexts().contains { $0.contains(code.display) || $0.contains(code.normalized) }
        let before = WinTextClipboard.read()
        let untouched = before == nil || before != code.display   // nothing copies without a click
        click(rows().code.control)
        let copied = await waitFor(1) { WinTextClipboard.read() == code.display }
        let history = WinTextClipboard.hasFormat("CanIncludeInClipboardHistory") && WinTextClipboard.hasFormat("CanUploadToCloudClipboard")
            && WinTextClipboard.hasFormat("ExcludeClipboardContentFromMonitorProcessing")
        let clicks = section.copies
        clearClipboard()
        r.add("settings.teamCopy", maskedOnly && untouched && copied && history && clicks == 1,
              "page shows only the masked code (no window text holds the code)=\(maskedOnly); clipboard untouched before the click=\(untouched); Copy -> clipboard holds the code=\(copied), "
                + "history and cloud opt-out formats present=\(history), copies=\(clicks); clipboard cleared after")
        close()
    }

    // MARK: settings.updates

    func updatesCheck() async {
        var notes: [String] = []
        var ok = true
        // An offer.
        let offer = updater(latest: "v2.5.700", name: "u1")
        guard await open(updater: offer), let page else { r.add("settings.updates", false, "no page"); return }
        let hiddenBefore = !shown(page.rowsForTesting.updateOffer) && !shown(page.rowsForTesting.updateCurrent)
        click(page.rowsForTesting.checkNow?.control)
        let offered = await waitFor(3) { self.contains(self.visibleTexts(), self.l.updateFound("2.5.700")) }
        let button = shown(page.rowsForTesting.updateOffer) && page.rowsForTesting.updateOffer?.control?.isEnabled == true
        ok = ok && hiddenBefore && offered && button
        notes.append("offer: hidden before=\(hiddenBefore) shown after Check now='\(l.updateFound("2.5.700"))'=\(offered) with its Update button=\(button)")
        // Skipped: offered again by "show again".
        defaults("u2").set("2.5.700", forKey: UpdateChecker.skippedVersionKey)
        guard await open(updater: updater(latest: "v2.5.700", name: "u2")), let page2 = self.page else { r.add("settings.updates", false, "no page"); return }
        click(page2.rowsForTesting.checkNow?.control)
        let skipped = await waitFor(3) { self.contains(self.visibleTexts(), self.l.skippedVersion("2.5.700")) }
        click(page2.rowsForTesting.updateSkipped?.control)
        let again = await waitFor(2) { self.contains(self.visibleTexts(), self.l.updateFound("2.5.700")) }
        ok = ok && skipped && again
        notes.append("skipped: shown='\(l.skippedVersion("2.5.700"))'=\(skipped); Show again -> offer=\(again)")
        // Up to date.
        let current = updater(latest: "v2.5.613", name: "u3")
        guard await open(updater: current), let page3 = self.page else { r.add("settings.updates", false, "no page"); return }
        click(page3.rowsForTesting.checkNow?.control)
        let uptodate = await waitFor(3) { self.contains(self.visibleTexts(), self.l.upToDate(WinSettingsPage.appVersion)) }
        let noOffer = !shown(page3.rowsForTesting.updateOffer)
        ok = ok && uptodate && noOffer
        notes.append("current: '\(l.upToDate(WinSettingsPage.appVersion))' shown=\(uptodate), no offer=\(noOffer)")
        r.add("settings.updates", ok, notes.joined(separator: "; "))
        close()
    }

    // MARK: settings.report

    func reportCheck() async {
        guard await open(), let page else { r.add("settings.report", false, "no page"); return }
        urls = []
        logged = []
        click(page.rowsForTesting.report?.control)
        await pause(0.2)
        let url = urls.first
        let comps = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let body = comps?.queryItems?.first { $0.name == "body" }?.value ?? ""
        let subject = comps?.queryItems?.first { $0.name == "subject" }?.value ?? ""
        let mailOK = url?.scheme == "mailto" && comps?.path == SupportMail.address && body.contains("Windows:") && body.contains(#"%LOCALAPPDATA%\PokeTokenBar\Logs"#)
            && !body.contains("macOS") && !body.contains("~/Library") && subject.hasPrefix("[PokeTokenBar]")
        let noFallback = !shown(page.rowsForTesting.fallback)
        // No mail app: the address shows in a read-only field.
        page.openURL = { _ in false }
        click(page.rowsForTesting.report?.control)
        let fallback = await waitFor(1) { self.shown(page.rowsForTesting.fallback) }
        let edit = page.rowsForTesting.fallback?.control
        let readOnly = edit.map { (GetWindowLongW($0.hwnd, -16) & 0x0800 /* ES_READONLY */) != 0 } ?? false
        let address = edit?.text == SupportMail.address
        // Explorer and a footer link.
        click(page.rowsForTesting.log?.control)
        let revealed = logged.first == AppLog.logFileURL
        page.openURL = { [weak self] u in self?.urls.append(u); return true }
        urls = []
        clickLink(page.footerControlsForTesting.first { $0.kind == .link })
        await pause(0.1)
        let link = urls.first?.host == "github.com"
        let allowed = WindowsShell.isOpenable(URL(string: "mailto:a@b.c")!) && !WindowsShell.isOpenable(URL(string: "ftp://x")!) && !WindowsShell.isOpenable(URL(string: "javascript:1")!)
        r.add("settings.report", mailOK && noFallback && fallback && readOnly && address && revealed && link && allowed,
              "Report a problem -> mailto to the support address with subject, a body naming Windows and %LOCALAPPDATA%\\PokeTokenBar\\Logs and no Mac words=\(mailOK), fallback hidden=\(noFallback); "
                + "no mail app -> address field shown=\(fallback) read-only=\(readOnly) with the address=\(address); Explorer button -> log file revealed=\(revealed); footer GitHub link opens github.com=\(link); "
                + "shell allows mailto, refuses ftp and javascript=\(allowed)")
        close()
    }

    // MARK: settings.escape

    func escapeCheck() async {
        let team = newTeam("escape", code: fixtureCode(), nickname: "다람")
        guard await open(team: team), let page, let section = page.teamForTesting, let nick = section.rowsForTesting.nickname.control else {
            r.add("settings.escape", false, "no page")
            return
        }
        await focus(nick)
        WinKit.send(nick.hwnd, 0x00B1, 99, 99)   // caret at the end
        WindowsSelftestPopover.typeUnicode(0x5A)   // Z: a typed character reaches the field
        WindowsSelftestPopover.typeUnicode(0xD55C)
        _ = await waitFor(1) { nick.text.hasSuffix("한") }
        let typed = nick.text == "다람Z한"
        key(0x0D)   // Enter commits and neither closes the popover nor goes back
        let stored = await waitFor(1) { team.nickname == "다람Z한" }
        await pause(0.2)
        let stillThere = popover?.isOpen == true && popover?.pageForTesting is WinSettingsPage
        // Tab leaves the field and writes nothing into it.
        key(0x09)
        await pause(0.2)
        let moved = GetFocus() != nick.hwnd && nick.text == "다람Z한"
        // Esc: back (to the Home page), the open edit's draft committed.
        await focus(nick)
        WinKit.send(nick.hwnd, 0x00B1, 99, 99)
        WindowsSelftestPopover.typeUnicode(0x71)   // q
        _ = await waitFor(1) { nick.text.hasSuffix("q") }
        key(0x1B)
        let back = await waitFor(2) { self.popover?.pageForTesting is WinHomePage }  // stage 7 Task 5: Back returns to Home
        let committed = team.nickname == "다람Z한q"
        let open = popover?.isOpen == true && popover?.state.showSettings == false
        // The Back link does the same.
        popover?.state.showSettings = true
        popover?.replacePage()
        _ = await waitFor(1) { self.popover?.pageForTesting is WinSettingsPage }
        clickLink(self.page?.backLinkForTesting)
        let linkBack = await waitFor(2) { self.popover?.pageForTesting is WinHomePage }  // stage 7 Task 5: Back returns to Home
        r.add("settings.escape", typed && stored && stillThere && moved && back && committed && open && linkBack,
              "typed Z and 한 reach the field once=\(typed); Enter commits (stored=\(stored)) and the popover stays on Settings=\(stillThere); Tab moves on and writes nothing=\(moved); "
                + "Esc after typing q -> back to the previous page=\(back) with the draft stored=\(committed), popover still open=\(open); Back link -> back=\(linkBack)")
        close()
    }

    // MARK: settings.teamTransport (the app's real team runtime)

    func transportCheck() async {
        guard let runtime = app.teamRuntime, let transport = app.teamTransport else { r.add("settings.teamTransport", false, "no team runtime"); return }
        let team = app.teamSettings!
        let before = (team.isEnabled, team.code, team.nickname)
        let startedOff = transport.listenerPort == nil && !team.isReady
        let code = fixtureCode()
        plazaOpens = 0
        guard await open(team: team, session: runtime.session, feed: runtime.feed), let page, let section = page.teamForTesting else {
            r.add("settings.teamTransport", false, "no page")
            return
        }
        var trace: [String] = []
        // Turn the team on, set a nickname, paste a bad code, then the fixture code.
        click(rows().enable.control)
        let enabled = await waitFor(2) { team.isEnabled && self.shown(rows().join) }
        await focus(rows().nickname.control)
        if let nick = rows().nickname.control { chars("자가", to: nick.hwnd) }
        await pause(0.2)
        key(0x0D)
        let named = await waitFor(2) { team.nickname == "자가" }
        let stillOff = transport.listenerPort == nil
        await paste("PTB-bad")
        click(rows().joinButton.control)
        let badText = await waitFor(1) { self.shown(rows().joinError) } && rows().joinError.hint?.text == L(.ko).teamCodeInvalid
        let badNoStart = team.code == nil && transport.listenerPort == nil
        await paste(code.display)
        click(rows().joinButton.control)
        let joined = await waitFor(3) { team.code == code && team.isReady }
        let started = await waitFor(10) { transport.hasSocketLoop && transport.listenerPort != nil }
        let plazaItem = app.tray?.menuItems().contains { $0?.action == .openPlaza && ($0?.title.hasPrefix(L(.ko).plazaOpen) ?? false) } ?? false
        let opened = await waitFor(2) { self.plazaOpens == 1 }
        trace.append("on=\(enabled) nickname=\(named) still off without a code=\(stillOff); bad code: error '\(rows().joinError.hint?.text ?? "")'=\(badText), no team/transport=\(badNoStart); "
            + "fixture code: ready=\(joined), transport started=\(started) (listener \(transport.listenerPort.map { "port \($0)" } ?? "none")), tray menu has \(L(.ko).plazaOpen)…=\(plazaItem), plaza button pressed once=\(opened)")
        // Leave: the team stops, the plaza item goes.
        click(rows().leave.control)
        await settle()
        let left = await waitFor(3) { team.code == nil && !team.isEnabled }
        let stopped = await waitFor(10) { transport.listenerPort == nil }
        let itemGone = !(app.tray?.menuItems().contains { $0?.action == .openPlaza } ?? true)
        trace.append("Leave: left=\(left), listener closed=\(stopped) (the idle socket loop thread stays, as after any stop: \(transport.hasSocketLoop)), plaza item gone=\(itemGone)")
        clearClipboard()
        // Back to what it was.
        team.isEnabled = before.0
        team.nickname = before.2
        r.add("settings.teamTransport", startedOff && enabled && named && stillOff && badText && badNoStart && joined && started && plazaItem && opened && left && stopped && itemGone,
              "app's own team runtime behind the page: started off=\(startedOff); " + trace.joined(separator: "; "))
        close()
    }

    // MARK: settings.secret

    func secretCheck() {
        AppLog.flush()
        let log = (try? String(contentsOf: AppLog.logFileURL, encoding: .utf8)) ?? ""
        let leaked = secrets.filter { !$0.isEmpty && log.contains($0) }
        r.add("settings.secret", leaked.isEmpty && !secrets.isEmpty,
              "\(secrets.count) fixture team codes of this group (display and normalized) looked for in the \(log.utf8.count)-byte log: found \(leaked.count) (no check printed a code; no window text outside the join field held one)")
    }

    // MARK: settings.openClose

    func openCloseCheck(start: PopoverResources) async {
        for _ in 0..<2 { _ = await open(); close() }   // warm-up: comctl32 and theme caches
        let warm = PopoverResources.now()
        for _ in 0..<3 { _ = await open(team: newTeam("cycle", code: fixtureCode(), nickname: "다람")); close() }
        await pause(0.3)
        let end = PopoverResources.now()
        let ok = end.gdi <= warm.gdi && end.user <= warm.user && end.controls == start.controls && end.dialogs == start.dialogs && end.pumpDepth == 0
            && !(app.popover?.isOpen ?? false)
        r.add("settings.openClose", ok, "after 2 warm-up cycles, 3 more open/close cycles of Settings with a team: \(warm.description) -> \(end.description) (controls/dialogs at the start: \(start.controls)/\(start.dialogs))")
    }

    func cleanUp() {
        close()
        for name in ["default", "join", "errors", "hangul", "plaza", "copy", "escape", "cycle", "u1", "u2", "u3"] { UserDefaults.standard.removePersistentDomain(forName: "\(suite).\(name)") }
        WinRegistry.deleteTree(#"Software\PokeTokenBarSelftest"#)
    }

    // MARK: captures (--dump-ui): FIXTURE data, the real page in the runner's popover window

    func captureChecks(_ dir: URL) async {
        var wrote: [String] = []
        var failed: [String] = []
        let previousScale = WinRegistry.bytes("Software\\Microsoft\\Accessibility", "TextScaleFactor")
        defer {
            switch previousScale {
            case .value(let bytes): _ = WinRegistry.setBytes("Software\\Microsoft\\Accessibility", "TextScaleFactor", bytes)
            default: _ = WinRegistry.deleteValue("Software\\Microsoft\\Accessibility", "TextScaleFactor")
            }
        }
        let original = app.companion.language
        for (scale, tag) in [(100, "100"), (150, "150")] {
            if scale == 100 { _ = WinRegistry.deleteValue("Software\\Microsoft\\Accessibility", "TextScaleFactor") }
            else { _ = WinRegistry.setBytes("Software\\Microsoft\\Accessibility", "TextScaleFactor", [UInt8(scale), 0, 0, 0]) }
            for language in [AppLanguage.en, .ko] {
                app.companion.setLanguage(language)
                app.store.localizationLanguage = language
                let code = fixtureCode()
                let joined = newTeam("cap-joined", code: code, nickname: "다람")
                let empty = newTeam("cap-empty", nickname: "")
                // Top and the sections of the page, team without a code, team joined.
                if await open(team: empty, updater: updater(latest: "v2.5.700", name: "cap")) {
                    if let page { await shoot(page, section: 0, name: "settings-\(language.rawValue)-\(tag)-top.png", dir: dir, wrote: &wrote, failed: &failed) }
                    if language == .en || tag == "100", let page {
                        await shoot(page, section: 3, name: "settings-\(language.rawValue)-\(tag)-team-nocode.png", dir: dir, wrote: &wrote, failed: &failed)
                        await shoot(page, section: 4, name: "settings-\(language.rawValue)-\(tag)-notifications.png", dir: dir, wrote: &wrote, failed: &failed)
                        click(page.rowsForTesting.checkNow?.control)
                        _ = await waitFor(3) { self.shown(page.rowsForTesting.updateOffer) }
                        await shoot(page, section: 5, name: "settings-\(language.rawValue)-\(tag)-updates-offer.png", dir: dir, wrote: &wrote, failed: &failed)
                    }
                } else { failed.append("open \(language.rawValue) \(tag)") }
                if language == .en, tag == "100", await open(team: joined, updater: updater(latest: "v2.5.613", name: "cap2")) {
                    if let page {
                        await shoot(page, section: 3, name: "settings-en-100-team-joined.png", dir: dir, wrote: &wrote, failed: &failed)
                        click(page.rowsForTesting.checkNow?.control)
                        _ = await waitFor(3) { self.shown(page.rowsForTesting.updateCurrent) }
                        await shoot(page, section: 5, name: "settings-en-100-updates-current.png", dir: dir, wrote: &wrote, failed: &failed)
                    }
                }
                close()
            }
        }
        app.companion.setLanguage(original)
        app.store.localizationLanguage = original
        for name in ["cap-joined", "cap-empty", "cap", "cap2"] { UserDefaults.standard.removePersistentDomain(forName: "\(suite).\(name)") }
        r.add("settings.capture", failed.isEmpty && wrote.count >= 10,
              "sample capture, Windows CI runner, FIXTURE team (no real code is ever on screen: the joined team shows only its masked code): \(wrote.count) PNGs in \(dir.path): \(wrote.joined(separator: ", ")); failures: \(failed)")
    }

    /// The popover scrolled to the top of section `section`, printed.
    func shoot(_ page: WinSettingsPage, section: Int, name: String, dir: URL, wrote: inout [String], failed: inout [String]) async {
        guard let hwnd, let area = page.areaForTesting, let frames = page.stackForTesting?.frames else { failed.append(name); return }
        var y: CGFloat = 0
        if section < frames.sections.count, let s = frames.sections[section] { y = (s.caption?.minY ?? s.card?.minY ?? 0) - 8 }
        area.scroll(to: Int32(max(0, y)))
        await pause(0.35)
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
#endif
