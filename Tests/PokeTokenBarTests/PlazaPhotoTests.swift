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
                   shadow: CGImage? = nil, shadowRect: CGRect = .zero, front: CGImage? = nil,
                   plate: CGImage? = nil, bubble: CGImage? = nil) -> PlazaPhotoActor {
    PlazaPhotoActor(image: img, flipped: flipped, foot: foot, bob: bob, scale: scale, shadow: shadow, shadowRect: shadowRect,
                    front: front, plate: plate, bubble: bubble)
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

    /// Fireworks are light: neither the night tint nor a light may change them, and a name plate stays readable on top.
    func testFireworksSitAboveTheTintAndTheLightAndBelowTheNames() throws {
        let tint = PlazaDaylight.Tint(red: 0.5, green: 0.5, blue: 0.5), grey: RGBA = (100, 100, 100, 255)
        var i = input(map: solid(8, 8, white), rect: CGRect(x: 0, y: 0, width: 8, height: 8), ppw: 1,
                      [actor(solid(2, 2, blue), foot: CGPoint(x: 4, y: 8), scale: 1, plate: solid(2, 2, green))])
        i.tint = tint
        i.fireworkLight = PlazaPhotoLight(center: CGPoint(x: 4, y: 4), radii: CGSize(width: 16, height: 16), tint: tint)
        i.fireworks = [PlazaPhotoParticle(image: solid(8, 8, grey), origin: .zero, size: CGSize(width: 8, height: 8))]
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(i)))
        XCTAssertTrue(same(px[0, 0], grey), "unchanged by the tint and the light: \(px[0, 0])")
        XCTAssertTrue(same(px[4, 3], green), "the plate stays on top: \(px[4, 3])")
    }

    /// A firework's light brightens the photo like the campfire's does, weaker as its level drops, and only inside it.
    func testFireworkLightBrightensThePhotoAtItsLevel() throws {
        let tint = PlazaDaylight.night
        func shot(level: Double) throws -> Pixels {
            var i = input(map: solid(40, 40, (100, 100, 100, 255)), rect: CGRect(x: 0, y: 0, width: 40, height: 40), ppw: 1)
            i.tint = tint
            i.fireworkLight = PlazaPhotoLight(center: CGPoint(x: 10, y: 10), radii: CGSize(width: 8, height: 8), tint: tint,
                                              color: (r: 1, g: 1, b: 1), level: level)
            return Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(i)))
        }
        let full = try shot(level: 1), half = try shot(level: 0.5)
        XCTAssertEqual(Int(full[10, 10].b), 100, accuracy: 1, "lifted back to the daylight colour")
        XCTAssertGreaterThan(full[10, 10].b, half[10, 10].b)
        XCTAssertGreaterThan(half[10, 10].b, full[30, 30].b)
        XCTAssertEqual(Int(full[30, 30].b), 78, accuracy: 1, "outside it the night stays")
    }

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

    /// An egg's nest rim goes over the egg, so the egg sits in its nest on the photo too. The rest of the nest stays behind.
    func testNestFrontIsDrawnOverTheEgg() throws {
        let map = solid(20, 20, green)
        let egg = solid(4, 4, red)
        let nest = solid(8, 4, yellow)
        let rim = image(8, 4) { _, y in y >= 2 ? blue : (0, 0, 0, 0) }
        // The egg covers x 8–11 and rows 6–9; the nest covers rows 7–10, its rim rows 9–10.
        let rect = CGRect(x: 6, y: 7, width: 8, height: 4)
        let a = actor(egg, foot: CGPoint(x: 10, y: 10), scale: 1, shadow: nest, shadowRect: rect, front: rim)
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(map: map, rect: CGRect(x: 0, y: 0, width: 20, height: 20), ppw: 1, [a]))))
        XCTAssertTrue(same(px[9, 8], red), "the egg is over the back of the nest")
        XCTAssertTrue(same(px[9, 9], blue), "the rim is over the egg's bottom")
        XCTAssertTrue(same(px[7, 8], yellow), "the back of the nest shows beside the egg")
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

    func testWideBubbleStaysInsideThePhotoUnlessTheNameIsOutside() throws {
        func photo(foot: CGPoint) throws -> Pixels {
            let a = actor(solid(2, 2, red), foot: foot, bubble: solid(40, 6, green))
            return Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input(
                map: solid(60, 60, black), rect: CGRect(x: 0, y: 0, width: 60, height: 60), ppw: 2, [a]))))
        }
        XCTAssertTrue(same(try photo(foot: CGPoint(x: 2, y: 30))[35, 50], green), "pushed in from the left")
        XCTAssertTrue(same(try photo(foot: CGPoint(x: 58, y: 30))[85, 50], green), "pushed in from the right")
        XCTAssertTrue(same(try photo(foot: CGPoint(x: 30, y: 6))[60, 2], green), "pushed down from the top")
        XCTAssertTrue(same(try photo(foot: CGPoint(x: -30, y: 30))[1, 50], black), "not pulled in from outside")
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
        // 낮과 날씨를 벽시계에 맡기지 않는다: 해 질 녘 색이나 계절 날씨가 끼면 사진 픽셀 비교가 시각에 따라 달라진다.
        scene.now = { Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12))! }
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
        XCTAssertEqual(try XCTUnwrap(actor.bubble).width, PlazaEmoteArt.image(.heart, scale: 2, large: true).width)
    }

    func testShutterFlashShowsAndFades() {
        let scene = newScene()
        XCTAssertFalse(scene.isShutterFlashing)
        scene.playShutterFlash()
        XCTAssertTrue(scene.isShutterFlashing)
    }

    /// A hidden plaza (paused scene) does not flash: its fade would not run and a white sheet would wait for the
    /// window to come back, as when a group photo ends while the window is covered.
    func testAPausedSceneDoesNotFlash() {
        let scene = newScene()
        scene.isPaused = true
        scene.playShutterFlash()
        XCTAssertFalse(scene.isShutterFlashing)
        scene.isPaused = false
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
        XCTAssertTrue(written.isEmpty, "첫 P는 사진 모드만 연다")
        XCTAssertTrue(c.isPhotoMode)
        _ = pressP(scene)
        _ = pressP(scene, isRepeat: true)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(written.first).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(scene.isShutterFlashing)
        XCTAssertEqual(c.banner, "사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기")
    }

    func testFailedWriteDoesNotFlash() throws {
        var calls = 0
        let c = controller { _ in calls += 1; return false }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(frames())
        _ = pressP(scene)
        _ = pressP(scene)
        XCTAssertEqual(calls, 1, "rendering succeeded and the writer was asked once")
        XCTAssertFalse(scene.isShutterFlashing)
        XCTAssertNil(c.banner)
    }

    func testClosedWindowStopsListeningForPhotoKey() throws {
        var written = 0
        let c = controller { _ in written += 1; return true }
        let scene = try XCTUnwrap(c.scene)
        scene.setCharacter(frames())
        _ = pressP(scene)
        _ = pressP(scene)
        XCTAssertEqual(written, 1)
        c.handleClose()
        _ = pressP(scene)
        XCTAssertEqual(written, 1, "a closed plaza no longer takes photos")
    }

    // MARK: 풀숲 띠와 숨은 팀원

    private func tallActor(foot: CGPoint, opacity: CGFloat = 1, plateBaseY: CGFloat? = nil, plate: CGImage? = nil) -> PlazaPhotoActor {
        // 32x48 그림은 배율 1.5로 48x72 월드 픽셀이다.
        var a = actor(solid(32, 48, red), foot: foot, plate: plate)
        a.opacity = opacity
        a.plateBaseY = plateBaseY
        return a
    }

    private func bandInput(_ actors: [PlazaPhotoActor], bands: [PlazaPhotoBand] = []) -> PlazaPhotoInput {
        var i = input(map: solid(8, 8, green), rect: CGRect(x: 0, y: 0, width: 128, height: 128), ppw: 2, actors)
        i.bands = bands
        return i
    }

    /// 칸 (1,1): 월드 x 32-64, y 32-64.
    private func yellowBand() -> PlazaPhotoBand {
        PlazaPhotoBand(image: solid(32, 32, yellow), origin: CGPoint(x: 32, y: 32), size: CGSize(width: 32, height: 32), sortY: 63)
    }

    func testABandCoversTheFeetOfAnActorInItsTile() throws {
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([tallActor(foot: CGPoint(x: 48, y: 50))], bands: [yellowBand()])))
        let px = Pixels(photo)
        XCTAssertTrue(same(px[96, 90], yellow), "just above the foot the band is on top: \(px[96, 90])")
        XCTAssertTrue(same(px[96, 50], red), "above the band the actor shows")
    }

    func testABandStaysBehindAnActorInTheRowBelow() throws {
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([tallActor(foot: CGPoint(x: 48, y: 90))], bands: [yellowBand()])))
        XCTAssertTrue(same(Pixels(photo)[96, 100], red), "the actor in front is drawn over the band")
    }

    func testAHiddenActorLeavesOnlyItsPlate() throws {
        let plate = solid(10, 6, black)
        let a = tallActor(foot: CGPoint(x: 48, y: 100), opacity: 0, plateBaseY: 80, plate: plate)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([a])))
        let px = Pixels(photo)
        for y in 0..<px.height { for x in 0..<px.width where same(px[x, y], red) { return XCTFail("sprite pixel at \(x),\(y)") } }
        // plateBaseY(80)는 사진 픽셀 160이고, 화면처럼 그 위로 plateGap(2)을 띄운다: 이름표는 152-157행.
        XCTAssertTrue(same(px[96, 157], black), "plate bottom row")
        XCTAssertTrue(same(px[96, 152], black), "plate top row")
        XCTAssertFalse(same(px[96, 158], black))
        XCTAssertFalse(same(px[96, 151], black))
    }

    func testAHiddenActorsShadowAndNestFrontAreNotDrawn() throws {
        var a = tallActor(foot: CGPoint(x: 48, y: 100), opacity: 0)
        a = PlazaPhotoActor(image: a.image, flipped: false, foot: a.foot, scale: a.scale, shadow: solid(20, 8, blue),
                            shadowRect: CGRect(x: 38, y: 96, width: 20, height: 8), front: solid(20, 8, yellow), plate: nil, bubble: nil,
                            opacity: 0)
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([a]))))
        for y in 0..<px.height { for x in 0..<px.width {
            XCTAssertFalse(same(px[x, y], blue), "shadow pixel at \(x),\(y)")
            XCTAssertFalse(same(px[x, y], yellow), "nest front pixel at \(x),\(y)")
        } }
    }

    func testOpacityBlendsTheSprite() throws {
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([tallActor(foot: CGPoint(x: 48, y: 100), opacity: 0.4)])))
        let p = Pixels(photo)[96, 150]
        XCTAssertFalse(same(p, red))
        XCTAssertFalse(same(p, green))
        XCTAssertTrue(p.r > 60 && p.g > 20 && p.g < 100, "a mix of the red sprite and green ground: \(p)")
    }

    private func tallGrassScene() throws -> PlazaScene {
        let art = try XCTUnwrap(PlazaTallGrassArt.load())
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: TilePoint(x: 20, y: 22), zoom: 2,
                           nickname: "me", tallGrass: art)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        let tall = [PlazaFrame(image: solid(32, 48, red), delay: 0.1)]   // 72 world px tall at x1.5
        s.setCharacter(PlazaCharacterFrames(front: tall, back: tall))
        s.applyMembers([PlazaSceneMember(memberID: "a", nickname: "a", isAway: false, tile: TilePoint(x: 7, y: 6), facing: .down, isWalking: false)])
        s.setMemberFrames("a", PlazaCharacterFrames(front: tall, back: tall))
        var t: TimeInterval = 0
        s.update(t)
        for _ in 0..<3 { t += 1.0 / 30; s.update(t) }
        return s
    }

    func testPhotoInputCarriesBandsAndConcealment() throws {
        let s = try tallGrassScene()
        let shown = try XCTUnwrap(s.photoInput())
        XCTAssertFalse(shown.bands.isEmpty)
        let hidden = try XCTUnwrap(shown.actors.first { $0.opacity == 0 }, "the teammate in the grass is drawn at opacity 0")
        XCTAssertNotNil(hidden.plateBaseY)
        s.setBackgroundHidden(true)
        let off = try XCTUnwrap(s.photoInput())
        XCTAssertTrue(off.bands.isEmpty)
        XCTAssertTrue(off.actors.allSatisfy { $0.opacity == 1 })
    }

    func testMyOwnPokemonInTheGrassIsDrawnAtFortyPercent() throws {
        let art = try XCTUnwrap(PlazaTallGrassArt.load())
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: TilePoint(x: 6, y: 6), zoom: 2,
                           nickname: "me", tallGrass: art)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        let tall = [PlazaFrame(image: solid(32, 48, red), delay: 0.1)]
        s.setCharacter(PlazaCharacterFrames(front: tall, back: tall))
        var t: TimeInterval = 0
        s.update(t)
        for _ in 0..<3 { t += 1.0 / 30; s.update(t) }
        let input = try XCTUnwrap(s.photoInput())
        let me = try XCTUnwrap(input.actors.first)
        XCTAssertEqual(me.opacity, 0.4, accuracy: 1e-9)
        XCTAssertNil(me.plateBaseY, "my name tag stays on my head")

        func pixels(_ opacity: CGFloat) throws -> Pixels {
            var i = input
            var a = me
            a.opacity = opacity
            i = PlazaPhotoInput(mapImage: i.mapImage, visibleRect: i.visibleRect, pixelsPerWorld: i.pixelsPerWorld,
                                actors: [a], bands: [])
            return Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(i)))
        }
        let blended = try pixels(me.opacity), full = try pixels(1), none = try pixels(0)
        var fullRed = 0, blendedRed = 0, changed = 0
        for y in 0..<full.height { for x in 0..<full.width {
            if same(full[x, y], red) { fullRed += 1 }
            if same(blended[x, y], red) { blendedRed += 1 }
            if !same(blended[x, y], none[x, y]) { changed += 1 }
        } }
        XCTAssertGreaterThan(fullRed, 0, "the sprite shows at full strength")
        XCTAssertEqual(blendedRed, 0, "at 40% no pixel keeps the pure sprite colour")
        XCTAssertGreaterThan(changed, 0, "at 40% the sprite is still visible")
    }

    // MARK: 모닥불

    private func nightDate() -> Date { Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())! }

    func testPhotoCarriesTheFireAndItsNightLight() throws {
        let scene = newScene()
        scene.now = { self.nightDate() }
        scene.setCharacter(frames())
        scene.campfireLit = true
        scene.sit(at: PlazaCampfire.seats[4])   // bring the fire into view
        scene.update(0)
        var input = try XCTUnwrap(scene.photoInput())
        XCTAssertTrue(input.visibleRect.contains(CGPoint(x: 768, y: 530)))
        XCTAssertTrue(input.items.isEmpty, "the pit is a depth-sorted prop, not a ground item")
        XCTAssertEqual(input.props.first?.particle.size, PlazaCampfireArt.worldSize)
        XCTAssertEqual(input.props.first?.baseY, 544)
        XCTAssertEqual(input.props.first?.particle.origin, CGPoint(x: 768 - 32, y: 548 - 80))
        let light = try XCTUnwrap(input.light)
        XCTAssertEqual(light.center, PlazaCampfireLight.center(campfireTiles: map.campfireTiles))
        // Tiny plate so we can compare it: it must be identical with and without the light.
        let plate = solid(4, 4, white)
        let probe = PlazaPhotoActor(image: solid(2, 2, red), flipped: false, foot: CGPoint(x: light.center.x - 40, y: light.center.y + 2),
                                    scale: 1, shadow: nil, shadowRect: .zero, plate: plate, bubble: nil)
        input = PlazaPhotoInput(mapImage: input.mapImage, visibleRect: input.visibleRect, pixelsPerWorld: input.pixelsPerWorld,
                                actors: [probe], tint: input.tint, props: input.props, light: light)
        let lit = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(input)))
        var dark = input; dark.light = nil
        let plain = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(dark)))
        let ppw = input.pixelsPerWorld
        // A ground pixel one tile left of the pit footprint.
        let gx = Int((CGFloat(22 * 32) + 16 - input.visibleRect.minX) * CGFloat(ppw)), gy = Int((CGFloat(16 * 32) + 16 - input.visibleRect.minY) * CGFloat(ppw))
        let a = lit[gx, gy], b = plain[gx, gy]
        XCTAssertGreaterThan(Int(a.r) + Int(a.g) + Int(a.b), Int(b.r) + Int(b.g) + Int(b.b))
        // The plate sits above the sprite: find it at the foot column, a few pixels above the sprite top.
        let px = Int((probe.foot.x - input.visibleRect.minX) * CGFloat(ppw)), foot = Int((probe.foot.y - input.visibleRect.minY) * CGFloat(ppw))
        let plateRow = foot - 2 * ppw - 2 - plate.height / 2   // inside the 4x4 plate, above the 2px*1 sprite
        XCTAssertTrue(same(lit[px, plateRow], plain[px, plateRow]))
        XCTAssertTrue(same(lit[px, plateRow], white), "the plate is white and untouched by the tint and the light")
    }

    func testPhotoLightMatchesTheSceneMaths() throws {
        let tint = PlazaDaylight.Tint(red: 0.45, green: 0.5, blue: 0.7)
        let ground = solid(64, 64, (200, 180, 160, 255))
        let center = CGPoint(x: 32, y: 32)
        let radii = CGSize(width: 24, height: 20)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        var inp = input(map: ground, rect: rect, ppw: 2)
        inp.tint = tint
        let plain = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(inp)))
        inp.light = PlazaPhotoLight(center: center, radii: radii, tint: tint)
        let lit = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(inp)))
        // The centre block is inside ring 1 (mix 1).
        let m = PlazaCampfireLight.multiplier(tint: tint, mix: 1)
        let base = plain[64, 64], got = lit[64, 64]
        func expect(_ v: UInt8, _ k: Double) -> Int { min(255, Int((Double(v) * k).rounded())) }
        XCTAssertEqual(Int(got.r), expect(base.r, m.r), accuracy: 2)
        XCTAssertEqual(Int(got.g), expect(base.g, m.g), accuracy: 2)
        XCTAssertEqual(Int(got.b), expect(base.b, m.b), accuracy: 2)
        // Outside the ellipse nothing changes.
        XCTAssertTrue(same(lit[2, 2], plain[2, 2]))
    }

    func testPhotoLightHalfOutsideTheFrameStillLightsTheInsideOnly() throws {
        let tint = PlazaDaylight.Tint(red: 0.45, green: 0.5, blue: 0.7)
        let ground = solid(64, 64, (200, 180, 160, 255))
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        var inp = input(map: ground, rect: rect, ppw: 2)
        inp.tint = tint
        let plain = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(inp)))
        // The fire sits on the frame's corner: most light blocks fall outside and must be skipped.
        inp.light = PlazaPhotoLight(center: CGPoint(x: 0, y: 0), radii: CGSize(width: 24, height: 20), tint: tint)
        let lit = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(inp)))
        XCTAssertTrue(same(lit[120, 120], plain[120, 120]), "far from the light nothing changes")
        let corners = [(0, 0), (0, 127), (127, 0), (127, 127)]
        XCTAssertTrue(corners.contains { !same(lit[$0.0, $0.1], plain[$0.0, $0.1]) }, "the part of the light inside the frame is drawn")
    }

    /// Renders the photo with a tall member on `tile` four ways (everything, members only, pit only, bare ground) and
    /// returns the pixels where both the member and the pit show: there the full photo says which one is in front.
    private func overlap(memberTile: TilePoint) throws -> (full: [RGBA], member: [RGBA], pit: [RGBA]) {
        let scene = newScene()
        scene.setCharacter(PlazaCharacterFrames(front: [PlazaFrame(image: solid(100, 60, red), delay: 0.1)],
                                                back: [PlazaFrame(image: solid(100, 60, red), delay: 0.1)]))
        scene.sit(at: PlazaCampfire.seats[4])
        scene.applyMembers([PlazaSceneMember(memberID: "m", nickname: "m", isAway: false, tile: memberTile, facing: .down, isWalking: false)])
        scene.setMemberFrames("m", PlazaCharacterFrames(front: [PlazaFrame(image: solid(100, 60, red), delay: 0.1)],
                                                        back: [PlazaFrame(image: solid(100, 60, red), delay: 0.1)]))
        scene.update(0)
        XCTAssertEqual(scene.memberTiles["m"], memberTile, "the tile is walkable, so the member stands there")
        let input = try XCTUnwrap(scene.photoInput())
        func render(actors: Bool, props: Bool) throws -> Pixels {
            var i = input
            if !actors { i.actors = [] }
            if !props { i.props = [] }
            return Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(i)))
        }
        let full = try render(actors: true, props: true), members = try render(actors: true, props: false)
        let pit = try render(actors: false, props: true), ground = try render(actors: false, props: false)
        var out: (full: [RGBA], member: [RGBA], pit: [RGBA]) = ([], [], [])
        for y in 0..<full.height {
            for x in 0..<full.width where !same(members[x, y], ground[x, y]) && !same(pit[x, y], ground[x, y]) && !same(members[x, y], pit[x, y]) {
                out.full.append(full[x, y]); out.member.append(members[x, y]); out.pit.append(pit[x, y])
            }
        }
        return out
    }

    func testAMemberNorthOfTheBaseLineIsDrawnBehindThePit() throws {
        let o = try overlap(memberTile: TilePoint(x: 22, y: 16))   // foot y = 16.875 * 32 = 540 < 544
        XCTAssertFalse(o.full.isEmpty, "the member's sprite overlaps the pit sprite")
        for (f, p) in zip(o.full, o.pit) { XCTAssertTrue(same(f, p), "the pit is in front") }
    }

    func testAMemberSouthOfTheBaseLineIsDrawnInFrontOfThePit() throws {
        let o = try overlap(memberTile: TilePoint(x: 23, y: 18))
        XCTAssertFalse(o.full.isEmpty)
        for (f, m) in zip(o.full, o.member) { XCTAssertTrue(same(f, m), "the member is in front") }
    }

    // MARK: 헤엄과 잠수

    func testASwimmerShowsOnlyTheTop() throws {
        // 72px 단색 배우: 발 y=100(사진 200행), sink 39.6이면 보이는 높이는 32.4 -> 사진 65행 안팎.
        var a = actor(solid(32, 48, red), foot: CGPoint(x: 48, y: 100), shadow: solid(20, 8, blue),
                      shadowRect: CGRect(x: 38, y: 96, width: 20, height: 8), front: solid(20, 8, yellow), plate: solid(10, 6, black))
        a.sink = 39.6
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([a]))))
        var redRows: [Int] = []
        for y in 0..<px.height {
            for x in 0..<px.width {
                XCTAssertFalse(same(px[x, y], blue), "no shadow at \(x),\(y)")
                XCTAssertFalse(same(px[x, y], yellow), "no nest front at \(x),\(y)")
                if same(px[x, y], red) { redRows.append(y) }
            }
        }
        XCTAssertLessThanOrEqual(redRows.max() ?? 0, 199, "nothing below the foot line (photo row 200)")
        XCTAssertEqual(Double(redRows.max()! - redRows.min()! + 1), 32.4 * 2, accuracy: 2)
        // 이름표는 보이는 윗부분 위에 놓인다: 맨 윗 행(135) 위 plateGap(2)을 띄운다.
        XCTAssertTrue(same(px[96, 132], black), "plate sits right above the visible top")
    }

    func testASwimmerWithBobIsClippedAtTheLiftedFootLine() throws {
        var a = actor(solid(32, 48, red), foot: CGPoint(x: 48, y: 100), bob: 2)
        a.sink = 39.6
        let px = Pixels(try XCTUnwrap(PlazaPhotoRenderer.render(bandInput([a]))))
        var maxRow = 0
        for y in 0..<px.height { for x in 0..<px.width where same(px[x, y], red) { maxRow = max(maxRow, y) } }
        XCTAssertEqual(maxRow, 195, "the cut follows the lifted foot like the scene")
    }

    private func pondScene() -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: TilePoint(x: 20, y: 22), zoom: 2,
                           nickname: "me", pondVisuals: true)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        let tall = [PlazaFrame(image: solid(32, 48, red), delay: 0.1)]
        s.setCharacter(PlazaCharacterFrames(front: tall, back: tall))
        return s
    }

    private func addMembers(_ s: PlazaScene, _ list: [(id: String, tile: TilePoint, diving: Bool)]) {
        s.applyMembers(list.map {
            var m = PlazaSceneMember(memberID: $0.id, nickname: $0.id, isAway: false, tile: $0.tile, facing: .down, isWalking: false)
            m.isDiving = $0.diving
            return m
        })
        let tall = [PlazaFrame(image: solid(32, 48, red), delay: 0.1)]
        for m in list { s.setMemberFrames(m.id, PlazaCharacterFrames(front: tall, back: tall)) }
    }

    private func settle(_ s: PlazaScene) {
        var t: TimeInterval = 0
        s.update(t)
        for _ in 0..<6 { t += 1.0 / 30; s.update(t) }
    }

    /// While a swimmer fades into a dive the name plate follows the visible (cut) height, not the full sprite.
    func testSwimmerNamePlateUsesTheVisibleHeightWhileDiving() throws {
        let s = pondScene()
        addMembers(s, [("dive", TilePoint(x: 35, y: 18), true)])
        s.update(0)
        s.update(1.0 / 30)   // the dive fade is a sixth of the way: 0 < concealment < 0.5
        let swimmer = try XCTUnwrap(try XCTUnwrap(s.photoInput()).actors.first { abs($0.foot.x - 35.5 * 32) < 1 })
        XCTAssertGreaterThan(swimmer.opacity, 0)
        let c = CGFloat(1.0 / 30 / PlazaPond.diveFade)
        let visible = 72 - swimmer.sink
        let expected = swimmer.foot.y - (visible - (visible - PlazaTallGrass.hiddenPlateLift) * min(1, c * 2))
        XCTAssertEqual(try XCTUnwrap(swimmer.plateBaseY), expected, accuracy: 0.5)
    }

    func testPhotoInputCarriesSwimAndDive() throws {
        let s = pondScene()
        addMembers(s, [("swim", TilePoint(x: 34, y: 18), false), ("dive", TilePoint(x: 35, y: 18), true),
                       ("land", TilePoint(x: 30, y: 18), false)])
        settle(s)
        // y가 같은 배우는 닉네임으로 가린다. 이름표 PNG 대신 발 x(타일 중심)로 고른다.
        let actors = try XCTUnwrap(s.photoInput()).actors
        let swimmer = try XCTUnwrap(actors.first { abs($0.foot.x - 34.5 * 32) < 1 })
        let diver = try XCTUnwrap(actors.first { abs($0.foot.x - 35.5 * 32) < 1 })
        let walker = try XCTUnwrap(actors.first { abs($0.foot.x - 30.5 * 32) < 1 })
        XCTAssertGreaterThan(swimmer.sink, 0)
        XCTAssertEqual(swimmer.sink, 72 * 0.55, accuracy: 1)
        XCTAssertEqual(diver.opacity, 0, accuracy: 0.001)
        XCTAssertNotNil(diver.plateBaseY)
        XCTAssertEqual(walker.sink, 0)

        s.setBackgroundHidden(true)
        XCTAssertTrue(try XCTUnwrap(s.photoInput()).actors.allSatisfy { $0.sink == 0 && $0.opacity == 1 },
                      "the live scene does not cut with the background hidden, and neither does the photo")
    }
}
