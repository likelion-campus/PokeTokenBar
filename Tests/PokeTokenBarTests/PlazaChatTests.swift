import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? { nil }
    func egg() async -> NSImage? { nil }
}

private let returnKey: UInt16 = 36, keypadEnterKey: UInt16 = 76, rightKey: UInt16 = 124

final class TeamChatTextTests: XCTestCase {
    func testPreparedMakesOneTrimmedLine() {
        XCTAssertEqual(TeamChat.prepared("  안녕  "), "안녕")
        XCTAssertEqual(TeamChat.prepared("a\nb\r\nc\td"), "a b c d")
        XCTAssertEqual(TeamChat.prepared("a\u{2028}b"), "a b")
        XCTAssertNil(TeamChat.prepared(""))
        XCTAssertNil(TeamChat.prepared(" \n\t "))
    }

    func testPreparedCutsToTheLimitWithoutEndingOnASpace() {
        XCTAssertEqual(TeamChat.prepared(String(repeating: "가", count: 50)), String(repeating: "가", count: 40))
        let cut = String(repeating: "a", count: 39) + " bbb"
        XCTAssertEqual(TeamChat.prepared(cut), String(repeating: "a", count: 39))
    }

    func testPreparedKeepsJoinedEmojiAndRejectsAnEndlessCharacter() {
        let family = "👨‍👩‍👧"
        XCTAssertEqual(TeamChat.prepared(family), family)
        XCTAssertNil(TeamChat.prepared("a" + String(repeating: "\u{0301}", count: 200)))
    }

    func testPreparedCutsLongJoinedEmojiInsteadOfLosingTheLine() throws {
        let line = String(repeating: "👩‍💻", count: 30)
        let cut = try XCTUnwrap(TeamChat.prepared(line))
        XCTAssertLessThanOrEqual(cut.utf8.count, TeamChat.maxBytes)
        XCTAssertTrue(line.hasPrefix(cut))
        XCTAssertEqual(TeamChat.prepared(cut), cut)
    }

    func testPreparedRemovesInvisibleFormatCharacters() {
        XCTAssertNil(TeamChat.prepared("\u{200B}\u{FEFF}\u{2060}"), "an empty bubble is not a line")
        XCTAssertEqual(TeamChat.prepared("a\u{202E}b"), "a b", "text direction cannot be overridden")
    }

    func testPreparedLineIsStable() throws {
        let once = try XCTUnwrap(TeamChat.prepared("  한 줄\n더 \t"))
        XCTAssertEqual(TeamChat.prepared(once), once, "a sent line must pass the receiver's check")
    }
}

final class PlazaChatBubbleTests: XCTestCase {
    func testLongLineWrapsInsideTheLimit() throws {
        let short = try XCTUnwrap(PlazaChatBubble.image(text: "안녕", scale: 2))
        let long = try XCTUnwrap(PlazaChatBubble.image(text: String(repeating: "가", count: 40), scale: 2))
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThan(short.height, long.height, "the long line wraps")
        XCTAssertLessThanOrEqual(CGFloat(long.width), PlazaChatBubble.maxSize.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(long.height), PlazaChatBubble.maxSize.height * 2)
    }

    func testEveryLineInTheLimitIsDrawnInFull() {
        let lines = [String(repeating: "가", count: 40), String(repeating: "😀", count: 40), String(repeating: "🇰🇷", count: 40),
                     String(repeating: "가😀", count: 20), String(repeating: "W", count: 40)]
        for line in lines {
            XCTAssertEqual(PlazaChatBubble.drawnLength(of: line), line.utf16.count, line)
        }
    }

    func testOneHugeCharacterCannotGrowTheImage() throws {
        let text = "a" + String(repeating: "\u{0301}", count: 150)
        let image = try XCTUnwrap(PlazaChatBubble.image(text: text, scale: 2))
        XCTAssertLessThanOrEqual(CGFloat(image.width), PlazaChatBubble.maxSize.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(image.height), PlazaChatBubble.maxSize.height * 2)
    }

    func testTextIsDrawnInsideTheWhiteBody() throws {
        let image = try XCTUnwrap(PlazaChatBubble.image(text: "안녕하세요", scale: 2))
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 테두리(2pt)와 꼬리(4pt)를 뺀 안쪽에 어두운 픽셀이 있으면 글자다.
        let dark = (6..<(h - 14)).reduce(0) { sum, y in
            sum + (6..<(w - 6)).filter { pixels[(y * w + $0) * 4] < 128 }.count
        }
        XCTAssertGreaterThan(dark, 0)
    }
}

@MainActor
final class PlazaChatInputTests: XCTestCase {
    private func input() -> (PlazaChatInput, sent: Box) {
        let box = Box()
        let i = PlazaChatInput()
        i.onSubmit = { box.sent.append($0); return box.accept }
        i.onClose = { box.closes += 1 }
        i.open()
        return (i, box)
    }

    final class Box {
        var sent: [String] = []
        var closes = 0
        var accept = true
    }

    /// 실제 입력 편집기를 쓰도록 창에 붙여 첫 응답자로 만든다. 창은 화면에 띄우지 않는다.
    private func editing(_ i: PlazaChatInput) throws -> (NSWindow, NSTextView) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = i.view
        XCTAssertTrue(w.makeFirstResponder(i.field))
        return (w, try XCTUnwrap(i.field.currentEditor() as? NSTextView))
    }

    func testEnterSendsTheTypedTextAndCloses() throws {
        let (i, box) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(box.sent, ["안녕"])
        XCTAssertFalse(i.isOpen)
        XCTAssertTrue(i.view.isHidden)
        XCTAssertEqual(box.closes, 1)
        w.contentView = nil
    }

    func testRefusedLineStaysInTheField() throws {
        let (i, box) = input()
        box.accept = false
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(i.isOpen)
        XCTAssertEqual(editor.string, "안녕")
        w.contentView = nil
    }

    func testEnterWhileComposingOnlyFinishesTheSyllable() throws {
        let (i, box) = input()
        let (w, editor) = try editing(i)
        editor.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(box.sent.isEmpty)
        XCTAssertTrue(i.isOpen, "the line must not be lost")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "하")
        w.contentView = nil
    }

    func testHeldEnterDoesNotCloseTheFieldItOpened() throws {
        let (i, box) = input()
        i.isKeyRepeating = { true }
        let (w, editor) = try editing(i)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(i.isOpen)
        XCTAssertTrue(box.sent.isEmpty)
        w.contentView = nil
    }

    func testTabKeepsTheLine() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(i.isOpen)
        XCTAssertEqual(editor.string, "안녕")
        w.contentView = nil
    }

    func testCuttingAnOverlongLineKeepsTheCaret() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText(String(repeating: "가", count: TeamChat.maxCharacters), replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertText("나", replacementRange: editor.selectedRange())
        i.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(i.field.stringValue.count, TeamChat.maxCharacters)
        XCTAssertEqual(editor.selectedRange().location, 11)
        w.contentView = nil
    }

    func testEscapeClosesWithoutSending() throws {
        let (i, box) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(box.sent.isEmpty)
        XCTAssertFalse(i.isOpen)
        i.open()
        XCTAssertEqual(i.field.stringValue, "", "a cancelled line does not come back")
        w.contentView = nil
    }

    func testLeavingTheFieldClosesIt() throws {
        let (i, box) = input()
        let (w, _) = try editing(i)
        XCTAssertTrue(w.makeFirstResponder(nil))
        XCTAssertFalse(i.isOpen)
        XCTAssertEqual(box.closes, 1)
        w.contentView = nil
    }

    func testOverlongTextIsCutAfterComposingEnds() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        let long = String(repeating: "가", count: TeamChat.maxCharacters + 1)
        editor.setMarkedText(long, selectedRange: NSRange(location: long.count, length: 0),
                             replacementRange: editor.selectedRange())
        i.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(editor.string.count, long.count, "composing text is left alone")
        editor.unmarkText()
        i.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(i.field.stringValue.count, TeamChat.maxCharacters)
        w.contentView = nil
    }

    func testCommandAReachesTheEditor() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: w.windowNumber, context: nil, characters: "a",
                                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(i.field.performKeyEquivalent(with: event))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 2))
        w.contentView = nil
    }

    func testCommandKeysWorkWithoutAMainMenu() {
        typealias F = PlazaChatTextField
        XCTAssertEqual(F.commandAction(keyCode: 9, modifiers: .command), #selector(NSText.paste(_:)))
        XCTAssertEqual(F.commandAction(keyCode: 8, modifiers: .command), #selector(NSText.copy(_:)))
        XCTAssertEqual(F.commandAction(keyCode: 7, modifiers: .command), #selector(NSText.cut(_:)))
        XCTAssertEqual(F.commandAction(keyCode: 0, modifiers: .command), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(F.commandAction(keyCode: 13, modifiers: .command), #selector(NSWindow.performClose(_:)))
        XCTAssertNil(F.commandAction(keyCode: 9, modifiers: []))
        XCTAssertNil(F.commandAction(keyCode: 9, modifiers: [.command, .shift]))
        XCTAssertNil(F.commandAction(keyCode: 1, modifiers: .command))
    }
}

@MainActor
final class PlazaChatTests: XCTestCase {
    private var hub: FakeTransportHub!
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

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

    private struct Node {
        let settings: TeamSettings
        let session: TeamSession
        let transport: FakeTeamTransport
        let feed: TeamFeedStore
        let received: Received
    }

    @MainActor final class Received {
        var lines: [(from: String, text: String)] = []
    }

    private func node(_ name: String) -> Node {
        let suite = "plaza.chat.\(UUID())"
        suites.append(suite)
        let settings = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.code = code
        settings.nickname = name
        settings.isEnabled = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaChatTests-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: settings.memberID)
        let transport = hub.makeTransport()
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                  profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
        session.updateCharacter(mon)
        session.applySettings()
        let received = Received()
        session.onChat = { [received] id, text in received.lines.append((id, text)) }
        return Node(settings: settings, session: session, transport: transport, feed: feed, received: received)
    }

    private func controller(_ me: Node) -> PlazaWindowController {
        let suite = "plaza.chat.prefs.\(UUID())"
        suites.append(suite)
        return PlazaWindowController(preferences: PlazaPreferences(defaults: UserDefaults(suiteName: suite)!),
                                     loader: PlazaCharacterLoader(fetcher: EmptyFetcher()),
                                     nickname: { "나" }, memberID: { me.settings.memberID },
                                     subject: { .init(speciesID: 25, isShiny: false) },
                                     myRosterEntry: { nil }, session: me.session, clock: { [unowned self] in now })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func connected() async -> (PlazaWindowController, PlazaScene, me: Node, other: Node) {
        let me = node("나"), other = node("민수")
        let c = controller(me)
        c.prepareScene()
        hub.connect(me.transport, to: other.transport)
        await settle()
        return (c, c.scene!, me, other)
    }

    private func step(_ scene: PlazaScene, seconds: TimeInterval, from start: TimeInterval = 0) {
        var t = start
        scene.update(t)
        while t < start + seconds { t += 1.0 / 30; scene.update(t) }
    }

    private func submit(_ c: PlazaWindowController, _ text: String) -> Bool {
        let input = c.chatInputForTesting
        let editor = NSTextView()
        editor.string = text
        XCTAssertTrue(input.control(input.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
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

    func testRepeatedOrModifiedEnterDoesNotOpenIt() {
        let c = controller(node("나"))
        c.prepareScene()
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: true)
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false, modifiers: .command)
        XCTAssertFalse(c.chatInputForTesting.isOpen)
    }

    func testEnterDoesNothingWhileABoardIsOpen() {
        let c = controller(node("나"))
        c.prepareScene()
        c.scene!.isOverlayOpen = true
        c.scene!.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertFalse(c.chatInputForTesting.isOpen)
    }

    func testOpeningTheInputDropsAHeldWalkKey() {
        let c = controller(node("나"))
        c.prepareScene()
        let scene = c.scene!
        scene.handleKeyDown(keyCode: rightKey, characters: nil, isRepeat: false)
        step(scene, seconds: 0.05)
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        step(scene, seconds: 2, from: 1)
        XCTAssertFalse(scene.walker.isWalking, "the key up goes to the field, so the walk must not continue")
    }

    func testClosingThePlazaClosesTheInput() {
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

    func testReceivedLineDoesNothingWhenClosed() {
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

    func testLogKeepsTheLatestLinesAndShowsTheLastFew() {
        let log = PlazaChatLog()
        let color = PlazaNameColor.palette[0]
        for i in 0..<(PlazaChatLog.capacity + 5) {
            log.append(time: Date(timeIntervalSince1970: 0), name: "a", text: "\(i)", color: color)
        }
        XCTAssertEqual(log.lines.count, PlazaChatLog.capacity)
        XCTAssertEqual(log.lines.first?.text, "5")
        XCTAssertEqual(log.visible.map(\.text), (49..<55).map(String.init))
        XCTAssertEqual(Set(log.lines.map(\.id)).count, log.lines.count)
    }

    func testTimeIsTwentyFourHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 14, minute: 5))!
        XCTAssertEqual(PlazaChatLog.timeText(afternoon, calendar: calendar), "14:05")
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 0))!
        XCTAssertEqual(PlazaChatLog.timeText(morning, calendar: calendar), "09:00")
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
        c.showChat(memberID: id, text: String(repeating: "가", count: 40))
        step(scene, seconds: 0.1, from: 1)
        XCTAssertNil(scene.shownEmote(memberID: id))
        XCTAssertNotEqual(scene.emoteFrame(memberID: id)!.size, emoteSize)
        c.showEmote(memberID: id, kind: .heart)
        step(scene, seconds: 0.1, from: 2)
        XCTAssertNil(scene.shownChat(memberID: id))
        XCTAssertEqual(scene.emoteFrame(memberID: id)!.size, emoteSize, "the same emote is drawn again after a line")
        c.showChat(memberID: id, text: String(repeating: "가", count: 40))
        step(scene, seconds: 0.1, from: 3)
        XCTAssertNotEqual(scene.emoteFrame(memberID: id)!.size, emoteSize, "the same line is drawn again after an emote")
    }

    func testPhotoCarriesTheLine() throws {
        let c = controller(node("나"))
        c.prepareScene()
        let scene = c.scene!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = PlazaFrame(image: ctx.makeImage()!, delay: 0.1)
        scene.setCharacter(PlazaCharacterFrames(front: [frame], back: [frame]))
        scene.showChat(memberID: nil, text: "안녕")
        scene.update(0)
        let actor = try XCTUnwrap(scene.photoInput()?.actors.first)
        XCTAssertEqual(try XCTUnwrap(actor.bubble).width, PlazaChatBubble.image(text: "안녕", scale: 2)?.width)
    }

    func testWideBubbleStaysOnScreenButFollowsAnOffscreenName() {
        let viewport = CGSize(width: 400, height: 300), size = CGSize(width: 180, height: 60)
        let left = PlazaActor.chatBubbleOrigin(CGPoint(x: -260, y: 0), size: size, plate: CGPoint(x: -190, y: 0), viewport: viewport)
        XCTAssertEqual(left.x, -196)
        let right = PlazaActor.chatBubbleOrigin(CGPoint(x: 100, y: 0), size: size, plate: CGPoint(x: 190, y: 0), viewport: viewport)
        XCTAssertEqual(right.x, 16)
        let top = PlazaActor.chatBubbleOrigin(CGPoint(x: 0, y: 120), size: size, plate: CGPoint(x: 0, y: 100), viewport: viewport)
        XCTAssertEqual(top.y, 86)
        let inside = CGPoint(x: -40, y: -20)
        XCTAssertEqual(PlazaActor.chatBubbleOrigin(inside, size: size, plate: .zero, viewport: viewport), inside)
        let away = CGPoint(x: -400, y: 0)
        XCTAssertEqual(PlazaActor.chatBubbleOrigin(away, size: size, plate: CGPoint(x: -320, y: 0), viewport: viewport), away)
    }
}
