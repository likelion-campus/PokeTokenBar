import Foundation

/// How the popover is dressed right now (stage 7 Task 16): light, dark, or a Windows high-contrast theme. The drawn parts are
/// shared with the Mac and name colours by role (`PopoverColorRole.plazaColor()` and friends); those functions read this
/// state for the appearance they were not given. The Mac never changes it, so the Mac draws light, byte for byte as before.
/// Windows sets it when a popover context is made (`WinUIContext`), before any part draws, and the page is rebuilt when the
/// system changes, so a part never draws with one appearance and keeps a picture of another.
///
/// The one rule for a page: take colours from a role (`ctx.colors.palette`, `ctx.colors.roleColor`, `PopoverColorRole`
/// `.plazaColor()`), never from a literal. Literals do not follow dark mode or high contrast.
enum PopoverAppearanceState {
    /// Written on the main thread before drawing, read while drawing (also on the main thread); no lock needed, and a lock in
    /// every colour lookup would cost more than it protects.
    nonisolated(unsafe) static var appearance: PopoverAppearance = .light
    nonisolated(unsafe) static var highContrast: PopoverHighContrast?

    /// Back to the Mac's light look (tests).
    static func reset() {
        appearance = .light
        highContrast = nil
    }
}

extension PopoverAppearance {
    /// The appearance drawn parts use where the caller names none.
    static var current: PopoverAppearance { PopoverAppearanceState.appearance }

    /// The colour of text and lines at `alpha`: black in light, white in dark, the theme's text colour in high contrast.
    func inkColor(alpha: Double) -> PlazaColor {
        if let hc = PopoverAppearanceState.highContrast { return hc.color(hc.text, alpha: alpha) }
        let v = self == .light ? 0.0 : 1.0
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    /// A translucent chip's fill (the Mac's `.regularMaterial` hover capsules): a light gray in light, a dark gray in dark, the
    /// window colour in high contrast. `light` is the light gray the chip had before dark mode existed.
    func chipColor(light: Double, alpha: Double) -> PlazaColor {
        if let hc = PopoverAppearanceState.highContrast { return hc.color(hc.window, alpha: 1) }
        let v = self == .light ? light : Self.darkChipGray
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    static let darkChipGray = 0.19

    /// A control's fill on the page (the Mac's `controlBackgroundColor`: the "Clear filters" button, a lifted tile under its
    /// shadow): white in light, a raised gray in dark, the window colour in high contrast.
    func controlFill(alpha: Double = 1) -> PlazaColor {
        if let hc = PopoverAppearanceState.highContrast { return hc.color(hc.window, alpha: 1) }
        let v = self == .light ? 1.0 : Self.darkControlGray
        return PlazaColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    static let darkControlGray = 0.27
}

/// A Windows high-contrast theme's colours (`GetSysColor`), as 0xRRGGBB. Everything the drawn parts draw is one of these:
/// text and bars the text colour, today and selection the highlight colour, cards the window colour with text borders.
struct PopoverHighContrast: Equatable, Sendable {
    var window: UInt32
    var text: UInt32
    var highlight: UInt32
    var highlightText: UInt32

    func color(_ rgb: UInt32, alpha: Double) -> PlazaColor {
        PlazaColor(srgbRed: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// What a role is drawn in. The accent is the highlight; every other role is the text colour (a status colour, a
    /// provider's bar colour: high contrast has no hues to spare). `shape` is a bar, track or tint, which keeps at least
    /// `shapeFloor` of the colour so a "faint" bar is still seen against the window; heatmap levels step the text colour's
    /// opacity (level 0 is the window itself).
    func color(for role: PopoverColorRole, alpha: Double, shape: Bool) -> PlazaColor {
        let a = shape ? max(alpha, Self.shapeFloor) : alpha
        switch role {
        case .accent: return color(highlight, alpha: a)
        case .heatmap(let level):
            guard (1...4).contains(level) else { return color(window, alpha: alpha) }
            return color(text, alpha: Double(level) / 4 * alpha)
        default: return color(text, alpha: a)
        }
    }

    static let shapeFloor = 0.35
}

/// The popover's dark surfaces and the contrast arithmetic behind its colour choices (RGB as 0xRRGGBB). Shared so the Mac
/// tests hold the Windows palette to its WCAG floors without a Windows machine.
enum PopoverSurface {
    /// Windows 11's dark window colour; the Mac's dark popover is the same near-black gray. `COLOR_WINDOW` stays white in dark
    /// mode (Win32 does not follow the app mode), so dark colours are given here.
    static let darkWindow: UInt32 = 0x202020
    /// A card is this much lighter than the window in dark (light: 4.5 % darker).
    static let darkCardStep = 0.05
    /// A text field's fill in dark: a step lighter than a card, as Windows 11's own fields are.
    static let darkFieldStep = 0.09
    /// Dark text colour for disabled text: white at this opacity over the window (≥ 3:1, WCAG's floor for disabled/inactive).
    static let darkDisabledAlpha = 0.45
    /// Contrast an accent used as a line or fill must keep against the window (WCAG 1.4.11).
    static let accentFloor = 3.0

    static func channels(_ rgb: UInt32) -> (Double, Double, Double) {
        (Double((rgb >> 16) & 0xFF), Double((rgb >> 8) & 0xFF), Double(rgb & 0xFF))
    }

    /// `a` moved towards `b` by `t`, per channel, rounded.
    static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = channels(a), y = channels(b)
        func ch(_ p: Double, _ q: Double) -> UInt32 { UInt32(min(255, max(0, (p + (q - p) * t).rounded()))) }
        return ch(x.0, y.0) << 16 | ch(x.1, y.1) << 8 | ch(x.2, y.2)
    }

    /// WCAG relative luminance.
    static func luminance(_ rgb: UInt32) -> Double {
        func lin(_ c: Double) -> Double { let v = c / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let c = channels(rgb)
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    /// The light window's colour (Windows 11), as the dark one is `darkWindow`.
    static let lightWindow: UInt32 = 0xF3F3F3

    /// `c` moved towards black (light) or white (dark) until it is `minRatio`:1 against `fill`; one that already passes is returned as it is.
    /// The one rule for an accent or a status colour used as ink (`WinUIColors.legible` is this over the window).
    static func legible(_ c: UInt32, over fill: UInt32, dark: Bool, minRatio: Double = 3) -> UInt32 {
        let toward: UInt32 = dark ? 0xFFFFFF : 0
        var out = c, t = 0.0
        while contrast(out, fill) < minRatio, t < 1 {
            t += 0.05
            out = blend(c, toward, t)
        }
        return out
    }

    /// WCAG contrast ratio, 1…21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The user's accent, lightened towards white until it is `accentFloor` against `window` (a navy accent would vanish on a
    /// dark window). An accent that already passes is returned as it is.
    static func liftedAccent(_ accent: UInt32, over window: UInt32) -> UInt32 {
        var t = 0.0
        var c = accent
        while contrast(c, window) < accentFloor, t < 1 {
            t += 0.05
            c = blend(accent, 0xFFFFFF, t)
        }
        return c
    }
}
