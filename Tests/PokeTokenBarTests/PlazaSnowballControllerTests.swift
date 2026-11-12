import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// Throwing a snowball with V and being hit by one: the controller side of snow days.
@MainActor
final class PlazaSnowballControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = PlazaSnowballControllerTests.day(6)
    private var t: TimeInterval = 0
    private let map = PlazaMapData.map
    private let vKey: UInt16 = 9, zKey: UInt16 = 6, spaceKey: UInt16 = 49

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
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
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
        let suite = "plaza.snowball.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaSnowballControllerTests-\(UUID())")
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

    private func defaults() -> UserDefaults {
        let name = "plaza.snowball.prefs.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func controller(_ me: Node, start: TilePoint, speciesID: Int?, stage: Int) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, evolutionStage: { stage }, session: me.session, clock: { [unowned self] in now })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func run(_ scene: PlazaScene, _ seconds: TimeInterval) {
        let end = t + seconds
        scene.update(t)
        while t < end - 1e-9 { t += 0.05; scene.update(t) }
    }

    private func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    @MainActor private struct World {
        let c: PlazaWindowController, me: Node, b: Node
        var scene: PlazaScene { c.scene! }
    }

    /// Me at `mine` facing `facing`, teammate b (when given) at `bTile`, the plaza scene seeing both.
    private func world(me mine: TilePoint, b bTile: TilePoint? = nil, facing: PlazaDirection = .right, stage: Int = 1,
                       speciesID: Int? = 25) async -> World {
        let me = node("나"), b = node("가")
        let c = controller(me, start: mine, speciesID: speciesID, stage: stage)
        c.prepareScene()
        hub.connect(me.transport, to: b.transport)
        await settle()
        let w = World(c: c, me: me, b: b)
        w.scene.face(facing)
        if let bTile { await place(w, bTile) }
        run(w.scene, 0.1)
        return w
    }

    private func place(_ w: World, _ tile: TilePoint) async {
        w.b.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        for _ in 0..<200 where w.scene.memberTiles[w.b.id] != tile { await Task.yield(); t += 0.05; w.scene.update(t) }
        XCTAssertEqual(w.scene.memberTiles[w.b.id], tile, "test precondition")
    }

    private func snowballs(_ n: Node) -> [TeamEmote] { n.received.emotes.filter { $0.kind == .snowball } }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    // MARK: - Throwing

    func testVThrowsAtTheFirstTeammateAheadAndSendsIt() async {
        let w = await world(me: p(10, 12), b: p(14, 12), stage: 2)
        press(w.scene, vKey)
        await settle()
        let sent = snowballs(w.b)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.targetMemberID, w.b.id)
        XCTAssertEqual(sent.first?.pushTiles, 2)
        XCTAssertEqual(sent.first?.snowballDirection, .right)
        XCTAssertEqual(w.scene.snowballFlightCount, 1)
    }

    func testVWithNobodyAheadSendsNoTarget() async {
        let w = await world(me: p(10, 12), b: p(10, 8))
        press(w.scene, vKey)
        await settle()
        XCTAssertEqual(snowballs(w.b).count, 1)
        XCTAssertNil(snowballs(w.b).first?.targetMemberID)
        XCTAssertEqual(snowballs(w.b).first?.snowballDirection, .right)
        XCTAssertEqual(w.scene.snowballFlightCount, 1)
    }

    func testVDoesNothingWhenICannotThrow() async {
        func assertNothing(_ name: String, _ w: World) async {
            press(w.scene, vKey)
            await settle()
            XCTAssertTrue(snowballs(w.b).isEmpty, "\(name): sent")
            XCTAssertEqual(w.scene.snowballFlightCount, 0, "\(name): flew")
        }
        now = Self.day(6)
        let focusing = await world(me: p(10, 12), b: p(14, 12))
        focusing.c.startFocus(minutes: 25)
        XCTAssertTrue(focusing.c.isFocusing, "test precondition")
        await assertNothing("focusing", focusing)
        let swimmer = await world(me: p(15, 14), b: p(12, 14), facing: .left)
        press(swimmer.scene, zKey)
        run(swimmer.scene, 0.5)
        XCTAssertTrue(swimmer.scene.isMeInWater, "test precondition")
        await assertNothing("swimming", swimmer)
        await assertNothing("an egg", await world(me: p(10, 12), b: p(14, 12), speciesID: nil))
        await assertNothing("a tree ahead", await world(me: p(3, 12), b: p(7, 12), facing: .left))
    }

    func testVThrowsOnAnyDate() async {
        now = Self.day(7, 23, 59, 59)
        let w = await world(me: p(10, 12), b: p(14, 12))
        XCTAssertTrue(w.c.shortcutsShowSnowball)
        press(w.scene, vKey)
        await settle()
        XCTAssertEqual(snowballs(w.b).count, 1)
        now = Self.day(20, 0, 0, 0)
        run(w.scene, 0.1)
        XCTAssertTrue(w.c.shortcutsShowSnowball)
    }

    func testVIsLimitedLikeTheOtherKeys() async {
        let w = await world(me: p(10, 12), b: p(14, 12))
        press(w.scene, vKey)
        now = now.addingTimeInterval(0.29)
        press(w.scene, vKey)
        await settle()
        XCTAssertEqual(snowballs(w.b).count, 1)
        now = now.addingTimeInterval(0.02)
        press(w.scene, vKey)
        await settle()
        XCTAssertEqual(snowballs(w.b).count, 2)
    }

    // MARK: - Being hit

    func testAHitPushesMeWhenTheBallLands() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 2, direction: .right)
        XCTAssertEqual(w.scene.snowballFlightCount, 1)
        run(w.scene, 0.35)
        XCTAssertEqual(w.scene.walker.tile, p(14, 12), "still in the air")
        run(w.scene, 0.85)
        XCTAssertEqual(w.scene.walker.tile, p(16, 12))
    }

    func testWalkingOffTheAimedTileBeforeTheBallLandsDodgesIt() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 2, direction: .right)
        let (key, side): (UInt16, TilePoint) = map.isWalkable(p(14, 13)) ? (125, p(14, 13)) : (126, p(14, 11))
        XCTAssertTrue(map.isWalkable(side), "test precondition")
        w.scene.handleKeyDown(keyCode: key, characters: "", isRepeat: false)
        run(w.scene, 0.1)
        w.scene.handleKeyUp(keyCode: key)
        run(w.scene, 1.2)
        XCTAssertEqual(w.scene.walker.tile, side, "walked off, not pushed along the row")
        XCTAssertEqual(w.scene.impactCount, 0, "no star on a tile the ball never touched")
    }

    func testAHitFromOutOfLineOrTooFarOnlyBursts() async {
        let cases: [(String, TilePoint, PlazaDirection)] = [
            ("too far", p(7, 12), .right), ("off the row", p(10, 11), .right), ("wrong way", p(10, 12), .left),
        ]
        for (name, from, direction) in cases {
            let w = await world(me: p(14, 12), b: from)
            w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 2, direction: direction)
            run(w.scene, 1.0)
            XCTAssertEqual(w.scene.walker.tile, p(14, 12), name)
            XCTAssertEqual(w.scene.impactCount, 1, name)
        }
    }

    private func opposite(_ d: PlazaDirection) -> PlazaDirection {
        switch d { case .left: .right; case .right: .left; case .up: .down; case .down: .up }
    }

    /// A tile where a sender two tiles away can push me: both sides of me are walkable.
    private func pushableSide(_ spot: TilePoint) -> PlazaDirection? {
        [PlazaDirection.left, .right, .up, .down].first { d in
            let opposite = opposite(d)
            return map.isWalkable(PlazaWalker.offset(spot, d)) && map.isWalkable(PlazaWalker.offset(PlazaWalker.offset(spot, opposite), opposite))
                && map.isWalkable(PlazaWalker.offset(spot, opposite))
        }
    }

    private func pushedAtTheFire(focusing: Bool, menuOpen: Bool) async -> Bool {
        let w = await world(me: p(23, 14), b: nil)
        if focusing { w.c.startFocus(minutes: 25) }
        if menuOpen { press(w.scene, spaceKey) }
        XCTAssertEqual(w.c.isFocusing, focusing)
        XCTAssertEqual(w.c.isCampfireMenuOpen, menuOpen)
        let spot = w.scene.walker.tile
        guard let d = pushableSide(spot) else { XCTFail("no pushable side"); return false }
        let o = opposite(d)
        let from = PlazaWalker.offset(PlazaWalker.offset(spot, o), o)
        await place(w, from)
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: d)
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.impactCount, 1, "the impact always plays")
        let moved = w.scene.walker.tile != spot
        w.c.handleClose()
        return moved
    }

    func testAFocusingOrMenuOpenMeIsNotPushed() async {
        let control = await pushedAtTheFire(focusing: false, menuOpen: false)
        XCTAssertTrue(control, "control: the harness really pushes")
        let focusing = await pushedAtTheFire(focusing: true, menuOpen: false)
        XCTAssertFalse(focusing)
        let menu = await pushedAtTheFire(focusing: false, menuOpen: true)
        XCTAssertFalse(menu)
    }

    func testAHitOnTheShoreDropsMeIntoThePond() async {
        let w = await world(me: p(15, 14), b: p(18, 14))
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 3, direction: .left)
        run(w.scene, 1.5)
        XCTAssertEqual(w.scene.walker.tile, p(14, 14))
        XCTAssertTrue(w.scene.isMeInWater)
    }

    private func swimming() async -> World {
        let w = await world(me: p(15, 14), b: p(18, 14), facing: .left)
        press(w.scene, zKey)
        run(w.scene, 0.5)
        XCTAssertEqual(w.scene.walker.tile, p(14, 14), "test precondition")
        XCTAssertTrue(w.scene.isMeInWater, "test precondition")
        return w
    }

    func testASwimmerIsPushedThroughTheWater() async {
        let w = await swimming()
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .left)
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(13, 14))
    }

    func testADivingMeIsPassedOver() async {
        let w = await swimming()
        now = now.addingTimeInterval(1)   // the jump key is held back by the clock, which stands still here
        press(w.scene, zKey)
        run(w.scene, 0.3)
        XCTAssertTrue(w.scene.isDiving, "test precondition")
        let before = w.scene.impactCount
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .left)
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(14, 14))
        XCTAssertEqual(w.scene.impactCount, before)
        XCTAssertEqual(w.scene.impactCount, 0)
    }

    // MARK: - Frames only a modified app sends

    func testASnowballWithoutADirectionDoesNothing() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 2, direction: nil)
        XCTAssertEqual(w.scene.snowballFlightCount, 0)
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(14, 12))
        XCTAssertEqual(w.scene.impactCount, 0)
    }

    func testAnUnknownOrHugeTargetFliesAsAMiss() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        w.c.showSnowball(from: w.b.id, on: String(repeating: "x", count: 10_000), tiles: 3, direction: .right)
        XCTAssertEqual(w.scene.snowballFlightCount, 1)
        run(w.scene, 1.0)
        XCTAssertEqual(w.scene.walker.tile, p(14, 12))
        XCTAssertEqual(w.scene.impactCount, 0)
    }

    func testAFloodOfSnowballsStaysUnderTheCap() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        for _ in 0..<500 { w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 1, direction: .right) }
        XCTAssertLessThanOrEqual(w.scene.snowballFlightCount, PlazaSnowballLayer.maxFlights)
        XCTAssertLessThanOrEqual(w.scene.snowballNodeCount, PlazaSnowballLayer.maxFlights * 8)
        XCTAssertEqual(w.scene.impactCount, 0, "refused flights draw no impact")
    }

    // MARK: - A covered window

    func testCoveringTheWindowMidFlightStillPushesMe() async {
        let w = await world(me: p(14, 12), b: p(10, 12))
        w.c.showSnowball(from: w.b.id, on: w.me.id, tiles: 2, direction: .right)
        run(w.scene, 0.15)
        XCTAssertEqual(w.scene.walker.tile, p(14, 12), "test precondition")
        w.c.setRendering(visible: false)
        XCTAssertEqual(w.scene.walker.tile, p(16, 12))
        XCTAssertEqual(w.scene.snowballFlightCount, 0)
        XCTAssertEqual(w.scene.snowballSpriteCount, 0, "no sprite is left on the paused scene")
    }
}
