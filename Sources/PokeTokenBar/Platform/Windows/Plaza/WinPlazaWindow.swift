#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// The Windows plaza window (D6): the `PlazaWindowShell` the shared controller talks to, as `PlazaMacWindow` is on the Mac.
/// One top-level window made through `WinSinkWindow` (so the character hook and the shared routing apply), the Direct2D
/// scene drawn by `WinPlazaRenderer` into a DirectComposition swap chain (D1), the frame clock (`WinPlazaView`, D4) and
/// the visibility signals (`WinPlazaVisibility`, D5). Window events go to `events`; this type decides nothing about the
/// plaza. Main thread only.
///
/// Lifecycle: `open` creates the window hidden, at the saved or centred place, and the device; only `bringToFront` shows it
/// (the only call that activates). The close button, Alt+F4 and `requestClose` reach `WM_CLOSE`, which reports
/// `handleClose` to the controller; the controller then calls `stopPresenting` and `dismantle`, which joins the clock
/// thread, removes the hooks, releases the swap chain and the device and destroys the window. The app keeps running.
///
/// The HUD's panels (stage 6 Task 10) are drawn into the same frame after the scene by `WinPlazaPanels`, which also routes the mouse
/// to them as the Mac's per-panel views do; their hover texts are a system tooltip control (`WinPlazaTooltips`). The chat line (Task 11)
/// is `WinPlazaChatInput`: a native EDIT child over the composition, its bar drawn above every panel.
/// Keyboard and mouse (Task 6) arrive through `inputHandler`: every input message of the window is handed to it unchanged.
@MainActor final class WinPlazaWindow: PlazaWindowShell {
    static let className = "PokeTokenBarPlaza"
    /// WS_OVERLAPPEDWINDOW (caption, system menu, thick frame, minimize and maximize boxes); created without WS_VISIBLE.
    static let style: UInt32 = 0x00CF_0000
    /// WS_EX_NOREDIRECTIONBITMAP: the composition is the client area's only content (D1).
    static let exStyle: UInt32 = 0x0020_0000
    /// The frame clock's tick and the WinEvent hooks' notice, posted to this window.
    static let frameMessage = UINT(WM_APP) + 0x50
    static let hookMessage = UINT(WM_APP) + 0x51
    /// The keyboard, mouse and focus messages handed to `inputHandler` (Task 6).
    static let inputMessages: [UINT] = [0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x0105, 0x0106, 0x0107,  // keys, chars
                                        0x0200, 0x0201, 0x0202, 0x0204, 0x0205, 0x0207, 0x0208, 0x020A, 0x020E, 0x02A3,  // mouse
                                        0x0007, 0x0008,  // WM_SETFOCUS, WM_KILLFOCUS
                                        0x0112, 0x0211, 0x001F, 0x0215, 0x0051]  // WM_SYSCOMMAND, WM_ENTERMENULOOP, WM_CANCELMODE, WM_CAPTURECHANGED, WM_INPUTLANGCHANGE
    static let mouseActivate: UINT = 0x0021

    private enum Msg {
        static let close: UINT = 0x0010, paint: UINT = 0x000F, eraseBackground: UINT = 0x0014, setCursor: UINT = 0x0020
        static let minMax: UINT = 0x0024, activate: UINT = 0x0006, size: UINT = 0x0005, windowPosChanged: UINT = 0x0047
        static let displayChange: UINT = 0x007E, timer: UINT = 0x0113, dpiChanged: UINT = 0x02E0, session: UINT = 0x02B1
    }

    struct Stats: Equatable, Sendable {
        var ticks = 0, draws = 0, presents = 0, cleanTicks = 0, gpuBusy = 0, deviceLosses = 0, presentFailures = 0
        var resizes = 0, dpiChanges = 0, paints = 0, activations = 0, shows = 0
        /// `didResignKey` reports (the chat field taking the keyboard must not add one: it is the plaza's own child).
        var resigns = 0
        /// Main thread per drawn frame: the renderer's build + submit, then the present (last frame).
        var lastDrawMs: Double = 0, lastPresentMs: Double = 0
    }

    weak var events: (any PlazaWindowEvents)?
    /// A hook that sees the window's input messages (`inputMessages`) raw before `input` does; a non-nil result wins.
    var inputHandler: ((UINT, WPARAM, LPARAM) -> LRESULT?)?
    /// Task 6 (D7): keys, mouse and wheel of the open window; nil without a window.
    private(set) var input: WinPlazaInputRouter?
    private var imeWanted = false

    private let placementKey: String
    private let defaults: UserDefaults
    private let allowActivation: Bool
    private let systemEvents: WindowsSystemEvents?
    private var window: WinSinkWindow?
    private var stage: WinPlazaStage?
    private var device: WinGfxDevice?
    private var surface: WinGfxSurface?
    private var renderer: WinPlazaRenderer?
    private var view: WinPlazaView?
    private(set) var visibility = WinPlazaVisibility(hookMessage: WinPlazaWindow.hookMessage)
    private var panels: WinPlazaPanels?
    private var tooltips: WinPlazaTooltips?
    /// Task 11: the chat line (the controller's `PlazaOverlayBindings.chatInput` when it is the Windows one).
    private(set) var chat: WinPlazaChatInput?
    private var dpi: UInt32 = 96
    private var transparent = false
    private(set) var isHUDHidden = false
    private(set) var isChatLogAboveInput = false
    private var showMaximized = false
    private var lastNormal: (rect: WinPlazaPlacement.Rect, dpi: UInt32)?
    private var monitor: HMONITOR?
    private var contentHeight: CGFloat = 0
    private var loggedChat = false, loggedPresentFailure = false, loggedStage = false
    private(set) var stats = Stats()
    /// The stats of the last window when it was dismantled, and whether its clock thread ended in time (selftest).
    private(set) var lastClosed: (stats: Stats, clockJoined: Bool)?
    /// Why the last `open` made no window (nil when it did).
    private(set) var openFailure: String?

    /// `defaults`: where the placement is saved (the app's settings). `allowActivation: false` shows the window without
    /// taking the foreground (a selftest on a person's PC); the app always passes true.
    init(placementKey: String = WinPlazaPlacement.defaultKey, defaults: UserDefaults, allowActivation: Bool = true,
         systemEvents: WindowsSystemEvents? = nil) {
        self.placementKey = placementKey
        self.defaults = defaults
        self.allowActivation = allowActivation
        self.systemEvents = systemEvents
    }

    // MARK: PlazaWindowShell

    func open(stage presented: any PlazaStage, title: String, overlays: PlazaOverlayBindings) {
        guard window == nil else { return }
        openFailure = nil
        guard let stage = presented as? WinPlazaStage else {
            fail("the stage is \(type(of: presented)), not WinPlazaStage (WinPlazaLive not installed?)")
            return
        }
        let device: WinGfxDevice
        switch WinGfxDevice.make() {
        case .success(let d): device = d
        case .failure(let e):
            fail("no Direct2D device: \(e)")
            return
        }
        let place = WinPlazaPlacement.restore(saved: WinPlazaPlacement.read(defaults, key: placementKey),
                                              monitors: WinPlazaPlacement.monitors(), frame: Self.frame)
        let r = place.rect
        let made: WinSinkWindow
        do {
            made = try WinSinkWindow(className: Self.className, title: title, style: Self.style, exStyle: Self.exStyle,
                                     x: r.left, y: r.top, width: r.width, height: r.height)
        } catch {
            fail("\(error)")
            return
        }
        let hwnd = made.hwnd
        dpi = ptb_window_dpi(UnsafeMutableRawPointer(hwnd))
        if dpi != place.dpi {  // created on a monitor of another scale than planned: the content keeps its DIP size
            let f = Self.frame(dpi, Int32((Double(r.width - Self.frame(place.dpi, 0, 0).width) * Double(dpi) / Double(place.dpi)).rounded()),
                               Int32((Double(r.height - Self.frame(place.dpi, 0, 0).height) * Double(dpi) / Double(place.dpi)).rounded()))
            _ = SetWindowPos(hwnd, nil, 0, 0, f.width, f.height, UINT(SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE))
        }
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let pw = max(1, Int(client.right - client.left)), ph = max(1, Int(client.bottom - client.top))
        let surface: WinGfxSurface
        switch WinGfxSurface.window(device: device, hwnd: UnsafeMutableRawPointer(hwnd), width: pw, height: ph) {
        case .success(let s): surface = s
        case .failure(let e):
            made.destroy()
            fail("no window surface: \(e)")
            return
        }
        window = made
        self.device = device
        self.surface = surface
        renderer = WinPlazaRenderer(surface: surface)
        let clock = WinFrameClock(window: hwnd, message: Self.frameMessage)
        if clock == nil { AppLog.write("plaza window: no frame clock thread (\(WinPlazaCodecs.lastError())); it draws only on its own events") }
        let view = WinPlazaView(clock: clock) { [weak stage] in stage?.isPaused ?? true }
        self.view = view
        monitor = MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST))
        clock?.setMonitor(monitor, forceTimer: Self.environmentForcesTimer)
        self.stage = stage
        stage.onPauseChange = { [weak self] in self?.view?.update() }
        showMaximized = place.maximized
        stats = Stats()
        let router = WinPlazaInputRouter(hwnd: hwnd, stage: { [weak self] in self?.stage }, scale: { [weak self] in CGFloat(self?.dpi ?? 96) / 96 })
        router.reassertIME = { [weak self] in self?.reassertIME() }
        input = router
        imeWanted = false
        _ = ptb_window_ime_set(UnsafeMutableRawPointer(hwnd), 0)   // D6: no IME context on the scene, so a Hangul-mode key stays a key
        register(made)
        WinCaptionColour.update(hwnd)   // Windows 11, no high contrast: the plaza's teal title bar; otherwise the system look
        let panels = WinPlazaPanels(hud: overlays.hud)
        self.panels = panels
        tooltips = WinPlazaTooltips(owner: hwnd)
        if let chat = overlays.chatInput as? WinPlazaChatInput, chat.attach(parent: hwnd) {
            self.chat = chat
            chat.onChange = { [weak self, weak chat] in
                // The chat log sits above the bar's real height (the grid unfolded makes it taller), as the Mac follows the bar's frame.
                if let h = chat?.barFrame?.height { self?.panels?.chatBarHeight = h }
                self?.panelsChanged()
            }
            chat.onCloseWindow = { [weak self] in self?.requestClose() }
        } else {
            chat = nil
            AppLog.write("plaza window: no chat field (\(type(of: overlays.chatInput))); Enter opens nothing that can be typed into")
        }
        let chatInput = chat
        router.onMouse = { [weak panels, weak chatInput] e in (chatInput?.mouse(e) ?? false) || (panels?.mouse(e) ?? false) }
        // A press on a panel or on the chat bar leaves the keyboard where it is (in the chat field), as the Mac's panel views do.
        router.takesFocus = { [weak panels, weak chatInput] p in !(chatInput?.takes(p) ?? false) && panels?.host(at: p) == nil }
        router.tracksMouse = { [weak panels] p in panels?.tracks(p) ?? false }
        panels.onChange = { [weak self] in self?.panelsChanged() }
        panels.applyScrollers(alwaysVisible: WinPlazaPanels.alwaysShowScrollbars())
        contentHeight = 0
        layoutForClient()   // reports the content height once: what `restoreFrame` does on the Mac (the roster's page size)
        panels.setHidden(isHUDHidden)
        panels.setChatLogAbove(isChatLogAboveInput)
        panels.attach()     // every visible panel renders once, before the first frame
        visibility = WinPlazaVisibility(hookMessage: Self.hookMessage)
        visibility.onChange = { [weak self] visible in
            self?.chat?.hud.isRendering = visible
            self?.events?.setRendering(visible: visible)
        }
        visibility.start(window: hwnd, displaysAsleep: systemEvents?.displaysAreAsleep ?? false)
        WinPlazaLive.current = self
        AppLog.write("plaza window open: adapter='\(device.adapter)' warp=\(device.isWarp) clock=\(clock.map { "\($0.source)" } ?? "none") "
            + "dpi=\(dpi) client=\(pw)x\(ph) placement=\(place.restored ? "restored" : "centred")\(place.maximized ? " maximized" : "")")
    }

    func bringToFront() {
        guard let window else { return }
        let hwnd = window.hwnd
        if !visibility.shown {
            drawFrame(waitMs: 50)   // the first frame is in the swap chain before the window appears
            if allowActivation {
                _ = ShowWindow(hwnd, showMaximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL)
            } else {
                _ = ShowWindow(hwnd, showMaximized ? SW_SHOWMAXIMIZED : 4 /* SW_SHOWNOACTIVATE */)
            }
            stats.shows += 1
            view?.isShown = true
            visibility.setShown(true)
            noteNormalRect()
        } else if IsIconic(hwnd) {
            _ = ShowWindow(hwnd, SW_RESTORE)
        }
        if allowActivation {
            _ = SetForegroundWindow(hwnd)
            stats.activations += 1
        }
    }

    func requestClose() {
        guard let window else { return }
        _ = SendMessageW(window.hwnd, Msg.close, 0, 0)   // handleClose runs before this returns, as `performClose`
    }

    func stopPresenting() {
        stage?.onPauseChange = nil
        stage = nil
        view?.update()
    }

    func dismantle() {
        guard let window else { return }
        savePlacement()
        input?.releaseAll()
        input = nil
        visibility.stop()
        stage?.onPauseChange = nil
        stage = nil
        let joined = view?.stop() ?? true
        view = nil
        tooltips?.destroy()
        tooltips = nil
        chat?.detach()
        chat = nil
        panels?.detach()
        panels = nil
        renderer = nil
        surface = nil
        device = nil
        lastClosed = (stats, joined)
        if WinPlazaLive.current === self { WinPlazaLive.current = nil }
        self.window = nil
        WinCaptionColour.forget(window.hwnd)
        window.destroy()
        AppLog.write("plaza window closed: ticks=\(stats.ticks) draws=\(stats.draws) presents=\(stats.presents) clean=\(stats.cleanTicks) "
            + "gpuBusy=\(stats.gpuBusy) losses=\(stats.deviceLosses) clockJoined=\(joined)")
    }

    func setTitle(_ title: String) {
        guard let window else { return }
        _ = SetWindowTextW(window.hwnd, WinStr.w(title))
    }

    /// The desktop shows through the client area (a transparent clear); the frame and its shadow stay (open question 6).
    func setTransparent(_ transparent: Bool) {
        guard transparent != self.transparent else { return }
        self.transparent = transparent
        stage?.setNeedsDraw()
    }

    /// Photo mode: the panels the Mac hides are neither drawn nor hit (the flag is kept for a window opened later).
    func setHUDHidden(_ hidden: Bool) {
        isHUDHidden = hidden
        panels?.setHidden(hidden)
    }

    /// The IME on the scene window: off while the scene has the keyboard; Task 11 turns it on for the chat field's focus.
    func setIMEEnabled(_ on: Bool) {
        guard let hwnd = window?.hwnd else { return }
        imeWanted = on
        _ = ptb_window_ime_set(UnsafeMutableRawPointer(hwnd), on ? 1 : 0)
    }

    var imeHasContext: Bool { window.map { ptb_window_ime_has_context(UnsafeMutableRawPointer($0.hwnd)) == 1 } ?? false }

    private func reassertIME() {
        guard !imeWanted, let hwnd = window?.hwnd, ptb_window_ime_has_context(UnsafeMutableRawPointer(hwnd)) == 1 else { return }
        _ = ptb_window_ime_set(UnsafeMutableRawPointer(hwnd), 0)
    }

    func focusScene() {
        guard let window, isFrontmost, GetFocus() != window.hwnd else { return }
        _ = SetFocus(window.hwnd)
    }

    func focusChatInput() {
        guard window != nil else { return }
        if chat?.focus() == true { return }
        guard !loggedChat else { return }
        loggedChat = true
        AppLog.write("plaza window: no chat field to focus; the keys stay with the scene")
    }

    func setChatLogAboveInput(_ above: Bool) {
        isChatLogAboveInput = above
        panels?.setChatLogAbove(above)
    }

    var isFrontmost: Bool { window.map { GetForegroundWindow() == $0.hwnd } ?? false }
    /// Windows keeps drawing while the window is resized (the tick is a posted message the modal loop dispatches; D4).
    var isInLiveResize: Bool { false }
    var renderLoop: (any PlazaPausableView)? { view }
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) {
        guard window != nil else { return (nil, nil) }
        return (visibility.visible, isFrontmost)
    }

    // MARK: what the selftest reads

    var hwndForTesting: HWND? { window?.hwnd }
    var stageForTesting: WinPlazaStage? { stage }
    var viewForTesting: WinPlazaView? { view }
    var deviceForTesting: WinGfxDevice? { device }
    var surfaceForTesting: WinGfxSurface? { surface }
    var rendererStatsForTesting: WinRenderStats? { renderer?.stats }
    var panelsForTesting: WinPlazaPanels? { panels }
    var chatForTesting: WinPlazaChatInput? { chat }
    var tooltipsForTesting: WinPlazaTooltips? { tooltips }
    var clockStatsForTesting: PTBClockStats? { view?.clock?.stats() }
    var dpiForTesting: UInt32 { dpi }
    func frameRGBAForTesting() -> [UInt8]? { surface?.readRGBA() }
    /// Draws now if anything changed (the selftest's synchronous frame).
    func drawForTesting(waitMs: UInt32 = 50) { drawFrame(waitMs: waitMs) }

    /// `PTB_PLAZA_CLOCK=timer`: the timer even where a vblank is available (QA only; not a usage location).
    nonisolated static var environmentForcesTimer: Bool {
        let environment = ProcessInfo.processInfo.environment   // as WinGfxDevice reads PTB_PLAZA_DEVICE
        return environment["PTB_PLAZA_CLOCK"]?.lowercased() == "timer"
    }

    // MARK: messages

    private func register(_ w: WinSinkWindow) {
        w.on(Self.frameMessage) { [weak self] _, _ in self?.tick(); return 0 }
        w.on(Self.hookMessage) { [weak self] wParam, _ in self?.visibility.hookEvent(UInt32(truncatingIfNeeded: wParam)); return 0 }
        w.on(Msg.close) { [weak self] _, _ in
            guard let self else { return nil }
            if let events { events.handleClose() } else { dismantle() }
            return 0
        }
        // A theme or high-contrast change: the colours are set again or taken off. Never consumed.
        for message: UINT in [0x001A /* WM_SETTINGCHANGE */, 0x031A /* WM_THEMECHANGED */] {
            w.on(message) { [weak self] _, _ in
                if let hwnd = self?.window?.hwnd { WinCaptionColour.update(hwnd) }
                return nil
            }
        }
        w.on(Msg.paint) { [weak self] _, _ in
            guard let self, let hwnd = window?.hwnd else { return nil }
            var ps = PAINTSTRUCT()
            _ = BeginPaint(hwnd, &ps)   // validates: an unvalidated WM_PAINT comes back at once, forever
            _ = EndPaint(hwnd, &ps)
            stats.paints += 1
            return 0
        }
        w.on(Msg.eraseBackground) { _, _ in 1 }
        w.on(Msg.setCursor) { [weak self] wParam, lParam in
            // Only over the plaza's own client area: the chat field (a child) asks its parent first and keeps its I-beam.
            guard lParam & 0xFFFF == 1 /* HTCLIENT */, let hwnd = self?.window?.hwnd, wParam == WPARAM(UInt(bitPattern: Int(bitPattern: hwnd))) else { return nil }
            _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDC_ARROW */)))
            return 1
        }
        w.on(Msg.minMax) { [weak self] _, lParam in
            guard let self, let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) else { return nil }
            let size = minTrackSize(dpi: dpi)
            info.pointee.ptMinTrackSize = POINT(x: size.width, y: size.height)
            return 0
        }
        w.on(Msg.size) { [weak self] wParam, _ in
            guard let self else { return nil }
            if wParam == WPARAM(SIZE_MINIMIZED) {
                input?.releaseAll()
                visibility.setMinimized(true)
                return 0
            }
            visibility.setMinimized(false)
            stats.resizes += 1
            layoutForClient()
            drawFrame(waitMs: 17)   // the new size now, so a live resize shows no stale or empty frame (at most one frame's wait)
            noteNormalRect()
            return 0
        }
        w.on(Msg.dpiChanged) { [weak self] wParam, lParam in
            guard let self, let hwnd = window?.hwnd else { return nil }
            dpi = UInt32(wParam & 0xFFFF)
            stats.dpiChanges += 1
            if let r = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                _ = SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            layoutForClient()   // also when the suggested rect left the pixel size unchanged: the points changed
            drawFrame(waitMs: 17)
            followMonitor()
            return 0
        }
        w.on(WinModalPump.enterSizeMove) { [weak self] _, _ in
            self?.input?.releaseAll()   // the move/size loop swallows key-ups
            WinModalPump.begin("sizemove")
            return nil
        }
        w.on(WinModalPump.exitSizeMove) { [weak self] _, _ in
            WinModalPump.end("sizemove")
            self?.savePlacement()
            return nil
        }
        w.on(Msg.activate) { [weak self] wParam, lParam in
            guard let self else { return nil }
            if wParam & 0xFFFF == 0 /* WA_INACTIVE */ {
                let other = HWND(bitPattern: Int(lParam))
                let ours = other.map { GetAncestor($0, UINT(GA_ROOTOWNER)) == window?.hwnd } ?? false
                if !ours {
                    input?.releaseAll()
                    stats.resigns += 1
                    events?.didResignKey()
                }
            } else {
                panels?.applyScrollers(alwaysVisible: WinPlazaPanels.alwaysShowScrollbars())   // a change made while another window was active
                events?.didBecomeKey()
                // Active again with the chat line open: the keyboard goes back to the field (DefWindowProc would give it to the
                // scene, and the next letters would be emotes), as AppKit restores the key window's first responder.
                if (wParam >> 16) & 0xFFFF == 0, chat?.restoreFocus() == true {
                    visibility.checkCoverNow()
                    return 0
                }
            }
            visibility.checkCoverNow()
            return nil
        }
        // The first click into the inactive window while the chat line is open only activates it (AppKit's default for the
        // views under it, `acceptsFirstMouse` false), so the line is not closed by the click that brings the plaza back. A click
        // on the field itself, the frame or the caption activates as usual.
        w.on(Self.mouseActivate) { [weak self] _, lParam in
            guard let self, let chat, chat.isOpen, lParam & 0xFFFF == 1 /* HTCLIENT */, let hwnd = window?.hwnd else { return nil }
            var p = POINT()
            guard GetCursorPos(&p), ScreenToClient(hwnd, &p), !chat.fieldContains(pixel: p) else { return nil }
            return 2   // MA_ACTIVATEANDEAT
        }
        w.on(Msg.windowPosChanged) { [weak self] _, _ in
            guard let self else { return nil }
            noteNormalRect()
            followMonitor()
            visibility.checkCoverNow()
            return nil   // DefWindowProc sends WM_SIZE and WM_MOVE from it
        }
        w.on(Msg.displayChange) { [weak self] _, _ in self?.followMonitor(force: true); return nil }
        w.on(0x001A /* WM_SETTINGCHANGE */) { [weak self] _, _ in
            self?.panels?.applyScrollers(alwaysVisible: WinPlazaPanels.alwaysShowScrollbars())   // as the Mac follows its scroller style live
            return nil
        }
        w.on(Msg.session) { [weak self] wParam, _ in
            if wParam == 7 || wParam == 2 || wParam == 4 { self?.input?.releaseAll() }   // lock, console / remote disconnect
            self?.visibility.sessionChanged(Int(wParam))
            return 0
        }
        w.on(Msg.timer) { [weak self] wParam, _ in
            guard wParam == WPARAM(WinPlazaVisibility.coverTimerID) else { return nil }
            self?.visibility.checkCoverNow()
            return 0
        }
        for message in Self.inputMessages {
            w.on(message) { [weak self] wParam, lParam in
                guard let self else { return nil }
                if message >= 0x0200 && message <= 0x0208 { tooltips?.relay(message, wParam, lParam) }   // the control times its rest delay
                return inputHandler?(message, wParam, lParam) ?? input?.handle(message, wParam, lParam)
            }
        }
    }

    /// One frame of the clock: the scene's update, then a draw and a present when something changed (D3, D4).
    private func tick() {
        view?.clock?.ack()
        stats.ticks += 1
        guard let stage, let view, view.isRunning else { return }
        stage.tick(at: WinPlazaClock.seconds())
        panels?.frame()
        drawFrame(waitMs: 0)
    }

    private func drawFrame(waitMs: UInt32) {
        guard let stage, let renderer, let surface, let device else { return }
        guard surface.acquireFrame(waitMs: waitMs) else {
            stats.gpuBusy += 1   // the frame stays dirty; the next tick draws it
            return
        }
        let t0 = WinPlazaClock.seconds()
        switch renderer.drawIfNeeded(stage: stage, panels: (panels?.drawList ?? []) + (chat?.drawList ?? []), transparent: transparent) {
        case .clean:
            stats.cleanTicks += 1
        case .gpuBusy:
            stats.gpuBusy += 1
        case .deviceLost:
            stats.deviceLosses += 1   // rebuilt by the renderer; the frame stays dirty
        case .drawn:
            stats.draws += 1
            let t1 = WinPlazaClock.seconds()
            let code = surface.present()
            stats.lastDrawMs = (t1 - t0) * 1000
            stats.lastPresentMs = (WinPlazaClock.seconds() - t1) * 1000
            if code >= 0 {
                stats.presents += 1
            } else if Self.isDeviceLoss(code) {
                stats.deviceLosses += 1
                _ = device.recreateAfterLoss(at: WinPlazaClock.seconds())
                stage.setNeedsDraw()
            } else {
                stats.presentFailures += 1
                stage.setNeedsDraw()
                if !loggedPresentFailure {
                    loggedPresentFailure = true
                    AppLog.write("plaza window: present failed: \(WinPlazaCodecs.lastError()) (logged once)")
                }
            }
        }
    }

    static func isDeviceLoss(_ code: Int32) -> Bool {
        [0x887A_0005, 0x887A_0006, 0x887A_0007, 0x8899_000C].map { Int32(bitPattern: UInt32($0)) }.contains(code)
    }

    /// The client area's pixels → the surface, the stage's size in points, the backing scale and the HUD's viewport.
    private func layoutForClient() {
        guard let hwnd = window?.hwnd, let stage else { return }
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let w = Int(client.right - client.left), h = Int(client.bottom - client.top)
        guard w > 0, h > 0 else { return }
        surface?.resize(width: w, height: h)
        let scale = CGFloat(dpi) / 96
        let size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        stage.setBackingScale(scale)
        stage.size = size
        stage.setNeedsDraw()
        panels?.report(size: size, scale: scale)
        chat?.report(size: size, scale: scale)
        updateTooltips()
        if size.height != contentHeight {
            contentHeight = size.height
            events?.contentHeightDidChange(size.height)
        }
    }

    /// A panel's drawing, frame or visibility changed: the frame is drawn again and the tooltip tools follow.
    private func panelsChanged() {
        stage?.setNeedsDraw()
        updateTooltips()
    }

    /// The shown panels' hover texts as tools in client pixels (replaced only when the list differs).
    private func updateTooltips() {
        guard let tooltips, let panels else { return }
        let scale = CGFloat(dpi) / 96
        tooltips.set(((chat?.tips ?? []) + panels.tips).map { tip in
            WinPlazaTooltips.Tip(rect: [Int32(tip.frame.minX * scale), Int32(tip.frame.minY * scale),
                                        Int32((tip.frame.maxX * scale).rounded(.up)), Int32((tip.frame.maxY * scale).rounded(.up))],
                                 text: tip.text)
        })
    }

    private func followMonitor(force: Bool = false) {
        guard let hwnd = window?.hwnd else { return }
        let now = MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST))
        guard force || now != monitor else { return }
        monitor = now
        view?.clock?.setMonitor(now, forceTimer: Self.environmentForcesTimer)
    }

    func minTrackSize(dpi: UInt32) -> (width: Int32, height: Int32) {
        let scale = Double(dpi) / 96
        let min = PlazaWindowController.minContentSize
        let f = Self.frame(dpi, Int32((Double(min.width) * scale).rounded(.up)), Int32((Double(min.height) * scale).rounded(.up)))
        return (f.width, f.height)
    }

    static let frame = WinPlazaPlacement.frame(style: style, exStyle: exStyle)

    // MARK: placement

    private func noteNormalRect() {
        guard let hwnd = window?.hwnd, visibility.shown, !IsIconic(hwnd), !IsZoomed(hwnd) else { return }
        var r = RECT()
        guard GetWindowRect(hwnd, &r) else { return }
        lastNormal = (WinPlazaPlacement.Rect(left: r.left, top: r.top, right: r.right, bottom: r.bottom), dpi)
    }

    private func savePlacement() {
        guard let hwnd = window?.hwnd, visibility.shown, let normal = lastNormal else { return }
        let f = Self.frame(normal.dpi, 0, 0)
        let scale = Double(normal.dpi) / 96
        let monitor = WinPlazaPlacement.monitors().max { $0.work.intersectionArea(normal.rect) < $1.work.intersectionArea(normal.rect) }
        let saved = WinPlazaPlacement.Saved(left: normal.rect.left, top: normal.rect.top,
                                            contentWidth: Double(normal.rect.width - f.width) / scale,
                                            contentHeight: Double(normal.rect.height - f.height) / scale,
                                            maximized: IsZoomed(hwnd), monitor: monitor?.name ?? "")
        WinPlazaPlacement.save(saved, to: defaults, key: placementKey)
    }

    // MARK: -

    /// No window: the plaza stays closed and says why once in the log (never a black window that looks alive). The
    /// controller has already counted the window as open, so the close is reported on the next turn.
    private func fail(_ why: String) {
        openFailure = why
        AppLog.write("plaza window: not opened: \(why)")
        DispatchQueue.main.async { [weak self] in
            guard let self, window == nil else { return }
            events?.handleClose()
        }
    }

    /// The display-state change from `WindowsSystemEvents` (WinPlazaLive forwards it to the open window).
    func displaysChanged(asleep: Bool) { visibility.displaysChanged(asleep: asleep) }

    /// The stats line for the log (the app's exit, the idle helper).
    var statsLine: String {
        let c = view?.clock?.stats()
        return "ticks=\(stats.ticks) draws=\(stats.draws) presents=\(stats.presents) clean=\(stats.cleanTicks) gpuBusy=\(stats.gpuBusy) "
            + "visible=\(visibility.visible) coverChecks=\(visibility.coverChecks) clock=\(c.map { "source \($0.source) posted \($0.posted) parks \($0.parks)" } ?? "none")"
    }
}
#endif
