import Foundation

/// The plaza window's title bar colours on Windows 11 (`DWMWA_CAPTION_COLOR`, `DWMWA_TEXT_COLOR`, `DWMWA_BORDER_COLOR`), taken
/// from the plaza's own panel palette: the hint pill's fill and text, the banner pill's stroke. Pure, so the Mac tests pin the
/// mapping and the rule for when to apply it; only the Windows window calls DWM.
enum PlazaCaptionTheme {
    /// `COLORREF` values, 0x00BBGGRR.
    struct Colours: Equatable {
        let caption: UInt32, text: UInt32, border: UInt32
    }

    static var plaza: Colours {
        Colours(caption: colorRef(PlazaPanelStyle.hint.fill), text: colorRef(PlazaPanelStyle.hint.text),
                border: colorRef(PlazaPanelStyle.banner.stroke))
    }

    /// Alpha is dropped: the caption is opaque.
    static func colorRef(_ c: PlazaColor) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.blue) << 16 | byte(c.green) << 8 | byte(c.red)
    }

    /// The caption colour attributes exist from Windows 11 (build 22000); Windows 10 ignores them, so nothing is set there.
    /// A high-contrast theme keeps the system's colours.
    static func shouldApply(buildNumber: Int, highContrast: Bool) -> Bool {
        buildNumber >= 22000 && !highContrast
    }
}
