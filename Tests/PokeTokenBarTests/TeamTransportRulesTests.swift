import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamTransportRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testConstantsAreTheOnesTheWireWasBuiltWith() async {
        XCTAssertEqual(TeamTransportRules.serviceType, "_ptbteam._tcp")
        XCTAssertEqual(TeamTransportRules.handshakeTimeout, 10)
        XCTAssertEqual(TeamTransportRules.redialInterval, 15)
        XCTAssertEqual(TeamTransportRules.listenerRetryDelay, 5)
        XCTAssertEqual(TeamTransportRules.maxUnfinishedInbound, 32)
        XCTAssertEqual(TeamTransportRules.maxUnfinishedOutbound, 32)
        XCTAssertEqual(TeamTransportRules.maxLinks, 128)
        XCTAssertEqual(TeamTransportRules.receiveBurst, 4_194_304)
        XCTAssertEqual(TeamTransportRules.receivePerSecond, 262_144)
        XCTAssertEqual(TeamTransportRules.frameCost, 1024)
        XCTAssertEqual(TeamTransportRules.maxReadChunk, 65_536)
        XCTAssertEqual(DNSSDName.defaultServiceType, TeamTransportRules.serviceType)
    }

    func testInstanceNameShape() async {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        XCTAssertEqual(TeamTransportRules.newInstanceName(id), "ptb-abcdef123456")
        let fresh = TeamTransportRules.newInstanceName()
        XCTAssertEqual(fresh.count, 16)
        XCTAssertTrue(fresh.hasPrefix("ptb-"))
        XCTAssertTrue(fresh.dropFirst(4).allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(fresh, TeamTransportRules.newInstanceName())
    }

    func testInboundAdmissionAtEachCap() async {
        XCTAssertTrue(TeamTransportRules.admitsInbound(linkCount: 0, unfinishedInbound: 0, linkLimit: 128))
        XCTAssertTrue(TeamTransportRules.admitsInbound(linkCount: 127, unfinishedInbound: 31, linkLimit: 128))
        XCTAssertFalse(TeamTransportRules.admitsInbound(linkCount: 128, unfinishedInbound: 0, linkLimit: 128), "link limit")
        XCTAssertFalse(TeamTransportRules.admitsInbound(linkCount: 5, unfinishedInbound: 32, linkLimit: 128), "unfinished cap")
        XCTAssertFalse(TeamTransportRules.admitsInbound(linkCount: 2, unfinishedInbound: 0, linkLimit: 2), "a small custom limit")
    }

    func testDialRoomNeverNegative() async {
        XCTAssertEqual(TeamTransportRules.dialRoom(unfinishedOutbound: 0, linkCount: 0, linkLimit: 128), 32)
        XCTAssertEqual(TeamTransportRules.dialRoom(unfinishedOutbound: 30, linkCount: 30, linkLimit: 128), 2)
        XCTAssertEqual(TeamTransportRules.dialRoom(unfinishedOutbound: 0, linkCount: 125, linkLimit: 128), 3, "the link limit leaves less")
        XCTAssertEqual(TeamTransportRules.dialRoom(unfinishedOutbound: 32, linkCount: 32, linkLimit: 128), 0)
        XCTAssertEqual(TeamTransportRules.dialRoom(unfinishedOutbound: 40, linkCount: 200, linkLimit: 128), 0)
    }

    func testReceiverDeliversInOrder() async throws {
        var r = TeamLinkReceiver()
        let a = try TeamWire.encode(.profileRequest)
        let b = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        guard case .messages(let got) = r.receive(a + b, now: t0) else { return XCTFail("not delivered") }
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first, .profileRequest)
    }

    func testReceiverKeepsAFrameSplitAcrossChunks() async throws {
        var r = TeamLinkReceiver()
        let frame = try TeamWire.encode(.profileRequest)
        XCTAssertEqual(r.receive(frame.prefix(3), now: t0), .messages([]))
        XCTAssertEqual(r.receive(frame.dropFirst(3), now: t0), .messages([.profileRequest]))
    }

    func testReceiverReportsABadFrameBeforeSpending() async throws {
        // Drain the budget with valid frames, then send a bad frame: it reads as a bad frame, not as a flood.
        var r = TeamLinkReceiver()
        let frame = try TeamWire.encode(.profileRequest)
        let cost = Double(frame.count + TeamTransportRules.frameCost)
        var left = TeamTransportRules.receiveBurst
        while left >= cost { _ = r.receive(frame, now: t0); left -= cost }
        XCTAssertEqual(r.receive(frame, now: t0), .flood, "the budget is empty")
        guard case .badFrame = r.receive(Data([0xFF, 0xFF, 0xFF, 0xFF]), now: t0) else {
            return XCTFail("a bad frame on an empty budget was not reported as one")
        }
    }

    func testReceiverDropsATinyFrameFlood() async throws {
        var r = TeamLinkReceiver()
        let frame = try TeamWire.encode(.emote(TeamEmote(kind: .jump, targetMemberID: nil)))
        let flood = (0..<6000).reduce(into: Data()) { d, _ in d.append(frame) }
        var verdict = TeamLinkReceiver.Outcome.messages([])
        var offset = 0
        while offset < flood.count, case .messages = verdict {
            let end = min(offset + TeamTransportRules.maxReadChunk, flood.count)
            verdict = r.receive(flood[offset..<end], now: t0)
            offset = end
        }
        XCTAssertEqual(verdict, .flood)
    }

    func testReceiverLetsAFullSyncThrough() async throws {
        var r = TeamLinkReceiver()
        let row = TeamReaction(id: UUID().uuidString, eventID: UUID().uuidString, authorID: UUID().uuidString,
                               authorNickname: "닉네임", kind: .cute, text: nil, createdAt: Date())
        let batch = try TeamWire.encode(.reactions(Array(repeating: row, count: TeamSession.batchSize), live: false))
        let moved = TeamPresence(nickname: "닉네임", character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                 inPlaza: true, tile: TilePoint(x: 3, y: 3), facing: .down, isWalking: true)
        let step = try TeamWire.encode(.presence(moved))
        var delivered = 0
        for _ in 0..<33 { if case .messages(let m) = r.receive(batch, now: t0) { delivered += m.count } else { return XCTFail("dropped a sync") } }
        for _ in 0..<300 { if case .messages(let m) = r.receive(step, now: t0) { delivered += m.count } else { return XCTFail("dropped a run") } }
        XCTAssertEqual(delivered, 333)
    }
}
