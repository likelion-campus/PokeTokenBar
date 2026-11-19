#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Dark popup menus (WinMenuTheme): the pixels of the real open menu, under forced dark and forced light, for the tray menu, a menu
// opened below a control of the popover (what a drop-down and the Representative row do) and a text box's own context menu; the
// fault variant (the kill-switch behaviour) must leave a forced-dark menu light. `popover.darkMenu.highContrast` switches the runner
// to the real "High Contrast White" theme, opens the tray menu and requires it to stay white (the system's colours, never dark), then
// puts the theme back; where Windows refuses the switch it reports that and passes (informational).

extension WindowsSelftest {
    @MainActor static func popoverDarkMenuChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverDarkMenu.run(r, app)
    }

    @MainActor static func popoverDarkMenuHighContrastCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverDarkMenu.highContrast(r, app)
    }
}

@MainActor enum WindowsSelftestPopoverDarkMenu {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _luma: Double?, _note = "", _done = false, _image: WinUIDump.Bitmap?
        func finish(luma: Double?, note: String, image: WinUIDump.Bitmap?) { lock.lock(); _luma = luma; _note = note; _image = image; _done = true; lock.unlock() }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
        var luma: Double? { lock.lock(); defer { lock.unlock() }; return _luma }
        var note: String { lock.lock(); defer { lock.unlock() }; return _note }
        var image: WinUIDump.Bitmap? { lock.lock(); defer { lock.unlock() }; return _image }
    }

    /// Opens a menu through `open` (run from the main loop), screenshots it from a helper thread, closes it with Escape sent to `owner`.
    /// Returns the average luminance (0...255) of a block inside the menu's item area, and the picture.
    static func capture(owner: HWND, open: @escaping @MainActor () -> Void) async -> (luma: Double?, note: String, image: WinUIDump.Bitmap?) {
        let box = Box()
        let ownerBits = Int(bitPattern: owner)
        let screenW = Int(GetSystemMetrics(SM_CXSCREEN)), screenH = Int(GetSystemMetrics(SM_CYSCREEN))
        Thread {
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { box.finish(luma: nil, note: "menu never opened", image: nil); return }
            Thread.sleep(forTimeInterval: 0.8)  // let it paint
            var rect = RECT()
            let found = WinStr.w("#32768").withUnsafeBufferPointer { FindWindowW($0.baseAddress, nil) }
            var luma: Double?, note = "", image: WinUIDump.Bitmap?
            if let found, GetWindowRect(found, &rect) {
                let x = max(0, Int(rect.left)), y = max(0, Int(rect.top))
                let w = min(screenW - x, Int(rect.right - rect.left)), h = min(screenH - y, Int(rect.bottom - rect.top))
                if w > 24, h > 24, let shot = WinUIDump.screenshot(x: x, y: y, w: w, h: h) {
                    image = shot
                    // an 8 x 8 block at the left edge of the item area, half way down: the menu's own background, not its text
                    var sum = 0.0, n = 0.0
                    for yy in (h / 2 - 4)..<(h / 2 + 4) { for xx in 10..<18 {
                        let i = (yy * w + xx) * 4
                        sum += 0.2126 * Double(shot.bgra[i + 2]) + 0.7152 * Double(shot.bgra[i + 1]) + 0.0722 * Double(shot.bgra[i]); n += 1
                    } }
                    luma = sum / n
                    note = "menu \(w)x\(h) at (\(x),\(y))"
                } else { note = "no picture of the menu window" }
            } else { note = "menu window #32768 not found" }
            for _ in 0..<5 where WinPopupMenu.openMenuBits != 0 {
                _ = PostMessageW(HWND(bitPattern: ownerBits), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
                _ = PostMessageW(HWND(bitPattern: ownerBits), UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
                for _ in 0..<10 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.1) }
            }
            box.finish(luma: luma, note: note + (WinPopupMenu.openMenuBits == 0 ? "" : ", STILL OPEN"), image: image)
        }.start()
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in MainActor.assumeIsolated { open() } }
        RunLoop.main.add(timer, forMode: .common)
        _ = await WindowsSelftest.waitUntil(timeout: 30) { box.done }
        return (box.luma, box.note, box.image)
    }

    private static func save(_ image: WinUIDump.Bitmap?, _ name: String) {
        guard let image, let dir = WinUIDump.directory(from: CommandLine.arguments) else { return }
        let menus = dir.appendingPathComponent("menus")
        try? FileManager.default.createDirectory(at: menus, withIntermediateDirectories: true)
        _ = WinUIDump.write(image, to: menus.appendingPathComponent(name))
    }

    struct Surface { var name: String; var owner: HWND; var open: @MainActor () -> Void }

    static func evaluate(dark: Bool, _ surfaces: [Surface]) async -> (problems: [String], notes: [String]) {
        var problems: [String] = [], notes: [String] = []
        let saved = WinDarkMode.testOverride
        defer { WinDarkMode.testOverride = saved }
        WinDarkMode.testOverride = dark
        for s in surfaces {
            let got = await capture(owner: s.owner, open: s.open)
            save(got.image, "menu-\(s.name)-\(dark ? "dark" : "light").png")
            guard let luma = got.luma else { problems.append("\(s.name) \(dark ? "dark" : "light"): \(got.note)"); continue }
            notes.append("\(s.name) \(dark ? "dark" : "light") luma \(Int(luma)) (\(WinMenuTheme.lastOutcome))")
            if dark, luma > 110 { problems.append("\(s.name): the menu is light (luma \(Int(luma))) under forced dark") }
            if !dark, luma < 170 { problems.append("\(s.name): the menu is dark (luma \(Int(luma))) under forced light") }
        }
        return (problems, notes)
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray else { r.add("popover.darkMenu", false, "no tray host"); return }
        guard let w = KitWindow(heightDIP: 300, register: true, origin: POINT(x: 40, y: 40), build: { _, s in
            _ = s.addSection("Menu").addRow("Name") { pane, ctx in WinControls.edit(.text(cue: "Name"), text: "x", width: 160, in: pane, ctx: ctx) }
        }) else { r.add("popover.darkMenu", false, "no kit window"); return }
        defer { w.destroy() }
        w.show(activate: true)
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
        let items: [TrayMenuModel.Item?] = [TrayMenuModel.Item(title: "English", enabled: true, checked: true, action: .none),
                                           TrayMenuModel.Item(title: "한국어", enabled: true, checked: false, action: .none),
                                           TrayMenuModel.Item(title: "日本語", enabled: true, checked: false, action: .none)]
        var edit: HWND?
        // the page's only Edit
        func find(_ parent: HWND?) {
            var c = GetWindow(parent, 5)
            while let h = c {
                if WinKit.className(h) == "Edit" { edit = h; return }
                find(h)
                if edit != nil { return }
                c = GetWindow(h, 2)
            }
        }
        find(w.hwnd)
        var surfaces: [Surface] = [
            Surface(name: "tray", owner: app.sink.hwnd) { host.openMenu(at: POINT(x: 300, y: 300)) },
            Surface(name: "popup", owner: w.hwnd) { _ = WinPopupMenu.run(items, at: POINT(x: 120, y: 160), owner: w.hwnd, below: true) },
        ]
        if let edit { surfaces.append(Surface(name: "textbox", owner: edit) { _ = SendMessageW(edit, 0x007B /* WM_CONTEXTMENU */, WPARAM(UInt(bitPattern: Int(bitPattern: edit))), -1) }) }
        let darkResult = await evaluate(dark: true, surfaces)
        let lightResult = await evaluate(dark: false, surfaces)
        let problems = darkResult.problems + lightResult.problems
        r.add("popover.darkMenu", problems.isEmpty,
              (darkResult.notes + lightResult.notes).joined(separator: "; ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
        // the kill-switch behaviour must leave a forced-dark menu light: the dark check fails
        WinMenuTheme.testDisabled = true
        let broken = await evaluate(dark: true, Array(surfaces.prefix(1)))
        WinMenuTheme.testDisabled = false
        WinMenuTheme.ensure()
        r.add("popover.darkMenu.fault", !broken.problems.isEmpty,
              "kill-switch on: the forced-dark tray menu stays light as expected (\(broken.problems.first ?? broken.notes.first ?? "none"))")
    }

    /// A real high-contrast theme: the menu keeps the system's colours.
    static func highContrast(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray else { r.add("popover.darkMenu.highContrast", true, "informational: no tray host"); return }
        func set(_ on: Bool) -> Bool {
            var hc = HIGHCONTRASTW()
            hc.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
            hc.dwFlags = on ? 0x1 | 0x2 : 0x2  // HCF_HIGHCONTRASTON | HCF_AVAILABLE
            var scheme = WinStr.w("High Contrast White")
            return scheme.withUnsafeMutableBufferPointer { buffer in
                hc.lpszDefaultScheme = buffer.baseAddress
                return SystemParametersInfoW(0x0043 /* SPI_SETHIGHCONTRAST */, hc.cbSize, &hc, UINT(0x0001 | 0x0002) /* SPIF_UPDATEINIFILE | SPIF_SENDCHANGE */)
            }
        }
        let saved = WinDarkMode.testOverride
        WinDarkMode.testOverride = nil
        defer { WinDarkMode.testOverride = saved }
        let switched = set(true)
        _ = await WindowsSelftest.waitUntil(timeout: 2.5) { false }
        let on = WinUIContext.systemHighContrast()
        guard switched, on else {
            _ = set(false)
            r.add("popover.darkMenu.highContrast", true, "informational: Windows did not switch to a real high-contrast theme on this runner (SPI ok=\(switched), active=\(on)); not proven here")
            return
        }
        let mode = WinMenuTheme.wantedMode()
        let got = await capture(owner: app.sink.hwnd) { host.openMenu(at: POINT(x: 300, y: 300)) }
        save(got.image, "menu-tray-highcontrast-white.png")
        let window = Int(GetSysColor(5 /* COLOR_WINDOW */) & 0xFF)
        _ = set(false)
        _ = await WindowsSelftest.waitUntil(timeout: 2.5) { false }
        let off = !WinUIContext.systemHighContrast()
        var problems: [String] = []
        if mode != .default { problems.append("the wanted mode is \(mode) under a real high-contrast theme, expected default") }
        if let luma = got.luma { if luma < 170 { problems.append("the menu is dark (luma \(Int(luma))) under High Contrast White (COLOR_WINDOW red \(window))") } }
        else { problems.append(got.note) }
        if !off { problems.append("the runner is still in high contrast after switching back") }
        r.add("popover.darkMenu.highContrast", problems.isEmpty,
              "real High Contrast White: mode \(mode), menu luma \(got.luma.map { String(Int($0)) } ?? "-"), COLOR_WINDOW red \(window), switched back=\(off); \(WinMenuTheme.lastOutcome)"
              + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }
}
#endif
