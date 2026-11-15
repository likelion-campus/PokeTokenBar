import XCTest
@testable import PokeTokenBar

/// Texts added to the parity corpus on both OSes (stage 6, Task 9): a long Korean chat line at both sizes, Korean with Latin
/// and digits (TextKit breaks `3번` between the digit and the syllable), a Korean name with a version number, Korean with
/// emoji. The numbers were measured on the Mac with TextKit (`CoreTextPlazaEngine.breaks`) and CTFramesetter and are pinned
/// here; `PlazaTextFrameTests+Mac` re-measures them, `WindowsPlazaTextTests` compares DirectWrite's line by line. This
/// suite runs with the platform's own engine (`PlatformPlaza.graphics.text`); the stub engine (the shared-only build) skips.
final class PlazaTextEngineParityTests: XCTestCase {
    struct Case {
        let text: String
        let size: PlazaTextSize
        let width: CGFloat
        let kit: [Int]            // TextKit's line ranges, UTF-16: lo, hi, lo, hi …
        let suggested: CGSize     // CTFramesetterSuggestFrameSizeWithConstraints, centred, the bubble's 8-line limit
        let lineWidth: CGFloat    // the whole text as one CTLine
        let hasEmoji: Bool        // Apple Color Emoji's advances: compared on the Mac only
    }

    static let cases: [Case] = [
        Case(text: "오늘 광장에서 같이 산책하실 분 계신가요 저는 지금 모닥불 옆에 있어요", size: .small, width: 120,
             kit: [0, 10, 11, 22, 23, 32, 33, 39], suggested: CGSize(width: 118, height: 63), lineWidth: 398, hasEmoji: false),
        Case(text: "오늘 광장에서 같이 산책하실 분 계신가요 저는 지금 모닥불 옆에 있어요", size: .body, width: 216,
             kit: [0, 15, 16, 32, 33, 39], suggested: CGSize(width: 204, height: 60), lineWidth: 495, hasEmoji: false),
        Case(text: "레벨 25 피카츄가 3번 이겼어요 ok 다음엔 10번!", size: .body, width: 80,
             kit: [0, 5, 6, 12, 12, 13, 14, 18, 19, 25, 26, 30], suggested: CGSize(width: 77, height: 102), lineWidth: 337, hasEmoji: false),
        Case(text: "도토리묵 Lv.12 앞으로 가요", size: .small, width: 40,
             kit: [0, 3, 3, 4, 5, 10, 11, 14, 15, 17], suggested: CGSize(width: 36, height: 79), lineWidth: 155, hasEmoji: false),
        Case(text: "안녕 🔥 반가워 🔥🔥 또 봐요", size: .body, width: 80,
             kit: [0, 5, 6, 12, 12, 19], suggested: CGSize(width: 77, height: 74), lineWidth: 210, hasEmoji: true),
    ]

    /// Name plates and bubbles rendered on both OSes for the report (Latin, Hangul, emoji, a title, a cut name; a wrapped
    /// chat line, 60 characters, mixed, short).
    static let plates: [(text: String, title: String?)] = [
        ("Name", nil), ("도토리", nil), ("🔥🔥", nil), ("도토리", "수줍은"), ("민트Mint", "Shy"), (String(repeating: "W", count: 200), nil),
    ]
    static let bubbles = [
        "이 포켓몬은 불꽃 타입이라서 물 근처에서는 조심해야 해요", String(repeating: "가", count: 60),
        "Mix 한글과 English와 🔥 emoji 가 섞인 60자 가까이 되는 긴 대화 한 줄입니다 정말로요요요", "안녕",
    ]
    static let chatTexts = ["안녕하세요!", "오늘 광장에서 같이 산책하실 분 계신가요 저는 지금 모닥불 옆에 있어요", "ok 🔥", "레벨 25 피카츄가 3번 이겼어요"]

    /// Chat log line `i` as the panel draws it (time, name, text runs); sample data.
    @MainActor static func chatRuns(_ i: Int, name: String) -> [PlazaTextRun] {
        PlazaChatLogPanel.runs(PlazaChatLog.Line(id: i, time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60), name: name,
                                                 text: chatTexts[i % chatTexts.count], color: PlazaNameColor.palette[i % PlazaNameColor.palette.count]))
    }

    func testTheAddedTextsMeasureAsOnTheMac() throws {
        let engine = PlatformPlaza.graphics.text
        guard !(engine is PlazaStubTextEngine) else { throw XCTSkip("the stub engine measures monospace") }
        for c in Self.cases where !c.hasEmoji {
            let font = PlazaFont.plaza(c.size)
            XCTAssertEqual(engine.wrappedLines(c.text, font: font, width: c.width).count, c.kit.count / 2, c.text)
            XCTAssertEqual(engine.line(c.text, font: font).width, c.lineWidth, c.text)
            let m = engine.metrics(font)
            let limit = CGSize(width: c.width, height: ((m.ascender - m.descender + m.leading) * 8).rounded(.up))
            XCTAssertEqual(engine.paragraph(c.text, font: font, alignment: .center).suggestedSize(limit: limit), c.suggested, c.text)
        }
    }
}
