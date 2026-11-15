import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// What the Mac host does for the roster, board and card panels (Track A Tasks 17c-d), and what they cost with the real CoreText:
/// tooltips reaching AppKit, accessibility frames updated in place on a scroll step, the roster's bounce against SwiftUI's, the
/// clicks the SwiftUI roster took against the panel's, and renders per second and milliseconds per render.
@MainActor final class PlazaContentPanelsMacTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    typealias Rig = ContentRig
    private let graphics = PlatformPlaza.graphics
    private func flush() async { for _ in 0..<30 { await Task.yield() } }

    override func setUp() async throws {
        Rig.blockNetwork()
        await Rig.seedIcons(Array(900_001...900_006))
        for id in 900_001...900_006 { Rig.seedSprite(id) }
    }

    private func rosterModel(_ n: Int, animating: Bool = false, capacity: Int = 6) -> PlazaRosterModel {
        let m = PlazaRosterModel()
        m.entries = PlazaRoster.sorted((0..<n).map { i in
            PlazaRosterEntry(id: "m\(i)", nickname: "친구\(i)", speciesID: 900_001 + i % 6, speciesName: "포켓몬\(i)", gender: nil, isShiny: false,
                             presence: i == 0 ? .online : (i % 3 == 2 ? .asleep : .online), isMe: i == 0)
        })
        m.capacity = capacity
        m.isAnimating = animating
        return m
    }

    // MARK: tooltips

    func testTooltipsReachTheHostAndFollowTheDrawing() async throws {
        let model = rosterModel(4)
        let panel = PlazaRosterPanel(model: model)
        let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
        await flush()
        let slots = panel.layout(scale: 2, text: graphics.text).slots
        let f = try XCTUnwrap(a.frame)
        func at(_ i: Int) -> CGPoint { CGPoint(x: f.minX + slots[i].frame.midX, y: f.minY + slots[i].frame.midY) }
        XCTAssertNil(a.host.tooltipForTesting(at: at(0)), "my own slot has none")
        XCTAssertEqual(a.host.tooltipForTesting(at: at(1)), "누르면 이 팀원에게 걸어가요")
        XCTAssertNotNil(a.host.tooltipForTesting(at: at(2)))
        XCTAssertNil(a.host.tooltipForTesting(at: at(3)), "an asleep member's slot (sorted last) has none: the walk hint is empty there")
        XCTAssertEqual(a.host.tooltipCountForTesting, 2, "the rectangles AppKit was given: the two online members")
        model.entries = Array(model.entries.prefix(1))
        await flush()
        XCTAssertEqual(a.host.tooltipCountForTesting, 0, "nobody to walk to: no tooltip left")
    }

    func testTheCardsCellTooltipsFollowTheScroll() async throws {
        let m = TeamMemberState(memberID: "m", nickname: "민수", character: TeamMonSummary(speciesID: 900_001, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let dex = (0..<60).map { TeamDexSpecies(speciesID: 900_001 + $0 % 6, form: nil, name: "포켓몬\($0)", rarity: .common, hasShiny: false, hasNormal: true) }
        let model = PlazaOverlayModel()
        model.content = .card(.loaded(m, TeamMemberProfile(memberID: "m", nickname: "", current: m.character, dex: dex)))
        let panel = PlazaCardPanel(model: model)
        panel.scrollIndicator.isDisabled = true   // these tests count renders; the indicator's fade has its own
        let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
        await flush()
        let f = try XCTUnwrap(a.frame)
        let cell = CGPoint(x: f.minX + 14 + 8 + 32, y: f.minY + 272 + 33)   // the first cell
        XCTAssertEqual(a.host.tooltipForTesting(at: cell), "포켓몬0")
        XCTAssertGreaterThanOrEqual(a.host.tooltipCountForTesting, 10)
        XCTAssertTrue(panel.scroll(dx: 0, dy: -140, at: CGPoint(x: 100, y: 300)))
        await flush()
        XCTAssertEqual(a.host.tooltipForTesting(at: cell), "포켓몬10", "two rows down: the cell under the pointer is another species")
    }

    // MARK: accessibility

    func testAScrollStepUpdatesTheAccessibilityFramesInPlaceAndAnnouncesOnlyWhenTheItemsChange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaContentPanelsMacTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("f.json"), myMemberID: "me", clock: { Date(timeIntervalSince1970: 1_793_400_000) })
        for i in (0..<30).reversed() {
            feed.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)", fromSpeciesName: nil,
                                  form: nil, isShiny: false, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: Date(timeIntervalSince1970: 1_793_400_000 - 3600 - Double(i) * 60)))
        }
        let model = PlazaOverlayModel()
        model.content = .board
        let panel = PlazaBoardPanel(model: model, feed: feed, myMemberID: "me")
        panel.scrollIndicator.isDisabled = true   // these tests count renders; the indicator's fade has its own
        let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
        await flush()
        let announced = a.host.accessibilityChangesForTesting
        let before = try XCTUnwrap(a.host.accessibilityChildren() as? [NSAccessibilityElement]).map { $0.accessibilityFrameInParentSpace() }
        XCTAssertTrue(panel.scroll(dx: 0, dy: -1, at: CGPoint(x: 100, y: 100)))
        await flush()
        XCTAssertEqual(a.host.accessibilityChangesForTesting, announced, "one point of scroll: the same items, no announcement")
        let after = try XCTUnwrap(a.host.accessibilityChildren() as? [NSAccessibilityElement]).map { $0.accessibilityFrameInParentSpace() }
        XCTAssertEqual(before.count, after.count)
        XCTAssertNotEqual(before, after, "but the frames moved with the rows")
        for _ in 0..<10 {
            XCTAssertTrue(panel.scroll(dx: 0, dy: -37, at: CGPoint(x: 100, y: 100)))
            await flush()
        }
        XCTAssertGreaterThan(a.host.accessibilityChangesForTesting, announced, "other rows came into view: one announcement per change of the items")
        XCTAssertLessThan(a.host.accessibilityChangesForTesting - announced, 10, "not one per scroll step")
    }

    // MARK: the roster's bounce

    /// SwiftUI's icon rises 2 points on the second half-second; the panel's on its first beat: the same distance, in the same direction.
    func testTheBounceMovesTheIconAsSwiftUIDid() async throws {
        func iconTop(_ image: CGImage, scale: CGFloat) -> Int {
            let px = K.rgba(image), w = image.width
            // The sample icon's dark outline row (30 scale 2: rows of 0.1 grey) inside the first slot; scan the icon's column.
            let x = Int((960 - 14 - 232 + 10 + 6 + 20) * scale)
            for y in Int(55 * scale)..<Int(140 * scale) {
                let i = (y * w + x) * 4
                if px[i] < 110 && px[i + 1] < 110 && px[i + 2] < 110 && px[i + 3] > 200 { return y }
            }
            return -1
        }
        for scale in [CGFloat(1), 2] {
            let view = LegacyPlazaRosterView(model: rosterModel(2, animating: true))
            let b = Rig.Before(view, viewport: CGSize(width: 960, height: 640), scale: scale)
            await Rig.settle(250)
            let down = iconTop(try b.placed(at: CGPoint(x: 960 - 14 - 232, y: 14)), scale: scale)
            await Rig.settle(500)
            let up = iconTop(try b.placed(at: CGPoint(x: 960 - 14 - 232, y: 14)), scale: scale)
            let model = rosterModel(2, animating: true)
            let beat = ManualBeat()
            let panel = PlazaRosterPanel(model: model, clock: PlazaAnimationClock(interval: 0.5, schedule: { beat.schedule($0, $1) }))
            let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: scale)
            await flush()
            let pDown = iconTop(try a.image(CGSize(width: 960, height: 640), scale: scale), scale: scale)
            beat.beat()
            await flush()
            let pUp = iconTop(try a.image(CGSize(width: 960, height: 640), scale: scale), scale: scale)
            print("BOUNCE \(scale)x swiftui down \(down) up \(up) panel down \(pDown) up \(pUp)")
            XCTAssertEqual(down - up, Int(2 * scale), "SwiftUI rises 2 points")
            XCTAssertEqual(pDown - pUp, Int(2 * scale), "so does the panel")
        }
    }

    // MARK: clicks

    /// Where a click lands on the SwiftUI roster (its hosting view's `hitTest`, every 2 points over it and 12 around it) and on
    /// the panel. Prints the mismatches.
    func testClicksLandWhereTheyDidOnTheSwiftUIRoster() async throws {
        let model = rosterModel(4)
        let host = LegacyPlazaRosterHostingView(rootView: LegacyPlazaRosterView(model: model))
        let viewport = CGSize(width: 960, height: 640)
        let window = ScaledWindow(scale: 2, size: viewport)
        let container = NSView(frame: CGRect(origin: .zero, size: viewport))
        window.contentView = container
        container.addSubview(host)
        let size = host.fittingSize
        host.frame = CGRect(x: viewport.width - 14 - size.width, y: viewport.height - 14 - size.height, width: size.width, height: size.height)
        container.layoutSubtreeIfNeeded()
        await Rig.settle()
        let panel = PlazaRosterPanel(model: rosterModel(4))
        let a = Rig.After(panel, viewport: viewport, scale: 2)
        await flush()
        let f = try XCTUnwrap(a.frame)
        var both = 0, swiftOnly = 0, panelOnly = 0
        var sample: [String] = []
        for y in stride(from: f.minY - 12, to: f.maxY + 12, by: 2) {
            for x in stride(from: f.minX - 12, to: f.maxX + 12, by: 2) {
                let sw = host.hitTest(NSPoint(x: x, y: viewport.height - y)) != nil
                let pn = a.hud.hit(at: CGPoint(x: x, y: y), in: .roster) != nil
                if sw && pn { both += 1 } else if sw { swiftOnly += 1; if sample.count < 6 { sample.append("sw(\(x - f.minX),\(y - f.minY))") } }
                else if pn { panelOnly += 1; if sample.count < 6 { sample.append("pn(\(x - f.minX),\(y - f.minY))") } }
            }
        }
        print("CLICK roster both \(both) swiftuiOnly \(swiftOnly) panelOnly \(panelOnly) \(sample)")
        XCTAssertEqual(f.size, size)
    }

    // MARK: SwiftUI's text shadow

    /// Where SwiftUI puts `.shadow(color: black, radius: 0, x: 1, y: 1)` under a white bar of text, in a hosting view and in
    /// `ImageRenderer`, at 1x and 2x: the dark pixels' offset from the white ink's, in device pixels.
    func testWhereSwiftUIPutsTheTextShadow() async throws {
        let view = Text("ㅡ").font(Font(PlazaResources.font(.body))).foregroundStyle(.white)
            .shadow(color: .black, radius: 0, x: 1, y: 1).padding(6).background(Color(red: 0.5, green: 0.5, blue: 0.5))
        func offset(_ image: CGImage) -> String {
            let px = K.rgba(image), w = image.width
            var white: [(Int, Int)] = [], dark: [(Int, Int)] = []
            for y in 0..<image.height { for x in 0..<w {
                let i = (y * w + x) * 4
                if px[i] > 240 { white.append((x, y)) } else if px[i] < 40 { dark.append((x, y)) }
            } }
            guard !white.isEmpty, !dark.isEmpty else { return "white \(white.count) dark \(dark.count)" }
            let wy = white.map(\.1), wx = white.map(\.0), dy = dark.map(\.1), dx = dark.map(\.0)
            return "white x \(wx.min()!)...\(wx.max()!) y \(wy.min()!)...\(wy.max()!); dark x \(dx.min()!)...\(dx.max()!) y \(dy.min()!)...\(dy.max()!)"
        }
        for scale in [CGFloat(1), 2] {
            let direct = try XCTUnwrap(K.render(view, scale: scale))
            let b = Rig.Before(view, viewport: CGSize(width: 60, height: 40), scale: scale)
            print("SHADOW \(Int(scale))x imageRenderer: \(offset(direct))")
            print("SHADOW \(Int(scale))x hosted:        \(offset(try b.capture()))")
        }
    }

    // MARK: cost

    /// Renders per second and what a render costs (debug build, real CoreText, real timer).
    func testRosterRenderCountsAndCosts() async throws {
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        // Animating: the real timer, one second and a bit.
        do {
            let model = rosterModel(6, animating: true)
            let panel = PlazaRosterPanel(model: model)
            let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
            await flush()
            let base = a.hud.renderCounts[.roster] ?? 0
            try await Task.sleep(for: .milliseconds(2250))
            let renders = (a.hud.renderCounts[.roster] ?? 0) - base
            print("COST roster animating 2.25 s: \(renders) renders = \(Double(renders) / 2.25) per second")
            XCTAssertEqual(renders, 4, "a beat every half second")
            // One render's cost: the beat's render (text laid out already).
            let t0 = clock.now
            for _ in 0..<20 { _ = panel.render(scale: 2, viewport: CGSize(width: 960, height: 640), graphics: graphics) }
            print("COST roster render (6 slots, 2x, warm): \(String(format: "%.2f", ms(t0.duration(to: clock.now)) / 20)) ms")
            // Stop: the plaza hides.
            model.isAnimating = false
            await flush()
            let stopped = a.hud.renderCounts[.roster] ?? 0
            try await Task.sleep(for: .milliseconds(1300))
            XCTAssertEqual(a.hud.renderCounts[.roster] ?? 0, stopped, "hidden: no render")
            XCTAssertFalse(panel.isAnimating)
            print("COST roster hidden 1.3 s: 0 renders, clock stopped")
        }
        // Idle visible with nothing to animate.
        do {
            let model = rosterModel(3, animating: true)
            model.entries = model.entries.map { e in
                PlazaRosterEntry(id: e.id, nickname: e.nickname, speciesID: e.speciesID, speciesName: e.speciesName, gender: e.gender, isShiny: e.isShiny, presence: .idle, isMe: e.isMe)
            }
            let panel = PlazaRosterPanel(model: model)
            let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
            await flush()
            let base = a.hud.renderCounts[.roster] ?? 0
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(a.hud.renderCounts[.roster] ?? 0, base)
            print("COST roster idle visible (nobody online) 1.2 s: 0 renders")
        }
        // A typical change: a member joins (layout + draw), a page turn, cold open.
        do {
            let model = rosterModel(5)
            let panel = PlazaRosterPanel(model: model)
            let t0 = clock.now
            let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
            print("COST roster cold open (5 slots, attach and first render): \(String(format: "%.1f", ms(t0.duration(to: clock.now)))) ms")
            await flush()
            let base = a.hud.renderCounts[.roster] ?? 0
            let t1 = clock.now
            model.entries = PlazaRoster.sorted(model.entries + [PlazaRosterEntry(id: "new", nickname: "새친구", speciesID: 900_001, speciesName: "새", gender: nil, isShiny: false, presence: .online, isMe: false)])
            await flush()
            XCTAssertEqual((a.hud.renderCounts[.roster] ?? 0) - base, 1)
            print("COST roster a member joins: 1 render, \(String(format: "%.1f", ms(t1.duration(to: clock.now)))) ms incl. 30 yields")
        }
    }

    func testBoardAndCardRenderCountsAndCosts() async throws {
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        // Board.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaContentPanelsMacTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("f.json"), myMemberID: "me", clock: { Date(timeIntervalSince1970: 1_793_400_000) })
        for i in (0..<60).reversed() {
            feed.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)", fromSpeciesName: nil,
                                  form: nil, isShiny: i % 5 == 0, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: Date(timeIntervalSince1970: 1_793_400_000 - 3600 - Double(i) * 60)))
        }
        let model = PlazaOverlayModel()
        model.content = .board
        let t0 = clock.now
        let panel = PlazaBoardPanel(model: model, feed: feed, myMemberID: "me")
        panel.scrollIndicator.isDisabled = true   // these tests count renders; the indicator's fade has its own
        let a = Rig.After(panel, viewport: CGSize(width: 960, height: 640), scale: 2)
        print("COST board cold open (60 events: wrap all, draw the rows in view, host): \(String(format: "%.1f", ms(t0.duration(to: clock.now)))) ms")
        await flush()
        let base = a.hud.renderCounts[.board] ?? 0
        var worst = 0.0, total = 0.0, consumed = 0
        let t1 = clock.now
        for i in 0..<120 {
            let s = clock.now
            if a.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: i < 100 ? -4 : 4), location: CGPoint(x: (960 - 340) / 2 + 100, y: 130 + 120)), in: .board) { consumed += 1 }
            for _ in 0..<6 { await Task.yield() }
            let d = ms(s.duration(to: clock.now)); total += d; worst = max(worst, d)
        }
        _ = t1
        let renders = (a.hud.renderCounts[.board] ?? 0) - base
        print("COST board wheel 1 s: 120 events, \(consumed) consumed, \(renders) renders, \(String(format: "%.2f", total / Double(max(renders, 1)))) ms each, worst \(String(format: "%.2f", worst)) ms")
        XCTAssertEqual(renders, consumed)
        let idle = a.hud.renderCounts[.board] ?? 0
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(a.hud.renderCounts[.board] ?? 0, idle)
        a.hud.isRendering = false
        model.content = .none; model.content = .board
        await flush()
        XCTAssertEqual(a.hud.renderCounts[.board] ?? 0, idle, "hidden: none")
        print("COST board idle visible 1.1 s: 0 renders; hidden: 0 renders")

        // Card.
        let m = TeamMemberState(memberID: "m", nickname: "민수", character: TeamMonSummary(speciesID: 900_001, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let dex = (0..<120).map { TeamDexSpecies(speciesID: 900_001 + $0 % 6, form: nil, name: "포켓몬\($0)", rarity: $0 % 9 == 0 ? .legendary : .common, hasShiny: $0 % 4 == 0, hasNormal: true) }
        let cardModel = PlazaOverlayModel()
        cardModel.content = .card(.loaded(m, TeamMemberProfile(memberID: "m", nickname: "", current: m.character, dex: dex)))
        let c0 = clock.now
        let card = PlazaCardPanel(model: cardModel)
        card.scrollIndicator.isDisabled = true   // these tests count renders; the indicator's fade has its own
        let b = Rig.After(card, viewport: CGSize(width: 960, height: 640), scale: 2)
        print("COST card cold open (120 species: header, activity, the rows in view, host): \(String(format: "%.1f", ms(c0.duration(to: clock.now)))) ms")
        await flush()
        let cbase = b.hud.renderCounts[.card] ?? 0
        var cworst = 0.0, ctotal = 0.0, cconsumed = 0
        for i in 0..<120 {
            let s = clock.now
            if b.hud.handleMouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: i < 100 ? -4 : 4), location: CGPoint(x: (960 - 380) / 2 + 100, y: 90 + 300)), in: .card) { cconsumed += 1 }
            for _ in 0..<6 { await Task.yield() }
            let d = ms(s.duration(to: clock.now)); ctotal += d; cworst = max(cworst, d)
        }
        let crenders = (b.hud.renderCounts[.card] ?? 0) - cbase
        print("COST card wheel 1 s: 120 events, \(cconsumed) consumed, \(crenders) renders, \(String(format: "%.2f", ctotal / Double(max(crenders, 1)))) ms each, worst \(String(format: "%.2f", cworst)) ms")
        XCTAssertEqual(crenders, cconsumed)
        let cidle = b.hud.renderCounts[.card] ?? 0
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(b.hud.renderCounts[.card] ?? 0, cidle)
        print("COST card idle visible 1.1 s: 0 renders")
    }
}
