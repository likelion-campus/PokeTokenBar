import XCTest
@testable import PokeTokenBar

/// Frames only a modified app sends. Anyone with the team code can send them, so each test feeds the real session one.
@MainActor
final class TeamHostilePeerTests: XCTestCase {
    private let hub = FakeTransportHub()
    private let now = Date(timeIntervalSince1970: 1_793_242_800)   // 2026-10-29 12:00 KST
    private var clock = Date(timeIntervalSince1970: 1_793_242_800)
    private var dir: URL!
    private var suite = ""
    private var settings: TeamSettings!
    private var feed: TeamFeedStore!
    private var transport: FakeTeamTransport!
    private var session: TeamSession!
    private var profilesServed = 0
    private var bigEvents: [TeamEvent] = []
    private var reactionsToMine: [TeamReaction] = []

    private static let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamHostilePeerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "ptb.test.team.hostile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(TestDefaults.make(suite: suite))
        defaults.set("me", forKey: "team.memberID")
        settings = TeamSettings(defaults: defaults)
        var rng = SystemRandomNumberGenerator()
        settings.code = TeamCode.generate(using: &rng)
        settings.nickname = "나"
        settings.isEnabled = true
        feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me", clock: { [unowned self] in clock })
        transport = hub.makeTransport()
        session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: { [unowned self] in
            profilesServed += 1
            return TeamMemberProfile(memberID: "me", nickname: "나", current: Self.mon, dex: [])
        }, clock: { [unowned self] in clock })
        session.onBigEvent = { [unowned self] in bigEvents.append($0) }
        session.onReactionToMine = { [unowned self] r, _ in reactionsToMine.append(r) }
        session.applySettings()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private final class Peer {
        let transport: FakeTeamTransport
        var peerID: TeamPeerID?
        var received: [TeamMessage] = []
        init(_ transport: FakeTeamTransport) { self.transport = transport }
    }

    /// Connects a bare endpoint with no session behind it, and says hello as `memberID`.
    private func join(_ memberID: String, version: Int = TeamWire.protocolVersion, current: TeamMonSummary = mon) -> Peer {
        let peer = Peer(hub.makeTransport())
        var rng = SystemRandomNumberGenerator()
        peer.transport.start(code: TeamCode.generate(using: &rng))
        peer.transport.onPeerConnected = { [unowned peer] id, _ in peer.peerID = id }
        peer.transport.onMessage = { [unowned peer] _, m in peer.received.append(m) }
        hub.connect(peer.transport, to: transport)
        say(.hello(TeamHello(memberID: memberID, nickname: "x", protocolVersion: version, current: current)), from: peer)
        return peer
    }

    private func say(_ m: TeamMessage, from peer: Peer) {
        guard let id = peer.peerID else { return }
        peer.transport.send(m, to: id)
    }

    private func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func event(_ id: String, author: String) -> TeamEvent {
        TeamEvent(id: id, authorID: author, authorNickname: author, kind: .hatch, speciesID: 25, fromSpeciesID: nil,
                  speciesName: "Pikachu", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common,
                  day: day(clock), occurredAt: clock)
    }

    private func reaction(_ id: String, on eventID: String, author: String) -> TeamReaction {
        TeamReaction(id: id, eventID: eventID, authorID: author, authorNickname: author, kind: .cute, text: nil, createdAt: clock)
    }

    // MARK: - Dance

    /// A modified app can send any `danceStyle` and as many dances as it likes. A huge or garbage style plays the default
    /// dance, and a flood only restarts the round: the plaza gains no nodes.
    func testAHugeDanceStyleAndAFloodOfDancesGrowNothing() {
        let map = PlazaMapData.map
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        scene.size = CGSize(width: 960, height: 640)
        scene.applyMembers([PlazaSceneMember(memberID: "A", nickname: "A", isAway: false,
                                             tile: TilePoint(x: map.spawn.x + 2, y: map.spawn.y), facing: .down, isWalking: false)])
        scene.update(0)
        let nodes = scene.children.count
        var received = 0
        session.onEmote = { id, emote in
            received += 1
            if emote.kind == .dance { scene.playDance(memberID: id, style: emote.danceStyle) }
        }
        let peer = join("A")
        let huge = String(repeating: "x", count: 900_000)
        say(.emote(TeamEmote(kind: .dance, targetMemberID: nil, danceStyle: huge)), from: peer)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(scene.danceStyle(memberID: "A"), .sway)
        for i in 0..<500 {
            say(.emote(TeamEmote(kind: .dance, targetMemberID: "someone", danceStyle: i.isMultiple(of: 2) ? "\u{0}\(i)" : "bigHop")), from: peer)
        }
        XCTAssertEqual(received, 501)
        XCTAssertEqual(scene.children.count, nodes)
        XCTAssertTrue(scene.isDancing(memberID: "A"))
    }

    // MARK: - Sizes

    func testAMemberIDTooLongToBeRealIsRefused() {
        _ = join(String(repeating: "x", count: TeamWire.maxFieldBytes + 1))
        XCTAssertTrue(session.members.isEmpty)
        XCTAssertEqual(transport.refuseCalls.count, 1)
    }

    func testHostileDittoStatesAreDropped() {
        let peer = join("hostile")
        let year: TimeInterval = 365 * 86400
        func ditto(decoyOf: String? = nil, since: Date? = nil, restUntil: Date? = nil) -> PlazaDittoState {
            PlazaDittoState(tile: TilePoint(x: 1, y: 1), facing: .down, isWalking: nil, isRunning: nil,
                            decoyOf: decoyOf, since: since ?? clock, restUntil: restUntil)
        }
        let hostile = [ditto(decoyOf: String(repeating: "x", count: 10_000)),
                       ditto(since: clock.addingTimeInterval(year)),
                       ditto(restUntil: clock.addingTimeInterval(year))]
        for d in hostile {
            var p = TeamPresence(nickname: "x", character: Self.mon, inPlaza: true, tile: TilePoint(x: 7, y: 8),
                                 facing: .left, isWalking: true)
            p.ditto = d
            p.dittoReady = true
            say(.presence(p), from: peer)
            XCTAssertNil(session.members["hostile"]?.ditto)
            XCTAssertEqual(session.members["hostile"]?.tile, TilePoint(x: 7, y: 8), "the rest of the presence still applies")
            XCTAssertEqual(session.members["hostile"]?.dittoReady, true)
        }
    }

    /// A modified app can send any totals. They are kept between zero and a size that still fits the roster.
    func testAbsurdUsageTotalsAreBounded() {
        let peer = join("hostile")
        var p = TeamPresence(nickname: "x", character: Self.mon, inPlaza: true, tile: TilePoint(x: 7, y: 8), facing: .left, isWalking: true)
        p.usage = TeamUsage(today: .min, week: -1, month: .max)
        say(.presence(p), from: peer)
        XCTAssertEqual(session.members["hostile"]?.usage, TeamUsage(today: 0, week: 0, month: TeamUsage.maxTokens))
        XCTAssertEqual(TokenFormatter.compact(TeamUsage.maxTokens), "999.99B")
        p.usage = TeamUsage(today: 5, week: TeamUsage.maxTokens, month: TeamUsage.maxTokens + 1)
        say(.presence(p), from: peer)
        XCTAssertEqual(session.members["hostile"]?.usage, TeamUsage(today: 5, week: TeamUsage.maxTokens, month: TeamUsage.maxTokens))
    }

    func testAnOverlongMimicIsDropped() {
        let peer = join("hostile")
        for length in [TeamWire.maxFieldBytes + 1, 10_000] {
            var p = TeamPresence(nickname: "x", character: Self.mon, inPlaza: true, tile: TilePoint(x: 7, y: 8),
                                 facing: .left, isWalking: true)
            p.mimicOf = String(repeating: "x", count: length)
            say(.presence(p), from: peer)
            XCTAssertNil(session.members["hostile"]?.mimicOf, "\(length) bytes")
            XCTAssertNil(session.members["hostile"]?.mimicSeenAt)
            XCTAssertEqual(session.members["hostile"]?.tile, TilePoint(x: 7, y: 8), "the rest of the presence still applies")
        }
        var ok = TeamPresence(nickname: "x", character: Self.mon, inPlaza: true, tile: TilePoint(x: 7, y: 8),
                              facing: .left, isWalking: true)
        ok.mimicOf = String(repeating: "x", count: TeamWire.maxFieldBytes)
        say(.presence(ok), from: peer)
        XCTAssertEqual(session.members["hostile"]?.mimicOf?.utf8.count, TeamWire.maxFieldBytes)
    }

    func testAMemberIDAtTheLimitIsServed() {
        _ = join(String(repeating: "x", count: TeamWire.maxFieldBytes))
        XCTAssertEqual(session.members.count, 1)
    }

    func testOversizeCharacterFieldsNeverReachTheMemberTable() throws {
        let long = String(repeating: "x", count: TeamWire.maxFieldBytes + 1)
        let fat = TeamMonSummary(speciesID: 25, isShiny: true, form: PokemonForm(long), speciesName: long, gender: nil)
        let peer = join("A", current: fat)
        var kept = try XCTUnwrap(session.members["A"]?.character)
        XCTAssertNil(kept.speciesName, "from the hello")
        XCTAssertNil(kept.form)
        XCTAssertEqual(kept.speciesID, 25, "only the oversize fields go")

        say(.presence(TeamPresence(nickname: "x", character: fat, inPlaza: true, tile: nil, facing: nil, isWalking: false)), from: peer)
        kept = try XCTUnwrap(session.members["A"]?.character)
        XCTAssertNil(kept.speciesName, "from a presence")
        XCTAssertNil(kept.form)
    }

    func testCharacterFieldsAtTheLimitAreKept() throws {
        let edge = String(repeating: "x", count: TeamWire.maxFieldBytes)
        _ = join("A", current: TeamMonSummary(speciesID: 25, isShiny: false, form: PokemonForm(edge), speciesName: edge, gender: nil))
        let kept = try XCTUnwrap(session.members["A"]?.character)
        XCTAssertEqual(kept.speciesName, edge)
        XCTAssertEqual(kept.form, PokemonForm(edge))
    }

    func testAFrameBiggerThanABatchIsIgnored() {
        let peer = join("A")
        let many = TeamSession.batchSize + 1
        say(.events((0..<many).map { event("e\($0)", author: "A") }, live: false), from: peer)
        say(.reactions((0..<many).map { reaction("r\($0)", on: "e", author: "A") }, live: false), from: peer)
        XCTAssertTrue(feed.events.isEmpty)
        XCTAssertTrue(feed.reactionIDs.isEmpty)
    }

    func testAFullBatchIsStored() {
        let peer = join("A")
        say(.events((0..<TeamSession.batchSize).map { event("e\($0)", author: "B") }, live: false), from: peer)
        say(.reactions((0..<TeamSession.batchSize).map { reaction("r\($0)", on: "e\($0)", author: "B") }, live: false), from: peer)
        XCTAssertEqual(feed.events.count, TeamSession.batchSize)
        XCTAssertEqual(feed.reactionIDs.count, TeamSession.batchSize)
    }

    // MARK: - Rates

    private var eventReplies: (Peer) -> Int {
        { $0.received.filter { if case .events = $0 { true } else { false } }.count }
    }

    /// One tiny frame asks for the whole feed back, so it is the cheapest way to make this Mac work.
    func testInventoryFloodIsAnsweredOnlyAFewTimes() {
        feed.insert(event("mine", author: "me"))
        let peer = join("A")
        for _ in 0..<50 { say(.inventory(eventIDs: [], reactionIDs: []), from: peer) }
        XCTAssertEqual(eventReplies(peer), TeamSession.inventoryReplyBurst)
        clock = clock.addingTimeInterval(TeamSession.inventoryReplyInterval)
        say(.inventory(eventIDs: [], reactionIDs: []), from: peer)
        XCTAssertEqual(eventReplies(peer), TeamSession.inventoryReplyBurst + 1, "it comes back with time")
    }

    func testProfileFloodIsAnsweredOnlyAFewTimes() {
        let peer = join("A")
        let before = profilesServed
        for _ in 0..<50 { say(.profileRequest, from: peer) }
        XCTAssertEqual(profilesServed - before, TeamSession.profileReplyBurst)
        clock = clock.addingTimeInterval(TeamSession.profileReplyInterval)
        say(.profileRequest, from: peer)
        XCTAssertEqual(profilesServed - before, TeamSession.profileReplyBurst + 1)
    }

    /// Replies are limited per link, so one member's flood does not cost a teammate their card.
    func testAnotherMembersRepliesAreUntouched() {
        let flood = join("A")
        for _ in 0..<50 { say(.profileRequest, from: flood) }
        let other = join("B")
        let before = profilesServed
        say(.profileRequest, from: other)
        XCTAssertEqual(profilesServed - before, 1)
    }

    // MARK: - Whose name is on it

    /// Anyone can say any member ID, so a refusal must never reach the real member.
    func testAWrongVersionHelloUnderAMembersIDDoesNotLockThemOut() {
        _ = join("B", version: TeamWire.protocolVersion + 1)
        XCTAssertTrue(session.members.isEmpty)
        _ = join("B")
        XCTAssertNotNil(session.members["B"])
    }

    func testABadFrameUnderAMembersIDDoesNotLockThemOut() throws {
        let impostor = join("B")
        let link = try XCTUnwrap(transport.peerIDs.first)
        transport.onPeerBadFrame?(link)
        _ = impostor
        XCTAssertNil(session.members["B"])
        _ = join("B")
        XCTAssertNotNil(session.members["B"])
    }

    func testALiveEventUnderAnotherNameIsDropped() {
        let peer = join("A")
        say(.events([event("forged", author: "B")], live: true), from: peer)
        XCTAssertTrue(feed.events.isEmpty, "a live frame is the sender's own news")
        XCTAssertTrue(bigEvents.isEmpty)
    }

    func testALiveEventUnderTheSendersNameGoesThrough() {
        let peer = join("A")
        say(.events([event("own", author: "A")], live: true), from: peer)
        XCTAssertEqual(feed.events.map(\.id), ["own"])
        XCTAssertEqual(bigEvents.map(\.id), ["own"])
    }

    /// Sync carries other members' news on purpose: it is how someone who was away catches up.
    func testASyncedEventKeepsItsAuthorAndStaysQuiet() {
        let peer = join("A")
        say(.events([event("theirs", author: "B")], live: false), from: peer)
        XCTAssertEqual(feed.events.map(\.authorID), ["B"])
        XCTAssertTrue(bigEvents.isEmpty)
    }

    func testALiveReactionUnderAnotherNameIsDropped() {
        feed.insert(event("mine", author: "me"))
        let peer = join("A")
        say(.reactions([reaction("forged", on: "mine", author: "B")], live: true), from: peer)
        XCTAssertTrue(feed.reactionIDs.isEmpty)
        XCTAssertTrue(reactionsToMine.isEmpty)
    }

    func testALiveReactionUnderTheSendersNameGoesThrough() {
        feed.insert(event("mine", author: "me"))
        let peer = join("A")
        say(.reactions([reaction("own", on: "mine", author: "A")], live: true), from: peer)
        XCTAssertEqual(reactionsToMine.map(\.id), ["own"])
    }

    // MARK: - A plaza window behind others

    private func scene() -> PlazaScene {
        let map = PlazaMapData.map
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        scene.applyMembers([PlazaSceneMember(memberID: "A", nickname: "A", isAway: false, tile: map.spawn, facing: .down, isWalking: false)])
        return scene
    }

    /// Their removal runs on SKActions and frames, and a covered window has neither, so each one would stay for good.
    func testEffectsAddNothingWhileTheSceneIsPaused() {
        let s = scene()
        s.isPaused = true
        let before = s.children.count
        for _ in 0..<50 {
            s.playJump(memberID: "A")
            s.playTackle(by: "A", on: nil, direction: .down)
            s.playSparkle(memberID: "A")
        }
        XCTAssertEqual(s.children.count, before)
        XCTAssertEqual(s.sparkleCount, 0)
    }

    func testEffectsStillPlayOnAVisibleScene() {
        let jump = scene(), tackle = scene(), sparkle = scene()
        let before = jump.children.count
        jump.playJump(memberID: "A")
        tackle.playTackle(by: "A", on: nil, direction: .down)
        sparkle.playSparkle(memberID: "A")
        XCTAssertGreaterThan(jump.children.count, before)
        XCTAssertGreaterThan(tackle.children.count, before)
        XCTAssertGreaterThan(sparkle.sparkleCount, 0)
    }

    func testTheAsleepListStopsGrowing() {
        for i in 0..<(TeamSession.maxAsleepMembers + 20) {
            let peer = join("gone-\(i)")
            hub.disconnect(hub.connection(of: peer.transport))
        }
        XCTAssertEqual(session.asleepMembers.count, TeamSession.maxAsleepMembers)
        XCTAssertNotNil(session.asleepMembers["gone-\(TeamSession.maxAsleepMembers + 19)"], "the one who just left is never the one dropped")
    }
}
