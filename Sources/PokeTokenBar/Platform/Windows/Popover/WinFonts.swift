#if os(Windows)
import Foundation
import WinSDK

/// The popover's GDI fonts for one DPI (stage 7 D6): the Mac's text styles (`PopoverTextStyle`, measured on the Mac) at
/// DIP size x dpi/96 x Windows' text size, in Segoe UI Variable Text (Windows 11) or Segoe UI (Windows 10). Hangul and
/// other scripts come through GDI font linking (Malgun Gothic). Glyphs come from Segoe Fluent Icons (Windows 11) or Segoe
/// MDL2 Assets (`WinGlyphs`), the 🔥/✨ fallbacks from Segoe UI Emoji. Fonts are made on first use and kept until `destroy`.
@MainActor final class WinFonts {
    static let variableText = "Segoe UI Variable Text"
    static let segoeUI = "Segoe UI"
    static let fluentIcons = "Segoe Fluent Icons"
    static let mdl2Assets = "Segoe MDL2 Assets"
    static let emojiFace = "Segoe UI Emoji"

    let dpi: UINT
    let textScale: Double
    /// The text face this machine has.
    let face: String
    /// The icon face this machine has (Fluent first).
    let iconFace: String
    var iconIsFluent: Bool { iconFace == Self.fluentIcons }

    private struct Key: Hashable {
        let face: String
        let height: Int32
        let weight: Int32
    }
    private var made: [Key: HFONT] = [:]
    private static var installed: [String: Bool] = [:]

    init(dpi: UINT, textScale: Double) {
        self.dpi = dpi
        self.textScale = textScale
        face = Self.isInstalled(Self.variableText) ? Self.variableText : Self.segoeUI
        iconFace = Self.isInstalled(Self.fluentIcons) ? Self.fluentIcons : Self.mdl2Assets
    }

    /// The style's font, optionally at another weight (the section caption is `.caption` semibold on the Mac).
    func font(_ style: PopoverTextStyle, weight: Int? = nil) -> HFONT? {
        let (faceName, lfWeight) = Self.face(base: face, weight: weight ?? style.weight)
        return make(faceName, height: -Int32(style.pixelSize(dpi: Int(dpi), textScale: textScale)), weight: lfWeight)
    }

    /// The icon font at `size` DIP (Fluent's crisp sizes are 16, 20, 24, 32).
    func icon(size: CGFloat) -> HFONT? {
        make(iconFace, height: -Int32(PopoverTextStyle.pixels(size * CGFloat(textScale), dpi: Int(dpi))), weight: 400)
    }

    func emoji(size: CGFloat) -> HFONT? {
        make(Self.emojiFace, height: -Int32(PopoverTextStyle.pixels(size * CGFloat(textScale), dpi: Int(dpi))), weight: 400)
    }

    /// `LOGFONTW.lfHeight` of a style (negative: the em height in pixels).
    func height(_ style: PopoverTextStyle) -> Int32 { -Int32(style.pixelSize(dpi: Int(dpi), textScale: textScale)) }

    var count: Int { made.count }

    func destroy() {
        for font in made.values { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        made = [:]
    }

    /// GDI groups at most regular and bold under one family name: semibold is its own family ("Segoe UI Semibold",
    /// "Segoe UI Variable Text Semibold"). Medium has no face in either family and draws regular.
    static func face(base: String, weight: Int) -> (String, Int32) {
        if weight >= 650 { return (base, 700) }
        if weight >= 550 {
            let semibold = base + " Semibold"
            return isInstalled(semibold) ? (semibold, 400) : (base, 600)
        }
        return (base, 400)
    }

    /// Whether a font family of this name is installed (`EnumFontFamiliesExW` on that name; cached for the process).
    static func isInstalled(_ family: String) -> Bool {
        if let known = installed[family] { return known }
        var lf = LOGFONTW()
        lf.lfCharSet = 1  // DEFAULT_CHARSET
        setFaceName(&lf, family)
        var found: Int32 = 0
        let dc = GetDC(nil)
        _ = withUnsafeMutablePointer(to: &found) { flag in
            EnumFontFamiliesExW(dc, &lf, { _, _, _, lParam in
                UnsafeMutablePointer<Int32>(bitPattern: Int(lParam))?.pointee = 1
                return 0
            }, LPARAM(Int(bitPattern: flag)), 0)
        }
        _ = ReleaseDC(nil, dc)
        installed[family] = found != 0
        return found != 0
    }

    static func setFaceName(_ lf: inout LOGFONTW, _ name: String) {
        let units = Array(name.utf16.prefix(31)) + [0]
        withUnsafeMutableBytes(of: &lf.lfFaceName) { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for (i, u) in units.enumerated() where i < p.count { p[i] = u }
        }
    }

    private func make(_ faceName: String, height: Int32, weight: Int32) -> HFONT? {
        let key = Key(face: faceName, height: height, weight: weight)
        if let font = made[key] { return font }
        var lf = LOGFONTW()
        lf.lfHeight = height
        lf.lfWeight = weight
        lf.lfCharSet = 1  // DEFAULT_CHARSET
        lf.lfQuality = 0  // DEFAULT_QUALITY: the user's own font smoothing setting (ClearType, greyscale or none)
        Self.setFaceName(&lf, faceName)
        guard let font = CreateFontIndirectW(&lf) else {
            AppLog.write("popover kit: CreateFontIndirectW(\(faceName), \(height)) failed")
            return nil
        }
        made[key] = font
        return font
    }
}
#endif
