import XCTest
@testable import PokeTokenBar

/// `PlazaTextFrame` (CoreText's frame layout as rules) over the clusters and metrics the Mac measured: on every corpus text
/// drawn in Galmuri alone the lines, `suggestedSize` and `visibleLength` are CTFramesetter's (`breaks.json`), as the chat
/// bubble asks for them. Both OSes run this; Windows feeds the same rules DirectWrite clusters in `WindowsPlazaTextTests`.
/// Fallback fonts (emoji, other scripts) are checked against live CoreText in `PlazaTextFrameTests+Mac`.
final class PlazaTextFrameTests: XCTestCase {
    private func galmuriMetrics() throws -> [PlazaFontMetrics] {
        let golden = try PlazaParityGoldens.load(PlazaFontMetricsGolden.self, "font-metrics.json")
        return try ["Galmuri11-Regular", "Galmuri14-Regular"].map {
            let e = try XCTUnwrap(golden.fonts[$0])
            return PlazaFontMetrics(ascender: CGFloat(e.nsAscender), descender: CGFloat(e.nsDescender), leading: CGFloat(e.nsLeading))
        }
    }

    func testTheFallbackListNamesTheCorpus() {
        XCTAssertEqual(PlazaBreakCorpus.fallbackIndices.count, 19)
        XCTAssertTrue(PlazaBreakCorpus.fallbackIndices.union(PlazaBreakCorpus.fallbackIndicesAt15).allSatisfy { $0 < PlazaBreakCorpus.texts.count })
        XCTAssertTrue(PlazaBreakCorpus.texts[56] == "🔥" && PlazaBreakCorpus.texts[78].hasPrefix("हिन्दी"), "indices follow the corpus order")
        XCTAssertTrue(PlazaBreakCorpus.texts[76].hasPrefix("Привет") && PlazaBreakCorpus.texts[77].hasPrefix("Ελληνικά"))
    }

    func testTheFrameIsCTFramesettersOnTheGalmuriCorpus() throws {
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        let metrics = try galmuriMetrics()
        var checked = 0, gapsSkipped = 0
        for c in golden.cases where !PlazaBreakCorpus.usesFallback(text: c.text, font: c.font) {
            let text = golden.texts[c.text], width = CGFloat(golden.widths[c.width])
            let clusters = golden.breakClusters(font: c.font, text: c.text)
            let m = [PlazaFontMetrics](repeating: metrics[c.font], count: clusters.count)
            let label = "\(golden.fonts[c.font]) width \(Int(width)) \(text)"
            if PlazaLineBreakerTests.knownGaps.contains("coreTextFrame " + label) { gapsSkipped += 1; continue }
            let lines = PlazaTextFrame.lines(clusters, metrics: m, width: width)
            XCTAssertEqual(lines.isEmpty ? [0..<0] : lines.map(\.range), PlazaBreaksGolden.ranges(c.frame), label)
            let f = metrics[c.font]
            let maxHeight = ((f.ascender - f.descender + f.leading) * 8).rounded(.up)   // PlazaChatBubble's eight lines
            let fit = PlazaTextFrame.suggestedSize(lines, limit: CGSize(width: width, height: maxHeight))
            XCTAssertEqual([Double(fit.width), Double(fit.height)], c.suggested, "suggested \(label)")
            let frame = CGSize(width: min(max(fit.width, 1).rounded(.up), width), height: min(max(fit.height, 1).rounded(.up), maxHeight))
            let inFrame = PlazaTextFrame.lines(clusters, metrics: m, width: frame.width)
            XCTAssertEqual(PlazaTextFrame.visibleLength(inFrame, height: frame.height, textLength: text.utf16.count), c.visible, "visible \(label)")
            checked += 1
        }
        XCTAssertEqual(checked + gapsSkipped, 590, "60 texts at 12 pt and 58 at 15 pt, 5 widths each")
        XCTAssertEqual(gapsSkipped, 2, "the two `( ` breaks CoreText makes at 12 pt (PlazaLineBreakerTests.knownGaps)")
    }

    func testBaselinesRoundEachStep() {
        // A Galmuri line then a taller one: 12 + round(2.0001 + 2.0001) + round(15) = 31, then + round(4.6875 + 2.0001) + 15 = 53
        let small = PlazaFontMetrics(ascender: 12, descender: -2.00006103515625, leading: 2.00006103515625)
        let tall = PlazaFontMetrics(ascender: 15, descender: -4.6875, leading: 2.00006103515625)
        func c(_ i: Int, _ w: CGFloat, space: Bool = false) -> PlazaBreakCluster {
            PlazaBreakCluster(utf16: i..<(i + 1), width: w, isWhitespace: space, isNewline: false, canBreakAfter: true, isHangul: false)
        }
        let clusters = [c(0, 10), c(1, 5, space: true), c(2, 10), c(3, 5, space: true), c(4, 10)]
        let lines = PlazaTextFrame.lines(clusters, metrics: [small, small, tall, small, tall], width: 12)
        XCTAssertEqual(lines.map(\.range), [0..<1, 2..<3, 4..<5])
        XCTAssertEqual(lines.map(\.baseline), [12, 31, 53])
        XCTAssertEqual(lines.map(\.end), [2, 4, 5], "a line holds the space it swallowed")
        XCTAssertEqual(PlazaTextFrame.suggestedSize(lines, limit: CGSize(width: 12, height: 1000)), CGSize(width: 10, height: 58))
        XCTAssertEqual(PlazaTextFrame.visibleLength(lines, height: 57.6875, textLength: 5), 5, "53 + 4.6875 fits exactly")
        XCTAssertEqual(PlazaTextFrame.visibleLength(lines, height: 57.6, textLength: 5), 4, "the third line does not fit")
        XCTAssertEqual(PlazaTextFrame.suggestedSize(lines, limit: CGSize(width: 12, height: 40)), CGSize(width: 10, height: 36), "two lines fit 40")
        XCTAssertEqual(PlazaTextFrame.lines([], metrics: [], width: 10), [])
        XCTAssertEqual(PlazaTextFrame.suggestedSize([], limit: CGSize(width: 10, height: 10)), .zero)
    }

    func testAlignment() {
        let line = PlazaTextFrame.Line(range: 0..<3, end: 4, width: 24, ascent: 12, descent: 2, leading: 2, baseline: 12)
        XCTAssertEqual(PlazaTextFrame.x(of: line, in: 41, alignment: .center, rightToLeft: false), 8.5, "centred without rounding")
        XCTAssertEqual(PlazaTextFrame.x(of: line, in: 41, alignment: .natural, rightToLeft: false), 0)
        XCTAssertEqual(PlazaTextFrame.x(of: line, in: 41, alignment: .natural, rightToLeft: true), 17)
        XCTAssertTrue(PlazaTextFrame.isRightToLeft("  123 שלום Hello"))
        XCTAssertFalse(PlazaTextFrame.isRightToLeft("Hello שלום"))
        XCTAssertFalse(PlazaTextFrame.isRightToLeft("안녕 مرحبا"))
        XCTAssertTrue(PlazaTextFrame.isRightToLeft("مرحبا Hello 안녕"))
        XCTAssertFalse(PlazaTextFrame.isRightToLeft("123 !? 🔥"))
    }

    /// What `CTLineCreateTruncatedLine(.end)` did on the Mac (measured with Galmuri, pinned again live in
    /// `PlazaTextFrameTests+Mac`): nil under the ellipsis's width even for a line that fits, the line itself when it fits,
    /// else the longest start that fits beside the ellipsis with its trailing spaces dropped.
    func testTruncationRule() {
        // "Hello world" in Galmuri11 12 pt: H 8, e 8, l 3 (kerned before l), l 4, o 8, space 5, w 10, …; ellipsis 12
        let widths: [CGFloat] = [8, 8, 3, 4, 8, 5, 10, 8, 6, 4, 7]
        let clusters = widths.enumerated().map { i, w in
            PlazaBreakCluster(utf16: i..<(i + 1), width: w, isWhitespace: i == 5, isNewline: false, canBreakAfter: true, isHangul: false)
        }
        func kept(_ w: CGFloat) -> Int? { PlazaTextFrame.truncation(clusters, width: w, ellipsisWidth: 12) }
        XCTAssertNil(kept(11))
        XCTAssertEqual(kept(12), 0, "only the ellipsis")
        XCTAssertEqual(kept(20), 1)
        XCTAssertEqual(kept(30), 2)
        XCTAssertEqual(kept(37), 4, "Hell…: the kerned l counts 3")
        XCTAssertEqual(kept(51), 5, "Hello … loses the space before the ellipsis")
        XCTAssertEqual(kept(60), 7)
        XCTAssertEqual(kept(71), 11, "the whole line fits: unchanged")
        XCTAssertNil(PlazaTextFrame.truncation(Array(clusters.prefix(1)), width: 8, ellipsisWidth: 12), "narrower than the ellipsis: nil even though the line fits")
        XCTAssertEqual(PlazaTextFrame.truncation([], width: 12, ellipsisWidth: 12), 0)
    }
}
