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

    /// A megaphone line reads as an ordinary line in v2.5.602 and earlier.
    func testMegaphoneFlagIsOptionalOnTheWire() throws {
        let loud = TeamMessage.chat(TeamChat(text: "점심!", isLoud: true))
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(loud)), [loud])
        let plain = String(decoding: try TeamWire.encode(.chat(TeamChat(text: "a"))).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("isLoud"))
    }

    /// A greeting reads as an ordinary targeted emote (over the sender only) in v2.5.605 and earlier.
    func testGreetingFlagIsOptionalOnTheWire() throws {
        let greeting = TeamMessage.emote(TeamEmote(kind: .heart, targetMemberID: "m", isShared: true))
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(greeting)), [greeting])
        let plain = String(decoding: try TeamWire.encode(.emote(TeamEmote(kind: .heart, targetMemberID: "m"))).dropFirst(4),
                           as: UTF8.self)
        XCTAssertFalse(plain.contains("isShared"))
        let earlier = frame(#"{"emote":{"_0":{"kind":"heart","targetMemberID":"m"}}}"#)
        var earlierDecoder = TeamWire.FrameDecoder()
        guard case .emote(let e)? = try earlierDecoder.append(earlier).first else { return XCTFail("not an emote") }
        XCTAssertNil(e.isShared)
    }

    /// A one-tile tackle leaves the push out, so it reads the same in v2.5.610 and earlier, which push one tile.
    /// Whatever a teammate sends, a tackle pushes one to three tiles.
    func testTacklePushTilesAreOptionalAndKeptInRange() throws {
        let strong = TeamMessage.emote(TeamEmote(kind: .tackle, targetMemberID: "m", pushTiles: 3))
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(strong)), [strong])
        let plain = String(decoding: try TeamWire.encode(.emote(TeamEmote(kind: .tackle, targetMemberID: "m"))).dropFirst(4),
                           as: UTF8.self)
        XCTAssertFalse(plain.contains("pushTiles"))
        let earlier = frame(#"{"emote":{"_0":{"kind":"tackle","targetMemberID":"m"}}}"#)
        var earlierDecoder = TeamWire.FrameDecoder()
        guard case .emote(let e)? = try earlierDecoder.append(earlier).first else { return XCTFail("not an emote") }
        XCTAssertNil(e.pushTiles)
        XCTAssertEqual([nil, 0, 1, 2, 3, 4, 99, -5].map(TeamEmote.pushTiles), [1, 1, 1, 2, 3, 3, 3, 1])
    }

    /// A picked name colour is sent only when there is one, and earlier versions' presence reads as none.
    func testNameColorIsOptionalOnTheWire() throws {
        var colored = presence
        colored.nameColor = 0xFF9ECF
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(colored))), [.presence(colored)])
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("nameColor"))
        let earlier = frame(#"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":false}}}"#)
        var earlierDecoder = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try earlierDecoder.append(earlier).first else { return XCTFail("not a presence") }
        XCTAssertNil(p.nameColor)
    }

    /// The shared plaza schedule is sent only when set; an unknown season period reads as a day.
    func testScheduleIsOptionalOnTheWire() throws {
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("schedule"))
        var withSchedule = presence
        withSchedule.schedule = PlazaSchedule(coreStart: 9, coreEnd: 18, seasonPeriod: "month",
                                              changedAt: Date(timeIntervalSince1970: 1_790_000_000.5),
                                              changedBy: "m1", changedByName: "Ash")
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(withSchedule))), [.presence(withSchedule)])
        let json = #"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":false,"schedule":{"coreStart":10,"coreEnd":16,"seasonPeriod":"season","changedAt":1790000000,"changedBy":"m","changedByName":"A"}}}}"#
        var d2 = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try d2.append(frame(json)).first, let sch = p.schedule else { return XCTFail("no schedule") }
        XCTAssertEqual(sch.period, .day)
    }

    /// 손으로 쓴 Codable 은 새 선택 필드를 키 목록에 빼먹어도 컴파일되지만, 합성이면 모든 필드가 오간다.
    func testEveryOptionalFieldSurvivesARoundTrip() throws {
        var full = presence
        full.tile = TilePoint(x: 3, y: 4)
        full.facing = .left
        full.isIdle = true
        full.nameColor = 0xFF9ECF
        full.isRunning = true
        full.takenItemSlot = 2
        full.focusEndsAt = Date(timeIntervalSince1970: 1_790_000_000.5)
        full.isDiving = true
        full.evolutionStage = 2
        full.schedule = PlazaSchedule(coreStart: 9, coreEnd: 18, seasonPeriod: "week",
                                      changedAt: Date(timeIntervalSince1970: 1_790_000_000.5),
                                      changedBy: "m1", changedByName: "Ash")
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(full))), [.presence(full)])
    }

    /// A schedule this version cannot read costs only the schedule, never the member's position or name.
    func testMalformedScheduleDropsOnlyTheSchedule() throws {
        let head = #"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"tile":{"x":3,"y":4},"facing":"left","isWalking":true,"nameColor":16752335,"schedule":"#
        let bad = [#"{"coreStart":"ten","coreEnd":16,"seasonPeriod":"day","changedAt":1790000000,"changedBy":"m","changedByName":"A"}"#,
                   #"{"coreStart":10,"coreEnd":16,"seasonPeriod":"day","changedAt":1790000000,"changedByName":"A"}"#]
        for schedule in bad {
            var decoder = TeamWire.FrameDecoder()
            guard case .presence(let p)? = try decoder.append(frame(head + schedule + "}}}")).first else {
                return XCTFail("presence dropped")
            }
            XCTAssertNil(p.schedule)
            XCTAssertEqual(p.nickname, "Ash")
            XCTAssertEqual(p.tile, TilePoint(x: 3, y: 4))
            XCTAssertEqual(p.facing, .left)
            XCTAssertTrue(p.isWalking)
            XCTAssertEqual(p.nameColor, 16752335)
        }
    }

    /// Running is sent only when true, and earlier versions' presence reads as walking.
    func testRunningFlagIsOptionalOnTheWire() throws {
        var running = presence
        running.isRunning = true
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(running))), [.presence(running)])
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("isRunning"))
        let earlier = frame(#"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":true}}}"#)
        var earlierDecoder = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try earlierDecoder.append(earlier).first else { return XCTFail("not a presence") }
        XCTAssertNil(p.isRunning)
    }

    /// A firework names its style. Plain emotes leave the field out, and an emote without one reads as none.
    func testFireworkStyleIsOptionalOnTheWire() throws {
        let firework = TeamMessage.emote(TeamEmote(kind: .firework, targetMemberID: nil, fireworkStyle: "willow"))
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(firework)), [firework])
        let plain = String(decoding: try TeamWire.encode(.emote(TeamEmote(kind: .heart, targetMemberID: nil))).dropFirst(4),
                           as: UTF8.self)
        XCTAssertFalse(plain.contains("fireworkStyle"))
        let noStyle = TeamMessage.emote(TeamEmote(kind: .firework, targetMemberID: nil))
        XCTAssertEqual(try decoder.append(try TeamWire.encode(noStyle)), [noStyle])
    }

    /// A pickup names its item slot, and presence carries the latest slot known taken. Both are left out when absent,
    /// and earlier versions' frames read as none.
    func testItemFieldsAreOptionalOnTheWire() throws {
        let pickup = TeamMessage.emote(TeamEmote(kind: .pickup, targetMemberID: nil, itemSlot: 160_000))
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(pickup)), [pickup])
        var picked = presence
        picked.takenItemSlot = 160_000
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(picked))), [.presence(picked)])
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("takenItemSlot"))
        let plainEmote = String(decoding: try TeamWire.encode(.emote(TeamEmote(kind: .heart, targetMemberID: nil))).dropFirst(4),
                                as: UTF8.self)
        XCTAssertFalse(plainEmote.contains("itemSlot"))
    }

    /// An idle flag is sent only when true, so v2.5.602 and earlier read every other presence byte for byte.
    func testIdleFlagIsOptionalOnTheWire() throws {
        var idle = presence
        idle.isIdle = true
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(idle))), [.presence(idle)])
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("isIdle"))
        let earlier = frame(#"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":false}}}"#)
        var earlierDecoder = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try earlierDecoder.append(earlier).first else { return XCTFail("not a presence") }
        XCTAssertNil(p.isIdle)
    }

    /// Diving and the evolution stage are sent only when true / above 1; earlier JSON without the keys still decodes.
    func testPondFieldsAreOptionalAndOmitted() throws {
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("isDiving"))
        XCTAssertFalse(plain.contains("evolutionStage"))
        var pond = presence
        pond.isDiving = true
        pond.evolutionStage = 2
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(pond))), [.presence(pond)])
        let earlier = frame(#"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":false}}}"#)
        var d2 = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try d2.append(earlier).first else { return XCTFail("not a presence") }
        XCTAssertNil(p.isDiving)
        XCTAssertNil(p.evolutionStage)
    }

    /// The focus end time is left out when nil, and v2.5.613 ignores the key.
    func testPresenceFocusIsOptionalForEarlierVersions() throws {
        let plain = String(decoding: try TeamWire.encode(.presence(presence)).dropFirst(4), as: UTF8.self)
        XCTAssertFalse(plain.contains("focusEndsAt"))
        var focused = presence
        focused.focusEndsAt = Date(timeIntervalSince1970: 1_800_000_000)
        var decoder = TeamWire.FrameDecoder()
        XCTAssertEqual(try decoder.append(try TeamWire.encode(.presence(focused))), [.presence(focused)])
        let withoutKey = frame(#"{"presence":{"_0":{"nickname":"Ash","character":{"speciesID":25,"isShiny":false,"speciesName":"P"},"inPlaza":true,"isWalking":false}}}"#)
        var d2 = TeamWire.FrameDecoder()
        guard case .presence(let p)? = try d2.append(withoutKey).first else { return XCTFail("not a presence") }
        XCTAssertNil(p.focusEndsAt)
        struct EarlierPresence: Codable {
            var nickname: String
            var character: TeamMonSummary
            var inPlaza: Bool
            var tile: TilePoint?
            var facing: PlazaDirection?
            var isWalking: Bool
            var isIdle: Bool?
            var nameColor: UInt32?
            var isRunning: Bool?
            var takenItemSlot: Int?
        }
        let body = try JSONEncoder().encode(focused)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("focusEndsAt"))
        XCTAssertEqual(try JSONDecoder().decode(EarlierPresence.self, from: body).nickname, "Ash")
    }

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
        XCTAssertEqual(TeamEmoteKind.allCases.map(\.rawValue), ["heart", "lol", "party", "exclaim", "question", "tackle", "jump", "groupPhoto", "pickup", "firework"])
        XCTAssertEqual([Rarity.common, .uncommon, .rare, .legendary].map(\.rawValue), ["common", "uncommon", "rare", "legendary"])
        XCTAssertEqual(PokemonGender.allCases.map(\.rawValue), ["male", "female", "genderless"])
        XCTAssertEqual(PlazaDirection.allCases.map(\.rawValue), ["up", "down", "left", "right"])
        XCTAssertEqual(PokemonNature.allCases.map(\.rawValue), [
            "hardy", "lonely", "brave", "adamant", "naughty", "bold", "docile", "relaxed", "impish", "lax",
            "timid", "hasty", "serious", "jolly", "naive", "modest", "mild", "quiet", "bashful", "rash",
            "calm", "gentle", "sassy", "careful", "quirky"])
    }
}
