// PlazaEmoteTests+Mac: the SwiftUI shortcut guide and CGImage pixel reads of the emote art
import XCTest
import SwiftUI
import AppKit
@testable import PokeTokenBar

extension PlazaEmoteTests {
    /// The top-left guide lists every key the plaza answers to.
    func testShortcutGuideListsEveryKey() async {
        XCTAssertEqual(PlazaShortcutGuide.entries.map(\.key),
                       ["방향키", "Shift", "Space", "Enter", "1–5", "Z", "X", "C", "V", "D", "F", "P", "G", "A", "−/+"])
        XCTAssertEqual(PlazaShortcutGuide.entries.map(\.label),
                       ["걷기", "달리기", "말 걸기", "한마디", "말풍선", "점프 · 물놀이", "인사하기", "몸통박치기", "눈뭉치", "춤", "불꽃놀이", "사진 모드", "단체 사진", "기도(알)", "확대·축소"])
    }

    /// On snow days the guide gains a V row right after C.
    func testShortcutGuideAddsVOnSnowDays() async {
        let snow = PlazaShortcutGuide.entries
        let at = snow.firstIndex { $0.key == "C" }! + 1
        XCTAssertEqual(snow[at].key, "V")
        XCTAssertEqual(snow[at].label, "눈뭉치")
        XCTAssertEqual(Set(snow.map(\.key)).count, snow.count)
        for (season, label) in [(PlazaSeason.spring, "꽃잎 뭉치"), (.summer, "물풍선"), (.autumn, "낙엽 뭉치"), (.winter, "눈뭉치")] {
            let rows = PlazaShortcutGuide.entries(season: season)
            XCTAssertEqual(rows.map(\.key), snow.map(\.key), "the same keys in every season")
            XCTAssertEqual(rows[at].label, label)
        }
    }

    /// The guide's rows are identified by key, so a repeated key would draw the first row twice.
    func testShortcutGuideKeysAreUnique() async {
        let keys = PlazaShortcutGuide.entries.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "repeated keys: \(keys)")
    }

    /// Folded, the guide is only its title line; unfolded it shows every key.
    func testFoldedShortcutGuideIsOnlyTheTitle() async throws {
        func height(folded: Bool) throws -> CGFloat {
            let model = PlazaShortcutGuideModel()
            model.isFolded = folded
            let r = ImageRenderer(content: PlazaShortcutGuide(model: model, toggle: {}))
            return try XCTUnwrap(r.nsImage).size.height
        }
        let folded = try height(folded: true), open = try height(folded: false)
        XCTAssertLessThan(folded, 40, "one line")
        XCTAssertGreaterThan(open, folded + CGFloat(PlazaShortcutGuide.entries.count) * 16)
    }

    func testEachEmoteHasArt() async {
        var pixels: [Data] = []
        // The decoy kinds and the pull are protocol messages, never bubbles; a new kind must be listed on purpose.
        let decoyKinds: [TeamEmoteKind] = [.decoyFound, .decoyJump, .decoyTackle, .pull, .snowball, .mimicTackle, .mimicFound]
        let bubbleKinds: [TeamEmoteKind] = [.heart, .lol, .party, .exclaim, .question, .tackle, .jump, .groupPhoto, .pickup,
                                            .firework, .dance, .pray]
        XCTAssertEqual(Set(bubbleKinds + decoyKinds), Set(TeamEmoteKind.allCases), "every kind is sorted into bubble or message")
        for kind in bubbleKinds {
            let one = PlazaEmoteArt.image(kind, scale: 1)
            let two = PlazaEmoteArt.image(kind, scale: 2)
            XCTAssertGreaterThan(one.width, 0)
            XCTAssertEqual(two.width, one.width * 2, "\(kind)")
            XCTAssertEqual(two.height, one.height * 2, "\(kind)")
            let data = one.cgImage.dataProvider?.data as Data? ?? Data()
            XCTAssertTrue(data.contains { $0 != 0 }, "\(kind) draws something")
            pixels.append(data)
        }
        XCTAssertEqual(Set(pixels).count, bubbleKinds.count, "every kind looks different")
        XCTAssertEqual(L(.ko).plazaEmoteLol, "ㅋㅋ")
    }

    /// The greeting bubble is the same art with 3-point dots: exactly 1.5 times as big, and every dot is still a
    /// whole block of one colour. The content sits half a dot off the bubble grid, so compare at 2x, where half a
    /// dot is 2 pixels in the normal bubble and 3 in the large one.
    func testGreetingBubbleIsTheSameArtOneAndAHalfTimesAsBig() async {
        func pixels(_ image: CGImage) -> [UInt8] {
            var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return raw
        }
        XCTAssertEqual(PlazaEmoteArt.size(large: true).width, PlazaEmoteArt.size.width * 1.5)
        XCTAssertEqual(PlazaEmoteArt.size(large: true).height, PlazaEmoteArt.size.height * 1.5)
        for kind in [TeamEmoteKind.heart, .party, .exclaim, .question] {
            let small = PlazaEmoteArt.image(kind, scale: 2), large = PlazaEmoteArt.image(kind, scale: 2, large: true)
            XCTAssertEqual(large.width * 2, small.width * 3, "\(kind)")
            let s = pixels(small.cgImage), l = pixels(large.cgImage)
            // Half-dot blocks: 3x3 pixels in the large bubble map to 2x2 in the normal one.
            var same = true
            for y in 0..<(large.height) where same {
                for x in 0..<(large.width) {
                    let li = (y * large.width + x) * 4, si = ((y / 3 * 2) * small.width + x / 3 * 2) * 4
                    if l[li..<li + 4] != s[si..<si + 4] { same = false; break }
                }
            }
            XCTAssertTrue(same, "\(kind) is the same dots, only bigger")
        }
    }

    /// Reads the bubble's inside (the cells clear of border and tail) as ink/white pixels at 1 px per point.
    private func interiorInk(_ kind: TeamEmoteKind) -> (ink: Set<[Int]>, onlyInkAndWhite: Bool) {
        let image = PlazaEmoteArt.image(kind, scale: 1).cgImage
        var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var ink = Set<[Int]>()
        var clean = true
        for y in 2..<20 {          // buffer row 0 is the top
            for x in 4..<24 {
                let i = (y * image.width + x) * 4
                let rgb = (Int(raw[i]), Int(raw[i + 1]), Int(raw[i + 2]))
                if rgb == (255, 255, 255) { continue }
                if rgb == (0x14, 0x16, 0x1F), raw[i + 3] == 255 { ink.insert([x, y]) } else { clean = false }
            }
        }
        return (ink, clean)
    }
}

extension PlazaEmoteTests {
    func testExclaimAndQuestionAreDotGridsLikeTheHeart() async {
        for kind in [TeamEmoteKind.exclaim, .question] {
            let (ink, clean) = interiorInk(kind)
            XCTAssertTrue(clean, "\(kind): only whole ink or white dots, no smoothed font edge")
            XCTAssertFalse(ink.isEmpty, "\(kind)")
            let xs = ink.map { $0[0] }
            XCTAssertEqual(xs.min()! + xs.max()!, 27, "\(kind) is centred in the 28 px bubble")
            XCTAssertEqual(xs.min()! % 2, 0, "\(kind) sits on the 2 px dot grid")
            for y in Set(ink.map { $0[1] }) {
                let row = ink.filter { $0[1] == y }.map { $0[0] }.sorted()
                var runs: [Int] = [], length = 1
                for (a, b) in zip(row, row.dropFirst()) { if b == a + 1 { length += 1 } else { runs.append(length); length = 1 } }
                runs.append(length)
                XCTAssertTrue(runs.allSatisfy { $0 >= 4 && $0 % 2 == 0 }, "\(kind) strokes are whole 2-cell wide dots (row \(y): \(runs))")
            }
        }
    }
}
