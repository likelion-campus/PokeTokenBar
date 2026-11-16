#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// What the selftest and the idle report read about the popover.
struct WinPopoverStats {
    var opens = 0, closes = 0, shows = 0
    var lastOpener: WinPopover.Opener?
    var lastClose: WinPopover.CloseReason?
    /// Selects absorbed as the click that closed the popover (D3), and key selects while it has the keyboard.
    var suppressedSelects = 0, duplicateKeySelects = 0
    var refusedForeground = 0
    /// Async completions (and deferred closes) that arrived for a window that is gone.
    var staleDropped = 0
    /// Activations of windows the popover owns (its own dialogs): it stayed open.
    var ownedActivations = 0
    /// Page rebuilds (a DPI or appearance change) and setting changes that changed nothing it shows.
    var rebuilds = 0, appearanceUnchanged = 0
    /// Keyboard-opened popovers dismissed from the keyboard: `NIM_SETFOCUS` asked, and how often the shell said yes.
    var focusReturnAttempts = 0, focusReturnedToTray = 0
    /// When the last deactivation arrived and the last close finished (`QueryPerformanceCounter`, ms).
    var lastDeactivationMs = 0.0, lastCloseMs = 0.0
    var lastCursorInAnchor = false
    var roundCorners = false
    var sessionNotify = false
    /// Closes after a deactivation that waited for a nested loop of the page (an edit's menu, a dialog: post-merge M5), closes
    /// called off when it got the activation back first, and closes that ran inside such a loop anyway (must stay 0).
    var deferredCloses = 0, closesCancelled = 0, closesInsideLoop = 0
    /// The primary button was down at the last deactivation (a slow click: the toggle guard's longer window).
    var lastButtonDown = false
    var lastFrame = RECT()
    /// The window the last open kept clear of (the overflow flyout holding the icon), nil for an icon on the taskbar.
    var lastHolder: RECT?
    var lastEdge: PopoverPlacement.Edge?
    var lastDPI: UINT = 0
    /// Stage 7 Task 15: rebuilds held back while a dialog of the page was open, and run after it.
    var deferredRebuilds = 0, runDeferredRebuilds = 0
    /// Tray, plaza and second-launch requests refused while a dialog is open (the dialog is flashed instead).
    var blockedByDialog = 0
}

/// The popover window (stage 7 D2–D4): one `WS_POPUP` tool window, owned by the hidden sink (no taskbar button, not in
/// Alt+Tab), anchored to the tray icon, made at the DPI of the icon's monitor, light-dismissed. Created on open, destroyed
/// on close: a closed popover leaves no window, timer, hook registration, GDI object or thread behind (D18).
///
/// It opens only for the user: a tray click or key (`toggle`), the tray menu's "Settings…", a second launch; `present` is
/// the only place that activates (`WindowsSeamScanTests`). It closes when another window takes the activation (unless the
/// popover owns it: its own dialogs, D17), when another app does, on Escape (unless the page goes back), on Alt+F4, on a
/// session lock or disconnect, when the plaza opens and when the app quits. A click on the icon while it is open closes it
/// and does not reopen it (`PopoverToggleGuard`). What it shows is a `WinPopoverPage` (`makePage`; Task 5's Home).
///
/// Async work for the open window captures `generation` and lands through `whenCurrent`: a completion that arrives after
/// the page it was for is gone (closed, or rebuilt at a new DPI or appearance) is dropped. Main thread only.
///
/// Topmost (post-merge review I1): other apps' always-on-top windows (a picture-in-picture video, a meeting's mini window,
/// PowerToys Always on Top) and the overflow flyout would otherwise cover it, and a click on the covered part would close it.
/// It is topmost only while it has the activation: it closes when it loses it, and while a close waits for a nested loop of
/// its page it drops to the normal band.
@MainActor final class WinPopover {
    static let className = "PokeTokenBarPopover"
    /// The close after a deactivation, posted so it runs after the activation change (the SDK's NotificationIcon sample does
    /// the same); `wParam` is the serial of the window it is for (not `generation`, which a rebuild changes).
    static let closeMessage = UINT(WM_APP) + 0x70
    /// The 50 ms timer that exists only while a close waits for a nested loop of the page to end (M5).
    static let deferTimerID: UINT_PTR = 0x5054_4204
    /// WS_POPUP | WS_CLIPCHILDREN; Windows 10 adds WS_BORDER (DWM draws a popup's border and round corners only on 11).
    static let baseStyle: DWORD = 0x8000_0000 | 0x0200_0000
    static let isWindows11 = ProcessInfo.processInfo.operatingSystemVersion.patchVersion >= 22000
    static let style: DWORD = isWindows11 ? baseStyle : baseStyle | 0x0080_0000
    /// WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT | WS_EX_TOPMOST: no taskbar button, not in Alt+Tab; Tab walks into the panes'
    /// controls; above other apps' always-on-top windows while it is open (its owned dialogs are too).
    static let exStyle: DWORD = 0x0000_0080 | 0x0001_0000 | 0x0000_0008
    /// CS_DROPSHADOW.
    static let classStyle: UINT = 0x0002_0000
    static let frame = WinPlazaPlacement.frame(style: style, exStyle: exStyle)

    enum Opener: Equatable {
        case trayClick(POINT), trayKey, trayMenu, secondLaunch

        static func == (a: Opener, b: Opener) -> Bool {
            switch (a, b) {
            case let (.trayClick(p), .trayClick(q)): return p.x == q.x && p.y == q.y
            case (.trayKey, .trayKey), (.trayMenu, .trayMenu), (.secondLaunch, .secondLaunch): return true
            default: return false
            }
        }
    }

    enum CloseReason: Equatable { case deactivated, escape, iconClick, plaza, quit, lock, destroyed }

    let host: WinPopoverHost
    /// The navigation state (the Mac's `PopoverNavigation` twin): reset to Home on every open, the provider and account
    /// tabs kept, kept across a DPI rebuild.
    let state = PopoverState()
    private(set) var stats = WinPopoverStats()
    /// What the window shows; Task 5 makes it Home.
    var makePage: @MainActor (WinPopover) -> WinPopoverPage = { _ in WinPopoverEmptyPage() }
    /// The selftest's stand-in for `SetForegroundWindow` (`popover.refusedForeground`); nil in the app.
    var setForegroundForTesting: ((HWND) -> Bool)?
    /// Seconds on a monotonic clock (the toggle guard's).
    var clock: () -> TimeInterval = { TimeInterval(GetTickCount64()) / 1000 }

    private var window: WinSinkWindow?
    private var ctx: WinUIContext?
    private var page: WinPopoverPage?
    private var router: WinControlRouter?
    private var opener: Opener?
    private var inputs: WinPopoverAnchor.Inputs?
    private var guardRegion: RECT?
    private var pendingClose = false
    private var deferring = false
    /// Why the close that is waiting for a nested loop was asked: a user's wish (the plaza, the tray menu) survives the page
    /// getting the activation back, a plain deactivation does not (`reactivated`).
    private var deferredReason: CloseReason = .deactivated
    /// A rebuild asked for while one of the popover's dialogs is open (the page's controls are on that dialog's stack): the
    /// DPI to rebuild at once it ends (`WM_ENABLE`). Stage 7 Task 15.
    private var rebuildAfterDialog: UINT?
    private var closing = false
    private var building = false, sizeChangedWhileBuilding = false
    /// Changes on every open and every close: the posted close's target (a rebuild keeps it).
    private var windowSerial = 0
    private var toggleGuard = PopoverToggleGuard()
    /// When a key select last opened it: the shell may report one Enter as a key select and a select, in either order.
    private var openedByKeyAt: TimeInterval?
    /// Changes on every open, every close and every page rebuild: the identity of the page async work was started for.
    private(set) var generation = 0

    init(host: WinPopoverHost) { self.host = host }

    var isOpen: Bool { window != nil }
    var hwndForTesting: HWND? { window?.hwnd }
    var contextForTesting: WinUIContext? { ctx }
    var pageForTesting: WinPopoverPage? { page }
    var closeSerialForTesting: Int { windowSerial }

    // MARK: - opening

    /// A tray click or key select: closes an open popover, else opens it, except for the click that just closed it (D3).
    /// A key select while it is open is ignored: the popover has the keyboard, so it cannot be the user's (the shell may
    /// report one key twice).
    func toggle(_ opener: Opener) {
        if dialogIsOpen { bringDialogForward(); return }
        guard settlePendingClose() else { return }
        if window != nil {
            if case .trayKey = opener {
                stats.duplicateKeySelects += 1
                return
            }
            if let keyAt = openedByKeyAt, clock() - keyAt < PopoverToggleGuard.window {  // the same Enter, reported twice
                stats.duplicateKeySelects += 1
                return
            }
            toggleGuard.noteSelect()
            close(.iconClick)
            return
        }
        if case .trayClick = opener, !toggleGuard.opensOnSelect(at: clock()) {
            toggleGuard.noteSelect()
            stats.suppressedSelects += 1
            return
        }
        toggleGuard.noteSelect()
        present(opener) { _ in }
    }

    /// Opens the popover for the user's action and takes the foreground (D4); `route` runs after the reset to Home (the
    /// tray menu's "Settings…" lands on Settings), as the Mac's `showPopover(route:)`. Already open: brought forward again,
    /// nothing rebuilt (a second launch while it shows). The foreground is taken while the window is still hidden: a
    /// refused one (R2) is seen before anything shows, the window goes, and the host's fallback runs (the tray menu, or the
    /// balloon). The only activation site of the popover (`WindowsSeamScanTests`).
    func present(_ opener: Opener, route: (PopoverState) -> Void) {
        if dialogIsOpen { bringDialogForward(); return }
        guard settlePendingClose() else { return }
        if let open = window {
            _ = SetForegroundWindow(open.hwnd)
            return
        }
        state.reset()
        route(state)
        let page = makePage(self)
        guard let made = makeWindow(for: opener, page: page) else { return }
        let hwnd = made.hwnd
        let granted = setForegroundForTesting.map { $0(hwnd) } ?? SetForegroundWindow(hwnd)
        guard granted, GetForegroundWindow() == hwnd else {
            stats.refusedForeground += 1
            let point = inputs?.clickPoint
            teardown(.destroyed)
            host.foregroundRefused(opener, at: point)
            return
        }
        _ = ShowWindow(hwnd, SW_SHOW)
        stats.shows += 1
        if GetForegroundWindow() != hwnd { _ = SetForegroundWindow(hwnd) }
        _ = SetFocus(page.initialFocus ?? hwnd)
        openedByKeyAt = nil
        if case .trayKey = opener {  // opened from the keyboard: focus rectangles from the start
            WinKit.send(hwnd, 0x0127 /* WM_CHANGEUISTATE */, 0x0003_0002 /* UIS_CLEAR, UISF_HIDEFOCUS | UISF_HIDEACCEL */)
            openedByKeyAt = clock()
        }
        host.opened()
    }

    /// The window, hidden, at its place, with its page: placed for the icon's monitor at that monitor's DPI.
    private func makeWindow(for opener: Opener, page: WinPopoverPage) -> WinSinkWindow? {
        let point: POINT?
        switch opener {
        case .trayClick(let p): point = p
        case .trayKey: point = host.tray?.tray.lastEventPoint
        case .trayMenu: point = host.lastMenuPoint
        case .secondLaunch: point = nil
        }
        let found = WinPopoverAnchor.inputs(anchor: host.anchorRect, point: point, useCursor: opener != .secondLaunch)
        guard var placed = place(found, heightDIP: page.heightDIP, dpi: nil) else {
            AppLog.write("popover: no monitor to open on")
            return nil
        }
        var r = WinKit.rect(placed.frame)
        let made: WinSinkWindow
        do {
            made = try WinSinkWindow(className: Self.className, title: "PokeTokenBar", style: Self.style, exStyle: Self.exStyle,
                                     x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top,
                                     parent: host.owner, classStyle: Self.classStyle)
        } catch {
            AppLog.write("popover: \(error)")
            return nil
        }
        let hwnd = made.hwnd
        window = made
        generation += 1
        windowSerial += 1
        self.opener = opener
        inputs = found
        stats.opens += 1
        stats.lastOpener = opener
        let dpi = WinUIContext.dpi(of: hwnd)
        if Int(dpi) != placed.dpi, let again = place(found, heightDIP: page.heightDIP, dpi: Int(dpi)) {  // made between monitors
            placed = again
            r = WinKit.rect(placed.frame)
            _ = SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        note(placed, r)
        stats.lastHolder = found.holder
        guardRegion = Self.guardRegion(anchor: found.anchor, opener: opener, dpi: dpi)
        stats.roundCorners = Self.isWindows11 && Self.roundCorners(hwnd)
        register(made)
        WinMessageHook.registerDialogWindow(hwnd)
        router = WinControlRouter(window: made)
        stats.sessionNotify = ptb_window_session_notify(UnsafeMutableRawPointer(hwnd), 1) == 1
        let context = WinUIContext(dpi: dpi, owner: hwnd)
        ctx = context
        build(page, in: made, ctx: context)
        return made
    }

    // MARK: - closing

    /// Closes the open popover (nothing when it is closed). Everything it made goes with it.
    func close(_ reason: CloseReason) {
        guard let w = window, !closing else { return }
        // Stage 7 Task 15: a dialog of the page is open (its modal loop is below us): tearing the page down now would free its
        // controls under the click that opened the dialog. The close waits like a deactivation's does (M5); `.destroyed` is the
        // window going whatever the page is doing (Alt+F4, the selftest).
        if reason != .destroyed, dialogIsOpen || !IsWindowEnabled(w.hwnd) {
            deferredReason = reason
            pendingClose = true
            closeAfterDeactivation()
            return
        }
        teardown(reason)
    }

    /// One of the popover's own dialogs (file dialog, task dialog) is open: app-modal behaviour, the popover cannot be toggled,
    /// moved on or replaced by the plaza until it is answered.
    var dialogIsOpen: Bool { WinModalPump.dialogDepth > 0 }

    /// A request that the open dialog blocks (the tray icon, the plaza, a second launch) flashes the dialog instead of acting,
    /// as an app-modal dialog does. Flashing activates nothing (the activation scan allows it).
    func bringDialogForward() {
        stats.blockedByDialog += 1
        guard let w = window else { return }
        var previous: HWND?
        let cls = WinStr.w("#32770")
        while let h = FindWindowExW(nil, previous, cls, nil) {
            previous = h
            if IsWindowVisible(h), Self.isOwned(h, by: w.hwnd) { _ = FlashWindow(h, true) }
        }
    }

    /// `windowGone`: Windows is destroying the window already (`WM_DESTROY` from outside): no second `DestroyWindow`; the
    /// window table drops it at `WM_NCDESTROY`.
    private func teardown(_ reason: CloseReason, windowGone: Bool = false) {
        guard let w = window else { return }
        closing = true
        defer { closing = false }
        let hwnd = w.hwnd
        var keyboard = false
        if case .trayKey = opener { keyboard = true }
        // Opened from the keyboard and dismissed by it: the keyboard goes back to the icon (NIM_SETFOCUS), asked while the
        // popover still has the foreground. Otherwise Windows activates the next window down (the app or the plaza below).
        if keyboard, reason == .escape || reason == .destroyed, !windowGone, GetForegroundWindow() == hwnd {
            stats.focusReturnAttempts += 1
            if host.returnFocusToTray() { stats.focusReturnedToTray += 1 }
        }
        if WinModalPump.depth > 0 || Self.inMenuOrMoveLoop() { stats.closesInsideLoop += 1 }  // must stay 0 (M5)
        if deferring { _ = KillTimer(hwnd, Self.deferTimerID) }
        deferring = false
        generation += 1
        windowSerial += 1
        pendingClose = false
        deferredReason = .deactivated
        rebuildAfterDialog = nil
        page?.destroy()
        page = nil
        router?.detach()
        router = nil
        WinMessageHook.unregisterDialogWindow(hwnd)
        if stats.sessionNotify { _ = ptb_window_session_notify(UnsafeMutableRawPointer(hwnd), 0) }
        ctx?.destroy()
        ctx = nil
        window = nil
        opener = nil
        inputs = nil
        guardRegion = nil
        if !windowGone { w.destroy() }
        stats.closes += 1
        stats.lastClose = reason
        stats.lastCloseMs = Self.milliseconds()
    }

    /// Another window took the activation. One the popover owns (its dialog, D17) leaves it open; anything else closes it,
    /// after the activation change (posted). The cursor's place now tells the toggle guard whether this was a click on the
    /// icon (D3).
    private func deactivated(by other: HWND?) {
        guard let w = window, !closing, !pendingClose else { return }
        if let other, Self.isOwned(other, by: w.hwnd) {
            stats.ownedActivations += 1
            return
        }
        pendingClose = true
        deferredReason = .deactivated
        stats.lastDeactivationMs = Self.milliseconds()
        let onIcon = cursorOnIcon()
        // The taskbar is activated on the press; a press still down here is released later (a slow click, M2).
        let primary = GetSystemMetrics(SM_SWAPBUTTON) != 0 ? VK_RBUTTON : VK_LBUTTON
        let down = GetAsyncKeyState(Int32(primary)) & Int16(bitPattern: 0x8000) != 0
        stats.lastCursorInAnchor = onIcon
        stats.lastButtonDown = down
        toggleGuard.noteClosedByDeactivation(at: clock(), cursorInAnchor: onIcon, buttonDown: down)
        _ = PostMessageW(w.hwnd, Self.closeMessage, WPARAM(UInt(bitPattern: windowSerial)), 0)
    }

    /// The posted close (or its timer): closes, unless a nested loop of the page is running (an edit's context menu, a
    /// combo box, a scroll-thumb drag, an owned modal dialog that disabled the popover). Tearing the page down then would
    /// free its views under their own stack frames: the close waits for the loop to end, polled by a 50 ms timer that exists
    /// only while it waits, and meanwhile the popover leaves the topmost band (it lost the activation).
    private func closeAfterDeactivation() {
        guard let w = window, pendingClose else { return }
        if WinModalPump.depth > 0 || Self.inMenuOrMoveLoop() || !IsWindowEnabled(w.hwnd) {
            if !deferring {
                deferring = true
                stats.deferredCloses += 1
                _ = SetTimer(w.hwnd, Self.deferTimerID, 50, nil)
                _ = SetWindowPos(w.hwnd, HWND(bitPattern: -2) /* HWND_NOTOPMOST */, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
            }
            return
        }
        let reason = deferredReason
        deferredReason = .deactivated
        close(reason)
    }

    /// A close still pending from a deactivation runs first. False: it is waiting for a nested loop of the page, which this
    /// request arrived inside; the request is dropped (the loop's own window message, nothing the user can see).
    private func settlePendingClose() -> Bool {
        guard pendingClose else { return true }
        closeAfterDeactivation()
        return !pendingClose
    }

    /// The popover has the activation again before a waiting close ran (its own dialog closed, the user came back): it stays.
    private func reactivated() {
        guard pendingClose, deferredReason == .deactivated, let w = window else { return }
        pendingClose = false
        stats.closesCancelled += 1
        guard deferring else { return }
        deferring = false
        _ = KillTimer(w.hwnd, Self.deferTimerID)
        _ = SetWindowPos(w.hwnd, HWND(bitPattern: -1) /* HWND_TOPMOST */, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
    }

    private func escape() {
        guard window != nil, !closing else { return }
        if page?.escape() == true { return }
        close(.escape)
    }

    // MARK: - async work, page size

    /// Whether the window that was open at `generation` still is.
    func isCurrent(_ generation: Int) -> Bool { window != nil && !pendingClose && generation == self.generation }

    /// Runs `body` only while the window that was open at `generation` still is: a completion (a sprite decode, a fetch)
    /// that arrives after that window closed, or for an earlier one, is dropped and counted.
    func whenCurrent(_ generation: Int, _ body: () -> Void) {
        guard isCurrent(generation) else {
            stats.staleDropped += 1
            return
        }
        body()
    }

    /// The page's `heightDIP` changed (Settings replaced Home, D2): the window is placed again for the same icon.
    func pageSizeChanged() {
        if building {  // from inside the page's own build: applied once build returns (no re-entrant layout)
            sizeChangedWhileBuilding = true
            return
        }
        guard let w = window, let page, let ctx, let inputs else { return }
        var fresh = WinPopoverAnchor.inputs(anchor: inputs.anchor, point: inputs.clickPoint, useCursor: false)
        fresh.holder = inputs.holder  // the flyout it opened from, not whatever is under that point now
        guard let placed = place(fresh, heightDIP: page.heightDIP, dpi: Int(ctx.dpi)) else { return }
        let r = WinKit.rect(placed.frame)
        _ = SetWindowPos(w.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        note(placed, r)
        page.layout(client: Self.client(w.hwnd))
    }

    // --- stage 7 Task 6: swap the page in place (begin) ---
    /// The page changed while the window stays (Home → Settings, Settings → Back, the Mac's in-place swap, P1): the old page
    /// is destroyed (a changed field commits), `makePage` builds the one `state` asks for in the same window and context, the
    /// window is placed again for the new height, and the keyboard starts in it. Async work of the old page is stale.
    func replacePage() {
        guard let w = window, let ctx, page != nil, !closing else { return }
        generation += 1
        page?.destroy()
        let next = makePage(self)
        page = next
        next.build(in: w, ctx: ctx, client: Self.client(w.hwnd))
        pageSizeChanged()
        _ = SetFocus(next.initialFocus ?? w.hwnd)
    }
    // --- stage 7 Task 6: swap the page in place (end) ---

    // MARK: - messages

    private func register(_ w: WinSinkWindow) {
        w.on(0x000A /* WM_ENABLE */) { [weak self] wParam, _ in
            if wParam != 0 { self?.runDeferredRebuild(tries: 0) }   // the owned dialog ended and enabled the popover again
            return nil
        }
        w.on(0x0006 /* WM_ACTIVATE */) { [weak self] wParam, lParam in
            if WinKit.loWord(wParam) == 0 /* WA_INACTIVE */ { self?.deactivated(by: HWND(bitPattern: Int(lParam))) } else { self?.reactivated() }
            return nil
        }
        w.on(0x001C /* WM_ACTIVATEAPP */) { [weak self] wParam, _ in
            if wParam == 0 { self?.deactivated(by: nil) }  // another app's window: never one of ours
            return nil
        }
        w.on(Self.closeMessage) { [weak self] wParam, _ in
            guard let self else { return 0 }
            if Int(bitPattern: UInt(wParam)) == windowSerial, pendingClose { closeAfterDeactivation() } else { stats.staleDropped += 1 }
            return 0
        }
        w.on(UINT(WM_TIMER)) { [weak self] wParam, _ in
            guard let self, wParam == WPARAM(Self.deferTimerID) else { return nil }
            closeAfterDeactivation()
            return 0
        }
        // Escape: `IsDialogMessageW` turns it into IDCANCEL for the popover (the message hook, D5); a key-down for the window
        // itself is the path without the hook. Nothing else closes it (a `WM_CLOSE` is Alt+F4, below).
        w.on(UINT(WM_COMMAND)) { [weak self] wParam, lParam in
            guard let self, WinKit.loWord(wParam) == 2 /* IDCANCEL */, WinKit.hiWord(wParam) == 0,
                  lParam == 0 || WinControl.control(HWND(bitPattern: Int(lParam))) == nil else { return nil }
            escape()
            return 0
        }
        w.on(UINT(WM_KEYDOWN)) { [weak self] wParam, _ in
            guard let self, wParam == WPARAM(VK_ESCAPE) else { return nil }
            escape()
            return 0
        }
        w.on(0x0010 /* WM_CLOSE */) { [weak self] _, _ in
            self?.close(.destroyed)  // Alt+F4
            return 0
        }
        w.on(0x0002 /* WM_DESTROY */) { [weak self] _, _ in
            guard let self, !closing, window != nil else { return nil }
            teardown(.destroyed, windowGone: true)  // destroyed by someone else: give everything back
            return nil
        }
        w.on(0x02E0 /* WM_DPICHANGED */) { [weak self] wParam, _ in
            self?.dpiChanged(UINT(WinKit.loWord(wParam)))
            return 0
        }
        for message: UINT in [0x001A /* WM_SETTINGCHANGE */, 0x0015 /* WM_SYSCOLORCHANGE */, 0x031A /* WM_THEMECHANGED */] {
            w.on(message) { [weak self] wParam, _ in
                self?.settingsChanged(workArea: message == 0x001A && wParam == 0x002F /* SPI_SETWORKAREA */)
                return nil
            }
        }
        w.on(0x02B1 /* WM_WTSSESSION_CHANGE */) { [weak self] wParam, _ in
            if [2, 4, 7].contains(Int(wParam)) { self?.close(.lock) }  // console or remote disconnect, lock (D3)
            return 0
        }
        w.on(0x0014 /* WM_ERASEBKGND */) { [weak self] wParam, _ in
            self?.eraseBackground(HDC(bitPattern: Int(bitPattern: UInt(wParam))))
        }
        w.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
    }

    /// After the dialog's own call stack unwound (the click that opened it has returned), not inside the message that enabled the
    /// popover: the rebuild frees the controls that click ran on.
    private func runDeferredRebuild(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let dpi = rebuildAfterDialog, let w = window else { return }
                if dialogIsOpen || !IsWindowEnabled(w.hwnd) {
                    if tries < 40 { runDeferredRebuild(tries: tries + 1) }
                    return
                }
                rebuildAfterDialog = nil
                stats.runDeferredRebuilds += 1
                rebuild(dpi: dpi)
            }
        }
    }

    /// A scale change while open: the window is placed again at the new DPI and the page rebuilt in place, the navigation
    /// state kept (D2, R6).
    private func dpiChanged(_ dpi: UINT) {
        guard let w = window, let page, let inputs, let ctx else { return }
        var fresh = WinPopoverAnchor.inputs(anchor: inputs.anchor, point: inputs.clickPoint, useCursor: false)
        fresh.holder = inputs.holder  // the flyout it opened from, not whatever is under that point now
        if let placed = place(fresh, heightDIP: page.heightDIP, dpi: Int(dpi)) {
            let r = WinKit.rect(placed.frame)
            _ = SetWindowPos(w.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            note(placed, r)
        }
        if ctx.needsRebuild(dpi: dpi) { rebuild(dpi: dpi) } else { page.layout(client: Self.client(w.hwnd)) }
    }

    /// A system setting changed: the page is rebuilt only when what it is drawn with changed (`WinUIContext.needsRebuild`:
    /// text size, high contrast, the accent, the system colours the palette reads); a rebuild loses focus, scroll position and
    /// an IME composition, so nothing else rebuilds it. A new work area (the taskbar moved or changed size) places the window
    /// again.
    private func settingsChanged(workArea: Bool) {
        guard window != nil, let ctx else { return }
        if workArea { pageSizeChanged() }
        guard ctx.needsRebuild() else {
            stats.appearanceUnchanged += 1
            return
        }
        rebuild(dpi: ctx.dpi)
    }

    /// The page again with a new context. `generation` changes first: work the old build started lands nowhere (the page
    /// asks again in `build`).
    private func rebuild(dpi: UINT) {
        guard let w = window, let page else { return }
        // Stage 7 Task 15: a dialog of the page is open, its controls are on that dialog's stack: wait until it ends.
        if dialogIsOpen || !IsWindowEnabled(w.hwnd) {
            rebuildAfterDialog = dpi
            stats.deferredRebuilds += 1
            return
        }
        let hadFocus = GetForegroundWindow() == w.hwnd
        generation += 1
        page.destroy()
        ctx?.destroy()
        let context = WinUIContext(dpi: dpi, owner: w.hwnd)
        ctx = context
        build(page, in: w, ctx: context)
        stats.rebuilds += 1
        if hadFocus { _ = SetFocus(page.initialFocus ?? w.hwnd) }
    }

    private func eraseBackground(_ dc: HDC?) -> LRESULT? {
        guard let dc, let w = window, let ctx, let brush = ctx.colors.brush(ctx.colors.palette.window) else { return nil }
        var r = RECT()
        _ = GetClientRect(w.hwnd, &r)
        _ = FillRect(dc, &r, brush)
        return 1
    }

    // MARK: - helpers

    /// The page is the popover's before its build runs (a `pageSizeChanged()` from inside it is applied right after).
    private func build(_ page: WinPopoverPage, in w: WinSinkWindow, ctx context: WinUIContext) {
        self.page = page
        building = true
        page.build(in: w, ctx: context, client: Self.client(w.hwnd))
        building = false
        if sizeChangedWhileBuilding {
            sizeChangedWhileBuilding = false
            pageSizeChanged()
        }
    }

    /// `GUI_INMOVESIZE | GUI_INMENUMODE | GUI_SYSTEMMENUMODE | GUI_POPUPMENUMODE` for this thread: a menu or a move/size loop
    /// runs on this thread's stack (also one the system starts for a control, like an edit's context menu).
    static func inMenuOrMoveLoop() -> Bool {
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        guard GetGUIThreadInfo(GetCurrentThreadId(), &info) else { return false }
        return info.flags & 0x1E != 0
    }

    private func place(_ inputs: WinPopoverAnchor.Inputs, heightDIP: CGFloat, dpi: Int?) -> PopoverPlacement.Result? {
        let frame = Self.frame
        return PopoverPlacement.place(anchor: inputs.placementAnchor.map(WinPopoverAnchor.cgRect), clickPoint: inputs.clickPoint.map(WinPopoverAnchor.cgPoint),
                                      sizeDIP: CGSize(width: PopoverWindowMetrics.width, height: heightDIP), monitors: inputs.monitors,
                                      appBar: inputs.appBar.map(WinPopoverAnchor.cgRect), dpi: dpi,
                                      framePixels: { d in let f = frame(UInt32(d), 0, 0); return CGSize(width: CGFloat(f.width), height: CGFloat(f.height)) })
    }

    private func note(_ placed: PopoverPlacement.Result, _ r: RECT) {
        stats.lastFrame = r
        stats.lastEdge = placed.edge
        stats.lastDPI = UINT(placed.dpi)
    }

    private func cursorOnIcon() -> Bool {
        guard let region = guardRegion else { return false }
        var p = POINT()
        guard GetCursorPos(&p) else { return false }
        return WinPopoverAnchor.contains(region, p)
    }

    /// Where a click means "the icon" for the toggle guard: the icon's rectangle when the click was in it, else a box the
    /// size of a small icon around the click (the icon in the overflow flyout, when the shell's rectangle is the flyout's
    /// button: a click on that button to open the flyout again is not a click on the icon). Key, menu and second-launch
    /// openers: the rectangle.
    static func guardRegion(anchor: RECT?, opener: Opener, dpi: UINT) -> RECT? {
        guard case .trayClick(let p) = opener else { return anchor }
        if let anchor, WinPopoverAnchor.contains(anchor, p) { return anchor }
        let half = Int32((16 * Double(dpi) / 96).rounded())
        return RECT(left: p.x - half, top: p.y - half, right: p.x + half, bottom: p.y + half)
    }

    /// Whether `window` is owned by `owner`, directly or through other owned windows.
    static func isOwned(_ window: HWND, by owner: HWND) -> Bool {
        var current: HWND? = window
        for _ in 0..<16 {
            guard let h = current, let next = GetWindow(h, UINT(GW_OWNER)) else { return false }
            if next == owner { return true }
            current = next
        }
        return false
    }

    static func milliseconds() -> Double {
        var counter = LARGE_INTEGER(), frequency = LARGE_INTEGER()
        _ = QueryPerformanceCounter(&counter)
        _ = QueryPerformanceFrequency(&frequency)
        return Double(counter.QuadPart) * 1000 / Double(frequency.QuadPart)
    }

    static func client(_ hwnd: HWND) -> RECT {
        var r = RECT()
        _ = GetClientRect(hwnd, &r)
        return r
    }

    /// Windows 11: `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND` (DWM then draws the rounded border too).
    static func roundCorners(_ hwnd: HWND) -> Bool {
        typealias Fn = @convention(c) (HWND?, DWORD, UnsafeRawPointer?, DWORD) -> Int32
        guard let set = WinDynamic.symbol("dwmapi.dll", "DwmSetWindowAttribute", as: Fn.self) else { return false }
        var preference: Int32 = 2  // DWMWCP_ROUND
        return withUnsafePointer(to: &preference) { set(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, $0, 4) } == 0
    }
}

#endif
