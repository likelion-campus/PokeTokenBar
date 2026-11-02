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
            .chat(TeamChat(text: "같이 점심?")),
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

    // MARK: - Compatibility with later versions

    private func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    /// The same message with its top-level case renamed or an item of its first list rewritten.
    private func rewritten(_ m: TeamMessage, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: TeamWire.encode(m).dropFirst(4)) as? [String: Any])
        edit(&json)
        let body = try JSONSerialization.data(withJSONObject: json)
        var len = UInt32(body.count).bigEndian
        return Data(bytes: &len, count: 4) + body
    }

    func testUnknownMessageKindIsIgnoredAndLaterFramesStillDecode() throws {
        var decoder = TeamWire.FrameDecoder()
        let later = frame(#"{"hologram":{"_0":[1,2,3],"live":true}}"#)
        let known = try TeamWire.encode(.profileRequest)
        XCTAssertEqual(try decoder.append(later + known + later), [.profileRequest])
    }

    func testUnknownNestedValuesInEphemeralFramesAreIgnoredNotMalformed() throws {
        let emote = try rewritten(.emote(TeamEmote(kind: .heart, targetMemberID: nil))) { json in
            var inner = json["emote"] as! [String: Any]
            var body = inner["_0"] as! [String: Any]
            body["kind"] = "confetti"   // an emote a later version added
            inner["_0"] = body
            json["emote"] = inner
        }
        let walking = try rewritten(.presence(presence)) { json in
            var inner = json["presence"] as! [String: Any]
            var body = inner["_0"] as! [String: Any]
            body["facing"] = "sideways"
            inner["_0"] = body
            json["presence"] = inner
        }
        let chat = frame(#"{"chat":{"_0":{"sticker":7}}}"#)   // a line a later version changed
        var decoder = TeamWire.FrameDecoder()
        let known = try TeamWire.encode(.profileRequest)
        XCTAssertEqual(try decoder.append(emote + walking + chat + known), [.profileRequest])
        // Every other known key keeps failing loudly.
        let bad = frame(#"{"inventory":{"_0":"nope"}}"#)
        XCTAssertThrowsError(try decoder.append(bad))
    }

    func testUnknownItemsInEventAndReactionFramesAreSkipped() throws {
        let other = TeamEvent(id: "e2", authorID: "m1", authorNickname: "Ash", kind: .evolve, speciesID: 26,
                              fromSpeciesID: 25, speciesName: "Raichu", fromSpeciesName: "Pikachu", form: nil,
                              isShiny: false, nature: nil, rarity: .common, day: "2026-10-29", occurredAt: nil)
        let events = try rewritten(.events([event, other], live: true)) { json in
            var inner = json["events"] as! [String: Any]
            var list = inner["_0"] as! [[String: Any]]
            list[0]["kind"] = "teleport"   // a kind a later version added
            inner["_0"] = list
            json["events"] = inner
        }
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(events), [.events([other], live: true)])

        let second = TeamReaction(id: "r2", eventID: "e1", authorID: "m3", authorNickname: "Brock", kind: .lol, text: nil,
                                  createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let reactions = try rewritten(.reactions([reaction, second], live: false)) { json in
            var inner = json["reactions"] as! [String: Any]
            var list = inner["_0"] as! [[String: Any]]
            list[0]["kind"] = "sparkle"
            inner["_0"] = list
            json["reactions"] = inner
        }
        var d2 = TeamWire.FrameDecoder()
        XCTAssertEqual(try d2.append(reactions), [.reactions([second], live: false)])
    }

    func testKnownMessageWithBrokenPayloadIsStillMalformed() {
        var decoder = TeamWire.FrameDecoder()
        XCTAssertThrowsError(try decoder.append(frame(#"{"hello":{"_0":"not a hello"}}"#))) {
            XCTAssertEqual($0 as? TeamWire.WireError, .malformed)
        }
        var d2 = TeamWire.FrameDecoder()
        XCTAssertThrowsError(try d2.append(frame(#"[1,2]"#))) {
            XCTAssertEqual($0 as? TeamWire.WireError, .malformed)
        }
    }

    /// Every raw value below is part of the wire format. Changing one is a protocol change:
    /// bump `TeamWire.protocolVersion` with it, because older Macs would drop or skip what they cannot read.
    func testWireRawValuesArePinned() throws {
        XCTAssertEqual(TeamWire.protocolVersion, 1)
        XCTAssertEqual(Set(allMessages.map { m -> String in
            let json = try! JSONSerialization.jsonObject(with: TeamWire.encode(m).dropFirst(4)) as! [String: Any]
            return json.keys.first!
        }), ["hello", "inventory", "events", "reactions", "profileRequest", "presence", "emote", "profile", "chat"])
        XCTAssertEqual([TeamEventKind.hatch, .evolve, .graduate, .dittoReveal].map(\.rawValue), ["hatch", "evolve", "graduate", "dittoReveal"])
        XCTAssertEqual([TeamReactionKind.cute, .lol, .congrats, .comment].map(\.rawValue), ["cute", "lol", "congrats", "comment"])
        XCTAssertEqual(TeamEmoteKind.allCases.map(\.rawValue), ["heart", "lol", "party", "exclaim", "question"])
        XCTAssertEqual([Rarity.common, .uncommon, .rare, .legendary].map(\.rawValue), ["common", "uncommon", "rare", "legendary"])
        XCTAssertEqual(PokemonGender.allCases.map(\.rawValue), ["male", "female", "genderless"])
        XCTAssertEqual(PlazaDirection.allCases.map(\.rawValue), ["up", "down", "left", "right"])
        XCTAssertEqual(PokemonNature.allCases.map(\.rawValue), [
            "hardy", "lonely", "brave", "adamant", "naughty", "bold", "docile", "relaxed", "impish", "lax",
            "timid", "hasty", "serious", "jolly", "naive", "modest", "mild", "quiet", "bashful", "rash",
            "calm", "gentle", "sassy", "careful", "quirky"])
    }
}
