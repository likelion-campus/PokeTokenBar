import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// The canvas-drawn member and campfire menus and the minimap (Track A Task 16) against the SwiftUI views they replace
/// (`Legacy/LegacyPlazaHUDMenus`, verbatim): the menus' frames and pixels in a window, the minimap's map layer against
/// SwiftUI's resampling, each through the hosts' layer trees (no window shown). With `PTB_PLAZA_HUD_OUT` set it writes
/// the PR's before/after images and a contact sheet into that directory. Real CoreText; nothing is shown on screen.
@MainActor final class PlazaHUDMenuRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    private let graphics = PlatformPlaza.graphics
    private let longName = "가나다라마바사아자차카타"

    @MainActor private final class Shell: PlazaPanelHost {
        var hosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) { hosts[id]?.show(drawing: drawing, frame: frame, scale: scale) }
        func hide(_ id: PlazaPanelID) { hosts[id]?.hide() }
    }

    private func throughHosts(_ hud: PlazaHUD, viewport: CGSize, scale: CGFloat) throws -> CGImage {
        let container = NSView(frame: NSRect(origin: .zero, size: viewport))
        let shell = Shell()
        var hosts: [PlazaPanelHostView] = []
        for p in hud.panels {
            let h = PlazaPanelHostView(hud: hud, panel: p.id)
            h.frame = container.bounds
            container.addSubview(h)
            hosts.append(h)
            shell.hosts[p.id] = h
        }
        hud.setViewport(viewport, scale: scale)
        hud.host = shell
        let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        for h in hosts { try XCTUnwrap(h.layer).render(in: ctx) }
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: menus

    struct MenuCase { var name: String; var content: PlazaOverlayContent; var viewport = CGSize(width: 960, height: 640); var pills = false }

    private func menuCases() -> [MenuCase] {
        var one = PlazaMemberMenu(memberID: "m1", nickname: "메타몽", nameColor: PlazaDitto.nameHex); one.actions = [.tackle]; one.selection = .tackle
        let three = PlazaMemberMenu(memberID: "m2", nickname: "피카츄", nameColor: nil, actions: [.greet, .tackle, .viewCard])
        let four = PlazaMemberMenu(memberID: "m3", nickname: "ＷＷＷＷＷＷＷＷＷＷＷＷ", nameColor: PlazaNameColor.hexes[4], selection: .follow)
        var status = PlazaMemberMenu(memberID: "m3", nickname: longName, nameColor: PlazaNameColor.hexes[4], selection: .follow)
        status.status = L(.ko).plazaFocusStatus(seconds: 7 * 3600 + 43 * 60)
        return [
            MenuCase(name: "member-1-row", content: .memberMenu(one)),
            MenuCase(name: "member-3-rows", content: .memberMenu(three)),
            MenuCase(name: "member-4-rows-long-name", content: .memberMenu(four)),
            MenuCase(name: "member-4-rows-long-status", content: .memberMenu(status), viewport: CGSize(width: 600, height: 372)),
            MenuCase(name: "member-under-pills", content: .memberMenu(three), pills: true),
            MenuCase(name: "campfire-light", content: .campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: PlazaCampfire.durations, selection: 1))),
            MenuCase(name: "campfire-join-lit", content: .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [25, 60], selection: 2, isLit: true))),
            MenuCase(name: "campfire-full", content: .campfireMenu(PlazaCampfireMenu(isJoin: true, minutes: [], selection: 0))),
        ]
    }

    private func menuBefore(_ c: MenuCase, scale: CGFloat) throws -> CGImage {
        let v = c.viewport
        let model = PlazaOverlayModel()
        model.content = c.content
        if c.pills { model.countdown = "단체 사진 5 · P를 누르면 함께 찍어요"; model.banner = "사진을 클립보드에 담았어요" }
        let pillsSize = PlazaPillsPanel(model: model).stack(in: v, scale: scale, text: graphics.text).size
        let view = ZStack(alignment: .top) {
            Color.clear
            VStack(spacing: 8) {
                if pillsSize.height > 0 { Color.clear.frame(width: pillsSize.width, height: pillsSize.height) }
                switch c.content {
                case .memberMenu(let m): LegacyPlazaMemberMenuView(menu: m, onChoose: { _ in })
                case .campfireMenu(let m): LegacyPlazaCampfireMenuView(menu: m, onChoose: { _ in })
                default: EmptyView()
                }
            }.padding(.top, PlazaRosterMetrics.margin)
        }.frame(width: v.width, height: v.height)
        return try XCTUnwrap(K.render(view, scale: scale))
    }

    private func menuAfter(_ c: MenuCase, scale: CGFloat) throws -> (CGImage, PlazaHUD, PlazaOverlayModel) {
        let model = PlazaOverlayModel()
        model.content = c.content
        if c.pills { model.countdown = "단체 사진 5 · P를 누르면 함께 찍어요"; model.banner = "사진을 클립보드에 담았어요" }
        let pills = PlazaPillsPanel(model: model)
        let hud = PlazaHUD(panels: [PlazaMenuPanel(model: model, pills: pills)], graphics: graphics)
        return (try throughHosts(hud, viewport: c.viewport, scale: scale), hud, model)
    }

    /// The menu is where SwiftUI put it and as big: its frame in the window is the SwiftUI menu's (measured from its render),
    /// at 1x and 2x, and grows from 180 to its longest line.
    func testMenusAreWhereAndAsBigAsSwiftUIMadeThem() async throws {
        for c in menuCases() {
            for scale in [CGFloat(1), 2] {
                let (_, hud, _) = try menuAfter(c, scale: scale)
                let panel = try XCTUnwrap(hud.panels.first as? PlazaMenuPanel)
                let items = panel.render(scale: scale, viewport: c.viewport, graphics: graphics).accessibility
                XCTAssertFalse(items.isEmpty, c.name)
                let before = K.boxes(try menuBefore(c, scale: scale))
                let menu = try XCTUnwrap(before.last, c.name)
                // The panel's menu rect: the union of its rows' frames, padded as the menu pads.
                let rowFrames = items.map(\.frame)
                let top = rowFrames.map(\.minY).min()! - PlazaMenuPanel.padding, left = rowFrames.map(\.minX).min()! - PlazaMenuPanel.padding
                XCTAssertEqual(menu.minX / scale, left, accuracy: 1.01, "\(c.name)@\(scale) x")
                XCTAssertEqual(menu.minY / scale, top, accuracy: 1.01, "\(c.name)@\(scale) y")
                let widest = items.filter { $0.role == .menuItem }.map(\.frame.width).max() ?? 0
                XCTAssertGreaterThanOrEqual(menu.width / scale, PlazaMenuText.width - 0.01, c.name)
                _ = widest
            }
        }
    }

    // MARK: minimap

    struct MapCase { var name: String; var season: PlazaSeason; var hour: Int; var minute = 0; var hidden = false; var marks = true }

    private func seasonImage(_ season: PlazaSeason) -> PlazaImage? {
        guard season != .summer, let sheet = PlatformPlaza.tileSheet() else { return nil }
        let art = PlatformPlaza.tallGrassSheet().map { PlazaSeasonSheet.tallGrass($0, season: season) }.flatMap(PlazaTallGrassArt.init(sheet:))
        return PlazaTileArt.mapImage(PlazaMapData.map, sheet: PlazaSeasonSheet.tiles(sheet, season: season), tallGrass: art)
    }

    private func baseMap() -> PlazaImage {
        let sheet = PlatformPlaza.tileSheet()
        return sheet.map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: PlatformPlaza.tallGrassArt()) } ?? PlazaTileArt.plainGrassImage(PlazaMapData.map)
    }

    private func mapModel(_ c: MapCase) -> (PlazaMinimapModel, PlazaBackgroundModel) {
        let m = PlazaMinimapModel()
        m.seasonMapImage = seasonImage(c.season)
        if c.marks {
            m.dots = [.init(id: "a", tile: TilePoint(x: 10, y: 8), color: PlazaNameColor.palette[1], isMe: false, isAway: false),
                      .init(id: "b", tile: TilePoint(x: 22, y: 14), color: PlazaNameColor.palette[3], isMe: false, isAway: true),
                      .init(id: "me", tile: TilePoint(x: 16, y: 11), color: PlazaNameColor.palette[0], isMe: true, isAway: false)]
            m.view = CGRect(x: 200, y: 120, width: 360, height: 220)
            m.campfire = TilePoint(x: 30, y: 6)
            m.item = TilePoint(x: 5, y: 18)
        }
        let b = PlazaBackgroundModel()
        b.isHidden = c.hidden
        return (m, b)
    }

    private func mapDate(_ c: MapCase) -> Date { K.date(hour: c.hour, minute: c.minute) }

    private func mapBefore(_ c: MapCase, scale: CGFloat) throws -> CGImage {
        let (m, b) = mapModel(c)
        let base = baseMap()
        let view = LegacyPlazaMinimapView(model: m, background: b, mapImage: base.nsImage, worldSize: PlazaMapData.map.pixelSize, fixedDate: mapDate(c))
        let fit = NSHostingView(rootView: view).fittingSize
        let v = CGSize(width: 400, height: 200)
        let ctx = K.context(Int(v.width * scale), Int(v.height * scale))
        // The border overhangs the view by 0.75 point; ImageRenderer crops to the view, so the view gets 2 points of room.
        let image = try XCTUnwrap(K.render(view.frame(width: fit.width, height: fit.height).padding(2), scale: scale))
        ctx.draw(image, in: CGRect(x: (v.width - PlazaRosterMetrics.margin - fit.width - 2) * scale, y: 14 * scale,
                                   width: (fit.width + 4) * scale, height: (fit.height + 4) * scale))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func mapAfter(_ c: MapCase, scale: CGFloat) throws -> CGImage {
        let (m, b) = mapModel(c)
        let base = baseMap()
        let panel = PlazaMinimapPanel(model: m, background: b, worldSize: PlazaMapData.map.pixelSize, mapImage: { base })
        panel.update(date: mapDate(c))
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        return try throughHosts(hud, viewport: CGSize(width: 400, height: 200), scale: scale)
    }

    static let mapCases: [MapCase] = {
        var out: [MapCase] = []
        for season in [PlazaSeason.summer, .spring, .autumn, .winter] {
            out.append(MapCase(name: "\(season)-day-map", season: season, hour: 12, marks: false))
            out.append(MapCase(name: "\(season)-night-map", season: season, hour: 23, marks: false))
        }
        out.append(MapCase(name: "summer-dusk-map", season: .summer, hour: 16, minute: 40, marks: false))
        out.append(MapCase(name: "summer-day-marks", season: .summer, hour: 12))
        out.append(MapCase(name: "winter-night-marks", season: .winter, hour: 23))
        out.append(MapCase(name: "summer-hidden-marks", season: .summer, hour: 12, hidden: true))
        return out
    }()

    /// The marks (rectangles, dots, diamond) against SwiftUI's at 1x and 2x: only antialiasing differs.
    func testTheMarksLookLikeSwiftUIs() async throws {
        for c in Self.mapCases where c.marks {
            for scale in [CGFloat(1), 2] {
                let d = K.diff(try mapBefore(c, scale: scale), try mapAfter(c, scale: scale))
                if ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] != nil {
                    try K.write(d.image, URL(fileURLWithPath: ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"]!).appendingPathComponent("window-diff-\(c.name)@\(Int(scale))x.png"))
                }
                print("MARKS \(c.name)@\(Int(scale))x over8 \(d.over8) over64 \(d.over64) max \(d.max)")
                XCTAssertLessThan(d.over64, scale == 1 ? 600 : 250, "\(c.name)@\(scale)")
            }
        }
    }

    /// Mean and largest channel error of the map layer (no marks) against SwiftUI's, per season, day, dusk and night, at 1x
    /// and 2x, inside the map's rectangle. The numbers go in the PR; the bounds are what the first run measured.
    func testTheMapLayerIsCloseToSwiftUIsResampling() async throws {
        var lines: [String] = []
        for c in Self.mapCases where !c.marks {
            for scale in [CGFloat(1), 2] {
                let b = K.rgba(try mapBefore(c, scale: scale)), a = K.rgba(try mapAfter(c, scale: scale))
                let w = Int(400 * scale)
                let height = PlazaPanelStyle.minimapHeight(worldSize: PlazaMapData.map.pixelSize) - 8
                // The map: 4 points in from the panel's trailing edge (14 from the window's) and 4 above the window's bottom 16.
                let x0 = Int((400 - PlazaRosterMetrics.margin - 4 - PlazaMinimapModel.width) * scale), x1 = Int((400 - PlazaRosterMetrics.margin - 4) * scale)
                let y1 = Int((200 - 16 - 4) * scale), y0 = Int((200 - 16 - 4 - height) * scale)
                var sum = 0, count = 0, worst = 0
                for y in (y0 + 2)..<(y1 - 2) { for x in (x0 + 2)..<(x1 - 2) {
                    for k in 0..<3 { let d = abs(Int(b[(y * w + x) * 4 + k]) - Int(a[(y * w + x) * 4 + k])); sum += d; count += 1; worst = max(worst, d) }
                } }
                let mean = Double(sum) / Double(count)
                lines.append(String(format: "%@@%dx mean %.2f max %d", c.name, Int(scale), mean, worst))
                XCTAssertLessThan(mean, scale == 1 ? 8 : 1, "\(c.name)@\(scale)")
            }
        }
        print("MINIMAP-ERRORS\n" + lines.joined(separator: "\n"))
    }

    /// What the minimap costs (printed for the PR): the map layer's cold render (downscale + light + plate), its re-render a minute
    /// later (the downscaled map kept), and the marks layer a walking member causes; with the bitmap sizes.
    func testMinimapRenderCost() async throws {
        let base = baseMap()
        for scale in [CGFloat(1), 2] {
            let model = PlazaMinimapModel(), bg = PlazaBackgroundModel()
            model.dots = (0..<8).map { .init(id: "\($0)", tile: TilePoint(x: 3 + $0 * 4, y: 6 + $0), color: PlazaNameColor.palette[$0 % 12], isMe: $0 == 0, isAway: $0 % 3 == 0) }
            model.view = CGRect(x: 200, y: 120, width: 360, height: 220)
            model.campfire = TilePoint(x: 30, y: 6)
            model.item = TilePoint(x: 5, y: 18)
            let panel = PlazaMinimapPanel(model: model, background: bg, worldSize: PlazaMapData.map.pixelSize, mapImage: { base })
            func ms(_ body: () -> Void) -> Double {
                let t = ContinuousClock.now; body()
                let d = ContinuousClock.now - t
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            var drawing = PlazaPanelDrawing()
            panel.update(date: K.date(hour: 12, minute: 0))
            let cold = ms { drawing = panel.render(scale: scale, viewport: .zero, graphics: graphics) }
            panel.update(date: K.date(hour: 12, minute: 1))
            let minuteLater = ms { drawing = panel.render(scale: scale, viewport: .zero, graphics: graphics) }
            model.dots[1] = .init(id: "1", tile: TilePoint(x: 8, y: 7), color: PlazaNameColor.palette[1], isMe: false, isAway: false)
            var marks = 0.0
            for _ in 0..<20 { marks += ms { drawing = panel.render(scale: scale, viewport: .zero, graphics: graphics) } }
            let sizes = drawing.layers.compactMap { l -> String? in if case .image(let i, _) = l { return "\(i.width)x\(i.height)" } else { return nil } }
            print("MINIMAP-COST @\(Int(scale))x cold \(String(format: "%.1f", cold)) ms, new minute \(String(format: "%.1f", minuteLater)) ms, a moved dot (marks layer; the plate is cached) \(String(format: "%.2f", marks / 20)) ms, images \(sizes)")
        }
    }

    // MARK: images

    func testWriteMenuAndMinimapImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var summary: [String] = [], rows: [(label: String, cells: [CGImage])] = []
        func row(_ tag: String, _ b: CGImage, _ a: CGImage, crop: CGRect, scale: CGFloat) throws {
            let zoom = scale == 1 ? 2 : 1
            let cells = [K.cell(b, crop: crop, scale: scale, background: nil, zoom: zoom), K.cell(a, crop: crop, scale: scale, background: nil, zoom: zoom)]
            let d = K.diff(K.cell(b, crop: crop, scale: scale, background: nil, zoom: 1), K.cell(a, crop: crop, scale: scale, background: nil, zoom: 1))
            try K.write(cells[0], out.appendingPathComponent("before-\(tag).png"))
            try K.write(cells[1], out.appendingPathComponent("after-\(tag).png"))
            try K.write(d.image, out.appendingPathComponent("diff-\(tag).png"))
            let line = "\(tag): pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
            summary.append(line)
            rows.append((line, cells + [K.cell(d.image, crop: CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / scale, height: CGFloat(d.image.height) / scale),
                                              scale: scale, background: nil, zoom: zoom)]))
        }
        for c in menuCases() {
            for scale in [CGFloat(2), 1] {
                let (a, _, _) = try menuAfter(c, scale: scale)
                try row("\(c.name)@\(Int(scale))x", try menuBefore(c, scale: scale), a,
                        crop: CGRect(x: c.viewport.width / 2 - 150, y: 0, width: 300, height: c.pills ? 260 : 190), scale: scale)
            }
        }
        for c in Self.mapCases {
            for scale in [CGFloat(2), 1] {
                try row("minimap-\(c.name)@\(Int(scale))x", try mapBefore(c, scale: scale), try mapAfter(c, scale: scale),
                        crop: CGRect(x: 170, y: 50, width: 216, height: 140), scale: scale)
            }
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try K.write(K.sheet(rows, columns: ["before (SwiftUI)", "after (panel)", "diff (magenta: a channel off by more than 8)"]),
                    out.appendingPathComponent("contact-sheet.png"))
    }
}
