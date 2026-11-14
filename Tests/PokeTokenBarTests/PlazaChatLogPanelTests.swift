import XCTest
@testable import PokeTokenBar

/// The chat log as a panel (Track A Task 17b), stub graphics (monospace text: in the body font a character is 9 points,
/// a line 15 tall, the header's small font 12 tall, so the 340-point text holds 37 characters), so it runs on Windows too.
/// The SwiftUI view's own numbers are in `PlazaChatLogPanelRenderTests+Mac`.
@MainActor final class PlazaChatLogPanelTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Rig {
        let log: PlazaChatLog, panel: PlazaChatLogPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics
        let actions: Actions
    }
    @MainActor final class Actions { var list: [String] = [] }

    private func rig(lines: Int = 0, expanded: Bool = false, viewport: CGSize = CGSize(width: 960, height: 640), scale: CGFloat = 2,
                     text: (Int) -> String = { "줄 \($0)" }) -> Rig {
        let log = PlazaChatLog()
        for i in 0..<lines { log.append(time: now, name: "나", text: text(i), color: PlazaNameColor.palette[0]) }
        log.isExpanded = expanded
        let panel = PlazaChatLogPanel(log: log)
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost(), actions = Actions()
        hud.onAction = { id, hit in actions.list.append("\(id) \(hit.action)") }
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        return Rig(log: log, panel: panel, hud: hud, host: host, graphics: graphics, actions: actions)
    }

    private func frame(_ r: Rig) -> CGRect? { r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.chatLog] }
    private func scroll(_ r: Rig, dy: CGFloat, dx: CGFloat = 0, at p: CGPoint? = nil) -> Bool {
        let f = frame(r) ?? .zero
        return r.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: dx, dy: dy), location: p ?? CGPoint(x: f.midX, y: f.midY)), in: .chatLog)
    }
    private func rows(_ r: Rig) -> [(frame: CGRect, image: PlazaImage)] {
        (r.host.drawings[.chatLog]?.layers ?? []).dropFirst(2).compactMap { layer in
            if case .image(let i, let f) = layer { return (f, i) }
            return nil
        }
    }

    // MARK: size and placement

    func testNothingShowsWhileTheLogIsEmpty() async {
        let r = rig()
        XCTAssertFalse(r.panel.isVisible)
        XCTAssertNil(frame(r), "no frame, no clicks")
        XCTAssertNil(r.host.drawings[.chatLog])
        XCTAssertEqual(r.hud.renderCounts[.chatLog] ?? 0, 0)
        r.log.append(time: now, name: "나", text: "안녕", color: PlazaNameColor.palette[0])
        await flush()
        XCTAssertNotNil(r.host.drawings[.chatLog], "the first line shows it")
    }

    func testFoldedHeightIsTheHeaderPlusTheLastSixLines() async {
        // 8 + header 12 + 4 + lines + 8; a line is 15 tall, 3 between them.
        let chrome: CGFloat = 8 + 12 + 4 + 8, line: CGFloat = 15, gap: CGFloat = 3
        XCTAssertEqual(frame(rig(lines: 1))?.size, CGSize(width: 360, height: chrome + line))
        let six: CGFloat = chrome + 6 * line + 5 * gap
        XCTAssertEqual(frame(rig(lines: 6))?.size.height, six)
        let capped = rig(lines: PlazaChatLog.capacity)
        XCTAssertEqual(frame(capped)?.size.height, six, "the cap: only the last six show")
        XCTAssertEqual(capped.host.drawings[.chatLog]?.accessibility.count, 2 + PlazaChatLog.visibleCount)
    }

    func testAWrappedLineIsTallerByWholeLines() async {
        let long = String(repeating: "가", count: 100)   // "나: " + 100 characters + the time: 3 lines of 37
        let r = rig(lines: 2, text: { $0 == 1 ? long : "짧음" })
        // "14:05 나:" is 8 characters; the 100-character word cannot follow it, so it starts a line and breaks between
        // characters: 37 + 37 + 26. Four lines.
        let expected: CGFloat = 8 + 12 + 4 + 15 + 3 + 4 * 15 + 8
        XCTAssertEqual(frame(r)?.height, expected)
    }

    func testUnfoldedIsAlwaysTheFixedWindowOnTheLines() async {
        for n in [1, 3, 50] {
            XCTAssertEqual(frame(rig(lines: n, expanded: true))?.height, 8 + 12 + 4 + PlazaChatLog.expandedHeight + 8, "\(n) lines")
        }
    }

    func testItSitsAtTheBottomLeftOfTheWindowAtEverySize() async {
        for v in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640), CGSize(width: 2560, height: 1440)] {
            for scale in [CGFloat(1), 2] {
                let r = rig(lines: 3, viewport: v, scale: scale), f = frame(r)!
                XCTAssertEqual(f.minX, 16)
                XCTAssertEqual(f.maxY, v.height - 16, "16 above the window's bottom")
                XCTAssertEqual(f.width, 360)
                r.panel.inputHeight = 30
                XCTAssertEqual(frame(r)?.maxY, v.height - 16 - 30 - 8, "8 above the chat field while it is open (\(v))")
            }
        }
    }

    func testOpeningTheChatFieldMovesTheLog() async {
        let r = rig(lines: 2)
        await flush()
        let before = r.hud.renderCounts[.chatLog]
        r.panel.inputHeight = 30
        await flush()
        XCTAssertEqual(r.host.calls.last, .show(.chatLog, frame(r)!, 2))
        XCTAssertEqual(r.hud.renderCounts[.chatLog], (before ?? 0) + 1)
    }

    // MARK: scrolling

    func testUnfoldedItStartsAtTheEndAndOnlyTheRowsInViewAreDrawn() async {
        let r = rig(lines: 50, expanded: true)
        XCTAssertTrue(r.panel.scrollState.isAtBottom)
        XCTAssertEqual(r.panel.scrollState.content, 50 * 15 + 49 * 3)
        let shown = rows(r)
        XCTAssertEqual(shown.count, 14, "rows 36...49 intersect the window; never the whole content")
        XCTAssertEqual(shown.first?.frame, CGRect(x: 10, y: 24, width: 340, height: 6), "row 36 is cut: 9 of its 15 points are above the window")
        XCTAssertEqual(shown.first?.image.height, 6 * 2, "the cut image has only the visible part (2x)")
        XCTAssertEqual(shown.last?.frame, CGRect(x: 10, y: 24 + 225, width: 340, height: 15))
        XCTAssertEqual(shown.last?.frame.maxY, 272 - 8, "the last line ends at the window's bottom")
        XCTAssertTrue(shown.dropFirst().allSatisfy { $0.image.height == 30 }, "the rows in full are whole images")
    }

    func testTheWheelScrollsAndIsConsumedOnlyWhileItCan() async {
        let r = rig(lines: 50, expanded: true)
        XCTAssertFalse(scroll(r, dy: -20), "already at the bottom: down is passed on")
        XCTAssertTrue(scroll(r, dy: 30), "up: consumed")
        XCTAssertEqual(r.panel.scrollState.offset, 627)
        await flush()
        XCTAssertEqual(rows(r).first?.frame, CGRect(x: 10, y: 27, width: 340, height: 15), "row 35 (630...645) now starts the window, whole")
        XCTAssertTrue(scroll(r, dy: 5000), "a big delta moves to the top")
        XCTAssertEqual(r.panel.scrollState.offset, 0, "clamped, no bounce")
        XCTAssertFalse(scroll(r, dy: 10), "at the top, further up is passed on")
        XCTAssertFalse(scroll(r, dy: 0, dx: 40), "a sideways scroll is not the log's")
        XCTAssertTrue(scroll(r, dy: -10, dx: 40), "the vertical part scrolls")
    }

    func testAPanelThatDoesNotScrollPassesTheWheelOn() async {
        let hud = PlazaHUD(panels: [ButtonPanel()], graphics: CanvasKeepingGraphics())
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 200, height: 100), scale: 2)
        hud.host = host
        XCTAssertFalse(hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 20), location: CGPoint(x: 15, y: 15)), in: .backgroundToggle))
    }

    func testAScrollOutsideTheLogOrOnAFoldedLogIsPassedOn() async {
        let r = rig(lines: 50, expanded: true)
        let f = frame(r)!
        XCTAssertFalse(scroll(r, dy: 30, at: CGPoint(x: f.midX, y: f.minY + 12)), "over the header: SwiftUI's header was not the scroll view's")
        XCTAssertFalse(scroll(r, dy: 30, at: CGPoint(x: f.minX + 4, y: f.midY)), "over the padding")
        XCTAssertTrue(scroll(r, dy: 30, at: CGPoint(x: f.minX + 10, y: f.minY + 24)), "the window's corner")
        XCTAssertFalse(scroll(r, dy: 30, at: CGPoint(x: 500, y: 100)), "not over the log")
        let folded = rig(lines: 50)
        XCTAssertFalse(scroll(folded, dy: 30), "a folded log has nothing to scroll")
        XCTAssertFalse(rig(lines: 2, expanded: true).hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 20), location: CGPoint(x: 100, y: 600)), in: .chatLog),
                       "a few lines in the unfolded window fit: nothing to scroll")
    }

    func testAScrolledOffsetIsDrawnOnTheDevicePixelGrid() async {
        let r = rig(lines: 50, expanded: true, scale: 2)
        XCTAssertTrue(scroll(r, dy: 0.3))
        await flush()
        XCTAssertEqual(r.panel.scrollState.offset, 656.7, accuracy: 0.0001, "the model keeps the exact offset")
        XCTAssertEqual(rows(r).first?.frame.minY, 24 + 0, "drawn at 656.5: row 36's top is 648 -> 8.5 above, 6.5 left")
        XCTAssertEqual(rows(r).first?.frame.height, 6.5)
    }

    func testANewLineScrollsToTheEndEvenWhenScrolledUp() async {
        let r = rig(lines: 50, expanded: true)
        XCTAssertTrue(scroll(r, dy: 5000))
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtTop)
        r.log.append(time: now, name: "나", text: "새 줄", color: PlazaNameColor.palette[0])
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtBottom, "SwiftUI's onChange(of: last id) scrolled to the end whatever the position")
        XCTAssertEqual(rows(r).last?.frame.maxY, 272 - 8)
    }

    func testUnfoldingScrollsToTheEndAndFoldedLinesDoNotScroll() async {
        let r = rig(lines: 50)
        r.log.isExpanded = true
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtBottom, "onAppear scrolled to the end")
        XCTAssertTrue(scroll(r, dy: 5000))
        r.log.isExpanded = false
        await flush()
        r.log.isExpanded = true
        await flush()
        XCTAssertTrue(r.panel.scrollState.isAtBottom, "unfolding again starts at the end again")
    }

    func testTheResizedWindowKeepsTheOffsetInRange() async {
        let r = rig(lines: 50, expanded: true)
        XCTAssertTrue(scroll(r, dy: 100))
        await flush()
        r.hud.setViewport(CGSize(width: 600, height: 372), scale: 2)
        await flush()
        XCTAssertEqual(r.panel.scrollState.offset, 557, "a resize does not move the log's content or offset")
        r.hud.setViewport(CGSize(width: 600, height: 372), scale: 1)
        await flush()
        XCTAssertEqual(r.panel.scrollState.offset, 557)
    }

    // MARK: drawing cost

    func testOnlyNewRowsAreDrawnWhileScrolling() async {
        let r = rig(lines: 50, expanded: true)
        await flush()
        let before = r.graphics.canvases.count
        XCTAssertTrue(scroll(r, dy: 15))
        await flush()
        // one line (15 + 3 gap = 18) is not a whole row: row 35 enters, the header image is made again; the other rows are kept.
        XCTAssertLessThanOrEqual(r.graphics.canvases.count - before, 2, "header + the one row that came in")
    }

    func testRendersAreOnePerChangeNeverPerFrame() async {
        let r = rig(lines: 5)
        await flush()
        let base = r.hud.renderCounts[.chatLog] ?? 0
        XCTAssertEqual(base, 1)
        for i in 0..<10 { r.log.append(time: now, name: "나", text: "줄 \(i)", color: PlazaNameColor.palette[0]) }
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 1, "ten lines in one turn: one render")
        await flush()
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 1, "idle: none")
        r.hud.isRendering = false
        r.log.append(time: now, name: "나", text: "숨김", color: PlazaNameColor.palette[0])
        r.log.isExpanded = true
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 1, "a hidden plaza renders nothing")
        r.hud.isRendering = true
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 2, "and once when it shows again")
    }

    func testAWheelEventIsOneRenderEach() async {
        let r = rig(lines: 50, expanded: true)
        await flush()
        let base = r.hud.renderCounts[.chatLog] ?? 0
        for _ in 0..<5 { XCTAssertTrue(scroll(r, dy: 3)); await flush() }
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 5)
        XCTAssertFalse(scroll(r, dy: 0))
        XCTAssertEqual(r.hud.renderCounts[.chatLog], base + 5, "an event that moves nothing renders nothing")
    }

    // MARK: accessibility and clicks

    func testVoiceOverGetsTheHeaderAndEveryRowWithFramesInsideTheWindow() async {
        let r = rig(lines: 50, expanded: true)
        let items = r.host.drawings[.chatLog]!.accessibility
        XCTAssertEqual(items.count, 2 + 50, "every row, as SwiftUI's non-lazy stack exposed them")
        XCTAssertEqual(items[0].label, L(.ko).plazaChatLogTitle)
        XCTAssertEqual(items[0].role, .staticText)
        XCTAssertEqual(items[1].role, .button)
        XCTAssertEqual(items[1].label, L(.ko).plazaChatLogCollapse)
        XCTAssertEqual(items[1].action, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertEqual(items[2].label, "\(PlazaChatLog.timeText(now)) 나: 줄 0", "read as the whole line")
        let window = CGRect(x: 10, y: 24, width: 340, height: 240)
        for item in items.dropFirst(2) { XCTAssertTrue(window.contains(item.frame) || item.frame.height == 0, "\(item.label) \(item.frame)") }
        XCTAssertEqual(items[2].frame, CGRect(x: 10, y: 24, width: 340, height: 0), "a row above the window: empty, at its top")
        XCTAssertEqual(items.last?.frame, CGRect(x: 10, y: 24 + 225, width: 340, height: 15))
        XCTAssertEqual(items[2 + 36].frame, CGRect(x: 10, y: 24, width: 340, height: 6), "the cut row: its visible part")
    }

    func testTheHeaderButtonTogglesAndTheRestOfTheLogTakesTheClickWithoutAnAction() async {
        let r = rig(lines: 3)
        let f = frame(r)!
        let button = CGPoint(x: f.maxX - 10 - 4, y: f.minY + 8 + 5)
        XCTAssertEqual(r.hud.hit(at: button, in: .chatLog), PlazaPanelHit(action: "toggle", index: nil))
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: button), in: .chatLog)
        XCTAssertTrue(r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: button), in: .chatLog))
        XCTAssertEqual(r.actions.list, ["chatLog toggle"])
        let body = CGPoint(x: f.minX + 40, y: f.maxY - 20)
        XCTAssertEqual(r.hud.hit(at: body, in: .chatLog), PlazaPanelHit(action: "log", index: nil), "a click on the log is taken: it does not reach the scene")
        XCTAssertTrue(r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: body), in: .chatLog))
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: body), in: .chatLog)
        XCTAssertEqual(r.actions.list, ["chatLog toggle", "chatLog log"], "the body's click is reported as `log`, which the owner ignores (as the menu's body)")
        XCTAssertNil(r.hud.hit(at: CGPoint(x: f.maxX + 1, y: f.midY), in: .chatLog), "beside the log: through")
        XCTAssertNil(r.hud.hit(at: CGPoint(x: f.midX, y: f.minY - 1), in: .chatLog), "above it: through")
    }

    func testThePressedButtonIsDrawnDimmed() async {
        let r = rig(lines: 3)
        await flush()
        let f = frame(r)!
        let button = CGPoint(x: f.maxX - 14, y: f.minY + 13)
        let before = r.graphics.canvases.count
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: button), in: .chatLog)
        await flush()
        XCTAssertTrue(r.graphics.canvases[before...].contains { $0.calls.contains("alpha \(Double(PlazaPanelStyle.pressedOpacity))") }, "the header is made again with the button dimmed")
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: 400, y: 10)), in: .chatLog)
    }

    func testEachRunOfALineIsDrawnInItsOwnColour() async {
        let log = PlazaChatLog()
        let colour = PlazaColor(hex: 0x7FD4FF)
        log.append(time: now, name: "나", text: "크게", color: colour, isLoud: true)
        let runs = PlazaChatLogPanel.runs(log.lines[0])
        XCTAssertEqual(runs.map(\.text), ["\(PlazaChatLog.timeText(now)) ", "📢 ", "나: ", "크게"])
        XCTAssertEqual(runs.map(\.color), [PlazaChatLogStyle.dimmed, PlazaChatLogStyle.ink, colour, PlazaChatLogStyle.loud])
        log.append(time: now, name: "너", text: "보통", color: colour)
        XCTAssertEqual(PlazaChatLogPanel.runs(log.lines[1]).map(\.text), ["\(PlazaChatLog.timeText(now)) ", "너: ", "보통"], "no 📢 run")
        XCTAssertEqual(PlazaChatLogPanel.runs(log.lines[1]).last?.color, PlazaChatLogStyle.ink)
    }
}
