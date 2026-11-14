import XCTest
@testable import PokeTokenBar

@MainActor
final class PlazaWeatherTests: XCTestCase {
    typealias W = PlazaWeather
    let calendar: Calendar = PlazaWeather.gregorian

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    // MARK: 계절

    /// A fixed season is that season on any date; only `auto` reads the calendar.
    func testAFixedSeasonIgnoresTheDate() async {
        for (y, m, d) in [(2026, 4, 5), (2026, 7, 1), (2026, 11, 13), (2027, 1, 10)] {
            XCTAssertEqual(PlazaSeasonChoice.spring.season(on: date(y, m, d), calendar: calendar), .spring)
            XCTAssertEqual(PlazaSeasonChoice.summer.season(on: date(y, m, d), calendar: calendar), .summer)
            XCTAssertEqual(PlazaSeasonChoice.autumn.season(on: date(y, m, d), calendar: calendar), .autumn)
            XCTAssertEqual(PlazaSeasonChoice.winter.season(on: date(y, m, d), calendar: calendar), .winter)
        }
    }

    /// March to May is spring, June to August summer, September to November autumn, December to February winter.
    func testAutoFollowsTheCalendarMonthAndTurnsAtMidnight() async {
        let want: [PlazaSeason] = [.winter, .winter, .spring, .spring, .spring, .summer, .summer, .summer, .autumn, .autumn, .autumn, .winter]
        for m in 1...12 {
            XCTAssertEqual(PlazaSeasonChoice.auto.season(on: date(2026, m, 15), calendar: calendar), want[m - 1], "month \(m)")
        }
        XCTAssertEqual(PlazaSeasonChoice.auto.season(on: date(2026, 2, 28, 23, 59, 59), calendar: calendar), .winter)
        XCTAssertEqual(PlazaSeasonChoice.auto.season(on: date(2026, 3, 1, 0, 0, 0), calendar: calendar), .spring)
        XCTAssertEqual(PlazaSeasonChoice.auto.season(on: date(2026, 11, 30, 23, 59, 59), calendar: calendar), .autumn)
        XCTAssertEqual(PlazaSeasonChoice.auto.season(on: date(2026, 12, 1, 0, 0, 0), calendar: calendar), .winter)
    }

    /// Unknown strings, and the period words v2.5.632 and earlier wrote, read as winter.
    func testTheWireValueReadsUnknownWordsAsWinter() async {
        for word in ["day", "week", "month", "", "quarter", "Spring"] { XCTAssertEqual(PlazaSeasonChoice(wire: word), .winter, word) }
        for c in PlazaSeasonChoice.allCases { XCTAssertEqual(PlazaSeasonChoice(wire: c.rawValue), c) }
        XCTAssertLessThanOrEqual(PlazaSeasonChoice.allCases.map(\.rawValue.utf8.count).max()!, 16, "fits the schedule's bound")
    }

    func testEachSeasonHasItsOwnWeather() async {
        XCTAssertEqual(PlazaSeason.allCases.map(\.weather), [.petals, .greenLeaves, .leaves, .snow])
    }

    // MARK: 입자 움직임

    let screen = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testCountScalesWithAreaAndRespectsTheCap() async {
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

    func testFieldIsSeededDeterministically() async {
        var a = PlazaWeatherField(kind: .snow, count: 50, in: screen)
        var b = PlazaWeatherField(kind: .snow, count: 50, in: screen)
        XCTAssertEqual(a.particles, b.particles)
        for _ in 0..<100 { a.advance(by: 0.05, in: screen); b.advance(by: 0.05, in: screen) }
        XCTAssertEqual(a.particles, b.particles)
        XCTAssertNotEqual(PlazaWeatherField(kind: .leaves, count: 50, in: screen).particles.map(\.x),
                          PlazaWeatherField(kind: .snow, count: 50, in: screen).particles.map(\.x), "kinds do not share a layout")
    }

    func testParticlesStartInsideTheScreenAndStayOnItWhileFalling() async {
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

    func testAParticleLeavingTheBottomComesBackAtTheTop() async {
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

    func testAParticleLeavingTheSideComesBackOnTheOtherSide() async {
        // 초록 잎은 오른쪽으로 흐르므로 오른쪽 가장자리를 넘은 입자가 왼쪽에서 돌아온다.
        var f = PlazaWeatherField(kind: .greenLeaves, count: 100, in: screen)
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

    func testEachKindFallsTheWayItShould() async {
        func averageMotion(_ k: W.Kind) -> (dx: Double, dy: Double) {
            var f = PlazaWeatherField(kind: k, count: 60, in: screen)
            let start = f.particles
            f.advance(by: 0.1, in: screen)
            let moves = zip(start, f.particles).map { ($1.x - $0.x, $1.y - $0.y) }.filter { abs($0.0) < 50 && abs($0.1) < 50 }
            return (moves.map(\.0).reduce(0, +) / Double(moves.count), moves.map(\.1).reduce(0, +) / Double(moves.count))
        }
        for k in W.Kind.allCases where k != .clear { XCTAssertLessThan(averageMotion(k).dy, 0, "\(k) falls (y goes down)") }
        XCTAssertGreaterThan(averageMotion(.leaves).dy, averageMotion(.snow).dy * 3, "nothing falls fast; snow drifts down slowest")
    }

    func testPausedTimeMovesNothing() async {
        var f = PlazaWeatherField(kind: .petals, count: 30, in: screen)
        let before = f.particles
        f.advance(by: 0, in: screen)
        XCTAssertEqual(f.particles, before)
    }

    func testArtGridsAreRectangularAndMirroredWhereTheyShouldBe() async {
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
        XCTAssertEqual(PlazaWeatherArt.grids(.greenLeaves).count, 4, "two greens, each also mirrored")
    }

    func testSpritesAreReusedAcrossFrames() async {
        let layer = PlazaWeatherLayer()
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        layer.update(weather: .snow, isHidden: false, dt: 0, visible: rect, step: 0.25)
        let first = layer.root.children
        XCTAssertFalse(first.isEmpty)
        for _ in 1...30 { layer.update(weather: .snow, isHidden: false, dt: 0.03, visible: rect, step: 0.25) }
        XCTAssertTrue(zip(first, layer.root.children).allSatisfy { $0 === $1 }, "no nodes made in steady state")
        XCTAssertEqual(first.count, layer.root.children.count)
        XCTAssertTrue(layer.root.children.allSatisfy { ($0 as? PlazaSprite)?.texture != nil })
    }

    /// 기본 달력은 시스템 달력(일본력·불기 등)이 아니라 그레고리력이다. 그래야 팀원 모두 같은 계절을 본다.
    func testTheDefaultCalendarIsGregorianWhateverTheSystemCalendar() async {
        XCTAssertEqual(W.gregorian.identifier, .gregorian)
        XCTAssertEqual(W.gregorian.timeZone, TimeZone.current)
        let when = date(2026, 11, 9)
        XCTAssertEqual(PlazaSeasonChoice.auto.season(on: when), PlazaSeasonChoice.auto.season(on: when, calendar: calendar))
    }
}
