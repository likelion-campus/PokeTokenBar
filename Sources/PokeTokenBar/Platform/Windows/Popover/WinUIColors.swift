#if os(Windows)
import Foundation
import WinSDK

/// The popover's colours (stage 7 D15, Task 16). Light: the window in `COLOR_WINDOW`, cards one step darker, text in
/// `COLOR_WINDOWTEXT`. Dark (`AppsUseLightTheme` = 0): `PopoverSurface.darkWindow`, cards one step lighter, text white at the
/// Mac's primary opacity, the Mac's dark values for status colours and the heatmap. Text colours below are the light case: secondary and tertiary text and the card's lines at Windows' label opacities
/// (`PopoverLabelOpacity.secondary/tertiary(_, windows: true)`: the Mac's, raised for contrast) over the card. High contrast overrides nothing: every role is a system
/// colour and the native controls draw themselves. Brushes are made on first use and freed by `destroy`.
@MainActor final class WinUIColors {
    enum Role: Equatable, Sendable {
        case primary, secondary, tertiary
        /// The Mac's red and orange status lines (an invalid nickname, an update on offer): systemRed and systemOrange in
        /// light; high contrast keeps the window text colour.
        case error, warning
    }

    /// The resolved colours (`COLORREF`, 0x00BBGGRR).
    struct Palette: Equatable, Sendable {
        var window: COLORREF
        var card: COLORREF
        var cardBorder: COLORREF
        var divider: COLORREF
        var text: COLORREF
        var secondaryText: COLORREF
        var tertiaryText: COLORREF
        var accent: COLORREF
        /// A pressed or hovered glyph button's fill.
        var pressed: COLORREF
        var hot: COLORREF
        /// A text field's fill (edits, the drop-down list) and disabled text.
        var field: COLORREF
        var disabled: COLORREF
    }

    /// The Mac's systemBlue in light (sRGB 0, 122, 255): the accent when Windows has none set.
    nonisolated static let systemBlue: COLORREF = 0x00FF_7A00
    /// How much darker than the window a card is.
    nonisolated static let cardStep = 0.045

    let highContrast: Bool
    /// Dark mode (never together with high contrast: that is the system's own colours).
    let dark: Bool
    let palette: Palette
    private var brushes: [COLORREF: HBRUSH] = [:]

    init(highContrast: Bool, dark: Bool = false, accent: COLORREF?) {
        self.highContrast = highContrast
        self.dark = dark && !highContrast
        palette = Self.resolve(highContrast: highContrast, dark: dark, accent: accent) { WinUIContext.sysColor($0) }
    }

    /// `COLORREF` (0x00BBGGRR) of a shared 0xRRGGBB, and back.
    nonisolated static func colorref(_ rgb: UInt32) -> COLORREF { rgb >> 16 & 0xFF | rgb & 0xFF00 | (rgb & 0xFF) << 16 }
    nonisolated static func rgb(of c: COLORREF) -> UInt32 { c >> 16 & 0xFF | c & 0xFF00 | (c & 0xFF) << 16 }

    /// The palette from the system colours `system(COLOR_…)`: pure, so the light, dark and high-contrast rules are unit-tested.
    nonisolated static func resolve(highContrast: Bool, dark: Bool = false, accent: COLORREF?, system: (Int32) -> COLORREF) -> Palette {
        let window = system(5 /* COLOR_WINDOW */), text = system(8 /* COLOR_WINDOWTEXT */)
        if highContrast {
            return Palette(window: window, card: window, cardBorder: text, divider: text, text: text, secondaryText: text, tertiaryText: text,
                           accent: system(13 /* COLOR_HIGHLIGHT */), pressed: system(13), hot: window, field: window,
                           disabled: system(17 /* COLOR_GRAYTEXT */))
        }
        if dark {
            let w = colorref(PopoverSurface.darkWindow), white = rgb(255, 255, 255)
            let card = blend(w, white, PopoverSurface.darkCardStep)
            let given = accent.map { colorref(PopoverSurface.liftedAccent(rgb(of: $0), over: PopoverSurface.darkWindow)) }
            return Palette(window: w, card: card,
                           cardBorder: blend(card, white, PopoverLabelOpacity.separator * 0.6),
                           divider: blend(card, white, PopoverLabelOpacity.separator),
                           text: blend(w, white, PopoverLabelOpacity.primary),
                           secondaryText: blend(card, white, PopoverLabelOpacity.secondary(.dark, windows: true)),
                           tertiaryText: blend(card, white, PopoverLabelOpacity.tertiary(.dark, windows: true)),
                           accent: given ?? colorref(PopoverColorRole.accent.macValue(.dark).rgba >> 8),
                           pressed: blend(card, white, 0.14), hot: blend(card, white, 0.07),
                           field: blend(w, white, PopoverSurface.darkFieldStep),
                           disabled: blend(w, white, PopoverSurface.darkDisabledAlpha))
        }
        let card = blend(window, rgb(0, 0, 0), cardStep)
        return Palette(window: window, card: card,
                       cardBorder: blend(card, rgb(0, 0, 0), PopoverLabelOpacity.separator * 0.6),
                       divider: blend(card, rgb(0, 0, 0), PopoverLabelOpacity.separator),
                       text: text,
                       secondaryText: blend(card, text, PopoverLabelOpacity.secondary(.light, windows: true)),
                       tertiaryText: blend(card, text, PopoverLabelOpacity.tertiary(.light, windows: true)),
                       accent: accent ?? systemBlue,
                       pressed: blend(card, text, 0.14), hot: blend(card, text, 0.07),
                       field: window, disabled: system(17 /* COLOR_GRAYTEXT */))
    }

    /// The orange of warnings, notice glyphs and the footer triangle: the light value the page always used (255, 149, 0), the Mac's
    /// dark orange in dark; high contrast the text colour.
    var statusOrange: COLORREF { highContrast ? palette.text : (dark ? roleColor(.systemOrange) : Self.rgb(255, 149, 0)) }

    /// A role's colour as a `COLORREF`: the Mac's value for the current appearance (light or dark); high contrast keeps the
    /// system's text colour (the accent role is the highlight). `.primary`/`.secondary`/`.tertiary` are the palette's.
    func roleColor(_ role: PopoverColorRole) -> COLORREF {
        switch role {
        case .primary: return palette.text
        case .secondary: return palette.secondaryText
        case .tertiary: return palette.tertiaryText
        case .accent: return palette.accent
        default:
            if highContrast { return palette.text }
            let v = role.macValue(dark ? .dark : .light)
            func byte(_ d: Double) -> UInt8 { UInt8(max(0, min(255, (d * 255).rounded()))) }
            return Self.rgb(byte(v.red), byte(v.green), byte(v.blue))
        }
    }

    func text(_ role: Role) -> COLORREF {
        switch role {
        case .primary: palette.text
        case .secondary: palette.secondaryText
        case .tertiary: palette.tertiaryText
        case .error: highContrast ? palette.text : (dark ? roleColor(.systemRed) : Self.rgb(255, 59, 48))
        case .warning: statusOrange
        }
    }

    /// A solid brush of `color`, made once.
    func brush(_ color: COLORREF) -> HBRUSH? {
        if let b = brushes[color] { return b }
        guard let b = CreateSolidBrush(color) else { return nil }
        brushes[color] = b
        return b
    }

    var count: Int { brushes.count }

    func destroy() {
        for b in brushes.values { _ = DeleteObject(UnsafeMutableRawPointer(b)) }
        brushes = [:]
    }

    nonisolated static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> COLORREF { COLORREF(r) | COLORREF(g) << 8 | COLORREF(b) << 16 }

    /// `a` moved towards `b` by `t` (0 = a, 1 = b), per channel, rounded.
    nonisolated static func blend(_ a: COLORREF, _ b: COLORREF, _ t: Double) -> COLORREF {
        func ch(_ c: COLORREF, _ shift: COLORREF) -> Double { Double((c >> shift) & 0xFF) }
        var out: COLORREF = 0
        for shift: COLORREF in [0, 8, 16] {
            let v = (ch(a, shift) + (ch(b, shift) - ch(a, shift)) * t).rounded()
            out |= COLORREF(min(255, max(0, v))) << shift
        }
        return out
    }
}
#endif
