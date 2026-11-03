import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

@MainActor
final class PlazaWeatherTests: XCTestCase {
    private typealias W = PlazaWeather
    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func kind(_ y: Int, _ m: Int, _ d: Int) -> W.Kind { W.kind(on: date(y, m, d), calendar: calendar) }

    /// The kind a window day must have: always the window's kind, or the kind on wet days only.
    private func expected(_ y: Int, _ m: Int, _ d: Int, wet: W.Kind) -> W.Kind {
        W.isWetDay(year: y, month: m, day: d) ? wet : .clear
    }

    // MARK: 날짜 창

    func testPetalsEveryDayFromAprilFirstToFourteenth() {
        for year in [2026, 2027, 2028] {
            XCTAssertEqual(kind(year, 3, 31), .clear)
            for d in 1...14 { XCTAssertEqual(kind(year, 4, d), .petals, "\(year)-4-\(d)") }
            XCTAssertEqual(kind(year, 4, 15), .clear)
        }
    }

    func testLeavesEveryDayFromOctoberTwentiethToNovemberTwentieth() {
        for year in [2026, 2027, 2028] {
            XCTAssertEqual(kind(year, 10, 19), .clear)
            XCTAssertEqual(kind(year, 10, 20), .leaves)
            XCTAssertEqual(kind(year, 11, 20), .leaves)
            XCTAssertEqual(kind(year, 11, 21), .clear)
        }
        for d in 20...31 { XCTAssertEqual(kind(2026, 10, d), .leaves) }
        for d in 1...20 { XCTAssertEqual(kind(2026, 11, d), .leaves) }
    }

    /// Wet days cannot sit outside the window, and the window's first and last day are inside it (some year has rain there).
    func testRainWindowIsJuneTwentiethToJulyThirtyFirst() {
        for year in 2000...2100 {
            XCTAssertEqual(kind(year, 6, 19), .clear)
            XCTAssertEqual(kind(year, 8, 1), .clear)
            XCTAssertEqual(kind(year, 6, 20), expected(year, 6, 20, wet: .rain))
            XCTAssertEqual(kind(year, 7, 31), expected(year, 7, 31, wet: .rain))
        }
        XCTAssertTrue((2000...2100).contains { kind($0, 6, 20) == .rain }, "June 20 is inside the window")
        XCTAssertTrue((2000...2100).contains { kind($0, 7, 31) == .rain }, "July 31 is inside the window")
    }

    func testSnowWindowIsDecemberFirstThroughFebruaryEndLeapYearsToo() {
        for year in 2000...2100 {
            XCTAssertEqual(kind(year, 11, 30), .clear)
            XCTAssertEqual(kind(year, 12, 1), expected(year, 12, 1, wet: .snow))
            XCTAssertEqual(kind(year, 12, 31), expected(year, 12, 31, wet: .snow))
            XCTAssertEqual(kind(year, 1, 1), expected(year, 1, 1, wet: .snow), "Dec 31 flows into Jan 1")
            XCTAssertEqual(kind(year, 2, 28), expected(year, 2, 28, wet: .snow))
            XCTAssertEqual(kind(year, 3, 1), .clear)
        }
        let leap = [2000, 2004, 2024, 2028]
        for year in leap { XCTAssertEqual(kind(year, 2, 29), expected(year, 2, 29, wet: .snow), "leap day \(year)") }
        XCTAssertTrue((2000...2100).filter { $0 % 4 == 0 && $0 != 2100 }.contains { kind($0, 2, 29) == .snow }, "Feb 29 is inside")
        XCTAssertTrue((2000...2100).contains { kind($0, 12, 1) == .snow })
        XCTAssertTrue((2000...2100).contains { kind($0, 12, 31) == .snow })
        XCTAssertTrue((2000...2100).contains { kind($0, 1, 1) == .snow })
        XCTAssertTrue((2000...2100).contains { kind($0, 2, 28) == .snow })
    }

    func testOtherDaysAreClear() {
        for (m, d) in [(5, 10), (8, 15), (9, 30), (3, 15), (4, 20), (6, 1)] { XCTAssertEqual(kind(2026, m, d), .clear, "\(m)/\(d)") }
    }

    /// Wet days come from the date alone: the same date gives the same answer, and the window has both kinds of day.
    func testWetDaysAreDeterministicAndMixed() {
        for (m, range) in [(7, 1...31), (12, 1...31), (1, 1...31)] {
            for year in 2020...2030 {
                let wet = range.filter { W.isWetDay(year: year, month: m, day: $0) }.count
                XCTAssertTrue((1..<range.count).contains(wet), "\(year)-\(m): \(wet) wet days")
                XCTAssertEqual(wet, range.filter { W.isWetDay(year: year, month: m, day: $0) }.count, "same answer twice")
            }
        }
        var wet = 0, total = 0
        for year in 2000...2100 { for d in 1...31 { total += 1; if W.isWetDay(year: year, month: 7, day: d) { wet += 1 } } }
        XCTAssertEqual(Double(wet) / Double(total), 0.5, accuracy: 0.08, "about half the days")
        let december = (1...31).map { W.isWetDay(year: 2026, month: 12, day: $0) }
        XCTAssertTrue(december.contains(true) && december.contains(false))
    }

    func testTimeOfDayDoesNotChangeTheDaysWeather() {
        for (y, m, d) in [(2026, 4, 5), (2026, 7, 4), (2026, 12, 25)] {
            let first = W.kind(on: date(y, m, d, 0, 0, 0), calendar: calendar)
            XCTAssertEqual(W.kind(on: date(y, m, d, 23, 59, 59), calendar: calendar), first)
        }
    }

    // MARK: 입자 움직임

    private let screen = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testCountScalesWithAreaAndRespectsTheCap() {
        for k in W.Kind.allCases where k != .clear {
            let small = W.count(k, area: 20_000), medium = W.count(k, area: 100_000)
            XCTAssertGreaterThan(small, 0, "\(k)")
            XCTAssertGreaterThan(medium, small, "\(k) grows with the visible area")
            XCTAssertLessThanOrEqual(W.count(k, area: 10_000_000), W.maxParticles)
            XCTAssertEqual(W.count(k, area: 10_000_000), W.maxParticles, "\(k) saturates at the cap")
        }
        XCTAssertEqual(W.count(.clear, area: 100_000), 0)
        XCTAssertEqual(W.count(.snow, area: 0), 0)
        XCTAssertLessThanOrEqual(W.maxParticles, 120)
    }

    func testFieldIsSeededDeterministically() {
        var a = PlazaWeatherField(kind: .snow, count: 50, in: screen)
        var b = PlazaWeatherField(kind: .snow, count: 50, in: screen)
        XCTAssertEqual(a.particles, b.particles)
        for _ in 0..<100 { a.advance(by: 0.05, in: screen); b.advance(by: 0.05, in: screen) }
        XCTAssertEqual(a.particles, b.particles)
        XCTAssertNotEqual(PlazaWeatherField(kind: .leaves, count: 50, in: screen).particles.map(\.x),
                          PlazaWeatherField(kind: .snow, count: 50, in: screen).particles.map(\.x), "kinds do not share a layout")
    }

    func testParticlesStartInsideTheScreenAndStayOnItWhileFalling() {
        let wrap = screen.insetBy(dx: -PlazaWeatherField.wrapMargin, dy: -PlazaWeatherField.wrapMargin)
        for k in W.Kind.allCases where k != .clear {
            var f = PlazaWeatherField(kind: k, count: 80, in: screen)
            for _ in 0..<600 {
                f.advance(by: 0.1, in: screen)
                XCTAssertTrue(f.particles.allSatisfy { wrap.contains(CGPoint(x: $0.x, y: $0.y)) }, "\(k)")
            }
            XCTAssertEqual(Set(f.particles.map(\.variant)).count, PlazaWeatherArt.grids(k).count, "\(k) uses every picture")
        }
    }

    func testAParticleLeavingTheBottomComesBackAtTheTop() {
        var f = PlazaWeatherField(kind: .snow, count: 40, in: screen)
        let before = f.particles
        var wrapped = 0
        for _ in 0..<100 {
            let last = f.particles
            f.advance(by: 0.1, in: screen)
            for (p, q) in zip(last, f.particles) where q.y > p.y { wrapped += 1; XCTAssertGreaterThan(q.y, screen.maxY - 12, "re-enters at the top") }
        }
        XCTAssertGreaterThan(wrapped, 0, "ten seconds of snow takes some past the bottom")
        XCTAssertNotEqual(before, f.particles)
    }

    func testAParticleLeavingTheSideComesBackOnTheOtherSide() {
        // 비는 오른쪽으로 흐르므로 오른쪽 가장자리를 넘은 입자가 왼쪽에서 돌아온다.
        var f = PlazaWeatherField(kind: .rain, count: 100, in: screen)
        var sideWraps = 0
        for _ in 0..<200 {
            let last = f.particles
            f.advance(by: 0.05, in: screen)
            for (p, q) in zip(last, f.particles) where q.x < p.x - 100 { sideWraps += 1; XCTAssertLessThan(q.x, screen.minX + 20) }
        }
        XCTAssertGreaterThan(sideWraps, 0)
        // 감기 함수 자체: 아래로 넘으면 위로, 음수 쪽으로 넘어도 안으로 돌아온다.
        XCTAssertEqual(PlazaWeatherField.wrap(-3, from: 0, length: 10), 7, accuracy: 1e-9)
        XCTAssertEqual(PlazaWeatherField.wrap(13, from: 0, length: 10), 3, accuracy: 1e-9)
        XCTAssertEqual(PlazaWeatherField.wrap(5, from: 0, length: 0), 0)
    }

    func testEachKindFallsTheWayItShould() {
        func averageMotion(_ k: W.Kind) -> (dx: Double, dy: Double) {
            var f = PlazaWeatherField(kind: k, count: 60, in: screen)
            let start = f.particles
            f.advance(by: 0.1, in: screen)
            let moves = zip(start, f.particles).map { ($1.x - $0.x, $1.y - $0.y) }.filter { abs($0.0) < 50 && abs($0.1) < 50 }
            return (moves.map(\.0).reduce(0, +) / Double(moves.count), moves.map(\.1).reduce(0, +) / Double(moves.count))
        }
        let rain = averageMotion(.rain), snow = averageMotion(.snow), petals = averageMotion(.petals), leaves = averageMotion(.leaves)
        XCTAssertLessThan(rain.dy, snow.dy * 4, "rain falls much faster than snow (y goes down)")
        XCTAssertGreaterThan(rain.dx, 3, "rain is slanted to the right")
        for m in [snow, petals, leaves] { XCTAssertLessThan(m.dy, 0, "everything falls") }
    }

    func testPausedTimeMovesNothing() {
        var f = PlazaWeatherField(kind: .petals, count: 30, in: screen)
        let before = f.particles
        f.advance(by: 0, in: screen)
        XCTAssertEqual(f.particles, before)
    }

    func testArtGridsAreRectangularAndMirroredWhereTheyShouldBe() {
        XCTAssertEqual(PlazaWeatherArt.grids(.clear).count, 0)
        for k in W.Kind.allCases {
            for grid in PlazaWeatherArt.grids(k) { XCTAssertEqual(Set(grid.map(\.count)).count, 1, "\(k) \(grid)") }
            let images = PlazaWeatherArt.images(k)
            XCTAssertEqual(images.count, PlazaWeatherArt.grids(k).count)
            for (image, grid) in zip(images, PlazaWeatherArt.grids(k)) {
                XCTAssertEqual(image.width, grid[0].count)
                XCTAssertEqual(image.height, grid.count)
            }
        }
        XCTAssertEqual(PlazaWeatherArt.grids(.petals)[1], PlazaWeatherArt.grids(.petals)[0].map { String($0.reversed()) })
        XCTAssertEqual(PlazaWeatherArt.grids(.leaves).count, 6, "three colours, each also mirrored")
        XCTAssertEqual(PlazaWeatherArt.grids(.rain)[0].count, 4, "a rain streak is four tall")
    }

    // MARK: 장면

    private let map = PlazaMapData.map

    private func scene(at day: Date, zoom: Int = 2, size: CGSize = CGSize(width: 800, height: 600)) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: zoom, nickname: "나")
        s.backingOverride = 2
        s.size = size
        s.now = { day }
        return s
    }

    private func firstDay(of wanted: W.Kind, year: Int = 2026, month: Int, hour: Int = 12) -> Date {
        for d in 1...28 where kind(year, month, d) == wanted { return date(year, month, d, hour) }
        XCTFail("no \(wanted) day in \(year)-\(month)")
        return date(year, month, 1)
    }

    private var snowDay: Date { firstDay(of: .snow, month: 12) }
    private var clearDay: Date { date(2026, 5, 10) }

    private func run(_ s: PlazaScene, seconds: Double, from start: Double = 0) {
        var t = start
        s.update(t)
        while t < start + seconds { t += 1.0 / 30; s.update(t) }
    }

    func testSceneShowsTheDaysWeather() {
        let cases: [(Date, W.Kind)] = [(date(2026, 4, 5), .petals), (firstDay(of: .rain, month: 7), .rain),
                                       (date(2026, 11, 1), .leaves), (snowDay, .snow), (clearDay, .clear)]
        for (day, wanted) in cases {
            let s = scene(at: day)
            s.update(0)
            XCTAssertEqual(s.weatherKind, wanted)
            XCTAssertEqual(s.weatherParticleCount > 0, wanted != .clear, "\(wanted)")
        }
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

    func testWeatherChangesWhenMidnightEntersANewWindow() {
        var current = date(2026, 3, 31, 23, 59, 59)
        let s = scene(at: current)
        s.now = { current }
        s.update(0)
        XCTAssertEqual(s.weatherKind, .clear)
        XCTAssertEqual(s.weatherParticleCount, 0)
        current = date(2026, 4, 1, 0, 0, 0)
        s.update(0.1)
        XCTAssertEqual(s.weatherKind, .petals)
        XCTAssertGreaterThan(s.weatherParticleCount, 0)
        current = date(2026, 4, 14, 23, 59, 59)
        s.update(0.2)
        XCTAssertEqual(s.weatherKind, .petals)
        current = date(2026, 4, 15, 0, 0, 0)
        s.update(0.3)
        XCTAssertEqual(s.weatherKind, .clear)
        XCTAssertEqual(s.weatherParticleCount, 0)
    }

    func testWeatherLayerSitsAboveCharactersAndBelowTheDaylightMultiply() {
        let s = scene(at: snowDay)
        let layer = s.children.first { $0 is PlazaWeatherLayer }
        XCTAssertNotNil(layer)
        XCTAssertGreaterThan(layer?.zPosition ?? 0, 2, "characters are 1...2")
        XCTAssertLessThan(layer?.zPosition ?? 9, 5, "the daylight multiply is 5, name plates 10")
    }

    func testSpritesAreReusedAcrossFrames() {
        let layer = PlazaWeatherLayer()
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        layer.update(date: snowDay, isHidden: false, dt: 0, visible: rect, step: 0.25)
        let first = layer.children
        XCTAssertFalse(first.isEmpty)
        for _ in 1...30 { layer.update(date: snowDay, isHidden: false, dt: 0.03, visible: rect, step: 0.25) }
        XCTAssertTrue(zip(first, layer.children).allSatisfy { $0 === $1 }, "no nodes made in steady state")
        XCTAssertEqual(first.count, layer.children.count)
        XCTAssertTrue(layer.children.allSatisfy { ($0 as? SKSpriteNode)?.texture?.filteringMode == .nearest })
    }

    func testTheDayIsNotRecalculatedWithinTheDay() {
        let layer = PlazaWeatherLayer()
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        layer.update(date: date(2026, 4, 5, 8), isHidden: false, dt: 0, visible: rect, step: 0.25)
        XCTAssertEqual(layer.kind, .petals)
        layer.update(date: date(2026, 4, 5, 23, 59, 59), isHidden: false, dt: 0, visible: rect, step: 0.25)
        XCTAssertEqual(layer.kind, .petals)
        layer.update(date: date(2026, 4, 20, 8), isHidden: false, dt: 0, visible: rect, step: 0.25)
        XCTAssertEqual(layer.kind, .clear, "a later date outside the cached day is looked up again")
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
        XCTAssertEqual(scene(at: clearDay).photoInput()?.weather.count, 0)
    }

    func testPhotoDrawsTheParticlesAndLeavesAClearDayAlone() throws {
        let snowy = scene(at: snowDay), clear = scene(at: clearDay)
        for s in [snowy, clear] { run(s, seconds: 1) }
        let input = try XCTUnwrap(snowy.photoInput())
        let withSnow = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        let without = try XCTUnwrap(PlazaPhotoRenderer.render(XCTUnwrap(clear.photoInput())))
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
        var day = night
        for d in 1...28 where kind(2026, 12, d) == .snow { day = date(2026, 12, d, 23, 0); break }
        let s = scene(at: day)
        run(s, seconds: 1)
        var input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.tint, PlazaDaylight.night)
        let tinted = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        let flake = try XCTUnwrap(plusFlake(input))
        let at = centerPixel(flake, input: input)
        let p = pixel(tinted, at.x, at.y)
        XCTAssertEqual(Double(p.r), 246 * PlazaDaylight.night.red, accuracy: 3)
        XCTAssertEqual(Double(p.b), 255 * PlazaDaylight.night.blue, accuracy: 3)
        XCTAssertLessThan(p.r, p.b, "night snow is blue, not white")
        input.tint = .none
        XCTAssertGreaterThan(pixel(try XCTUnwrap(PlazaPhotoRenderer.render(input)), at.x, at.y).r, 0xF0)
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
        s.setCharacter(PlazaCharacterFrames(front: [PlazaFrame(image: red, delay: 0.1)], back: [PlazaFrame(image: red, delay: 0.1)]))
        s.update(0)
        var input = try XCTUnwrap(s.photoInput())
        input.weather = []
        let base = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        let blanket = PlazaWeatherArt.images(.snow)[2]   // 흰 한 칸
        input.weather = [PlazaPhotoParticle(image: blanket, origin: input.visibleRect.origin, size: input.visibleRect.size)]
        let covered = try XCTUnwrap(PlazaPhotoRenderer.render(input))
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
