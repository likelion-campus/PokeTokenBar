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
/// `tertiaryLabelColor`, `separatorColor`: black at these alphas), measured into `mac-text-styles.json`. The Windows kit
/// draws secondary and tertiary text as the window text at these opacities over its background (D15).
enum PopoverLabelOpacity {
    static let primary = 0.8471
    static let secondary = 0.498
    static let tertiary = 0.2588
    static let separator = 0.098
}
