import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

private let returnKey: UInt16 = 36, keypadEnterKey: UInt16 = 76, rightKey: UInt16 = 124

final class TeamChatTextTests: XCTestCase {
    func testPreparedMakesOneTrimmedLine() async {
        XCTAssertEqual(TeamChat.prepared("  안녕  "), "안녕")
        XCTAssertEqual(TeamChat.prepared("a\nb\r\nc\td"), "a b c d")
        XCTAssertEqual(TeamChat.prepared("a\u{2028}b"), "a b")
        XCTAssertNil(TeamChat.prepared(""))
        XCTAssertNil(TeamChat.prepared(" \n\t "))
    }

    func testPreparedCutsToTheLimitWithoutEndingOnASpace() async {
        let max = TeamChat.maxCharacters
        XCTAssertEqual(TeamChat.prepared(String(repeating: "가", count: max + 10)), String(repeating: "가", count: max))
        let cut = String(repeating: "a", count: max - 1) + " bbb"
        XCTAssertEqual(TeamChat.prepared(cut), String(repeating: "a", count: max - 1))
    }

    func testPreparedKeepsJoinedEmojiAndRejectsAnEndlessCharacter() async {
        let family = "👨‍👩‍👧"
        XCTAssertEqual(TeamChat.prepared(family), family)
        // Two bytes a mark: one Character twice as big as the byte limit.
        XCTAssertNil(TeamChat.prepared("a" + String(repeating: "\u{0301}", count: TeamChat.maxBytes)))
    }

    func testPreparedCutsLongJoinedEmojiInsteadOfLosingTheLine() async throws {
        // 11 bytes each: within the character limit, over the byte limit.
        let line = String(repeating: "👩‍💻", count: TeamChat.maxCharacters)
        XCTAssertGreaterThan(line.utf8.count, TeamChat.maxBytes)
        let cut = try XCTUnwrap(TeamChat.prepared(line))
        XCTAssertLessThanOrEqual(cut.utf8.count, TeamChat.maxBytes)
        XCTAssertTrue(line.hasPrefix(cut))
        XCTAssertEqual(TeamChat.prepared(cut), cut)
    }

    func testPreparedRemovesInvisibleFormatCharacters() async {
        XCTAssertNil(TeamChat.prepared("\u{200B}\u{FEFF}\u{2060}"), "an empty bubble is not a line")
        XCTAssertEqual(TeamChat.prepared("a\u{202E}b"), "a b", "text direction cannot be overridden")
    }

    func testPreparedLineIsStable() async throws {
        let once = try XCTUnwrap(TeamChat.prepared("  한 줄\n더 \t"))
        XCTAssertEqual(TeamChat.prepared(once), once, "a sent line must pass the receiver's check")
    }
}

final class PlazaChatBubbleTests: XCTestCase {
    func testLongLineWrapsInsideTheLimit() async throws {
        let short = try XCTUnwrap(PlazaChatBubble.image(text: "안녕", scale: 2))
        let long = try XCTUnwrap(PlazaChatBubble.image(text: String(repeating: "가", count: TeamChat.maxCharacters), scale: 2))
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThan(short.height, long.height, "the long line wraps")
        XCTAssertLessThanOrEqual(CGFloat(long.width), PlazaChatBubble.maxSize.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(long.height), PlazaChatBubble.maxSize.height * 2)
    }

    func testEveryLineInTheLimitIsDrawnInFull() async {
        let max = TeamChat.maxCharacters
        let lines = [String(repeating: "가", count: max), String(repeating: "😀", count: max), String(repeating: "🇰🇷", count: max),
                     String(repeating: "가😀", count: max / 2), String(repeating: "W", count: max), String(repeating: "가 ", count: max / 2)]
        for line in lines {
            XCTAssertEqual(PlazaChatBubble.drawnLength(of: line), line.utf16.count, line)
        }
    }

    func testOneHugeCharacterCannotGrowTheImage() async throws {
        let text = "a" + String(repeating: "\u{0301}", count: 150)
        let image = try XCTUnwrap(PlazaChatBubble.image(text: text, scale: 2))
        XCTAssertLessThanOrEqual(CGFloat(image.width), PlazaChatBubble.maxSize.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(image.height), PlazaChatBubble.maxSize.height * 2)
    }
}

@MainActor
final class PlazaChatTests: XCTestCase {
    var hub: FakeTransportHub!
    nonisolated(unsafe) private var dirs: [URL] = []
    private var code: TeamCode!
    var now = Date(timeIntervalSince1970: 1_700_000_000)

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
        let feed: TeamFeedStore
        let received: Received
    }

    @MainActor final class Received {
        var lines: [(from: String, text: String)] = []
        var loud: [String] = []
    }

    func node(_ name: String) -> Node {
        let suite = "plaza.chat.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaChatTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
        session.updateCharacter(mon)
        session.applySettings()
        let received = Received()
        session.onChat = { [received] id, text, loud in
            received.lines.append((id, text))
            if loud { received.loud.append(text) }
        }
        return Node(settings: settings, session: session, transport: transport, feed: feed, received: received)
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    func testWideBubbleStaysOnScreenButFollowsAnOffscreenName() async {
        let viewport = CGSize(width: 400, height: 300), size = CGSize(width: 180, height: 60)
        let left = PlazaActor.chatBubbleOrigin(CGPoint(x: -260, y: 0), size: size, plate: CGPoint(x: -190, y: 0), viewport: viewport)
        XCTAssertEqual(left.x, -196)
        let right = PlazaActor.chatBubbleOrigin(CGPoint(x: 100, y: 0), size: size, plate: CGPoint(x: 190, y: 0), viewport: viewport)
        XCTAssertEqual(right.x, 16)
        let top = PlazaActor.chatBubbleOrigin(CGPoint(x: 0, y: 120), size: size, plate: CGPoint(x: 0, y: 100), viewport: viewport)
        XCTAssertEqual(top.y, 86)
        let inside = CGPoint(x: -40, y: -20)
        XCTAssertEqual(PlazaActor.chatBubbleOrigin(inside, size: size, plate: .zero, viewport: viewport), inside)
        let away = CGPoint(x: -400, y: 0)
        XCTAssertEqual(PlazaActor.chatBubbleOrigin(away, size: size, plate: CGPoint(x: -320, y: 0), viewport: viewport), away)
    }
}
