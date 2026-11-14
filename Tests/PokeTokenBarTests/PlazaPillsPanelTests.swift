import XCTest
@testable import PokeTokenBar

/// The countdown, banner and hint pills as one panel (Track A Task 14). Stub text: every character 0.6 × 15 = 9 points
/// wide, a line 15 tall (ascender 12). Runs on Windows.
@MainActor final class PlazaPillsPanelTests: XCTestCase {
    private let text = PlazaStubTextEngine()
    private let window = CGSize(width: 960, height: 640)

    private func panel(countdown: String? = nil, banner: String? = nil, hint: String? = nil) -> (PlazaPillsPanel, PlazaOverlayModel) {
        let model = PlazaOverlayModel()
        model.countdown = countdown
        model.banner = banner
        model.hint = hint
        return (PlazaPillsPanel(model: model), model)
    }

    private func texts(_ pill: PlazaPill) -> [String] { pill.lines.map { ($0.line.native as! PlazaStubText).text } }

    func testPillsStackCountdownBannerHintInOrder() async throws {
        let (p, _) = panel(countdown: "단체 사진 5", banner: "배너", hint: "안내 한 줄")
        let (size, pills) = p.stack(in: window, scale: 2, text: text)
        XCTAssertEqual(pills.map(\.style.stroke), [PlazaPanelStyle.countdown.stroke, PlazaPanelStyle.banner.stroke, PlazaPanelStyle.hint.stroke])
        XCTAssertEqual(pills.map(texts), [["단체 사진 5"], ["배너"], ["안내 한 줄"]])
        // countdown 7 × 9 + 28 = 91 by 15 + 16; banner 360 by 31; hint 6 × 9 + 24 = 78 by 15 + 12; 8 apart, centred.
        XCTAssertEqual(pills.map(\.frame), [CGRect(x: 134.5, y: 0, width: 91, height: 31), CGRect(x: 0, y: 39, width: 360, height: 31),
                                            CGRect(x: 141, y: 78, width: 78, height: 27)])
        XCTAssertEqual(size, CGSize(width: 360, height: 105))
        XCTAssertEqual(p.size(in: window, scale: 2, text: text), CGSize(width: 362, height: 107), "1 point of stroke room around")
        XCTAssertEqual(p.stack(in: window, scale: 1, text: text).pills[0].frame.minX, 135, "on whole pixels at 1x")

        // Drawn in that order, each as fill, text, stroke; CoreGraphics' y runs up from the image's bottom.
        let graphics = CanvasKeepingGraphics()
        XCTAssertNotNil(p.render(scale: 2, viewport: window, graphics: graphics))
        let calls = try XCTUnwrap(graphics.canvases.first).calls
        XCTAssertEqual(calls.first, "scale 2.0 2.0")
        let drawn = calls.filter { $0.hasPrefix("fillRoundedRect") || $0.hasPrefix("line") || $0.hasPrefix("strokeRoundedRect") }
        XCTAssertEqual(drawn, [
            "fillRoundedRect (135.5, 75.0, 91.0, 31.0) 8.0", "line \"단체 사진 5\" at 149.5 86.0", "strokeRoundedRect (135.5, 75.0, 91.0, 31.0) 8.0 2.0",
            "fillRoundedRect (1.0, 36.0, 360.0, 31.0) 8.0", "line \"배너\" at 172.0 47.0", "strokeRoundedRect (1.0, 36.0, 360.0, 31.0) 8.0 2.0",
            "fillRoundedRect (142.0, 1.0, 78.0, 27.0) 6.0", "line \"안내 한 줄\" at 154.0 10.0", "strokeRoundedRect (142.0, 1.0, 78.0, 27.0) 6.0 1.5",
        ])
        XCTAssertEqual(graphics.canvases.first.map { [$0.width, $0.height] }, [724, 214])
    }

    /// The banner is always 360 wide (`.frame(maxWidth: 360)` in a wider window) and wraps inside its 14-point padding:
    /// at spaces, and a word longer than a line between characters.
    func testBannerWrapsAt360Points() async {
        let short = panel(banner: "짧은 배너").0.stack(in: CGSize(width: 600, height: 372), scale: 2, text: text).pills[0]
        XCTAssertEqual(short.frame.size, CGSize(width: 360, height: 31))
        XCTAssertEqual(short.lines.first?.at, CGPoint(x: 14 + (332.0 - 45) / 2, y: 8 + 12), "centred")

        // 20 four-character words: 7 fit in 332 points (34 characters, 306), the 8th would not (39, 351).
        let words = Array(repeating: "가나다라", count: 20).joined(separator: " ")
        let long = panel(banner: words).0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(long.lines.map { ($0.line.native as! PlazaStubText).text.split(separator: " ").count }, [7, 7, 6])
        XCTAssertTrue(long.lines.allSatisfy { $0.line.width <= 332 })
        XCTAssertEqual(long.frame.size, CGSize(width: 360, height: 3 * 15 + 16))
        XCTAssertEqual(long.lines.map(\.at.y), [20, 35, 50], "one line height apart")

        let word = String(repeating: "가", count: 50)
        let broken = panel(banner: "📢 " + word).0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(broken.lines.map { ($0.line.native as! PlazaStubText).text.count }, [1, 36, 14],
                       "the long word starts a line of its own, 36 characters fill a line")
    }

    /// The hint and the countdown stay one line (`lineLimit(1)`): cut with "…" to the window's width less the padding.
    func testHintIsOneLine() async {
        let long = String(repeating: "가", count: 100)
        let narrow = CGSize(width: 600, height: 372)
        let hint = panel(hint: long).0.stack(in: narrow, scale: 2, text: text).pills[0]
        XCTAssertEqual(hint.lines.count, 1)
        XCTAssertEqual(texts(hint), [String(repeating: "가", count: 63) + "…"], "576 points: 63 characters and the ellipsis")
        XCTAssertEqual(hint.frame.size, CGSize(width: 600, height: 27))
        let countdown = panel(countdown: long).0.stack(in: narrow, scale: 2, text: text).pills[0]
        XCTAssertEqual(texts(countdown), [String(repeating: "가", count: 62) + "…"], "572 points: 62 and the ellipsis")
        XCTAssertEqual(countdown.frame.size, CGSize(width: 63 * 9 + 28, height: 31))
        let fits = panel(hint: "스페이스바를 눌러 소식판 보기").0.stack(in: narrow, scale: 2, text: text).pills[0]
        XCTAssertEqual(texts(fits), ["스페이스바를 눌러 소식판 보기"], "a hint that fits is not cut")
    }

    func testNothingToShowIsInvisible() async {
        let (p, model) = panel()
        XCTAssertFalse(p.isVisible)
        model.banner = "배너"
        XCTAssertTrue(p.isVisible)
        model.banner = nil
        model.countdown = "단체 사진 3"
        XCTAssertTrue(p.isVisible)
    }

    /// What the window already rendered (the model written before it opened) is not rendered again when the model's
    /// change arrives; showing the same text again after it was hidden is a change.
    func testWhatIsAlreadyShownIsNotRenderedAgain() async {
        let (p, model) = panel()
        model.hint = "안내"
        let hud = PlazaHUD(panels: [p], graphics: PlazaStubGraphics(log: { _ in }))
        let host = RecordingPanelHost()
        hud.setViewport(window, scale: 2)
        hud.host = host
        XCTAssertEqual(hud.renderCount, 1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(hud.renderCount, 1, "the pending change is what was rendered")
        model.hint = "안내"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(hud.renderCount, 1, "the same text again")
        model.hint = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(host.take().last, .hide(.pills))
        model.hint = "안내"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(hud.renderCount, 2, "shown again")
        XCTAssertNotNil(host.images[.pills])
    }

    /// The panel follows the model itself (as the SwiftUI view did): one change report per turn, however many writes.
    func testThePanelFollowsItsModel() async {
        let (p, model) = panel()
        var changes = 0
        p.onChange = { changes += 1 }
        model.banner = "배너"
        model.hint = "안내"
        model.countdown = "단체 사진 5"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changes, 1)
        model.hint = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changes, 2, "and keeps following")
        model.content = .board
        model.isPhotoMode = true
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changes, 2, "the rest of the model is not the pills'")
    }
}
