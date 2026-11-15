#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 3: the popover kit's selftest group (`ui.kit.*`). Every check prints one PASS/FAIL line with what it
// measured. Windows of the selftest only; synthetic input (`SendInput`) only when `CI` is set.

extension WindowsSelftest {
    @MainActor static func popoverKitChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopover.probeChecks(r, app)
    }
}

@MainActor enum WindowsSelftestPopover {
    // MARK: - R1: IsDialogMessageW inside the WH_GETMESSAGE hook

    /// The risky path first (plan R1): a window holding an EDIT, a check box, a combo box and a button, registered as a
    /// dialog window, driven by real keys (CI) and posted characters.
    static func probeChecks(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        let dialogsBefore = WinMessageHook.dialogWindowCount
        guard let probe = ProbeWindow(register: true) else {
            r.add("ui.kit.tabOrder", false, "the probe window could not be made: \(GetLastError())")
            return
        }
        probe.show()
        if WindowsSelftest.onCI { WindowsSelftest.forceForeground(probe.window.hwnd) }
        _ = SetFocus(probe.edit)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == probe.edit }
        let foreground = GetForegroundWindow() == probe.window.hwnd

        // ui.kit.tabOrder: Tab x 4 from the edit visits check box, combo box, button, edit; Shift+Tab goes back.
        if WindowsSelftest.onCI {
            var visited: [String] = []
            for _ in 0..<4 {
                let before = GetFocus()
                tap(0x09)
                _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() != before }
                visited.append(probe.name(GetFocus()))
            }
            tap(0x09, shift: true)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() != probe.edit }
            let back = probe.name(GetFocus())
            let ok = visited == ["check", "combo", "button", "edit"] && back == "button"
            r.add("ui.kit.tabOrder", ok, "foreground=\(foreground) Tab x4 from edit: \(visited) (expected [check, combo, button, edit]); "
                  + "Shift+Tab -> \(back); dialog messages=\(WinMessageHook.dialogMessages)")
        } else {
            r.add("ui.kit.tabOrder", true, "skipped: CI not set (the selftest types only on CI)")
        }

        // ui.kit.keys: Space toggles the focused check box; Down moves the combo's selection; Enter on the button clicks it.
        if WindowsSelftest.onCI {
            _ = SetFocus(probe.check)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == probe.check }
            let checkedBefore = SendMessageW(probe.check, 0x00F0 /* BM_GETCHECK */, 0, 0)
            tap(0x20)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { SendMessageW(probe.check, 0x00F0, 0, 0) != checkedBefore }
            let checkedAfter = SendMessageW(probe.check, 0x00F0, 0, 0)
            _ = SetFocus(probe.combo)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == probe.combo }
            tap(0x28)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { SendMessageW(probe.combo, 0x0147 /* CB_GETCURSEL */, 0, 0) == 1 }
            let selection = SendMessageW(probe.combo, 0x0147, 0, 0)
            _ = SetFocus(probe.button)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == probe.button }
            let clicks0 = probe.clicks
            tap(0x0D)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { probe.clicks > clicks0 }
            let ok = checkedBefore == 0 && checkedAfter == 1 && selection == 1 && probe.clicks == clicks0 + 1 && probe.oks == 0
            r.add("ui.kit.keys", ok, "Space on the check box: \(checkedBefore) -> \(checkedAfter); Down on the combo: selection 0 -> \(selection); "
                  + "Enter on the button: clicks +\(probe.clicks - clicks0), IDOK to the window \(probe.oks)")
        } else {
            r.add("ui.kit.keys", true, "skipped: CI not set")
        }

        // ui.kit.text: posted WM_CHAR "Aa" + WM_IME_CHAR U+D55C reach the edit once each, whole, at the runner's ANSI code page.
        _ = SetFocus(probe.edit)
        probe.resetEdit()
        let dialog0 = WinMessageHook.dialogMessages
        _ = PostMessageW(probe.edit, UINT(WM_CHAR), 0x41, 0)
        _ = PostMessageW(probe.edit, UINT(WM_CHAR), 0x61, 0)
        _ = PostMessageW(probe.edit, 0x0286 /* WM_IME_CHAR */, 0xD55C, 0)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { probe.editText.count >= 3 }
        _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
        let text = probe.editText
        // The text is the judge: an edit that leaves WM_IME_CHAR to DefWindowProc gets it again as one WM_CHAR (seen below).
        r.add("ui.kit.text", text == "Aa\u{D55C}" && probe.imeChars == [0xD55C] && Array(probe.chars.prefix(2)) == [0x41, 0x61],
              "edit text=\(hex(text)) (expected [0x41, 0x61, 0xd55c]) WM_CHAR seen=\(hexList(probe.chars)) WM_IME_CHAR seen=\(hexList(probe.imeChars)) "
              + "acp=\(GetACP()) through IsDialogMessageW: \(WinMessageHook.dialogMessages - dialog0) messages")

        // ui.kit.typed: real typed characters (KEYEVENTF_UNICODE: VK_PACKET, translated inside IsDialogMessageW) arrive once.
        if WindowsSelftest.onCI {
            probe.resetEdit()
            _ = SetFocus(probe.edit)
            typeUnicode(0x42)
            typeUnicode(0xD55C)
            _ = await WindowsSelftest.waitUntil(timeout: 2) { probe.editText.count >= 2 }
            _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
            let typed = probe.editText
            r.add("ui.kit.typed", typed == "B\u{D55C}", "typed [0x42, 0xd55c] -> edit text=\(hex(typed)) WM_CHAR seen=\(hexList(probe.chars)) "
                  + "redispatched by the char hook=\(WinMessageHook.redispatchedChars)")
        } else {
            r.add("ui.kit.typed", true, "skipped: CI not set")
        }

        // ui.kit.enterEscape: Enter in the edit reaches its commit (no IDOK to the window, no '\r' in the text); Escape
        // reaches the window as IDCANCEL.
        if WindowsSelftest.onCI {
            probe.resetEdit()
            _ = SetFocus(probe.edit)
            typeUnicode(0x78)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { probe.editText == "x" }
            let commits0 = probe.commits.count, oks0 = probe.oks, escapes0 = probe.escapes
            tap(0x0D)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { probe.commits.count > commits0 }
            _ = await WindowsSelftest.waitUntil(timeout: 0.2) { false }
            tap(0x1B)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { probe.escapes > escapes0 }
            let ok = probe.commits.count == commits0 + 1 && probe.commits.last == "x" && probe.oks == oks0 && probe.escapes == escapes0 + 1
                && probe.editText == "x"
            r.add("ui.kit.enterEscape", ok, "Enter: commits +\(probe.commits.count - commits0) (\(probe.commits.last ?? "-")), IDOK +\(probe.oks - oks0), "
                  + "text after=\(hex(probe.editText)); Escape: IDCANCEL to the window +\(probe.escapes - escapes0)")
        } else {
            r.add("ui.kit.enterEscape", true, "skipped: CI not set")
        }

        // ui.kit.menuKeys: a menu opened from the probe while its edit has the focus gets the keys posted during it; the hook's
        // dialog path leaves them to the menu loop, and the main queue keeps running (WinModalPump).
        await menuKeysCheck(r, probe)

        // ui.kit.imeProbe: is a Korean IME on this machine (the runner usually has none)?
        await imeProbe(r, probe)

        probe.destroy()
        let dialogsAfter = WinMessageHook.dialogWindowCount
        r.add("ui.kit.unregister", dialogsAfter == dialogsBefore && !IsWindow(probe.windowHandleForCheck),
              "registered dialog windows before=\(dialogsBefore) while open=\(dialogsBefore + 1) after destroy=\(dialogsAfter); window gone=\(!IsWindow(probe.windowHandleForCheck)); "
              + "messages left to modal loops=\(WinMessageHook.dialogMessagesLeftToModalLoop)")
    }

    private static func menuKeysCheck(_ r: WindowsSelftest.Recorder, _ probe: ProbeWindow) async {
        guard WindowsSelftest.onCI else {
            r.add("ui.kit.menuKeys", true, "skipped: CI not set")
            return
        }
        _ = SetFocus(probe.edit)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == probe.edit }
        probe.resetEdit()
        guard let menu = CreatePopupMenu() else {
            r.add("ui.kit.menuKeys", false, "CreatePopupMenu failed: \(GetLastError())")
            return
        }
        defer { DestroyMenu(menu) }
        for (i, title) in ["One", "Two"].enumerated() {
            _ = WinStr.w(title).withUnsafeBufferPointer { AppendMenuW(menu, 0 /* MF_STRING */, UINT_PTR(i + 1), $0.baseAddress) }
        }
        let editBits = Int(bitPattern: probe.edit)
        let state = MenuState()
        Thread {
            var waited = 0
            while !state.open, waited < 200 { Thread.sleep(forTimeInterval: 0.01); waited += 1 }
            Thread.sleep(forTimeInterval: 0.3)
            for i in 0..<10 {  // main-queue work while the menu is open
                DispatchQueue.main.async { if state.open { state.ranWhileOpen(i) } }
                Thread.sleep(forTimeInterval: 0.02)
            }
            Thread.sleep(forTimeInterval: 0.3)
            let edit = HWND(bitPattern: editBits)
            _ = PostMessageW(edit, UINT(WM_KEYDOWN), WPARAM(VK_DOWN), 0)
            _ = PostMessageW(edit, UINT(WM_KEYUP), WPARAM(VK_DOWN), LPARAM(Int(bitPattern: UInt(0xC000_0001))))
            Thread.sleep(forTimeInterval: 0.2)
            _ = PostMessageW(edit, UINT(WM_KEYDOWN), WPARAM(VK_RETURN), 0)
            _ = PostMessageW(edit, UINT(WM_KEYUP), WPARAM(VK_RETURN), LPARAM(Int(bitPattern: UInt(0xC000_0001))))
            Thread.sleep(forTimeInterval: 1.5)
            if state.open {  // the keys never reached the menu: close it so the selftest goes on
                _ = PostMessageW(edit, UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
                _ = PostMessageW(edit, UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
            }
        }.start()
        typealias TrackFn = @convention(c) (HMENU?, UINT, Int32, Int32, Int32, HWND?, UnsafePointer<RECT>?) -> Int32
        guard let track = WinDynamic.symbol("user32.dll", "TrackPopupMenu", as: TrackFn.self) else {
            r.add("ui.kit.menuKeys", false, "TrackPopupMenu not found")
            return
        }
        let keysBefore = probe.keyDowns.count, left0 = WinMessageHook.dialogMessagesLeftToModalLoop
        var rect = RECT()
        _ = GetWindowRect(probe.window.hwnd, &rect)
        _ = SetForegroundWindow(probe.window.hwnd)
        WinModalPump.begin("menu")
        state.open = true
        let command = track(menu, UINT(TPM_RETURNCMD | TPM_NONOTIFY), rect.left + 20, rect.top + 20, 0, probe.window.hwnd, nil)
        state.open = false
        WinModalPump.end("menu")
        _ = PostMessageW(probe.window.hwnd, UINT(WM_NULL), 0, 0)
        _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
        let keysInEdit = probe.keyDowns.count - keysBefore
        let ran = state.ranCount
        r.add("ui.kit.menuKeys", command == 1 && keysInEdit == 0 && probe.editText.isEmpty && ran > 0,
              "menu over the probe with the edit focused: posted Down + Return -> command=\(command) (expected 1); key-downs that reached the edit=\(keysInEdit); "
              + "edit text=\(hex(probe.editText)); hook left \(WinMessageHook.dialogMessagesLeftToModalLoop - left0) messages to the menu loop; "
              + "main-queue blocks run while open=\(ran)/10")
    }

    private static func imeProbe(_ r: WindowsSelftest.Recorder, _ probe: ProbeWindow) async {
        guard WindowsSelftest.onCI else {
            r.add("ui.kit.imeProbe", true, "skipped: CI not set (the probe would add a keyboard layout to the user's list)")
            return
        }
        var before = [HKL?](repeating: nil, count: 64)
        let countBefore = GetKeyboardLayoutList(Int32(before.count), &before)
        let current = GetKeyboardLayout(0)
        let korean = LoadKeyboardLayoutW(WinStr.w("00000412"), 0x80 /* KLF_NOTELLSHELL */)
        let isIME = korean.map { ImmIsIME($0) } ?? false
        var detail = "layouts before=\(countBefore) current=\(hexHKL(current)) LoadKeyboardLayout(00000412)=\(hexHKL(korean)) ImmIsIME=\(isIME)"
        if let korean {
            _ = SetFocus(probe.edit)
            probe.resetEdit()
            _ = ActivateKeyboardLayout(korean, 0)
            let himc = ImmGetContext(probe.edit)
            var opened = false
            if let himc {
                opened = ImmSetOpenStatus(himc, true)
                _ = ImmSetConversionStatus(himc, 0x0001 /* IME_CMODE_NATIVE (Hangul) */, 0)
                _ = ImmReleaseContext(probe.edit, himc)
            }
            for vk: UInt16 in [0x47, 0x4B, 0x53] { tap(vk) }  // g k s: ㅎ ㅏ ㄴ = 한 on the 2-set layout
            _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
            tap(0x27)  // Right: ends the composition
            _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
            detail += " context=\(himc != nil) open=\(opened) typed g k s + Right -> edit text=\(hex(probe.editText)) WM_IME_CHAR seen=\(hexList(probe.imeChars)) WM_CHAR seen=\(hexList(probe.chars))"
            _ = ActivateKeyboardLayout(current, 0)
            let loadedByUs = !before.prefix(Int(countBefore)).contains { $0 == korean }
            if loadedByUs { _ = UnloadKeyboardLayout(korean) }
            detail += " unloaded=\(loadedByUs)"
        }
        r.add("ui.kit.imeProbe", true, "informational: " + detail)
    }

    // MARK: - helpers

    private final class MenuState: @unchecked Sendable {
        private let lock = NSLock()
        private var _open = false
        private var ran: Set<Int> = []
        var open: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _open }
            set { lock.lock(); _open = newValue; lock.unlock() }
        }
        func ranWhileOpen(_ i: Int) { lock.lock(); ran.insert(i); lock.unlock() }
        var ranCount: Int { lock.lock(); defer { lock.unlock() }; return ran.count }
    }

    static func tap(_ vk: UInt16, shift: Bool = false) {
        var inputs: [INPUT] = []
        func key(_ code: UInt16, up: Bool) -> INPUT {
            var i = INPUT()
            i.type = DWORD(INPUT_KEYBOARD)
            i.ki.wVk = code
            i.ki.dwFlags = up ? DWORD(KEYEVENTF_KEYUP) : 0
            return i
        }
        if shift { inputs.append(key(0x10, up: false)) }
        inputs.append(key(vk, up: false))
        inputs.append(key(vk, up: true))
        if shift { inputs.append(key(0x10, up: true)) }
        _ = SendInput(UINT(inputs.count), &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    static func typeUnicode(_ unit: UInt16) {
        var inputs = [INPUT(), INPUT()]
        inputs[0].type = DWORD(INPUT_KEYBOARD)
        inputs[0].ki.wScan = unit
        inputs[0].ki.dwFlags = DWORD(KEYEVENTF_UNICODE)
        inputs[1] = inputs[0]
        inputs[1].ki.dwFlags = DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)
        _ = SendInput(2, &inputs, Int32(MemoryLayout<INPUT>.stride))
    }

    static func hex(_ s: String) -> String { hexList(s.utf16.map { UInt32($0) }) }
    static func hexList(_ values: [UInt32]) -> String { "[" + values.map { "0x" + String($0, radix: 16) }.joined(separator: ", ") + "]" }
    static func hexHKL(_ h: HKL?) -> String { h.map { "0x" + String(UInt(bitPattern: Int(bitPattern: $0)), radix: 16) } ?? "nil" }
}

/// The R1 probe: a tool window with four standard controls, registered with the message hook as a dialog window.
@MainActor private final class ProbeWindow {
    static let className = "PokeTokenBarKitProbe"
    let window: WinSinkWindow
    let edit: HWND, check: HWND, combo: HWND, button: HWND
    let windowHandleForCheck: HWND
    private(set) var commits: [String] = []
    private(set) var escapes = 0, oks = 0, clicks = 0
    private(set) var chars: [UInt32] = [], imeChars: [UInt32] = [], keyDowns: [UInt32] = []
    private var swallowReturnChar = false
    private let registered: Bool
    static var current: ProbeWindow?

    init?(register: Bool) {
        let style: DWORD = 0x8000_0000 | 0x0080_0000 | 0x0200_0000  // WS_POPUP | WS_BORDER | WS_CLIPCHILDREN
        let exStyle: DWORD = 0x0000_0080 | 0x0001_0000  // WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT
        guard let made = try? WinSinkWindow(className: Self.className, title: "PokeTokenBar kit probe", style: style, exStyle: exStyle,
                                            x: 60, y: 60, width: 360, height: 200) else { return nil }
        window = made
        windowHandleForCheck = made.hwnd
        let font = GetStockObject(17 /* DEFAULT_GUI_FONT */)
        func child(_ cls: String, _ text: String, _ style: DWORD, _ id: Int, _ y: Int32, _ h: Int32, ex: DWORD = 0) -> HWND? {
            let h = CreateWindowExW(ex, WinStr.w(cls), WinStr.w(text), 0x4000_0000 | 0x1000_0000 | 0x0001_0000 | style,  // WS_CHILD | WS_VISIBLE | WS_TABSTOP
                                    12, y, 320, h, made.hwnd, HMENU(bitPattern: id), GetModuleHandleW(nil), nil)
            if let h, let font { _ = SendMessageW(h, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: font))), 1) }
            return h
        }
        guard let e = child("Edit", "", 0x0080 /* ES_AUTOHSCROLL */, 101, 12, 24, ex: 0x0200 /* WS_EX_CLIENTEDGE */),
              let c = child("Button", "Check box", 0x0003 /* BS_AUTOCHECKBOX */, 102, 44, 24),
              let cb = child("ComboBox", "", 0x0003 /* CBS_DROPDOWNLIST */ | 0x0020_0000 /* WS_VSCROLL */, 103, 76, 160),
              let b = child("Button", "Button", 0x0000 /* BS_PUSHBUTTON */, 104, 112, 28) else {
            made.destroy()
            return nil
        }
        edit = e; check = c; combo = cb; button = b
        for item in ["First", "Second", "Third"] {
            _ = WinStr.w(item).withUnsafeBufferPointer { SendMessageW(cb, 0x0143 /* CB_ADDSTRING */, 0, LPARAM(Int(bitPattern: $0.baseAddress))) }
        }
        _ = SendMessageW(cb, 0x014E /* CB_SETCURSEL */, 0, 0)
        registered = register
        if register { WinMessageHook.registerDialogWindow(made.hwnd) }
        Self.current = self
        _ = SetWindowSubclass(e, probeEditSubclass, 1, 0)
        made.on(UINT(WM_COMMAND)) { [weak self] wParam, _ in
            guard let self else { return nil }
            switch wParam & 0xFFFF {
            case 1: self.oks += 1
            case 2: self.escapes += 1
            case 104 where (wParam >> 16) & 0xFFFF == 0: self.clicks += 1
            default: return nil
            }
            return 0
        }
    }

    func show() {
        _ = SetWindowPos(window.hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW))
    }

    var editText: String {
        var buffer = [UInt16](repeating: 0, count: 256)
        let n = GetWindowTextW(edit, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(n)), as: UTF16.self)
    }

    func resetEdit() {
        _ = SetWindowTextW(edit, WinStr.w(""))
        chars = []
        imeChars = []
    }

    func name(_ h: HWND?) -> String {
        guard let h else { return "none" }
        if h == edit { return "edit" }
        if h == check { return "check" }
        if h == combo { return "combo" }
        if h == button { return "button" }
        return h == window.hwnd ? "window" : "other"
    }

    /// The edit's subclass: counts what arrives, takes Enter as its commit (the Mac's onSubmit) and swallows the '\r' after it.
    fileprivate func editMessage(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case 0x0087:  // WM_GETDLGCODE: ask for Enter, so IsDialogMessageW hands it to the edit instead of IDOK to the window
            if let msg = UnsafePointer<MSG>(bitPattern: Int(lParam)), msg.pointee.message == UINT(WM_KEYDOWN), msg.pointee.wParam == WPARAM(VK_RETURN) {
                return DefSubclassProc(edit, message, wParam, lParam) | 0x0004 /* DLGC_WANTALLKEYS */
            }
            return nil
        case UINT(WM_KEYDOWN):
            keyDowns.append(UInt32(truncatingIfNeeded: wParam))
            if wParam == WPARAM(VK_RETURN) {
                commits.append(editText)
                swallowReturnChar = true
                return 0
            }
            return nil
        case UINT(WM_CHAR):
            if wParam == 0x0D, swallowReturnChar {
                swallowReturnChar = false
                return 0
            }
            chars.append(UInt32(truncatingIfNeeded: wParam))
            return nil
        case 0x0286:  // WM_IME_CHAR
            imeChars.append(UInt32(truncatingIfNeeded: wParam))
            return nil
        default:
            return nil
        }
    }

    func destroy() {
        _ = RemoveWindowSubclass(edit, probeEditSubclass, 1)
        if registered { WinMessageHook.unregisterDialogWindow(window.hwnd) }
        window.destroy()
        Self.current = nil
    }
}

/// One function pointer for SetWindowSubclass and RemoveWindowSubclass (a subclass is identified by it and the id).
nonisolated(unsafe) private let probeEditSubclass: SUBCLASSPROC = { h, m, w, l, _, _ in probeEditProc(h, m, w, l) }

private func probeEditProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let result = MainActor.assumeIsolated({ ProbeWindow.current?.editMessage(message, wParam, lParam) }) { return result }
    return DefSubclassProc(hwnd, message, wParam, lParam)
}
#endif
