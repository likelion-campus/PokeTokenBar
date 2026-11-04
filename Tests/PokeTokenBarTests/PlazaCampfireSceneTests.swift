import XCTest
import AppKit
@testable import PokeTokenBar

@MainActor
final class PlazaCampfireSceneTests: XCTestCase {
    private let map = PlazaMapData.map

    private func newScene() -> PlazaScene {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        scene.backingOverride = 2
        scene.size = CGSize(width: 800, height: 600)
        return scene
    }

    private func at(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    /// Steps `update` with the given game-time increment, starting from `t`; returns the new time.
    @discardableResult
    private func step(_ scene: PlazaScene, from t: TimeInterval, seconds: TimeInterval, dt: TimeInterval = 0.05) -> TimeInterval {
        var t = t
        let end = t + seconds
        while t < end - 1e-9 { t += dt; scene.update(t) }
        return t
    }

    func testPitIsReadyUntilLitAndFlickersByFrameTime() {
        let scene = newScene()
        scene.update(0)
        XCTAssertEqual(scene.campfireState, .ready)
        scene.campfireLit = true
        XCTAssertEqual(scene.campfireState, .lit)
        // Mid-frame samples every 0.09 s: 0.045 steps, odd steps sit in the middle of frame (i - 1) / 2.
        var t = 0.0
        var seen: [Int] = []
        for i in 1...26 {
            t += 0.045
            scene.update(t)
            if i % 2 == 1 { seen.append(scene.campfirePhase) }
        }
        XCTAssertEqual(seen, Array(0..<12) + [0], "13 frames of 0.09 s wrap 12 back to 0")
        let phase = scene.campfirePhase
        for _ in 0..<10 { scene.update(t) }   // zero dt
        XCTAssertEqual(scene.campfirePhase, phase)
    }

    /// A paused (hidden) scene never saw the fire go out, so it must not queue smoke for whenever it is shown next.
    func testNoSmokeQueuesWhileThePausedSceneLosesTheFire() {
        let scene = newScene()
        scene.update(0)
        scene.campfireLit = true
        scene.isPaused = true
        scene.campfireLit = false
        scene.isPaused = false
        XCTAssertEqual(scene.campfireState, .ready)
    }

    func testSmokeShowsFifteenSecondsAfterTheFireGoesOut() {
        let scene = newScene()
        scene.update(0)
        scene.campfireLit = true
        var t = step(scene, from: 0, seconds: 1)
        scene.campfireLit = false
        XCTAssertEqual(scene.campfireState, .ended)
        t = step(scene, from: t, seconds: 14.9)
        XCTAssertEqual(scene.campfireState, .ended)
        t = step(scene, from: t, seconds: 0.2)
        XCTAssertEqual(scene.campfireState, .ready)
    }

    /// Lighting the fire again and putting it out starts a fresh 15 s smoke, not the rest of the first one.
    func testASecondExtinguishStartsAFreshSmoke() {
        let scene = newScene()
        scene.update(0)
        scene.campfireLit = true
        var t = step(scene, from: 0, seconds: 0.5)
        scene.campfireLit = false
        t = step(scene, from: t, seconds: 10)
        scene.campfireLit = true
        t = step(scene, from: t, seconds: 0.5)
        scene.campfireLit = false
        t = step(scene, from: t, seconds: 14.9)
        XCTAssertEqual(scene.campfireState, .ended)
        t = step(scene, from: t, seconds: 0.2)
        XCTAssertEqual(scene.campfireState, .ready)
    }

    func testAFireThatWasNeverLitShowsNoSmoke() {
        let scene = newScene()
        scene.update(0)
        scene.campfireLit = false
        XCTAssertEqual(scene.campfireState, .ready)
    }

    func testPitDrawsBehindCharactersInFrontOfIt() throws {
        let scene = newScene()
        scene.applyMembers([
            PlazaSceneMember(memberID: "front", nickname: "front", isAway: false, tile: TilePoint(x: 36, y: 26), facing: .down, isWalking: false),
            PlazaSceneMember(memberID: "back", nickname: "back", isAway: false, tile: TilePoint(x: 36, y: 21), facing: .down, isWalking: false),
        ])
        scene.update(0)
        let pit = try XCTUnwrap(scene.campfireZ)
        XCTAssertEqual(pit, 1 + CGFloat(25 * 32) / map.pixelSize.height, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(scene.memberZ("front")), pit)
        XCTAssertLessThan(try XCTUnwrap(scene.memberZ("back")), pit)
    }

    func testLightOnlyAtDuskAndNightWhileLit() {
        let scene = newScene()
        scene.now = { self.at(hour: 13) }
        scene.campfireLit = true
        scene.update(0)
        XCTAssertFalse(scene.isCampfireLightShown)
        scene.now = { self.at(hour: 21) }
        scene.update(0.05)
        XCTAssertTrue(scene.isCampfireLightShown)
        XCTAssertTrue(scene.isCampfirePitShown)
        scene.campfireLit = false
        scene.update(0.1)
        XCTAssertFalse(scene.isCampfireLightShown)
        scene.campfireLit = true
        scene.setBackgroundHidden(true)
        scene.update(0.15)
        XCTAssertFalse(scene.isCampfireLightShown)
        XCTAssertFalse(scene.isCampfirePitShown)
    }

    func testSitSnapsToTheSeatAndFacesTheFire() {
        let scene = newScene()
        scene.update(0)
        var reports: [(TilePoint, PlazaDirection, Bool)] = []
        scene.onLocalPositionChange = { reports.append(($0, $1, $2)) }
        let seat = PlazaCampfire.seats[4]
        scene.sit(at: seat)
        XCTAssertEqual(scene.walker.tile, TilePoint(x: 33, y: 24))
        XCTAssertEqual(scene.walker.facing, .right)
        XCTAssertFalse(scene.walker.isWalking)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, seat.tile)
    }

    func testSitStopsAutoWalk() {
        let scene = newScene()
        scene.applyMembers([PlazaSceneMember(memberID: "a", nickname: "a", isAway: false, tile: TilePoint(x: 36, y: 26), facing: .down, isWalking: false)])
        XCTAssertTrue(scene.follow(member: "a"))
        scene.sit(at: PlazaCampfire.seats[4])
        XCTAssertNil(scene.followingMember)
        XCTAssertNil(scene.walkingToMember)
    }

    func testArrowKeyCallsOnWalkKeyEvenForAnEgg() {
        let scene = newScene()
        scene.canWalk = false
        var calls = 0
        scene.onWalkKey = { calls += 1 }
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        XCTAssertEqual(calls, 1)
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: true)
        XCTAssertEqual(calls, 1)
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false, modifiers: .command)
        XCTAssertEqual(calls, 1, "Command+arrow is ignored like the walk itself")
        scene.isOverlayOpen = true
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        XCTAssertEqual(calls, 1, "an open overlay swallows the arrow before it reaches the walk hook")
    }

    func testTimerLabelAppearsRedrawsOnChangeAndHides() {
        let scene = newScene()
        scene.update(0)
        XCTAssertFalse(scene.isCampfireTimerShown)
        XCTAssertNil(scene.campfireTimerText)
        scene.setCampfireTimer("12:34")
        XCTAssertEqual(scene.campfireTimerText, "12:34")
        let first = scene.campfireTimerTextureID
        scene.setCampfireTimer("12:34")
        XCTAssertEqual(scene.campfireTimerTextureID, first, "same text is not redrawn")
        scene.setCampfireTimer("12:33")
        XCTAssertNotEqual(scene.campfireTimerTextureID, first)
        XCTAssertTrue(scene.isCampfireTimerShown)
        scene.setBackgroundHidden(true)
        XCTAssertFalse(scene.isCampfireTimerShown)
        scene.setBackgroundHidden(false)
        scene.setCampfireTimer(nil)
        XCTAssertNil(scene.campfireTimerText)
        XCTAssertFalse(scene.isCampfireTimerShown)
    }

    func testLightTextureIsReusedWithinAFrameAndRebuiltOnPhaseChange() {
        let scene = newScene()
        scene.now = { self.at(hour: 21) }
        scene.campfireLit = true
        scene.update(0)
        scene.update(0.01)
        let a = scene.campfireLightTextureID
        scene.update(0.02)
        XCTAssertEqual(scene.campfireLightTextureID, a)
        scene.update(0.08); scene.update(0.12)
        XCTAssertNotEqual(scene.campfireLightTextureID, a)
    }

    /// The light texture holds `multiplier / 2` per ring, neutral grey outside the ellipse, laid out on the 2 px block grid.
    func testLightTextureHoldsTheRingsOnTheBlockGrid() throws {
        let scene = newScene()
        scene.now = { self.at(hour: 21) }
        scene.campfireLit = true
        scene.update(0)
        let tint = scene.daylightTint
        let image = try XCTUnwrap(scene.campfireLightImage)
        let radii = PlazaCampfireLight.radii(phase: 0)
        let n = PlazaCampfireLight.blockCounts(radii: radii)
        XCTAssertEqual(image.width, n.w)
        XCTAssertEqual(image.height, n.h)
        var data = [UInt8](repeating: 0, count: n.w * n.h * 4)
        let ctx = CGContext(data: &data, width: n.w, height: n.h, bitsPerComponent: 8, bytesPerRow: n.w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n.w, height: n.h))
        func texel(_ i: Int, _ j: Int) -> [Int] { (0..<3).map { Int(data[(j * n.w + i) * 4 + $0]) } }   // j = 0 is the top row
        func expected(_ mix: Double) -> [Int] {
            let m = PlazaCampfireLight.multiplier(tint: tint, mix: mix)
            return [m.r, m.g, m.b].map { Int(($0 / 2 * 255).rounded()) }
        }
        func assertTexel(_ i: Int, _ j: Int, mix: Double, _ what: String) {
            for (got, want) in zip(texel(i, j), expected(mix)) { XCTAssertEqual(got, want, accuracy: 2, what) }
        }
        let mid = n.w / 2
        assertTexel(mid, n.h / 2, mix: 1, "centre texel is ring 1")
        assertTexel(mid, n.h / 2 - 1, mix: 1, "the texel just above the centre is ring 1")
        assertTexel(0, 0, mix: 0, "the corner is outside the ellipse, so neutral")
        XCTAssertEqual(texel(0, 0), [128, 128, 128].map { $0 }, "neutral is 0.5")
        assertTexel(mid, 0, mix: PlazaCampfireLight.blockMix(i: mid, j: 0, radii: radii), "top middle follows the maths")
        XCTAssertEqual(PlazaCampfireLight.blockMix(i: mid, j: 0, radii: radii), 0.26, "top middle sits in ring 4")
        // World placement: the box is centred on the light centre, 2 world px per texel.
        let center = try XCTUnwrap(PlazaCampfireLight.center(campfireTiles: map.campfireTiles))
        let frame = scene.campfireLightFrame
        XCTAssertEqual(frame.width, CGFloat(2 * n.w))
        XCTAssertEqual(frame.height, CGFloat(2 * n.h))
        XCTAssertEqual(frame.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(map.pixelSize.height - frame.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(map.pixelSize.height - frame.maxY, center.y - CGFloat(n.h), accuracy: 0.001, "the top row is the north edge")
    }

    /// The tint is read once per update: moving `now` without an update does not move the light.
    func testLightFollowsTheTintOnlyOnUpdate() {
        let scene = newScene()
        scene.now = { self.at(hour: 21) }
        scene.campfireLit = true
        scene.update(0)
        XCTAssertTrue(scene.isCampfireLightShown)
        scene.now = { self.at(hour: 13) }
        XCTAssertTrue(scene.isCampfireLightShown, "still the tint of the last update")
        scene.update(0.05)
        XCTAssertFalse(scene.isCampfireLightShown)
    }
}
