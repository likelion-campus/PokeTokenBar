import XCTest
import SpriteKit
@testable import PokeTokenBar

/// Frame cost of the plaza scene (windows-port Track A, Task 1). Mac only.
/// `PTB_PLAZA_FRAMECOST_OUT=<file>` appends one line `update <ms/frame> render <ms/frame>`; frames from `PTB_PLAZA_FRAMECOST_FRAMES` (default 3000).
@MainActor
final class PlazaFrameCostHarness: XCTestCase {
    /// 12 teammates on seeded routes, winter snow, fireworks every 0.5 s, footprints at cap, campfire lit at night,
    /// three swimmers splashing, me walking.
    private func rushHour() -> (PlazaRenderScenes.Stage, (Int) -> Void) {
        var o = PlazaRenderScenes.Options()
        o.season = .winter; o.hour = 23; o.me = TilePoint(x: 20, y: 10)
        let s = PlazaRenderScenes.stage(o)
        let names = (0..<12).map { "m\($0)" }
        let looks: [PlazaRenderLook] = [.ash, .brock, .misty, .dawn]
        var list: [PlazaSceneMember] = []
        var lookMap: [String: PlazaRenderLook] = [:]
        for (i, n) in names.enumerated() {
            let swimming = i < 3
            list.append(PlazaRenderScenes.member(n, n, swimming ? 6 + i : 14 + i, swimming ? 14 : 8 + i % 4, walking: !swimming))
            lookMap[n] = looks[i % 4]
        }
        s.put(list, looks: lookMap)
        s.scene.campfireLit = true
        s.scene.setCampfireTimer("24:59")
        // routes: a fixed rng picks the next tile every second; a firework every 30 frames; me keeps pacing
        var rng = PlazaSplitMix64(seed: 0xC0FFEE)
        let step: (Int) -> Void = { f in
            s.clock.date(at: f, base: s.base)
            if f % 60 == 0 {
                for (i, n) in names.enumerated() where i >= 3 {
                    let x = 12 + Int(rng.next() % 16), y = 7 + Int(rng.next() % 8)
                    if PlazaRenderScenes.map.isWalkable(TilePoint(x: x, y: y)) { s.move(n, to: TilePoint(x: x, y: y), walking: true) }
                }
            }
            if f % 30 == 0 { _ = s.scene.playFirework(memberID: names[(f / 30) % 12], style: PlazaFireworks.styles[(f / 30) % PlazaFireworks.styles.count].id) }
            if f % 20 == 0 { s.move(names[f / 20 % 3], diving: (f / 20) % 2 == 0) }
            if f % 240 == 0 { PlazaRenderScenes.release(s, 123); PlazaRenderScenes.press(s, 124) }
            if f % 240 == 120 { PlazaRenderScenes.release(s, 124); PlazaRenderScenes.press(s, 123) }
        }
        return (s, step)
    }

    func testFrameCost() throws {
        guard let out = PlazaRenderEnv.value("PTB_PLAZA_FRAMECOST_OUT") else { throw XCTSkip("PTB_PLAZA_FRAMECOST_OUT not set") }
        let frames = PlazaRenderEnv.value("PTB_PLAZA_FRAMECOST_FRAMES").flatMap(Int.init) ?? 3000
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }

        let (s, step) = rushHour()
        for f in 0..<120 { step(f); s.scene.update(Double(f) / 60) }   // warm-up, not timed
        let updateMs = ms(clock.measure { for f in 120..<(120 + frames) { step(f); s.scene.update(Double(f) / 60) } })

        let renderer = try XCTUnwrap(PlazaOffscreenRenderer(), "no Metal device")
        let (r, rstep) = rushHour()
        let sk = PlazaRenderHarness.skScene(of: r.scene)
        let size = PlazaRenderScenes.viewport
        let pixels = (width: Int(size.width * 2), height: Int(size.height * 2))
        for f in 0..<30 { rstep(f); renderer.pass(sk, points: size, pixels: pixels, time: Double(f) / 60) }
        let renderMs = ms(clock.measure { for f in 30..<330 { rstep(f); renderer.pass(sk, points: size, pixels: pixels, time: Double(f) / 60) } })
        let line = String(format: "update %.4f render %.4f\n", updateMs / Double(frames), renderMs / 300)
        let url = URL(fileURLWithPath: out)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (old + line).write(to: url, atomically: true, encoding: .utf8)
    }
}
