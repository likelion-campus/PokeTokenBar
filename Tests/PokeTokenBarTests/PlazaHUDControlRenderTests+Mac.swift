import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// The canvas-drawn shortcut guide, background toggle, name-colour picker and photo frame (Track A Task 15) against the
/// SwiftUI views they replace (`Legacy/LegacyPlazaHUDControls`, verbatim): the sizes SwiftUI measured and the pixels in a
/// window, the "after" taken through the hosts' layer trees (no window shown). With `PTB_PLAZA_HUD_OUT` set it writes the
/// PR's before/after images, diffs and a contact sheet into that directory. Real CoreText; nothing is shown on screen.
@MainActor final class PlazaHUDControlRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    private let graphics = PlatformPlaza.graphics

    struct Case {
        var name: String
        var viewport = CGSize(width: 960, height: 640)
        var hidden = false
        var folded = false
        var season = PlazaSeason.winter
        var open = false
        var selected = 0
        var photo = false
        var parts: Set<String> = ["toggle", "guide", "picker"]
    }

    // MARK: before: the SwiftUI views where the old constraints put them

    /// The hosting views' fitting sizes and frames (points, top-left) in a window: toggle at the margin, the guide 6 under it,
    /// the picker 8 right of it, as the old Auto Layout constraints placed them.
    private func swiftUIFrames(_ c: Case) -> (toggle: CGRect, guide: CGRect, picker: CGRect) {
        let bg = PlazaBackgroundModel(); bg.isHidden = c.hidden
        let gm = PlazaShortcutGuideModel(); gm.isFolded = c.folded; gm.season = c.season
        let nm = PlazaNameColorModel(); nm.isOpen = c.open; nm.current = PlazaNameColor.hexes[c.selected]
        let t = NSHostingView(rootView: LegacyPlazaBackgroundToggle(model: bg, toggle: {})).fittingSize
        let g = NSHostingView(rootView: LegacyPlazaShortcutGuide(model: gm, toggle: {})).fittingSize
        let p = NSHostingView(rootView: LegacyPlazaNameColorPicker(model: nm, toggle: {}, choose: { _ in })).fittingSize
        let m = PlazaRosterMetrics.margin
        return (CGRect(x: m, y: m, width: t.width, height: t.height),
                CGRect(x: m, y: m + t.height + 6, width: g.width, height: g.height),
                CGRect(x: m + t.width + 8, y: m, width: p.width, height: p.height))
    }

    private func before(_ c: Case, scale: CGFloat) throws -> CGImage {
        let v = c.viewport
        if c.photo {
            let model = PlazaOverlayModel(); model.isPhotoMode = true
            return try XCTUnwrap(K.render(LegacyPlazaPhotoFrame(model: model).frame(width: v.width, height: v.height), scale: scale))
        }
        let bg = PlazaBackgroundModel(); bg.isHidden = c.hidden
        let gm = PlazaShortcutGuideModel(); gm.isFolded = c.folded; gm.season = c.season
        let nm = PlazaNameColorModel(); nm.isOpen = c.open; nm.current = PlazaNameColor.hexes[c.selected]
        let f = swiftUIFrames(c)
        let ctx = K.context(Int(v.width * scale), Int(v.height * scale))
        func put<V: View>(_ view: V, _ r: CGRect) throws {
            // The hosting view centres its content in its frame; rendering the view in a frame of that size does the same.
            let image = try XCTUnwrap(K.render(view.frame(width: r.width, height: r.height), scale: scale))
            ctx.draw(image, in: CGRect(x: r.minX * scale, y: (v.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale))
        }
        if c.parts.contains("guide") { try put(LegacyPlazaShortcutGuide(model: gm, toggle: {}), f.guide) }
        if c.parts.contains("toggle") { try put(LegacyPlazaBackgroundToggle(model: bg, toggle: {}), f.toggle) }
        if c.parts.contains("picker") { try put(LegacyPlazaNameColorPicker(model: nm, toggle: {}, choose: { _ in }), f.picker) }
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: after: the panels through their hosts

    @MainActor private final class Shell: PlazaPanelHost {
        var hosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) { hosts[id]?.show(drawing: drawing, frame: frame, scale: scale) }
        func hide(_ id: PlazaPanelID) { hosts[id]?.hide() }
    }

    private func after(_ c: Case, scale: CGFloat) throws -> CGImage {
        let bg = PlazaBackgroundModel(); bg.isHidden = c.hidden
        let gm = PlazaShortcutGuideModel(); gm.isFolded = c.folded; gm.season = c.season
        let nm = PlazaNameColorModel(); nm.isOpen = c.open; nm.current = PlazaNameColor.hexes[c.selected]
        let om = PlazaOverlayModel(); om.isPhotoMode = c.photo
        let toggle = PlazaBackgroundTogglePanel(model: bg)
        let panels: [any PlazaPanel] = [PlazaPhotoFramePanel(model: om), PlazaShortcutGuidePanel(model: gm, toggle: toggle), toggle,
                                        PlazaNameColorPickerPanel(model: nm, toggle: toggle, background: bg)]
        let hud = PlazaHUD(panels: panels.filter { p in
            switch p.id { case .shortcuts: c.parts.contains("guide"); case .backgroundToggle: c.parts.contains("toggle")
            case .nameColorPicker: c.parts.contains("picker"); default: true }
        }, graphics: graphics)
        let container = NSView(frame: NSRect(origin: .zero, size: c.viewport))
        let shell = Shell()
        var hosts: [PlazaPanelHostView] = []
        for p in hud.panels {
            let h = PlazaPanelHostView(hud: hud, panel: p.id)
            h.frame = container.bounds
            container.addSubview(h)
            hosts.append(h)
            shell.hosts[p.id] = h
        }
        hud.setViewport(c.viewport, scale: scale)
        hud.host = shell
        let ctx = K.context(Int(c.viewport.width * scale), Int(c.viewport.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        for h in hosts { try XCTUnwrap(h.layer).render(in: ctx) }
        return try XCTUnwrap(ctx.makeImage())
    }

    static let cases: [Case] = [
        Case(name: "toggle-hide", parts: ["toggle"]), Case(name: "toggle-show", hidden: true, parts: ["toggle"]),
        Case(name: "guide-open-winter", parts: ["toggle", "guide"]), Case(name: "guide-open-summer", season: .summer, parts: ["toggle", "guide"]),
        Case(name: "guide-folded", folded: true, parts: ["toggle", "guide"]),
        Case(name: "picker-closed", parts: ["toggle", "picker"]), Case(name: "picker-open-0", open: true, selected: 0, parts: ["toggle", "picker"]),
        Case(name: "picker-open-5", open: true, selected: 5, parts: ["toggle", "picker"]),
        Case(name: "picker-open-11", open: true, selected: 11, parts: ["toggle", "picker"]),
        Case(name: "toggle-show+picker", hidden: true, open: true, selected: 3, parts: ["toggle", "picker"]),
        Case(name: "photo-600", viewport: CGSize(width: 600, height: 372), photo: true, parts: []),
        Case(name: "photo-1280", viewport: CGSize(width: 1280, height: 800), photo: true, parts: []),
        Case(name: "minimum-600-guide", viewport: CGSize(width: 600, height: 372)),
    ]

    /// The panels sit where SwiftUI's hosting views did: the frames SwiftUI measured (toggle 108×26 or ×25 with `eye`, guide
    /// 64×26 folded, 112×326 open, picker 75×24 / 180×98) are the panels' frames less the stroke room, in both states, with
    /// the guide 6 under the toggle and the picker 8 beside it. Pinned numbers are what the SwiftUI views measured.
    func testPanelFramesAreTheHostingViewFramesSwiftUIHad() async throws {
        for c in Self.cases where !c.photo {
            for scale in [CGFloat(1), 2] {
                let f = swiftUIFrames(c)
                let bg = PlazaBackgroundModel(); bg.isHidden = c.hidden
                let gm = PlazaShortcutGuideModel(); gm.isFolded = c.folded; gm.season = c.season
                let nm = PlazaNameColorModel(); nm.isOpen = c.open
                let toggle = PlazaBackgroundTogglePanel(model: bg)
                let panels: [any PlazaPanel] = [PlazaShortcutGuidePanel(model: gm, toggle: toggle), toggle,
                                                PlazaNameColorPickerPanel(model: nm, toggle: toggle, background: bg)]
                let frames = PlazaHUD(panels: panels, graphics: graphics).layout(viewport: c.viewport, scale: scale)
                let room = PlazaPanelStyle.strokeRoom
                XCTAssertEqual(frames[.backgroundToggle]?.insetBy(dx: room, dy: room), f.toggle, "\(c.name) toggle @\(scale)")
                XCTAssertEqual(frames[.shortcuts]?.insetBy(dx: room, dy: room), f.guide, "\(c.name) guide @\(scale)")
                XCTAssertEqual(frames[.nameColorPicker]?.insetBy(dx: room, dy: room), f.picker, "\(c.name) picker @\(scale)")
            }
        }
        let hide = swiftUIFrames(Case(name: "hide")), show = swiftUIFrames(Case(name: "show", hidden: true))
        XCTAssertEqual(hide.toggle.size, CGSize(width: 108, height: 26), "pinned: SwiftUI's toggle host, background shown")
        XCTAssertEqual(show.toggle.size, CGSize(width: 108, height: 25), "pinned: eye instead of eye.slash is a point shorter")
        XCTAssertEqual(hide.guide.minY, 46, "pinned: the guide sits 46 points under the top")
        XCTAssertEqual(show.guide.minY, 45)
        XCTAssertEqual(hide.picker.minX, 130)
        XCTAssertEqual(swiftUIFrames(Case(name: "f", folded: true)).guide.size, CGSize(width: 64, height: 26))
        XCTAssertEqual(hide.guide.size, CGSize(width: 112, height: 326))
        XCTAssertEqual(hide.picker.size, CGSize(width: 75, height: 24))
        XCTAssertEqual(swiftUIFrames(Case(name: "o", open: true)).picker.size, CGSize(width: 180, height: 98))
    }

    /// The pixels in a window against SwiftUI's at 1x and 2x: only antialiasing differs (the bounds are what the first run
    /// measured, and a regression in a position or size shows as a jump).
    func testPanelsLookLikeTheirSwiftUIOriginals() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let d = K.diff(try before(c, scale: scale), try after(c, scale: scale))
                let area = Int(c.viewport.width * c.viewport.height * scale * scale)
                XCTAssertLessThan(d.over64, c.photo ? area / 40 : 2500, "\(c.name)@\(scale): \(d.over64) pixels off by more than 64")
                XCTAssertLessThan(d.over8, c.photo ? area / 30 : 6500, "\(c.name)@\(scale): \(d.over8) pixels off by more than 8")
            }
        }
    }

    /// Writes before/after PNGs (over the plaza map and over a checkerboard, for a transparent background), diffs and one
    /// contact sheet into `PTB_PLAZA_HUD_OUT`.
    func testWriteControlImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        func background(_ v: CGSize, _ scale: CGFloat) -> CGImage {
            let ctx = K.context(Int(v.width * scale), Int(v.height * scale))
            ctx.interpolationQuality = .none
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: v.height * scale - size.height + 300 * scale, width: size.width, height: size.height))
            return ctx.makeImage()!
        }
        var summary: [String] = [], rows: [(label: String, cells: [CGImage])] = []
        for c in Self.cases {
            for scale in [CGFloat(2), 1] {
                let b = try before(c, scale: scale), a = try after(c, scale: scale)
                let crop = c.photo ? CGRect(origin: .zero, size: c.viewport)
                                   : CGRect(x: 0, y: 0, width: min(c.viewport.width, 330), height: min(c.viewport.height, c.open ? 160 : 360))
                let tag = "\(c.name)@\(Int(scale))x"
                let bg = background(c.viewport, scale)
                let zoom = c.photo ? 1 : (scale == 1 ? 2 : 1)
                let cells = [K.cell(b, crop: crop, scale: scale, background: bg, zoom: zoom), K.cell(a, crop: crop, scale: scale, background: bg, zoom: zoom),
                             K.cell(b, crop: crop, scale: scale, background: nil, zoom: zoom), K.cell(a, crop: crop, scale: scale, background: nil, zoom: zoom)]
                let d = K.diff(K.cell(b, crop: crop, scale: scale, background: nil, zoom: 1), K.cell(a, crop: crop, scale: scale, background: nil, zoom: 1))
                try K.write(cells[0], out.appendingPathComponent("before-\(tag)-default.png"))
                try K.write(cells[1], out.appendingPathComponent("after-\(tag)-default.png"))
                try K.write(cells[2], out.appendingPathComponent("before-\(tag)-transparent.png"))
                try K.write(cells[3], out.appendingPathComponent("after-\(tag)-transparent.png"))
                try K.write(d.image, out.appendingPathComponent("diff-\(tag).png"))
                let line = "\(tag): pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
                summary.append(line)
                let zoomed = K.cell(d.image, crop: CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / scale, height: CGFloat(d.image.height) / scale),
                                    scale: scale, background: nil, zoom: zoom)
                rows.append((line, cells + [zoomed]))
            }
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try K.write(K.sheet(rows, columns: ["before · plaza", "after · plaza", "before · transparent", "after · transparent",
                                            "diff (magenta: a channel off by more than 8)"]), out.appendingPathComponent("contact-sheet.png"))
    }
}
