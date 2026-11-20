import XCTest
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
    func scene(at date: Date? = nil) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        s.size = CGSize(width: 960, height: 640)
        if let date { s.now = { date } }
        return s
    }

    private func noon() -> Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)! }
    private func midnight() -> Date { Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: date)! }

    func run(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testFFiresOnceAndIsHeldBackLikeTheOtherKeys() async {
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

    func testAShowDarkensTheDaytimePlazaAndTheDayComesBack() async throws {
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

    func testAShowDoesNotDarkenNightAnyFurther() async throws {
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
    func testAHiddenBackgroundGetsThePiecesWithoutTheDark() async {
        let s = scene(at: noon())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        XCTAssertNil(s.shownDaylight)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
    }

    /// The pieces are light, so night must not dim them, and the names must stay readable on top.
    func testFireworksDrawAboveTheNightTintAndBelowTheNames() async {
        let z = scene().fireworkZ
        XCTAssertGreaterThan(z, 6, "above the daylight (5) and the campfire light (6)")
        XCTAssertLessThan(z, 10, "below the name plates (10)")
    }

    func testAPausedSceneDropsAFirework() async {
        let s = scene()
        s.update(0)
        s.isPaused = true
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"))
        s.isPaused = false
        run(s, seconds: 1, from: 0)
        XCTAssertEqual(s.fireworkPieceCount, 0)
    }

    func testAFireworkFromSomeoneNotHereIsIgnored() async {
        let s = scene()
        s.update(0)
        XCTAssertFalse(s.playFirework(memberID: "nobody", style: "ring"))
    }

    /// The map is far wider than the view, so most teammates are off screen. Their burst comes to this view's edge, and on
    /// the right that edge is the roster's: the camera counts that column as covered, and a burst there would be hidden.
    func testATeammateFarEastBurstsClearOfTheRoster() async throws {
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
    func testATeammateFarWestBurstsClearOfTheGuide() async throws {
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
                XCTAssertGreaterThan(p.x, v.minX + PlazaShortcutGuideMetrics.coveredWidth / CGFloat(zoom), "behind the guide at zoom \(zoom)")
            }
        }
    }

    /// A burst pushed down by the top of the view must not start its shell under the feet.
    func testAShellLeavesFromTheHeadWhenTheBurstIsPushedDown() async throws {
        let s = scene()
        s.zoom = 3
        s.update(0)
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        run(s, seconds: 0.1, from: 0)
        let foot = map.pixelSize.height - s.walkerFootY
        let low = try XCTUnwrap(s.fireworkPositions.map(\.y).min())
        XCTAssertGreaterThan(low, foot, "the shell starts above the feet")
    }

    func testAPhotoCatchesTheFireworkAndTheDark() async throws {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: 1, from: 0)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworks.count, s.fireworkPieceCount)
        XCTAssertEqual(input.tint.red, 0.594, accuracy: 0.001)
    }

    func testATeammatesFireworkDoesNotHoldBackMine() async {
        let s = scene()
        s.update(0)
        s.applyMembers([PlazaSceneMember(memberID: "가", nickname: "가", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        XCTAssertTrue(s.playFirework(memberID: "가", style: "ring"))
        XCTAssertTrue(s.playFirework(memberID: nil, style: "ring"))
        XCTAssertFalse(s.playFirework(memberID: nil, style: "ring"), "my own was just fired")
    }


    func testASecondOfMineLaunchesWhileTheFirstIsStillInTheAir() async {
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
    func testATeammatesNextFireworkIsNeverHeldBack() async {
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

    func testBesideALitCampfireTheFireworkAddsNoLight() async throws {
        let fire = try XCTUnwrap(map.campfireTiles.first)
        let s = nightScene(start: TilePoint(x: fire.x, y: fire.y + 3))
        XCTAssertTrue(s.isCampfireLightShown)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertGreaterThan(s.fireworkPieceCount, 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }

    func testFarFromALitCampfireTheFireworkLights() async {
        let s = nightScene(start: TilePoint(x: 4, y: 28))
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testTheSceneLightsANightFirework() async throws {
        let s = scene(at: midnight())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
        let input = try XCTUnwrap(s.photoInput())
        XCTAssertEqual(input.fireworkLight?.tint, input.tint)
    }

    /// The dark of a daytime show is dark enough for the burst to light the ground.
    func testADaytimeShowIsLitToo() async {
        let s = scene(at: noon())
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 1)
    }

    func testAHiddenBackgroundGetsNoLight() async {
        let s = scene(at: midnight())
        s.setBackgroundHidden(true)
        s.update(0)
        s.playFirework(memberID: nil, style: "ring")
        run(s, seconds: F.riseDuration + 0.2, from: 0)
        XCTAssertEqual(s.fireworkLightCount, 0)
    }


    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    @MainActor final class Received { var emotes: [TeamEmote] = [] }

    func session(_ name: String, code: TeamCode, hub: FakeTransportHub) -> (TeamSession, FakeTeamTransport, TeamSettings, Received) {
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

    func settle() async { for _ in 0..<20 { await Task.yield() } }

    /// The light node is lifted above the daylight tint (camera z 5) by the layer's own z.
    func testTheFireworkLightLayerSitsAboveTheDaylightTint() async {
        let layer = PlazaFireworkLayer()
        layer.launch(ring(), at: CGPoint(x: 200, y: 300))
        lit(layer, seconds: F.riseDuration + 0.1)
        let node = layer.root.children.compactMap { $0 as? PlazaSprite }.first { $0.blendMode == .multiplyX2 && !$0.isHidden }
        XCTAssertGreaterThan(scene().fireworkZ + (node?.zPosition ?? 0), 5, "above the daylight tint, or it is multiplied away")
    }
}
