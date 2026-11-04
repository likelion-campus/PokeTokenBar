import CoreGraphics
import XCTest
@testable import PokeTokenBar

final class PlazaCampfireArtTests: XCTestCase {
    /// RGBA 바이트(위에서 아래). 비투명 픽셀의 색은 알파가 255일 때만 정확하다.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func color(_ p: [UInt8], _ i: Int) -> UInt32 {
        UInt32(p[i * 4]) << 16 | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2])
    }

    func testFramesLoopWithoutAJump() {
        for state in [PlazaCampfireArt.State.lit, .ended] {
            let f = (0..<12).map { pixels(PlazaCampfireArt.image(state, phase: $0, scale: 1)) }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).filter { $0 != $1 }.count }
            let steps = (0..<11).map { diff(f[$0], f[$0 + 1]) }
            let seam = diff(f[11], f[0])
            XCTAssertGreaterThan(steps.max()!, 0)
            XCTAssertLessThanOrEqual(Double(seam), Double(steps.max()!) * 1.5, "\(state): frame 11 -> 0 jumps")
        }
    }

    func testArtIsDeterministic() {
        for state in [PlazaCampfireArt.State.ready, .lit, .ended] {
            XCTAssertEqual(pixels(PlazaCampfireArt.image(state, phase: 3, scale: 2)),
                           pixels(PlazaCampfireArt.image(state, phase: 3, scale: 2)))
        }
        XCTAssertEqual(PlazaCampfireArt.frames(.ready).count, 1)
        XCTAssertEqual(PlazaCampfireArt.frames(.lit).count, 12)
        XCTAssertEqual(PlazaCampfireArt.frames(.ended).count, 12)
        XCTAssertEqual(PlazaCampfireArt.frames(.lit)[0].width, 32 * 8)
        XCTAssertEqual(PlazaCampfireArt.frames(.lit)[0].height, 40 * 8)
    }

    /// 아래에서 센 칸 줄 번호가 rows 범위 안인 곳에 껍질 색이 있는지.
    private func hasBark(_ image: CGImage, rows: ClosedRange<Int>) -> Bool {
        let p = pixels(image)
        for py in 0..<image.height {
            let row = image.height - 1 - py
            guard rows.contains(row) else { continue }
            for x in 0..<image.width where p[(py * image.width + x) * 4 + 3] == 255 {
                let c = color(p, py * image.width + x)
                if c == 0x79584F || c == 0x94785C { return true }
            }
        }
        return false
    }

    func testLitLogsStayUnderTheFlames() {
        for phase in 0..<12 {
            XCTAssertFalse(hasBark(PlazaCampfireArt.image(.lit, phase: phase, scale: 1), rows: 13...39), "phase \(phase)")
        }
        XCTAssertTrue(hasBark(PlazaCampfireArt.image(.ready, phase: 0, scale: 1), rows: 6...11))
    }

    func testArtUsesOnlyThePalette() {
        let a = PlazaCampfireArt.self
        let palette: Set<UInt32> = [a.ink, a.inkSoft, a.bark0, a.bark1, a.bark2, a.bark3, a.bark4, a.cut0, a.cut1,
                                    a.stone0, a.stone1, a.stone2, a.stone3, a.grass0, a.grass1,
                                    0xFFF4C2, 0xF8CF3A, 0xF08A24, 0xD8382E, 0x9E2A1E,
                                    0xF8A030, 0xC0401E, 0x8E2A1C, 0xFFE070]
        func isSmokeBlend(_ c: UInt32) -> Bool {
            func ch(_ v: UInt32, _ s: UInt32) -> Int { Int(v >> s & 0xFF) }
            return palette.contains { p in
                [UInt32(16), 8, 0].allSatisfy { s in
                    let lo = min(ch(p, s), ch(a.stone3, s)) - 1, hi = max(ch(p, s), ch(a.stone3, s)) + 1
                    return (lo...hi).contains(ch(c, s))
                }
            }
        }
        for state in [PlazaCampfireArt.State.ready, .lit, .ended] {
            for phase in 0..<(state == .ready ? 1 : 12) {
                let img = PlazaCampfireArt.image(state, phase: phase, scale: 1)
                let p = pixels(img)
                for i in 0..<(img.width * img.height) where p[i * 4 + 3] > 0 {
                    if p[i * 4 + 3] < 255 { XCTAssertEqual(state, .ended); continue }
                    let c = color(p, i)
                    if palette.contains(c) { continue }
                    XCTAssertEqual(state, .ended, "\(state) \(phase) \(String(c, radix: 16))")
                    XCTAssertTrue(isSmokeBlend(c), "\(phase) \(String(c, radix: 16))")
                }
            }
        }
    }

    func testLightIsOffInDaylightAndFullAtNight() {
        XCTAssertEqual(PlazaCampfireLight.strength(.none), 0)
        XCTAssertEqual(PlazaCampfireLight.strength(PlazaDaylight.night), 1, accuracy: 1e-12)
        let m = PlazaCampfireLight.multiplier(tint: .none, mix: 1)
        XCTAssertEqual([m.r, m.g, m.b], [1, 1, 1])
        // 밤보다 어두운 색은 1로 잘리고, 낮보다 밝은 색은 0으로 잘린다.
        XCTAssertEqual(PlazaCampfireLight.strength(PlazaDaylight.Tint(red: 0.1, green: 0.1, blue: 0.1)), 1)
        XCTAssertEqual(PlazaCampfireLight.strength(PlazaDaylight.Tint(red: 1.2, green: 1.2, blue: 1.2)), 0)
    }

    func testNightLightLiftsTowardWarmDaylight() {
        let m = PlazaCampfireLight.multiplier(tint: PlazaDaylight.night, mix: 1)
        XCTAssertEqual(m.r, 2.0, accuracy: 1e-9)
        XCTAssertEqual(m.g, 0.84 / 0.48, accuracy: 1e-9)
        XCTAssertEqual(m.b, 0.62 / 0.78, accuracy: 1e-9)
    }

    func testRingsAndFlicker() {
        // 사용자가 정한 반경: 150 × 104 → 190 × 132 → 285 × 198 → 다시 2배인 570 × 396.
        XCTAssertEqual(PlazaCampfireLight.radii, CGSize(width: 570, height: 396))
        XCTAssertEqual(PlazaCampfireLight.mix(normalizedDistance: 0.3), 1)
        XCTAssertEqual(PlazaCampfireLight.mix(normalizedDistance: 0.5), 0.78)
        XCTAssertEqual(PlazaCampfireLight.mix(normalizedDistance: 0.7), 0.52)
        XCTAssertEqual(PlazaCampfireLight.mix(normalizedDistance: 0.9), 0.26)
        XCTAssertEqual(PlazaCampfireLight.mix(normalizedDistance: 1.0), 0)
        XCTAssertEqual(PlazaCampfireLight.flicker(phase: 0), PlazaCampfireLight.flicker(phase: 12), accuracy: 1e-12)
        for phase in 0..<12 {
            XCTAssertTrue((0.925...1.075).contains(PlazaCampfireLight.flicker(phase: phase)))
        }
    }

    func testLightCenterSitsUnderTheFlames() throws {
        let tiles = [TilePoint(x: 36, y: 23), TilePoint(x: 37, y: 23), TilePoint(x: 36, y: 24), TilePoint(x: 37, y: 24)]
        let c = try XCTUnwrap(PlazaCampfireLight.center(campfireTiles: tiles))
        XCTAssertEqual(c.x, 37 * 32)
        XCTAssertEqual(c.y, 25 * 32 - 14)
        XCTAssertNil(PlazaCampfireLight.center(campfireTiles: []))
    }
}

extension PlazaCampfireArtTests {
    func testLitLogCellsAreClippedBelowRowTen() {
        let logs = PlazaCampfireArt.litLogs()
        XCTAssertTrue(logs.filled(10, 5))
        for y in 10..<logs.h { for x in 0..<logs.w { XCTAssertFalse(logs.filled(x, y)) } }
    }
}
