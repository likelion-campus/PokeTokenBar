import XCTest
@testable import PokeTokenBar

/// 키 1–5의 keyCode. 순서는 ♥, ㅋㅋ, 🎉, !, ?.
private let heartKey: UInt16 = 18, lolKey: UInt16 = 19, partyKey: UInt16 = 20, exclaimKey: UInt16 = 21, questionKey: UInt16 = 23

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaEmoteTests {

    private func controller(_ me: Node, start: TilePoint? = nil, speciesID: Int? = 25) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: defaults())
        if let start { prefs.saveLastTile(start) }
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: speciesID, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now },
                                     dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed },
                                     shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    // MARK: - 인사하기

    /// A greeting between two teammates shows over both of them here.
    func testGreetingShowsOverTheSenderAndTheTarget() async {
        let me = node("나"), b = node("가"), d = node("다")
        let c = controller(me)
        c.prepareScene()
        await connect(me, b)
        await connect(me, d)
        let scene = c.scene!, bID = b.settings.memberID, dID = d.settings.memberID
        for _ in 0..<200 where scene.memberTiles[bID] == nil || scene.memberTiles[dID] == nil { await Task.yield() }
        c.showEmote(memberID: bID, kind: .heart, alsoOver: dID)
        XCTAssertEqual(scene.shownEmote(memberID: bID), .heart)
        XCTAssertEqual(scene.shownEmote(memberID: dID), .heart)
        XCTAssertNil(scene.shownEmote(memberID: nil), "not over me")
    }


    // MARK: - 보내기와 표적

    func testHeartAtFacingMemberTargetsThem() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: PlazaTargeting.facingTile(from: start, facing: .down),
                                          facing: .down, isWalking: false)
        await settle()
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.count, 1)
        XCTAssertEqual(other.received.emotes.first?.from, me.settings.memberID)
        XCTAssertEqual(other.received.emotes.first?.emote, TeamEmote(kind: .heart, targetMemberID: other.settings.memberID))
        XCTAssertEqual(c.scene?.shownEmote(memberID: nil), .heart, "my own bubble shows at once")
    }

    func testHeartAtAwayMemberTargetsThem() async {
        let me = node("나")
        // 자리 비움 팀원은 멤버 ID로 정해진 쉼터 칸에 선다. 멤버 ID는 매번 달라서, 그 위쪽 칸을 걸을 수 있는 팀원이 나올 때까지 만든다.
        // 멤버 ID는 UUID라서 팀원을 만들기 전에 ID만 먼저 굴린다(팀원마다 suite 가 하나씩 생기지 않게).
        var candidateID = UUID().uuidString
        for _ in 0..<100 {
            let tile = PlazaShelterWanderer(memberID: candidateID, shelter: map.shelterTiles).tile
            if map.isWalkable(TilePoint(x: tile.x, y: tile.y - 1)) { break }
            candidateID = UUID().uuidString
        }
        let other = node("민수", memberID: candidateID)
        let id = other.settings.memberID
        let shelter = PlazaShelterWanderer(memberID: id, shelter: map.shelterTiles).tile
        let above = TilePoint(x: shelter.x, y: shelter.y - 1)
        XCTAssertTrue(map.isWalkable(above), "test precondition")
        let c = controller(me, start: above)
        c.prepareScene()
        await connect(me, other)   // 접속 직후에는 자리 비움
        XCTAssertEqual(c.scene?.memberTiles[id], shelter)
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.first?.emote, TeamEmote(kind: .heart, targetMemberID: id))
    }

    func testHeartWithNobodyNearHasNoTarget() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        let far = TilePoint(x: start.x + 6, y: start.y)
        XCTAssertTrue(map.isWalkable(far), "test precondition")
        other.session.updatePlazaPosition(inPlaza: true, tile: far, facing: .down, isWalking: false)
        await settle()
        press(c.scene!, heartKey)
        await settle()
        XCTAssertEqual(other.received.emotes.count, 1, "still sent, to everyone")
        XCTAssertNil(other.received.emotes.first?.emote.targetMemberID)
        XCTAssertEqual(other.received.emotes.first?.emote.kind, .heart)
    }

    func testExclaimNeverTargets() async {
        let me = node("나"), other = node("민수")
        let start = startFacingDown()
        let c = controller(me, start: start)
        c.prepareScene()
        await connect(me, other)
        other.session.updatePlazaPosition(inPlaza: true, tile: PlazaTargeting.facingTile(from: start, facing: .down),
                                          facing: .down, isWalking: false)
        await settle()
        press(c.scene!, exclaimKey)
        now += 1
        press(c.scene!, questionKey)
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote), [TeamEmote(kind: .exclaim, targetMemberID: nil),
                                                            TeamEmote(kind: .question, targetMemberID: nil)])
    }

    func testKeyMashIsLimited() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: startFacingDown())
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        press(scene, heartKey)
        for _ in 0..<2 {
            now += 0.1
            press(scene, partyKey)   // 0.1초, 0.2초: 막힌다
        }
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart])
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart, "a limited press does not replace my bubble")
        now += 0.15   // 처음 누른 뒤 0.35초. 막힌 키는 제한 시계를 늦추지 않는다.
        press(scene, lolKey)
        await settle()
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart, .lol])
    }

    // MARK: - 받기와 보이기

    func testReceivedEmoteShowsOverThatMember() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .party)
        let scene = c.scene!
        XCTAssertEqual(scene.shownEmote(memberID: id), .party)
        XCTAssertNil(scene.shownEmote(memberID: nil), "not over me")
        c.showEmote(memberID: "nobody", kind: .party)   // 모르는 팀원은 조용히 넘어간다
        // 이름표 위에 놓이고 기기 픽셀 격자에 맞는다.
        scene.backingOverride = 2
        step(scene, seconds: 0.1)
        let frame = scene.emoteFrame(memberID: id)!
        XCTAssertEqual(frame.minX * 2, (frame.minX * 2).rounded(), accuracy: 0.0001)
        XCTAssertEqual(frame.minY * 2, (frame.minY * 2).rounded(), accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(frame.minY, scene.memberNamePlateTop(id)!)
    }

    func testReceivedEmoteDoesNothingWhenClosed() async {
        let me = node("나")
        let c = controller(me)
        c.showEmote(memberID: "anyone", kind: .heart)
        XCTAssertNil(c.scene, "no scene is created just to show a bubble")
    }

    func testEmoteExpires() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 2.4)
        XCTAssertEqual(scene.shownEmote(memberID: id), .heart)
        step(scene, seconds: 0.3, from: 2.4)
        XCTAssertNil(scene.shownEmote(memberID: id))
        XCTAssertNil(scene.emoteFrame(memberID: id))
    }

    func testNewEmoteReplacesOldAndRestartsTimer() async {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        let id = other.settings.memberID
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 1.5)
        c.showEmote(memberID: id, kind: .question)
        XCTAssertEqual(scene.shownEmote(memberID: id), .question)
        step(scene, seconds: 2.3, from: 1.5)   // 처음 것이었다면 이미 사라졌을 때
        XCTAssertEqual(scene.shownEmote(memberID: id), .question)
        step(scene, seconds: 0.5, from: 3.8)
        XCTAssertNil(scene.shownEmote(memberID: id))
    }

    func testEggCanStillEmote() async {
        let me = node("나"), other = node("민수")
        let c = controller(me, start: startFacingDown(), speciesID: nil)
        c.prepareScene()
        await connect(me, other)
        let scene = c.scene!
        XCTAssertFalse(scene.canWalk)
        press(scene, heartKey)
        await settle()
        XCTAssertEqual(scene.shownEmote(memberID: nil), .heart)
        XCTAssertEqual(other.received.emotes.map(\.emote.kind), [.heart])
        step(scene, seconds: 0.1)
        XCTAssertNotNil(scene.emoteFrame(memberID: nil))
    }
}
