#if os(Windows)
import CPlazaD2D
import WinSDK
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 10: the HUD's panels in the Windows window. The virtual hosts (`WinPlazaPanels`) route like the Mac's per-panel
/// views, driven here with fake panels over the real `PlazaHUD`; the tooltip control on a plain window; the eye glyphs.
@MainActor final class WindowsPlazaPanelsTests: XCTestCase {
    // MARK: fixtures

    /// A panel of one colour layer with one hit rectangle (panel points) and, optionally, a scroll and tooltips.
    @MainActor final class Fake: PlazaPanel {
        let id: PlazaPanelID
        let anchor: PlazaPanelAnchor
        let offset: CGPoint
        let panelSize: CGSize
        let hitRect: CGRect?
        var isVisible = true
        var onChange: (() -> Void)?
        var interaction = PlazaPanelInteraction()
        var canScroll = false
        var tracks = false
        var tips: [PlazaTooltip] = []
        private(set) var renders = 0

        init(_ id: PlazaPanelID, anchor: PlazaPanelAnchor = .topLeading, offset: CGPoint = .zero, size: CGSize, hit: CGRect?) {
            self.id = id
            self.anchor = anchor
            self.offset = offset
            panelSize = size
            hitRect = hit
        }

        func size(in viewport: CGSize, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { panelSize }

        func render(scale: CGFloat, viewport: CGSize, graphics: any PlazaGraphics) -> PlazaPanelDrawing {
            renders += 1
            return PlazaPanelDrawing(layers: [.color(PlazaColor(hex: 0x336699), frame: CGRect(origin: .zero, size: panelSize))],
                                     tracksMouse: tracks, tooltips: tips)
        }

        func hit(_ point: CGPoint) -> PlazaPanelHit? {
            guard let r = hitRect, r.contains(point) else { return nil }
            return PlazaPanelHit(action: String(describing: id), index: nil)
        }

        func scroll(dx: CGFloat, dy: CGFloat, at point: CGPoint) -> Bool { canScroll }
    }

    @MainActor final class Rig {
        let hud: PlazaHUD
        let panels: WinPlazaPanels
        let fakes: [PlazaPanelID: Fake]
        var actions: [String] = []

        init(_ list: [Fake], viewport: CGSize = CGSize(width: 800, height: 600), scale: CGFloat = 1) {
            let h = PlazaHUD(panels: list)
            hud = h
            panels = WinPlazaPanels(hud: h)
            fakes = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            hud.onAction = { [unowned self] id, _ in actions.append(String(describing: id)) }
            panels.report(size: viewport, scale: scale)
            panels.attach()
        }

        /// A press and a release at `point`; the actions it caused.
        func click(_ point: CGPoint) -> [String] {
            let before = actions.count
            panels.mouse(PlazaMouseEvent(kind: .down, location: point))
            panels.mouse(PlazaMouseEvent(kind: .up, location: point))
            return Array(actions[before...])
        }
    }

    /// The Mac's window in miniature: a roster at the left, a board in the middle, a toggle at the top right, a chat log at the
    /// bottom left. 800x600 points.
    private func standardRig(scale: CGFloat = 1) -> Rig {
        let roster = Fake(.roster, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 200, height: 300), hit: CGRect(x: 0, y: 0, width: 200, height: 300))
        roster.tips = [PlazaTooltip(frame: CGRect(x: 0, y: 0, width: 200, height: 44), text: "walk there")]
        let board = Fake(.board, anchor: .center, size: CGSize(width: 300, height: 200), hit: CGRect(x: 0, y: 0, width: 300, height: 200))
        board.canScroll = true
        let toggle = Fake(.backgroundToggle, anchor: .topTrailing, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 80, height: 30),
                          hit: CGRect(x: 0, y: 0, width: 80, height: 30))
        let chat = Fake(.chatLog, anchor: .bottomLeading, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 300, height: 100),
                        hit: CGRect(x: 0, y: 0, width: 300, height: 20))
        chat.canScroll = true
        let pills = Fake(.pills, anchor: .topCenter, offset: CGPoint(x: 0, y: 5), size: CGSize(width: 100, height: 30), hit: nil)
        return Rig([roster, board, pills, chat, toggle], scale: scale)
    }

    // MARK: z list

    func testZListIsTheMacsSubviewOrder() async {
        XCTAssertEqual(WinPlazaPanels.zOrder, [.roster, .drawBoard, .board, .card, .photoFrame, .menu, .gameTitle, .gameCard, .pills, .chatLog, .minimap, .clock,
                                               .shortcuts, .backgroundToggle, .nameColorPicker, .berryTable])
        // the controller's own HUD list (what the Mac window's stack follows) is the same order
        let c = controller(feed: true)
        XCTAssertEqual(c.hud.panels.map(\.id), WinPlazaPanels.zOrder)
        // drawn bottom first
        let rig = standardRig()
        XCTAssertEqual(rig.panels.drawList.count, 5)
        let ids = WinPlazaPanels.zOrder.filter { rig.fakes[$0] != nil }
        XCTAssertEqual(ids, [.roster, .board, .pills, .chatLog, .backgroundToggle])
    }

    // MARK: the controller's content panels

    private func controller(feed: Bool) -> PlazaWindowController {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.panels.\(UUID())"))
        var store: TeamFeedStore?
        if feed {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WinPanels-\(UUID())")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me")
        }
        return PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: PlazaStubSpriteFetcher(log: { _ in })),
                                     nickname: { "me" }, memberID: { "me" }, subject: { .init(speciesID: 25, isShiny: false) },
                                     feed: store, shell: PlazaHeadlessShell(), chatInput: PlazaStubChatInput())
    }

    func testTheShellBuildsTheContentPanelsFromTheBindings() async {
        let with = controller(feed: true)
        let ids = Set(with.overlayBindings.hud.panels.map(\.id))
        XCTAssertTrue(Set<PlazaPanelID>([.roster, .board, .card, .chatLog]).isSubset(of: ids))
        XCTAssertEqual(ids, Set(WinPlazaPanels.zOrder))
        let without = Set(controller(feed: false).overlayBindings.hud.panels.map(\.id))
        XCTAssertFalse(without.contains(.board), "no feed, no board")
        XCTAssertTrue(Set<PlazaPanelID>([.roster, .card, .chatLog]).isSubset(of: without))
        // attached to a viewport, the host shows what the HUD renders, in z order and nothing else
        let hud = with.overlayBindings.hud
        let panels = WinPlazaPanels(hud: hud)
        panels.report(size: CGSize(width: 960, height: 640), scale: 1)
        panels.attach()
        XCTAssertFalse(panels.entries.isEmpty)
        XCTAssertTrue(Set(panels.entries.keys).isSubset(of: ids))
        XCTAssertTrue(panels.entries.keys.contains(.backgroundToggle))
        panels.detach()
    }

    func testContentActionsCallTheBindings() async {
        let c = controller(feed: true)
        let hud = c.overlayBindings.hud
        let model = c.overlayBindings.rosterModel
        model.capacity = 2
        model.entries = (0..<5).map {
            PlazaRosterEntry(id: "m\($0)", nickname: "n\($0)", speciesID: 25, speciesName: "Pikachu", gender: nil, isShiny: false,
                             presence: .online, isMe: $0 == 0)
        }
        XCTAssertEqual(model.page, 0)
        hud.onAction?(.roster, PlazaPanelHit(action: "next", index: nil))
        XCTAssertEqual(model.page, 1)
        hud.onAction?(.roster, PlazaPanelHit(action: "previous", index: nil))
        XCTAssertEqual(model.page, 0)
        hud.onAction?(.chatLog, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertTrue(c.isChatLogExpanded)
        // inert hits: taken and do nothing
        hud.onAction?(.chatLog, PlazaPanelHit(action: "log", index: nil))
        hud.onAction?(.board, PlazaPanelHit(action: "board", index: nil))
        hud.onAction?(.board, PlazaPanelHit(action: "react", index: 99))
        hud.onAction?(.roster, PlazaPanelHit(action: "select", index: 99))
        hud.onAction?(.menu, PlazaPanelHit(action: "choose", index: 0))   // no menu open
        XCTAssertTrue(c.isChatLogExpanded)
        XCTAssertEqual(model.page, 0)
        // a click through the virtual hosts reaches the same closure
        let rig = standardRig()
        XCTAssertEqual(rig.click(CGPoint(x: 760, y: 20)), ["backgroundToggle"])
        let alone = Rig([Fake(.roster, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 200, height: 300), hit: CGRect(x: 0, y: 0, width: 200, height: 300))])
        XCTAssertEqual(alone.click(CGPoint(x: 100, y: 100)), ["roster"])
    }

    // MARK: routing

    func testClicksGoToTheTopMostPanelWithAHit() async {
        let low = Fake(.roster, offset: CGPoint(x: 100, y: 100), size: CGSize(width: 200, height: 200), hit: CGRect(x: 0, y: 0, width: 200, height: 200))
        // above, overlapping the lower panel's right half; only its top strip has a hit
        let high = Fake(.chatLog, offset: CGPoint(x: 200, y: 100), size: CGSize(width: 200, height: 200), hit: CGRect(x: 0, y: 0, width: 200, height: 40))
        let rig = Rig([low, high])
        XCTAssertEqual(rig.click(CGPoint(x: 250, y: 110)), ["chatLog"], "both have a hit: the upper")
        XCTAssertEqual(rig.click(CGPoint(x: 250, y: 200)), ["roster"], "the upper panel is there but has no hit: the lower takes it")
        XCTAssertEqual(rig.click(CGPoint(x: 120, y: 120)), ["roster"])
        XCTAssertEqual(rig.click(CGPoint(x: 600, y: 500)), [], "nothing: the scene, which takes no mouse")
        XCTAssertNil(rig.panels.captured)
    }

    func testTheOpenBoardCoversTheWholeWindow() async {
        let rig = standardRig()
        // the board is open (shown): every click lands on it, the roster under it takes none; the toggle above it still does
        XCTAssertEqual(rig.panels.host(at: CGPoint(x: 400, y: 300)), .board)   // on the plate, not on its hit
        XCTAssertEqual(rig.click(CGPoint(x: 100, y: 100)), [], "the roster under the cover is not clickable")
        XCTAssertEqual(rig.panels.host(at: CGPoint(x: 100, y: 100)), .board)
        XCTAssertEqual(rig.panels.host(at: CGPoint(x: 5, y: 590)), .board)
        XCTAssertEqual(rig.click(CGPoint(x: 760, y: 20)), ["backgroundToggle"], "panels above the cover stay clickable")
        XCTAssertEqual(rig.click(CGPoint(x: 20, y: 500)), ["chatLog"])
        XCTAssertTrue(rig.panels.isCovered(.roster))
        XCTAssertFalse(rig.panels.isCovered(.chatLog))
        // the roster's tooltip is suspended under the cover
        XCTAssertTrue(rig.panels.tips.isEmpty)
    }

    func testHUDHiddenHidesTheMacsSet() async {
        var list: [Fake] = []
        for (i, id) in WinPlazaPanels.zOrder.enumerated() {
            list.append(Fake(id, offset: CGPoint(x: CGFloat(i) * 60, y: 10), size: CGSize(width: 50, height: 50), hit: CGRect(x: 0, y: 0, width: 50, height: 50)))
        }
        let rig = Rig(list, viewport: CGSize(width: 900, height: 200))
        XCTAssertEqual(rig.panels.drawList.count, 15)
        rig.panels.setHidden(PlazaPanelID.hiddenInPhotoMode)
        let shown = Set(WinPlazaPanels.zOrder).subtracting(WinPlazaPanels.hiddenInPhotoMode)
        XCTAssertEqual(shown, [.board, .card, .photoFrame, .menu, .gameTitle, .gameCard, .pills, .berryTable])
        XCTAssertEqual(rig.panels.drawList.count, shown.count)
        for (i, id) in WinPlazaPanels.zOrder.enumerated() {
            let p = CGPoint(x: CGFloat(i) * 60 + 25, y: 30)
            let takes = rig.panels.host(at: p)
            if WinPlazaPanels.hiddenInPhotoMode.contains(id) {
                XCTAssertNotEqual(takes, id, "\(id) is hidden and takes nothing")
            }
        }
        rig.panels.setHidden([])
        XCTAssertEqual(rig.panels.drawList.count, 15)
    }

    func testASuppressedPanelLeavesTheDrawList() async {
        // a pills fake that takes clicks, alone at the top centre (350...450 x, 5...35 y)
        let pills = Fake(.pills, anchor: .topCenter, offset: CGPoint(x: 0, y: 5), size: CGSize(width: 100, height: 30),
                         hit: CGRect(x: 0, y: 0, width: 100, height: 30))
        let roster = Fake(.roster, offset: CGPoint(x: 10, y: 100), size: CGSize(width: 100, height: 100), hit: CGRect(x: 0, y: 0, width: 100, height: 100))
        let rig = Rig([roster, pills])
        let spot = CGPoint(x: 400, y: 20)
        let before = rig.panels.drawList
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(rig.panels.host(at: spot), .pills)
        rig.hud.suppressed = [.pills]
        XCTAssertEqual(rig.panels.drawList.count, 1)
        XCTAssertNil(rig.panels.host(at: spot), "the pills' spot takes nothing while suppressed")
        rig.hud.suppressed = []
        XCTAssertEqual(rig.panels.drawList, before)
        XCTAssertEqual(rig.panels.host(at: spot), .pills)
    }

    func testPressDimsAndReleaseOutsideCancels() async {
        let rig = standardRig()
        let toggle = rig.fakes[.backgroundToggle]!
        let on = CGPoint(x: 760, y: 20), off = CGPoint(x: 100, y: 550)
        rig.panels.mouse(PlazaMouseEvent(kind: .down, location: on))
        XCTAssertNotNil(toggle.interaction.pressed, "the press look")
        XCTAssertEqual(rig.panels.captured, .backgroundToggle)
        rig.panels.mouse(PlazaMouseEvent(kind: .moved, location: off))   // dragged away: still the same host
        rig.panels.mouse(PlazaMouseEvent(kind: .up, location: off))
        XCTAssertNil(toggle.interaction.pressed, "released: the look is gone")
        XCTAssertEqual(rig.actions, [], "released outside: no action")
        XCTAssertNil(rig.panels.captured)
        // a lost capture arrives as an up nowhere: also cancelled
        rig.panels.mouse(PlazaMouseEvent(kind: .down, location: on))
        rig.panels.mouse(PlazaMouseEvent(kind: .up, location: WinPlazaInputRouter.nowhere))
        XCTAssertEqual(rig.actions, [])
        XCTAssertEqual(rig.click(on), ["backgroundToggle"])
    }

    func testHoverFollowsOnlyTrackingDrawings() async {
        let a = Fake(.roster, offset: CGPoint(x: 10, y: 10), size: CGSize(width: 100, height: 100), hit: CGRect(x: 0, y: 0, width: 100, height: 100))
        a.tracks = true
        let rig = Rig([a])
        XCTAssertTrue(rig.panels.tracks(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(rig.panels.tracks(CGPoint(x: 500, y: 500)))
        rig.panels.mouse(PlazaMouseEvent(kind: .moved, location: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(a.interaction.hovered?.action, "roster")
        rig.panels.mouse(PlazaMouseEvent(kind: .exited, location: CGPoint(x: 500, y: 500)))
        XCTAssertNil(a.interaction.hovered)
    }

    func testWheelGoesToTheHostUnderTheMouseAndPassesOnAtTheEnds() async {
        let rig = standardRig()
        // over the open board's plate: taken while it scrolls, and still swallowed (not passed on) when it cannot
        let board = rig.fakes[.board]!
        XCTAssertTrue(rig.panels.mouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 30), location: CGPoint(x: 400, y: 300))))
        board.canScroll = false
        XCTAssertTrue(rig.panels.mouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 30), location: CGPoint(x: 400, y: 300))), "the cover swallows it")
        XCTAssertEqual(rig.panels.counts.swallowed, 1)
        // over the chat log (above the cover): taken while it scrolls, passed on at its end
        let chat = rig.fakes[.chatLog]!
        XCTAssertTrue(rig.panels.mouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 30), location: CGPoint(x: 20, y: 500))))
        chat.canScroll = false
        XCTAssertFalse(rig.panels.mouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 30), location: CGPoint(x: 20, y: 500))))
        XCTAssertEqual(rig.panels.counts.scrollsPassedOn, 1)
        // over nothing but the cover: swallowed, the scene gets none
        XCTAssertTrue(rig.panels.mouse(PlazaMouseEvent(kind: .scroll(dx: 0, dy: 30), location: CGPoint(x: 600, y: 580))))
        XCTAssertEqual(rig.panels.counts.swallowed, 2)
    }

    // MARK: tooltips

    func testTooltipsFollowDrawings() async throws {
        let rig = Rig([Fake(.roster, offset: CGPoint(x: 10, y: 20), size: CGSize(width: 200, height: 100), hit: nil)])
        rig.fakes[.roster]!.tips = [PlazaTooltip(frame: CGRect(x: 5, y: 6, width: 100, height: 44), text: "첫째"),
                                    PlazaTooltip(frame: CGRect(x: 5, y: 50, width: 100, height: 44), text: "둘째"),
                                    PlazaTooltip(frame: CGRect(x: 0, y: 0, width: 5, height: 5), text: "")]
        rig.hud.setNeedsRender(.roster)
        try await Task.sleep(for: .milliseconds(50))
        // the panel's tips in window points; the empty text is dropped
        XCTAssertEqual(rig.panels.tips, [.init(frame: CGRect(x: 15, y: 26, width: 100, height: 44), text: "첫째"),
                                         .init(frame: CGRect(x: 15, y: 70, width: 100, height: 44), text: "둘째")])
        let owner = try WinSinkWindow(className: "PTBTestTooltipOwner", title: "owner", style: DWORD(WS_OVERLAPPED), exStyle: 0,
                                      x: 0, y: 0, width: 300, height: 300)
        defer { owner.destroy() }
        let control = WinPlazaTooltips(owner: owner.hwnd)
        defer { control.destroy() }
        XCTAssertTrue(control.isAvailable)
        let tips = rig.panels.tips.map { WinPlazaTooltips.Tip(rect: [Int32($0.frame.minX), Int32($0.frame.minY), Int32($0.frame.maxX), Int32($0.frame.maxY)], text: $0.text) }
        control.set(tips)
        XCTAssertEqual(control.count, 2)
        XCTAssertEqual(control.text(of: 0), "첫째", "TTM_GETTEXT")
        XCTAssertEqual(control.text(of: 1), "둘째")
        XCTAssertEqual(control.rebuilds, 1)
        control.set(tips)   // the same list: the control is left alone
        XCTAssertEqual(control.rebuilds, 1)
        control.set([tips[1]])
        XCTAssertEqual(control.count, 1)
        XCTAssertEqual(control.text(of: 0), "둘째")
        XCTAssertEqual(control.rebuilds, 2)
        control.set([])
        XCTAssertEqual(control.count, 0)
    }

    // MARK: render discipline

    func testPanelsRenderNothingWhileHidden() async throws {
        let rig = standardRig()
        let base = rig.hud.renderCount
        XCTAssertGreaterThan(base, 0)
        rig.hud.isRendering = false
        for f in rig.fakes.values { f.onChange?() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.hud.renderCount, base, "hidden plaza: nothing renders")
        rig.hud.isRendering = true
        XCTAssertGreaterThan(rig.hud.renderCount, base, "the changed panels render once when shown again")
    }

    func testAStillSceneRendersNoPanel() async throws {
        let rig = standardRig()
        let base = rig.hud.renderCount, draws = rig.panels.drawList, changes = rig.panels.counts.changes
        for _ in 0..<200 { rig.panels.frame() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(rig.hud.renderCount, base)
        XCTAssertEqual(rig.panels.counts.changes, changes)
        XCTAssertEqual(rig.panels.drawList, draws)
    }

    func testADPIChangeRendersEveryPanelOnce() async throws {
        let rig = standardRig(scale: 1)
        let base = rig.hud.renderCount
        rig.panels.report(size: CGSize(width: 640, height: 480), scale: 1.5)
        XCTAssertEqual(rig.hud.scale, 1.5)
        XCTAssertEqual(rig.hud.renderCount, base + 5)
        XCTAssertTrue(rig.panels.entries.values.allSatisfy { $0.scale == 1.5 })
        rig.panels.report(size: CGSize(width: 640, height: 480), scale: 1.5)
        XCTAssertEqual(rig.hud.renderCount, base + 5, "the same report again renders nothing")
    }

    func testTheChatLogKeepsTheBarsPlaceWhileTheFieldIsOpen() async {
        let c = controller(feed: false)
        let panels = WinPlazaPanels(hud: c.overlayBindings.hud)
        XCTAssertEqual(panels.chatBarHeight, 37, "Galmuri14's line (21) + 12 above + 4 below, as PlazaChatInput lays it out")
        panels.setChatLogAbove(true)
        let log = c.overlayBindings.hud.panels.first { $0.id == .chatLog } as? PlazaChatLogPanel
        XCTAssertEqual(log?.inputHeight, 37)
        panels.chatBarHeight = 60
        XCTAssertEqual(log?.inputHeight, 60)
        panels.setChatLogAbove(false)
        XCTAssertNil(log?.inputHeight)
    }

    // MARK: eye glyphs

    func testEyeGlyphs() async throws {
        XCTAssertEqual(WinPlazaSymbols.family(fluent: true, mdl2: true), .fluent)
        XCTAssertEqual(WinPlazaSymbols.family(fluent: false, mdl2: true), .mdl2, "Windows 10")
        XCTAssertNil(WinPlazaSymbols.family(fluent: false, mdl2: false))
        XCTAssertEqual(WinPlazaSymbols.glyph(for: "eye"), "\u{E890}", "View, not RedEye (E7B3)")
        XCTAssertEqual(WinPlazaSymbols.glyph(for: "eye.slash"), "\u{ED1A}")
        XCTAssertNil(WinPlazaSymbols.glyph(for: "star"))
        XCTAssertNil(WinPlazaSymbols.image(named: "star", pointSize: 12, scale: 1, color: .white, family: .fluent), "not a symbol it knows")
        XCTAssertNil(WinPlazaSymbols.image(named: "eye", pointSize: 12, scale: 1, color: .white, family: nil), "no symbol font: the panel draws its own")
        guard let family = WinPlazaSymbols.installed else { throw XCTSkip("neither Segoe Fluent Icons nor Segoe MDL2 Assets is installed: only the fallback path above ran") }
        print("symbol font used on this machine: \(family)")
        for name in ["eye", "eye.slash"] {
            for scale in [1.0, 1.25, 2.0] {
                let s = WinPlazaSymbols.image(named: name, pointSize: 12, scale: CGFloat(scale), color: .white, family: family)
                XCTAssertNotNil(s, "\(name) @\(scale)")
                if let s {
                    XCTAssertEqual(s.image.width, Int((s.size.width * CGFloat(scale)).rounded()))
                    XCTAssertTrue(s.size.width > 6 && s.size.width < 30 && s.size.height > 4 && s.size.height < 30, "\(s.size)")
                }
            }
        }
    }

    // MARK: faults

    /// One scenario that checks every rule a fault breaks; the failures it finds, by name.
    private func scenarioFailures() async throws -> [String] {
        var failed: [String] = []
        let rig = standardRig()
        if rig.panels.drawList.map({ $0.frame }) != WinPlazaPanels.zOrder.compactMap({ rig.panels.entries[$0]?.frame }) { failed.append("z") }
        if rig.click(CGPoint(x: 100, y: 100)) != [] { failed.append("cover") }               // the roster is below the board: covered
        if rig.click(CGPoint(x: 20, y: 500)) != ["chatLog"] { failed.append("hit") }         // the chat log is under the toggle in z
        if rig.click(CGPoint(x: 760, y: 20)) != ["backgroundToggle"] { failed.append("hit") }
        if rig.panels.host(at: CGPoint(x: 5, y: 590)) != .board { failed.append("cover") }
        let hidden = Rig([Fake(.roster, size: CGSize(width: 50, height: 50), hit: CGRect(x: 0, y: 0, width: 50, height: 50))])
        hidden.panels.setHidden([.roster])
        if hidden.panels.host(at: CGPoint(x: 10, y: 10)) != nil { failed.append("hidden") }
        let dpi = Rig([Fake(.roster, size: CGSize(width: 50, height: 50), hit: nil)])
        dpi.panels.report(size: CGSize(width: 400, height: 300), scale: 1.5)
        if dpi.hud.scale != 1.5 { failed.append("dpi") }
        let base = rig.hud.renderCount
        for _ in 0..<20 { rig.panels.frame() }
        try await Task.sleep(for: .milliseconds(50))
        if rig.hud.renderCount != base { failed.append("rerender") }
        return failed
    }

    func testEachInjectedFaultIsCaught() async throws {
        let clean = try await scenarioFailures()
        XCTAssertEqual(clean, [])
        #if DEBUG
        let expected: [WinPanelFaults.Fault: String] = [.wrongZ: "z", .topPanelTakesHit: "hit", .coverNotFullWindow: "cover",
                                                         .hiddenStillHit: "hidden", .dpiIgnored: "dpi", .rerenderEveryFrame: "rerender"]
        for fault in WinPanelFaults.Fault.allCases {
            WinPanelFaults.active = [fault]
            let failures = try await scenarioFailures()
            WinPanelFaults.active = []
            XCTAssertTrue(failures.contains(expected[fault] ?? "?"), "\(fault) was not noticed: \(failures)")
        }
        #endif
    }
}
#endif
