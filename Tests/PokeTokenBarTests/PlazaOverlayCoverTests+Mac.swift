import AppKit
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 1: while the board or the card is open, the SwiftUI overlay (full window, above the roster and the scene, below
/// everything else) swallowed every click, its hover and its scroll. The panels must do the same: nothing under them (the roster, the
/// scene) acts, nothing above them (the chat log, the minimap, the guide, the toggles, the chat field) loses its clicks.
@MainActor final class PlazaOverlayCoverTests: XCTestCase {
    private var dirs: [URL] = []
    override func tearDown() async throws { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    private func feed() -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaOverlayCoverTests-\(UUID())")
        dirs.append(dir)
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        let f = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "member-1", clock: { now })
        f.insert(TeamEvent(id: "e0", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬", fromSpeciesName: nil,
                           form: nil, isShiny: false, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: now))
        return f
    }
    private func member(_ nick: String = "민수") -> TeamMemberState {
        TeamMemberState(memberID: "m-\(nick)", nickname: nick, character: TeamMonSummary(speciesID: 6, isShiny: false, form: nil, speciesName: "리자몽", gender: nil),
                        inPlaza: true, tile: nil, facing: nil, isWalking: false)
    }
    private func people(_ n: Int) -> [PlazaRosterEntry] {
        (0..<n).map { PlazaRosterEntry(id: "m\($0)", nickname: "멤버\($0)", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: .online, isMe: false) }
    }
    private func slot(_ i: Int) -> CGPoint {
        let m = PlazaRosterMetrics.self
        return CGPoint(x: m.width / 2, y: m.padding + m.headerHeight + m.listTopPadding + CGFloat(i) * (m.slotHeight + m.slotSpacing) + m.slotHeight / 2)
    }
    private var nextArrow: CGPoint {
        CGPoint(x: PlazaRosterMetrics.width - PlazaRosterMetrics.padding - PlazaRosterMetrics.pagerHitSize / 2, y: PlazaRosterMetrics.padding + PlazaRosterMetrics.headerHeight / 2)
    }

    private func open(_ rig: PlazaWindowRig, _ content: PlazaOverlayContent) async {
        rig.overlays.overlayModel.content = content
        rig.controller.scene?.isOverlayOpen = true
        await rig.flush()
    }

    func testBoardAndCardSwallowEverythingUnderThemAndLeaveWhatWasAboveClickable() async throws {
        let m = member()
        let contents: [(String, PlazaOverlayContent)] = [
            ("board", .board),
            ("card", .card(.loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: m.nickname, current: m.character, dex: [])))),
        ]
        for (name, content) in contents {
            let rig = try PlazaWindowRig(feed: feed())
            defer { rig.close() }
            rig.overlays.rosterModel.entries = people(8)
            rig.overlays.chatLog.append(time: Date(), name: "팀원", text: "안녕", color: PlazaNameColor.palette[0])
            await rig.flush()
            rig.controller.startFocus(minutes: 25)
            XCTAssertNotNil(rig.controller.focus, "a campfire focus is running")
            var actions: [String] = []
            let own = rig.hud.onAction
            rig.hud.onAction = { id, hit in actions.append("\(id) \(hit.action)"); own?(id, hit) }
            await open(rig, content)
            let overlayID: PlazaPanelID = name == "board" ? .board : .card
            let host = try XCTUnwrap(rig.host(overlayID))
            // Under the overlay: the roster's slots and arrows, the empty scene.
            for p in [slot(0), slot(3), nextArrow, CGPoint(x: 100, y: 4)] {
                let hit = try rig.click(.roster, at: p)
                XCTAssertTrue(hit === host, "\(name): the click on the roster at \(p) lands on the \(name) host, got \(String(describing: hit))")
            }
            let scenePoint = NSPoint(x: 40, y: rig.container.bounds.midY)
            XCTAssertTrue(try rig.click(atWindow: scenePoint) === host, "\(name): an empty scene point is swallowed too")
            XCTAssertEqual(actions.filter { $0.hasPrefix("roster") }, [], "\(name): no roster action")
            XCTAssertEqual(rig.overlays.rosterModel.page, 0, "\(name): no page turned")
            XCTAssertNotNil(rig.controller.focus, "\(name): the campfire focus did not end (walkToMember/standUp never ran)")
            // Hover: the roster's tooltips are not offered through the overlay.
            XCTAssertEqual(try XCTUnwrap(rig.host(.roster)).tooltipCountForTesting, 0, "\(name): no tooltips under the overlay")
            // Scroll anywhere over the overlay is swallowed (not passed up to the scene).
            let passed = host.scrollsPassedOnForTesting
            try rig.scroll(overlayID, at: CGPoint(x: -100, y: 20), dy: -30)
            XCTAssertEqual(host.scrollsPassedOnForTesting, passed, "\(name): a scroll outside the plate does not go on")
            // Above the overlay: the chat log still takes its button.
            actions.removeAll()
            let logHit = try rig.click(.chatLog, at: CGPoint(x: 360 - 22, y: 14))
            XCTAssertTrue(logHit === rig.host(.chatLog), "\(name): the chat log is above the overlay")
            XCTAssertEqual(actions, ["chatLog toggle"])
            // Closed: the roster works again, with its tooltips.
            rig.overlays.overlayModel.content = .none
            rig.controller.scene?.isOverlayOpen = false
            rig.overlays.rosterModel.entries = people(8)   // the controller refreshed the roster from its own members meanwhile
            await rig.flush()
            XCTAssertEqual(try XCTUnwrap(rig.host(.roster)).tooltipCountForTesting, 6, "tooltips are back (my own slot and sleepers have none)")
            try rig.click(.roster, at: nextArrow)
            XCTAssertEqual(rig.overlays.rosterModel.page, 1)
        }
    }
}
