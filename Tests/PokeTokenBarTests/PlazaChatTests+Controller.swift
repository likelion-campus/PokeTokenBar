import XCTest
@testable import PokeTokenBar

private let returnKey: UInt16 = 36, keypadEnterKey: UInt16 = 76, rightKey: UInt16 = 124

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

extension PlazaChatTests {

    func controller(_ me: Node, chatInput: any PlazaChatInputHost = PlazaStubChatInput()) -> PlazaWindowController {
        let suite = "plaza.chat.prefs.\(UUID())"
        return PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
                                     loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now },
                                     shell: PlazaHeadlessShell(), chatInput: chatInput)
    }

    func connected(chatInput: any PlazaChatInputHost = PlazaStubChatInput()) async -> (PlazaWindowController, PlazaScene, me: Node, other: Node) {
        let me = node("나"), other = node("민수")
        let c = controller(me, chatInput: chatInput)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await settle()
        return (c, c.scene!, me, other)
    }

    /// What the field does on Enter: hand the line to `onSubmit`, close when it was taken. The AppKit field's own Enter
    /// handling is covered by `PlazaChatInputTests`; `testSendingThroughTheRealFieldReachesTheTeammate` (Mac) sends one line
    /// through it end to end.
    func submit(_ c: PlazaWindowController, _ text: String) -> Bool {
        let input = c.chatInputForTesting
        if input.onSubmit?(text) != false { input.close() }
        return !input.isOpen
    }

    // MARK: 입력창 열기

    func testEnterOpensTheInput() async {
        for key in [returnKey, keypadEnterKey] {
            let c = controller(node("나"))
            c.prepareScene()
            c.scene!.handleKeyDown(keyCode: key, characters: nil, isRepeat: false)
            XCTAssertTrue(c.chatInputForTesting.isOpen, "key \(key)")
        }
    }

    func testRepeatedOrModifiedEnterDoesNotOpenIt() async {
        let c = controller(node("나"))
        c.prepareScene()
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: true)
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false, modifiers: .command)
        XCTAssertFalse(c.chatInputForTesting.isOpen)
    }

    func testEnterDoesNothingWhileABoardIsOpen() async {
        let c = controller(node("나"))
        c.prepareScene()
        c.scene!.isOverlayOpen = true
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertFalse(c.chatInputForTesting.isOpen)
    }

    func testOpeningTheInputDropsAHeldWalkKey() async {
        let c = controller(node("나"))
        c.prepareScene()
        let scene = c.scene!
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        step(scene, seconds: 0.05)
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        step(scene, seconds: 2, from: 1)
        XCTAssertFalse(scene.walker.isWalking, "the key up goes to the field, so the walk must not continue")
    }

    func testClosingThePlazaClosesTheInput() async {
        let c = controller(node("나"))
        c.prepareScene()
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        c.handleClose()
        XCTAssertFalse(c.chatInputForTesting.isOpen)
    }

    // MARK: 보내기와 받기

    func testSendingShowsOverMeAtOnceAndReachesTheTeammate() async {
        let (c, scene, me, other) = await connected()
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(submit(c, "  같이 점심?\n"))
        await settle()
        XCTAssertEqual(scene.shownChat(memberID: nil), "같이 점심?")
        XCTAssertEqual(other.received.lines.map(\.text), ["같이 점심?"])
        XCTAssertEqual(other.received.lines.first?.from, me.settings.memberID)
        XCTAssertTrue(other.feed.events.isEmpty, "chat is not news")
    }

    func testBlankLineClosesWithoutSending() async {
        let (c, scene, _, other) = await connected()
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(submit(c, "   "))
        await settle()
        XCTAssertNil(scene.shownChat(memberID: nil))
        XCTAssertTrue(other.received.lines.isEmpty)
    }

    func testTooFastLineIsKeptInsteadOfLost() async {
        let (c, scene, _, other) = await connected()
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(submit(c, "하나"))
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertFalse(submit(c, "둘"), "the field stays open")
        now = now.addingTimeInterval(PlazaWindowController.emoteInterval + 0.01)
        XCTAssertTrue(submit(c, "둘"))
        await settle()
        XCTAssertEqual(other.received.lines.map(\.text), ["하나", "둘"])
    }

    func testReceivedLineShowsOverThatMember() async {
        let (c, scene, _, other) = await connected()
        let id = other.settings.memberID
        c.showChat(memberID: id, text: "안녕")
        XCTAssertEqual(scene.shownChat(memberID: id), "안녕")
        XCTAssertNil(scene.shownChat(memberID: nil), "not over me")
        c.showChat(memberID: "nobody", text: "안녕")   // 모르는 팀원은 조용히 넘어간다
        scene.backingOverride = 2
        step(scene, seconds: 0.1)
        let frame = scene.emoteFrame(memberID: id)!
        XCTAssertGreaterThanOrEqual(frame.minY, scene.memberNamePlateTop(id)!)
    }

    func testReceivedLineDoesNothingWhenClosed() async {
        let c = controller(node("나"))
        c.showChat(memberID: "anyone", text: "안녕")
        XCTAssertNil(c.scene, "no scene is created just to show a bubble")
    }

    // MARK: 대화 기록

    func testOwnAndReceivedLinesAreLoggedWithTimeAndNameColor() async {
        let (c, scene, _, other) = await connected()
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(submit(c, "점심?"))
        now = now.addingTimeInterval(60)
        c.showChat(memberID: other.settings.memberID, text: "좋아요")
        let lines = c.chatLogLines
        guard lines.count == 2 else { return XCTFail("expected two lines, got \(lines.map(\.text))") }
        XCTAssertEqual(lines.map(\.name), ["나", "민수"])
        XCTAssertEqual(lines.map(\.text), ["점심?", "좋아요"])
        XCTAssertEqual(lines.map(\.time), [now.addingTimeInterval(-60), now])
        XCTAssertEqual(lines[0].color, scene.nameColor)
        XCTAssertEqual(lines[1].color, scene.memberNameColor(other.settings.memberID))
    }

    func testLinesWhileClosedAreNotLoggedButEarlierLinesStay() async {
        let (c, _, _, other) = await connected()
        let id = other.settings.memberID
        c.showChat(memberID: id, text: "하나")
        c.handleClose()
        c.showChat(memberID: id, text: "둘")
        c.prepareScene()
        await settle()
        XCTAssertEqual(c.chatLogLines.map(\.text), ["하나"])
    }

    func testUnknownMemberIsNotLogged() async {
        let (c, _, _, _) = await connected()
        c.showChat(memberID: "nobody", text: "안녕")
        XCTAssertTrue(c.chatLogLines.isEmpty)
    }

    // MARK: 확성기와 기록 패널



    func testReceivedMegaphoneIsMarkedInTheLog() async {
        let (c, _, _, other) = await connected()
        c.showChat(memberID: other.settings.memberID, text: "모두 회의실로", isLoud: true)
        XCTAssertEqual(c.chatLogLines.last?.isLoud, true)
    }


    // MARK: 말풍선

    func testLineExpires() async {
        let (c, scene, _, other) = await connected()
        let id = other.settings.memberID
        c.showChat(memberID: id, text: "안녕")
        step(scene, seconds: PlazaActor.chatDuration - 0.1)
        XCTAssertEqual(scene.shownChat(memberID: id), "안녕")
        step(scene, seconds: 0.3, from: PlazaActor.chatDuration - 0.1)
        XCTAssertNil(scene.shownChat(memberID: id))
        XCTAssertNil(scene.emoteFrame(memberID: id))
    }

    func testNewerBubbleReplacesTheOlderKindAndRedraws() async {
        let (c, scene, _, other) = await connected()
        let id = other.settings.memberID
        scene.backingOverride = 2
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 0.1)
        let emoteSize = scene.emoteFrame(memberID: id)!.size
        c.showChat(memberID: id, text: String(repeating: "가", count: TeamChat.maxCharacters))
        step(scene, seconds: 0.1, from: 1)
        XCTAssertNil(scene.shownEmote(memberID: id))
        XCTAssertNotEqual(scene.emoteFrame(memberID: id)!.size, emoteSize)
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 0.1, from: 2)
        XCTAssertNil(scene.shownChat(memberID: id))
        XCTAssertEqual(scene.emoteFrame(memberID: id)!.size, emoteSize, "the same emote is drawn again after a line")
        c.showChat(memberID: id, text: String(repeating: "가", count: TeamChat.maxCharacters))
        step(scene, seconds: 0.1, from: 3)
        XCTAssertNotEqual(scene.emoteFrame(memberID: id)!.size, emoteSize, "the same line is drawn again after an emote")
    }

}
