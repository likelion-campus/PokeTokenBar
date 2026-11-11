import XCTest
import AppKit
@testable import PokeTokenBar

private final class NoSprites: PlazaSpriteFetching, @unchecked Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// A teammate jumping out of the tall grass beside me makes my Mac hop me. Patch A covers x 5-11, y 5-8; row 4 is open ground.
@MainActor
final class PlazaStartleControllerTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    private func defaults() -> UserDefaults {
        let name = "plaza.startle.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func node(_ name: String) -> Node {
        let settings = TeamSettings(defaults: defaults())
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaStartleControllerTests-\(UUID())")
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

    private func controller(_ me: Node, start: TilePoint) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        prefs.saveLastTile(start)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoSprites()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in self.now },
                                     spriteRetrySleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                     dittoLoopSleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                                     dittoSeed: { 7 })
    }

    /// How high I am a tenth of a second on.
    private func lift(_ scene: PlazaScene) -> CGFloat {
        scene.update(0)
        scene.update(0.1)
        return scene.jumpLift(memberID: nil) ?? 0
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    /// Me at `myTile` with the plaza open, and a teammate standing at `theirTile`. Returns what the teammate hears from me.
    private func setUp(me myTile: TilePoint, teammate theirTile: TilePoint, another: TilePoint? = nil) async throws
        -> (c: PlazaWindowController, scene: PlazaScene, other: Node, heard: () -> [TeamEmoteKind]) {
        let me = node("나"), other = node("민수")
        hub.connect(me.transport, to: other.transport)
        await settle()
        final class Box { var kinds: [TeamEmoteKind] = [] }
        let box = Box()
        other.session.onEmote = { _, emote in box.kinds.append(emote.kind) }
        let c = controller(me, start: myTile)
        c.prepareScene()
        let scene = try XCTUnwrap(c.scene)
        XCTAssertNotNil(scene.tallGrassLayer, "the tall grass art ships with the app")
        other.session.updatePlazaPosition(inPlaza: true, tile: theirTile, facing: .down, isWalking: false)
        if let another {
            let third = node("지영")
            hub.connect(me.transport, to: third.transport)
            await settle()
            third.session.updatePlazaPosition(inPlaza: true, tile: another, facing: .down, isWalking: false)
        }
        await settle()
        XCTAssertEqual(scene.memberTiles[other.id], theirTile)
        return (c, scene, other, { box.kinds })
    }

    func testAJumpOutOfTheGrassBesideMeHopsMeAndTellsTheTeam() async throws {
        let (c, scene, other, heard) = try await setUp(me: p(4, 5), teammate: p(5, 5))
        XCTAssertEqual(scene.walker.facing, .down)
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertGreaterThan(lift(scene), 0, "I hopped")
        XCTAssertEqual(scene.walker.facing, .right, "and turned to the grass")
        XCTAssertEqual(heard(), [.jump, .exclaim])
    }

    func testAJumpOnOpenGroundBesideMeDoesNothing() async throws {
        let (c, scene, other, heard) = try await setUp(me: p(7, 3), teammate: p(7, 4))
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertEqual(heard(), [])
        XCTAssertEqual(lift(scene), 0)
    }

    func testIAmStartledOnceInTheCooldown() async throws {
        let (c, _, other, heard) = try await setUp(me: p(7, 4), teammate: p(7, 5))
        c.showJump(memberID: other.id)
        now += PlazaStartle.cooldown - 0.1
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertEqual(heard(), [.jump, .exclaim])
        now += 0.2
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertEqual(heard(), [.jump, .exclaim, .jump, .exclaim])
    }

    func testNoStartleWithTheBackgroundHidden() async throws {
        let (c, _, other, heard) = try await setUp(me: p(7, 4), teammate: p(7, 5))
        c.toggleBackground()
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertEqual(heard(), [], "no grass is drawn, so nobody was hiding")
    }

    func testNoStartleInPhotoMode() async throws {
        let (c, scene, other, heard) = try await setUp(me: p(7, 4), teammate: p(7, 5))
        _ = scene.handleKeyDown(keyCode: 35, characters: "p", isRepeat: false)
        XCTAssertTrue(c.isPhotoMode)
        c.showJump(memberID: other.id)
        await settle()
        XCTAssertEqual(heard(), [])
    }

    // MARK: - Hints

    func testHiddenInTheGrassAloneShowsHowToStartle() async throws {
        let (c, _, _, _) = try await setUp(me: p(7, 6), teammate: p(20, 22))
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaHiddenHint)
    }

    func testHiddenBesideATeammateNamesWhoZWouldStartle() async throws {
        let (c, _, _, _) = try await setUp(me: p(7, 5), teammate: p(7, 4))
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaStartleHint(nickname: "민수"))
    }

    func testHiddenBesideTwoTeammatesNamesNoOne() async throws {
        let (c, _, _, _) = try await setUp(me: p(5, 5), teammate: p(4, 5), another: p(5, 4))
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaStartleManyHint)
    }

    func testOnOpenGroundBesideATeammateTheHintIsStillTalking() async throws {
        let (c, _, _, _) = try await setUp(me: p(7, 3), teammate: p(7, 4))
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaMemberHint(nickname: "민수"))
    }
}
