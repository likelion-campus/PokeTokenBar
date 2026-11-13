import XCTest
@testable import PokeTokenBar

private let runtimeNow = Date(timeIntervalSince1970: 1_700_000_000)

private func runtimeNode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private let runtimeLine = EvoLine(
    baseID: 1, tree: runtimeNode(1, [runtimeNode(2)]), rarity: .common,
    names: [1: ["en": "P1", "ko": "포1"], 2: ["en": "P2", "ko": "포2"]])

private struct RuntimeTestProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { runtimeLine }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: 1, captureRate: 255)] }
}

@MainActor
private final class RuntimeNode {
    let settings: TeamSettings
    let companion: CompanionStore
    let transport: FakeTeamTransport
    let runtime: TeamRuntime
    private let suite = "ptb.test.team.runtime.\(UUID().uuidString)"

    init(hub: FakeTransportHub, code: TeamCode, nickname: String, companionURL: URL? = nil,
         secondsSinceInput: @escaping () -> TimeInterval = { 0 }) {
        let defaults = TestDefaults.make(suite: suite)
        settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = nickname
        settings.isEnabled = true
        let tmp = FileManager.default.temporaryDirectory
        companion = CompanionStore(provider: RuntimeTestProvider(), clock: { runtimeNow },
                                   fileURL: companionURL ?? tmp.appendingPathComponent("rt-companion-\(UUID().uuidString).json"),
                                   rng: SeededRNG(seed: 7), dittoDisguiseRollingEnabled: false, defaults: defaults)
        transport = hub.makeTransport()
        let feed = TeamFeedStore(fileURL: tmp.appendingPathComponent("rt-feed-\(UUID().uuidString).json"),
                                 myMemberID: settings.memberID)
        runtime = TeamRuntime(settings: settings, companion: companion, transport: transport, feed: feed,
                              secondsSinceInput: secondsSinceInput)
    }
}

/// Runs the main actor's queued hops until `condition` holds, or ten seconds pass; then asserts it holds. Tests wait on the
/// condition they need, never on a yield count.
@MainActor
private func settleUntil(_ condition: () -> Bool, file: StaticString, line: UInt) async {
    let deadline = ContinuousClock.now + .seconds(10)
    var spins = 0
    while !condition(), ContinuousClock.now < deadline {
        spins += 1
        if spins < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(2)) }
    }
    XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
}

@MainActor
final class TeamRuntimeTests: XCTestCase {
    /// The fake transports hold their hub unowned, so it must outlive the test body.
    private let hub = FakeTransportHub()

    private func newCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    /// Lets the main actor run queued observation hops until `condition` holds, or ten seconds pass.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await settleUntil(condition, file: file, line: line)
    }

    private func connectedPair() -> (a: RuntimeNode, b: RuntimeNode) {
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가")
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        return (a, b)
    }

    // MARK: - Focus

    /// Real time: teammates drop a focus end that is already past by their own clock.
    private var focusNow = Date()

    /// A node whose plaza sits at the campfire, with a notifier posting to a fake.
    private func focusingNode() async -> (a: RuntimeNode, b: RuntimeNode, plaza: PlazaWindowController, poster: RuntimePoster) {
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가")
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        let suite = "ptb.test.team.runtime.focus.\(UUID().uuidString)"
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: suite))
        prefs.saveLastTile(TilePoint(x: 36, y: 22))
        let plaza = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session,
                                          clock: { [unowned self] in focusNow },
                                          focusTickSleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let poster = RuntimePoster()
        b.runtime.plaza = plaza
        b.runtime.notifier = TeamNotifier(settings: b.settings, poster: poster, isPlazaFrontmost: { false },
                                          showInPlaza: { _ in })
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        plaza.prepareScene()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        plaza.startFocus(minutes: 25)
        XCTAssertNotNil(plaza.focus)
        return (a, b, plaza, poster)
    }

    /// A teammate's dance carries when they began, and that (not when it arrived here) decides who follows whom.
    func testATeammatesDanceStartTimeReachesThePlaza() async throws {
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가")
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        let suite = "ptb.test.team.runtime.dance.\(UUID().uuidString)"
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: suite))
        let plaza = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        plaza.prepareScene()
        let scene = try XCTUnwrap(plaza.scene)
        scene.pickDanceStyle = { _ in .bounce }
        let tile = scene.walker.tile
        var now = Date()
        scene.now = { now }
        let spot = TilePoint(x: tile.x + 1, y: tile.y)
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: spot, facing: .down, isWalking: false)
        // Wait for the spot itself: before this news lands the scene already draws `a` on a random shelter tile, so "has a tile"
        // is true at once, and a dance sent from there is out of `togetherRange` and is not followed.
        await settle { scene.memberTiles[a.settings.memberID] == spot }
        _ = scene.handleKeyDown(keyCode: 2, characters: "d", isRepeat: false)
        XCTAssertEqual(scene.danceStyle(memberID: nil), .bounce, "test precondition: I dance alone")
        now += 1   // a new round is refused within a beat of my last one
        a.runtime.session.sendEmote(.dance, target: nil, danceStyle: "spin", danceSince: now.addingTimeInterval(-60))
        await settle { scene.danceStyle(memberID: nil) == .spin }
        XCTAssertEqual(scene.danceStyle(memberID: nil), .spin, "they began a minute before me, though their news came after my D")
    }

    /// A local schedule change reaches an already open plaza without reopening it.
    func testChangingTheScheduleUpdatesAnOpenPlaza() async throws {
        let node = RuntimeNode(hub: hub, code: newCode(), nickname: "가")
        let suite = "ptb.test.team.runtime.schedule.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "가" }, memberID: { node.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) },
                                          schedule: { node.settings.schedule })
        node.runtime.plaza = plaza
        node.runtime.start()
        plaza.prepareScene()
        let scene = try XCTUnwrap(plaza.scene)
        XCTAssertEqual(scene.coreTime, .standard)
        node.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .month, now: Date())
        await settle { scene.coreTime == PlazaCoreTime(start: 8, end: 20) }
        XCTAssertEqual(scene.weatherPeriod, .month)
    }

    func testTickEndsADueFocus() async {
        let (_, b, plaza, poster) = await focusingNode()
        focusNow = focusNow.addingTimeInterval(25 * 60 + 1)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies, ["🔥 25분 집중 끝!"])
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 1)
        plaza.handleClose()
    }

    func testChangingTeamEndsTheFocusSilently() async {
        let (a, b, plaza, poster) = await focusingNode()
        await settle { a.runtime.session.members[b.settings.memberID]?.focusEndsAt != nil }
        b.settings.code = newCode()
        await settle { plaza.focus == nil }
        XCTAssertTrue(poster.bodies.isEmpty)
        await settle { a.runtime.session.members[b.settings.memberID]?.focusEndsAt == nil }
        plaza.handleClose()
    }

    func testTurningTheTeamOffEndsTheFocusSilently() async {
        let (a, b, plaza, poster) = await focusingNode()
        await settle { a.runtime.session.members[b.settings.memberID]?.focusEndsAt != nil }
        b.settings.isEnabled = false
        await settle { plaza.focus == nil }
        XCTAssertTrue(poster.bodies.isEmpty)
        await settle { a.runtime.session.members[b.settings.memberID]?.focusEndsAt == nil }
        plaza.handleClose()
    }

    /// A teammate's pickup reaches my plaza through the runtime, which then hides that item.
    func testReceivedPickupHidesTheItem() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.pickup.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        let slot = PlazaItems.slot(at: Date())
        a.runtime.session.sendEmote(.pickup, target: nil, itemSlot: slot)
        await settle { plaza.scene?.pickedItemSlots.contains(slot) == true }
        plaza.handleClose()
    }

    /// A teammate's group photo starts the countdown on my plaza with their name.
    func testReceivedGroupPhotoStartsTheCountdown() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.groupphoto.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session,
                                          groupPhotoSleep: { _ in try? await Task.sleep(for: .seconds(60)) })
        b.runtime.plaza = plaza
        plaza.prepareScene()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        a.runtime.session.sendEmote(.groupPhoto, target: nil)
        await settle { plaza.countdown != nil }
        let name = b.runtime.session.members[a.settings.memberID]?.nickname ?? "?"
        XCTAssertEqual(plaza.countdown, "\(name)님의 단체 사진 5 · P를 누르면 함께 찍어요")
        plaza.handleClose()
    }

    /// A teammate's firework bursts here in the style they sent.
    func testReceivedFireworkBurstsInTheirStyle() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.firework.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        a.runtime.session.sendEmote(.firework, target: nil, fireworkStyle: "willow")
        await settle { plaza.scene?.fireworkStyleIDs.isEmpty == false }
        XCTAssertEqual(plaza.scene?.fireworkStyleIDs, ["willow"])
        plaza.handleClose()
    }

    /// A teammate's dance plays here in the style they sent, with ♪ over it, and an unknown style plays the default one.
    func testReceivedDancePlaysTheirStyle() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.dance.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        a.runtime.session.sendEmote(.dance, target: nil, danceStyle: "twirl")
        await settle { plaza.scene?.isDancing(memberID: sender) == true }
        XCTAssertEqual(plaza.scene?.danceStyle(memberID: sender), .twirl)
        XCTAssertEqual(plaza.scene?.shownEmote(memberID: sender), .dance, "the notes show over every dancer")
        a.runtime.session.sendEmote(.dance, target: nil, danceStyle: "fromANewerVersion")
        await settle { plaza.scene?.danceStyle(memberID: sender) == .sway }
        XCTAssertEqual(plaza.scene?.danceStyle(memberID: sender), .sway)
        plaza.handleClose()
    }

    /// A teammate who does something else stops dancing on my screen; the shared moments and the Ditto copy's jump do not.
    func testARemotesActionEmoteOrChatStopsItsDance() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.danceStop.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        func dance() async {
            a.runtime.session.sendEmote(.dance, target: nil, danceStyle: "sway")
            await settle { plaza.scene?.isDancing(memberID: sender) == true }
        }
        for kind in TeamEmoteKind.allCases where kind.endsSendersDance {
            await dance()
            a.runtime.session.sendEmote(kind, target: nil)
            await settle { plaza.scene?.isDancing(memberID: sender) == false }
        }
        await dance()
        a.runtime.session.sendChat("안녕", loud: false)
        await settle { plaza.scene?.isDancing(memberID: sender) == false }
        for kind in TeamEmoteKind.allCases where !kind.endsSendersDance && kind != .dance {
            await dance()
            a.runtime.session.sendEmote(kind, target: nil)
            for _ in 0..<60 { await Task.yield() }
            XCTAssertEqual(plaza.scene?.isDancing(memberID: sender), true, "\(kind) leaves the dance alone")
        }
        plaza.handleClose()
    }

    /// A teammate's jump makes their character hop here.
    func testReceivedJumpHopsThatTeammate() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.jump.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        a.runtime.session.sendEmote(.jump, target: nil)
        await settle { (plaza.scene?.dustCount ?? 0) == 2 }
        var t: TimeInterval = 0
        plaza.scene?.update(t)
        while t < PlazaActor.jumpDuration / 2 { t += 1.0 / 60; plaza.scene?.update(t) }
        XCTAssertGreaterThan(plaza.scene?.jumpLift(memberID: sender) ?? 0, 0)
        XCTAssertEqual(plaza.scene?.jumpLift(memberID: nil), 0, "only they jump")
    }

    /// A breaking jump reaches the plaza as a break the controller learns when the landing comes.
    func testABreakingJumpReachesThePlaza() async {
        let (a, b) = connectedPair()
        let now = Date(timeIntervalSince1970: 10_000 * 180 + 60)
        let suite = "ptb.test.team.runtime.icejump.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session,
                                          clock: { now })
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        let brk = PlazaIceBreak(pond: TilePoint(x: 5, y: 13), turn: PlazaIce.turn(at: now))
        a.runtime.session.sendEmote(.jump, target: nil, iceBreak: brk)
        await settle { (plaza.scene?.iceLandingCount ?? 0) == 1 }
        var t: TimeInterval = 0
        plaza.scene?.update(t)
        while t < 0.5 { t += 0.05; plaza.scene?.update(t) }
        XCTAssertEqual(plaza.iceBreak, brk)
        plaza.handleClose()
    }

    /// A tackle aimed at me pushes me one tile away from the teammate who did it, when they stand right next to me.
    /// From further away (I walked off while their menu was open) it only shows the impact.
    func testTackleFromBesideMePushesMeOneTileAway() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.tackle.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let scene = try! XCTUnwrap(plaza.scene)
        let map = PlazaMapData.map, start = scene.walker.tile
        let left = TilePoint(x: start.x - 1, y: start.y), right = TilePoint(x: start.x + 1, y: start.y)
        XCTAssertTrue(map.isWalkable(left) && map.isWalkable(right), "test precondition")
        let sender = a.settings.memberID
        // A Ditto can't copy an egg, and a fresh runtime's companion is one: give `a` a species to copy.
        a.runtime.session.updateCharacter(TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil))
        await settle { b.runtime.session.members[sender]?.character.speciesID == 25 }
        await settle { scene.memberTiles[sender] != nil }
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: start.x - 2, y: start.y), facing: .right, isWalking: false)
        await settle { scene.memberTiles[sender] == TilePoint(x: start.x - 2, y: start.y) }
        a.runtime.session.sendEmote(.tackle, target: b.settings.memberID)
        await settle { scene.impactCount == 1 }
        scene.update(0); scene.update(1)
        XCTAssertEqual(scene.walker.tile, start, "two tiles away: no push")
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
        // A received step is walked over the next frames, so keep the scene running while waiting.
        var t: TimeInterval = 1
        for _ in 0..<200 where scene.memberTiles[sender] != left { await Task.yield(); t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.memberTiles[sender], left)
        a.runtime.session.sendEmote(.tackle, target: b.settings.memberID)
        await settle { scene.impactCount == 2 }
        for _ in 0..<20 { t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.walker.tile, right, "pushed one tile away from the teammate on my left")
    }

    /// A tackle from an evolved teammate slides me as many tiles as it asks, whether my plaza is drawing or hidden.
    func testStrongerTacklePushesMeSeveralTiles() async {
        for hidden in [false, true] {
            let (a, b) = connectedPair()
            let suite = "ptb.test.team.runtime.strongpush.\(UUID().uuidString)"
            let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                              loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                              nickname: { "나" }, memberID: { b.settings.memberID },
                                              subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
            b.runtime.plaza = plaza
            plaza.prepareScene()
            let scene = try! XCTUnwrap(plaza.scene)
            let map = PlazaMapData.map, start = scene.walker.tile
            let left = TilePoint(x: start.x - 1, y: start.y), far = TilePoint(x: start.x + 3, y: start.y)
            XCTAssertTrue((1...3).allSatisfy { map.isWalkable(TilePoint(x: start.x + $0, y: start.y)) }, "test precondition")
            let sender = a.settings.memberID
            await settle { scene.memberTiles[sender] != nil }
            a.runtime.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
            var t: TimeInterval = 0
            for _ in 0..<200 where scene.memberTiles[sender] != left { await Task.yield(); t += 0.05; scene.update(t) }
            XCTAssertEqual(scene.memberTiles[sender], left)
            if hidden { plaza.setRendering(visible: false) }
            a.runtime.session.sendEmote(.tackle, target: b.settings.memberID, pushTiles: 3)
            if hidden {
                await settle { scene.walker.tile == far }
            } else {
                await settle { scene.impactCount == 1 }
                for _ in 0..<40 { t += 0.05; scene.update(t) }
            }
            XCTAssertEqual(scene.walker.tile, far, "three tiles away (hidden: \(hidden))")
            await settle { a.runtime.session.members[b.settings.memberID]?.tile == far }
        }
    }

    /// A snowball flies on my screen and pushes me when it lands; the push is capped at three tiles however much the frame asks.
    func testSnowballReachesThePlazaAndPushesAtMostThreeTiles() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.snowpush.\(UUID().uuidString)"
        let snowDay = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session,
                                          clock: { snowDay })
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let scene = try! XCTUnwrap(plaza.scene)
        let map = PlazaMapData.map, start = scene.walker.tile
        let left = TilePoint(x: start.x - 1, y: start.y), far = TilePoint(x: start.x + 3, y: start.y)
        XCTAssertTrue((1...3).allSatisfy { map.isWalkable(TilePoint(x: start.x + $0, y: start.y)) }, "test precondition")
        let sender = a.settings.memberID
        // A Ditto can't copy an egg, and a fresh runtime's companion is one: give `a` a species to copy.
        a.runtime.session.updateCharacter(TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil))
        await settle { b.runtime.session.members[sender]?.character.speciesID == 25 }
        await settle { scene.memberTiles[sender] != nil }
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
        var t: TimeInterval = 0
        for _ in 0..<200 where scene.memberTiles[sender] != left { await Task.yield(); t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.memberTiles[sender], left)
        a.runtime.session.sendEmote(.snowball, target: b.settings.memberID, pushTiles: 99, snowballDirection: .right)
        await settle { scene.snowballFlightCount == 1 }
        for _ in 0..<40 { t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.walker.tile, far, "exactly three tiles right")
    }

    /// The plaza stops drawing while its window is hidden behind others, but a tackle still pushes me at once and
    /// teammates get my new tile. Before, the push waited for the next drawn frame, so the tackler saw nothing happen.
    func testTackleWhileMyPlazaIsHiddenStillPushesMe() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.hiddenpush.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let scene = try! XCTUnwrap(plaza.scene)
        let start = scene.walker.tile
        let left = TilePoint(x: start.x - 1, y: start.y), right = TilePoint(x: start.x + 1, y: start.y)
        let sender = a.settings.memberID
        // A Ditto can't copy an egg, and a fresh runtime's companion is one: give `a` a species to copy.
        a.runtime.session.updateCharacter(TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil))
        await settle { b.runtime.session.members[sender]?.character.speciesID == 25 }
        await settle { scene.memberTiles[sender] != nil }
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
        await settle { scene.memberTiles[sender] == left }
        plaza.setRendering(visible: false)
        XCTAssertTrue(scene.isPaused)
        a.runtime.session.sendEmote(.tackle, target: b.settings.memberID)
        await settle { scene.walker.tile == right }
        await settle { a.runtime.session.members[b.settings.memberID]?.tile == right }
    }

    /// Picking a name colour in the plaza (a settings change) reaches teammates without any other trigger.
    func testPickedNameColorReachesTeammates() async {
        let (a, b) = connectedPair()
        // Both hellos and the presences that follow them are done, so only the pick itself can carry the colour.
        await settle { b.runtime.session.members[a.settings.memberID] != nil && a.runtime.session.members[b.settings.memberID] != nil }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(b.runtime.session.members[a.settings.memberID]?.nameColor)
        a.settings.nameColor = 0x7FD4FF
        await settle { b.runtime.session.members[a.settings.memberID]?.nameColor == 0x7FD4FF }
    }

    /// Five minutes without keyboard or mouse input is idle, checked on every tick whether or not the plaza is open.
    func testFiveMinutesWithoutInputIsIdleOnTheNextTick() async {
        var idleFor: TimeInterval = 0
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가", secondsSinceInput: { idleFor })
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        a.runtime.start(); b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        let id = a.settings.memberID
        XCTAssertEqual(TeamRuntime.idleAfter, 300)
        idleFor = 299
        a.runtime.tickOnce()
        XCTAssertFalse(a.runtime.session.isIdle, "not yet")
        idleFor = 300
        a.runtime.tickOnce()
        XCTAssertTrue(a.runtime.session.isIdle)
        await settle { b.runtime.session.members[id]?.isIdle == true }
        XCTAssertEqual(b.runtime.session.members[id]?.inPlaza, false, "the plaza was never opened")
        idleFor = 1
        a.runtime.tickOnce()
        XCTAssertFalse(a.runtime.session.isIdle)
        await settle { b.runtime.session.members[id]?.isIdle == false }
    }

    func testSystemIdleTimeIsReadable() {
        XCTAssertGreaterThanOrEqual(TeamRuntime.systemSecondsSinceInput(), 0)
    }

    func testCompanionEventIsPublished() {
        let (a, b) = connectedPair()
        a.companion.onTeamEvent?(CompanionTeamEvent(kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu",
                                                    fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common))
        XCTAssertEqual(a.transport.sentMessages { if case .events = $0 { true } else { false } }, 1)
        XCTAssertEqual(b.runtime.feed.events.map(\.speciesID), [25])
    }

    func testRepresentativeChangeSendsPresenceImmediately() async {
        let (a, b) = connectedPair()
        XCTAssertNil(b.runtime.session.members[a.settings.memberID]?.character.speciesID)
        let before = a.transport.sentMessages { if case .presence = $0 { true } else { false } }
        await a.companion.hatch(baseID: 1)   // no tick: the observation alone must push the new character
        await settle { b.runtime.session.members[a.settings.memberID]?.character.speciesID == 1 }
        let after = a.transport.sentMessages { if case .presence = $0 { true } else { false } }
        XCTAssertGreaterThan(after, before)
    }

    /// The raised Pokemon is species 2 but the pinned representative is species 1, so the plaza character
    /// differs from the session's profile fallback.
    func testFirstHelloCarriesThePlazaCharacter() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-pinned-\(UUID().uuidString).json")
        let active = "{\"baseID\":1,\"pathIDs\":[1,2],\"stageIndex\":1,\"usedAtStage\":0,"
            + "\"rarity\":\"common\",\"totalForms\":2,\"isShiny\":false,\"hasGrowthBoost\":false}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":0,\"spentTokens\":0,"
            + "\"lastDate\":\"d1\",\"active\":\(active),\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가", companionURL: url)
        XCTAssertTrue(a.companion.setRepresentativeSpeciesID(1))
        XCTAssertEqual(a.companion.currentSpeciesID, 2)
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        XCTAssertEqual(b.runtime.session.members[a.settings.memberID]?.character.speciesID, 1)
    }

    func testHelloCarriesMyNatureAndAMintReachesTeammates() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-nature-\(UUID().uuidString).json")
        let active = "{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"common\",\"totalForms\":1,\"isShiny\":false,\"nature\":\"adamant\"}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":0,\"spentTokens\":0,\"lastDate\":\"d1\","
            + "\"active\":\(active),\"dex\":[],\"collectedFinals\":[],\"inventory\":{\"mint\":1}}"
        try json.data(using: .utf8)!.write(to: url)
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가", companionURL: url)
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        let id = a.settings.memberID
        XCTAssertEqual(b.runtime.session.members[id]?.character.nature, .adamant)
        let minted = try XCTUnwrap(a.companion.useMint())
        await settle { b.runtime.session.members[id]?.character.nature == minted }
    }

    func testSettingsChangeRestartsTransport() async {
        let (a, _) = connectedPair()
        XCTAssertEqual(a.transport.startedCodes.count, 1)
        a.settings.code = newCode()
        await settle { a.transport.startedCodes.count == 2 }
        XCTAssertEqual(a.transport.stopCount, 1)
        XCTAssertTrue(a.transport.isRunning)
    }

    func testNotReadyClosesPlaza() async {
        let settingsDefaults = TestDefaults.make(suite: "ptb.test.team.runtime.close.\(UUID().uuidString)")
        let settings = TeamSettings(defaults: settingsDefaults)
        settings.code = newCode()
        settings.nickname = "가"
        settings.isEnabled = true
        let tmp = FileManager.default.temporaryDirectory
        let companion = CompanionStore(provider: RuntimeTestProvider(), clock: { runtimeNow },
                                       fileURL: tmp.appendingPathComponent("rt-companion-\(UUID().uuidString).json"),
                                       rng: SeededRNG(seed: 7), dittoDisguiseRollingEnabled: false, defaults: settingsDefaults)
        var closes = 0
        let runtime = TeamRuntime(settings: settings, companion: companion, transport: hub.makeTransport(),
                                  feed: TeamFeedStore(fileURL: tmp.appendingPathComponent("rt-feed-\(UUID().uuidString).json"),
                                                      myMemberID: settings.memberID),
                                  closePlaza: { closes += 1 })
        runtime.start()
        XCTAssertTrue(runtime.isTicking)

        settings.nickname = "나"   // still ready
        await Task.yield(); await Task.yield()
        XCTAssertEqual(closes, 0)
        XCTAssertTrue(runtime.isTicking)

        settings.isEnabled = false
        await settle { closes == 1 }
        XCTAssertFalse(runtime.isTicking)

        settings.isEnabled = true
        await settle { runtime.isTicking }
        XCTAssertEqual(closes, 1)
    }

    private struct NoSprites: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
        func egg() async -> NSImage? { nil }
    }

    func testReceivedEmoteReachesThePlaza() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.emote.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        a.runtime.session.sendEmote(.lol, target: nil)
        await settle { plaza.scene?.shownEmote(memberID: sender) == .lol }
    }

    /// A greeting aimed at me shows over the sender and over me. An ordinary emote aimed at me shows over the sender only.
    func testReceivedGreetingShowsOverTheSenderAndMe() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.greeting.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let sender = a.settings.memberID
        await settle { plaza.scene?.memberTiles[sender] != nil }
        a.runtime.session.sendEmote(.heart, target: b.settings.memberID)
        await settle { plaza.scene?.shownEmote(memberID: sender) == .heart }
        XCTAssertNil(plaza.scene?.shownEmote(memberID: nil))
        plaza.scene?.update(0)
        XCTAssertEqual(plaza.scene?.emoteFrame(memberID: sender)?.size, PlazaEmoteArt.size(large: true), "every bubble is the greeting size")
        a.runtime.session.sendEmote(.party, target: b.settings.memberID, shared: true)
        await settle { plaza.scene?.shownEmote(memberID: sender) == .party && plaza.scene?.shownEmote(memberID: nil) == .party }
        plaza.scene?.update(0.1)
        XCTAssertEqual(plaza.scene?.emoteFrame(memberID: sender)?.size, PlazaEmoteArt.size(large: true), "a greeting is bigger")
        XCTAssertEqual(plaza.scene?.emoteFrame(memberID: nil)?.size, PlazaEmoteArt.size(large: true))
    }
    func testAppNapIsHeldOnlyWhileSomeoneIsOnline() async {
        let code = newCode()
        let a = RuntimeNode(hub: hub, code: code, nickname: "가")
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        a.runtime.start()
        b.runtime.start()
        XCTAssertTrue(a.runtime.isTicking, "the tick stays tied to readiness")
        XCTAssertFalse(a.runtime.isHoldingActivity, "alone, App Nap may nap")
        let connection = hub.connect(a.transport, to: b.transport)
        await settle { a.runtime.isHoldingActivity }
        XCTAssertTrue(a.runtime.isTicking)
        hub.disconnect(connection)
        await settle { !a.runtime.isHoldingActivity }
        XCTAssertTrue(a.runtime.isTicking)
        a.settings.isEnabled = false
        await settle { !a.runtime.isTicking }
        XCTAssertFalse(a.runtime.isHoldingActivity)
    }

    func testFeatureOffStartsNothing() async {
        let suite = "ptb.test.team.off.\(UUID().uuidString)"
        let defaults = TestDefaults.make(suite: suite)
        let settings = TeamSettings(defaults: defaults)   // disabled by default
        var rng = SystemRandomNumberGenerator()
        settings.code = TeamCode.generate(using: &rng)
        settings.nickname = "가"
        XCTAssertFalse(settings.isEnabled)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-off-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let feedURL = dir.appendingPathComponent("team-feed.json")
        let companion = CompanionStore(provider: RuntimeTestProvider(), clock: { runtimeNow },
                                       fileURL: dir.appendingPathComponent("companion-state.json"),
                                       rng: SeededRNG(seed: 7), dittoDisguiseRollingEnabled: false, defaults: defaults)
        let transport = hub.makeTransport()
        let poster = RuntimePoster()
        let runtime = TeamRuntime(settings: settings, companion: companion, transport: transport,
                                  feed: TeamFeedStore(fileURL: feedURL, myMemberID: settings.memberID))
        runtime.notifier = TeamNotifier(settings: settings, poster: poster, isPlazaFrontmost: { false }, showInPlaza: { _ in })
        runtime.start()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.startedCodes.isEmpty, "transport never started")
        XCTAssertFalse(transport.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedURL.path), "no feed file")
        XCTAssertFalse(runtime.isTicking, "no tick")
        XCTAssertFalse(runtime.isHoldingActivity)
        XCTAssertEqual(poster.authorizationRequests, 0, "no authorization request")
    }

    func testInvalidNicknameAttemptKeepsTheStoredNameAndTheTransport() {
        let (a, _) = connectedPair()
        let stops = a.transport.stopCount
        for bad in ["", "   ", String(repeating: "가", count: 13)] {
            XCTAssertFalse(a.settings.commitNickname(bad))
        }
        XCTAssertEqual(a.settings.nickname, "가")
        XCTAssertTrue(a.settings.isReady)
        XCTAssertTrue(a.transport.isRunning)
        XCTAssertEqual(a.transport.stopCount, stops)
        XCTAssertTrue(a.settings.commitNickname(" 다람 "))
        XCTAssertEqual(a.settings.nickname, "다람")
    }

    // MARK: - Ditto mimic

    /// b's plaza (a Ditto), with a standing on the tile to b's left. `a` and `b` are connected.
    private func mimicPlaza() async -> (a: RuntimeNode, b: RuntimeNode, plaza: PlazaWindowController, scene: PlazaScene) {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.mimic.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                          nickname: { "나" }, memberID: { b.settings.memberID },
                                          subject: { .init(speciesID: 132, isShiny: false) }, session: b.runtime.session)
        b.runtime.plaza = plaza
        plaza.prepareScene()
        let scene = try! XCTUnwrap(plaza.scene)
        let start = scene.walker.tile
        let left = TilePoint(x: start.x - 1, y: start.y)
        XCTAssertTrue(PlazaMapData.map.isWalkable(left), "test precondition")
        let sender = a.settings.memberID
        // A Ditto can't copy an egg, and a fresh runtime's companion is one: give `a` a species to copy.
        a.runtime.session.updateCharacter(TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil))
        await settle { b.runtime.session.members[sender]?.character.speciesID == 25 }
        await settle { scene.memberTiles[sender] != nil }
        a.runtime.session.updatePlazaPosition(inPlaza: true, tile: left, facing: .right, isWalking: false)
        var t: TimeInterval = 0
        // An away member is drawn on a shelter tile that can be `left` by chance, so the tile alone is not enough: a Ditto
        // tackle needs the controller's own copy to read "in the plaza", which the scene shows as no longer away.
        await settle {
            t += 0.05; scene.update(t)
            return scene.memberTiles[sender] == left && scene.memberIsAway(sender) == false
        }
        return (a, b, plaza, scene)
    }

    /// A frame an older version sends reveals a disguised me, and pushes nobody.
    func testAnOlderVersionsTackleRevealsMeAndDoesNotPush() async {
        let (a, b, plaza, scene) = await mimicPlaza()
        let start = scene.walker.tile
        let aID = a.settings.memberID
        let found = RuntimeFoundLog()
        a.runtime.session.onEmote = { found.items.append($1) }
        plaza.chooseMenu(.tackle, memberID: aID)
        XCTAssertEqual(plaza.mimicking, aID, "test precondition")
        let before = scene.impactCount   // my own tackle on a already drew one
        a.runtime.session.sendEmote(.tackle, target: b.settings.memberID, pushTiles: 3)
        await settle { scene.impactCount == before + 1 }
        var t: TimeInterval = 100
        for _ in 0..<40 { t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.walker.tile, start)
        XCTAssertNil(plaza.mimicking)
        await settle { found.items.contains { $0.kind == .mimicFound } }
        XCTAssertEqual(found.items.first { $0.kind == .mimicFound }?.targetMemberID, aID)
    }

    /// The two new kinds reach the plaza: a Ditto's tackle only bursts, and a find shows the banner.
    func testMimicKindsReachThePlaza() async {
        let (a, b, plaza, scene) = await mimicPlaza()
        let start = scene.walker.tile
        let session = a.runtime.session
        session.sendEmote(.mimicTackle, target: b.settings.memberID)
        await settle { scene.impactCount == 1 }
        var t: TimeInterval = 100
        for _ in 0..<40 { t += 0.05; scene.update(t) }
        XCTAssertEqual(scene.walker.tile, start)

        session.updateCharacter(TeamMonSummary(speciesID: 132, isShiny: false, form: nil, speciesName: "Ditto", gender: nil))
        session.updateMimic(b.settings.memberID)
        await settle { plaza.shownMimics[a.settings.memberID] == b.settings.memberID }
        session.sendEmote(.mimicFound, target: b.settings.memberID)
        await settle { plaza.banner != nil }
        XCTAssertEqual(plaza.banner, "나님이 가의 메타몽을 찾았어요!")
    }
}

@MainActor private final class RuntimeFoundLog { var items: [TeamEmote] = [] }

private struct DecoyNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
private final class RuntimePoster: TeamNotificationPosting {
    private(set) var bodies: [String] = []
    private(set) var authorizationRequests = 0
    func post(id: String, title: String, body: String) { bodies.append(body) }
    func requestAuthorization() { authorizationRequests += 1 }
}

@MainActor
final class TeamRuntimeNotificationTests: XCTestCase {
    private let hub = FakeTransportHub()
    private var now = runtimeNow

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await settleUntil(condition, file: file, line: line)
    }

    private func pair() -> (a: RuntimeNode, b: RuntimeNode, poster: RuntimePoster) {
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let a = RuntimeNode(hub: hub, code: code, nickname: "가")
        let b = RuntimeNode(hub: hub, code: code, nickname: "나")
        let poster = RuntimePoster()
        b.runtime.notifier = TeamNotifier(settings: b.settings, poster: poster, isPlazaFrontmost: { false },
                                          showInPlaza: { _ in }, clock: { [unowned self] in now })
        a.runtime.start()
        b.runtime.start()
        hub.connect(a.transport, to: b.transport)
        return (a, b, poster)
    }

    private func hatch() -> CompanionTeamEvent {
        CompanionTeamEvent(kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
                           form: nil, isShiny: false, nature: nil, rarity: .common)
    }

    /// A greeting aimed at the Ditto copy never reaches the real teammate's notifications, even when a hostile app
    /// names me as the target.
    func testAGreetingAtTheCopyDoesNotNotifyTheRealOne() async {
        let (a, b, poster) = pair()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        a.runtime.session.sendEmote(.lol, target: b.settings.memberID, overDecoy: true)
        a.runtime.session.sendEmote(.party, target: b.settings.memberID)
        await settle { poster.bodies.count >= 1 }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(poster.bodies, [L(.ko).teamEmoteNotice(nickname: "가", kind: .party)])
    }

    /// The two decoy kinds are routed to the plaza, not drawn as bubbles. The plaza runs on the larger ID, so the other Mac hosts
    /// a copy of it; each kind must then show its own effect (a hop, a banner), which a missing route would never produce.
    func testDecoyKindsReachThePlaza() async throws {
        let (x, y, _) = pair()
        let (host, viewer) = x.settings.memberID < y.settings.memberID ? (x, y) : (y, x)
        let suite = "ptb.test.team.runtime.decoy.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: DecoyNoSprites()),
                                          nickname: { "나" }, memberID: { viewer.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: viewer.runtime.session)
        viewer.runtime.plaza = plaza
        plaza.prepareScene()
        let hostID = host.settings.memberID, viewerID = viewer.settings.memberID
        await settle { viewer.runtime.session.members[hostID] != nil }
        let now = Date()
        let tile = TilePoint(x: PlazaMapData.map.spawn.x + 8, y: PlazaMapData.map.spawn.y + 8)
        XCTAssertTrue(PlazaDitto.isGround(tile, in: PlazaMapData.map), "test precondition")
        host.runtime.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        host.runtime.session.updateDitto(ready: true, state: PlazaDittoState(
            tile: tile, facing: .down, isWalking: nil, isRunning: nil, decoyOf: viewerID, since: now, restUntil: nil))
        await settle { viewer.runtime.session.members[hostID]?.ditto != nil }
        for _ in 0..<20 { await Task.yield() }   // the plaza reads the session through an observation hop
        plaza.advanceDitto(now: now)
        XCTAssertEqual(plaza.shownDitto?.decoyOf, viewerID, "test precondition: the host's copy of me is shown")
        let scene = try XCTUnwrap(plaza.scene)

        // decoyJump: the copy hops (dust), and nothing is drawn as a bubble over the host.
        XCTAssertEqual(scene.dustCount, 0)
        host.runtime.session.sendEmote(.decoyJump, target: nil)
        await settle { scene.dustCount > 0 }
        XCTAssertNil(scene.shownEmote(memberID: hostID))

        // decoyFound: the banner names the finder and the copy turns back.
        host.runtime.session.sendEmote(.decoyFound, target: viewerID)
        await settle { plaza.banner != nil }
        XCTAssertEqual(plaza.shownDitto?.isDecoy, false)
        XCTAssertNil(scene.shownEmote(memberID: hostID))
        plaza.handleClose()
    }

    /// A greeting that was aimed at the copy (`overDecoy`) shows its bubble over the copy on this screen too, so greeting the copy
    /// looks the same as greeting the real one. Without the flag, or with no copy shown, nothing is drawn over the Ditto.
    func testAGreetingAtTheCopyShowsOverTheCopy() async throws {
        let (x, y, _) = pair()
        let (host, viewer) = x.settings.memberID < y.settings.memberID ? (x, y) : (y, x)
        let suite = "ptb.test.team.runtime.decoyemote.\(UUID().uuidString)"
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                          loader: PlazaCharacterLoader(fetcher: DecoyNoSprites()),
                                          nickname: { "나" }, memberID: { viewer.settings.memberID },
                                          subject: { .init(speciesID: 25, isShiny: false) }, session: viewer.runtime.session)
        viewer.runtime.plaza = plaza
        plaza.prepareScene()
        let hostID = host.settings.memberID, viewerID = viewer.settings.memberID
        await settle { viewer.runtime.session.members[hostID] != nil }
        let now = Date()
        let tile = TilePoint(x: PlazaMapData.map.spawn.x + 8, y: PlazaMapData.map.spawn.y + 8)
        host.runtime.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        host.runtime.session.updateDitto(ready: true, state: PlazaDittoState(
            tile: tile, facing: .down, isWalking: nil, isRunning: nil, decoyOf: viewerID, since: now, restUntil: nil))
        await settle { viewer.runtime.session.members[hostID]?.ditto != nil }
        for _ in 0..<20 { await Task.yield() }
        plaza.advanceDitto(now: now)
        XCTAssertEqual(plaza.shownDitto?.decoyOf, viewerID, "test precondition: the host's copy of me is shown")
        let scene = try XCTUnwrap(plaza.scene)
        let key = PlazaDitto.sceneKey

        host.runtime.session.sendEmote(.lol, target: nil)
        await settle { scene.shownEmote(memberID: hostID) == .lol }
        XCTAssertNil(scene.shownEmote(memberID: key), "an ordinary bubble is not drawn over the copy")

        host.runtime.session.sendEmote(.party, target: nil, overDecoy: true)
        await settle { scene.shownEmote(memberID: key) == .party }
        plaza.handleClose()
    }

    func testOthersBigEventReachesTheNotifier() async {
        let (a, b, poster) = pair()
        a.companion.onTeamEvent?(hatch())
        await settle { poster.bodies.count == 1 }
        XCTAssertEqual(poster.bodies, [L(.ko).teamEventText(b.runtime.feed.events[0])])
    }

    func testEvolveNeverReachesNotifier() async {
        let (a, b, poster) = pair()
        a.companion.onTeamEvent?(CompanionTeamEvent(kind: .evolve, speciesID: 26, fromSpeciesID: 25, speciesName: "Raichu",
                                                    fromSpeciesName: "Pikachu", form: nil, isShiny: false, nature: nil, rarity: .common))
        await settle { b.runtime.feed.events.count == 1 }
        XCTAssertTrue(poster.bodies.isEmpty)
    }

    func testReactionToMyEventReachesTheNotifier() async {
        let (a, b, poster) = pair()
        b.companion.onTeamEvent?(hatch())
        await settle { a.runtime.feed.events.count == 1 }
        a.runtime.session.react(to: a.runtime.feed.events[0].id, kind: .cute)
        await settle { poster.bodies.count == 1 }
        XCTAssertEqual(poster.bodies, [L(.ko).teamReactionNotice(nickname: "가")])
    }

    func testEmoteTargetedAtMePosts() async {
        let (a, b, poster) = pair()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        a.runtime.session.sendEmote(.heart, target: b.settings.memberID)
        await settle { poster.bodies.count == 1 }
    }

    /// The first valid emote posts at once and opens the batch window, so anything wrongly accepted after it
    /// would sit in the batch; ticking past the window makes such a leak show up as a second post.
    func testEmoteForSomeoneElseOrWithoutTargetDoesNotPost() async {
        let (a, b, poster) = pair()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        a.runtime.session.sendEmote(.party, target: b.settings.memberID)
        await settle { poster.bodies.count == 1 }
        a.runtime.session.sendEmote(.heart, target: "somebody-else")
        a.runtime.session.sendEmote(.heart, target: nil)
        now = runtimeNow.addingTimeInterval(31)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 1)
    }

    func testNonNotifyingEmoteDoesNotPost() async {
        let (a, b, poster) = pair()
        await settle { b.runtime.session.members[a.settings.memberID] != nil }
        a.runtime.session.sendEmote(.party, target: b.settings.memberID)
        await settle { poster.bodies.count == 1 }
        a.runtime.session.sendEmote(.question, target: b.settings.memberID)
        a.runtime.session.sendEmote(.exclaim, target: b.settings.memberID)
        now = runtimeNow.addingTimeInterval(31)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 1)
    }

    func testTickFlushesTheBatchWindow() async {
        let (a, b, poster) = pair()
        b.companion.onTeamEvent?(hatch())
        await settle { a.runtime.feed.events.count == 1 }
        let id = a.runtime.feed.events[0].id
        a.runtime.session.react(to: id, kind: .cute)
        await settle { poster.bodies.count == 1 }
        a.runtime.session.react(to: id, kind: .lol)
        await settle { b.runtime.feed.reactions(for: id).count == 2 }
        XCTAssertEqual(poster.bodies.count, 1)
        now = runtimeNow.addingTimeInterval(31)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 2)
    }

    private func batchedReaction(_ a: RuntimeNode, _ b: RuntimeNode, _ poster: RuntimePoster) async {
        b.companion.onTeamEvent?(hatch())
        await settle { a.runtime.feed.events.count == 1 }
        let id = a.runtime.feed.events[0].id
        a.runtime.session.react(to: id, kind: .cute)
        await settle { poster.bodies.count == 1 }
        a.runtime.session.react(to: id, kind: .lol)
        await settle { b.runtime.feed.reactions(for: id).count == 2 }
    }

    func testBatchedNoticesDoNotOutliveTheTeam() async {
        let (a, b, poster) = pair()
        await batchedReaction(a, b, poster)
        b.settings.isEnabled = false
        await settle { !b.runtime.isTicking }
        b.settings.isEnabled = true
        await settle { b.runtime.isTicking }
        now = runtimeNow.addingTimeInterval(31)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 1)
    }

    func testBatchedNoticesDoNotOutliveACodeChange() async {
        let (a, b, poster) = pair()
        await batchedReaction(a, b, poster)
        var rng = SystemRandomNumberGenerator()
        b.settings.code = TeamCode.generate(using: &rng)
        await Task.yield(); await Task.yield()
        now = runtimeNow.addingTimeInterval(31)
        b.runtime.tickOnce()
        XCTAssertEqual(poster.bodies.count, 1)
    }

    func testNoAuthorizationRequestWhileTheTeamIsOff() async {
        var rng = SystemRandomNumberGenerator()
        let node = RuntimeNode(hub: hub, code: TeamCode.generate(using: &rng), nickname: "가")
        node.settings.isEnabled = false
        let poster = RuntimePoster()
        node.runtime.notifier = TeamNotifier(settings: node.settings, poster: poster, isPlazaFrontmost: { false },
                                             showInPlaza: { _ in })
        node.runtime.start()
        await Task.yield()
        XCTAssertEqual(poster.authorizationRequests, 0)
        XCTAssertFalse(node.runtime.isTicking)
        node.settings.isEnabled = true
        await settle { poster.authorizationRequests == 1 }
    }
}
