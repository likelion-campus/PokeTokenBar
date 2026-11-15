#if os(Windows)
import WinSDK
import XCTest
@testable import PokeTokenBar

/// The Windows chat field (stage 6 Task 11, D13): the Mac field's rules (`PlazaChatInputTests` in `PlazaChatTests+Mac`) on the real
/// `EDIT` control, its messages sent to it directly (no message pump in XCTest: `--selftest` drives the real pump, the hook and the
/// keyboard on the runner). What a real IME reports is a script (`FakeIME`): its composition string, and on "finish" what IMM does
/// synchronously (the result, the end, the characters). The field's host is the plain child here: a layered child window needs the
/// app's Windows 8+ manifest, which the XCTest process does not have (the app's host is checked on screen by `plaza.chatChildVisible`).
@MainActor final class WindowsPlazaChatInputTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    @MainActor final class Box { var sent: [String] = []; var closes = 0; var accept = true }
    @MainActor final class FakeIME { var composition = ""; var result = ""; var finishes: [Bool] = [] }

    @MainActor private struct Rig {
        let input: WinPlazaChatInput, box: Box, ime: FakeIME, parent: WinSinkWindow, edit: HWND
    }

    private var parents: [WinSinkWindow] = []
    private var inputs: [WinPlazaChatInput] = []

    private var shippedHost = WinPlazaChatInput.fieldHost

    override func setUp() async throws {
        shippedHost = WinPlazaChatInput.fieldHost
        WinPlazaChatInput.fieldHost = .child
    }

    override func tearDown() async throws {
        WinPlazaChatInput.fieldHost = shippedHost
        WinChatFaults.active = []
        for i in inputs { i.detach() }   // the field first, then its window
        inputs = []
        for p in parents { p.destroy() }
        parents = []
    }

    private func rig(open: Bool = true) throws -> Rig {
        let parent = try WinSinkWindow(className: "PTBTestChatParent", title: "chat", style: DWORD(WS_OVERLAPPED), exStyle: 0,
                                       x: 0, y: 0, width: 640, height: 400)
        parents.append(parent)
        let input = WinPlazaChatInput()
        inputs.append(input)
        XCTAssertTrue(input.attach(parent: parent.hwnd))
        let edit = try XCTUnwrap(input.editHWND, "the field was not made")
        input.report(size: CGSize(width: 640, height: 400), scale: 1)
        let ime = FakeIME()
        input.ime = .init(composition: { _ in ime.composition }, result: { _ in ime.result }, finish: { h, cancel in
            ime.finishes.append(cancel)
            let text = ime.composition
            ime.composition = ""
            if !cancel, !text.isEmpty {
                ime.result = text
                _ = SendMessageW(h, 0x010F, 0, 0x800)   // WM_IME_COMPOSITION, GCS_RESULTSTR
                for u in text.utf16 { _ = SendMessageW(h, 0x0102, WPARAM(u), 1) }   // the committed characters
            } else {
                _ = SendMessageW(h, 0x010F, 0, 0)
            }
            _ = SendMessageW(h, 0x010E, 0, 0)   // WM_IME_ENDCOMPOSITION
            ime.result = ""
        })
        let box = Box()
        input.onSubmit = { box.sent.append($0); return box.accept }
        input.onClose = { box.closes += 1 }
        if open { input.open() }
        return Rig(input: input, box: box, ime: ime, parent: parent, edit: edit)
    }

    private func type(_ r: Rig, _ text: String) {
        for u in text.utf16 { _ = SendMessageW(r.edit, 0x0102, WPARAM(u), 1) }
    }

    private func key(_ r: Rig, _ vk: WPARAM, repeat isRepeat: Bool = false) {
        _ = SendMessageW(r.edit, 0x0100, vk, isRepeat ? LPARAM(1 | (1 << 30)) : 1)
    }

    /// What the IME does at the start of a syllable and on every jamo: the field's composition record follows it.
    private func compose(_ r: Rig, _ steps: [String]) {
        _ = SendMessageW(r.edit, 0x010D, 0, 0)
        for s in steps {
            r.ime.composition = s
            _ = SendMessageW(r.edit, 0x010F, 0, 0x8)   // GCS_COMPSTR
        }
    }

    func testEnterSendsTheTypedTextAndCloses() async throws {
        let r = try rig()
        type(r, "안녕")
        key(r, 0x0D)
        XCTAssertEqual(r.box.sent, ["안녕"])
        XCTAssertFalse(r.input.isOpen)
        XCTAssertEqual(r.box.closes, 1)
        XCTAssertEqual(r.input.text, "", "a closed field keeps nothing")
    }

    func testRefusedLineStaysInTheField() async throws {
        let r = try rig()
        r.box.accept = false
        type(r, "안녕")
        key(r, 0x0D)
        XCTAssertTrue(r.input.isOpen)
        XCTAssertEqual(r.input.text, "안녕")
        XCTAssertEqual(r.input.counts.refused, 1)
    }

    func testEnterWhileComposingOnlyFinishesTheSyllable() async throws {
        let r = try rig()
        compose(r, ["ㅎ", "하"])
        XCTAssertEqual(r.input.composition?.text, "하")
        XCTAssertTrue(r.input.isComposing)
        key(r, 0x0D)
        XCTAssertTrue(r.box.sent.isEmpty)
        XCTAssertTrue(r.input.isOpen, "the line must not be lost")
        XCTAssertEqual(r.ime.finishes, [false], "completed, not cancelled")
        XCTAssertNil(r.input.composition)
        XCTAssertEqual(r.input.text, "하")
        key(r, 0x0D)
        XCTAssertEqual(r.box.sent, ["하"], "the next Enter sends it")
    }

    func testHeldEnterDoesNotCloseTheFieldItOpened() async throws {
        let r = try rig()
        key(r, 0x0D, repeat: true)
        XCTAssertTrue(r.input.isOpen)
        XCTAssertTrue(r.box.sent.isEmpty)
        type(r, "a")
        key(r, 0x0D, repeat: true)
        XCTAssertTrue(r.input.isOpen, "a held Enter never sends")
        XCTAssertEqual(r.input.counts.repeatsIgnored, 2)
    }

    func testTabKeepsTheLineAndTogglesTheMegaphone() async throws {
        let r = try rig()
        type(r, "안녕")
        XCTAssertFalse(r.input.isLoud)
        key(r, 0x09)
        XCTAssertTrue(r.input.isLoud)
        XCTAssertTrue(r.input.bar.isLoud, "the border turns orange")
        key(r, 0x09)   // Shift+Tab is the same key
        XCTAssertFalse(r.input.isLoud)
        XCTAssertTrue(r.input.isOpen)
        XCTAssertEqual(r.input.text, "안녕", "Tab types nothing")
        key(r, 0x09)
        r.input.close(); r.input.open()
        XCTAssertFalse(r.input.isLoud, "each new line starts as an ordinary line")
    }

    func testCuttingAnOverlongLineKeepsTheCaret() async throws {
        let r = try rig()
        type(r, String(repeating: "가", count: TeamChat.maxCharacters))
        _ = SendMessageW(r.edit, 0x00B1, 10, 10)
        type(r, "나")
        XCTAssertEqual(r.input.text.count, TeamChat.maxCharacters)
        XCTAssertEqual(r.input.selection.start, 11)
        XCTAssertEqual(r.input.counts.cuts, 1)
    }

    func testEscapeClosesWithoutSending() async throws {
        let r = try rig()
        type(r, "안녕")
        key(r, 0x1B)
        XCTAssertTrue(r.box.sent.isEmpty)
        XCTAssertFalse(r.input.isOpen)
        r.input.open()
        XCTAssertEqual(r.input.text, "", "a cancelled line does not come back")
    }

    /// Esc in the middle of a syllable: the composition is cancelled with the line, so the next open shows no ghost syllable.
    func testEscapeWhileComposingLeavesNoGhost() async throws {
        let r = try rig()
        type(r, "안")
        compose(r, ["ㄴ", "녀"])
        key(r, 0x1B)
        XCTAssertEqual(r.ime.finishes, [true], "cancelled")
        XCTAssertNil(r.input.composition)
        r.input.open()
        XCTAssertEqual(r.input.text, "")
        XCTAssertFalse(r.input.isComposing)
        XCTAssertTrue(r.box.sent.isEmpty)
    }

    func testOverlongTextIsCutAfterComposingEnds() async throws {
        let r = try rig()
        type(r, String(repeating: "가", count: TeamChat.maxCharacters))
        compose(r, ["ㄴ", "나"])
        type(r, "나")   // the syllable in place, as the EDIT shows a composition
        XCTAssertEqual(r.input.text.count, TeamChat.maxCharacters + 1, "composing text is left alone")
        XCTAssertEqual(r.input.counts.cuts, 0)
        r.ime.composition = ""
        _ = SendMessageW(r.edit, 0x010E, 0, 0)
        XCTAssertEqual(r.input.text.count, TeamChat.maxCharacters, "cut once the syllable is done")
    }

    func testPickingAnEmojiPutsItAtTheCaretAndKeepsTheInputOpen() async throws {
        let r = try rig()
        type(r, "안녕")
        _ = SendMessageW(r.edit, 0x00B1, 1, 1)
        r.input.hud.press(PlazaPanelHit(action: "emoji", index: nil), in: .chatBar)
        XCTAssertTrue(r.input.bar.isEmojiOpen)
        let i = try XCTUnwrap(PlazaChatEmojis.all.firstIndex(of: "🍜"))
        r.input.hud.press(PlazaPanelHit(action: "pick", index: i), in: .chatBar)
        XCTAssertEqual(r.input.text, "안🍜녕")
        XCTAssertTrue(r.input.isOpen)
        XCTAssertTrue(r.input.bar.isEmojiOpen, "stays open for another pick")
        XCTAssertTrue(r.box.sent.isEmpty)
    }

    func testPickingWhileComposingKeepsTheSyllable() async throws {
        let r = try rig()
        compose(r, ["ㄱ", "가"])
        r.input.insert("😀")
        XCTAssertEqual(r.ime.finishes, [false])
        XCTAssertFalse(r.input.isComposing)
        XCTAssertEqual(r.input.text, "가😀")
    }

    func testPickingAtTheLimitKeepsTheLimit() async throws {
        let r = try rig()
        type(r, String(repeating: "가", count: TeamChat.maxCharacters))
        r.input.insert("🔥")
        XCTAssertEqual(r.input.text.count, TeamChat.maxCharacters)
    }

    func testPanelIsFoldedWhenTheInputOpensAgain() async throws {
        let r = try rig()
        r.input.hud.press(PlazaPanelHit(action: "emoji", index: nil), in: .chatBar)
        r.input.close()
        XCTAssertFalse(r.input.bar.isEmojiOpen)
        r.input.open()
        XCTAssertFalse(r.input.bar.isEmojiOpen)
    }

    /// A paste is one line: line breaks and tabs become spaces (a single-line EDIT would keep only the first line), long text is cut.
    func testPasteIsOneLineAndKeepsTheLimit() async throws {
        let r = try rig()
        r.input.clipboardText = { "첫 줄\r\n둘째\t줄\n셋" }
        _ = SendMessageW(r.edit, 0x0302, 0, 0)
        XCTAssertEqual(r.input.text, "첫 줄 둘째 줄 셋")
        r.input.clipboardText = { String(repeating: "x", count: 10_000) }
        _ = SendMessageW(r.edit, 0x0302, 0, 0)
        XCTAssertEqual(r.input.text.count, TeamChat.maxCharacters)
        XCTAssertEqual(r.input.counts.pastes, 2)
        XCTAssertEqual(WinPlazaChatInput.pastable("a\r\nb"), "a b", "CRLF is one character: one space")
        XCTAssertEqual(WinPlazaChatInput.pastable("👨‍👩‍👧 \u{1F600}"), "👨‍👩‍👧 \u{1F600}", "joined emoji stay whole")
    }

    /// Characters the line never takes: Enter, Tab, Esc, Ctrl+A / Ctrl+W, Ctrl+Backspace's DEL; Backspace and Ctrl+C / V / X / Z pass.
    func testControlCharactersStayOutOfTheLine() async throws {
        for c: UInt32 in [0x0D, 0x0A, 0x09, 0x1B, 0x01, 0x17, 0x7F, 0x02] { XCTAssertTrue(WinPlazaChatInput.swallows(character: c), "\(c)") }
        for c: UInt32 in [0x08, 0x03, 0x16, 0x18, 0x1A, 0x20, 0xD55C, 0xD83D] { XCTAssertFalse(WinPlazaChatInput.swallows(character: c), "\(c)") }
        let r = try rig()
        type(r, "a\r\t\u{1B}\u{7F}b")
        XCTAssertEqual(r.input.text, "ab")
    }

    /// UTF-16 halves arrive one WM_CHAR at a time (the emoji panel, VK_PACKET): the line holds the whole character, once.
    func testSurrogatesAndJoinedEmojiArriveWhole() async throws {
        let r = try rig()
        type(r, "😀👨‍👩‍👧한")
        XCTAssertEqual(r.input.text, "😀👨‍👩‍👧한")
        XCTAssertEqual(r.input.text.count, 3)
    }

    /// The bar is the field's chrome: closed it is hidden, open it sits where the Mac's does and the field is inside it.
    func testTheFieldSitsInTheBar() async throws {
        let r = try rig(open: false)
        await flush()
        XCTAssertNil(r.input.barFrame)
        XCTAssertNil(r.input.fieldPixels)
        r.input.open()
        XCTAssertNotNil(r.input.fieldPixels, "the field shows at once")
        await flush()
        let bar = try XCTUnwrap(r.input.barFrame)
        XCTAssertEqual(bar, CGRect(x: 16, y: 400 - 16 - 37, width: 360, height: 37))
        let f = try XCTUnwrap(r.input.fieldPixels)
        XCTAssertEqual(f.x, 16 + 10)
        XCTAssertEqual(f.y, Int32(400 - 16 - 37 + 12))
        XCTAssertEqual(f.w, 316)
        XCTAssertEqual(f.h, 21)
        XCTAssertEqual(r.input.drawList.count, 1)
        r.input.hud.press(PlazaPanelHit(action: "emoji", index: nil), in: .chatBar)
        await flush()
        XCTAssertEqual(r.input.barFrame?.height, 169, "the grid unfolds upward")
        XCTAssertEqual(r.input.fieldPixels?.y, Int32(400 - 16 - 169 + 144))
        r.input.close()
        await flush()
        XCTAssertNil(r.input.fieldPixels)
        XCTAssertEqual(r.input.drawList.count, 0)
        r.input.detach()
        XCTAssertNil(r.input.editHWND)
    }

    /// Each rule above, broken on purpose (`WinChatFaults`, debug builds), is noticed by its scenario; with no fault every scenario holds.
    func testEachInjectedFaultIsCaught() async throws {
        defer { WinChatFaults.active = [] }
        let scenarios: [(WinChatFaults.Fault, @MainActor () throws -> Bool)] = [
            (.sendWhileComposing, { [self] in
                let r = try rig(); compose(r, ["ㅎ", "하"]); key(r, 0x0D); return r.box.sent.isEmpty && r.input.isOpen }),
            (.sendOnRepeat, { [self] in
                let r = try rig(); type(r, "a"); key(r, 0x0D, repeat: true); return r.box.sent.isEmpty }),
            (.cutWhileComposing, { [self] in
                let r = try rig(); type(r, String(repeating: "가", count: TeamChat.maxCharacters)); compose(r, ["나"]); type(r, "나")
                return r.input.text.count == TeamChat.maxCharacters + 1 }),
            (.pasteKeepsLineBreaks, { [self] in
                let r = try rig(); r.input.clipboardText = { "a\r\nb\tc" }; _ = SendMessageW(r.edit, 0x0302, 0, 0); return r.input.text == "a b c" }),
            (.keepCompositionOnClose, { [self] in
                let r = try rig(); compose(r, ["ㄱ"]); key(r, 0x1B); return r.ime.finishes == [true] }),
            (.insertOverComposition, { [self] in
                let r = try rig(); compose(r, ["가"]); r.input.insert("😀"); return r.input.text == "가😀" }),
        ]
        XCTAssertEqual(Set(scenarios.map(\.0)), Set(WinChatFaults.Fault.allCases), "every fault has its scenario")
        for (fault, scenario) in scenarios {
            WinChatFaults.active = []
            XCTAssertTrue(try scenario(), "\(fault): the scenario holds without the fault")
            WinChatFaults.active = [fault]
            XCTAssertFalse(try scenario(), "\(fault): the injected fault is caught")
        }
    }

    /// At 150 % the field is in device pixels and the font is the body size at that scale.
    func testTheFieldFollowsTheScale() async throws {
        let r = try rig()
        r.input.report(size: CGSize(width: 640 / 1.5, height: 400 / 1.5), scale: 1.5)
        await flush()
        let f = try XCTUnwrap(r.input.fieldPixels)
        XCTAssertLessThanOrEqual(abs(f.w - Int32((316 * 1.5).rounded())), 1, "\(f)")
        XCTAssertLessThanOrEqual(abs(f.h - Int32((21 * 1.5).rounded())), 1, "\(f)")
    }
}

/// The controller's chat flow (`PlazaChatTests+Controller`) through the Windows field instead of the stub: what the Mac's
/// `testSendingThroughTheRealFieldReachesTheTeammate` and the megaphone test do through the AppKit field.
extension PlazaChatTests {
    private func windowsField() throws -> (WinPlazaChatInput, WinSinkWindow) {
        let parent = try WinSinkWindow(className: "PTBTestChatController", title: "chat", style: DWORD(WS_OVERLAPPED), exStyle: 0,
                                       x: 0, y: 0, width: 640, height: 400)
        let input = WinPlazaChatInput()
        let shipped = WinPlazaChatInput.fieldHost
        WinPlazaChatInput.fieldHost = .child   // a layered child needs the app's manifest (see WindowsPlazaChatInputTests)
        XCTAssertTrue(input.attach(parent: parent.hwnd))
        WinPlazaChatInput.fieldHost = shipped
        input.report(size: CGSize(width: 640, height: 400), scale: 1)
        return (input, parent)
    }

    private func typeAndEnter(_ input: WinPlazaChatInput, _ text: String) {
        guard let h = input.editHWND else { return XCTFail("no field") }
        for u in text.utf16 { _ = SendMessageW(h, 0x0102, WPARAM(u), 1) }
        _ = SendMessageW(h, 0x0100, 0x0D, 1)
    }

    func testSendingThroughTheWindowsFieldReachesTheTeammate() async throws {
        let (input, parent) = try windowsField()
        defer { input.detach(); parent.destroy() }
        let (c, scene, _, other) = await connected(chatInput: input)
        scene.handleKeyDown(keyCode: 36, characters: nil, isRepeat: false)
        XCTAssertTrue(input.isOpen)
        typeAndEnter(input, "  같이 점심?\n")
        XCTAssertFalse(input.isOpen)
        await settle()
        XCTAssertEqual(other.received.lines.map(\.text), ["같이 점심?"])
        XCTAssertEqual(c.chatLogLines.last?.text, "같이 점심?")
    }

    func testMegaphoneThroughTheWindowsFieldIsSentLoudAndLimited() async throws {
        let (input, parent) = try windowsField()
        defer { input.detach(); parent.destroy() }
        let (c, scene, _, other) = await connected(chatInput: input)
        scene.handleKeyDown(keyCode: 36, characters: nil, isRepeat: false)
        guard let h = input.editHWND else { return XCTFail("no field") }
        _ = SendMessageW(h, 0x0100, 0x09, 1)   // Tab
        XCTAssertTrue(input.isLoud)
        typeAndEnter(input, "점심 먹어요")
        await settle()
        XCTAssertEqual(other.received.loud, ["점심 먹어요"])
        XCTAssertEqual(c.chatLogLines.last?.isLoud, true)
        now = now.addingTimeInterval(PlazaWindowController.loudInterval - 1)
        scene.handleKeyDown(keyCode: 36, characters: nil, isRepeat: false)
        _ = SendMessageW(h, 0x0100, 0x09, 1)
        typeAndEnter(input, "또")
        XCTAssertTrue(input.isOpen, "the field keeps the line")
        XCTAssertEqual(input.text, "또")
        XCTAssertEqual(c.banner, L(.ko).plazaLoudTooSoon)
    }

    /// Closing the plaza closes the line (the controller's `handleClose`), with nothing sent.
    func testClosingThePlazaClosesTheWindowsField() async throws {
        let (input, parent) = try windowsField()
        defer { input.detach(); parent.destroy() }
        let (c, scene, _, other) = await connected(chatInput: input)
        scene.handleKeyDown(keyCode: 36, characters: nil, isRepeat: false)
        guard let h = input.editHWND else { return XCTFail("no field") }
        for u in "안녕".utf16 { _ = SendMessageW(h, 0x0102, WPARAM(u), 1) }
        c.handleClose()
        XCTAssertFalse(input.isOpen)
        await settle()
        XCTAssertTrue(other.received.lines.isEmpty)
    }
}
#endif
