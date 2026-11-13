import XCTest
import AppKit
@testable import PokeTokenBar

private final class NoSprites: PlazaSpriteFetching, @unchecked Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// 물귀신 at the right pond (x32-38 y14-20 is water, (31,16) is its shore): a diver pulls the teammate on the shore beside it in.
@MainActor
final class PlazaPullUnderTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let map = PlazaMapData.map
    private let cKey: UInt16 = 8

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }
    private func isWater(_ t: TilePoint) -> Bool { map.isWater(t) }

    // MARK: - Rule

    func testTheMapIsAsTheseTestsAssume() {
        XCTAssertTrue(isWater(p(32, 16)) && isWater(p(33, 16)) && isWater(p(34, 16)))
        XCTAssertFalse(isWater(p(31, 16)))
        XCTAssertFalse(isWater(p(30, 16)))
    }

    // A one-row world: water from x=10 on, land before it, `blocked` tiles are bushes, `ice` tiles are land on water.
    private struct Row {
        var water: Set<TilePoint> = Set((10...14).map { TilePoint(x: $0, y: 0) })
        var blocked: Set<TilePoint> = []
        var occupied: Set<TilePoint> = []
        func isWater(_ t: TilePoint) -> Bool { water.contains(t) }
        func isWalkable(_ t: TilePoint) -> Bool { !water.contains(t) && !blocked.contains(t) }
        func isFree(_ t: TilePoint) -> Bool { !occupied.contains(t) }
        func target(me: TilePoint, facing: PlazaDirection = .left, _ members: [String: TilePoint])
            -> (id: String, pull: PlazaPullUnder.Pull)? {
            PlazaPullUnder.target(me: me, facing: facing, members: members, isWater: isWater, isWalkable: isWalkable, isFree: isFree)
        }
    }

    func testTargetsAMateOneTwoOrThreeTilesAheadAndStepsBack() {
        let row = Row()
        for k in 1...3 {
            let hit = row.target(me: p(10, 0), ["m": p(10 - k, 0)])
            XCTAssertEqual(hit?.id, "m", "\(k) ahead")
            XCTAssertEqual(hit?.pull, PlazaPullUnder.Pull(direction: .right, tiles: k, landing: p(10, 0), stepsBack: true))
        }
        XCTAssertNil(row.target(me: p(10, 0), ["m": p(6, 0)]), "four ahead is out of reach")
    }

    func testTheNearerMateOnTheLineIsTheOneTargeted() {
        let hit = Row().target(me: p(10, 0), ["far": p(7, 0), "near": p(8, 0)])
        XCTAssertEqual(hit?.id, "near")
    }

    func testABushOnTheWayMeansNoTarget() {
        var row = Row()
        row.blocked = [p(9, 0)]
        XCTAssertNil(row.target(me: p(10, 0), ["m": p(8, 0)]))
        row.blocked = [p(8, 0)]
        XCTAssertNil(row.target(me: p(10, 0), ["m": p(7, 0)]))
    }

    func testAnOccupiedLandingTileMeansNoTarget() {
        var row = Row()   // I am two tiles into the pond: the landing is the first water tile (10), not my tile
        row.occupied = [p(10, 0)]
        XCTAssertNil(row.target(me: p(11, 0), ["m": p(8, 0)]))
        row.occupied = []
        let hit = row.target(me: p(11, 0), ["m": p(8, 0)])
        XCTAssertEqual(hit?.pull, PlazaPullUnder.Pull(direction: .right, tiles: 2, landing: p(10, 0), stepsBack: false))
    }

    func testPullingOntoMyTileNeedsFreeWaterBehindMe() {
        var row = Row()
        row.occupied = [p(11, 0)]
        XCTAssertNil(row.target(me: p(10, 0), ["m": p(8, 0)]), "someone is behind me")
        row.occupied = []
        row.water = [p(10, 0)]
        XCTAssertNil(row.target(me: p(10, 0), ["m": p(8, 0)]), "no water behind me")
    }

    func testAMateBesideMeIsTheFallbackWhenTheFacingLineIsEmpty() {
        var row = Row()
        row.water = [p(10, 0), p(10, 1)]
        let hit = row.target(me: p(10, 0), ["m": p(10, -1)])
        XCTAssertEqual(hit?.pull, PlazaPullUnder.Pull(direction: .down, tiles: 1, landing: p(10, 0), stepsBack: true))
        row.blocked = [p(8, 0)]
        XCTAssertEqual(row.target(me: p(10, 0), ["blocked": p(7, 0), "m": p(10, -1)])?.id, "m", "the facing mate cannot be pulled")
        XCTAssertNil(row.target(me: p(10, 0), ["far": p(10, -2)]), "beside means beside")
    }

    func testAMateInTheWaterIsNeverPulledAndAMateOnIceIsOnLand() {
        var row = Row()
        XCTAssertNil(row.target(me: p(12, 0), ["swimmer": p(11, 0)]))
        // Ice at 10 and 11, open water at 12 and 13: the mate on the ice falls into 12, the first real water.
        row.water = [p(12, 0), p(13, 0)]
        let hit = row.target(me: p(13, 0), ["m": p(11, 0)])
        XCTAssertEqual(hit?.pull, PlazaPullUnder.Pull(direction: .right, tiles: 1, landing: p(12, 0), stepsBack: false))
        XCTAssertNil(row.target(me: p(9, 0), ["m": p(8, 0)]), "I am on land")
    }

    func testTheDragIsTheDirectionAndTileCountToTheFirstWater() {
        let row = Row()
        func drag(_ v: Int, _ pl: Int) -> PlazaDirection? {
            let r = PlazaPullUnder.drag(victim: p(v, 0), puller: p(pl, 0), isWater: row.isWater, isWalkable: row.isWalkable)
            return r?.direction
        }
        func tiles(_ v: Int, _ pl: Int) -> Int? {
            PlazaPullUnder.drag(victim: p(v, 0), puller: p(pl, 0), isWater: row.isWater, isWalkable: row.isWalkable)?.tiles
        }
        XCTAssertEqual(drag(9, 10), .right)
        for k in 1...3 {
            XCTAssertEqual(tiles(10 - k, 10), k)
            XCTAssertEqual(tiles(10 - k, 11), k, "the puller's step back has already arrived")
        }
        XCTAssertEqual(tiles(9, 13), 1, "four tiles off still lands in the first water")
    }

    func testNoDragFromAnywhereElse() {
        var row = Row()
        func drag(_ v: TilePoint, _ pl: TilePoint) -> Bool {
            PlazaPullUnder.drag(victim: v, puller: pl, isWater: row.isWater, isWalkable: row.isWalkable) != nil
        }
        XCTAssertFalse(drag(p(9, 0), p(14, 0)), "five tiles off")
        XCTAssertFalse(drag(p(6, 0), p(10, 0)), "the first water is four tiles away")
        XCTAssertFalse(drag(p(9, 0), p(10, 1)), "diagonal")
        XCTAssertFalse(drag(p(9, 0), p(8, 0)), "the puller is on land")
        XCTAssertFalse(drag(p(11, 0), p(12, 0)), "I am already in the water")
        row.blocked = [p(8, 0)]
        XCTAssertFalse(drag(p(7, 0), p(10, 0)), "a bush on the way")
    }

    func testTheDragWorksAlongAColumnToo() {
        var row = Row()
        row.water = [p(0, 10)]
        let r = PlazaPullUnder.drag(victim: p(0, 8), puller: p(0, 10), isWater: row.isWater, isWalkable: row.isWalkable)
        XCTAssertEqual(r?.direction, .down)
        XCTAssertEqual(r?.tiles, 2)
    }

    // MARK: - In the plaza

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private func defaults() -> UserDefaults {
        let name = "plaza.pull.\(UUID())"
        return TestDefaults.make(suite: name)
    }

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: defaults())
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaPullUnderTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
        session.updateCharacter(mon)
        session.applySettings()
        return Node(settings: settings, session: session, transport: transport)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private var sceneTime = 0.0
    private func run(_ s: PlazaScene, _ seconds: TimeInterval) {
        let end = sceneTime + seconds
        s.update(sceneTime)
        while sceneTime < end { sceneTime += 1.0 / 30; s.update(sceneTime) }
    }

    private final class Heard { var emotes: [TeamEmote] = [] }

    /// Me at `myTile` with the plaza open, and a teammate standing at `theirTile`.
    private func open(me myTile: TilePoint, plunging: PlazaDirection? = nil, teammate theirTile: TilePoint) async throws
        -> (c: PlazaWindowController, scene: PlazaScene, me: Node, other: Node, heard: Heard) {
        let me = node("나"), other = node("민수")
        hub.connect(me.transport, to: other.transport)
        await settle()
        let heard = Heard()
        other.session.onEmote = { _, emote in heard.emotes.append(emote) }
        let prefs = PlazaPreferences(defaults: defaults())
        prefs.saveLastTile(myTile)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                      nickname: { "나" }, memberID: { me.settings.memberID },
                                      subject: { .init(speciesID: 25, isShiny: false) },
                                      myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in self.now },
                                      spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                      dittoLoopSleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                      dittoSeed: { 7 })
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        XCTAssertEqual(scene.walker.tile, myTile)
        if let plunging {
            scene.plunge(plunging)
            run(scene, 1)
            XCTAssertTrue(scene.isMeInWater)
        }
        other.session.updatePlazaPosition(inPlaza: true, tile: theirTile, facing: .down, isWalking: false)
        await settle()
        XCTAssertEqual(scene.memberTiles[other.id], theirTile)
        return (c, scene, me, other, heard)
    }

    func testCWhileDivingSurfacesBacksOffAndTellsTheShoreTeammate() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(31, 16), plunging: .right, teammate: p(31, 16))
        scene.setDiving(true)
        XCTAssertTrue(scene.isDiving)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(scene.isDiving)
        XCTAssertFalse(c.isPhotoMode)   // the controller must outlive the key press
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        XCTAssertEqual(heard.emotes.first?.targetMemberID, other.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(33, 16), "I made room")
    }

    func testCWhileDivingWithNobodyOnTheShoreDoesNothing() async throws {
        let (c, scene, _, _, heard) = try await open(me: p(31, 16), plunging: .right, teammate: p(29, 16))
        scene.setDiving(true)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertTrue(scene.isDiving, "still under")
        XCTAssertFalse(c.isPhotoMode)
        XCTAssertEqual(heard.emotes.count, 0)
    }

    func testAPullDragsMeIntoTheWaterTheDiverLeft() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(32, 16))
        c.showPull(from: other.id, on: me.id)   // the diver's step back has not arrived yet
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(32, 16))
        XCTAssertTrue(scene.isMeInWater)
    }

    func testAPullOnSomeoneElseOrFromTheWrongPlaceDoesNotMoveMe() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(36, 16))
        c.showPull(from: other.id, on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16), "the sender is five tiles off")
        other.session.updatePlazaPosition(inPlaza: true, tile: p(32, 16), facing: .down, isWalking: false)
        await settle()
        c.showPull(from: other.id, on: "someone-else")
        c.showPull(from: other.id, on: nil)
        c.showPull(from: "nobody", on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16))
    }

    func testNoPullInPhotoMode() async throws {
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(32, 16))
        _ = scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(c.isPhotoMode)
        c.showPull(from: other.id, on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16))
    }

    func testThePullCarriesOnlyItsKindAndTarget() throws {
        let frame = try TeamWire.encode(.emote(TeamEmote(kind: .pull, targetMemberID: "m")))
        let body = try JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: [String: [String: String]]]
        XCTAssertEqual(body, ["emote": ["_0": ["kind": "pull", "targetMemberID": "m"]]])
    }

    // MARK: - Pulling from range (the right pond is x32-38 y14-20; row 17 east of it, x39-44, is open land)

    /// Plunges in from (39,17) to (38,17), swims `extra` more tiles west and turns to face the shore.
    private func swimOut(_ scene: PlazaScene, extra: Int = 0) {
        for _ in 0..<extra {
            _ = scene.handleKeyDown(keyCode: 123, characters: "", isRepeat: false)
            run(scene, 0.1)
            _ = scene.handleKeyUp(keyCode: 123)
            run(scene, 1)
        }
        scene.face(.right)
    }

    func testTheMapRowAssumedBelowIsOpenLand() {
        XCTAssertTrue(isWater(p(38, 17)))
        for x in 39...44 { XCTAssertTrue(map.isWalkable(p(x, 17)), "x=\(x)") }
    }

    func testCWhileSwimmingPullsAMateThreeTilesAheadWithoutSteppingBack() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(40, 17))
        swimOut(scene, extra: 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17))
        XCTAssertFalse(scene.isDiving)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        XCTAssertEqual(heard.emotes.first?.targetMemberID, other.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17), "the landing is the water tile in front, so I stay")
        XCTAssertFalse(scene.isDiving)
        withExtendedLifetime(c) {}
    }

    func testCWhileSwimmingPullsOntoMyTileAndStepsBack() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17), "I made room")
        withExtendedLifetime((c, other)) {}
    }

    func testCWhileDivingPullsFromRangeAndSurfaces() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        scene.setDiving(true)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(scene.isDiving)
        XCTAssertEqual(heard.emotes.map(\.kind), [.pull])
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(37, 17))
        withExtendedLifetime((c, other)) {}
    }

    func testCAtAnotherSwimmerStillTackles() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(37, 17))
        scene.face(.left)
        run(scene, 0.1)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertFalse(heard.emotes.isEmpty)
        XCTAssertFalse(heard.emotes.map(\.kind).contains(.pull), "nobody is on the shore")
        withExtendedLifetime((c, other)) {}
    }

    func testAFarPullSlidesMeThreeTilesAndSplashesBig() async throws {
        let (c, scene, me, other, _) = try await open(me: p(41, 17), teammate: p(38, 17))
        c.showPull(from: other.id, on: me.id)
        run(scene, 0.25)
        XCTAssertFalse(scene.isMeInWater, "still sliding")
        var splashed = 0
        for _ in 0..<30 { run(scene, 0.1); splashed = max(splashed, try XCTUnwrap(scene.pondLayer).dropletCount) }
        XCTAssertEqual(scene.walker.tile, p(38, 17), "the puller's own tile does not stop me")
        XCTAssertTrue(scene.isMeInWater)
        XCTAssertEqual(splashed, PlazaPondLayer.bigDroplets, "a big splash")
        withExtendedLifetime(c) {}
    }

    func testAPullStopsAtTheFirstWaterTileWhenThePullerIsFurtherOut() async throws {
        let (c, scene, me, other, _) = try await open(me: p(40, 17), teammate: p(36, 17))
        c.showPull(from: other.id, on: me.id)
        run(scene, 2)
        XCTAssertEqual(scene.walker.tile, p(38, 17))
    }

    func testNoFarPullInPhotoMode() async throws {
        let (c, scene, me, other, _) = try await open(me: p(41, 17), teammate: p(38, 17))
        _ = scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(c.isPhotoMode)
        c.showPull(from: other.id, on: me.id)
        run(scene, 2)
        XCTAssertEqual(scene.walker.tile, p(41, 17))
    }

    // MARK: - Hints

    func testDivingAloneShowsHowToPull() async throws {
        let (c, scene, _, _, _) = try await open(me: p(31, 16), plunging: .right, teammate: p(29, 16))
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaDivingHint)
    }

    func testDivingUnderATeammateNamesWhoCWouldPull() async throws {
        let (c, scene, _, _, _) = try await open(me: p(31, 16), plunging: .right, teammate: p(31, 16))
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"))
        scene.setDiving(false)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"), "swimming pulls too now")
    }
}

extension PlazaPullUnderTests {
    func testSwimmingWithAShoreMateAheadShowsThePullHint() async throws {
        let (c, scene, _, _, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(41, 17))
        swimOut(scene)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"))
        XCTAssertFalse(scene.isDiving)
    }

    func testSwimmingWithNobodyToPullAddsNoHintButDivingStillTeaches() async throws {
        let (c, scene, _, _, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(30, 17))
        swimOut(scene)
        c.refreshHintForTesting()
        XCTAssertNil(c.hint)
        scene.setDiving(true)
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaDivingHint)
    }

    func testCWhileDivingWithNothingToPullDoesNotEvenTurnMe() async throws {
        let (c, scene, _, other, heard) = try await open(me: p(39, 17), plunging: .left, teammate: p(37, 17))
        scene.face(.right)
        scene.setDiving(true)
        run(scene, 0.1)
        _ = scene.handleKeyDown(keyCode: cKey, characters: "c", isRepeat: false)
        await settle()
        XCTAssertEqual(scene.walker.facing, .right, "a swimmer beside me is no pull target and a diver cannot tackle")
        XCTAssertTrue(scene.isDiving)
        XCTAssertTrue(heard.emotes.isEmpty)
        withExtendedLifetime((c, other)) {}
    }

    func testThePullHintFollowsAMateWalkingIntoAndOutOfRange() async throws {
        let (c, scene, _, other, _) = try await open(me: p(39, 17), plunging: .left, teammate: p(40, 10))
        swimOut(scene, extra: 1)   // (37,17), facing the shore
        run(scene, 0.2)
        XCTAssertNil(c.hint)
        other.session.updatePlazaPosition(inPlaza: true, tile: p(40, 17), facing: .down, isWalking: false)
        await settle()
        run(scene, 6)
        XCTAssertEqual(scene.memberTiles[other.id], p(40, 17))
        XCTAssertEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"), "no key press needed")
        other.session.updatePlazaPosition(inPlaza: true, tile: p(40, 10), facing: .down, isWalking: false)
        await settle()
        run(scene, 6)
        XCTAssertEqual(scene.memberTiles[other.id], p(40, 10))
        XCTAssertNil(c.hint)
    }
}
