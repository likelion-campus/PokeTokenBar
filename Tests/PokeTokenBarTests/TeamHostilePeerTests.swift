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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
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
        UserDefaults().removePersistentDomain(forName: suite)
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

    // MARK: - Sizes

    func testAMemberIDTooLongToBeRealIsRefused() {
        _ = join(String(repeating: "x", count: TeamWire.maxFieldBytes + 1))
        XCTAssertTrue(session.members.isEmpty)
        XCTAssertEqual(transport.refuseCalls.count, 1)
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

    func testTheAsleepListStopsGrowing() {
        for i in 0..<(TeamSession.maxAsleepMembers + 20) {
            let peer = join("gone-\(i)")
            hub.disconnect(hub.connection(of: peer.transport))
        }
        XCTAssertEqual(session.asleepMembers.count, TeamSession.maxAsleepMembers)
        XCTAssertNotNil(session.asleepMembers["gone-\(TeamSession.maxAsleepMembers + 19)"], "the one who just left is never the one dropped")
    }
}
