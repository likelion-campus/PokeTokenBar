#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Stage 6 Task 6: the plaza window's keyboard and mouse with input the way the OS delivers it. On CI the keys are
/// `SendInput(KEYEVENTF_SCANCODE)` to the foreground plaza window (real scan codes, real `GetKeyState`); the mouse is
/// synthetic `SendMessage` (the DPI cases need a window that believes it is at 125-200 %) plus one real
/// `SendInput` press that is dragged out of the window. On a person's PC nothing is injected (their keyboard is theirs).
extension WindowsSelftest {
    private static let scanShift: UInt32 = 0x2A, scanControl: UInt32 = 0x1D, scanAlt: UInt32 = 0x38

    private static func sendScan(_ scan: UInt32, extended: Bool = false, up: Bool) {
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki.wScan = WORD(scan)
        input.ki.dwFlags = DWORD(KEYEVENTF_SCANCODE) | (extended ? DWORD(KEYEVENTF_EXTENDEDKEY) : 0) | (up ? DWORD(KEYEVENTF_KEYUP) : 0)
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.stride))
    }

    private static func sendMouse(_ flags: Int32) {
        var input = INPUT()
        input.type = DWORD(INPUT_MOUSE)
        input.mi.dwFlags = DWORD(flags)
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.stride))
    }

    private static func pumpFor(_ seconds: TimeInterval) async { _ = await waitUntil(timeout: seconds) { false } }

    private static func key(_ code: UInt16, down: Bool) {
        guard let k = WinPlazaInput.scanCode(forMacKeyCode: code) else { return }
        sendScan(k.scan, extended: k.extended, up: !down)
    }

    private static func tap(_ code: UInt16, hold: TimeInterval = 0.04) async {
        key(code, down: true)
        await pumpFor(hold)
        key(code, down: false)
        await pumpFor(0.04)
    }

    private static func dirName(_ code: UInt16) -> String {
        [PlazaKeyCode.left: "left", PlazaKeyCode.right: "right", PlazaKeyCode.up: "up", PlazaKeyCode.down: "down"][code] ?? "\(code)"
    }

    private static func tileText(_ t: TilePoint) -> String { "(\(t.x),\(t.y))" }

    /// plaza.keys, plaza.repeat, plaza.walk, plaza.altAlone, plaza.altGr, plaza.resignReleasesKeys, plaza.imeOff, plaza.click.
    @MainActor static func plazaInputChecks(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND, scene: PlazaScene) async {
        guard let router = shell.input else {
            r.add("plaza.keys", false, "the window has no input router")
            return
        }
        if onCI {
            forceForeground(hwnd)
            _ = SetFocus(hwnd)
            await pumpFor(0.2)
        }
        await plazaImeCheck(r, shell, hwnd, router)
        await plazaMouseChecks(r, shell, hwnd, router)
        guard onCI else {
            r.add("plaza.keys", true, "skipped: real keys are injected on CI only (a person's own keyboard is not touched); the PC checklist has them")
            return
        }
        let other: WinSinkWindow? = try? WinSinkWindow(className: "PokeTokenBarSelftestFocus", title: "focus", style: 0x10CF_0000, exStyle: 0,
                                                        x: 700, y: 60, width: 300, height: 200)
        defer { other?.destroy() }
        scene.applyMembers([])
        forceForeground(hwnd)
        _ = SetFocus(hwnd)
        await pumpFor(0.3)
        let foreground = GetForegroundWindow() == hwnd && GetFocus() == hwnd
        defer {   // never leave a modifier down on the runner
            for s in [scanShift, scanControl] { sendScan(s, up: true) }
            sendScan(scanAlt, up: true)
            sendScan(scanAlt, extended: true, up: true)
        }

        // plaza.keys: every key the Mac scene names reaches the shared input once, by position, with its modifiers.
        var downs: [PlazaKeyEvent] = [], ups: [UInt16] = []
        router.forwardToStage = false
        router.keyObserver = { downs.append($0) }
        router.keyUpObserver = { ups.append($0) }
        let keys: [UInt16] = [PlazaKeyCode.a, PlazaKeyCode.d, PlazaKeyCode.f, PlazaKeyCode.g, PlazaKeyCode.z, PlazaKeyCode.x, PlazaKeyCode.c,
                              PlazaKeyCode.v, PlazaKeyCode.w, PlazaKeyCode.one, PlazaKeyCode.two, PlazaKeyCode.three, PlazaKeyCode.four,
                              PlazaKeyCode.five, PlazaKeyCode.p, PlazaKeyCode.returnKey, PlazaKeyCode.space, PlazaKeyCode.escape,
                              PlazaKeyCode.keypadEnter, PlazaKeyCode.left, PlazaKeyCode.right, PlazaKeyCode.down, PlazaKeyCode.up, 27, 24]
        for k in keys { await tap(k) }
        let plainChars = downs.suffix(2).map { $0.characters ?? "nil" }   // "-" and "="
        key(24, down: false)
        sendScan(scanShift, up: false)
        await pumpFor(0.04)
        await tap(24)   // Shift + "=" is "+" on a US layout
        sendScan(scanShift, up: true)
        await pumpFor(0.04)
        let plus = downs.last
        let got = downs.prefix(keys.count).map { $0.keyCode }
        let noRepeat = downs.allSatisfy { !$0.isRepeat }
        let plainMods = downs.prefix(keys.count).allSatisfy { $0.modifiers.isEmpty }
        r.add("plaza.keys", got == keys && Array(ups.prefix(keys.count)) == keys && noRepeat && plainMods && plainChars == ["-", "="]
                && plus?.characters == "+" && plus?.modifiers == [.shift] && foreground,
              "foreground+focus=\(foreground); SendInput scan codes down/up for \(keys.count) keys, each once in order: got=\(got == keys) ups=\(Array(ups.prefix(keys.count)) == keys) "
                + "no repeat flag=\(noRepeat) no modifiers=\(plainMods); '-' '=' characters \(plainChars) (US layout), Shift+'=' -> '\(plus?.characters ?? "nil")' mods=\(String(describing: plus?.modifiers.rawValue))")

        // plaza.repeat: bit 30 of lParam is the shared isRepeat (synthetic: one press and three auto-repeats), and a real held key.
        downs.removeAll()
        let rightScan = WinPlazaInput.scanCode(forMacKeyCode: PlazaKeyCode.right) ?? (0x4D, true)
        let base = LPARAM((Int(rightScan.scan) << 16) | (1 << 24) | 1)
        _ = SendMessageW(hwnd, 0x0100, 0x27, base)
        for _ in 0..<3 { _ = SendMessageW(hwnd, 0x0100, 0x27, base | LPARAM(1 << 30)) }
        _ = SendMessageW(hwnd, 0x0101, 0x27, base | LPARAM(1 << 30) | LPARAM(Int(truncatingIfNeeded: UInt32(1) << 31)))
        let synthetic = downs.map { $0.isRepeat }
        downs.removeAll()
        key(PlazaKeyCode.right, down: true)
        await pumpFor(0.9)
        key(PlazaKeyCode.right, down: false)
        await pumpFor(0.1)
        let real = downs.map { $0.isRepeat }
        let realOK = real.first == false && real.dropFirst().allSatisfy { $0 }
        r.add("plaza.repeat", synthetic == [false, true, true, true] && realOK && router.held.isEmpty,
              "synthetic WM_KEYDOWN press + 3 repeats -> isRepeat \(synthetic); a real held Right arrow 0.9 s: \(real.count) key-downs (first not a repeat, the rest repeats: \(realOK)); "
                + "held set after release \(router.held.sorted())")

        // plaza.walk: arrows walk (a tap is one tile), W/S do not (the Mac scene walks on arrows only), Shift runs, two keys at once.
        router.forwardToStage = true
        router.keyObserver = nil
        router.keyUpObserver = nil
        await pumpFor(0.3)
        func settle() async { _ = await waitUntil(timeout: 1.5) { !scene.walker.isWalking && !scene.walker.hasPendingMove } }
        func tapMove(_ code: UInt16) async -> (dx: Int, dy: Int) {
            let t0 = scene.walker.tile
            await tap(code)
            await pumpFor(0.05)
            await settle()
            let t1 = scene.walker.tile
            return (t1.x - t0.x, t1.y - t0.y)
        }
        let start = scene.walker.tile
        func capture(_ name: String) -> String {
            shell.drawForTesting()
            guard let rgba = shell.frameRGBAForTesting(), let ws = shell.surfaceForTesting?.windowStats else { return "no frame" }
            return "\(name) written=\(writeFrame(rgba, Int(ws.bufferWidth), Int(ws.bufferHeight), name))"
        }
        let beforeShot = capture("plaza-input-before.png")
        var log: [String] = []
        // horizontal pair, vertical pair: the first tap may meet an obstacle, then the pair is walked from the other side
        var free: [UInt16: Bool] = [:]
        var pairsOK = true
        for (a, b, horizontal) in [(PlazaKeyCode.right, PlazaKeyCode.left, true), (PlazaKeyCode.down, PlazaKeyCode.up, false)] {
            var da = await tapMove(a)
            var db: (dx: Int, dy: Int)
            if da.dx == 0 && da.dy == 0 {
                db = await tapMove(b)
                da = await tapMove(a)
                free[b] = db.dx != 0 || db.dy != 0
                pairsOK = pairsOK && (db.dx != 0 || db.dy != 0) && da.dx == -db.dx && da.dy == -db.dy
            } else {
                db = await tapMove(b)
                free[a] = true
                pairsOK = pairsOK && db.dx == -da.dx && db.dy == -da.dy
            }
            let axisOK = horizontal ? (abs(da.dx) + abs(db.dx) > 0 && da.dy == 0 && db.dy == 0) : (abs(da.dy) + abs(db.dy) > 0 && da.dx == 0 && db.dx == 0)
            pairsOK = pairsOK && axisOK && max(abs(da.dx), abs(da.dy)) <= 1 && max(abs(db.dx), abs(db.dy)) <= 1
            log.append("\(dirName(a)) \(da) then \(dirName(b)) \(db)")
        }
        let afterPairs = scene.walker.tile
        for code in [PlazaKeyCode.w, 1 /* S */] as [UInt16] { await tap(code) }
        await pumpFor(0.4)
        let wsNoWalk = scene.walker.tile == afterPairs
        // The place has changed since the taps: which way is open here is asked again before each use.
        func openDirection(_ a: UInt16, _ b: UInt16) async -> UInt16 {
            let m = await tapMove(a)
            if m.dx != 0 || m.dy != 0 {
                _ = await tapMove(b)
                return a
            }
            return b
        }
        var hDir = await openDirection(PlazaKeyCode.right, PlazaKeyCode.left)
        var vDir = await openDirection(PlazaKeyCode.down, PlazaKeyCode.up)
        _ = free
        // Shift runs: the walker runs while Shift and the arrow are held, and not without Shift.
        var walkedRunning = false
        key(hDir, down: true)
        for _ in 0..<5 { await pumpFor(0.1); walkedRunning = walkedRunning || scene.walker.isRunning }
        key(hDir, down: false)
        await pumpFor(0.1); await settle()
        sendScan(scanShift, up: false)
        await pumpFor(0.06)
        var ranRunning = false
        key(vDir, down: true)
        for _ in 0..<5 { await pumpFor(0.1); ranRunning = ranRunning || scene.walker.isRunning }
        key(vDir, down: false)
        sendScan(scanShift, up: true)
        await pumpFor(0.1); await settle()
        // Two arrows at once (rollover): the last pressed leads, the earlier one takes over when it is let go.
        hDir = await openDirection(PlazaKeyCode.right, PlazaKeyCode.left)
        vDir = await openDirection(PlazaKeyCode.down, PlazaKeyCode.up)
        let beforeBoth = scene.walker.tile
        key(hDir, down: true)
        key(vDir, down: true)
        await pumpFor(0.1)
        let heldBoth = router.held == [hDir, vDir]
        await pumpFor(0.4)
        let leading = scene.walker.tile
        key(vDir, down: false)
        await pumpFor(0.5)
        let after = scene.walker.tile
        let stillHolding = router.held == [hDir] && scene.walker.isHoldingKey
        key(hDir, down: false)
        await pumpFor(0.1); await settle()
        let leadMoved = leading.y != beforeBoth.y && leading.x == beforeBoth.x
        let followed = after.x != leading.x || stillHolding   // the open way may end at a wall: the earlier key stays held either way
        let afterShot = capture("plaza-input-after.png")
        r.add("plaza.walk", pairsOK && wsNoWalk && !walkedRunning && ranRunning && heldBoth && leadMoved && followed && foreground,
              "start \(tileText(start)); taps: \(log.joined(separator: "; ")); W and S taps walked nothing=\(wsNoWalk) (A is prayer and D dance on the Mac; only arrows walk); "
                + "running while holding \(dirName(hDir)) without Shift=\(walkedRunning), with Shift on \(dirName(vDir))=\(ranRunning); "
                + "\(dirName(hDir))+\(dirName(vDir)) both held=\(heldBoth) (\(router.held.sorted())): the last leads \(tileText(beforeBoth))->\(tileText(leading)) (moved=\(leadMoved)), "
                + "then \(dirName(hDir)) alone \(tileText(leading))->\(tileText(after)) (followed=\(followed)); frames \(beforeShot) at \(tileText(start)), \(afterShot) at \(tileText(scene.walker.tile))")

        // plaza.altAlone: a lone Alt press must not put the window in menu mode (the next key would go to the system menu).
        var gui = GUITHREADINFO()
        gui.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        sendScan(scanAlt, up: false)
        await pumpFor(0.05)
        sendScan(scanAlt, up: true)
        await pumpFor(0.15)
        _ = GetGUIThreadInfo(GetCurrentThreadId(), &gui)
        let menuFlags = gui.flags & 0xC   // GUI_INMENUMODE | GUI_SYSTEMMENUMODE
        hDir = await openDirection(PlazaKeyCode.right, PlazaKeyCode.left)
        let t0 = scene.walker.tile
        await tap(hDir)
        await pumpFor(0.05)
        await settle()
        let moved = scene.walker.tile != t0
        // Alt+arrow: the key still walks (Alt is ⌥ and does not block walking on the Mac), through WM_SYSKEYDOWN.
        sendScan(scanAlt, up: false)
        await pumpFor(0.03)
        let t1 = scene.walker.tile
        let back: UInt16 = hDir == PlazaKeyCode.right ? PlazaKeyCode.left : PlazaKeyCode.right
        await tap(back)
        await pumpFor(0.05)
        await settle()
        sendScan(scanAlt, up: true)
        await pumpFor(0.1)
        let altArrow = scene.walker.tile != t1
        r.add("plaza.altAlone", menuFlags == 0 && moved && altArrow,
              "Alt press and release: menu mode flags=\(menuFlags); the next \(dirName(hDir)) tap moved=\(moved) \(tileText(t0))->\(tileText(scene.walker.tile)); Alt held + arrow walks=\(altArrow)")
        await pumpFor(0.2)

        // plaza.altGr: left Ctrl + right Alt (what AltGr sends) is not the Ctrl chord: W does not close the plaza.
        downs.removeAll()
        router.keyObserver = { downs.append($0) }
        sendScan(scanControl, up: false)
        sendScan(scanAlt, extended: true, up: false)
        await pumpFor(0.05)
        await tap(PlazaKeyCode.w)
        sendScan(scanAlt, extended: true, up: true)
        sendScan(scanControl, up: true)
        await pumpFor(0.2)
        router.keyObserver = nil
        let stillOpen = shell.hwndForTesting == hwnd
        let wEvent = downs.first { $0.keyCode == PlazaKeyCode.w }
        r.add("plaza.altGr", stillOpen && wEvent?.modifiers == [.option],
              "LCtrl + RAlt + W: window still open=\(stillOpen), W reached the scene with modifiers \(String(describing: wEvent?.modifiers.rawValue)) (expected only option = \(PlazaModifiers.option.rawValue); Ctrl+W alone closes, plaza.ctrlW)")

        // plaza.resignReleasesKeys: another window takes the foreground while an arrow is down.
        key(hDir, down: true)
        await pumpFor(0.25)
        let heldBefore = scene.walker.isHoldingKey && router.held.contains(hDir)
        let releases0 = router.counts.releases
        var upsSeen: [UInt16] = []
        router.keyUpObserver = { upsSeen.append($0) }
        if let other { forceForeground(other.hwnd) }
        await pumpFor(0.4)
        router.keyUpObserver = nil
        let heldAfter = scene.walker.isHoldingKey
        let stopped = !scene.walker.isWalking
        key(hDir, down: false)
        await pumpFor(0.1)
        forceForeground(hwnd)
        _ = SetFocus(hwnd)
        await pumpFor(0.2)
        r.add("plaza.resignReleasesKeys", heldBefore && !heldAfter && stopped && router.held.isEmpty && router.counts.releases == releases0 + 1 && upsSeen == [hDir],
              "\(dirName(hDir)) held=\(heldBefore); another window activated mid-hold: scene still holds=\(heldAfter) walking stopped=\(stopped), key-ups reported \(upsSeen.map(dirName)), "
                + "releases +\(router.counts.releases - releases0), router held \(router.held.sorted())")
        router.forwardToStage = true
        scene.applyMembers([])
    }

    /// plaza.imeOff: the scene window has no IME context; a key the IME took (VK_PROCESSKEY) is still the key at its position.
    @MainActor private static func plazaImeCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND, _ router: WinPlazaInputRouter) async {
        let raw = UnsafeMutableRawPointer(hwnd)
        let plain: WinSinkWindow? = try? WinSinkWindow(className: "PokeTokenBarSelftestImePlain", title: "ime", style: 0x00CF_0000, exStyle: 0,
                                                        x: 700, y: 300, width: 200, height: 120)
        defer { plain?.destroy() }
        let contrast = plain.map { ptb_window_ime_has_context(UnsafeMutableRawPointer($0.hwnd)) == 1 } ?? false
        let off = !shell.imeHasContext
        shell.setIMEEnabled(true)
        let onAgain = shell.imeHasContext
        shell.setIMEEnabled(false)
        let offAgain = !shell.imeHasContext
        _ = ptb_window_ime_set(raw, 1)   // something gave the context back: the next focus puts it away again
        _ = SendMessageW(hwnd, 0x0007, 0, 0)
        let reasserted = !shell.imeHasContext
        var downs: [PlazaKeyEvent] = []
        router.forwardToStage = false
        router.keyObserver = { downs.append($0) }
        let wBits = LPARAM((0x11 << 16) | 1), aBits = LPARAM((0x1E << 16) | 1)
        _ = SendMessageW(hwnd, 0x0100, 0xE5, wBits)   // VK_PROCESSKEY, scan code of W
        _ = SendMessageW(hwnd, 0x0100, 0x51, aBits)   // the key at A's position on a layout that types Q there
        router.keyObserver = nil
        router.forwardToStage = true
        let processKeyOK = downs.map { $0.keyCode } == [PlazaKeyCode.w, PlazaKeyCode.a]
        r.add("plaza.imeOff", off && offAgain && reasserted && processKeyOK && (!contrast || onAgain == contrast),
              "scene window has no IME context=\(off) (a plain window of the thread has one=\(contrast)); setIMEEnabled(true) -> context=\(onAgain), false -> none=\(offAgain); "
                + "context given back then WM_SETFOCUS -> none again=\(reasserted); VK_PROCESSKEY+W scan and a mismatched VK at A's scan reach the scene as \(downs.map { $0.keyCode }) "
                + "(w=\(PlazaKeyCode.w), a=\(PlazaKeyCode.a)); IME open status=\(ptb_window_ime_open(raw)) (no Korean IME on the runner: the real Hangul-mode key is on the PC checklist)")
    }

    /// plaza.click: mouse down/up/move/wheel in window points at 96-192 dpi, capture, right/middle ignored, Ctrl+wheel ignored.
    @MainActor private static func plazaMouseChecks(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND, _ router: WinPlazaInputRouter) async {
        var wr = RECT()
        _ = GetWindowRect(hwnd, &wr)
        var events: [PlazaMouseEvent] = []
        router.mouseObserver = { events.append($0) }
        defer { router.mouseObserver = nil }
        var dpiLines: [String] = []
        var dpiOK = true
        for dpi: UInt32 in [96, 120, 144, 192] {
            var rect = wr
            _ = withUnsafeMutablePointer(to: &rect) { SendMessageW(hwnd, 0x02E0, WPARAM(dpi | (dpi << 16)), LPARAM(Int(bitPattern: $0))) }
            await pumpFor(0.1)
            events.removeAll()
            let at = LPARAM((217 << 16) | 333)
            _ = SendMessageW(hwnd, 0x0201, 1, at)
            _ = SendMessageW(hwnd, 0x0202, 0, at)
            _ = SendMessageW(hwnd, 0x0204, 2, at)   // right button: nothing
            _ = SendMessageW(hwnd, 0x0205, 0, at)
            let s = CGFloat(dpi) / 96
            let expect = CGPoint(x: 333 / s, y: 217 / s)
            let ok = events.count == 2 && events[0].kind == .down && events[1].kind == .up
                && events.allSatisfy { abs($0.location.x - expect.x) < 0.001 && abs($0.location.y - expect.y) < 0.001 }
            dpiOK = dpiOK && ok
            dpiLines.append("\(dpi): (333,217) px -> \(events.first.map { "(\($0.location.x),\($0.location.y))" } ?? "none") expected (\(expect.x),\(expect.y)) events \(events.count)")
        }
        var back = wr
        _ = withUnsafeMutablePointer(to: &back) { SendMessageW(hwnd, 0x02E0, WPARAM(96 | (96 << 16)), LPARAM(Int(bitPattern: $0))) }
        await pumpFor(0.2)
        _ = SetWindowPos(hwnd, nil, wr.left, wr.top, wr.right - wr.left, wr.bottom - wr.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        await pumpFor(0.2)

        // wheel: a notch, fractions that add up to a notch, the horizontal wheel, Ctrl+wheel (pinch).
        var origin = POINT(x: 100, y: 100)
        _ = ClientToScreen(hwnd, &origin)
        let screen = LPARAM(Int(UInt32(UInt16(truncatingIfNeeded: origin.y)) << 16 | UInt32(UInt16(truncatingIfNeeded: origin.x))))
        func wheel(_ delta: Int16, _ message: UINT, keys: UInt64 = 0) {
            _ = SendMessageW(hwnd, message, (WPARAM(UInt16(bitPattern: delta)) << 16) | keys, screen)
        }
        let lines = Int(ptb_input_wheel_lines(0)), chars = Int(ptb_input_wheel_lines(1))
        events.removeAll()
        wheel(120, 0x020A)
        let notch = events.last
        events.removeAll()
        for _ in 0..<8 { wheel(15, 0x020A) }
        let fractions = events.reduce(CGFloat(0)) { acc, e in if case .scroll(_, let dy) = e.kind { return acc + dy } else { return acc } }
        events.removeAll()
        wheel(120, 0x020E)
        let horizontal = events.last
        events.removeAll()
        let pinch0 = router.counts.ignoredPinch
        wheel(120, 0x020A, keys: 0x0008)
        let pinchIgnored = events.isEmpty && router.counts.ignoredPinch == pinch0 + 1
        func scroll(_ e: PlazaMouseEvent?) -> (CGFloat, CGFloat, CGPoint)? {
            if let e, case .scroll(let dx, let dy) = e.kind { return (dx, dy, e.location) } else { return nil }
        }
        let n = scroll(notch), h = scroll(horizontal)
        let wheelOK = n?.1 == CGFloat(lines * 10) && n?.0 == 0 && n?.2 == CGPoint(x: 100, y: 100) && fractions == CGFloat(lines * 10)
            && h?.0 == CGFloat(-chars * 10) && h?.1 == 0 && pinchIgnored

        // capture lost while a button is down: the press is cancelled somewhere nothing can be hit.
        events.removeAll()
        _ = SendMessageW(hwnd, 0x0201, 1, LPARAM((50 << 16) | 60))
        _ = ReleaseCapture()   // the window sends itself WM_CAPTURECHANGED, as when another window takes the mouse
        let cancelled = events.count == 2 && events[1].kind == .up && events[1].location == WinPlazaInputRouter.nowhere && GetCapture() != hwnd

        // a real press dragged out of the window still gets its release (capture).
        var real: [PlazaMouseEvent] = []
        var captured = false, capturedOutside = false
        var downAt = POINT(x: 200, y: 150)
        if onCI {
            _ = ClientToScreen(hwnd, &downAt)
            router.mouseObserver = { real.append($0) }
            _ = SetCursorPos(downAt.x, downAt.y)
            await pumpFor(0.1)
            sendMouse(Int32(MOUSEEVENTF_LEFTDOWN))
            await pumpFor(0.1)
            captured = GetCapture() == hwnd
            _ = SetCursorPos(2, 2)
            await pumpFor(0.15)
            capturedOutside = GetCapture() == hwnd
            sendMouse(Int32(MOUSEEVENTF_LEFTUP))
            await pumpFor(0.15)
            router.mouseObserver = { events.append($0) }
        }
        let kinds = real.map { $0.kind }
        let upEvent = real.last { $0.kind == .up }   // the pointer's exit (hover ends) may follow the release
        let realOK = !onCI || (captured && capturedOutside && GetCapture() != hwnd && kinds.first == .down && upEvent != nil
            && (upEvent?.location.x ?? 0) < 0 && real.first?.location == CGPoint(x: 200, y: 150))
        r.add("plaza.click", dpiOK && wheelOK && cancelled && realOK,
              "points at dpi [\(dpiLines.joined(separator: "; "))]; right button ignored; wheel notch dy=\(n?.1 ?? -1) (\(lines) lines x 10), 8 x 15/120 notches sum=\(fractions), "
                + "horizontal dx=\(h?.0 ?? -1) (\(chars) chars, sign flipped), at (\(n?.2.x ?? -1),\(n?.2.y ?? -1)), Ctrl+wheel ignored=\(pinchIgnored); lost capture cancels the press=\(cancelled); "
                + (onCI ? "real press dragged outside: captured=\(captured) still captured outside=\(capturedOutside) events \(kinds.count) first \(kinds.first.map { "\($0)" } ?? "-") last \(kinds.last.map { "\($0)" } ?? "-") up at x=\(upEvent?.location.x ?? 0)"
                        : "real press skipped (not CI)"))
    }

    /// plaza.ctrlW: Ctrl+W closes the plaza through the shared path (the Mac's ⌘W). Reopens it and returns the new window.
    @MainActor static func plazaCtrlWCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND) async -> HWND {
        guard onCI else {
            r.add("plaza.ctrlW", true, "skipped: real keys are injected on CI only")
            return hwnd
        }
        forceForeground(hwnd)
        _ = SetFocus(hwnd)
        await pumpFor(0.3)
        let foreground = GetForegroundWindow() == hwnd
        let closes0 = shell.lastClosed?.stats.ticks
        sendScan(scanControl, up: false)
        await pumpFor(0.05)
        sendScan(0x11, up: false)
        let closed = await waitUntil(timeout: 2) { shell.hwndForTesting == nil }
        sendScan(0x11, up: true)
        sendScan(scanControl, up: true)
        await pumpFor(0.1)
        let reported = shell.lastClosed != nil && (closes0 == nil || shell.lastClosed?.stats.ticks != closes0 || closed)
        c.show()
        _ = await waitUntil(timeout: 3) { shell.stats.presents >= 1 }
        let fresh = shell.hwndForTesting ?? hwnd
        forceForeground(fresh)
        r.add("plaza.ctrlW", closed && reported && foreground,
              "foreground=\(foreground); LCtrl + W (SendInput scan codes) closed the plaza window=\(closed) through the controller (closed event recorded=\(reported)); reopened=\(shell.hwndForTesting != nil)")
        return fresh
    }
}
#endif
