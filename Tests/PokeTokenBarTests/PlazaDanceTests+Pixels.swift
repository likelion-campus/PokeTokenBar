import XCTest
@testable import PokeTokenBar

extension PlazaDanceTests {

    func testNotesAreTheLolStyleBubbleAtTheGreetingSize() async throws {
        let s = scene()
        press(s)
        run(s, dt)
        let frame = try XCTUnwrap(s.emoteFrame(memberID: nil))
        XCTAssertEqual(frame.size, PlazaEmoteArt.size(large: true))
        XCTAssertNotEqual(PlazaEmoteArt.image(.dance, scale: 2, large: true).pixels.bytes,
                          PlazaEmoteArt.image(.lol, scale: 2, large: true).pixels.bytes)
    }

    // MARK: 화면의 노드

    private func plain(_ r: Double, _ g: Double, _ b: Double) -> PlazaFrame {
        PlazaFrame(image: solid(32, 48, r: r, g: g, b: b), delay: 1)
    }

    func testSpinAndTwirlTurnToTheBackFrameAndComeBack() async throws {
        let front = plain(1, 0, 0), back = plain(0, 0, 1)
        let s = scene()
        s.setCharacter(PlazaCharacterFrames(front: [front], back: [back]))
        s.pickDanceStyle = { _ in .spin }
        wall = grid
        press(s)
        func shown() throws -> PlazaImage { try XCTUnwrap(s.photoInput()?.actors.first).image }
        XCTAssertTrue(try shown() === front.image, "tick 0")
        run(s, 0.8)   // tick 8: the back
        XCTAssertTrue(try shown() === back.image)
        run(s, 0.8)   // the next round starts at once
        XCTAssertTrue(s.isDancing(memberID: nil))
        XCTAssertTrue(try shown() === front.image, "facing front again")
        wall += PlazaDance.beat
        s.pickDanceStyle = { _ in .twirl }
        press(s)
        run(s, 0.2)   // tick 2 of the next round: the back
        XCTAssertTrue(try shown() === back.image)
    }

    // MARK: 사진 합성

    private func solid(_ w: Int, _ h: Int, r: Double, g: Double, b: Double) -> PlazaImage {
        var bitmap = PlazaBitmap(width: w, height: h)
        let px = PlazaRGBA(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()), b: UInt8((b * 255).rounded()), a: 255)
        for y in 0..<h { for x in 0..<w { bitmap[x, y] = px } }
        return PlazaImage(bitmap: bitmap)
    }

    private func redness(_ img: PlazaBitmap, _ x: Int, _ y: Int) -> Bool {
        let p = img[x, y]
        return p.r > 200 && p.g < 60
    }

    private func render(lift: CGFloat = 0, squash: CGFloat = 1, tilt: CGFloat = 0) throws -> PlazaBitmap {
        var a = PlazaPhotoActor(image: solid(10, 20, r: 1, g: 0, b: 0), flipped: false, foot: CGPoint(x: 50, y: 60), scale: 1,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        a.lift = lift; a.squash = squash; a.tilt = tilt
        let input = PlazaPhotoInput(mapImage: solid(100, 100, r: 0, g: 0.6, b: 0), visibleRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    pixelsPerWorld: 1, actors: [a])
        return try XCTUnwrap(PlazaPhotoRenderer.renderBitmap(input))
    }

    func testTheRendererDrawsASquashedDancerShorter() async throws {
        let plain = try render()
        XCTAssertTrue(redness(plain, 50, 60 - 18), "20 tall: reaches row 42")
        let squashed = try render(squash: 0.5)
        XCTAssertTrue(redness(squashed, 50, 60 - 8), "10 tall")
        XCTAssertFalse(redness(squashed, 50, 60 - 14), "the top is lower than the plain one")
        let tall = try render(squash: 1.5)
        XCTAssertTrue(redness(tall, 50, 60 - 28), "30 tall")
    }

    func testTheRendererTiltsADancerOnItsFeet() async throws {
        let tilted = try render(tilt: .pi / 2)   // 반시계 90도: 위로 선 몸이 왼쪽으로 눕는다
        XCTAssertTrue(redness(tilted, 50 - 12, 59), "the body lies to the left of the feet")
        XCTAssertFalse(redness(tilted, 50, 60 - 12), "nothing is left standing above")
        let upright = try render()
        XCTAssertFalse(redness(upright, 50 - 12, 59))
    }

    func testTheRendererLiftsADancerOffTheGround() async throws {
        let up = try render(lift: 10)
        XCTAssertFalse(redness(up, 50, 59), "the feet left the ground")
        XCTAssertTrue(redness(up, 50, 49))
    }

    // MARK: 안내

    func testTheShortcutGuideListsD() async {
        XCTAssertTrue(PlazaShortcutGuide.entries.contains { $0.key == "D" && $0.label == "춤" })
    }
}
