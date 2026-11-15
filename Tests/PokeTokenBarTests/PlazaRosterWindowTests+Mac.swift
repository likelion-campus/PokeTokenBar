import AppKit
import XCTest
@testable import PokeTokenBar

/// The roster in the real plaza window (Track A Task 17w): the shared panel in `PlazaMacWindow`, the window never shown and
/// never key. It replaces `PlazaRosterPagerTests`, `PlazaRosterHoverLayoutTests` and the SwiftUI roster's hit-test tests.
@MainActor final class PlazaRosterWindowTests: XCTestCase {
    /// Held in memory so no row reaches for the disk or the network.
    private let species = 987_657

    override func setUp() async throws {
        let png = try XCTUnwrap(PlazaRosterTests.solidPNG(red: 1))
        _ = await PlazaIconLoader.icon(speciesID: species) { _ in png }
    }

    private func people(_ count: Int, presence: PlazaPresence = .idle, me: Bool = false) -> [PlazaRosterEntry] {
        (0..<count).map {
            PlazaRosterEntry(id: "m\($0)", nickname: "멤버\($0)", speciesID: species, speciesName: "피카츄", gender: nil,
                             isShiny: false, presence: presence, isMe: me && $0 == 0)
        }
    }

    private var nextPoint: CGPoint {
        let m = PlazaRosterMetrics.self
        return CGPoint(x: m.width - m.padding - m.pagerHitSize / 2, y: m.padding + m.headerHeight / 2)
    }
    private var previousPoint: CGPoint { CGPoint(x: nextPoint.x - PlazaRosterMetrics.pagerHitSize, y: nextPoint.y) }
    private func slot(_ i: Int) -> CGPoint {
        let m = PlazaRosterMetrics.self
        return CGPoint(x: m.width / 2, y: m.padding + m.headerHeight + m.listTopPadding + CGFloat(i) * (m.slotHeight + m.slotSpacing) + m.slotHeight / 2)
    }

    private func rig(_ entries: [PlazaRosterEntry], page: Int = 0) async throws -> PlazaWindowRig {
        let rig = try PlazaWindowRig()
        rig.overlays.rosterModel.entries = entries
        rig.overlays.rosterModel.page = page
        await rig.flush()
        return rig
    }

    func testTheRosterIsAtTheTopRightWhereTheHostingViewWas() async throws {
        let rig = try await rig(people(3))
        defer { rig.close() }
        let f = try XCTUnwrap(rig.frame(.roster))
        XCTAssertEqual(f.width, PlazaRosterMetrics.width)
        XCTAssertEqual(f.maxX, rig.container.bounds.width - PlazaRosterMetrics.margin, accuracy: 0.001)
        XCTAssertEqual(f.minY, PlazaRosterMetrics.margin)
        XCTAssertEqual(rig.container.subviews.firstIndex { ($0 as? PlazaPanelHostView)?.panelID == .roster }, 1, "just above the scene, below everything else")
        XCTAssertFalse(try XCTUnwrap(rig.host(.roster)).hasTrackingAreaForTesting, "no hover look: no tracking area")
    }

    func testArrowsTurnThePageAndTheSceneKeepsTheKeys() async throws {
        let rig = try await rig(people(13), page: 1)
        defer { rig.close() }
        let model = rig.overlays.rosterModel
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
        try rig.click(.roster, at: nextPoint)
        XCTAssertEqual(model.page, 2)
        await rig.flush()
        try rig.click(.roster, at: previousPoint)
        XCTAssertEqual(model.page, 1)
        XCTAssertTrue(rig.window.firstResponder === rig.skView, "the scene keeps the keys")
        // The keys stay with the chat field too: a click on an arrow does not take them from the field's editor.
        rig.shell.focusChatInput()
        await rig.flush()
        let before = rig.window.firstResponder
        XCTAssertFalse(before === rig.skView)
        try rig.click(.roster, at: nextPoint)
        XCTAssertEqual(model.page, 2)
        XCTAssertTrue(rig.window.firstResponder === before, "a panel click never moves the keys")
    }

    /// The glyph is about 7 points wide: a click near the corner of the 24-point target must still count.
    func testClickBesideTheGlyphStillTurns() async throws {
        let rig = try await rig(people(7))
        defer { rig.close() }
        try rig.click(.roster, at: CGPoint(x: nextPoint.x + 9, y: nextPoint.y + 9))
        XCTAssertEqual(rig.overlays.rosterModel.page, 1)
        XCTAssertGreaterThanOrEqual(PlazaRosterMetrics.pagerHitSize, 24, "the pointer target minimum")
    }

    /// The live arrow beside each dead one proves the click lands on the header.
    func testAnArrowIsDeadAtItsEnd() async throws {
        let rig = try await rig(people(7))
        defer { rig.close() }
        let model = rig.overlays.rosterModel
        try rig.click(.roster, at: previousPoint)
        XCTAssertEqual(model.page, 0)
        try rig.click(.roster, at: nextPoint)
        XCTAssertEqual(model.page, 1)
        await rig.flush()
        try rig.click(.roster, at: nextPoint)
        XCTAssertEqual(model.page, 1, "no page after the last")
    }

    func testArrowsAppearFromTheSeventhPerson() async throws {
        for (count, arrows) in [(6, 0), (7, 2)] {
            let rig = try await rig(people(count))
            defer { rig.close() }
            let children = try XCTUnwrap(rig.host(.roster)?.accessibilityChildren() as? [NSAccessibilityElement])
            XCTAssertEqual(children.filter { $0.accessibilityLabel() == "<" || $0.accessibilityLabel() == ">" }.count, arrows, "\(count) people")
        }
    }

    func testASlotSelectsAndMySlotAndThePlateOnlyTakeTheClick() async throws {
        var entries = people(3)
        entries[0] = PlazaRosterEntry(id: "me", nickname: "나", speciesID: species, speciesName: "피카츄", gender: nil, isShiny: false, presence: .online, isMe: true)
        let rig = try await rig(entries)
        defer { rig.close() }
        var actions: [String] = []
        let controllersOwn = rig.hud.onAction
        rig.hud.onAction = { id, hit in actions.append("\(id) \(hit.action) \(hit.index.map(String.init) ?? "")"); controllersOwn?(id, hit) }
        let host = try XCTUnwrap(rig.host(.roster))
        XCTAssertTrue(try XCTUnwrap(rig.hitView(.roster, slot(1))) === host)
        try rig.click(.roster, at: slot(1))
        try rig.click(.roster, at: slot(0))
        try rig.click(.roster, at: CGPoint(x: 100, y: 4))
        XCTAssertEqual(actions, ["roster select 1", "roster me ", "roster roster "])
        XCTAssertEqual(rig.overlays.rosterModel.page, 0)
        // Outside the plate the click goes to the scene.
        XCTAssertNil(rig.hitView(.roster, CGPoint(x: -20, y: 40)).flatMap { $0 === host ? $0 : nil })
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
    }

    func testTheWalkHintIsTheTooltipOnATeammatesSlotButNotMineOrASleepers() async throws {
        var entries = people(3)
        entries[0] = PlazaRosterEntry(id: "me", nickname: "나", speciesID: species, speciesName: "피카츄", gender: nil, isShiny: false, presence: .online, isMe: true)
        entries[2] = PlazaRosterEntry(id: "z", nickname: "잠꾸러기", speciesID: species, speciesName: "피카츄", gender: nil, isShiny: false, presence: .asleep, isMe: false)
        let rig = try await rig(entries)
        defer { rig.close() }
        let host = try XCTUnwrap(rig.host(.roster))
        let f = try XCTUnwrap(rig.frame(.roster))
        func tip(_ i: Int) -> String? { host.tooltipForTesting(at: CGPoint(x: f.minX + slot(i).x, y: f.minY + slot(i).y)) }
        XCTAssertNil(tip(0), "mine")
        XCTAssertEqual(tip(1), L(.ko).plazaRosterWalkHint)
        XCTAssertNil(tip(2), "asleep")
        XCTAssertEqual(host.tooltipCountForTesting, 1, "registered with AppKit")
    }

    func testVoiceOverReadsTheHeaderAndEverySlot() async throws {
        let rig = try await rig(people(2))
        defer { rig.close() }
        let children = try XCTUnwrap(rig.host(.roster)?.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 2 + 2)
        XCTAssertEqual(children[0].accessibilityLabel(), L(.ko).plazaRosterTitle)
        XCTAssertEqual(children[2].accessibilityRole(), .button, "a teammate's slot is a button")
        XCTAssertTrue(try XCTUnwrap(children[2].accessibilityLabel()).contains("멤버0"))
        try XCTUnwrap(children[2] as? PlazaPanelAccessibilityElement).accessibilityPerformPress()   // the same hit a click reports
    }

    /// The bounce runs only while someone is online and the plaza shows: nothing is scheduled for an idle roster, a hidden
    /// plaza stops it, and a shown one beats twice a second (one render per beat).
    func testTheBounceRunsOnlyWhileSomeoneIsOnlineAndThePlazaShows() async throws {
        let rig = try await rig(people(2, presence: .idle))
        defer { rig.close() }
        let panel = try XCTUnwrap(rig.panel(.roster, as: PlazaRosterPanel.self))
        let model = rig.overlays.rosterModel
        XCTAssertFalse(panel.animationClock.isRunning, "nobody online: no timer")
        let idleRenders = rig.hud.renderCounts[.roster] ?? 0
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(rig.hud.renderCounts[.roster] ?? 0, idleRenders, "idle and visible: no renders")
        model.entries = people(2, presence: .online)
        await rig.flush()
        XCTAssertTrue(panel.animationClock.isRunning, "someone online and the plaza shows")
        let base = rig.hud.renderCounts[.roster] ?? 0
        try await Task.sleep(for: .milliseconds(2300))
        let beats = (rig.hud.renderCounts[.roster] ?? 0) - base
        XCTAssertTrue((3...6).contains(beats), "about two renders a second, got \(beats) in 2.3 s")
        model.isAnimating = false   // the plaza is hidden (the controller's setRendering)
        rig.hud.isRendering = false
        await rig.flush()
        XCTAssertFalse(panel.animationClock.isRunning, "hidden: the clock is stopped")
        let hidden = rig.hud.renderCounts[.roster] ?? 0
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(rig.hud.renderCounts[.roster] ?? 0, hidden, "hidden: no renders")
        rig.hud.isRendering = true
    }

    func testTheCapacityFollowsTheWindowHeightAndTheHostsDoNotRelayout() async throws {
        let rig = try await rig(people(13))
        defer { rig.close() }
        let host = try XCTUnwrap(rig.host(.roster))
        let model = rig.overlays.rosterModel
        let passes = host.layoutPassesForTesting, invalidations = host.intrinsicInvalidationsForTesting
        var heights = Set<CGFloat>()
        for (i, capacity) in [2, 6, 3, 6, 2, 4].enumerated() {
            model.capacity = capacity
            model.page = i % 2
            await rig.flush()
            rig.container.layoutSubtreeIfNeeded()
            heights.insert(try XCTUnwrap(host.panelFrame).height)
            XCTAssertEqual(host.frame, rig.container.bounds, "the host keeps the window's frame")
        }
        XCTAssertGreaterThanOrEqual(heights.count, 4, "the roster really changed height")
        XCTAssertLessThanOrEqual(host.layoutPassesForTesting - passes, 2)
        XCTAssertEqual(host.intrinsicInvalidationsForTesting, invalidations)
        XCTAssertEqual(host.intrinsicInvalidationsInLayoutForTesting, 0)
    }
}
