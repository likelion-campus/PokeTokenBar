import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// F의 keyCode.
private let fireworkKey: UInt16 = 3

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaFireworksTests {

    private func guideSize(snowDay: Bool = false) throws -> CGSize {
        let model = PlazaShortcutGuideModel()
        model.season = snowDay ? .winter : .summer
        let renderer = ImageRenderer(content: PlazaShortcutGuide(model: model, toggle: {}))
        renderer.scale = 1
        return try XCTUnwrap(renderer.nsImage?.size)
    }

    /// `coveredWidth` is written by hand, so a longer row must not outgrow it unnoticed.
    func testTheGuideFitsItsCoveredWidth() throws {
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + (try guideSize()).width, PlazaShortcutGuide.coveredWidth)
    }

    /// Adding the F row made the unfolded guide taller than the smallest window. It sits 46 points below the top.
    func testTheGuideFitsTheSmallestWindow() throws {
        XCTAssertLessThanOrEqual(46 + (try guideSize()).height, PlazaWindowController.minContentSize.height)
    }

    /// The V row of snow days must not outgrow the smallest window or the covered width either.
    func testTheSnowDayGuideFitsTheSmallestWindowAndItsWidth() throws {
        let size = try guideSize(snowDay: true)
        XCTAssertLessThanOrEqual(PlazaRosterMetrics.margin + size.width, PlazaShortcutGuide.coveredWidth)
        XCTAssertLessThanOrEqual(46 + size.height, PlazaWindowController.minContentSize.height)
    }

    private func controller(_ session: TeamSession, _ settings: TeamSettings) -> PlazaWindowController {
        let name = "plaza.fireworks.prefs.\(UUID())"
        return PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: name)),
                                     loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: session, clock: { [unowned self] in clockNow })
    }

    /// 두 Mac을 잇고 팀원이 장면에 나타날 때까지 기다린다.
    private func connected(_ c: PlazaWindowController, _ a: FakeTeamTransport, _ b: FakeTeamTransport, hub: FakeTransportHub,
                           other: TeamSettings) async throws -> PlazaScene {
        hub.connect(a, to: b)
        let scene = try XCTUnwrap(c.scene)
        for _ in 0..<400 where scene.memberTiles[other.memberID] == nil { await Task.yield() }
        XCTAssertNotNil(scene.memberTiles[other.memberID])
        scene.update(0)
        return scene
    }

    func testFFiresHereAndTellsTeammatesWhichStyle() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.map(\.kind), [.firework])
        let sent = try XCTUnwrap(other.emotes.first?.fireworkStyle)
        XCTAssertEqual(scene.fireworkStyleIDs, [sent], "the same style on both screens")
    }

    /// F is held back until 0.5 s after my last firework, so it cannot be spammed. The wait is scene time, not the wall clock:
    /// the show pauses with the window, and so does the wait.
    func testTheNextFireworkWaitsHalfASecondOfSceneTime() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1)

        run(scene, seconds: 0.3, from: 0)
        clockNow = clockNow.addingTimeInterval(3600)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1, "too soon, however long the wall clock says")

        run(scene, seconds: 0.3, from: 0.3)
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 2, "0.5 s of scene time passed while the first is still in the air")
    }

    /// One pair of shots differs by chance seven times in eight, so this fires enough of them to catch a repeat.
    func testTheKeyNeverFiresTheSameStyleTwiceInARow() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        var t: TimeInterval = 0
        for _ in 0..<40 {
            scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
            await settle()
            while !scene.fireworkStyleIDs.isEmpty { t += 0.06; scene.update(t) }
        }
        let sent = other.emotes.compactMap(\.fireworkStyle)
        XCTAssertEqual(sent.count, 40)
        for (a, b) in zip(sent, sent.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    /// A launch the scene refuses (a paused window) must not reach teammates or use up the turn.
    func testAKeyTheSceneRefusesTellsNobody() async throws {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let (me, meT, meS, _) = session("나", code: code, hub: hub)
        let (_, otherT, otherS, other) = session("가", code: code, hub: hub)
        let c = controller(me, meS)
        c.prepareScene()
        let scene = try await connected(c, meT, otherT, hub: hub, other: otherS)
        scene.isPaused = true
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertTrue(other.emotes.isEmpty)
        scene.isPaused = false
        scene.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        await settle()
        XCTAssertEqual(other.emotes.count, 1, "the turn was not used up")
    }
}
