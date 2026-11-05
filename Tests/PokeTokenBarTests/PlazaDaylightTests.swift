import XCTest
import AppKit
import SwiftUI
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
        // 코어타임(10~16시)은 내내 밝다.
        XCTAssertEqual(D.tint(minute: 10 * 60), .none, "bright from 10:00")
        XCTAssertEqual(D.tint(minute: 16 * 60), .none, "still bright at 16:00; the evening glow starts fading in")
        XCTAssertEqual(D.tint(minute: 16 * 60 + 30), D.dusk, "orange at its deepest at 16:30")
        let five = D.tint(minute: 17 * 60)
        for (got, want) in [(five.red, D.night.red), (five.green, D.night.green), (five.blue, D.night.blue)] {
            XCTAssertEqual(got, want, accuracy: 1e-9, "dark from 17:00")
        }
        XCTAssertEqual(D.tint(minute: 9 * 60), D.night, "still dark at 9:00")
        XCTAssertEqual(D.tint(minute: 9 * 60 + 30), D.dawn, "the morning glow is deepest at 9:30")
        XCTAssertEqual(D.tint(minute: 7 * 60), D.night, "dark before the morning glow")
        XCTAssertEqual(D.tint(minute: 0), D.tint(minute: 24 * 60), "midnight meets itself")
    }

    /// Each glow fades in and out over half an hour, so a quarter past is halfway between.
    func testFadeIsHalfwayAtTheQuarterHour() {
        let half = D.tint(minute: 16 * 60 + 15)
        XCTAssertEqual(half.red, (1 + D.dusk.red) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.blue, (1 + D.dusk.blue) / 2, accuracy: 1e-9)
        let morning = D.tint(minute: 9 * 60 + 45)
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

    /// No jumps: a minute later is never much darker or lighter. The steepest fade (evening glow to night over half an
    /// hour) moves the three channels by about 0.035 a minute.
    func testTintChangesSmoothlyAllDay() {
        var last = D.tint(minute: 0)
        for m in 1...(24 * 60) {
            let t = D.tint(minute: Double(m))
            XCTAssertLessThan(abs(t.red - last.red) + abs(t.green - last.green) + abs(t.blue - last.blue), 0.04, "minute \(m)")
            last = t
        }
    }

    /// The minimap loses colour toward night, smoothly, and is untouched by day.
    func testMinimapSaturationFollowsTheTime() {
        XCTAssertEqual(D.minimapSaturation(minute: 12 * 60), 1)
        XCTAssertEqual(D.minimapSaturation(minute: 22 * 60), 0.65)
        XCTAssertEqual(D.minimapSaturation(minute: 16 * 60 + 30), 0.95)
        XCTAssertEqual(D.minimapSaturation(minute: 17 * 60), 0.65)
        XCTAssertEqual(D.minimapSaturation(minute: 9 * 60 + 30), 0.85)
        let all = (0...(24 * 60)).map { D.minimapSaturation(minute: Double($0)) }
        XCTAssertEqual(all.min(), 0.65, "night is the greyest")
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { abs($0 - $1) < 0.011 }, "no jumps")
    }

    /// The minimap's map follows the time like the plaza: darker, bluer and greyer at night. With the background
    /// hidden it does not change, as the plaza does not.
    func testMinimapMapFollowsTheTime() throws {
        let map = NSImage(size: NSSize(width: 48, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.43, green: 0.73, blue: 0.33, alpha: 1).setFill(); rect.fill(); return true
        }
        func corner(hour: Int, hidden: Bool = false) throws -> (r: Int, g: Int, b: Int) {
            let background = PlazaBackgroundModel()
            background.isHidden = hidden
            let view = PlazaMinimapView(model: PlazaMinimapModel(), background: background, mapImage: map,
                                        worldSize: PlazaMapData.map.pixelSize, fixedDate: at(hour, 0))
            let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let i = (12 * image.width + 12) * 4   // inside the map, clear of the frame and any dot
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        let noon = try corner(hour: 12), night = try corner(hour: 22)
        XCTAssertLessThan(night.g, noon.g - 40, "darker at night")
        XCTAssertLessThan(night.g - night.r, noon.g - noon.r, "and less green (greyer, bluer)")
        XCTAssertGreaterThan(night.b * noon.g, noon.b * night.g, "blue holds up better than green")
        let hiddenNoon = try corner(hour: 12, hidden: true), hiddenNight = try corner(hour: 22, hidden: true)
        XCTAssertEqual(hiddenNight.r, hiddenNoon.r)
        XCTAssertEqual(hiddenNight.g, hiddenNoon.g)
    }

    func testPhaseBoundaries() {
        let cases: [(Int, Int, D.Phase)] = [(8, 59, .night), (9, 0, .dawn), (9, 59, .dawn), (10, 0, .day), (15, 59, .day),
                                             (16, 0, .dusk), (16, 59, .dusk), (17, 0, .night), (0, 0, .night), (7, 0, .night)]
        for (h, m, phase) in cases {
            XCTAssertEqual(D.phase(minute: Double(h * 60 + m)), phase, "\(h):\(m)")
        }
    }

    func testClockTextShowsThePhaseAndTwentyFourHourTime() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(D.clockText(at(21, 34, calendar: seoul), calendar: seoul), "밤 21:34")
        XCTAssertEqual(D.clockText(at(10, 5, calendar: seoul), calendar: seoul), "낮 10:05")
        XCTAssertEqual(D.clockText(at(9, 30, calendar: seoul), calendar: seoul), "아침 09:30")
        XCTAssertEqual(D.clockText(at(16, 30, calendar: seoul), calendar: seoul), "저녁 16:30")
        XCTAssertEqual(D.clockText(at(17, 0, calendar: seoul), calendar: seoul), "밤 17:00")
        XCTAssertEqual(D.clockText(at(7, 5, calendar: seoul), calendar: seoul), "밤 07:05")
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
