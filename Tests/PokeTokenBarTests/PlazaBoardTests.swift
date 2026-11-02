import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private struct BoardProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [1: ["en": "P1", "ko": "포1"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: 1, captureRate: 255)] }
}

/// 배너 타이머를 시계 대신 손으로 푼다.
@MainActor
private final class SleepGate {
    private(set) var durations: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>?] = []

    func sleep(_ d: Duration) async {
        durations.append(d)
        await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ index: Int) {
        waiting[index]?.resume()
        waiting[index] = nil
    }

    func releaseAll() { for i in waiting.indices { release(i) } }
}

private let spaceKey: UInt16 = 49, escKey: UInt16 = 53

private func event(_ id: String = "e1", author: String = "a", nick: String = "민수", kind: TeamEventKind = .hatch,
                   species: String = "깨봉이", from: String? = nil, shiny: Bool = false,
                   day: String = "2026-10-30", at: Date? = nil) -> TeamEvent {
    TeamEvent(id: id, authorID: author, authorNickname: nick, kind: kind, speciesID: 25, fromSpeciesID: from == nil ? nil : 24,
              speciesName: species, fromSpeciesName: from, form: nil, isShiny: shiny, nature: nil, rarity: .common,
              day: day, occurredAt: at)
}

final class PlazaBoardTextTests: XCTestCase {
    private let l = L(.ko)

    func testEventTextPerKind() {
        XCTAssertEqual(l.teamEventText(event()), "민수의 알에서 깨봉이가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(shiny: true)), "민수의 알에서 이로치 깨봉이가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .dittoReveal)), "민수의 포켓몬은 사실 메타몽이었어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .graduate)), "민수의 깨봉이가 졸업했어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "딱충이", from: "깨봉이")), "민수의 깨봉이가 딱충이로 진화했어요")
    }

    func testEventTextParticlesFollowFinalConsonant() {
        // 받침 있음: 이 / 으로, 받침 없음: 가 / 로, ㄹ 받침: 로
        XCTAssertEqual(l.teamEventText(event(species: "피카츄")), "민수의 알에서 피카츄가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(species: "꼬렛")), "민수의 알에서 꼬렛이 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "리자드", from: "파이리")), "민수의 파이리가 리자드로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "리자몽", from: "리자드")), "민수의 리자드가 리자몽으로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "이상해꽃", from: "이상해풀")), "민수의 이상해풀이 이상해꽃으로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "알", from: "삐")), "민수의 삐가 알로 진화했어요")
    }

    func testEventTextHasNoUsageNumbers() {
        for kind in [TeamEventKind.hatch, .evolve, .graduate, .dittoReveal] {
            let text = l.teamEventText(event(kind: kind, from: "깨봉이", shiny: true))
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "\(kind): \(text)")
        }
    }
}

@MainActor
final class PlazaBoardRowTests: XCTestCase {
    private var dirs: [URL] = []
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func feed() -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardRowTests-\(UUID())")
        dirs.append(dir)
        return TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me",
                             clock: { Date(timeIntervalSince1970: 1_793_400_000) }, calendar: calendar)
    }

    private func reaction(_ id: String, by nick: String, _ kind: TeamReactionKind, on e: String = "e1", author: String? = nil) -> TeamReaction {
        TeamReaction(id: id, eventID: e, authorID: author ?? nick, authorNickname: nick, kind: kind,
                     text: kind == .comment ? "hi" : nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100))
    }

    func testRowsFollowFeedOrderNewestFirst() {
        let f = feed()
        f.insert(event("old", day: "2026-10-28"))
        f.insert(event("new", day: "2026-10-30"))
        XCTAssertEqual(PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar).map(\.id), ["new", "old"])
    }

    func testDateShowsTimeOnlyWhenKnown() {
        let f = feed()
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 5))!
        f.insert(event("timed", at: at))
        f.insert(event("dated", day: "2026-10-29"))
        let rows = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)
        let l = L(.ko)
        XCTAssertEqual(rows.first { $0.id == "timed" }?.date, l.teamBoardDate(month: 10, day: 30, time: "14:05"))
        XCTAssertEqual(rows.first { $0.id == "dated" }?.date, l.teamBoardDate(month: 10, day: 29, time: nil))
        XCTAssertNotEqual(rows.first { $0.id == "timed" }?.date, rows.first { $0.id == "dated" }?.date)
    }

    func testRowFlagsBigAndShiny() {
        let f = feed()
        f.insert(event("big", kind: .graduate, shiny: true))
        f.insert(event("small", kind: .evolve, from: "깨봉이", day: "2026-10-29"))
        let rows = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)
        XCTAssertEqual(rows.first { $0.id == "big" }.map { ($0.isBig, $0.isShiny) }.map { [$0.0, $0.1] }, [true, true])
        XCTAssertEqual(rows.first { $0.id == "small" }.map { ($0.isBig, $0.isShiny) }.map { [$0.0, $0.1] }, [false, false])
    }

    func testReactionsGroupedByKindWithNicknamesAndCommentsHidden() {
        let f = feed()
        f.insert(event())
        f.insert(reaction("r1", by: "영희", .cute))
        f.insert(reaction("r2", by: "철수", .cute))
        f.insert(reaction("r3", by: "영희", .congrats))
        f.insert(reaction("r4", by: "철수", .comment))
        let row = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)[0]
        XCTAssertEqual(row.reactions.map(\.kind), [.cute, .congrats])
        XCTAssertEqual(row.reactions.map(\.nicknames), [["영희", "철수"], ["영희"]])
    }

    func testMyReactionIsMarkedSoItsButtonCanBeDisabled() {
        let f = feed()
        f.insert(event())
        f.insert(reaction("r1", by: "나", .lol, author: "me"))
        let row = PlazaBoardRow.rows(feed: f, myMemberID: "me", calendar: calendar)[0]
        XCTAssertEqual(row.mine, [.lol])
        XCTAssertEqual(PlazaBoardRow.buttonKinds, [.cute, .lol, .congrats])
    }
}

@MainActor
final class PlazaBoardTests: XCTestCase {
    private var hub: FakeTransportHub!
    private var suites: [String] = []
    private var dirs: [URL] = []
    private var code: TeamCode!
    private let map = PlazaMapData.map
    private let gate = SleepGate()

    override func setUp() async throws {
        hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        code = TeamCode.generate(using: &rng)
    }

    override func tearDown() async throws {
        gate.releaseAll()
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []; dirs = []
    }

    @MainActor private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let feed: TeamFeedStore
        let transport: FakeTeamTransport
        var id: String { settings.memberID }
    }

    private static let pikachu = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)

    private func node(_ name: String) -> Node {
        let suite = "plaza.board.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: Self.pikachu, dex: []) })
        session.updateCharacter(Self.pikachu)
        session.applySettings()
        return Node(settings: settings, session: session, feed: feed, transport: transport)
    }

    private func controller(_ me: Node, start: TilePoint) -> PlazaWindowController {
        let name = "plaza.board.prefs.\(UUID())"
        suites.append(name)
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: name)!)
        prefs.saveLastTile(start)
        let gate = gate, myID = me.id
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { myID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, feed: me.feed,
                                     bannerSleep: { await gate.sleep($0) })
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func step(_ scene: PlazaScene, seconds: TimeInterval) {
        var t: TimeInterval = 0
        scene.update(t)
        while t < seconds { t += 1.0 / 30; scene.update(t) }
    }

    private func space(_ scene: PlazaScene) { scene.handleKeyDown(keyCode: spaceKey, characters: " ", isRepeat: false) }
    private var aboveBoard: TilePoint { TilePoint(x: map.boardTile.x, y: map.boardTile.y - 1) }

    private func hatch() -> CompanionTeamEvent {
        CompanionTeamEvent(kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "Pikachu", fromSpeciesName: nil,
                           form: nil, isShiny: false, nature: nil, rarity: .common)
    }

    /// 두 노드를 잇고 상대가 광장 안 `tile`에 선 것을 내 장면이 볼 때까지 기다린다.
    private func connected(otherAt tile: TilePoint, start: TilePoint)
        async -> (c: PlazaWindowController, me: Node, other: Node) {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: start)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await waitUntil { me.session.members[other.id] != nil }
        other.session.updatePlazaPosition(inPlaza: true, tile: tile, facing: .down, isWalking: false)
        await waitUntil { me.session.members[other.id]?.tile == tile && c.scene?.memberTiles[other.id] == tile }
        return (c, me, other)
    }

    // MARK: unread and the board

    func testOpeningBoardMarksRead() async {
        let (c, me, other) = await connected(otherAt: TilePoint(x: 3, y: 3), start: aboveBoard)
        other.session.publish(hatch())
        await waitUntil { me.feed.unreadCount == 1 && c.scene?.isBoardMarkerVisible == true }
        XCTAssertEqual(me.feed.unreadCount, 1)
        XCTAssertTrue(c.scene!.isBoardMarkerVisible)
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        XCTAssertEqual(me.feed.unreadCount, 0)
        await waitUntil { c.scene?.isBoardMarkerVisible == false }
        XCTAssertFalse(c.scene!.isBoardMarkerVisible)
    }

    func testClosingBoardMarksNewsThatArrivedMeanwhileRead() async {
        let (c, me, other) = await connected(otherAt: TilePoint(x: 3, y: 3), start: aboveBoard)
        space(c.scene!)
        XCTAssertEqual(c.overlayContent, .board)
        other.session.publish(hatch())
        await waitUntil { me.feed.unreadCount == 1 }
        XCTAssertEqual(me.feed.unreadCount, 1)
        c.scene!.handleKeyDown(keyCode: escKey, characters: nil, isRepeat: false)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertEqual(me.feed.unreadCount, 0)
        await waitUntil { c.scene?.isBoardMarkerVisible == false }
        XCTAssertFalse(c.scene!.isBoardMarkerVisible)
    }

    func testNewNewsLightsBoardMarker() async {
        let (c, me, other) = await connected(otherAt: TilePoint(x: 3, y: 3), start: map.spawn)
        XCTAssertFalse(c.scene!.isBoardMarkerVisible)
        other.session.publish(hatch())
        await waitUntil { c.scene?.isBoardMarkerVisible == true }
        XCTAssertTrue(c.scene!.isBoardMarkerVisible)
        XCTAssertEqual(c.overlayContent, .none, "news never opens anything by itself")
        _ = me
    }

    func testMarkerIsLitFromTheStartWhenNewsWasAlreadyUnread() {
        let me = node("나")
        me.feed.insert(event("e0", author: "other"))
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        XCTAssertTrue(c.scene!.isBoardMarkerVisible)
    }

    // MARK: reactions

    func testReactionButtonSendsOnce() async {
        let (_, me, other) = await connected(otherAt: TilePoint(x: 3, y: 3), start: map.spawn)
        other.session.publish(hatch())
        await waitUntil { me.feed.events.count == 1 }
        let eventID = me.feed.events[0].id
        me.session.react(to: eventID, kind: .cute)
        me.session.react(to: eventID, kind: .cute)
        await waitUntil { !other.feed.reactions(for: eventID).isEmpty }
        try? await Task.sleep(for: .milliseconds(100))   // a second one would have arrived by now
        XCTAssertEqual(other.feed.reactions(for: eventID).count, 1)
        XCTAssertEqual(me.transport.sentMessages { if case .reactions = $0 { true } else { false } }, 1)
    }

    // MARK: big news

    func testBigEventSparklesAndShowsBanner() async {
        let far = TilePoint(x: 3, y: 3)
        let (c, _, other) = await connected(otherAt: far, start: map.spawn)
        let e = event("big", author: other.id, kind: .graduate, at: Date())
        c.showBigEvent(e)
        XCTAssertGreaterThan(c.scene!.sparkleCount, 0)
        XCTAssertEqual(c.banner, L(.ko).teamEventText(e))
        // 반짝임은 그 팀원 위에 뜬다(내 캐릭터 위가 아니다).
        let foot = c.scene!.memberFoot(other.id)!
        let mine = c.scene!.sparkleCenter!.x
        XCTAssertEqual(mine, foot.x, accuracy: 40)
        XCTAssertNotEqual(foot.x, c.scene!.walkerFootX, accuracy: 40)
    }

    func testMyBigEventSparklesOnMe() async {
        let (c, me, _) = await connected(otherAt: TilePoint(x: 3, y: 3), start: map.spawn)
        let e = event("mine", author: me.id, kind: .hatch, at: Date())
        c.showBigEvent(e)
        XCTAssertGreaterThan(c.scene!.sparkleCount, 0)
        XCTAssertEqual(c.scene!.sparkleCenter!.x, c.scene!.walkerFootX, accuracy: 40)
        XCTAssertEqual(c.banner, L(.ko).teamEventText(e))
    }

    func testBigEventFromUnknownMemberStillShowsBannerButNoSparkle() {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        c.showBigEvent(event("x", author: "stranger", at: Date()))
        XCTAssertEqual(c.scene!.sparkleCount, 0)
        XCTAssertNotNil(c.banner)
    }

    func testBigEventWithClosedPlazaDoesNothing() async {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        XCTAssertNil(c.scene)
        c.showBigEvent(event("x", author: me.id, at: Date()))
        c.showBanner("hi")
        XCTAssertNil(c.banner)
        await Task.yield()
        XCTAssertTrue(gate.durations.isEmpty, "no timer without a window")
    }

    func testEvolutionIsNotStaged() {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        c.showBigEvent(event("evo", author: me.id, kind: .evolve, from: "깨봉이", at: Date()))
        XCTAssertEqual(c.scene!.sparkleCount, 0)
        XCTAssertNil(c.banner)
    }

    func testSparklesFadeAwayAboutASecondLater() {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        let scene = c.scene!
        scene.playSparkle(memberID: nil)
        XCTAssertGreaterThan(scene.sparkleCount, 0)
        step(scene, seconds: 0.5)
        XCTAssertGreaterThan(scene.sparkleCount, 0)
        step(scene, seconds: 1.3)
        XCTAssertEqual(scene.sparkleCount, 0)
    }

    // MARK: banner timing

    func testBannerClearsAfterDelay() async {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        c.showBanner("hello")
        XCTAssertEqual(c.banner, "hello")
        await waitUntil { gate.durations.count == 1 }
        XCTAssertEqual(gate.durations, [.seconds(4)])
        XCTAssertEqual(c.banner, "hello", "still shown until the delay is up")
        gate.release(0)
        await waitUntil { c.banner == nil }
        XCTAssertNil(c.banner)
    }

    func testSecondBannerGetsItsOwnFullDelay() async {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        c.showBanner("first")
        await waitUntil { gate.durations.count == 1 }
        c.showBanner("second")
        await waitUntil { gate.durations.count == 2 }
        gate.release(0)   // the first timer is up; it must not clear the newer banner
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.banner, "second")
        gate.release(1)
        await waitUntil { c.banner == nil }
        XCTAssertNil(c.banner)
    }

    func testClosingThePlazaDropsTheBannerAndItsTimer() async {
        let me = node("나")
        let c = controller(me, start: map.spawn)
        c.prepareScene()
        c.showBanner("bye")
        await waitUntil { gate.durations.count == 1 }
        c.handleClose()
        XCTAssertNil(c.banner)
        c.prepareScene()
        c.showBanner("again")
        await waitUntil { gate.durations.count == 2 }
        gate.release(0)   // the old timer must not clear the new window's banner
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.banner, "again")
    }

    // MARK: runtime wiring

    func testRuntimeRoutesBigEventToThePlaza() async {
        let defaults = UserDefaults(suiteName: "plaza.board.runtime.\(UUID())")!
        let settings = TeamSettings(defaults: defaults)
        settings.code = code
        settings.nickname = "나"
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardTests-\(UUID())")
        dirs.append(dir)
        let companion = CompanionStore(provider: BoardProvider(), clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                                       fileURL: dir.appendingPathComponent("c.json"), rng: SeededRNG(seed: 7),
                                       dittoDisguiseRollingEnabled: false, defaults: defaults)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("f.json"), myMemberID: settings.memberID)
        let runtime = TeamRuntime(settings: settings, companion: companion, transport: hub.makeTransport(), feed: feed)
        let myID = settings.memberID
        let prefs = PlazaPreferences(defaults: UserDefaults(suiteName: "plaza.board.rt.prefs.\(UUID())")!)
        let plaza = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                          nickname: { "나" }, memberID: { myID },
                                          subject: { .init(speciesID: 25, isShiny: false) },
                                          session: runtime.session, feed: feed, bannerSleep: { [gate] in await gate.sleep($0) })
        plaza.prepareScene()
        runtime.plaza = plaza
        runtime.start()
        let e = event("rt", author: "other", at: Date())
        runtime.session.onBigEvent?(e)
        XCTAssertEqual(plaza.banner, L(.ko).teamEventText(e))
        // 말풍선 연결은 그대로 남아 있다.
        runtime.session.onEmote?("nobody", TeamEmote(kind: .heart, targetMemberID: nil))
    }
}
