import XCTest
import AppKit
@testable import PokeTokenBar

@MainActor
final class PlazaDaylightTests: XCTestCase {
    private typealias D = PlazaDaylight

    private func at(_ hour: Int, _ minute: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!
    }

    func testTintAtTheKeyTimes() {
        XCTAssertEqual(D.tint(minute: 12 * 60), .none, "noon is untinted")
        XCTAssertEqual(D.tint(minute: 2 * 60), D.night)
        XCTAssertEqual(D.tint(minute: 23 * 60 + 59), D.night)
        XCTAssertEqual(D.tint(minute: 18 * 60), D.dusk)
        XCTAssertEqual(D.tint(minute: 6 * 60), D.dawn)
        XCTAssertEqual(D.tint(minute: 0), D.tint(minute: 24 * 60), "midnight meets itself")
    }

    /// Halfway between day and evening the plaza is halfway to the evening colour, so it fades in.
    func testFadeIsHalfwayAtTheHalfHour() {
        let half = D.tint(minute: 17 * 60 + 30)
        XCTAssertEqual(half.red, (1 + D.dusk.red) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.blue, (1 + D.dusk.blue) / 2, accuracy: 1e-9)
        let morning = D.tint(minute: 6 * 60 + 30)
        XCTAssertEqual(morning.green, (D.dawn.green + 1) / 2, accuracy: 1e-9)
    }

    /// Night is the darkest time and the evening is warm: red is kept more than blue.
    func testNightIsDarkestAndEveningIsWarm() {
        let all = (0..<(24 * 60)).map { D.tint(minute: Double($0)) }
        let darkest = all.min { $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue }
        XCTAssertEqual(darkest, D.night)
        XCTAssertGreaterThan(D.dusk.red, D.dusk.blue)
        XCTAssertGreaterThan(D.night.blue, D.night.red, "night is blue")
    }

    /// No jumps: a minute later is never much darker or lighter.
    func testTintChangesSmoothlyAllDay() {
        var last = D.tint(minute: 0)
        for m in 1...(24 * 60) {
            let t = D.tint(minute: Double(m))
            XCTAssertLessThan(abs(t.red - last.red) + abs(t.green - last.green) + abs(t.blue - last.blue), 0.03, "minute \(m)")
            last = t
        }
    }

    func testPhaseBoundaries() {
        let cases: [(Int, Int, D.Phase)] = [(4, 59, .night), (5, 0, .dawn), (6, 59, .dawn), (7, 0, .day), (16, 59, .day),
                                             (17, 0, .dusk), (18, 59, .dusk), (19, 0, .night), (0, 0, .night)]
        for (h, m, phase) in cases {
            XCTAssertEqual(D.phase(minute: Double(h * 60 + m)), phase, "\(h):\(m)")
        }
    }

    func testClockTextShowsThePhaseAndTwentyFourHourTime() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(D.clockText(at(21, 34, calendar: seoul), calendar: seoul), "밤 21:34")
        XCTAssertEqual(D.clockText(at(7, 5, calendar: seoul), calendar: seoul), "낮 07:05")
        XCTAssertEqual(D.clockText(at(5, 30, calendar: seoul), calendar: seoul), "새벽 05:30")
        XCTAssertEqual(D.clockText(at(18, 0, calendar: seoul), calendar: seoul), "저녁 18:00")
    }

    private func scene(at date: Date) -> PlazaScene {
        let map = PlazaMapData.map
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.size = CGSize(width: 400, height: 300)
        s.now = { date }
        return s
    }

    /// The plaza is tinted by this Mac's time, and not at all while the background is hidden (the window shows the
    /// desktop then, which a tint would darken).
    func testSceneTintFollowsTheTimeAndSkipsAHiddenBackground() {
        let night = scene(at: at(22, 0))
        night.update(0)
        func close(_ a: D.Tint?, _ b: D.Tint) -> Bool {
            guard let a else { return false }
            return abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue) < 0.01
        }
        XCTAssertTrue(close(night.shownDaylight, D.night))
        night.setBackgroundHidden(true)
        XCTAssertNil(night.shownDaylight)
        XCTAssertEqual(night.daylightTint, .none, "and the photo is not tinted either")
        night.setBackgroundHidden(false)
        XCTAssertTrue(close(night.shownDaylight, D.night))
        let noon = scene(at: at(12, 0))
        noon.update(0)
        XCTAssertNil(noon.shownDaylight)
    }

    func testPhotoOfANightPlazaIsTintedToo() throws {
        let s = scene(at: at(22, 0))
        s.update(0)
        XCTAssertEqual(try XCTUnwrap(s.photoInput()).tint, D.night)
    }

    /// The photo tints the map and characters, but not name tags or bubbles, as the plaza does.
    func testPhotoTintsTheMapButNotTheNameTag() throws {
        func solid(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> CGImage {
            var d = [UInt8](repeating: 255, count: w * h * 4)
            for i in stride(from: 0, to: d.count, by: 4) { d[i] = rgb.0; d[i + 1] = rgb.1; d[i + 2] = rgb.2 }
            let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let white = solid(4, 2, (255, 255, 255))
        let actor = PlazaPhotoActor(image: solid(2, 2, (255, 255, 255)), flipped: false, foot: CGPoint(x: 10, y: 15), scale: 1,
                                    shadow: nil, shadowRect: .zero, plate: white, bubble: nil)
        let input = PlazaPhotoInput(mapImage: solid(20, 20, (255, 255, 255)), visibleRect: CGRect(x: 0, y: 0, width: 20, height: 20),
                                    pixelsPerWorld: 1, actors: [actor], tint: D.night)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        var px = [UInt8](repeating: 0, count: photo.width * photo.height * 4)
        let ctx = CGContext(data: &px, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: photo.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        func red(_ x: Int, _ y: Int) -> UInt8 { px[(y * photo.width + x) * 4] }   // row 0 is the top
        XCTAssertEqual(Double(red(1, 1)), 255 * D.night.red, accuracy: 2, "the map is darkened by the night colour")
        XCTAssertEqual(Double(red(10, 14)), 255 * D.night.red, accuracy: 2, "so is the character")
        // The plate sits above the character (rows 13-14) with a small gap; find a pure white pixel above it.
        let plateRows = (0..<13).filter { y in (8..<12).contains { red($0, y) == 255 } }
        XCTAssertFalse(plateRows.isEmpty, "the name tag stays untinted")
    }
}
