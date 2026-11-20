#if os(Windows)
import Foundation
import WinSDK
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 9: the DirectWrite text engine against the Mac (CoreText and TextKit, `Tests/PlazaParityGoldens`). Parity
/// numbers print as `TEXT-*` lines; renders and side-by-sides (Mac | Windows | difference x4) go to `PTB_CANVAS_OUT/text`.
final class WindowsPlazaTextTests: XCTestCase {
    private let graphics = WinPlazaGraphics.shared
    private let engine = WinPlazaTextEngine()
    private var fonts: WinTextFonts { WinTextFonts.shared }

    private func requireResources() throws {
        if ProcessInfo.processInfo.environment[WinPlazaAssets.environmentKey] == nil, ProcessInfo.processInfo.environment["CI"] == nil {
            throw XCTSkip("set \(WinPlazaAssets.environmentKey) to the checkout's Resources\\Plaza and windows\\resources\\Plaza")
        }
    }

    private func native(_ line: PlazaTextLine, file: StaticString = #filePath, line l: UInt = #line) throws -> WinTextLine {
        try XCTUnwrap(line.native as? WinTextLine, "a DirectWrite line", file: file, line: l)
    }

    private func sizeFont(_ f: Int) -> PlazaFont { .plaza(f == 0 ? .small : .body) }

    private func substring(_ text: String, _ r: Range<Int>) -> String {
        String(decoding: Array(text.utf16)[r], as: UTF16.self)
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> PlazaColor {
        PlazaColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: a)
    }

    private func canvas(_ w: Int, _ h: Int) throws -> WinPlazaCanvas {
        try XCTUnwrap(graphics.makeCanvas(width: w, height: h, colorSpace: .sRGB) as? WinPlazaCanvas, "a Direct2D canvas")
    }

    /// Inked pixels (alpha > 128) whose colour is near `c` (each channel within 40 of the premultiplied-then-divided value).
    private func columns(_ image: PlazaImage, near c: PlazaColor) -> [Int] {
        var out: [Int] = []
        let p = image.pixels
        for y in 0..<p.height {
            for x in 0..<p.width {
                let q = p[x, y]
                guard q.a > 128 else { continue }
                let k = 255 / Double(q.a)
                if abs(Double(q.r) * k - c.red * 255) < 40, abs(Double(q.g) * k - c.green * 255) < 40, abs(Double(q.b) * k - c.blue * 255) < 40 { out.append(x) }
            }
        }
        return out
    }

    // MARK: fonts and metrics

    func testGalmuriMetricsAreCoreTexts() throws {
        try requireResources()
        let golden = try PlazaParityGoldens.load(PlazaFontMetricsGolden.self, "font-metrics.json")
        for (size, name) in [(PlazaTextSize.small, "Galmuri11-Regular"), (.body, "Galmuri14-Regular")] {
            let e = try XCTUnwrap(golden.fonts[name])
            let m = engine.metrics(.plaza(size))
            let r = try XCTUnwrap(fonts.report(.plaza(size)))
            let upem = Double(r.info.unitsPerEm)
            print("TEXT-METRICS \(name) \(size.points)pt: engine ascender \(m.ascender) descender \(m.descender) leading \(m.leading) | Mac NSFont \(e.nsAscender) \(e.nsDescender) \(e.nsLeading) | hhea \(r.info.hheaAscender)/\(r.info.hheaDescender)/\(r.info.hheaLineGap) upem \(r.info.unitsPerEm) | DirectWrite's own (OS/2) \(Double(r.info.dwAscent) * Double(size.points) / upem)/\(Double(r.info.dwDescent) * Double(size.points) / upem)/\(Double(r.info.dwLineGap) * Double(size.points) / upem) | family \(r.family) face \(r.face) found \(r.info.found)")
            XCTAssertEqual(Double(m.ascender), e.nsAscender, "\(name) ascender")
            XCTAssertEqual(Double(m.descender), e.nsDescender, "\(name) descender: CoreText's 16.16 ratio (\(e.nsDescender))")
            XCTAssertEqual(Double(m.leading), e.nsLeading, "\(name) leading")
            XCTAssertEqual(Int(r.info.unitsPerEm), e.unitsPerEm)
            XCTAssertEqual([Int(r.info.hheaAscender), Int(r.info.hheaDescender), Int(r.info.hheaLineGap)], [e.hheaAscender, e.hheaDescender, e.hheaLineGap])
            XCTAssertEqual(r.info.found, 1, "the bundled file")
            // a line's typographic bounds: CTLineGetTypographicBounds of a Galmuri line
            let line = engine.line("가 Ag", font: .plaza(size))
            XCTAssertEqual([Double(line.ascent), Double(line.descent), Double(line.leading)], [e.ctAscent, e.ctDescent, e.ctLeading], name)
        }
        for font in [PlazaFont.system(size: 15, weight: .bold), .system(size: 12, weight: .semibold), .system(size: 12, weight: .regular), .emoji(size: 12)] {
            guard let r = fonts.report(font) else { XCTFail("no font for \(font)"); continue }
            let m = engine.metrics(font)
            print("TEXT-METRICS \(font): family \(r.family) face \(r.face) weight \(r.info.weight) found \(r.info.found) upem \(r.info.unitsPerEm) hhea \(r.info.hheaAscender)/\(r.info.hheaDescender)/\(r.info.hheaLineGap) os2 \(r.info.dwAscent)/\(r.info.dwDescent)/\(r.info.dwLineGap) -> \(m.ascender)/\(m.descender)/\(m.leading)")
        }
        let empty = engine.line("", font: .plaza(.body))
        XCTAssertEqual([empty.width, empty.ascent, empty.descent, empty.leading], [0, 0, 0, 0], "an empty CTLine has no bounds")
    }

    func testPrivateFontsAreNotInstalled() throws {
        try requireResources()
        XCTAssertEqual(fonts.missing, [])
        XCTAssertEqual(fonts.refused, [])
        for name in ["Galmuri11", "Galmuri14"] {
            XCTAssertTrue(fonts.hasFamily(name, system: false), "\(name) is in the private collection")
            XCTAssertFalse(fonts.hasFamily(name, system: true), "\(name) is not installed for the system")
        }
        XCTAssertTrue(fonts.hasFamily("Pretendard", system: false))
        XCTAssertTrue(fonts.hasFamily("Segoe UI Emoji", system: true))
        print("TEXT-FONTS private collection made in \(fonts.creationMilliseconds) ms; system has Pretendard: \(fonts.hasFamily("Pretendard", system: true)); Malgun Gothic: \(fonts.hasFamily("Malgun Gothic", system: true))")
    }

    func testPretendardWeightsLoad() throws {
        try requireResources()
        var widths: [CGFloat] = []
        for weight in [PlazaFontWeight.regular, .semibold, .bold] {
            let font = PlazaFont.system(size: 15, weight: weight)
            let r = try XCTUnwrap(fonts.report(font))
            let w = engine.line("Pretendard 가나다 Weight 123", font: font).width
            print("TEXT-PRETENDARD \(weight): family \(r.family) face \(r.face) weight \(r.info.weight) width \(w)")
            XCTAssertEqual(r.family, "Pretendard")
            XCTAssertEqual(r.info.found, 1)
            XCTAssertEqual(Int(r.info.weight), weight == .regular ? 400 : (weight == .semibold ? 600 : 700))
            widths.append(w)
        }
        XCTAssertEqual(Set(widths).count, 3, "three distinct widths: \(widths)")
        XCTAssertTrue(widths[0] < widths[1] && widths[1] < widths[2], "heavier is wider: \(widths)")
        // Natural measuring keeps the design's fractional advances (GDI classic would round each to a whole pixel).
        let clusters = try native(engine.line("Pretendard 가나다 Weight 123", font: .system(size: 15, weight: .bold))).measured.clusters
        XCTAssertTrue(clusters.contains { $0.width != $0.width.rounded() }, "fractional advances: \(clusters.map(\.width))")
    }

    func testAMissingFontFallsBackLogsOnceAndDoesNotCrash() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-no-fonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        var logged: [String] = []
        let bare = WinTextFonts(directories: [empty], measuringMode: 0, log: { logged.append($0) })
        XCTAssertEqual(bare.missing.count, 5)
        XCTAssertEqual(logged.count, 1, "one line for the missing files: \(logged)")
        let e = WinPlazaTextEngine(fonts: bare)
        let line = e.line("가나다 abc", font: .plaza(.body))
        XCTAssertGreaterThan(line.width, 0)
        XCTAssertGreaterThan(e.metrics(.plaza(.body)).ascender, 0)
        let r = try XCTUnwrap(bare.report(.plaza(.body)))
        XCTAssertEqual(r.info.found, 0)
        print("TEXT-MISSING-FONT stands in: \(r.family) \(r.face); line width \(line.width); log: \(logged.first ?? "")")
        let c = try canvas(120, 24)
        c.setFillColor(rgb(0, 0, 0))
        c.draw(line, at: CGPoint(x: 2, y: 6))
        let image = try XCTUnwrap(c.makeImage())
        XCTAssertTrue(image.pixels.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, "the stand-in font draws")
        XCTAssertEqual(c.failureCount, 0)
    }

    // MARK: clusters and breaks against the Mac

    struct ClusterDiff {
        var boundaries = 0, widths = 0, flags = 0, maxWidthDelta: CGFloat = 0
        var notes: [String] = []
        var same: Bool { boundaries == 0 && widths == 0 && flags == 0 }
    }

    private func compare(_ mine: [PlazaBreakCluster], _ mac: [PlazaBreakCluster], _ text: String) -> ClusterDiff {
        var d = ClusterDiff()
        if mine.map(\.utf16) != mac.map(\.utf16) {
            d.boundaries = abs(mine.count - mac.count) + 1
            d.notes.append("boundaries mine \(mine.map(\.utf16.upperBound)) mac \(mac.map(\.utf16.upperBound))")
            return d
        }
        for (a, b) in zip(mine, mac) {
            if a.width != b.width {
                d.widths += 1
                d.maxWidthDelta = max(d.maxWidthDelta, abs(a.width - b.width))
                if d.notes.count < 6 { d.notes.append("\(substring(text, a.utf16).debugDescription) width \(a.width) mac \(b.width)") }
            }
            if (a.isWhitespace, a.isNewline, a.canBreakAfter, a.isHangul, a.isWordCharacter) != (b.isWhitespace, b.isNewline, b.canBreakAfter, b.isHangul, b.isWordCharacter) {
                d.flags += 1
                if d.notes.count < 12 {
                    d.notes.append("\(substring(text, a.utf16).debugDescription) flags mine \(PlazaBreaksGolden.flags(a)) mac \(PlazaBreaksGolden.flags(b))")
                }
            }
        }
        return d
    }

    /// The fonts DirectWrite drew a text with.
    private func families(_ line: WinTextLine) -> [String] {
        Array(Set(line.segments.flatMap { $0.handle.pieceFamilies().map { $0.family + ($0.color ? " (colour)" : "") } })).sorted()
    }

    func testClustersAreTheMacsForTheGalmuriCorpus() throws {
        try requireResources()
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        var same = 0, galmuriDiffer: [String] = [], report: [String] = []
        for f in 0..<2 {
            for (ti, text) in golden.texts.enumerated() {
                let line = try native(engine.line(text, font: sizeFont(f)))
                let d = compare(line.measured.clusters, golden.breakClusters(font: f, text: ti), text)
                let fallback = PlazaBreakCorpus.usesFallback(text: ti, font: f)
                let fams = families(line)
                let observed = fams.contains { !$0.hasPrefix("Galmuri") }
                let label = "\(golden.fonts[f]) #\(ti) \(text.prefix(24).debugDescription)"
                let row = "TEXT-CLUSTERS \(label): \(d.same ? "same" : "boundaries \(d.boundaries) widths \(d.widths) (max delta \(d.maxWidthDelta)) flags \(d.flags)") fonts \(fams)\(fallback != observed ? " [fallback list says \(fallback), DirectWrite drew \(observed ? "with" : "without") a fallback font]" : "")\(d.notes.isEmpty ? "" : " | " + d.notes.joined(separator: "; "))"
                print(row)
                report.append(row)
                if d.same { same += 1 } else if !fallback { galmuriDiffer.append(row) }
            }
        }
        print("TEXT-CLUSTERS summary: \(same) of \(2 * golden.texts.count) texts give the Mac's clusters exactly; Galmuri-only texts that differ: \(galmuriDiffer.count)")
        save(report.joined(separator: "\n"), as: "clusters.txt")
        XCTAssertEqual(galmuriDiffer, [], "every text drawn in Galmuri alone gives the Mac's clusters (boundaries, advances, flags)")
    }

    private enum Cause: String {
        case same, ruleGap = "rule gap (pinned by Task 1)", boundary = "cluster boundary", width = "width", flags = "flags", engine = "engine"
        case size = "same lines, other size (the fallback font's advances or line metrics)"
    }

    private func cause(mine: [Range<Int>], mac: [Range<Int>], goldenRule: [Range<Int>], diff: ClusterDiff) -> Cause {
        if mine == mac { return .same }
        if goldenRule != mac { return .ruleGap }
        if diff.boundaries > 0 { return .boundary }
        if diff.widths > 0 { return .width }
        if diff.flags > 0 { return .flags }
        return .engine
    }

    func testWrappedLinesAreTheMacsForTheCorpus() throws {
        try requireResources()
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        var counts: [String: Int] = [:], galmuriMismatches: [String] = [], rows: [String] = []
        var widthChecked = 0
        for c in golden.cases {
            let text = golden.texts[c.text], width = CGFloat(golden.widths[c.width]), font = sizeFont(c.font)
            let macClusters = golden.breakClusters(font: c.font, text: c.text)
            let lines = engine.wrappedLines(text, font: font, width: width)
            let mineTexts = try lines.map { try native($0).text }
            let mac = PlazaBreaksGolden.ranges(c.kit)
            let macTexts = mac.map { substring(text, $0) }
            // the ranges mine stand for, rebuilt from the texts in order
            let measured = try native(engine.line(text, font: font)).measured
            let mineRanges = PlazaLineBreaker.lines(measured.clusters, width: width, rule: .swiftUIText)
            let why = mineTexts == macTexts ? Cause.same
                : cause(mine: mineRanges, mac: mac, goldenRule: PlazaLineBreaker.lines(macClusters, width: width, rule: .swiftUIText),
                        diff: compare(measured.clusters, macClusters, text))
            let fallback = PlazaBreakCorpus.usesFallback(text: c.text, font: c.font)
            counts[(fallback ? "fallback " : "galmuri ") + why.rawValue, default: 0] += 1
            if why != .same {
                let row = "TEXT-WRAP \(golden.fonts[c.font]) width \(Int(width)) #\(c.text) \(text.prefix(24).debugDescription): \(why.rawValue) mine \(mineTexts) mac \(macTexts)"
                rows.append(row)
                if !fallback && why != .ruleGap { galmuriMismatches.append(row) }
            }
            if !fallback, why == .same {   // each line's width is the Mac's typesetter line width (the whole text's advances)
                for (line, r) in zip(lines, mac) {
                    let expected = macClusters.filter { $0.utf16.lowerBound >= r.lowerBound && $0.utf16.upperBound <= r.upperBound }.reduce(CGFloat(0)) { $0 + $1.width }
                    XCTAssertEqual(line.width, expected, "width of \(substring(text, r).debugDescription)")
                    widthChecked += 1
                }
            }
        }
        rows.forEach { print($0) }
        print("TEXT-WRAP summary (790 cases, .swiftUIText): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")); line widths checked \(widthChecked)")
        save(rows.joined(separator: "\n"), as: "wrap-mismatches.txt")
        XCTAssertEqual(galmuriMismatches, [], "Galmuri-only cases break as TextKit did, but for the rule gaps Task 1 pinned")
    }

    func testBubbleParagraphIsTheMacs() throws {
        try requireResources()
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        var counts: [String: Int] = [:], galmuriMismatches: [String] = [], rows: [String] = []
        for c in golden.cases {
            let text = golden.texts[c.text], width = CGFloat(golden.widths[c.width]), font = sizeFont(c.font)
            let m = engine.metrics(font)
            let maxHeight = ((m.ascender - m.descender + m.leading) * 8).rounded(.up)
            let paragraph = engine.paragraph(text, font: font, alignment: .center)
            let p = try XCTUnwrap(paragraph.native as? WinTextParagraph)
            let lines = p.frameLines(width: width)
            let mine = lines.isEmpty ? [0..<0] : lines.map(\.range)
            let mac = PlazaBreaksGolden.ranges(c.frame)
            let fit = paragraph.suggestedSize(limit: CGSize(width: width, height: maxHeight))
            let frame = CGSize(width: min(max(fit.width, 1).rounded(.up), width), height: min(max(fit.height, 1).rounded(.up), maxHeight))
            let visible = paragraph.visibleLength(in: frame)
            let macClusters = golden.breakClusters(font: c.font, text: c.text)
            var why = cause(mine: mine, mac: mac, goldenRule: PlazaLineBreaker.lines(macClusters, width: width, rule: .coreTextFrame),
                            diff: compare(p.whole.measured.clusters, macClusters, text))
            let sizeSame = [Double(fit.width), Double(fit.height)] == c.suggested && visible == c.visible
            if why == .same && !sizeSame { why = .size }
            let fallback = PlazaBreakCorpus.usesFallback(text: c.text, font: c.font)
            counts[(fallback ? "fallback " : "galmuri ") + why.rawValue, default: 0] += 1
            if why != .same {
                let row = "TEXT-BUBBLE \(golden.fonts[c.font]) width \(Int(width)) #\(c.text) \(text.prefix(24).debugDescription): \(why.rawValue) lines mine \(mine) mac \(mac) suggested mine \(fit) mac \(c.suggested) visible mine \(visible) mac \(c.visible)"
                rows.append(row)
                if !fallback && why != .ruleGap { galmuriMismatches.append(row) }
            }
        }
        rows.forEach { print($0) }
        print("TEXT-BUBBLE summary (790 cases, .coreTextFrame, suggestedSize, visibleLength): \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        save(rows.joined(separator: "\n"), as: "bubble-mismatches.txt")
        XCTAssertEqual(galmuriMismatches, [], "Galmuri-only paragraphs are CTFramesetter's: lines, suggested size and visible length")
    }

    /// Texts added on both sides (measured with TextKit / CTFramesetter on the Mac, `PlazaTextEngineParityTests` pins the same
    /// numbers for the Mac's engine): a long Korean chat line, Korean with Latin and digits, a Korean name.
    func testKoreanLaysOutAsOnTheMac() throws {
        try requireResources()
        for c in PlazaTextEngineParityTests.cases {
            let font = PlazaFont.plaza(c.size)
            let lines = engine.wrappedLines(c.text, font: font, width: c.width).map { try? native($0).text }
            let kit = PlazaBreaksGolden.ranges(c.kit).map { substring(c.text, $0) }
            print("TEXT-KOREAN \(c.size.points)pt width \(c.width) \(c.text.debugDescription): wrapped mine \(lines) mac \(kit)")
            let p = engine.paragraph(c.text, font: font, alignment: .center)
            let m = engine.metrics(font)
            let maxHeight = ((m.ascender - m.descender + m.leading) * 8).rounded(.up)
            let fit = p.suggestedSize(limit: CGSize(width: c.width, height: maxHeight))
            print("TEXT-KOREAN   bubble suggested mine \(fit) mac \(c.suggested); width of the whole line mine \(engine.line(c.text, font: font).width) mac \(c.lineWidth)")
            guard !c.hasEmoji else { continue }   // Segoe UI Emoji's advances are not Apple Color Emoji's: reported, not compared
            XCTAssertEqual(lines.compactMap { $0 }, kit, c.text)
            XCTAssertEqual(fit, c.suggested, c.text)
            XCTAssertEqual(engine.line(c.text, font: font).width, c.lineWidth, c.text)
        }
    }

    // MARK: truncation, runs, direction, emoji, stroke, bounds

    func testTruncationAddsAnEllipsisAndFits() throws {
        try requireResources()
        // CTLineCreateTruncatedLine(.end) on the Mac (Galmuri, measured): the width asked -> the truncated line's width (nil: none)
        let pins: [(String, PlazaTextSize, [(CGFloat, CGFloat?)])] = [
            ("Hello world", .small, [(11, nil), (12, 12), (20, 20), (23, 20), (30, 28), (37, 35), (44, 43), (51, 43), (60, 58), (80, 71), (200, 71)]),
            ("안녕하세요 반가워요", .body, [(12, nil), (17, 15), (23, 15), (30, 30), (44, 30), (51, 45), (60, 60), (80, 75), (200, 141)]),
            ("a b c d e f", .small, [(12, 12), (20, 19), (23, 19), (30, 19), (37, 32), (44, 44), (51, 44), (60, 57), (80, 69)]),
            ("WWWWWWWWWW", .body, [(12, nil), (17, 15), (30, 26), (37, 37), (44, 37), (51, 48), (60, 59), (80, 70), (200, 110)]),
            ("ab  cd", .small, [(12, 12), (20, 19), (30, 27), (37, 27), (44, 40)]),
            ("가나다라마바사", .small, [(12, 12), (20, 12), (30, 24), (37, 36), (44, 36), (51, 48), (60, 60), (80, 72), (200, 84)]),
            ("x", .small, [(8, nil), (12, 8)]),
            ("", .small, [(11, nil), (12, 0)]),
        ]
        var checked = 0
        for (text, size, cases) in pins {
            let font = PlazaFont.plaza(size)
            let line = engine.line(text, font: font), ellipsis = engine.line("…", font: font)
            for (w, expected) in cases {
                let cut = engine.truncated(line, width: w, ellipsis: ellipsis)
                XCTAssertEqual(cut?.width, expected, "\(text) at \(w)")
                if let cut, let expected, expected < line.width {
                    XCTAssertTrue(try native(cut).text.hasSuffix("…"), "\(text) at \(w): ends with the ellipsis")
                    XCTAssertLessThanOrEqual(cut.width, w)
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 56)
        // a line of runs: the kept start keeps its colours, the ellipsis takes the canvas's fill
        let red = rgb(230, 30, 30), blue = rgb(30, 60, 230), green = rgb(20, 200, 40)
        let runs = engine.line([PlazaTextRun(text: "가나", font: .plaza(.body), color: red), PlazaTextRun(text: "다라마바", font: .plaza(.body), color: blue)])
        let cut = try XCTUnwrap(engine.truncated(runs, width: 60, ellipsis: engine.line("…", font: .plaza(.body))))
        XCTAssertEqual(try native(cut).text, "가나다…")
        let c = try canvas(80, 24)
        c.setFillColor(green)
        c.draw(cut, at: CGPoint(x: 2, y: 6))
        let image = try XCTUnwrap(c.makeImage())
        let r = columns(image, near: red), b = columns(image, near: blue), g = columns(image, near: green)
        XCTAssertFalse(r.isEmpty || b.isEmpty || g.isEmpty, "red \(r.count) blue \(b.count) green \(g.count)")
        XCTAssertLessThan(r.max() ?? 0, b.min() ?? 0)
        XCTAssertLessThan(b.max() ?? 0, g.min() ?? 0, "the ellipsis follows in the fill colour")
    }

    func testRunsKeepTheirColours() throws {
        try requireResources()
        let red = rgb(230, 30, 30), blue = rgb(30, 60, 230), green = rgb(20, 200, 40)
        let line = engine.line([PlazaTextRun(text: "AB 가", font: .plaza(.body), color: red), PlazaTextRun(text: "나 CD", font: .plaza(.body), color: blue)])
        XCTAssertEqual(line.runs.map(\.text), ["AB 가", "나 CD"])
        let c = try canvas(120, 24)
        c.setFillColor(green)   // runs with their own colour ignore the fill
        c.draw(line, at: CGPoint(x: 2, y: 6))
        let image = try XCTUnwrap(c.makeImage())
        let r = columns(image, near: red), b = columns(image, near: blue)
        XCTAssertFalse(r.isEmpty || b.isEmpty)
        XCTAssertLessThan(r.max() ?? 0, b.min() ?? 0, "red then blue")
        XCTAssertTrue(columns(image, near: green).isEmpty, "no fill-coloured pixel")
        // across a wrap: each line carries its pieces, in their colours
        let wrapped = engine.wrappedLines([PlazaTextRun(text: "가나 다라 ", font: .plaza(.body), color: red),
                                           PlazaTextRun(text: "마바 사아", font: .plaza(.body), color: blue)], width: 50)
        let pieces = wrapped.map { $0.runs.map { "\($0.text)|\($0.color == red ? "r" : "b")" } }
        print("TEXT-RUNS wrapped at 50: \(pieces) widths \(wrapped.map(\.width))")
        XCTAssertEqual(pieces, [["가나|r"], ["다라|r"], ["마바|b"], ["사아|b"]], "the space a break swallows is in no line")
        for (i, l) in wrapped.enumerated() {
            let k = try canvas(80, 24)
            k.setFillColor(green)
            k.draw(l, at: CGPoint(x: 2, y: 6))
            let img = try XCTUnwrap(k.makeImage())
            XCTAssertFalse(columns(img, near: i < 2 ? red : blue).isEmpty, "line \(i) in its run's colour")
            XCTAssertTrue(columns(img, near: green).isEmpty)
        }
    }

    func testRTLBaseDirection() throws {
        try requireResources()
        XCTAssertTrue(try native(engine.line("שלום עולם", font: .plaza(.small))).rightToLeft)
        XCTAssertTrue(try native(engine.line("123 مرحبا Hello", font: .plaza(.small))).rightToLeft)
        XCTAssertFalse(try native(engine.line("Hello שלום", font: .plaza(.small))).rightToLeft)
        let red = rgb(230, 30, 30), blue = rgb(30, 60, 230)
        func order(_ runs: [PlazaTextRun]) throws -> (red: [Int], blue: [Int]) {
            let c = try canvas(120, 24)
            c.draw(engine.line(runs), at: CGPoint(x: 10, y: 6))
            let image = try XCTUnwrap(c.makeImage())
            return (columns(image, near: red), columns(image, near: blue))
        }
        // In a right-to-left paragraph the "!" that ends it is drawn at its left; in a left-to-right one at its right.
        let rtl = try order([PlazaTextRun(text: "שלום", font: .plaza(.small), color: red), PlazaTextRun(text: "!", font: .plaza(.small), color: blue)])
        XCTAssertLessThan(rtl.blue.max() ?? 999, rtl.red.min() ?? 0, "visual order: ! then the Hebrew")
        let ltr = try order([PlazaTextRun(text: "ab", font: .plaza(.small), color: red), PlazaTextRun(text: "!", font: .plaza(.small), color: blue)])
        XCTAssertLessThan(ltr.red.max() ?? 999, ltr.blue.min() ?? 0)
        // natural alignment in a frame: flush right for a right-to-left paragraph (the Mac's origin x = 200 - 58.09)
        let p = engine.paragraph("שלום עולם", font: .plaza(.small), alignment: .natural)
        let c = try canvas(200, 30)
        c.setFillColor(rgb(0, 0, 0))
        c.draw(p, in: CGRect(x: 0, y: 0, width: 200, height: 30))
        let image = try XCTUnwrap(c.makeImage())
        let inked = (0..<200).filter { x in (0..<30).contains { image.pixels[x, $0].a > 0 } }
        print("TEXT-RTL natural paragraph ink columns \(inked.first ?? -1)...\(inked.last ?? -1); line width \(engine.line("שלום עולם", font: .plaza(.small)).width) (Mac 58.09 in Lucida Grande); fonts \(families(try native(engine.line("שלום עולם", font: .plaza(.small)))))")
        XCTAssertGreaterThan(inked.last ?? 0, 190, "flush right")
        XCTAssertGreaterThan(inked.first ?? 0, 100)
    }

    func testEmojiFallBackToSegoeAndDrawInColour() throws {
        try requireResources()
        for (text, font) in [("🔥", PlazaFont.plaza(.body)), ("💧", .emoji(size: 12)), ("가🔥나", .plaza(.small)), ("👨‍👩‍👧‍👦", .plaza(.body)), ("👍🏽", .plaza(.body)), ("🇰🇷", .plaza(.body))] {
            let line = engine.line(text, font: font)
            let n = try native(line)
            let fams = n.segments.flatMap { $0.handle.pieceFamilies() }
            let bounds = n.inkBounds()
            print("TEXT-EMOJI \(text.debugDescription) \(font): width \(line.width) ascent \(line.ascent) descent \(line.descent) clusters \(n.measured.clusters.count) colour runs \(n.segments[0].handle.info.colorRuns) pieces \(fams.count) fonts \(Set(fams.map(\.family)).sorted()) ink \(bounds)")
            guard text != "🇰🇷" else { continue }   // Windows has no flag glyphs: two regional-indicator letters, reported
            XCTAssertTrue(fams.contains { $0.family == "Segoe UI Emoji" && $0.color }, "\(text) falls back to Segoe UI Emoji in colour")
            let c = try canvas(64, 40)
            c.setFillColor(rgb(0, 0, 0))
            let at = CGPoint(x: 8, y: 12)
            c.draw(line, at: at)
            let image = try XCTUnwrap(c.makeImage())
            var chromatic = 0
            for y in 0..<40 {
                for x in 0..<64 {
                    let p = image.pixels[x, y]
                    guard p.a > 128 else { continue }
                    let ux = Double(x) + 0.5 - at.x, uy = 40 - (Double(y) + 0.5) - at.y   // user space, relative to the origin
                    guard bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: ux, y: uy)) else { continue }
                    if max(p.r, p.g, p.b) - min(p.r, p.g, p.b) > 40 { chromatic += 1 }
                }
            }
            XCTAssertGreaterThan(chromatic, 4, "\(text): colour pixels inside the glyph box")
        }
    }

    /// A character with U+FE0F (or a keycap) asks for emoji presentation: drawn in the emoji font even where Galmuri has the
    /// base character, as CoreText draws `©️` and `1️⃣` in Apple Color Emoji.
    func testEmojiPresentationUsesTheEmojiFont() throws {
        try requireResources()
        for text in ["©️", "1️⃣", "™️"] {
            let n = try native(engine.line(text, font: .plaza(.body)))
            let fams = n.segments.flatMap { $0.handle.pieceFamilies() }
            print("TEXT-EMOJI-PRESENTATION \(text.debugDescription): fonts \(fams.map { $0.family + ($0.color ? " (colour)" : "") }) width \(engine.line(text, font: .plaza(.body)).width)")
            XCTAssertTrue(fams.contains { $0.family == "Segoe UI Emoji" }, "\(text) in the emoji font")
            XCTAssertFalse(fams.contains { $0.family.hasPrefix("Galmuri") }, "\(text) not in Galmuri")
        }
        XCTAssertTrue(try native(engine.line("©", font: .plaza(.body))).segments[0].handle.pieceFamilies().allSatisfy { $0.family == "Galmuri14" },
                      "without the selector Galmuri's own © is used")
    }

    func testStrokeModeSkipsColourGlyphs() throws {
        try requireResources()
        let c = try canvas(64, 32)
        c.setTextDrawingMode(.stroke)
        c.setLineWidth(3)
        c.setLineJoin(.round)
        c.setStrokeColor(rgb(20, 22, 31))
        c.draw(engine.line("🔥", font: .plaza(.body)), at: CGPoint(x: 6, y: 8))
        let emoji = try XCTUnwrap(c.makeImage())
        XCTAssertFalse(emoji.pixels.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, "a colour glyph draws no stroke")
        c.draw(engine.line("A", font: .system(size: 15, weight: .bold)), at: CGPoint(x: 30, y: 8))
        let letter = try XCTUnwrap(c.makeImage())
        XCTAssertTrue(letter.pixels.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element > 200 }, "a plain glyph's outline is stroked")
        XCTAssertEqual(c.failureCount, 0)
    }

    func testImageBoundsAreInk() throws {
        try requireResources()
        // CTLineGetImageBounds on the Mac (Galmuri, measured): pixel-font outlines on the design grid
        let pins: [(String, PlazaTextSize, CGRect)] = [
            ("Zz", .small, CGRect(x: 0, y: 0, width: 13, height: 11)), ("!?", .body, CGRect(x: 2, y: 0, width: 11, height: 14)),
            ("Name", .body, CGRect(x: 1, y: 0, width: 38, height: 14)), ("도토리", .body, CGRect(x: 1, y: 0, width: 42, height: 14)),
            ("g", .small, CGRect(x: 0, y: -2, width: 7, height: 10)), ("", .small, .zero), (" ", .small, .zero),
        ]
        let c = try canvas(80, 30)
        for (text, size, expected) in pins {
            let line = engine.line(text, font: .plaza(size))
            let first = c.imageBounds(of: line)
            XCTAssertEqual(first, expected, text)
            c.draw(line, at: CGPoint(x: 37, y: 11))
            XCTAssertEqual(c.imageBounds(of: line), first, "\(text): the same after drawing it")
        }
        // every inked pixel of a line drawn at whole pixels is inside its bounds
        let k = try canvas(40, 24)
        k.setShouldAntialias(false)
        let zz = engine.line("Zz", font: .plaza(.small))
        k.draw(zz, at: CGPoint(x: 5, y: 6))
        let image = try XCTUnwrap(k.makeImage())
        let box = k.imageBounds(of: zz).offsetBy(dx: 5, dy: 6)
        var inside = 0, outside = 0
        for y in 0..<24 {
            for x in 0..<40 where image.pixels[x, y].a > 0 {
                if box.contains(CGPoint(x: Double(x) + 0.5, y: 24 - (Double(y) + 0.5))) { inside += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 10)
        XCTAssertEqual(outside, 0)
    }

    // MARK: measuring mode

    /// GDI classic rounds every advance to whole pixels at 1 px per point: Galmuri at its design sizes has whole-pixel
    /// advances, so both modes agree; Pretendard does not. Natural is the plaza's mode (CoreText's advances are fractional).
    func testMeasuringModesOnThePixelFontAndOnPretendard() throws {
        try requireResources()
        let gdi = WinPlazaTextEngine(fonts: WinTextFonts(directories: WinPlazaAssets.directories, measuringMode: 1, log: { _ in }))
        let golden = try PlazaParityGoldens.load(PlazaBreaksGolden.self, "breaks.json")
        var same = 0, differ = 0
        for f in 0..<2 {
            for (ti, text) in golden.texts.enumerated() where !PlazaBreakCorpus.usesFallback(text: ti, font: f) {
                let a = try native(engine.line(text, font: sizeFont(f))).measured.clusters.map(\.width)
                let b = try native(gdi.line(text, font: sizeFont(f))).measured.clusters.map(\.width)
                if a == b { same += 1 } else { differ += 1 }
            }
        }
        let plate = "도토리 Ab Pretendard"
        let natural = engine.line(plate, font: .system(size: 15, weight: .bold)).width
        let classic = gdi.line(plate, font: .system(size: 15, weight: .bold)).width
        print("TEXT-MEASURING Galmuri corpus texts with the same advances in natural and GDI classic: \(same), different: \(differ); Pretendard Bold 15 \(plate.debugDescription): natural \(natural), GDI classic \(classic)")
        XCTAssertEqual(differ, 0, "a pixel font at its design size has whole-pixel advances in both modes")
        XCTAssertNotEqual(natural, classic, "Pretendard's fractional advances are rounded by GDI classic")
    }

    // MARK: images next to the Mac

    private var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PTB_CANVAS_OUT"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("text", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ text: String, as name: String) {
        guard let dir = outputDirectory else { return }
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func save(_ bitmap: PlazaBitmap, as name: String) {
        guard let dir = outputDirectory, let png = graphics.encodePNG(PlazaImage(bitmap: bitmap)) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }

    private func golden(_ path: String) throws -> PlazaBitmap {
        try XCTUnwrap(graphics.decodeImage(Data(contentsOf: PlazaParityGoldens.url(path))), path).pixels
    }

    /// Mac | Windows | |difference| x 4 (where both have pixels), each blown up `zoom` times, flattened on white; sizes may differ.
    private func sideBySide(mac: PlazaBitmap, windows: PlazaBitmap, zoom z: Int = 4) -> PlazaBitmap {
        let w = max(mac.width, windows.width), h = max(mac.height, windows.height), gap = 4
        var out = PlazaBitmap(width: (w * 3) * z + gap * 2, height: h * z, fill: PlazaRGBA(r: 90, g: 90, b: 90, a: 255))
        func flat(_ b: PlazaBitmap, _ x: Int, _ y: Int) -> PlazaRGBA? {
            guard x < b.width, y < b.height else { return nil }
            let p = b[x, y], k = 255 - Int(p.a)
            return PlazaRGBA(r: UInt8(min(255, Int(p.r) + k)), g: UInt8(min(255, Int(p.g) + k)), b: UInt8(min(255, Int(p.b) + k)), a: 255)
        }
        for y in 0..<(h * z) {
            for x in 0..<(w * z) {
                let sx = x / z, sy = y / z
                let a = flat(mac, sx, sy), b = flat(windows, sx, sy)
                if let a { out[x, y] = a }
                if let b { out[w * z + gap + x, y] = b }
                if let a, let b {
                    func d(_ p: UInt8, _ q: UInt8) -> UInt8 { UInt8(min(255, abs(Int(p) - Int(q)) * 4)) }
                    out[2 * (w * z + gap) + x, y] = PlazaRGBA(r: d(a.r, b.r), g: d(a.g, b.g), b: d(a.b, b.b), a: 255)
                }
            }
        }
        return out
    }

    private func diffLine(_ a: PlazaBitmap, _ b: PlazaBitmap) -> String {
        guard a.width == b.width, a.height == b.height else { return "size Mac \(a.width)x\(a.height) Windows \(b.width)x\(b.height)" }
        var over1 = 0, over64 = 0, worst = 0
        for i in 0..<(a.width * a.height) {
            var m = 0
            for c in 0..<4 { m = max(m, abs(Int(a.bytes[i * 4 + c]) - Int(b.bytes[i * 4 + c]))) }
            if m > 1 { over1 += 1 }
            if m > 64 { over64 += 1 }
            worst = max(worst, m)
        }
        return "same size \(a.width)x\(a.height): over1=\(over1) over64=\(over64) max=\(worst)"
    }

    func testTextArtNextToTheMac() throws {
        try requireResources()
        let plate = PlazaColor(hex: 0xFF9ECF)
        for scale in [1, 2] {
            let p = try XCTUnwrap(PlazaNamePlate.image(text: "도토리 Ab", color: plate, scale: CGFloat(scale), graphics: graphics))
            let macPlate = try golden("canvas-script/plate@\(scale).png")
            print("TEXT-ART plate@\(scale) (Pretendard Bold vs the Mac's system font): \(diffLine(macPlate, p.pixels)); origin \(p.origin)")
            XCTAssertEqual(p.origin, .canvasWithText)
            save(p.pixels, as: "plate@\(scale).png")
            save(sideBySide(mac: macPlate, windows: p.pixels), as: "plate@\(scale)-compare.png")
            let b = try XCTUnwrap(PlazaChatBubble.image(text: "안녕 hello 🔥 긴 줄은 접힌다", scale: CGFloat(scale), graphics: graphics))
            let macBubble = try golden("canvas-script/bubble@\(scale).png")
            print("TEXT-ART bubble@\(scale): \(diffLine(macBubble, b.pixels))")
            save(b.pixels, as: "bubble@\(scale).png")
            save(sideBySide(mac: macBubble, windows: b.pixels), as: "bubble@\(scale)-compare.png")
        }
        let c = try canvas(PlazaCanvasScript.width, PlazaCanvasScript.height)
        PlazaCanvasScript.run(c, graphics.text)
        XCTAssertEqual(c.failureCount, 0)
        let script = try XCTUnwrap(c.makeImage())
        let mac = try golden("canvas-script/script.png")
        print("TEXT-ART script.png (with text): \(diffLine(mac, script.pixels))")
        XCTAssertEqual(script.origin, .canvasWithText)
        save(script.pixels, as: "script.png")
        save(sideBySide(mac: mac, windows: script.pixels), as: "script-compare.png")
        // the Galmuri-only bubble is the Mac's size exactly
        let galmuri = try XCTUnwrap(PlazaChatBubble.image(text: "안녕하세요 오늘 광장에서 만나요", scale: 2, graphics: graphics))
        print("TEXT-ART Galmuri bubble @2: \(galmuri.width)x\(galmuri.height)")
        // more renders for the report (the Mac's side is rendered on the Mac from the same calls)
        for (i, name) in PlazaTextEngineParityTests.plates.enumerated() {
            for scale in [1, 2] {
                let image = try XCTUnwrap(PlazaNamePlate.image(text: name.text, title: name.title, color: plate, scale: CGFloat(scale), graphics: graphics))
                save(image.pixels, as: "plate-\(i)@\(scale).png")
                print("TEXT-ART plate-\(i)@\(scale) \(name.text.prefix(16).debugDescription) title \(name.title ?? "-"): \(image.width)x\(image.height)")
            }
        }
        for (i, text) in PlazaTextEngineParityTests.bubbles.enumerated() {
            for scale in [1, 2] {
                let image = try XCTUnwrap(PlazaChatBubble.image(text: text, scale: CGFloat(scale), graphics: graphics))
                save(image.pixels, as: "bubble-\(i)@\(scale).png")
                print("TEXT-ART bubble-\(i)@\(scale) \(text.prefix(16).debugDescription): \(image.width)x\(image.height) drawn \(PlazaChatBubble.drawnLength(of: text, graphics: graphics)) of \(text.utf16.count)")
            }
        }
    }

    @MainActor func testChatLogRowsAndCost() async throws {
        try requireResources()
        let log = PlazaChatLog()
        let names = ["도토리", "Mint", "아주긴닉네임입니다요", "Zoe"]
        for i in 0..<50 {
            log.append(time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60), name: names[i % names.count],
                       text: PlazaTextEngineParityTests.chatTexts[i % PlazaTextEngineParityTests.chatTexts.count],
                       color: PlazaNameColor.palette[i % PlazaNameColor.palette.count], isLoud: i % 7 == 3)
        }
        let panel = PlazaChatLogPanel(log: log)
        var times: [Double] = []
        var drawing: PlazaPanelDrawing?
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            drawing = panel.render(scale: 2, viewport: CGSize(width: 900, height: 600), graphics: graphics)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let layers = drawing?.layers.count ?? 0
        print("TEXT-COST chat log panel (visible lines, 50 kept) render @2: median \(times[2]) ms min \(times[0]) max \(times[4]); layers \(layers)")
        if let drawing { savePanel(drawing, as: "chatlog@2.png") }

        // 50 chat lines laid out (runs, wrapped) and drawn into one canvas
        let runs = (0..<50).map { PlazaTextEngineParityTests.chatRuns($0, name: names[$0 % names.count]) }
        var layout: [Double] = [], draw: [Double] = []
        for _ in 0..<5 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let wrapped = runs.map { engine.wrappedLines($0, width: 300) }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let c = try canvas(640, 50 * 40)
            c.scale(x: 2, y: 2)
            var y: CGFloat = 1000
            for lines in wrapped { for l in lines { y -= 19; c.draw(l, at: CGPoint(x: 4, y: y)) } }
            _ = c.makeImage()
            let t2 = DispatchTime.now().uptimeNanoseconds
            layout.append(Double(t1 - t0) / 1e6)
            draw.append(Double(t2 - t1) / 1e6)
        }
        layout.sort(); draw.sort()
        print("TEXT-COST 50 chat lines: wrappedLines median \(layout[2]) ms, draw @2 + makeImage median \(draw[2]) ms")
        var bubble: [Double] = []
        for i in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = PlazaChatBubble.image(text: "오늘 광장에서 같이 산책하실 분 \(i)", scale: 2, graphics: graphics)
            bubble.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        bubble.sort()
        print("TEXT-COST bubble (30 chars) @2 layout + draw + image: median \(bubble[10]) ms min \(bubble[0]) max \(bubble[19])")
        var plates: [Double] = []
        for i in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = PlazaNamePlate.image(text: "도토리 \(i)", title: "수줍은", color: PlazaColor(hex: 0xFF9ECF), scale: 2, graphics: graphics)
            plates.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        plates.sort()
        print("TEXT-COST name plate with title @2 (stroke under a shadow): median \(plates[10]) ms min \(plates[0]) max \(plates[19])")
        XCTAssertLessThan(bubble[10], 200)
    }

    private func savePanel(_ drawing: PlazaPanelDrawing, as name: String) {
        for (i, layer) in drawing.layers.enumerated() {
            if case .image(let image, _) = layer { save(image.pixels, as: name.replacingOccurrences(of: ".png", with: "-\(i).png")) }
        }
    }

    func testFontsAndLinesCostAndLeak() throws {
        try requireResources()
        var made: [Double] = []
        let start = WindowsPlazaTextTests.privateBytes() ?? 0
        var kept: [WinTextFonts] = []
        for _ in 0..<3 {
            let f = WinTextFonts(directories: WinPlazaAssets.directories, measuringMode: 0, log: { _ in })
            for font in [PlazaFont.plaza(.small), .plaza(.body), .system(size: 15, weight: .bold), .emoji(size: 12)] {
                _ = WinPlazaTextEngine(fonts: f).line("가 A 🔥", font: font)
            }
            made.append(f.creationMilliseconds)
            kept.append(f)
        }
        let held = (WindowsPlazaTextTests.privateBytes() ?? 0) - start
        print("TEXT-COST font collection (5 files): first in this process \(fonts.creationMilliseconds) ms, fresh ones \(made) ms; three fresh collections, each used in every font, hold \(held / 3) private bytes each (font files are mapped, not copied)")
        kept.removeAll()
        guard let before = WindowsPlazaTextTests.privateBytes() else { throw XCTSkip("process counters unavailable") }
        for i in 0..<200 { _ = engine.line("warm \(i) 가나다", font: .plaza(.body)) }
        guard let warm = WindowsPlazaTextTests.privateBytes() else { return }
        let c = try canvas(200, 40)
        for i in 0..<2000 {
            let l = engine.line("줄 \(i) line 🔥", font: i % 2 == 0 ? .plaza(.small) : .system(size: 15, weight: .bold))
            if i % 10 == 0 { c.draw(l, at: CGPoint(x: 2, y: 10)); _ = c.imageBounds(of: l) }
        }
        guard let after = WindowsPlazaTextTests.privateBytes() else { return }
        print("TEXT-LEAK 2000 lines (200 drawn): private \(warm) -> \(after) (+\(after - warm)); before warm-up \(before)")
        XCTAssertLessThan(after - warm, 8 << 20)
        XCTAssertEqual(c.failureCount, 0)
    }

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testTextWorksOffTheMainThread() throws {
        try requireResources()
        let group = DispatchGroup()
        let failures = Failures()
        let engine = self.engine, graphics = self.graphics
        for t in 0..<8 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for i in 0..<40 {
                    let lines = engine.wrappedLines("스레드 \(t) 줄 \(i) 가나다라 마바사 아자차", font: .plaza(.body), width: 60)
                    guard let c = graphics.makeCanvas(width: 80, height: 60, colorSpace: .sRGB) else { failures.add("no canvas"); return }
                    for (k, l) in lines.enumerated() { c.draw(l, at: CGPoint(x: 1, y: 50 - 18 * CGFloat(k))) }
                    if lines.count < 2 || c.makeImage() == nil { failures.add("thread \(t) #\(i)") }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(failures.all, [])
    }

    private static func privateBytes() -> Int? {
        typealias Memory = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
        struct Counters {
            var cb: UInt32 = 0, faults: UInt32 = 0
            var peakWS: UInt = 0, ws: UInt = 0, qpp: UInt = 0, qp: UInt = 0, qnpp: UInt = 0, qnp: UInt = 0, pagefile: UInt = 0, peakPagefile: UInt = 0, privateUsage: UInt = 0
        }
        guard let memory = WinDynamic.symbol("kernel32.dll", "K32GetProcessMemoryInfo", as: Memory.self) else { return nil }
        var counters = Counters()
        counters.cb = UInt32(MemoryLayout<Counters>.size)
        guard memory(GetCurrentProcess(), &counters, counters.cb) != 0 else { return nil }
        return Int(counters.privateUsage)
    }
}
#endif
