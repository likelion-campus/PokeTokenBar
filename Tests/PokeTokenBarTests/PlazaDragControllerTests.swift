import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Dragging a teammate (끌어당기기): the controller side, both the received drag and the Space menu row.
@MainActor
final class PlazaDragControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    var now = PlazaDragControllerTests.day(6)
    private var t: TimeInterval = 0
    private let map = PlazaMapData.map
    let spaceKey: UInt16 = 49, zKey: UInt16 = 6

    static func day(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Self.day(6)
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

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.drag.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaDragControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    private func controller(_ me: Node, start: TilePoint, speciesID: Int?, stage: Int) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.drag.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        // The left pond is broken (the next one is the far right pond): this class swims in the left one.
        prefs.iceBreak = PlazaIceBreak(at: now.timeIntervalSince1970, pond: TilePoint(x: 5, y: 13))
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, evolutionStage: { stage }, session: me.session, clock: { [unowned self] in now },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    /// Me at `mine` facing `facing`, teammate b (when given) at `bTile`, the plaza scene seeing both.
    func world(me mine: TilePoint, b bTile: TilePoint? = nil, facing: PlazaDirection = .right, stage: Int = 1,
               speciesID: Int? = 25) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, start: mine, speciesID: speciesID, stage: stage)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b)
        w.scene.face(facing)
        if let bTile { await place(b, bTile, in: w) }
        run(w.scene, 0.1)
        return w
    }

    func place(_ n: Node, _ tile: TilePoint, in w: World) async {
        n.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        for _ in 0..<200 where w.scene.memberTiles[n.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[n.id], tile, "test precondition")
    }

    /// A third teammate, connected to me only.
    func join(_ w: World, _ name: String, at tile: TilePoint) async -> Node {
        let n = node(name)
        hub.connect(w.me.transport, to: n.transport)
        await settle()
        await place(n, tile, in: w)
        return n
    }

    /// Teammate `n` says it has body class `size`, and my scene believes it.
    func claim(_ n: Node, size: Int, in w: World) async {
        n.session.updateBodySize(size)
        for _ in 0..<200 where w.scene.body(of: n.id)?.size != size { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.body(of: n.id)?.size, size, "test precondition")
    }

    func pull(_ w: World, from n: Node, tiles: Int = 1) { w.c.showDrag(from: n.id, on: w.me.id, tiles: tiles) }

    func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    // MARK: - A received drag

    func testADragSlidesMeToBesideThePullersNewTile() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        let dust = w.scene.dustShown
        pull(w, from: w.b, tiles: 2)
        XCTAssertEqual(w.scene.dustShown, dust + 2)
        run(w.scene, PlazaActor.lungeDuration / 2)
        XCTAssertLessThan(w.scene.lungeOffset(memberID: w.b.id)!.x, 0, "b yanks left, away from me")
        run(w.scene, 1.5)
        XCTAssertEqual(w.scene.walker.tile, p(18, 12), "b's old tile did not block me")
    }

    func testABigPullerDragsMeFromThreeTilesAway() async {
        let w = await world(me: p(17, 12))
        await claim(w.b, size: 3, in: w)
        await place(w.b, p(17, 15), in: w)
        pull(w, from: w.b)
        run(w.scene, 1.5)
        XCTAssertEqual(w.scene.walker.tile, p(17, 15))
    }

    func testTheSlideStopsBeforeSomeoneOrTheWater() async {
        let w = await world(me: p(17, 12))
        await claim(w.b, size: 3, in: w)
        await place(w.b, p(17, 15), in: w)
        _ = await join(w, "다", at: p(17, 14))
        pull(w, from: w.b)
        run(w.scene, 1.5)
        XCTAssertEqual(w.scene.walker.tile, p(17, 13))

        let pond = await world(me: p(10, 11))
        await claim(pond.b, size: 3, in: pond)
        await place(pond.b, p(10, 14), in: pond)
        pull(pond, from: pond.b)
        run(pond.scene, 1.5)
        XCTAssertEqual(pond.scene.walker.tile, p(10, 12), "stops on the shore")
    }

    // MARK: - Hostile peers

    func testADragFromOutOfReachOrOffMyLineOnlyShowsThePull() async {
        let mine = p(20, 12)
        // out of reach, in line
        let far = await world(me: mine, b: p(22, 12))
        var dust = far.scene.dustShown
        pull(far, from: far.b)
        run(far.scene, PlazaActor.lungeDuration / 2)
        XCTAssertGreaterThan(far.scene.lungeOffset(memberID: far.b.id)!.x, 0, "along the line")
        run(far.scene, 1)
        XCTAssertEqual(far.scene.walker.tile, mine)
        XCTAssertEqual(far.scene.dustShown, dust + 2)
        // touching, not on my line
        let diagonal = await world(me: mine)
        await claim(diagonal.b, size: 2, in: diagonal)
        await place(diagonal.b, p(21, 13), in: diagonal)
        dust = diagonal.scene.dustShown
        pull(diagonal, from: diagonal.b)
        run(diagonal.scene, PlazaActor.lungeDuration / 2)
        XCTAssertLessThan(diagonal.scene.lungeOffset(memberID: diagonal.b.id)!.y, 0, "opposite of b's facing")
        run(diagonal.scene, 1)
        XCTAssertEqual(diagonal.scene.walker.tile, mine)
        XCTAssertEqual(diagonal.scene.dustShown, dust + 2)
        // a class-3 claim that still does not reach
        let claimed = await world(me: mine)
        await claim(claimed.b, size: 3, in: claimed)
        await place(claimed.b, p(20, 16), in: claimed)
        dust = claimed.scene.dustShown
        pull(claimed, from: claimed.b)
        run(claimed.scene, 1)
        XCTAssertEqual(claimed.scene.walker.tile, mine)
        XCTAssertEqual(claimed.scene.dustShown, dust + 2)
    }

    func testADragOnSomeoneElseIsDrawnButMovesNobody() async {
        let w = await world(me: p(20, 12), b: p(22, 12))
        let c = await join(w, "다", at: p(21, 12))
        let dust = w.scene.dustShown
        w.c.showDrag(from: w.b.id, on: c.id, tiles: 1)
        XCTAssertEqual(w.scene.dustShown, dust + 2)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12))
        XCTAssertEqual(w.scene.memberTiles[c.id], p(21, 12), "presence moves them, not the drag")
    }

    func testAnUnknownTargetOrSenderOrTheDittoDrawsNothing() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        let dust = w.scene.dustShown, impacts = w.scene.impactsShown
        w.c.showDrag(from: w.b.id, on: nil, tiles: 1)
        w.c.showDrag(from: w.b.id, on: String(repeating: "x", count: 10_000), tiles: 3)
        w.c.showDrag(from: w.b.id, on: PlazaDitto.sceneKey, tiles: 1)
        w.c.showDrag(from: "nobody", on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.dustShown, dust)
        XCTAssertEqual(w.scene.impactsShown, impacts)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12))
    }

    func testASwimmingMeIsNotDragged() async {
        let w = await world(me: p(15, 14), b: p(18, 14), facing: .left)
        press(w.scene, zKey)
        run(w.scene, 0.5)
        XCTAssertEqual(w.scene.walker.tile, p(14, 14), "test precondition")
        XCTAssertTrue(w.scene.isMeInWater, "test precondition")
        await place(w.b, p(15, 14), in: w)
        pull(w, from: w.b)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(14, 14))
        // control: the same pull on land moves me
        let land = await world(me: p(16, 14), b: p(15, 14))
        pull(land, from: land.b)
        run(land.scene, 1)
        XCTAssertEqual(land.scene.walker.tile, p(15, 14))
    }

    private func opposite(_ d: PlazaDirection) -> PlazaDirection { d.opposite }

    private func draggedAtTheFire(focusing: Bool, menuOpen: Bool) async -> Bool {
        let w = await world(me: p(23, 14), b: nil)
        if focusing { w.c.startFocus(minutes: 25) }
        if menuOpen { press(w.scene, spaceKey) }
        XCTAssertEqual(w.c.isFocusing, focusing)
        XCTAssertEqual(w.c.isCampfireMenuOpen, menuOpen)
        let spot = w.scene.walker.tile
        guard let d = PlazaDirection.allCases.first(where: { map.isWalkable(PlazaWalker.offset(spot, $0)) }) else {
            XCTFail("no side"); return false
        }
        await place(w.b, PlazaWalker.offset(spot, d), in: w)
        pull(w, from: w.b)
        run(w.scene, 1)
        let moved = w.scene.walker.tile != spot
        w.c.handleClose()
        return moved
    }

    func testAFocusingOrMenuOpenMeIsNotDragged() async {
        let control = await draggedAtTheFire(focusing: false, menuOpen: false)
        XCTAssertTrue(control, "control: the harness really drags")
        let focusing = await draggedAtTheFire(focusing: true, menuOpen: false)
        XCTAssertFalse(focusing)
        let menu = await draggedAtTheFire(focusing: false, menuOpen: true)
        XCTAssertFalse(menu)
    }

    func testAHiddenPlazaIsStillDraggedButMakesNoDust() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        w.c.setRendering(visible: false)
        let dust = w.scene.dustShown
        pull(w, from: w.b, tiles: 2)
        XCTAssertEqual(w.scene.walker.tile, p(18, 12), "at once")
        XCTAssertEqual(w.scene.dustShown, dust, "no node on a paused scene")
    }
}
