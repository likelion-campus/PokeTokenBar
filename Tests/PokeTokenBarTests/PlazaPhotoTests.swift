import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
private let photoKey: UInt16 = 35

private func image(_ w: Int, _ h: Int, _ color: (Int, Int) -> RGBA) -> CGImage {
    var data = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let c = color(x, y)
            let o = (y * w + x) * 4
            // 미리 곱한 색으로 저장한다.
            let a = Int(c.a)
            data[o] = UInt8(Int(c.r) * a / 255); data[o + 1] = UInt8(Int(c.g) * a / 255)
            data[o + 2] = UInt8(Int(c.b) * a / 255); data[o + 3] = c.a
        }
    }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

private func solid(_ w: Int, _ h: Int, _ c: RGBA) -> CGImage { image(w, h) { _, _ in c } }

/// 위에서 아래로 읽은 픽셀(맨 윗줄이 0번).
private struct Pixels {
    let width: Int, height: Int
    private let data: [UInt8]
    init(_ img: CGImage) {
        width = img.width; height = img.height
        var d = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &d, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = d
    }
    subscript(x: Int, y: Int) -> RGBA {
        let o = (y * width + x) * 4
        return (data[o], data[o + 1], data[o + 2], data[o + 3])
    }
}

private func same(_ a: RGBA, _ b: RGBA) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a }

private let red: RGBA = (255, 0, 0, 255), blue: RGBA = (0, 0, 255, 255), green: RGBA = (0, 255, 0, 255)
private let yellow: RGBA = (255, 255, 0, 255), black: RGBA = (0, 0, 0, 255), white: RGBA = (255, 255, 255, 255)

private func actor(_ img: CGImage, flipped: Bool = false, foot: CGPoint, scale: CGFloat = 1.5, bob: CGFloat = 0,
                   shadow: CGImage? = nil, shadowRect: CGRect = .zero,
                   plate: CGImage? = nil, bubble: CGImage? = nil) -> PlazaPhotoActor {
    PlazaPhotoActor(image: img, flipped: flipped, foot: foot, bob: bob, scale: scale, shadow: shadow, shadowRect: shadowRect,
                    plate: plate, bubble: bubble)
}

private func input(map: CGImage, rect: CGRect, ppw: Int, _ actors: [PlazaPhotoActor] = []) -> PlazaPhotoInput {
    PlazaPhotoInput(mapImage: map, visibleRect: rect, pixelsPerWorld: ppw, actors: actors)
}

@MainActor
final class PlazaPhotoTests: XCTestCase {
    private let map = PlazaMapData.map
    private var suites: [String] = []

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
    }

    // MARK: 합성

    func testPhotoSizeMatchesViewportAtIntegerScale() throws {
        let map = solid(64, 64, green)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 3, y: 2, width: 40, height: 30), ppw: 4)))
        XCTAssertEqual(photo.width, 160)
        XCTAssertEqual(photo.height, 120)
        let wide = try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0.5, y: 0, width: 20.5, height: 10), ppw: 6)))
        XCTAssertEqual(wide.width, 123)
    }

    func testEmptyOrNonFiniteViewIsNotRendered() {
        let map = solid(8, 8, green)
        XCTAssertNil(PlazaPhotoRenderer.render(input(map: map, rect: .zero, ppw: 4)))
        XCTAssertNil(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 8, height: 8), ppw: 0)))
        XCTAssertNil(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 8), ppw: 4)))
        XCTAssertNil(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000), ppw: 6)))
        XCTAssertNil(PlazaPhotoRenderer.pngData(for: input(map: map, rect: .zero, ppw: 4)))
    }

    func testTilesStayCrisp() throws {
        // 체크무늬 지도를 3배로 찍어도 빨강과 파랑 외의 색(섞인 경계)이 없다.
        let map = image(8, 8) { x, y in (x + y).isMultiple(of: 2) ? red : blue }
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 8, height: 8), ppw: 6)))
        let px = Pixels(photo)
        for y in 0..<px.height {
            for x in 0..<px.width {
                let p = px[x, y]
                XCTAssertTrue(same(p, red) || same(p, blue), "blended pixel at \(x),\(y): \(p)")
                if !(same(p, red) || same(p, blue)) { return }
            }
        }
    }

    func testMapAlignsToVisibleRectOrigin() throws {
        // 왼쪽 위 칸만 빨강. 보이는 영역이 (1,1)에서 시작하면 사진 왼쪽 위는 빨강이 아니다.
        let map = image(4, 4) { x, y in x == 0 && y == 0 ? red : blue }
        let a = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 2, height: 2), ppw: 4))))
        XCTAssertTrue(same(a[0, 0], red))
        XCTAssertTrue(same(a[4, 0], blue))
        let b = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 1, y: 1, width: 2, height: 2), ppw: 4))))
        XCTAssertTrue(same(b[0, 0], blue))
    }

    func testAreaOutsideMapIsFilled() throws {
        let map = solid(4, 4, red)
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: -2, y: 0, width: 6, height: 4), ppw: 2))))
        XCTAssertTrue(same(px[0, 0], (0x1E, 0x3A, 0x26, 255)), "outside the map shows the forest colour")
        XCTAssertTrue(same(px[5, 0], red))
    }

    /// 홀수 폭(5열) 스프라이트: 열마다 색이 달라 폭을 잴 수 있다.
    private func oddSprite() -> CGImage {
        let colors = [red, green, blue, yellow, white]
        return image(5, 3) { x, _ in colors[x] }
    }

    private func runs(_ px: Pixels, row: Int) -> [(color: RGBA, length: Int)] {
        var result: [(RGBA, Int)] = []
        for x in 0..<px.width {
            let p = px[x, row]
            if same(p, black) { continue }
            if let last = result.last, same(last.0, p), x > 0, !same(px[x - 1, row], black) {
                result[result.count - 1].1 += 1
            } else {
                result.append((p, 1))
            }
        }
        return result.map { (color: $0.0, length: $0.1) }
    }

    func testSpritePixelsAreWholeBlocks() throws {
        // zoom 2 → 사진 배율 4, 1.5배 포켓몬 → 도트 하나가 6픽셀. 홀수 폭이라 왼쪽 가장자리가 반 칸에 놓일 수 있다.
        let map = solid(40, 20, black)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input(
            map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4,
            [actor(oddSprite(), foot: CGPoint(x: 20.3, y: 15))])))
        let px = Pixels(photo)
        let row = (15 * 4) - 6   // 스프라이트 가운데 줄 근처(높이 3 × 6 = 18픽셀이 발 위로 선다)
        let r = runs(px, row: row)
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.map(\.length), [6, 6, 6, 6, 6])
    }

    func testSpriteSitsOnItsFootPoint() throws {
        let map = solid(40, 20, black)
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
            map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4,
            [actor(solid(4, 2, red), foot: CGPoint(x: 20, y: 15))]))))
        // 폭 4 × 6 = 24, 높이 2 × 6 = 12. 발 가운데 x = 80, 발 y = 60.
        XCTAssertTrue(same(px[68, 59], red))
        XCTAssertTrue(same(px[91, 48], red))
        XCTAssertTrue(same(px[67, 59], black))
        XCTAssertTrue(same(px[92, 59], black))
        XCTAssertTrue(same(px[80, 60], black), "the pixel row under the foot is empty")
        XCTAssertTrue(same(px[80, 47], black), "above the sprite is empty")
    }

    func testFlippedActorIsMirrored() throws {
        let map = solid(40, 20, black)
        func row(flipped: Bool) throws -> [RGBA] {
            let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4,
                [actor(oddSprite(), flipped: flipped, foot: CGPoint(x: 20, y: 15))]))))
            return runs(px, row: 50).map(\.color)
        }
        let normal = try row(flipped: false), mirrored = try row(flipped: true)
        XCTAssertEqual(normal.count, 5)
        XCTAssertEqual(mirrored.count, 5)
        for (a, b) in zip(normal, mirrored.reversed()) { XCTAssertTrue(same(a, b)) }
        XCTAssertFalse(same(normal[0], mirrored[0]))
    }

    func testLowerActorDrawsOnTop() throws {
        // 두 캐릭터가 겹친다. 발이 아래인 쪽이 위에 그려진다(배열 순서와 상관없이).
        let map = solid(40, 20, black)
        let upper = actor(solid(6, 4, red), foot: CGPoint(x: 20, y: 12))
        let lower = actor(solid(6, 4, blue), foot: CGPoint(x: 22, y: 14))
        for list in [[upper, lower], [lower, upper]] {
            let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4, list))))
            // 겹치는 곳: x 84, y 44(월드 위쪽 캐릭터 발 12×4=48 위).
            XCTAssertTrue(same(px[84, 44], blue))
            XCTAssertTrue(same(px[65, 40], red), "the part of the upper actor that is not covered stays visible")
        }
    }

    func testBobDoesNotChangeDrawOrder() throws {
        // 발이 똑같이 겹친 두 캐릭터: 배열에서 뒤에 있는 쪽이 위에 그려진다. 뒤쪽이 통통 튀어도 순서는 그대로다.
        let map = solid(40, 20, black)
        func topColor(bob: CGFloat) throws -> RGBA {
            let first = actor(solid(6, 4, red), foot: CGPoint(x: 20, y: 12))
            let second = actor(solid(6, 4, blue), foot: CGPoint(x: 20, y: 12), bob: bob)
            let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4, [first, second]))))
            return px[80, 36]
        }
        XCTAssertTrue(same(try topColor(bob: 0), blue))
        XCTAssertTrue(same(try topColor(bob: 2), blue), "a bobbing actor keeps its place in the order (the later one stays on top)")
    }

    func testBobLiftsTheSpriteButNotTheShadowOrder() throws {
        let map = solid(40, 20, black)
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
            map: map, rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 4,
            [actor(solid(4, 2, red), foot: CGPoint(x: 20, y: 15), bob: 2)]))))
        XCTAssertTrue(same(px[80, 51], red), "drawn 2 world pixels higher: last row ends at 15-2")
        XCTAssertTrue(same(px[80, 52], black))
    }

    func testShadowsAreDrawnBeneathEverySprite() throws {
        // 앞(아래) 캐릭터의 그림자가 뒤(위) 캐릭터의 그림 위로 올라오지 않는다. 그림자는 모든 캐릭터보다 먼저 그린다.
        let back = actor(solid(4, 4, blue), foot: CGPoint(x: 22, y: 8), scale: 1)
        let front = actor(solid(2, 2, red), foot: CGPoint(x: 5, y: 12), scale: 1,
                          shadow: solid(8, 4, black), shadowRect: CGRect(x: 18, y: 4, width: 8, height: 4))
        for list in [[back, front], [front, back]] {
            let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: solid(40, 20, white), rect: CGRect(x: 0, y: 0, width: 40, height: 20), ppw: 2, list))))
            XCTAssertTrue(same(px[44, 12], blue), "the sprite wins over the other actor's shadow")
            XCTAssertTrue(same(px[37, 12], black), "the shadow is still there beside the sprite")
        }
    }

    func testNamePlateDrawnAboveOthers() throws {
        // 위쪽 캐릭터의 이름표가 아래쪽 캐릭터의 그림에 가려지지 않는다.
        let map = solid(60, 60, black)
        let plate = solid(10, 4, yellow)   // 사진 픽셀 그대로
        let top = actor(solid(2, 2, red), foot: CGPoint(x: 30, y: 20), plate: plate)
        let tall = actor(solid(20, 20, blue), foot: CGPoint(x: 30, y: 40))
        for list in [[top, tall], [tall, top]] {
            let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: map, rect: CGRect(x: 0, y: 0, width: 60, height: 60), ppw: 2, list))))
            // 위 캐릭터: 폭 3·높이 3 월드 → 머리 y = (20-3)*2 = 34. 이름표는 그 위 2픽셀 띄워 y 28–31.
            XCTAssertTrue(same(px[60, 30], yellow), "the plate sits over the lower actor's picture")
            XCTAssertTrue(same(px[60, 40], red) || same(px[60, 40], blue))
        }
    }

    func testBubbleSitsAbovePlate() throws {
        let map = solid(60, 60, black)
        let a = actor(solid(2, 2, red), foot: CGPoint(x: 30, y: 30), plate: solid(10, 4, yellow), bubble: solid(6, 6, green))
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
            map: map, rect: CGRect(x: 0, y: 0, width: 60, height: 60), ppw: 2, [a]))))
        // 머리 y = (30-3)*2 = 54, 이름표 y 48–51, 말풍선 y 42–47.
        XCTAssertTrue(same(px[60, 50], yellow))
        XCTAssertTrue(same(px[60, 45], green))
        XCTAssertTrue(same(px[60, 41], black))
    }

    func testPNGHeaderIsValid() throws {
        let map = image(4, 4) { x, _ in x < 2 ? red : blue }
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 4, height: 4), ppw: 2)))
        let data = try XCTUnwrap(PlazaPhotoRenderer.png(photo))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
    }

    // MARK: 장면

    private func newScene(zoom: Int = 2) -> PlazaScene {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: zoom, nickname: "나")
        scene.backingOverride = 2
        scene.size = CGSize(width: 800, height: 600)
        return scene
    }

    private func frames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: solid(9, 8, red), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func member(_ id: String, away: Bool = false) -> PlazaSceneMember {
        PlazaSceneMember(memberID: id, nickname: id, isAway: away, tile: map.spawn, facing: .down, isWalking: false)
    }

    // MARK: 키

    private func pressP(_ scene: PlazaScene, characters: String? = "ㅔ", isRepeat: Bool = false,
                        modifiers: NSEvent.ModifierFlags = []) -> PlazaKeyResult {
        scene.handleKeyDown(keyCode: photoKey, characters: characters, isRepeat: isRepeat, modifiers: modifiers)
    }

    func testPhotoKeyWorksWithHangulInput() {
        let scene = newScene()
        var count = 0
        scene.onPhotoKey = { count += 1 }
        XCTAssertEqual(pressP(scene, characters: "ㅔ"), .swallowed)
        XCTAssertEqual(pressP(scene, characters: "p"), .swallowed)
        XCTAssertEqual(count, 2, "judged by keyCode 35 whatever the input method types")
        scene.handleKeyDown(keyCode: 36, characters: "p", isRepeat: false)
        XCTAssertEqual(count, 2, "a 'p' character on another key is not a photo")
    }

    func testPhotoKeyIgnoresModifiersAndRepeat() {
        let scene = newScene()
        var count = 0
        scene.onPhotoKey = { count += 1 }
        for mod: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            XCTAssertEqual(pressP(scene, modifiers: mod), .swallowed)
        }
        XCTAssertEqual(pressP(scene, isRepeat: true), .swallowed)
        XCTAssertEqual(count, 0)
        _ = pressP(scene, modifiers: .shift)
        XCTAssertEqual(count, 1, "Shift alone does not block the photo")
    }

    func testPhotoKeyIsSwallowedWhileOverlayIsOpen() {
        let scene = newScene()
        var count = 0
        scene.onPhotoKey = { count += 1 }
        scene.isOverlayOpen = true
        XCTAssertEqual(pressP(scene), .swallowed)
        XCTAssertEqual(count, 0)
        scene.isOverlayOpen = false
        _ = pressP(scene)
        XCTAssertEqual(count, 1)
    }

    // MARK: 입력 모으기

    func testPhotoInputUsesZoomAndViewport() throws {
        for zoom in 1...3 {
            let scene = newScene(zoom: zoom)
            scene.setCharacter(frames())
            let input = try XCTUnwrap(scene.photoInput())
            XCTAssertEqual(input.pixelsPerWorld, zoom * 2)
            XCTAssertEqual(input.visibleRect.width * CGFloat(input.pixelsPerWorld), 1600, accuracy: 0.001)
            XCTAssertEqual(input.visibleRect.height * CGFloat(input.pixelsPerWorld), 1200, accuracy: 0.001)
            let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input))
            XCTAssertEqual(photo.width, 1600)
            XCTAssertEqual(photo.height, 1200)
        }
    }

    func testPhotoInputKeepsEggsAwayMembersAndSkipsMembersStillLoading() throws {
        let scene = newScene()
        scene.setCharacter(frames())
        scene.applyMembers([member("a"), member("away", away: true), member("loading")])
        scene.setMemberFrames("a", frames())
        scene.setMemberFrames("away", frames())
        let input = try XCTUnwrap(scene.photoInput())
        XCTAssertEqual(input.actors.count, 3, "me, a and the away member; the one still loading is left out")
        XCTAssertTrue(input.actors.allSatisfy { $0.scale == PlazaScene.characterScale })
        XCTAssertTrue(input.actors.allSatisfy { $0.shadow != nil && $0.plate != nil })
    }

    func testPhotoInputPlatesAndBubblesAreMadeAtScaleTwo() throws {
        let scene = newScene()
        scene.backingOverride = 1
        scene.setCharacter(frames())
        scene.showEmote(memberID: nil, kind: .heart)
        scene.update(0)
        let actor = try XCTUnwrap(scene.photoInput()?.actors.first)
        let plate = try XCTUnwrap(actor.plate)
        XCTAssertEqual(plate.width, PlazaNamePlate.image(text: "나", color: scene.nameColor, scale: 2)?.width)
        XCTAssertEqual(try XCTUnwrap(actor.bubble).width, PlazaEmoteArt.image(.heart, scale: 2).width)
    }

    func testShutterFlashShowsAndFades() {
        let scene = newScene()
        XCTAssertFalse(scene.isShutterFlashing)
        scene.playShutterFlash()
        XCTAssertTrue(scene.isShutterFlashing)
    }

    // MARK: 창

    private func controller(writer: @escaping (Data) -> Bool) -> PlazaWindowController {
        let name = "plaza.photo.prefs.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                      nickname: { "나" }, memberID: { "me" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      photoWriter: writer)
        c.prepareScene()
        c.scene?.backingOverride = 2
        c.scene?.size = CGSize(width: 800, height: 600)
        return c
    }

    func testPhotoKeyWritesPNGOnceAndFlashes() throws {
        var written: [Data] = []
        let c = controller { written.append($0); return true }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(frames())
        _ = pressP(scene)
        _ = pressP(scene, isRepeat: true)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(written.first).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(scene.isShutterFlashing)
    }

    func testFailedWriteDoesNotFlash() throws {
        var calls = 0
        let c = controller { _ in calls += 1; return false }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(frames())
        _ = pressP(scene)
        XCTAssertEqual(calls, 1, "rendering succeeded and the writer was asked once")
        XCTAssertFalse(scene.isShutterFlashing)
    }

    func testClosedWindowStopsListeningForPhotoKey() throws {
        var written = 0
        let c = controller { _ in written += 1; return true }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(frames())
        _ = pressP(scene)
        XCTAssertEqual(written, 1)
        c.handleClose()
        _ = pressP(scene)
        XCTAssertEqual(written, 1, "a closed plaza no longer takes photos")
    }
}
