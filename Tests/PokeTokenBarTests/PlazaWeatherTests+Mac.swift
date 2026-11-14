import XCTest
import AppKit
@testable import PokeTokenBar

/// The scene-driven weather tests and the photo checks (CoreGraphics pixel reads): `PlazaScene` is a SpriteKit scene until the plaza stage lands.
extension PlazaWeatherTests {
    // MARK: 장면

    private var map: PlazaMap { PlazaMapData.map }

    private func scene(at day: Date, zoom: Int = 2, size: CGSize = CGSize(width: 800, height: 600)) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: zoom, nickname: "나")
        s.backingOverride = 2
        s.size = size
        s.now = { day }
        return s
    }

    private var snowDay: Date { date(2026, 12, 1) }

    private func run(_ s: PlazaScene, seconds: Double, from start: Double = 0) {
        var t = start
        s.update(t)
        while t < start + seconds { t += 1.0 / 30; s.update(t) }
    }

    func testSceneShowsSnow() {
        let s = scene(at: date(2026, 11, 13))
        s.update(0)
        XCTAssertEqual(s.weatherKind, .snow)
        XCTAssertGreaterThan(s.weatherParticleCount, 0)
    }

    func testCountFollowsTheVisibleAreaAndNeverPassesTheCap() {
        let day = snowDay
        let near = scene(at: day, zoom: 3), mid = scene(at: day, zoom: 2), far = scene(at: day, zoom: 1)
        for s in [near, mid, far] { s.update(0) }
        XCTAssertLessThan(near.weatherParticleCount, mid.weatherParticleCount, "zoom 3 sees less of the plaza")
        XCTAssertLessThanOrEqual(far.weatherParticleCount, W.maxParticles)
        let huge = scene(at: day, zoom: 1, size: CGSize(width: 4000, height: 3000))
        huge.update(0)
        XCTAssertEqual(huge.weatherParticleCount, W.maxParticles, "a huge window is capped")
    }

    func testResizingRebuildsTheParticleSet() {
        let s = scene(at: snowDay, zoom: 3, size: CGSize(width: 400, height: 300))
        s.update(0)
        let small = s.weatherParticleCount
        s.size = CGSize(width: 900, height: 700)
        s.update(0.1)
        XCTAssertGreaterThan(s.weatherParticleCount, small)
    }

    func testParticlesStayInsideTheVisibleAreaAsTheCameraMoves() {
        let s = scene(at: snowDay)
        run(s, seconds: 1)
        s.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        run(s, seconds: 3, from: 1)
        let v = s.visibleWorldRect
        let sceneRect = CGRect(x: v.minX, y: map.pixelSize.height - v.maxY, width: v.width, height: v.height).insetBy(dx: -6, dy: -6)
        XCTAssertTrue(s.weatherParticlePositions.allSatisfy { sceneRect.contains($0) })
    }

    func testParticlesFallAndLandOnTheDeviceGrid() {
        let s = scene(at: snowDay)
        s.update(0)
        let before = s.weatherParticlePositions
        run(s, seconds: 0.5, from: 0.1)
        XCTAssertNotEqual(before, s.weatherParticlePositions)
        let step = PlazaPixelSnap.step(backing: 2, zoom: 2)
        for p in s.weatherParticlePositions {
            XCTAssertEqual((p.x / step).rounded() * step, p.x, accuracy: 1e-9)
            XCTAssertEqual((p.y / step).rounded() * step, p.y, accuracy: 1e-9)
        }
        // 격자가 더 굵지 않다: 반 칸(0.25) 위치에 선 입자가 있다. 굵은 격자(0.5)에 맞추면 이런 입자가 없다.
        XCTAssertTrue(s.weatherParticlePositions.contains { ($0.x * 2).truncatingRemainder(dividingBy: 1) != 0 || ($0.y * 2).truncatingRemainder(dividingBy: 1) != 0 })
    }

    func testAPausedSceneKeepsTheParticlesStill() {
        let s = scene(at: snowDay)
        s.update(0)
        s.update(0.05)
        let before = s.weatherParticlePositions
        s.update(0.05)   // 같은 시각: dt 0
        XCTAssertEqual(s.weatherParticlePositions, before)
        s.update(60)   // 잠자기 뒤의 큰 간격은 한 프레임 분량만 흐른다
        // 바닥을 넘어 위로 감긴 입자는 빼고 잰다(감김은 따로 시험한다).
        let moved = zip(before, s.weatherParticlePositions).map { abs($1.y - $0.y) }.filter { $0 < 50 }.max() ?? 0
        XCTAssertLessThanOrEqual(moved, 14 * 1.25 * 0.1 + 0.6, "the clamped dt, not sixty seconds of falling (or one wrap)")
    }

    func testHiddenBackgroundShowsNoWeather() {
        let s = scene(at: snowDay)
        run(s, seconds: 0.5)
        XCTAssertGreaterThan(s.weatherParticleCount, 0)
        s.setBackgroundHidden(true)
        XCTAssertEqual(s.weatherParticleCount, 0, "gone at once, not on the next frame")
        XCTAssertEqual(s.photoInput()?.weather.count, 0)
        run(s, seconds: 0.5, from: 1)
        XCTAssertEqual(s.weatherParticleCount, 0)
        XCTAssertEqual(s.weatherKind, .clear)
        s.setBackgroundHidden(false)
        XCTAssertGreaterThan(s.weatherParticleCount, 0, "and back when the map returns")
    }

    func testWeatherLayerSitsAboveCharactersAndBelowTheDaylightMultiply() {
        let s = scene(at: snowDay)
        let layer = s.weatherLayer.root
        XCTAssertGreaterThan(layer.zPosition, 2, "characters are 1...2")
        XCTAssertLessThan(layer.zPosition, 5, "the daylight multiply is 5, name plates 10")
    }

    // MARK: 기념사진

    private typealias RGBA = (r: Int, g: Int, b: Int, a: Int)

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        var d = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(d[0]), Int(d[1]), Int(d[2]), Int(d[3]))
    }

    /// 사진 픽셀 좌표(위에서 아래)로 본 입자 하나의 가운데 칸.
    private func centerPixel(_ p: PlazaPhotoParticle, input: PlazaPhotoInput) -> (x: Int, y: Int) {
        let ppw = CGFloat(input.pixelsPerWorld)
        let col = p.image.width / 2, row = p.image.height / 2
        return (Int(((p.origin.x - input.visibleRect.minX) * ppw).rounded()) + col * input.pixelsPerWorld + input.pixelsPerWorld / 2,
                Int(((p.origin.y - input.visibleRect.minY) * ppw).rounded()) + row * input.pixelsPerWorld + input.pixelsPerWorld / 2)
    }

    /// 눈송이(3x3 십자)의 한가운데 칸은 늘 흰색이라 사진에서 확인하기 좋다.
    private func plusFlake(_ input: PlazaPhotoInput) -> PlazaPhotoParticle? {
        let size = input.visibleRect.size
        return input.weather.first { p in
            p.image.width == 3 && p.image.height == 3 && centerPixel(p, input: input).x > 4
                && centerPixel(p, input: input).x < Int(size.width) * input.pixelsPerWorld - 4
                && centerPixel(p, input: input).y > 4 && centerPixel(p, input: input).y < Int(size.height) * input.pixelsPerWorld - 4
        }
    }

    func testPhotoInputCarriesTheParticlesOnScreen() throws {
        let s = scene(at: snowDay)
        run(s, seconds: 1)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.weather.count, s.weatherParticleCount)
        let ppw = CGFloat(input.pixelsPerWorld)
        XCTAssertEqual(ppw, 4)
        let world = map.pixelSize.height
        for (p, onScreen) in zip(input.weather, s.weatherParticlePositions) {
            XCTAssertEqual(p.origin.x, onScreen.x, accuracy: 1e-9)
            XCTAssertEqual(p.origin.y, world - onScreen.y - p.size.height, accuracy: 1e-9, "scene y up becomes world y down")
        }
    }

    func testPhotoDrawsTheParticles() throws {
        let snowy = scene(at: snowDay)
        run(snowy, seconds: 1)
        let input = try XCTUnwrap(snowy.photoInput())
        let withSnow = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        var bareInput = input
        bareInput.weather = []
        let without = try XCTUnwrap(PlazaPhotoRenderer.renderCG(bareInput))
        let flake = try XCTUnwrap(plusFlake(input))
        let at = centerPixel(flake, input: input)
        let drawn = pixel(withSnow, at.x, at.y), bare = pixel(without, at.x, at.y)
        XCTAssertGreaterThan(drawn.r, 0xF0)
        XCTAssertGreaterThan(drawn.g, 0xF0)
        XCTAssertGreaterThan(drawn.b, 0xF0)
        XCTAssertNotEqual(drawn.g, bare.g, "the grass underneath is covered")
        // 입자 한 칸은 월드 픽셀 하나(사진 4x4)로 또렷하다: 칸 안쪽 네 모퉁이가 모두 같은 색.
        let x0 = at.x - input.pixelsPerWorld / 2, y0 = at.y - input.pixelsPerWorld / 2
        let corners = [(0, 0), (3, 0), (0, 3), (3, 3)].map { pixel(withSnow, x0 + $0.0, y0 + $0.1) }
        XCTAssertTrue(corners.allSatisfy { $0 == corners[0] })
    }

    func testPhotoTintsTheParticlesLikeTheMap() throws {
        let night = date(2026, 12, 1, 23, 0)
        let day = night
        let s = scene(at: day)
        run(s, seconds: 1)
        var input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.tint, PlazaDaylight.night)
        let tinted = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        let flake = try XCTUnwrap(plusFlake(input))
        let at = centerPixel(flake, input: input)
        let p = pixel(tinted, at.x, at.y)
        XCTAssertEqual(Double(p.r), 246 * PlazaDaylight.night.red, accuracy: 3)
        XCTAssertEqual(Double(p.b), 255 * PlazaDaylight.night.blue, accuracy: 3)
        XCTAssertLessThan(p.r, p.b, "night snow is blue, not white")
        input.tint = .none
        XCTAssertGreaterThan(pixel(try XCTUnwrap(PlazaPhotoRenderer.renderCG(input)), at.x, at.y).r, 0xF0)
    }

    /// A particle covering the whole photo is painted over the map and characters but never over name plates.
    func testParticlesAreDrawnUnderNamePlates() throws {
        let s = scene(at: snowDay)
        let red = { () -> CGImage in
            let ctx = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 9, height: 8))
            return ctx.makeImage()!
        }()
        s.setCharacter(PlazaCharacterFrames(front: [PlazaFrame(image: PlazaImage(cgImage: red), delay: 0.1)], back: [PlazaFrame(image: PlazaImage(cgImage: red), delay: 0.1)]))
        s.update(0)
        var input = try XCTUnwrap(s.photoInput())
        input.weather = []
        let base = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        let blanket = PlazaWeatherArt.images(.snow)[2]   // 흰 한 칸
        input.weather = [PlazaPhotoParticle(image: blanket, origin: input.visibleRect.origin, size: input.visibleRect.size)]
        let covered = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        var plateOnTop = 0, whites = 0
        for y in stride(from: 0, to: base.height, by: 2) {
            for x in stride(from: 0, to: base.width, by: 2) {
                let c = pixel(covered, x, y)
                if c.r > 0xF0 && c.g > 0xF0 && c.b > 0xF0 { whites += 1 } else { plateOnTop += 1 }
            }
        }
        XCTAssertGreaterThan(plateOnTop, 20, "the name plate shows through an all-white blanket, so it is drawn after it")
        XCTAssertGreaterThan(whites, 1000, "while the map and character are under it")
    }
}
