#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Visual polish K4: the glyph contrast sweep (`popover.glyphContrast`).
//
// A glyph button's picture is the glyph's ink on its own fill. The detail star was a near-white glyph on a hard-coded white box in dark
// mode and every check stayed green because none of them looked at the two together. Here every glyph button of the popover (the footer's
// refresh, pet eye, settings and quit, Collection's sort and shiny filter, Home's "?" and error triangle, the back chevrons, the drop-down
// chevron, both stepper chevrons) is drawn in a kit window and the window is captured (the dump's own `ptb_window_print`): the fill is the
// pixel inside the button, the ink the pixel farthest from it, and the WCAG ratio of the two must be at least 3:1 (the floor for a graphical
// object) at rest, hovered and pressed, in light, dark and high contrast (the system's colours: just seen). Every number goes in the check's
// detail. `popover.glyphContrast.fault` runs the same sweep with the ink forced onto the fill and passes only when it fails.
//
// The Collection detail star (a drawn part, not a window) is measured the same way in `collection.detail` through `measure` below.

@MainActor final class ContrastPage {
    struct Entry { var name: String; var control: WinControl; var kind: Kind }
    enum Kind { case glyph, pill, dropDown, stepper }
    var entries: [Entry] = []

    func build(_ s: WinStack) {
        let section = s.addSection("Glyph buttons")
        func glyph(_ name: String, _ symbol: String, size: CGFloat = 16, color: ((WinControl) -> COLORREF?)? = nil) {
            let row = section.addRow(name) { pane, ctx in WinControls.glyphButton(symbol: symbol, label: name, size: size, in: pane, ctx: ctx) }
            if let c = row.control {
                if let color { c.glyphColor = color(c) }
                entries.append(Entry(name: name, control: c, kind: .glyph))
            }
        }
        glyph("refresh", "arrow.clockwise")
        glyph("pet eye", "eye")
        glyph("pet eye off", "eye.slash")
        glyph("settings", "gearshape")
        glyph("quit", "power")
        glyph("sort", "arrow.up.arrow.down", size: 13)
        // as the Collection toolbar sets them: a custom sort is the accent ink on a tinted box, the shiny filter on is a gold tint
        glyph("sort (custom)", "arrow.up.arrow.down", size: 13) { c in
            let tinted = WinUIColors.blend(c.ctx.colors.palette.window, c.ctx.colors.palette.accent, 0.12)
            c.background = tinted
            return c.ctx.colors.legible(c.ctx.colors.palette.accent, on: tinted)
        }
        glyph("shiny filter", "sparkles", size: 13)
        glyph("shiny filter on", "sparkles", size: 13) { c in
            c.background = WinUIColors.blend(c.ctx.colors.palette.window, 0x0000_CCFF, 0.18)
            return nil
        }
        glyph("help ?", "questionmark.circle", size: 14)
        glyph("error triangle", "exclamationmark.triangle", size: 12) { $0.ctx.colors.legible($0.ctx.colors.statusOrange, on: $0.ctx.colors.palette.window) }
        glyph("search clear", "xmark.circle.fill", size: 13)
        for (name, pill) in [("back (Settings)", WinPill(style: .borderless, title: "Back", glyph: "chevron.backward", textStyle: .body, accent: true)),
                             ("back (Recap)", WinPill(style: .borderless, title: "Back", glyph: "chevron.left", textStyle: .body))] {
            let row = section.addRow(name) { pane, ctx in WinControls.pillButton(pill, in: pane, ctx: ctx) }
            if let c = row.control { entries.append(Entry(name: name, control: c, kind: .pill)) }
        }
        if let c = section.addRow("drop-down") { pane, ctx in WinControls.combo(["English", "한국어", "日本語"], selected: 0, in: pane, ctx: ctx) }.control {
            entries.append(Entry(name: "drop-down chevron", control: c, kind: .dropDown))
        }
        if let c = section.addRow("stepper") { pane, ctx in WinControls.stepper(range: 1...5, step: 1, value: 3, format: { "×\($0)" }, in: pane, ctx: ctx) }.control {
            entries.append(Entry(name: "stepper up", control: c, kind: .stepper))
            entries.append(Entry(name: "stepper down", control: c, kind: .stepper))
        }
    }
}

@MainActor enum WindowsSelftestPopoverContrast {
    typealias Bitmap = WinUIDump.Bitmap
    /// The floor for a graphical object against its neighbour (WCAG 1.4.11).
    static let floor = 3.0
    /// SELFTEST HOOK for the fault twin: the measured ink is replaced by the fill.
    nonisolated(unsafe) static var testInkIsFill = false

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    static func capture(_ hwnd: HWND) -> Bitmap? {
        var width: UInt32 = 0, height: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &width, &height, &out) == 0, let out else { return nil }
        defer { ptb_plaza_free(out) }
        return Bitmap(width: Int(width), height: Int(height), bgra: Array(UnsafeBufferPointer(start: out, count: Int(width * height) * 4)))
    }

    private static func rgb(_ b: Bitmap, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let cx = min(max(0, x), b.width - 1), cy = min(max(0, y), b.height - 1)
        let i = (cy * b.width + cx) * 4
        return (Int(b.bgra[i + 2]), Int(b.bgra[i + 1]), Int(b.bgra[i]))
    }

    private static func lum(_ c: (r: Int, g: Int, b: Int)) -> Double {
        func ch(_ v: Int) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    static func ratio(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
    }

    /// The fill read at `fill` and the ink farthest from it inside `region` (window pixels): the WCAG ratio and both colours.
    static func measure(_ shot: Bitmap, fill: (x: Int, y: Int), region: RECT) -> (ratio: Double, fill: (r: Int, g: Int, b: Int), ink: (r: Int, g: Int, b: Int)) {
        let f = rgb(shot, fill.x, fill.y)
        var best = f, far = 0
        for y in Int(region.top)..<max(Int(region.top), Int(region.bottom)) {
            for x in Int(region.left)..<max(Int(region.left), Int(region.right)) {
                let p = rgb(shot, x, y)
                let d = abs(p.r - f.r) + abs(p.g - f.g) + abs(p.b - f.b)
                if d > far { far = d; best = p }
            }
        }
        if testInkIsFill { best = f }
        return (ratio(best, f), f, best)
    }

    private static func hex(_ c: (r: Int, g: Int, b: Int)) -> String { WindowsSelftestPopoverCustomDraw.hex(c) }

    /// One appearance: every entry in each state (rest, hover, pressed; a stepper's lower half in its own pair of passes).
    static func evaluate(dark: Bool, highContrast: Bool) async -> (problems: [String], note: String) {
        var problems: [String] = []
        let page = ContrastPage()
        guard let w = KitWindow(heightDIP: 900, highContrast: highContrast, dark: highContrast ? nil : dark, register: true,
                                origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else { return (["no window"], "") }
        defer { w.destroy() }
        w.fitToContent()
        w.show(activate: false)
        _ = RedrawWindow(w.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        await wait(0.4)
        let scale = Double(w.ctx.scale)
        func ipx(_ dip: Double) -> Int { Int((dip * scale).rounded()) }
        var results: [String: [String: Double]] = [:]   // entry -> state -> ratio
        var fills: [String: [String: (r: Int, g: Int, b: Int)]] = [:]
        var order: [String] = []

        func apply(_ state: String) {
            for e in page.entries {
                let c = e.control
                switch (e.kind, state) {
                case (.glyph, "hover"), (.pill, "hover"):
                    c.forceHot(true)
                case (.glyph, "pressed"), (.pill, "pressed"):
                    _ = SendMessageW(c.hwnd, 0x00F3 /* BM_SETSTATE */, 1, 0)
                case (.dropDown, "hover"): c.forceState(hot: 0)
                case (.dropDown, "pressed"): c.forceState(pressed: 0)
                case (.stepper, "hover"): c.forceHalves(hot: e.name == "stepper up" ? 1 : 2, pressed: 0)
                case (.stepper, "pressed"): c.forceHalves(hot: e.name == "stepper up" ? 1 : 2, pressed: e.name == "stepper up" ? 1 : 2)
                default: break
                }
                _ = InvalidateRect(c.hwnd, nil, false)
                _ = UpdateWindow(c.hwnd)
            }
        }
        func clear() {
            for e in page.entries {
                let c = e.control
                switch e.kind {
                case .glyph, .pill:
                    _ = SendMessageW(c.hwnd, 0x00F3, 0, 0)
                    c.forceHot(false)
                case .dropDown: c.forceState()
                case .stepper: c.forceHalves(hot: 0, pressed: 0)
                }
                _ = InvalidateRect(c.hwnd, nil, false)
                _ = UpdateWindow(c.hwnd)
            }
        }

        for state in ["rest", "hover", "pressed"] {
            // the two stepper halves are shown one at a time: their entries take the same state in this pass, each its own half
            clear()
            apply(state)
            await wait(0.15)
            guard let shot = capture(w.hwnd) else { problems.append("no capture for \(state)"); continue }
            for e in page.entries {
                // a stepper's two entries are the two halves of ONE control: the pass shows the half of the entry applied last (down),
                // so the upper half is read in its own pass below
                if e.kind == .stepper, e.name == "stepper up", state != "rest" { continue }
                let r = WinKit.rect(e.control.hwnd, in: w.hwnd)
                let h = Int(r.bottom - r.top), mid = Int(r.top) + h / 2
                let m: (ratio: Double, fill: (r: Int, g: Int, b: Int), ink: (r: Int, g: Int, b: Int))
                switch e.kind {
                case .glyph, .pill:
                    let region = RECT(left: r.left + Int32(ipx(2)), top: r.top + Int32(ipx(2)), right: r.right - Int32(ipx(2)), bottom: r.bottom - Int32(ipx(2)))
                    m = measure(shot, fill: (Int(r.left) + ipx(2), mid), region: e.kind == .pill ? RECT(left: region.left, top: region.top, right: region.left + Int32(ipx(20)), bottom: region.bottom) : region)
                case .dropDown:
                    if highContrast { continue }   // a plain push button there: the system draws it
                    let right = Int(r.right) - ipx(10)
                    m = measure(shot, fill: (Int(r.left) + ipx(4), mid), region: RECT(left: Int32(right - ipx(12) - 2), top: r.top + Int32(ipx(3)), right: Int32(right + 2), bottom: r.bottom - Int32(ipx(3))))
                case .stepper:
                    if highContrast { continue }
                    let boxW = ipx(18), boxH = ipx(24)
                    let boxTop = Int(r.top) + (h - boxH) / 2, boxLeft = Int(r.right) - boxW - ipx(2)
                    let up = e.name == "stepper up"
                    let top = up ? boxTop + 1 : boxTop + boxH / 2, bottom = up ? boxTop + boxH / 2 : boxTop + boxH - 1
                    m = measure(shot, fill: (boxLeft + 2, (top + bottom) / 2), region: RECT(left: Int32(boxLeft + 2), top: Int32(top), right: Int32(boxLeft + boxW - 2), bottom: Int32(bottom)))
                }
                results[e.name, default: [:]][state] = m.ratio
                fills[e.name, default: [:]][state] = m.fill
                if !order.contains(e.name) { order.append(e.name) }
                if m.ratio < floor { problems.append("\(e.name) \(state): glyph \(hex(m.ink)) on \(hex(m.fill)) is \(String(format: "%.2f", m.ratio)):1, below \(floor):1") }
            }
            // the upper half of the stepper in this pass (the entry above was skipped)
            if state != "rest", let e = page.entries.first(where: { $0.name == "stepper up" }), !highContrast {
                clear()
                let c = e.control
                c.forceHalves(hot: 1, pressed: state == "pressed" ? 1 : 0)
                await wait(0.15)
                if let shot2 = capture(w.hwnd) {
                    let r = WinKit.rect(c.hwnd, in: w.hwnd)
                    let h = Int(r.bottom - r.top)
                    let boxW = ipx(18), boxH = ipx(24)
                    let boxTop = Int(r.top) + (h - boxH) / 2, boxLeft = Int(r.right) - boxW - ipx(2)
                    let m = measure(shot2, fill: (boxLeft + 2, boxTop + boxH / 4), region: RECT(left: Int32(boxLeft + 2), top: Int32(boxTop + 1), right: Int32(boxLeft + boxW - 2), bottom: Int32(boxTop + boxH / 2)))
                    results["stepper up", default: [:]][state] = m.ratio
                    if m.ratio < floor { problems.append("stepper up \(state): glyph \(hex(m.ink)) on \(hex(m.fill)) is \(String(format: "%.2f", m.ratio)):1, below \(floor):1") }
                }
            }
            // a state that did not show (the sweep would read the rest picture three times): the fill of a hovered glyph button differs
            if state == "hover", !highContrast, let e = page.entries.first(where: { $0.kind == .glyph }),
               let rest = fills[e.name]?["rest"], let hov = fills[e.name]?["hover"], rest == hov {
                problems.append("hover did not show on \(e.name) (the fill at rest and hovered is \(hex(rest)))")
            }
        }
        clear()
        let table = order.map { n in
            let v = results[n] ?? [:]
            func f(_ s: String) -> String { v[s].map { String(format: "%.2f", $0) } ?? "-" }
            return "\(n) \(f("rest"))/\(f("hover"))/\(f("pressed"))"
        }.joined(separator: "; ")
        return (problems, "rest/hover/pressed: " + table)
    }

    static func run(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = [], notes: [String] = []
        for (name, dark, high) in [("light", false, false), ("dark", true, false), ("high contrast", false, true)] {
            let result = await evaluate(dark: dark, highContrast: high)
            problems.append(contentsOf: result.problems.map { "\(name): \($0)" })
            notes.append("\(name): \(result.note)")
        }
        r.add("popover.glyphContrast", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
        testInkIsFill = true
        let broken = await evaluate(dark: false, highContrast: false)
        testInkIsFill = false
        r.add("popover.glyphContrast.fault", !broken.problems.isEmpty, "ink forced onto the fill: \(broken.problems.count) problems found as expected (first: \(broken.problems.first ?? "none"))")
    }
}
#endif
