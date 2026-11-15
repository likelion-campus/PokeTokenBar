import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// Shared pieces of the Mac render tests of the roster, board and card panels (Track A Tasks 17c-d): the "before" is the
/// real SwiftUI view in a hosting view inside a never-shown window (`ScaledWindow`, defined with the chat log tests) at a
/// forced backing scale, the "after" the panel through the host's layers; sample pictures that stand in for the downloaded
/// ones; and a URL protocol that refuses every request so no test reaches the network.
@MainActor enum ContentRig {
    typealias K = PlazaPanelRenderTests

    /// A host per panel, as `PlazaMacWindow` makes them.
    @MainActor final class Shell: PlazaPanelHost {
        var hosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) { hosts[id]?.show(drawing: drawing, frame: frame, scale: scale) }
        func hide(_ id: PlazaPanelID) { hosts[id]?.hide() }
    }

    @MainActor final class After {
        let hud: PlazaHUD, host: PlazaPanelHostView, container: NSView, shell = Shell(), id: PlazaPanelID
        init(_ panel: any PlazaPanel, viewport: CGSize, scale: CGFloat, graphics: any PlazaGraphics = PlatformPlaza.graphics) {
            id = panel.id
            hud = PlazaHUD(panels: [panel], graphics: graphics)
            container = NSView(frame: CGRect(origin: .zero, size: viewport))
            host = PlazaPanelHostView(hud: hud, panel: panel.id)
            host.frame = container.bounds
            container.addSubview(host)
            shell.hosts[panel.id] = host
            hud.setViewport(viewport, scale: scale)
            hud.host = shell
        }
        func image(_ viewport: CGSize, scale: CGFloat) throws -> CGImage {
            let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            try XCTUnwrap(host.layer).render(in: ctx)
            return try XCTUnwrap(ctx.makeImage())
        }
        var frame: CGRect? { hud.layout(viewport: hud.viewport, scale: hud.scale)[id] }
    }

    /// The SwiftUI view in a never-shown window; `image` is the whole window (top-left origin, as the panels' windows are).
    @MainActor final class Before<V: View> {
        let host: NSHostingView<V>, window: ScaledWindow, viewport: CGSize, scale: CGFloat
        /// `placed`: where the hosting view sits in the window (top-left origin) given its fitting size.
        init(_ view: V, viewport: CGSize, scale: CGFloat, fill: Bool = false) {
            host = NSHostingView(rootView: view)
            self.viewport = viewport
            self.scale = scale
            window = ScaledWindow(scale: scale, size: viewport)
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: fill ? viewport : host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        var size: CGSize { host.fittingSize }
        func capture() throws -> CGImage {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.cgImage)
        }
        /// The captured view drawn at `origin` (points, top-left) in a window-sized image.
        func placed(at origin: CGPoint) throws -> CGImage {
            let shown = try capture()
            let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            let s = CGSize(width: CGFloat(shown.width), height: CGFloat(shown.height))
            ctx.draw(shown, in: CGRect(x: origin.x * scale, y: viewport.height * scale - origin.y * scale - s.height, width: s.width, height: s.height))
            return try XCTUnwrap(ctx.makeImage())
        }
    }

    /// The view as `ImageRenderer` draws it, `viewport` big (top-left origin), and, over `patch` (points), the pixels of `hosted`.
    /// A hosting view captured with `cacheDisplay` draws SwiftUI's `.shadow(y:)` upside down (measured by
    /// `testWhereSwiftUIPutsTheTextShadow`: up where the real one is down), so everything but the scroll view, which only a
    /// window draws, comes from `ImageRenderer`.
    static func renderedWithPatch<V: View>(_ view: V, viewport: CGSize, scale: CGFloat, hosted: CGImage, patch: CGRect) throws -> CGImage {
        let base = try XCTUnwrap(K.render(view.frame(width: viewport.width, height: viewport.height), scale: scale))
        let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: patch.minX * scale, y: (viewport.height - patch.maxY) * scale, width: patch.width * scale, height: patch.height * scale))
        ctx.setBlendMode(.copy)
        ctx.draw(hosted, in: CGRect(x: 0, y: 0, width: hosted.width, height: hosted.height))
        ctx.restoreGState()
        return try XCTUnwrap(ctx.makeImage())
    }

    static func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: sample pictures

    /// A 40x30 sample box icon whose colours follow `id` (a test fixture, not game art): a block with transparent margins and
    /// a notch, so scaling and edges show.
    static func iconData(_ id: Int, size: CGSize = CGSize(width: 40, height: 30)) -> Data {
        let w = Int(size.width), h = Int(size.height)
        let ctx = K.context(w, h)
        let r = CGFloat((id * 53) % 200 + 40) / 255, g = CGFloat((id * 97) % 200 + 40) / 255, b = CGFloat((id * 31) % 200 + 40) / 255
        // CGContext rows count from the bottom: the notch is at the top right.
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 4, y: 3, width: w - 8, height: h - 6))
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 5, y: 4, width: w - 10, height: h - 8))
        ctx.clear(CGRect(x: w - 14, y: h - 10, width: 10, height: 7))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    /// Puts sample icons for `ids` in `PlazaIconLoader`'s memory (what both the view and the panel read).
    static func seedIcons(_ ids: [Int]) async {
        for id in ids { _ = await PlazaIconLoader.icon(speciesID: id, load: { Self.iconData($0) }) }
    }

    /// Puts a sample card picture for `speciesID` in `SpriteLoader`'s memory cache (the key the loader reads).
    static func seedSprite(_ id: Int, shiny: Bool = false, form: PokemonForm? = nil) {
        let key = SpriteStore.cacheKey(speciesID: id, animated: false, shiny: shiny, form: form, back: false)
        let path = SpriteStore.shared.directory.appendingPathComponent("\(key).png").path as NSString
        SpriteLoader.imageCache.setObject(NSImage(data: iconData(id, size: CGSize(width: 96, height: 96)))!, forKey: path)
    }

    /// Refuses every request, so the views' own loads fail at once instead of reaching the network.
    final class NoNetwork: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
    /// Registered for `test` only: the shared session consults `registerClass` process-wide, so a leftover registration
    /// refuses every later suite's loopback request (`-1009`, RedirectHeadersMacTests in the full run).
    static func blockNetwork(for test: XCTestCase) {
        URLProtocol.registerClass(NoNetwork.self)
        test.addTeardownBlock { URLProtocol.unregisterClass(NoNetwork.self) }
    }

    // MARK: images

    /// Writes, for each (tag, scale, before, after, crop) in `shots`: before/after PNGs over the plaza map ("default") and a
    /// checkerboard ("transparent"), the diff, `summary.txt` and one contact sheet into `dir`. `only` (comma separated tag
    /// prefixes, from `PTB_PLAZA_ONLY`) limits the cases.
    struct Shot { var tag: String, scale: CGFloat, before: CGImage, after: CGImage, crop: CGRect, viewport: CGSize }

    static func write(_ shots: [Shot], to dir: String) throws {
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        func background(_ v: CGSize, _ scale: CGFloat) -> CGImage {
            let ctx = K.context(Int(v.width * scale), Int(v.height * scale))
            ctx.interpolationQuality = .none
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            ctx.draw(map.cgImage, in: CGRect(x: -300 * scale, y: v.height * scale - size.height + 200 * scale, width: size.width, height: size.height))
            return ctx.makeImage()!
        }
        var summary: [String] = [], rows: [(label: String, cells: [CGImage])] = []
        for s in shots {
            let bg = background(s.viewport, s.scale)
            let zoom = s.scale == 1 ? 2 : 1
            let cells = [K.cell(s.before, crop: s.crop, scale: s.scale, background: bg, zoom: zoom), K.cell(s.after, crop: s.crop, scale: s.scale, background: bg, zoom: zoom),
                         K.cell(s.before, crop: s.crop, scale: s.scale, background: nil, zoom: zoom), K.cell(s.after, crop: s.crop, scale: s.scale, background: nil, zoom: zoom)]
            let d = K.diff(K.cell(s.before, crop: s.crop, scale: s.scale, background: nil, zoom: 1), K.cell(s.after, crop: s.crop, scale: s.scale, background: nil, zoom: 1))
            let tag = "\(s.tag)@\(Int(s.scale))x"
            try K.write(cells[0], out.appendingPathComponent("before-\(tag)-default.png"))
            try K.write(cells[1], out.appendingPathComponent("after-\(tag)-default.png"))
            try K.write(cells[2], out.appendingPathComponent("before-\(tag)-transparent.png"))
            try K.write(cells[3], out.appendingPathComponent("after-\(tag)-transparent.png"))
            try K.write(d.image, out.appendingPathComponent("diff-\(tag).png"))
            let line = "\(tag): pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
            summary.append(line)
            let zoomed = K.cell(d.image, crop: CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / s.scale, height: CGFloat(d.image.height) / s.scale),
                                scale: s.scale, background: nil, zoom: zoom)
            rows.append((line, cells + [zoomed]))
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try K.write(K.sheet(rows, columns: ["before · plaza", "after · plaza", "before · transparent", "after · transparent",
                                            "diff (magenta: a channel off by more than 8)"]), out.appendingPathComponent("contact-sheet.png"))
    }

    static func only(_ name: String) -> Bool {
        guard let f = ProcessInfo.processInfo.environment["PTB_PLAZA_ONLY"], !f.isEmpty else { return true }
        return f.split(separator: ",").contains { name.hasPrefix($0) }
    }
}
