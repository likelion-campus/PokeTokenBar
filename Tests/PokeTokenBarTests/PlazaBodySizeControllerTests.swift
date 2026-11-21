import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Every species gets a plain picture of a known size, front and back, so a test picks the class by species.
private struct SizedFetcher: PlazaSpriteFetching {
    static let sizes: [Int: (Int, Int)] = [25: (50, 40), 143: (75, 60), 130: (102, 90), 132: (40, 40)]
    private func image(_ w: Int, _ h: Int) -> PlazaImage {
        PlazaImage(bitmap: PlazaTestImages.solid(width: w, height: h, PlazaRGBA(r: 255, g: 0, b: 0, a: 255)))
    }
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        let s = Self.sizes[speciesID] ?? (40, 40)
        return image(s.0, s.1)
    }
    func egg() async -> PlazaImage? { image(80, 80) }
}

/// Body size in the plaza controller: what I measure and send, what the scene knows, and what the rules do with it.
@MainActor
final class PlazaBodySizeControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    /// A snow day (V throws only then).
    private var now = PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
    private var t: TimeInterval = 0
    private let map = PlazaMapData.map

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        t = 0
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        let received: Received
        var id: String { settings.memberID }
    }
    @MainActor final class Received { var emotes: [TeamEmote] = [] }
    @MainActor final class Subject { var value: CompanionStore.RepresentativeSubject
        init(_ speciesID: Int?) { value = .init(speciesID: speciesID, isShiny: false) }
    }

    private func mon(_ id: Int) -> TeamMonSummary { TeamMonSummary(speciesID: id, isShiny: false, form: nil, speciesName: "M\(id)", gender: nil) }

    private func node(_ name: String, species: Int = 25) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.bodysize.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBodySizeControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let character = mon(species)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: character, dex: []) })
        session.updateCharacter(character)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    private func controller(_ me: Node, start: TilePoint, subject: Subject, fetcher: PlazaSpriteFetching = SizedFetcher(),
                            stage: Int = 1) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.bodysize.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        prefs.iceBreak = PlazaIceBreak(at: now.timeIntervalSince1970, pond: TilePoint(x: 5, y: 13))
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: fetcher),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { subject.value },
                                     myRosterEntry: { nil }, evolutionStage: { stage }, session: me.session, clock: { [unowned self] in now },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node, subject: Subject
        var scene: PlazaScene { c.scene! }
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    /// Me (species `mine`, measured) at `mineTile`; teammate b (species `theirs`) at `bTile` when given.
    private func world(me mineTile: TilePoint, species mine: Int? = 25, b bTile: TilePoint? = nil, theirs: Int = 25,
                       bSize: Int? = nil, facing: PlazaDirection = .right, measure: Bool = true,
                       fetcher: PlazaSpriteFetching = SizedFetcher()) async -> World {
        let me = node("나", species: mine ?? 25), b = node("가", species: theirs)
        let subject = Subject(mine)
        let c = controller(me, start: mineTile, subject: subject, fetcher: fetcher)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b, subject: subject)
        if measure { await c.refreshCharacter(); await settle() }
        w.scene.face(facing)
        if let bSize { b.session.updateBodySize(bSize) }
        if let bTile { await place(w, bTile) }
        run(w.scene, 0.1)
        return w
    }

    private func place(_ w: World, _ tile: TilePoint) async {
        w.b.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
    }

    private func lastSentSize(_ n: Node) -> Int? {
        let presences = n.transport.sent.compactMap { s -> TeamPresence? in
            if case .presence(let p) = s.message { return p }
            return nil
        }
        return presences.last?.bodySize
    }

    // MARK: - What I send

    func testMySizeIsSentWhenMyPictureArrivesAndAgainWhenItChanges() async {
        let w = await world(me: p(17, 9), species: 130)
        XCTAssertEqual(w.c.myBodySize, 3)
        XCTAssertEqual(w.scene.myBody.size, 3)
        XCTAssertEqual(lastSentSize(w.me), 3)
        XCTAssertEqual(w.b.session.members[w.me.id]?.bodySize, 3)

        w.subject.value = .init(speciesID: 25, isShiny: false)
        await w.c.refreshCharacter(); await settle()
        XCTAssertEqual(w.c.myBodySize, 1)
        XCTAssertNil(lastSentSize(w.me))
        XCTAssertEqual(w.b.session.members[w.me.id]?.bodySize, 1)

        w.subject.value = .init(speciesID: 143, isShiny: false)
        await w.c.refreshCharacter(); await settle()
        XCTAssertEqual(w.c.myBodySize, 2)
        XCTAssertEqual(lastSentSize(w.me), 2)
        XCTAssertEqual(w.b.session.members[w.me.id]?.bodySize, 2)
    }

    func testAPlaceholderOrAnEggSendsNoSize() async {
        let w = await world(me: p(17, 9), species: 25, fetcher: EmptyFetcher())
        XCTAssertEqual(w.c.myBodySize, 1)
        XCTAssertNil(lastSentSize(w.me))
        let e = await world(me: p(17, 9), species: nil)
        XCTAssertEqual(e.c.myBodySize, 1)
        XCTAssertNil(lastSentSize(e.me))
    }

    func testMyDisguiseSendsTheSizeOfTheLookIShow() async {
        let w = await world(me: p(17, 9), species: 132, b: p(17, 8), theirs: 130, facing: .up)
        XCTAssertEqual(w.c.myBodySize, 1, "a Ditto is class 1 before it copies")
        w.scene.handleKeyDown(keyCode: 8, characters: "ㅊ", isRepeat: false)   // C
        await settle()
        await w.c.refreshCharacter(); await settle()
        XCTAssertEqual(w.c.mimicking, w.b.id)
        XCTAssertEqual(w.c.myBodySize, 3)
        XCTAssertEqual(lastSentSize(w.me), 3)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)   // being found ends the disguise
        run(w.scene, 1)
        await settle()
        await w.c.refreshCharacter(); await settle()
        XCTAssertNil(w.c.mimicking)
        XCTAssertEqual(w.c.myBodySize, 1)
        XCTAssertNil(lastSentSize(w.me))
    }

    // MARK: - What the scene knows

    func testATeammatesSizeIsWhatTheySentNeverTheirPictureHere() async {
        let w = await world(me: p(17, 9), b: p(17, 12), theirs: 130)
        XCTAssertEqual(w.scene.body(of: w.b.id)?.size, 1, "my fetcher draws them 102×90, but they sent nothing")
        w.b.session.updateBodySize(2)
        await settle()
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.body(of: w.b.id)?.size, 2)
    }

    func testANewSceneStartsFromMyLastSize() async {
        let w = await world(me: p(17, 9), species: 130)
        XCTAssertEqual(w.c.myBodySize, 3)
        w.c.handleClose()
        w.c.prepareScene()
        XCTAssertEqual(w.c.scene?.myBodySize, 3)
    }

    // MARK: - Reach by body

    private func press(_ w: World, _ key: UInt16, _ chars: String = "ㅁ") {
        w.scene.handleKeyDown(keyCode: key, characters: chars, isRepeat: false)
    }

    func testABigTacklerPushesMeFromThreeBelowButNotFour() async {
        let w = await world(me: p(17, 9), b: p(17, 12), bSize: 3)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(17, 8))

        let f = await world(me: p(17, 9), b: p(17, 13), bSize: 3)
        let before = f.scene.impactsShown
        f.c.showTackle(from: f.b.id, on: f.me.id, tiles: 1)
        run(f.scene, 1)
        XCTAssertEqual(f.scene.walker.tile, p(17, 9))
        XCTAssertEqual(f.scene.impactsShown, before + 1)
    }

    func testMyBigBodyIsTackledFromThreeAbove() async {
        let w = await world(me: p(17, 12), species: 130, b: p(17, 9))
        XCTAssertEqual(w.c.myBodySize, 3, "test precondition")
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(17, 13))
    }

    func testTheHintSpaceXAndCAllPickTheBigReach() async {
        let w = await world(me: p(17, 12), species: 130, b: p(17, 9), facing: .down)
        XCTAssertEqual(w.c.hint, L(.ko).plazaMemberHint(nickname: "가"))
        press(w, 49, " ")
        await settle()
        XCTAssertEqual(w.c.overlayContent, .memberMenu(PlazaMemberMenu(memberID: w.b.id, nickname: "가")))
        XCTAssertEqual(w.scene.walker.facing, .up)
        press(w, 53, "\u{1b}")
        await settle()
        press(w, 7, "ㅌ")   // X
        await settle()
        XCTAssertTrue(w.b.received.emotes.contains { $0.isShared == true && $0.targetMemberID == w.b.id })
        w.scene.face(.down)
        run(w.scene, 1)
        now = now.addingTimeInterval(5)   // past the emote rate limit
        press(w, 8, "ㅊ")   // C
        await settle()
        XCTAssertTrue(w.b.received.emotes.contains { $0.kind == .tackle && $0.targetMemberID == w.b.id })
    }

    func testATeammatesNewSizeMovesTheHintWithoutAStep() async {
        let w = await world(me: p(17, 9), b: p(17, 12), facing: .up)
        let hint = L(.ko).plazaMemberHint(nickname: "가")
        XCTAssertNotEqual(w.c.hint, hint)
        w.b.session.updateBodySize(3)
        await settle()
        run(w.scene, 0.1)
        XCTAssertEqual(w.c.hint, hint)
        XCTAssertEqual(w.scene.walker.tile, p(17, 9))
    }

    // MARK: - Throws

    func testVHitsABigTeammateOneRowOff() async {
        let w = await world(me: p(12, 11), b: p(17, 12), bSize: 3, facing: .right)
        press(w, 9)   // V
        await settle()
        XCTAssertEqual(w.b.received.emotes.filter { $0.kind == .snowball }.first?.targetMemberID, w.b.id)
        XCTAssertEqual(w.c.activity.snowballHits, 0, "still in the air")
        run(w.scene, 1)
        XCTAssertEqual(w.c.activity.snowballHits, 1)

        let s = await world(me: p(12, 11), b: p(17, 12), facing: .right)
        press(s, 9)
        await settle()
        let sent = s.b.received.emotes.filter { $0.kind == .snowball }
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent.first?.targetMemberID)
    }

    func testABallOneRowOffHitsMyBigBodyUnlessItLeavesTheEndTile() async {
        let w = await world(me: p(17, 12), species: 130, b: p(12, 11))
        XCTAssertEqual(w.c.myBodySize, 3, "test precondition")
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .right)
        run(w.scene, 1.2)
        XCTAssertEqual(w.scene.walker.tile, p(18, 12))

        let away = await world(me: p(17, 12), species: 130, b: p(12, 11))
        away.c.showSnowball(from: away.b.id, on: away.me.id, tiles: 1, direction: .right)
        away.scene.pushMe(.right)
        run(away.scene, 1.2)
        XCTAssertEqual(away.scene.walker.tile, p(18, 12), "my body no longer covers the end tile (16,11)")

        let stay = await world(me: p(17, 12), species: 130, b: p(12, 11))
        stay.c.showSnowball(from: stay.b.id, on: stay.me.id, tiles: 1, direction: .right)
        stay.scene.pushMe(.left)
        run(stay.scene, 1.2)
        XCTAssertEqual(stay.scene.walker.tile, p(17, 12), "still covers (16,11), so the ball pushes me back")
    }
}
