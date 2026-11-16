#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Stage 6 Task 11: the chat line in the plaza window (`plaza.chat*`, `plaza.imeChar`). The field is the real `EDIT` over the
/// composition; characters and IME messages are POSTED to it, so they take the app's real path (CoreFoundation's ANSI pump, the
/// `WH_GETMESSAGE` hook, the field's subclass). Real keys (`SendInput`), the clipboard, the tray menu and a real Korean IME only on
/// CI. What a real IME reports is scripted where none exists (`ChatScript`): its composition string, and on "finish" what IMM does
/// synchronously (the result, the end, the characters).
extension WindowsSelftest {
    @MainActor final class ChatScript {
        var composition = ""
        var finishes: [Bool] = []
        /// Installs the script as the field's IME; `finish` sends what IMM sends when a composition is completed or cancelled.
        func install(on chat: WinPlazaChatInput) {
            chat.ime = .init(composition: { [unowned self] _ in self.composition }, result: { _ in "" }, finish: { [unowned self] h, cancel in
                self.finishes.append(cancel)
                let text = self.composition
                self.composition = ""
                _ = SendMessageW(h, 0x010F, 0, cancel || text.isEmpty ? 0 : 0x800)
                if !cancel { for u in text.utf16 { _ = SendMessageW(h, 0x0102, WPARAM(u), 1) } }   // the committed characters, at once (IMM sends them)
                _ = SendMessageW(h, 0x010E, 0, 0)
            })
        }
    }

    private static func chatPump(_ s: TimeInterval = 0.15) async { _ = await waitUntil(timeout: s) { false } }

    private static func chatPost(_ h: HWND, _ m: UINT, _ w: WPARAM, _ l: LPARAM = 1) { _ = PostMessageW(h, m, w, l) }

    private static func chatPostText(_ h: HWND, _ s: String) { for u in s.utf16 { chatPost(h, 0x0102, WPARAM(u)) } }

    private static func chatScan(_ scan: UInt32, extended: Bool = false, up: Bool) {
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki.wScan = WORD(scan)
        input.ki.dwFlags = DWORD(KEYEVENTF_SCANCODE) | (extended ? DWORD(KEYEVENTF_EXTENDEDKEY) : 0) | (up ? DWORD(KEYEVENTF_KEYUP) : 0)
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.stride))
    }

    private static func chatTap(_ scan: UInt32, extended: Bool = false) async {
        chatScan(scan, extended: extended, up: false)
        await chatPump(0.03)
        chatScan(scan, extended: extended, up: true)
        await chatPump(0.05)
    }

    private static func chatVirtualKey(_ vk: UInt16) async {
        var input = [INPUT(), INPUT()]
        input[0].type = DWORD(INPUT_KEYBOARD)
        input[0].ki.wVk = WORD(vk)
        input[1] = input[0]
        input[1].ki.dwFlags = DWORD(KEYEVENTF_KEYUP)
        _ = SendInput(2, &input, Int32(MemoryLayout<INPUT>.stride))
        await chatPump(0.1)
    }

    /// Text the way the emoji panel and many input tools send it: VK_PACKET, one UTF-16 unit per key (surrogates as two).
    private static func chatUnicode(_ s: String) async {
        for u in s.utf16 {
            var input = [INPUT(), INPUT()]
            input[0].type = DWORD(INPUT_KEYBOARD)
            input[0].ki.wScan = WORD(u)
            input[0].ki.dwFlags = DWORD(KEYEVENTF_UNICODE)
            input[1] = input[0]
            input[1].ki.dwFlags = DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)
            _ = SendInput(2, &input, Int32(MemoryLayout<INPUT>.stride))
            await chatPump(0.01)
        }
        await chatPump(0.15)
    }

    /// The scripted-IME checks can run (no real IME active in this process, or CI where the selftest chose the layout).
    @MainActor private static var scriptedIME = true

    private static func chatPacked(_ x: Int32, _ y: Int32) -> LPARAM { LPARAM((Int(y) << 16) | (Int(x) & 0xFFFF)) }

    /// A click at a window point (points), as messages to the plaza window (the panels' and the bar's path).
    @MainActor private static func chatClick(_ shell: WinPlazaWindow, _ hwnd: HWND, at p: CGPoint) {
        let s = CGFloat(shell.dpiForTesting) / 96
        let l = chatPacked(Int32((p.x * s).rounded()), Int32((p.y * s).rounded()))
        _ = SendMessageW(hwnd, 0x0200, 0, l)
        _ = SendMessageW(hwnd, 0x0201, 1, l)
        _ = SendMessageW(hwnd, 0x0202, 0, l)
    }

    @MainActor private static func chatLogInputHeight(_ shell: WinPlazaWindow) -> CGFloat? {
        (shell.panelsForTesting?.hud.panels.first { $0.id == .chatLog } as? PlazaChatLogPanel)?.inputHeight
    }

    @MainActor private static func chatOpen(_ c: PlazaWindowController, _ chat: WinPlazaChatInput) async {
        if !chat.isOpen { c.scene?.handleKeyDown(keyCode: PlazaKeyCode.returnKey, characters: nil, isRepeat: false) }
        await chatPump(0.15)
    }

    @MainActor private static func chatClose(_ chat: WinPlazaChatInput) async {
        if let e = chat.editHWND, chat.isOpen { chatPost(e, 0x0100, 0x1B) }
        await chatPump(0.15)
        if chat.isOpen { chat.close() }
    }

    private static func q(_ s: String) -> String { "'" + s + "'" }

    /// The screen over the shown bar (and 8 px around it) as a PNG next to the selftest output: the native field over the drawn plate.
    @MainActor @discardableResult
    private static func chatCapture(_ shell: WinPlazaWindow, _ hwnd: HWND, _ chat: WinPlazaChatInput, _ name: String) -> Bool {
        guard let bf = chat.barFrame else { return false }
        let s = CGFloat(shell.dpiForTesting) / 96
        var o = POINT(x: Int32((bf.minX * s).rounded()), y: Int32((bf.minY * s).rounded()))
        _ = ClientToScreen(hwnd, &o)
        guard let shot = WinUIDump.screenshot(x: Int(o.x) - 8, y: Int(o.y) - 8, w: Int((bf.width * s).rounded()) + 16,
                                              h: Int((bf.height * s).rounded()) + 16) else { return false }
        return WinUIDump.write(shot, to: selftestOutDirectory().appendingPathComponent(name)) == 0
    }

    // MARK: - the checks in the live plaza window

    /// Returns the plaza window that is open afterwards (`plaza.chatReopenAfterHidden` closes and reopens it).
    @MainActor static func plazaChatChecks(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                           app: WindowsAppDelegate) async -> HWND {
        guard let chat = shell.chatForTesting, chat.editHWND != nil else {
            r.add("plaza.chatChildVisible", false, "the window has no chat field (the controller's chat input is \(type(of: c.chatInputForTesting)))")
            return hwnd
        }
        shell.input?.forwardToStage = true
        // The scripted IME (synthesized composition messages) must not meet a real one: the native field reads the REAL input context
        // on WM_IME_COMPOSITION, so a real IME's last result would go in too. CI: the US layout for this process (a Korean IME left
        // active for the runner's user by an earlier process is put aside). A person's PC: their input method is theirs, never
        // changed; the scripted checks are skipped while a real IME is active.
        if onCI { _ = ptb_ime_plain_layout() }
        scriptedIME = onCI || ptb_ime_active_is_text_service() != 1
        // Inside the work area: the earlier size checks leave the window as large as the screen, its bottom (where the bar is) under
        // the taskbar, and a screen capture there reads the taskbar.
        let size = WinPlazaWindow.frame(shell.dpiForTesting, 820, 560)
        _ = SetWindowPos(hwnd, nil, 40, 40, size.width, size.height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        if onCI { forceForeground(hwnd); _ = SetFocus(hwnd) }
        await chatPump(0.3)
        await chatVisibleCheck(r, c, shell, hwnd, chat)
        await imeCharCheck(r, c, chat, ansiPump: app.loopStrategy == .cfRunLoopWithMessages)
        await chatOpenCloseCheck(r, c, shell, hwnd, chat)
        await chatSubmitCheck(r, c, chat)
        await chatTabCheck(r, c, shell, hwnd, chat)
        await chatEmojiGridCheck(r, c, shell, hwnd, chat)
        await chatFocusOwnChildCheck(r, c, shell, hwnd, chat)
        await chatCompositionCheck(r, c, chat)
        await chatFocusMoveCheck(r, c, shell, hwnd, chat)
        await chatDpiCheck(r, c, shell, hwnd, chat)
        if onCI {
            await chatMinimizeRestoreCheck(r, c, shell, hwnd, chat)
            await chatTypingCheck(r, c, shell, hwnd, chat)
            await chatClipboardCheck(r, c, chat)
            await chatMenuCheck(r, c, shell, hwnd, chat, app: app)
            await chatContextMenuCheck(r, c, chat)
            await chatRealIMECheck(r, c, shell, hwnd, chat)
        } else {
            for name in ["plaza.chatTyping", "plaza.chatClipboard", "plaza.chatMenu", "plaza.chatContextMenu", "plaza.chatRealIME",
                         "plaza.chatMinimizeRestore"] {
                r.add(name, true, "skipped: real keys, the clipboard, the tray menu and IME changes are for CI only (a person's own PC is not touched)")
            }
        }
        await chatClose(chat)
        chat.ime = .system
        if onCI { forceForeground(hwnd); _ = SetFocus(hwnd) }
        return await chatReopenAfterHiddenCheck(r, c, shell, hwnd, chat)
    }

    /// Review item 1: the field outlives the window; a window closed while hidden (minimized, covered, another desktop) left the bar's HUD
    /// "not rendering", and the reopened window drew a bare field with no plate, no 😀 and no lifted chat log. Minimize, close through the
    /// controller, reopen, open the line: the bar is drawn, the log sits above it, a click on the plate keeps the line.
    @MainActor private static func chatReopenAfterHiddenCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                              _ chat: WinPlazaChatInput) async -> HWND {
        await chatClose(chat)
        _ = ShowWindow(hwnd, 7 /* SW_SHOWMINNOACTIVE */)
        let hidden = await waitUntil(timeout: 2) { !chat.hud.isRendering }
        shell.requestClose()
        _ = await waitUntil(timeout: 1) { shell.hwndForTesting == nil }
        c.show()
        _ = await waitUntil(timeout: 3) { shell.stats.presents >= 1 }
        guard let fresh = shell.hwndForTesting else {
            r.add("plaza.chatReopenAfterHidden", false, "the plaza did not reopen")
            return hwnd
        }
        if onCI { forceForeground(fresh); _ = SetFocus(fresh) }
        await chatPump(0.3)
        await chatOpen(c, chat)
        await chatPump(0.3)
        let rendering = chat.hud.isRendering
        let bar = chat.barFrame
        let drawn = bar != nil && chat.drawList.count == 1
        let lifted = chatLogInputHeight(shell)
        var kept = false
        if let bar {
            chatClick(shell, fresh, at: CGPoint(x: bar.minX + 4, y: bar.minY + 4))
            await chatPump(0.2)
            kept = chat.isOpen
        }
        await chatClose(chat)
        if onCI { forceForeground(fresh); _ = SetFocus(fresh) }
        r.add("plaza.chatReopenAfterHidden", hidden && rendering && drawn && lifted != nil && lifted == bar?.height && kept,
              "minimized (bar HUD rendering=\(!hidden)), closed through the controller, reopened, line opened: bar HUD rendering=\(rendering), "
                + "bar drawn=\(drawn) frame=\(bar.map { "\($0)" } ?? "nil"), chat log above \(lifted.map { "\($0)" } ?? "nil"), a click on the plate kept the line=\(kept)")
        return fresh
    }

    /// Review item 7: minimize with the line open, restore: the keyboard is back in the field (and which path put it there).
    @MainActor private static func chatMinimizeRestoreCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                            _ chat: WinPlazaChatInput) async {
        forceForeground(hwnd)
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatMinimizeRestore", false, "no field"); return }
        _ = chat.focus()
        chatPostText(e, "ab")
        await chatPump(0.2)
        let byActivate0 = chat.counts.focusRestores, byRestore0 = chat.counts.focusRestoresAfterRestore
        _ = ShowWindow(hwnd, 6 /* SW_MINIMIZE */)
        _ = await waitUntil(timeout: 2) { IsIconic(hwnd) }
        await chatPump(0.3)
        let openWhileMinimized = chat.isOpen
        // What the taskbar button does: the window is made foreground while still minimized (WM_ACTIVATE with fMinimized set: the
        // activation path leaves the keyboard alone), then SC_RESTORE. The restore path must put the keyboard back in the field; its
        // counter moves only when the field did NOT have it at that moment (without that path this check fails).
        forceForeground(hwnd)
        await chatPump(0.1)
        _ = SendMessageW(hwnd, 0x0112 /* WM_SYSCOMMAND */, 0xF120 /* SC_RESTORE */, 0)
        _ = await waitUntil(timeout: 2) { !IsIconic(hwnd) }
        await chatPump(0.4)
        let foreground = GetForegroundWindow() == hwnd
        let focused = GetFocus() == e
        chatPostText(e, "c")
        await chatPump(0.2)
        let text = chat.text
        let byActivate = chat.counts.focusRestores - byActivate0, byRestore = chat.counts.focusRestoresAfterRestore - byRestore0
        await chatClose(chat)
        forceForeground(hwnd)
        r.add("plaza.chatMinimizeRestore", openWhileMinimized && foreground && focused && text == "abc",
              "minimized with the line open (still open=\(openWhileMinimized)), made foreground while minimized then SC_RESTORE (the taskbar's way): foreground=\(foreground), keyboard in the field=\(focused) "
                + "(put back by WM_ACTIVATE \(byActivate)x, by the restore path \(byRestore)x); typed c -> \(q(text))")
    }

    /// Review item 7: a DPI change with the line open: the field follows (device pixels, font), keeps the keyboard and the line.
    @MainActor private static func chatDpiCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                _ chat: WinPlazaChatInput) async {
        if onCI { forceForeground(hwnd) }
        await chatOpen(c, chat)
        guard let e = chat.editHWND, let before = chat.fieldPixels else { r.add("plaza.chatDpi", false, "no field"); return }
        if onCI { _ = chat.focus() }
        chatPostText(e, "dpi 한")
        await chatPump(0.2)
        var wr = RECT()
        _ = GetWindowRect(hwnd, &wr)
        var suggested = RECT(left: wr.left, top: wr.top, right: wr.left + (wr.right - wr.left) * 3 / 2, bottom: wr.top + (wr.bottom - wr.top) * 3 / 2)
        _ = withUnsafeMutablePointer(to: &suggested) { SendMessageW(hwnd, 0x02E0, WPARAM(144 | (144 << 16)), LPARAM(Int(bitPattern: $0))) }
        await chatPump(0.4)
        let at144 = chat.fieldPixels
        let barAt144 = chat.barFrame
        chatCapture(shell, hwnd, chat, "plaza-chat-144dpi.png")
        let focused = !onCI || GetFocus() == e
        let text = chat.text
        var back = wr
        _ = withUnsafeMutablePointer(to: &back) { SendMessageW(hwnd, 0x02E0, WPARAM(96 | (96 << 16)), LPARAM(Int(bitPattern: $0))) }
        await chatPump(0.4)
        let at96 = chat.fieldPixels
        await chatClose(chat)
        let scaled = at144.map { abs(Int($0.w) - Int((CGFloat(before.w) * 1.5).rounded())) <= 1 && abs(Int($0.h) - Int((CGFloat(before.h) * 1.5).rounded())) <= 1 } ?? false
        let restored = at96.map { $0.w == before.w && $0.h == before.h } ?? false
        r.add("plaza.chatDpi", scaled && restored && focused && text == "dpi 한" && chat.isOpen == false && barAt144 != nil,
              "field at 96 dpi \(before.w)x\(before.h) px; WM_DPICHANGED 144: \(at144.map { "\($0.w)x\($0.h) at (\($0.x),\($0.y))" } ?? "none"), bar \(barAt144.map { "\($0)" } ?? "nil") pt, "
                + "keyboard in the field=\(focused), line kept=\(q(text)); back to 96: \(at96.map { "\($0.w)x\($0.h)" } ?? "none"); capture plaza-chat-144dpi.png")
    }

    /// The brief's first check (D13, R1): is a plain EDIT child composed over the WS_EX_NOREDIRECTIONBITMAP window? "Aa한" is posted to
    /// it and the SCREEN is read over the field: white text pixels on the bar colour, which the frame bitmap under it does not have.
    /// Both hosts are tried; the one the product ships must show.
    @MainActor private static func chatVisibleCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                    _ chat: WinPlazaChatInput) async {
        let shipped = WinPlazaChatInput.fieldHost
        func attempt(_ host: WinPlazaChatInput.FieldHost) async -> (visible: Bool, detail: String) {
            if WinPlazaChatInput.fieldHost != host || chat.editHWND == nil {
                chat.detach()
                WinPlazaChatInput.fieldHost = host
                _ = chat.attach(parent: hwnd)
            }
            await chatOpen(c, chat)
            guard let e = chat.editHWND, let f = chat.fieldPixels else { return (false, "\(host): no field") }
            chatPostText(e, "Aa한")
            await chatPump(0.5)
            let text = chat.text
            var origin = POINT(x: f.x, y: f.y)
            _ = ClientToScreen(hwnd, &origin)
            var work = RECT()
            _ = SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
            let onScreen = origin.x >= work.left && origin.y >= work.top && origin.x + f.w <= work.right && origin.y + f.h <= work.bottom
            let screen = WinUIDump.screenshot(x: Int(origin.x), y: Int(origin.y), w: Int(f.w), h: Int(f.h))
            let frame = shell.frameRGBAForTesting()
            var client = RECT()
            _ = GetClientRect(hwnd, &client)
            let cw = Int(client.right)
            var white = 0, bar = 0, frameWhite = 0
            if let screen {
                for i in stride(from: 0, to: screen.bgra.count, by: 4) {
                    let b = Int(screen.bgra[i]), g = Int(screen.bgra[i + 1]), rr = Int(screen.bgra[i + 2])
                    if min(b, g, rr) >= 200 { white += 1 }
                    if abs(rr - 0x1D) <= 3 && abs(g - 0x4F) <= 3 && abs(b - 0x5C) <= 3 { bar += 1 }
                }
            }
            if let frame {
                for y in Int(f.y)..<Int(f.y + f.h) {
                    for x in Int(f.x)..<Int(f.x + f.w) {
                        let i = (y * cw + x) * 4
                        guard i + 2 < frame.count else { continue }
                        if min(frame[i], frame[i + 1], frame[i + 2]) >= 200 { frameWhite += 1 }
                    }
                }
            }
            if let bf = chat.barFrame {
                let s = CGFloat(shell.dpiForTesting) / 96
                var o = POINT(x: Int32((bf.minX * s).rounded()), y: Int32((bf.minY * s).rounded()))
                _ = ClientToScreen(hwnd, &o)
                if let shot = WinUIDump.screenshot(x: Int(o.x) - 8, y: Int(o.y) - 8, w: Int((bf.width * s).rounded()) + 16, h: Int((bf.height * s).rounded()) + 16) {
                    _ = WinUIDump.write(shot, to: selftestOutDirectory().appendingPathComponent("plaza-chat-\(host).png"))
                }
            }
            let area = Int(f.w * f.h)
            let visible = onScreen && text == "Aa한" && white >= 15 && white < area / 2 && bar >= area / 3 && frameWhite < white
            await chatClose(chat)
            return (visible, "\(host): text=\(q(text)) field \(f.w)x\(f.h) px at client (\(f.x),\(f.y)) screen (\(origin.x),\(origin.y)) in the work area=\(onScreen); "
                + "screen white text px=\(white) bar-colour px=\(bar) of \(area); "
                + "frame bitmap white px under the field=\(frameWhite); visible=\(visible)")
        }
        let child = await attempt(.child)
        let layered = await attempt(.layered)
        if WinPlazaChatInput.fieldHost != shipped || chat.editHWND == nil {
            chat.detach()
            WinPlazaChatInput.fieldHost = shipped
            _ = chat.attach(parent: hwnd)
        }
        let shippedVisible = shipped == .child ? child.visible : layered.visible
        r.add("plaza.chatChildVisible", shippedVisible,
              "\(child.detail); \(layered.detail); shipped host=\(shipped); captures plaza-chat-child.png / plaza-chat-layered.png in \(WinPath.native(selftestOutDirectory()))")
    }

    /// D13's defect check: WM_IME_CHAR (what the IME sends for a finished syllable in an app that leaves it to DefWindowProc) posted
    /// to the field arrives whole; the same message to an EDIT under a window that is NOT ours (the hook leaves it to
    /// CoreFoundation's ANSI pump, i.e. the app before the fix) arrives as "?" on a code page without Hangul. And exactly once in the
    /// popover kit's edit too: its window is registered as a dialog window, so `IsDialogMessageW` dispatches it before the hook's
    /// re-dispatch line is reached (the chat field is not a dialog window: it takes the re-dispatch).
    @MainActor private static func imeCharCheck(_ r: Recorder, _ c: PlazaWindowController, _ chat: WinPlazaChatInput, ansiPump: Bool) async {
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.imeChar", false, "no field"); return }
        let acp = GetACP()
        let before = WinMessageHook.redispatchedChars, imeChars0 = chat.counts.imeChars
        chatPost(e, 0x0286, 0xD55C)
        await chatPump(0.3)
        let ours = chat.text
        let redispatched = WinMessageHook.redispatchedChars - before
        var foreignText = "-"
        if let parent = CreateWindowExW(0, WinStr.w("STATIC"), WinStr.w("ptb-selftest-foreign"), 0x8000_0000 /* WS_POPUP */, 0, 0, 10, 10, nil, nil, nil, nil) {
            if let raw = ptb_chat_edit_create(UnsafeMutableRawPointer(parent), 0, nil, nil), let fe = HWND(bitPattern: Int(bitPattern: raw)) {
                chatPost(fe, 0x0286, 0xD55C)
                await chatPump(0.3)
                var buf = [UInt16](repeating: 0, count: 16)
                let n = buf.withUnsafeMutableBufferPointer { p in Int(SendMessageW(fe, 0x000D, WPARAM(p.count), LPARAM(Int(bitPattern: p.baseAddress)))) }
                foreignText = String(decoding: buf.prefix(max(0, n)), as: UTF16.self)
                ptb_chat_edit_destroy(raw)
            }
            _ = DestroyWindow(parent)
        }
        let hangulCodePage = acp == 949 || acp == 1361 || acp == 65001
        var kitText = "-", kitDialog = 0, kitRedispatch = 0
        let page = KeyPage()
        if let kit = KitWindow(heightDIP: 230, build: { _, s in page.build(s) }) {
            kit.show(activate: false)
            if let kitEdit = page.edit {
                let d0 = WinMessageHook.dialogMessages, h0 = WinMessageHook.redispatchedChars
                chatPost(kitEdit.hwnd, 0x0286, 0xD55C)
                await chatPump(0.3)
                kitText = kitEdit.text
                kitDialog = WinMessageHook.dialogMessages - d0
                kitRedispatch = WinMessageHook.redispatchedChars - h0
            }
            kit.destroy()
        }
        await chatClose(chat)
        // The control shows the defect only under CoreFoundation's ANSI pump (the dispatch-handle loop pumps in Unicode itself).
        r.add("plaza.imeChar", ours == "한" && redispatched >= 1 && chat.counts.imeChars > imeChars0 && (hangulCodePage || !ansiPump || foreignText == "?")
                && kitText == "한" && kitDialog >= 1 && kitRedispatch == 0,
              "ACP \(acp); posted WM_IME_CHAR U+D55C to the field: text=\(q(ours)) (hook re-dispatched \(redispatched), the field saw WM_IME_CHAR "
                + "\(chat.counts.imeChars - imeChars0)x); the popover kit's edit (a registered dialog window): \(q(kitText)) through IsDialogMessageW "
                + "\(kitDialog)x, hook re-dispatch \(kitRedispatch); the same to an EDIT outside our windows (no re-dispatch, the pre-fix path): \(q(foreignText))"
                + (hangulCodePage ? " (this code page holds Hangul: the defect cannot show here)" : "")
                + (ansiPump ? "" : " (dispatch-handle loop: a Unicode pump, the control is not judged)"))
    }

    /// Enter (and the keypad's Enter) opens the line with the keyboard in the field, the chat log above it, the IME context on the
    /// field and none on the scene; Esc closes it and the keyboard goes back to the scene. Real keys on CI.
    @MainActor private static func chatOpenCloseCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                      _ chat: WinPlazaChatInput) async {
        var parts: [String] = []
        var ok = true
        for (label, scan, extended) in [("Enter", UInt32(0x1C), false), ("keypad Enter", UInt32(0x1C), true)] {
            if onCI {
                forceForeground(hwnd)
                _ = SetFocus(hwnd)
                await chatPump(0.15)
                await chatTap(scan, extended: extended)
            } else {
                c.scene?.handleKeyDown(keyCode: extended ? PlazaKeyCode.keypadEnter : PlazaKeyCode.returnKey, characters: nil, isRepeat: false)
            }
            await chatPump(0.3)
            let edit = chat.editHWND
            let opened = chat.isOpen
            let focused = !onCI || (edit != nil && GetFocus() == edit)
            let fieldIME = edit.map { ptb_window_ime_has_context(UnsafeMutableRawPointer($0)) == 1 } ?? false
            let sceneIME = shell.imeHasContext
            let above = chatLogInputHeight(shell)
            let barHeight = chat.barFrame?.height
            if onCI { await chatTap(0x01) } else if let edit { chatPost(edit, 0x0100, 0x1B) }
            await chatPump(0.3)
            let closed = !chat.isOpen
            let back = !onCI || GetFocus() == hwnd
            let hidden = chat.hostHWND.map { !IsWindowVisible($0) } ?? false
            let after = chatLogInputHeight(shell)
            let good = opened && focused && fieldIME && !sceneIME && above != nil && above == barHeight && closed && back && hidden && after == nil
            ok = ok && good
            parts.append("\(label): opened=\(opened) field has the keyboard=\(focused) IME context field=\(fieldIME) scene=\(sceneIME) chat log above "
                + "\(above.map { "\($0)" } ?? "nil") (bar \(barHeight.map { "\($0)" } ?? "nil")); Esc closed=\(closed) keyboard back to the scene=\(back) field hidden=\(hidden) log above after=\(after.map { "\($0)" } ?? "nil")")
        }
        r.add("plaza.chatOpenClose", ok, (onCI ? "SendInput scan codes. " : "scene keys and posted Esc. ") + parts.joined(separator: "; ")
              + " (the Mac opens the line with Enter only; no T key)")
    }

    /// "hello 안녕" posted through the pump, a held Enter (repeat bit) does nothing, Enter sends the exact line and closes.
    @MainActor private static func chatSubmitCheck(_ r: Recorder, _ c: PlazaWindowController, _ chat: WinPlazaChatInput) async {
        await chatPump(0.35)   // the controller's 0.3 s between lines
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatSubmit", false, "no field"); return }
        let lines0 = c.chatLogLines.count
        chatPostText(e, "hello 안녕")
        await chatPump(0.3)
        let typed = chat.text
        chatPost(e, 0x0100, 0x0D, LPARAM(1 | (1 << 30)))
        await chatPump(0.2)
        let heldKeptOpen = chat.isOpen && c.chatLogLines.count == lines0
        chatPost(e, 0x0100, 0x0D)
        await chatPump(0.3)
        let sent = c.chatLogLines.count == lines0 + 1 ? c.chatLogLines.last?.text : nil
        let bubble = c.scene?.shownChat(memberID: nil)
        r.add("plaza.chatSubmit", typed == "hello 안녕" && heldKeptOpen && sent == "hello 안녕" && bubble == "hello 안녕" && !chat.isOpen,
              "typed=\(q(typed)); held Enter (repeat bit): open=\(heldKeptOpen) nothing sent; Enter: sent=\(q(sent ?? "nothing")) bubble=\(q(bubble ?? "none")) "
                + "closed=\(!chat.isOpen); field counts submits=\(chat.counts.submits) repeatsIgnored=\(chat.counts.repeatsIgnored)")
    }

    @MainActor private static func chatTabCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                _ chat: WinPlazaChatInput) async {
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatTab", false, "no field"); return }
        chatPostText(e, "확성기")
        await chatPump(0.2)
        let renders0 = chat.hud.renderCount
        chatCapture(shell, hwnd, chat, "plaza-chat-open.png")
        chatPost(e, 0x0100, 0x09)
        await chatPump(0.3)
        chatCapture(shell, hwnd, chat, "plaza-chat-loud.png")
        let on = chat.isLoud, orange = chat.bar.borderColor == PlazaChatBarPanel.loudBorder, renders = chat.hud.renderCount - renders0
        chatPost(e, 0x0100, 0x09)
        await chatPump(0.3)
        let off = !chat.isLoud
        let text = chat.text
        await chatClose(chat)
        await chatOpen(c, chat)
        let fresh = !chat.isLoud
        await chatClose(chat)
        r.add("plaza.chatTab", on && orange && renders >= 1 && off && text == "확성기" && fresh,
              "Tab: loud=\(on) border orange=\(orange) bar renders +\(renders); Tab again: loud=\(!off); the line kept=\(q(text)); a new line starts ordinary=\(fresh)")
    }

    /// The 😀 button unfolds the grid (the bar grows upward, the chat log follows it), a cell inserts at the caret, the keyboard stays
    /// in the field throughout (no `didResignKey`: the field is the plaza's own child). A syllable being composed is finished first.
    @MainActor private static func chatEmojiGridCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                      _ chat: WinPlazaChatInput) async {
        guard scriptedIME else {
            r.add("plaza.chatEmojiGrid", true, "skipped: a real IME is active in this process (a person's PC: their input method is not changed)")
            return
        }
        let resigns0 = shell.stats.resigns, foreground0 = GetForegroundWindow()
        await chatOpen(c, chat)
        await chatPump(0.2)
        guard let e = chat.editHWND, let bar = chat.barFrame else { r.add("plaza.chatEmojiGrid", false, "no field or bar"); return }
        chatPostText(e, "안녕")
        await chatPump(0.2)
        _ = SendMessageW(e, 0x00B1, 1, 1)
        let y0 = chat.fieldPixels?.y
        let button = chat.bar.emojiButtonRect
        chatClick(shell, hwnd, at: CGPoint(x: bar.minX + button.midX, y: bar.minY + button.midY))
        await chatPump(0.3)
        let unfolded = chat.bar.isEmojiOpen
        chatCapture(shell, hwnd, chat, "plaza-chat-emoji.png")
        let grown = chat.barFrame?.height ?? 0
        let logAbove = chatLogInputHeight(shell)
        let y1 = chat.fieldPixels?.y
        let focusAfterButton = !onCI || GetFocus() == e
        guard let i = PlazaChatEmojis.all.firstIndex(of: "🍜"), let grownBar = chat.barFrame else { r.add("plaza.chatEmojiGrid", false, "no cell"); return }
        let cell = chat.bar.gridCells[i]
        chatClick(shell, hwnd, at: CGPoint(x: grownBar.minX + cell.midX, y: grownBar.minY + cell.midY))
        await chatPump(0.2)
        let inserted = chat.text
        let focusAfterPick = !onCI || GetFocus() == e
        // A syllable being composed is finished first, so the emoji does not replace it.
        let script = ChatScript()
        script.install(on: chat)
        script.composition = "가"
        let firstCell = chat.bar.gridCells[0]
        chatClick(shell, hwnd, at: CGPoint(x: grownBar.minX + firstCell.midX, y: grownBar.minY + firstCell.midY))
        await chatPump(0.2)
        let afterComposing = chat.text
        chat.ime = .system
        let resigns = shell.stats.resigns - resigns0
        let stillOpen = chat.isOpen
        await chatClose(chat)
        r.add("plaza.chatEmojiGrid",
              unfolded && grown == 169 && logAbove == 169 && y1 == y0 && inserted == "안🍜녕" && focusAfterButton && focusAfterPick && stillOpen
                && afterComposing == "안🍜가😀녕" && script.finishes == [false] && resigns == 0 && (!onCI || GetForegroundWindow() == foreground0),
              "😀 click: grid unfolded=\(unfolded) bar height \(grown) (chat log above \(logAbove.map { "\($0)" } ?? "nil")), field stayed at y \(y0.map { "\($0)" } ?? "-")->\(y1.map { "\($0)" } ?? "-"); "
                + "🍜 at the caret: \(q(inserted)); keyboard in the field after the button=\(focusAfterButton) after the pick=\(focusAfterPick); "
                + "😀 while composing 가: \(q(afterComposing)) (finished first: \(script.finishes)); didResignKey +\(resigns); still open=\(stillOpen)")
    }

    /// The field taking the keyboard, clicks on its bar and typing in it are moves inside the plaza: no `didResignKey` (the
    /// controller would release the scene's keys and log "resigned key"), the plaza stays the foreground window.
    @MainActor private static func chatFocusOwnChildCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                          _ chat: WinPlazaChatInput) async {
        if onCI { forceForeground(hwnd); _ = SetFocus(hwnd); await chatPump(0.15) }
        let resigns0 = shell.stats.resigns, becomes0 = shell.stats.activations
        var foregroundKept = true
        await chatOpen(c, chat)
        let took = !onCI || GetFocus() == chat.editHWND
        foregroundKept = foregroundKept && (!onCI || GetForegroundWindow() == hwnd)
        if let bar = chat.barFrame {
            chatClick(shell, hwnd, at: CGPoint(x: bar.minX + 4, y: bar.minY + 4))   // the plate
            await chatPump(0.15)
        }
        if let e = chat.editHWND { chatPostText(e, "x") }
        await chatPump(0.15)
        let kept = !onCI || GetFocus() == chat.editHWND
        foregroundKept = foregroundKept && (!onCI || GetForegroundWindow() == hwnd)
        await chatClose(chat)
        let backToScene = !onCI || GetFocus() == hwnd
        let resigns = shell.stats.resigns - resigns0
        r.add("plaza.chatFocusOwnChild", resigns == 0 && took && kept && backToScene && foregroundKept,
              "field took the keyboard=\(took), kept it through a click on the bar's plate and typing=\(kept), gave it back to the scene on close=\(backToScene); "
                + "didResignKey +\(resigns); plaza stayed foreground=\(foregroundKept); bringToFront calls +\(shell.stats.activations - becomes0)")
    }

    /// Synthesized IME messages POSTED through the real pump (start, composition strings, end, WM_IME_CHAR), the IME's strings
    /// scripted: the field's composition record, Enter while composing (finished, not sent), Esc and the limit while composing,
    /// the composition and candidate windows at the caret.
    @MainActor private static func chatCompositionCheck(_ r: Recorder, _ c: PlazaWindowController, _ chat: WinPlazaChatInput) async {
        guard scriptedIME else {
            r.add("plaza.chatComposition", true, "skipped: a real IME is active in this process (a person's PC: their input method is not changed)")
            return
        }
        await chatPump(0.35)
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatComposition", false, "no field"); return }
        let raw = UnsafeMutableRawPointer(e)
        let script = ChatScript()
        script.install(on: chat)
        func step(_ s: String) async -> String {
            script.composition = s
            chatPost(e, 0x010F, 0, 0x8 | 0x10 | 0x80)   // GCS_COMPSTR | GCS_COMPATTR | GCS_CURSORPOS
            await chatPump(0.08)
            return chat.composition?.text ?? "nil"
        }
        chatPost(e, 0x010D, 0, 0)
        await chatPump(0.08)
        let started = chat.composition != nil
        var trace: [String] = []
        for s in ["ㅎ", "하", "한"] { trace.append(await step(s)) }
        var windows = [Int32](repeating: 0, count: 10)
        let read = ptb_ime_windows(raw, &windows)
        let fieldH = chat.fieldPixels?.h ?? 0
        let imeAtCaret = !onCI || (windows[0] == 2 /* CFS_POINT */ && windows[3] == 0x80 /* CFS_EXCLUDE */ && windows[9] - windows[7] == fieldH)
        var backspaces: [String] = []
        for s in ["하", "ㅎ", ""] { backspaces.append(await step(s)) }
        chatPost(e, 0x010E, 0, 0)
        await chatPump(0.08)
        let ended = chat.composition == nil && chat.text.isEmpty
        // Enter while "안" is being composed: finished, not sent; the next Enter sends it.
        let lines0 = c.chatLogLines.count
        chatPost(e, 0x010D, 0, 0)
        _ = await step("아")
        _ = await step("안")
        chatPost(e, 0x0100, 0x0D)
        await chatPump(0.25)
        let enterKept = chat.isOpen && c.chatLogLines.count == lines0 && chat.text == "안" && script.finishes == [false] && chat.composition == nil
        chatPost(e, 0x0100, 0x0D)
        await chatPump(0.3)
        let sentAfter = c.chatLogLines.count == lines0 + 1 ? c.chatLogLines.last?.text ?? "" : "nothing"
        // The limit: 60 committed + a syllable being composed (shown in place) is left alone; the end of the composition cuts it.
        await chatPump(0.35)
        await chatOpen(c, chat)
        chatPostText(e, String(repeating: "가", count: TeamChat.maxCharacters))
        await chatPump(0.4)
        let cuts0 = chat.counts.cuts
        chatPost(e, 0x010D, 0, 0)
        _ = await step("나")
        chatPost(e, 0x0102, WPARAM(("나" as Unicode.Scalar).value))   // the syllable in place, as the EDIT shows a composition
        await chatPump(0.15)
        let whileComposing = chat.text.count
        script.composition = ""
        chatPost(e, 0x010E, 0, 0)
        await chatPump(0.15)
        let afterEnd = chat.text.count
        let cut = chat.counts.cuts - cuts0
        // Esc while composing: cancelled with the line; the next open shows no ghost.
        _ = WinStr.w("x").withUnsafeBufferPointer { SendMessageW(e, 0x000C, 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
        chatPost(e, 0x010D, 0, 0)
        _ = await step("ㄱ")
        script.finishes = []
        chatPost(e, 0x0100, 0x1B)
        await chatPump(0.2)
        let escCancelled = !chat.isOpen && script.finishes == [true]
        await chatOpen(c, chat)
        let noGhost = chat.text.isEmpty && chat.composition == nil
        await chatClose(chat)
        chat.ime = .system
        r.add("plaza.chatComposition",
              started && trace == ["ㅎ", "하", "한"] && imeAtCaret && backspaces == ["하", "ㅎ", ""] && ended && enterKept && sentAfter == "안"
                && whileComposing == TeamChat.maxCharacters + 1 && afterEnd == TeamChat.maxCharacters && cut == 1 && escCancelled && noGhost,
              "posted START + COMPSTR: composition \(trace) started=\(started); IME windows (read \(read)): composition style \(windows[0]) at (\(windows[1]),\(windows[2])), "
                + "candidates style 0x\(String(windows[3], radix: 16)) at (\(windows[4]),\(windows[5])) excluding (\(windows[6]),\(windows[7]))-(\(windows[8]),\(windows[9])) "
                + "(field height \(fieldH)) at the caret=\(imeAtCaret); Backspace x3 \(backspaces) then END: empty=\(ended); Enter while composing 안: kept open, "
                + "finished not sent=\(enterKept), next Enter sent \(q(sentAfter)); limit: 60 + composing = \(whileComposing) left alone, after END \(afterEnd) (cuts +\(cut)); "
                + "Esc while composing: closed and cancelled=\(escCancelled), reopened empty=\(noGhost)")
    }

    /// Focus moves: a click on an inert panel area leaves the keyboard and the composition alone (the Mac's panel views refuse first
    /// responder); a panel action that gives the keys to the scene (the guide's fold, as the roster's walk or the chat log's fold)
    /// closes the line, as on the Mac (`focusScene` ends the field editor): the syllable goes with the line, nothing is sent; a click
    /// on the map closes it; the app going to the background keeps it and the keyboard comes back to it; the first click into the
    /// inactive window only activates it.
    @MainActor private static func chatFocusMoveCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                      _ chat: WinPlazaChatInput) async {
        guard let panels = shell.panelsForTesting else { r.add("plaza.chatCloseOnFocusMove", false, "no panels"); return }
        guard scriptedIME else {
            r.add("plaza.chatCloseOnFocusMove", true, "skipped: a real IME is active in this process (a person's PC: their input method is not changed)")
            return
        }
        if onCI { forceForeground(hwnd) }
        let script = ChatScript()
        let lines0 = c.chatLogLines.count
        var parts: [String] = []
        var ok = true
        // (a) an inert panel area: the chat log's own lines ("log" hits do nothing).
        await chatOpen(c, chat)
        script.install(on: chat)
        if let e = chat.editHWND { chatPostText(e, "abc") }
        await chatPump(0.2)
        script.composition = "안"
        var inert: CGPoint?
        if let frame = panels.entries[.chatLog]?.frame {
            outer: for y in stride(from: frame.minY + 2, to: frame.maxY, by: 4) {
                for x in stride(from: frame.minX + 2, to: frame.maxX, by: 8) where panels.hud.hit(at: CGPoint(x: x, y: y), in: .chatLog)?.action == "log"
                    && panels.host(at: CGPoint(x: x, y: y)) == .chatLog {
                    inert = CGPoint(x: x, y: y)
                    break outer
                }
            }
        }
        if let inert {
            chatClick(shell, hwnd, at: inert)
            await chatPump(0.25)
            let kept = chat.isOpen && (!onCI || GetFocus() == chat.editHWND) && script.finishes.isEmpty && chat.text == "abc"
            ok = ok && kept
            parts.append("chat log line clicked at (\(Int(inert.x)),\(Int(inert.y))): open, keyboard and composition 안 untouched=\(kept)")
        } else if onCI {
            ok = false
            parts.append("FAIL: no inert chat-log point found (the log has lines by now)")
        } else {
            parts.append("skipped: no inert chat-log point shown")
        }
        // (b) the guide's fold: a panel action that calls focusScene.
        let guide = panels.entries[.shortcuts].flatMap { e -> CGPoint? in
            e.drawing.accessibility.first { $0.action?.action == "toggle" }.map { CGPoint(x: e.frame.minX + $0.frame.midX, y: e.frame.minY + $0.frame.midY) }
        }
        if let guide {
            chatClick(shell, hwnd, at: guide)
            await chatPump(0.3)
            let closed = !chat.isOpen && script.finishes == [false] && c.chatLogLines.count == lines0
            ok = ok && (closed || !onCI)   // focusScene acts only while the plaza is the foreground window (CI)
            parts.append("guide fold clicked while composing 안: closed=\(!chat.isOpen) syllable finished into the line=\(script.finishes == [false]) then discarded with it, nothing sent=\(c.chatLogLines.count == lines0)")
            chatClick(shell, hwnd, at: guide)   // fold it back
            await chatPump(0.2)
        } else if onCI {
            ok = false
            parts.append("FAIL: no guide toggle found")
        } else {
            parts.append("skipped: no guide toggle shown")
        }
        // (c) a click on the map.
        await chatOpen(c, chat)
        script.finishes = []
        if let e = chat.editHWND { chatPostText(e, "xyz") }
        await chatPump(0.2)
        script.composition = "하"
        let size = shell.stageForTesting?.size ?? CGSize(width: 600, height: 400)
        var map: CGPoint?
        for p in [CGPoint(x: size.width * 0.5, y: size.height * 0.35), CGPoint(x: size.width * 0.6, y: size.height * 0.5), CGPoint(x: size.width * 0.4, y: size.height * 0.6)]
            where panels.host(at: p) == nil && !chat.takes(p) { map = p; break }
        if let map {
            chatClick(shell, hwnd, at: map)
            await chatPump(0.3)
            let closed = !chat.isOpen && (!onCI || GetFocus() == hwnd) && script.finishes == [false] && c.chatLogLines.count == lines0
            await chatOpen(c, chat)
            let empty = chat.text.isEmpty && chat.composition == nil
            ok = ok && closed && empty
            parts.append("map click while composing 하: closed=\(closed) (keyboard to the scene, syllable finished then discarded, nothing sent), reopened empty=\(empty)")
        } else {
            parts.append("no free map point: not judged")
            ok = false
        }
        // (d) the app going to the background and back (CI: another window takes the foreground).
        if onCI {
            let other = try? WinSinkWindow(className: "PokeTokenBarSelftestChatOther", title: "other", style: 0x10CF_0000, exStyle: 0,
                                           x: 650, y: 80, width: 300, height: 200)
            defer { other?.destroy() }
            await chatOpen(c, chat)
            forceForeground(hwnd)
            _ = chat.focus()
            await chatPump(0.15)
            if let e = chat.editHWND { chatPostText(e, "keep") }
            await chatPump(0.2)
            script.finishes = []
            script.composition = "가"
            let caretBefore = ptb_chat_caret_window().map { HWND(bitPattern: Int(bitPattern: $0)) == chat.editHWND } ?? false
            if let other { forceForeground(other.hwnd) }
            await chatPump(0.3)
            let keptOpen = chat.isOpen && script.finishes == [false]
            let caretGone = ptb_chat_caret_window() == nil
            forceForeground(hwnd)
            await chatPump(0.3)
            let restored = GetFocus() == chat.editHWND
            let text = chat.text
            // (e) the first click into the inactive window, on the map: only activates.
            if let other { forceForeground(other.hwnd) }
            await chatPump(0.3)
            var firstClickKept = false
            if let map {
                let s = CGFloat(shell.dpiForTesting) / 96
                var pt = POINT(x: Int32((map.x * s).rounded()), y: Int32((map.y * s).rounded()))
                _ = ClientToScreen(hwnd, &pt)
                _ = SetCursorPos(pt.x, pt.y)
                await chatPump(0.1)
                var down = INPUT(), up = INPUT()
                down.type = DWORD(INPUT_MOUSE)
                down.mi.dwFlags = DWORD(0x0002)
                up.type = DWORD(INPUT_MOUSE)
                up.mi.dwFlags = DWORD(0x0004)
                _ = SendInput(1, &down, Int32(MemoryLayout<INPUT>.stride))
                await chatPump(0.05)
                _ = SendInput(1, &up, Int32(MemoryLayout<INPUT>.stride))
                await chatPump(0.4)
                firstClickKept = chat.isOpen && GetFocus() == chat.editHWND && GetForegroundWindow() == hwnd
            }
            let good = keptOpen && caretBefore && caretGone && restored && text == "keep가" && firstClickKept
            ok = ok && good
            parts.append("another window took the foreground while composing 가: kept open, syllable finished in place=\(keptOpen), caret gone (no blink)=\(caretGone) "
                + "(was on the field=\(caretBefore)); back: keyboard restored to the field=\(restored) text=\(q(text)); first click on the map of the inactive "
                + "window: activated, line kept with the keyboard=\(firstClickKept)")
        }
        await chatClose(chat)
        chat.ime = .system
        r.add("plaza.chatCloseOnFocusMove", ok, parts.joined(separator: "; ") + "; field counts closesByFocus=\(chat.counts.closesByFocus) "
              + "keptOnFocusLoss=\(chat.counts.keptOnFocusLoss) focusRestores=\(chat.counts.focusRestores)")
    }

    /// Real keys (CI): VK_PACKET text with surrogates and a ZWJ sequence through TranslateMessage, the pump and the hook arrives whole and
    /// once; an arrow in the field moves the caret and does not walk; real Enter sends; with the line closed, typing reaches the scene and
    /// not the hidden field.
    @MainActor private static func chatTypingCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                   _ chat: WinPlazaChatInput) async {
        guard let router = shell.input else { r.add("plaza.chatTyping", false, "no input router"); return }
        await chatPump(0.35)
        forceForeground(hwnd)
        _ = SetFocus(hwnd)
        await chatPump(0.15)
        await chatTap(0x1C)
        await chatPump(0.2)
        let text = "Hi 한글 😀👨‍👩‍👧"
        let hook0 = WinMessageHook.redispatchedChars, chars0 = chat.counts.chars
        await chatUnicode(text)
        let typed = chat.text
        let hooked = WinMessageHook.redispatchedChars - hook0, seen = chat.counts.chars - chars0
        let downs0 = router.counts.keyDowns
        let sel0 = chat.selection
        await chatTap(0x4B, extended: true)   // Left arrow
        let sel1 = chat.selection
        let walking = c.scene?.walker.isWalking ?? false
        let leaked = router.counts.keyDowns - downs0
        let lines0 = c.chatLogLines.count
        await chatTap(0x1C)
        await chatPump(0.3)
        let sent = c.chatLogLines.count == lines0 + 1 ? c.chatLogLines.last?.text ?? "" : "nothing"
        // The line closed: typing goes to the scene, the hidden field takes nothing.
        let downs1 = router.counts.keyDowns, fieldChars = chat.counts.chars
        await chatTap(0x10)   // Q
        await chatUnicode("한")
        let sceneGot = router.counts.keyDowns - downs1
        let fieldGot = chat.counts.chars - fieldChars
        r.add("plaza.chatTyping",
              typed == text && hooked == text.utf16.count && seen == text.utf16.count && sel1.start < sel0.start && !walking && leaked == 0
                && sent == text && sceneGot >= 1 && fieldGot == 0 && chat.text.isEmpty,
              "VK_PACKET \(text.utf16.count) units: field \(q(typed)) (\(typed.count) characters), hook re-dispatched \(hooked), field WM_CHAR \(seen); "
                + "Left arrow in the field: caret \(sel0.start)->\(sel1.start), scene key-downs +\(leaked), walking=\(walking); real Enter sent \(q(sent)); "
                + "line closed: Q + VK_PACKET 한 -> scene key-downs +\(sceneGot), field characters +\(fieldGot), field text \(q(chat.text))")
    }

    /// Paste (Ctrl+V, real keys), select-all, copy and cut against the real clipboard (CI only: a person's clipboard is theirs).
    @MainActor private static func chatClipboardCheck(_ r: Recorder, _ c: PlazaWindowController, _ chat: WinPlazaChatInput) async {
        await chatOpen(c, chat)
        guard chat.editHWND != nil else { r.add("plaza.chatClipboard", false, "no field"); return }
        func setClipboard(_ s: String) -> Bool { Array(s.utf16).withUnsafeBufferPointer { ptb_clipboard_set_text($0.baseAddress, $0.count, 500) } >= 0 }
        func ctrl(_ scan: UInt32) async {
            chatScan(0x1D, up: false)
            await chatPump(0.03)
            await chatTap(scan)
            chatScan(0x1D, up: true)
            await chatPump(0.1)
        }
        let multi = "첫 줄\r\n둘째\t줄\n셋"
        let set1 = setClipboard(multi)
        await ctrl(0x2F)   // V
        let pasted = chat.text
        await ctrl(0x1E)   // A
        let selection = chat.selection
        await ctrl(0x2E)   // C
        let copied = WinPlazaChatInput.readClipboardText()
        await ctrl(0x2D)   // X
        let afterCut = chat.text
        let cutText = WinPlazaChatInput.readClipboardText()
        let set2 = setClipboard(String(repeating: "길", count: 5000))
        await ctrl(0x2F)
        let long = chat.text.count
        await chatClose(chat)
        r.add("plaza.chatClipboard",
              set1 && set2 && pasted == "첫 줄 둘째 줄 셋" && selection.start == 0 && selection.end == pasted.utf16.count && copied == pasted
                && afterCut.isEmpty && cutText == pasted && long == TeamChat.maxCharacters,
              "Ctrl+V of \(q(multi.debugDescription)): \(q(pasted)) (one line); Ctrl+A selection \(selection); Ctrl+C clipboard=\(q(copied ?? "nil")); "
                + "Ctrl+X field \(q(afterCut)) clipboard=\(q(cutText ?? "nil")); Ctrl+V of 5000 characters: \(long) kept")
    }

    /// The tray menu while the line is open and a syllable is being composed (CI): the menu takes the keyboard. Real Down keys reach
    /// it, not the field; a character posted to the field meanwhile is taken by the menu's modal loop as a typed one would be
    /// (native: a popup menu reads every keyboard message of the thread), and the hook re-dispatches nothing while the menu runs
    /// (its menu guard). The syllable is finished into the line once, the line stays open and gets the keyboard back after.
    @MainActor private static func chatMenuCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                 _ chat: WinPlazaChatInput, app: WindowsAppDelegate) async {
        guard let host = app.tray else { r.add("plaza.chatMenu", true, "no tray host in this run: not judged"); return }
        forceForeground(hwnd)
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatMenu", false, "no field"); return }
        _ = chat.focus()
        chatPostText(e, "ab")
        await chatPump(0.2)
        let script = ChatScript()
        script.install(on: chat)
        script.composition = "가"
        let editBits = Int(bitPattern: e), sinkBits = Int(bitPattern: app.sink.hwnd)
        let hookBefore = WinMessageHook.redispatchedChars, charsBefore = chat.counts.chars
        let finished = PlazaTally(), sawMenu = PlazaTally()
        onThread {
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.02); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { finished.set(); return }
            sawMenu.set()
            Thread.sleep(forTimeInterval: 0.2)
            _ = PostMessageW(HWND(bitPattern: editBits), 0x0102, 0xD55C, 1)   // a character for the field while the menu loop runs
            for _ in 0..<2 {   // real keys: the menu has them
                var k = [INPUT(), INPUT()]
                k[0].type = DWORD(INPUT_KEYBOARD); k[0].ki.wScan = 0x50; k[0].ki.dwFlags = DWORD(KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY)
                k[1] = k[0]; k[1].ki.dwFlags |= DWORD(KEYEVENTF_KEYUP)
                _ = SendInput(2, &k, Int32(MemoryLayout<INPUT>.stride))
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.2)
            _ = PostMessageW(HWND(bitPattern: sinkBits), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
            _ = PostMessageW(HWND(bitPattern: sinkBits), UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.05) }
            finished.set()
        }
        let opener = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { host.openMenu(at: POINT(x: 300, y: 300)) }
        }
        RunLoop.main.add(opener, forMode: .common)
        _ = await waitUntil(timeout: 10) { finished.isSet }
        _ = await waitUntil(timeout: 3) { WinPopupMenu.openMenuBits == 0 }
        await chatPump(0.2)
        let duringMenu = chat.text
        let hookDuring = WinMessageHook.redispatchedChars - hookBefore
        let fieldChars = chat.counts.chars - charsBefore - script.finishes.filter { !$0 }.count   // besides the finished syllable
        let stayedOpen = chat.isOpen
        forceForeground(hwnd)
        await chatPump(0.3)
        let back = GetFocus() == e
        chatPostText(e, "c")
        await chatPump(0.2)
        let final = chat.text
        await chatClose(chat)
        chat.ime = .system
        r.add("plaza.chatMenu", sawMenu.isSet && stayedOpen && duringMenu == "ab가" && fieldChars == 0 && back && final == "ab가c" && script.finishes == [false],
              "tray menu opened=\(sawMenu.isSet) over the open line (composing 가): the syllable finished into the line once when the menu took the keyboard "
                + "(\(script.finishes)); 2 real Down keys and a posted 한 during the menu: field \(q(duringMenu)), characters reaching the field +\(fieldChars) "
                + "(the menu took them, as natively; hook re-dispatches meanwhile +\(hookDuring), none to the field); line open=\(stayedOpen); plaza active "
                + "again: keyboard back in the field=\(back); typed c: \(q(final))")
    }

    /// The field's own context menu (right click) is a modal loop of the EDIT: the main queue is served meanwhile (WinModalPump).
    @MainActor private static func chatContextMenuCheck(_ r: Recorder, _ c: PlazaWindowController, _ chat: WinPlazaChatInput) async {
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatContextMenu", false, "no field"); return }
        let pumps0 = chat.counts.menuPumps
        let ranInside = PlazaTally(), sawMenu = PlazaTally(), finished = PlazaTally()
        let main = WindowsApp.mainThreadID
        let editBits = Int(bitPattern: e)
        onThread {
            var info = GUITHREADINFO()
            info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
            var waited = 0
            while waited < 150 {
                if GetGUIThreadInfo(main, &info), info.flags & 0x10 != 0 { break }   // GUI_POPUPMENUMODE
                Thread.sleep(forTimeInterval: 0.02); waited += 1
            }
            guard info.flags & 0x10 != 0 else { finished.set(); return }
            sawMenu.set()
            DispatchQueue.main.async {
                var now = GUITHREADINFO()
                now.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
                if GetGUIThreadInfo(main, &now), now.flags & 0x10 != 0 { ranInside.set() }
            }
            Thread.sleep(forTimeInterval: 0.4)
            _ = PostMessageW(HWND(bitPattern: editBits), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
            Thread.sleep(forTimeInterval: 0.3)
            finished.set()
        }
        chatPost(e, 0x007B, WPARAM(UInt(bitPattern: editBits)), chatPacked(-1, -1))   // WM_CONTEXTMENU from the keyboard (at the caret)
        _ = await waitUntil(timeout: 8) { finished.isSet }
        await chatPump(0.2)
        let stillOpen = chat.isOpen
        await chatClose(chat)
        r.add("plaza.chatContextMenu", sawMenu.isSet && ranInside.isSet && chat.counts.menuPumps > pumps0 && stillOpen,
              "the EDIT's context menu opened=\(sawMenu.isSet); a main-queue block ran while it was open=\(ranInside.isSet); pumped=\(chat.counts.menuPumps - pumps0); line open after=\(stillOpen)")
    }

    /// A real Korean IME, if this machine has one (CI only: activated for this process alone and put back afterwards). Real keys in
    /// Hangul mode: "gks" -> 한 in place, Backspace x3, "dkssud" + Enter, "rkqt" + Left, "ekfr" + "h".
    @MainActor private static func chatRealIMECheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                    _ chat: WinPlazaChatInput) async {
        var report = [UInt16](repeating: 0, count: 1024)
        let probe = ptb_ime_korean(0, &report, Int32(report.count))
        let probeText = String(decoding: report.prefix { $0 != 0 }, as: UTF16.self)
        let folder = FileManager.default.fileExists(atPath: "C:\\Windows\\System32\\IME\\IMEKR")
        guard probe == 1 else {   // the runner image has it: its absence there is a failure, not a pass
            r.add("plaza.chatRealIME", !onCI, "unavailable: no Korean IME on this machine (IMEKR folder=\(folder); TSF: \(probeText))")
            return
        }
        forceForeground(hwnd)
        await chatPump(0.35)
        await chatOpen(c, chat)
        guard let e = chat.editHWND else { r.add("plaza.chatRealIME", false, "no field"); return }
        _ = chat.focus()
        var act = [UInt16](repeating: 0, count: 1024)
        var activated = ptb_ime_korean(1, &act, Int32(act.count))
        await chatPump(0.5)
        // Enabling the profile for the user takes effect after the thread has pumped: activate once more (the second process of a run
        // found it enabled and active at once).
        activated = ptb_ime_korean(1, &act, Int32(act.count))
        let actText = String(decoding: act.prefix { $0 != 0 }, as: UTF16.self)
        defer { _ = ptb_ime_korean_restore() }
        await chatPump(0.3)
        _ = chat.focus()
        var after = [UInt16](repeating: 0, count: 1024)
        _ = ptb_ime_korean(0, &after, Int32(after.count))
        let afterText = String(decoding: after.prefix { $0 != 0 }, as: UTF16.self)
        let raw = UnsafeMutableRawPointer(e)
        _ = ptb_ime_set_status(raw, 1, 0x1 /* IME_CMODE_HANGUL */)
        await chatPump(0.2)
        var status: [UInt32] = [0, 0, 0]
        _ = ptb_ime_status(raw, &status)
        func state() -> String { "\(q(chat.text))/\(q(WinPlazaChatInput.imeString(e, kind: 0x8)))" }
        var trace: [String] = ["after a pump: \(afterText)"]
        for s: UInt32 in [0x22, 0x25, 0x1F] { await chatTap(s) }   // g k s
        await chatPump(0.2)
        var han = state()
        trace.append("gks \(han)")
        if !han.hasPrefix("'한'") {   // still alphanumeric: the Han/Eng key once, then again
            _ = WinStr.w("").withUnsafeBufferPointer { SendMessageW(e, 0x000C, 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
            await chatVirtualKey(0x15)   // VK_HANGUL
            _ = ptb_ime_status(raw, &status)
            for s: UInt32 in [0x22, 0x25, 0x1F] { await chatTap(s) }
            await chatPump(0.2)
            han = state()
            trace.append("VK_HANGUL (conversion 0x\(String(status[0], radix: 16))) gks \(han)")
        }
        // Judged only when the IME really took the keys (Hangul in the field or a composition string). A later selftest process of the
        // same run can find TSF reporting the text service active while it passes letters through (the earlier process's restore
        // disabled it for the user a moment before): that is the harness, said plainly, not the field.
        let engaged = chat.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
            || !WinPlazaChatInput.imeString(e, kind: 0x8).isEmpty
        guard engaged else {
            await chatClose(chat)
            // Field or harness? The same keys into a plain EDIT of ours in this process: the IME takes them there but not in the field ->
            // the field broke it (FAIL); neither -> the harness could not engage the IME in this process (the workflow requires one
            // process per run that did: "engaged").
            let control = await controlEditTakesHangul()
            forceForeground(hwnd)
            r.add("plaza.chatRealIME", !control.engaged,
                  "not engaged: the field passed letters through (\(han)); a control edit in this process: \(control.detail) -> "
                    + (control.engaged ? "the IME takes keys there but not in the field" : "harness (TSF would not engage here)") + "; TSF: \(actText)")
            return
        }
        for _ in 0..<3 { await chatTap(0x0E); trace.append("BS \(state())") }
        for s: UInt32 in [0x20, 0x25, 0x1F, 0x1F, 0x16, 0x20] { await chatTap(s) }   // d k s s u d
        trace.append("dkssud \(state())")
        let lines0 = c.chatLogLines.count
        await chatTap(0x1C)
        await chatPump(0.3)
        var enters = 1
        if chat.isOpen, c.chatLogLines.count == lines0 { trace.append("Enter 1: \(state()) open"); await chatTap(0x1C); await chatPump(0.3); enters = 2 }
        let sent = c.chatLogLines.count > lines0 ? c.chatLogLines.last?.text ?? "" : "nothing"
        trace.append("sent \(q(sent)) after \(enters) Enter")
        await chatPump(0.35)
        await chatOpen(c, chat)
        _ = chat.focus()
        for s: UInt32 in [0x13, 0x25, 0x10, 0x14] { await chatTap(s) }   // r k q t
        trace.append("rkqt \(state())")
        await chatTap(0x4B, extended: true)
        trace.append("Left \(state()) caret \(chat.selection.start)")
        _ = SendMessageW(e, 0x00B1, 0xFFFF, 0xFFFF)
        for s: UInt32 in [0x12, 0x25, 0x21, 0x13] { await chatTap(s) }   // e k f r
        trace.append("ekfr \(state())")
        await chatTap(0x23)   // h
        trace.append("+h \(state())")
        // Hanja: a fresh 한 composing, the Hanja key opens the candidate list next to the line, the first candidate replaces it. The
        // syllable still being composed is cancelled first (setting the text does not end a composition; the field's own reset does both).
        _ = ptb_ime_finish(raw, 1)
        await chatPump(0.1)
        _ = WinStr.w("").withUnsafeBufferPointer { SendMessageW(e, 0x000C, 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
        for s: UInt32 in [0x22, 0x25, 0x1F] { await chatTap(s) }
        let opens0 = chat.counts.candidateOpens
        await chatVirtualKey(0x19)   // VK_HANJA
        await chatPump(0.4)
        var listing = [UInt16](repeating: 0, count: 2048)
        _ = ptb_ime_candidate_windows(&listing, Int32(listing.count))
        let candidates = String(decoding: listing.prefix { $0 != 0 }, as: UTF16.self)
        var fieldTop = POINT(x: chat.fieldPixels?.x ?? 0, y: chat.fieldPixels?.y ?? 0)
        _ = ClientToScreen(hwnd, &fieldTop)
        var form = [Int32](repeating: 0, count: 10)
        _ = ptb_ime_windows(raw, &form)
        trace.append("Hanja: candidate list opened +\(chat.counts.candidateOpens - opens0), windows [\(candidates)], field at screen (\(fieldTop.x),\(fieldTop.y)) "
            + "height \(chat.fieldPixels?.h ?? 0), our candidate form style 0x\(String(form[3], radix: 16)) at (\(form[4]),\(form[5])) excluding (\(form[6]),\(form[7]))-(\(form[8]),\(form[9]))")
        await chatTap(0x02)   // the first candidate
        await chatPump(0.3)
        let hanja = chat.text
        let isHan = hanja.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        trace.append("1 -> \(q(hanja)) (a Han character: \(isHan))")
        let hanjaOK = isHan && hanja.count == 1 && chat.counts.candidateOpens > opens0
        await chatTap(0x01)
        trace.append("Esc open=\(chat.isOpen)")
        await chatClose(chat)
        // Review item 3: the paths that END a composition themselves, with the real IME holding the syllable in the field's text.
        let ends = await realIMEEndings(r, c, shell, hwnd, chat)
        trace.append(ends.detail)
        r.add("plaza.chatRealIME", activated == 1 && han.hasPrefix("'한'") && sent == "안녕" && hanjaOK && ends.ok,
              "engaged: TSF: \(probeText); activate: \(actText); conversion 0x\(String(status[0], radix: 16)) open=\(status[2]); " + trace.joined(separator: "; "))
    }

    /// `gks` into a plain EDIT of ours (not the chat field) in its own window, with real keys: does the IME take them in this process?
    @MainActor private static func controlEditTakesHangul() async -> (engaged: Bool, detail: String) {
        guard let host = try? WinSinkWindow(className: "PokeTokenBarSelftestImeControl", title: "ime control", style: 0x9000_0000 /* WS_POPUP|WS_VISIBLE */,
                                            exStyle: 0, x: 120, y: 120, width: 240, height: 40),
              let raw = ptb_chat_edit_create(UnsafeMutableRawPointer(host.hwnd), 0, nil, nil),
              let edit = HWND(bitPattern: Int(bitPattern: raw)) else { return (false, "could not be made") }
        defer { ptb_chat_edit_destroy(raw); host.destroy() }
        _ = ptb_chat_edit_place(raw, 0, 0, 240, 40, 1)
        forceForeground(host.hwnd)
        _ = SetFocus(edit)
        await chatPump(0.2)
        _ = ptb_ime_set_status(raw, 1, 0x1)
        await chatPump(0.1)
        var composing = ""
        for (i, s) in [UInt32(0x22), 0x25, 0x1F].enumerated() {
            await chatTap(s)
            if i == 1 { composing = WinPlazaChatInput.imeString(edit, kind: 0x8) }
        }
        await chatPump(0.2)
        var buf = [UInt16](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { p in Int(SendMessageW(edit, 0x000D, WPARAM(p.count), LPARAM(Int(bitPattern: p.baseAddress)))) }
        let text = String(decoding: buf.prefix(max(0, n)), as: UTF16.self)
        let hangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
        _ = ptb_ime_finish(raw, 1)
        return (hangul || !composing.isEmpty, "text \(q(text)), composition after gk \(q(composing))")
    }

    /// With the real IME: `gk` + Esc, `gk` + a click on the map, `gk` + the grid's 🍜, 59 × a + `gksrmf` + Space.
    @MainActor private static func realIMEEndings(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                  _ chat: WinPlazaChatInput) async -> (ok: Bool, detail: String) {
        func comp(_ e: HWND) -> String { WinPlazaChatInput.imeString(e, kind: 0x8) }
        func jamo(_ s: String) -> Bool { s.unicodeScalars.contains { (0x3131...0x318E).contains($0.value) } }
        func reopen() async -> HWND? {
            await chatPump(0.35)
            forceForeground(hwnd)
            await chatOpen(c, chat)
            _ = chat.focus()
            await chatPump(0.15)
            return chat.editHWND
        }
        var parts: [String] = []
        var ok = true
        let lines0 = c.chatLogLines.count
        // (1) gk + Esc: the line closes (a second Esc if the IME takes the first to end its syllable); the next line is empty.
        if let e = await reopen() {
            await chatTap(0x22); await chatTap(0x25)
            let during = "\(q(chat.text))/\(q(comp(e)))"
            await chatTap(0x01)
            await chatPump(0.2)
            var escs = 1
            if chat.isOpen { await chatTap(0x01); await chatPump(0.2); escs = 2 }
            let closed = !chat.isOpen
            let e2 = await reopen() ?? e
            let empty = chat.text.isEmpty && comp(e2).isEmpty
            ok = ok && closed && empty && c.chatLogLines.count == lines0
            parts.append("gk \(during) + Esc x\(escs): closed=\(closed), reopened empty with no composition=\(empty) (\(q(chat.text))/\(q(comp(e2))))")
            await chatClose(chat)
        }
        // (2) gk + a click on the map: closed, nothing sent, the next line empty.
        if let e = await reopen(), let panels = shell.panelsForTesting {
            await chatTap(0x22); await chatTap(0x25)
            let during = "\(q(chat.text))/\(q(comp(e)))"
            let size = shell.stageForTesting?.size ?? CGSize(width: 600, height: 400)
            let map = [CGPoint(x: size.width * 0.5, y: size.height * 0.35), CGPoint(x: size.width * 0.6, y: size.height * 0.5)]
                .first { panels.host(at: $0) == nil && !chat.takes($0) }
            if let map { chatClick(shell, hwnd, at: map) }
            await chatPump(0.4)
            let closed = !chat.isOpen
            let e2 = await reopen() ?? e
            let empty = chat.text.isEmpty && comp(e2).isEmpty
            ok = ok && map != nil && closed && empty && c.chatLogLines.count == lines0
            parts.append("gk \(during) + map click: closed=\(closed), nothing sent=\(c.chatLogLines.count == lines0), reopened empty=\(empty) (\(q(chat.text))/\(q(comp(e2))))")
            await chatClose(chat)
        }
        // (3) gk + the grid's 🍜: the syllable is finished first -> '하🍜'.
        if let e = await reopen(), let bar = chat.barFrame {
            let button = chat.bar.emojiButtonRect
            chatClick(shell, hwnd, at: CGPoint(x: bar.minX + button.midX, y: bar.minY + button.midY))
            await chatPump(0.3)
            await chatTap(0x22); await chatTap(0x25)
            let during = "\(q(chat.text))/\(q(comp(e)))"
            if let grown = chat.barFrame, let i = PlazaChatEmojis.all.firstIndex(of: "🍜") {
                let cell = chat.bar.gridCells[i]
                chatClick(shell, hwnd, at: CGPoint(x: grown.minX + cell.midX, y: grown.minY + cell.midY))
            }
            await chatPump(0.4)
            let text = chat.text, left = comp(e)
            ok = ok && text == "하🍜" && left.isEmpty
            parts.append("gk \(during) + 🍜: \(q(text)) composition left \(q(left))")
            await chatClose(chat)
        }
        // (4) 59 × a + gksrmf + Space: 60 characters, no stray jamo.
        if let e = await reopen() {
            chatPostText(e, String(repeating: "a", count: TeamChat.maxCharacters - 1))
            await chatPump(0.3)
            for s: UInt32 in [0x22, 0x25, 0x1F, 0x13, 0x32, 0x21] { await chatTap(s) }   // g k s r m f
            let during = "\(chat.text.count) chars, composition \(q(comp(e)))"
            await chatTap(0x39)   // Space
            await chatPump(0.3)
            let text = chat.text, left = comp(e)
            let expected = String(repeating: "a", count: TeamChat.maxCharacters - 1) + "한"
            ok = ok && text == expected && !jamo(text) && left.isEmpty
            parts.append("59 x a + gksrmf (\(during)) + Space: \(text.count) characters, ends \(q(String(text.suffix(3)))), stray jamo=\(jamo(text)), composition left \(q(left)) (expected 59 a + 한)")
            await chatClose(chat)
        }
        return (ok, "endings: " + parts.joined(separator: "; "))
    }

    // MARK: - idle, in the still window

    /// The chat line open and focused in a still plaza: nothing is drawn beyond opening it (the caret is the EDIT's own, blinking at
    /// the system rate, drawn by the system), and what the main thread does with and without it.
    @MainActor static func plazaChatIdleCheck(_ r: Recorder, _ shell: WinPlazaWindow) async {
        guard let chat = shell.chatForTesting, let e = chat.editHWND else {
            r.add("plaza.chatIdle", false, "the still window has no chat field")
            return
        }
        _ = await waitUntil(timeout: 0.5) { false }
        let closed0 = shell.stats
        let closedSample = await IdleSampler.measure(seconds: 5, mainThread: WindowsApp.mainThreadID)
        let closed1 = shell.stats
        chat.open()
        shell.focusChatInput()
        _ = await waitUntil(timeout: 1) { false }
        let focused = GetFocus() == e
        let caretOnField = ptb_chat_caret_window().map { HWND(bitPattern: Int(bitPattern: $0)) == e } ?? false
        let renders0 = chat.hud.renderCount
        let s0 = shell.stats
        let openSample = await IdleSampler.measure(seconds: 5, mainThread: WindowsApp.mainThreadID)
        let s1 = shell.stats
        let draws = s1.draws - s0.draws, presents = s1.presents - s0.presents, ticks = s1.ticks - s0.ticks
        let renders = chat.hud.renderCount - renders0
        let blink = ptb_chat_caret_blink_ms()
        chat.close()
        _ = await waitUntil(timeout: 0.3) { false }
        r.add("plaza.chatIdle", draws == 0 && presents == 0 && renders == 0 && ticks > 100 && (!onCI || (focused && caretOnField)),
              "line open and focused in a still plaza, 5 s: ticks=\(ticks) draws=\(draws) presents=\(presents) bar renders=\(renders); field focused=\(focused) "
                + "caret on the field=\(caretOnField) blink \(blink) ms (system); main thread cs with the line \(openSample?.mainContextSwitches ?? -1) "
                + "vs closed \(closedSample?.mainContextSwitches ?? -1) (closed: ticks \(closed1.ticks - closed0.ticks) draws \(closed1.draws - closed0.draws)); "
                + "main cycles open \(openSample?.mainCycles ?? 0) closed \(closedSample?.mainCycles ?? 0)")
    }
}
#endif
