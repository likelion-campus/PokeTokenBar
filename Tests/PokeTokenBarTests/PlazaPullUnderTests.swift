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

    func testADiverTargetsTheShoreNeighbourWhenTheWaterBehindIsFree() {
        let members = ["shore": p(31, 16), "swimmer": p(32, 15), "far": p(30, 16)]
        let all = PlazaPullUnder.targets(diver: p(32, 16), members: members, isWater: isWater, isFree: { _ in true })
        XCTAssertEqual(all, ["shore": p(31, 16)], "not one in the water, not one two tiles off")
        let blocked = PlazaPullUnder.targets(diver: p(32, 16), members: members, isWater: isWater, isFree: { $0 != self.p(33, 16) })
        XCTAssertEqual(blocked, [:], "nowhere to back off to")
        XCTAssertEqual(PlazaPullUnder.targets(diver: p(31, 16), members: ["a": p(30, 16)], isWater: isWater, isFree: { _ in true }), [:],
                       "a diver is in the water")
    }

    func testTheDragGoesTowardsAPullerRightInFrontOrOneBehindThat() {
        XCTAssertEqual(PlazaPullUnder.drag(victim: p(31, 16), puller: p(32, 16), isWater: isWater), .right)
        XCTAssertEqual(PlazaPullUnder.drag(victim: p(31, 16), puller: p(33, 16), isWater: isWater), .right)
    }

    func testNoDragFromAnywhereElse() {
        XCTAssertNil(PlazaPullUnder.drag(victim: p(31, 16), puller: p(34, 16), isWater: isWater), "three tiles off")
        XCTAssertNil(PlazaPullUnder.drag(victim: p(31, 16), puller: p(32, 17), isWater: isWater), "diagonal")
        XCTAssertNil(PlazaPullUnder.drag(victim: p(31, 16), puller: p(30, 16), isWater: isWater), "the puller is on land")
        XCTAssertNil(PlazaPullUnder.drag(victim: p(30, 16), puller: p(32, 16), isWater: isWater), "I am not on the shore")
        XCTAssertNil(PlazaPullUnder.drag(victim: p(33, 16), puller: p(34, 16), isWater: isWater), "I am already in the water")
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
        let (c, scene, me, other, _) = try await open(me: p(31, 16), teammate: p(34, 16))
        c.showPull(from: other.id, on: me.id)
        run(scene, 1)
        XCTAssertEqual(scene.walker.tile, p(31, 16), "the sender is three tiles off")
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
        XCTAssertNotEqual(c.hint, L(.ko).plazaPullHint(nickname: "민수"), "swimming on the surface is not an ambush")
    }
}
