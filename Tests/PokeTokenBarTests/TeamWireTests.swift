import XCTest
@testable import PokeTokenBar

final class TeamWireTests: XCTestCase {
    private let event = TeamEvent(
        id: "e1", authorID: "m1", authorNickname: "Ash", kind: .hatch,
        speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
        form: nil, isShiny: true, nature: nil, rarity: .rare,
        day: "2026-10-29", occurredAt: Date(timeIntervalSince1970: 1_790_000_000.123))
    private let reaction = TeamReaction(
        id: "r1", eventID: "e1", authorID: "m2", authorNickname: "Misty",
        kind: .comment, text: "nice", createdAt: Date(timeIntervalSince1970: 1_790_000_100.5))
    private let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu")

    private let presence = TeamPresence(
        nickname: "Ash", character: TeamMonSummary(speciesID: 25, isShiny: true, form: nil, speciesName: "Pikachu", gender: .female),
        inPlaza: true, tile: TilePoint(x: 3, y: 4), facing: .left, isWalking: true)

    private var allMessages: [TeamMessage] {
        [
            .hello(TeamHello(memberID: "m1", nickname: "Ash", protocolVersion: TeamWire.protocolVersion, current: mon)),
            .inventory(eventIDs: ["e1", "e2"], reactionIDs: ["r1"]),
            .events([event], live: true),
            .reactions([reaction], live: false),
            .profileRequest,
            .presence(presence),
            .emote(TeamEmote(kind: .heart, targetMemberID: "m2")),
            .emote(TeamEmote(kind: .question, targetMemberID: nil)),
            .profile(TeamMemberProfile(memberID: "m1", nickname: "Ash", current: mon,
                dex: [TeamDexSpecies(speciesID: 25, form: nil, name: "Pikachu", rarity: .rare, hasShiny: true, hasNormal: false)])),
        ]
    }

    func testRoundTripEveryCase() throws {
        for m in allMessages {
            var decoder = TeamWire.FrameDecoder()
            let out = try decoder.append(try TeamWire.encode(m))
            XCTAssertEqual(out, [m])
        }
    }

    func testDecoderHandlesSplitAndCoalescedChunks() throws {
        let a = allMessages[1], b = allMessages[2]
        let bytes = try TeamWire.encode(a) + TeamWire.encode(b)
        var decoder = TeamWire.FrameDecoder()
        var out: [TeamMessage] = []
        for byte in bytes { out += try decoder.append(Data([byte])) }
        XCTAssertEqual(out, [a, b])
        var d2 = TeamWire.FrameDecoder()
        XCTAssertEqual(try d2.append(bytes), [a, b])
    }

    func testOversizedFrameThrows() {
        var len = UInt32(TeamWire.maxFrameBytes + 1).bigEndian
        let header = Data(bytes: &len, count: 4)
        var decoder = TeamWire.FrameDecoder()
        XCTAssertThrowsError(try decoder.append(header)) {
            XCTAssertEqual($0 as? TeamWire.WireError, .frameTooLarge)
        }
    }

    func testGarbageJSONThrowsMalformed() {
        let body = Data("not json!".utf8)
        var len = UInt32(body.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + body
        var decoder = TeamWire.FrameDecoder()
        XCTAssertThrowsError(try decoder.append(frame)) {
            XCTAssertEqual($0 as? TeamWire.WireError, .malformed)
        }
    }

    func testPresenceRoundTrip() throws {
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(presence))), [.presence(presence)])
        let away = TeamPresence(nickname: "Ash", character: mon, inPlaza: false, tile: nil, facing: nil, isWalking: false)
        var d2 = TeamWire.FrameDecoder()
        XCTAssertEqual(try d2.append(try TeamWire.encode(.presence(away))), [.presence(away)])
    }

    func testEmoteRoundTrip() throws {
        for target in ["m2", nil] as [String?] {
            let m = TeamMessage.emote(TeamEmote(kind: .party, targetMemberID: target))
            var decoder = TeamWire.FrameDecoder()
            XCTAssertEqual(try decoder.append(try TeamWire.encode(m)), [m])
        }
    }

    func testNotifyingEmotesAreOnlyHeartLolParty() {
        for kind in TeamEmoteKind.allCases {
            XCTAssertEqual(kind.notifiesTarget, [.heart, .lol, .party].contains(kind), "\(kind)")
        }
    }

    func testPresenceJSONHasOnlyPlazaFields() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["nickname", "character", "inPlaza", "tile", "facing", "isWalking"])
    }

    func testWireJSONCarriesNoUsageOrHostWords() throws {
        for m in allMessages {
            let body = try TeamWire.encode(m).dropFirst(4)
            let text = String(decoding: body, as: UTF8.self).lowercased()
            for word in ["token", "cost", "usage", "limit", "progress", "host"] {
                XCTAssertFalse(text.contains(word), "\(word) in \(text)")
            }
        }
    }
}
