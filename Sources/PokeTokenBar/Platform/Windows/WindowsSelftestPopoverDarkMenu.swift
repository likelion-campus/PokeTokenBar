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
            // a text box's own menu does not go through WinPopupMenu: the menu window itself says it is open
            func menuWindow() -> HWND? { WinStr.w("#32768").withUnsafeBufferPointer { FindWindowW($0.baseAddress, nil) } }
            var waited = 0
            while menuWindow() == nil, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard menuWindow() != nil else { box.finish(luma: nil, note: "menu never opened", image: nil); return }
            Thread.sleep(forTimeInterval: 0.8)  // let it paint
            var rect = RECT()
            let found = menuWindow()
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
            for _ in 0..<5 where menuWindow() != nil {
                _ = PostMessageW(HWND(bitPattern: ownerBits), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
                _ = PostMessageW(HWND(bitPattern: ownerBits), UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
                for _ in 0..<10 where menuWindow() != nil { Thread.sleep(forTimeInterval: 0.1) }
            }
            box.finish(luma: luma, note: note + (menuWindow() == nil ? "" : ", STILL OPEN"), image: image)
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

    static func evaluate(dark: Bool, _ surfaces: [Surface], saving: Bool = true) async -> (problems: [String], notes: [String]) {
        var problems: [String] = [], notes: [String] = []
        let saved = WinDarkMode.testOverride
        defer { WinDarkMode.testOverride = saved }
        WinDarkMode.testOverride = dark
        for s in surfaces {
            let got = await capture(owner: s.owner, open: s.open)
            if saving { save(got.image, "menu-\(s.name)-\(dark ? "dark" : "light").png") }
            guard let luma = got.luma else { problems.append("\(s.name) \(dark ? "dark" : "light"): \(got.note)"); continue }
            notes.append("\(s.name) \(dark ? "dark" : "light") luma \(Int(luma)) (\(WinMenuTheme.lastOutcome))")
            if dark, luma > 110 { problems.append("\(s.name): the menu is light (luma \(Int(luma))) under forced dark") }
            if !dark, luma < 170 { problems.append("\(s.name): the menu is dark (luma \(Int(luma))) under forced light") }
        }
        return (problems, notes)
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray else { r.add("popover.darkMenu", false, "no tray host"); return }
        var dropDown: WinControl?
        guard let w = KitWindow(heightDIP: 300, register: true, origin: POINT(x: 40, y: 40), build: { _, s in
            let section = s.addSection("Menu")
            _ = section.addRow("Name") { pane, ctx in WinControls.edit(.text(cue: "Name"), text: "x", width: 160, in: pane, ctx: ctx) }
            // the real K4 drop-down (a Settings picker): its own `openMenu`, not a hand-made `WinPopupMenu.run`
            dropDown = section.addRow("Language") { pane, ctx in WinControls.combo(["English", "한국어", "日本語"], selected: 1, in: pane, ctx: ctx) }.control
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
        if let dropDown { surfaces.append(Surface(name: "dropDown", owner: w.hwnd) { dropDown.openMenu() }) }
        if let edit { surfaces.append(Surface(name: "textbox", owner: edit) { _ = SendMessageW(edit, 0x007B /* WM_CONTEXTMENU */, WPARAM(UInt(bitPattern: Int(bitPattern: edit))), -1) }) }
        decisions(r)
        let darkResult = await evaluate(dark: true, surfaces)
        let lightResult = await evaluate(dark: false, surfaces)
        let problems = darkResult.problems + lightResult.problems
        r.add("popover.darkMenu", problems.isEmpty,
              (darkResult.notes + lightResult.notes).joined(separator: "; ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
        // the kill-switch behaviour must leave a forced-dark menu light: the dark check fails
        WinMenuTheme.testDisabled = true
        let broken = await evaluate(dark: true, Array(surfaces.prefix(1)), saving: false)
        WinMenuTheme.testDisabled = false
        WinMenuTheme.ensure()
        r.add("popover.darkMenu.fault", !broken.problems.isEmpty,
              "kill-switch on: the forced-dark tray menu stays light as expected (\(broken.problems.first ?? broken.notes.first ?? "none"))")
    }

    /// The decision table, with injected readings: runs everywhere and changes nothing.
    static func decisions(_ r: WindowsSelftest.Recorder) {
        typealias D = WinMenuTheme
        let cases: [(String, D.Mode, D.Mode)] = [
            ("high contrast", D.decide(killed: false, highContrast: true, forced: nil), .default),
            ("high contrast beats a forced dark", D.decide(killed: false, highContrast: true, forced: true), .default),
            ("kill-switch", D.decide(killed: true, highContrast: false, forced: nil), .default),
            ("kill-switch beats a forced dark", D.decide(killed: true, highContrast: false, forced: true), .default),
            ("follow Windows", D.decide(killed: false, highContrast: false, forced: nil), .allowDark),
            ("forced dark (selftest hook)", D.decide(killed: false, highContrast: false, forced: true), .forceDark),
            ("forced light (selftest hook)", D.decide(killed: false, highContrast: false, forced: false), .forceLight),
        ]
        let wrong = cases.filter { $0.1 != $0.2 }.map { "\($0.0): \($0.1), expected \($0.2)" }
        r.add("popover.darkMenu.mode", wrong.isEmpty, "\(cases.count) readings: " + cases.map { "\($0.0) -> \($0.1)" }.joined(separator: "; ") + (wrong.isEmpty ? "" : " | PROBLEMS: " + wrong.joined(separator: "; ")))
    }

    private struct HighContrastState: Equatable { var flags: UInt32; var scheme: String }
    private static func readHighContrast() -> HighContrastState? {
        var buffer = [UInt16](repeating: 0, count: 256)
        return buffer.withUnsafeMutableBufferPointer { b -> HighContrastState? in
            var hc = HIGHCONTRASTW()
            hc.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
            hc.lpszDefaultScheme = b.baseAddress
            guard SystemParametersInfoW(0x0042 /* SPI_GETHIGHCONTRAST */, hc.cbSize, &hc, 0) else { return nil }
            return HighContrastState(flags: hc.dwFlags, scheme: String(decodingCString: b.baseAddress!, as: UTF16.self))
        }
    }
    private static func writeHighContrast(_ flags: UInt32, scheme: String) -> Bool {
        var buffer = WinStr.w(scheme.isEmpty ? "High Contrast White" : scheme)
        return buffer.withUnsafeMutableBufferPointer { b in
            var hc = HIGHCONTRASTW()
            hc.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
            hc.dwFlags = flags
            hc.lpszDefaultScheme = b.baseAddress
            return SystemParametersInfoW(0x0043 /* SPI_SETHIGHCONTRAST */, hc.cbSize, &hc, UINT(0x0001 | 0x0002) /* SPIF_UPDATEINIFILE | SPIF_SENDCHANGE */)
        }
    }

    /// A real high-contrast theme: the menu keeps the system's colours. THIS CHECK CHANGES AND RESTORES A SYSTEM-WIDE SETTING (the
    /// high-contrast theme), so it runs only on the CI runner (an ephemeral VM) and never on a person's PC (`--selftest`). It records the
    /// theme flags and the apps/system light-dark values first, restores them in a `defer`, and fails loudly if they differ afterwards.
    /// The same decision is covered without touching anything by `popover.darkMenu.mode`.
    static func highContrast(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("popover.darkMenu.highContrast", true, "skipped: not CI. This check switches Windows to a real high-contrast theme and back (a system-wide setting), so it runs only on the runner; the decision is tested without it by popover.darkMenu.mode")
            return
        }
        guard let host = app.tray else { r.add("popover.darkMenu.highContrast", false, "no tray host"); return }
        let personalization = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"
        let names = ["AppsUseLightTheme", "SystemUsesLightTheme"]
        let beforeHC = readHighContrast()
        let beforeValues = names.map { name -> [UInt8]? in if case .value(let b) = WinRegistry.bytes(personalization, name) { return b } else { return nil } }
        guard let beforeHC else { r.add("popover.darkMenu.highContrast", true, "informational: the current high-contrast state cannot be read here, so the probe did not run (nothing changed)"); return }
        let savedOverride = WinDarkMode.testOverride
        var problems: [String] = []
        var detail = "CHANGED AND RESTORED a system-wide setting (high-contrast theme, flags 0x\(String(beforeHC.flags, radix: 16)) before): "
        func restore() async {
            if !writeHighContrast(beforeHC.flags, scheme: beforeHC.scheme) { problems.append("restoring the high-contrast flags failed") }
            _ = await WindowsSelftest.waitUntil(timeout: 2.5) { false }
            for (name, value) in zip(names, beforeValues) {
                var now: [UInt8]?
                if case .value(let b) = WinRegistry.bytes(personalization, name) { now = b }
                if now != value {
                    if let value { _ = WinRegistry.setBytes(personalization, name, value) } else { _ = WinRegistry.deleteValue(personalization, name) }
                    detail += "personalization \(name) had changed and was restored; "
                }
            }
        }
        WinDarkMode.testOverride = nil
        let switched = writeHighContrast(0x1 | 0x2, scheme: "High Contrast White")
        _ = await WindowsSelftest.waitUntil(timeout: 2.5) { false }
        let on = WinUIContext.systemHighContrast()
        if switched, on {
            let mode = WinMenuTheme.wantedMode()
            let got = await capture(owner: app.sink.hwnd) { host.openMenu(at: POINT(x: 300, y: 300)) }
            save(got.image, "menu-tray-highcontrast-white.png")
            if mode != .default { problems.append("the wanted mode is \(mode) under a real high-contrast theme, expected default") }
            if let luma = got.luma { if luma < 170 { problems.append("the menu is dark (luma \(Int(luma))) under High Contrast White") } } else { problems.append(got.note) }
            detail += "real High Contrast White: mode \(mode), menu luma \(got.luma.map { String(Int($0)) } ?? "-"); "
        } else {
            detail += "Windows did not switch to a real high-contrast theme (SPI ok=\(switched), active=\(on)); not proven here; "
        }
        await restore()
        WinDarkMode.testOverride = savedOverride
        let afterHC = readHighContrast()
        if afterHC?.flags.nonzeroOn != beforeHC.flags.nonzeroOn {
            // one more try, then fail loudly
            _ = writeHighContrast(0, scheme: beforeHC.scheme)
            _ = await WindowsSelftest.waitUntil(timeout: 2.5) { false }
            if readHighContrast()?.flags.nonzeroOn != beforeHC.flags.nonzeroOn { problems.append("THE RUNNER IS NOT BACK IN ITS PREVIOUS HIGH-CONTRAST STATE (before \(beforeHC.flags), after \(afterHC?.flags ?? 0))") }
        }
        detail += "restored: high contrast on=\(afterHC?.flags.nonzeroOn ?? false) (before \(beforeHC.flags.nonzeroOn)); \(WinMenuTheme.lastOutcome)"
        r.add("popover.darkMenu.highContrast", problems.isEmpty, detail + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }
}

private extension UInt32 { var nonzeroOn: Bool { self & 0x1 != 0 } }
#endif
