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
        // Lighting it again during smoke cancels the smoke.
        scene.campfireLit = true
        scene.campfireLit = false
        t = step(scene, from: t, seconds: 1)
        scene.campfireLit = true
        XCTAssertEqual(scene.campfireState, .lit)
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
        scene.isOverlayOpen = true
        scene.handleKeyDown(keyCode: 124, characters: nil, isRepeat: false)
        XCTAssertEqual(calls, 1, "an open overlay swallows the arrow before it reaches the walk hook")
    }

    func testTimerLabelAppearsRedrawsOnChangeAndHides() {
        let scene = newScene()
        scene.update(0)
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
}
