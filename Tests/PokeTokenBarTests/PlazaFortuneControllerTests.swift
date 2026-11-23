import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Space at the fortune stall: one cookie a day, shown to teammates once, and the slip again on a later visit.
@MainActor
final class PlazaFortuneControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = PlazaFortuneControllerTests.day(23)
    private var t: TimeInterval = 0
    private let spaceKey: UInt16 = 49, dKey: UInt16 = 2

    static func day(_ day: Int, _ hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Self.day(23)
        t = 0
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor final class Received { var emotes: [TeamEmote] = [] }
    @MainActor struct Node {
        let settings: TeamSettings, session: TeamSession, transport: FakeTeamTransport, received: Received
        var id: String { settings.memberID }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.fortune.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaFortuneControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID),
                                  transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node, suite: String
        var scene: PlazaScene { c.scene! }
    }

    private func controller(_ me: Node, start: TilePoint, suite: String) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: suite))
        prefs.saveLastTile(start)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      session: me.session, clock: { [unowned self] in now },
                                      bannerSleep: { _ in try? await Task.sleep(for: .seconds(60)) },
                                      shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
        c.prepareScene()
        return c
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    /// Me in front of the stall counter (or wherever `mine` says), facing up, with teammate b connected and in the plaza.
    private func world(me mine: TilePoint = TilePoint(x: 42, y: 6), suite: String? = nil) async -> World {
        let me = node("나"), b = node("가")
        let suite = suite ?? "plaza.fortune.prefs.\(UUID())"
        let c = controller(me, start: mine, suite: suite)
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b, suite: suite)
        w.scene.face(.up)
        b.session.updatePlazaPosition(inPlaza: true, tile: p(38, 9), facing: .down, isWalking: false, isFlushed: false)
        for _ in 0..<200 where w.scene.memberTiles[b.id] != p(38, 9) { await Task.yield(); t += 0.05; w.scene.update(t) }
        run(w.scene, 0.1)
        return w
    }

    private func space(_ w: World) async {
        w.scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: false)
        await settle()
    }

    private func fortunes(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .fortune } }

    private func myDraw(_ w: World, _ date: Date) -> PlazaFortuneDraw {
        PlazaFortune.draw(day: PlazaActivity.dayKey(date), memberID: w.me.id)
    }

    func testTheFirstSpaceOfTheDayCracksTheCookieAndTellsTheTeamOnce() async throws {
        let w = await world()
        XCTAssertEqual(w.c.hint, L(.ko).plazaFortuneHint)
        await space(w)
        let draw = myDraw(w, now), text = try XCTUnwrap(PlazaFortune.text(draw))
        var shown = try XCTUnwrap(w.scene.shownFortune(memberID: nil))
        XCTAssertEqual(shown.stage, .whole, "the cookie floats up first")
        XCTAssertEqual(shown.line, text.line)
        XCTAssertEqual(shown.action, text.action)
        XCTAssertEqual(fortunes(w.b).map(\.fortune), [draw])
        XCTAssertNil(fortunes(w.b).first?.targetMemberID)
        XCTAssertEqual(w.c.overlayContent, .none, "no panel opens")
        run(w.scene, PlazaFortune.splitStart + 0.6)
        shown = try XCTUnwrap(w.scene.shownFortune(memberID: nil))
        XCTAssertEqual(shown.stage, .open)
        XCTAssertEqual(w.c.hint, L(.ko).plazaFortuneAgainHint)
        run(w.scene, PlazaFortune.readDuration)
        XCTAssertNil(w.scene.shownFortune(memberID: nil), "the slip leaves by itself")
        w.c.handleClose()
    }

    func testTheSameDayShowsOnlyTheSlipAgainAndSendsNothingMore() async throws {
        let w = await world()
        await space(w)
        run(w.scene, 9)
        XCTAssertNil(w.scene.shownFortune(memberID: nil))
        now = now.addingTimeInterval(3600)
        await space(w)
        let shown = try XCTUnwrap(w.scene.shownFortune(memberID: nil))
        XCTAssertEqual(shown.stage, .split(1), "no whole cookie this time")
        XCTAssertEqual(shown.line, PlazaFortune.text(myDraw(w, now))?.line, "the same line as this morning")
        XCTAssertEqual(fortunes(w.b).count, 1, "teammates saw it once")
        w.c.handleClose()
        // Reopening the plaza keeps the day.
        let again = controller(w.me, start: p(42, 6), suite: w.suite)
        again.scene!.face(.up)
        again.scene!.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: false)
        await settle()
        XCTAssertEqual(again.scene!.shownFortune(memberID: nil)?.stage, .split(1))
        XCTAssertEqual(fortunes(w.b).count, 1)
        again.handleClose()
    }

    func testANewDayBringsANewCookie() async throws {
        let w = await world()
        await space(w)
        run(w.scene, 9)
        now = Self.day(24, 9)
        w.c.refreshHintForTesting()   // nothing redraws the hint at midnight by itself; the next move does
        XCTAssertEqual(w.c.hint, L(.ko).plazaFortuneHint)
        await space(w)
        XCTAssertEqual(w.scene.shownFortune(memberID: nil)?.stage, .whole)
        XCTAssertEqual(fortunes(w.b).map(\.fortune), [myDraw(w, Self.day(23)), myDraw(w, Self.day(24, 9))])
        w.c.handleClose()
    }

    func testAwayFromTheStallSpaceDoesNothingForFortunes() async {
        let w = await world(me: p(42, 8))
        XCTAssertNotEqual(w.c.hint, L(.ko).plazaFortuneHint)
        await space(w)
        XCTAssertNil(w.scene.shownFortune(memberID: nil))
        XCTAssertTrue(fortunes(w.b).isEmpty)
        w.c.handleClose()
    }

    func testATeammatesCookieCracksOverThemAndABadSlipShowsNothing() async throws {
        let w = await world()
        let draw = PlazaFortuneDraw(line: 2, action: 5)
        w.c.showFortune(memberID: w.b.id, draw: draw)
        let shown = try XCTUnwrap(w.scene.shownFortune(memberID: w.b.id))
        XCTAssertEqual(shown.stage, .whole)
        XCTAssertEqual(shown.line, PlazaFortune.lines[2])
        XCTAssertNil(w.scene.shownFortune(memberID: nil), "not over me")
        XCTAssertTrue(fortunes(w.b).isEmpty, "nothing is sent back")
        run(w.scene, 9)
        w.c.showFortune(memberID: w.b.id, draw: PlazaFortuneDraw(line: PlazaFortune.lines.count, action: 0))
        XCTAssertNil(w.scene.shownFortune(memberID: w.b.id), "a line this version does not have")
        w.c.showFortune(memberID: "nobody", draw: draw)
        XCTAssertNil(w.scene.shownFortune(memberID: "nobody"))
        w.c.handleClose()
    }

    func testAChatLineOrAnEmoteReplacesTheSlip() async {
        let w = await world()
        await space(w)
        w.scene.showChat(memberID: nil, text: "안녕")
        XCTAssertNil(w.scene.shownFortune(memberID: nil))
        XCTAssertEqual(w.scene.shownChat(memberID: nil), "안녕")
        await space(w)
        XCTAssertNotNil(w.scene.shownFortune(memberID: nil))
        XCTAssertNil(w.scene.shownChat(memberID: nil), "and the slip replaces the line")
        w.scene.showEmote(memberID: nil, kind: .heart)
        XCTAssertNil(w.scene.shownFortune(memberID: nil))
        w.c.handleClose()
    }
}
