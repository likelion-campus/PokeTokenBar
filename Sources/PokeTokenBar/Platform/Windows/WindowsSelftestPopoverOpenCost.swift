#if os(Windows)
import Foundation
import WinSDK

// Field report 2026-11-17: on a real PC (imported save with a hatched companion, a team code, no usage, no session key,
// Korean) pressing the gear on Home did not show Settings at once: the window stuttered for about five seconds first.
// `settings.openCost` opens the popover on Home in that state, presses the gear as a click does and measures the swap the user
// saw: the page's builds, layout and refresh passes, windows made, paints and erases (the page's own counters, the ones the log
// line carries, and as ground truth thread hooks that see every paint message of the popover's windows, split into those sent
// while a page was being built and the rest), the 60 Hz frames a paint landed in, the slowest steps, and the time from the
// click to the page standing still. `popover.swapCost` measures Back to Home and Home -> Recap, the same swap; Settings opened
// straight from the tray (built hidden, the path every earlier check took) is printed beside them for comparison. CI only
// (the popover takes the foreground). Fixture data only; the fixture team code is never printed and is looked for in the log.

extension WindowsSelftest {
    @MainActor static func popoverOpenCostChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestOpenCost.run(r, app)
    }
}

/// Paint messages of one window tree, seen by thread hooks on the main thread: sent ones (a control's own redraw on
/// `WM_SETFONT`, `SetWindowPos`'s erase of the parent, `UpdateWindow`, `RDW_UPDATENOW`) and the `WM_PAINT`s the loop removes.
/// Drawn views are left out (their sprite clock repaints them while Home is open: not the page changing).
@MainActor enum WinPaintSpy {
    struct Counts: Equatable {
        var sent = 0, sentInBuild = 0, queued = 0
        /// Distinct 60 Hz frames with at least one paint message: how many different pictures the compositor could have shown.
        var frames = 0
        var firstMs = 0.0, lastMs = 0.0
    }

    private(set) static var counts = Counts()
    /// Per 60 Hz frame: what was painted, as `message@class widthxheight` and how often (the open-cost line prints it).
    private(set) static var frameDetail: [[String: Int]] = []
    private static var root: HWND?
    private static var lastFrame = -1
    private static var hooks: [HHOOK] = []

    static func start(_ root: HWND) {
        stop()
        self.root = root
        counts = Counts()
        frameDetail = []
        lastFrame = -1
        let thread = GetCurrentThreadId()
        if let h = SetWindowsHookExW(4 /* WH_CALLWNDPROC */, { code, wParam, lParam in winPaintSpySent(code, wParam, lParam) }, nil, thread) { hooks.append(h) }
        if let h = SetWindowsHookExW(3 /* WH_GETMESSAGE */, { code, wParam, lParam in winPaintSpyQueued(code, wParam, lParam) }, nil, thread) { hooks.append(h) }
    }

    static var installed: Bool { hooks.count == 2 }

    static func stop() {
        for h in hooks { _ = UnhookWindowsHookEx(h) }
        hooks = []
        root = nil
    }

    fileprivate static func seen(_ message: UINT, _ bits: Int, queued: Bool) {
        guard message == 0x000F || message == 0x0014 || message == 0x0085,  // WM_PAINT, WM_ERASEBKGND, WM_NCPAINT
              let root, let h = HWND(bitPattern: bits), h == root || IsChild(root, h), WinKit.className(h) != WinDrawnView.className else { return }
        let t = WinOpenTrace.now()
        if queued { counts.queued += 1 } else {
            counts.sent += 1
            // To a window on screen while a page is built: a half-built page the user sees (a hidden or frozen window draws nothing).
            if WinOpenTrace.buildDepth > 0, IsWindowVisible(h) { counts.sentInBuild += 1 }
        }
        let frame = Int(t / (1000.0 / 60))
        if frame != lastFrame {
            counts.frames += 1
            lastFrame = frame
        }
        if !queued, counts.frames > 0 {
            var r = RECT()
            _ = GetWindowRect(h, &r)
            let name = message == 0x000F ? "PAINT" : (message == 0x0014 ? "ERASE" : "NCPAINT")
            if frameDetail.count < counts.frames { frameDetail.append([:]) }
            frameDetail[counts.frames - 1]["\(name)@\(WinKit.className(h)) \(r.right - r.left)x\(r.bottom - r.top)", default: 0] += 1
        }
        if counts.firstMs == 0 { counts.firstMs = t }
        counts.lastMs = t
    }
}

private func winPaintSpySent(_ code: Int32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if code >= 0, let p = UnsafePointer<CWPSTRUCT>(bitPattern: Int(lParam)) {
        let message = p.pointee.message, bits = Int(bitPattern: p.pointee.hwnd)
        MainActor.assumeIsolated { WinPaintSpy.seen(message, bits, queued: false) }
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}

private func winPaintSpyQueued(_ code: Int32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if code >= 0, wParam == 1 /* PM_REMOVE */, let p = UnsafePointer<MSG>(bitPattern: Int(lParam)) {
        let message = p.pointee.message, bits = Int(bitPattern: p.pointee.hwnd)
        MainActor.assumeIsolated { WinPaintSpy.seen(message, bits, queued: true) }
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}

@MainActor enum WindowsSelftestOpenCost {
    static let names = ["settings.openCost", "popover.swapCost", "popover.caret"]

    /// What one page change cost.
    struct Swap {
        var name: String
        var arrived = false
        var report: WinOpenTrace.Report?
        /// The hooks watched this change (a page change in an open window; an open from the tray is built before there is one).
        var hooked = false
        var spy = WinPaintSpy.Counts()
        /// K2: the antialiased painter's binds and the milliseconds they took during this change.
        var painter = ""
        var frameNotes = ""
        var clickToSettledMs = 0.0
        var descendants = 0
        var stillOpen = false, foreground = false, visible = false
        var dwmMatches = false

        var summary: String {
            guard let t = report else { return "\(name): no trace (arrived=\(arrived))" }
            func ms(_ v: Double) -> String { String(Int(v.rounded())) }
            let slow = t.slow.map { "\($0.name) \(ms($0.ms))" }.joined(separator: ", ")
            let top = t.steps.sorted { $0.ms > $1.ms }.prefix(4).map { "\($0.name) \(ms($0.ms))" }.joined(separator: ", ")
            let hooks = hooked ? "sent \(spy.sent) (on screen in a build \(spy.sentInBuild)), queued \(spy.queued), frames with a paint \(spy.frames) over \(ms(spy.lastMs - spy.firstMs)) ms, \(painter); paints by frame [\(frameNotes)]"
                : "not watched (built before the window was shown)"
            return "\(name) [\(t.page) via \(t.via)]: click->settled \(ms(clickToSettledMs)) ms, build \(ms(t.buildMs)) ms in \(t.builds) build(s); "
                + "layouts \(t.layouts) (on screen \(t.layoutsOnScreen)), refreshes \(t.refreshes), windows made \(t.windows) / in the window now \(descendants); "
                + "trace paints \(t.paints) (on screen in a build \(t.paintsInBuild)), erases \(t.erases) (on screen in a build \(t.erasesInBuild)); hooks: \(hooks); "
                + "top steps \(top.isEmpty ? "-" : top); slow \(slow.isEmpty ? "none" : slow); open=\(stillOpen) foreground=\(foreground) visible=\(visible) dwm bounds=\(dwmMatches)"
        }

        /// The budgets: one build, nothing painted while it is built, the change drawn in a few frames, the window still the
        /// user's, a click that stands within the bound. Counts more than time: the runner draws with WARP, a PC with a real GPU
        /// over a remote link pays more for each paint, not fewer of them.
        func violations(maxFrames: Int, maxLayoutsOnScreen: Int, maxMs: Double, maxStepMs: Double) -> [String] {
            guard arrived, let t = report else { return ["the page did not arrive"] }
            var bad: [String] = []
            if !hooked { bad.append("the paint hooks could not be installed") }
            if t.builds != 1 { bad.append("\(t.builds) builds (budget 1)") }
            if spy.sentInBuild > 0 || t.paintsInBuild > 0 || t.erasesInBuild > 0 {
                bad.append("painted on screen while built: \(spy.sentInBuild) paint messages, \(t.paintsInBuild) paints, \(t.erasesInBuild) erases (budget 0)")
            }
            if spy.frames > maxFrames { bad.append("\(spy.frames) frames with a paint (budget \(maxFrames))") }
            if t.layoutsOnScreen > maxLayoutsOnScreen { bad.append("\(t.layoutsOnScreen) layout passes on screen (budget \(maxLayoutsOnScreen))") }
            if t.windows > descendants + 4 { bad.append("\(t.windows) windows made for \(descendants) in the window") }
            if clickToSettledMs > maxMs { bad.append("click->settled \(Int(clickToSettledMs)) ms (budget \(Int(maxMs)))") }
            if let worst = t.steps.max(by: { $0.ms < $1.ms }), worst.ms > maxStepMs { bad.append("step \(worst.name) \(Int(worst.ms)) ms (budget \(Int(maxStepMs)))") }
            if !(stillOpen && foreground && visible) { bad.append("popover open=\(stillOpen) foreground=\(foreground) visible=\(visible)") }
            if !dwmMatches { bad.append("the compositor's frame differs from the window's") }
            return bad
        }
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            for name in names { r.add(name, true, "skipped: CI not set (the popover takes the foreground)") }
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            for name in names { r.add(name, false, "no probe window: \(GetLastError())") }
            return
        }
        defer { probe.destroy() }
        let suite = "ptb.selftest.opencost.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let stores = await HomeStores.make(language: .ko)   // no providers: no usage; no session key
        let (companion, companionDir) = WindowsSelftestPopoverCompanion.fixtureCompanion(language: .ko, eggUsage: 1)
        await companion.hatch(baseID: 1)
        for i in 0..<3 { _ = try? companion.createManualSnapshot(now: Date().addingTimeInterval(-Double(i + 1) * 86_400)) }
        let team = TeamSettings(defaults: defaults)
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        team.isEnabled = true
        team.code = code
        team.nickname = "다람"
        let loginItem = WindowsLoginItem(runKey: #"Software\PokeTokenBarSelftest\OpenCost\Run"#, approvedKey: #"Software\PokeTokenBarSelftest\OpenCost\Approved"#,
                                         valueName: "PokeTokenBarOpenCost", command: WindowsLoginItem.command(forExecutable: #"C:\Fixture\PokeTokenBar.exe"#))
        let updater = UpdateChecker(currentVersion: "2.5.613", defaults: defaults, fetchLatest: { nil }, brewLocator: { nil })
        let host = WinPopoverHost(store: stores.store, companion: companion, updater: updater, team: team, session: nil, feed: nil, tray: nil,
                                  loginItem: loginItem, openPlaza: {})
        host.owner = app.sink.hwnd
        let popover = WinPopover(host: host)
        popover.makePage = WinSettingsPage.routed
        defer {
            popover.close(.destroyed)
            WinPaintSpy.stop()
            stores.remove()
            try? FileManager.default.removeItem(at: companionDir)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            WinRegistry.deleteTree(#"Software\PokeTokenBarSelftest\OpenCost"#)
        }
        let l = L(.ko)
        let snapshots = companion.availableSnapshots.count

        // Home, from the tray (built hidden, then shown).
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        let openStart = WinOpenTrace.now()
        popover.present(.secondLaunch) { _ in }
        let homeUp = await WindowsSelftest.waitUntil(timeout: 3) { popover.pageForTesting is WinHomePage && popover.hwndForTesting.map { GetForegroundWindow() == $0 } == true }
        await wait(1.5)
        var homeOpen = Swap(name: "Home opened from the tray")
        homeOpen.arrived = homeUp
        homeOpen.report = WinOpenTrace.running
        if let t = homeOpen.report { homeOpen.clickToSettledMs = t.startedAt + t.settledMs - openStart }
        fill(&homeOpen, popover)

        // The gear (a click message, as a mouse or Enter gives it).
        guard let hwnd = popover.hwndForTesting, let gear = findButton(hwnd, text: l.settings) else {
            r.add("settings.openCost", false, "Home up=\(homeUp); no button named '\(l.settings)' on Home")
            r.add("popover.swapCost", false, "Home did not come up")
            return
        }
        let settings = await measure("Home -> Settings (the gear)", popover) {
            WinKit.send(gear, 0x00F5 /* BM_CLICK */)
        } until: { popover.pageForTesting is WinSettingsPage }
        let back = await measure("Settings -> Home (Back)", popover) {
            _ = popover.pageForTesting?.escape()
        } until: { popover.pageForTesting is WinHomePage }
        // stage 7 Task 21: the Collection tab is built by the same swap (a tab switch goes through `replacePage`)
        let collection = await measure("Home -> Collection (tab)", popover) {
            popover.state.tab = .collection
            popover.replacePage()
        } until: { (popover.pageForTesting as? WinHomePage)?.builtTab == .collection }
        popover.state.tab = .home
        popover.replacePage()
        _ = await WindowsSelftest.waitUntil(timeout: 3) { (popover.pageForTesting as? WinHomePage)?.builtTab == .home }
        await wait(0.5)
        let recap = await measure("Home -> Recap", popover) {
            popover.state.showingRecap = true
            popover.replacePage()
        } until: { popover.pageForTesting is WinRecapPage }

        // For comparison: Settings opened straight from the tray menu (built while the window is hidden).
        popover.close(.destroyed)
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        let directStart = WinOpenTrace.now()
        popover.present(.secondLaunch) { $0.showSettings = true }
        let directUp = await WindowsSelftest.waitUntil(timeout: 3) { popover.pageForTesting is WinSettingsPage }
        await wait(1.5)
        var direct = Swap(name: "Settings opened from the tray menu")
        direct.arrived = directUp
        direct.report = WinOpenTrace.running
        if let t = direct.report { direct.clickToSettledMs = t.startedAt + t.settledMs - directStart }
        fill(&direct, popover)
        // The system caret: an EDIT that keeps the focus (or a caret that outlives its field) blinks every ~530 ms, one WM_SYSTIMER on the main
        // thread each. Settings is open here and has fields: put the keyboard in one, then leave the page (Back) and close the popover; the
        // thread must have no caret window and no focus on a window that is gone or hidden.
        var caretNotes: [String] = [], caretBad: [String] = []
        func gui() -> (caret: HWND?, focus: HWND?) {
            var info = GUITHREADINFO()
            info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
            _ = GetGUIThreadInfo(WindowsApp.mainThreadID, &info)
            return (info.hwndCaret, info.hwndFocus)
        }
        func visibleEdit(_ root: HWND) -> HWND? {
            var child = GetWindow(root, 5)
            while let c = child {
                if WinKit.className(c) == "Edit", IsWindowVisible(c), IsWindowEnabled(c) { return c }
                if let inner = visibleEdit(c) { return inner }
                child = GetWindow(c, 2)
            }
            return nil
        }
        if let root = popover.hwndForTesting, let edit = visibleEdit(root) {
            _ = SetFocus(edit)
            await wait(0.3)
            let during = gui()
            caretNotes.append("a field of Settings focused: focus on it=\(during.focus == edit) caret window present=\(during.caret != nil)")
            if during.focus != edit { caretBad.append("the field did not take the focus") }
            _ = popover.pageForTesting?.escape()   // Back to Home: the page with the field goes
            _ = await WindowsSelftest.waitUntil(timeout: 3) { popover.pageForTesting is WinHomePage }
            await wait(0.4)
            let afterPage = gui()
            caretNotes.append("after leaving the page: caret=\(afterPage.caret != nil) focus=\(afterPage.focus.map { IsWindow($0) } == true ? "a live window" : "none")")
            if afterPage.caret != nil { caretBad.append("a caret window after leaving the page") }
            if let f = afterPage.focus, WinKit.className(f) == "Edit" { caretBad.append("the focus is still in an edit after leaving the page") }
            // a field focused on the Home page's Settings again, then the popover closes
            popover.state.showSettings = true
            popover.replacePage()
            _ = await WindowsSelftest.waitUntil(timeout: 3) { popover.pageForTesting is WinSettingsPage }
            if let root2 = popover.hwndForTesting, let edit2 = visibleEdit(root2) {
                _ = SetFocus(edit2)
                await wait(0.3)
            }
            popover.close(.destroyed)
            await wait(0.5)
            let afterClose = gui()
            caretNotes.append("after closing the popover: caret=\(afterClose.caret != nil) focus=\(afterClose.focus != nil ? "set" : "none")")
            if afterClose.caret != nil { caretBad.append("a caret window after the popover closed") }
            if let f = afterClose.focus, WinKit.className(f) == "Edit" { caretBad.append("the focus is still in an edit after the popover closed") }
        } else { caretBad.append("no field on the Settings page to put the keyboard in") }
        r.add("popover.caret", caretBad.isEmpty, caretNotes.joined(separator: " | ") + (caretBad.isEmpty ? "" : " | PROBLEMS: " + caretBad.joined(separator: "; ")))
        popover.close(.destroyed)

        AppLog.flush()
        let log = (try? String(contentsOf: AppLog.logFileURL, encoding: .utf8)) ?? ""
        let leaked = [code.display, code.normalized].contains { log.contains($0) }
        let lines = log.components(separatedBy: "\n").filter { $0.contains("popover page Settings") }.count

        let state = "state: team joined with a nickname, companion hatched with \(snapshots) snapshots, no usage, no session key, Korean"
        let settingsBad = settings.violations(maxFrames: 4, maxLayoutsOnScreen: 1, maxMs: 3000, maxStepMs: 500)
            + (leaked ? ["the fixture team code is in the log"] : []) + (lines == 0 ? ["no 'popover page Settings' line in the log"] : [])
        r.add("settings.openCost", settingsBad.isEmpty,
              "\(state); \(settings.summary); for comparison \(homeOpen.summary); \(direct.summary); log lines for Settings \(lines), team code in the log=\(leaked)"
              + (settingsBad.isEmpty ? "" : "; OVER BUDGET: " + settingsBad.joined(separator: "; ")))
        let swapBad = back.violations(maxFrames: 4, maxLayoutsOnScreen: 1, maxMs: 3000, maxStepMs: 500).map { "Back: \($0)" }
            + recap.violations(maxFrames: 4, maxLayoutsOnScreen: 1, maxMs: 3000, maxStepMs: 500).map { "Recap: \($0)" }
            + collection.violations(maxFrames: 4, maxLayoutsOnScreen: 1, maxMs: 3000, maxStepMs: 500).map { "Collection: \($0)" }
        r.add("popover.swapCost", swapBad.isEmpty, "\(back.summary); \(recap.summary); \(collection.summary)" + (swapBad.isEmpty ? "" : "; OVER BUDGET: " + swapBad.joined(separator: "; ")))
    }

    /// One page change in the open popover: the hooks watch its window from just before `action` until it has stood still.
    private static func measure(_ name: String, _ popover: WinPopover, action: () -> Void, until: () -> Bool) async -> Swap {
        var s = Swap(name: name)
        guard let hwnd = popover.hwndForTesting else { return s }
        WinPaintSpy.start(hwnd)
        s.hooked = WinPaintSpy.installed
        let binds0 = WinPaint.binds, bindMs0 = WinPaint.bindMs
        let t0 = WinOpenTrace.now()
        action()
        s.arrived = await WindowsSelftest.waitUntil(timeout: 5) { until() }
        await wait(1.5)   // the page's queued passes, its paints
        s.spy = WinPaintSpy.counts
        s.frameNotes = WinPaintSpy.frameDetail.enumerated().map { "f\($0.offset): " + $0.element.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(", ") }.joined(" | ")
        s.painter = "painter \(WinPaint.binds - binds0) binds \(Int((WinPaint.bindMs - bindMs0).rounded())) ms"
        WinPaintSpy.stop()
        s.report = WinOpenTrace.running
        if let t = s.report { s.clickToSettledMs = t.startedAt + t.settledMs - t0 }
        fill(&s, popover)
        return s
    }

    private static func fill(_ s: inout Swap, _ popover: WinPopover) {
        guard let hwnd = popover.hwndForTesting else { return }
        s.stillOpen = popover.isOpen
        s.foreground = GetForegroundWindow() == hwnd
        s.visible = IsWindowVisible(hwnd)
        s.descendants = descendants(of: hwnd)
        s.dwmMatches = dwmFrameMatches(hwnd)
    }

    private static func descendants(of root: HWND) -> Int {
        var n = 0
        var child = GetWindow(root, 5 /* GW_CHILD */)
        while let c = child {
            n += 1 + descendants(of: c)
            child = GetWindow(c, 2 /* GW_HWNDNEXT */)
        }
        return n
    }

    /// The compositor's idea of the window (`DWMWA_EXTENDED_FRAME_BOUNDS`) has the window's size: a page change that resized
    /// the window while it did not draw left nothing stale behind.
    private static func dwmFrameMatches(_ hwnd: HWND) -> Bool {
        typealias Fn = @convention(c) (HWND?, DWORD, UnsafeMutableRawPointer?, DWORD) -> Int32
        guard let get = WinDynamic.symbol("dwmapi.dll", "DwmGetWindowAttribute", as: Fn.self) else { return true }
        var bounds = RECT(), window = RECT()
        guard get(hwnd, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, &bounds, DWORD(MemoryLayout<RECT>.size)) == 0, GetWindowRect(hwnd, &window) else { return true }
        return abs((bounds.bottom - bounds.top) - (window.bottom - window.top)) <= 2 && abs((bounds.right - bounds.left) - (window.right - window.left)) <= 2
    }

    private static func findButton(_ root: HWND, text: String) -> HWND? {
        var child = GetWindow(root, 5 /* GW_CHILD */)
        while let c = child {
            if WinKit.className(c) == "Button", WinKit.text(of: c) == text { return c }
            if let inner = findButton(c, text: text) { return inner }
            child = GetWindow(c, 2 /* GW_HWNDNEXT */)
        }
        return nil
    }

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }
}
#endif
