import XCTest
@testable import PokeTokenBar

private struct NoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// C on the big tree and teammates' shakes: the controller decides (order, day count, drop, grant, banner), the scene only draws.
@MainActor
final class PlazaTreeControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = PlazaTreeControllerTests.day(21, 12)
    private var t: TimeInterval = 0
    private var granted: [ItemKind] = []
    private var suites: [String] = []
    private let cKey: UInt16 = 8, spaceKey: UInt16 = 49, pKey: UInt16 = 35

    static func day(_ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Double = 0) -> Date {
        PlazaWeather.gregorian.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: 0))!
            .addingTimeInterval(second)
    }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Self.day(21, 12)
        t = 0
        granted = []
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
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.tree.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaTreeControllerTests-\(UUID())")
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

    /// The suite the controller's preferences live in (a new controller on the same suite is a reopen).
    private func controller(_ me: Node, start: TilePoint, suite: String) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: suite))
        prefs.saveLastTile(start)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      grantItem: { [unowned self] in granted.append($0) },
                                      session: me.session, clock: { [unowned self] in now },
                                      bannerSleep: { _ in try? await Task.sleep(for: .seconds(60)) },
                                      shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
        c.prepareScene()
        return c
    }

    @MainActor struct World {
        let c: PlazaWindowController, me: Node, b: Node, suite: String
        var scene: PlazaScene { c.scene! }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    private func press(_ scene: PlazaScene, _ key: UInt16) { scene.handleKeyDown(keyCode: key, characters: "ㅊ", isRepeat: false) }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func world(me mine: TilePoint, b bTile: TilePoint? = nil, facing: PlazaDirection = .up, bodySize: Int = 1, suite: String? = nil) async -> World {
        let me = node("나"), b = node("가")
        let suite = suite ?? "plaza.tree.prefs.\(UUID())"
        let c = controller(me, start: mine, suite: suite)
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b, suite: suite)
        w.scene.face(facing)
        w.scene.myBodySize = bodySize
        if let bTile { await place(w, bTile) }
        run(w.scene, 0.1)
        return w
    }

    private func place(_ w: World, _ tile: TilePoint, facing: PlazaDirection = .down, inPlaza: Bool = true) async {
        w.b.session.updatePlazaPosition(inPlaza: inPlaza, tile: tile, facing: facing, isWalking: false, isFlushed: false)
        if inPlaza {
            for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
            XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
        } else {
            await settle()
        }
    }

    private func shakes(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .treeShake } }
    private func tackles(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .tackle } }

    /// One C, then the clock moves on past the 0.3 s limit.
    private func hit(_ w: World) async {
        press(w.scene, cKey)
        await settle()
        now = now.addingTimeInterval(0.4)
        run(w.scene, 0.4)
    }

    // MARK: - Order and reach

    func testFacingTheTreeHitsItEvenWithATeammateBeside() async {
        for beside in [p(16, 11), p(18, 11), p(17, 10)] {   // (17,10) is an old peer drawn inside the trunk
            let w = await world(me: p(17, 11), b: beside, facing: .up)
            let before = w.scene.memberTiles[w.b.id]
            press(w.scene, cKey)
            await settle()
            XCTAssertEqual(shakes(w.b).count, 1, "\(beside)")
            XCTAssertEqual(tackles(w.b).count, 0, "\(beside): no tackle")
            XCTAssertEqual(w.scene.memberTiles[w.b.id], before, "\(beside): b did not move")
            XCTAssertEqual(w.c.treeHitsToday, 1)
            XCTAssertTrue(w.scene.isTreeBusy)
            w.c.handleClose()
        }
    }

    func testFacingAwayStillTacklesTheTeammate() async {
        let w = await world(me: p(17, 11), b: p(16, 11), facing: .left)
        press(w.scene, cKey)
        await settle()
        XCTAssertEqual(tackles(w.b).count, 1)
        XCTAssertEqual(shakes(w.b).count, 0)
        XCTAssertEqual(w.c.treeHitsToday, 0)
        w.c.handleClose()
    }

    /// A big body touches the tree with its body: facing it from where the foot's faced tile is not a tree tile still hits.
    func testABigBodyHitsFromWhereItsBodyReaches() async {
        let w = await world(me: p(15, 11), facing: .right, bodySize: 3)
        press(w.scene, cKey)
        await settle()
        XCTAssertEqual(w.c.treeHitsToday, 1, "class 3 at (15,11) facing right")
        w.c.handleClose()
        let v = await world(me: p(15, 11), b: p(15, 12), facing: .down, bodySize: 3)
        press(v.scene, cKey)
        await settle()
        XCTAssertEqual(v.c.treeHitsToday, 0, "facing down, away from the tree")
        XCTAssertEqual(tackles(v.b).count, 1, "tackles b")
        v.c.handleClose()
    }

    func testSpaceBesideTheTreeStillGreetsATeammate() async {
        let w = await world(me: p(17, 11), b: p(16, 11), facing: .up)
        run(w.scene, 0.2)
        press(w.scene, spaceKey)
        await settle()
        if case .memberMenu = w.c.overlayContent {} else { XCTFail("Space opens the teammate's menu: \(w.c.overlayContent)") }
        XCTAssertEqual(w.c.treeHitsToday, 0)
        w.c.handleClose()
    }

    func testNoHitWhileFocusingOrInPhotoMode() async {
        let w = await world(me: p(17, 11), facing: .up)
        w.c.startFocus(minutes: 25)
        press(w.scene, cKey)
        await settle()
        XCTAssertEqual(w.c.treeHitsToday, 0, "focusing")
        w.c.handleClose()
        let v = await world(me: p(17, 11), facing: .up)
        press(v.scene, pKey)
        XCTAssertTrue(v.c.overlayIsPhotoMode, "test precondition")
        press(v.scene, cKey)
        await settle()
        XCTAssertEqual(v.c.treeHitsToday, 0, "photo mode swallows C")
        XCTAssertTrue(shakes(v.b).isEmpty)
        v.c.handleClose()
    }

    /// The limit answers for C: a second press inside 0.3 s is the tree's, not a fall-through that would turn me to the teammate.
    func testHitsAreRateLimitedLikeATackle() async {
        let w = await world(me: p(17, 11), b: p(16, 11), facing: .up)
        press(w.scene, cKey)
        now = now.addingTimeInterval(0.29)
        press(w.scene, cKey)
        await settle()
        XCTAssertEqual(w.c.treeHitsToday, 1, "0.29 s apart: one hit")
        XCTAssertEqual(w.scene.walker.facing, .up, "I still face the tree (a fall-through would turn me to b)")
        XCTAssertTrue(tackles(w.b).isEmpty)
        now = now.addingTimeInterval(0.02)
        press(w.scene, cKey)
        await settle()
        XCTAssertEqual(w.c.treeHitsToday, 2, "0.31 s after the first: two hits")
        w.c.handleClose()
    }

    // MARK: - The drop

    func testTheThirdHitGrantsOneMintOnce() async {
        let w = await world(me: p(17, 11), facing: .up)
        let shown = w.c.bannersShown
        for _ in 0..<3 { await hit(w) }
        XCTAssertEqual(granted, [.mint])
        XCTAssertEqual(w.c.banner, "나무에서 민트가 떨어졌어요! 가방에 넣었어요")
        XCTAssertEqual(w.c.bannersShown, shown + 1, "one banner")
        XCTAssertEqual(w.c.activity.pickups, 1)
        XCTAssertEqual(w.c.activity.tackles, 0)
        let sent = shakes(w.b)
        XCTAssertEqual(sent.map { TeamEmote.pushTiles($0.pushTiles) }, [1, 2, 3])
        XCTAssertEqual(sent.map(\.treeDrop), [nil, nil, .mint])
        await hit(w)
        XCTAssertEqual(granted, [.mint], "a fourth hit grants nothing")
        XCTAssertEqual(w.c.bannersShown, shown + 1)
        XCTAssertEqual(TeamEmote.pushTiles(shakes(w.b).last?.pushTiles), 1)
        XCTAssertNil(shakes(w.b).last?.treeDrop)
        w.c.handleClose()
    }

    func testTheCountCrossesMidnight() async {
        let w = await world(me: p(17, 11), facing: .up)
        now = Self.day(21, 23, 59, 58)
        await hitNoAdvance(w)
        now = now.addingTimeInterval(0.4)   // 23:59:58.4
        await hitNoAdvance(w)
        now = Self.day(22, 0, 0, 0)
        await hitNoAdvance(w)
        XCTAssertTrue(granted.isEmpty, "the third hit is on a new day: it counts as the first")
        for _ in 0..<2 { now = now.addingTimeInterval(0.4); await hitNoAdvance(w) }
        XCTAssertEqual(granted, [.mint])
        w.c.handleClose()
    }

    private func hitNoAdvance(_ w: World) async {
        press(w.scene, cKey)
        await settle()
        run(w.scene, 0.1)
    }

    func testTheCountSurvivesAReopen() async {
        let first = await world(me: p(17, 11), facing: .up)
        await hit(first); await hit(first)
        XCTAssertTrue(granted.isEmpty)
        first.c.handleClose()
        let second = await world(me: p(17, 11), facing: .up, suite: first.suite)
        XCTAssertEqual(second.c.treeHitsToday, 2)
        await hit(second)
        XCTAssertEqual(granted, [.mint], "the third hit of the day, across a restart")
        second.c.handleClose()
    }

    func testAHiddenSceneStillDecides() async {
        let w = await world(me: p(17, 11), facing: .up)
        await hit(w); await hit(w)
        w.c.setRendering(visible: false)
        await hit(w)
        XCTAssertEqual(granted, [.mint], "the grant is the controller's, whatever the scene draws")
        XCTAssertEqual(w.c.activity.pickups, 1)
        w.c.handleClose()
    }

    // MARK: - Teammates' shakes

    func testATeammatesShakeIsDrawnWhereTheyTouchTheTree() async {
        let w = await world(me: p(20, 12), b: p(17, 11))
        w.scene.update(t)
        let banner = w.c.banner, activity = w.c.activity, tile = w.scene.walker.tile
        w.c.showTreeShake(from: w.b.id, level: 2, drop: nil)
        XCTAssertTrue(w.scene.isTreeBusy)
        run(w.scene, 0.08)
        XCTAssertNotEqual(w.scene.lungeOffset(memberID: w.b.id), .zero, "b lunges")
        w.c.showTreeShake(from: w.b.id, level: 3, drop: .mint)
        var sparkled = false
        for _ in 0..<40 { t += 0.05; w.scene.update(t); if w.scene.sparkleCount > 0 { sparkled = true } }
        XCTAssertTrue(sparkled, "the drop landed and sparkled for b")
        XCTAssertTrue(granted.isEmpty)
        XCTAssertEqual(w.c.banner, banner)
        XCTAssertEqual(w.c.activity, activity)
        XCTAssertEqual(w.scene.walker.tile, tile)
        w.c.handleClose()
    }

    /// A teammate's drop bounces out to a tile two away from them, rests there, and comes to their foot.
    func testADropBouncesOutBesideTheSenderAndComesToTheirFoot() async {
        let w = await world(me: p(20, 12), b: p(17, 11))
        w.c.showTreeShake(from: w.b.id, level: 3, drop: .mint)
        let foot = w.scene.memberFoot(w.b.id)!
        var seen: [CGPoint] = []
        for _ in 0..<60 { t += 0.05; w.scene.update(t); if let q = w.scene.treeItemPosition { seen.append(q) } }
        let size = CGFloat(PlazaMap.tileSize)
        let rest = seen.filter { q in seen.filter { abs($0.x - q.x) < 0.6 && abs($0.y - q.y) < 0.6 }.count > 8 }
        XCTAssertFalse(rest.isEmpty, "it rests somewhere")
        let tile = TilePoint(x: Int(rest[0].x / size), y: Int(rest[0].y / size))
        XCTAssertEqual(max(abs(tile.x - 17), abs(tile.y - 11)), 2, "two tiles from the sender: \(tile)")
        XCTAssertFalse(PlazaTree.coveredTiles(in: PlazaMapData.map).contains(tile))
        XCTAssertTrue(PlazaMapData.map.isWalkable(tile))
        XCTAssertLessThan(hypot(seen.last!.x - foot.x, seen.last!.y - foot.y), 12, "it ends at b's foot")
        w.c.handleClose()
    }

    // MARK: - The second tree

    func testHittingTheSecondTreeSharesTheDayCountAndShakesOnlyThatTree() async {
        let w = await world(me: p(42, 28), facing: .up)
        let shown = w.c.bannersShown
        await hit(w)
        XCTAssertTrue(w.scene.treeLayers[1].isBusy)
        XCTAssertFalse(w.scene.treeLayers[0].isBusy, "the other tree stays still")
        run(w.scene, 3)
        // Two hits on the second, then one on the first (walk is not needed: a second world on the same save would reset the scene, so the
        // controller's own count is what we read): the third hit of the day drops, whichever tree takes it.
        await hit(w)
        XCTAssertEqual(w.c.treeHitsToday, 2)
        await hit(w)
        XCTAssertEqual(granted, [.mint], "three hits, one mint")
        XCTAssertEqual(w.c.bannersShown, shown + 1)
        for _ in 0..<3 { await hit(w) }
        XCTAssertEqual(granted, [.mint], "one drop a day in total, not per tree")
        XCTAssertEqual(shakes(w.b).count, 6)
        w.c.handleClose()
    }

    /// Two hits on the first tree, a reopen standing at the second: the third hit of the day is the one that drops, on the other tree.
    func testTheDayCountIsSharedAcrossBothTrees() async {
        let first = await world(me: p(17, 11), facing: .up)
        await hit(first); await hit(first)
        first.c.handleClose()
        let second = await world(me: p(42, 28), facing: .up, suite: first.suite)
        XCTAssertEqual(second.c.treeHitsToday, 2)
        await hit(second)
        XCTAssertEqual(granted, [.mint], "the third hit of the day, on the other tree, drops")
        XCTAssertTrue(second.scene.treeLayers[1].isBusy)
        XCTAssertFalse(second.scene.treeLayers[0].isBusy)
        for _ in 0..<3 { await hit(second) }
        XCTAssertEqual(granted, [.mint], "never a second drop that day")
        second.c.handleClose()
    }

    /// A teammate standing at the second tree shakes that tree on my screen; one standing at the first shakes the first. Where they stand decides, not a field.
    func testATeammatesShakeFindsItsTreeFromWhereTheyStand() async {
        let w = await world(me: p(30, 5), b: p(42, 28))
        w.c.showTreeShake(from: w.b.id, level: 2, drop: nil)
        XCTAssertTrue(w.scene.treeLayers[1].isBusy)
        XCTAssertFalse(w.scene.treeLayers[0].isBusy)
        run(w.scene, 3)
        await place(w, p(17, 11), facing: .up)
        w.c.showTreeShake(from: w.b.id, level: 2, drop: nil)
        XCTAssertTrue(w.scene.treeLayers[0].isBusy)
        XCTAssertFalse(w.scene.treeLayers[1].isBusy)
        w.c.handleClose()
    }

    /// What a v2.5.637 peer (one tree, at the first one) does with my hit on the second tree: its `showTreeShake` needs my body to touch ITS tree, so a hitter
    /// standing at the new tree is ignored there. This test plays that old rule against the frame I send.
    func testAnOldPeerIgnoresAHitOnTheNewTree() async {
        let old = PlazaTree.runs(in: PlazaMapData.map)[0]
        XCTAssertFalse(PlazaTree.touches(PlazaBody(foot: p(42, 28), size: 1), tiles: old), "my body at the second tree does not touch the old peer's only tree")
        XCTAssertTrue(PlazaTree.touches(PlazaBody(foot: p(17, 11), size: 1), tiles: old), "control: a hit on the first tree still reaches an old peer")
        // And the new rule sees an old peer's hit on the first tree as the first tree.
        let w = await world(me: p(30, 5), b: p(17, 11))
        w.c.showTreeShake(from: w.b.id, level: 3, drop: .mint)
        XCTAssertTrue(w.scene.treeLayers[0].isBusy)
        XCTAssertFalse(w.scene.treeLayers[1].isBusy)
        w.c.handleClose()
    }

    // MARK: - Hostile peers

    func testAShakeFromAPeerNotTouchingTheTreeIsIgnored() async {
        let w = await world(me: p(20, 12), b: p(14, 11))
        w.c.showTreeShake(from: w.b.id, level: 3, drop: .mint)
        XCTAssertFalse(w.scene.isTreeBusy)
        XCTAssertEqual(w.scene.lungeOffset(memberID: w.b.id), .zero)
        w.c.showTreeShake(from: "nobody", level: 3, drop: .mint)
        XCTAssertFalse(w.scene.isTreeBusy)
        let away = await world(me: p(20, 12), b: p(17, 11))
        await place(away, p(17, 11), inPlaza: false)
        away.c.showTreeShake(from: away.b.id, level: 3, drop: .mint)
        XCTAssertFalse(away.scene.isTreeBusy, "a teammate who is not in the plaza")
        w.c.handleClose(); away.c.handleClose()
    }

    func testAShakeWithAnUnknownItemShakesOnly() async throws {
        let w = await world(me: p(20, 12), b: p(17, 11))
        // The wire turns an unknown kind into nil (tested with the frames); a shake without a drop draws the shake and no item.
        w.c.showTreeShake(from: w.b.id, level: 2, drop: nil)
        run(w.scene, 0.5)
        XCTAssertNil(w.scene.treeItemPosition)
        w.c.handleClose()
    }

    func testAShakeNeverMovesMe() async {
        let w = await world(me: p(17, 12), b: p(17, 11), facing: .down)
        let tile = w.scene.walker.tile
        for i in 0..<100 {
            w.c.showTreeShake(from: w.b.id, level: i % 3 + 1, drop: i % 7 == 0 ? .mint : nil)
            if i % 10 == 0 { run(w.scene, 0.1) }
        }
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.walker.tile, tile)
        XCTAssertTrue(granted.isEmpty)
        w.c.handleClose()
    }

    /// A shaker the scene draws but the session no longer lists (a race) still shakes the tree, facing down by default.
    func testAShakerTheSessionDoesNotListIsStillDrawn() async {
        let w = await world(me: p(20, 12))
        w.scene.applyMembers([PlazaSceneMember(memberID: "ghost", nickname: "g", isAway: false, tile: p(17, 11), facing: .up, isWalking: false)])
        w.c.showTreeShake(from: "ghost", level: 1, drop: nil)
        XCTAssertTrue(w.scene.isTreeBusy)
        w.c.handleClose()
    }

    /// The minimap's tree follows the season the scene shows (summer has no season image, the others do).
    func testTheMinimapFollowsTheSeason() async {
        let w = await world(me: p(20, 12))
        w.scene.seasonChoice = .winter
        run(w.scene, 0.1)
        XCTAssertNotNil(w.c.minimapSeasonImage)
        w.scene.seasonChoice = .summer
        run(w.scene, 0.1)
        XCTAssertNil(w.c.minimapSeasonImage)
        w.c.handleClose()
    }
}
