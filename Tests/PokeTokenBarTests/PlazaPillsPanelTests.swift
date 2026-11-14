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
        let drawing = p.render(scale: 2, viewport: window, graphics: graphics)
        XCTAssertEqual(drawing.layers.count, 1, "one image of the whole panel")
        XCTAssertFalse(drawing.tracksMouse)
        // One static text per pill, top to bottom, over each pill (1 point of stroke room in).
        XCTAssertEqual(drawing.accessibility, [
            PlazaAccessibilityItem(frame: CGRect(x: 135.5, y: 1, width: 91, height: 31), role: .staticText, label: "단체 사진 5"),
            PlazaAccessibilityItem(frame: CGRect(x: 1, y: 40, width: 360, height: 31), role: .staticText, label: "배너"),
            PlazaAccessibilityItem(frame: CGRect(x: 142, y: 79, width: 78, height: 27), role: .staticText, label: "안내 한 줄"),
        ])
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

    /// VoiceOver reads a cut pill's whole text, as SwiftUI's `Text` did (the cut is only drawn).
    func testACutPillIsReadWhole() async {
        let long = String(repeating: "가", count: 100)
        let drawing = panel(hint: long).0.render(scale: 2, viewport: CGSize(width: 600, height: 372), graphics: PlazaStubGraphics(log: { _ in }))
        XCTAssertEqual(drawing.accessibility.map(\.label), [long])
    }

    /// The banner is wrapped once per render: the HUD's size, the render and the overlay's menu room share one layout.
    func testTheBannerIsLaidOutOncePerRender() async {
        let text = CountingTextEngine()
        let graphics = CountingGraphics(text: text)
        let (p, model) = panel(banner: "가나다라 " + String(repeating: "마바사 ", count: 30))
        let hud = PlazaHUD(panels: [p], graphics: graphics)
        hud.setViewport(window, scale: 2)
        let host = RecordingPanelHost()   // the HUD holds its host weakly: keep it alive
        hud.host = host
        XCTAssertEqual(hud.renderCount, 1)
        XCTAssertEqual(text.wrapped, 1, "one wrap for size and render")
        _ = p.stack(in: window, scale: 2, text: text)
        XCTAssertEqual(text.wrapped, 1, "the overlay's menu room reuses it")
        hud.setViewport(CGSize(width: 1000, height: 700), scale: 2)
        XCTAssertEqual(text.wrapped, 2, "a new width lays out again (a one-line pill may cut differently)")
        model.banner = "다른 배너"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(text.wrapped, 3)
    }

    /// Joined emoji (a family, a flag, a skin tone) are one character each: wrapping never splits one.
    func testJoinedEmojiStayWhole() async {
        let family = "👨‍👩‍👧‍👦", flag = "🇰🇷", thumb = "👍🏽"
        let banner = panel(banner: String(repeating: family + flag + thumb, count: 20)).0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(banner.lines.map { ($0.line.native as! PlazaStubText).text.count }, [36, 24], "60 characters: 36 fill a line")
        XCTAssertEqual(banner.lines.map { ($0.line.native as! PlazaStubText).text }.joined(), String(repeating: family + flag + thumb, count: 20))
        let hint = panel(hint: family + flag + thumb).0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(hint.frame.width, 3 * 9 + 24)
    }

    /// Inputs no caller can produce (every hint, banner and countdown is a non-empty one-line string: nicknames are
    /// rejected with a line break by `TeamSettings.validNickname`, chat lines lose theirs in `TeamChat.prepared`), pinned
    /// so a change is seen: an empty text keeps one line's height (SwiftUI's empty `Text` was 14 points, not 18); a
    /// one-line pill stays one line whatever its text holds.
    func testInputsNoCallerProduces() async {
        let empty = panel(hint: "").0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(empty.frame.size, CGSize(width: 24, height: 27))
        let newline = panel(countdown: "첫 줄\n둘째 줄").0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(newline.lines.count, 1)
        let emptyBanner = panel(banner: "").0.stack(in: window, scale: 2, text: text).pills[0]
        XCTAssertEqual(emptyBanner.lines.count, 1)
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

/// The stub text engine, counting how often it wraps.
final class CountingTextEngine: PlazaTextEngine, @unchecked Sendable {
    private let base = PlazaStubTextEngine()
    private(set) var wrapped = 0
    func metrics(_ font: PlazaFont) -> PlazaFontMetrics { base.metrics(font) }
    func line(_ text: String, font: PlazaFont) -> PlazaTextLine { base.line(text, font: font) }
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? {
        base.truncated(line, width: width, ellipsis: ellipsis)
    }
    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph {
        base.paragraph(text, font: font, alignment: alignment)
    }
    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine] {
        wrapped += 1
        return base.wrappedLines(text, font: font, width: width)
    }
    func line(_ runs: [PlazaTextRun]) -> PlazaTextLine { base.line(runs) }
    func wrappedLines(_ runs: [PlazaTextRun], width: CGFloat) -> [PlazaTextLine] {
        wrapped += 1
        return base.wrappedLines(runs, width: width)
    }
}

/// The stub graphics with a given text engine.
struct CountingGraphics: PlazaGraphics {
    let text: any PlazaTextEngine
    private let base = PlazaStubGraphics(log: { _ in })
    init(text: any PlazaTextEngine) { self.text = text }
    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
        base.makeCanvas(width: width, height: height, colorSpace: colorSpace)
    }
    func assetURL(_ name: String, ext: String) -> URL? { nil }
    func decodeImage(at url: URL) -> PlazaImage? { nil }
    func decodeImage(_ data: Data) -> PlazaImage? { nil }
    func decodeImageFrames(at url: URL) -> [PlazaImage] { [] }
    func encodePNG(_ image: PlazaImage) -> Data? { nil }
}
