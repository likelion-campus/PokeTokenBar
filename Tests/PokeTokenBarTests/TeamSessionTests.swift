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
    var chats: [(memberID: String, text: String)] = []
    var loudChats: [String] = []

    static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    static let eevee = TeamMonSummary(speciesID: 133, isShiny: true, form: nil, speciesName: "Eevee", gender: nil)

    init(_ name: String, hub: FakeTransportHub, clock: TestClock, code: TeamCode?, defaults: UserDefaults, feedURL: URL, enabled: Bool = true, stage: Int = 1) {
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
                              evolutionStage: { stage },
                              clock: { clock.now })
        session.onBigEvent = { [unowned self] in bigEvents.append($0) }
        session.onReactionToMine = { [unowned self] in reactionsToMine.append(($0, $1)) }
        session.onEmote = { [unowned self] in emotes.append(($0, $1)) }
        session.onChat = { [unowned self] in
            chats.append(($0, $1))
            if $2 { loudChats.append($1) }
        }
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
        hub = FakeTransportHub()
        clock = TestClock()
        code = newCode()
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        dirs = []; suites = []
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

    private func node(_ name: String, code: TeamCode? = nil, enabled: Bool = true, stage: Int = 1) -> Node {
        Node(name, hub: hub, clock: clock, code: code ?? self.code, defaults: makeDefaults(), feedURL: makeFeedURL(), enabled: enabled, stage: stage)
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

    /// `publish` sends one event per live frame, so a live frame with more is not a moment that just happened.
    func testLiveFrameWithSeveralEventsStoresThemButShowsNoneAsBig() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: "z")
        func big(_ id: String) -> TeamEvent {
            TeamEvent(id: id, authorID: "z", authorNickname: "Z", kind: .hatch, speciesID: 1, fromSpeciesID: nil,
                      speciesName: "Bulbasaur", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil,
                      rarity: .common, day: "2026-10-29", occurredAt: clock.now)
        }
        raw.say(.events([big("b1"), big("b2"), big("b3")], live: true))
        XCTAssertEqual(a.feed.events.count, 3)
        XCTAssertEqual(a.bigEvents.count, 0)
        raw.say(.events([big("b4")], live: true))
        XCTAssertEqual(a.bigEvents.map(\.id), ["b4"])
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

    /// R26: a reaction carries the day it was made, never the time, on the wire and in every teammate's file.
    func testReactionCarriesOnlyTheDayOnWireAndOnDisk() throws {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.publish(hatch())
        clock.advance(5 * 3600 + 17.25)
        b.session.react(to: a.feed.events[0].id, kind: .cute)
        let dayStart = Calendar.current.startOfDay(for: clock.now)
        let sent = b.transport.sent.compactMap { sent -> TeamReaction? in
            if case .reactions(let r, _) = sent.message { return r.first }
            return nil
        }
        XCTAssertEqual(sent.map(\.createdAt), [dayStart])
        let body = try TeamWire.encode(.reactions(sent, live: true)).dropFirst(4)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let list = try XCTUnwrap((json["reactions"] as? [String: Any])?["_0"] as? [[String: Any]])
        XCTAssertEqual(list.first?["createdAt"] as? Double, dayStart.timeIntervalSinceReferenceDate)
        XCTAssertEqual(a.feed.reactions(for: a.feed.events[0].id).map(\.createdAt), [dayStart])
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
        XCTAssertEqual(a.transport.refuseCalls.count, 1)
        XCTAssertEqual(a.transport.linkCount, 0)
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testOwnMemberIDIsDisconnected() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: a.memberID)
        XCTAssertEqual(a.transport.refuseCalls.count, 1)
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertFalse(a.session.hasIncompatiblePeer)
    }

    /// Another version costs one hello per attempt and never a resync.
    func testAnotherVersionGetsNothingButAHelloEveryTime() {
        let a = node("A")
        let id = UUID().uuidString
        for attempt in 1...3 {
            let raw = RawPeer(hub: hub)
            hub.connect(raw.transport, to: a.transport)
            raw.hello(memberID: id, version: TeamWire.protocolVersion + 1)
            XCTAssertEqual(a.transport.refuseCalls.count, attempt)
            XCTAssertTrue(a.session.members.isEmpty)
            XCTAssertFalse(raw.received.contains { if case .hello = $0 { false } else { true } },
                           "only the hello: no inventory, no presence for another version")
        }
    }

    /// Someone who updates gets straight in, whenever they were last refused.
    func testAnUpdatedMemberIsServedAtOnce() {
        let a = node("A")
        let id = UUID().uuidString
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: id, version: TeamWire.protocolVersion + 1)
        let updated = RawPeer(hub: hub)
        hub.connect(updated.transport, to: a.transport)
        updated.hello(memberID: id)
        XCTAssertEqual(a.transport.refuseCalls.count, 1)
        XCTAssertEqual(a.session.members.count, 1)
    }

    func testUndecodableFrameIsTreatedLikeARefusal() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        let id = UUID().uuidString
        raw.hello(memberID: id)
        XCTAssertEqual(a.session.members.count, 1)
        let peer = try! XCTUnwrap(raw.peerID)
        _ = peer
        let aPeer = a.transport.peerIDs.first!
        a.transport.onPeerBadFrame?(aPeer)
        XCTAssertTrue(a.session.hasIncompatiblePeer)
        XCTAssertEqual(a.transport.refuseCalls, [aPeer])
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testIncompatibleNoticeExpiresTenMinutesAfterTheLastMismatch() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(version: TeamWire.protocolVersion + 1)
        XCTAssertTrue(a.session.hasIncompatiblePeer)
        clock.advance(599)
        a.session.tick()
        XCTAssertTrue(a.session.hasIncompatiblePeer)
        clock.advance(2)
        a.session.tick()
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

    // MARK: - Pruning

    /// Stale rows leave while the app keeps running, not only at launch and on the next event.
    func testTickPrunesAboutHourly() {
        let a = node("A")
        let cal = Calendar.current
        let day = cal.startOfDay(for: clock.now)
        func at(_ days: Int, hours: Double) -> Date { cal.date(byAdding: .day, value: days, to: day)!.addingTimeInterval(hours * 3600) }
        // An orphan reaction (its news never arrived) leaves only through `prune()`.
        a.feed.insert(TeamReaction(id: "orphan", eventID: "nowhere", authorID: "z", authorNickname: "Zed", kind: .cute,
                                   text: nil, createdAt: clock.now))
        clock.now = at(7, hours: 23.5)
        a.session.tick()                       // first tick since the start: prunes, nothing stale yet
        XCTAssertTrue(a.feed.reactionIDs.contains("orphan"))
        clock.now = at(8, hours: 0.2)          // the orphan is stale now, the last prune is 40 minutes old
        a.session.tick()
        XCTAssertTrue(a.feed.reactionIDs.contains("orphan"), "no second prune inside the hour")
        clock.now = at(8, hours: 0.7)
        a.session.tick()
        XCTAssertFalse(a.feed.reactionIDs.contains("orphan"))
    }

    func testTurningTheTeamOnPrunes() {
        let a = node("A")
        let cal = Calendar.current
        a.feed.insert(TeamReaction(id: "orphan", eventID: "nowhere", authorID: "z", authorNickname: "Zed", kind: .cute,
                                   text: nil, createdAt: clock.now))
        a.settings.isEnabled = false
        a.session.applySettings()
        clock.now = cal.date(byAdding: .day, value: 9, to: clock.now)!
        XCTAssertTrue(a.feed.reactionIDs.contains("orphan"))
        a.settings.isEnabled = true
        a.session.applySettings()
        XCTAssertFalse(a.feed.reactionIDs.contains("orphan"))
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

    func testScheduleChangeReachesTheOtherNode() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        a.session.applySettings()
        XCTAssertNotNil(a.settings.schedule)
        XCTAssertEqual(b.settings.schedule, a.settings.schedule)
    }

    func testOlderScheduleIsNotAdoptedAndDoesNotRevert() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        a.session.applySettings()
        let older = PlazaSchedule(coreStart: 1, coreEnd: 2, seasonPeriod: "day", changedAt: clock.now.addingTimeInterval(-60),
                                  changedBy: "zzz", changedByName: "Z")
        XCTAssertFalse(b.settings.adoptSchedule(older, now: clock.now))
        b.session.applySettings()
        XCTAssertEqual(a.settings.schedule?.coreStart, 8)
        XCTAssertEqual(b.settings.schedule?.coreStart, 8)
    }

    func testTwoChangesASecondApartConvergeOnTheLater() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        a.session.applySettings()
        clock.advance(1)
        b.settings.changeSchedule(coreStart: 11, coreEnd: 15, period: .month, now: clock.now)
        b.session.applySettings()
        XCTAssertEqual(a.settings.schedule, b.settings.schedule)
        XCTAssertEqual(a.settings.schedule?.coreStart, 11)
        // The same, made while apart: the later one wins on both once they meet.
        let c = node("C"), d = node("D")
        c.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        clock.advance(1)
        d.settings.changeSchedule(coreStart: 12, coreEnd: 14, period: .day, now: clock.now)
        connect(c, d)
        XCTAssertEqual(c.settings.schedule?.coreStart, 12)
        XCTAssertEqual(d.settings.schedule?.coreStart, 12)
    }

    func testScheduleRelaysThroughAMiddleNodeAndReachesALateJoiner() {
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b)
        connect(b, c)            // c has no link to a
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        a.session.applySettings()
        XCTAssertEqual(c.settings.schedule, a.settings.schedule)
        let late = node("L")
        connect(b, late)         // offline during the change
        XCTAssertEqual(late.settings.schedule, a.settings.schedule)
    }

    /// The far-future guard runs against the session's clock, not the wall clock.
    func testScheduleStampedMoreThanTenMinutesAheadIsNotAdopted() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello()
        func send(_ ahead: TimeInterval, start: Int) {
            let s = PlazaSchedule(coreStart: start, coreEnd: 20, seasonPeriod: "week",
                                  changedAt: clock.now.addingTimeInterval(ahead), changedBy: "x", changedByName: "X")
            raw.say(.presence(TeamPresence(nickname: "Raw", character: Node.eevee, inPlaza: true,
                                           tile: TilePoint(x: 1, y: 1), facing: .down, isWalking: false, schedule: s)))
        }
        send(601, start: 5)
        XCTAssertNil(a.settings.schedule)
        send(599, start: 6)
        XCTAssertEqual(a.settings.schedule?.coreStart, 6)
    }

    /// A peer's 900 KB name must not be adopted, or it would ride in every presence and push the frame past the limit.
    func testScheduleWithAHugeNameIsNeitherAdoptedNorRelayed() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello()
        let s = PlazaSchedule(coreStart: 5, coreEnd: 20, seasonPeriod: "week", changedAt: clock.now,
                              changedBy: "x", changedByName: String(repeating: "가", count: 300_000))
        raw.say(.presence(TeamPresence(nickname: "Raw", character: Node.eevee, inPlaza: true,
                                       tile: TilePoint(x: 1, y: 1), facing: .down, isWalking: false, schedule: s)))
        XCTAssertTrue(a.session.members.values.contains { $0.nickname == "Raw" }, "the presence itself still arrives")
        XCTAssertNil(a.settings.schedule)
        XCTAssertNil(b.settings.schedule)
    }

    /// settings.code moves before applySettings runs; the old team's links must not feed the new team's key.
    func testScheduleIsNotStoredUnderACodeThatTheLinksDoNotBelongTo() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let oldCode = a.settings.code
        let otherCode = newCode()
        a.settings.code = otherCode
        b.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        b.session.applySettings()
        XCTAssertNil(a.settings.schedule)
        a.settings.code = oldCode
        XCTAssertNil(a.settings.schedule)
    }

    /// The other direction: in the same window, my presence to the old team's links must not carry the new team's schedule.
    func testScheduleIsNotSentOnLinksOfAnotherTeam() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.settings.code = newCode()
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)   // stored under the new code
        XCTAssertNotNil(a.settings.schedule)
        a.session.updateTakenItemSlot(1)   // a presence broadcast on the old team's links
        XCTAssertEqual(b.session.members[a.memberID]?.takenItemSlot, 1, "the presence did arrive")
        XCTAssertNil(b.settings.schedule, "but without the other team's schedule")
    }

    func testPresenceWithoutScheduleLeavesMineUnchanged() {
        let a = node("A")
        a.settings.changeSchedule(coreStart: 8, coreEnd: 20, period: .week, now: clock.now)
        let before = a.settings.schedule
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello()
        raw.say(.presence(TeamPresence(nickname: "Raw", character: Node.eevee, inPlaza: true,
                                       tile: TilePoint(x: 1, y: 1), facing: .down, isWalking: false)))
        XCTAssertEqual(a.settings.schedule, before)
    }

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

    /// Idle is mine, not the plaza's: closing the plaza keeps it, and it is resent only when it changes.
    func testIdleIsSentWithThePlazaOpenOrClosed() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .up, isWalking: false)
        a.session.updateIdle(true)
        XCTAssertEqual(b.session.members[a.memberID]?.isIdle, true)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        XCTAssertEqual(b.session.members[a.memberID]?.isIdle, true, "closing the plaza does not clear idle")
        XCTAssertEqual(b.session.members[a.memberID]?.inPlaza, false)
        let before = a.presencesSent
        a.session.updateIdle(true)
        XCTAssertEqual(a.presencesSent, before, "no change, nothing sent")
        a.session.updateIdle(false)
        XCTAssertEqual(b.session.members[a.memberID]?.isIdle, false)
    }

    /// A received focus end time counts only inside (now, now + 8 h + 600 s] on this Mac's clock.
    func testReceivedFocusIsKeptOnlyInsideTheWindow() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let t0 = clock.now
        a.session.updateFocus(endsAt: t0.addingTimeInterval(1500))
        XCTAssertEqual(b.session.members[a.memberID]?.focusEndsAt, t0.addingTimeInterval(1500))
        a.session.updateFocus(endsAt: t0.addingTimeInterval(9 * 3600))
        XCTAssertNil(b.session.members[a.memberID]?.focusEndsAt)
        a.session.updateFocus(endsAt: t0.addingTimeInterval(-60))
        XCTAssertNil(b.session.members[a.memberID]?.focusEndsAt)
    }

    private func dittoState(since: Date) -> PlazaDittoState {
        PlazaDittoState(tile: TilePoint(x: 3, y: 4), facing: .down, isWalking: nil, isRunning: nil,
                        decoyOf: nil, since: since, restUntil: nil)
    }

    func testPresenceCarriesMyDittoAndReadiness() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let s = dittoState(since: clock.now)
        a.session.updateDitto(ready: true, state: s)
        XCTAssertEqual(b.session.members[a.memberID]?.ditto, s)
        XCTAssertEqual(b.session.members[a.memberID]?.dittoReady, true)
        a.session.updateDitto(ready: false, state: nil)
        XCTAssertNil(b.session.members[a.memberID]?.ditto)
        XCTAssertEqual(b.session.members[a.memberID]?.dittoReady, false)
    }

    func testUpdateDittoSendsOnlyOnChange() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let s = dittoState(since: clock.now)
        let before = a.presencesSent
        a.session.updateDitto(ready: false, state: nil)
        XCTAssertEqual(a.presencesSent, before)
        a.session.updateDitto(ready: true, state: s)
        a.session.updateDitto(ready: true, state: s)
        XCTAssertEqual(a.presencesSent, before + 1)
        var moved = s
        moved.tile = TilePoint(x: 5, y: 4)
        a.session.updateDitto(ready: true, state: moved)
        XCTAssertEqual(a.presencesSent, before + 2)
    }

    func testReceivedDittoIsKeptOnTheMember() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let s = dittoState(since: clock.now)
        a.session.updateDitto(ready: true, state: s)
        XCTAssertEqual(b.session.members[a.memberID]?.ditto, s)
    }

    func testAHelloClaimingTheDittoKeyIsRefused() {
        let a = node("A")
        let raw = RawPeer(hub: hub)
        hub.connect(raw.transport, to: a.transport)
        raw.hello(memberID: PlazaDitto.sceneKey)
        XCTAssertEqual(a.transport.refuseCalls.count, 1)
        XCTAssertTrue(a.session.members.isEmpty)
    }

    func testPresenceCarriesDivingAndStage() {
        let a = node("A", stage: 3), b = node("B")
        connect(a, b)
        XCTAssertEqual(b.session.members[a.memberID]?.evolutionStage, 3)
        XCTAssertEqual(b.session.members[a.memberID]?.isDiving, false)
        let sentDiving = a.transport.sentMessages { if case .presence(let p) = $0, p.isDiving != nil { true } else { false } }
        XCTAssertEqual(sentDiving, 0, "isDiving stays off the wire until true")
        let before = a.presencesSent
        a.session.updateDiving(true)
        a.session.updateDiving(true)
        XCTAssertEqual(a.presencesSent, before + 1)
        XCTAssertEqual(b.session.members[a.memberID]?.isDiving, true)
        XCTAssertEqual(b.session.members[a.memberID]?.evolutionStage, 3)
        a.session.updateDiving(false)
        XCTAssertEqual(b.session.members[a.memberID]?.isDiving, false)
    }

    func testReceivedStageIsClampedAndMissingIsOne() {
        let a = node("A", stage: 7), b = node("B")
        connect(a, b)
        XCTAssertEqual(b.session.members[a.memberID]?.evolutionStage, 3)
        let c = node("C"), d = node("D")
        connect(c, d)
        XCTAssertEqual(d.session.members[c.memberID]?.evolutionStage, 1)
    }

    func testUpdateFocusSendsPresenceOnlyOnChange() {
        let a = node("A"), b = node("B")
        connect(a, b)
        let before = a.presencesSent
        let end = clock.now.addingTimeInterval(1500)
        a.session.updateFocus(endsAt: end)
        a.session.updateFocus(endsAt: end)
        XCTAssertEqual(a.presencesSent, before + 1)
    }

    /// A teammate whose connection is gone is kept as asleep (their last state) until they connect again.
    func testDisconnectedMemberIsKeptAsAsleepUntilBack() {
        let a = node("A"), b = node("B")
        let ab = connect(a, b)
        b.session.updatePlazaPosition(inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .up, isWalking: false)
        hub.disconnect(ab)
        XCTAssertTrue(a.session.members.isEmpty)
        XCTAssertEqual(a.session.asleepMembers[b.memberID]?.nickname, "B")
        XCTAssertFalse(a.session.hasOnlinePeers, "asleep teammates do not hold App Nap off")
        connect(a, b)
        XCTAssertNotNil(a.session.members[b.memberID])
        XCTAssertNil(a.session.asleepMembers[b.memberID])
    }

    /// The asleep list belongs to one team: a code change or turning the team off forgets it.
    func testAsleepListIsForgottenWithTheTeam() {
        let a = node("A"), b = node("B")
        hub.disconnect(connect(a, b))
        XCTAssertFalse(a.session.asleepMembers.isEmpty, "test precondition")
        a.settings.code = newCode()
        a.session.applySettings()
        XCTAssertTrue(a.session.asleepMembers.isEmpty)
        let c = node("C"), d = node("D")
        hub.disconnect(connect(c, d))
        c.settings.isEnabled = false
        c.session.applySettings()
        XCTAssertTrue(c.session.asleepMembers.isEmpty)
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

    // MARK: - Chat

    func testChatIsNeitherStoredNorForwarded() {
        let a = node("A"), b = node("B"), c = node("C")
        connect(a, b); connect(b, c)
        let feedBefore = b.feed.events
        a.session.sendChat("안녕")
        XCTAssertEqual(b.chats.map(\.text), ["안녕"])
        XCTAssertEqual(b.chats.first?.memberID, a.memberID)
        XCTAssertTrue(c.chats.isEmpty)
        XCTAssertEqual(b.feed.events, feedBefore)
        XCTAssertEqual(b.transport.sentMessages { if case .chat = $0 { true } else { false } }, 0)
    }

    func testMegaphoneFlagReachesTheTeammate() {
        let a = node("A"), b = node("B")
        connect(a, b)
        a.session.sendChat("점심!", loud: true)
        a.session.sendChat("그냥 말")
        XCTAssertEqual(b.chats.map(\.text), ["점심!", "그냥 말"])
        XCTAssertEqual(b.loudChats, ["점심!"])
    }

    func testLineOutOfFormIsDroppedAndTheLinkStays() {
        let a = node("A"), b = node("B")
        connect(a, b)
        for bad in ["둘\n줄", "  공백", "", String(repeating: "가", count: TeamChat.maxCharacters + 1)] {
            a.session.sendChat(bad)
        }
        XCTAssertTrue(b.chats.isEmpty)
        a.session.sendChat("정상")
        XCTAssertEqual(b.chats.map(\.text), ["정상"])
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

    /// A picked name colour goes out at once, and a teammate who connects later gets it with the first presence.
    func testNameColorChangeSendsPresence() {
        let a = node("A"), b = node("B")
        connect(a, b)
        XCTAssertNil(b.session.members[a.memberID]?.nameColor)
        a.settings.nameColor = 0xFF9ECF
        a.session.applySettings()
        XCTAssertEqual(b.session.members[a.memberID]?.nameColor, 0xFF9ECF)
        let before = a.presencesSent
        a.session.applySettings()
        XCTAssertEqual(a.presencesSent, before)
        let c = node("C")
        connect(a, c)
        XCTAssertEqual(c.session.members[a.memberID]?.nameColor, 0xFF9ECF)
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
