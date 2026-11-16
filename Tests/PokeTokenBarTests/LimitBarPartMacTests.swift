import XCTest
@testable import PokeTokenBar

/// The bar's measurements are the Mac's private constants (`LimitProgressBar`); a Mac change fails here until the Windows
/// bar (`LimitBarPart`) has it too (stage 7 Task 5). Reads the Mac view's source text, like the parity scan.
@MainActor
final class LimitBarPartMacTests: XCTestCase {
    func testTheBarUsesTheMacsMarkerAndTrackNumbers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/UI/PopoverView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("private static let markerWidth: CGFloat = 2.5"), "marker width")
        XCTAssertTrue(source.contains("private static let trackHeight: CGFloat = 6"), "track height")
        XCTAssertTrue(source.contains("private static let markerOverhang: CGFloat = 2"), "marker overhang")
        XCTAssertTrue(source.contains(".fill(.primary.opacity(0.55))"), "marker colour")
        XCTAssertEqual(LimitBarPart.markerWidth, 2.5)
        XCTAssertEqual(LimitBarPart.trackHeight, 6)
        XCTAssertEqual(LimitBarPart.markerHeight, LimitBarPart.trackHeight + 2 * 2)
    }
}
