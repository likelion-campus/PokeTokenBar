#if os(Windows)
import Foundation

/// The Windows popover's type ramp (visual polish K1). The Mac's text styles (`PopoverTextStyle`, the Mac golden: points on a
/// 2x display) are drawn here at the Windows step above them, because Windows draws DIP 1:1 on 96 DPI: a Mac 10 pt caption is
/// 20 device pixels on a Retina screen but 10 px of GDI text here. Windows 11's own ramp is Caption 12/16, Body 14/20, Body
/// Strong 14/20 semibold, Subtitle 20/28 semibold, Title 28/36 semibold (Microsoft, "Typography in Windows",
/// learn.microsoft.com/windows/apps/design/signature-experiences/typography). The Mac's styles and the shared tests of them stay
/// as they are; only this Windows table differs, by design (`docs/reference/windows-differences.md`).
enum WinTypeRamp {
    /// Segoe UI Variable's optical sizes: Small up to 12, Text 13-19, Display from 20 (the same pairing as the Windows ramp).
    enum Optical: Equatable, Sendable { case small, text, display }

    struct Step: Equatable, Sendable {
        var size: CGFloat
        var weight: Int
    }

    /// The Windows step of a Mac style: size in DIP and weight (400 or 600; GDI has no medium, and Windows emphasises with
    /// semibold, not bold).
    static func step(_ style: PopoverTextStyle) -> Step {
        switch style {
        case .caption, .caption2: Step(size: 12, weight: 400)
        case .callout: Step(size: 13, weight: 400)
        case .body: Step(size: 14, weight: 400)
        case .headline: Step(size: 14, weight: 600)
        case .title3: Step(size: 16, weight: 400)
        case .largeBold: Step(size: 28, weight: 600)
        }
    }

    /// An explicit weight of a call site (the Mac's bold or semibold) as Windows draws it: regular below 550, semibold above.
    static func weight(_ weight: Int) -> Int { weight >= 550 ? 600 : 400 }

    static func optical(size dip: CGFloat) -> Optical { dip <= 12 ? .small : (dip < 20 ? .text : .display) }

    /// A drawn part's `.system(size:)` (Mac points) at the Windows step: s+2 up to 10, s+1 for 11-13, unchanged from 14 up.
    static func drawnSize(_ size: CGFloat) -> CGFloat {
        if size <= 10 { return size + 2 }
        if size < 14 { return size + 1 }
        return size
    }

    /// The same for a drawn part's weight: Windows' semibold where the Mac has bold.
    static func drawnWeight(_ weight: PlazaFontWeight) -> PlazaFontWeight { weight == .bold ? .semibold : weight }
}
#endif
