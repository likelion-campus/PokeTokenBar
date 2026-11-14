import XCTest
import AppKit
@testable import PokeTokenBar

/// Text made of runs through the real CoreText/TextKit engine (Track A Task 17a): a run's colour is drawn, a break may
/// fall inside or between runs, and the breaks are the plain text's breaks (Korean words whole, emoji, RTL).
@MainActor final class PlazaTextRunsMacTests: XCTestCase {
    private let engine = PlatformPlaza.graphics.text
    private let body = PlazaFont.plaza(.body)
    private let red = PlazaColor(hex: 0xFF0000), blue = PlazaColor(hex: 0x0000FF)

    /// Where each line sits in the text (UTF-16), from the engine's own CTLines.
    private func ranges(_ lines: [PlazaTextLine]) -> [NSRange] {
        lines.map { let r = CTLineGetStringRange(CoreTextPlazaEngine.ctLine($0)!); return NSRange(location: r.location, length: r.length) }
    }

    func testARunsColourIsDrawn() throws {
        let line = engine.line([PlazaTextRun(text: "████", font: body, color: red), PlazaTextRun(text: "████", font: body, color: blue)])
        let w = Int(line.width.rounded(.up)) + 2, h = 24
        let canvas = try XCTUnwrap(PlatformPlaza.graphics.makeCanvas(width: w, height: h, colorSpace: .sRGB))
        canvas.setFillColor(.white)   // a context colour that no run has: the runs' own colours must win
        canvas.draw(line, at: CGPoint(x: 1, y: 6))
        let px = try XCTUnwrap(canvas.makeImage()).pixels
        var redLeft = 0, blueRight = 0, wrong = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, r = Int(px.bytes[i]), b = Int(px.bytes[i + 2]), a = Int(px.bytes[i + 3])
            guard a > 200 else { continue }
            if r > 200, b < 60 { if x < w / 2 { redLeft += 1 } else { wrong += 1 } }
            else if b > 200, r < 60 { if x >= w / 2 { blueRight += 1 } else { wrong += 1 } }
            else { wrong += 1 }
        } }
        XCTAssertGreaterThan(redLeft, 50)
        XCTAssertGreaterThan(blueRight, 50)
        XCTAssertEqual(wrong, 0, "no pixel of the other colour, no context-white")
    }

    func testBreaksAreThePlainTextsBreaksWhereverTheColoursChange() {
        let cases = ["오늘 점심은 뭘 먹을까요 우리 같이 먹어요", "hello wonderful world of colourful runs", "verylongunbrokenwordthatcannotfitanywhereatall and more",
                     "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀", "שלום עולם זה טקסט ארוך מאוד בעברית שמתפרש על כמה שורות", "a b",
                     "한국어 English 混ぜた text 😀 with everything"]
        for text in cases {
            for width in [CGFloat(60), 120, 200] {
                let plain = ranges(engine.wrappedLines(text, font: body, width: width))
                for cut in [1, text.count / 3, text.count / 2, text.count - 1] where cut > 0 && cut < text.count {
                    let i = text.index(text.startIndex, offsetBy: cut)
                    let runs = [PlazaTextRun(text: String(text[..<i]), font: body, color: red),
                                PlazaTextRun(text: String(text[i...]), font: body, color: blue)]
                    let lines = engine.wrappedLines(runs, width: width)
                    XCTAssertEqual(ranges(lines), plain, "\(text) @\(width), colours change after \(cut)")
                    XCTAssertEqual(lines.map { $0.runs.map(\.text).joined() }, plain.map { (text as NSString).substring(with: $0) }.map { $0.trimmingCharacters(in: .whitespaces) },
                                   "the pieces of each line are its text")
                    XCTAssertEqual(lines.map(\.width), engine.wrappedLines(text, font: body, width: width).map(\.width), "\(text) @\(width) cut \(cut): same widths")
                }
            }
        }
    }

    func testEachLineCarriesTheColoursOfItsPieces() {
        let lines = engine.wrappedLines([PlazaTextRun(text: "가나다 라마바 ", font: body, color: red), PlazaTextRun(text: "사아자 차카타", font: body, color: blue)], width: 70)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines { XCTAssertTrue(line.runs.allSatisfy { !$0.text.isEmpty }) }
        let joined = lines.flatMap(\.runs).map(\.text).joined()
        XCTAssertEqual(joined.replacingOccurrences(of: " ", with: ""), "가나다라마바사아자차카타", "every character on exactly one line; breaking spaces left off")
        XCTAssertEqual(lines.first?.runs.first?.color, red)
        XCTAssertEqual(lines.last?.runs.last?.color, blue)
    }

    func testNoRunsIsOneEmptyLineAndAnEmptyRunToo() {
        XCTAssertEqual(engine.wrappedLines([], width: 100).count, 1)
        XCTAssertEqual(engine.wrappedLines([PlazaTextRun(text: "", font: body, color: red)], width: 100).map(\.width), [0])
    }

    func testALineOfRunsCanBeTruncated() throws {
        let line = engine.line([PlazaTextRun(text: "긴 이름: ", font: body, color: red), PlazaTextRun(text: "아주아주아주 긴 메시지입니다", font: body, color: blue)])
        let cut = try XCTUnwrap(engine.truncated(line, width: 100, ellipsis: engine.line("…", font: body)))
        XCTAssertLessThanOrEqual(cut.width, 100.01)
        XCTAssertLessThan(cut.width, line.width)
    }
}
