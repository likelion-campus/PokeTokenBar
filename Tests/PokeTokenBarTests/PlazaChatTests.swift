import XCTest
import AppKit
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
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
        let max = TeamChat.maxCharacters
        XCTAssertEqual(TeamChat.prepared(String(repeating: "가", count: max + 10)), String(repeating: "가", count: max))
        let cut = String(repeating: "a", count: max - 1) + " bbb"
        XCTAssertEqual(TeamChat.prepared(cut), String(repeating: "a", count: max - 1))
    }

    func testPreparedKeepsJoinedEmojiAndRejectsAnEndlessCharacter() {
        let family = "👨‍👩‍👧"
        XCTAssertEqual(TeamChat.prepared(family), family)
        // Two bytes a mark: one Character twice as big as the byte limit.
        XCTAssertNil(TeamChat.prepared("a" + String(repeating: "\u{0301}", count: TeamChat.maxBytes)))
    }

    func testPreparedCutsLongJoinedEmojiInsteadOfLosingTheLine() throws {
        // 11 bytes each: within the character limit, over the byte limit.
        let line = String(repeating: "👩‍💻", count: TeamChat.maxCharacters)
        XCTAssertGreaterThan(line.utf8.count, TeamChat.maxBytes)
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
        let long = try XCTUnwrap(PlazaChatBubble.image(text: String(repeating: "가", count: TeamChat.maxCharacters), scale: 2))
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThan(short.height, long.height, "the long line wraps")
        XCTAssertLessThanOrEqual(CGFloat(long.width), PlazaChatBubble.maxSize.width * 2)
        XCTAssertLessThanOrEqual(CGFloat(long.height), PlazaChatBubble.maxSize.height * 2)
    }

    func testEveryLineInTheLimitIsDrawnInFull() {
        let max = TeamChat.maxCharacters
        let lines = [String(repeating: "가", count: max), String(repeating: "😀", count: max), String(repeating: "🇰🇷", count: max),
                     String(repeating: "가😀", count: max / 2), String(repeating: "W", count: max), String(repeating: "가 ", count: max / 2)]
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
        ctx.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
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

    /// The field was shorter than the pixel font's line, which cut off the tops of tall letters like the ㅎ stroke.
    func testFieldIsAsTallAsTheFontsLine() throws {
        let (i, _) = input()
        let (w, _) = try editing(i)
        defer { w.close() }
        i.view.layoutSubtreeIfNeeded()
        let font = try XCTUnwrap(i.field.font)
        XCTAssertGreaterThanOrEqual(i.field.frame.height, NSLayoutManager().defaultLineHeight(for: font))
    }

    /// Both placeholders fit the field at the plaza's input width; a longer one was cut off on the right.
    func testPlaceholdersFitTheField() throws {
        let (i, _) = input()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PlazaChatLog.width, height: 40), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.contentView = i.view
        i.view.layoutSubtreeIfNeeded()
        let available = try XCTUnwrap(i.field.cell).titleRect(forBounds: i.field.bounds).width
        let l = L(.ko)
        for text in [l.plazaChatPlaceholder, l.plazaLoudPlaceholder] {
            let width = NSAttributedString(string: text, attributes: [.font: PlazaResources.font(.body)]).size().width
            XCTAssertLessThanOrEqual(width, available, text)
        }
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

    func testTabKeepsTheLineAndTogglesTheMegaphone() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        XCTAssertFalse(i.isLoud)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(i.isLoud)
        XCTAssertEqual(i.field.placeholderAttributedString?.string, L(.ko).plazaLoudPlaceholder)
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertFalse(i.isLoud)
        XCTAssertTrue(i.isOpen)
        XCTAssertEqual(editor.string, "안녕")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        i.close(); i.open()
        XCTAssertFalse(i.isLoud, "each new line starts as an ordinary line")
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

    /// The emoji button unfolds the panel above the field (the bar grows upward) and folds it again; the line stays.
    /// The macOS emoji window is not used: on some Macs it never opens in the plaza, not even with ⌃⌘Space or 🌐.
    func testEmojiButtonUnfoldsThePanelAboveTheField() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        i.view.layoutSubtreeIfNeeded()
        let closedHeight = i.view.fittingSize.height
        i.emojiButton.performClick(nil)
        XCTAssertTrue(i.isEmojiPanelOpen)
        i.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(i.view.fittingSize.height, closedHeight + 3 * PlazaChatInput.emojiCell)
        XCTAssertGreaterThanOrEqual(i.emojiPanel.frame.minY, i.field.frame.maxY, "above the field")
        XCTAssertTrue(i.field.currentEditor() === editor, "the field is still being edited")
        i.emojiButton.performClick(nil)
        XCTAssertFalse(i.isEmojiPanelOpen)
        i.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(i.view.fittingSize.height, closedHeight)
        XCTAssertEqual(i.field.stringValue, "안녕")
        XCTAssertTrue(i.emojiButton.refusesFirstResponder, "taking focus would end editing and close the field")
        w.contentView = nil
    }

    private func pick(_ i: PlazaChatInput, _ emoji: String) throws {
        try XCTUnwrap(i.emojiPanelButtons.first { $0.title == emoji }, emoji).performClick(nil)
    }

    func testPickingAnEmojiPutsItAtTheCaretAndKeepsTheInputOpen() throws {
        let (i, box) = input()
        let (w, editor) = try editing(i)
        editor.insertText("안녕", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        i.emojiButton.performClick(nil)
        try pick(i, "🍜")
        XCTAssertEqual(i.field.stringValue, "안🍜녕")
        XCTAssertTrue(i.isOpen)
        XCTAssertTrue(i.isEmojiPanelOpen, "stays open for another pick")
        XCTAssertTrue(i.field.currentEditor() === editor)
        XCTAssertTrue(box.sent.isEmpty)
        XCTAssertTrue(i.emojiPanelButtons.allSatisfy(\.refusesFirstResponder))
        w.contentView = nil
    }

    /// A syllable being composed is finished first, so the emoji does not replace or break it.
    func testPickingWhileComposingKeepsTheSyllable() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        i.emojiButton.performClick(nil)
        try pick(i, "😀")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(i.field.stringValue, "가😀")
        w.contentView = nil
    }

    func testPickingAtTheLimitKeepsTheLimit() throws {
        let (i, _) = input()
        let (w, editor) = try editing(i)
        editor.insertText(String(repeating: "가", count: TeamChat.maxCharacters), replacementRange: editor.selectedRange())
        i.emojiButton.performClick(nil)
        try pick(i, "🔥")
        XCTAssertEqual(i.field.stringValue.count, TeamChat.maxCharacters)
        w.contentView = nil
    }

    func testPanelIsFoldedWhenTheInputOpensAgain() throws {
        let (i, _) = input()
        let (w, _) = try editing(i)
        i.emojiButton.performClick(nil)
        i.close()
        XCTAssertFalse(i.isEmojiPanelOpen)
        i.open()
        XCTAssertFalse(i.isEmojiPanelOpen)
        w.contentView = nil
    }

    /// Every emoji is one character that a teammate receives exactly as picked.
    func testEveryPanelEmojiIsSentAsPicked() {
        XCTAssertEqual(Set(PlazaChatInput.emojis).count, PlazaChatInput.emojis.count)
        for emoji in PlazaChatInput.emojis {
            XCTAssertEqual(emoji.count, 1, emoji)
            XCTAssertEqual(TeamChat.prepared(emoji), emoji, emoji)
        }
    }

    /// The opened panel fits inside the bar at the plaza's input width.
    func testOpenPanelFitsTheBar() {
        let (i, _) = input()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PlazaChatLog.width, height: 300), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        let host = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView = host
        i.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(i.view)
        NSLayoutConstraint.activate([
            i.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            i.view.widthAnchor.constraint(equalToConstant: PlazaChatLog.width),
            i.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        i.emojiButton.performClick(nil)
        host.layoutSubtreeIfNeeded()
        for b in i.emojiPanelButtons {
            let f = b.convert(b.bounds, to: i.view)
            XCTAssertTrue(i.view.bounds.contains(f), "\(b.title) at \(f) outside \(i.view.bounds)")
        }
        w.contentView = nil
    }

    func testEmojiButtonSitsAfterTheFieldInsideTheBar() {
        let (i, _) = input()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PlazaChatLog.width, height: 40), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.contentView = i.view
        i.view.layoutSubtreeIfNeeded()
        let button = i.emojiButton.frame, field = i.field.frame
        XCTAssertGreaterThan(button.width, 0)
        XCTAssertLessThanOrEqual(field.maxX, button.minX)
        XCTAssertLessThanOrEqual(button.maxX, i.view.bounds.maxX)
        XCTAssertEqual(button.midY, field.midY, accuracy: 1, "on the field's line")
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
    nonisolated(unsafe) private var dirs: [URL] = []
    private var code: TeamCode!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

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
        let feed: TeamFeedStore
        let received: Received
    }

    @MainActor final class Received {
        var lines: [(from: String, text: String)] = []
        var loud: [String] = []
    }

    private func node(_ name: String) -> Node {
        let suite = "plaza.chat.\(UUID())"
        let settings = TeamSettings(defaults: TestDefaults.make(suite: suite))
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
        session.onChat = { [received] id, text, loud in
            received.lines.append((id, text))
            if loud { received.loud.append(text) }
        }
        return Node(settings: settings, session: session, transport: transport, feed: feed, received: received)
    }

    private func controller(_ me: Node) -> PlazaWindowController {
        let suite = "plaza.chat.prefs.\(UUID())"
        return PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: suite)),
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
        let input = c.chatInputForTesting as! PlazaChatInput   // the Mac's AppKit field
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

    // MARK: 확성기와 기록 패널

    private func submitLoud(_ c: PlazaWindowController, _ text: String) -> Bool {
        let input = c.chatInputForTesting as! PlazaChatInput   // the Mac's AppKit field
        let editor = NSTextView()
        editor.string = text
        if !input.isLoud { _ = input.control(input.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))) }
        XCTAssertTrue(input.isLoud)
        XCTAssertTrue(input.control(input.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        return !input.isOpen
    }

    func testMegaphoneLineIsSentLoudAndLoggedAndLimitedToOnePerMinute() async {
        let (c, scene, _, other) = await connected()
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertTrue(submitLoud(c, "점심 먹어요"))
        await settle()
        XCTAssertEqual(other.received.loud, ["점심 먹어요"])
        XCTAssertEqual(c.chatLogLines.last?.isLoud, true)
        XCTAssertEqual(c.banner, L(.ko).teamMegaphoneNotice(nickname: "나", text: "점심 먹어요"))
        now = now.addingTimeInterval(PlazaWindowController.loudInterval - 1)
        scene.handleKeyDown(keyCode: returnKey, characters: nil, isRepeat: false)
        XCTAssertFalse(submitLoud(c, "또"), "the field keeps the line")
        XCTAssertEqual(c.banner, L(.ko).plazaLoudTooSoon)
        let input = c.chatInputForTesting as! PlazaChatInput   // the Mac's AppKit field
        _ = input.control(input.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertFalse(input.isLoud)
        XCTAssertTrue(submit(c, "보통 말은 돼요"), "an ordinary line is not limited")
        await settle()
        XCTAssertEqual(other.received.loud, ["점심 먹어요"])
        XCTAssertEqual(other.received.lines.map(\.text), ["점심 먹어요", "보통 말은 돼요"])
    }

    func testReceivedMegaphoneIsMarkedInTheLog() async {
        let (c, _, _, other) = await connected()
        c.showChat(memberID: other.settings.memberID, text: "모두 회의실로", isLoud: true)
        XCTAssertEqual(c.chatLogLines.last?.isLoud, true)
    }

    func testChatLogExpandsAndTakesClicksOnlyWithLines() async throws {
        let log = PlazaChatLog()
        let view = PlazaChatLogHostingView(rootView: PlazaChatLogView(log: log), log: log)
        view.frame = NSRect(x: 0, y: 0, width: PlazaChatLog.width, height: 120)
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 20)), "an empty log lets clicks through")
        log.append(time: now, name: "a", text: "b", color: PlazaNameColor.palette[0])
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertFalse(view.acceptsFirstResponder)
        let (c, _, _, other) = await connected()
        c.showChat(memberID: other.settings.memberID, text: "안녕")
        XCTAssertFalse(c.isChatLogExpanded)
        c.toggleChatLog()
        XCTAssertTrue(c.isChatLogExpanded)
        c.toggleChatLog()
        XCTAssertFalse(c.isChatLogExpanded)
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

    func testPhotoCarriesTheLine() throws {
        let c = controller(node("나"))
        c.prepareScene()
        let scene = c.scene!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = PlazaFrame(image: PlazaImage(cgImage: ctx.makeImage()!), delay: 0.1)
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
