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
        // The left pond is broken (the next one is the bottom pond): this class swims in the left one.
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

    /// The target slides as far as the puller stepped back, so the two keep the arrangement they stood in (a class-3 puller three
    /// feet away stays three feet away).
    func testIMoveAsFarAsThePullerSteppedAndKeepMyPlace() async {
        let w = await world(me: p(17, 12))
        await claim(w.b, size: 3, in: w)
        await place(w.b, p(17, 15), in: w)
        pull(w, from: w.b)
        run(w.scene, 1.5)
        await place(w.b, p(17, 16), in: w)   // it stepped back one tile
        XCTAssertEqual(w.scene.walker.tile, p(17, 13))
        XCTAssertTrue(w.scene.myBody.touches(w.scene.body(of: w.b.id)!))
    }

    func testTheSlideStopsBeforeSomeoneOrTheWater() async {
        // along row 12: a class-3 puller at (22,12) covers x 21...23; I would slide three tiles but someone stands at (22,12)
        let w = await world(me: p(20, 12))
        await claim(w.b, size: 3, in: w)
        await place(w.b, p(22, 12), in: w)
        _ = await join(w, "다", at: p(22, 13))
        _ = await join(w, "라", at: p(21, 12))
        pull(w, from: w.b, tiles: 3)
        run(w.scene, 1.5)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12), "the first tile is taken")

        let pond = await world(me: p(10, 11))
        await claim(pond.b, size: 3, in: pond)
        await place(pond.b, p(10, 14), in: pond)
        pull(pond, from: pond.b, tiles: 3)
        run(pond.scene, 1.5)
        XCTAssertEqual(pond.scene.walker.tile, p(10, 12), "stops on the shore")
    }

    /// A tile with room along all four directions.
    private func clearing() -> TilePoint? {
        for y in 8..<(PlazaMapData.map.height - 8) { for x in 8..<(PlazaMapData.map.width - 8) {
            let c = p(x, y)
            // a plus: each arm eight long and five wide, for the bodies and the sliding along each direction
            let plus = (-8...8).allSatisfy { a in (-2...2).allSatisfy { cross in
                map.isWalkable(p(x + a, y + cross)) && map.isWalkable(p(x + cross, y + a)) } }
            if plus { return c }
        } }
        return nil
    }

    /// Every class of puller and of me, in every direction, for a step back of one and of three: with the puller at its stepped-back
    /// tile, I moved exactly as far and stand where I stood relative to it.
    private func assertKeepsMyPlace(puller pc: Int, me mc: Int) async throws {
        // one test opens at most `TestDefaults.maxNamesPerTest` suites: eight worlds of three here
        let centre = try XCTUnwrap(clearing(), "test precondition: a clearing on the map")
        for b in PlazaDirection.allCases { for k in [1, 3] {
            let name = "puller \(pc) me \(mc) \(b) k \(k)"
            let w = await world(me: centre)
            w.scene.myBodySize = mc
            await claim(w.b, size: pc, in: w)
            let foot = PlazaWalker.offset(centre, b)
            await place(w.b, foot, in: w)
            XCTAssertTrue(w.scene.myBody.touches(w.scene.body(of: w.b.id)!), "\(name): test precondition")
            pull(w, from: w.b, tiles: k)
            run(w.scene, 2)
            var stepped = foot, moved = centre
            for _ in 0..<k { stepped = PlazaWalker.offset(stepped, b) }
            for _ in 0..<k { moved = PlazaWalker.offset(moved, b) }
            await place(w.b, stepped, in: w)
            XCTAssertEqual(w.scene.walker.tile, moved, "\(name): I moved as far as it stepped")
            XCTAssertTrue(w.scene.myBody.touches(w.scene.body(of: w.b.id)!), name)
        } }
    }

    func testIKeepMyPlaceBesideThePullerPuller1Me1() async throws { try await assertKeepsMyPlace(puller: 1, me: 1) }
    func testIKeepMyPlaceBesideThePullerPuller1Me2() async throws { try await assertKeepsMyPlace(puller: 1, me: 2) }
    func testIKeepMyPlaceBesideThePullerPuller1Me3() async throws { try await assertKeepsMyPlace(puller: 1, me: 3) }
    func testIKeepMyPlaceBesideThePullerPuller2Me1() async throws { try await assertKeepsMyPlace(puller: 2, me: 1) }
    func testIKeepMyPlaceBesideThePullerPuller2Me2() async throws { try await assertKeepsMyPlace(puller: 2, me: 2) }
    func testIKeepMyPlaceBesideThePullerPuller2Me3() async throws { try await assertKeepsMyPlace(puller: 2, me: 3) }
    func testIKeepMyPlaceBesideThePullerPuller3Me1() async throws { try await assertKeepsMyPlace(puller: 3, me: 1) }
    func testIKeepMyPlaceBesideThePullerPuller3Me2() async throws { try await assertKeepsMyPlace(puller: 3, me: 2) }
    func testIKeepMyPlaceBesideThePullerPuller3Me3() async throws { try await assertKeepsMyPlace(puller: 3, me: 3) }

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

    // MARK: - The Space menu row

    private let downKey: UInt16 = 125

    func menu(_ w: World) -> PlazaMemberMenu? {
        if case .memberMenu(let m) = w.c.overlayContent { m } else { nil }
    }

    func drags(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .drag } }

    func testTheMenuListsDragBetweenTackleAndFollow() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        press(w.scene, spaceKey)
        XCTAssertEqual(menu(w)?.actions, [.greet, .tackle, .drag, .follow, .viewCard])
        press(w.scene, downKey)
        press(w.scene, downKey)
        XCTAssertEqual(menu(w)?.selection, .drag)
    }

    /// The recorded tile is where b saw me when the drag arrived.
    @MainActor private final class Seen { var tiles: [TilePoint?] = [] }

    func testChoosingDragSendsItFirstThenStepsMeBack() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left, stage: 2)
        let seen = Seen()
        let b = w.b, me = w.me
        b.session.onEmote = { [seen, b] _, e in
            b.received.emotes.append(e)
            if e.kind == .drag { seen.tiles.append(b.session.members[me.id]?.tile) }
        }
        w.c.setRendering(visible: false)   // pushMe reports at once, so the order on the wire is visible
        w.c.chooseMenu(.drag, memberID: w.b.id)
        await settle()
        XCTAssertEqual(drags(w.b), [TeamEmote(kind: .drag, targetMemberID: w.b.id, pushTiles: 2)])
        XCTAssertEqual(seen.tiles, [p(20, 12)], "b saw my tile from before the step")
        XCTAssertEqual(w.scene.walker.tile, p(22, 12))
        XCTAssertEqual(w.scene.walker.facing, .left)
        XCTAssertEqual(w.c.activity.tackles, 0)
    }

    func testMyPullShowsOnMyScreen() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        let dust = w.scene.dustShown
        press(w.scene, spaceKey)
        press(w.scene, downKey)
        press(w.scene, downKey)
        press(w.scene, spaceKey)
        XCTAssertEqual(w.scene.dustShown, dust + 2)
        run(w.scene, PlazaActor.lungeDuration / 2)
        XCTAssertGreaterThan(w.scene.lungeOffset(memberID: nil)!.x, 0, "I lunge away from b")
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12))
    }

    func testAShortStepBackSendsWhatIStepped() async {
        let w = await world(me: p(36, 10), b: p(35, 10), facing: .left, stage: 3)
        w.c.chooseMenu(.drag, memberID: w.b.id)
        run(w.scene, 1.5)
        await settle()
        XCTAssertEqual(drags(w.b).first?.pushTiles, 2)
        XCTAssertEqual(w.scene.walker.tile, p(38, 10))
    }

    func testNoDragWhenICannotStepBack() async {
        func assertTackleOnly(_ name: String, _ w: World) {
            press(w.scene, spaceKey)
            XCTAssertTrue(menu(w)?.actions.contains(.tackle) == true, "\(name): the menu opened")
            XCTAssertFalse(menu(w)?.actions.contains(.drag) == true, name)
        }
        assertTackleOnly("a tree behind me", await world(me: p(44, 12), b: p(43, 12), facing: .left))
        assertTackleOnly("a bush behind me", await world(me: p(38, 10), b: p(37, 10), facing: .left))
        assertTackleOnly("the pond behind me", await world(me: p(10, 12), b: p(10, 11), facing: .up))
        let crowded = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        _ = await join(crowded, "다", at: p(21, 12))
        assertTackleOnly("someone behind me", crowded)
    }

    func testNoDragForAnEgg() async {
        let egg = await world(me: p(20, 12), b: p(19, 12), facing: .left, speciesID: nil)
        press(egg.scene, spaceKey)
        XCTAssertEqual(menu(egg)?.actions, [.greet, .tackle, .viewCard])
        let control = await world(me: p(20, 12), b: p(19, 12), facing: .left, speciesID: 25)
        press(control.scene, spaceKey)
        XCTAssertTrue(menu(control)?.actions.contains(.drag) == true)
    }

    func testNoDragWhileISwimEvenWithLandBehindMe() async {
        let w = await world(me: p(10, 12), facing: .down)
        press(w.scene, zKey)
        run(w.scene, 0.5)
        XCTAssertEqual(w.scene.walker.tile, p(10, 13), "test precondition")
        XCTAssertTrue(w.scene.isMeInWater, "test precondition")
        w.scene.myBodySize = 3
        await claim(w.b, size: 3, in: w)
        await place(w.b, p(10, 16), in: w)
        XCTAssertEqual(PlazaDrag.direction(puller: w.scene.myBody, target: w.scene.body(of: w.b.id)!), .up, "test precondition")
        XCTAssertEqual(PlazaDrag.stepBack(from: p(10, 13), direction: .up, stage: 1, isOpen: { PlazaMapData.map.isWalkable($0) }), 1, "test precondition")
        press(w.scene, spaceKey)
        XCTAssertTrue(menu(w)?.actions.contains(.tackle) == true, "the menu opened")
        XCTAssertFalse(menu(w)?.actions.contains(.drag) == true)
    }

    func testADittoMeStillDragsNormally() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left, speciesID: 132)
        press(w.scene, spaceKey)
        XCTAssertTrue(menu(w)?.actions.contains(.drag) == true)
        w.c.chooseMenu(.drag, memberID: w.b.id)
        await settle()
        XCTAssertEqual(drags(w.b).count, 1)
        XCTAssertFalse(w.b.received.emotes.contains { $0.kind == .mimicTackle })
        XCTAssertNil(w.c.mimicking)
    }

    func testAChangedLayoutAtChoiceTimeDoesNothing() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        press(w.scene, spaceKey)
        XCTAssertTrue(menu(w)?.actions.contains(.drag) == true, "test precondition")
        _ = await join(w, "다", at: p(21, 12))
        w.c.chooseMenu(.drag, memberID: w.b.id)
        run(w.scene, 1)
        await settle()
        XCTAssertTrue(drags(w.b).isEmpty)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12))
    }

    func testDragSharesTheTackleRateLimit() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        press(w.scene, 8)   // C
        w.c.chooseMenu(.drag, memberID: w.b.id)
        await settle()
        XCTAssertEqual(w.b.received.emotes.filter { $0.kind == .tackle }.count, 1, "test precondition")
        XCTAssertTrue(drags(w.b).isEmpty)
        now = now.addingTimeInterval(0.31)   // 0.3 itself is lost to Date's rounding at this magnitude
        w.c.chooseMenu(.drag, memberID: w.b.id)
        await settle()
        XCTAssertEqual(drags(w.b).count, 1)
    }

    // MARK: - Receive cooldown

    func testTwoTacklesFromOneTeammateUnderASecondApartPushMeOnce() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        let t0 = now, impacts = w.scene.impactsShown
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12))
        await place(w.b, p(20, 12), in: w)
        now = t0.addingTimeInterval(0.99)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12))
        XCTAssertEqual(w.scene.impactsShown, impacts + 2, "the star shows both times")
    }

    func testTwoTacklesASecondApartPushMeTwice() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        let t0 = now
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        await place(w.b, p(20, 12), in: w)
        now = t0.addingTimeInterval(1.0)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(22, 12))
    }

    /// After b's tackle at t0 moved me to (21,12), what a second move from b at `after` seconds does.
    private func tackleThen(_ follow: (World) async -> Void, after: TimeInterval, me mine: TilePoint = TilePoint(x: 20, y: 12),
                            b bTile: TilePoint = TilePoint(x: 19, y: 12)) async -> World {
        let w = await world(me: mine, b: bTile)
        let t0 = now
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        now = t0.addingTimeInterval(after)
        await follow(w)
        return w
    }

    func testASnowballPullOrDragWithinASecondOfATackleDoesNotMoveMe() async {
        // snowball
        let ball: (World) async -> Void = { w in
            await self.place(w.b, self.p(17, 12), in: w)
            w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .right)
            self.run(w.scene, 1.2)
        }
        var w = await tackleThen(ball, after: 0.99)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12), "snowball within a second")
        XCTAssertGreaterThan(w.scene.impactsShown, 1, "the snowball still bursts")
        w = await tackleThen(ball, after: 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(22, 12), "snowball control")
        // underwater pull: b swims at (14,14); its tackle puts me at (16,14)
        let under: (World) async -> Void = { w in
            w.c.showPull(from: w.b.id, on: w.me.id)
            self.run(w.scene, 1)
        }
        w = await tackleThen(under, after: 0.99, me: p(15, 14), b: p(14, 14))
        XCTAssertEqual(w.scene.walker.tile, p(16, 14), "pull within a second")
        w = await tackleThen(under, after: 1.0, me: p(15, 14), b: p(14, 14))
        XCTAssertEqual(w.scene.walker.tile, p(14, 14), "pull control: in the water")
        XCTAssertTrue(w.scene.isMeInWater)
        // drag
        let dragged: (World) async -> Void = { w in
            await self.place(w.b, self.p(20, 12), in: w)
            let dust = w.scene.dustShown
            self.pull(w, from: w.b)
            self.run(w.scene, 1)
            XCTAssertGreaterThan(w.scene.dustShown, dust, "the pull still draws")
        }
        w = await tackleThen(dragged, after: 0.99)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12), "drag within a second")
        w = await tackleThen(dragged, after: 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12), "drag control")
    }

    func testAnotherTeammatesMoveIsNotHeldByTheFirstOnesSecond() async {
        let w = await world(me: p(20, 12), b: p(19, 12))
        let t0 = now
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12), "test precondition")
        let c = await join(w, "다", at: p(20, 12))
        now = t0.addingTimeInterval(0.5)
        w.c.showTackle(from: c.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(22, 12))
    }

    func testAnAttemptFromOutOfReachDoesNotStartTheSecond() async {
        let w = await world(me: p(20, 12), b: p(18, 12))
        let t0 = now
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(20, 12))
        await place(w.b, p(19, 12), in: w)
        now = t0.addingTimeInterval(0.1)
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12))
    }

    // MARK: - Hostile peers

    func testAHundredHitsASecondFromOneTeammateMoveMeOnceASecond() async {
        let w = await world(me: p(8, 12), b: p(4, 12))
        w.c.setRendering(visible: false)   // a hidden plaza lands each ball at once and pushes at once
        let t0 = now
        var moved: [Int] = []
        var last = w.scene.walker.tile
        for i in 0..<200 {
            now = t0.addingTimeInterval(Double(i) / 100)
            w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .right)
            if w.scene.walker.tile != last { moved.append(i); last = w.scene.walker.tile }
        }
        XCTAssertEqual(moved, [0, 100])
        XCTAssertEqual(w.scene.walker.tile, p(10, 12))
    }

    // MARK: - A move that went nowhere

    /// A move that went nowhere (a wall, someone in the way) never started the second: a drag from the same teammate at once still moves me.
    func testATackleIntoAWallDoesNotUseUpTheSecond() async {
        let w = await world(me: p(44, 12), b: p(43, 12))   // the tree at (45,12)
        let t0 = now
        w.c.showTackle(from: w.b.id, on: w.me.id, tiles: 1)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(44, 12), "test precondition: the wall stopped it")
        now = t0.addingTimeInterval(0.1)
        pull(w, from: w.b)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(43, 12))
    }

    func testASnowballIntoAWallDoesNotUseUpTheSecond() async {
        let w = await world(me: p(44, 12), b: p(40, 12))
        let t0 = now
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .right)
        run(w.scene, 1.2)
        XCTAssertEqual(w.scene.walker.tile, p(44, 12), "test precondition: the wall stopped it")
        await place(w.b, p(43, 12), in: w)
        now = t0.addingTimeInterval(0.1)
        pull(w, from: w.b)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(43, 12))
    }

    func testABlockedUnderwaterPullDoesNotUseUpTheSecond() async {
        let w = await world(me: p(16, 14), b: p(14, 14))   // b in the pond
        let c = await join(w, "다", at: p(15, 14))        // in the way
        let t0 = now
        w.c.showPull(from: w.b.id, on: w.me.id)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(16, 14), "test precondition: c blocked it")
        await place(c, p(18, 14), in: w)
        await place(w.b, p(15, 14), in: w)
        now = t0.addingTimeInterval(0.1)
        pull(w, from: w.b)
        run(w.scene, 1)
        XCTAssertEqual(w.scene.walker.tile, p(15, 14))
    }

    // MARK: - The row follows the Space target

    /// The menu's drag row is judged for the teammate Space opened the menu on, and choosing it drags that same teammate.
    func testTheDragRowIsForTheTeammateSpaceOpenedTheMenuOn() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        let c = await join(w, "다", at: p(20, 13))
        press(w.scene, spaceKey)
        XCTAssertEqual(menu(w)?.memberID, w.b.id)
        XCTAssertTrue(menu(w)?.actions.contains(.drag) == true)
        press(w.scene, 53)   // Esc closes the menu
        w.scene.face(.down)
        press(w.scene, spaceKey)
        XCTAssertEqual(menu(w)?.memberID, c.id)
        XCTAssertTrue(menu(w)?.actions.contains(.drag) == true)
        w.c.chooseMenu(.drag, memberID: c.id)
        await settle()
        XCTAssertEqual(drags(c).count, 1)
        XCTAssertTrue(drags(w.b).allSatisfy { $0.targetMemberID == c.id }, "b only overhears the drag aimed at c")
        XCTAssertEqual(drags(c).first?.targetMemberID, c.id)
    }

    /// A big teammate whose body covers my tile but whose foot is off my line is a Space target (found by `memberAround`'s first step,
    /// "the body covers my tile": I face up, so the faced tile holds nobody) but is not draggable: the menu opens without the drag row.
    /// A small teammate on the tile below me would win `memberAround`'s second step, so only the first step finds the big one.
    func testABodyOnMyTileOffMyLineOpensTheMenuWithoutDrag() async {
        let w = await world(me: p(20, 12), facing: .up)
        await claim(w.b, size: 2, in: w)
        await place(w.b, p(21, 13), in: w)
        let small = await join(w, "다", at: p(20, 13))
        press(w.scene, spaceKey)
        XCTAssertEqual(menu(w)?.memberID, w.b.id, "the body-covers-my-tile step picks it, not the small one below me")
        XCTAssertNotEqual(menu(w)?.memberID, small.id)
        XCTAssertTrue(menu(w)?.actions.contains(.tackle) == true)
        XCTAssertFalse(menu(w)?.actions.contains(.drag) == true)
    }

    // MARK: - When the row is offered

    /// The row needs the target to be able to follow me: a member in the way of its slide hides it.
    func testABlockedTargetHidesTheRow() async {
        func layout(blocked: Bool) async -> World {
            let w = await world(me: p(20, 12), facing: .down)
            await claim(w.b, size: 3, in: w)
            await place(w.b, p(20, 15), in: w)   // its body covers rows 13...15, the faced tile (20,13) among them
            if blocked { _ = await join(w, "다", at: p(20, 14)) }   // inside its body, on its way to me
            press(w.scene, spaceKey)
            return w
        }
        let free = await layout(blocked: false)
        XCTAssertEqual(menu(free)?.memberID, free.b.id)
        XCTAssertTrue(menu(free)?.actions.contains(.drag) == true, "control: nothing in its way")
        let blocked = await layout(blocked: true)
        XCTAssertEqual(menu(blocked)?.memberID, blocked.b.id)
        XCTAssertTrue(menu(blocked)?.actions.contains(.tackle) == true)
        XCTAssertFalse(menu(blocked)?.actions.contains(.drag) == true)
    }

    /// The tackle row has no such check (a shelter teammate can be tackled, the push is theirs to refuse); a pull of a teammate whose
    /// plaza is closed would show me stepping back for nobody, so the row needs `inPlaza`.
    func testNoDragForATeammateWhosePlazaIsClosed() async {
        let me = node("나"), b = node("가")
        let shelter = PlazaShelterWanderer(memberID: b.id, shelter: map.shelterTiles).tile
        // a neighbour of its shelter tile with room to step back behind it (further along the same direction)
        guard let d = PlazaDirection.allCases.first(where: {
            map.isWalkable(PlazaWalker.offset(shelter, $0)) && map.isWalkable(PlazaWalker.offset(PlazaWalker.offset(shelter, $0), $0))
        }) else { return XCTFail("no spot beside the shelter tile") }
        let start = PlazaWalker.offset(shelter, d)
        let c = controller(me, start: start, speciesID: 25, stage: 1)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b)
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.memberTiles[b.id], shelter, "test precondition: it waits in the shelter")
        XCTAssertEqual(me.session.members[b.id]?.inPlaza, false)
        let direction = PlazaDrag.direction(puller: w.scene.myBody, target: w.scene.body(of: b.id)!)
        XCTAssertNotNil(direction, "test precondition: the bodies touch on a line")
        XCTAssertGreaterThan(PlazaDrag.stepBack(from: start, direction: direction!, stage: 1, isOpen: { self.map.isWalkable($0) }), 0,
                             "test precondition: there is room behind me")
        w.c.chooseMenu(.drag, memberID: b.id)
        await settle()
        XCTAssertTrue(drags(b).isEmpty)
        XCTAssertEqual(w.scene.walker.tile, start)
    }

    /// Following the teammate I drag would walk me back into the tile it slides into.
    func testDraggingTheTeammateIFollowStopsTheFollow() async {
        let w = await world(me: p(20, 12), b: p(19, 12), facing: .left)
        XCTAssertTrue(w.scene.follow(member: w.b.id))
        w.c.chooseMenu(.drag, memberID: w.b.id)
        XCTAssertNil(w.scene.followingMember)
        run(w.scene, 2)
        XCTAssertEqual(w.scene.walker.tile, p(21, 12), "I stayed where I stepped back to")
    }
}
