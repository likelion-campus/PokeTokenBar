import Foundation
import XCTest
@testable import PokeTokenBar

/// What a transport needs from its test environment. The Mac (Network.framework) and the Windows (Schannel) transports each
/// implement this and run every `TeamTransportContract` scenario, so the two cannot drift apart. No Network import here.
@MainActor
protocol TeamTransportHarness: AnyObject {
    associatedtype Transport: TeamTransporting
    associatedtype Endpoint

    /// A transport that does not advertise, stopped in `tearDown()`.
    func make(linkLimit: Int) -> Transport
    /// 127.0.0.1:<listener port>, waiting up to 5 s for the listener.
    func loopbackEndpoint(of t: Transport) async throws -> Endpoint
    func listenerPort(of t: Transport) -> UInt16?
    func connect(_ t: Transport, to e: Endpoint)
    func injectDiscovered(_ t: Transport, name: String, endpoint e: Endpoint)
    func plannedDials(_ t: Transport, now: Date) -> [String]
    func linkCount(_ t: Transport) -> Int
    func peerIDs(_ t: Transport) -> [TeamPeerID]
    func sendRaw(_ t: Transport, _ data: Data, to peer: TeamPeerID)
    func willSleep(_ t: Transport)
    func didWake(_ t: Transport)
    func restart(_ t: Transport)
    func failDiscovery(_ t: Transport)
    /// A TCP service that accepts and never speaks TLS.
    func silentSink() async throws -> (endpoint: Endpoint, close: () -> Void)
    /// `count` plain TCP connections to the transport's listener; none ever handshakes.
    func plainTCP(toPortOf t: Transport, count: Int) async throws -> () -> Void
    /// A TLS connection with the team's key, ready, that the test writes to as it likes.
    func rawTLS(to e: Endpoint, code: TeamCode) async throws -> (send: (Data) -> Void, close: () -> Void)
    func tearDown()
}

extension TeamTransportHarness {
    func make() -> Transport { make(linkLimit: TeamTransportRules.maxLinks) }
}

@MainActor
func contractWaitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Two connected transports: `a` listens, `b` dials it.
@MainActor
func contractConnectedPair<H: TeamTransportHarness>(_ h: H) async throws
    -> (a: H.Transport, b: H.Transport, aPeer: TeamPeerID, bPeer: TeamPeerID) {
    var rng = SystemRandomNumberGenerator()
    let code = TeamCode.generate(using: &rng)
    let a = h.make(), b = h.make()
    var aPeer: TeamPeerID?, bPeer: TeamPeerID?
    a.onPeerConnected = { id, _ in aPeer = id }
    b.onPeerConnected = { id, _ in bPeer = id }
    a.start(code: code); b.start(code: code)
    h.connect(b, to: try await h.loopbackEndpoint(of: a))
    let up = await contractWaitUntil(5) { aPeer != nil && bPeer != nil && h.linkCount(a) == 1 }
    XCTAssertTrue(up)
    return (a, b, try XCTUnwrap(aPeer), try XCTUnwrap(bPeer))
}


@MainActor
enum TeamTransportContract {
    private static func newCode() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    private static let hello = TeamMessage.profileRequest

    // MARK: delivery

    static func sameCodePeersExchangeMessagesOverLoopback<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var aPeer: (TeamPeerID, Bool)?, bPeer: (TeamPeerID, Bool)?
        var aGot: [TeamMessage] = [], bGot: [TeamMessage] = []
        a.onPeerConnected = { aPeer = ($0, $1) }
        b.onPeerConnected = { bPeer = ($0, $1) }
        a.onMessage = { _, m in aGot.append(m) }
        b.onMessage = { _, m in bGot.append(m) }
        a.start(code: code); b.start(code: code)
        h.connect(b, to: try await h.loopbackEndpoint(of: a))

        let connected = await contractWaitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(connected)
        XCTAssertEqual(aPeer?.1, false)
        XCTAssertEqual(bPeer?.1, true)

        b.send(hello, to: try XCTUnwrap(bPeer).0)
        a.send(.emote(TeamEmote(kind: .heart, targetMemberID: nil)), to: try XCTUnwrap(aPeer).0)
        let delivered = await contractWaitUntil(5) { !aGot.isEmpty && !bGot.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(aGot, [hello])
        XCTAssertEqual(bGot, [.emote(TeamEmote(kind: .heart, targetMemberID: nil))])
    }

    static func differentCodeNeverDeliversMessages<H: TeamTransportHarness>(_ h: H) async throws {
        let a = h.make(), b = h.make()
        var events = 0
        for t in [a, b] {
            t.onPeerConnected = { _, _ in events += 1 }
            t.onMessage = { _, _ in events += 1 }
        }
        a.start(code: newCode()); b.start(code: newCode())
        h.connect(b, to: try await h.loopbackEndpoint(of: a))
        let leaked = await contractWaitUntil(3) { events > 0 }
        XCTAssertFalse(leaked)
    }

    /// The owner hears `onPeerBadFrame` first and then the disconnect, both for the same peer.
    static func malformedFrameDisconnects<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make()
        var connected: TeamPeerID?
        var events: [String] = []
        a.onPeerConnected = { id, _ in connected = id }
        a.onPeerBadFrame = { events.append("bad:\($0)") }
        a.onPeerDisconnected = { events.append("down:\($0)") }
        a.start(code: code)
        let raw = try await h.rawTLS(to: try await h.loopbackEndpoint(of: a), code: code)
        defer { raw.close() }
        let up = await contractWaitUntil(5) { connected != nil }
        XCTAssertTrue(up)
        raw.send(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        let dropped = await contractWaitUntil(5) { events.count >= 2 }
        XCTAssertTrue(dropped)
        let id = try XCTUnwrap(connected)
        XCTAssertEqual(events, ["bad:\(id)", "down:\(id)"])
    }

    // MARK: stop, disconnect, sleep, restart

    static func stopSilencesCallbacks<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, b, _, bPeer) = try await contractConnectedPair(h)
        var aEvents = 0
        a.onMessage = { _, _ in aEvents += 1 }
        a.onPeerDisconnected = { _ in aEvents += 1 }
        a.stop()
        b.send(hello, to: bPeer)
        let leaked = await contractWaitUntil(1) { aEvents > 0 }
        XCTAssertFalse(leaked)
    }

    static func disconnectIsSilentAndUnknownPeerIsNoOp<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var bDisconnected = false, aDisconnected = false
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.onPeerDisconnected = { _ in aDisconnected = true }
        b.onPeerDisconnected = { _ in bDisconnected = true }
        a.start(code: code); b.start(code: code)
        h.connect(b, to: try await h.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        a.disconnect("no-such-peer", coveredBy: nil)
        XCTAssertFalse(aDisconnected)
        a.disconnect(try XCTUnwrap(aPeer), coveredBy: nil)
        let remoteSawIt = await contractWaitUntil(5) { bDisconnected }
        XCTAssertTrue(remoteSawIt)
        XCTAssertFalse(aDisconnected, "owner-initiated disconnect is not reported back")
    }

    static func sleepReportsDisconnectsAndWakeRestartsOnlyRunningTransport<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var aPeer: TeamPeerID?, bPeer: TeamPeerID?
        var aDown: [TeamPeerID] = []
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerConnected = { id, _ in bPeer = id }
        a.onPeerDisconnected = { aDown.append($0) }
        a.start(code: code); b.start(code: code)
        h.connect(b, to: try await h.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil && bPeer != nil }
        XCTAssertTrue(up)

        h.willSleep(a)
        XCTAssertEqual(aDown, [try XCTUnwrap(aPeer)])
        XCTAssertNil(h.listenerPort(of: a))

        h.didWake(a)
        let back = await contractWaitUntil(5) { h.listenerPort(of: a) != nil }
        XCTAssertTrue(back, "wake restarts a transport that was running")

        a.stop()
        h.didWake(a)
        XCTAssertNil(h.listenerPort(of: a), "wake must not restart a transport the owner stopped")
    }

    static func ownerStoppingInsideDisconnectCallbackPreventsRestart<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, _, _, _) = try await contractConnectedPair(h)
        a.onPeerDisconnected = { _ in a.stop() }
        h.restart(a)
        h.didWake(a)
        let came = await contractWaitUntil(0.5) { h.listenerPort(of: a) != nil }
        XCTAssertFalse(came, "a transport stopped from the disconnect callback must stay stopped")
    }

    static func failedDiscoveryRestartsLikeAFailedListener<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, _, aPeer, _) = try await contractConnectedPair(h)
        var aDown: [TeamPeerID] = []
        a.onPeerDisconnected = { aDown.append($0) }
        h.failDiscovery(a)
        XCTAssertEqual(aDown, [aPeer])
        XCTAssertNil(h.listenerPort(of: a))
        let back = await contractWaitUntil(8) { h.listenerPort(of: a) != nil }
        XCTAssertTrue(back, "the transport comes back by itself after the retry delay")
    }

    // MARK: caps

    static func unfinishedInboundLinksAreCapped<H: TeamTransportHarness>(_ h: H) async throws {
        let a = h.make()
        a.start(code: newCode())
        _ = try await h.loopbackEndpoint(of: a)
        // Plain TCP never completes the TLS handshake, so every one of these stays unfinished.
        let close = try await h.plainTCP(toPortOf: a, count: TeamTransportRules.maxUnfinishedInbound + 8)
        defer { close() }
        let full = await contractWaitUntil(5) { h.linkCount(a) >= TeamTransportRules.maxUnfinishedInbound }
        XCTAssertTrue(full)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(h.linkCount(a), TeamTransportRules.maxUnfinishedInbound)
    }

    /// Anyone on the network can advertise a thousand services without the team code. Before the cap every one
    /// was dialed at once, which took all 256 file handles an app gets: saves failed and no teammate could connect.
    static func dialsToRogueServicesAreCapped<H: TeamTransportHarness>(_ h: H) async throws {
        let sink = try await h.silentSink()
        defer { sink.close() }
        let a = h.make()
        a.start(code: newCode())
        for i in 0..<1000 { h.injectDiscovered(a, name: "ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(h.linkCount(a), TeamTransportRules.maxUnfinishedOutbound)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.linkCount(a), TeamTransportRules.maxUnfinishedOutbound, "they stay unfinished, so nothing more is dialed")
    }

    /// Every new name asks for a dial. Sorting all of them each time held the main thread for 21 s over 5,000 names,
    /// so with no room nothing may be scanned. Far under the limit here, to stay clear of a busy machine.
    static func aFloodOfNamesCostsLittleOnceTheDialsAreFull<H: TeamTransportHarness>(_ h: H) async throws {
        let sink = try await h.silentSink()
        defer { sink.close() }
        let a = h.make()
        a.start(code: newCode())
        let start = Date()
        for i in 0..<5000 { h.injectDiscovered(a, name: "ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(h.linkCount(a), TeamTransportRules.maxUnfinishedOutbound)
    }

    static func dialsLeaveRoomForTheLinkLimit<H: TeamTransportHarness>(_ h: H) async throws {
        let sink = try await h.silentSink()
        defer { sink.close() }
        let a = h.make(linkLimit: 3)
        a.start(code: newCode())
        for i in 0..<10 { h.injectDiscovered(a, name: "ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(h.linkCount(a), 3)
    }

    static func inboundLinksStopAtTheLinkLimit<H: TeamTransportHarness>(_ h: H) async throws {
        let a = h.make(linkLimit: 2)
        a.start(code: newCode())
        _ = try await h.loopbackEndpoint(of: a)
        let close = try await h.plainTCP(toPortOf: a, count: 6)
        defer { close() }
        let full = await contractWaitUntil(5) { h.linkCount(a) >= 2 }
        XCTAssertTrue(full)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(h.linkCount(a), 2)
    }

    /// The cap only counts unfinished dials, so a finished link leaves room for the next one.
    static func aFinishedLinkDoesNotUseUpADialSlot<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let server = h.make()
        server.start(code: code)
        let real = try await h.loopbackEndpoint(of: server)
        let a = h.make()
        a.start(code: code)
        var connected = 0
        a.onPeerConnected = { _, _ in connected += 1 }
        h.injectDiscovered(a, name: "ptb-teammate", endpoint: real)
        let up = await contractWaitUntil(5) { connected == 1 }
        XCTAssertTrue(up)
        let sink = try await h.silentSink()
        defer { sink.close() }
        for i in 0..<100 { h.injectDiscovered(a, name: "ptb-rogue-\(i)", endpoint: sink.endpoint) }
        XCTAssertEqual(h.linkCount(a), TeamTransportRules.maxUnfinishedOutbound + 1)
    }

    // MARK: floods

    /// Big frames decode on the main thread, so a link pouring them in would hold it for as long as it liked.
    static func aLinkPouringInBytesIsDropped<H: TeamTransportHarness>(_ h: H) async throws {
        let (receiver, sender, _, peer) = try await contractConnectedPair(h)
        var bad = 0
        receiver.onPeerBadFrame = { _ in bad += 1 }
        let id = String(repeating: "x", count: 1_000_000)
        let frame = try TeamWire.encode(.inventory(eventIDs: [id], reactionIDs: []))
        for _ in 0..<6 { h.sendRaw(sender, frame, to: peer) }
        let dropped = await contractWaitUntil(5) { bad == 1 }
        XCTAssertTrue(dropped)
        XCTAssertEqual(h.linkCount(receiver), 0)
    }

    /// Small frames cost little to send and more to handle, so each one counts for more than its bytes.
    static func aLinkPouringInTinyFramesIsDropped<H: TeamTransportHarness>(_ h: H) async throws {
        let (receiver, sender, _, peer) = try await contractConnectedPair(h)
        var delivered = 0, bad = 0
        receiver.onMessage = { _, _ in delivered += 1 }
        receiver.onPeerBadFrame = { _ in bad += 1 }
        let frame = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        let flood = (0..<6000).reduce(into: Data()) { d, _ in d.append(frame) }
        h.sendRaw(sender, flood, to: peer)
        let dropped = await contractWaitUntil(5) { bad == 1 }
        XCTAssertTrue(dropped)
        XCTAssertLessThan(delivered, 6000, "the rest of a flood is not handled")
    }

    /// What an honest app sends at its busiest: a full sync, well under the burst, then a run across the plaza.
    static func aSyncAndARunAreNotDropped<H: TeamTransportHarness>(_ h: H) async throws {
        let (receiver, sender, _, peer) = try await contractConnectedPair(h)
        var bad = 0, delivered = 0
        receiver.onPeerBadFrame = { _ in bad += 1 }
        receiver.onMessage = { _, _ in delivered += 1 }
        let row = TeamReaction(id: UUID().uuidString, eventID: UUID().uuidString, authorID: UUID().uuidString,
                               authorNickname: "닉네임", kind: .cute, text: nil, createdAt: Date())
        let batch = try TeamWire.encode(.reactions(Array(repeating: row, count: TeamSession.batchSize), live: false))
        for _ in 0..<33 { h.sendRaw(sender, batch, to: peer) }
        let moved = TeamPresence(nickname: "닉네임", character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                 inPlaza: true, tile: TilePoint(x: 3, y: 3), facing: .down, isWalking: true)
        let step = try TeamWire.encode(.presence(moved))
        for _ in 0..<300 { h.sendRaw(sender, step, to: peer) }
        let all = await contractWaitUntil(5) { delivered == 333 }
        XCTAssertTrue(all)
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(h.linkCount(receiver), 1)
    }

    // MARK: redial

    static func failedDialIsClosedAndWaitsForCooldown<H: TeamTransportHarness>(_ h: H) async throws {
        let a = h.make(), b = h.make()
        a.start(code: newCode()); b.start(code: newCode())
        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        XCTAssertEqual(h.linkCount(b), 1)

        let later = Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
        let failed = await contractWaitUntil(5) { h.plannedDials(b, now: later) == ["x"] }
        XCTAssertTrue(failed, "the failed dial should end and become due again after the cooldown")
        XCTAssertEqual(h.linkCount(b), 0)
        XCTAssertEqual(h.plannedDials(b, now: Date()), [], "no redial inside the cooldown")
    }

    /// A bad frame refuses the dialed name: no redial for five minutes, even when the name is discovered again.
    static func aBadFrameHoldsTheNameOffForFiveMinutes<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var aPeer: TeamPeerID?
        var bBad = 0
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerBadFrame = { _ in bBad += 1 }
        a.start(code: code); b.start(code: code)
        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil && h.linkCount(b) == 1 }
        XCTAssertTrue(up)
        h.sendRaw(a, Data([0xFF, 0xFF, 0xFF, 0xFF]), to: try XCTUnwrap(aPeer))
        let dropped = await contractWaitUntil(5) { bBad == 1 && h.linkCount(b) == 0 }
        XCTAssertTrue(dropped)

        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        XCTAssertEqual(h.linkCount(b), 0, "rediscovery inside the hold-off dials nothing")
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.refusalCooldown - 5)), [])
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.refusalCooldown + 5)), ["x"])
    }

    /// A dialed (named) peer that floods is dropped like one that sends a bad frame: its name waits five minutes.
    static func aFloodedNamedPeerWaitsForTheRefusalCooldown<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var aPeer: TeamPeerID?
        var bBad = 0
        a.onPeerConnected = { id, _ in aPeer = id }
        b.onPeerBadFrame = { _ in bBad += 1 }
        a.start(code: code); b.start(code: code)
        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { aPeer != nil && h.linkCount(b) == 1 }
        XCTAssertTrue(up)
        let frame = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        let flood = (0..<6000).reduce(into: Data()) { d, _ in d.append(frame) }
        h.sendRaw(a, flood, to: try XCTUnwrap(aPeer))
        let dropped = await contractWaitUntil(5) { bBad == 1 && h.linkCount(b) == 0 }
        XCTAssertTrue(dropped)

        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        XCTAssertEqual(h.linkCount(b), 0, "rediscovery inside the hold-off dials nothing")
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.refusalCooldown - 5)), [])
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.refusalCooldown + 5)), ["x"])
    }

    static func disconnectCoveredByKeptConnectionStopsRedialUntilKeptEnds<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var bPeers: [TeamPeerID] = []
        b.onPeerConnected = { id, _ in bPeers.append(id) }
        a.start(code: code); b.start(code: code)
        let endpoint = try await h.loopbackEndpoint(of: a)
        h.injectDiscovered(b, name: "x", endpoint: endpoint)
        let first = await contractWaitUntil(5) { bPeers.count == 1 }
        XCTAssertTrue(first)
        h.connect(b, to: endpoint)
        let second = await contractWaitUntil(5) { bPeers.count == 2 }
        XCTAssertTrue(second)

        b.disconnect(bPeers[0], coveredBy: bPeers[1])
        XCTAssertEqual(h.plannedDials(b, now: Date()), [])
        b.disconnect(bPeers[1], coveredBy: nil)
        XCTAssertEqual(h.plannedDials(b, now: Date()), ["x"])
    }

    // MARK: sessions

    private static func frame(_ json: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    private static func event(_ id: String, author: String) -> TeamEvent {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return TeamEvent(id: id, authorID: author, authorNickname: "Ash", kind: .evolve, speciesID: 26, fromSpeciesID: 25,
                         speciesName: "Raichu", fromSpeciesName: "Pikachu", form: nil, isShiny: false, nature: nil,
                         rarity: .common, day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), occurredAt: nil)
    }

    /// Two real sessions over the transport. `FakeTeamTransport.send` skips `TeamWire.encode`, so only a real
    /// transport sees what a later version of the app could put on the wire.
    @MainActor private final class Side {
        let settings: TeamSettings
        let feed: TeamFeedStore
        let session: TeamSession
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamTransportContract-\(UUID().uuidString)")

        init(_ name: String, code: TeamCode, transport: TeamTransporting) {
            let defaults = TestDefaults.make(suite: UUID().uuidString)
            settings = TeamSettings(defaults: defaults)
            settings.code = code
            settings.nickname = name
            settings.isEnabled = true
            feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
            let memberID = settings.memberID
            session = TeamSession(settings: settings, feed: feed, transport: transport, profileProvider: {
                TeamMemberProfile(memberID: memberID, nickname: name,
                                  current: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil),
                                  dex: [])
            })
            session.applySettings()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: dir) }
    }

    static func laterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let ta = h.make(), tb = h.make()
        let a = Side("Aa", code: code, transport: ta), b = Side("Bb", code: code, transport: tb)
        defer { a.cleanUp(); b.cleanUp() }

        let ready = await contractWaitUntil(5) { h.listenerPort(of: ta) != nil }
        XCTAssertTrue(ready, "listener did not become ready")
        h.connect(tb, to: try await h.loopbackEndpoint(of: ta))
        let joined = await contractWaitUntil(5) { a.session.members.count == 1 && b.session.members.count == 1 }
        XCTAssertTrue(joined, "hello exchange did not finish")
        let toA = try XCTUnwrap(h.peerIDs(tb).first)

        // A message kind a later version added, then a batch where one event is of a kind this version lacks.
        let good = event("good", author: b.settings.memberID), future = event("future", author: b.settings.memberID)
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(
            with: TeamWire.encode(.events([future, good], live: false)).dropFirst(4)) as? [String: Any])
        var inner = try XCTUnwrap(batch["events"] as? [String: Any])
        var list = try XCTUnwrap(inner["_0"] as? [[String: Any]])
        list[0]["kind"] = "teleport"
        inner["_0"] = list
        h.sendRaw(tb, try frame(["hologram": ["_0": [1, 2, 3]]]), to: toA)
        h.sendRaw(tb, try frame(["events": inner]), to: toA)

        let arrived = await contractWaitUntil(5) { a.feed.eventIDs.contains("good") }
        XCTAssertTrue(arrived, "the readable event of the batch must arrive")
        XCTAssertFalse(a.feed.eventIDs.contains("future"))
        XCTAssertEqual(a.session.members.count, 1, "the link survives")
        XCTAssertEqual(b.session.members.count, 1)
        XCTAssertFalse(a.session.hasIncompatiblePeer)
        XCTAssertEqual(h.linkCount(ta), 1)
    }

    // MARK: new scenarios

    /// An unfinished link ends at the handshake timeout in both directions, and its slot is free again afterwards.
    static func anUnfinishedHandshakeEndsAfterTheTimeout<H: TeamTransportHarness>(_ h: H) async throws {
        let sink = try await h.silentSink()
        defer { sink.close() }
        let a = h.make(linkLimit: 2)
        a.start(code: newCode())
        _ = try await h.loopbackEndpoint(of: a)
        h.injectDiscovered(a, name: "ptb-rogue-0", endpoint: sink.endpoint)   // outbound, never answered
        let inbound = try await h.plainTCP(toPortOf: a, count: 1)             // inbound, never handshakes
        defer { inbound() }
        let both = await contractWaitUntil(5) { h.linkCount(a) == 2 }
        XCTAssertTrue(both)
        // At the limit nothing more is taken, in either direction.
        h.injectDiscovered(a, name: "ptb-rogue-1", endpoint: sink.endpoint)
        let extra = try await h.plainTCP(toPortOf: a, count: 1)
        defer { extra() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.linkCount(a), 2)

        let ended = await contractWaitUntil(TeamTransportRules.handshakeTimeout + 2) { h.linkCount(a) == 0 }
        XCTAssertTrue(ended, "unfinished handshakes end within the timeout")
        let due = Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)
        XCTAssertTrue(h.plannedDials(a, now: due).contains("ptb-rogue-0"), "due again after the cooldown")
        XCTAssertFalse(h.plannedDials(a, now: Date()).contains("ptb-rogue-0"), "not inside the cooldown")

        // The slots are free: a new link of each kind is taken at the former cap.
        h.injectDiscovered(a, name: "ptb-rogue-2", endpoint: sink.endpoint)
        let again = try await h.plainTCP(toPortOf: a, count: 1)
        defer { again() }
        let reopened = await contractWaitUntil(5) { h.linkCount(a) == 2 }
        XCTAssertTrue(reopened, "the timeout freed the slots")
    }

    /// The remote side stopping ends the link, and the owner hears it exactly once.
    static func remoteStopIsReportedOnce<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, b, aPeer, _) = try await contractConnectedPair(h)
        var down: [TeamPeerID] = []
        a.onPeerDisconnected = { down.append($0) }
        b.stop()
        let reported = await contractWaitUntil(5) { !down.isEmpty }
        XCTAssertTrue(reported)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(down, [aPeer])
        XCTAssertEqual(h.linkCount(a), 0)
    }

    /// Sending to a peer that is not connected, or whose handshake is not finished, does nothing: no crash, no event.
    static func sendToAnUnreadyOrUnknownPeerIsDropped<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, b, _, bPeer) = try await contractConnectedPair(h)
        var events = 0
        a.onMessage = { _, _ in events += 1 }
        a.onPeerDisconnected = { _ in events += 1 }
        b.onPeerDisconnected = { _ in events += 1 }

        let sink = try await h.silentSink()
        defer { sink.close() }
        h.injectDiscovered(b, name: "ptb-rogue", endpoint: sink.endpoint)
        let unready = try XCTUnwrap(h.peerIDs(b).first { $0 != bPeer }, "the dial to the sink is a link that is not ready")

        b.send(hello, to: "no-such-peer")
        b.send(hello, to: unready)
        let leaked = await contractWaitUntil(1) { events > 0 }
        XCTAssertFalse(leaked)
        XCTAssertEqual(h.linkCount(b), 2, "nothing was torn down by the dropped sends")

        var got: [TeamMessage] = []
        a.onMessage = { _, m in got.append(m) }
        b.send(hello, to: bPeer)
        let still = await contractWaitUntil(5) { !got.isEmpty }
        XCTAssertTrue(still, "the ready link still delivers")
    }

    /// When the owner disconnects a peer from inside `onMessage`, the rest of that batch is not delivered.
    static func ownerDisconnectInsideOnMessageStopsTheBatch<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, b, _, bPeer) = try await contractConnectedPair(h)
        var delivered = 0
        a.onMessage = { id, _ in
            delivered += 1
            a.disconnect(id, coveredBy: nil)
        }
        let frame = try TeamWire.encode(hello)
        h.sendRaw(b, frame + frame, to: bPeer)   // two frames in one write
        let first = await contractWaitUntil(5) { delivered >= 1 }
        XCTAssertTrue(first)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(h.linkCount(a), 0)
    }

    /// `refuse` ends the link silently and holds the name off for the refusal cooldown (not the 60 s handshake one).
    static func refusedPeerWaitsForTheRefusalCooldown<H: TeamTransportHarness>(_ h: H) async throws {
        let code = newCode()
        let a = h.make(), b = h.make()
        var bPeer: TeamPeerID?
        var bDown = 0
        b.onPeerConnected = { id, _ in bPeer = id }
        b.onPeerDisconnected = { _ in bDown += 1 }
        a.start(code: code); b.start(code: code)
        h.injectDiscovered(b, name: "x", endpoint: try await h.loopbackEndpoint(of: a))
        let up = await contractWaitUntil(5) { bPeer != nil }
        XCTAssertTrue(up)

        b.refuse(try XCTUnwrap(bPeer))
        XCTAssertEqual(h.linkCount(b), 0)
        XCTAssertEqual(bDown, 0, "refusing is owner-initiated and silent")
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.handshakeRetryCooldown + 1)), [],
                       "not due at +61 s")
        XCTAssertEqual(h.plannedDials(b, now: Date().addingTimeInterval(TeamDialPlanner.refusalCooldown + 1)), ["x"],
                       "due at +301 s")
    }

    /// An internal restart tells the owner about every live link, then the transport listens again and links work.
    static func restartReportsLiveLinksThenComesBack<H: TeamTransportHarness>(_ h: H) async throws {
        let (a, b, aPeer, _) = try await contractConnectedPair(h)
        var down: [TeamPeerID] = []
        a.onPeerDisconnected = { down.append($0) }
        h.restart(a)
        XCTAssertEqual(down, [aPeer])
        XCTAssertEqual(h.linkCount(a), 0)
        let back = await contractWaitUntil(5) { h.listenerPort(of: a) != nil }
        XCTAssertTrue(back, "a restart listens again")

        var again: TeamPeerID?
        a.onPeerConnected = { id, _ in again = id }
        h.connect(b, to: try await h.loopbackEndpoint(of: a))
        let linked = await contractWaitUntil(5) { again != nil && h.linkCount(a) == 1 }
        XCTAssertTrue(linked, "links work after the restart")
    }
}
