import XCTest
@testable import PokeTokenBar

/// Text made of runs with different colours (Track A Task 17a), through the stub engine (monospace: 9 points a character
/// in the 15-point body font, so a 45-point line holds 5 characters). The Mac's real line breaking is in
/// `PlazaChatLogPanelRenderTests+Mac`.
final class PlazaTextRunsTests: XCTestCase {
    private let engine = PlazaStubTextEngine()
    private let body = PlazaFont.plaza(.body)
    private let red = PlazaColor(hex: 0xFF0000), blue = PlazaColor(hex: 0x0000FF), green = PlazaColor(hex: 0x00FF00)
    private func run(_ text: String, _ color: PlazaColor, _ font: PlazaFont? = nil) -> PlazaTextRun {
        PlazaTextRun(text: text, font: font ?? body, color: color)
    }
    private func summary(_ lines: [PlazaTextLine]) -> [[String]] { lines.map { $0.runs.map { "\($0.text)|\($0.color == red ? "r" : $0.color == blue ? "b" : "g")" } } }

    func testALineKeepsEachRunsColour() {
        let line = engine.line([run("ab ", red), run("cd", blue)])
        XCTAssertEqual(line.width, 45)
        XCTAssertEqual(summary([line]), [["ab |r", "cd|b"]])
        XCTAssertEqual(engine.line([]).width, 0)
    }

    func testAWordBreaksAtSpacesAcrossRuns() {
        let lines = engine.wrappedLines([run("ab", red), run("cd ef", blue)], width: 45)
        XCTAssertEqual(summary(lines), [["ab|r", "cd|b"], ["ef|b"]], "abcd is one word spanning two runs; ef does not fit after it")
        XCTAssertEqual(lines.map(\.width), [36, 18])
    }

    func testAWordWiderThanALineBreaksBetweenCharactersAndKeepsItsRuns() {
        let lines = engine.wrappedLines([run("abcdefg", red), run("hij", blue)], width: 45)
        XCTAssertEqual(summary(lines), [["abcde|r"], ["fg|r", "hij|b"]])
    }

    func testASpaceAtABreakBelongsToNoLine() {
        let lines = engine.wrappedLines([run("abcde ", red), run("fgh", blue), run(" ", green), run("ij", green)], width: 54)
        XCTAssertEqual(summary(lines), [["abcde|r"], ["fgh|b", " ij|g"]], "the space after abcde is swallowed; the one inside the second line stays, joined to its run's neighbour")
    }

    func testNoRunsOrEmptyRunsIsOneEmptyLine() {
        XCTAssertEqual(engine.wrappedLines([], width: 100).count, 1)
        XCTAssertEqual(engine.wrappedLines([run("", red)], width: 100).map(\.width), [0])
    }

    func testOnePlainRunBreaksLikeAPlainText() {
        for width in [CGFloat(18), 45, 90, 400] {
            let text = "ab cdefghij kl mnopqrstuvwxyz a"
            let plain = engine.wrappedLines(text, font: body, width: width)
            let runs = engine.wrappedLines([run(text, red)], width: width)
            XCTAssertEqual(plain.map { ($0.native as! PlazaStubText).text }, runs.map { ($0.native as! PlazaStubText).text }, "width \(width)")
            XCTAssertEqual(plain.map(\.width), runs.map(\.width))
        }
    }

    func testRunsOfDifferentFontsAddTheirOwnAdvance() {
        let lines = engine.wrappedLines([run("ab", red), run("cd", blue, .plaza(.small))], width: 100)
        XCTAssertEqual(lines.map(\.width), [18 + 14.4], "15-point ab then 12-point cd")
    }
}
