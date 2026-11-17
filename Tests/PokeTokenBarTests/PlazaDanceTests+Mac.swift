import XCTest
import AppKit
import CoreGraphics
@testable import PokeTokenBar

extension PlazaDanceTests {

    func testNotesAreTheLolStyleBubbleAtTheGreetingSize() throws {
        let s = scene()
        press(s)
        run(s, dt)
        let frame = try XCTUnwrap(s.emoteFrame(memberID: nil))
        XCTAssertEqual(frame.size, PlazaEmoteArt.size(large: true))
        XCTAssertNotEqual(PlazaEmoteArt.image(.dance, scale: 2, large: true).cgImage.dataProvider?.data as Data?,
                          PlazaEmoteArt.image(.lol, scale: 2, large: true).cgImage.dataProvider?.data as Data?)
    }

    // MARK: 화면의 노드

    private func plain(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlazaFrame {
        PlazaFrame(image: PlazaImage(cgImage: solid(32, 48, r: r, g: g, b: b)), delay: 1)
    }

    func testSpinAndTwirlTurnToTheBackFrameAndComeBack() throws {
        let front = plain(1, 0, 0), back = plain(0, 0, 1)
        let s = scene()
        s.setCharacter(PlazaCharacterFrames(front: [front], back: [back]))
        s.pickDanceStyle = { _ in .spin }
        wall = grid
        press(s)
        func shown() throws -> CGImage { try XCTUnwrap(s.photoInput()?.actors.first).image.cgImage }
        XCTAssertTrue(try shown() === front.image.cgImage, "tick 0")
        run(s, 0.8)   // tick 8: the back
        XCTAssertTrue(try shown() === back.image.cgImage)
        run(s, 0.8)   // the next round starts at once
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertTrue(try shown() === front.image.cgImage, "facing front again")
        wall += PlazaDance.beat
        s.pickDanceStyle = { _ in .twirl }
        press(s)
        run(s, 0.2)   // tick 2 of the next round: the back
        XCTAssertTrue(try shown() === back.image.cgImage)
    }

    // MARK: 사진 합성

    private func solid(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func redness(_ img: CGImage, _ x: Int, _ y: Int) -> Bool {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let o = (y * img.width + x) * 4
        return d[o] > 200 && d[o + 1] < 60
    }

    private func render(lift: CGFloat = 0, squash: CGFloat = 1, tilt: CGFloat = 0) throws -> CGImage {
        var a = PlazaPhotoActor(image: PlazaImage(cgImage: solid(10, 20, r: 1, g: 0, b: 0)), flipped: false, foot: CGPoint(x: 50, y: 60), scale: 1,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        a.lift = lift; a.squash = squash; a.tilt = tilt
        let input = PlazaPhotoInput(mapImage: PlazaImage(cgImage: solid(100, 100, r: 0, g: 0.6, b: 0)), visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    pixelsPerWorld: 1, actors: [a])
        return try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
    }

    func testTheRendererDrawsASquashedDancerShorter() throws {
        let plain = try render()
        XCTAssertTrue(redness(plain, 50, 60 - 18), "20 tall: reaches row 42")
        let squashed = try render(squash: 0.5)
        XCTAssertTrue(redness(squashed, 50, 60 - 8), "10 tall")
        XCTAssertFalse(redness(squashed, 50, 60 - 14), "the top is lower than the plain one")
        let tall = try render(squash: 1.5)
        XCTAssertTrue(redness(tall, 50, 60 - 28), "30 tall")
    }

    func testTheRendererTiltsADancerOnItsFeet() throws {
        let tilted = try render(tilt: .pi / 2)   // 반시계 90도: 위로 선 몸이 왼쪽으로 눕는다
        XCTAssertTrue(redness(tilted, 50 - 12, 59), "the body lies to the left of the feet")
        XCTAssertFalse(redness(tilted, 50, 60 - 12), "nothing is left standing above")
        let upright = try render()
        XCTAssertFalse(redness(upright, 50 - 12, 59))
    }

    func testTheRendererLiftsADancerOffTheGround() throws {
        let up = try render(lift: 10)
        XCTAssertFalse(redness(up, 50, 59), "the feet left the ground")
        XCTAssertTrue(redness(up, 50, 49))
    }

    // MARK: 안내

    func testTheShortcutGuideListsD() {
        XCTAssertTrue(PlazaShortcutGuide.entries.contains { $0.key == "D" && $0.label == "춤" })
    }
}
