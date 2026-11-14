import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// 키 1–5의 keyCode. 순서는 ♥, ㅋㅋ, 🎉, !, ?.
private let heartKey: UInt16 = 18, lolKey: UInt16 = 19, partyKey: UInt16 = 20, exclaimKey: UInt16 = 21, questionKey: UInt16 = 23

@MainActor
final class PlazaEmoteTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    let map = PlazaMapData.map

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        /// 이 세션이 받은 말풍선(보낸 멤버 ID, 내용)
        let received: Received
    }

    @MainActor final class Received {
        var emotes: [(from: String, emote: TeamEmote)] = []
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    func node(_ name: String, memberID: String? = nil) -> Node {
        let suite = "plaza.emote.\(UUID())"
        let nodeDefaults = TestDefaults.make(suite: suite)
        if let memberID { nodeDefaults.set(memberID, forKey: "team.memberID") }
        let settings = TeamSettings(defaults: nodeDefaults)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaEmoteTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] id, emote in received.emotes.append((id, emote)) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    func defaults() -> UserDefaults {
        let name = "plaza.emote.prefs.\(UUID())"
        return TestDefaults.make(suite: name)
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    /// 시작 칸에서 바라보는 칸이 갈 수 있는 칸인 시작 칸.
    func startFacingDown() -> TilePoint { map.spawn }

    func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    // MARK: - 키와 그림

    func testEmoteKeysWorkWithHangulInput() async {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [TeamEmoteKind] = []
        scene.onEmoteKey = { pressed.append($0) }
        // 한글 입력기에서는 characters가 "1"이 아니다. keyCode로만 판정한다.
        for key in [heartKey, lolKey, partyKey, exclaimKey, questionKey] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false), .swallowed)
        }
        XCTAssertEqual(pressed, [.heart, .lol, .party, .exclaim, .question])
        pressed = []
        for key: UInt16 in [0, 22, 24, 49] { scene.handleKeyDown(keyCode: key, characters: "1", isRepeat: false) }
        XCTAssertEqual(pressed, [], "other keys, even with a '1' character, are not emotes")
    }

    /// Z jumps, X greets and C tackles, also with Hangul input (the characters are "ㅋ", "ㅌ", "ㅊ"); not with
    /// Cmd/Ctrl/Opt or when held. J no longer jumps.
    func testZXCKeysWorkWithHangulInputOnly() async {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [String] = []
        scene.onJumpKey = { pressed.append("jump") }
        scene.onGreetKey = { pressed.append("greet") }
        scene.onTackleKey = { pressed.append("tackle") }
        scene.onGroupPhotoKey = { pressed.append("groupPhoto") }
        for (code, hangul) in [(UInt16(6), "ㅋ"), (7, "ㅌ"), (8, "ㅊ"), (5, "ㅎ")] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: false), .swallowed)
            scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: true)
            for mod: PlazaModifiers in [.command, .control, .option] {
                scene.handleKeyDown(keyCode: code, characters: hangul, isRepeat: false, modifiers: mod)
            }
        }
        XCTAssertEqual(pressed, ["jump", "greet", "tackle", "groupPhoto"])
        scene.handleKeyDown(keyCode: 38, characters: "j", isRepeat: false)
        XCTAssertEqual(pressed, ["jump", "greet", "tackle", "groupPhoto"], "J is not a shortcut any more")
    }

    func testModifiedOrRepeatedEmoteKeysDoNotFire() async {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var pressed: [TeamEmoteKind] = []
        scene.onEmoteKey = { pressed.append($0) }
        for mod: PlazaModifiers in [.command, .control, .option, [.command, .shift]] {
            XCTAssertEqual(scene.handleKeyDown(keyCode: heartKey, characters: "1", isRepeat: false, modifiers: mod), .swallowed)
        }
        XCTAssertEqual(pressed, [], "Cmd, Ctrl and Opt combinations are not emotes")
        XCTAssertEqual(scene.handleKeyDown(keyCode: heartKey, characters: "1", isRepeat: true), .swallowed)
        XCTAssertEqual(pressed, [], "auto-repeat is not an emote")
        scene.handleKeyDown(keyCode: heartKey, characters: "!", isRepeat: false, modifiers: .shift)
        XCTAssertEqual(pressed, [.heart], "Shift still works")
    }

    func testDecoyKindsDrawNoBubble() async {
        let map = PlazaMapData.map
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        for kind in [TeamEmoteKind.decoyFound, .decoyJump] {
            scene.showEmote(memberID: nil, kind: kind)
            XCTAssertNil(scene.shownEmote(memberID: nil), "\(kind)")
        }
    }
}
