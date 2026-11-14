import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// F의 keyCode.
private let fireworkKey: UInt16 = 3

/// The scene- and controller-driven firework tests: `PlazaScene` is a SpriteKit scene until the plaza stage lands.
extension PlazaFireworksTests {
    // MARK: 장면
    private func scene(at date: Date? = nil) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.size = CGSize(width: 960, height: 640)
        if let date { s.now = { date } }
        return s
    }

    private func noon() -> Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)! }
    private func midnight() -> Date { Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: date)! }

    private func run(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testFFiresOnceAndIsHeldBackLikeTheOtherKeys() {
        let s = scene()
        var fired = 0
        s.onFireworkKey = { fired += 1 }
        s.handleKeyDown(keyCode: fireworkKey, characters: "ㄹ", isRepeat: false)
        XCTAssertEqual(fired, 1, "the key code decides, so Hangul input works")
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: true)
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: false, modifiers: .command)
        XCTAssertEqual(fired, 1)
        s.isOverlayOpen = true
        s.handleKeyDown(keyCode: fireworkKey, characters: "f", isRepeat: false)
        XCTAssertEqual(fired, 1)
    }

    func testAShowDarkensTheDaytimePlazaAndTheDayComesBack() throws {
        let s = scene(at: noon())
        s.update(0)
        XCTAssertNil(s.shownDaylight)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.5, from: 0)
        let tint = try XCTUnwrap(s.shownDaylight)
        XCTAssertEqual(tint.red, 0.594, accuracy: 0.001)
        XCTAssertEqual(tint.green, 0.636, accuracy: 0.001)
        XCTAssertEqual(tint.blue, 0.846, accuracy: 0.001)
        run(s, seconds: 4, from: 0.5)
        XCTAssertNil(s.shownDaylight)
    }

    func testAShowDoesNotDarkenNightAnyFurther() throws {
        let s = scene(at: midnight())
        s.update(0)
        let night = try XCTUnwrap(s.shownDaylight)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 0.5, from: 0)
        let tint = try XCTUnwrap(s.shownDaylight)
        XCTAssertEqual(tint.red, night.red, accuracy: 0.001)
        XCTAssertEqual(tint.blue, night.blue, accuracy: 0.001)
    }

    /// A hidden background shows the desktop, which a tint would darken. The pieces still fly, like the bubbles.
    func testAHiddenBackgroundGetsThePiecesWithoutTheDark() {
        let s = scene(at: noon())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        XCTAssertNil(s.shownDaylight)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
    }

    /// The pieces are light, so night must not dim them, and the names must stay readable on top.
    func testFireworksDrawAboveTheNightTintAndBelowTheNames() {
        let z = scene().fireworkZ
        XCTAssertGreaterThan(z, 6, "above the daylight (5) and the campfire light (6)")
        XCTAssertLessThan(z, 10, "below the name plates (10)")
    }

    func testAPausedSceneDropsAFirework() {
        let s = scene()
        s.update(0)
        s.isPaused = true
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"))
        s.isPaused = false
        run(s, seconds: 1, from: 0)
        XCTAssertEqual(s.fireworkPieceCount, 0)
    }

    func testAFireworkFromSomeoneNotHereIsIgnored() {
        let s = scene()
        s.update(0)
        XCTAssertFalse(s.playFirework(memberID: "nobody", style: "ring"))
    }

    /// The map is far wider than the view, so most teammates are off screen. Their burst comes to this view's edge, and on
    /// the right that edge is the roster's: the camera counts that column as covered, and a burst there would be hidden.
    func testATeammateFarEastBurstsClearOfTheRoster() throws {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "far", nickname: "가", isAway: false, tile: TilePoint(x: 44, y: 28), facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "far", style: "ring"))
        run(s, seconds: 1, from: 0)
        let v = try XCTUnwrap(s.photoInput()?.visibleRect)
        let height = map.pixelSize.height
        XCTAssertFalse(s.fireworkPositions.isEmpty)
        let clearEdge = v.maxX - PlazaRosterMetrics.coveredWidth / 2   // zoom 2
        for p in s.fireworkPositions {
            XCTAssertLessThan(p.x + 10, clearEdge, "behind the roster")
            XCTAssertTrue(v.insetBy(dx: -10, dy: -10).contains(CGPoint(x: p.x, y: height - p.y)), "off screen")
        }
    }

    /// The same on the left, where the unfolded shortcut guide hides the sky, at every zoom.
    func testATeammateFarWestBurstsClearOfTheGuide() throws {
        for zoom in PlazaCamera.zoomRange {
            let s = scene()
            s.zoom = zoom
            s.update(0)
            s.applyMembers([PlazaSceneMember(memberID: "far", nickname: "가", isAway: false, tile: TilePoint(x: 4, y: 28), facing: .down, isWalking: false)])
            XCTAssertTrue(s.playFirework(memberID: "far", style: "ring"))
            run(s, seconds: 1, from: 0)
            let v = try XCTUnwrap(s.photoInput()?.visibleRect)
            XCTAssertFalse(s.fireworkPositions.isEmpty)
            for p in s.fireworkPositions {
                XCTAssertGreaterThan(p.x, v.minX + PlazaShortcutGuide.coveredWidth / CGFloat(zoom), "behind the guide at zoom \(zoom)")
            }
        }
    }

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

    /// A burst pushed down by the top of the view must not start its shell under the feet.
    func testAShellLeavesFromTheHeadWhenTheBurstIsPushedDown() throws {
        let s = scene()
        s.zoom = 3
        s.update(0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.1, from: 0)
        let foot = map.pixelSize.height - s.walkerFootY
        let low = try XCTUnwrap(s.fireworkPositions.map(\.y).min())
        XCTAssertGreaterThan(low, foot, "the shell starts above the feet")
    }

    func testAPhotoCatchesTheFireworkAndTheDark() throws {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworks.count, s.fireworkPieceCount)
        XCTAssertEqual(input.tint.red, 0.594, accuracy: 0.001)
    }

    func testATeammatesFireworkDoesNotHoldBackMine() {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "가", nickname: "가", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"), "my own was just fired")
    }


    func testASecondOfMineLaunchesWhileTheFirstIsStillInTheAir() {
        let s = scene()
        s.update(0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.4, from: 0)
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"), "0.4 s is too soon")
        run(s, seconds: 0.1, from: 0.4)
        let one = s.fireworkPieceCount
        XCTAssertGreaterThan(one, 0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"), "0.5 s on, with the first still rising")
        run(s, seconds: 1, from: 0.5)
        XCTAssertGreaterThan(s.fireworkPieceCount, one, "both bursts are drawn")
    }

    /// A teammate's Mac decides when they may fire. A slow frame here must not lose their next one.
    func testATeammatesNextFireworkIsNeverHeldBack() {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "가", nickname: "가", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
    }


    private func nightScene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2, nickname: "나")
        s.size = CGSize(width: 960, height: 640)
        let at = midnight()
        s.now = { at }
        s.campfireLit = true
        s.update(0)
        return s
    }

    func testBesideALitCampfireTheFireworkAddsNoLight() throws {
        let fire = try XCTUnwrap(map.campfireTiles.first)
        let s = nightScene(start: TilePoint(x: fire.x, y: fire.y + 3))
        XCTAssertTrue(s.isCampfireLightShown)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }

    func testFarFromALitCampfireTheFireworkLights() {
        let s = nightScene(start: TilePoint(x: 4, y: 28))
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testTheSceneLightsANightFirework() throws {
        let s = scene(at: midnight())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworkLight?.tint, input.tint)
    }

    /// The dark of a daytime show is dark enough for the burst to light the ground.
    func testADaytimeShowIsLitToo() {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testAHiddenBackgroundGetsNoLight() {
        let s = scene(at: midnight())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }


    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    @MainActor private final class Received { var emotes: [TeamEmote] = [] }

    private func session(_ name: String, code: TeamCode, hub: FakeTransportHub) -> (TeamSession, FakeTeamTransport, TeamSettings, Received) {
        let suite = "plaza.fireworks.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaFireworksTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        sessions.append(session)
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return (session, transport, settings, received)
    }

    private func controller(_ session: TeamSession, _ settings: TeamSettings) -> PlazaWindowController {
        let name = "plaza.fireworks.prefs.\(UUID())"
        return PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: name)),
                                     loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: session, clock: { [unowned self] in clockNow })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

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

    /// The light node is lifted above the daylight tint (camera z 5) by the layer's own z.
    func testTheFireworkLightLayerSitsAboveTheDaylightTint() {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = layer.root.children.compactMap { $0 as? PlazaSprite }.first { $0.blendMode == .multiplyX2 && !$0.isHidden }
        XCTAssertGreaterThan(scene().fireworkZ + (node?.zPosition ?? 0), 5, "above the daylight tint, or it is multiplied away")
    }
}
