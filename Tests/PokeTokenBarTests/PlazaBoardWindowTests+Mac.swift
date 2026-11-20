import AppKit
import XCTest
@testable import PokeTokenBar

/// The news board in the real plaza window (Track A Task 17w): the shared panel in `PlazaMacWindow`, the window never shown and
/// never key. Reaction buttons (and my own, disabled), the wheel, the keys, VoiceOver, no relayout, cost.
@MainActor final class PlazaBoardWindowTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    /// `events` events, newest first; the first has my own "cute" reaction (so that button is disabled).
    private func feed(_ events: Int) -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardWindowTests-\(UUID())")
        dirs.append(dir)
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        let f = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "member-1", clock: { now })
        for i in (0..<events).reversed() {
            f.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)",
                               fromSpeciesName: nil, form: nil, isShiny: false, nature: nil, rarity: .common, day: "2026-10-30",
                               occurredAt: now.addingTimeInterval(-3600 - Double(i) * 60)))
        }
        f.insert(TeamReaction(id: "r0", eventID: "e0", authorID: "member-1", authorNickname: "나", kind: .cute, text: nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100)))
        return f
    }

    private func rig(events: Int = 30, open: Bool = true) async throws -> PlazaWindowRig {
        let rig = try PlazaWindowRig(feed: feed(events))
        if open { rig.overlays.overlayModel.content = .board; rig.controller.scene?.isOverlayOpen = true }
        await rig.flush()
        return rig
    }

    /// Every element in item order (the scroll area's children included).
    private func children(_ rig: PlazaWindowRig) throws -> [PlazaPanelAccessibilityElement] {
        try XCTUnwrap(rig.host(.board)).accessibilityElementsForTesting
    }
    /// The centre of an accessibility child in window points (its frame is in the host's space, which is the window's).
    private func centre(_ e: PlazaPanelAccessibilityElement) -> NSPoint {
        let f = e.hostFrame
        return NSPoint(x: f.midX, y: f.midY)
    }
    private func buttons(_ rig: PlazaWindowRig) throws -> [PlazaPanelAccessibilityElement] { try children(rig).filter { $0.accessibilityRole() == .button } }

    func testTheBoardIsCentredAndTakesClicksOnlyOnItsPlate() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let f = try XCTUnwrap(rig.frame(.board))
        XCTAssertEqual(f.size, CGSize(width: 340, height: 380))
        XCTAssertEqual(f.midX, rig.container.bounds.width / 2, accuracy: 1)
        XCTAssertEqual(f.midY, rig.container.bounds.height / 2, accuracy: 1)
        let host = try XCTUnwrap(rig.host(.board))
        XCTAssertTrue(try XCTUnwrap(rig.hitView(.board, CGPoint(x: 170, y: 190))) === host)
        XCTAssertTrue(rig.hitView(.board, CGPoint(x: -30, y: 190)) === host, "beside the plate the host still takes it (the SwiftUI overlay covered the whole window) and nothing acts")
        XCTAssertTrue(rig.hitView(.board, CGPoint(x: 170, y: 400)) === host)
        // Closed: nothing is drawn and nothing takes a click.
        rig.overlays.overlayModel.content = .none
        await rig.flush()
        XCTAssertNil(host.panelFrame)
        XCTAssertTrue(rig.container.hitTest(NSPoint(x: rig.container.bounds.midX, y: rig.container.bounds.midY)) !== host)
    }

    func testAReactionButtonReactsMineIsDisabledAndTheKeysStay() async throws {
        let rig = try await rig()
        defer { rig.close() }
        var actions: [PlazaPanelHit] = []
        let own = rig.hud.onAction
        rig.hud.onAction = { id, hit in if id == .board { actions.append(hit) }; own?(id, hit) }
        let bs = try buttons(rig)
        XCTAssertEqual(bs.count, 3 * (bs.count / 3), "buttons come in threes")
        // The first row's buttons: cute (mine: disabled, still a button for VoiceOver, as SwiftUI's disabled button was), funny, cheer.
        XCTAssertEqual(bs.map { $0.accessibilityLabel() ?? "" }.prefix(3).map { $0 }, PlazaBoardRow.buttonKinds.map { L(.ko).teamReactionLabel($0) })
        XCTAssertFalse(bs[0].isAccessibilityEnabled(), "my own reaction's button is announced as dimmed")
        XCTAssertTrue(bs[1].isAccessibilityEnabled())
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
        let target = try XCTUnwrap(rig.click(atWindow: centre(bs[1])))
        XCTAssertTrue(target === rig.host(.board))
        XCTAssertEqual(actions, [PlazaPanelHit(action: "react", index: 1, target: "e0:lol")], "the first row's second button (index 1)")
        let board = try XCTUnwrap(rig.panel(.board, as: PlazaBoardPanel.self))
        let r = try XCTUnwrap(board.reaction(forHit: actions[0]))
        XCTAssertEqual(r.eventID, "e0")
        XCTAssertEqual(r.kind, PlazaBoardRow.buttonKinds[1])
        XCTAssertTrue(rig.window.firstResponder === rig.skView, "the click left the keys where they were")
        // The disabled button (the first one, cute) swallows the click and does nothing.
        let f = try XCTUnwrap(rig.frame(.board))
        let disabled = centre(bs[0])
        actions.removeAll()
        try rig.click(atWindow: disabled)
        XCTAssertEqual(actions, [PlazaPanelHit(action: "board", index: nil)], "mine: a click on the plate, no reaction")
        XCTAssertTrue(f.contains(CGPoint(x: disabled.x, y: rig.container.bounds.height - disabled.y)))
    }

    /// Where a click landed on the SwiftUI overlay (its hosting view's `hitTest`, every 4 points over the 960 x 640 window) and where
    /// the panel's host takes it. MEASURED DIFFERENCE: while the board was open the SwiftUI overlay's hosting view took a click
    /// ANYWHERE in the window (the scene got none); the panel takes only its plate and the click outside goes to the scene. The
    /// scene has no mouse handling at all (keys only; the menus and panels are views above it), so nothing a user can do changes:
    /// the click outside the plate does nothing in either case, and the board stays open (it closes by Space/Esc only).
    func testTheHostTakesEveryClickInTheWindowAsTheSwiftUIOverlayDid() async throws {
        let theFeed = feed(30)
        let rig = try PlazaWindowRig(feed: theFeed)
        defer { rig.close() }
        rig.overlays.overlayModel.content = .board
        rig.controller.scene?.isOverlayOpen = true
        await rig.flush()
        let model = PlazaOverlayModel()
        model.content = .board
        let size = rig.container.bounds.size
        let legacyWindow = ScaledWindow(scale: 2, size: size)
        let box = NSView(frame: CGRect(origin: .zero, size: size))
        legacyWindow.contentView = box
        let legacy = LegacyPlazaOverlayHostingView(rootView: LegacyPlazaOverlayView(model: model, feed: theFeed, myMemberID: "member-1"), model: model)
        legacy.frame = box.bounds
        box.addSubview(legacy)
        box.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(rig.host(.board))
        var both = 0, legacyOnly = 0, panelOnly = 0, none = 0
        var odd: [String] = []
        for x in stride(from: 0, to: Int(size.width), by: 4) {
            for y in stride(from: 0, to: Int(size.height), by: 4) {
                let p = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let l = legacy.hitTest(box.convert(p, to: legacy.superview)) != nil
                let hit = rig.container.hitTest(rig.container.convert(p, from: nil))
                // Taken by this host, or by a panel ABOVE it (the chat log, minimap, guide, toggles: they were above the SwiftUI overlay too).
                let n = hit === host || (hit is PlazaPanelHostView && hit !== rig.host(.roster))
                switch (l, n) {
                case (true, true): both += 1
                case (true, false): legacyOnly += 1; if odd.count < 6 { odd.append("legacy only \(x),\(y)") }
                case (false, true): panelOnly += 1; if odd.count < 6 { odd.append("panel only \(x),\(y)") }
                default: none += 1
                }
            }
        }
        print("BOARD CLICK both \(both) swiftuiOnly \(legacyOnly) panelOnly \(panelOnly) neither \(none) \(odd)")
        XCTAssertEqual(panelOnly, 0, "the panel never takes a click the SwiftUI overlay did not")
        XCTAssertEqual(none, 0, "the SwiftUI overlay took every click in the window")
        // The plate: 340 x 380 points = 85 x 95 samples.
        XCTAssertEqual(legacyOnly, 0, "the panel takes every click the SwiftUI overlay took: the whole window")
        XCTAssertEqual(both, 240 * 160)
        // The click that the panel lets through reaches the scene, which does nothing with it: the board stays, the keys stay.
        try rig.click(atWindow: NSPoint(x: 20, y: 20))
        XCTAssertEqual(rig.overlays.overlayModel.content, .board)
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
    }

    func testTheKeysThatClosedTheBoardStillDo() async throws {
        for (name, keyCode) in [("space", UInt16(49)), ("escape", UInt16(53))] {
            let rig = try await rig()
            defer { rig.close() }
            let scene = try XCTUnwrap(rig.controller.scene)
            XCTAssertEqual(scene.handleKeyDown(keyCode: keyCode, characters: nil, isRepeat: false), .swallowed)
            await rig.flush()
            XCTAssertEqual(rig.overlays.overlayModel.content, .none, "\(name) closes the board")
            XCTAssertNil(rig.host(.board)?.panelFrame)
        }
    }

    func testTheWheelScrollsTheListOnlyAndEachOpeningStartsAtTheTop() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let panel = try XCTUnwrap(rig.panel(.board, as: PlazaBoardPanel.self))
        let list = CGPoint(x: 170, y: 200)
        XCTAssertTrue(panel.scrollState.isAtTop)
        XCTAssertFalse(try rig.panelTakesScroll(.board, at: list, dy: 30), "at the top, further up passes on")
        try rig.scroll(.board, at: list, dy: -40)
        XCTAssertEqual(panel.scrollState.offset, 40, accuracy: 0.001, "the host gave the wheel to the panel")
        try rig.scroll(.board, at: list, dy: -1, precise: false)
        XCTAssertEqual(panel.scrollState.offset, 40 + PlazaPanelHostView.lineScrollStep, accuracy: 0.001)
        XCTAssertFalse(try rig.panelTakesScroll(.board, at: CGPoint(x: 170, y: 12), dy: -40), "over the title: passed on")
        XCTAssertFalse(try rig.panelTakesScroll(.board, at: CGPoint(x: 170, y: 600), dy: -40), "outside the plate: passed on")
        rig.overlays.overlayModel.content = .none
        await rig.flush()
        rig.overlays.overlayModel.content = .board
        await rig.flush()
        XCTAssertTrue(panel.scrollState.isAtTop, "reopening starts at the top")
    }

    func testVoiceOverReadsTheTitleAndEveryNoteAndFocusingTheLastOneScrollsToIt() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let host = try XCTUnwrap(rig.host(.board))
        let c = try children(rig)
        XCTAssertEqual(c.first?.accessibilityLabel(), L(.ko).plazaBoardTitle)
        XCTAssertEqual(c.filter { $0.areaRole }.count, 1, "the list is a scroll area")
        XCTAssertGreaterThan(c.count, 30 * 5, "every note: its text, date, buttons (and reaction lines)")
        XCTAssertTrue(c.contains { ($0.accessibilityLabel() ?? "").contains("포켓몬29") }, "the last note is reachable without scrolling by hand")
        // Focusing the last note's text scrolls the list to it.
        let panel = try XCTUnwrap(rig.panel(.board, as: PlazaBoardPanel.self))
        XCTAssertTrue(panel.scrollState.isAtTop)
        let last = try XCTUnwrap(c.last { $0.accessibilityRole() == .button })
        last.accessibilityPerformAction(PlazaPanelAccessibilityElement.scrollToVisible)
        await rig.flush()
        XCTAssertFalse(panel.scrollState.isAtTop, "the list scrolled")
        let area = try XCTUnwrap(c.first { $0.areaRole }).hostFrame
        XCTAssertTrue(area.contains(CGPoint(x: last.hostFrame.midX, y: last.hostFrame.midY)), "and the element is inside the scroll area now")
        let announced = host.accessibilityChangesForTesting
        for _ in 0..<10 { try rig.scroll(.board, at: CGPoint(x: 170, y: 200), dy: 3) }
        await rig.flush()
        XCTAssertEqual(host.accessibilityChangesForTesting, announced, "scroll steps never announce: the items do not change")
    }

    func testOpeningAndClosingNeverRelayoutsTheHostAndTheIndicatorEndsItsTimers() async throws {
        let rig = try await rig(open: false)
        defer { rig.close() }
        rig.useOverlayScrollers()
        let host = try XCTUnwrap(rig.host(.board))
        let passes = host.layoutPassesForTesting, invalidations = host.intrinsicInvalidationsForTesting
        for i in 0..<6 {
            rig.overlays.overlayModel.content = i % 2 == 0 ? .board : .none
            await rig.flush()
            XCTAssertEqual(host.frame, rig.container.bounds)
        }
        XCTAssertLessThanOrEqual(host.layoutPassesForTesting - passes, 1)
        XCTAssertEqual(host.intrinsicInvalidationsForTesting, invalidations)
        XCTAssertEqual(host.intrinsicInvalidationsInLayoutForTesting, 0)
        // Cost: one render per wheel step, none while idle once the indicator has faded, none hidden.
        rig.overlays.overlayModel.content = .board
        await rig.flush()
        let panel = try XCTUnwrap(rig.panel(.board, as: PlazaBoardPanel.self))
        let base = rig.hud.renderCounts[.board] ?? 0
        for _ in 0..<20 { _ = try rig.panelTakesScroll(.board, at: CGPoint(x: 170, y: 200), dy: -6); await rig.flush() }
        XCTAssertGreaterThanOrEqual((rig.hud.renderCounts[.board] ?? 0) - base, 20, "a render per scroll step that moved")
        XCTAssertTrue(panel.scrollIndicator.isTimerRunning)
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertFalse(panel.scrollIndicator.isTimerRunning)
        let idle = rig.hud.renderCounts[.board] ?? 0
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(rig.hud.renderCounts[.board] ?? 0, idle, "idle and visible: no renders")
    }
}
