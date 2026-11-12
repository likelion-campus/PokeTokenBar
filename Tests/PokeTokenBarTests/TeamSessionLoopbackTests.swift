import Network
import XCTest
@testable import PokeTokenBar

/// Two real sessions over real loopback sockets. `FakeTeamTransport.send` skips `TeamWire.encode`, so only
/// this path sees what a later version of the app could put on the wire.
@MainActor
final class TeamSessionLoopbackTests: XCTestCase {
    @MainActor private final class Side {
        let transport = BonjourTeamTransport(advertise: false)
        let settings: TeamSettings
        let feed: TeamFeedStore
        let session: TeamSession
        let suite = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamSessionLoopbackTests-\(UUID().uuidString)")

        init(_ name: String, code: TeamCode) {
            let defaults = TestDefaults.make(suite: suite)
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

        func tearDown() {
            transport.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func frame(_ json: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    private func event(_ id: String, author: String) -> TeamEvent {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return TeamEvent(id: id, authorID: author, authorNickname: "Ash", kind: .evolve, speciesID: 26, fromSpeciesID: 25,
                         speciesName: "Raichu", fromSpeciesName: "Pikachu", form: nil, isShiny: false, nature: nil,
                         rarity: .common, day: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), occurredAt: nil)
    }

    func testLaterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems() async throws {
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let a = Side("Aa", code: code), b = Side("Bb", code: code)
        defer { a.tearDown(); b.tearDown() }

        let ready = await waitUntil(5) { a.transport.listenerPort != nil }
        XCTAssertTrue(ready, "listener did not become ready")
        b.transport.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(a.transport.listenerPort)))
        let joined = await waitUntil(5) { a.session.members.count == 1 && b.session.members.count == 1 }
        XCTAssertTrue(joined, "hello exchange did not finish")
        let toA = try XCTUnwrap(b.transport.peerIDs.first)

        // A message kind a later version added, then a batch where one event is of a kind this version lacks.
        let good = event("good", author: b.settings.memberID), future = event("future", author: b.settings.memberID)
        let batch = try XCTUnwrap(JSONSerialization.jsonObject(
            with: TeamWire.encode(.events([future, good], live: false)).dropFirst(4)) as? [String: Any])
        var inner = try XCTUnwrap(batch["events"] as? [String: Any])
        var list = try XCTUnwrap(inner["_0"] as? [[String: Any]])
        list[0]["kind"] = "teleport"
        inner["_0"] = list
        b.transport.sendRaw(try frame(["hologram": ["_0": [1, 2, 3]]]), to: toA)
        b.transport.sendRaw(try frame(["events": inner]), to: toA)

        let arrived = await waitUntil(5) { a.feed.eventIDs.contains("good") }
        XCTAssertTrue(arrived, "the readable event of the batch must arrive")
        XCTAssertFalse(a.feed.eventIDs.contains("future"))
        XCTAssertEqual(a.session.members.count, 1, "the link survives")
        XCTAssertEqual(b.session.members.count, 1)
        XCTAssertFalse(a.session.hasIncompatiblePeer)
        XCTAssertEqual(a.transport.linkCount, 1)
    }
}
