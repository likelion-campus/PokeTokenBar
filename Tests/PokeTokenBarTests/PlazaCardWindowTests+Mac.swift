import AppKit
import XCTest
@testable import PokeTokenBar

/// The member card in the real plaza window (Track A Task 17w): the shared panel in `PlazaMacWindow`, the window never shown and
/// never key. Placement, dismissal by the keys, the wheel over the dex, tooltips, VoiceOver, dark appearance, cost.
@MainActor final class PlazaCardWindowTests: XCTestCase {
    private func member(_ nick: String = "민수") -> TeamMemberState {
        var m = TeamMemberState(memberID: "m-\(nick)", nickname: nick, character: TeamMonSummary(speciesID: 6, isShiny: true, form: nil, speciesName: "리자몽", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        var a = PlazaActivity(day: PlazaActivity.dayKey(Date()))
        a.addSeconds(3 * 3600 + 25 * 60); a.record(.iceBreak); a.record(.firework)
        m.activity = a
        return m
    }
    private func dex(_ n: Int) -> [TeamDexSpecies] {
        (0..<n).map { TeamDexSpecies(speciesID: 100 + $0, form: nil, name: "종\($0)", rarity: $0 % 4 == 3 ? .legendary : .common, hasShiny: $0 % 3 == 0, hasNormal: true) }
    }
    private func card(_ species: Int = 60, nick: String = "민수") -> PlazaCardState {
        let m = member(nick)
        return .loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: nick, current: m.character, dex: dex(species)))
    }

    private func rig(_ state: PlazaCardState? = nil) async throws -> PlazaWindowRig {
        let rig = try PlazaWindowRig()
        if let state { rig.overlays.overlayModel.content = .card(state); rig.controller.scene?.isOverlayOpen = true }
        await rig.flush()
        return rig
    }

    func testTheCardIsCentredAndTakesClicksOnlyOnItsPlate() async throws {
        let rig = try await rig(card())
        defer { rig.close() }
        let f = try XCTUnwrap(rig.frame(.card))
        XCTAssertEqual(f.size, PlazaCardMetrics.panelSize)
        XCTAssertEqual(f.midX, rig.container.bounds.width / 2, accuracy: 1)
        XCTAssertEqual(f.midY, rig.container.bounds.height / 2, accuracy: 1)
        let host = try XCTUnwrap(rig.host(.card))
        XCTAssertTrue(try XCTUnwrap(rig.hitView(.card, CGPoint(x: 190, y: 230))) === host)
        XCTAssertTrue(rig.hitView(.card, CGPoint(x: -30, y: 230)) !== host, "beside the plate the click goes to the scene")
        var actions: [PlazaPanelHit] = []
        let own = rig.hud.onAction
        rig.hud.onAction = { id, hit in if id == .card { actions.append(hit) }; own?(id, hit) }
        try rig.click(.card, at: CGPoint(x: 190, y: 40))
        XCTAssertEqual(actions, [PlazaPanelHit(action: "card", index: nil)], "taken, nothing happens")
        XCTAssertTrue(rig.window.firstResponder === rig.skView, "the keys stay with the scene")
        rig.overlays.overlayModel.content = .none
        await rig.flush()
        XCTAssertNil(host.panelFrame)
        XCTAssertTrue(rig.container.hitTest(NSPoint(x: rig.container.bounds.midX, y: rig.container.bounds.midY)) !== host)
    }

    /// Space and Esc close it through the scene (as before); a click outside the plate does not (as before: the card had no
    /// tap-outside area), the SwiftUI overlay having swallowed it and the panel letting the scene ignore it.
    func testSpaceAndEscapeCloseItAndAClickOutsideDoesNot() async throws {
        for (name, keyCode) in [("space", UInt16(49)), ("escape", UInt16(53))] {
            let rig = try await rig(card())
            defer { rig.close() }
            try rig.click(atWindow: NSPoint(x: 20, y: 20))
            await rig.flush()
            XCTAssertNotNil(rig.host(.card)?.panelFrame, "a click outside leaves the card open")
            XCTAssertEqual(try XCTUnwrap(rig.controller.scene).handleKeyDown(keyCode: keyCode, characters: nil, isRepeat: false), .swallowed)
            await rig.flush()
            XCTAssertEqual(rig.overlays.overlayModel.content, .none, "\(name) closes the card")
            XCTAssertNil(rig.host(.card)?.panelFrame)
        }
    }

    /// Where a click landed on the SwiftUI overlay and where the panel's host takes it (see the board's test): the same plate.
    func testClicksOutsideThePlateGoToTheSceneWhichIgnoresThem() async throws {
        let state = card()
        let rig = try await rig(state)
        defer { rig.close() }
        let model = PlazaOverlayModel()
        model.content = .card(state)
        let size = rig.container.bounds.size
        let legacyWindow = ScaledWindow(scale: 2, size: size)
        let box = NSView(frame: CGRect(origin: .zero, size: size))
        legacyWindow.contentView = box
        let legacy = LegacyPlazaOverlayHostingView(rootView: LegacyPlazaOverlayView(model: model), model: model)
        legacy.frame = box.bounds
        box.addSubview(legacy)
        box.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(rig.host(.card))
        var both = 0, legacyOnly = 0, panelOnly = 0
        for x in stride(from: 0, to: Int(size.width), by: 4) {
            for y in stride(from: 0, to: Int(size.height), by: 4) {
                let p = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let l = legacy.hitTest(box.convert(p, to: legacy.superview)) != nil
                let n = rig.container.hitTest(rig.container.convert(p, from: nil)) === host
                if l && n { both += 1 } else if l { legacyOnly += 1 } else if n { panelOnly += 1 }
            }
        }
        print("CARD CLICK both \(both) swiftuiOnly \(legacyOnly) panelOnly \(panelOnly)")
        XCTAssertEqual(panelOnly, 0)
        XCTAssertEqual(Double(both), 95 * 115, accuracy: 4 * 95 + 4 * 115, "the plate: 380 x 460 points")
        XCTAssertEqual(both + legacyOnly, 240 * 160, "the SwiftUI overlay took every click in the window")
    }

    func testTheWheelScrollsTheDexOnlyAndEachCardStartsAtTheTop() async throws {
        let rig = try await rig(card(60))
        defer { rig.close() }
        let panel = try XCTUnwrap(rig.panel(.card, as: PlazaCardPanel.self))
        let dexPoint = CGPoint(x: 190, y: 380)
        XCTAssertTrue(panel.scrollState.isAtTop)
        XCTAssertFalse(try rig.panelTakesScroll(.card, at: dexPoint, dy: 30), "at the top, further up passes on")
        try rig.scroll(.card, at: dexPoint, dy: -50)
        XCTAssertEqual(panel.scrollState.offset, 50, accuracy: 0.001)
        XCTAssertFalse(try rig.panelTakesScroll(.card, at: CGPoint(x: 190, y: 30), dy: -50), "over the header: passed on")
        XCTAssertFalse(try rig.panelTakesScroll(.card, at: CGPoint(x: 190, y: 120), dy: -50), "over the activity box: passed on")
        // Another member's card starts at the top again.
        rig.overlays.overlayModel.content = .card(card(60, nick: "지연"))
        await rig.flush()
        XCTAssertTrue(panel.scrollState.isAtTop)
    }

    func testEveryVisibleCellHasItsNameAsHoverTextAndForVoiceOver() async throws {
        let rig = try await rig(card(60))
        defer { rig.close() }
        let host = try XCTUnwrap(rig.host(.card))
        let f = try XCTUnwrap(rig.frame(.card))
        let lower = PlazaCardStyle.lower
        let first = CGPoint(x: f.minX + lower.minX + 20, y: f.minY + lower.minY + 20)
        XCTAssertEqual(host.tooltipForTesting(at: first), "종0")
        XCTAssertGreaterThan(host.tooltipCountForTesting, 5)
        let labels = (try XCTUnwrap(host.accessibilityChildren() as? [NSAccessibilityElement])).compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("종0"))
        XCTAssertFalse(labels.contains("종59"), "only the cells in view")
        let announced = host.accessibilityChangesForTesting
        for _ in 0..<10 { try rig.scroll(.card, at: CGPoint(x: 190, y: 380), dy: -3) }
        await rig.flush()
        XCTAssertLessThan(host.accessibilityChangesForTesting - announced, 10, "not one announcement per scroll step")
    }

    /// The SwiftUI card's rarity colours were adaptive system colours: the dark appearance gets the dark set and the card draws again.
    func testTheCardFollowsTheWindowsDarkAppearance() async throws {
        let rig = try await rig(card(60))
        defer { rig.close() }
        let panel = try XCTUnwrap(rig.panel(.card, as: PlazaCardPanel.self))
        XCTAssertFalse(panel.isDark)
        let before = rig.hud.renderCounts[.card] ?? 0
        rig.window.appearance = NSAppearance(named: .darkAqua)
        await rig.flush()
        XCTAssertTrue(panel.isDark, "the window's effective appearance reached the panel")
        XCTAssertGreaterThan(rig.hud.renderCounts[.card] ?? 0, before, "and it rendered again")
        XCTAssertEqual(try XCTUnwrap(rig.panel(.chatLog, as: PlazaChatLogPanel.self)).scrollIndicator.isDark, true, "so did the scroll indicators")
        rig.window.appearance = NSAppearance(named: .aqua)
        await rig.flush()
        XCTAssertFalse(panel.isDark)
    }

    func testOpeningAndClosingNeverRelayoutsTheHostAndItCostsNothingIdle() async throws {
        let rig = try await rig()
        defer { rig.close() }
        let host = try XCTUnwrap(rig.host(.card))
        let passes = host.layoutPassesForTesting, invalidations = host.intrinsicInvalidationsForTesting
        for i in 0..<6 {
            rig.overlays.overlayModel.content = i % 2 == 0 ? .card(card(i * 10 + 5)) : .none
            await rig.flush()
            XCTAssertEqual(host.frame, rig.container.bounds)
        }
        XCTAssertLessThanOrEqual(host.layoutPassesForTesting - passes, 1)
        XCTAssertEqual(host.intrinsicInvalidationsForTesting, invalidations)
        XCTAssertEqual(host.intrinsicInvalidationsInLayoutForTesting, 0)
        rig.overlays.overlayModel.content = .card(card(60))
        await rig.flush()
        let panel = try XCTUnwrap(rig.panel(.card, as: PlazaCardPanel.self))
        for _ in 0..<10 { _ = try rig.panelTakesScroll(.card, at: CGPoint(x: 190, y: 380), dy: -6); await rig.flush() }
        try await Task.sleep(for: .seconds(1.6))
        XCTAssertFalse(panel.scrollIndicator.isTimerRunning, "after the fade nothing runs")
        let idle = rig.hud.renderCounts[.card] ?? 0
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(rig.hud.renderCounts[.card] ?? 0, idle, "idle and visible: no renders")
    }
}
