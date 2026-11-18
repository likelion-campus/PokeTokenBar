#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// The popover kit's Windows parts that need GDI but no window (stage 7 Task 3): the fonts per DPI, the glyphs in the
/// installed icon font, the DIB the drawn parts are blitted from, the colour rules, the value snapping and the paste rule.
@MainActor
final class WindowsPopoverKitTests: XCTestCase {
    private func logFont(_ font: HFONT?) -> LOGFONTW {
        var lf = LOGFONTW()
        _ = GetObjectW(UnsafeMutableRawPointer(font), Int32(MemoryLayout<LOGFONTW>.size), &lf)
        return lf
    }

    private func faceName(_ lf: LOGFONTW) -> String {
        var copy = lf
        return withUnsafeBytes(of: &copy.lfFaceName) { String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self) }
    }

    func testFontsAreTheMacSizesAtEachDPI() async {
        for (dpi, body, caption, large) in [(UINT(96), Int32(-13), Int32(-10), Int32(-28)), (120, -16, -13, -35), (144, -20, -15, -42), (192, -26, -20, -56)] {
            let fonts = WinFonts(dpi: dpi, textScale: 1)
            defer { fonts.destroy() }
            XCTAssertEqual(logFont(fonts.font(.body)).lfHeight, body, "body at \(dpi)")
            XCTAssertEqual(logFont(fonts.font(.caption)).lfHeight, caption, "caption at \(dpi)")
            XCTAssertEqual(logFont(fonts.font(.largeBold)).lfHeight, large, "28 pt bold at \(dpi)")
            XCTAssertEqual(logFont(fonts.font(.largeBold)).lfWeight, 700)
            XCTAssertEqual(faceName(logFont(fonts.font(.body))), fonts.face)
        }
        let scaled = WinFonts(dpi: 96, textScale: 1.5)
        defer { scaled.destroy() }
        XCTAssertEqual(logFont(scaled.font(.body)).lfHeight, -20, "Windows' text size scales every font")
        print("POPOVER-FONTS face=\(scaled.face) icons=\(scaled.iconFace)")
    }

    func testTheSameFontIsMadeOnce() async {
        let fonts = WinFonts(dpi: 96, textScale: 1)
        defer { fonts.destroy() }
        XCTAssertEqual(fonts.font(.body), fonts.font(.body))
        _ = fonts.font(.caption)
        _ = fonts.font(.caption, weight: 600)
        XCTAssertEqual(fonts.count, 3)
        fonts.destroy()
        XCTAssertEqual(fonts.count, 0)
    }

    func testSemiboldIsItsOwnFamilyAndMediumDrawsRegular() async {
        XCTAssertEqual(WinFonts.face(base: "Segoe UI", weight: 700).1, 700)
        XCTAssertEqual(WinFonts.face(base: "Segoe UI", weight: 500).1, 400)
        let semibold = WinFonts.face(base: "Segoe UI", weight: 600)
        XCTAssertTrue(semibold == ("Segoe UI Semibold", 400) || semibold == ("Segoe UI", 600), "\(semibold)")
        XCTAssertTrue(WinFonts.isInstalled("Segoe UI"))
        XCTAssertFalse(WinFonts.isInstalled("No Such Font PTB"))
    }

    /// Every symbol with a code point has that glyph in the icon font this machine uses (GetGlyphIndicesW marks a missing one 0xFFFF).
    func testEveryMappedGlyphIsInTheInstalledIconFont() async throws {
        let fonts = WinFonts(dpi: 96, textScale: 1)
        defer { fonts.destroy() }
        let dc = try XCTUnwrap(CreateCompatibleDC(nil))
        defer { _ = DeleteDC(dc) }
        var missing: [String] = []
        for fluent in [true, false] where WinFonts.isInstalled(fluent ? WinFonts.fluentIcons : WinFonts.mdl2Assets) {
            var lf = LOGFONTW()
            lf.lfHeight = -16
            lf.lfCharSet = 1
            WinFonts.setFaceName(&lf, fluent ? WinFonts.fluentIcons : WinFonts.mdl2Assets)
            let font = try XCTUnwrap(CreateFontIndirectW(&lf))
            defer { _ = DeleteObject(UnsafeMutableRawPointer(font)) }
            let old = SelectObject(dc, UnsafeMutableRawPointer(font))
            defer { _ = SelectObject(dc, old) }
            for (symbol, entry) in PopoverGlyphTable.entries.sorted(by: { $0.key < $1.key }) {
                guard let cp = entry.codePoint(fluent: fluent) else { continue }
                var units: [UInt16] = [cp], index: [UInt16] = [0]
                _ = GetGlyphIndicesW(dc, &units, 1, &index, 1 /* GGI_MARK_NONEXISTING_GLYPHS */)
                if index[0] == 0xFFFF { missing.append("\(fluent ? "Fluent" : "MDL2") \(symbol) U+\(String(cp, radix: 16))") }
            }
        }
        print("POPOVER-GLYPHS checked in \(fonts.iconFace) (Fluent installed: \(WinFonts.isInstalled(WinFonts.fluentIcons)), MDL2 installed: \(WinFonts.isInstalled(WinFonts.mdl2Assets))); missing: \(missing)")
        XCTAssertEqual(missing, [])
    }

    /// A FIXTURE bitmap (bytes, not art) through the drawn parts' path: composed BGRA → a 32-bpp top-down DIB → read back
    /// with GetDIBits: the same bytes, row 0 first, premultiplied.
    func testTheDIBOfAFixtureBitmapIsPremultipliedBGRATopDown() async throws {
        var bitmap = PlazaBitmap(width: 3, height: 2)
        bitmap[0, 0] = PlazaRGBA(r: 255, g: 0, b: 0, a: 255)
        bitmap[2, 0] = PlazaRGBA(r: 0, g: 64, b: 0, a: 128)
        bitmap[0, 1] = PlazaRGBA(r: 0, g: 0, b: 200, a: 200)
        bitmap[2, 1] = PlazaRGBA(r: 10, g: 20, b: 30, a: 40)
        let bytes = PopoverComposite.compose([.image(PlazaImage(bitmap: bitmap), frame: CGRect(x: 0, y: 0, width: 3, height: 2))], width: 3, height: 2, scale: 1)
        XCTAssertEqual(Array(bytes[0..<4]), [0, 0, 255, 255], "row 0, pixel 0: red as B, G, R, A")
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = 3
        info.bmiHeader.biHeight = -2
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        let dc = try XCTUnwrap(CreateCompatibleDC(nil))
        defer { _ = DeleteDC(dc) }
        var bits: UnsafeMutableRawPointer?
        let dib = try XCTUnwrap(CreateDIBSection(dc, &info, 0, &bits, nil, 0))
        defer { _ = DeleteObject(UnsafeMutableRawPointer(dib)) }
        bytes.withUnsafeBytes { bits?.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        _ = GdiFlush()
        var back = [UInt8](repeating: 0, count: 24)
        let lines = GetDIBits(dc, dib, 0, 2, &back, &info, 0)
        XCTAssertEqual(lines, 2)
        XCTAssertEqual(back, bytes)
        XCTAssertEqual(Array(back[12..<16]), [200, 0, 0, 200], "row 1 (the bottom row) comes second: blue at alpha 200")
        XCTAssertEqual(Array(back[20..<24]), [30, 20, 10, 40], "premultiplied values pass unchanged")
    }

    func testLightColoursAreWindowsLabelOpacitiesAndHighContrastIsTheSystems() async {
        let system: (Int32) -> COLORREF = { index in
            switch index {
            case 5: WinUIColors.rgb(255, 255, 255)
            case 8: WinUIColors.rgb(0, 0, 0)
            case 13: WinUIColors.rgb(0, 120, 215)
            default: WinUIColors.rgb(1, 2, 3)
            }
        }
        let light = WinUIColors.resolve(highContrast: false, accent: nil, system: system)
        XCTAssertEqual(light.window, WinUIColors.rgb(0xF3, 0xF3, 0xF3), "WinUI SolidBackgroundFillColorBase, not COLOR_WINDOW (K1 layering)")
        XCTAssertEqual(light.card, WinUIColors.rgb(255, 255, 255), "white cards on the grey base, as Windows 11 and the Mac")
        XCTAssertEqual(light.cardBorder, WinUIColors.rgb(229, 229, 229), "black 5.9 % over the base")
        XCTAssertEqual(light.text, WinUIColors.rgb(37, 37, 37), "the Mac's 84.7 % black over the base, not pure COLOR_WINDOWTEXT")
        XCTAssertEqual(light.secondaryText, WinUIColors.rgb(78, 78, 78), "black at Windows' 68 % over the base (the Mac's 49.8 % was too faint: PopoverLabelContrastTests)")
        XCTAssertEqual(light.tertiaryText, WinUIColors.rgb(107, 107, 107), "black at Windows' 56 % over the base (the Mac's 25.9 % read as white on white)")
        XCTAssertGreaterThanOrEqual(PopoverSurface.contrast(WinUIColors.rgb(of: light.tertiaryText), WinUIColors.rgb(of: light.window)), 4.74)
        XCTAssertEqual(light.accent, WinUIColors.systemBlue, "no Windows accent: the Mac's systemBlue")
        XCTAssertEqual(WinUIColors.resolve(highContrast: false, accent: WinUIColors.rgb(9, 8, 7), system: system).accent, WinUIColors.rgb(9, 8, 7))
        let hc = WinUIColors.resolve(highContrast: true, accent: WinUIColors.rgb(9, 8, 7), system: system)
        XCTAssertEqual(hc.card, hc.window, "high contrast: no card colour of ours")
        XCTAssertEqual(hc.secondaryText, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.tertiaryText, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.cardBorder, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.accent, WinUIColors.rgb(0, 120, 215), "high contrast: COLOR_HIGHLIGHT, not the accent")
    }

    func testDarkPaletteIsOurOwnAndHighContrastWinsOverIt() async {
        let system: (Int32) -> COLORREF = { index in
            switch index {
            case 5: WinUIColors.rgb(255, 255, 255)
            case 8: WinUIColors.rgb(0, 0, 0)
            case 13: WinUIColors.rgb(0, 120, 215)
            default: WinUIColors.rgb(1, 2, 3)
            }
        }
        let dark = WinUIColors.resolve(highContrast: false, dark: true, accent: nil, system: system)
        XCTAssertEqual(dark.window, WinUIColors.colorref(PopoverSurface.darkWindow), "not COLOR_WINDOW: Win32 stays white in dark mode")
        XCTAssertNotEqual(dark.card, dark.window)
        XCTAssertEqual(dark.accent, WinUIColors.colorref(0x0091FF), "no Windows accent: the Mac's dark systemBlue")
        for text in [dark.secondaryText, dark.tertiaryText, dark.text] {
            XCTAssertGreaterThanOrEqual(PopoverSurface.contrast(WinUIColors.rgb(of: text), WinUIColors.rgb(of: dark.card)), 4.5)
        }
        XCTAssertGreaterThanOrEqual(PopoverSurface.contrast(WinUIColors.rgb(of: dark.secondaryText), WinUIColors.rgb(of: dark.card)), 7)
        XCTAssertGreaterThanOrEqual(PopoverSurface.contrast(WinUIColors.rgb(of: dark.disabled), WinUIColors.rgb(of: dark.window)), 3)
        let navy = WinUIColors.resolve(highContrast: false, dark: true, accent: WinUIColors.colorref(0x101060), system: system)
        XCTAssertGreaterThanOrEqual(PopoverSurface.contrast(WinUIColors.rgb(of: navy.accent), PopoverSurface.darkWindow), 3, "a dark accent is lifted")
        let both = WinUIColors.resolve(highContrast: true, dark: true, accent: nil, system: system)
        XCTAssertEqual(both.window, WinUIColors.rgb(255, 255, 255), "high contrast wins: the system's colours")
        XCTAssertEqual(WinUIColors.colorref(0xFF8040), WinUIColors.rgb(0xFF, 0x80, 0x40))
        XCTAssertEqual(WinUIColors.rgb(of: WinUIColors.colorref(0x123456)), 0x123456)
    }

    /// K1: the Windows ramp is its own table; the Mac's (`PopoverTextStyle`, the golden) is not touched.
    func testTheWindowsTypeRampStepsAboveTheMacsAndKeepsSemiboldForBold() async {
        let ramp: [(PopoverTextStyle, CGFloat, Int)] = [(.caption, 12, 400), (.caption2, 12, 400), (.callout, 13, 400), (.body, 14, 400),
                                                       (.headline, 14, 600), (.title3, 16, 400), (.largeBold, 28, 600)]
        for (style, size, weight) in ramp {
            XCTAssertEqual(WinTypeRamp.step(style), WinTypeRamp.Step(size: size, weight: weight), "\(style)")
            XCTAssertGreaterThan(WinTypeRamp.step(style).size, style.size, "\(style) is one step above the Mac's points")
        }
        XCTAssertEqual(WinTypeRamp.weight(700), 600, "bold is semibold on Windows")
        XCTAssertEqual(WinTypeRamp.weight(500), 400, "GDI has no medium")
        XCTAssertEqual([10, 12, 13, 20, 28].map { WinTypeRamp.optical(size: CGFloat($0)) }, [.small, .small, .text, .display, .display])
        XCTAssertEqual([9, 10, 11, 13, 14, 20].map { WinTypeRamp.drawnSize(CGFloat($0)) }, [11, 12, 12, 14, 14, 20])
        XCTAssertEqual(WinTypeRamp.drawnWeight(.bold), .semibold)
        XCTAssertEqual(WinTypeRamp.drawnWeight(.regular), .regular)
        XCTAssertEqual(WinPopoverTextEngine.mapped(.system(size: 10, weight: .bold)), .system(size: 12, weight: .semibold))
        XCTAssertEqual(WinPopoverTextEngine.mapped(.mono(size: 10, weight: .bold)), .mono(size: 10, weight: .bold), "the recap LCD keeps its font")
        XCTAssertEqual(WinPopoverTextEngine.mapped(.plaza(.small)), .plaza(.small), "the plaza is not mapped")
        let fonts = WinFonts(dpi: 96, textScale: 1)
        defer { fonts.destroy() }
        XCTAssertEqual(logFont(fonts.font(.body)).lfHeight, -14)
        XCTAssertEqual(logFont(fonts.font(.caption)).lfHeight, -12)
        XCTAssertNotEqual(logFont(fonts.font(.largeBold)).lfWeight, 700, "semibold, never bold")
        XCTAssertEqual(fonts.height(.callout), -13)
    }

    func testSlidersAndSteppersSnapToTheirStep() async {
        XCTAssertEqual(WinControl.snap(72, range: 50...95, step: 5), 70)
        XCTAssertEqual(WinControl.snap(73, range: 50...95, step: 5), 75)
        XCTAssertEqual(WinControl.snap(10, range: 50...95, step: 5), 50)
        XCTAssertEqual(WinControl.snap(120, range: 50...95, step: 5), 95)
        XCTAssertEqual(WinControl.snap(97, range: 80...100, step: 5), 95, "97.5 is not reached: 97 rounds to 95")
        XCTAssertEqual(WinControl.snap(3, range: 0...10, step: 0), 3, "a step of 0 is 1")
    }

    func testACodePasteDropsSpacesAndLineBreaks() async {
        XCTAssertEqual(WinEditKind.codePaste(" PTB-ABCDE-\r\nFGHIJ\t\n"), "PTB-ABCDE-FGHIJ")
        XCTAssertEqual(WinEditKind.codePaste("한글 코드"), "한글코드")
        XCTAssertEqual(WinEditKind.multiLine(lines: 3, cue: "folders").cue, "folders")
        XCTAssertNil(WinEditKind.password(cue: nil).cue)
    }

    /// Review 10: the fonts follow the user's smoothing setting (DEFAULT_QUALITY), not ClearType forced.
    func testFontsUseTheUsersSmoothing() async {
        let fonts = WinFonts(dpi: 96, textScale: 1)
        defer { fonts.destroy() }
        XCTAssertEqual(logFont(fonts.font(.body)).lfQuality, 0)
        XCTAssertEqual(logFont(fonts.icon(size: 16)).lfQuality, 0)
    }

    /// Japanese wraps between characters (a label narrower than the phrase is not squeezed); Latin words and Hangul eojeol stay whole.
    func testJapaneseBreaksBetweenCharacters() async {
        XCTAssertEqual(KitTree.unbreakableRuns("追加のClaudeアカウント"), ["追", "加", "の", "Claude", "ア", "カ", "ウ", "ン", "ト"])
        XCTAssertEqual(KitTree.unbreakableRuns("（孵化・卒業）"), ["（", "孵", "化", "・", "卒", "業", "）"])
        XCTAssertEqual(KitTree.unbreakableRuns("Refresh interval"), ["Refresh", "interval"])
        XCTAssertEqual(KitTree.unbreakableRuns("새로 고침 간격"), ["새로", "고침", "간격"])
    }

    /// Review 7: titles double "&" for controls that read access keys, and give it back.
    func testAmpersandsInTitlesAreDoubled() async {
        let l = L(.en)
        XCTAssertEqual(WinKit.title(l.aboutSupportSectionTitle), "About && Support")
        XCTAssertEqual(WinKit.plainTitle(WinKit.title(l.transferSectionTitle)), l.transferSectionTitle)
        XCTAssertEqual(WinKit.title("no ampersand"), "no ampersand")
    }

    /// Review 4: every label of the Mac's Settings rows (the real `L` strings), in every language, at Windows text sizes 100,
    /// 125 and 150 %, beside controls 60 to 180 DIP wide: the label is never narrower than its widest word (it wraps, or
    /// goes above the control). Measured with GDI in the kit's own font.
    func testNoSettingsLabelIsCutInAnyLanguageOrTextSize() async throws {
        let labels: [KeyPath<L, String>] = [
            \.additionalClaudeAccountsLabel, \.checkForUpdatesLabel, \.critical, \.customScanRootsLabel, \.dailyTrendPeriod,
            \.exportSaveLabel, \.floatingPetAgentActivityLabel, \.floatingPetEnableLabel, \.floatingPetSizeLabel, \.importSaveLabel,
            \.language, \.launchAtLogin, \.limitDisplayModeLabel, \.refreshInterval, \.refreshLimitToken, \.reportProblem,
            \.representativePokemonLabel, \.sessionKeyOrganizationLabel, \.showLogFile, \.statusChecksLabel, \.warning,
            \.companionNotificationsLabel, \.limitNotificationsLabel, \.updateNotificationsLabel,
        ]
        let dc = try XCTUnwrap(CreateCompatibleDC(nil))
        defer { _ = DeleteDC(dc) }
        func measure(_ text: String, width: Int32?) -> CGSize {
            var r = RECT(left: 0, top: 0, right: width ?? 0x7FFF, bottom: 0)
            let flags = UINT(DT_CALCRECT | DT_NOPREFIX) | (width == nil ? UINT(DT_SINGLELINE) : UINT(DT_WORDBREAK))
            _ = WinStr.w(text).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &r, flags) }
            return CGSize(width: CGFloat(r.right - r.left), height: CGFloat(r.bottom - r.top))
        }
        var cut: [String] = []
        var checked = 0, stacked = 0
        for scale in [1.0, 1.25, 1.5] {
            let fonts = WinFonts(dpi: 96, textScale: scale)
            let old = SelectObject(dc, UnsafeMutableRawPointer(fonts.font(.body)))
            for language in AppLanguage.allCases {
                let l = L(language)
                for path in labels {
                    let text = l[keyPath: path]
                    let widest = KitTree.unbreakableRuns(text).map { measure($0, width: nil).width }.max() ?? 0
                    for control in [60, 90, 120, 150, 180] as [CGFloat] {
                        let row = PopoverStackRow(style: .trailing, control: CGSize(width: control * CGFloat(scale), height: 24)) { w in
                            (measure(text, width: Int32(w)), nil)
                        }
                        let frames = PopoverStackLayout.layout([PopoverStackSection(rows: [row])], width: 343, metrics: .settings)
                        let row0 = try XCTUnwrap(frames.sections[0]?.rows[0])
                        let label = try XCTUnwrap(row0.label)
                        checked += 1
                        if let c = row0.control, c.minY > label.minY { stacked += 1 }
                        if label.width + 1 < widest { cut.append("\(language) '\(text)' at \(Int(scale * 100)) % beside \(Int(control)) DIP: \(Int(label.width)) < \(Int(widest)) px") }
                    }
                }
            }
            _ = SelectObject(dc, old)
            fonts.destroy()
        }
        print("POPOVER-LABEL-SWEEP \(checked) rows, \(stacked) stacked, \(cut.count) cut")
        XCTAssertEqual(cut, [])
    }

    func testTheTooltipDelayIsTheMacApps() async {
        XCTAssertEqual(WinTooltips.initialDelayMs, 600)
    }
}
#endif
