import XCTest
@testable import PokeTokenBar

/// `PlazaLineBreaker` over the clusters the Mac measured (Galmuri 12 pt and 15 pt, glyph advances of one CTLine, UAX #14
/// units from CFStringTokenizer) equals what TextKit (`.swiftUIText`) and CTFramesetter (`.coreTextFrame`) did with the
/// same text and width, on every case of the corpus but the named gaps. Both OSes run this; Windows feeds it
/// DirectWrite clusters in Task 9 and compares with the same golden.
final class PlazaLineBreakerTests: XCTestCase {
    /// Where the rules still differ from the engines, named: the corpus text, the font, the width. Each is a measured
    /// engine behaviour no simple rule explained (see `PlazaLineBreaker`), pinned so that fixing or breaking one shows.
    static let knownGaps: Set<String> = [
        "swiftUIText body width 120 불꽃 🔥 물 💧 풀 🌿",                       // TextKit's pushOut also acts with an emoji beside the last word
        "coreTextFrame small width 40 no break after open ( paren or before close ) paren",   // CoreText ends a line after `( ` where LB14 forbids it,
        "coreTextFrame small width 80 no break after open ( paren or before close ) paren",   // but only at 12 pt
    ]

    private func range(_ text: String, _ r: Range<Int>) -> String {
        let ns = text as NSString
        return ns.substring(with: NSRange(location: r.lowerBound, length: r.count))
    }

    func testTheRulesEqualTheEnginesOnTheCorpus() throws {
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        XCTAssertEqual(golden.texts, PlazaBreakCorpus.texts, "the golden was measured on this corpus")
        XCTAssertEqual(golden.cases.count, golden.fonts.count * golden.texts.count * golden.widths.count)
        var gaps = Set<String>()
        var checked = 0
        for c in golden.cases {
            let clusters = golden.breakClusters(font: c.font, text: c.text)
            let width = CGFloat(golden.widths[c.width]), text = golden.texts[c.text]
            let label = "\(golden.fonts[c.font]) width \(Int(width)) \(text)"
            checked += 1
            if PlazaLineBreaker.lines(clusters, width: width, rule: .swiftUIText) != PlazaBreaksGolden.ranges(c.kit) { gaps.insert("swiftUIText " + label) }
            if PlazaLineBreaker.lines(clusters, width: width, rule: .coreTextFrame) != PlazaBreaksGolden.ranges(c.frame) { gaps.insert("coreTextFrame " + label) }
        }
        XCTAssertEqual(checked, 790, "79 texts x 2 fonts x 5 widths")
        XCTAssertEqual(gaps.sorted(), Self.knownGaps.sorted(), "lines that differ from the engines' must be exactly the known gaps")
    }

    /// TextKit's `pushOut`, named: the one thing the greedy rule does not do.
    func testPushOutInTheCorpus() throws {
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        let t = try XCTUnwrap(golden.texts.firstIndex(of: "배고프다 점심 뭐 먹지"))
        let wi = try XCTUnwrap(golden.widths.firstIndex(of: 120))
        for font in 0..<2 {
            let c = try XCTUnwrap(golden.cases.first { $0.font == font && $0.text == t && $0.width == wi })
            let clusters = golden.breakClusters(font: font, text: t)
            let kit = PlazaBreaksGolden.ranges(c.kit).map { range("배고프다 점심 뭐 먹지", $0) }
            XCTAssertEqual(kit, ["배고프다 점심", "뭐 먹지"], "TextKit moved 뭐 down so that 먹지 is not alone")
            XCTAssertEqual(PlazaLineBreaker.lines(clusters, width: 120, rule: .swiftUIText).map { range("배고프다 점심 뭐 먹지", $0) }, kit)
            // CTFramesetter does not push out, and breaks between syllables where the width ends (12 pt: 뭐 먹 | 지)
            let frame = font == 0 ? ["배고프다 점심 뭐 먹", "지"] : ["배고프다 점심 뭐", "먹지"]
            XCTAssertEqual(PlazaBreaksGolden.ranges(c.frame).map { range("배고프다 점심 뭐 먹지", $0) }, frame)
            XCTAssertEqual(PlazaLineBreaker.lines(clusters, width: 120, rule: .coreTextFrame).map { range("배고프다 점심 뭐 먹지", $0) }, frame)
        }
    }

    // MARK: hand-built clusters (what the rules are, without the font)

    private func clusters(_ text: String, advance: CGFloat = 10, hangulBreaks: Bool = false) -> [PlazaBreakCluster] {
        var out: [PlazaBreakCluster] = []
        var u = 0
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            let len = String(ch).utf16.count
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let space = ch == " "
            let hangul = ch.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false
            out.append(PlazaBreakCluster(utf16: u..<(u + len), width: advance, isWhitespace: space, isNewline: ch == "\n",
                                         canBreakAfter: space || ch == "\n" || (hangul && (next?.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false)),
                                         isHangul: hangul, isWordCharacter: ch.isLetter || ch.isNumber))
            u += len
        }
        return out
    }

    private func lines(_ text: String, width: CGFloat, _ rule: PlazaLineBreaker.Rule) -> [String] {
        PlazaLineBreaker.lines(clusters(text), width: width, rule: rule).map { range(text, $0) }
    }

    func testGreedyBreaksAtSpacesAndDropsTrailingSpace() {
        XCTAssertEqual(lines("aaa bbb ccc", width: 70, .coreTextFrame), ["aaa bbb", "ccc"])
        XCTAssertEqual(lines("aaa bbb   ", width: 70, .coreTextFrame), ["aaa bbb"], "trailing white space neither wraps nor stays")
        XCTAssertEqual(lines("", width: 70, .swiftUIText), [""])
        XCTAssertEqual(lines("a\nb\n\nc", width: 70, .swiftUIText), ["a", "b", "", "c"])
        XCTAssertEqual(lines("abcdefghij", width: 40, .swiftUIText), ["abcd", "efgh", "ij"], "a word wider than a line breaks between clusters")
    }

    func testKoreanWordsStayWholeInTextKitAndBreakBetweenSyllablesInCoreText() {
        XCTAssertEqual(lines("가나다라 마바", width: 45, .swiftUIText), ["가나다라", "마바"])
        XCTAssertEqual(lines("가나다라마바", width: 45, .coreTextFrame), ["가나다라", "마바"])
        XCTAssertEqual(lines("가나 다라마바", width: 55, .coreTextFrame), ["가나 다라", "마바"])
        XCTAssertEqual(lines("가나 다라마바", width: 55, .swiftUIText), ["가나", "다라마바"])
    }

    func testPushOutOnlyActsWhenItShouldInTextKit() {
        // three words, the last alone on the second line: the word before it moves down
        XCTAssertEqual(lines("aaa bbb ccc ddd", width: 110, .swiftUIText), ["aaa bbb", "ccc ddd"])
        XCTAssertEqual(lines("aaa bbb ccc ddd", width: 110, .coreTextFrame), ["aaa bbb ccc", "ddd"])
        // two words on the first line: nothing moves
        XCTAssertEqual(lines("aaa bbb ccc", width: 70, .swiftUIText), ["aaa bbb", "ccc"])
        // a last word with punctuation is not a word (`effective!!`): nothing moves
        XCTAssertEqual(lines("aaa bbb ccc dd!", width: 110, .swiftUIText), ["aaa bbb ccc", "dd!"])
        // three lines: nothing moves
        XCTAssertEqual(lines("aaa bbb ccc ddd eee fff", width: 70, .swiftUIText), ["aaa bbb", "ccc ddd", "eee fff"])
        XCTAssertEqual(lines("aaa bbb ccc ddd eee", width: 70, .swiftUIText), ["aaa bbb", "ccc ddd", "eee"])
    }
}
