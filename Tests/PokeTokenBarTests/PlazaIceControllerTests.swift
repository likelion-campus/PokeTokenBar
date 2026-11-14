import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Breaking the frozen plaza ponds together: the controller side (Z, learning, saving, presence, the hint).
@MainActor
final class PlazaIceControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 0)
    private var t: TimeInterval = 0
    private let zKey: UInt16 = 6, rightKey: UInt16 = 124

    private var T: Double { now.timeIntervalSince1970 }
    private var leftPond: TilePoint { TilePoint(x: 5, y: 13) }
    private var R: TilePoint { TilePoint(x: 32, y: 14) }
    private var B: TilePoint { TilePoint(x: 20, y: 24) }
    private func brk(_ pond: TilePoint, _ at: Double) -> PlazaIceBreak { PlazaIceBreak(at: at, pond: pond) }
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
        now = Date(timeIntervalSince1970: 1_800_000_000)
        t = 0
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        let received: Received
        var id: String { settings.memberID }
    }

    @MainActor final class Received { var emotes: [TeamEmote] = [] }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.ice.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaIceControllerTests-\(UUID())")
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

    private func controller(_ me: Node, start: TilePoint, speciesID: Int?, prefs: PlazaPreferences? = nil) -> PlazaWindowController {
        let prefs = prefs ?? PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.ice.prefs.\(UUID())"))
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    private func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: key)
    }

    @MainActor private struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    /// Me at `mine`, teammate b connected; the left pond is frozen (fresh preferences).
    private func world(me mine: TilePoint, speciesID: Int? = 25, prefs: PlazaPreferences? = nil) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, start: mine, speciesID: speciesID, prefs: prefs)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b)
        w.scene.face(.right)
        run(w.scene, 0.1)
        return w
    }

    /// Me on the ice at (5,14).
    private func onIce(speciesID: Int? = 25) async -> World {
        let w = await world(me: p(4, 14), speciesID: speciesID)
        if speciesID == nil {
            w.scene.pushMe(.right)
        } else {
            press(w.scene, rightKey)
        }
        run(w.scene, 0.5)
        XCTAssertEqual(w.scene.walker.tile, p(5, 14), "test precondition")
        XCTAssertTrue(w.scene.isMeOnIce, "test precondition")
        return w
    }

    private func place(_ w: World, _ tile: TilePoint) async {
        w.b.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
    }

    private func jumps(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .jump } }

    // MARK: - My break

    func testZOnTheIceSendsABreakingJumpAndBreaksWhenItLands() async {
        let w = await onIce()
        press(w.scene, zKey)
        await settle()
        XCTAssertEqual(jumps(w.b).last?.iceBreak, brk(leftPond, T))
        run(w.scene, 0.3)
        await settle()
        XCTAssertNil(w.c.iceBreak)
        XCTAssertNil(w.b.session.members[w.me.id]?.iceBreak)
        run(w.scene, 0.1)
        await settle()
        XCTAssertEqual(w.c.iceBreak, brk(leftPond, T))
        XCTAssertEqual(w.b.session.members[w.me.id]?.iceBreak, brk(leftPond, T))
        run(w.scene, 0.7)
        XCTAssertTrue(w.scene.isMeInWater)
        XCTAssertNil(w.scene.frozenPondAnchor, "nothing is frozen for a minute")
        now = now.addingTimeInterval(60)
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.frozenPondAnchor, B, "the next pond froze a minute after the break")
    }

    func testAReceivedBreakFreezesTheNextPondAMinuteLater() async {
        let w = await world(me: p(20, 10))
        await place(w, p(8, 14))
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        run(w.scene, 1.2)
        XCTAssertTrue(w.scene.isWaterNow(p(9, 14)))
        XCTAssertNil(w.scene.frozenPondAnchor)
        XCTAssertTrue(w.scene.isWaterNow(p(34, 17)))
        now = now.addingTimeInterval(60)
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.frozenPondAnchor, B)
        XCTAssertTrue(w.scene.isWalkableNow(p(21, 25)))
    }

    func testZFromTheShoreLeapsOntoTheIceAndBreaksIt() async {
        let w = await world(me: p(4, 14))
        press(w.scene, zKey)
        await settle()
        XCTAssertEqual(jumps(w.b).last?.iceBreak, brk(leftPond, T))
        run(w.scene, 0.4)
        XCTAssertEqual(w.scene.walker.tile, p(5, 14))
        run(w.scene, 0.7)
        XCTAssertTrue(w.scene.isMeInWater)
    }

    func testAnEggOnTheIceSendsAPlainJump() async {
        let w = await onIce(speciesID: nil)
        press(w.scene, zKey)
        await settle()
        XCTAssertEqual(jumps(w.b).count, 1)
        XCTAssertNil(jumps(w.b).last?.iceBreak)
        XCTAssertEqual(w.scene.iceLandingCount, 0)
    }

    func testClosingBeforeTheLandingStillLearnsMyBreak() async {
        let defaults = TestDefaults.make(suite: "plaza.ice.close.\(UUID())")
        let prefs = PlazaPreferences(defaults: defaults)
        let me = node("나")
        let c = controller(me, start: p(4, 14), speciesID: 25, prefs: prefs)
        c.prepareScene()
        let scene = c.scene!
        scene.face(.right)
        run(scene, 0.1)
        press(scene, rightKey)
        run(scene, 0.5)
        press(scene, zKey)
        c.handleClose()
        XCTAssertEqual(prefs.iceBreak, brk(leftPond, T))
    }

    // MARK: - Received breaks

    func testAReceivedBreakingJumpBreaksFromTheJumpersTile() async {
        let w = await world(me: p(20, 10))
        await place(w, p(8, 14))
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        run(w.scene, 0.3)
        XCTAssertNil(w.scene.breakingHit)
        run(w.scene, 0.1)
        XCTAssertEqual(w.scene.breakingHit, p(8, 14))
        XCTAssertEqual(w.c.iceBreak, brk(leftPond, T))
    }

    func testAJumperOffThePondHitsTheNearestPondTile() async {
        let w = await world(me: p(20, 10))
        await place(w, p(3, 14))
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        run(w.scene, 0.4)
        XCTAssertEqual(w.scene.breakingHit, p(5, 14))
    }

    func testAPresenceOnlyBreakRunsFromTheCentre() async {
        let w = await world(me: p(20, 10))
        w.b.session.updateIceBreak(brk(leftPond, T))
        await settle()
        XCTAssertEqual(w.scene.breakingHit, p(9, 14))
    }

    func testPresenceBeforeTheLandingWaitsForTheJump() async {
        let w = await world(me: p(20, 10))
        await place(w, p(8, 14))
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        w.b.session.updateIceBreak(brk(leftPond, T))
        await settle()
        XCTAssertNil(w.scene.breakingHit)
        run(w.scene, 0.4)
        XCTAssertEqual(w.scene.breakingHit, p(8, 14))
    }

    func testAJumpAfterTheWindowClosedStillLearnsTheBreak() {
        let me = node("나")
        let c = controller(me, start: p(20, 10), speciesID: 25)
        XCTAssertNil(c.scene)
        c.showJump(memberID: "x", iceBreak: brk(leftPond, T))
        XCTAssertEqual(c.iceBreak, brk(leftPond, T))
        c.showJump(memberID: "x", iceBreak: brk(leftPond, T + 61))
        XCTAssertEqual(c.iceBreak, brk(leftPond, T))
    }

    func testAMismatchedBreakTurnsMyIceToWaterAtOnce() async {
        let w = await world(me: p(20, 10))
        XCTAssertEqual(w.scene.frozenPondAnchor, leftPond, "test precondition")
        w.b.session.updateIceBreak(brk(R, T))
        await settle()
        XCTAssertNil(w.scene.breakingHit)
        XCTAssertNil(w.scene.frozenPondAnchor, "nothing is frozen for a minute after R")
        XCTAssertTrue(w.scene.isWaterNow(p(6, 14)))
    }

    func testARestartKeepsTheLastBreak() async {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.ice.restart.\(UUID())"))
        prefs.iceBreak = brk(leftPond, T - 100)
        let w = await world(me: p(20, 10), prefs: prefs)
        XCTAssertEqual(w.scene.frozenPondAnchor, R)
        XCTAssertNil(w.scene.breakingHit)
        XCTAssertEqual(w.b.session.members[w.me.id]?.iceBreak, brk(leftPond, T - 100))
    }

    func testThePreferenceRoundTrips() {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.ice.roundtrip.\(UUID())"))
        XCTAssertNil(prefs.iceBreak)
        prefs.iceBreak = brk(R, 7)
        XCTAssertEqual(prefs.iceBreak, brk(R, 7))
        prefs.iceBreak = nil
        XCTAssertNil(prefs.iceBreak)
    }

    func testFutureForeignAndImpossibleBreaksAreDropped() async {
        let w = await world(me: p(20, 10))
        for bad in [brk(leftPond, T + 61), brk(p(6, 13), T), brk(leftPond, .infinity)] {
            w.c.showJump(memberID: w.b.id, iceBreak: bad)
        }
        w.b.session.updateIceBreak(brk(leftPond, T + 61))
        await settle()
        XCTAssertEqual(w.scene.iceLandingCount, 0)
        XCTAssertNil(w.c.iceBreak)
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T + 60))
        XCTAssertEqual(w.scene.iceLandingCount, 1)
    }

    func testAFloodOfBreakingJumpsStaysUnderTheCap() async {
        let w = await world(me: p(20, 10))
        for _ in 0..<200 { w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T)) }
        XCTAssertLessThanOrEqual(w.scene.iceLandingCount, PlazaScene.maxIceLandings)
        run(w.scene, 1.5)
        XCTAssertLessThanOrEqual(w.scene.iceLayerNodeCount, 3 + 49 + 6)
    }

    func testABreakWhileCoveredIsWaterWhenUncovered() async {
        let w = await onIce()
        w.c.setRendering(visible: false)
        let count = w.scene.children.count
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        XCTAssertEqual(w.c.iceBreak, brk(leftPond, T))
        XCTAssertTrue(w.scene.isMeInWater)
        XCTAssertEqual(w.scene.children.count, count)
        w.c.setRendering(visible: true)
        run(w.scene, 0.05)
        XCTAssertTrue(w.scene.isMeInWater)
        XCTAssertNil(w.scene.breakingHit)
    }

    // MARK: - Hint

    func testTheIceHintShowsOnTheIceUnlessAnotherHintWins() async {
        let w = await onIce()
        w.c.refreshHintForTesting()
        XCTAssertEqual(w.c.hint, L(.ko).plazaIceHint)
        await place(w, p(6, 14))
        w.scene.face(.right)
        run(w.scene, 0.1)
        w.c.refreshHintForTesting()
        XCTAssertEqual(w.c.hint, L(.ko).plazaMemberHint(nickname: "가"))
        w.c.showJump(memberID: w.b.id, iceBreak: brk(leftPond, T))
        run(w.scene, 1.2)
        XCTAssertFalse(w.scene.isMeOnIce)
        w.c.refreshHintForTesting()
        XCTAssertNotEqual(w.c.hint, L(.ko).plazaIceHint)
    }

    func testAnEggOnTheIceSeesNoIceHint() async {
        let w = await onIce()
        w.scene.canWalk = false
        w.c.refreshHintForTesting()
        XCTAssertNotEqual(w.c.hint, L(.ko).plazaIceHint)
    }
}
