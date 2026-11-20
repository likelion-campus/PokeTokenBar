import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Review round item 6 (finished): the legacy ("always show scroll bars") scroller as a control, through the default path (events to the view
/// AppKit's `hitTest` finds): drag the knob (proportional, captured outside the track), click in the track (page by a viewport, or jump to the
/// spot with `AppleScrollerPagingBehavior` = 1), and the content widths against the deleted SwiftUI views with the legacy style forced.
@MainActor final class PlazaLegacyScrollerControlTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() async throws { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    private func feed(_ n: Int) -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaLegacyScrollerControlTests-\(UUID())")
        dirs.append(dir)
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        let f = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "member-1", clock: { now })
        for i in (0..<n).reversed() {
            f.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)", fromSpeciesName: nil,
                               form: nil, isShiny: false, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: now.addingTimeInterval(-3600 - Double(i) * 60)))
        }
        return f
    }
    private func member() -> TeamMemberState {
        TeamMemberState(memberID: "m", nickname: "민수", character: TeamMonSummary(speciesID: 6, isShiny: false, form: nil, speciesName: "리자몽", gender: nil), inPlaza: true, tile: nil, facing: nil, isWalking: false)
    }

    /// One scrolling panel in the real window, scroller forced to "always".
    private struct Case {
        let id: PlazaPanelID
        let rig: PlazaWindowRig
        let indicator: PlazaScrollIndicator
        let state: () -> PlazaScrollState
        let viewport: CGRect   // panel points
    }

    private func make(_ id: PlazaPanelID) async throws -> Case {
        switch id {
        case .chatLog:
            let rig = try PlazaWindowRig()
            for i in 0..<50 { rig.overlays.chatLog.append(time: Date(), name: "나", text: "줄 \(i)", color: PlazaNameColor.palette[0]) }
            rig.controller.toggleChatLog()
            await rig.flush()
            let panel = try XCTUnwrap(rig.panel(.chatLog, as: PlazaChatLogPanel.self))
            panel.scrollIndicator.alwaysVisible = true
            await rig.flush()
            let l = panel.layout(scale: rig.hud.scale, text: PlatformPlaza.graphics.text)
            return Case(id: id, rig: rig, indicator: panel.scrollIndicator, state: { panel.scrollState },
                        viewport: CGRect(x: PlazaChatLogStyle.padding.width, y: l.bodyTop, width: PlazaChatLogPanel.Layout.innerWidth, height: l.bodyHeight))
        case .board:
            let rig = try PlazaWindowRig(feed: feed(30))
            rig.overlays.overlayModel.content = .board
            rig.controller.scene?.isOverlayOpen = true
            await rig.flush()
            let panel = try XCTUnwrap(rig.panel(.board, as: PlazaBoardPanel.self))
            panel.scrollIndicator.alwaysVisible = true
            await rig.flush()
            return Case(id: id, rig: rig, indicator: panel.scrollIndicator, state: { panel.scrollState }, viewport: PlazaBoardStyle.list)
        default:
            let rig = try PlazaWindowRig()
            let m = member()
            let dex = (0..<80).map { TeamDexSpecies(speciesID: 100 + $0, form: nil, name: "종\($0)", rarity: .common, hasShiny: false, hasNormal: true) }
            rig.overlays.overlayModel.content = .card(.loaded(m, TeamMemberProfile(memberID: "m", nickname: "민수", current: m.character, dex: dex)))
            rig.controller.scene?.isOverlayOpen = true
            await rig.flush()
            let panel = try XCTUnwrap(rig.panel(.card, as: PlazaCardPanel.self))
            panel.scrollIndicator.alwaysVisible = true
            await rig.flush()
            return Case(id: .card, rig: rig, indicator: panel.scrollIndicator, state: { panel.scrollState }, viewport: PlazaCardStyle.lower)
        }
    }

    /// The wheel to the top (the chat log opens at its end).
    private func toTop(_ c: Case) async throws {
        try c.rig.scroll(c.id, at: CGPoint(x: c.viewport.midX, y: c.viewport.midY), dy: 1_000_000)
        await c.rig.flush()
        XCTAssertEqual(c.state().offset, 0)
    }

    private func knob(_ c: Case) throws -> CGRect {
        try XCTUnwrap(c.indicator.thumb(state: c.state(), offset: c.state().offset, viewport: c.viewport, scale: c.rig.hud.scale))
    }
    private func windowPoint(_ c: Case, _ p: CGPoint) throws -> NSPoint { try XCTUnwrap(c.rig.windowPoint(c.id, p)) }

    func testDraggingTheKnobScrollsInProportionAndStaysCapturedOutsideTheTrack() async throws {
        for id in [PlazaPanelID.chatLog, .board, .card] {
            let c = try await make(id)
            defer { c.rig.close() }
            try await toTop(c)
            let k = try knob(c)
            let start = CGPoint(x: k.midX, y: k.midY)
            let before = c.state(), travel = c.viewport.height - k.height
            // Drag 40 points down, then well outside the track (to the left of the window's plate), release there.
            let down = try windowPoint(c, CGPoint(x: start.x, y: start.y + 40))
            let outside = try windowPoint(c, CGPoint(x: start.x - 400, y: start.y + 40))
            try c.rig.drag(from: try windowPoint(c, start), through: [down, outside], release: outside)
            await c.rig.flush()
            let moved = c.state().offset - before.offset
            XCTAssertEqual(moved, 40 / travel * before.maxOffset, accuracy: 1.5, "\(id): the knob's 40 points are 40/travel of the content's range, even with the pointer outside the track")
            XCTAssertFalse(c.indicator.isDragging, "\(id): the release ended the drag")
            // After the release the pointer's moves do nothing.
            let rest = c.state().offset
            try c.rig.drag(from: NSPoint(x: -500, y: 5), through: [NSPoint(x: -500, y: 100)])
            XCTAssertEqual(c.state().offset, rest)
        }
    }

    func testAClickInTheTrackPagesByOneViewportTowardTheClick() async throws {
        for id in [PlazaPanelID.chatLog, .board, .card] {
            let c = try await make(id)
            defer { c.rig.close() }
            c.indicator.pagingBehavior = { 0 }
            try await toTop(c)
            let track = CGPoint(x: c.viewport.maxX - PlazaScrollIndicator.legacyWidth / 2, y: 0)
            let k0 = try knob(c)
            // Below the knob (it is at the top): one viewport down.
            try c.rig.click(atWindow: try windowPoint(c, CGPoint(x: track.x, y: c.viewport.maxY - 3)))
            XCTAssertEqual(c.state().offset, min(c.viewport.height, c.state().maxOffset), accuracy: 0.5, "\(id): paged down by a viewport (knob was \(k0))")
            // Above the knob: one viewport back up.
            let k1 = try knob(c)
            try c.rig.click(atWindow: try windowPoint(c, CGPoint(x: track.x, y: max(c.viewport.minY + 1, k1.minY - 3))))
            XCTAssertEqual(c.state().offset, 0, accuracy: 0.5, "\(id): paged back up")
        }
    }

    func testTheJumpToTheSpotPreferenceMovesTheKnobToTheClick() async throws {
        for id in [PlazaPanelID.chatLog, .board, .card] {
            let c = try await make(id)
            defer { c.rig.close() }
            c.indicator.pagingBehavior = { 1 }   // AppleScrollerPagingBehavior = 1: "jump to the spot that's clicked"
            try await toTop(c)
            let k = try knob(c)
            let spot = c.viewport.minY + c.viewport.height * 0.6
            try c.rig.click(atWindow: try windowPoint(c, CGPoint(x: c.viewport.maxX - 8, y: spot)))
            let after = try knob(c)
            XCTAssertEqual(after.midY, spot, accuracy: 1.5, "\(id): the knob is centred on the click")
            XCTAssertNotEqual(after.minY, k.minY)
        }
    }

    func testTheOverlayStyleHasNoControlAndTheTrackIsOnlyForAScrollingWindow() async throws {
        let c = try await make(.chatLog)
        defer { c.rig.close() }
        c.indicator.alwaysVisible = false
        await c.rig.flush()
        let before = c.state().offset
        try c.rig.click(atWindow: try windowPoint(c, CGPoint(x: c.viewport.maxX - 8, y: c.viewport.maxY - 3)))
        XCTAssertEqual(c.state().offset, before, "overlay style: a click at the edge scrolls nothing")
    }

    /// The system's setting is read from the global preferences when the mouse goes down.
    func testThePagingBehaviourIsReadFromTheGlobalPreferences() {
        let i = PlazaScrollIndicator()
        XCTAssertEqual(i.pagingBehavior(), UserDefaults.standard.integer(forKey: "AppleScrollerPagingBehavior"))
    }

    // MARK: widths against the deleted SwiftUI views

    private func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(sub) { return s } }
        return nil
    }

    /// The board's and the card's scrolling content, in the SwiftUI views with the legacy scroller forced, and in the panels.
    func testTheBoardAndTheCardLoseWhatSwiftUIsScrollViewLost() async throws {
        let size = CGSize(width: 960, height: 640)
        var report: [String] = []
        for name in ["board", "card"] {
            let model = PlazaOverlayModel()
            let theFeed = feed(30)
            let m = member()
            let dex = (0..<80).map { TeamDexSpecies(speciesID: 100 + $0, form: nil, name: "종\($0)", rarity: .common, hasShiny: false, hasNormal: true) }
            model.content = name == "board" ? .board : .card(.loaded(m, TeamMemberProfile(memberID: "m", nickname: "민수", current: m.character, dex: dex)))
            let host = NSHostingView(rootView: LegacyPlazaOverlayView(model: model, feed: theFeed, myMemberID: "member-1"))
            let window = ScaledWindow(scale: 2, size: size)
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let sv = try XCTUnwrap(findScroll(host))
            var widths: [Bool: CGFloat] = [:]
            for legacy in [false, true] {
                sv.scrollerStyle = legacy ? .legacy : .overlay
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                widths[legacy] = sv.contentSize.width
            }
            let overlay = try XCTUnwrap(widths[false]), legacy = try XCTUnwrap(widths[true])
            report.append("LEGACY \(name): SwiftUI scroll content overlay \(overlay) legacy \(legacy)")
            // MEASURED: the board's content loses 17 (312 -> 295); the card's dex window loses 16 (352 -> 336: its scroll view's width is not a whole 17 wider).
            XCTAssertEqual(overlay - legacy, name == "board" ? PlazaScrollIndicator.legacyWidth : 16, "\(name): what the legacy scroller takes from the SwiftUI content")
            // The panel reserves the same.
            if name == "board" {
                let panel = PlazaBoardPanel(model: model, feed: theFeed, myMemberID: "member-1")
                panel.scrollIndicator.isDisabled = true
                let g = PlatformPlaza.graphics
                let plain = panel.layout(scale: 2, text: g.text).rows.first?.frame.width
                panel.scrollIndicator.alwaysVisible = true
                let narrow = panel.layout(scale: 2, text: g.text).rows.first?.frame.width
                XCTAssertEqual(try XCTUnwrap(plain), overlay, "board rows are the scroll content's width in overlay mode")
                XCTAssertEqual(try XCTUnwrap(narrow), legacy, "and the legacy content's in always mode")
                report.append("LEGACY board panel rows: overlay \(plain ?? 0) legacy \(narrow ?? 0)")
            } else {
                let panel = PlazaCardPanel(model: model, icons: PlazaStubIconSource())
                panel.scrollIndicator.isDisabled = true
                let g = PlatformPlaza.graphics
                func gridX() -> CGFloat? {
                    _ = panel.render(scale: 2, viewport: size, graphics: g)
                    return panel.dexCellOriginForTesting?.x
                }
                let plain = gridX()
                panel.scrollIndicator.alwaysVisible = true
                let narrow = gridX()
                XCTAssertEqual(try XCTUnwrap(plain) - (try XCTUnwrap(narrow)), 16.0 / 2, accuracy: 1, "the grid centres in the narrower content (SwiftUI: 8 left; the panel 8.5, half a point more)")
                report.append("LEGACY card panel grid x: overlay \(plain ?? 0) legacy \(narrow ?? 0)")
            }
        }
        report.forEach { print($0) }
    }
}
