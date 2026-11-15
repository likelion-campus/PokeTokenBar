import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Review round item 15: `CoreTextPlazaEngine.wrappedLines` turned a BLANK line into the rest of the text (`CFRange` length 0 means "to the end"),
/// so `"a\n\nbcd"` drew `bcd` twice. A blank line is an empty line of the font's height, as SwiftUI's `Text` showed it.
@MainActor final class PlazaBlankLineTests: XCTestCase {
    private let engine = PlatformPlaza.graphics.text
    private let font = PlazaFont.plaza(.body)

    private func widths(_ text: String) -> [CGFloat] { engine.wrappedLines(text, font: font, width: 300).map(\.width) }

    func testABlankLineIsAnEmptyLineNotTheRestOfTheText() {
        let one = engine.line("a", font: font).width, three = engine.line("bcd", font: font).width
        XCTAssertEqual(widths("a\n\nbcd"), [one, 0, three], "three lines: a, blank, bcd (it was a, bcd, bcd)")
        XCTAssertEqual(widths("a\n\n\n\nb").count, 5, "several blank lines in a row")
        XCTAssertEqual(widths("a\n\n\n\nb").map { $0 == 0 }, [false, true, true, true, false])
        XCTAssertEqual(widths("\n\na").count, 3, "leading blank lines")
        XCTAssertEqual(widths("\n\na").prefix(2).map { $0 }, [0, 0])
    }

    func testTheSameBlankLinesAsRunsAreEmptyToo() {
        let red = PlazaColor(hex: 0xFF0000)
        let lines = engine.wrappedLines([PlazaTextRun(text: "a\n\nbcd", font: font, color: red)], width: 300)
        XCTAssertEqual(lines.map(\.width), [engine.line("a", font: font).width, 0, engine.line("bcd", font: font).width])
        XCTAssertEqual(lines.map { $0.runs.map(\.text).joined() }, ["a", "", "bcd"])
    }

    /// The line count a SwiftUI `Text` shows for the same string (its height over the font's line height), compared with the engine's.
    func testTheLineCountIsWhatSwiftUIsTextShows() async throws {
        let lineHeight = (engine.metrics(font).ascender - engine.metrics(font).descender).rounded()
        for text in ["a\n\nbcd", "a\n\n\n\nb", "\n\na", "a\n\n", "\n", "a\nb"] {
            let host = NSHostingView(rootView: Text(text).font(Font(PlazaResources.font(.body))).fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading))
            let swiftUI = Int((host.fittingSize.height / lineHeight).rounded())
            XCTAssertEqual(engine.wrappedLines(text, font: font, width: 300).count, swiftUI, "\(text.debugDescription)")
        }
    }
}
