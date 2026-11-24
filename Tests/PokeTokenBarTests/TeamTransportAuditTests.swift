import XCTest
@testable import PokeTokenBar

/// The 2026-11-24 transport audit: what one link, one address or one name may cost. Each limit has a flooding peer that
/// must hit it and an honest peer at the most it ever sends that must not.
final class TeamTransportAuditRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: per-address caps

    func testAddressCapsRefuseTheNinthUnfinishedAndThirtyThirdLinkFromOneAddress() {
        func admits(links: Int, unfinished: Int) -> Bool {
            TeamTransportRules.admitsInbound(linkCount: links, unfinishedInbound: unfinished, linkLimit: 128,
                                             linksFromAddress: links, unfinishedFromAddress: unfinished)
        }
        XCTAssertTrue(admits(links: 7, unfinished: 7), "eight teammates waking up behind one NAT")
        XCTAssertFalse(admits(links: 8, unfinished: 8))
        XCTAssertTrue(admits(links: 31, unfinished: 0), "sixteen teammates, two links each while a duplicate closes")
        XCTAssertFalse(admits(links: 32, unfinished: 0))
        // The rest of the host is never touched by an address that is at its cap.
        XCTAssertTrue(TeamTransportRules.admitsInbound(linkCount: 40, unfinishedInbound: 8, linkLimit: 128,
                                                       linksFromAddress: 0, unfinishedFromAddress: 0))
    }

    func testAnAddressKeyIsTheHostAlone() {
        XCTAssertEqual(TeamTransportRules.addressKey("192.168.0.7"), "192.168.0.7")
        XCTAssertEqual(TeamTransportRules.addressKey("FE80::1%en0"), "fe80::1")
        XCTAssertEqual(TeamTransportRules.addressKey("[fe80::1%en0]:5000"), "fe80::1")
    }

    // MARK: a reconnect after a flood

    func testAnAddressCutOffForFloodingDoesNotGetAFreshBurstBack() {
        var floods = TeamFloodMemory()
        XCTAssertNil(floods.startingTokens(for: "10.0.0.9", now: t0), "an address never cut off starts with the full burst")
        floods.noteFlood(from: "10.0.0.9", now: t0)
        XCTAssertEqual(floods.startingTokens(for: "10.0.0.9", now: t0), 0)
        let later = floods.startingTokens(for: "10.0.0.9", now: t0.addingTimeInterval(4))
        XCTAssertEqual(later ?? -1, 4 * TeamTransportRules.receivePerSecond, accuracy: 0.001)
        XCTAssertNil(floods.startingTokens(for: "10.0.0.9", now: t0.addingTimeInterval(TeamTransportRules.floodPenaltyWindow)),
                     "after the window the address is forgiven")
        XCTAssertNil(floods.startingTokens(for: "10.0.0.8", now: t0), "another address is untouched")
    }

    func testAReconnectAfterAFloodFloodsAgainOnTheFirstBigRead() throws {
        var floods = TeamFloodMemory()
        floods.noteFlood(from: "10.0.0.9", now: t0)
        var fresh = TeamLinkReceiver()
        var reconnect = TeamLinkReceiver(startingTokens: floods.startingTokens(for: "10.0.0.9", now: t0))
        let frame = try TeamWire.encode(.profileRequest)
        let run = Data((0..<2_000).flatMap { _ in frame })
        if case .flood = fresh.receive(run, now: t0) { XCTFail("a fresh link takes a run of 2000 requests") }
        guard case .flood = reconnect.receive(run, now: t0) else { return XCTFail("the reconnect had a full burst") }
    }

    func testTheFloodMemoryIsBounded() {
        var floods = TeamFloodMemory()
        for i in 0..<(TeamTransportRules.maxRememberedFloods * 3) {
            floods.noteFlood(from: "10.0.\(i / 200).\(i % 200)", now: t0.addingTimeInterval(Double(i) / 100))
        }
        var remembered = 0
        for i in 0..<(TeamTransportRules.maxRememberedFloods * 3)
        where floods.startingTokens(for: "10.0.\(i / 200).\(i % 200)", now: t0.addingTimeInterval(2)) != nil { remembered += 1 }
        XCTAssertLessThanOrEqual(remembered, TeamTransportRules.maxRememberedFloods)
        XCTAssertGreaterThan(remembered, 0)
    }

    // MARK: the receive budget

    /// A frame of a kind this version does not know is skipped, but it still cost a parse.
    private func unknownKindRun(_ count: Int) -> Data {
        let body = Data(#"{"zzzFutureKind":{"a":1}}"#.utf8)
        var one = Data([0, 0, 0, UInt8(body.count)])
        one.append(body)
        return Data((0..<count).flatMap { _ in one })
    }

    func testAFloodOfSkippedFramesIsCharged() {
        var r = TeamLinkReceiver()
        // 10 000 frames are about 340 KB of bytes: under the 4 MB burst by size alone, over it with the frame cost.
        let run = unknownKindRun(10_000)
        XCTAssertLessThan(run.count, Int(TeamTransportRules.receiveBurst))
        guard case .flood = r.receive(run, now: t0) else { return XCTFail("skipped frames were free") }
    }

    func testAnHonestRunOfSkippedFramesIsNotAFlood() {
        var r = TeamLinkReceiver()
        guard case .messages(let m) = r.receive(unknownKindRun(1_000), now: t0) else { return XCTFail("an honest burst was cut") }
        XCTAssertTrue(m.isEmpty)
    }

    func testTheDecoderCountsEveryFrameItTook() throws {
        var d = TeamWire.FrameDecoder()
        let one = try TeamWire.encode(.profileRequest)
        let run = unknownKindRun(3) + one + one
        XCTAssertEqual(try d.append(run).count, 2)
        XCTAssertEqual(d.lastFrameCount, 5)
        XCTAssertEqual(try d.append(Data()).count, 0)
        XCTAssertEqual(d.lastFrameCount, 0)
    }

    func testTheDecoderKeepsAFrameSplitAnywhereAcrossManyFrames() throws {
        let one = try TeamWire.encode(.profileRequest)
        let all = Data((0..<500).flatMap { _ in one })
        for cut in [1, 3, 4, 5, one.count - 1, one.count, one.count + 2, all.count - 1] {
            var d = TeamWire.FrameDecoder()
            let first = try d.append(all.prefix(cut))
            let second = try d.append(all.dropFirst(cut))
            XCTAssertEqual(first.count + second.count, 500, "cut at \(cut)")
        }
    }

    func testTheDecoderStillRejectsAnOversizedLength() {
        var d = TeamWire.FrameDecoder()
        XCTAssertThrowsError(try d.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }

    // MARK: queued bytes

    func testTheQueueLimitIsTheOneWindowsAlreadyHad() {
        XCTAssertEqual(TeamTransportRules.maxQueuedBytes, 8 * 1_048_576)
    }

    // MARK: discovered names

    func testTheDialPlannerKeepsOnlyTheNewestNamesNothingUses() {
        var p = TeamDialPlanner()
        let cap = TeamTransportRules.maxDiscoveredNames
        var evicted: [String] = []
        for i in 0..<(cap + 5) { if let gone = p.discovered("n\(i)") { evicted.append(gone) } }
        XCTAssertEqual(evicted, (0..<5).map { "n\($0)" }, "the oldest go first")
        XCTAssertEqual(p.dueDials(now: t0).count, cap)
        XCTAssertFalse(p.dueDials(now: t0).contains("n0"))
        XCTAssertTrue(p.dueDials(now: t0).contains("n\(cap + 4)"))
    }

    func testTheDialPlannerNeverDropsAHonestNameForAFlood() {
        var p = TeamDialPlanner()
        let cap = TeamTransportRules.maxDiscoveredNames
        for i in 0..<(cap - 1) { p.discovered("n\(i)") }
        p.discovered("honest"); p.dialStarted("honest", peer: "p1")
        for i in 0..<(cap * 2) { p.discovered("flood\(i)") }
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)
        XCTAssertTrue(p.dueDials(now: t0).contains("honest"), "a name with a running dial is not evictable")
        XCTAssertLessThanOrEqual(p.dueDials(now: t0).count, cap)
    }

    func testNamesNeverConnectedGoBeforeAQuietTeammate() {
        var p = TeamDialPlanner()
        let cap = TeamTransportRules.maxDiscoveredNames
        p.discovered("teammate"); p.dialStarted("teammate", peer: "p1")
        p.connectionEnded(peer: "p1", handshakeFailed: false, now: t0)   // met, then went quiet: the oldest name in the table
        for i in 0..<(cap - 1) { p.discovered("rogue\(i)") }
        for i in 0..<50 { p.discovered("more\(i)") }
        XCTAssertTrue(p.dueDials(now: t0).contains("teammate"), "a name that connected before outlasts names that never did")
        XCTAssertFalse(p.dueDials(now: t0).contains("rogue0"))
    }

    func testAMetNameThatKeepsAnsweringIsEvictedLast() {
        var p = TeamDialPlanner()
        let cap = TeamTransportRules.maxDiscoveredNames
        for i in 0..<cap { p.discovered("a\(i)") }
        p.discovered("a0")   // answers again: not the longest quiet any more
        XCTAssertEqual(p.discovered("new"), "a1")
    }

    func testWhenEveryNameIsInUseANewOneIsNotKept() {
        var p = TeamDialPlanner()
        let cap = TeamTransportRules.maxDiscoveredNames
        for i in 0..<cap { p.discovered("n\(i)"); p.dialStarted("n\(i)", peer: "p\(i)") }
        XCTAssertEqual(p.discovered("late"), "late")
        XCTAssertFalse(p.dueDials(now: t0).contains("late"))
    }

    func testEvictionVictimsAreTheOldestAnswers() {
        let names = Set((0..<10).map { "n\($0)" })
        var answered: [String: Date] = [:]
        for i in 2..<10 { answered["n\(i)"] = t0.addingTimeInterval(Double(i)) }   // n0 and n1 never answered
        XCTAssertEqual(Set(TeamTransportRules.evictionVictims(names, answeredAt: answered, limit: 8)), ["n0", "n1"])
        XCTAssertEqual(TeamTransportRules.evictionVictims(names, answeredAt: answered, limit: 10), [])
    }

    // MARK: what a peer says about itself

    func testASpeciesBeyondTheKnownRangeIsDropped() {
        for id in [0, -1, 650, 100_000, Int.max] {
            XCTAssertNil(TeamMonSummary(speciesID: id, isShiny: false, form: nil, speciesName: "x", gender: nil).bounded.speciesID, "\(id)")
        }
        for id in [1, 25, 649] {
            XCTAssertEqual(TeamMonSummary(speciesID: id, isShiny: false, form: nil, speciesName: "x", gender: nil).bounded.speciesID, id)
        }
    }

    func testAnOutOfRangeSpeciesLosesItsNameAndFormToo() {
        let got = TeamMonSummary(speciesID: 9_999, isShiny: false, form: nil, speciesName: "Fakemon", gender: nil).bounded
        XCTAssertNil(got.speciesID)
        XCTAssertNil(got.speciesName, "no name label over an egg")
        XCTAssertNil(got.form)
    }

    func testADexBeyondARealOneIsCutOnReceipt() {
        let real = (1...649).map { TeamDexSpecies(speciesID: $0, form: nil, name: "n", rarity: .common, hasShiny: false, hasNormal: true) }
        let junk = (0..<5_000).map { TeamDexSpecies(speciesID: 650 + $0, form: nil, name: "n", rarity: .common, hasShiny: false, hasNormal: true) }
        let longName = String(repeating: "가", count: 100)
        var big = TeamMemberProfile(memberID: "m", nickname: "n", current: TeamMonSummary(speciesID: 25, isShiny: false, form: nil,
                                    speciesName: "P", gender: nil), dex: real + junk)
        big.dex[24].name = longName
        let got = big.bounded
        XCTAssertEqual(got.dex.count, 649, "species this version does not have are dropped")
        XCTAssertEqual(got.dex[24].name, "#25", "a name longer than a field reads as the number")
        XCTAssertEqual(got.dex[0].name, "n")
        let stuffed = TeamMemberProfile(memberID: "m", nickname: "n", current: big.current,
                                        dex: (0..<(TeamMemberProfile.maxDexEntries + 500)).map { _ in real[0] })
        XCTAssertEqual(stuffed.bounded.dex.count, TeamMemberProfile.maxDexEntries)
        XCTAssertGreaterThanOrEqual(TeamMemberProfile.maxDexEntries, 649)
    }
}

/// The feed's delayed save: a flood of frames is one write, an honest frame is still written.
@MainActor
final class TeamFeedSaveCoalescingTests: XCTestCase {
    private var dir: URL!
    private let now = Date()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamFeedSave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func store(delay: TimeInterval) -> TeamFeedStore {
        TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me", clock: { [now] in now }, saveDelay: delay)
    }

    private func event(_ id: String, author: String) -> TeamEvent {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return TeamEvent(id: id, authorID: author, authorNickname: author, kind: .hatch, speciesID: 25, fromSpeciesID: nil,
                         speciesName: "Pikachu", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common,
                         day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), occurredAt: now)
    }

    func testAThousandFramesFromTeammatesAreOneWrite() async {
        let feed = store(delay: 60)
        for i in 0..<1_000 { _ = feed.insert([event("e\(i)", author: "other")]) }
        XCTAssertEqual(feed.saveCount, 0, "nothing was written per frame")
        feed.flush()
        XCTAssertEqual(feed.saveCount, 1)
        feed.flush()
        XCTAssertEqual(feed.saveCount, 1, "nothing owed, nothing written")
        XCTAssertEqual(store(delay: 60).events.count, feed.events.count, "what was flushed is what a restart reads")
    }

    func testMyOwnNewsIsWrittenAtOnce() async {
        let feed = store(delay: 60)
        XCTAssertTrue(feed.insert(event("mine", author: "me")))
        XCTAssertEqual(feed.saveCount, 1)
        XCTAssertEqual(store(delay: 60).events.map(\.id), ["mine"])
    }

    func testAnHonestFrameIsOnDiskAfterTheDelay() async {
        let feed = store(delay: 0.05)
        _ = feed.insert([event("e1", author: "other")])
        XCTAssertEqual(feed.saveCount, 0)
        for _ in 0..<100 where feed.saveCount == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(feed.saveCount, 1)
        XCTAssertEqual(store(delay: 60).events.map(\.id), ["e1"])
    }

    func testTheSortOrderIsStillNewestFirstWithTiesByID() async {
        let feed = store(delay: 60)
        _ = feed.insert([event("b", author: "x"), event("a", author: "x"), event("c", author: "x")])
        XCTAssertEqual(feed.events.map(\.id), ["a", "b", "c"])
    }
}

/// Frames only a modified app sends, against the real session: what one link may cost, and an honest peer at its most.
@MainActor
final class TeamLinkLimitsTests: XCTestCase {
    private let hub = FakeTransportHub()
    private var clock = Date(timeIntervalSince1970: 1_793_242_800)   // 2026-10-29 12:00 KST
    private var dir: URL!
    private var settings: TeamSettings!
    private var feed: TeamFeedStore!
    private var transport: FakeTeamTransport!
    private var session: TeamSession!

    private static let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamLinkLimits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(TestDefaults.make(suite: "ptb.test.team.limits.\(UUID().uuidString)"))
        defaults.set("me", forKey: "team.memberID")
        settings = TeamSettings(defaults: defaults)
        var rng = SystemRandomNumberGenerator()
        settings.code = TeamCode.generate(using: &rng)
        settings.nickname = "나"
        settings.isEnabled = true
        feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me",
                             clock: { [unowned self] in clock }, saveDelay: 60)
        transport = hub.makeTransport()
        session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: {
            TeamMemberProfile(memberID: "me", nickname: "나", current: Self.mon, dex: [])
        }, clock: { [unowned self] in clock })
        session.applySettings()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private final class Peer {
        let transport: FakeTeamTransport
        var peerID: TeamPeerID?
        var received: [TeamMessage] = []
        var disconnected = false
        init(_ transport: FakeTeamTransport) { self.transport = transport }
        var presences: Int { received.filter { if case .presence = $0 { return true } else { return false } }.count }
    }

    private func connect() -> Peer {
        let peer = Peer(hub.makeTransport())
        var rng = SystemRandomNumberGenerator()
        peer.transport.start(code: TeamCode.generate(using: &rng))
        peer.transport.onPeerConnected = { [unowned peer] id, _ in peer.peerID = id }
        peer.transport.onPeerDisconnected = { [unowned peer] _ in peer.disconnected = true }
        peer.transport.onMessage = { [unowned peer] _, m in peer.received.append(m) }
        hub.connect(peer.transport, to: transport)
        return peer
    }

    private func join(_ memberID: String) -> Peer {
        let peer = connect()
        say(.hello(TeamHello(memberID: memberID, nickname: "x", protocolVersion: TeamWire.protocolVersion, current: Self.mon)), from: peer)
        return peer
    }

    private func say(_ m: TeamMessage, from peer: Peer) {
        guard let id = peer.peerID else { return }
        peer.transport.send(m, to: id)
    }

    private func event(_ id: String, author: String) -> TeamEvent {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: clock)
        return TeamEvent(id: id, authorID: author, authorNickname: author, kind: .hatch, speciesID: 25, fromSpeciesID: nil,
                         speciesName: "Pikachu", fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common,
                         day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), occurredAt: clock)
    }

    private func schedule(_ n: Int, by member: String) -> PlazaSchedule {
        PlazaSchedule(coreStart: 9, coreEnd: 18, seasonPeriod: "winter", changedAt: clock.addingTimeInterval(-1_000 + Double(n)),
                      changedBy: member, changedByName: "x")
    }

    private func presence(schedule: PlazaSchedule?) -> TeamPresence {
        var p = TeamPresence(nickname: "x", character: Self.mon, inPlaza: false, tile: nil, facing: nil, isWalking: false)
        p.schedule = schedule
        return p
    }

    // MARK: synced frames

    func testAFloodOfSyncedFramesIsLimitedPerLink() async {
        let peer = join("flooder")
        for i in 0..<400 { say(.events([event("e\(i)", author: "someone")], live: false), from: peer) }
        XCTAssertEqual(feed.events.count, TeamSession.syncedFrameBurst)
        XCTAssertFalse(peer.disconnected, "the link stays: the next inventory brings the rest")
    }

    func testAFullFeedSyncedThreeTimesAtOnceIsNotLimited() async {
        let peer = join("honest")
        // 300 events and 3000 reactions in frames of 100, asked for three times: 99 frames.
        for frame in 0..<99 {
            say(.events((0..<3).map { event("e\(frame)-\($0)", author: "someone") }, live: false), from: peer)
        }
        XCTAssertEqual(feed.events.count, 99 * 3)
    }

    func testLiveFramesAreNotChargedAsSyncedOnes() async {
        let peer = join("author")
        for i in 0..<(TeamSession.syncedFrameBurst + 30) { say(.events([event("l\(i)", author: "author")], live: true), from: peer) }
        XCTAssertEqual(feed.events.count, TeamSession.syncedFrameBurst + 30)
    }

    func testSyncedFramesComeBackWithTime() async {
        let peer = join("flooder")
        for i in 0..<(TeamSession.syncedFrameBurst + 10) { say(.events([event("a\(i)", author: "o")], live: false), from: peer) }
        let before = feed.events.count
        clock = clock.addingTimeInterval(10)
        for i in 0..<10 { say(.events([event("b\(i)", author: "o")], live: false), from: peer) }
        XCTAssertEqual(feed.events.count, before + 10)
    }

    // MARK: shared values

    func testAFloodOfNewerSchedulesIsAdoptedOnlyUpToTheBurst() async {
        let peer = join("flooder")
        let watcher = join("watcher")
        watcher.received = []
        for n in 0..<200 { say(.presence(presence(schedule: schedule(n, by: "flooder"))), from: peer) }
        XCTAssertEqual(settings.schedule?.changedAt, schedule(TeamSession.sharedValueBurst - 1, by: "flooder").changedAt)
        XCTAssertLessThanOrEqual(watcher.presences, 2, "one presence at once and one owed, not one per adoption")
    }

    func testAPersonChangingTheScheduleTwentyTimesInARowIsNotLimited() async {
        let peer = join("honest")
        for n in 0..<TeamSession.sharedValueBurst { say(.presence(presence(schedule: schedule(n, by: "honest"))), from: peer) }
        XCTAssertEqual(settings.schedule?.changedAt, schedule(TeamSession.sharedValueBurst - 1, by: "honest").changedAt)
    }

    func testARepeatedValueCostsNothing() async {
        let peer = join("honest")
        for _ in 0..<500 { say(.presence(presence(schedule: schedule(1, by: "honest"))), from: peer) }
        say(.presence(presence(schedule: schedule(2, by: "honest"))), from: peer)
        XCTAssertEqual(settings.schedule?.changedAt, schedule(2, by: "honest").changedAt, "heartbeats did not use the budget up")
    }

    func testTheOwedPresenceGoesOutOnTheNextTick() async {
        let peer = join("flooder")
        let watcher = join("watcher")
        for n in 0..<5 { say(.presence(presence(schedule: schedule(n, by: "flooder"))), from: peer) }
        watcher.received = []
        clock = clock.addingTimeInterval(TeamSession.adoptionBroadcastInterval)
        session.tick()
        XCTAssertEqual(watcher.presences, 1)
    }

    // MARK: profiles

    func testAProfileOfAMillionDexEntriesIsCutBeforeTheCardSeesIt() async {
        let peer = join("big")
        peer.transport.onMessage = { [unowned peer] id, m in
            peer.received.append(m)
            guard case .profileRequest = m else { return }
            let dex = (0..<3_000).map {
                TeamDexSpecies(speciesID: $0 % 2 == 0 ? 25 : 100_000 + $0, form: nil, name: $0 == 0 ? String(repeating: "x", count: 5_000) : "n",
                               rarity: .common, hasShiny: false, hasNormal: true)
            }
            peer.transport.send(.profile(TeamMemberProfile(memberID: "big", nickname: "x", current: Self.mon, dex: dex)), to: id)
        }
        let got = await session.requestProfile(memberID: "big")
        XCTAssertEqual(got?.dex.count, TeamMemberProfile.maxDexEntries, "foreign species are dropped and the rest is cut to what a real dex holds")
        XCTAssertEqual(got?.dex.first?.name, "#25", "a name longer than a field reads as the number")
    }

    // MARK: ice break in a jump

    private func jump(_ n: Int, ice: Bool = true) -> TeamMessage {
        var e = TeamEmote(kind: .jump, targetMemberID: nil)
        if ice { e.iceBreak = PlazaIceBreak(at: clock.timeIntervalSince1970 - 100 + Double(n) / 1000, pond: TilePoint(x: 5, y: 5)) }
        return .emote(e)
    }

    func testAFloodOfJumpsWithNewerIceBreaksIsAdoptedOnlyUpToTheBurst() async {
        var withIce = 0, jumps = 0
        session.onEmote = { _, e in jumps += 1; if e.iceBreak != nil { withIce += 1 } }
        let peer = join("flooder")
        for n in 0..<200 { say(jump(n), from: peer) }
        XCTAssertEqual(jumps, 200, "every jump still plays")
        XCTAssertEqual(withIce, TeamSession.sharedValueBurst)
    }

    func testAHonestJumpThatBreaksIceStillBreaksIt() async {
        var got: [PlazaIceBreak?] = []
        session.onEmote = { _, e in got.append(e.iceBreak) }
        let peer = join("honest")
        say(jump(1), from: peer)
        say(jump(1), from: peer)   // the same ice again is not a change
        say(jump(0, ice: false), from: peer)
        XCTAssertEqual(got.count, 3)
        XCTAssertNotNil(got[0])
        XCTAssertNotNil(got[1], "a repeated value costs nothing")
        XCTAssertNil(got[2])
    }

    // MARK: hello deadline

    func testALinkThatNeverSaysHelloIsClosedAfterTheDeadline() async {
        let silent = connect()
        clock = clock.addingTimeInterval(TeamSession.helloDeadline - 1)
        session.tick()
        XCTAssertFalse(silent.disconnected)
        clock = clock.addingTimeInterval(2)
        session.tick()
        XCTAssertTrue(silent.disconnected)
    }

    func testALinkThatSaidHelloIsNotClosedByTheDeadline() async {
        let peer = join("honest")
        for _ in 0..<5 {   // 50 s: past the deadline, with the heartbeats an honest peer sends
            clock = clock.addingTimeInterval(10)
            say(.presence(presence(schedule: nil)), from: peer)
            session.tick()
        }
        XCTAssertFalse(peer.disconnected)
    }
}
