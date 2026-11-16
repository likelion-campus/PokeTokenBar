import Foundation
import XCTest
@testable import PokeTokenBar

/// `Tests/PopoverParity/mac-text-styles.json`: the Mac's text styles and label opacities, written on the Mac by
/// `PopoverTextStyleGoldensMacTests` (env-gated) and read here on both systems through `#filePath`.
struct MacTextStyleGolden: Codable, Equatable {
    struct Style: Codable, Equatable {
        var name: String
        var size: Double
        var weight: Int
        var font: String
    }
    var measured: String
    var styles: [Style]
    var labels: [String: Double]

    static let url = PopoverParity.directory.appendingPathComponent("mac-text-styles.json")

    static func load() throws -> MacTextStyleGolden {
        try JSONDecoder().decode(MacTextStyleGolden.self, from: Data(contentsOf: url))
    }
}

/// The popover kit's pure parts (stage 7 Task 3): font sizes, the glyph table, the page layout, scrolling and the drawn
/// parts' picture. Shared, so the Windows runner and the Mac run the same cases.
final class PopoverTextStyleTests: XCTestCase {
    func testTheTableIsTheMacGolden() throws {
        let golden = try MacTextStyleGolden.load()
        XCTAssertEqual(Set(golden.styles.map(\.name)), Set(PopoverTextStyle.allCases.map(\.rawValue)))
        for style in golden.styles {
            let ours = try XCTUnwrap(PopoverTextStyle(rawValue: style.name), style.name)
            XCTAssertEqual(Double(ours.size), style.size, "\(style.name) size")
            XCTAssertEqual(ours.weight, style.weight, "\(style.name) weight (\(style.font))")
        }
        XCTAssertEqual(golden.labels["primary"] ?? -1, PopoverLabelOpacity.primary, accuracy: 0.0001)
        XCTAssertEqual(golden.labels["secondary"] ?? -1, PopoverLabelOpacity.secondary, accuracy: 0.0001)
        XCTAssertEqual(golden.labels["tertiary"] ?? -1, PopoverLabelOpacity.tertiary, accuracy: 0.0001)
        XCTAssertEqual(golden.labels["separator"] ?? -1, PopoverLabelOpacity.separator, accuracy: 0.0001)
    }

    func testPixelSizesFollowTheDPI() {
        XCTAssertEqual(PopoverTextStyle.body.pixelSize(dpi: 96), 13)
        XCTAssertEqual(PopoverTextStyle.body.pixelSize(dpi: 120), 16)   // 16.25
        XCTAssertEqual(PopoverTextStyle.body.pixelSize(dpi: 144), 20)   // 19.5 rounds up
        XCTAssertEqual(PopoverTextStyle.body.pixelSize(dpi: 192), 26)
        XCTAssertEqual(PopoverTextStyle.caption.pixelSize(dpi: 144), 15)
        XCTAssertEqual(PopoverTextStyle.largeBold.pixelSize(dpi: 144), 42)
        XCTAssertEqual(PopoverTextStyle.body.pixelSize(dpi: 96, textScale: 1.5), 20)
        XCTAssertEqual(PopoverTextStyle.pixels(0.4, dpi: 96), 1, "a positive length never rounds away")
        XCTAssertEqual(PopoverTextStyle.pixels(0, dpi: 144), 0)
    }

    func testTextScaleComesFromTheRegistryRange() {
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: nil), 1)
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: 100), 1)
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: 150), 1.5)
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: 225), 2.25)
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: 90), 1)
        XCTAssertEqual(PopoverTextStyle.textScale(registryPercent: 300), 1)
    }

    func testTheWindowMetricsAreTheMacs() {
        XCTAssertEqual(PopoverWindowMetrics.width, 360)
        XCTAssertEqual(PopoverWindowMetrics.padding, 14)
        XCTAssertEqual(PopoverWindowMetrics.contentWidth, 332)
        XCTAssertEqual(PopoverWindowMetrics.scrollerInset, 12)
        XCTAssertEqual(PopoverWindowMetrics.scrollContentWidth, 320)
    }
}

final class PopoverGlyphTableTests: XCTestCase {
    func testEverySymbolOfTheMacPopoverMapsOrIsMarked() throws {
        let symbols = try PopoverParity.load().sfSymbols.map(\.name)
        XCTAssertEqual(symbols.count, 31)
        XCTAssertEqual(Set(symbols), Set(PopoverGlyphTable.entries.keys), "the table has a row for every listed symbol and no other")
        for symbol in symbols {
            let entry = try XCTUnwrap(PopoverGlyphTable.entry(symbol), symbol)
            for fluent in [true, false] where entry.codePoint(fluent: fluent) == nil {
                XCTAssertFalse(entry.fallback?.isEmpty ?? true, "\(symbol) has no \(fluent ? "Fluent" : "MDL2") glyph and no fallback text")
                XCTAssertNotNil(entry.note, "\(symbol): say why there is no glyph")
            }
        }
    }

    func testCodePointsAreTheFontsPrivateUseArea() {
        for (symbol, entry) in PopoverGlyphTable.entries {
            for cp in [entry.fluent, entry.mdl2].compactMap({ $0 }) {
                XCTAssertTrue((0xE000...0xF8FF).contains(cp), "\(symbol): U+\(String(cp, radix: 16)) is outside the icon fonts' range")
            }
        }
    }

    func testTheGapsAreThoseListed() {
        let gaps = PopoverGlyphTable.entries.filter { $0.value.fluent == nil || $0.value.mdl2 == nil }.keys.sorted()
        XCTAssertEqual(gaps, ["eye.slash", "flame.fill", "sparkle", "sparkles"])
        let approximate = PopoverGlyphTable.entries.filter { $0.value.note != nil && $0.value.fallback == nil }.keys.sorted()
        XCTAssertEqual(approximate, ["chart.bar.xaxis", "checkmark.seal.fill", "key.slash.fill", "map"])
    }
}

final class PopoverStackLayoutTests: XCTestCase {
    private func row(_ label: CGSize?, hint: CGSize? = nil, control: CGSize?, style: PopoverStackRow.Style = .trailing,
                     visible: Bool = true, seen: ((CGFloat) -> Void)? = nil) -> PopoverStackRow {
        PopoverStackRow(style: style, isVisible: visible, control: control) { width in
            seen?(width)
            return (label, hint)
        }
    }

    func testATrailingRowIsTheMacGroupRow() {
        let section = PopoverStackSection(caption: CGSize(width: 60, height: 13), rows: [
            row(CGSize(width: 100, height: 17), control: CGSize(width: 80, height: 24)),
            row(CGSize(width: 50, height: 17), hint: CGSize(width: 120, height: 13), control: CGSize(width: 40, height: 20)),
        ])
        let f = PopoverStackLayout.layout([section], width: 360, metrics: .settings)
        let s = f.sections[0]!
        XCTAssertEqual(s.caption, CGRect(x: 20, y: 16, width: 60, height: 13))
        XCTAssertEqual(s.card, CGRect(x: 16, y: 35, width: 328, height: 88))
        let r1 = s.rows[0]!, r2 = s.rows[1]!
        XCTAssertEqual(r1.frame, CGRect(x: 16, y: 35, width: 328, height: 40), "24 + 2 x 8 is over the 38 minimum")
        XCTAssertEqual(r1.label, CGRect(x: 28, y: 46, width: 100, height: 17))
        XCTAssertEqual(r1.control, CGRect(x: 252, y: 43, width: 80, height: 24), "right-aligned in the 12 pt padding")
        XCTAssertEqual(s.dividers, [CGRect(x: 16, y: 75, width: 328, height: 1)])
        XCTAssertEqual(r2.frame, CGRect(x: 16, y: 76, width: 328, height: 47))
        XCTAssertEqual(r2.label, CGRect(x: 28, y: 84, width: 50, height: 17))
        XCTAssertEqual(r2.hint, CGRect(x: 28, y: 102, width: 120, height: 13), "1 pt under the label")
        XCTAssertEqual(r2.control, CGRect(x: 292, y: 89, width: 40, height: 20))
        XCTAssertEqual(f.height, 139)
    }

    func testTheLabelWrapsInTheWidthTheControlLeaves() {
        var widths: [CGFloat] = []
        _ = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(CGSize(width: 10, height: 17), control: CGSize(width: 80, height: 24), seen: { widths.append($0) }),
            row(CGSize(width: 10, height: 17), control: nil, seen: { widths.append($0) }),
        ])], width: 360, metrics: .settings)
        XCTAssertEqual(widths, [214, 304], "328 - 2 x 12 = 304, minus the control and the 10 pt spacing")
    }

    func testAWideControlPutsItsLabelAboveIt() {
        let f = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(CGSize(width: 40, height: 17), control: CGSize(width: 190, height: 24)),
            row(CGSize(width: 40, height: 17), control: CGSize(width: 180, height: 24)),
            row(nil, control: CGSize(width: 250, height: 24)),
        ])], width: 360, metrics: .settings)
        let wide = f.sections[0]!.rows[0]!, fits = f.sections[0]!.rows[1]!, alone = f.sections[0]!.rows[2]!
        XCTAssertEqual(wide.label, CGRect(x: 28, y: 24, width: 40, height: 17), "190 > 60 % of 304: the label goes on top")
        XCTAssertEqual(wide.control, CGRect(x: 28, y: 47, width: 304, height: 24))
        XCTAssertEqual(fits.control?.minX, 28 + 304 - 180, "180 <= 182.4: it stays on the right")
        XCTAssertEqual(alone.control?.minX, 28 + 304 - 250, "without a label nothing is squeezed: right-aligned")
    }

    func testALabelWithAWordWiderThanItsRoomGoesAboveTheControl() {
        // The closure measures as GDI does: wrapped at the width, but one word never narrower than itself (220 here).
        func label(_ w: CGFloat) -> CGSize { w >= 220 ? CGSize(width: 220, height: 17) : CGSize(width: 220, height: 34) }
        let f = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(nil, control: CGSize(width: 100, height: 24)),
            PopoverStackRow(style: .trailing, control: CGSize(width: 100, height: 24)) { w in (label(w), nil) },
            PopoverStackRow(style: .trailing, control: CGSize(width: 70, height: 24)) { w in (label(w), nil) },
        ])], width: 360, metrics: .settings)
        let tight = f.sections[0]!.rows[1]!, roomy = f.sections[0]!.rows[2]!
        XCTAssertEqual(tight.label?.width, 220, "194 px beside a 100 px control is too little for a 220 px word: the label goes on top, whole")
        XCTAssertEqual(tight.control?.minX, 28, "and the control under it, the row's width")
        XCTAssertEqual(roomy.control?.minX, 28 + 304 - 70, "224 px beside a 70 px control: it stays on the right")
    }

    func testATallRowGrowsAndShortOnesKeepTheMinimum() {
        let f = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(CGSize(width: 10, height: 15), control: CGSize(width: 20, height: 14)),
            row(CGSize(width: 10, height: 51), control: CGSize(width: 20, height: 14)),
        ])], width: 360, metrics: .settings)
        XCTAssertEqual(f.sections[0]!.rows[0]!.frame.height, 38)
        XCTAssertEqual(f.sections[0]!.rows[1]!.frame.height, 67)
        XCTAssertEqual(f.sections[0]!.rows[1]!.control?.minY, 39 + 16 + 26, "the control is centred on the tall label")
    }

    func testHiddenRowsAndSectionsTakeNoSpace() {
        let a = PopoverStackSection(caption: CGSize(width: 40, height: 13), rows: [
            row(CGSize(width: 10, height: 17), control: CGSize(width: 20, height: 20)),
            row(CGSize(width: 10, height: 17), control: CGSize(width: 20, height: 20), visible: false),
            row(CGSize(width: 10, height: 17), control: CGSize(width: 20, height: 20)),
        ])
        var hidden = a
        hidden.isVisible = false
        let f = PopoverStackLayout.layout([hidden, a, PopoverStackSection(rows: [row(nil, control: nil, visible: false)])], width: 360,
                                          metrics: .settings)
        XCTAssertNil(f.sections[0])
        XCTAssertNil(f.sections[2], "a section whose rows are all hidden and has no caption is not shown")
        let s = f.sections[1]!
        XCTAssertEqual(s.caption?.minY, 16, "the first visible section starts at the page padding")
        XCTAssertNil(s.rows[1])
        XCTAssertEqual(s.dividers.count, 1, "one divider between the two visible rows")
        XCTAssertEqual(s.rows[2]!.frame.minY, s.rows[0]!.frame.maxY + 1)
        XCTAssertEqual(f.height, 16 + 13 + 6 + 38 + 1 + 38 + 16)
    }

    func testSectionsAreEighteenApart() {
        let one = PopoverStackSection(rows: [row(CGSize(width: 10, height: 17), control: nil)])
        let f = PopoverStackLayout.layout([one, one], width: 360, metrics: .settings)
        XCTAssertEqual(f.sections[1]!.card!.minY - f.sections[0]!.card!.maxY, 18)
    }

    func testStackedAndFullRowsSpanTheRow() {
        let f = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(CGSize(width: 60, height: 17), hint: CGSize(width: 90, height: 13), control: CGSize(width: 10, height: 60), style: .stacked),
            row(CGSize(width: 60, height: 17), control: CGSize(width: 10, height: 30), style: .full),
        ])], width: 360, metrics: .settings)
        let stacked = f.sections[0]!.rows[0]!, full = f.sections[0]!.rows[1]!
        XCTAssertEqual(stacked.label, CGRect(x: 28, y: 24, width: 60, height: 17))
        XCTAssertEqual(stacked.hint, CGRect(x: 28, y: 42, width: 90, height: 13))
        XCTAssertEqual(stacked.control, CGRect(x: 28, y: 61, width: 304, height: 60), "6 pt under the text, the row's width")
        XCTAssertEqual(stacked.frame.height, 8 + 17 + 1 + 13 + 6 + 60 + 8)
        XCTAssertNil(full.label, "a full row shows its control only")
        XCTAssertEqual(full.control, CGRect(x: 28, y: full.frame.minY + 8, width: 304, height: 30))
        XCTAssertEqual(full.frame.height, 46)
    }

    func testAToggleRowIsTheCheckBoxAcrossTheRowWithItsHintUnder() {
        let f = PopoverStackLayout.layout([PopoverStackSection(rows: [
            row(nil, hint: CGSize(width: 200, height: 13), control: CGSize(width: 90, height: 18), style: .toggle),
            row(nil, control: CGSize(width: 90, height: 18), style: .toggle),
        ])], width: 360, metrics: .settings)
        let withHint = f.sections[0]!.rows[0]!, plain = f.sections[0]!.rows[1]!
        XCTAssertEqual(withHint.frame.height, 8 + 18 + 1 + 13 + 8)
        XCTAssertEqual(withHint.control, CGRect(x: 28, y: 24, width: 304, height: 18), "the box sits at the row's right edge")
        XCTAssertEqual(withHint.hint, CGRect(x: 28, y: 43, width: 200, height: 13))
        XCTAssertNil(withHint.label)
        XCTAssertEqual(plain.frame.height, 38)
        XCTAssertEqual(plain.control?.minY, plain.frame.minY + 10, "centred in the 38 pt row")
    }

    func testAPlainSectionHasNoCardPaddingOrDividers() {
        let f = PopoverStackLayout.layout([PopoverStackSection(card: false, rows: [
            row(nil, control: CGSize(width: 10, height: 30), style: .full),
            row(nil, control: CGSize(width: 10, height: 20), style: .full),
        ])], width: 360, metrics: .settings)
        let s = f.sections[0]!
        XCTAssertNil(s.card)
        XCTAssertEqual(s.dividers, [])
        XCTAssertEqual(s.rows[0]!.control, CGRect(x: 16, y: 16, width: 328, height: 30))
        XCTAssertEqual(s.rows[1]!.control, CGRect(x: 16, y: 54, width: 328, height: 20), "8 apart")
    }

    func testPixelMetricsFollowTheDPI() {
        let m144 = PopoverStackMetrics.settings.pixels(dpi: 144), m120 = PopoverStackMetrics.settings.pixels(dpi: 120)
        XCTAssertEqual(m144.pagePadding, 24)
        XCTAssertEqual(m144.rowMinHeight, 57)
        XCTAssertEqual(m144.sectionSpacing, 27)
        XCTAssertEqual(m144.divider, 2, "1.5 rounds up")
        XCTAssertEqual(m144.hintSpacing, 2)
        XCTAssertEqual(m120.divider, 1, "1.25 rounds down, never to nothing")
        XCTAssertEqual(m120.rowMinHeight, 48)
        XCTAssertEqual(PopoverStackMetrics.settings.pixels(dpi: 96), .settings)
    }

    func testThePageAt150PercentIsTheDIPPageScaled() {
        func page(_ k: CGFloat) -> [PopoverStackSection] {
            [PopoverStackSection(caption: CGSize(width: 60 * k, height: 13 * k), rows: [
                row(CGSize(width: 100 * k, height: 17 * k), control: CGSize(width: 80 * k, height: 24 * k)),
                row(CGSize(width: 50 * k, height: 17 * k), hint: CGSize(width: 120 * k, height: 13 * k), control: CGSize(width: 40 * k, height: 20 * k)),
            ])]
        }
        let dip = PopoverStackLayout.layout(page(1), width: 360, metrics: .settings)
        let px = PopoverStackLayout.layout(page(1.5), width: 540, metrics: PopoverStackMetrics.settings.pixels(dpi: 144))
        let a = dip.sections[0]!, b = px.sections[0]!
        for (r, s) in zip(a.rows, b.rows) {
            // Every length snaps to whole pixels on its own (rounded up), so frames drift up to ~2.5 px from the exact x1.5.
            for (x, y) in [(r!.frame, s!.frame), (r!.control!, s!.control!), (r!.label!, s!.label!)] {
                XCTAssertEqual(y.minX, x.minX * 1.5, accuracy: 3)
                XCTAssertEqual(y.minY, x.minY * 1.5, accuracy: 3)
                XCTAssertEqual(y.width, x.width * 1.5, accuracy: 3)
                XCTAssertEqual(y.height, x.height * 1.5, accuracy: 3)
            }
        }
        XCTAssertEqual(px.height, dip.height * 1.5, accuracy: 3)
    }

    func testReadingOrderIsTopToBottomThenLeftToRight() {
        let label = CGRect(x: 28, y: 46, width: 100, height: 17), control = CGRect(x: 252, y: 43, width: 80, height: 24)
        let next = CGRect(x: 28, y: 84, width: 50, height: 17)
        XCTAssertTrue(PopoverStackLayout.isReadingOrder([label, control, next]))
        XCTAssertFalse(PopoverStackLayout.isReadingOrder([control, label, next]), "right before left on one line")
        XCTAssertFalse(PopoverStackLayout.isReadingOrder([next, label]), "a lower control before a higher one")
        XCTAssertTrue(PopoverStackLayout.isReadingOrder([]))
    }
}

final class PopoverScrollMathTests: XCTestCase {
    func testTheOffsetStaysInsideTheContent() {
        XCTAssertEqual(PopoverScrollMath.clamped(-5, content: 1000, viewport: 400), 0)
        XCTAssertEqual(PopoverScrollMath.clamped(700, content: 1000, viewport: 400), 600)
        XCTAssertEqual(PopoverScrollMath.clamped(300, content: 1000, viewport: 400), 300)
        XCTAssertEqual(PopoverScrollMath.clamped(50, content: 300, viewport: 400), 0, "content shorter than the viewport never scrolls")
    }

    func testAFocusedControlIsScrolledIntoViewByTheSmallestMove() {
        func reveal(_ top: CGFloat, _ bottom: CGFloat, at offset: CGFloat) -> CGFloat {
            PopoverScrollMath.revealing(top: top, bottom: bottom, offset: offset, viewport: 400, content: 2000, margin: 8)
        }
        XCTAssertEqual(reveal(100, 130, at: 50), 50, "already visible: no move")
        XCTAssertEqual(reveal(600, 630, at: 50), 238, "below: its bottom (+ margin) at the viewport's bottom")
        XCTAssertEqual(reveal(30, 60, at: 200), 22, "above: its top (- margin) at the top")
        XCTAssertEqual(reveal(500, 1100, at: 0), 492, "taller than the viewport: its top")
        XCTAssertEqual(reveal(1980, 1995, at: 0), 1600, "never past the end")
    }

    func testAWheelNotchScrollsTheSystemsLines() {
        var w = PopoverWheel()
        XCTAssertEqual(w.offsetChange(delta: 120, lines: 3, lineHeight: 16, page: 400), -48, "wheel away: towards the top")
        XCTAssertEqual(w.offsetChange(delta: -120, lines: 3, lineHeight: 16, page: 400), 48)
        XCTAssertEqual(w.offsetChange(delta: -120, lines: 0, lineHeight: 16, page: 400), 0, "lines 0: the wheel scrolls nothing")
        XCTAssertEqual(w.offsetChange(delta: -240, lines: UInt32.max, lineHeight: 16, page: 400), 800, "WHEEL_PAGESCROLL: a page per notch")
    }

    func testTouchpadPartsAddUpToANotch() {
        var w = PopoverWheel()
        var sum: CGFloat = 0
        for _ in 0..<8 { sum += w.offsetChange(delta: -15, lines: 3, lineHeight: 16, page: 400) }
        XCTAssertEqual(sum, 48)
        for _ in 0..<7 { sum += w.offsetChange(delta: 17, lines: 3, lineHeight: 16, page: 400) }
        XCTAssertEqual(sum, 48 - 47, "7 x 17 = 119 of 120: 47.6 px, 47 so far, the rest kept")
        w.reset()
        XCTAssertEqual(w.offsetChange(delta: 1, lines: 3, lineHeight: 16, page: 400), 0)
    }
}

final class PopoverCompositeTests: XCTestCase {
    /// A FIXTURE bitmap made of bytes (not art): 2 x 2, each pixel distinct, premultiplied.
    private func fixture() -> PlazaBitmap {
        var b = PlazaBitmap(width: 2, height: 2)
        b[0, 0] = PlazaRGBA(r: 200, g: 10, b: 20, a: 255)
        b[1, 0] = PlazaRGBA(r: 64, g: 32, b: 0, a: 128)
        b[0, 1] = PlazaRGBA(r: 0, g: 0, b: 0, a: 0)
        b[1, 1] = PlazaRGBA(r: 1, g: 2, b: 3, a: 4)
        return b
    }

    func testTheDIBIsPremultipliedBGRAWithTheTopRowFirst() {
        XCTAssertEqual(PopoverComposite.bgra(fixture()), [20, 10, 200, 255, 0, 32, 64, 128, 0, 0, 0, 0, 3, 2, 1, 4])
    }

    func testAnOpaqueBitmapGetsFullAlpha() {
        var b = fixture()
        b.alpha = .noneSkipLast
        XCTAssertEqual(PopoverComposite.bgra(b).enumerated().filter { $0.offset % 4 == 3 }.map(\.element), [255, 255, 255, 255])
    }

    func testAColourLayerIsPremultipliedAndClipped() {
        let out = PopoverComposite.compose([.color(PlazaColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.5), frame: CGRect(x: -1, y: 0, width: 2, height: 1))],
                                           width: 3, height: 1, scale: 1)
        XCTAssertEqual(out, [0, 64, 128, 128, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testLayersAreDrawnSourceOverBottomFirst() {
        let out = PopoverComposite.compose([
            .color(PlazaColor(srgbRed: 0, green: 0, blue: 1), frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            .color(PlazaColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
        ], width: 1, height: 1, scale: 1)
        XCTAssertEqual(out, [127, 0, 128, 255], "half red over blue: blue 255 x 127/255 + 0, red 128")
    }

    func testAnImageLandsOneToOneAtTheScale() {
        let image = PlazaImage(bitmap: fixture())
        let out = PopoverComposite.compose([.image(image, frame: CGRect(x: 1, y: 0.5, width: 1, height: 1))], width: 4, height: 3, scale: 2)
        XCTAssertEqual(PopoverComposite.pixelRect(CGRect(x: 1, y: 0.5, width: 1, height: 1), scale: 2), PlazaPixelRect(x: 2, y: 1, width: 2, height: 2))
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(out[(y * 4 + x) * 4..<(y * 4 + x) * 4 + 4]) }
        XCTAssertEqual(px(2, 1), [20, 10, 200, 255])
        XCTAssertEqual(px(3, 1), [0, 32, 64, 128])
        XCTAssertEqual(px(3, 2), [3, 2, 1, 4])
        XCTAssertEqual(px(0, 0), [0, 0, 0, 0], "outside the frame stays transparent")
    }

    func testAnImageOfAnotherSizeIsScaledNearest() {
        let out = PopoverComposite.compose([.image(PlazaImage(bitmap: fixture()), frame: CGRect(x: 0, y: 0, width: 4, height: 2))],
                                           width: 4, height: 2, scale: 1)
        XCTAssertEqual(Array(out[0..<16]), [20, 10, 200, 255, 20, 10, 200, 255, 0, 32, 64, 128, 0, 32, 64, 128], "each source pixel twice across")
    }
}
