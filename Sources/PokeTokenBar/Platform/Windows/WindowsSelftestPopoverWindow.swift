#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 4: the popover window's selftest group (`popover.*`). The app's own popover, driven through the real
// channels: the tray callback message as the shell posts it (NIN_SELECT, NIN_KEYSELECT, WM_CONTEXTMENU, with the point
// in wParam), real activation changes (another window of ours, another process, the taskbar), real keys and mouse
// (`SendInput`), the real single-instance channel (a second process). Explorer grants the tray owner the foreground on a
// click; the runner stands in for that grant by making a probe window of this process the foreground first
// ("CI-granted"). The popover takes the foreground, so the group runs only on the runner (`CI`); on a person's PC each
// check prints a skipped PASS. Every check prints one line with what it measured; nothing is left open after the group.

extension WindowsSelftest {
    @MainActor static func popoverWindowChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverWindow.run(r, app)
    }

    @MainActor static func popoverWithPlazaChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverWindow.withPlaza(r, app)
    }
}

@MainActor enum WindowsSelftestPopoverWindow {
    /// Every check of the main group (the workflow requires each, passed and not skipped).
    static let names = ["popover.open", "popover.placement", "popover.toggle", "popover.dismissOnActivate", "popover.dismissInput",
                        "popover.escape", "popover.closePaths", "popover.ownedKeepsOpen", "popover.staleCompletion", "popover.dpiChange",
                        "popover.noSelfOpen", "popover.refusedForeground", "popover.menuAfter", "popover.menuSettings",
                        "popover.secondLaunch", "popover.realClick", "popover.openClose3"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            for name in names { r.add(name, true, "skipped: CI not set (the popover takes the foreground; the selftest opens it only on the runner)") }
            return
        }
        guard let popover = app.popover, let host = app.tray else {
            r.add("popover.open", false, "the app has no popover (tray host missing)")
            return
        }
        guard let probe = makeProbe() else {
            r.add("popover.open", false, "no probe window: \(GetLastError())")
            return
        }
        defer { probe.destroy() }
        let t = PopoverRun(r: r, app: app, popover: popover, host: host, probe: probe)
        let start = PopoverResources.now()
        await t.openCheck()
        await t.placementCheck(dump: dumpDirectory())
        await t.toggleCheck()
        await t.dismissChecks()
        await t.escapeCheck()
        await t.closePathsCheck()
        await t.ownedCheck()
        await t.staleCheck()
        await t.dpiCheck()
        await t.noSelfOpenCheck()
        await t.refusedCheck()
        await t.menuChecks()
        await t.secondLaunchCheck()
        await t.realClickCheck()
        if let dir = dumpDirectory() { await t.captureCheck(dir) }
        await t.openCloseCheck(start: start)
        popover.close(.destroyed)
    }

    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("popover", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A plain window of this process: the stand-in for Explorer's foreground grant, and "another window of ours".
    static func makeProbe() -> WinSinkWindow? {
        guard let w = try? WinSinkWindow(className: "PokeTokenBarSelftestProbe", title: "PokeTokenBar selftest probe",
                                         style: 0x10CF_0000 /* WS_OVERLAPPEDWINDOW | WS_VISIBLE */, exStyle: 0,
                                         x: 40, y: 40, width: 320, height: 200) else { return nil }
        return w
    }

    // MARK: - the popover over an open plaza (after the plaza group: it loads Direct3D)

    static func withPlaza(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("popover.withPlaza", true, "skipped: CI not set")
            return
        }
        guard let popover = app.popover, let host = app.tray, WinPlazaLive.isInstalled else {
            r.add("popover.withPlaza", false, "no popover, tray or Windows plaza in this app")
            return
        }
        popover.close(.destroyed)
        let defaults = WinDefaultsSync.makeAppDefaults()
        let key = "plaza.windowPlacement.popoverSelftest"
        defer { defaults.removeObject(forKey: key) }
        let shell = WinPlazaWindow(placementKey: key, defaults: defaults, allowActivation: true,
                                   systemEvents: Platform.current.events as? WindowsSystemEvents)
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: defaults),
                                      loader: PlazaCharacterLoader(fetcher: PlazaStubSpriteFetcher(log: { _ in })),
                                      nickname: { "selftest" }, memberID: { "selftest-me" },
                                      subject: { .init(speciesID: 25, isShiny: false) }, teamName: { "selftest" },
                                      shell: shell, chatInput: PlazaStubChatInput())
        c.show()
        guard let plaza = shell.hwndForTesting else {
            r.add("popover.withPlaza", false, "the plaza did not open: \(shell.openFailure ?? "?")")
            return
        }
        WindowsSelftest.forceForeground(plaza)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == plaza }
        let raw = UnsafeMutableRawPointer(plaza)
        let imeBefore = ptb_window_ime_has_context(raw)
        let t = PopoverRun(r: r, app: app, popover: popover, host: host, probe: nil)
        // A tray click while the plaza is in front: the popover opens over it (the plaza is this process: the grant).
        t.post(PopoverRun.ninSelect, t.iconPoint)
        let opened = await t.opened()
        let plazaStill = shell.hwndForTesting == plaza && IsWindowVisible(plaza)
        // Escape: the plaza has the foreground again (Windows activates the next window down).
        WindowsSelftestPopover.tap(0x1B)
        let closed = await t.closed(1)
        let back = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == plaza }
        // The plaza's keys afterwards: a real key reaches its window.
        let keys = PopoverCounter()
        shell.inputHandler = { message, _, _ in
            if message == 0x0100 /* WM_KEYDOWN */ { keys.n += 1 }
            return nil
        }
        WindowsSelftestPopover.tap(0x27)  // Right
        let keysReached = await WindowsSelftest.waitUntil(timeout: 1) { keys.n > 0 }
        shell.inputHandler = nil
        // The plaza coming forward closes the popover.
        t.post(PopoverRun.ninSelect, t.iconPoint)
        let reopened = await t.opened()
        c.show()  // bringToFront: SetForegroundWindow(plaza)
        let closedByPlaza = await t.closed(1)
        let reason = popover.stats.lastClose
        let imeAfter = ptb_window_ime_has_context(raw)
        shell.requestClose()
        let plazaGone = await WindowsSelftest.waitUntil(timeout: 3) { shell.hwndForTesting == nil }
        r.add("popover.withPlaza", opened && plazaStill && closed && back && keysReached && reopened && closedByPlaza && reason == .deactivated
                && imeBefore == 0 && imeAfter == 0 && plazaGone,
              "plaza open and in front; tray click -> popover open over it=\(opened), plaza still open=\(plazaStill); Escape -> closed=\(closed), "
              + "foreground back on the plaza=\(back); a real key then reached the plaza=\(keysReached) (key-downs \(keys.n)); popover again=\(reopened), "
              + "the plaza brought forward -> popover closed=\(closedByPlaza) (\(reason.map { "\($0)" } ?? "-")); the plaza's IME context before/after=\(imeBefore)/\(imeAfter) "
              + "(none: game keys stay keys); plaza closed=\(plazaGone)")
    }

    // MARK: - helper processes and the idle gate's probe

    /// `--selftest-popover-helper foreground <s>`: another app's window takes the foreground, holds it `s` seconds.
    /// `--selftest-popover-helper launch-second <s>`: the same, then starts this exe as a second instance from the
    /// foreground process (what the Start menu does), and holds the window `s` more seconds. Ready is signalled after the
    /// foreground (foreground) or after the second instance exited (launch-second). Exit 0, else 40 (no foreground), 20 + n.
    @MainActor static func runHelper(_ args: [String]) -> Never {
        _ = WinMainLoop.prepare()
        let mode = args.first ?? "foreground"
        let seconds = args.count > 1 ? Double(args[1]) ?? 3 : 3
        guard let w = try? WinSinkWindow(className: "PokeTokenBarSelftestOtherApp", title: "PokeTokenBar selftest other app",
                                         style: 0x10CF_0000 /* WS_OVERLAPPEDWINDOW | WS_VISIBLE */, exStyle: 0,
                                         x: 420, y: 60, width: 300, height: 180) else { WindowsApp.exit(30, .helper) }
        WindowsSelftest.forceForeground(w.hwnd)
        pump(0.2)
        var code: Int32 = GetForegroundWindow() == w.hwnd ? 0 : 40
        if mode == "launch-second" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: WindowsSelftest.executablePath())
            p.arguments = ["--selftest-second"]
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 3 { code = 20 + p.terminationStatus }
            } catch {
                code = 29
            }
        }
        WindowsSelftest.signalReady()
        pump(seconds)
        w.destroy()
        WindowsApp.exit(code, .helper)
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
    }

    /// `--popover-idle-probe open|closed`: the idle gate's popover (CI only): opened through the tray callback as a key
    /// select would, then left open and still, or closed again (what a closed popover leaves behind).
    static func startIdleProbe(_ app: WindowsAppDelegate, mode: String) {
        guard WindowsSelftest.onCI else {
            AppLog.write("popover idle probe: CI not set; nothing opened")
            return
        }
        Task { @MainActor in
            _ = await WindowsSelftest.waitUntil(timeout: 5) { false }
            guard let popover = app.popover, let probe = makeProbe() else {
                AppLog.write("popover idle probe: no popover or probe window")
                return
            }
            WindowsSelftest.forceForeground(probe.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
            _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
            let opened = await WindowsSelftest.waitUntil(timeout: 3) { popover.isOpen }
            if mode == "closed" {
                popover.close(.escape)
                _ = await WindowsSelftest.waitUntil(timeout: 1) { false }
            }
            probe.destroy()
            AppLog.write("popover idle probe: mode=\(mode) opened=\(opened) open now=\(popover.isOpen) opens=\(popover.stats.opens) "
                + "closes=\(popover.stats.closes) \(PopoverResources.now())")
        }
    }
}

/// What a closed popover must give back: GDI and USER objects, handles, windows of ours, kit controls, dialog registrations,
/// the modal pump and its timer.
struct PopoverResources: CustomStringConvertible {
    var gdi: Int, user: Int, handles: Int, windows: Int, controls: Int, dialogs: Int, pumpDepth: Int, pumpTimer: Bool

    @MainActor static func now() -> PopoverResources {
        let process = GetCurrentProcess()
        return PopoverResources(gdi: Int(GetGuiResources(process, 0)), user: Int(GetGuiResources(process, 1)),
                                handles: Int(ptb_process_handle_count()), windows: WinSinkWindow.liveCount, controls: WinControl.liveCount,
                                dialogs: WinMessageHook.dialogWindowCount, pumpDepth: WinModalPump.depth, pumpTimer: WinModalPump.timerLive)
    }

    var description: String {
        "gdi=\(gdi) user=\(user) handles=\(handles) windows=\(windows) controls=\(controls) dialogs=\(dialogs) pump=\(pumpDepth)\(pumpTimer ? "+timer" : "")"
    }
}

@MainActor final class PopoverCounter { var n = 0 }

/// A helper thread's notes (lock-protected: written off the main thread).
final class PopoverDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var done = false, sawMenu = false
    func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    func menuSeen() { lock.lock(); sawMenu = true; lock.unlock() }
    func finish() { lock.lock(); done = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var menuWasOpen: Bool { lock.lock(); defer { lock.unlock() }; return sawMenu }
    var text: String { lock.lock(); defer { lock.unlock() }; return log.joined(separator: ",") }
}

/// One run of the group: the app's popover and tray, the probe window, and the steps the checks share.
@MainActor final class PopoverRun {
    static let ninSelect: UInt32 = 0x400, ninKeySelect: UInt32 = 0x401, ninBalloonShow: UInt32 = 0x402, ninBalloonHide: UInt32 = 0x403
    static let ninBalloonClick: UInt32 = 0x405, contextMenu: UInt32 = 0x007B

    let r: WindowsSelftest.Recorder
    let app: WindowsAppDelegate
    let popover: WinPopover
    let host: WinTrayHost
    let probe: WinSinkWindow?
    var tray: WinTray { host.tray }
    var sink: HWND { app.sink.hwnd }
    /// Where the icon is: the centre of the shell's rectangle, else near the bottom-right corner of the primary screen.
    let iconPoint: POINT
    let anchor: RECT?

    init(r: WindowsSelftest.Recorder, app: WindowsAppDelegate, popover: WinPopover, host: WinTrayHost, probe: WinSinkWindow?) {
        self.r = r
        self.app = app
        self.popover = popover
        self.host = host
        self.probe = probe
        let a = host.tray.anchorRect()
        anchor = a
        iconPoint = a.map { POINT(x: ($0.left + $0.right) / 2, y: ($0.top + $0.bottom) / 2) }
            ?? POINT(x: GetSystemMetrics(SM_CXSCREEN) - 80, y: GetSystemMetrics(SM_CYSCREEN) - 24)
    }

    // MARK: steps

    /// The stand-in for Explorer's grant on a click: a window of this process in front.
    @discardableResult
    func grant() async -> Bool {
        guard let probe else { return GetForegroundWindow().map { WinSinkWindow.owns($0) } ?? false }
        WindowsSelftest.forceForeground(probe.hwnd)
        return await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
    }

    /// The tray callback as the shell posts it (v4: the event in the low word of lParam, the icon id above it, the point in
    /// wParam).
    func post(_ event: UInt32, _ p: POINT = POINT()) {
        _ = PostMessageW(sink, WinTray.callbackMessage, Self.wParam(p), LPARAM(Int(event) | (1 << 16)))
    }

    static func wParam(_ p: POINT) -> WPARAM {
        WPARAM(UInt32(UInt16(truncatingIfNeeded: p.x)) | (UInt32(UInt16(truncatingIfNeeded: p.y)) << 16))
    }

    func click() async -> Bool {
        await grant()
        post(Self.ninSelect, iconPoint)
        return await opened()
    }

    func key() async -> Bool {
        await grant()
        post(Self.ninKeySelect, iconPoint)
        return await opened()
    }

    /// Open, visible and in front.
    func opened(_ timeout: TimeInterval = 2) async -> Bool {
        await WindowsSelftest.waitUntil(timeout: timeout) {
            guard let h = self.popover.hwndForTesting else { return false }
            return IsWindowVisible(h) && GetForegroundWindow() == h
        }
    }

    func closed(_ timeout: TimeInterval = 1) async -> Bool {
        await WindowsSelftest.waitUntil(timeout: timeout) { !self.popover.isOpen }
    }

    func pause(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    /// The real cursor onto the icon, then the taskbar takes the activation: what a click on the icon does first.
    func deactivateOnIcon() async -> Bool {
        _ = SetCursorPos(iconPoint.x, iconPoint.y)
        guard let taskbar = FindWindowW(WinStr.w("Shell_TrayWnd"), nil) else { return false }
        _ = SetForegroundWindow(taskbar)
        return await closed(1)
    }

    var closeLatencyMs: Double { popover.stats.lastCloseMs - popover.stats.lastDeactivationMs }

    func foregroundName() -> String {
        guard let h = GetForegroundWindow() else { return "none" }
        if h == popover.hwndForTesting { return "the popover" }
        if let probe, h == probe.hwnd { return "the probe" }
        var pid: DWORD = 0
        _ = GetWindowThreadProcessId(h, &pid)
        return "\(WinKit.className(h)) (pid \(pid == GetCurrentProcessId() ? "self" : "\(pid)"))"
    }

    func workArea(of r: RECT) -> CGRect? {
        let cg = WinPopoverAnchor.cgRect(r)
        return WinPopoverAnchor.monitors().max { PopoverPlacement.overlapArea($0.bounds, cg) < PopoverPlacement.overlapArea($1.bounds, cg) }?.work
    }

    static func inside(_ r: RECT, _ work: CGRect) -> Bool {
        CGFloat(r.left) >= work.minX && CGFloat(r.right) <= work.maxX && CGFloat(r.top) >= work.minY && CGFloat(r.bottom) <= work.maxY
    }

    static func text(_ r: RECT) -> String { "(\(r.left),\(r.top),\(r.right),\(r.bottom))" }

    func windowRect() -> RECT {
        var wr = RECT()
        if let h = popover.hwndForTesting { _ = GetWindowRect(h, &wr) }
        return wr
    }

    func clientRect() -> RECT {
        var cr = RECT()
        if let h = popover.hwndForTesting { _ = GetClientRect(h, &cr) }
        return cr
    }

    func leftClick(_ p: POINT) async {
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: 0x8001 /* MOVE | ABSOLUTE */)
        await pause(0.05)
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: 0x8003 /* + LEFTDOWN */)
        await pause(0.05)
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: 0x8005 /* + LEFTUP */)
    }

    func keys(_ codes: [(UInt16, Bool)]) {
        var inputs: [INPUT] = codes.map { code, up in
            var i = INPUT()
            i.type = DWORD(INPUT_KEYBOARD)
            i.ki.wVk = code
            i.ki.dwFlags = up ? DWORD(KEYEVENTF_KEYUP) : 0
            return i
        }
        _ = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    // MARK: popover.open

    func openCheck() async {
        popover.close(.destroyed)
        let dialogs0 = WinMessageHook.dialogWindowCount, selects0 = tray.selectCount
        let ok = await click()
        guard let hwnd = popover.hwndForTesting else {
            r.add("popover.open", false, "NIN_SELECT at \(iconPoint.x),\(iconPoint.y): no window (opens=\(popover.stats.opens) refused=\(popover.stats.refusedForeground))")
            return
        }
        let wr = windowRect(), cr = clientRect()
        let style = UInt32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_STYLE)), ex = UInt32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_EXSTYLE))
        let owner = GetWindow(hwnd, UINT(GW_OWNER))
        let work = workArea(of: wr)
        let inside = work.map { Self.inside(wr, $0) } ?? false
        let dpi = WinUIContext.dpi(of: hwnd), scale = Double(dpi) / 96
        let wantW = Int32((360 * scale).rounded()), wantH = Int32((600 * scale).rounded())
        let focus = GetFocus()
        let focusInside = focus == hwnd || focus.map { IsChild(hwnd, $0) } == true
        let tool = ex & 0x80 != 0 && ex & 0x4_0000 == 0  // WS_EX_TOOLWINDOW, no WS_EX_APPWINDOW: no taskbar button, not in Alt+Tab
        let topmost = ex & 0x8 != 0
        let opener = popover.stats.lastOpener == .trayClick(iconPoint)
        let margin = Int32((12 * scale).rounded())
        let heightOK = cr.bottom == wantH || work.map { Int32($0.height) - 2 * margin == wr.bottom - wr.top } == true  // or clamped to a small work area
        r.add("popover.open", ok && IsWindowVisible(hwnd) && GetForegroundWindow() == hwnd && inside && tool && !topmost && owner == sink && focusInside
                && WinMessageHook.dialogWindowCount == dialogs0 + 1 && cr.right == wantW && heightOK && tray.selectCount == selects0 + 1 && opener
                && WinKit.className(hwnd) == WinPopover.className,
              "posted NIN_SELECT at \(iconPoint.x),\(iconPoint.y) (shell rect \(anchor.map(Self.text) ?? "nil"), CI-granted foreground): visible=\(IsWindowVisible(hwnd)) "
              + "foreground=\(GetForegroundWindow() == hwnd) window=\(Self.text(wr)) work=\(work.map { "\($0)" } ?? "?") inside=\(inside) edge=\(popover.stats.lastEdge.map { "\($0)" } ?? "-") "
              + "client=\(cr.right)x\(cr.bottom) (360x600 DIP at \(dpi) dpi = \(wantW)x\(wantH)) style=0x\(String(style, radix: 16)) ex=0x\(String(ex, radix: 16)) "
              + "tool window=\(tool) topmost=\(topmost) owner=sink:\(owner == sink) focus inside=\(focusInside) dialog registrations \(dialogs0) -> "
              + "\(WinMessageHook.dialogWindowCount) Windows 11=\(WinPopover.isWindows11) round corners=\(popover.stats.roundCorners) session notifications=\(popover.stats.sessionNotify)")
        popover.close(.destroyed)
    }

    // MARK: popover.placement (synthetic work areas on the real primary monitor)

    func placementCheck(dump: URL?) async {
        popover.close(.destroyed)
        guard let real = WinPopoverAnchor.monitors().first(where: { $0.isPrimary }) else {
            r.add("popover.placement", false, "no primary monitor")
            return
        }
        let m = real.bounds, s = CGFloat(real.dpi) / 96, bar = (48 * s).rounded(), margin = Int32((12 * s).rounded())
        var lines: [String] = [], ok = true
        let cases: [(String, PopoverPlacement.Edge)] = [("bottom", .bottom), ("top", .top), ("left", .left), ("right", .right), ("small", .bottom)]
        for (name, edge) in cases {
            let band: CGRect, icon: CGRect
            var work: CGRect
            switch edge {
            case .bottom: band = CGRect(x: m.minX, y: m.maxY - bar, width: m.width, height: bar); work = CGRect(x: m.minX, y: m.minY, width: m.width, height: m.height - bar)
            case .top: band = CGRect(x: m.minX, y: m.minY, width: m.width, height: bar); work = CGRect(x: m.minX, y: m.minY + bar, width: m.width, height: m.height - bar)
            case .left: band = CGRect(x: m.minX, y: m.minY, width: bar, height: m.height); work = CGRect(x: m.minX + bar, y: m.minY, width: m.width - bar, height: m.height)
            case .right: band = CGRect(x: m.maxX - bar, y: m.minY, width: bar, height: m.height); work = CGRect(x: m.minX, y: m.minY, width: m.width - bar, height: m.height)
            }
            if name == "small" {  // a work area 400 DIP tall: the popover is clamped and its page scrolls (R12)
                let h = (400 * s).rounded()
                work = CGRect(x: work.minX, y: work.maxY - h, width: work.width, height: h)
            }
            let size = 32 * s
            switch edge {
            case .bottom, .top: icon = CGRect(x: m.midX + 100 * s, y: band.midY - size / 2, width: size, height: size)
            case .left, .right: icon = CGRect(x: band.midX - size / 2, y: band.maxY - 120 * s, width: size, height: size)
            }
            let iconRect = WinKit.rect(icon), bandRect = WinKit.rect(band)
            let monitor = PopoverPlacement.Monitor(bounds: m, work: work, dpi: real.dpi, isPrimary: true)
            WinPopoverAnchor.environmentForTesting = { i in
                WinPopoverAnchor.Inputs(anchor: iconRect, clickPoint: i.clickPoint, monitors: [monitor], appBar: bandRect)
            }
            let opened = await click()
            let wr = windowRect()
            WinPopoverAnchor.environmentForTesting = nil
            let w = WinKit.rect(work)
            let insideWork = wr.left >= w.left + margin && wr.right <= w.right - margin && wr.top >= w.top + margin && wr.bottom <= w.bottom - margin
            let centre = (wr.left + wr.right) / 2, iconMid = iconRect.left + (iconRect.right - iconRect.left) / 2
            let docked: Bool
            switch edge {
            case .bottom: docked = wr.bottom == w.bottom - margin && abs(centre - iconMid) <= 1
            case .top: docked = wr.top == w.top + margin && abs(centre - iconMid) <= 1
            case .left: docked = wr.left == w.left + margin && wr.bottom == iconRect.bottom
            case .right: docked = wr.right == w.right - margin && wr.bottom == iconRect.bottom
            }
            let clamped = name != "small" || wr.bottom - wr.top == w.bottom - w.top - 2 * margin
            let edgeOK = popover.stats.lastEdge == edge
            let fine = opened && insideWork && docked && clamped && edgeOK
            ok = ok && fine
            lines.append("\(name): window=\(Self.text(wr)) work=\(Self.text(w)) taskbar=\(Self.text(bandRect)) icon=\(Self.text(iconRect)) "
                         + "edge=\(popover.stats.lastEdge.map { "\($0)" } ?? "-") inside=\(insideWork) docked=\(docked) clamped=\(clamped)\(fine ? "" : " FAIL")")
            if let dump, opened {
                await pause(0.4)  // DWM's frame and shadow
                if var shot = WinUIDump.screenshot(x: Int(m.minX), y: Int(m.minY), w: Int(m.width), h: Int(m.height)) {
                    Self.shade(&shot, bandRect, origin: POINT(x: Int32(m.minX), y: Int32(m.minY)))
                    _ = WinUIDump.write(shot, to: dump.appendingPathComponent("placement-\(name).png"))
                }
            }
            popover.close(.destroyed)
        }
        r.add("popover.placement", ok, "synthetic work areas on the primary monitor (\(Int(m.width))x\(Int(m.height)) at \(real.dpi) dpi, margin \(margin) px), "
              + "window rect read back: " + lines.joined(separator: "; "))
    }

    /// The synthetic taskbar band drawn dark blue over the capture (labelled illustration of where the taskbar would be).
    static func shade(_ b: inout WinUIDump.Bitmap, _ band: RECT, origin: POINT) {
        let y0 = max(0, Int(band.top - origin.y)), y1 = min(b.height, Int(band.bottom - origin.y))
        let x0 = max(0, Int(band.left - origin.x)), x1 = min(b.width, Int(band.right - origin.x))
        guard y0 < y1, x0 < x1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * b.width + x) * 4
                b.bgra[o] = UInt8((Int(b.bgra[o]) + 2 * 120) / 3)
                b.bgra[o + 1] = UInt8((Int(b.bgra[o + 1]) + 2 * 60) / 3)
                b.bgra[o + 2] = UInt8((Int(b.bgra[o + 2]) + 2 * 30) / 3)
                b.bgra[o + 3] = 255
            }
        }
    }

    // MARK: popover.toggle (D3)

    func toggleCheck() async {
        popover.close(.destroyed)
        // (a) The race: the click on the icon deactivates first (the taskbar), then the shell reports the click.
        let absorbed0 = popover.stats.suppressedSelects
        let aOpen = await click()
        let aClosed = await deactivateOnIcon()
        let aOnIcon = popover.stats.lastCursorInAnchor
        await grant()  // the click's grant: a reopen would succeed if the guard let it through
        post(Self.ninSelect, iconPoint)
        await pause(0.4)
        let a = aOpen && aClosed && aOnIcon && !popover.isOpen && popover.stats.suppressedSelects == absorbed0 + 1
        // (b) A second click 700 ms after such a close is a new click: it opens.
        let bOpen = await click()
        let bClosed = await deactivateOnIcon()
        await pause(0.75)
        let bReopened = await click()
        let b = bOpen && bClosed && bReopened
        // (c) A deactivation with the cursor elsewhere (another window of ours clicked), then a quick click: it opens.
        if let probe {
            var pr = RECT()
            _ = GetWindowRect(probe.hwnd, &pr)
            _ = SetCursorPos((pr.left + pr.right) / 2, (pr.top + pr.bottom) / 2)
        }
        let cWasOpen = popover.isOpen
        await grant()
        let cClosed = await closed(1)
        let cOnIcon = popover.stats.lastCursorInAnchor
        post(Self.ninSelect, iconPoint)
        let cReopened = await opened()
        let c = cWasOpen && cClosed && !cOnIcon && cReopened
        // (d) A select while it is open (no deactivation came first): closes.
        post(Self.ninSelect, iconPoint)
        let dClosed = await closed(1)
        let d = dClosed && popover.stats.lastClose == .iconClick
        // (e) The shell reporting one key twice: the second key select does not close it.
        let dup0 = popover.stats.duplicateKeySelects
        let eOpen = await key()
        post(Self.ninKeySelect, iconPoint)
        await pause(0.3)
        let e = eOpen && popover.isOpen && popover.stats.duplicateKeySelects == dup0 + 1
        popover.close(.destroyed)
        r.add("popover.toggle", a && b && c && d && e,
              "(a) open=\(aOpen), cursor on the icon + taskbar activated -> closed=\(aClosed) (cursor on icon=\(aOnIcon)), then NIN_SELECT within ~0.1 s -> "
              + "open=\(popover.stats.suppressedSelects > absorbed0 ? "no" : "?") absorbed +\(popover.stats.suppressedSelects - absorbed0); (b) same close, NIN_SELECT 0.75 s later -> "
              + "opened=\(bReopened); (c) another window of ours activated with the cursor there -> closed=\(cClosed) (cursor on icon=\(cOnIcon)), "
              + "NIN_SELECT at once -> opened=\(cReopened); (d) NIN_SELECT while open -> closed=\(dClosed) (\(popover.stats.lastClose.map { "\($0)" } ?? "-")); "
              + "(e) NIN_KEYSELECT twice -> still open=\(e) (duplicates +\(popover.stats.duplicateKeySelects - dup0))")
        _ = SetCursorPos(iconPoint.x - 200, iconPoint.y - 200)
    }

    // MARK: popover.dismissOnActivate, popover.dismissInput (D3)

    func dismissChecks() async {
        popover.close(.destroyed)
        // Another window of this process.
        let sameOpen = await click()
        if let probe { _ = SetForegroundWindow(probe.hwnd) }
        let sameClosed = await closed(1)
        let sameMs = closeLatencyMs
        // Another app's window (a helper process started while the popover is in front, so it may take the foreground).
        let otherOpen = await click()
        var otherClosed = false, otherMs = -1.0, helperFront = false, helperCode: DWORD?
        if let helper = try? WindowsSelftest.Helper.start(["--selftest-popover-helper", "foreground", "2"], ready: true) {
            let ready = await helper.waitReady(timeout: 10)
            otherClosed = await closed(2)
            otherMs = closeLatencyMs
            helperFront = ready && foregroundName().contains("PokeTokenBarSelftestOtherApp")
            helperCode = await helper.waitExit(timeout: 10)
            if helperCode == nil { helper.kill() }
            helper.close()
        }
        r.add("popover.dismissOnActivate", sameOpen && sameClosed && sameMs >= 0 && sameMs <= 200 && otherOpen && otherClosed && otherMs >= 0 && otherMs <= 200,
              "a window of this process activated -> closed=\(sameClosed) in \(String(format: "%.1f", sameMs)) ms after WM_ACTIVATE; another process's window took "
              + "the foreground -> closed=\(otherClosed) in \(String(format: "%.1f", otherMs)) ms (helper in front=\(helperFront), exit=\(WindowsSelftest.describe(helperCode))); "
              + "budget 200 ms each")
        await grant()

        // Real input: a click outside it, Alt+Tab, the Windows key.
        var outsideClosed = false, outsideReason = "-"
        if await click(), let probe {
            var pr = RECT()
            _ = GetWindowRect(probe.hwnd, &pr)
            await leftClick(POINT(x: (pr.left + pr.right) / 2, y: (pr.top + pr.bottom) / 2))
            outsideClosed = await closed(1)
            outsideReason = popover.stats.lastClose.map { "\($0)" } ?? "-"
        }
        let altOpen = await click()
        keys([(0x12, false), (0x09, false), (0x09, true), (0x12, true)])  // Alt+Tab
        let altClosed = await closed(1.5)
        await pause(0.3)
        let altFront = foregroundName()
        let winOpen = await click()
        keys([(0x5B, false), (0x5B, true)])  // the Windows key
        let winClosed = await closed(2)
        await pause(0.5)
        let winFront = foregroundName()
        WindowsSelftestPopover.tap(0x1B)  // closes Start
        await pause(0.5)
        popover.close(.destroyed)
        await grant()
        r.add("popover.dismissInput", outsideClosed && altOpen && altClosed,
              "real click on another window of ours -> closed=\(outsideClosed) (\(outsideReason)); Alt+Tab -> closed=\(altClosed) (then in front: \(altFront)); "
              + "informational: Windows key (open=\(winOpen)) -> closed=\(winClosed) (then in front: \(winFront))")
    }

    // MARK: popover.escape (D3, D5)

    func escapeCheck() async {
        popover.close(.destroyed)
        let mouseOpen = await click()
        WindowsSelftestPopover.tap(0x1B)
        let mouseClosed = await closed(1)
        let mouseReason = popover.stats.lastClose
        await pause(0.2)
        let afterMouse = foregroundName()
        let attempts0 = popover.stats.focusReturnAttempts, returned0 = popover.stats.focusReturnedToTray
        let keyOpen = await key()
        let cues = popover.hwndForTesting.map { WinKit.send($0, 0x0129 /* WM_QUERYUISTATE */) & 0x1 /* UISF_HIDEFOCUS */ == 0 } ?? false
        WindowsSelftestPopover.tap(0x1B)
        let keyClosed = await closed(1)
        let keyReason = popover.stats.lastClose
        await pause(0.3)
        let afterKey = foregroundName()
        r.add("popover.escape", mouseOpen && mouseClosed && mouseReason == .escape && keyOpen && cues && keyClosed && keyReason == .escape
                && popover.stats.focusReturnAttempts == attempts0 + 1,
              "opened by click, real Escape -> closed=\(mouseClosed) (\(mouseReason.map { "\($0)" } ?? "-")), then in front: \(afterMouse); opened by key select -> "
              + "focus cues shown=\(cues); Escape -> closed=\(keyClosed) (\(keyReason.map { "\($0)" } ?? "-")), NIM_SETFOCUS asked +\(popover.stats.focusReturnAttempts - attempts0) "
              + "answered \(popover.stats.focusReturnedToTray > returned0 ? "yes" : "no") (shell returned \(tray.lastSetFocusOK)), then in front: \(afterKey)")
        await grant()
    }

    // MARK: popover.closePaths: every way it closes gives everything back

    func closePathsCheck() async {
        popover.close(.destroyed)
        let base = PopoverResources.now()
        var lines: [String] = [], ok = true
        func record(_ name: String, opened: Bool, closed: Bool, reason: WinPopover.CloseReason?, old: HWND?) {
            let now = PopoverResources.now()
            let clean = now.dialogs == base.dialogs && now.windows == base.windows && now.controls == 0 && now.pumpDepth == 0
                && !(old.map { IsWindow($0) } ?? false) && !popover.isOpen
            let fine = opened && closed && clean
            ok = ok && fine
            lines.append("\(name): closed=\(closed) (\(reason.map { "\($0)" } ?? "-")) registrations clean=\(clean)\(fine ? "" : " FAIL \(now)")")
        }
        // Escape (the dialog path's IDCANCEL).
        var o = await click(); var h = popover.hwndForTesting
        WindowsSelftestPopover.tap(0x1B)
        record("Escape", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // Deactivation.
        o = await click(); h = popover.hwndForTesting
        await grant()
        record("deactivation", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // Alt+F4 (real keys: the default WM_CLOSE).
        o = await click(); h = popover.hwndForTesting
        keys([(0x12, false), (0x73, false), (0x73, true), (0x12, true)])
        record("Alt+F4", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // A click on the icon while open.
        o = await click(); h = popover.hwndForTesting
        post(Self.ninSelect, iconPoint)
        record("icon click", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // Session lock (WM_WTSSESSION_CHANGE, WTS_SESSION_LOCK).
        o = await click(); h = popover.hwndForTesting
        if let h { _ = SendMessageW(h, 0x02B1, 7, 0) }
        record("lock", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // The app's exit path (WindowsApp.exit closes it first).
        o = await click(); h = popover.hwndForTesting
        popover.close(.quit)
        record("quit", opened: o, closed: !popover.isOpen, reason: popover.stats.lastClose, old: h)
        // Destroyed from outside (DestroyWindow without the popover asking).
        o = await click(); h = popover.hwndForTesting
        if let h { _ = DestroyWindow(h) }
        record("DestroyWindow", opened: o, closed: await closed(1), reason: popover.stats.lastClose, old: h)
        // A second present while the deactivation's close is still pending: the old window goes first, one window stays.
        o = await click(); h = popover.hwndForTesting
        let stale0 = popover.stats.staleDropped
        if let probe { _ = SetForegroundWindow(probe.hwnd) }  // WM_ACTIVATE now: the close is posted, not run yet
        popover.present(.trayMenu) { _ in }
        let reopened = popover.isOpen && popover.hwndForTesting != h && !(h.map { IsWindow($0) } ?? false)
        let oneWindow = PopoverResources.now().dialogs == base.dialogs + 1
        await pause(0.3)  // the stale close for the old window arrives and is dropped
        let survived = popover.isOpen && popover.stats.staleDropped >= stale0 + 1
        let h2 = popover.hwndForTesting
        popover.close(.destroyed)
        record("present while closing (reopened=\(reopened) one registration=\(oneWindow) survived the stale close=\(survived))", opened: o && reopened && oneWindow && survived,
               closed: !popover.isOpen, reason: popover.stats.lastClose, old: h2)
        r.add("popover.closePaths", ok, "before: \(base); " + lines.joined(separator: "; "))
        await grant()
    }

    // MARK: popover.ownedKeepsOpen (D3, D17)

    func ownedCheck() async {
        popover.close(.destroyed)
        let o = await click()
        guard o, let hwnd = popover.hwndForTesting,
              let owned = try? WinSinkWindow(className: "PokeTokenBarSelftestOwned", title: "PokeTokenBar selftest dialog",
                                             style: 0x90C8_0000 /* WS_POPUP | WS_VISIBLE | WS_CAPTION | WS_SYSMENU */, exStyle: 0,
                                             x: 60, y: 300, width: 260, height: 140, parent: hwnd) else {
            r.add("popover.ownedKeepsOpen", false, "open=\(o): no owned window (\(GetLastError()))")
            popover.close(.destroyed)
            return
        }
        let owned0 = popover.stats.ownedActivations
        _ = SetForegroundWindow(owned.hwnd)
        await pause(0.3)
        let stayed = popover.isOpen && popover.hwndForTesting == hwnd
        let ownedFront = GetForegroundWindow() == owned.hwnd
        owned.destroy()
        await pause(0.3)
        let after = popover.isOpen && GetForegroundWindow() == hwnd
        r.add("popover.ownedKeepsOpen", stayed && ownedFront && after && popover.stats.ownedActivations == owned0 + 1,
              "a window owned by the popover (a later dialog's stand-in) activated: popover still open=\(stayed) (dialog in front=\(ownedFront), owned activations "
              + "+\(popover.stats.ownedActivations - owned0)); the dialog destroyed: popover open and in front again=\(after)")
        popover.close(.destroyed)
    }

    // MARK: popover.staleCompletion (the generation guard)

    func staleCheck() async {
        popover.close(.destroyed)
        let o1 = await click()
        let g1 = popover.generation
        popover.close(.destroyed)
        let o2 = await click()
        let g2 = popover.generation, h2 = popover.hwndForTesting
        let dropped0 = popover.stats.staleDropped
        let stale = PopoverCounter(), current = PopoverCounter(), late = PopoverCounter()
        popover.whenCurrent(g1) { stale.n += 1 }
        popover.whenCurrent(g2) { current.n += 1 }
        if let h2 { _ = PostMessageW(h2, WinPopover.closeMessage, WPARAM(UInt(bitPattern: g1)), 0) }  // a deferred close for the first window
        await pause(0.3)
        let survived = popover.isOpen && popover.hwndForTesting == h2
        // A completion that lands after the window closed (a decode that took 0.2 s).
        let g3 = popover.generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.popover.whenCurrent(g3) { late.n += 1 }
        }
        popover.close(.destroyed)
        await pause(0.5)
        r.add("popover.staleCompletion", o1 && o2 && stale.n == 0 && current.n == 1 && survived && late.n == 0 && popover.stats.staleDropped == dropped0 + 3,
              "generations \(g1) -> \(g2): a completion for the first window ran \(stale.n)x, for the open one \(current.n)x; a deferred close for the first window "
              + "left the second open=\(survived); a completion 0.2 s after the close ran \(late.n)x; dropped +\(popover.stats.staleDropped - dropped0) (expected 3)")
    }

    // MARK: popover.dpiChange (D2, R6)

    func dpiCheck() async {
        popover.close(.destroyed)
        let o = await click()
        guard o, let hwnd = popover.hwndForTesting else {
            r.add("popover.dpiChange", false, "open=\(o)")
            return
        }
        popover.state.showSettings = true  // a page the user went to: kept across the rebuild
        let rebuilds0 = popover.stats.rebuilds
        var suggested = windowRect()
        _ = withUnsafeMutablePointer(to: &suggested) { SendMessageW(hwnd, 0x02E0, WPARAM(144 | (144 << 16)), LPARAM(Int(bitPattern: $0))) }
        let dpi144 = popover.contextForTesting?.dpi ?? 0
        let wr = windowRect(), cr = clientRect()
        let inside = workArea(of: wr).map { Self.inside(wr, $0) } ?? false
        let kept = popover.state.showSettings
        var back = windowRect()
        let real = WinUIContext.dpi(of: hwnd)
        _ = withUnsafeMutablePointer(to: &back) { SendMessageW(hwnd, 0x02E0, WPARAM(UInt(real) | (UInt(real) << 16)), LPARAM(Int(bitPattern: $0))) }
        let rebuilds1 = popover.stats.rebuilds, unchanged0 = popover.stats.appearanceUnchanged
        _ = SendMessageW(hwnd, 0x001A /* WM_SETTINGCHANGE */, 0, 0)
        _ = SendMessageW(hwnd, 0x031A /* WM_THEMECHANGED */, 0, 0)
        let noRebuild = popover.stats.rebuilds == rebuilds1 && popover.stats.appearanceUnchanged == unchanged0 + 2
        r.add("popover.dpiChange", dpi144 == 144 && cr.right == 540 && inside && kept && rebuilds1 == rebuilds0 + 2 && noRebuild && popover.isOpen,
              "WM_DPICHANGED 144 on a \(real)-dpi monitor: context \(dpi144) dpi, client \(cr.right)x\(cr.bottom) (540 wide; height clamped to the work area), window "
              + "\(Self.text(wr)) inside the work area=\(inside), Settings kept=\(kept); back to \(real): rebuilds +\(rebuilds1 - rebuilds0); "
              + "WM_SETTINGCHANGE + WM_THEMECHANGED with nothing changed: rebuilt=\(!noRebuild) (unchanged +\(popover.stats.appearanceUnchanged - unchanged0))")
        popover.close(.destroyed)
    }

    // MARK: popover.noSelfOpen (D4)

    func noSelfOpenCheck() async {
        popover.close(.destroyed)
        await grant()
        let front0 = GetForegroundWindow(), opens0 = popover.stats.opens
        await app.store.refresh()
        var balloons = "no presenter"
        if let presenter = host.balloons {
            let hint = presenter.post(.init(id: "popover-noself-hint", title: "PokeTokenBar", body: "selftest", sound: false, kind: .hint))
            post(Self.ninBalloonShow)
            post(Self.ninBalloonClick)
            let team = presenter.post(.init(id: "popover-noself-team", title: "PokeTokenBar", body: "selftest team", sound: false, kind: .team))
            post(Self.ninBalloonShow)
            post(Self.ninBalloonClick)
            balloons = "hint accepted=\(hint), team accepted=\(team), each shown and clicked"
        }
        let created = RegisterWindowMessageW(WinStr.w("TaskbarCreated"))
        _ = SendMessageW(sink, created, 0, 0)  // Explorer restarted: the icon comes back
        _ = SendMessageW(sink, UINT(WM_TIMECHANGE), 0, 0)
        await pause(1.5)
        let front1 = GetForegroundWindow()
        let none = FindWindowW(WinStr.w(WinPopover.className), nil) == nil
        r.add("popover.noSelfOpen", popover.stats.opens == opens0 && !popover.isOpen && front1 == front0 && none,
              "a store refresh, two balloons (\(balloons); a team balloon's click opens the plaza only when the team is ready), TaskbarCreated, WM_TIMECHANGE: "
              + "popover opens +\(popover.stats.opens - opens0), a popover window exists=\(!none), foreground unchanged=\(front1 == front0)")
    }

    // MARK: popover.refusedForeground (D4, R2)

    func refusedCheck() async {
        popover.close(.destroyed)
        let refused0 = popover.stats.refusedForeground, shows0 = popover.stats.shows
        popover.setForegroundForTesting = { _ in false }
        defer { popover.setForegroundForTesting = nil }
        let driver = PopoverDriver()
        let owner = Int(bitPattern: sink)
        WindowsSelftest.onThread {
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 160 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { driver.note("no menu"); driver.finish(); return }
            driver.menuSeen()
            Thread.sleep(forTimeInterval: 0.4)
            for _ in 0..<5 where WinPopupMenu.openMenuBits != 0 {
                _ = PostMessageW(HWND(bitPattern: owner), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
                _ = PostMessageW(HWND(bitPattern: owner), UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
                for _ in 0..<10 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.1) }
            }
            driver.note(WinPopupMenu.openMenuBits == 0 ? "menu closed" : "menu STILL OPEN")
            driver.finish()
        }
        await grant()
        post(Self.ninSelect, iconPoint)
        let done = await WindowsSelftest.waitUntil(timeout: 12) { driver.isFinished }
        let clickRefused = popover.stats.refusedForeground == refused0 + 1
        // A second launch refused: the balloon of before.
        let requests0 = app.showRequests
        _ = PostMessageW(sink, WinSingleInstance.showMessage, 0, 0)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { self.app.showRequests > requests0 }
        let balloon = host.balloons.map { $0.inFlight?.id == "already-running" || $0.lastShown?.id == "already-running" } ?? false
        post(Self.ninBalloonHide)
        await pause(0.2)
        r.add("popover.refusedForeground", done && driver.menuWasOpen && clickRefused && popover.stats.refusedForeground == refused0 + 2
                && popover.stats.shows == shows0 && !popover.isOpen && balloon,
              "SetForegroundWindow stubbed false: tray click -> refused=\(clickRefused), shown never (shows +\(popover.stats.shows - shows0)), the tray menu instead: "
              + "\(driver.text) (opened=\(driver.menuWasOpen)); second launch -> refused +\(popover.stats.refusedForeground - refused0) in all, the already-running balloon=\(balloon); "
              + "popover open=\(popover.isOpen) (one log line each: \"popover: the foreground was refused\")")
        await grant()
    }

    // MARK: popover.menuAfter, popover.menuSettings: the right-click menu with the popover

    /// Opens the menu through the real tray callback (WM_CONTEXTMENU), highlights `target` with posted Down keys and presses
    /// Return (a helper thread: the menu loop blocks the main thread).
    func driveMenu(to target: Int, grantFirst: Bool = true) async -> PopoverDriver {
        if grantFirst { await grant() }
        let driver = PopoverDriver()
        let owner = Int(bitPattern: sink), count = host.menuItems().count
        WindowsSelftest.onThread {
            func post(_ message: Int32, _ key: Int32) { _ = PostMessageW(HWND(bitPattern: owner), UINT(message), WPARAM(key), 0) }
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 160 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            let bits = WinPopupMenu.openMenuBits
            guard bits != 0 else { driver.note("menu never opened"); driver.finish(); return }
            driver.menuSeen()
            Thread.sleep(forTimeInterval: 0.4)
            var presses = 0
            while WinPopupMenu.highlightedIndex(menuBits: bits, count: count) != target, presses < count + 2 {
                post(WM_KEYDOWN, Int32(VK_DOWN)); post(WM_KEYUP, Int32(VK_DOWN))
                presses += 1
                Thread.sleep(forTimeInterval: 0.2)
            }
            driver.note("down=\(presses) highlighted=\(WinPopupMenu.highlightedIndex(menuBits: bits, count: count).map(String.init) ?? "none")")
            post(WM_KEYDOWN, Int32(VK_RETURN)); post(WM_KEYUP, Int32(VK_RETURN))
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.1) }
            if WinPopupMenu.openMenuBits != 0 {
                driver.note("still open; Escape")
                post(WM_KEYDOWN, Int32(VK_ESCAPE)); post(WM_KEYUP, Int32(VK_ESCAPE))
            }
            driver.finish()
        }
        post(Self.contextMenu, iconPoint)
        _ = await WindowsSelftest.waitUntil(timeout: 25) { driver.isFinished }
        return driver
    }

    func menuChecks() async {
        popover.close(.destroyed)
        let items = host.menuItems()
        guard let back = items.firstIndex(where: { $0?.action == .toggleBackView }),
              let settings = items.firstIndex(where: { $0?.action == .openSettings }) else {
            r.add("popover.menuAfter", false, "the menu has no Back view or Settings… entry")
            r.add("popover.menuSettings", false, "the menu has no Settings… entry")
            return
        }
        let facing = app.store.alwaysFacesBack, menus0 = tray.contextMenuCount
        // The popover was open just before: it closes when the menu opens (the Mac's showStatusMenu).
        let wasOpen = await click()
        let a = await driveMenu(to: back, grantFirst: false)  // the popover is in front: the menu's own close of it is what is seen
        let closedBy = popover.stats.lastClose
        let toggled = app.store.alwaysFacesBack != facing
        let action = host.lastAction
        if toggled { app.store.alwaysFacesBack = facing }
        r.add("popover.menuAfter", wasOpen && a.isFinished && a.menuWasOpen && toggled && action == .toggleBackView && !popover.isOpen && closedBy == .iconClick
                && WinModalPump.depth == 0 && tray.contextMenuCount == menus0 + 1,
              "popover open=\(wasOpen), then WM_CONTEXTMENU through the tray callback: popover closed=\(!popover.isOpen) (\(closedBy.map { "\($0)" } ?? "-")), menu keys: \(a.text) -> action=\(action), "
              + "back view \(facing) -> \(toggled ? !facing : facing) (restored), pump depth after=\(WinModalPump.depth)")
        let b = await driveMenu(to: settings)
        let opened = await opened()
        r.add("popover.menuSettings", b.isFinished && opened && popover.state.showSettings && popover.stats.lastOpener == .trayMenu,
              "menu keys: \(b.text) -> popover open and in front=\(opened), on Settings=\(popover.state.showSettings), opener=\(popover.stats.lastOpener.map { "\($0)" } ?? "-")")
        popover.close(.destroyed)
        await grant()
    }

    // MARK: popover.secondLaunch (D4, ruling 3)

    func secondLaunchCheck() async {
        popover.close(.destroyed)
        // Is the foreground lock enforced against this process on the runner? (Another app in front, then a plain attempt.)
        var lockEnforced: Bool?
        await grant()
        if let other = try? WindowsSelftest.Helper.start(["--selftest-popover-helper", "foreground", "1"], ready: true) {
            if await other.waitReady(timeout: 10), let probe {
                _ = SetForegroundWindow(probe.hwnd)
                lockEnforced = GetForegroundWindow() != probe.hwnd
            }
            if await other.waitExit(timeout: 10) == nil { other.kill() }
            other.close()
        }
        // A second start from a foreground process, as Explorer starts it from Start: that process hands its right on.
        await grant()
        let requests0 = app.showRequests
        let marker = "single instance: asked pid \(GetCurrentProcessId()) to open its popover"
        let lines0 = Self.logLines(containing: marker).count
        var launcherCode: DWORD?, ready = false
        var opened = false
        if let launcher = try? WindowsSelftest.Helper.start(["--selftest-popover-helper", "launch-second", "1"], ready: true) {
            ready = await launcher.waitReady(timeout: 30)
            opened = await self.opened(5)
            launcherCode = await launcher.waitExit(timeout: 10)
            if launcherCode == nil { launcher.kill() }
            launcher.close()
        }
        let line = Self.logLines(containing: marker).dropFirst(lines0).last ?? "no line from the second instance"
        let opener = popover.stats.lastOpener == .secondLaunch
        let wr = windowRect()
        r.add("popover.secondLaunch", ready && opened && opener && launcherCode == 0 && app.showRequests == requests0 + 1,
              "a foreground helper started a second instance (--selftest-second) through the single-instance channel: launcher exit=\(WindowsSelftest.describe(launcherCode)) "
              + "(0: it was in front and the second instance yielded with 3); popover open and in front=\(opened), opener second launch=\(opener) at \(Self.text(wr)); "
              + "the second instance logged: \"\(line)\"; foreground lock enforced against this process on the runner=\(lockEnforced.map { "\($0)" } ?? "unknown")")
        popover.close(.destroyed)
        await grant()
    }

    static func logLines(containing marker: String) -> [String] {
        guard let text = try? String(contentsOf: AppLog.logFileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { $0.contains(marker) }.map(String.init)
    }

    // MARK: popover.realClick (informational unless the shell reports the click)

    func realClickCheck() async {
        popover.close(.destroyed)
        guard let rect = tray.anchorRect() else {
            r.add("popover.realClick", true, "informational: the shell gives no icon rectangle (Shell_NotifyIconGetRect hr=0x\(String(UInt32(bitPattern: tray.lastAnchorResult), radix: 16)))")
            return
        }
        let c = POINT(x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2)
        let onTaskbar = workArea(of: rect).map { !Self.inside(rect, $0) } ?? false
        await grant()
        let s0 = tray.selectCount
        await leftClick(c)
        let reported = await WindowsSelftest.waitUntil(timeout: 1.5) { self.tray.selectCount > s0 }
        var detail = "shell rect \(Self.text(rect)) on the taskbar=\(onTaskbar); a real click at \(c.x),\(c.y): NIN_SELECT=\(reported)"
        var ok = true
        if reported {
            let opened = await opened()
            let s1 = tray.selectCount, absorbed0 = popover.stats.suppressedSelects
            await leftClick(c)  // the toggle race for real
            _ = await WindowsSelftest.waitUntil(timeout: 1.5) { self.tray.selectCount > s1 }
            await pause(0.7)
            let closedNotReopened = !popover.isOpen
            ok = opened && closedNotReopened
            detail += "; popover open=\(opened) at \(Self.text(popover.stats.lastFrame)); a second real click: closed and not reopened=\(closedNotReopened) "
                + "(closed by \(popover.stats.lastClose.map { "\($0)" } ?? "-"), cursor on the icon=\(popover.stats.lastCursorInAnchor), absorbed +\(popover.stats.suppressedSelects - absorbed0))"
        } else {
            // Probably in the overflow: the click opened the ^ flyout. Is the icon there now?
            await pause(0.8)
            let now = tray.anchorRect()
            detail += "; in front after it: \(foregroundName()); the shell's rect now \(now.map(Self.text) ?? "nil")"
            if let now, now.left != rect.left || now.top != rect.top {
                let p = POINT(x: (now.left + now.right) / 2, y: (now.top + now.bottom) / 2)
                let s2 = tray.selectCount
                await leftClick(p)
                let reported2 = await WindowsSelftest.waitUntil(timeout: 1.5) { self.tray.selectCount > s2 }
                var opened2 = false
                if reported2 { opened2 = await opened() }
                ok = !reported2 || opened2
                detail += "; a real click on the icon in the overflow flyout at \(p.x),\(p.y): NIN_SELECT=\(reported2) popover open=\(opened2)"
                    + (opened2 ? " at \(Self.text(popover.stats.lastFrame)) edge \(popover.stats.lastEdge.map { "\($0)" } ?? "-")" : "")
            }
            WindowsSelftestPopover.tap(0x1B)
            await pause(0.3)
        }
        popover.close(.destroyed)
        r.add("popover.realClick", ok, (reported ? "" : "informational: ") + detail)
        await grant()
    }

    // MARK: popover.capture (--dump-ui): the empty popover anchored at the runner's tray

    func captureCheck(_ dir: URL) async {
        popover.close(.destroyed)
        let o = await click()
        await pause(0.6)
        let wr = popover.stats.lastFrame
        var wrote: [String] = []
        let sw = Int(GetSystemMetrics(SM_CXSCREEN)), sh = Int(GetSystemMetrics(SM_CYSCREEN))
        if let full = WinUIDump.screenshot(x: 0, y: 0, w: sw, h: sh), WinUIDump.write(full, to: dir.appendingPathComponent("anchored-screen.png")) == 0 {
            wrote.append("anchored-screen.png \(sw)x\(sh)")
        }
        let left = max(0, Int(min(wr.left, anchor?.left ?? wr.left)) - 40), top = max(0, Int(wr.top) - 40)
        let right = min(sw, Int(max(wr.right, anchor?.right ?? wr.right)) + 40), bottom = sh
        if right > left, bottom > top, let crop = WinUIDump.screenshot(x: left, y: top, w: right - left, h: bottom - top),
           WinUIDump.write(crop, to: dir.appendingPathComponent("anchored-tray.png")) == 0 {
            wrote.append("anchored-tray.png \(right - left)x\(bottom - top)")
        }
        r.add("popover.capture", o && wrote.count == 2,
              "sample capture, Windows CI runner: the empty popover opened by a posted NIN_SELECT at the shell's icon rect \(anchor.map(Self.text) ?? "nil"), window \(Self.text(wr)); "
              + "wrote \(wrote.joined(separator: ", ")) in \(dir.path)")
        popover.close(.destroyed)
        await grant()
    }

    // MARK: popover.openClose3: nothing left behind

    func openCloseCheck(start: PopoverResources) async {
        popover.close(.destroyed)
        var cycles: [PopoverResources] = []
        for i in 0..<4 {
            guard await click() else { break }
            await pause(0.3)
            if i % 2 == 0 { await grant() } else { WindowsSelftestPopover.tap(0x1B) }  // by deactivation, then by Escape
            _ = await closed(1)
            await pause(0.3)
            cycles.append(PopoverResources.now())
        }
        guard cycles.count == 4, let warm = cycles.first, let last = cycles.last else {
            r.add("popover.openClose3", false, "only \(cycles.count) of 4 open/close cycles opened")
            return
        }
        let ok = last.gdi - warm.gdi <= 5 && last.user - warm.user <= 5 && last.handles - warm.handles <= 10 && last.windows == start.windows
            && last.controls == 0 && last.dialogs == start.dialogs && last.pumpDepth == 0 && !last.pumpTimer && !popover.isOpen
        r.add("popover.openClose3", ok,
              "before the group: \(start); after a warm-up open/close: \(warm); after 3 more: \(cycles.dropFirst().map { "\($0)" }.joined(separator: " / ")) "
              + "(budget over the warm-up: GDI +5, USER +5, handles +10; windows, kit controls, dialog registrations, the pump and its timer back to the start)")
    }
}
#endif
