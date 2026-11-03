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
        let defaults = UserDefaults(suiteName: suite)!
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

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
}

@MainActor
final class TeamRuntimeTests: XCTestCase {
    /// The fake transports hold their hub unowned, so it must outlive the test body.
    private let hub = FakeTransportHub()

    private func newCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    /// Lets the main actor run queued observation hops until `condition` holds.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
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

    /// A teammate's jump makes their character hop here.
    func testReceivedJumpHopsThatTeammate() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.jump.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
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

    /// A tackle aimed at me pushes me one tile away from the teammate who did it, when they stand right next to me.
    /// From further away (I walked off while their menu was open) it only shows the impact.
    func testTackleFromBesideMePushesMeOneTileAway() async {
        let (a, b) = connectedPair()
        let suite = "ptb.test.team.runtime.tackle.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
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

    func testSettingsChangeRestartsTransport() async {
        let (a, _) = connectedPair()
        XCTAssertEqual(a.transport.startedCodes.count, 1)
        a.settings.code = newCode()
        await settle { a.transport.startedCodes.count == 2 }
        XCTAssertEqual(a.transport.stopCount, 1)
        XCTAssertTrue(a.transport.isRunning)
    }

    func testNotReadyClosesPlaza() async {
        let settingsDefaults = UserDefaults(suiteName: "ptb.test.team.runtime.close.\(UUID().uuidString)")!
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
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
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
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plaza = PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
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
        XCTAssertEqual(plaza.scene?.emoteFrame(memberID: sender)?.size, PlazaEmoteArt.size, "an ordinary emote keeps its size")
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
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
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
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
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
