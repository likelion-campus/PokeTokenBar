#if os(Windows)
import Foundation
import WinSDK

/// The popover's GDI fonts for one DPI (stage 7 D6): the Mac's text styles (`PopoverTextStyle`, measured on the Mac) at
/// DIP size x dpi/96 x Windows' text size, in Segoe UI Variable Text (Windows 11) or Segoe UI (Windows 10). Hangul and
/// other scripts come through GDI font linking (Malgun Gothic). Glyphs come from Segoe Fluent Icons (Windows 11) or Segoe
/// MDL2 Assets (`WinGlyphs`), the 🔥/✨ fallbacks from Segoe UI Emoji. Fonts are made on first use and kept until `destroy`.
@MainActor final class WinFonts {
    static let variableText = "Segoe UI Variable Text"
    static let variableSmall = "Segoe UI Variable Small"
    static let variableDisplay = "Segoe UI Variable Display"
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

    /// The style's font at its Windows step (`WinTypeRamp`), optionally at another weight (the section caption is `.caption`
    /// semibold on the Mac). The optical-size family follows the size.
    func font(_ style: PopoverTextStyle, weight: Int? = nil) -> HFONT? {
        let step = WinTypeRamp.step(style)
        let w = weight.map(WinTypeRamp.weight) ?? step.weight
        let (faceName, lfWeight) = Self.face(base: family(forDIP: step.size), weight: w)
        return make(faceName, height: -Int32(pixelSize(step.size)), weight: lfWeight)
    }

    /// DIP to device pixels with the text-size factor.
    func pixelSize(_ dip: CGFloat) -> Int { PopoverTextStyle.pixels(dip * CGFloat(textScale), dpi: Int(dpi)) }

    /// The text face for a size: Segoe UI Variable Small (<= 12 DIP), Text (13-19) or Display (>= 20) on Windows 11 where the
    /// family is installed and GDI links Hangul through it (`linksHangul`); else the plain text face (Windows 10: Segoe UI).
    func family(forDIP dip: CGFloat) -> String {
        guard face == Self.variableText else { return face }
        let name: String
        switch WinTypeRamp.optical(size: dip) {
        case .small: name = Self.variableSmall
        case .text: return face
        case .display: name = Self.variableDisplay
        }
        return Self.isInstalled(name) && Self.linksHangul(name) ? name : face
    }

    /// Whether GDI draws Hangul through this family as through Malgun Gothic (font linking is per family name; a family
    /// without a link would show boxes). Probed once per family: the advance of 한 at 64 px equals Malgun Gothic's. A machine
    /// without Malgun Gothic cannot tell, and the family is used.
    static func linksHangul(_ family: String) -> Bool {
        if let known = hangulLinks[family] { return known }
        let malgun = hangulAdvance("Malgun Gothic")
        let ok = malgun == nil || hangulAdvance(family) == malgun
        hangulLinks[family] = ok
        if !ok { AppLog.write("popover kit: \(family) does not link Hangul; the text face is used for that size") }
        return ok
    }
    private static var hangulLinks: [String: Bool] = [:]

    private static func hangulAdvance(_ family: String) -> Int32? {
        guard isInstalled(family) || family == "Malgun Gothic", let dc = CreateCompatibleDC(nil) else { return nil }
        defer { _ = DeleteDC(dc) }
        var lf = LOGFONTW()
        lf.lfHeight = -64
        lf.lfCharSet = 1
        setFaceName(&lf, family)
        guard let font = CreateFontIndirectW(&lf) else { return nil }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        defer { _ = SelectObject(dc, old) }
        var size = SIZE()
        let units: [UInt16] = [0xD55C]
        guard GetTextExtentPoint32W(dc, units, 1, &size) else { return nil }
        return size.cx
    }

    /// The icon font at `size` DIP (Fluent's crisp sizes are 16, 20, 24, 32).
    func icon(size: CGFloat) -> HFONT? {
        make(iconFace, height: -Int32(PopoverTextStyle.pixels(size * CGFloat(textScale), dpi: Int(dpi))), weight: 400)
    }

    func emoji(size: CGFloat) -> HFONT? {
        make(Self.emojiFace, height: -Int32(PopoverTextStyle.pixels(size * CGFloat(textScale), dpi: Int(dpi))), weight: 400)
    }

    /// A text font at `size` DIP (the Shop wallet's 24 DIP semibold Display: a size the text styles do not have).
    func sized(_ size: CGFloat, weight: Int) -> HFONT? {
        let (faceName, lfWeight) = Self.face(base: family(forDIP: size), weight: WinTypeRamp.weight(weight))
        return make(faceName, height: -Int32(pixelSize(size)), weight: lfWeight)
    }

    /// `LOGFONTW.lfHeight` of a style (negative: the em height in pixels).
    func height(_ style: PopoverTextStyle) -> Int32 { -Int32(pixelSize(WinTypeRamp.step(style).size)) }

    var count: Int { made.count }

    func destroy() {
        for font in made.values { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
        made = [:]
    }

    /// GDI groups at most regular and bold under one family name: semibold is its own family ("Segoe UI Semibold",
    /// "Segoe UI Variable Text Semibold"). Medium has no face in either family and draws regular. The popover uses semibold
    /// where the Mac uses bold (`WinTypeRamp.weight`), so 700 is only for a caller that asks for it here.
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
