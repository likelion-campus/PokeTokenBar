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

    func testLightColoursAreTheMacsOpacitiesAndHighContrastIsTheSystems() async {
        let system: (Int32) -> COLORREF = { index in
            switch index {
            case 5: WinUIColors.rgb(255, 255, 255)
            case 8: WinUIColors.rgb(0, 0, 0)
            case 13: WinUIColors.rgb(0, 120, 215)
            default: WinUIColors.rgb(1, 2, 3)
            }
        }
        let light = WinUIColors.resolve(highContrast: false, accent: nil, system: system)
        XCTAssertEqual(light.window, WinUIColors.rgb(255, 255, 255))
        XCTAssertEqual(light.card, WinUIColors.rgb(244, 244, 244), "one step (4.5 %) darker than the window")
        XCTAssertEqual(light.secondaryText, WinUIColors.rgb(122, 122, 122), "black at 49.8 % over the card")
        XCTAssertEqual(light.tertiaryText, WinUIColors.rgb(181, 181, 181), "black at 25.9 % over the card")
        XCTAssertEqual(light.accent, WinUIColors.systemBlue, "no Windows accent: the Mac's systemBlue")
        XCTAssertEqual(WinUIColors.resolve(highContrast: false, accent: WinUIColors.rgb(9, 8, 7), system: system).accent, WinUIColors.rgb(9, 8, 7))
        let hc = WinUIColors.resolve(highContrast: true, accent: WinUIColors.rgb(9, 8, 7), system: system)
        XCTAssertEqual(hc.card, hc.window, "high contrast: no card colour of ours")
        XCTAssertEqual(hc.secondaryText, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.tertiaryText, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.cardBorder, WinUIColors.rgb(0, 0, 0))
        XCTAssertEqual(hc.accent, WinUIColors.rgb(0, 120, 215), "high contrast: COLOR_HIGHLIGHT, not the accent")
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

    func testTheTooltipDelayIsTheMacApps() async {
        XCTAssertEqual(WinTooltips.initialDelayMs, 600)
    }
}
#endif
