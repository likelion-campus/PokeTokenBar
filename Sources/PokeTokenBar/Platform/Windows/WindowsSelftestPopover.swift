#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 3: the popover kit's selftest group (`ui.kit.*`). Every check prints one PASS/FAIL line with what it
// measured. Windows of the selftest only; synthetic input (`SendInput`) only when `CI` is set. With `--dump-ui <dir>` the
// kit gallery (every control and part at 100 % and at a synthetic 144 dpi, high contrast and 150 % text) goes to
// `<dir>/kit/` as PNGs and control-tree JSON.

extension WindowsSelftest {
    @MainActor static func popoverKitChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopover.run(r)
    }

    /// `--popover-kit-idle-probe`: the idle gate's open-and-still kit window (not a `--selftest…` flag: those switch to the
    /// selftest's own settings suite, and the gate's settings, refresh off, are the app's).
    @MainActor static func startPopoverKitIdle() {
        WindowsSelftestPopover.startIdleProbe()
    }
}

@MainActor enum WindowsSelftestPopover {
    static func run(_ r: WindowsSelftest.Recorder) async {
        let start = KitResources.now()
        await keyboardChecks(r)
        await galleryChecks(r)
        await openCloseCheck(r, start: start)
    }

    // MARK: - keyboard and text (R1, D5)

    /// The risky path first (plan R1): the kit's edit, check box, combo box and button in a window registered as a dialog
    /// window, driven by real keys (CI) and posted characters, through `IsDialogMessageW` inside the `WH_GETMESSAGE` hook.
    static func keyboardChecks(_ r: WindowsSelftest.Recorder) async {
        let dialogsBefore = WinMessageHook.dialogWindowCount
        let refs = KeyPage()
        guard let w = KitWindow(heightDIP: 230, build: { _, s in refs.build(s) }) else {
            r.add("ui.kit.tabOrder", false, "the kit window could not be made: \(GetLastError())")
            return
        }
        defer { if !w.isDestroyed { w.destroy() } }
        w.show(activate: true)
        guard let edit = refs.edit, let check = refs.check, let combo = refs.combo, let button = refs.button else {
            r.add("ui.kit.tabOrder", false, "the page's controls were not made")
            return
        }
        _ = SetFocus(edit.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == edit.hwnd }
        let foreground = GetForegroundWindow() == w.hwnd
        func name(_ h: HWND?) -> String {
            [(edit, "edit"), (check, "check"), (combo, "combo"), (button, "button")].first { $0.0.hwnd == h }?.1 ?? (h == nil ? "none" : "other")
        }

        if WindowsSelftest.onCI {
            var visited: [String] = []
            for _ in 0..<4 {
                let before = GetFocus()
                tap(0x09)
                _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() != before }
                visited.append(name(GetFocus()))
            }
            tap(0x09, shift: true)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() != edit.hwnd }
            let back = name(GetFocus())
            r.add("ui.kit.tabOrder", visited == ["check", "combo", "button", "edit"] && back == "button",
                  "foreground=\(foreground) Tab x4 from the edit: \(visited) (expected [check, combo, button, edit]); Shift+Tab -> \(back); "
                  + "messages through IsDialogMessageW=\(WinMessageHook.dialogMessages) registered=\(w.isRegistered)")
        } else {
            r.add("ui.kit.tabOrder", true, "skipped: CI not set (the selftest types only on CI)")
        }

        if WindowsSelftest.onCI {
            var toggled: [Bool] = []
            check.onToggle = { toggled.append($0) }
            _ = SetFocus(check.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == check.hwnd }
            tap(0x20)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { !toggled.isEmpty }
            var selected: [Int] = []
            combo.onSelect = { selected.append($0) }
            _ = SetFocus(combo.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == combo.hwnd }
            tap(0x28)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { !selected.isEmpty }
            var clicks = 0
            button.onClick = { clicks += 1 }
            _ = SetFocus(button.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == button.hwnd }
            tap(0x0D)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { clicks > 0 }
            tap(0x20)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { clicks > 1 }
            r.add("ui.kit.keys", toggled == [true] && selected == [1] && clicks == 2 && w.oks == 0,
                  "Space on the check box -> onToggle \(toggled); Down on the combo box -> onSelect \(selected); Enter then Space on the button -> "
                  + "onClick x\(clicks); IDOK to the window \(w.oks)")
        } else {
            r.add("ui.kit.keys", true, "skipped: CI not set")
        }

        // Posted WM_CHAR "Aa" + WM_IME_CHAR U+D55C reach the edit once each, whole, at the runner's ANSI code page.
        let probe = EditProbe(edit.hwnd)
        _ = SetFocus(edit.hwnd)
        edit.text = ""
        let dialog0 = WinMessageHook.dialogMessages
        _ = PostMessageW(edit.hwnd, UINT(WM_CHAR), 0x41, 0)
        _ = PostMessageW(edit.hwnd, UINT(WM_CHAR), 0x61, 0)
        _ = PostMessageW(edit.hwnd, 0x0286 /* WM_IME_CHAR */, 0xD55C, 0)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { edit.text.utf16.count >= 3 }
        _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
        r.add("ui.kit.text", edit.text == "Aa\u{D55C}" && probe.imeChars == [0xD55C] && Array(probe.chars.prefix(2)) == [0x41, 0x61],
              "edit text=\(hex(edit.text)) (expected [0x41, 0x61, 0xd55c]); WM_CHAR seen=\(hexList(probe.chars)) WM_IME_CHAR seen=\(hexList(probe.imeChars)) "
              + "(an edit leaves WM_IME_CHAR to DefWindowProc, which sends it once more as WM_CHAR: the text shows it once) acp=\(GetACP()) "
              + "through IsDialogMessageW: \(WinMessageHook.dialogMessages - dialog0) messages")

        if WindowsSelftest.onCI {
            edit.text = ""
            probe.reset()
            _ = SetFocus(edit.hwnd)
            typeUnicode(0x42)
            typeUnicode(0xD55C)
            _ = await WindowsSelftest.waitUntil(timeout: 2) { edit.text.utf16.count >= 2 }
            _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
            r.add("ui.kit.typed", edit.text == "B\u{D55C}", "typed [0x42, 0xd55c] (KEYEVENTF_UNICODE) -> edit text=\(hex(edit.text)) WM_CHAR seen=\(hexList(probe.chars))")

            edit.text = ""
            var commits: [String] = []
            edit.onCommit = { commits.append($0) }
            typeUnicode(0x78)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { edit.text == "x" }
            let escapes0 = w.escapes, oks0 = w.oks
            tap(0x0D)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { !commits.isEmpty }
            _ = await WindowsSelftest.waitUntil(timeout: 0.2) { false }
            tap(0x1B)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { w.escapes > escapes0 }
            let onEnter = commits
            // Focus loss commits a changed field; an unchanged one does not commit again.
            typeUnicode(0x79)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { edit.text == "xy" }
            _ = SetFocus(button.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { commits.count > onEnter.count }
            _ = SetFocus(edit.hwnd)
            _ = SetFocus(button.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
            r.add("ui.kit.enterEscape", onEnter == ["x"] && w.oks == oks0 && w.escapes == escapes0 + 1 && commits == ["x", "xy"],
                  "Enter in the edit: onCommit \(onEnter) (no IDOK to the window: +\(w.oks - oks0), text after=\(hex(edit.text))); Escape: IDCANCEL to the window "
                  + "+\(w.escapes - escapes0); focus loss after a change: commits \(commits) (an unchanged field does not commit twice)")
        } else {
            r.add("ui.kit.typed", true, "skipped: CI not set")
            r.add("ui.kit.enterEscape", true, "skipped: CI not set")
        }

        await menuKeysCheck(r, w, edit: edit, probe: probe)
        await imeProbe(r, edit: edit, probe: probe)
        probe.remove()

        let handle = w.hwnd
        w.destroy()
        r.add("ui.kit.unregister", WinMessageHook.dialogWindowCount == dialogsBefore && !IsWindow(handle) && WinControl.liveCount == 0,
              "registered dialog windows before=\(dialogsBefore) while open=\(dialogsBefore + 1) after destroy=\(WinMessageHook.dialogWindowCount); window gone=\(!IsWindow(handle)); "
              + "kit controls alive=\(WinControl.liveCount); messages the hook left to modal loops=\(WinMessageHook.dialogMessagesLeftToModalLoop)")
    }

    /// A menu over the kit window while its edit has the focus: the keys posted during it reach the menu (the hook leaves
    /// them to the menu's loop) and the main queue keeps running (WinModalPump). Opened from a window message, as every
    /// menu of the app is (a click, a tray callback); a second menu opened from inside a main-queue item (a Task) shows the
    /// rule the popover's later tasks must keep: libdispatch's main queue is serial, so nothing queued runs under it.
    private static func menuKeysCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow, edit: WinControl, probe: EditProbe) async {
        guard WindowsSelftest.onCI else {
            r.add("ui.kit.menuKeys", true, "skipped: CI not set")
            return
        }
        _ = SetFocus(edit.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == edit.hwnd }
        edit.text = ""
        probe.reset()
        var fromMessage: MenuRun?
        w.onMenuMessage = { fromMessage = runMenu(over: w, editBits: Int(bitPattern: edit.hwnd)) }
        _ = PostMessageW(w.hwnd, KitWindow.menuMessage, 0, 0)
        _ = await WindowsSelftest.waitUntil(timeout: 10) { fromMessage != nil }
        let inTask = runMenu(over: w, editBits: Int(bitPattern: edit.hwnd))
        _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
        let m = fromMessage ?? MenuRun(command: -1, keyDowns: -1, left: -1, ran: -1)
        r.add("ui.kit.menuKeys", m.command == 1 && m.keyDowns == 0 && edit.text.isEmpty && m.ran > 0 && probe.keyDowns.isEmpty,
              "menu opened from a window message over the focused edit: posted Down + Return -> command=\(m.command) (expected 1); key-downs that reached the edit=\(m.keyDowns); "
              + "edit text=\(hex(edit.text)); the hook left \(m.left) messages to the menu loop; main-queue blocks run while open=\(m.ran)/10. "
              + "Informational, the same menu opened inside a main-queue item (a Task): command=\(inTask.command) blocks run while open=\(inTask.ran)/10 "
              + "(modal loops must start from window messages)")
    }

    private struct MenuRun { var command: Int32, keyDowns: Int, left: Int, ran: Int }

    private static func runMenu(over w: KitWindow, editBits: Int) -> MenuRun {
        guard let menu = CreatePopupMenu() else { return MenuRun(command: -2, keyDowns: 0, left: 0, ran: 0) }
        defer { _ = DestroyMenu(menu) }
        for (i, title) in ["One", "Two"].enumerated() {
            _ = WinStr.w(title).withUnsafeBufferPointer { AppendMenuW(menu, 0 /* MF_STRING */, UINT_PTR(i + 1), $0.baseAddress) }
        }
        let state = MenuState()
        let ownerBits = Int(bitPattern: w.hwnd)
        Thread {
            var waited = 0
            while !state.open, waited < 300 { Thread.sleep(forTimeInterval: 0.01); waited += 1 }
            Thread.sleep(forTimeInterval: 0.3)
            for i in 0..<10 {
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
            // The keys never reached the menu: WM_CANCELMODE to the owner ends menu mode whoever reads the queue.
            for _ in 0..<5 where state.open {
                _ = PostMessageW(HWND(bitPattern: ownerBits), 0x001F /* WM_CANCELMODE */, 0, 0)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }.start()
        typealias TrackFn = @convention(c) (HMENU?, UINT, Int32, Int32, Int32, HWND?, UnsafePointer<RECT>?) -> Int32
        guard let track = WinDynamic.symbol("user32.dll", "TrackPopupMenu", as: TrackFn.self) else { return MenuRun(command: -3, keyDowns: 0, left: 0, ran: 0) }
        let probeKeys = EditProbe.keyDownCount, left0 = WinMessageHook.dialogMessagesLeftToModalLoop
        var rect = RECT()
        _ = GetWindowRect(w.hwnd, &rect)
        _ = SetForegroundWindow(w.hwnd)
        WinModalPump.begin("menu")
        state.open = true
        let command = track(menu, UINT(TPM_RETURNCMD | TPM_NONOTIFY), rect.left + 20, rect.top + 20, 0, w.hwnd, nil)
        state.open = false
        WinModalPump.end("menu")
        _ = PostMessageW(w.hwnd, UINT(WM_NULL), 0, 0)
        return MenuRun(command: command, keyDowns: EditProbe.keyDownCount - probeKeys, left: WinMessageHook.dialogMessagesLeftToModalLoop - left0,
                       ran: state.ranCount)
    }

    /// Is a Korean IME on this machine? The runner's Korean layout loads but types ASCII (no Hangul TIP); a PC with one
    /// composes 한 here. Informational: composition is a PC item.
    private static func imeProbe(_ r: WindowsSelftest.Recorder, edit: WinControl, probe: EditProbe) async {
        guard WindowsSelftest.onCI else {
            r.add("ui.kit.imeProbe", true, "skipped: CI not set (the probe would add a keyboard layout to the user's list)")
            return
        }
        var before = [HKL?](repeating: nil, count: 64)
        let countBefore = GetKeyboardLayoutList(Int32(before.count), &before)
        let current = GetKeyboardLayout(0)
        let korean = LoadKeyboardLayoutW(WinStr.w("00000412"), 0x80 /* KLF_NOTELLSHELL */)
        var detail = "layouts before=\(countBefore) current=\(hexHKL(current)) LoadKeyboardLayout(00000412)=\(hexHKL(korean)) ImmIsIME=\(korean.map { ImmIsIME($0) } ?? false)"
        if let korean {
            _ = SetFocus(edit.hwnd)
            _ = ActivateKeyboardLayout(korean, 0)
            for (label, useHangulKey) in [("conversion status", false), ("VK_HANGUL", true)] {
                edit.text = ""
                probe.reset()
                let himc = ImmGetContext(edit.hwnd)
                if let himc {
                    _ = ImmSetOpenStatus(himc, true)
                    if !useHangulKey { _ = ImmSetConversionStatus(himc, 0x0001 /* IME_CMODE_NATIVE */, 0) }
                    _ = ImmReleaseContext(edit.hwnd, himc)
                }
                if useHangulKey { tap(0x15) }  // VK_HANGUL: Hangul mode on
                for vk: UInt16 in [0x47, 0x4B, 0x53] { tap(vk) }  // g k s: ㅎ ㅏ ㄴ = 한 on the 2-set layout
                _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
                tap(0x27)  // Right: ends the composition
                _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
                var conversion: DWORD = 0, sentence: DWORD = 0
                if let himc = ImmGetContext(edit.hwnd) {
                    _ = ImmGetConversionStatus(himc, &conversion, &sentence)
                    _ = ImmReleaseContext(edit.hwnd, himc)
                }
                detail += "; via \(label): g k s + Right -> edit text=\(hex(edit.text)) conversion=0x\(String(conversion, radix: 16)) "
                    + "WM_IME_CHAR=\(hexList(probe.imeChars)) WM_CHAR=\(hexList(probe.chars)) composition messages=\(probe.compositionMessages)"
                if useHangulKey { tap(0x15) }
            }
            _ = ActivateKeyboardLayout(current, 0)
            let loadedByUs = !before.prefix(Int(countBefore)).contains { $0 == korean }
            if loadedByUs { _ = UnloadKeyboardLayout(korean) }
            detail += "; unloaded=\(loadedByUs)"
        }
        r.add("ui.kit.imeProbe", true, "informational: " + detail)
    }

    // MARK: - the gallery: fonts, glyphs, tooltips, drawn part, scrolling, DPI, captures, idle

    static func galleryChecks(_ r: WindowsSelftest.Recorder) async {
        let dumpDir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("kit", isDirectory: true)
        if let dumpDir { try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true) }

        // A page of normal height: scrolling, the drawn part, DPI changes, idle.
        let page = GalleryPage()
        guard let w = KitWindow(heightDIP: 520, build: { _, s in page.build(s) }) else {
            r.add("ui.kit.drawn", false, "the gallery window could not be made: \(GetLastError())")
            return
        }
        defer { if !w.isDestroyed { w.destroy() } }
        w.show(activate: true)
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }

        fontAndGlyphChecks(r, w)
        await drawnChecks(r, w, page)
        tooltipCheck(r, w, page)
        await scrollChecks(r, w, page)
        await dpiCheck(r, w, page)
        await idleCheck(r, w, page)
        w.destroy()

        // Full-height pages for the captures and the tree checks.
        await captureChecks(r, into: dumpDir)
    }

    private static func fontAndGlyphChecks(_ r: WindowsSelftest.Recorder, _ w: KitWindow) {
        let fonts = w.ctx.fonts
        let body = logFont(fonts.font(.body)), large = logFont(fonts.font(.largeBold))
        r.add("ui.kit.fonts", body.lfHeight == -Int32(PopoverTextStyle.body.pixelSize(dpi: Int(w.ctx.dpi), textScale: w.ctx.textScale)) && large.lfWeight == 700,
              "face=\(fonts.face) (Segoe UI Variable Text installed: \(WinFonts.isInstalled(WinFonts.variableText))) icons=\(fonts.iconFace) dpi=\(w.ctx.dpi) "
              + "textScale=\(w.ctx.textScale) highContrast=\(w.ctx.highContrast) body lfHeight=\(body.lfHeight) 28 bold lfHeight=\(large.lfHeight) weight=\(large.lfWeight) "
              + "semibold face=\(WinFonts.face(base: fonts.face, weight: 600).0) fonts made=\(fonts.count) brushes=\(w.ctx.colors.count)")
        var missing: [String] = []
        var checked = 0
        let dc = CreateCompatibleDC(nil)
        defer { _ = DeleteDC(dc) }
        for fluent in [true, false] where WinFonts.isInstalled(fluent ? WinFonts.fluentIcons : WinFonts.mdl2Assets) {
            var lf = LOGFONTW()
            lf.lfHeight = -16
            lf.lfCharSet = 1
            WinFonts.setFaceName(&lf, fluent ? WinFonts.fluentIcons : WinFonts.mdl2Assets)
            guard let font = CreateFontIndirectW(&lf) else { continue }
            let old = SelectObject(dc, UnsafeMutableRawPointer(font))
            for (symbol, entry) in PopoverGlyphTable.entries.sorted(by: { $0.key < $1.key }) {
                guard let cp = entry.codePoint(fluent: fluent) else { continue }
                var units: [UInt16] = [cp], index: [UInt16] = [0]
                _ = GetGlyphIndicesW(dc, &units, 1, &index, 1 /* GGI_MARK_NONEXISTING_GLYPHS */)
                checked += 1
                if index[0] == 0xFFFF { missing.append("\(fluent ? "Fluent" : "MDL2") \(symbol)") }
            }
            _ = SelectObject(dc, old)
            _ = DeleteObject(UnsafeMutableRawPointer(font))
        }
        let fallbacks = PopoverGlyphTable.entries.filter { $0.value.fallback != nil }.keys.sorted()
        r.add("ui.kit.glyphs", missing.isEmpty && checked > 0,
              "\(checked) code points checked (Fluent installed: \(WinFonts.isInstalled(WinFonts.fluentIcons)), MDL2 installed: \(WinFonts.isInstalled(WinFonts.mdl2Assets))); "
              + "missing=\(missing); drawn as text instead (no glyph in either font): \(fallbacks)")
    }

    private static func drawnChecks(_ r: WindowsSelftest.Recorder, _ w: KitWindow, _ page: GalleryPage) async {
        guard let view = page.drawn, let part = page.part else {
            r.add("ui.kit.drawn", false, "no drawn view on the page")
            return
        }
        let scale = w.ctx.scale
        let fill = view.pixel(x: Int(4 * scale), y: Int(43 * scale)) ?? []
        let track = view.pixel(x: Int((KitFixturePart.barWidth(view) - 4) * scale), y: Int(43 * scale)) ?? []
        let items = view.items.map { "\(WinKit.className($0.hwnd)) '\(WinKit.text(of: $0.hwnd))' tabStop=\(GetWindowLongW($0.hwnd, -16) & 0x0001_0000 != 0)" }
        let paints0 = view.stats.paints
        _ = await WindowsSelftest.waitUntil(timeout: 1) { false }
        let paintsIdle = view.stats.paints - paints0
        let green = [UInt8(0x59), 0xC7, 0x34, 255]  // the FIXTURE bar's systemGreen as B, G, R, A
        var hits: [String] = []
        view.onHit = { hit in hits.append(hit.action); part.countUp() }
        let button = view.items.first { $0.kind == .drawnItem && WinKit.className($0.hwnd) == "Button" }
        let renders0 = view.stats.renders
        if let button { WinKit.send(button.hwnd, 0x00F5 /* BM_CLICK */) }
        _ = await WindowsSelftest.waitUntil(timeout: 2) { view.stats.renders > renders0 }
        // A click on the picture where the part has no hit reports nothing.
        WinKit.send(view.hwnd, 0x0201, 1, Int(2 * scale) << 16 | Int(2 * scale))
        WinKit.send(view.hwnd, 0x0202, 0, Int(2 * scale) << 16 | Int(2 * scale))
        let afterClick = view.items.map { WinKit.text(of: $0.hwnd) }
        var keyHit = "skipped (CI not set)"
        if WindowsSelftest.onCI, let again = view.items.first(where: { WinKit.className($0.hwnd) == "Button" }) {
            _ = SetFocus(again.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetFocus() == again.hwnd }
            let before = hits.count
            tap(0x0D)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { hits.count > before }
            keyHit = "Enter on the focused item -> hits \(hits.count - before)"
        }
        let ok = Array(fill.prefix(4)) == green && track.count == 4 && track[3] < 64 && items.count == 2 && hits.first == "countUp"
            && afterClick.contains { $0.contains("40 %") } && paintsIdle == 0 && view.stats.composes >= 2
        r.add("ui.kit.drawn", ok,
              "picture \(view.pixelSize.cx)x\(view.pixelSize.cy) px at scale \(scale): fill pixel BGRA=\(fill) (expected \(green)), track pixel=\(track); "
              + "accessibility children=\(items); a press of the button item -> hits \(hits) -> part re-rendered (renders=\(view.stats.renders), children now \(afterClick)); "
              + "a click outside every hit -> nothing; \(keyHit); paints in 1 s idle=\(paintsIdle); stats=\(view.stats)")
    }

    private static func tooltipCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow, _ page: GalleryPage) {
        let tips = w.ctx.tooltips
        r.add("ui.kit.tooltips", tips.initialDelay == WinTooltips.initialDelayMs && tips.count >= page.tooltipCount && tips.hwnd != nil,
              "tooltip window=\(tips.hwnd != nil) TTDT_INITIAL=\(tips.initialDelay) ms (the Mac app's NSInitialToolTipDelay \(WinTooltips.initialDelayMs)); "
              + "tools=\(tips.count) (glyph buttons and the drawn part's rect: at least \(page.tooltipCount))")
    }

    private static func scrollChecks(_ r: WindowsSelftest.Recorder, _ w: KitWindow, _ page: GalleryPage) async {
        guard let area = w.scroll, let first = page.styleLabel, let last = page.lastField else {
            r.add("ui.kit.scroll", false, "no scroll area")
            return
        }
        area.scroll(to: 0)
        var lines: UINT = 3
        _ = SystemParametersInfoW(0x0068, 0, &lines, 0)
        // One notch down sent to a label: it reaches the scroll area through its parents.
        WinKit.send(first.hwnd, 0x020A, Int(UInt32(UInt16(bitPattern: -120)) << 16), 0)
        let afterWheel = area.offset
        let expected = lines == UInt32.max ? area.viewportHeight : Int32(lines) * w.ctx.px(WinScrollArea.lineDIP)
        // Touchpad parts add up to the notch.
        for _ in 0..<8 { WinKit.send(first.hwnd, 0x020A, Int(UInt32(UInt16(bitPattern: -15)) << 16), 0) }
        let afterParts = area.offset
        // The keyboard focus on a control below the viewport brings it into view.
        area.scroll(to: 0)
        _ = SetFocus(last.hwnd)
        let r0 = WinKit.rect(last.hwnd, in: area.viewport.hwnd)
        let visible = r0.top >= 0 && r0.bottom <= area.viewportHeight
        // A real thumb drag (CI): the scroll bar's own modal loop, served by WinModalPump.
        var drag = "skipped (CI not set)"
        var dragOK = true
        if WindowsSelftest.onCI {
            area.scroll(to: 0)
            _ = SetFocus(first.hwnd)
            var sbi = SCROLLBARINFO()
            sbi.cbSize = DWORD(MemoryLayout<SCROLLBARINFO>.size)
            _ = GetScrollBarInfo(area.viewport.hwnd, Int32(bitPattern: 0xFFFF_FFFB) /* OBJID_VSCROLL */, &sbi)
            let x = (sbi.rcScrollBar.left + sbi.rcScrollBar.right) / 2
            let y = sbi.rcScrollBar.top + (sbi.xyThumbTop + sbi.xyThumbBottom) / 2
            let observed = DepthBox()
            let drags0 = area.stats.thumbDrags, offset0 = area.offset
            Thread {
                mouse(x: x, y: y, flags: 0x0001 | 0x8000)  // MOVE | ABSOLUTE
                Thread.sleep(forTimeInterval: 0.1)
                mouse(x: x, y: y, flags: 0x0002)  // LEFTDOWN
                Thread.sleep(forTimeInterval: 0.2)
                for i in 1...6 {
                    mouse(x: x, y: y + Int32(i * 15), flags: 0x0001 | 0x8000)
                    DispatchQueue.main.async { MainActor.assumeIsolated { observed.add(WinModalPump.depth) } }
                    Thread.sleep(forTimeInterval: 0.08)
                }
                Thread.sleep(forTimeInterval: 0.2)
                mouse(x: x, y: y + 90, flags: 0x0004)  // LEFTUP
                observed.finish()
            }.start()
            _ = await WindowsSelftest.waitUntil(timeout: 5) { observed.isFinished }
            _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
            let depths = observed.values
            dragOK = area.stats.thumbDrags > drags0 && area.offset > offset0 && depths.contains(1) && WinModalPump.depth == 0
            drag = "thumb at screen (\(x),\(y)) dragged 90 px: drags +\(area.stats.thumbDrags - drags0) offset \(offset0) -> \(area.offset); main-queue blocks "
                + "run during the drag saw pump depth \(depths) (1 = inside WinModalPump); depth after=\(WinModalPump.depth); SB_THUMBTRACK saw depth \(area.stats.pumpDepthDuringDrag)"
        }
        r.add("ui.kit.scroll", afterWheel == expected && afterParts == 2 * expected && visible && dragOK,
              "content \(area.contentHeight) px in a \(area.viewportHeight) px viewport, width \(area.contentWidth) px beside the bar: one wheel notch "
              + "(\(lines) lines x \(WinScrollArea.lineDIP) DIP) -> offset \(afterWheel) (expected \(expected)); 8 touchpad parts of 15 -> \(afterParts) "
              + "(expected \(2 * expected)); focus on the last field -> offset \(area.offset), field at \(r0.top)...\(r0.bottom) inside=\(visible); \(drag)")
    }

    private static func dpiCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow, _ page: GalleryPage) async {
        var before = RECT()
        _ = GetWindowRect(w.hwnd, &before)
        var suggested = RECT(left: before.left, top: before.top, right: before.left + (before.right - before.left) * 3 / 2,
                             bottom: before.top + (before.bottom - before.top) * 3 / 2)
        _ = withUnsafeMutablePointer(to: &suggested) { WinKit.send(w.hwnd, 0x02E0, 144 | 144 << 16, Int(bitPattern: $0)) }
        var after = RECT()
        _ = GetWindowRect(w.hwnd, &after)
        let heights = Set(w.stack?.controls.compactMap { c -> Int32? in
            let font = WinKit.send(c.hwnd, 0x0031 /* WM_GETFONT */)
            return font == 0 ? nil : logFont(HFONT(bitPattern: font)).lfHeight
        } ?? [])
        let made = Set([PopoverTextStyle.body, .callout, .caption, .caption2, .headline, .title3, .largeBold].map { w.ctx.fonts.height($0) })
        let card = w.stack?.frames?.sections.compactMap { $0?.card }.first
        let atSuggested = after.left == suggested.left && after.top == suggested.top && after.right == suggested.right && after.bottom == suggested.bottom
        let ok144 = w.ctx.dpi == 144 && atSuggested && heights.isSubset(of: made) && !heights.isEmpty && card?.minX == 24
        let detail144 = "WM_DPICHANGED 144: context dpi=\(w.ctx.dpi) rebuilds=\(w.rebuilds) window=\(atSuggested ? "the suggested rect" : "(\(after.left),\(after.top),\(after.right),\(after.bottom))") "
            + "control font heights=\(heights.sorted()) all from the 144 dpi set \(made.sorted())=\(heights.isSubset(of: made)) first card x=\(card.map { "\($0.minX)" } ?? "-") (24 = 16 DIP x 1.5)"
        var back = before
        _ = withUnsafeMutablePointer(to: &back) { WinKit.send(w.hwnd, 0x02E0, 96 | 96 << 16, Int(bitPattern: $0)) }
        let body96 = logFont(HFONT(bitPattern: WinKit.send(page.styleLabel?.hwnd, 0x0031))).lfHeight
        r.add("ui.kit.dpi", ok144 && w.ctx.dpi == 96 && body96 == -13,
              detail144 + "; back to 96: dpi=\(w.ctx.dpi) body lfHeight=\(body96) (the page is built again at each DPI: comctl32 controls keep the font they were given, R6)")
    }

    /// The open page with nothing changing: the kit adds no timer and paints nothing. A focused edit's caret blinks only
    /// for Windows' caret timeout (5 s) after the last input, so the window is measured after that.
    private static func idleCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow, _ page: GalleryPage) async {
        if WindowsSelftest.onCI { WindowsSelftest.forceForeground(w.hwnd) }
        if let field = page.firstField { _ = SetFocus(field.hwnd) }
        _ = await WindowsSelftest.waitUntil(timeout: 7) { false }
        let paints0 = (w.scroll?.content.paints ?? 0) + (page.drawn?.stats.paints ?? 0)
        let seconds = 10.0
        guard let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID) else {
            r.add("ui.kit.idle", false, "measurement failed")
            return
        }
        let paints = (w.scroll?.content.paints ?? 0) + (page.drawn?.stats.paints ?? 0) - paints0
        r.add("ui.kit.idle", sample.mainContextSwitches <= 6 && paints == 0 && !WinModalPump.timerLive,
              "kit page open, focus in a field (caret timeout passed), \(Int(seconds)) s: main_thread_cs=\(sample.mainContextSwitches) (budget 6) "
              + "main_thread_cycles=\(sample.mainCycles) process_cycles=\(sample.processCycles) pane+part paints=\(paints) pump timer live=\(WinModalPump.timerLive); "
              + "busy_threads=[\(sample.busy)]")
    }

    // MARK: - captures and the control tree (D19)

    private static func captureChecks(_ r: WindowsSelftest.Recorder, into dir: URL?) async {
        var lines: [String] = []
        var allOK = true
        let variants: [(name: String, dpi: UINT?, textScale: Double?, highContrast: Bool?)] = [
            ("100", nil, 1, false), ("150", 144, 1, false), ("text150", nil, 1.5, false), ("hc", nil, 1, true),
        ]
        for v in variants {
            let page = GalleryPage()
            guard let w = KitWindow(heightDIP: 400, dpi: v.dpi, textScale: v.textScale, highContrast: v.highContrast, register: true,
                                    origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else {
                lines.append("\(v.name): no window")
                allOK = false
                continue
            }
            w.fitToContent()
            w.show(activate: false)
            _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))  // INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW
            _ = await WindowsSelftest.waitUntil(timeout: 0.4) { false }
            let tree = KitTree.collect(w)
            let checks = tree.check(w)
            allOK = allOK && checks.ok
            var wrote = "no --dump-ui"
            if let dir {
                let png = capture(w).map { WinUIDump.write($0, to: dir.appendingPathComponent("kit-\(v.name).png")) } ?? -1
                let json = tree.write(to: dir.appendingPathComponent("kit-tree-\(v.name).json"))
                wrote = "png=\(png == 0 ? "kit-\(v.name).png" : "FAILED \(png)") tree=\(json)"
                if png != 0 { allOK = false }
            }
            lines.append("\(v.name) (dpi \(w.ctx.dpi), text x\(w.ctx.textScale), high contrast \(w.ctx.highContrast)): client \(w.clientSize.cx)x\(w.clientSize.cy) px, "
                         + "\(tree.nodes.count) windows; \(checks.summary); \(wrote)")
            w.destroy()
        }
        if let dir {
            let sheet = GlyphSheet.render()
            let wrote = sheet.map { WinUIDump.write($0, to: dir.appendingPathComponent("glyphs.png")) } ?? -1
            lines.append("glyph sheet=\(wrote == 0 ? "glyphs.png" : "FAILED \(wrote)")")
            allOK = allOK && wrote == 0
            if WindowsSelftest.onCI { lines.append(await focusCapture(into: dir)) }
        }
        r.add(dir == nil ? "ui.kit.tree" : "ui.kit.capture", allOK, lines.joined(separator: " | "))
    }

    /// The focus rectangles after keyboard use: Tab into the page and capture it.
    private static func focusCapture(into dir: URL) async -> String {
        let page = GalleryPage()
        guard let w = KitWindow(heightDIP: 300, origin: POINT(x: 0, y: 0), build: { _, s in page.buildButtons(s) }) else { return "focus: no window" }
        defer { w.destroy() }
        w.show(activate: true)
        _ = SetFocus(page.firstButton?.hwnd)
        tap(0x09)
        tap(0x09)
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
        let focused = WinKit.text(of: GetFocus())
        let png = capture(w).map { WinUIDump.write($0, to: dir.appendingPathComponent("kit-focus-100.png")) } ?? -1
        return "focus capture after Tab x2: focus on '\(focused)' png=\(png == 0 ? "kit-focus-100.png" : "FAILED \(png)")"
    }

    private static func capture(_ w: KitWindow) -> WinUIDump.Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(w.hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    // MARK: - open and close: nothing left behind

    private static func openCloseCheck(_ r: WindowsSelftest.Recorder, start: KitResources) async {
        var cycles: [KitResources] = []
        for _ in 0..<4 {
            let page = GalleryPage()
            guard let w = KitWindow(heightDIP: 520, build: { _, s in page.build(s) }) else { break }
            w.show(activate: false)
            _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
            w.destroy()
            _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
            cycles.append(KitResources.now())
        }
        guard let warm = cycles.first, cycles.count == 4 else {
            r.add("ui.kit.openClose3", false, "the window could not be made")
            return
        }
        let last = cycles[3]
        let ok = last.gdi - warm.gdi <= 5 && last.user - warm.user <= 5 && last.handles - warm.handles <= 10 && last.controls == 0 && last.dialogs == start.dialogs
            && last.pumpDepth == 0 && !WinModalPump.timerLive
        r.add("ui.kit.openClose3", ok,
              "before the group: \(start); after a warm-up open/close: \(warm); after 3 more: \(cycles.dropFirst().map { "\($0)" }.joined(separator: " / ")) "
              + "(budget over the warm-up: GDI +5, USER +5, handles +10; no kit control, dialog registration or pump timer left)")
    }

    // MARK: - the idle gate's probe

    private static var idleWindow: KitWindow?

    static func startIdleProbe() {
        Task { @MainActor in
            _ = await WindowsSelftest.waitUntil(timeout: 5) { false }
            let page = GalleryPage()
            guard let w = KitWindow(heightDIP: 520, build: { _, s in page.build(s) }) else {
                AppLog.write("popover kit idle probe: no window (\(GetLastError()))")
                return
            }
            idleWindow = w
            w.show(activate: WindowsSelftest.onCI)
            if let field = page.firstField { _ = SetFocus(field.hwnd) }
            AppLog.write("popover kit idle probe: open dpi=\(w.ctx.dpi) controls=\(WinControl.liveCount) focus in a field=\(GetFocus() == page.firstField?.hwnd)")
        }
    }

    // MARK: - helpers

    static func logFont(_ font: HFONT?) -> LOGFONTW {
        var lf = LOGFONTW()
        _ = GetObjectW(UnsafeMutableRawPointer(font), Int32(MemoryLayout<LOGFONTW>.size), &lf)
        return lf
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

    /// A mouse event at screen pixels (absolute moves are normalised to 0…65535 over the primary screen).
    nonisolated static func mouse(x: Int32, y: Int32, flags: DWORD) {
        var input = INPUT()
        input.type = DWORD(INPUT_MOUSE)
        let sw = max(2, GetSystemMetrics(SM_CXSCREEN)), sh = max(2, GetSystemMetrics(SM_CYSCREEN))
        input.mi.dx = x * 65535 / (sw - 1)
        input.mi.dy = y * 65535 / (sh - 1)
        input.mi.dwFlags = flags
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.stride))
    }

    static func hex(_ s: String) -> String { hexList(s.utf16.map { UInt32($0) }) }
    static func hexList(_ values: [UInt32]) -> String { "[" + values.map { "0x" + String($0, radix: 16) }.joined(separator: ", ") + "]" }
    static func hexHKL(_ h: HKL?) -> String { h.map { "0x" + String(UInt(bitPattern: Int(bitPattern: $0)), radix: 16) } ?? "nil" }

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

    private final class DepthBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        private var done = false
        func add(_ d: Int) { lock.lock(); items.append(d); lock.unlock() }
        func finish() { lock.lock(); done = true; lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }
}

/// GDI and USER objects, handles, kit controls, dialog registrations and the pump: what a popover must give back on close.
struct KitResources: CustomStringConvertible {
    var gdi: Int, user: Int, handles: Int, controls: Int, dialogs: Int, pumpDepth: Int

    @MainActor static func now() -> KitResources {
        let process = GetCurrentProcess()
        return KitResources(gdi: Int(GetGuiResources(process, 0 /* GR_GDIOBJECTS */)), user: Int(GetGuiResources(process, 1 /* GR_USEROBJECTS */)),
                            handles: Int(ptb_process_handle_count()), controls: WinControl.liveCount, dialogs: WinMessageHook.dialogWindowCount,
                            pumpDepth: WinModalPump.depth)
    }

    var description: String { "gdi=\(gdi) user=\(user) handles=\(handles) controls=\(controls) dialogs=\(dialogs)" }
}

/// A top-level kit window of the selftest: the popover's window style (a tool window: no taskbar button, not in Alt+Tab),
/// a scroll area with a `WinStack` page, registered as a dialog window, rebuilt on `WM_DPICHANGED` (R6) and on system
/// colour or text-size changes. Task 4's `WinPopover` is the app's own; this one only proves the kit.
@MainActor final class KitWindow {
    static let className = "PokeTokenBarKitTest"
    static let menuMessage = UINT(WM_APP) + 0x60

    let window: WinSinkWindow
    var hwnd: HWND { window.hwnd }
    private(set) var ctx: WinUIContext
    private(set) var scroll: WinScrollArea?
    private(set) var stack: WinStack?
    private var router: WinControlRouter?
    private let build: (KitWindow, WinStack) -> Void
    private let widthDIP: CGFloat
    private var heightDIP: CGFloat
    private let textScale: Double?, highContrast: Bool?
    let isRegistered: Bool
    private(set) var escapes = 0, oks = 0, rebuilds = 0
    var onMenuMessage: (() -> Void)?
    private(set) var isDestroyed = false

    init?(widthDIP: CGFloat = PopoverWindowMetrics.width, heightDIP: CGFloat, dpi: UINT? = nil, textScale: Double? = nil, highContrast: Bool? = nil,
          register: Bool = true, origin: POINT = POINT(x: 40, y: 40), build: @escaping (KitWindow, WinStack) -> Void) {
        let style: DWORD = 0x8000_0000 | 0x0080_0000 | 0x0200_0000  // WS_POPUP | WS_BORDER | WS_CLIPCHILDREN
        let exStyle: DWORD = 0x0000_0080 | 0x0001_0000  // WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT
        guard let made = try? WinSinkWindow(className: Self.className, title: "PokeTokenBar kit", style: style, exStyle: exStyle,
                                            x: origin.x, y: origin.y, width: 100, height: 100) else { return nil }
        let context = WinUIContext(dpi: dpi ?? WinUIContext.dpi(of: made.hwnd), owner: made.hwnd, textScale: textScale, highContrast: highContrast)
        window = made
        ctx = context
        self.build = build
        self.widthDIP = widthDIP
        self.heightDIP = heightDIP
        self.textScale = textScale
        self.highContrast = highContrast
        isRegistered = register
        router = WinControlRouter(window: made)
        if register { WinMessageHook.registerDialogWindow(made.hwnd) }
        made.on(UINT(WM_COMMAND)) { [weak self] wParam, lParam in
            guard let self, lParam == 0 || WinControl.control(HWND(bitPattern: Int(lParam))) == nil else { return nil }
            switch WinKit.loWord(wParam) {
            case 1: self.oks += 1  // IDOK: Enter where no control takes it
            case 2: self.escapes += 1  // IDCANCEL: Escape (the popover closes or goes back, D3)
            default: return nil
            }
            return 0
        }
        made.on(0x02E0 /* WM_DPICHANGED */) { [weak self] wParam, lParam in
            guard let self else { return nil }
            self.rebuild(dpi: UINT(WinKit.loWord(wParam)))
            if let r = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
                _ = SetWindowPos(self.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
                self.layoutToClient()
            }
            return 0
        }
        for message: UINT in [0x001A /* WM_SETTINGCHANGE */, 0x0015 /* WM_SYSCOLORCHANGE */, 0x031A /* WM_THEMECHANGED */] {
            made.on(message) { [weak self] _, _ in
                guard let self else { return nil }
                self.rebuild(dpi: self.ctx.dpi)  // high contrast, the accent and the text size are read again
                return nil
            }
        }
        made.on(Self.menuMessage) { [weak self] _, _ in self?.onMenuMessage?(); return 0 }
        made.on(0x0014 /* WM_ERASEBKGND */) { _, _ in 1 }
        made.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
        sizeWindow()
        buildPage()
    }

    var clientSize: SIZE {
        var r = RECT()
        _ = GetClientRect(hwnd, &r)
        return SIZE(cx: r.right, cy: r.bottom)
    }

    func show(activate: Bool) {
        _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW))
        if activate, WindowsSelftest.onCI { WindowsSelftest.forceForeground(hwnd) }
    }

    /// The window as tall as its page (the captures show every row without scrolling).
    func fitToContent() {
        guard let height = stack?.frames?.height else { return }
        heightDIP = height / ctx.scale
        sizeWindow()
        layoutToClient()
    }

    func rebuild(dpi: UINT) {
        tearDownPage()
        ctx.destroy()
        ctx = WinUIContext(dpi: dpi, owner: hwnd, textScale: textScale, highContrast: highContrast)
        rebuilds += 1
        buildPage()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        tearDownPage()
        router?.detach()
        router = nil
        if isRegistered { WinMessageHook.unregisterDialogWindow(hwnd) }
        ctx.destroy()
        window.destroy()
    }

    private func sizeWindow() {
        let w = ctx.px(widthDIP) + 2, h = ctx.px(heightDIP) + 2  // WS_BORDER: one pixel each side
        _ = SetWindowPos(hwnd, nil, 0, 0, w, h, UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    private func layoutToClient() {
        let size = clientSize
        scroll?.move(RECT(left: 0, top: 0, right: size.cx, bottom: size.cy))
        if let stack, let scroll { stack.width = scroll.contentWidth; stack.layout() }
    }

    private func buildPage() {
        let size = clientSize
        guard let area = try? WinScrollArea(parent: hwnd, ctx: ctx, rect: RECT(left: 0, top: 0, right: size.cx, bottom: size.cy)) else {
            AppLog.write("kit window: no scroll area (\(GetLastError()))")
            return
        }
        let page = WinStack(pane: area.content, width: area.contentWidth)
        page.onHeight = { [weak area] h in area?.setContentHeight(h) }
        scroll = area
        stack = page
        build(self, page)
        page.layout()
    }

    private func tearDownPage() {
        stack?.destroy()
        scroll?.destroy()
        stack = nil
        scroll = nil
    }
}

/// The R1 page: an edit, a check box, a combo box and a button.
@MainActor final class KeyPage {
    var edit: WinControl?, check: WinControl?, combo: WinControl?, button: WinControl?

    func build(_ s: WinStack) {
        let section = s.addSection("Keyboard")
        edit = section.addRow("Nickname") { pane, ctx in WinControls.edit(.text(cue: "Nickname"), width: 160, in: pane, ctx: ctx) }.control
        check = section.addToggle("Back view", isOn: false).control
        combo = section.addRow("Language") { pane, ctx in WinControls.combo(["English", "한국어", "日本語"], selected: 0, in: pane, ctx: ctx) }.control
        button = section.addRow("Refresh limits") { pane, ctx in WinControls.button("Refresh", in: pane, ctx: ctx) }.control
    }
}

/// The gallery: every control and part of the kit on one page (FIXTURE texts; nothing here is an app string).
@MainActor final class GalleryPage {
    var styleLabel: WinControl?, firstField: WinControl?, lastField: WinControl?, firstButton: WinControl?
    var drawn: WinDrawnView?
    var part: KitFixturePart?
    var tooltipCount = 0

    func build(_ s: WinStack) {
        let ctx = s.ctx
        let styles = s.addSection("Text styles")
        let samples: [(PopoverTextStyle, String, WinUIColors.Role)] = [
            (.body, "Body 13 · 오늘 사용량 1,234,567", .primary), (.callout, "Callout 12 · 지난 7일 · 日本語", .primary),
            (.caption, "Caption 10 · 3분 전 업데이트", .primary), (.caption2, "Caption2 10 · 0123456789", .primary),
            (.headline, "Headline 13 bold", .primary), (.title3, "Title3 15", .primary), (.largeBold, "1,234,567", .primary),
            (.body, "Secondary text (the Mac's 49.8 %)", .secondary), (.body, "Tertiary text (the Mac's 25.9 %)", .tertiary),
        ]
        for (i, sample) in samples.enumerated() {
            let row = styles.addRow(nil, style: .full) { pane, ctx in
                WinControls.label(sample.1, style: sample.0, role: sample.2, wraps: false, in: pane, ctx: ctx)
            }
            if i == 0 { styleLabel = row.control }
        }
        buildButtons(s)
        let toggles = s.addSection("Toggles")
        toggles.addToggle("Launch at login", hint: "Turned off in Task Manager > Startup apps", isOn: true)
        toggles.addToggle("Back view", isOn: false)
        toggles.addToggle("A disabled toggle", isOn: true).control?.isEnabled = false
        toggles.addToggle(KitTree.hiddenMarker, hint: KitTree.hiddenMarker, isOn: false).isVisible = false  // laid out while the window is hidden
        let pickers = s.addSection("Pickers")
        pickers.addRow("Language") { pane, ctx in
            WinControls.combo(["English", "한국어", "日本語", "Español", "Français", "Deutsch", "Русский", "中文"], selected: 1, in: pane, ctx: ctx)
        }
        pickers.addRow("Limit display") { pane, ctx in WinControls.radioGroup(["Used", "Remaining"], selected: 0, in: pane, ctx: ctx) }
        pickers.addRow("Snapshots kept", hint: "Up-down stepper") { pane, ctx in
            WinControls.stepper(range: 1...10, step: 1, value: 5, format: { "\($0)" }, in: pane, ctx: ctx)
        }
        pickers.addRow("Warn at") { pane, ctx in
            WinControls.trackbar(range: 50...95, step: 5, value: 80, format: { "\($0) %" }, width: 170, in: pane, ctx: ctx)
        }
        let fields = s.addSection("Fields")
        firstField = fields.addRow("Nickname") { pane, ctx in WinControls.edit(.text(cue: "Nickname"), width: 160, in: pane, ctx: ctx) }.control
        fields.addRow("Team code") { pane, ctx in WinControls.edit(.code(cue: "PTB-XXXXX-XXXXX"), width: 170, in: pane, ctx: ctx) }
        fields.addRow("Session key", style: .stacked) { pane, ctx in WinControls.edit(.password(cue: "sk-ant-sid01-…"), text: "fixture", in: pane, ctx: ctx) }
        lastField = fields.addRow("Scan folders", hint: "One folder per line: Enter saves, Ctrl+Enter adds a line", style: .stacked) { pane, ctx in
            WinControls.edit(.multiLine(lines: 3, cue: "C:\\Users\\you\\.claude"), in: pane, ctx: ctx)
        }.control
        let tabs = s.addSection("Tabs")
        tabs.addRow(nil, style: .full) { pane, ctx in WinControls.tabs(["Home", "Shop", "Bag", "Collection"], selected: 0, in: pane, ctx: ctx) }
        let drawnSection = s.addSection("Drawn part")
        drawnSection.addRow(nil, style: .full) { [weak self] pane, ctx in
            guard let self, let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            let part = KitFixturePart()
            view.host(part, width: 280)
            self.drawn = view
            self.part = part
            return view.control
        }
        tooltipCount += 1
        let plain = s.addSection(nil, card: false)
        plain.addRow(nil, style: .full) { pane, ctx in
            WinControls.label("A section without a card: rows stacked plainly (Home's parts)", style: .caption, role: .secondary, wraps: false, in: pane, ctx: ctx)
        }
        _ = ctx
    }

    func buildButtons(_ s: WinStack) {
        let buttons = s.addSection("Buttons")
        firstButton = buttons.addRow("Push button") { pane, ctx in WinControls.button("Refresh", in: pane, ctx: ctx) }.control
        for (symbol, label) in [("arrow.clockwise", "Refresh"), ("gearshape", "Settings"), ("power", "Quit"), ("eye.slash", "Hide the pet"),
                                ("chart.bar.xaxis", "Details"), ("flame.fill", "Streak (no glyph: emoji text)")] {
            let row = buttons.addRow("Glyph · \(symbol)") { pane, ctx in WinControls.glyphButton(symbol: symbol, label: label, in: pane, ctx: ctx) }
            row.control?.tooltip = label
            tooltipCount += 1
        }
        buttons.addRow("Link") { pane, ctx in WinControls.link("GitHub repository", in: pane, ctx: ctx) }
    }
}

/// A FIXTURE drawn part (UI chrome only: two colour bars, text and a capsule from the canvas, one bundled sprite at its
/// own pixels): a static text item over the bar, a button item over the capsule that counts up, a tooltip on the bar.
@MainActor final class KitFixturePart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var count = 3
    private var width: CGFloat = 280
    static let green = PlazaColor(hex: 0x34C759)

    func countUp() {
        count = min(10, count + 1)
        onChange?()
    }

    static func barWidth(_ view: WinDrawnView) -> CGFloat { CGFloat(view.pixelSize.cx) / view.ctx.scale - 52 }

    private var bar: CGRect { CGRect(x: 0, y: 40, width: width - 52, height: 6) }
    private var button: CGRect { CGRect(x: width - 44, y: 6, width: 40, height: 24) }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize {
        self.width = width
        return CGSize(width: width, height: 52)
    }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        var layers: [PlazaPanelLayer] = [
            .color(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1), frame: bar),
            .color(Self.green, frame: CGRect(x: bar.minX, y: bar.minY, width: (bar.width * CGFloat(count) / 10).rounded(), height: bar.height)),
        ]
        let space = PlazaPanelSpace(content: CGSize(width: width, height: 34), room: 0)
        let button = self.button
        let count = self.count
        if let image = space.image(scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85))
            canvas.draw(graphics.text.line("Fixture part \(count) / 10 · 픽스처", font: .system(size: 12, weight: .semibold)),
                        at: space.canvas(CGPoint(x: 24, y: 22)))
            canvas.setFillColor(PlazaColor(hex: 0x007AFF))
            canvas.fillRoundedRect(space.canvas(button), radius: 12)
            canvas.setFillColor(.white)
            canvas.draw(graphics.text.line("+1", font: .system(size: 12, weight: .bold)), at: space.canvas(CGPoint(x: button.minX + 12, y: button.minY + 16)))
        }) {
            layers.append(.image(image, frame: CGRect(x: 0, y: 0, width: width, height: 34)))
        }
        if let url = graphics.assetURL("plaza-water-balloon", ext: "png"), let balloon = graphics.decodeImage(at: url) {
            let side = min(20, CGFloat(balloon.width))
            layers.append(.image(balloon, frame: CGRect(x: 0, y: 6, width: side, height: side * CGFloat(balloon.height) / CGFloat(max(1, balloon.width)))))
        }
        let drawing = PlazaPanelDrawing(layers: layers, accessibility: [
            PlazaAccessibilityItem(frame: bar, role: .staticText, label: "Fixture bar", value: "\(count * 10) %"),
            PlazaAccessibilityItem(frame: button, role: .button, label: "Add one", action: PlazaPanelHit(action: "countUp", index: nil)),
        ], tooltips: [PlazaTooltip(frame: bar, text: "\(count) of 10")])
        return PopoverDrawing(drawing: drawing, spriteSlots: [SpriteSlot(frame: CGRect(x: 0, y: 6, width: 20, height: 20), subject: nil, bob: false, animated: false)])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? {
        button.contains(point) ? PlazaPanelHit(action: "countUp", index: nil) : nil
    }
}

/// What reached an edit: characters, IME characters, key-downs and composition messages (a second subclass on top of the
/// kit's, removed after the checks).
@MainActor final class EditProbe {
    private let hwnd: HWND
    private(set) var chars: [UInt32] = [], imeChars: [UInt32] = [], keyDowns: [UInt32] = []
    private(set) var compositionMessages = 0
    static var current: EditProbe?
    static var keyDownCount = 0

    init(_ hwnd: HWND) {
        self.hwnd = hwnd
        Self.current = self
        _ = SetWindowSubclass(hwnd, editProbeSubclass, 0x5054_4550, 0)
    }

    func reset() {
        chars = []
        imeChars = []
        keyDowns = []
        compositionMessages = 0
    }

    func remove() {
        _ = RemoveWindowSubclass(hwnd, editProbeSubclass, 0x5054_4550)
        if Self.current === self { Self.current = nil }
    }

    fileprivate func saw(_ message: UINT, _ wParam: WPARAM) {
        switch message {
        case UINT(WM_CHAR): chars.append(UInt32(truncatingIfNeeded: wParam))
        case 0x0286: imeChars.append(UInt32(truncatingIfNeeded: wParam))
        case UINT(WM_KEYDOWN):
            keyDowns.append(UInt32(truncatingIfNeeded: wParam))
            Self.keyDownCount += 1
        case 0x010D, 0x010E, 0x010F: compositionMessages += 1  // WM_IME_STARTCOMPOSITION, ENDCOMPOSITION, COMPOSITION
        default: break
        }
    }
}

nonisolated(unsafe) private let editProbeSubclass: SUBCLASSPROC = { h, m, w, l, _, _ in
    _ = MainActor.assumeIsolated { EditProbe.current?.saw(m, w) }
    return DefSubclassProc(h, m, w, l)
}

/// Every window of a kit window, in DIP of its client area, with the D19 checks: every Tab stop reachable by Tab and in
/// reading order, no two visible controls overlapping, every label's text fitting its box, every control inside the
/// window, Hangul present in the font GDI links to.
@MainActor struct KitTree {
    struct Node: Codable {
        var cls: String
        var text: String
        var x: Double, y: Double, w: Double, h: Double
        var visible: Bool, enabled: Bool, tabStop: Bool
        var tabIndex: Int?
        var fontHeight: Int32?
        var depth: Int
    }
    var nodes: [Node] = []
    var handles: [HWND] = []
    var tabOrder: [HWND] = []

    static let containers: Set<String> = [WinPane.className, WinScrollArea.className, WinDrawnView.className]
    /// The text of a row the gallery hides: no window with it may be visible.
    static let hiddenMarker = "Hidden row (must not show)"

    static func collect(_ w: KitWindow) -> KitTree {
        var tree = KitTree()
        var cur = GetNextDlgTabItem(w.hwnd, nil, false)
        while let c = cur, !tree.tabOrder.contains(c), tree.tabOrder.count < 400 {
            tree.tabOrder.append(c)
            cur = GetNextDlgTabItem(w.hwnd, c, false)
        }
        func walk(_ parent: HWND, _ depth: Int) {
            var child = GetWindow(parent, 5 /* GW_CHILD */)
            while let c = child {
                let style = GetWindowLongW(c, -16 /* GWL_STYLE */)
                let cls = WinKit.className(c)
                let r = WinKit.rect(c, in: w.hwnd)
                let s = w.ctx.scale
                let masked = cls == "Edit" && style & 0x0020 /* ES_PASSWORD */ != 0
                let text = WinKit.text(of: c)
                let font = WinKit.send(c, 0x0031)
                tree.nodes.append(Node(cls: cls, text: masked ? "(masked, \(text.count) characters)" : text,
                                       x: Double(CGFloat(r.left) / s), y: Double(CGFloat(r.top) / s), w: Double(CGFloat(r.right - r.left) / s),
                                       h: Double(CGFloat(r.bottom - r.top) / s), visible: IsWindowVisible(c), enabled: IsWindowEnabled(c),
                                       tabStop: style & 0x0001_0000 != 0, tabIndex: tree.tabOrder.firstIndex(of: c),
                                       fontHeight: font == 0 ? nil : WindowsSelftestPopover.logFont(HFONT(bitPattern: font)).lfHeight, depth: depth))
                tree.handles.append(c)
                walk(c, depth + 1)
                child = GetWindow(c, 2 /* GW_HWNDNEXT */)
            }
        }
        walk(w.hwnd, 0)
        return tree
    }

    struct Result { var ok: Bool; var summary: String }

    func check(_ w: KitWindow) -> Result {
        let client = w.clientSize, s = w.ctx.scale
        var problems: [String] = []
        let stops = zip(nodes, handles).filter { $0.0.tabStop && $0.0.visible && $0.0.enabled && !Self.containers.contains($0.0.cls) }
        let unreachable = stops.filter { !tabOrder.contains($0.1) }.map { "\($0.0.cls) '\($0.0.text)'" }
        if !unreachable.isEmpty { problems.append("not reachable by Tab: \(unreachable)") }
        let tabRects = tabOrder.map { h -> CGRect in
            let r = WinKit.rect(h, in: w.hwnd)
            return CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.right - r.left), height: CGFloat(r.bottom - r.top))
        }
        if !PopoverStackLayout.isReadingOrder(tabRects) { problems.append("Tab order is not the reading order") }
        let leaves = zip(nodes, handles).filter { $0.0.visible && !Self.containers.contains($0.0.cls) && $0.0.cls != "msctls_updown32" }
        var overlaps: [String] = []
        for i in leaves.indices {
            for j in leaves.indices where j > i {
                let a = leaves[i].0, b = leaves[j].0
                let ra = CGRect(x: a.x, y: a.y, width: a.w, height: a.h).insetBy(dx: 0.5, dy: 0.5)
                let rb = CGRect(x: b.x, y: b.y, width: b.w, height: b.h).insetBy(dx: 0.5, dy: 0.5)
                if ra.intersects(rb), IsChild(leaves[i].1, leaves[j].1) == false, IsChild(leaves[j].1, leaves[i].1) == false {
                    overlaps.append("\(a.cls) '\(a.text.prefix(16))' x \(b.cls) '\(b.text.prefix(16))'")
                }
            }
        }
        if !overlaps.isEmpty { problems.append("overlaps: \(overlaps.prefix(6))") }
        var clipped: [String] = []
        for (node, h) in zip(nodes, handles) where node.cls == "Static" && node.visible && !node.text.isEmpty {
            let style = GetWindowLongW(h, -16)
            guard style & 0x1F != 0x0D /* SS_OWNERDRAW */, style & 0x4000 == 0 /* SS_ENDELLIPSIS */ else { continue }
            let font = HFONT(bitPattern: WinKit.send(h, 0x0031))
            let need = w.ctx.measure(node.text, font: font, width: Int32((node.w * Double(s)).rounded()))
            if CGFloat(need.cy) > CGFloat(node.h) * s + 1 { clipped.append("'\(node.text.prefix(24))' needs \(need.cy) px of \(Int(CGFloat(node.h) * s))") }
        }
        if !clipped.isEmpty { problems.append("labels cut: \(clipped)") }
        // A label squeezed narrower than its widest word: its height still "fits" (one word a line), so the check above
        // misses it (seen at 150 % text: a row's label at 0 px beside a wide control).
        var squeezed: [String] = []
        for (node, h) in zip(nodes, handles) where node.cls == "Static" && node.visible && !node.text.isEmpty {
            let style = GetWindowLongW(h, -16)
            guard style & 0x1F != 0x0D, style & 0x4000 == 0 else { continue }
            let font = HFONT(bitPattern: WinKit.send(h, 0x0031))
            let widest = node.text.split(separator: " ").map { w.ctx.measure(String($0), font: font).cx }.max() ?? 0
            if CGFloat(widest) > CGFloat(node.w) * s + 1 { squeezed.append("'\(node.text.prefix(24))' \(Int(CGFloat(node.w) * s)) px < its widest word \(widest) px") }
        }
        if !squeezed.isEmpty { problems.append("labels squeezed: \(squeezed)") }
        let outside = zip(nodes, handles).filter { n, _ in
            n.tabStop && n.visible && (n.x < -0.5 || n.y < -0.5 || CGFloat(n.x + n.w) * s > CGFloat(client.cx) + 1 || CGFloat(n.y + n.h) * s > CGFloat(client.cy) + 1)
        }.map { "\($0.0.cls) '\($0.0.text.prefix(16))'" }
        if !outside.isEmpty { problems.append("outside the window: \(outside)") }
        let shownHidden = nodes.filter { $0.text == Self.hiddenMarker && $0.visible }.count
        if shownHidden > 0 { problems.append("a hidden row shows (\(shownHidden) windows)") }
        let hangul = Set(nodes.flatMap { $0.text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.map { UInt16($0.value) } })
        let missingHangul = Self.missingGlyphs(Array(hangul), face: "Malgun Gothic")
        // R9: a machine without Malgun Gothic (a server image) draws Hangul as boxes: reported, not failed; with the font, a missing glyph fails.
        if !missingHangul.isEmpty, WinFonts.isInstalled("Malgun Gothic") { problems.append("Hangul without a glyph in Malgun Gothic: \(missingHangul.count)") }
        let summary = "hidden row windows shown=\(shownHidden) of \(nodes.filter { $0.text == Self.hiddenMarker }.count); \(stops.count) Tab stops, \(tabOrder.count) reached in reading order=\(PopoverStackLayout.isReadingOrder(tabRects)); "
            + "\(leaves.count) visible controls; \(hangul.count) Hangul syllables, \(missingHangul.count) without a glyph in Malgun Gothic (GDI's link for Hangul, "
            + "installed=\(WinFonts.isInstalled("Malgun Gothic"))); problems=\(problems.isEmpty ? "none" : problems.joined(separator: "; "))"
        return Result(ok: problems.isEmpty, summary: summary)
    }

    static func missingGlyphs(_ units: [UInt16], face: String) -> [UInt16] {
        guard !units.isEmpty, let dc = CreateCompatibleDC(nil) else { return [] }
        defer { _ = DeleteDC(dc) }
        var lf = LOGFONTW()
        lf.lfHeight = -16
        lf.lfCharSet = 1
        WinFonts.setFaceName(&lf, face)
        guard let font = CreateFontIndirectW(&lf) else { return units }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        defer { _ = SelectObject(dc, old) }
        var input = units, index = [UInt16](repeating: 0, count: units.count)
        _ = GetGlyphIndicesW(dc, &input, Int32(units.count), &index, 1)
        return zip(units, index).filter { $0.1 == 0xFFFF }.map(\.0)
    }

    func write(to url: URL) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(nodes), (try? data.write(to: url)) != nil else { return "FAILED" }
        return url.lastPathComponent
    }
}

/// Every SF Symbol of the Mac popover next to its Segoe Fluent Icons and Segoe MDL2 Assets glyph (or its fallback text),
/// drawn with GDI on white for the PR and the report.
@MainActor enum GlyphSheet {
    static func render() -> WinUIDump.Bitmap? {
        let entries = PopoverGlyphTable.entries.sorted { $0.key < $1.key }
        let rowH: Int32 = 30, width: Int32 = 900, height = Int32(entries.count + 1) * rowH + 8
        guard let dc = CreateCompatibleDC(nil) else { return nil }
        defer { _ = DeleteDC(dc) }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        var bits: UnsafeMutableRawPointer?
        guard let dib = CreateDIBSection(dc, &info, 0, &bits, nil, 0), let bits else { return nil }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(dib)) }
        let oldBitmap = SelectObject(dc, UnsafeMutableRawPointer(dib))
        defer { _ = SelectObject(dc, oldBitmap) }
        var all = RECT(left: 0, top: 0, right: width, bottom: height)
        let white = CreateSolidBrush(0x00FF_FFFF)
        _ = FillRect(dc, &all, white)
        _ = DeleteObject(UnsafeMutableRawPointer(white))
        func font(_ face: String, _ px: Int32, bold: Bool = false) -> HFONT? {
            var lf = LOGFONTW()
            lf.lfHeight = -px
            lf.lfWeight = bold ? 700 : 400
            lf.lfCharSet = 1
            lf.lfQuality = 5
            WinFonts.setFaceName(&lf, face)
            return CreateFontIndirectW(&lf)
        }
        let text = font("Segoe UI", 13), bold = font("Segoe UI", 13, bold: true)
        let fluent = font(WinFonts.fluentIcons, 20), mdl2 = font(WinFonts.mdl2Assets, 20), emoji = font(WinFonts.emojiFace, 18)
        defer { for f in [text, bold, fluent, mdl2, emoji] { if let f { _ = DeleteObject(UnsafeMutableRawPointer(f)) } } }
        _ = SetBkMode(dc, 1)
        _ = SetTextColor(dc, 0)
        func put(_ s: String, _ f: HFONT?, _ x: Int32, _ y: Int32, _ w: Int32) {
            _ = SelectObject(dc, UnsafeMutableRawPointer(f))
            var r = RECT(left: x, top: y, right: x + w, bottom: y + rowH)
            _ = WinStr.w(s).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &r, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS)) }
        }
        put("SF Symbol", bold, 8, 4, 230)
        put("Fluent", bold, 240, 4, 60)
        put("MDL2", bold, 305, 4, 60)
        put("Glyph name · note (fallback text drawn in Segoe UI Emoji)", bold, 370, 4, 520)
        for (i, (symbol, entry)) in entries.enumerated() {
            let y = Int32(i + 1) * rowH + 4
            put(symbol, text, 8, y, 230)
            if let cp = entry.fluent { put(String(decoding: [cp], as: UTF16.self), fluent, 248, y, 50) } else { put(entry.fallback ?? "-", emoji, 248, y, 50) }
            if let cp = entry.mdl2 { put(String(decoding: [cp], as: UTF16.self), mdl2, 313, y, 50) } else { put(entry.fallback ?? "-", emoji, 313, y, 50) }
            put("\(entry.name)" + (entry.note.map { " · \($0)" } ?? ""), text, 370, y, 520)
        }
        _ = GdiFlush()
        let count = Int(width * height) * 4
        var bgra = [UInt8](UnsafeRawBufferPointer(start: bits, count: count))
        for i in stride(from: 3, to: count, by: 4) { bgra[i] = 255 }
        return WinUIDump.Bitmap(width: Int(width), height: Int(height), bgra: bgra)
    }
}
#endif
