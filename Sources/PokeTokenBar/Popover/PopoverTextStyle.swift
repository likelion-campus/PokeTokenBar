import Foundation

/// The Mac popover's text styles, as the Windows kit sizes its fonts (stage 7 D6). The size is the Mac's point size used as
/// DIP; the weight is CSS/GDI's (400 regular, 500 medium, 600 semibold, 700 bold). The Mac measures both into
/// `Tests/PopoverParity/mac-text-styles.json` (`PopoverTextStyleGoldensMacTests`); a shared test holds this table to that file.
/// Monospaced digits (`.monospacedDigit()` on the Mac) need no style of their own on Windows: Segoe UI's figures are tabular.
enum PopoverTextStyle: String, CaseIterable, Sendable {
    /// SwiftUI's default text, also every Form row's label.
    case body
    case callout
    case caption
    case caption2
    case headline
    case title3
    /// `.system(size: 28, weight: .bold)`: the today total (P5).
    case largeBold

    var size: CGFloat {
        switch self {
        case .body, .headline: 13
        case .callout: 12
        case .caption, .caption2: 10
        case .title3: 15
        case .largeBold: 28
        }
    }

    var weight: Int {
        switch self {
        case .body, .callout, .caption, .title3: 400
        case .caption2: 500
        case .headline, .largeBold: 700
        }
    }

    /// The em height in device pixels at `dpi`, with the Windows text-size factor (`LOGFONTW.lfHeight` is its negative):
    /// DIP times dpi/96, never below 1.
    func pixelSize(dpi: Int, textScale: Double = 1) -> Int {
        Self.pixels(size * CGFloat(textScale), dpi: dpi)
    }

    /// DIP to whole device pixels at `dpi`, rounded half up, at least 1 for a positive length.
    static func pixels(_ dip: CGFloat, dpi: Int) -> Int {
        guard dip > 0 else { return 0 }
        return max(1, Int((dip * CGFloat(dpi) / 96).rounded(.toNearestOrAwayFromZero)))
    }

    /// Windows' "Text size" (Settings > Accessibility, `HKCU\Software\Microsoft\Accessibility\TextScaleFactor`, 100…225 %)
    /// as a factor; anything outside that range is 1.
    static func textScale(registryPercent: Int?) -> Double {
        guard let p = registryPercent, (100...225).contains(p) else { return 1 }
        return Double(p) / 100
    }
}

/// The opacities of the Mac's label colours in the light appearance (`labelColor`, `secondaryLabelColor`,
/// `tertiaryLabelColor`, `separatorColor`: black at these alphas), measured into `mac-text-styles.json`. These are the
/// MAC's numbers and stay the reference; what Windows draws is `secondary(_:windows:)` / `tertiary(_:windows:)` below.
enum PopoverLabelOpacity {
    static let primary = 0.8471
    static let secondary = 0.498
    static let tertiary = 0.2588
    static let separator = 0.098

    /// Windows deviation from the Mac (approved by the user, user report 2026-11-17, a real Windows 11 PC): the Mac's 26 %
    /// black is about 1.9:1 against white, and with Windows' thinner glyph rendering the tertiary texts (the companion
    /// caption, "This week" / "This month", hints, "updated 0s ago", arrows) read as white on white. Tertiary 0.55 is about
    /// #737373 on white (4.7:1, WCAG AA); secondary is raised to 0.68 (#525252, 7.6:1) so primary > secondary > tertiary
    /// stays visible. Light only; dark values are not built yet (the dark case below keeps the Mac's until Task 16).
    static let windowsLightSecondary = 0.68
    static let windowsLightTertiary = 0.55

    /// The secondary label opacity in `appearance`: the Mac's, or Windows' where `windows`.
    static func secondary(_ appearance: PopoverAppearance, windows: Bool) -> Double {
        // TODO(dark mode, Task 16): Windows dark values go here; until then dark keeps the Mac's.
        windows && appearance == .light ? windowsLightSecondary : secondary
    }

    /// The tertiary label opacity in `appearance`: the Mac's, or Windows' where `windows`.
    static func tertiary(_ appearance: PopoverAppearance, windows: Bool) -> Double {
        windows && appearance == .light ? windowsLightTertiary : tertiary
    }

    /// What the drawing on this platform uses (single call site of the platform switch: `PopoverPlatform.isWindows`).
    static func displayedSecondary(_ appearance: PopoverAppearance = .light) -> Double { secondary(appearance, windows: PopoverPlatform.isWindows) }
    static func displayedTertiary(_ appearance: PopoverAppearance = .light) -> Double { tertiary(appearance, windows: PopoverPlatform.isWindows) }
}
