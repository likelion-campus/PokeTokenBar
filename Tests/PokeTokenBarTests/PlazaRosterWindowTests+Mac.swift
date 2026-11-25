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
        // With the chat field focused, an arrow click gives the keys back to the scene (`turnRosterPage` ends in `focusScene`, as before).
        rig.shell.focusChatInput()
        await rig.flush()
        XCTAssertFalse(rig.window.firstResponder === rig.skView)
        try rig.click(.roster, at: nextPoint)
        XCTAssertEqual(model.page, 2)
        XCTAssertTrue(rig.window.firstResponder === rig.skView)
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

    /// The original pager test's three assertions, through the real window: with six people a click where the arrows would be turns nothing,
    /// and the count reaches the right edge; the seventh person brings the arrows, which push the count left, and the arrows turn.
    func testArrowsAppearFromTheSeventhPerson() async throws {
        let m = PlazaRosterMetrics.self
        var countRight: [Int: CGFloat] = [:]
        for count in [6, 7] {
            let rig = try await rig(people(count))
            defer { rig.close() }
            let elements = try XCTUnwrap(rig.host(.roster)).accessibilityElementsForTesting
            let arrows = elements.filter { $0.accessibilityLabel() == "<" || $0.accessibilityLabel() == ">" }
            XCTAssertEqual(arrows.count, count == 6 ? 0 : 2, "\(count) people")
            try rig.click(.roster, at: previousPoint)
            XCTAssertEqual(rig.overlays.rosterModel.page, 0, "\(count) people: the back arrow is dead on the first page")
            try rig.click(.roster, at: nextPoint)
            XCTAssertEqual(rig.overlays.rosterModel.page, count == 6 ? 0 : 1, "\(count) people: no turn without arrows; with them next turns")
            let countItem = try XCTUnwrap(elements.first { ($0.accessibilityLabel() ?? "").hasPrefix("접속") })
            countRight[count] = countItem.hostFrame.maxX - (rig.frame(.roster)?.minX ?? 0)
        }
        let right = m.width - m.padding
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(countRight[6]), right - 6, "the count reaches the right edge when there are no arrows")
        XCTAssertLessThan(try XCTUnwrap(countRight[7]), right - 6, "the arrows push the count left")
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
        // The timer is free-running: wait for three beats (up to 10 s) rather than counting a fixed 2.3 s, which a late timer shortens.
        // It cannot beat faster than its 0.5 s interval, so the elapsed time bounds the count from above.
        let started = ContinuousClock.now
        while (rig.hud.renderCounts[.roster] ?? 0) - base < 3, ContinuousClock.now - started < .seconds(10) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let beats = (rig.hud.renderCounts[.roster] ?? 0) - base
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(beats, 3, "it renders on every beat while someone is online")
        XCTAssertLessThanOrEqual(Double(beats), seconds / 0.5 + 1, "and no faster than two a second, got \(beats) in \(seconds) s")
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

    /// What SwiftUI's separate Texts read: the name, ♂/♀, ★, the species, the status; a dimmed arrow is announced as not enabled.
    func testSlotsReadTheirMarksAndADeadArrowIsNotEnabled() async throws {
        var entries = people(7)
        entries[0] = PlazaRosterEntry(id: "m0", nickname: "민수", speciesID: species, speciesName: "피카츄", gender: .male, isShiny: true, presence: .idle, isMe: false)
        let rig = try await rig(entries)
        defer { rig.close() }
        let elements = try XCTUnwrap(rig.host(.roster)).accessibilityElementsForTesting
        XCTAssertTrue(elements.contains { $0.accessibilityLabel() == "민수 ♂ ★, 피카츄, \(PlazaPresence.idle.badge.text)" }, "\(elements.compactMap { $0.accessibilityLabel() })")
        let previous = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "<" }), next = try XCTUnwrap(elements.first { $0.accessibilityLabel() == ">" })
        XCTAssertFalse(previous.isAccessibilityEnabled(), "page 1: the back arrow is dimmed")
        XCTAssertTrue(next.isAccessibilityEnabled())
    }
}
