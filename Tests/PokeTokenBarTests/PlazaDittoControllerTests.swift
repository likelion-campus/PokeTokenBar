import XCTest
import AppKit
@testable import PokeTokenBar

/// Records which species were asked for, so a test can see a frame load start without any network.
private final class RecordingFetcher: PlazaSpriteFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [Int] = []
    private func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        add(speciesID)
        return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

@MainActor
final class PlazaDittoControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private let map = PlazaMapData.map
    private let key = PlazaDitto.sceneKey

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
    }

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private func node(_ name: String, character: TeamMonSummary? = nil) -> Node {
        let suite = "plaza.ditto.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaDittoControllerTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let current = character ?? Self.pikachu
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: current, dex: []) })
        session.updateCharacter(current)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func defaults() -> UserDefaults {
        let name = "plaza.ditto.prefs.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Holds the Ditto loop's sleep until the test fires it.
    @MainActor private final class LoopGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var waitingCount: Int { waiting.count }
        func sleep(_ d: Duration) async { await withCheckedContinuation { waiting.append($0) } }
        func fire() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
    }

    /// The loop sleeps for good, so only `advanceDitto(now:)` moves the Ditto.
    private func controller(_ me: Node, fetcher: PlazaSpriteFetching = RecordingFetcher(), gate: LoopGate? = nil,
                            seed: UInt64 = 7) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: defaults()),
                              loader: PlazaCharacterLoader(fetcher: fetcher),
                              nickname: { "나" }, memberID: { me.settings.memberID },
                              subject: { .init(speciesID: 25, isShiny: false) },
                              myRosterEntry: { nil }, session: me.session,
                              spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                              dittoLoopSleep: { d in
                                  if let gate { await gate.sleep(d) } else { try? await Task.sleep(for: .seconds(3600)) }
                              },
                              dittoSeed: { seed })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    /// Nodes ordered by member ID, so a test knows who would host.
    private func sorted(_ count: Int, character: TeamMonSummary? = nil) -> [Node] {
        (0..<count).map { node("n\($0)", character: character) }.sorted { $0.id < $1.id }
    }

    private func ground(_ dx: Int = 0, _ dy: Int = 0) -> TilePoint {
        let t = TilePoint(x: map.spawn.x + dx, y: map.spawn.y + dy)
        XCTAssertTrue(PlazaDitto.isGround(t, in: map), "\(t) must be ground")
        return t
    }

    private func place(_ n: Node, at tile: TilePoint, ready: Bool = true) {
        n.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        n.session.updateDitto(ready: ready, state: nil)
    }

    private func host(_ n: Node, _ state: PlazaDittoState) {
        n.session.updatePlazaPosition(inPlaza: true, tile: ground(8, 8), facing: .down, isWalking: false)
        n.session.updateDitto(ready: true, state: state)
    }

    private func dittoForm(_ tile: TilePoint, now: Date = Date()) -> PlazaDittoState {
        PlazaDittoState(tile: tile, facing: .down, isWalking: nil, isRunning: nil, decoyOf: nil, since: now, restUntil: nil)
    }

    // MARK: - Readiness

    func testOpeningTheWindowMakesMeReadyAndClosingClearsIt() async {
        let me = node("나"), other = node("민수")
        await connect(me, other)
        XCTAssertNotEqual(other.session.members[me.id]?.dittoReady, true)
        let c = controller(me)
        c.prepareScene()
        await settle()
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, true)
        c.advanceDitto(now: Date())
        await settle()
        c.handleClose()
        await settle()
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, false)
        XCTAssertNil(other.session.members[me.id]?.ditto)
        XCTAssertNil(c.shownDitto)
        XCTAssertFalse(c.isDittoHost)
    }

    func testAControllerWhoseWindowWasNeverShownNeverSendsReady() async {
        let me = node("나"), other = node("민수")
        await connect(me, other)
        _ = controller(me)
        me.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        await settle()
        XCTAssertNotNil(other.session.members[me.id], "my presence did reach the other side")
        XCTAssertEqual(other.session.members[me.id]?.dittoReady, false)
    }

    func testTheLoopTicksWhileOpenStopsOnCloseAndRestartsOnce() async {
        let me = node("나")
        let gate = LoopGate()
        let c = controller(me, gate: gate)
        c.prepareScene()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1)
        XCTAssertNil(c.shownDitto, "no tick yet")
        gate.fire()
        await settle()
        XCTAssertNotNil(c.shownDitto, "a tick reached advanceDitto")
        XCTAssertEqual(gate.waitingCount, 1, "and the loop sleeps again")

        c.handleClose()
        gate.fire()
        await settle()
        XCTAssertEqual(gate.waitingCount, 0, "closing ends the loop")

        c.prepareScene()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1)
        gate.fire()
        await settle()
        XCTAssertEqual(gate.waitingCount, 1, "one stream of ticks after reopening, not two")
        XCTAssertNotNil(c.shownDitto)
    }

    func testAnUnchangedDittoLeavesTheSceneAlone() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(4, 0))
        // Remove it behind the controller's back: a tick with nothing new must not redraw it.
        c.scene?.applyDitto(nil)
        c.advanceDitto(now: Date())
        XCTAssertNil(c.scene?.dittoTile)
        host(a, dittoForm(ground(6, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(6, 0), "a change is drawn")
    }

    // MARK: - Host choice

    func testTheSmallestReadyIDHosts() async {
        let pair = sorted(2)
        let (a, b) = (pair[0], pair[1])
        await connect(a, b)
        place(a, at: ground(4, 0))
        let cb = controller(b)
        cb.prepareScene()
        await settle()
        cb.advanceDitto(now: Date())
        await settle()
        XCTAssertFalse(cb.isDittoHost, "a smaller ready ID hosts")
        XCTAssertNil(a.session.members[b.id]?.ditto)

        let ca = controller(a)
        ca.prepareScene()
        place(b, at: ground(6, 0))
        await settle()
        ca.advanceDitto(now: Date())
        await settle()
        XCTAssertTrue(ca.isDittoHost)
        XCTAssertNotNil(b.session.members[a.id]?.ditto, "the host's presence carries the Ditto")
    }

    func testANonHostShowsTheHostsDitto() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(c.scene?.dittoTile, ground(4, 0))
        XCTAssertEqual(c.shownDitto?.tile, ground(4, 0))
        XCTAssertEqual(c.scene?.memberName(key), L(.ko).plazaDittoName)
    }

    func testTwoHostsSettleOnTheSmallerID() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertTrue(c.isDittoHost, "alone, I host")
        host(a, dittoForm(ground(6, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertFalse(c.isDittoHost, "a smaller ID hosting wins at once")
        XCTAssertEqual(c.scene?.dittoTile, ground(6, 0))
    }

    func testANewHostCarriesOnTheCopyWhereTheOldHostLeftIt() async {
        let trio = sorted(3)
        let (a, me, m) = (trio[0], trio[1], trio[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        let before = try? XCTUnwrap(c.shownDitto)
        XCTAssertEqual(before?.decoyOf, m.id)
        a.session.updatePlazaPosition(inPlaza: false, tile: nil, facing: nil, isWalking: false)
        a.session.updateDitto(ready: false, state: nil)
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        await settle()
        XCTAssertTrue(c.isDittoHost)
        let sent = a.session.members[me.id]?.ditto
        XCTAssertEqual(sent?.decoyOf, m.id)
        XCTAssertEqual(sent?.since, before?.since)
        XCTAssertEqual(sent?.tile, before?.tile)
    }

    func testTheHostMovesTheDittoWithoutSceneFrames() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        c.scene?.isPaused = true
        var now = Date()
        c.advanceDitto(now: now)
        var tiles: Set<TilePoint> = [try! XCTUnwrap(c.shownDitto).tile]
        for _ in 0..<1200 {
            now = now.addingTimeInterval(0.05)
            c.advanceDitto(now: now)
            if let t = c.shownDitto?.tile { tiles.insert(t) }
        }
        XCTAssertGreaterThan(tiles.count, 1, "the brain walks on the controller's clock alone")
    }

    // MARK: - Showing

    /// [host a, me, member m] with m ready next to nothing, and a hosting a copy of m.
    private func copyScene(character: TeamMonSummary? = nil, fetcher: PlazaSpriteFetching = RecordingFetcher())
        async -> (c: PlazaWindowController, a: Node, m: Node) {
        let nodes = sorted(3)
        let (a, me) = (nodes[0], nodes[1])
        let m = nodes[2]
        await connect(a, me); await connect(m, me)
        let c = controller(me, fetcher: fetcher)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now)
        return (c, a, m)
    }

    func testACopyLooksLikeTheRealOne() async {
        let (c, _, m) = await copyScene()
        let scene = c.scene!
        XCTAssertEqual(scene.memberName(key), m.settings.nickname)
        XCTAssertEqual(scene.memberNameColor(key), PlazaNameColor.color(forMemberID: m.id, chosen: m.settings.nameColor))
        XCTAssertEqual(scene.memberNameColor(key), scene.memberNameColor(m.id))
        XCTAssertEqual(scene.decoyTile, ground(5, 3))
        let dots = c.minimapDots.filter { $0.color == scene.memberNameColor(m.id) && !$0.isMe }
        XCTAssertEqual(Set(dots.map(\.id)), [m.id, key])
    }

    func testTheCopyFollowsTheRealOnesLookChange() async {
        let fetcher = RecordingFetcher()
        let (c, _, m) = await copyScene(fetcher: fetcher)
        let scene = c.scene!
        var changed = Self.pikachu
        changed.nature = .jolly
        m.session.updateCharacter(changed)
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertEqual(scene.memberTitle(key), L(.ko).plazaNatureTitle(.jolly))
        XCTAssertEqual(scene.memberTitle(key), scene.memberTitle(m.id))

        let before = c.appliedMemberSpecies(key).count
        m.session.updateCharacter(TeamMonSummary(speciesID: 4, isShiny: false, form: nil, speciesName: "Charmander", gender: nil))
        await settle()
        c.advanceDitto(now: Date())
        await settle()
        XCTAssertGreaterThan(c.appliedMemberSpecies(key).count, before)
        XCTAssertEqual(c.appliedMemberSpecies(key).last, 4, "a species change starts a load under the Ditto key")
    }

    func testDittoFormHasNoMinimapDot() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        host(a, dittoForm(ground(4, 0)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNotNil(c.scene?.dittoTile)
        XCTAssertFalse(c.minimapDots.contains { $0.id == key })
    }

    func testTransformStopsMyWalkToTheCopiedMember() async {
        let nodes = sorted(3)
        let (a, me, m) = (nodes[0], nodes[1], nodes[2])
        await connect(a, me); await connect(m, me)
        let c = controller(me)
        c.prepareScene()
        place(m, at: ground(-5, 0))
        let now = Date()
        host(a, dittoForm(ground(5, 3), now: now))
        await settle()
        c.advanceDitto(now: now)
        c.walkToMember(m.id)
        XCTAssertEqual(c.scene?.walkingToMember, m.id)
        host(a, dittoForm(ground(5, 3), now: now).copying(m.id, now: now))
        await settle()
        c.advanceDitto(now: now.addingTimeInterval(0.05))
        XCTAssertEqual(c.scene?.decoyTile, ground(5, 3))
        XCTAssertNil(c.scene?.walkingToMember, "the walk to the real one ends at the swap")
    }

    func testAStateOffTheGroundIsIgnored() async {
        let pair = sorted(2)
        let (a, me) = (pair[0], pair[1])
        await connect(a, me)
        let c = controller(me)
        c.prepareScene()
        var water: TilePoint?
        for y in 0..<map.height { for x in 0..<map.width where map.isWater(TilePoint(x: x, y: y)) { water = TilePoint(x: x, y: y) } }
        host(a, dittoForm(try! XCTUnwrap(water)))
        await settle()
        c.advanceDitto(now: Date())
        XCTAssertNil(c.scene?.dittoTile)
        XCTAssertNil(c.shownDitto)
    }

    // MARK: - Campfire seats

    func testACampfireSeatUnderTheDittoIsNotChosen() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        let scene = c.scene!
        let seat = try! XCTUnwrap(PlazaCampfire.nearestFreeSeat(from: scene.walker.tile, occupied: []))
        scene.applyDitto(PlazaDittoShown(tile: seat.tile, facing: .down, isWalking: false, isRunning: false, name: "d",
                                         nameColor: PlazaNameColor.palette[0], title: nil, isDecoy: false))
        c.startFocus(minutes: 25)
        XCTAssertNotNil(c.focus)
        XCTAssertNotEqual(c.focus?.seat, seat.tile)
    }
}
