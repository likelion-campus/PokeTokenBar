import XCTest
@testable import PokeTokenBar

private struct NoPraySprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// A의 keyCode.
private let prayKey: UInt16 = 0

/// 광장에서 알이 하는 기도: A 키, 내 화면의 말풍선과 흔들림, 팀원에게 보내기, 받은 기도 걸러 내기.
@MainActor
final class PlazaPrayTests: XCTestCase {
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
        let received: Received
    }

    @MainActor final class Received {
        var emotes: [TeamEmote] = []
    }

    /// 컨트롤러에 끼우는 가짜 세이브: 기도 횟수만 센다.
    @MainActor final class Prayers {
        var count = 0
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    static let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)

    func node(_ name: String, character: TeamMonSummary = PlazaPrayTests.pikachu) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.pray.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaPrayTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: character, dex: []) })
        session.updateCharacter(character)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    // MARK: - 키

    /// A prays, also with Hangul input (the character is "ㅁ"); not with Cmd/Ctrl/Opt or when held.
    func testAKeyPraysWithHangulInputOnly() async {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var presses = 0
        scene.onPrayKey = { presses += 1 }
        XCTAssertEqual(scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: false), .swallowed)
        XCTAssertEqual(presses, 1)
        scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: true)
        for mod: PlazaModifiers in [.command, .control, .option] {
            scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: false, modifiers: mod)
        }
        XCTAssertEqual(presses, 1, "a held key or a shortcut is not a prayer")
    }
}
