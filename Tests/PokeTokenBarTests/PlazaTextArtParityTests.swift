import XCTest
@testable import PokeTokenBar

/// Legacy oracles (D5) for the art that draws text: the name plate, the chat bubble and the emote art give the Mac the
/// very bytes the CoreGraphics/CoreText originals gave it. Every case compares size, pixel format, colour space and
/// every data-provider byte.
final class PlazaTextArtParityTests: XCTestCase {
    private let scales: [CGFloat] = [1, 2, 3]

    private let names = [
        "", "나", "Name", "도토리", "Zoe", "민트Mint", "🔥🔥", "👨‍👩‍👧‍👦 가족", "WWWWWWWWWWWW",
        "아주긴닉네임입니다요아주긴닉네임입니다요",
        String(repeating: "W", count: 200),                                  // far wider than the plate: truncation
        String(repeating: "가", count: 300),
        String(repeating: "🔥", count: 120),
        "a" + String(repeating: "\u{0301}", count: 400),                      // one Character, thousands of points
    ]
    private let titles: [String?] = [nil, "수줍은", "무사태평한", "", "Shy", "🔥"]

    func testNamePlateIsByteIdentical() {
        var colors = PlazaNameColor.palette
        colors.append(PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        colors.append(PlazaColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.5))
        var cases = 0
        for (n, name) in names.enumerated() {
            for title in titles {
                for scale in scales {
                    // every colour on the short names, one colour per long name (the long ones cost the most)
                    let picks = n < 7 ? colors : [colors[n % colors.count]]
                    for color in picks {
                        let legacy = LegacyPlazaNamePlate.image(text: name, title: title, color: color, scale: scale)
                        let new = PlazaNamePlate.image(text: name, title: title, color: color, scale: scale)
                        XCTAssertEqual(legacy == nil, new == nil, "\(name.prefix(8)) \(title ?? "-") @\(scale)")
                        guard let legacy, let new else { continue }
                        PlazaArtParity.assertIdentical(legacy, new, "plate \(name.prefix(8)) title \(title ?? "-") @\(scale)")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 400)
        // a scale under 1 is raised to 1 by both
        PlazaArtParity.assertIdentical(LegacyPlazaNamePlate.image(text: "Name", color: colors[0], scale: 0.5)!,
                                       PlazaNamePlate.image(text: "Name", color: colors[0], scale: 0.5)!, "plate @0.5")
    }

    private let chats = [
        "", "나", "안녕", "Hello", "hi there", "🔥🔥", "안녕하세요 반갑습니다 😀",
        String(repeating: "가", count: 60),
        String(repeating: "Lorem ipsum dolor sit amet ", count: 3),
        "Mix 한글과 English와 🔥 emoji 가 섞인 60자 가까이 되는 긴 대화 한 줄입니다 정말로요요요",
        String(repeating: "가", count: 400),                                   // beyond maxLines: the tail is dropped
        String(repeating: "🔥", count: 200),
        String(repeating: "word ", count: 120),
        "줄\n바꿈\n\n있는 글",
    ]

    func testChatBubbleIsByteIdentical() {
        for text in chats {
            for scale in scales {
                let legacy = LegacyPlazaChatBubble.image(text: text, scale: scale)
                let new = PlazaChatBubble.image(text: text, scale: scale)
                XCTAssertEqual(legacy == nil, new == nil, "\(text.prefix(8)) @\(scale)")
                guard let legacy, let new else { continue }
                PlazaArtParity.assertIdentical(legacy, new, "bubble \(text.prefix(8)) @\(scale)")
            }
        }
        PlazaArtParity.assertIdentical(LegacyPlazaChatBubble.image(text: "안녕", scale: 0.5)!,
                                       PlazaChatBubble.image(text: "안녕", scale: 0.5)!, "bubble @0.5")
    }

    func testChatBubbleDrawnLengthMatches() {
        for text in chats {
            XCTAssertEqual(PlazaChatBubble.drawnLength(of: text), LegacyPlazaChatBubble.drawnLength(of: text), "\(text.prefix(8))")
        }
        XCTAssertEqual(PlazaChatBubble.maxSize, LegacyPlazaChatBubble.maxSize)
    }

    func testEmoteArtIsByteIdentical() {
        for kind in TeamEmoteKind.allCases {
            for scale in scales {
                for large in [false, true] {
                    PlazaArtParity.assertIdentical(LegacyPlazaEmoteArt.image(kind, scale: scale, large: large),
                                                   PlazaEmoteArt.image(kind, scale: scale, large: large),
                                                   "emote \(kind) @\(scale) large \(large)")
                }
            }
        }
        for scale in scales + [8] {
            PlazaArtParity.assertIdentical(LegacyPlazaEmoteArt.impactImage(scale: scale), PlazaEmoteArt.impactImage(scale: scale), "impact @\(scale)")
            PlazaArtParity.assertIdentical(LegacyPlazaEmoteArt.dustImage(scale: scale), PlazaEmoteArt.dustImage(scale: scale), "dust @\(scale)")
            PlazaArtParity.assertIdentical(LegacyPlazaEmoteArt.sparkImage(scale: scale), PlazaEmoteArt.sparkImage(scale: scale), "spark @\(scale)")
            for kind in ItemKind.allCases {
                PlazaArtParity.assertIdentical(LegacyPlazaEmoteArt.itemImage(kind, scale: scale), PlazaEmoteArt.itemImage(kind, scale: scale),
                                               "item \(kind) @\(scale)")
            }
        }
        XCTAssertEqual(PlazaEmoteArt.size(large: true), LegacyPlazaEmoteArt.size(large: true))
    }
}
