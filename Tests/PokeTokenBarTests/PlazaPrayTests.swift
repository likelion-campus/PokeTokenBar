import XCTest
import AppKit
@testable import PokeTokenBar

private struct NoPraySprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

/// A의 keyCode.
private let prayKey: UInt16 = 0

/// 광장에서 알이 하는 기도: A 키, 내 화면의 말풍선과 흔들림, 팀원에게 보내기, 받은 기도 걸러 내기.
@MainActor
final class PlazaPrayTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private let map = PlazaMapData.map

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        let received: Received
    }

    @MainActor final class Received {
        var emotes: [TeamEmote] = []
    }

    /// 컨트롤러에 끼우는 가짜 세이브: 기도 횟수만 센다.
    @MainActor final class Prayers {
        var count = 0
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
    private static let egg = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)

    private func node(_ name: String, character: TeamMonSummary = PlazaPrayTests.pikachu) -> Node {
        let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.pray.\(UUID())"))
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaPrayTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: character, dex: []) })
        session.updateCharacter(character)
        session.applySettings()
        let received = Received()
        session.onEmote = { [received] _, emote in received.emotes.append(emote) }
        return Node(settings: settings, session: session, transport: transport, received: received)
    }

    private func controller(_ me: Node, speciesID: Int?, prayers: Prayers, start: TilePoint? = nil) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.pray.prefs.\(UUID())"))
        prefs.saveLastTile(start ?? map.spawn)
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: NoPraySprites()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil },
                                     pray: { prayers.count += 1 }, prayerCount: { prayers.count },
                                     session: me.session, clock: { [unowned self] in now },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed })
    }

    /// 팻말·모닥불에서 멀고 풀숲도 아닌 걸을 수 있는 칸. 여기서는 다른 안내가 뜨지 않아 기도 안내가 보인다.
    /// 풀숲은 장면이 알고 있어서 조사용 장면을 하나 열어 묻는다.
    private func quietTile() -> TilePoint {
        let probe = controller(node("조사"), speciesID: 25, prayers: Prayers())
        probe.prepareScene()
        defer { probe.handleClose() }
        guard let scene = probe.scene else { return map.spawn }
        let landmarks = [map.boardTile] + map.campfireTiles
        for y in 0..<map.height {
            for x in 0..<map.width {
                let tile = TilePoint(x: x, y: y)
                let isFarFromLandmarks = landmarks.allSatisfy { abs($0.x - x) + abs($0.y - y) > 4 }
                if map.isWalkable(tile), isFarFromLandmarks, !scene.isGrass(tile) { return tile }
            }
        }
        return map.spawn
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    private func connect(_ a: Node, _ b: Node) async {
        hub.connect(a.transport, to: b.transport)
        await settle()
    }

    private func press(_ scene: PlazaScene, _ key: UInt16) {
        scene.handleKeyDown(keyCode: key, characters: "ㅁ", isRepeat: false)
    }

    /// 팀원을 광장 안 한 칸에 세우고, 내 장면이 그 팀원을 알 때까지 기다린다.
    private func standInPlaza(_ other: Node, seenBy c: PlazaWindowController, me: Node) async {
        let tile = TilePoint(x: map.spawn.x + 3, y: map.spawn.y)
        other.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        let id = other.settings.memberID
        // 세션이 먼저 알고 컨트롤러는 한 박자 늦게 따라온다. 장면이 그 칸을 알면 컨트롤러도 안다.
        await waitUntil { me.session.members[id]?.inPlaza == true && c.scene?.memberTiles[id] == tile }
        await settle()
    }

    // MARK: - 키

    /// A prays, also with Hangul input (the character is "ㅁ"); not with Cmd/Ctrl/Opt or when held.
    func testAKeyPraysWithHangulInputOnly() {
        let scene = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: map.spawn, zoom: 2, nickname: "나")
        var presses = 0
        scene.onPrayKey = { presses += 1 }
        XCTAssertEqual(scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: false), .swallowed)
        XCTAssertEqual(presses, 1)
        scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: true)
        for mod: NSEvent.ModifierFlags in [.command, .control, .option] {
            scene.handleKeyDown(keyCode: prayKey, characters: "ㅁ", isRepeat: false, modifiers: mod)
        }
        XCTAssertEqual(presses, 1, "a held key or a shortcut is not a prayer")
    }

    // MARK: - 내 기도

    /// An egg's A counts one prayer, shows the bubble and the wobble at once, and tells the team.
    func testAnEggPraysCountsShowsAndTellsTheTeam() async {
        let me = node("나", character: Self.egg), other = node("민수")
        let prayers = Prayers()
        let c = controller(me, speciesID: nil, prayers: prayers, start: quietTile())
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        XCTAssertNil(scene.interactionTarget, "test precondition: nothing else to hint at")
        XCTAssertFalse(scene.isGrass(scene.walker.tile), "test precondition: not hidden in grass")
        press(scene, prayKey)
        XCTAssertEqual(prayers.count, 1)
        XCTAssertEqual(scene.shownEmote(memberID: nil), .pray, "my own bubble shows at once")
        XCTAssertEqual(c.hint, "기도 1번", "the count shows right after a prayer")
        now = now.addingTimeInterval(PlazaWindowController.prayedHintDuration)
        c.endPrayedHintIfDue()
        XCTAssertEqual(c.hint, L(.ko).plazaPrayHint(prayers: 1), "then the usual hint returns, with the count")

        var t: TimeInterval = 0
        scene.update(t)
        while t < PlazaActor.wobbleDuration / 8 { t += 1.0 / 120; scene.update(t) }
        XCTAssertGreaterThan(abs(scene.wobbleTilt(memberID: nil) ?? 0), PlazaActor.wobbleAngle * 0.3, "the egg leans mid-wobble")
        while t < PlazaActor.wobbleDuration + 0.05 { t += 1.0 / 60; scene.update(t) }
        XCTAssertEqual(scene.wobbleTilt(memberID: nil), 0, "and comes to rest")

        await waitUntil { !other.received.emotes.isEmpty }
        XCTAssertEqual(other.received.emotes, [TeamEmote(kind: .pray, targetMemberID: nil)])
    }

    /// Every press counts, but only one prayer per emote interval goes out to the team.
    func testEveryPressCountsButTheTeamHearsOnePerInterval() async {
        let me = node("나", character: Self.egg), other = node("민수")
        let prayers = Prayers()
        let c = controller(me, speciesID: nil, prayers: prayers)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        for _ in 0..<5 { press(scene, prayKey) }
        XCTAssertEqual(prayers.count, 5, "the count is never throttled")
        await waitUntil { !other.received.emotes.isEmpty }
        await settle()
        XCTAssertEqual(other.received.emotes.count, 1, "the burst went out once")

        now = now.addingTimeInterval(PlazaWindowController.emoteInterval * 2)
        press(scene, prayKey)
        XCTAssertEqual(prayers.count, 6)
        await waitUntil { other.received.emotes.count == 2 }
        XCTAssertEqual(other.received.emotes.map(\.kind), [.pray, .pray])
    }

    /// A hatched Pokémon does not pray: no count, no bubble, nothing sent, no hint.
    func testAHatchedPokemonDoesNotPray() async {
        let me = node("나"), other = node("민수")
        let prayers = Prayers()
        let c = controller(me, speciesID: 25, prayers: prayers)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        press(scene, prayKey)
        await settle()
        XCTAssertEqual(prayers.count, 0)
        XCTAssertNil(scene.shownEmote(memberID: nil))
        XCTAssertEqual(scene.wobbleTilt(memberID: nil), 0)
        XCTAssertEqual(other.received.emotes, [])
        c.refreshHintForTesting()
        XCTAssertNotEqual(c.hint, L(.ko).plazaPrayHint(prayers: 0))
    }

    /// An egg cannot walk and usually stands beside the board, whose hint is always up there. The count still shows
    /// right after a prayer, and the board hint returns afterwards.
    func testThePrayerCountShowsEvenBesideTheBoard() {
        let me = node("나", character: Self.egg)
        let prayers = Prayers()
        let besideBoard = TilePoint(x: map.boardTile.x, y: map.boardTile.y - 1)
        let c = controller(me, speciesID: nil, prayers: prayers, start: besideBoard)
        c.prepareScene()
        let scene = c.scene!
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint, "test precondition: the board hint is up")
        press(scene, prayKey)
        XCTAssertEqual(c.hint, "기도 1번")
        c.endPrayedHintIfDue()
        XCTAssertEqual(c.hint, "기도 1번", "not before its time")
        now = now.addingTimeInterval(PlazaWindowController.prayedHintDuration)
        c.endPrayedHintIfDue()
        XCTAssertEqual(c.hint, L(.ko).plazaBoardHint)
    }

    /// An egg that has not prayed yet is told how; the count joins once there is one.
    func testAnEggIsToldHowToPray() {
        let me = node("나", character: Self.egg)
        let prayers = Prayers()
        let c = controller(me, speciesID: nil, prayers: prayers, start: quietTile())
        c.prepareScene()
        XCTAssertNil(c.scene?.interactionTarget, "test precondition: nothing else to hint at")
        XCTAssertEqual(c.scene.map { $0.isGrass($0.walker.tile) }, false, "test precondition: not hidden in grass")
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, "A를 눌러 기도하기")
        prayers.count = 12
        c.refreshHintForTesting()
        XCTAssertEqual(c.hint, "A를 눌러 기도하기 · 기도 12번")
    }

    // MARK: - 받은 기도

    /// A prayer from an egg teammate standing in the plaza shows over their egg, with the wobble.
    func testATeammatesPrayerShowsOverTheirEgg() async {
        let me = node("나"), other = node("민수", character: Self.egg)
        let c = controller(me, speciesID: 25, prayers: Prayers())
        c.prepareScene()
        await connect(me, other)
        await standInPlaza(other, seenBy: c, me: me)
        let scene = c.scene!, id = other.settings.memberID
        c.showPray(memberID: id)
        XCTAssertEqual(scene.shownEmote(memberID: id), .pray)
        XCTAssertNil(scene.shownEmote(memberID: nil), "not over me")
        var t: TimeInterval = 0
        scene.update(t)
        while t < PlazaActor.wobbleDuration / 8 { t += 1.0 / 120; scene.update(t) }
        XCTAssertNotEqual(scene.wobbleTilt(memberID: id), 0, "their egg wobbles")
        XCTAssertEqual(scene.wobbleTilt(memberID: nil), 0, "mine does not")
    }

    /// Only an egg prays. An honest app never sends a prayer for a hatched Pokémon, so one that arrives is dropped.
    func testAPrayerFromAHatchedTeammateIsDropped() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, speciesID: 25, prayers: Prayers())
        c.prepareScene()
        await connect(me, other)
        await standInPlaza(other, seenBy: c, me: me)
        let scene = c.scene!, id = other.settings.memberID
        c.showPray(memberID: id)
        XCTAssertNil(scene.shownEmote(memberID: id))
        XCTAssertEqual(scene.wobbleTilt(memberID: id), 0)
    }

    /// A prayer from an egg teammate who is not in the plaza, or from nobody we know, is dropped too.
    func testAPrayerFromOutsideThePlazaIsDropped() async {
        let me = node("나"), other = node("민수", character: Self.egg)
        let c = controller(me, speciesID: 25, prayers: Prayers())
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        await waitUntil { me.session.members[id] != nil }
        await settle()
        c.showPray(memberID: id)
        XCTAssertNil(c.scene?.shownEmote(memberID: id), "they are not in the plaza")
        c.showPray(memberID: "nobody")
    }

    /// A closed plaza shows nothing and creates no scene for a prayer.
    func testAReceivedPrayerDoesNothingWhenClosed() {
        let me = node("나")
        let c = controller(me, speciesID: 25, prayers: Prayers())
        c.showPray(memberID: "anyone")
        XCTAssertNil(c.scene)
    }

    // MARK: - 그림

    /// The prayer bubble has its own picture, not another kind's.
    func testThePrayerBubbleHasItsOwnArt() {
        func pixels(_ kind: TeamEmoteKind) -> Data? { PlazaEmoteArt.image(kind, scale: 1).dataProvider?.data as Data? }
        XCTAssertNotNil(pixels(.pray))
        for other: TeamEmoteKind in [.heart, .party, .exclaim, .question] {
            XCTAssertNotEqual(pixels(.pray), pixels(other), "\(other)")
        }
    }
}
