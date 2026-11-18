#if os(Windows)
import Foundation
import WinSDK

// Visual polish K3: the custom-drawn native controls (segmented control, switch, push buttons, slider, capsule chips). Fixture
// texts only; the windows are KitWindows (no popover, nothing shown to a person except on the runner).
//
// What is proved, per appearance (light, dark, simulated high contrast):
//   - custom draw ran for every kind (a control that silently fell back to the system's drawing has `customDrawCount` 0);
//   - the raised segment and the unselected track are the look's colours (pixels), AND the checked state is the radio's (`BM_GETCHECK`);
//   - a switch's on and off differ in pixels (accent track vs plain) AND in the check box's state;
//   - a disabled button's text is visibly weaker than an enabled one's, and the primary button is the accent;
//   - the controls keep their native classes and styles (role: radio button, check box, push button, trackbar);
//   - high contrast: nothing is custom drawn and the system's drawing still shows the checked segment (pixels differ).
// `popover.customDraw.fault` runs the same evaluation with custom draw turned off and passes only when the evaluation FAILS: the
// guard is proved to guard, in every run, without a second CI round.

extension WindowsSelftest {
    @MainActor static func popoverCustomDrawChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverCustomDraw.run(r)
    }
}

@MainActor final class CustomDrawPage {
    var segments: WinControl?, chips: WinControl?, on: WinControl?, off: WinControl?
    var enabled: WinControl?, disabled: WinControl?, primary: WinControl?, small: WinControl?, slider: WinControl?

    func build(_ s: WinStack) {
        let section = s.addSection("Custom draw")
        segments = section.addRow(nil, style: .full) { pane, ctx in WinControls.radioGroup(["Used", "Remaining", "Third"], selected: 1, in: pane, ctx: ctx) }.control
        chips = section.addRow(nil, style: .full) { pane, ctx in
            WinControls.chipGroup(names: ["Claude", "Codex", "Gemini"], marks: [false, true, false], selected: 0, in: pane, ctx: ctx)
        }.control
        on = section.addToggle("Switch on", isOn: true).control
        off = section.addToggle("Switch off", isOn: false).control
        enabled = section.addRow("Enabled") { pane, ctx in WinControls.button("Refresh", in: pane, ctx: ctx) }.control
        disabled = section.addRow("Disabled") { pane, ctx in WinControls.button("Refresh", in: pane, ctx: ctx) }.control
        primary = section.addRow("Primary") { pane, ctx in WinControls.button("Update", style: .primary, in: pane, ctx: ctx) }.control
        small = section.addRow("Small") { pane, ctx in WinControls.button("Buy", small: true, in: pane, ctx: ctx) }.control
        slider = section.addRow("Slider") { pane, ctx in
            WinControls.trackbar(range: 0...10, step: 1, value: 4, format: { "\($0)" }, width: 170, in: pane, ctx: ctx)
        }.control
        disabled?.isEnabled = false
    }
}

@MainActor enum WindowsSelftestPopoverCustomDraw {
    static let names = ["popover.customDraw", "popover.customDraw.fault"]

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    /// A window's client pixels (BGRA).
    struct Shot {
        let width: Int, height: Int
        let bgra: [UInt8]

        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let cx = min(max(0, x), width - 1), cy = min(max(0, y), height - 1)
            let i = (cy * width + cx) * 4
            return (Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
        }

        func luma(_ x: Int, _ y: Int) -> Double {
            let c = rgb(x, y)
            return 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)
        }

        /// How far the strongest-contrast pixel is from the reference pixel's brightness: the text's strength.
        func contrast(against reference: (x: Int, y: Int)) -> Double {
            let ref = luma(reference.x, reference.y)
            var best = 0.0
            for y in 0..<height { for x in 0..<width { best = max(best, abs(luma(x, y) - ref)) } }
            return best
        }
    }

    static func shot(_ hwnd: HWND) -> Shot? {
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let w = Int(client.right - client.left), h = Int(client.bottom - client.top)
        guard w > 0, h > 0, let dc = CreateCompatibleDC(nil) else { return nil }
        defer { _ = DeleteDC(dc) }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(w)
        info.bmiHeader.biHeight = -Int32(h)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        var bits: UnsafeMutableRawPointer?
        guard let dib = CreateDIBSection(dc, &info, 0, &bits, nil, 0), let bits else { return nil }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(dib)) }
        let old = SelectObject(dc, UnsafeMutableRawPointer(dib))
        defer { _ = SelectObject(dc, old) }
        guard PrintWindow(hwnd, dc, UINT(1) /* PW_CLIENTONLY */) else { return nil }
        _ = GdiFlush()
        return Shot(width: w, height: h, bgra: Array(UnsafeRawBufferPointer(start: bits, count: w * h * 4)))
    }

    private static func near(_ a: (r: Int, g: Int, b: Int), _ c: COLORREF, tolerance: Int = 4) -> Bool {
        abs(a.r - Int(c & 0xFF)) <= tolerance && abs(a.g - Int((c >> 8) & 0xFF)) <= tolerance && abs(a.b - Int((c >> 16) & 0xFF)) <= tolerance
    }

    private static func byte(_ v: Int) -> String { (v < 16 ? "0" : "") + String(v, radix: 16, uppercase: true) }
    private static func hex(_ a: (r: Int, g: Int, b: Int)) -> String { "#" + byte(a.r) + byte(a.g) + byte(a.b) }

    /// One appearance: the problems found (empty = all proved) and a note of the measured values.
    static func evaluate(dark: Bool, highContrast: Bool) async -> (problems: [String], note: String) {
        var problems: [String] = []
        let page = CustomDrawPage()
        guard let w = KitWindow(heightDIP: 700, highContrast: highContrast, dark: highContrast ? nil : dark, register: true,
                                origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else { return (["no window"], "") }
        defer { w.destroy() }
        w.fitToContent()
        w.show(activate: false)
        _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))  // INVALIDATE | ERASE | ALLCHILDREN | UPDATENOW
        await wait(0.4)
        var notes: [String] = []

        // The native classes and styles are untouched (role and state come from them).
        func style(_ h: HWND) -> DWORD { DWORD(bitPattern: GetWindowLongW(h, -16)) }
        guard let seg = page.segments, let chips = page.chips, let on = page.on, let off = page.off, let enabled = page.enabled,
              let disabled = page.disabled, let primary = page.primary, let slider = page.slider, let small = page.small else {
            return (["the page's controls were not made"], "")
        }
        for part in seg.parts + chips.parts where WinKit.className(part) != "Button" || style(part) & 0xF != 0x9 || style(part) & 0x1000 == 0 {
            problems.append("a segment is not a push-like auto radio button")
        }
        for h in [on.hwnd, off.hwnd] where WinKit.className(h) != "Button" || style(h) & 0xF != 0x3 { problems.append("a switch is not an auto check box") }
        for h in [enabled.hwnd, disabled.hwnd, primary.hwnd, small.hwnd] where WinKit.className(h) != "Button" || style(h) & 0xF != 0x0 {
            problems.append("a push button lost its class or style")
        }
        if WinKit.className(slider.hwnd) != "msctls_trackbar32" { problems.append("the slider is not a trackbar") }

        // Custom draw ran for every kind (never in high contrast: the system draws there).
        let drawn = [("segments", seg), ("chips", chips), ("switch", on), ("button", enabled), ("primary", primary), ("slider", slider)]
        // The spike's answer per class: `NM_CUSTOMDRAW` delivered (customDrawCount) or only the WM_PAINT safety net painted (fallback).
        notes.append("NM_CUSTOMDRAW/fallback paints " + drawn.map { "\($0.0)=\($0.1.customDrawCount)/\($0.1.fallbackPaintCount)" }.joined(separator: " "))
        if highContrast {
            for (name, c) in drawn where c.customDrawCount + c.fallbackPaintCount != 0 { problems.append("\(name) was custom drawn in high contrast") }
        } else {
            for (name, c) in drawn where c.customDrawCount + c.fallbackPaintCount == 0 { problems.append("\(name): neither custom draw nor the fallback painted it") }
            for (name, c) in drawn where c.customDrawCount == 0 && c.fallbackPaintCount > 0 { problems.append("\(name): NM_CUSTOMDRAW was not delivered (the fallback painted)") }
        }

        // The checked segment is the radio's checked state and a different picture than its neighbours.
        guard let p0 = seg.parts.first, let p1 = seg.parts.dropFirst().first,
              let a = shot(p0), let b = shot(p1) else { problems.append("no picture of the segments"); return (problems, notes.joined(separator: "; ")) }
        let checked0 = WinKit.send(p0, 0x00F0), checked1 = WinKit.send(p1, 0x00F0)
        if checked0 != 0 || checked1 != 1 { problems.append("segment states \(checked0)/\(checked1), expected 0/1") }
        if highContrast {
            var different = 0
            for i in 0..<min(a.bgra.count, b.bgra.count) where abs(Int(a.bgra[i]) - Int(b.bgra[i])) > 8 { different += 1 }
            if different < 20 { problems.append("high contrast: the checked segment looks like an unchecked one (\(different) channel values differ)") }
            notes.append("high contrast: \(different) channel values differ between a checked and an unchecked segment")
        } else {
            let look = WinLook(seg)
            let y = Int(look.px(5)), x = b.width / 2
            let raised = b.rgb(x, y), flat = a.rgb(x, y)
            if !near(raised, look.thumb) { problems.append("the raised segment is \(hex(raised)), expected the thumb \(hex(from: look.thumb))") }
            if !near(flat, look.track) { problems.append("an unselected segment is \(hex(flat)), expected the track \(hex(from: look.track))") }
            notes.append("segment raised \(hex(raised)) vs track \(hex(flat))")
        }

        // A switch: on and off differ in pixels and in state.
        if !highContrast, let onShot = shot(on.hwnd), let offShot = shot(off.hwnd) {
            var client = RECT()
            _ = GetClientRect(on.hwnd, &client)
            let look = WinLook(on)
            let track = WinCustomDraw.switchTrack(in: client, look)
            let x = Int(track.midX), y = Int(track.midY)
            let onPixel = onShot.rgb(x, y), offPixel = offShot.rgb(x, y)
            if !near(onPixel, look.accent) { problems.append("an on switch is \(hex(onPixel)), expected the accent \(hex(from: look.accent))") }
            if near(offPixel, look.accent, tolerance: 40) { problems.append("an off switch is as accent as an on one (\(hex(offPixel)))") }
            if WinKit.send(on.hwnd, 0x00F0) != 1 || WinKit.send(off.hwnd, 0x00F0) != 0 { problems.append("switch check states are not 1/0") }
            notes.append("switch on \(hex(onPixel)) off \(hex(offPixel))")
        }

        // Buttons: disabled is weaker than enabled; primary is the accent.
        if !highContrast, let e = shot(enabled.hwnd), let d = shot(disabled.hwnd), let p = shot(primary.hwnd) {
            let ref = (x: e.width / 2, y: 3)
            let strong = e.contrast(against: ref), weak = d.contrast(against: ref)
            if !(weak < strong - 25) { problems.append("a disabled button's text (\(Int(weak))) is not visibly weaker than an enabled one's (\(Int(strong)))") }
            if IsWindowEnabled(disabled.hwnd) { problems.append("the disabled button is enabled") }
            let look = WinLook(primary)
            let corner = p.rgb(p.width / 2, 3)
            if !near(corner, look.accent) { problems.append("the primary button is \(hex(corner)), expected the accent \(hex(from: look.accent))") }
            notes.append("button text contrast enabled \(Int(strong)) disabled \(Int(weak)); primary \(hex(corner))")
        }
        // The slider's accent fill reaches the thumb: the track left of the thumb is the accent, right of it the strong stroke.
        if !highContrast, let s = shot(slider.parts[0]) {
            let look = WinLook(slider)
            let y = s.height / 2
            let left = s.rgb(Int(look.px(8)), y)
            let right = s.rgb(s.width - Int(look.px(8)), y)
            if !near(left, look.accent) { problems.append("the slider's filled track is \(hex(left)), expected the accent") }
            if near(right, look.accent, tolerance: 30) { problems.append("the slider's empty track is as accent as the filled one (\(hex(right)))") }
            notes.append("slider filled \(hex(left)) empty \(hex(right))")
        }
        return (problems, notes.joined(separator: "; "))
    }

    private static func hex(from c: COLORREF) -> String { hex((r: Int(c & 0xFF), g: Int((c >> 8) & 0xFF), b: Int((c >> 16) & 0xFF))) }

    static func run(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = []
        var notes: [String] = []
        for (name, dark, high) in [("light", false, false), ("dark", true, false), ("high contrast", false, true)] {
            let result = await evaluate(dark: dark, highContrast: high)
            problems.append(contentsOf: result.problems.map { "\(name): \($0)" })
            notes.append("\(name): \(result.note)")
        }
        r.add("popover.customDraw", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))

        // The guard guards: the same evaluation with custom draw off must find problems.
        WinCustomDraw.testDisabled = true
        let broken = await evaluate(dark: false, highContrast: false)
        WinCustomDraw.testDisabled = false
        r.add("popover.customDraw.fault", !broken.problems.isEmpty,
              "custom draw switched off: \(broken.problems.count) problems found as expected (first: \(broken.problems.first ?? "none"))")
    }
}
#endif
