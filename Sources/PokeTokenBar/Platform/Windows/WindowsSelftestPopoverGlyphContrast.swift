#if os(Windows)
import Foundation
import WinSDK

// The ink of every glyph button and pill against its own fill, in light, dark and high contrast, at rest, hovered and pressed (a
// disabled control is exempt, WCAG 1.4.11). A star nearly the colour of its button ("the star shape cannot be seen") was reported on
// the real PC; the kit's own buttons are held to 3:1 here and the drawn parts' star by `DexGlyphButtonContrastTests`.
// `popover.glyphContrast.fault` measures the footer triangle in the raw orange it had (2:1 on the light window) and must fail.

extension WindowsSelftest {
    @MainActor static func popoverGlyphContrastChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverGlyphContrast.run(r)
    }
}

@MainActor final class GlyphContrastPage {
    var glyphs: [(name: String, control: WinControl)] = []
    var pills: [(name: String, control: WinControl)] = []
    var rawOrange = false
    var chips: WinControl?
    /// K4: the drop-down and the stepper, whose chevrons are drawn by `WinCustomDraw` (secondary ink on the button's own fill).
    var dropDown: WinControl?, stepper: WinControl?

    func build(_ s: WinStack) {
        let section = s.addSection("Glyphs")
        let symbols: [(String, String, CGFloat)] = [("questionmark.circle", "help", 14), ("sparkles", "shiny filter", 13), ("arrow.up.arrow.down", "sort", 13),
                                                    ("arrow.clockwise", "refresh", 16), ("gearshape", "settings", 16), ("power", "quit", 16), ("eye.slash", "pet", 16),
                                                    ("exclamationmark.triangle", "error triangle", 12)]
        for (symbol, name, size) in symbols {
            let row = section.addRow(name) { pane, ctx in WinControls.glyphButton(symbol: symbol, label: name, size: size, in: pane, ctx: ctx) }
            if let c = row.control {
                if name == "error triangle" { c.glyphColor = s.ctx.colors.statusOrange }  // as Home sets it
                glyphs.append((name, c))
            }
        }
        let sort = section.addRow("sort (filter on)") { pane, ctx in WinControls.glyphButton(symbol: "arrow.up.arrow.down", label: "sort on", size: 13, in: pane, ctx: ctx) }
        sort.control?.glyphColor = s.ctx.colors.palette.accent
        if let c = sort.control { glyphs.append(("sort, filter on (accent)", c)) }
        let chipRow = section.addRow(nil, style: .full) { pane, ctx in
            WinControls.chipGroup(names: ["Claude", "Codex"], marks: [false, false], selected: 0, in: pane, ctx: ctx)
        }
        chips = chipRow.control
        dropDown = section.addRow("drop-down") { pane, ctx in WinControls.combo(["English", "한국어"], selected: 0, in: pane, ctx: ctx) }.control
        stepper = section.addRow("stepper") { pane, ctx in WinControls.stepper(range: 1...5, step: 1, value: 3, format: { "×\($0)" }, in: pane, ctx: ctx) }.control
        let pillSection = s.addSection("Pills")
        let specs: [(String, WinPill)] = [
            ("Back (borderless accent, chevron)", WinPill(style: .borderless, title: "Back", glyph: "chevron.left", textStyle: .body, accent: true)),
            ("Skip (borderless secondary)", WinPill(style: .borderless, title: "Skip", secondary: true, textStyle: .callout)),
            ("Previous / Next (borderless)", WinPill(style: .borderless, title: "Next", glyph: "arrowtriangle.right.fill", glyphAfter: true, textStyle: .caption)),
            ("Details (capsule, chart)", WinPill(style: .capsule, title: "Details", glyph: "chart.bar.xaxis", textStyle: .caption)),
            ("Tab chip, selected", WinPill(style: .tab, title: "Claude", selected: true, bold: true)),
            ("Tab chip, unselected", WinPill(style: .tab, title: "Codex")),
            ("Update (prominent)", WinPill(style: .prominent, title: "Update", textStyle: .callout)),
            ("Disclosure (chevron)", WinPill(style: .disclosure, title: "Advanced", glyph: "chevron.right", textStyle: .body)),
        ]
        for (name, pill) in specs {
            let row = pillSection.addRow(name) { pane, ctx in WinControls.pillButton(pill, in: pane, ctx: ctx) }
            if let c = row.control { pills.append((name, c)) }
        }
    }
}

@MainActor enum WindowsSelftestPopoverGlyphContrast {
    private static func ratio(_ a: COLORREF, _ b: COLORREF) -> Double { PopoverSurface.contrast(WinUIColors.rgb(of: a), WinUIColors.rgb(of: b)) }

    /// (problems, one line per control with the lowest ratio of its states)
    static func evaluate(dark: Bool, highContrast: Bool, rawOrange: Bool) async -> (problems: [String], lines: [String]) {
        let page = GlyphContrastPage()
        page.rawOrange = rawOrange
        guard let w = KitWindow(heightDIP: 700, highContrast: highContrast, dark: highContrast ? nil : dark, register: true,
                                origin: POINT(x: 0, y: 0), build: { _, s in page.build(s) }) else { return (["no window"], []) }
        defer { w.destroy() }
        var problems: [String] = []
        var lines: [String] = []
        let name = highContrast ? "hc" : (dark ? "dark" : "light")
        for (label, c) in page.glyphs {
            var worst = 99.0, worstState = ""
            for (state, pressed, hot) in [("rest", false, false), ("hover", false, true), ("pressed", true, true)] {
                var look = WinControls.glyphColours(c, pressed: pressed, hot: hot, disabled: false)
                if rawOrange, label == "error triangle", let raw = c.glyphColor { look.ink = raw }  // the fault: the colour as it was drawn before the fix
                let r = ratio(look.ink, look.fill)
                if r < worst { worst = r; worstState = state }
            }
            lines.append("\(name) \(label) \(String(format: "%.1f", worst))")
            if worst < 3 { problems.append("\(name): glyph button '\(label)' is \(String(format: "%.2f", worst)):1 against its fill at \(worstState), expected 3:1") }
        }
        if let chips = page.chips {
            // the selected chip (provider and account tabs): ink against its fill at rest, hover and press, as `paintChip` composes them
            let look = WinLook(chips)
            var worst = 99.0, worstState = ""
            for (state, tint) in [("rest", 0.0), ("hover", 0.03), ("pressed", 0.06)] {
                var fill = WinUIColors.blend(look.bg, look.accent, 0.15)
                if tint > 0 { fill = WinUIColors.blend(fill, look.ink, tint) }
                let r = ratio(highContrast ? look.palette.text : look.chipInk(fill: fill), highContrast ? look.palette.window : fill)
                if r < worst { worst = r; worstState = state }
            }
            lines.append("\(name) selected chip \(String(format: "%.1f", worst))")
            if worst < 3 { problems.append("\(name): selected chip is \(String(format: "%.2f", worst)):1 against its fill at \(worstState), expected 3:1") }
        }
        // K4: the chevrons are `secondaryText` on the button's fill (a stepper half under the pointer or press is tinted by the ink at the look's
        // hover and press alphas); the stepper's chevrons are both usable at 3 of 1...5. High contrast: the system draws these buttons.
        if !highContrast {
            if let c = page.dropDown {
                let look = WinLook(c)
                var worst = 99.0, worstState = ""
                for (state, pressed, hot) in [("rest", false, false), ("hover", false, true), ("pressed", true, true)] {
                    let r = ratio(look.palette.secondaryText, look.buttonFill(hot: hot, pressed: pressed))
                    if r < worst { worst = r; worstState = state }
                }
                lines.append("\(name) drop-down chevron \(String(format: "%.1f", worst))")
                if worst < 3 { problems.append("\(name): the drop-down chevron is \(String(format: "%.2f", worst)):1 against its fill at \(worstState), expected 3:1") }
            }
            if let c = page.stepper {
                let look = WinLook(c)
                let base = look.buttonFill(hot: false, pressed: false)
                var worst = 99.0, worstState = ""
                for (state, alpha) in [("rest", 0.0), ("hover", look.hover), ("pressed", look.pressed)] {
                    let fill = alpha > 0 ? WinUIColors.blend(base, look.ink, alpha) : base
                    let r = ratio(look.palette.secondaryText, fill)   // the upper and the lower half are tinted alike
                    if r < worst { worst = r; worstState = state }
                }
                lines.append("\(name) stepper chevrons (both halves) \(String(format: "%.1f", worst))")
                if worst < 3 { problems.append("\(name): a stepper chevron is \(String(format: "%.2f", worst)):1 against its half at \(worstState), expected 3:1") }
            }
        }
        for (label, c) in page.pills {
            guard let pill = c.pillForTesting else { continue }
            var worst = 99.0, worstState = ""
            for (state, pressed, hot) in [("rest", false, false), ("hover", false, true), ("pressed", true, true)] {
                let look = WinControls.pillColours(pill, ctx: c.ctx, background: c.background, pressed: pressed, hot: hot, disabled: false)
                let r = ratio(look.ink, look.fill ?? c.background)
                if r < worst { worst = r; worstState = state }
            }
            lines.append("\(name) \(label) \(String(format: "%.1f", worst))")
            if worst < 3 { problems.append("\(name): pill '\(label)' is \(String(format: "%.2f", worst)):1 against its fill at \(worstState), expected 3:1") }
        }
        return (problems, lines)
    }

    static func run(_ r: WindowsSelftest.Recorder) async {
        var problems: [String] = []
        var lines: [String] = []
        for (dark, high) in [(false, false), (true, false), (false, true)] {
            let result = await evaluate(dark: dark, highContrast: high, rawOrange: false)
            problems.append(contentsOf: result.problems)
            lines.append(contentsOf: result.lines)
        }
        r.add("popover.glyphContrast", problems.isEmpty, "lowest contrast of ink against fill over rest/hover/pressed (:1): " + lines.joined(separator: "; ")
              + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
        let broken = await evaluate(dark: false, highContrast: false, rawOrange: true)
        r.add("popover.glyphContrast.fault", !broken.problems.isEmpty,
              "the footer triangle in its old raw orange: \(broken.problems.count) problem(s) found as expected (\(broken.problems.first ?? "none"))")
    }
}
#endif
