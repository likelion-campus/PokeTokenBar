import XCTest
@testable import PokeTokenBar

/// The member and campfire menus and the minimap as panels (Track A Task 16): sizes, the ▶ marker, what a click does and where
/// (rows choose, the menu's body does nothing, everywhere else cancels), the items VoiceOver reads, and when the minimap
/// draws. Stub graphics (deterministic monospace text), so they run on Windows too; the SwiftUI originals and the Mac's
/// real text are in `PlazaHUDMenuRenderTests+Mac`.
@MainActor final class PlazaHUDMenusTests: XCTestCase {
    private let viewport = CGSize(width: 960, height: 640)
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    private struct Rig {
        let hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics, model: PlazaOverlayModel, panel: PlazaMenuPanel
        let log: Log
    }
    @MainActor final class Log { var actions: [String] = [] }

    private func rig(_ content: PlazaOverlayContent, viewport: CGSize? = nil, countdown: String? = nil, banner: String? = nil) -> Rig {
        let model = PlazaOverlayModel()
        model.content = content
        model.countdown = countdown
        model.banner = banner
        let pills = PlazaPillsPanel(model: model)
        let panel = PlazaMenuPanel(model: model, pills: pills)
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel, pills], graphics: graphics)
        let host = RecordingPanelHost(), log = Log()
        hud.onAction = { id, hit in log.actions.append("\(id) \(hit.action) \(hit.index.map(String.init) ?? "-")") }
        hud.setViewport(viewport ?? self.viewport, scale: 2)
        hud.host = host
        return Rig(hud: hud, host: host, graphics: graphics, model: model, panel: panel, log: log)
    }

    private func click(_ r: Rig, _ point: CGPoint) {
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: point), in: .menu)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: point), in: .menu)
    }

    private func frame(_ r: Rig) throws -> CGRect {
        guard case .image(_, let f)? = r.host.drawings[.menu]?.layers.first else { throw XCTSkip("no menu") }
        return f
    }

    private let three = PlazaMemberMenu(memberID: "m", nickname: "민수", nameColor: nil, actions: [.greet, .tackle, .viewCard])

    // MARK: size and growth

    func testMenuGrowsFrom180ToTheLongestRow() async throws {
        XCTAssertEqual(PlazaMenuText.width, 180, "pinned: the SwiftUI menu's minimum width")
        XCTAssertEqual(try frame(rig(.memberMenu(three))).width, PlazaMenuText.width, "a short menu is 180 wide")
        var menu = PlazaMemberMenu(memberID: "m", nickname: String(repeating: "Ｗ", count: 12), nameColor: nil, actions: [.greet, .tackle, .viewCard])
        XCTAssertEqual(try frame(rig(.memberMenu(menu))).width, PlazaMenuText.width, "a long name is cut at 156 inside it, it does not widen the menu")
        menu.status = L(.ko).plazaFocusStatus(seconds: 7 * 3600 + 43 * 60)
        let status = try frame(rig(.memberMenu(menu))).width
        XCTAssertGreaterThan(status, PlazaMenuText.width, "a long status grows it")
        let shorter = try frame(rig(.memberMenu(PlazaMemberMenu(memberID: "m", nickname: "가", status: "🔥 짧음")))).width
        XCTAssertEqual(shorter, PlazaMenuText.width)
        // The campfire menu: the same, and its notice/rows grow it too.
        let camp = PlazaCampfireMenu(isJoin: false, minutes: PlazaCampfire.durations, selection: 0)
        XCTAssertGreaterThanOrEqual(try frame(rig(.campfireMenu(camp))).width, PlazaMenuText.width)
        // Height: padding 12 twice, a line per entry, 4 between.
        let r = rig(.memberMenu(three))
        let lineH = (0.8 + 0.2) * 15   // stub body font: ascender 0.8, descender -0.2, size 15
        XCTAssertEqual(try frame(r).height, 24 + 4 * lineH + 3 * 4, accuracy: 0.01)
    }

    func testTheMenuIsCentredBelowThePills() async throws {
        let alone = try frame(rig(.memberMenu(three)))
        XCTAssertEqual(alone.minY, PlazaRosterMetrics.margin)
        XCTAssertEqual(alone.midX, viewport.width / 2, accuracy: 0.5)
        let banner = try frame(rig(.memberMenu(three), banner: "배너"))
        XCTAssertGreaterThan(banner.minY, alone.minY, "a banner pushes it down by its height and 8")
        let narrow = try frame(rig(.memberMenu(three), viewport: CGSize(width: 600, height: 372)))
        XCTAssertEqual(narrow.midX, 300, accuracy: 0.5)
    }

    // MARK: selection marker

    func testMenuSelectionMarker() async throws {
        for (selection, row) in [(PlazaMemberAction.greet, 0), (.tackle, 1), (.viewCard, 2)] {
            var menu = three
            menu.selection = selection
            let r = rig(.memberMenu(menu))
            let markers = r.graphics.canvases.flatMap(\.calls).filter { $0.hasPrefix("line ") && $0.contains("▶") }
            XCTAssertEqual(markers.count, 1, "one ▶, on the selected row (\(selection))")
            let items = try XCTUnwrap(r.host.drawings[.menu]).accessibility
            XCTAssertTrue(items.allSatisfy { !$0.label.contains("▶") }, "the marker is decoration: no item")
            XCTAssertEqual(items.filter { $0.role == .menuItem }.count, 3)
            _ = row
        }
        let camp = rig(.campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: [25, 60], selection: 2, isLit: true)))
        XCTAssertEqual(camp.graphics.canvases.flatMap(\.calls).filter { $0.hasPrefix("line ") && $0.contains("▶") }.count, 1)
    }

    // MARK: clicks

    func testClickingARowChooses() async throws {
        let r = rig(.memberMenu(three))
        let f = try frame(r)
        let items = try XCTUnwrap(r.host.drawings[.menu]).accessibility.filter { $0.role == .menuItem }
        XCTAssertEqual(items.map(\.label), three.actions.map(PlazaMenuText.title))
        for (i, item) in items.enumerated() {
            click(r, CGPoint(x: item.frame.midX, y: item.frame.midY))
            XCTAssertEqual(r.log.actions.last, "menu choose \(i)")
            XCTAssertEqual(item.action, PlazaPanelHit(action: "choose", index: i))
            // The whole width of the row, padding to padding, is the row (the label's `contentShape`).
            click(r, CGPoint(x: f.minX + PlazaMenuPanel.padding + 1, y: item.frame.midY))
            click(r, CGPoint(x: f.maxX - PlazaMenuPanel.padding - 1, y: item.frame.midY))
            XCTAssertEqual(r.log.actions.suffix(2), ["menu choose \(i)", "menu choose \(i)"])
        }
        // The name line, the padding and the gaps between rows are the menu's background: nothing.
        func real() -> Int { r.log.actions.filter { $0 != "menu menu -" }.count }
        let count = real()
        click(r, CGPoint(x: f.midX, y: f.minY + 4))
        click(r, CGPoint(x: f.minX + 3, y: items[0].frame.midY))
        click(r, CGPoint(x: f.midX, y: (items[0].frame.maxY + items[1].frame.minY) / 2))
        XCTAssertEqual(real(), count, "the menu's own background takes the click and does nothing (the controller ignores `menu`)")
    }

    func testClickingOutsideCancels() async throws {
        let r = rig(.memberMenu(three))
        let f = try frame(r)
        click(r, CGPoint(x: 5, y: 5))
        click(r, CGPoint(x: f.maxX + 40, y: f.midY))
        click(r, CGPoint(x: f.midX, y: f.maxY + 100))
        XCTAssertEqual(r.log.actions, ["menu cancel -", "menu cancel -", "menu cancel -"])
        // Released outside the press: no action (a click is a press and a release on the same spot of the menu).
        r.log.actions = []
        let row = try XCTUnwrap(r.host.drawings[.menu]).accessibility.first { $0.role == .menuItem }!.frame
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: CGPoint(x: row.midX, y: row.midY)), in: .menu)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: 5, y: 5)), in: .menu)
        XCTAssertEqual(r.log.actions, [])
    }

    func testAMenuPanelIsOnlyThereWhileAMenuIsOpen() async throws {
        let r = rig(.none)
        XCTAssertNil(r.host.drawings[.menu])
        XCTAssertNil(r.hud.hit(at: CGPoint(x: 5, y: 5), in: .menu), "no menu: no click catcher")
        r.model.content = .memberMenu(three)
        await flush()
        XCTAssertNotNil(r.host.drawings[.menu])
        XCTAssertNotNil(r.hud.hit(at: CGPoint(x: 5, y: 5), in: .menu))
        r.model.content = .board
        await flush()
        XCTAssertNil(r.host.drawings[.menu], "a board or a card is not a menu")
        // The arrow keys move the selection (the scene's path): the marker follows without a new frame.
        var moved = three
        moved.move(by: 1)
        r.model.content = .memberMenu(moved)
        await flush()
        XCTAssertNotNil(r.host.drawings[.menu])
    }

    func testAPressedRowDims() async throws {
        let r = rig(.memberMenu(three))
        let row = try XCTUnwrap(r.host.drawings[.menu]).accessibility.first { $0.role == .menuItem }!.frame
        let p = CGPoint(x: row.midX, y: row.midY)
        let before = r.graphics.canvases.count
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .menu)
        await flush()
        XCTAssertTrue(r.graphics.canvases.dropFirst(before).last?.calls.contains("alpha \(Double(PlazaPanelStyle.pressedOpacity))") ?? false)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: .menu)
        XCTAssertEqual(r.log.actions, ["menu choose 0"])
    }

    func testTheCampfireMenuListsItsRows() async throws {
        let camp = PlazaCampfireMenu(isJoin: false, minutes: [25, 480], selection: 0, isLit: true)
        let r = rig(.campfireMenu(camp))
        let items = try XCTUnwrap(r.host.drawings[.menu]).accessibility
        XCTAssertEqual(items.map(\.label), [L(.ko).plazaCampfireMenuTitle(isJoin: false), "25분 집중", "8시간 집중", "불 끄기"])
        XCTAssertEqual(items.map(\.role), [.staticText, .menuItem, .menuItem, .menuItem])
        let full = rig(.campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [], selection: 0)))
        XCTAssertEqual(try XCTUnwrap(full.host.drawings[.menu]).accessibility.map(\.label),
                       [L(.ko).plazaCampfireMenuTitle(isJoin: true), "자리가 없어요", "불 켜기"])
    }

    // MARK: the minimap

    private func minimapRig(background: Bool = false) -> (PlazaHUD, RecordingPanelHost, CanvasKeepingGraphics, PlazaMinimapPanel, PlazaMinimapModel, PlazaBackgroundModel) {
        let model = PlazaMinimapModel(), bg = PlazaBackgroundModel()
        bg.isHidden = background
        let map = PlazaImage(bitmap: PlazaBitmap(width: 48, height: 32, fill: PlazaRGBA(r: 110, g: 186, b: 84, a: 255)))
        let panel = PlazaMinimapPanel(model: model, background: bg, worldSize: PlazaMapData.map.pixelSize, mapImage: { map })
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(viewport, scale: 2)
        hud.host = host
        return (hud, host, graphics, panel, model, bg)
    }

    func testMinimapDotsAndViewRect() async throws {
        let (hud, host, graphics, _, model, _) = minimapRig()
        defer { _ = hud }
        model.dots = [.init(id: "a", tile: TilePoint(x: 3, y: 4), color: PlazaNameColor.palette[1], isMe: false, isAway: true),
                      .init(id: "me", tile: TilePoint(x: 9, y: 2), color: PlazaNameColor.palette[0], isMe: true, isAway: false)]
        model.view = CGRect(x: 100, y: 80, width: 300, height: 200)
        model.campfire = TilePoint(x: 12, y: 6)
        model.item = TilePoint(x: 5, y: 5)
        await flush()
        let calls = try XCTUnwrap(graphics.canvases.last).calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("fillEllipse") }.count, 2, "a dot each")
        XCTAssertEqual(calls.filter { $0.hasPrefix("strokeEllipse") }.count, 2)
        XCTAssertGreaterThanOrEqual(calls.filter { $0.hasPrefix("strokePath") }.count, 3, "the view rectangle, the campfire's square, the item's diamond")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex { $0.hasPrefix("fillEllipse") }), try XCTUnwrap(calls.lastIndex { $0.hasPrefix("fillEllipse") }))
        let alphas = calls.filter { $0.hasPrefix("alpha ") }
        XCTAssertTrue(alphas.contains("alpha 0.45"), "an away member's dot is fainter")
        let scale = PlazaMinimapModel.width / PlazaMapData.map.pixelSize.width
        let tile = CGFloat(PlazaMap.tileSize) * scale
        // Me is drawn last (on top), 4.5 around the middle of its tile.
        let me = try XCTUnwrap(calls.last { $0.hasPrefix("fillEllipse") })
        XCTAssertTrue(me.contains(String(describing: Double(9.5 * tile - 4.5))), "\(me)")
        XCTAssertEqual(host.drawings[.minimap]?.layers.count, 2, "the plate and the marks")
        XCTAssertTrue(host.drawings[.minimap]?.accessibility.isEmpty ?? false, "SwiftUI exposed nothing readable")
    }

    func testMinimapDimsWhenTheBackgroundIsHidden() async throws {
        let (_, _, shown, _, _, _) = minimapRig()
        let (_, _, hidden, _, _, _) = minimapRig(background: true)
        let a = shown.canvases.flatMap(\.calls), b = hidden.canvases.flatMap(\.calls)
        XCTAssertFalse(a.contains("alpha 0.3"))
        XCTAssertTrue(b.contains("alpha \(Double(PlazaMinimapPanel.dimmedMapOpacity))"), "the map at 30 %")
        XCTAssertTrue(b.contains { $0.hasPrefix("fillColor (0.0, 0.0, 0.0, 0.45") }, "the plate black at 45 %")
        XCTAssertTrue(a.contains { $0.hasPrefix("fillColor (0.1137") || $0.hasPrefix("fillColor (0.11") }, "the plate teal while shown")
    }

    /// The map layer is made again for a new minute, season map, hidden background or scale, and for nothing else: walking
    /// members only redraw the small marks layer.
    func testMinimapRendersOncePerMinuteAtMost() async throws {
        let (hud, host, _, panel, model, bg) = minimapRig()
        defer { _ = host }
        await flush()
        XCTAssertEqual([panel.plateRenders, panel.marksRenders, panel.mapScalings], [1, 1, 1])
        for i in 0..<50 {
            model.dots = [.init(id: "me", tile: TilePoint(x: i % 40, y: 3), color: PlazaNameColor.palette[0], isMe: true, isAway: false)]
            await flush()
        }
        XCTAssertEqual(panel.plateRenders, 1, "dots moving never redraw the map")
        XCTAssertEqual(panel.mapScalings, 1)
        XCTAssertEqual(panel.marksRenders, 51)
        // Several changes in one turn are one render.
        let marks = panel.marksRenders
        model.dots = []
        model.view = CGRect(x: 1, y: 1, width: 50, height: 50)
        model.item = TilePoint(x: 1, y: 1)
        await flush()
        XCTAssertEqual(panel.marksRenders, marks + 1)
        // The clock's ticks: the same minute does nothing, a new minute draws the map once.
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 0))!
        panel.update(date: noon)
        await flush()
        XCTAssertEqual(panel.plateRenders, 2)
        for s in 1..<60 { panel.update(date: noon.addingTimeInterval(Double(s))) }
        await flush()
        XCTAssertEqual(panel.plateRenders, 2, "59 more seconds of the same minute: no render")
        panel.update(date: noon.addingTimeInterval(60))
        await flush()
        XCTAssertEqual(panel.plateRenders, 3)
        XCTAssertEqual(panel.mapScalings, 1, "the downscaled map is kept; only the light is applied again")
        // Hidden background: the minute does not matter; showing again draws once.
        bg.isHidden = true
        await flush()
        XCTAssertEqual(panel.plateRenders, 4)
        panel.update(date: noon.addingTimeInterval(120))
        await flush()
        XCTAssertEqual(panel.plateRenders, 4, "unlit while hidden: a new minute changes nothing")
        // A hidden plaza renders nothing at all.
        hud.isRendering = false
        model.dots = [.init(id: "x", tile: TilePoint(x: 1, y: 1), color: PlazaNameColor.palette[2], isMe: false, isAway: false)]
        bg.isHidden = false
        await flush()
        let renders = [panel.plateRenders, panel.marksRenders]
        XCTAssertEqual(renders, [4, panel.marksRenders])
        hud.isRendering = true
        XCTAssertEqual(panel.plateRenders, 5)
        XCTAssertEqual(panel.marksRenders, renders[1] + 1)
    }

    func testTheMinimapIsThePlacedWhereTheOldConstraintsPutIt() async throws {
        let (hud, _, _, _, _, _) = minimapRig()
        let f = try XCTUnwrap(hud.layout(viewport: viewport, scale: 2)[.minimap])
        let room = PlazaPanelStyle.strokeRoom
        XCTAssertEqual(f.insetBy(dx: room, dy: room).size.width, PlazaMinimapModel.width + 8)
        XCTAssertEqual(f.insetBy(dx: room, dy: room).size.height, PlazaPanelStyle.minimapHeight(worldSize: PlazaMapData.map.pixelSize))
        XCTAssertEqual(f.maxX - room, viewport.width - PlazaRosterMetrics.margin, "14 from the trailing edge")
        XCTAssertEqual(f.maxY - room, viewport.height - 16, "16 from the bottom")
        XCTAssertNil(hud.hit(at: CGPoint(x: f.midX, y: f.midY), in: .minimap), "no clicks")
    }
}
