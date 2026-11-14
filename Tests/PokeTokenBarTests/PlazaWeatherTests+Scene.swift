import XCTest
@testable import PokeTokenBar

/// The scene-driven weather tests and the photo checks (CoreGraphics pixel reads): `PlazaScene` is a SpriteKit scene until the plaza stage lands.
extension PlazaWeatherTests {
    // MARK: 장면

    private var map: PlazaMap { PlazaMapData.map }

    func scene(at day: Date, zoom: Int = 2, size: CGSize = CGSize(width: 800, height: 600)) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: zoom, nickname: "나")
        s.backingOverride = 2
        s.size = size
        s.now = { day }
        return s
    }

    var snowDay: Date { date(2026, 12, 1) }

    func run(_ s: PlazaScene, seconds: Double, from start: Double = 0) {
        var t = start
        s.update(t)
        while t < start + seconds { t += 1.0 / 30; s.update(t) }
    }

    func testSceneShowsSnow() async {
        let s = scene(at: date(2026, 11, 13))
        s.update(0)
        XCTAssertEqual(s.weatherKind, .snow)
        XCTAssertGreaterThan(s.weatherParticleCount, 0)
    }

    func testCountFollowsTheVisibleAreaAndNeverPassesTheCap() async {
        let day = snowDay
        let near = scene(at: day, zoom: 3), mid = scene(at: day, zoom: 2), far = scene(at: day, zoom: 1)
        for s in [near, mid, far] { s.update(0) }
        XCTAssertLessThan(near.weatherParticleCount, mid.weatherParticleCount, "zoom 3 sees less of the plaza")
        XCTAssertLessThanOrEqual(far.weatherParticleCount, W.maxParticles)
        let huge = scene(at: day, zoom: 1, size: CGSize(width: 4000, height: 3000))
        huge.update(0)
        XCTAssertEqual(huge.weatherParticleCount, W.maxParticles, "a huge window is capped")
    }

    func testResizingRebuildsTheParticleSet() async {
        let s = scene(at: snowDay, zoom: 3, size: CGSize(width: 400, height: 300))
        s.update(0)
        let small = s.weatherParticleCount
        s.size = CGSize(width: 900, height: 700)
        s.update(0.1)
        XCTAssertGreaterThan(s.weatherParticleCount, small)
    }

    func testParticlesStayInsideTheVisibleAreaAsTheCameraMoves() async {
        let s = scene(at: snowDay)
        run(s, seconds: 1)
        s.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        run(s, seconds: 3, from: 1)
        let v = s.visibleWorldRect
        let sceneRect = CGRect(x: v.minX, y: map.pixelSize.height - v.maxY, width: v.width, height: v.height).insetBy(dx: -6, dy: -6)
        XCTAssertTrue(s.weatherParticlePositions.allSatisfy { sceneRect.contains($0) })
    }

    func testParticlesFallAndLandOnTheDeviceGrid() async {
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

    func testAPausedSceneKeepsTheParticlesStill() async {
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

    func testHiddenBackgroundShowsNoWeather() async {
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

    func testWeatherLayerSitsAboveCharactersAndBelowTheDaylightMultiply() async {
        let s = scene(at: snowDay)
        let layer = s.weatherLayer.root
        XCTAssertGreaterThan(layer.zPosition, 2, "characters are 1...2")
        XCTAssertLessThan(layer.zPosition, 5, "the daylight multiply is 5, name plates 10")
    }

    // MARK: 기념사진

    typealias RGBA = (r: Int, g: Int, b: Int, a: Int)

    /// 사진 픽셀 좌표(위에서 아래)로 본 입자 하나의 가운데 칸.
    func centerPixel(_ p: PlazaPhotoParticle, input: PlazaPhotoInput) -> (x: Int, y: Int) {
        let ppw = CGFloat(input.pixelsPerWorld)
        let col = p.image.width / 2, row = p.image.height / 2
        return (Int(((p.origin.x - input.visibleRect.minX) * ppw).rounded()) + col * input.pixelsPerWorld + input.pixelsPerWorld / 2,
                Int(((p.origin.y - input.visibleRect.minY) * ppw).rounded()) + row * input.pixelsPerWorld + input.pixelsPerWorld / 2)
    }

    /// 눈송이(3x3 십자)의 한가운데 칸은 늘 흰색이라 사진에서 확인하기 좋다.
    func plusFlake(_ input: PlazaPhotoInput) -> PlazaPhotoParticle? {
        let size = input.visibleRect.size
        return input.weather.first { p in
            p.image.width == 3 && p.image.height == 3 && centerPixel(p, input: input).x > 4
                && centerPixel(p, input: input).x < Int(size.width) * input.pixelsPerWorld - 4
                && centerPixel(p, input: input).y > 4 && centerPixel(p, input: input).y < Int(size.height) * input.pixelsPerWorld - 4
        }
    }

    func testPhotoInputCarriesTheParticlesOnScreen() async throws {
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
}
