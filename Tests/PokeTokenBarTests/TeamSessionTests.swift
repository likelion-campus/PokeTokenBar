import XCTest
@testable import PokeTokenBar

private func newCode() -> TeamCode {
    var rng = SystemRandomNumberGenerator()
    return TeamCode.generate(using: &rng)
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_793_242_800) // 2026-10-29 12:00 KST
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// One simulated Mac: settings, feed, fake transport and the session on top.
@MainActor
private final class Node {
    let settings: TeamSettings
    let feed: TeamFeedStore
    let transport: FakeTeamTransport
    let session: TeamSession
    let nickname: String
    var memberID: String { settings.memberID }
    var bigEvents: [TeamEvent] = []
    var reactionsToMine: [(TeamReaction, TeamEvent)] = []
    var emotes: [(memberID: String, emote: TeamEmote)] = []

    static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    static let eevee = TeamMonSummary(speciesID: 133, isShiny: true, form: nil, speciesName: "Eevee", gender: nil)

    init(_ name: String, hub: FakeTransportHub, clock: TestClock, code: TeamCode?, defaults: UserDefaults, feedURL: URL, enabled: Bool = true) {
        nickname = name
        settings = TeamSettings(defaults: defaults)
        if let code { settings.code = code }
        settings.nickname = name
        settings.isEnabled = enabled
        feed = TeamFeedStore(fileURL: feedURL, myMemberID: settings.memberID, clock: { clock.now })
        transport = hub.makeTransport()
        let settings = settings
        let nickname = name
        session = TeamSession(settings: settings, feed: feed, transport: transport,
                              profileProvider: {
                                  TeamMemberProfile(memberID: settings.memberID, nickname: nickname, current: Node.pikachu,
                                                    dex: [TeamDexSpecies(speciesID: 25, form: nil, name: "Pikachu", rarity: .common,
                                                                         hasShiny: false, hasNormal: true)])
                              },
                              clock: { clock.now })
        session.onBigEvent = { [unowned self] in bigEvents.append($0) }
        session.onReactionToMine = { [unowned self] in reactionsToMine.append(($0, $1)) }
        session.onEmote = { [unowned self] in emotes.append(($0, $1)) }
        session.applySettings()
    }

    var presencesSent: Int {
        transport.sentMessages { if case .presence = $0 { true } else { false } }
    }

    var expectedProfile: TeamMemberProfile {
        TeamMemberProfile(memberID: memberID, nickname: nickname, current: Node.pikachu,
                          dex: [TeamDexSpecies(speciesID: 25, form: nil, name: "Pikachu", rarity: .common,
                                               hasShiny: false, hasNormal: true)])
    }
}

/// A bare transport endpoint the test drives by hand (a peer with no session behind it).
@MainActor
private final class RawPeer {
    let transport: FakeTeamTransport
    var received: [TeamMessage] = []
    var peerID: TeamPeerID?

    init(hub: FakeTransportHub) {
        transport = hub.makeTransport()
        transport.start(code: newCode())
        transport.onMessage = { [unowned self] _, m in received.append(m) }
        transport.onPeerConnected = { [unowned self] peer, _ in peerID = peer }
    }

    func say(_ m: TeamMessage) { transport.send(m, to: peerID!) }

    func hello(memberID: String = UUID().uuidString, nickname: String = "Raw", version: Int = TeamWire.protocolVersion) {
        say(.hello(TeamHello(memberID: memberID, nickname: nickname, protocolVersion: version, current: Node.eevee)))
    }
}

@MainActor
final class TeamSessionTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var clock: TestClock!
    private var code: TeamCode!
    private var dirs: [URL] = []
    private var suites: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        hub = FakeTransportHub()
        clock = TestClock()
        code = newCode()
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        dirs = []; suites = []
        try await super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeFeedURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir.appendingPathComponent("team-feed.json")
    }

    private func node(_ name: String, code: TeamCode? = nil, enabled: Bool = true) -> Node {
        Node(name, hub: hub, clock: clock, code: code ?? self.code, defaults: makeDefaults(), feedURL: makeFeedURL(), enabled: enabled)
    }

    private func hatch() -> CompanionTeamEvent { companion(.hatch) }

    private func companion(_ kind: TeamEventKind) -> CompanionTeamEvent {
        CompanionTeamEvent(kind: kind, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
                           form: nil, isShiny: false, nature: nil, rarity: .common)
    }

    @discardableResult
    private func connect(_ a: Node, _ b: Node) -> FakeConnection { hub.connect(a.transport, to: b.transport) }

    // MARK: - News and reactions

    func testHelloThenInventorySyncFillsMissingEvents() {
        let a = node("A"), b = node("B")
        a.session.publish(hatch())
        a.session.publish(companion(.graduate))
        XCTAssertEqual(a.feed.events.count, 2)
        connect(a, b)
        XCTAssertEqual(Set(b.feed.events.map(\.id)), Set(a.feed.events.map(\.id)))
        XCTAssertEqual(b.bigEvents.count, 0)
    }

    func testLivePublishReachesOthersOnce() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.publish(hatch())
        XCTAssertEqual(b.bigEvents.count, 1)
        XCTAssertEqual(a.bigEvents.count, 1)
        XCTAssertEqual(b.feed.events.count, 1)
        XCTAssertEqual(b.bigEvents.first?.authorID, a.memberID)
    }

    func testDuplicateEventFromTwoPeersFiresOnce() {
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b); connect(a, c)
        let bc = connect(c, b)
        a.session.publish(hatch())
        let e = b.feed.events[0]
        let peer = bc.peerID(on: b.transport)
        b.transport.onMessage?(peer, .events([e], live: true))
        b.transport.onMessage?(peer, .events([e], live: false))
        XCTAssertEqual(b.bigEvents.count, 1)
        XCTAssertEqual(b.feed.events.count, 1)
    }

    func testEvolveFiresNoBigEvent() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.publish(companion(.evolve))
        XCTAssertEqual(a.bigEvents.count, 0)
        XCTAssertEqual(b.bigEvents.count, 0)
        XCTAssertEqual(b.feed.events.count, 1)
    }

    func testOfflinePublishIsDayOnlyAndSyncedLaterQuietly() {
        let a = node("A"), b = node("B")
        a.session.publish(hatch())
        XCTAssertNil(a.feed.events[0].occurredAt)
        XCTAssertEqual(a.bigEvents.count, 0)
        connect(a, b)
        XCTAssertEqual(b.feed.events.count, 1)
        XCTAssertEqual(b.bigEvents.count, 0)
    }

    func testReactionToMyEventCallsBackOnce() {
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b); connect(a, c); connect(b, c)
        a.session.publish(hatch())
        let id = a.feed.events[0].id
        b.session.react(to: id, kind: .cute)
        XCTAssertEqual(a.reactionsToMine.count, 1)
        XCTAssertEqual(a.reactionsToMine.first?.1.id, id)
        XCTAssertEqual(c.feed.reactions(for: id).count, 1)
        XCTAssertEqual(c.reactionsToMine.count, 0)
        b.session.react(to: id, kind: .cute)   // same author and kind: not new
        XCTAssertEqual(a.reactionsToMine.count, 1)
    }

    func testReactionWhileAuthorOfflineArrivesLaterQuietly() {
        let a = node("A"), b = node("B"), c = node("C")
        let ab = connect(a, b); let ac = connect(a, c); connect(b, c)
        a.session.publish(hatch())
        let id = a.feed.events[0].id
        hub.disconnect(ab); hub.disconnect(ac)
        b.session.react(to: id, kind: .congrats)
        XCTAssertEqual(c.feed.reactions(for: id).count, 1)
        connect(a, b)
        XCTAssertEqual(a.feed.reactions(for: id).count, 1)
        XCTAssertEqual(a.reactionsToMine.count, 0)
    }

    func testReconnectResyncsWithoutDuplicates() {
        let a = node("A"), b = node("B")
        let first = connect(a, b)
        a.session.publish(hatch())
        XCTAssertEqual(b.feed.events.count, 1)
        hub.disconnect(first)
        a.session.publish(companion(.graduate))
        a.session.publish(companion(.dittoReveal))
        connect(a, b)
        XCTAssertEqual(b.feed.events.count, 3)
        XCTAssertEqual(Set(b.feed.events.map(\.id)), Set(a.feed.events.map(\.id)))
    }

    func testInventorySyncSendsInBatchesOf100() {
        let a = node("A"), b = node("B")
        for i in 0..<250 {
            a.feed.insert(TeamEvent(id: "e\(i)", authorID: a.memberID, authorNickname: "A", kind: .evolve, speciesID: 25,
                                    fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil, form: nil, isShiny: false,
                                    nature: nil, rarity: .common, day: "2026-10-29", occurredAt: nil))
        }
        connect(a, b)
        let batches = a.transport.sent.compactMap { sent -> Int? in
            if case .events(let events, let live) = sent.message, !live { return events.count }
            return nil
        }
        XCTAssertEqual(batches, [100, 100, 50])
        XCTAssertEqual(b.feed.events.count, 250)
    }

    // MARK: - Hello rules

    func testProtocolMismatchMarksIncompatibleAndDisconnects() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(version: TeamWire.protocolVersion + 1)
        XCTAssertTrue(a.session.hasIncompatiblePeer)
        XCTAssertEqual(a.transport.disconnectCalls.count, 1)
        XCTAssertEqual(a.transport.linkCount, 0)
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testOwnMemberIDIsDisconnected() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: a.memberID)
        XCTAssertEqual(a.transport.disconnectCalls.count, 1)
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertFalse(a.session.hasIncompatiblePeer)
    }

    func testMessageBeforeHelloIsIgnored() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.say(.events([TeamEvent(id: "x", authorID: "z", authorNickname: "Z", kind: .hatch, speciesID: 1, fromSpeciesID: nil,
                                   speciesName: "Bulbasaur", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil,
                                   rarity: .common, day: "2026-10-29", occurredAt: clock.now)], live: true))
        XCTAssertTrue(a.feed.events.isEmpty)
        XCTAssertEqual(a.bigEvents.count, 0)
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testDuplicateConnectionsKeepOneAndBothSidesAgree() {
        let a = node("A"), b = node("B")
        let first = connect(a, b)
        let second = connect(b, a)
        XCTAssertEqual(a.session.members.count, 1)
        XCTAssertEqual(b.session.members.count, 1)
        let preferredInitiator = min(a.memberID, b.memberID)
        let expected = (a.memberID == preferredInitiator) ? first : second
        let dropped = (a.memberID == preferredInitiator) ? second : first
        for n in [a, b] {
            XCTAssertTrue(n.transport.hasLink(expected))
            XCTAssertFalse(n.transport.hasLink(dropped))
            XCTAssertEqual(n.transport.linkCount, 1)
        }
        a.session.publish(hatch())
        XCTAssertEqual(b.bigEvents.count, 1)
    }

    func testNewerConnectionReplacesStaleOne() {
        let a = node("A"), b = node("B")
        let old = connect(a, b)
        hub.sever(old, silentlyOn: a.transport)   // A's transport forgot the link; B still holds it. Both links are dialed by A, so the newest wins whichever ID is smaller
        let fresh = connect(a, b)
        let freshPeer = fresh.peerID(on: b.transport)
        XCTAssertEqual(b.transport.disconnectCalls, [.init(peer: old.peerID(on: b.transport), kept: freshPeer)])
        XCTAssertTrue(b.transport.hasLink(fresh))
        XCTAssertFalse(b.transport.hasLink(old))
        XCTAssertEqual(b.session.members.count, 1)
        a.session.publish(hatch())
        XCTAssertEqual(b.bigEvents.count, 1)
    }

    /// `lo` has the smaller member ID, so a connection `lo` dials is the preferred one.
    private func orderedPair() -> (lo: Node, hi: Node) {
        let a = node("A"), b = node("B")
        return a.memberID < b.memberID ? (a, b) : (b, a)
    }

    /// Simulates a Mac restarting: its session and transport lose every connection, silently.
    private func restart(_ n: Node) {
        n.settings.isEnabled = false
        n.session.applySettings()
        n.settings.isEnabled = true
        n.session.applySettings()
    }

    func testStalePreferredConnectionBeatsFreshNonPreferredOneUntilRedialed() {
        let (lo, hi) = orderedPair()
        let old = connect(lo, hi)   // dialed by lo: the preferred direction
        hub.sever(old, silentlyOn: hi.transport)
        restart(hi)                  // hi forgot it; lo still holds the dead link
        let fresh = connect(hi, lo)  // hi dials lo: not the preferred direction
        XCTAssertEqual(lo.transport.disconnectCalls,
                       [.init(peer: fresh.peerID(on: lo.transport), kept: old.peerID(on: lo.transport))])
        XCTAssertTrue(lo.transport.hasLink(old))
        XCTAssertFalse(lo.transport.hasLink(fresh))
        XCTAssertEqual(lo.session.members.count, 1)

        let redialed = connect(lo, hi)   // lo discovers hi's new name and dials it
        XCTAssertEqual(lo.transport.disconnectCalls.last,
                       .init(peer: old.peerID(on: lo.transport), kept: redialed.peerID(on: lo.transport)))
        for n in [lo, hi] {
            XCTAssertTrue(n.transport.hasLink(redialed))
            XCTAssertEqual(n.transport.linkCount, 1)
            XCTAssertEqual(n.session.members.count, 1)
        }
        lo.session.publish(hatch())
        XCTAssertEqual(hi.bigEvents.count, 1)
    }

    func testStalePreferredConnectionIsDroppedAfterSilenceAndLaterDialIsKept() {
        let (lo, hi) = orderedPair()
        let old = connect(lo, hi)
        hub.sever(old, silentlyOn: hi.transport)
        restart(hi)
        clock.advance(31)
        lo.session.tick()
        XCTAssertTrue(lo.session.members.isEmpty)
        XCTAssertEqual(lo.transport.disconnectCalls.count, 1)

        let fresh = connect(hi, lo)
        for n in [lo, hi] {
            XCTAssertTrue(n.transport.hasLink(fresh))
            XCTAssertEqual(n.session.members.count, 1)
        }
        XCTAssertEqual(lo.transport.disconnectCalls.count, 1)
    }

    func testOnlyConnectionIsKeptEvenIfNotPreferred() {
        let a = node("A"), b = node("B")
        let (high, low) = a.memberID > b.memberID ? (a, b) : (b, a)
        connect(high, low)
        XCTAssertTrue(a.transport.disconnectCalls.isEmpty)
        XCTAssertTrue(b.transport.disconnectCalls.isEmpty)
        XCTAssertEqual(a.session.members.count, 1)
        XCTAssertEqual(b.session.members.count, 1)
    }

    // MARK: - Heartbeat and timeouts

    func testSilentPeerIsDroppedAfterTimeout() {
        let a = node("A"), b = node("B")
        connect(a, b)
        clock.advance(29)
        a.session.tick()
        XCTAssertEqual(a.session.members.count, 1)
        clock.advance(2)
        a.session.tick()
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertEqual(a.transport.disconnectCalls.count, 1)
    }

    func testHeartbeatSendsPresence() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let before = a.presencesSent
        clock.advance(11)
        a.session.tick()
        XCTAssertEqual(a.presencesSent, before + 1)
    }

    func testNoHeartbeatBeforeTenSeconds() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let before = a.presencesSent
        clock.advance(9)
        a.session.tick()
        XCTAssertEqual(a.presencesSent, before)
    }

    func testInventoryIsResentEveryFiveMinutes() {
        let a = node("A"), b = node("B")
        connect(a, b)
        func inventories() -> Int { a.transport.sentMessages { if case .inventory = $0 { true } else { false } } }
        let before = inventories()
        for _ in 0..<29 {   // keep both sides talking so the 30 s silence rule stays out of the way
            clock.advance(10)
            a.session.tick(); b.session.tick()
        }
        XCTAssertEqual(inventories(), before)
        clock.advance(10)
        a.session.tick()
        XCTAssertEqual(inventories(), before + 1)
    }

    // MARK: - Presence

    func testCharacterChangeIsSentImmediately() {
        let a = node("A"), b = node("B")
        connect(a, b)
        XCTAssertEqual(b.session.members[a.memberID]?.character, Node.pikachu)   // from hello, via the profile fallback
        a.session.updateCharacter(Node.eevee)
        XCTAssertEqual(b.session.members[a.memberID]?.character, Node.eevee)
    }

    func testSameCharacterIsNotResent() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.updateCharacter(Node.eevee)
        let before = a.presencesSent
        a.session.updateCharacter(Node.eevee)
        XCTAssertEqual(a.presencesSent, before)
    }

    func testHelloCarriesLastGivenCharacter() {
        let a = node("A"), b = node("B")
        a.session.updateCharacter(Node.eevee)
        connect(a, b)
        XCTAssertEqual(b.session.members[a.memberID]?.character, Node.eevee)
    }

    func testPositionChangeReachesOthers() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .left, isWalking: true)
        let m = b.session.members[a.memberID]
        XCTAssertEqual(m?.inPlaza, true)
        XCTAssertEqual(m?.tile, TilePoint(x: 3, y: 4))
        XCTAssertEqual(m?.facing, .left)
        XCTAssertEqual(m?.isWalking, true)
        XCTAssertEqual(m?.nickname, "A")
        let before = a.presencesSent
        a.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .left, isWalking: true)
        XCTAssertEqual(a.presencesSent, before)
    }

    func testLeavingPlazaMarksAway() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .up, isWalking: false)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        let m = b.session.members[a.memberID]
        XCTAssertEqual(m?.inPlaza, false)
        XCTAssertNil(m?.tile)
        XCTAssertNil(m?.facing)
    }

    func testDisconnectRemovesMember() {
        let a = node("A"), b = node("B")
        let ab = connect(a, b)
        XCTAssertTrue(a.session.hasOnlinePeers)
        hub.disconnect(ab)
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertFalse(a.session.hasOnlinePeers)
        XCTAssertTrue(b.session.members.isEmpty)
        a.transport.onPeerDisconnected?(ab.peerID(on: a.transport))   // a second report is harmless
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testDisconnectKeepsMemberWhileAnotherConnectionRemains() {
        let a = node("A"), b = node("B")
        let old = connect(a, b)
        hub.sever(old, silentlyOn: a.transport)
        // B holds a dead link and a fresh one; losing the dead one must not drop the member.
        let fresh = connect(a, b)
        b.transport.onPeerDisconnected?(old.peerID(on: b.transport))
        XCTAssertEqual(b.session.members.count, 1)
        XCTAssertTrue(b.transport.hasLink(fresh))
    }

    func testNicknameFromPeerIsValidated() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        let id = UUID().uuidString
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: id, nickname: "Raw")
        func presence(_ nickname: String) -> TeamMessage {
            .presence(TeamPresence(nickname: nickname, character: Node.eevee, inPlaza: true,
                                   tile: TilePoint(x: 1, y: 1), facing: .down, isWalking: false))
        }
        raw.say(presence(String(repeating: "x", count: 13)))
        XCTAssertEqual(a.session.members[id]?.nickname, "Raw")
        XCTAssertEqual(a.session.members[id]?.inPlaza, true)
        raw.say(presence("  New  "))
        XCTAssertEqual(a.session.members[id]?.nickname, "New")
    }

    func testInvalidHelloNicknameIsEmptyWhenThereIsNoPrevious() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        let id = UUID().uuidString
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: id, nickname: String(repeating: "x", count: 13))
        XCTAssertEqual(a.session.members[id]?.nickname, "")
    }

    // MARK: - Emotes

    func testEmoteIsNeitherStoredNorForwarded() {
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b); connect(b, c)
        let feedBefore = b.feed.events
        a.session.sendEmote(.heart, target: b.memberID)
        XCTAssertEqual(b.emotes.count, 1)
        XCTAssertEqual(b.emotes.first?.memberID, a.memberID)
        XCTAssertEqual(b.emotes.first?.emote, TeamEmote(kind: .heart, targetMemberID: b.memberID))
        XCTAssertEqual(c.emotes.count, 0)
        XCTAssertEqual(b.feed.events, feedBefore)
        XCTAssertEqual(b.transport.sentMessages { if case .emote = $0 { true } else { false } }, 0)
    }

    // MARK: - Profiles

    func testProfileRoundTrip() async {
        let a = node("A"), b = node("B")
        connect(a, b)
        let profile = await b.session.requestProfile(memberID: a.memberID)
        XCTAssertEqual(profile, a.expectedProfile)
    }

    func testProfileForUnknownMemberIsNil() async {
        let b = node("B")
        let profile = await b.session.requestProfile(memberID: "nobody")
        XCTAssertNil(profile)
    }

    private func profileRequestsReceived(by raw: RawPeer) -> Int {
        raw.received.filter { if case .profileRequest = $0 { true } else { false } }.count
    }

    func testProfileTimesOut() async {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        let id = UUID().uuidString
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: id)
        let start = ContinuousClock.now
        let profile = await a.session.requestProfile(memberID: id, timeout: .milliseconds(50))
        let elapsed = ContinuousClock.now - start
        XCTAssertNil(profile)
        XCTAssertEqual(profileRequestsReceived(by: raw), 1)   // it was really asked, then the timer ended it
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(45))
    }

    func testProfileRequestEndsWhenMemberLeaves() async {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        let id = UUID().uuidString
        let connection = hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: id)
        let finished = expectation(description: "request ended")
        var ended = false
        var profile: TeamMemberProfile?
        Task {
            profile = await a.session.requestProfile(memberID: id, timeout: .seconds(30))
            ended = true
            finished.fulfill()
        }
        for _ in 0..<20 where profileRequestsReceived(by: raw) == 0 { await Task.yield() }
        XCTAssertEqual(profileRequestsReceived(by: raw), 1)   // the request is pending before the member leaves
        XCTAssertFalse(ended)
        hub.disconnect(connection)
        await fulfillment(of: [finished], timeout: 2)          // far shorter than the 30 s timeout
        XCTAssertTrue(ended)
        XCTAssertNil(profile)
    }

    // MARK: - Settings

    func testDisabledSessionPublishesNothing() {
        let a = node("A", enabled: false)
        a.session.publish(hatch())
        a.session.react(to: "x", kind: .cute)
        XCTAssertTrue(a.feed.events.isEmpty)
        XCTAssertEqual(a.bigEvents.count, 0)
        XCTAssertTrue(a.transport.startedCodes.isEmpty)
        XCTAssertFalse(a.transport.isRunning)
    }

    func testChangingTeamCodeClearsFeed() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.publish(hatch())
        XCTAssertEqual(a.feed.events.count, 1)
        let other = newCode()
        a.settings.code = other
        a.session.applySettings()
        XCTAssertTrue(a.feed.events.isEmpty)
        XCTAssertEqual(a.transport.startedCodes, [code, other])
        XCTAssertTrue(a.transport.isRunning)
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testLeavingTeamClearsFeed() {
        let a = node("A")
        a.session.publish(hatch())
        a.settings.leaveTeam()
        a.session.applySettings()
        XCTAssertTrue(a.feed.events.isEmpty)
        XCTAssertFalse(a.transport.isRunning)
    }

    func testTurningOffKeepsFeed() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.publish(hatch())
        a.settings.isEnabled = false
        a.session.applySettings()
        XCTAssertEqual(a.feed.events.count, 1)
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertFalse(a.transport.isRunning)
        a.settings.isEnabled = true
        a.session.applySettings()
        XCTAssertEqual(a.feed.events.count, 1)
        XCTAssertTrue(a.transport.isRunning)
    }

    func testLaunchDoesNotClearFeed() {
        let defaults = makeDefaults()
        let url = makeFeedURL()
        let first = Node("A", hub: hub, clock: clock, code: code, defaults: defaults, feedURL: url)
        first.session.publish(hatch())
        XCTAssertEqual(first.feed.events.count, 1)
        let relaunched = Node("A", hub: hub, clock: clock, code: nil, defaults: defaults, feedURL: url)
        XCTAssertEqual(relaunched.settings.code, code)
        XCTAssertEqual(relaunched.feed.events.count, 1)
        XCTAssertTrue(relaunched.transport.isRunning)
    }

    func testNicknameChangeSendsPresence() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.settings.nickname = "Renamed"
        a.session.applySettings()
        XCTAssertEqual(b.session.members[a.memberID]?.nickname, "Renamed")
        XCTAssertEqual(a.transport.startedCodes.count, 1)
        let before = a.presencesSent
        a.session.applySettings()
        XCTAssertEqual(a.presencesSent, before)
    }
}
