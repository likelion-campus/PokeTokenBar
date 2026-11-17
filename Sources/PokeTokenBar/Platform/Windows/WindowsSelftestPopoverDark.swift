#if os(Windows)
import Foundation
import WinSDK

// Stage 7 Task 16: the popover follows the app mode (dark) and high-contrast themes while it is open. Two checks:
//   ui.dark.switch   light -> dark -> light on one open window, driven by WM_SETTINGCHANGE("ImmersiveColorSet") with the
//                    selftest override standing in for the registry value: every time the page is rebuilt through the
//                    drawing-once path, the shared drawn-part state follows, the page's dominant colour is the new palette's
//                    (no stale light rectangle), and the resources are flat over repeated switches (PopoverResourceRule).
//   ui.highContrast  injected, changes nothing on the machine. ui.highContrast.system: the real SPI_SETHIGHCONTRAST (GitHub Actions runners only, restored in a defer): the window follows, the palette is the
//                    system's colours, the shared state is high contrast; captured as kit-highcontrast.png with --dump-ui.
@MainActor enum WindowsSelftestPopoverDark {
    static func run(_ r: WindowsSelftest.Recorder) async {
        await switchCheck(r)
        injectedHighContrastCheck(r)
        await highContrastCheck(r)
    }

    /// `ui.highContrast`: high contrast injected into the context (no system setting touched, every run): the palette is the
    /// system colours, the shared drawn-part state is high contrast, and the colour mapping holds.
    private static func injectedHighContrastCheck(_ r: WindowsSelftest.Recorder) {
        defer { PopoverAppearanceState.reset() }
        let ctx = WinUIContext(dpi: 96, owner: nil, textScale: 1, highContrast: true, dark: true)
        defer { ctx.destroy() }
        let p = ctx.colors.palette
        let win = COLORREF(GetSysColor(5)), text = COLORREF(GetSysColor(8)), hi = COLORREF(GetSysColor(13))
        let paletteOK = p.window == win && p.text == text && p.secondaryText == text && p.tertiaryText == text && p.cardBorder == text
            && p.accent == hi && !ctx.dark
        let state = PopoverAppearanceState.highContrast
        let stateOK = state?.window == WinUIColors.rgb(of: win) && state?.text == WinUIColors.rgb(of: text) && PopoverAppearanceState.appearance == .light
        let tertiary = PopoverColorRole.tertiary.plazaColor(), accent = PopoverColorRole.accent.plazaColor()
        let mapOK = tertiary.alpha == 1 && Int((accent.red * 255).rounded()) == Int(hi & 0xFF)
        r.add("ui.highContrast", paletteOK && stateOK && mapOK,
              "injected (no system setting changed): palette is the system's=\(paletteOK) (dark requested but ignored: dark=\(ctx.dark)); shared state=\(stateOK); role mapping (tertiary opaque, accent = highlight)=\(mapOK)")
    }

    /// The most frequent pixel colour (0xRRGGBB) and the share of near-white pixels of a capture.
    private static func profile(_ bitmap: WinUIDump.Bitmap) -> (dominant: UInt32, nearWhite: Double) {
        var counts: [UInt32: Int] = [:]
        var white = 0
        let total = bitmap.width * bitmap.height
        bitmap.bgra.withUnsafeBufferPointer { px in
            for i in 0..<total {
                let b = UInt32(px[i * 4]), g = UInt32(px[i * 4 + 1]), r = UInt32(px[i * 4 + 2])
                counts[r << 16 | g << 8 | b, default: 0] += 1
                if r > 0xE0, g > 0xE0, b > 0xE0 { white += 1 }
            }
        }
        let top = counts.max { $0.value < $1.value }?.key ?? 0
        return (top, total > 0 ? Double(white) / Double(total) : 0)
    }

    private static func hex(_ v: UInt32) -> String { "#" + String(format: "%06X", v) }

    private static func settle() async { _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false } }

    // MARK: ui.dark.switch

    private static func switchCheck(_ r: WindowsSelftest.Recorder) async {
        let saved = WinDarkMode.testOverride
        defer { WinDarkMode.testOverride = saved; PopoverAppearanceState.reset() }
        WinDarkMode.testOverride = false
        let page = GalleryPage()
        guard let w = KitWindow(heightDIP: 400, build: { _, s in page.build(s) }) else {
            r.add("ui.dark.switch", false, "the kit window could not be made: \(GetLastError())")
            return
        }
        defer { if !w.isDestroyed { w.destroy() } }
        w.fitToContent()
        w.show(activate: false)
        _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        await settle()

        var steps: [String] = []
        var ok = true
        var samples: [PopoverResourceRule.Sample] = []
        func step(_ name: String, dark: Bool) async {
            let rebuilds0 = w.rebuilds, once0 = WinKit.drawnOnce
            WinDarkMode.testOverride = dark
            WinKit.send(w.hwnd, 0x001A /* WM_SETTINGCHANGE */, 0, text: "ImmersiveColorSet")
            _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
            await settle()
            let palette = w.ctx.colors.palette
            let want = dark ? PopoverSurface.darkWindow : WinUIColors.rgb(of: palette.window)
            let shot = WindowsSelftestPopover.capture(w).map(profile)
            let dominantOK = shot.map { $0.dominant == want || $0.dominant == WinUIColors.rgb(of: palette.card) } ?? false
            let whiteOK = shot.map { dark ? $0.nearWhite < 0.10 : $0.nearWhite > 0.30 } ?? false
            let stateOK = (PopoverAppearanceState.appearance == .dark) == dark && PopoverAppearanceState.highContrast == nil
            let rebuilt = w.rebuilds == rebuilds0 + 1 && WinKit.drawnOnce == once0 + 1 && w.ctx.dark == dark
            let live = WinControl.liveCount
            let res = KitResources.now()
            samples.append(.init(gdi: res.gdi, user: res.user, handles: res.handles))
            let good = dominantOK && whiteOK && stateOK && rebuilt
            ok = ok && good
            steps.append("\(name): dark=\(w.ctx.dark) rebuilt once=\(rebuilt) (drawingOnce +\(WinKit.drawnOnce - once0)) dominant=\(shot.map { hex($0.dominant) } ?? "no capture") "
                         + "want \(hex(want)) or card \(hex(WinUIColors.rgb(of: palette.card))) near-white=\(shot.map { String(format: "%.0f%%", $0.nearWhite * 100) } ?? "?") "
                         + "shared state dark=\(PopoverAppearanceState.appearance == .dark) controls=\(live) ok=\(good)")
        }
        // A message that changes nothing must not rebuild (the focus and the scroll position stay).
        let rebuilds0 = w.rebuilds
        WinKit.send(w.hwnd, 0x001A, 0, text: "ImmersiveColorSet")
        let quiet = w.rebuilds == rebuilds0
        for i in 0..<3 {
            await step("dark #\(i + 1)", dark: true)
            await step("light #\(i + 1)", dark: false)
        }
        let verdict = PopoverResourceRule.judge(samples)
        r.add("ui.dark.switch", ok && quiet && verdict.ok,
              "no change -> no rebuild=\(quiet); " + steps.joined(separator: " | ") + "; \(verdict.summary)")
    }

    // MARK: ui.highContrast

    private static func highContrastCheck(_ r: WindowsSelftest.Recorder) async {
        guard WindowsSelftest.onCI, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            r.add("ui.highContrast.system", true, "skipped: not a GitHub Actions runner (this check flips the real high-contrast setting)"); return
        }
        let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("kit", isDirectory: true)
        let saved = WinDarkMode.testOverride
        WinDarkMode.testOverride = false
        let page = GalleryPage()
        guard let w = KitWindow(heightDIP: 400, build: { _, s in page.build(s) }) else {
            r.add("ui.highContrast.system", false, "the kit window could not be made: \(GetLastError())")
            return
        }
        w.fitToContent()
        w.show(activate: false)
        await settle()

        var original = HIGHCONTRASTW()
        original.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
        guard SystemParametersInfoW(0x0042 /* SPI_GETHIGHCONTRAST */, original.cbSize, &original, 0) else {
            w.destroy()
            r.add("ui.highContrast.system", false, "SPI_GETHIGHCONTRAST failed: \(GetLastError())")
            return
        }
        if original.dwFlags & 0x1 != 0 {  // never touch a session that already runs a high-contrast theme
            w.destroy()
            r.add("ui.highContrast.system", true, "skipped: the session already runs a high-contrast theme (left as it is)")
            return
        }
        // Puts the session's own setting back (high contrast off); idempotent, so it runs both before the verdict and, whatever
        // happens in between (a failed check, an early exit), in the defer.
        func restore() {
            var off = original
            off.dwFlags = original.dwFlags & ~0x1
            _ = SystemParametersInfoW(0x0043 /* SPI_SETHIGHCONTRAST */, off.cbSize, &off, UINT(0x0002 /* SPIF_SENDCHANGE */))
        }
        defer {
            restore()
            WinDarkMode.testOverride = saved
            PopoverAppearanceState.reset()
        }
        // "High Contrast Black" is Windows' own scheme name; the string must stay valid through the call.
        var scheme = WinStr.w("High Contrast Black")
        let on: Bool = scheme.withUnsafeMutableBufferPointer { buffer in
            var hc = HIGHCONTRASTW()
            hc.cbSize = UINT(MemoryLayout<HIGHCONTRASTW>.size)
            hc.dwFlags = 0x1 | 0x4  // HCF_HIGHCONTRASTON | HCF_AVAILABLE
            hc.lpszDefaultScheme = buffer.baseAddress
            return SystemParametersInfoW(0x0043, hc.cbSize, &hc, UINT(0x0002))
        }
        let rebuilt = await WindowsSelftest.waitUntil(timeout: 3) { w.ctx.highContrast }
        await settle()
        let palette = w.ctx.colors.palette
        let sysWindow = COLORREF(GetSysColor(5)), sysText = COLORREF(GetSysColor(8))
        let paletteOK = palette.window == sysWindow && palette.text == sysText && palette.secondaryText == sysText && palette.cardBorder == sysText
        let state = PopoverAppearanceState.highContrast
        let stateOK = state?.window == WinUIColors.rgb(of: sysWindow) && state?.text == WinUIColors.rgb(of: sysText)
        let shot = WindowsSelftestPopover.capture(w)
        let profileText = shot.map(profile).map { "dominant=\(hex($0.dominant)) (window \(hex(WinUIColors.rgb(of: sysWindow))))" } ?? "no capture"
        var wrote = "no --dump-ui"
        if let dir, let shot { wrote = WinUIDump.write(shot, to: dir.appendingPathComponent("kit-highcontrast.png")) == 0 ? "kit-highcontrast.png" : "write FAILED" }
        let dominantOK = shot.map { profile($0).dominant == WinUIColors.rgb(of: sysWindow) } ?? false
        let tree = KitTree.collect(w)
        let checks = tree.check(w)
        w.destroy()
        restore()  // before the verdict, so "restored" is a measurement
        let back = await WindowsSelftest.waitUntil(timeout: 3) { !WinUIContext.systemHighContrast() }
        r.add("ui.highContrast.system", on && rebuilt && paletteOK && stateOK && dominantOK && checks.ok && back,
              "SPI_SETHIGHCONTRAST on=\(on) window rebuilt=\(rebuilt); palette is the system's=\(paletteOK); shared state=\(stateOK); \(profileText); tree \(checks.summary); restored=\(back); \(wrote)")
    }
}
#endif
