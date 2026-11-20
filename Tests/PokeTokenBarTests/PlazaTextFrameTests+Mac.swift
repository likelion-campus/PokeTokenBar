import AppKit
import CoreText
import XCTest
@testable import PokeTokenBar

/// `PlazaTextFrame` against live CoreText on this Mac, fallback fonts included (emoji, Hebrew, Arabic, Devanagari lines are
/// taller than Galmuri's): the clusters are `clusters(of:font:)` (one CTLine's advances), each cluster's metrics its run's
/// font's. Where `PlazaLineBreaker` already differs from CTFramesetter (its known gaps) the frame cannot be compared.
extension PlazaParityGoldensMacTests {
    /// Each cluster's font metrics: the font of the glyph run that holds its first UTF-16 unit (a cluster no run holds, as a
    /// newline can be, takes the font asked for).
    private func clusterMetrics(_ text: String, font: NSFont, clusters: [PlazaBreakCluster]) -> [PlazaFontMetrics] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let base = PlazaFontMetrics(ascender: CTFontGetAscent(font), descender: -CTFontGetDescent(font), leading: CTFontGetLeading(font))
        var unit = [PlazaFontMetrics](repeating: base, count: (text as NSString).length)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { continue }
            let f = value as! CTFont   // checked by the type id above
            let m = PlazaFontMetrics(ascender: CTFontGetAscent(f), descender: -CTFontGetDescent(f), leading: CTFontGetLeading(f))
            let r = CTRunGetStringRange(run)
            for k in r.location..<(r.location + r.length) { unit[k] = m }
        }
        return clusters.map { unit[$0.utf16.lowerBound] }
    }

    func testTheFrameIsCTFramesettersWithFallbackFonts() throws {
        let extra = ["안녕 🔥\n🔥🔥 줄\n\n끝", "가나다 라마바 사아자 차카타 파하 가나다 라마바 사아자 차카타 파하 가나다 라마바 사아자 차카타 파하 가나다 라마바",
                     "마지막 줄은 이모지 🔥🔥🔥🔥🔥🔥🔥🔥"]
        var compared = 0, fallbackCompared = 0, skipped = 0, helveticaGaps = 0
        for size in [PlazaTextSize.small, .body] {
            let font = PlazaResources.font(size)
            let metrics = PlatformPlaza.graphics.text.metrics(.plaza(size))
            let maxHeight = ((metrics.ascender - metrics.descender + metrics.leading) * 8).rounded(.up)
            for (ti, text) in (PlazaBreakCorpus.texts + extra).enumerated() {
                let clusters = clusters(of: text, font: font)
                let m = clusterMetrics(text, font: font, clusters: clusters)
                let attributed = NSAttributedString(string: text, attributes: CoreTextPlazaEngine.attributes(.plaza(size)))
                let setter = CTFramesetterCreateWithAttributedString(attributed)
                for width in PlazaBreakCorpus.widths + [216] {
                    let label = "\(size) width \(width) \(text.prefix(20))"
                    let lines = PlazaTextFrame.lines(clusters, metrics: m, width: width)
                    let ctLines = frameLines(attributed, width: width)
                    guard (lines.isEmpty ? [0..<0] : lines.map(\.range)) == ctLines else { skipped += 1; continue }
                    // Known gap (PlazaTextFrame): lines wholly in Helvetica, CoreText's fallback for Cyrillic and Greek in Galmuri14,
                    // step by Galmuri14's ascent.
                    if size == .body, PlazaBreakCorpus.fallbackIndicesAt15.contains(ti) { helveticaGaps += 1; continue }
                    // baselines: CTFrameGetLineOrigins in a tall frame
                    let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil), nil)
                    let n = (CTFrameGetLines(frame) as! [CTLine]).count
                    var origins = [CGPoint](repeating: .zero, count: n)
                    CTFrameGetLineOrigins(frame, CFRange(), &origins)
                    XCTAssertEqual(lines.map(\.baseline), origins.map { 100_000 - $0.y }, "baselines \(label)")
                    let fit = PlazaTextFrame.suggestedSize(lines, limit: CGSize(width: width, height: maxHeight))
                    let ct = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: maxHeight), nil)
                    XCTAssertEqual(fit.width, ct.width, accuracy: 1e-9, "suggested width \(label)")
                    XCTAssertEqual(fit.height, ct.height, accuracy: 1e-9, "suggested height \(label)")
                    let frameSize = CGSize(width: min(max(fit.width, 1).rounded(.up), width), height: min(max(fit.height, 1).rounded(.up), maxHeight))
                    let shown = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: frameSize), transform: nil), nil)
                    XCTAssertEqual(PlazaTextFrame.visibleLength(PlazaTextFrame.lines(clusters, metrics: m, width: frameSize.width), height: frameSize.height,
                                                                textLength: (text as NSString).length),
                                   CTFrameGetVisibleStringRange(shown).length, "visible \(label)")
                    compared += 1
                    let inCorpus = ti < PlazaBreakCorpus.texts.count
                    if !inCorpus || PlazaBreakCorpus.usesFallback(text: ti, font: size == .small ? 0 : 1) { fallbackCompared += 1 }
                }
            }
        }
        XCTAssertGreaterThan(compared, 900)
        XCTAssertGreaterThan(fallbackCompared, 200, "lines in fallback fonts were compared")
        XCTAssertLessThan(skipped, 12, "only the breaker's known gaps are skipped")
        XCTAssertTrue((1...12).contains(helveticaGaps), "Cyrillic and Greek at 15 pt, at most six widths each: \(helveticaGaps)")
    }

    func testTruncationIsCTLineCreateTruncatedLines() throws {
        let texts = ["Hello world", "안녕하세요 반가워요", "a b c d e f", "WWWWWWWWWW", "ab  cd", "가나다라마바사", "", "x", "Hi 🔥🔥 there",
                     "도토리 Ab", "naïve café", "1234 5678"]
        var checked = 0
        for size in [PlazaTextSize.small, .body] {
            let font = PlazaResources.font(size)
            let attributes = CoreTextPlazaEngine.attributes(.plaza(size))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let e = CGFloat(CTLineGetTypographicBounds(ellipsis, nil, nil, nil))
            for text in texts {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                let clusters = clusters(of: text, font: font)
                for w in stride(from: 0.0, through: 150, by: 1.0) {
                    let ct = CTLineCreateTruncatedLine(line, w, .end, ellipsis)
                    let kept = PlazaTextFrame.truncation(clusters, width: w, ellipsisWidth: e)
                    XCTAssertEqual(ct == nil, kept == nil, "\(size) \(text) width \(w)")
                    guard let ct, let kept else { continue }
                    let expected = kept == clusters.count ? clusters.reduce(0) { $0 + $1.width } : clusters.prefix(kept).reduce(0) { $0 + $1.width } + e
                    XCTAssertEqual(CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)), expected, accuracy: 1e-9, "\(size) \(text) width \(w)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 2500)
    }

    /// The added texts' pins (`PlazaTextEngineParityTests.cases`) are still what TextKit and CTFramesetter measure here, and the
    /// shared breaker reproduces TextKit on the Mac's own clusters for them (so a Windows difference is DirectWrite's).
    func testTheAddedParityTextsAreTheMacs() throws {
        for c in PlazaTextEngineParityTests.cases {
            let font = PlazaResources.font(c.size)
            let attributed = NSAttributedString(string: c.text, attributes: CoreTextPlazaEngine.attributes(.plaza(c.size)))
            let kit = PlazaBreaksGolden.ranges(c.kit)
            XCTAssertEqual(textKitLines(attributed, width: c.width), kit, "TextKit \(c.text)")
            XCTAssertEqual(PlazaLineBreaker.lines(clusters(of: c.text, font: font), width: c.width, rule: .swiftUIText), kit, "breaker \(c.text)")
            let engine = PlatformPlaza.graphics.text
            XCTAssertEqual(engine.wrappedLines(c.text, font: .plaza(c.size), width: c.width).count, kit.count, c.text)
            XCTAssertEqual(engine.line(c.text, font: .plaza(c.size)).width, c.lineWidth, c.text)
            let m = engine.metrics(.plaza(c.size))
            let limit = CGSize(width: c.width, height: ((m.ascender - m.descender + m.leading) * 8).rounded(.up))
            XCTAssertEqual(engine.paragraph(c.text, font: .plaza(c.size), alignment: .center).suggestedSize(limit: limit), c.suggested, c.text)
        }
    }
}
