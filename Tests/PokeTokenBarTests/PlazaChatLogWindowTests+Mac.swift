import AppKit
import XCTest
@testable import PokeTokenBar

/// The chat log in the real plaza window (Track A Task 17w): the shared panel in `PlazaMacWindow`, the window never shown and
/// never key. What a click, the wheel, the chat field and VoiceOver do to it, and what it costs.
@MainActor final class PlazaChatLogWindowTests: XCTestCase {
    private func line(_ rig: PlazaWindowRig, _ n: Int, _ text: String? = nil) {
        rig.overlays.chatLog.append(time: Date(timeIntervalSince1970: 1_700_000_000), name: "팀원", text: text ?? "줄 \(n)", color: PlazaNameColor.palette[0])
    }
    private func fill(_ rig: PlazaWindowRig, _ count: Int) {
        for n in 0..<count { line(rig, n) }
    }

    /// The header button's centre and a point on the body, in panel points.
    private func button(_ rig: PlazaWindowRig) throws -> CGPoint {
        let f = try XCTUnwrap(rig.frame(.chatLog))
        return CGPoint(x: f.width - 10 - 12, y: 8 + 6)
    }

    func testNothingTakesAClickWhileTheLogIsEmpty() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        await rig.flush()
        XCTAssertNil(rig.host(.chatLog)?.panelFrame, "no lines: nothing drawn")
        XCTAssertTrue(rig.container.hitTest(NSPoint(x: 40, y: 40)) !== rig.host(.chatLog), "the click goes below")
        line(rig, 0)
        await rig.flush()
        let f = try XCTUnwrap(rig.frame(.chatLog))
        XCTAssertEqual(f.minX, 16)
        XCTAssertEqual(f.maxY, rig.container.bounds.height - 16, accuracy: 0.001, "16 from the bottom")
        XCTAssertTrue(try XCTUnwrap(rig.hitView(.chatLog, CGPoint(x: f.width / 2, y: f.height / 2))) === rig.host(.chatLog))
    }

    func testTheButtonTogglesTheBodyIsTakenAndTheKeysStayWhereTheyWere() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        fill(rig, 3)
        await rig.flush()
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
        // A click on the log's body: taken (the scene gets no click), nothing happens, the keys stay with the scene.
        try rig.click(.chatLog, at: CGPoint(x: 100, y: 40))
        XCTAssertFalse(rig.controller.isChatLogExpanded)
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
        // While the chat field is open and typing, a click on the body leaves the field focused.
        rig.shell.focusChatInput()
        XCTAssertFalse(rig.window.firstResponder === rig.skView, "the field has the keys")
        let before = rig.window.firstResponder
        try rig.click(.chatLog, at: CGPoint(x: 100, y: 40))
        XCTAssertTrue(rig.window.firstResponder === before, "a panel click never moves the keys")
        XCTAssertFalse(rig.controller.isChatLogExpanded)
        // The button expands it (and, as the SwiftUI button did, the controller gives the keys back to the scene).
        rig.shell.focusScene()
        try rig.click(.chatLog, at: try button(rig))
        XCTAssertTrue(rig.controller.isChatLogExpanded)
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
        await rig.flush()
        let f = try XCTUnwrap(rig.frame(.chatLog))
        XCTAssertEqual(f.height, 274, "unfolded: always 274")
        try rig.click(.chatLog, at: try button(rig))
        XCTAssertFalse(rig.controller.isChatLogExpanded, "the same button folds it again")
    }

    func testItRidesAboveTheChatFieldWhileItIsOpen() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        fill(rig, 2)
        await rig.flush()
        let chat = try XCTUnwrap(rig.overlays.chatInput as? PlazaChatInput)
        let h = rig.container.bounds.height
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, h - 16, accuracy: 0.001)
        chat.open()
        rig.shell.setChatLogAboveInput(true)
        await rig.flush()
        rig.container.layoutSubtreeIfNeeded()
        let barTop = h - chat.view.frame.maxY   // top-left coordinates
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, barTop - 8, accuracy: 0.001, "8 above the field, as the constraint put it")
        XCTAssertGreaterThan(chat.view.frame.height, 20)
        chat.close()
        rig.shell.setChatLogAboveInput(false)
        await rig.flush()
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, h - 16, accuracy: 0.001, "back at the bottom")
    }

    func testTheWheelScrollsTheUnfoldedLogAndPassesOnAtTheEnds() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        fill(rig, 50)
        rig.controller.toggleChatLog()
        await rig.flush()
        let panel = try XCTUnwrap(rig.panel(.chatLog, as: PlazaChatLogPanel.self))
        let body = CGPoint(x: 100, y: 80)
        XCTAssertTrue(panel.scrollState.isAtBottom, "unfolding scrolls to the end")
        XCTAssertFalse(try rig.panelTakesScroll(.chatLog, at: body, dy: -30), "at the bottom, further down passes on")
        let end = panel.scrollState.offset
        try rig.scroll(.chatLog, at: body, dy: 30)
        XCTAssertEqual(panel.scrollState.offset, end - 30, accuracy: 0.001, "the host gave the wheel to the panel")
        try rig.scroll(.chatLog, at: body, dy: 1, precise: false)
        XCTAssertEqual(panel.scrollState.offset, end - 30 - PlazaPanelHostView.lineScrollStep, accuracy: 0.001)
        XCTAssertTrue(try rig.panelTakesScroll(.chatLog, at: body, dy: 100_000))
        XCTAssertFalse(try rig.panelTakesScroll(.chatLog, at: body, dy: 10), "at the top, further up passes on")
        XCTAssertFalse(try rig.panelTakesScroll(.chatLog, at: CGPoint(x: 100, y: 10), dy: -30), "over the header: passed on")
        // New lines scroll to the end again, whatever the user scrolled to.
        await rig.flush()
        XCTAssertTrue(panel.scrollState.isAtTop)
        line(rig, 99, "새 줄")
        await rig.flush()
        XCTAssertTrue(panel.scrollState.isAtBottom)
    }

    func testVoiceOverReadsTheTitleTheButtonAndEveryLineAndAScrollStepSaysNothing() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        fill(rig, 30)
        rig.controller.toggleChatLog()
        await rig.flush()
        let host = try XCTUnwrap(rig.host(.chatLog))
        let children = try XCTUnwrap(host.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 2 + 30)
        XCTAssertEqual(children[0].accessibilityRole(), .staticText)
        XCTAssertEqual(children[0].accessibilityLabel(), L(.ko).plazaChatLogTitle)
        XCTAssertEqual(children[1].accessibilityRole(), .button)
        XCTAssertEqual(children[1].accessibilityLabel(), L(.ko).plazaChatLogCollapse)
        XCTAssertTrue(try XCTUnwrap(children[2].accessibilityLabel()).hasSuffix("팀원: 줄 0"))
        XCTAssertTrue(try XCTUnwrap(children[31].accessibilityLabel()).hasSuffix("팀원: 줄 29"))
        let announced = host.accessibilityChangesForTesting
        let frame = children[31].accessibilityFrameInParentSpace()
        for _ in 0..<10 {
            try rig.scroll(.chatLog, at: CGPoint(x: 100, y: 80), dy: 12)
            await rig.flush()
        }
        XCTAssertEqual(host.accessibilityChangesForTesting, announced, "ten scroll steps: VoiceOver is not told the layout changed")
        XCTAssertNotEqual(try XCTUnwrap(host.accessibilityChildren() as? [NSAccessibilityElement])[31].accessibilityFrameInParentSpace(), frame,
                          "the frames did follow the scroll")
        // The button's press is the same hit a click reports.
        try XCTUnwrap(children[1] as? PlazaPanelAccessibilityElement).accessibilityPerformPress()
        XCTAssertFalse(rig.controller.isChatLogExpanded, "VoiceOver's press on the button folds the log")
    }

    /// What the log costs in the real window: a scroll step is one render; after the indicator's fade nothing runs.
    func testItRendersOnlyForChangesAndTheIndicatorsTimersEndAfterTheFade() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        fill(rig, 50)
        rig.controller.toggleChatLog()
        await rig.flush()
        let panel = try XCTUnwrap(rig.panel(.chatLog, as: PlazaChatLogPanel.self))
        XCTAssertTrue(panel.scrollIndicator.isTimerRunning, "opening scrolled to the end: the scroller is showing")
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertFalse(panel.scrollIndicator.isTimerRunning, "hold and fade are over: no timer")
        let idle = rig.hud.renderCounts[.chatLog] ?? 0
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(rig.hud.renderCounts[.chatLog] ?? 0, idle, "idle and visible: no renders")
        // Hidden: a scroll renders nothing (the HUD is not rendering); no timer outlives the fade.
        rig.hud.isRendering = false
        _ = try rig.panelTakesScroll(.chatLog, at: CGPoint(x: 100, y: 80), dy: 40)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertEqual(rig.hud.renderCounts[.chatLog] ?? 0, idle, "hidden: nothing renders")
        XCTAssertFalse(panel.scrollIndicator.isTimerRunning)
        rig.hud.isRendering = true
    }
}

/// Task 17w review item 4: the chat bar's frame change (the emoji panel opening resizes it DURING the window's layout pass) must never force
/// layout again, and the log still rides above the bar.
@MainActor final class PlazaChatLogLayoutTests: XCTestCase {
    func testTheEmojiPanelResizingTheBarNeverForcesLayoutInsideALayoutPass() async throws {
        let rig = try PlazaWindowRig()
        defer { rig.close() }
        rig.overlays.chatLog.append(time: Date(), name: "팀원", text: "안녕", color: PlazaNameColor.palette[0])
        await rig.flush()
        let content = try XCTUnwrap(rig.window.contentView as? PlazaWindowContentView)
        let chat = try XCTUnwrap(rig.overlays.chatInput as? PlazaChatInput)
        chat.open()
        rig.shell.setChatLogAboveInput(true)
        rig.container.layoutSubtreeIfNeeded()
        await rig.flush()
        let h = rig.container.bounds.height
        let closedBar = chat.view.frame.height
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, h - 16 - closedBar - 8, accuracy: 0.001)
        // The emoji panel opens: the bar grows inside the next layout pass.
        chat.emojiButton.performClick(nil)
        XCTAssertTrue(chat.isEmojiPanelOpen)
        rig.container.needsLayout = true
        rig.container.layoutSubtreeIfNeeded()
        await rig.flush()
        XCTAssertGreaterThan(chat.view.frame.height, closedBar, "the bar really grew")
        XCTAssertEqual(content.forcedLayoutsDuringLayoutForTesting, 0, "layout was never forced from inside a layout pass")
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, h - 16 - chat.view.frame.height - 8, accuracy: 0.001, "the log moved up with the bar")
        chat.close()
        rig.shell.setChatLogAboveInput(false)
        await rig.flush()
        XCTAssertEqual(try XCTUnwrap(rig.frame(.chatLog)).maxY, h - 16, accuracy: 0.001)
    }
}
