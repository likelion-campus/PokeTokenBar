#if os(Windows)
import Foundation
import WinSDK

/// The popover's colours in light mode (stage 7 D15; dark mode is Task 16): the window in `COLOR_WINDOW`, cards one step
/// darker, text in `COLOR_WINDOWTEXT`, secondary and tertiary text and the card's lines at Windows' label opacities
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
    }

    /// The Mac's systemBlue in light (sRGB 0, 122, 255): the accent when Windows has none set.
    nonisolated static let systemBlue: COLORREF = 0x00FF_7A00
    /// How much darker than the window a card is.
    nonisolated static let cardStep = 0.045

    let highContrast: Bool
    let palette: Palette
    private var brushes: [COLORREF: HBRUSH] = [:]

    init(highContrast: Bool, accent: COLORREF?) {
        self.highContrast = highContrast
        palette = Self.resolve(highContrast: highContrast, accent: accent) { COLORREF(GetSysColor($0)) }
    }

    /// The palette from the system colours `system(COLOR_…)`: pure, so the light and high-contrast rules are unit-tested.
    nonisolated static func resolve(highContrast: Bool, accent: COLORREF?, system: (Int32) -> COLORREF) -> Palette {
        let window = system(5 /* COLOR_WINDOW */), text = system(8 /* COLOR_WINDOWTEXT */)
        if highContrast {
            return Palette(window: window, card: window, cardBorder: text, divider: text, text: text, secondaryText: text, tertiaryText: text,
                           accent: system(13 /* COLOR_HIGHLIGHT */), pressed: system(13), hot: window)
        }
        let card = blend(window, rgb(0, 0, 0), cardStep)
        return Palette(window: window, card: card,
                       cardBorder: blend(card, rgb(0, 0, 0), PopoverLabelOpacity.separator * 0.6),
                       divider: blend(card, rgb(0, 0, 0), PopoverLabelOpacity.separator),
                       text: text,
                       secondaryText: blend(card, text, PopoverLabelOpacity.secondary(.light, windows: true)),
                       tertiaryText: blend(card, text, PopoverLabelOpacity.tertiary(.light, windows: true)),
                       accent: accent ?? systemBlue,
                       pressed: blend(card, text, 0.14), hot: blend(card, text, 0.07))
    }

    func text(_ role: Role) -> COLORREF {
        switch role {
        case .primary: palette.text
        case .secondary: palette.secondaryText
        case .tertiary: palette.tertiaryText
        case .error: highContrast ? palette.text : Self.rgb(255, 59, 48)
        case .warning: highContrast ? palette.text : Self.rgb(255, 149, 0)
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
