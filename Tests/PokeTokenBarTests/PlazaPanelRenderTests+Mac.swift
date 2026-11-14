import XCTest
import AppKit
import SwiftUI
import CoreText
@testable import PokeTokenBar

/// The canvas-drawn pills and clock (Track A Task 14) against the SwiftUI views they replace (`Legacy/LegacyPlazaHUDViews`,
/// verbatim): the same frames in the window, the same wrapping and cutting, and the host view's behaviour (no clicks, no
/// keys, the image at its frame, its place among the window's views). With `PTB_PLAZA_HUD_OUT` set it also writes the
/// before/after images for the PR into that directory. Real CoreText; nothing is shown on screen.
@MainActor final class PlazaPanelRenderTests: XCTestCase {
    private let graphics = PlatformPlaza.graphics
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    // MARK: pixels

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Premultiplied sRGB RGBA, row 0 at the top.
    private static func rgba(_ image: CGImage) -> [UInt8] {
        let ctx = context(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    /// The pixel boxes of what is drawn (any alpha), one per run of rows with ink: the pills are 8 points apart.
    private static func boxes(_ image: CGImage) -> [CGRect] {
        let px = rgba(image), w = image.width, h = image.height
        func ink(_ x: Int, _ y: Int) -> Bool { px[(y * w + x) * 4 + 3] > 0 }
        var result: [CGRect] = []
        var y = 0
        while y < h {
            guard (0..<w).contains(where: { ink($0, y) }) else { y += 1; continue }
            let y0 = y
            var x0 = w, x1 = 0
            while y < h, (0..<w).contains(where: { ink($0, y) }) {
                for x in 0..<w where ink(x, y) { x0 = min(x0, x); x1 = max(x1, x + 1) }
                y += 1
            }
            result.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y - y0))
        }
        return result
    }

    private static func render<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.cgImage
    }

    // MARK: the two layouts

    private func model(countdown: String? = nil, banner: String? = nil, hint: String? = nil) -> PlazaOverlayModel {
        let m = PlazaOverlayModel()
        m.countdown = countdown
        m.banner = banner
        m.hint = hint
        return m
    }

    /// The SwiftUI pills in a window of `viewport` points: each pill's frame (points, its stroke not included).
    private func swiftUIPills(_ m: PlazaOverlayModel, viewport: CGSize, scale: CGFloat) throws -> [CGRect] {
        let image = try XCTUnwrap(Self.render(LegacyPlazaPills(model: m).frame(width: viewport.width, height: viewport.height), scale: scale))
        // Strokes are centred on the edge: 1 point (2 / 2, and 1.5 / 2 rounded out to whole pixels) outside it.
        return Self.boxes(image).map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale)
            .insetBy(dx: 1, dy: 1) }
    }

    /// The panel's pills in the same window: the HUD's frame for the panel, then each pill in it.
    private func panelPills(_ m: PlazaOverlayModel, viewport: CGSize, scale: CGFloat) throws -> [CGRect] {
        let panel = PlazaPillsPanel(model: m)
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let frame = try XCTUnwrap(hud.layout(viewport: viewport, scale: scale)[.pills])
        let room = PlazaPanelStyle.strokeRoom
        return panel.stack(in: viewport, scale: scale, text: graphics.text).pills.map {
            $0.frame.offsetBy(dx: frame.minX + room, dy: frame.minY + room)
        }
    }

    private static let all = (countdown: "단체 사진 5 · P를 누르면 함께 찍어요", banner: "사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기",
                              hint: "스페이스바를 눌러 소식판 보기")
    private static let longName = "가나다라마바사아자차카타"   // 12 characters, the longest nickname
    private static let banners = [
        "피카츄님이 이상해씨를 잡았어요! 🎉",
        "📢 \(longName): 오늘 점심은 다 같이 광장 앞 분식집에서 떡볶이 먹으러 가요 늦지 마세요 다들 꼭 와요 ㅎㅎ",
        "\(longName)님이 \(longName)의 메타몽을 찾았어요!",
        "📢 \(longName): 띄어쓰기없이아주길게쓴한줄짜리채팅메시지가배너에서어떻게줄바꿈되는지보는문장입니다",
        "📢 🐱🐶🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵: 🎉🎉🎉 축하해요 🎂🎈🎁 ✨✨✨ 👍👍👍 💯💯💯",
        "📢 مرحبا: שלום עולם مرحبا بالعالم هذا نص طويل للاختبار שלום שוב",
        "📢 Alexander: Supercalifragilisticexpialidocious-is-a-very-long-word-without-spaces ok",
    ]

    /// Measured once from the SwiftUI views (scale 2) and pinned: the pills' frames for the full stack, and the clock's.
    func testPanelsAreAnchoredLikeTheirConstraints() async throws {
        let m = model(countdown: Self.all.countdown, banner: Self.all.banner, hint: Self.all.hint)
        for viewport in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640)] {
            for scale in [CGFloat(1), 2] {
                let swiftUI = try swiftUIPills(m, viewport: viewport, scale: scale)
                XCTAssertEqual(try panelPills(m, viewport: viewport, scale: scale), swiftUI, "pills \(viewport)@\(scale)")
            }
        }
        // Pinned: what the SwiftUI views measured (Track A Task 14), so a change on either side shows here first.
        let pinned: [CGFloat: [CGRect]] = [
            600: [CGRect(x: 155, y: 14, width: 290, height: 34), CGRect(x: 120, y: 56, width: 360, height: 34),
                  CGRect(x: 181.5, y: 98, width: 237, height: 30)],
            960: [CGRect(x: 335, y: 14, width: 290, height: 34), CGRect(x: 300, y: 56, width: 360, height: 34),
                  CGRect(x: 361.5, y: 98, width: 237, height: 30)],
        ]
        for viewport in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640)] {
            XCTAssertEqual(try panelPills(m, viewport: viewport, scale: 2), pinned[viewport.width], "pinned \(viewport)")
            var oneX = try XCTUnwrap(pinned[viewport.width])
            oneX[2].origin.x += 0.5   // 1x: the half point rounds up
            XCTAssertEqual(try panelPills(m, viewport: viewport, scale: 1), oneX, "pinned \(viewport)@1")
        }
        // The clock: its hosting view's size, on the minimap's top edge, trailing edges aligned.
        let clockModel = PlazaMinimapModel()
        let date = Self.date(hour: 21, minute: 34)
        let fitting = NSHostingView(rootView: LegacyPlazaClock(model: clockModel, date: date)).fittingSize
        let map = NSHostingView(rootView: PlazaMinimapView(model: PlazaMinimapModel(), mapImage: NSImage(size: NSSize(width: 1, height: 1)),
                                                           worldSize: PlazaMapData.map.pixelSize)).fittingSize
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update(PlazaDaylight.clockText(date, core: clockModel.coreTime))
        let hud = PlazaHUD(panels: [clock], graphics: graphics)
        XCTAssertEqual(fitting, CGSize(width: 67, height: 24), "pinned: the clock's hosting view")
        XCTAssertEqual(map.height, 136, "pinned: the minimap's hosting view")
        for (viewport, origin) in [(CGSize(width: 600, height: 372), CGPoint(x: 519, y: 190)), (CGSize(width: 960, height: 640), CGPoint(x: 879, y: 458))] {
            let swiftUI = CGRect(x: viewport.width - PlazaRosterMetrics.margin - fitting.width,
                                 y: viewport.height - 16 - map.height - 6 - fitting.height, width: fitting.width, height: fitting.height)
            XCTAssertEqual(swiftUI.origin, origin, "pinned \(viewport)")
            for scale in [CGFloat(1), 2] {
                let panel = try XCTUnwrap(hud.layout(viewport: viewport, scale: scale)[.clock]).insetBy(dx: 1, dy: 1)
                XCTAssertEqual(panel, swiftUI, "clock \(viewport)@\(scale)")
            }
        }
    }

    /// The panel's pills as the window shows them, through the host: its layer tree rendered off screen.
    private func panelWindow(_ m: PlazaOverlayModel, viewport: CGSize, scale: CGFloat) throws -> CGImage {
        try throughHosts([PlazaPillsPanel(model: m)], viewport: viewport, scale: scale)
    }

    /// `panels` shown by their hosts in a container of `viewport` points, and the hosts' layer trees rendered off screen
    /// (`CALayer.render(in:)`, no window) at `scale`, bottom host first: what the window composites.
    private func throughHosts(_ panels: [any PlazaPanel], viewport: CGSize, scale: CGFloat) throws -> CGImage {
        let (hud, hosts, _) = hostWithPanels(panels, size: viewport)
        let shell = Shell()
        for h in hosts { shell.hosts[h.panelID] = h }
        hud.setViewport(viewport, scale: scale)
        hud.host = shell
        let ctx = Self.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        for h in hosts { try XCTUnwrap(h.layer).render(in: ctx) }
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The panels' drawings composed by hand at their HUD frames: the expectation for `throughHosts`.
    private func composed(_ panels: [any PlazaPanel], viewport: CGSize, scale: CGFloat) throws -> CGImage {
        let hud = PlazaHUD(panels: panels, graphics: graphics)
        let frames = hud.layout(viewport: viewport, scale: scale)
        let ctx = Self.context(Int(viewport.width * scale), Int(viewport.height * scale))
        for panel in panels {
            let f = try XCTUnwrap(frames[panel.id])
            for layer in panel.render(scale: scale, viewport: viewport, graphics: graphics).layers {
                func bottomLeft(_ r: CGRect) -> CGRect {
                    let w = r.offsetBy(dx: f.minX, dy: f.minY)
                    return CGRect(x: w.minX * scale, y: (viewport.height - w.maxY) * scale, width: w.width * scale, height: w.height * scale)
                }
                switch layer {
                case .image(let image, let r): ctx.draw(image.cgImage, in: bottomLeft(r))
                case .color(let c, let r): ctx.setFillColor(c.cgColor); ctx.fill(bottomLeft(r))
                }
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    /// For each 18-point text line of a banner pill: the first and last pixel column with ink (far from the pill's fill)
    /// in the line's middle 12 points (emoji are taller than a line and reach into the next one).
    private static func lineExtents(_ image: CGImage, pill: CGRect, scale: CGFloat) -> [ClosedRange<Int>?] {
        let px = rgba(image), w = image.width
        func at(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(px[(y * w + x) * 4 + $0]) } }
        let fill = at(Int((pill.minX + 4) * scale), Int(pill.midY * scale))
        let lines = Int((pill.height - 16) / 18)
        return (0..<lines).map { k in
            let top = pill.minY + 8 + CGFloat(18 * k)
            let y0 = Int((top + 3) * scale), y1 = Int((top + 15) * scale)
            let xs = Int((pill.minX + 2) * scale)..<Int((pill.maxX - 2) * scale)
            let ink = xs.filter { x in (y0..<y1).contains { y in zip(at(x, y), fill).contains { abs($0 - $1) > 96 } } }
            return ink.first.flatMap { first in ink.last.map { first...$0 } }
        }
    }

    /// Every banner wraps where SwiftUI's did (long Korean names — a Korean word stays whole —, no spaces, emoji,
    /// right-to-left, a long Latin word with hyphens): the pill is as tall and as wide, and every line spans the same
    /// columns within 3 pixels (a different break moves a line's ends by a glyph, 12 pixels or more; colour emoji are
    /// drawn a pixel higher than SwiftUI's, which moves their antialiased edges across the ink threshold).
    func testBannersWrapLikeSwiftUI() async throws {
        let viewport = CGSize(width: 600, height: 372)
        for banner in Self.banners {
            let m = model(banner: banner)
            let pills = try panelPills(m, viewport: viewport, scale: 2)
            XCTAssertEqual(pills, try swiftUIPills(m, viewport: viewport, scale: 2), banner)
            let pill = try XCTUnwrap(pills.first)
            let before = Self.lineExtents(try XCTUnwrap(Self.render(LegacyPlazaPills(model: m).frame(width: viewport.width, height: viewport.height),
                                                                    scale: 2)), pill: pill, scale: 2)
            let after = Self.lineExtents(try panelWindow(m, viewport: viewport, scale: 2), pill: pill, scale: 2)
            XCTAssertEqual(before.count, after.count, banner)
            for (b, a) in zip(before, after) {
                XCTAssertEqual(b?.lowerBound ?? -1, a?.lowerBound ?? -1, accuracy: 3, "\(banner): a line starts elsewhere")
                XCTAssertEqual(b?.upperBound ?? -1, a?.upperBound ?? -1, accuracy: 3, "\(banner): a line ends elsewhere")
            }
        }
    }

    /// A one-line pill too long for the window is cut like SwiftUI's `lineLimit(1)`: the same width.
    func testOneLinePillsCutLikeSwiftUI() async throws {
        let countdowns = ["\(Self.longName)님의 단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요", "🐱🐶🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵님의 단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요"]
        for text in countdowns {
            for m in [model(countdown: text), model(hint: text)] {
                let viewport = CGSize(width: 600, height: 372)
                XCTAssertEqual(try panelPills(m, viewport: viewport, scale: 2), try swiftUIPills(m, viewport: viewport, scale: 2), text)
            }
        }
    }

    // MARK: the host view

    private func hostWithPanels(_ panels: [any PlazaPanel], size: CGSize = CGSize(width: 960, height: 640)) -> (PlazaHUD, [PlazaPanelHostView], NSView) {
        let hud = PlazaHUD(panels: panels, graphics: graphics)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosts = panels.map { PlazaPanelHostView(hud: hud, panel: $0.id) }
        for h in hosts {
            h.frame = container.bounds
            container.addSubview(h)
        }
        return (hud, hosts, container)
    }

    @MainActor private final class Shell: PlazaPanelHost {
        var hosts: [PlazaPanelID: PlazaPanelHostView] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) {
            hosts[id]?.show(drawing: drawing, frame: frame, scale: scale)
        }
        func hide(_ id: PlazaPanelID) { hosts[id]?.hide() }
    }

    /// The pills and the clock take no clicks (the scene below gets them) and never the keyboard; the image is the layer's
    /// contents at the panel's frame, at the backing scale, magnified nearest.
    func testThePanelHostShowsTheImageAndTakesNoClicksOrKeys() async throws {
        let m = model(banner: "배너", hint: "안내")
        let pills = PlazaPillsPanel(model: m)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let (hud, hosts, container) = hostWithPanels([pills, clock])
        let shell = Shell()
        for h in hosts { shell.hosts[h.panelID] = h }
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        let frames = hud.layout(viewport: container.bounds.size, scale: 2)
        for host in hosts {
            let f = try XCTUnwrap(frames[host.panelID])
            XCTAssertEqual(host.panelLayersForTesting.count, 1, "one image")
            let layer = try XCTUnwrap(host.panelLayersForTesting.first)
            XCTAssertTrue(layer.superlayer === host.layer, "in the host's layer tree")
            XCTAssertFalse(layer.isHidden)
            XCTAssertNotNil(layer.contents)
            XCTAssertEqual(layer.contentsScale, 2)
            XCTAssertEqual(layer.magnificationFilter, .nearest)
            XCTAssertEqual(layer.frame, CGRect(x: f.minX, y: 640 - f.maxY, width: f.width, height: f.height), "bottom-left layer coordinates")
            let image = layer.contents as! CGImage
            XCTAssertEqual([image.width, image.height], [Int(f.width * 2), Int(f.height * 2)], "one image pixel per device pixel")
            XCTAssertFalse(host.acceptsFirstResponder)
            // The middle of the panel, in the container's (bottom-left) coordinates.
            XCTAssertNil(host.hitTest(NSPoint(x: f.midX, y: 640 - f.midY)), "\(host.panelID): clicks go through")
            XCTAssertTrue(container.hitTest(NSPoint(x: f.midX, y: 640 - f.midY)) === container, "to what is below the panels")
        }
        m.banner = nil
        m.hint = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(hosts[0].panelLayersForTesting.count, 0, "nothing to show: no layer")
        XCTAssertNil(hosts[0].layer?.sublayers?.first { $0.contents != nil }, "and no image left behind")
        // The host follows its own size: a taller window keeps a top panel's top edge.
        m.hint = "안내"
        for _ in 0..<20 { await Task.yield() }
        let top = try XCTUnwrap(hosts[0].panelFrame)
        container.setFrameSize(NSSize(width: 960, height: 700))
        for h in hosts { h.setFrameSize(NSSize(width: 960, height: 700)) }
        XCTAssertEqual(hosts[0].panelLayersForTesting.first?.frame.maxY, 700 - top.minY)
    }

    /// A panel with a button takes the click through its host, and only on the button; the click reaches the HUD.
    func testAnInteractivePanelTakesClicksThroughItsHost() async throws {
        let button = ButtonPanel()
        let (hud, hosts, container) = hostWithPanels([button])
        let shell = Shell()
        shell.hosts[button.id] = hosts[0]
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        // The button is the left half of a 40×20 panel at (10, 10) from the top left.
        XCTAssertTrue(container.hitTest(NSPoint(x: 15, y: 640 - 15)) === hosts[0])
        XCTAssertTrue(container.hitTest(NSPoint(x: 45, y: 640 - 15)) === container, "the other half lets the click through")
        var actions: [PlazaPanelHit] = []
        hud.onAction = { actions.append($1) }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 640 - 15), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        hosts[0].mouseDown(with: event(.leftMouseDown))
        hosts[0].mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(actions, [PlazaPanelHit(action: "toggle", index: nil)])
        window.contentView = nil
    }

    /// The pills' host sits right above the overlay and below the chat log; the clock's above the minimap and below the
    /// shortcut guide, where their SwiftUI hosting views were.
    func testPanelsBelowTheChatLogStayBelowIt() async throws {
        let name = "PlazaPanelRenderTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.panels.\(UUID())")),
                                      loader: PlazaCharacterLoader(fetcher: RenderTestNoSprites()),
                                      nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                                      shell: RecordingPlazaShell())
        c.prepareScene()
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("never brought forward") })
        shell.open(stage: try XCTUnwrap(c.scene).stage, title: "t", overlays: c.overlayBindings)
        let subs = try XCTUnwrap(shell.windowForTesting?.contentView).subviews
        func index<T>(_ type: T.Type) -> Int? { subs.firstIndex { $0 is T } }
        let pills = try XCTUnwrap(subs.firstIndex { ($0 as? PlazaPanelHostView)?.panelID == .pills })
        let clock = try XCTUnwrap(subs.firstIndex { ($0 as? PlazaPanelHostView)?.panelID == .clock })
        XCTAssertEqual(pills, try XCTUnwrap(index(PlazaOverlayHostingView.self)) + 1, "right above the overlay")
        XCTAssertLessThan(pills, try XCTUnwrap(index(PlazaChatLogHostingView.self)), "below the chat log")
        XCTAssertEqual(clock, try XCTUnwrap(index(PlazaMinimapHostingView.self)) + 1, "right above the minimap")
        XCTAssertLessThan(clock, try XCTUnwrap(index(PlazaShortcutGuideHostingView.self)))
        XCTAssertTrue(c.hud.host === shell, "the window shows the controller's panels")
        XCTAssertEqual(c.hud.renderCounts[.clock], 1, "the clock is drawn once on opening")
        shell.stopPresenting()
        shell.dismantle()
        XCTAssertNil(c.hud.host)
        c.handleClose()
    }

    /// The SwiftUI overlay still opens a member menu below the pills, as when they were in its stack: the menu moves down
    /// by the pills' height and the 8-point gap (a banner: 34 + 8; a countdown and a banner: 2 × (34 + 8)).
    func testAMenuStillOpensBelowThePills() async throws {
        func menuTop(countdown: String?, banner: String?) throws -> Int {
            let m = model(countdown: countdown, banner: banner)
            m.content = .memberMenu(PlazaMemberMenu(memberID: "m", nickname: "민수"))
            let pills = PlazaPillsPanel(model: m)
            let viewport = CGSize(width: 600, height: 372)
            let view = PlazaOverlayView(model: m, pillsSize: { pills.stack(in: viewport, scale: 2, text: PlatformPlaza.graphics.text).size })
            let image = try XCTUnwrap(Self.render(view.frame(width: viewport.width, height: viewport.height), scale: 2))
            return Int(try XCTUnwrap(Self.boxes(image).first).minY)   // the pills are not in the overlay: the menu is its first ink
        }
        let alone = try menuTop(countdown: nil, banner: nil)
        XCTAssertEqual(try menuTop(countdown: nil, banner: "배너") - alone, 2 * (34 + 8))
        XCTAssertEqual(try menuTop(countdown: "단체 사진 5", banner: "배너") - alone, 2 * (34 + 8 + 34 + 8))
    }

    /// A host's frame is the window's (four constraints, no intrinsic size): a panel growing and shrinking — a banner of
    /// one line and of three, a countdown coming and going, the clock's text getting wider — only moves and resizes the
    /// host's layer, so the hosts are not laid out again per change and never ask for an intrinsic size. (On `main` the
    /// roster's hosting view, sized by its content, crashed AppKit by re-invalidating inside the constraint pass.)
    func testPanelSizeChangesDoNotRelayoutTheirHosts() async throws {
        let name = "PlazaPanelRenderTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.panels.\(UUID())")),
                                      loader: PlazaCharacterLoader(fetcher: RenderTestNoSprites()),
                                      nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                                      shell: RecordingPlazaShell())
        c.prepareScene()
        let shell = PlazaMacWindow(autosaveName: name, front: { _ in XCTFail("never brought forward") })
        let overlays = c.overlayBindings
        shell.open(stage: try XCTUnwrap(c.scene).stage, title: "t", overlays: overlays)
        let container = try XCTUnwrap(shell.windowForTesting?.contentView)
        container.layoutSubtreeIfNeeded()
        let hosts = container.subviews.compactMap { $0 as? PlazaPanelHostView }
        XCTAssertEqual(hosts.map(\.panelID), [.pills, .clock])
        let clock = try XCTUnwrap(c.hud.panels.first { $0.id == .clock } as? PlazaClockPanel)
        for host in hosts {
            XCTAssertEqual(host.intrinsicContentSize, NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))
            XCTAssertEqual(host.frame, container.bounds)
        }
        let passes = hosts.map(\.layoutPassesForTesting), invalidations = hosts.map(\.intrinsicInvalidationsForTesting)
        var sizes: [PlazaPanelID: Set<CGFloat>] = [:]
        for i in 0..<12 {
            overlays.overlayModel.banner = i % 2 == 0 ? "짧은 배너" : Self.banners[1]
            overlays.overlayModel.countdown = i % 3 == 0 ? "단체 사진 \(i)" : nil
            clock.update(i % 2 == 0 ? "밤 21:34" : "새벽 0:00 · 아주 긴 시계")
            for _ in 0..<20 { await Task.yield() }
            container.layoutSubtreeIfNeeded()
            for host in hosts {
                XCTAssertEqual(host.frame, container.bounds, "the host keeps the window's frame")
                if let f = host.panelFrame { sizes[host.panelID, default: []].insert(f.height * 1000 + f.width) }
            }
        }
        XCTAssertGreaterThanOrEqual(sizes[.pills]?.count ?? 0, 3, "the pills really changed size")
        XCTAssertEqual(sizes[.clock]?.count, 2, "the clock really changed size")
        for (i, host) in hosts.enumerated() {
            XCTAssertLessThanOrEqual(host.layoutPassesForTesting - passes[i], 1, "\(host.panelID): no layout pass per change")
            XCTAssertEqual(host.intrinsicInvalidationsForTesting, invalidations[i], "\(host.panelID): a change never asks for an intrinsic size")
            XCTAssertEqual(host.intrinsicInvalidationsInLayoutForTesting, 0, "\(host.panelID): nothing invalidates inside a layout pass")
        }
        shell.stopPresenting()
        shell.dismantle()
        c.handleClose()
    }

    // MARK: the host: drawing, VoiceOver, mouse (fix round)

    /// What the window composites — the hosts' layer trees, rendered off screen — is the panels' drawings at their HUD
    /// frames, upright: the pills, the clock and a full-window dim with brackets (colour layers and small images).
    func testTheHostDrawsThePanelsWhereTheyBelong() async throws {
        let m = model(countdown: Self.all.countdown, banner: Self.all.banner, hint: Self.all.hint)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        for scale in [CGFloat(1), 2] {
            let viewport = CGSize(width: 600, height: 372)
            let panels: [any PlazaPanel] = [DimPanel(), PlazaPillsPanel(model: m), clock]
            let host = Self.rgba(try throughHosts(panels, viewport: viewport, scale: scale))
            let expected = Self.rgba(try composed(panels, viewport: viewport, scale: scale))
            let worst = zip(host, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "@\(scale): the host shows the drawings unmoved, unflipped, unscaled")
            // Upright: the countdown pill (the top one) is near the top of the window.
            let w = Int(viewport.width * scale)
            let topRow = Int(20 * scale), midX = w / 2
            XCTAssertGreaterThan(host[(topRow * w + midX) * 4 + 3], 200, "the top pill is at the top")
        }
    }

    /// Every sublayer the host makes has no implicit animation for what the host sets.
    func testTheHostNeverAnimatesItsLayers() async throws {
        let m = model(hint: "안내")
        let (hud, hosts, container) = hostWithPanels([DimPanel(), PlazaPillsPanel(model: m)])
        let shell = Shell()
        for h in hosts { shell.hosts[h.panelID] = h }
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        let layers = hosts.flatMap(\.panelLayersForTesting)
        XCTAssertGreaterThan(layers.count, 5, "colour and image layers")
        for layer in layers {
            for key in ["contents", "contentsScale", "position", "bounds", "hidden", "backgroundColor"] {
                // A sublayer of a view's layer animates these implicitly on screen unless its own actions say no (off
                // screen `action(forKey:)` finds nothing either way, so the table itself is checked).
                XCTAssertTrue(layer.actions?[key] is NSNull, "\(key) would animate")
                XCTAssertNil(layer.action(forKey: key))
            }
        }
    }

    /// A new backing scale (the window moved to another display) renders the panels again at that scale.
    func testANewBackingScaleRendersAgain() async throws {
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let (hud, hosts, container) = hostWithPanels([clock])
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil }
        let shell = Shell()
        shell.hosts[.clock] = hosts[0]
        hud.setViewport(container.bounds.size, scale: 7)   // as if the last display had been 7x
        hud.host = shell
        XCTAssertEqual(hosts[0].panelLayersForTesting.first?.contentsScale, 7)
        let before = hud.renderCounts[.clock] ?? 0
        hosts[0].viewDidChangeBackingProperties()
        XCTAssertEqual(hud.renderCounts[.clock], before + 1)
        XCTAssertEqual(hosts[0].panelLayersForTesting.first?.contentsScale, window.backingScaleFactor)
        XCTAssertEqual(hud.scale, window.backingScaleFactor)
    }

    /// VoiceOver finds the four texts as before: one static text per pill and one for the clock, read as their whole
    /// text, over each pill, in window coordinates; a pill that goes away leaves; a move announces nothing.
    func testVoiceOverReadsThePanels() async throws {
        let m = model(countdown: Self.all.countdown, banner: Self.all.banner, hint: Self.all.hint)
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let pills = PlazaPillsPanel(model: m)
        let (hud, hosts, container) = hostWithPanels([pills, clock])
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 960, height: 640), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil }
        let shell = Shell()
        for h in hosts { shell.hosts[h.panelID] = h }
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        func children(_ host: PlazaPanelHostView) -> [NSAccessibilityElement] { (host.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement } }
        func windowFrame(_ e: NSAccessibilityElement) -> CGRect { window.convertFromScreen(e.accessibilityFrame()) }
        XCTAssertFalse(hosts[0].isAccessibilityElement(), "the host is a container, not an element")
        let frames = hud.layout(viewport: container.bounds.size, scale: 2)
        let stack = pills.stack(in: container.bounds.size, scale: 2, text: graphics.text).pills
        let p = try XCTUnwrap(frames[.pills])
        XCTAssertEqual(children(hosts[0]).map { $0.accessibilityRole() }, [.staticText, .staticText, .staticText])
        XCTAssertEqual(children(hosts[0]).map { $0.accessibilityLabel() }, [Self.all.countdown, Self.all.banner, Self.all.hint])
        for (e, pill) in zip(children(hosts[0]), stack) {
            let f = pill.frame.offsetBy(dx: p.minX + 1, dy: p.minY + 1)
            XCTAssertEqual(windowFrame(e), CGRect(x: f.minX, y: 640 - f.maxY, width: f.width, height: f.height), "over the pill")
        }
        let c = try XCTUnwrap(frames[.clock])
        XCTAssertEqual(children(hosts[1]).map { $0.accessibilityLabel() }, ["밤 21:34"])
        XCTAssertEqual(children(hosts[1]).map(windowFrame), [CGRect(x: c.minX + 1, y: 640 - c.maxY + 1, width: c.width - 2, height: c.height - 2)])
        let announced = hosts[0].accessibilityChangesForTesting
        m.banner = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(children(hosts[0]).map { $0.accessibilityLabel() }, [Self.all.countdown, Self.all.hint], "the banner left")
        XCTAssertEqual(hosts[0].accessibilityChangesForTesting, announced + 1)
        container.setFrameSize(NSSize(width: 1000, height: 700))
        for h in hosts { h.setFrameSize(NSSize(width: 1000, height: 700)) }
        hud.setViewport(CGSize(width: 1000, height: 700), scale: 2)
        XCTAssertEqual(hosts[0].accessibilityChangesForTesting, announced + 1, "moving is no change to announce")
        let moved = try XCTUnwrap(hud.layout(viewport: CGSize(width: 1000, height: 700), scale: 2)[.pills])
        XCTAssertEqual(windowFrame(children(hosts[0])[0]).midX, moved.midX, accuracy: 0.5, "the elements moved with the pills")
        m.countdown = nil
        m.hint = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(children(hosts[0]).count, 0, "no pills, nothing to read")
    }

    /// VoiceOver's press on a button item goes where a click on it goes.
    func testAVoiceOverPressIsAClick() async throws {
        let button = ButtonPanel()
        let (hud, hosts, container) = hostWithPanels([button])
        let shell = Shell()
        shell.hosts[button.id] = hosts[0]
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        var actions: [PlazaPanelHit] = []
        hud.onAction = { actions.append($1) }
        let element = try XCTUnwrap(hosts[0].accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(element.accessibilityRole(), .button)
        XCTAssertEqual(element.accessibilityLabel(), "토글")
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(actions, [ButtonPanel.toggle])
    }

    private final class ScrollRecorder: NSView {
        var scrolls = 0
        override func scrollWheel(with event: NSEvent) { scrolls += 1 }
    }

    /// A scroll over a panel no panel takes goes on to the next responder (the views below get it as before).
    func testAnUnhandledScrollGoesOn() async throws {
        let button = ButtonPanel()
        let hud = PlazaHUD(panels: [button], graphics: graphics)
        let container = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let host = PlazaPanelHostView(hud: hud, panel: button.id)
        host.frame = container.bounds
        container.addSubview(host)
        let shell = Shell()
        shell.hosts[button.id] = host
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        host.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(container.scrolls, 1)
    }

    /// Only a panel whose drawing tracks the mouse gets a tracking area (over its frame); its moves reach the panel.
    func testOnlyATrackingPanelFollowsTheMouse() async throws {
        let m = model(hint: "안내")
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("밤 21:34")
        let button = ButtonPanel(tracksMouse: true)
        let (hud, hosts, container) = hostWithPanels([PlazaPillsPanel(model: m), clock, button])
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil }
        let shell = Shell()
        for h in hosts { shell.hosts[h.panelID] = h }
        hud.setViewport(container.bounds.size, scale: 2)
        hud.host = shell
        XCTAssertEqual(hosts.map(\.hasTrackingAreaForTesting), [false, false, true])
        XCTAssertEqual(hosts[0].trackingAreas.count, 0, "the pills cost nothing")
        XCTAssertEqual(hosts[2].trackingAreas.first?.rect, CGRect(x: 10, y: 640 - 30, width: 40, height: 20), "over the panel")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 15, y: 640 - 15), modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        hosts[2].mouseMoved(with: event)
        XCTAssertEqual(button.interaction.hovered, ButtonPanel.toggle)
    }

    /// Joined emoji (a family, a flag, a skin tone) wrap and size as SwiftUI's did; right-to-left one-line pills size as
    /// SwiftUI's, and a right-to-left text too long for one is cut to within a device pixel of SwiftUI's width (TextKit,
    /// which cut SwiftUI's, and CoreText pick cuts a fraction of a point apart: Arabic letters change shape at the cut).
    /// No caller can make that cut: a nickname has at most 12 characters and 12 Arabic letters never fill a pill.
    func testJoinedEmojiAndRightToLeftCutLikeSwiftUI() async throws {
        let viewport = CGSize(width: 600, height: 372)
        let family = "👨‍👩‍👧‍👦", flag = "🇰🇷", thumb = "👍🏽"
        let banners = ["📢 \(family)\(flag)\(thumb): " + String(repeating: "\(family) \(flag) \(thumb) 축하해요 ", count: 4),
                       String(repeating: family + flag + thumb, count: 12)]
        for banner in banners {
            let m = model(banner: banner)
            XCTAssertEqual(try panelPills(m, viewport: viewport, scale: 2), try swiftUIPills(m, viewport: viewport, scale: 2), banner)
        }
        for m in [model(countdown: "مرحبا بالعالم님의 단체 사진 5"), model(hint: "שלום עולם 따라가는 중"),
                  model(hint: "\(family)\(flag)\(thumb) 따라가는 중 · 방향키로 멈추기")] {
            XCTAssertEqual(try panelPills(m, viewport: viewport, scale: 2), try swiftUIPills(m, viewport: viewport, scale: 2), "\(m.countdown ?? m.hint ?? "")")
        }
        let rtl = String(repeating: "مرحبا بالعالم هذا نص طويل ", count: 4) + "님의 단체 사진 5"
        for m in [model(countdown: rtl), model(hint: rtl)] {
            let panel = try XCTUnwrap(try panelPills(m, viewport: viewport, scale: 2).first)
            let swiftUI = try XCTUnwrap(try swiftUIPills(m, viewport: viewport, scale: 2).first)
            XCTAssertEqual(panel.width, swiftUI.width, accuracy: 0.5, "cut within a device pixel of SwiftUI's")
            XCTAssertEqual(panel.height, swiftUI.height)
            XCTAssertLessThanOrEqual(panel.width, viewport.width, "cut to the window")
        }
    }

    // MARK: images for the PR

    private struct Shot {
        let name: String
        let viewport: CGSize
        let model: PlazaOverlayModel?   // nil: the clock
    }

    /// Before (the SwiftUI views) and after (the panels as the window shows them: their hosts' layer trees rendered off
    /// screen), window-sized and transparent.
    private func beforeAfter(_ shot: Shot, scale: CGFloat) throws -> (before: CGImage, after: CGImage, crop: CGRect) {
        let v = shot.viewport, w = Int(v.width * scale), h = Int(v.height * scale)
        let after = Self.context(w, h)
        let before: CGImage
        let frame: CGRect
        if let m = shot.model {
            before = try XCTUnwrap(Self.render(LegacyPlazaPills(model: m).frame(width: v.width, height: v.height), scale: scale))
            let panel = PlazaPillsPanel(model: m)
            frame = try XCTUnwrap(PlazaHUD(panels: [panel], graphics: graphics).layout(viewport: v, scale: scale)[.pills])
            after.draw(try throughHosts([panel], viewport: v, scale: scale), in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            let date = Self.date(hour: 21, minute: 34)
            let clockModel = PlazaMinimapModel()
            let old = try XCTUnwrap(Self.render(LegacyPlazaClock(model: clockModel, date: date), scale: scale))
            let fitting = CGSize(width: CGFloat(old.width) / scale, height: CGFloat(old.height) / scale)
            let mapHeight = PlazaPanelStyle.minimapHeight(worldSize: PlazaMapData.map.pixelSize)
            let at = CGPoint(x: v.width - PlazaRosterMetrics.margin - fitting.width, y: v.height - 16 - mapHeight - 6 - fitting.height)
            let ctx = Self.context(w, h)
            ctx.draw(old, in: CGRect(x: at.x * scale, y: (v.height - at.y - fitting.height) * scale, width: CGFloat(old.width),
                                     height: CGFloat(old.height)))
            before = try XCTUnwrap(ctx.makeImage())
            let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
            clock.update(PlazaDaylight.clockText(date, core: clockModel.coreTime))
            frame = try XCTUnwrap(PlazaHUD(panels: [clock], graphics: graphics).layout(viewport: v, scale: scale)[.clock])
            after.draw(try throughHosts([clock], viewport: v, scale: scale), in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let crop = frame.insetBy(dx: -12, dy: -10).intersection(CGRect(origin: .zero, size: v))
        return (before, try XCTUnwrap(after.makeImage()), crop)
    }

    /// `image` cropped to `crop` (points, top-left) over `background` (the plaza map, or a checkerboard for transparency),
    /// magnified `zoom` times nearest.
    private static func cell(_ image: CGImage, crop: CGRect, scale: CGFloat, background: CGImage?, zoom: Int) -> CGImage {
        let px = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        let w = Int(px.width), h = Int(px.height)
        let ctx = context(w * zoom, h * zoom)
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
        if let background {
            ctx.draw(background, in: CGRect(x: -px.minX, y: -(CGFloat(image.height) - px.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
        } else {
            let square = Int(4 * scale)
            for y in stride(from: 0, to: h, by: square) {
                for x in stride(from: 0, to: w, by: square) {
                    let light = ((x / square) + (y / square)) % 2 == 0
                    ctx.setFillColor(CGColor(gray: light ? 0.85 : 0.65, alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: square, height: square))
                }
            }
        }
        ctx.draw(image, in: CGRect(x: -px.minX, y: -(CGFloat(image.height) - px.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()!
    }

    /// Magenta where any channel differs by more than 8, else a dim copy of `a`; and the counts.
    private static func diff(_ a: CGImage, _ b: CGImage) -> (image: CGImage, over8: Int, over64: Int, max: Int) {
        let pa = rgba(a), pb = rgba(b)
        var out = [UInt8](repeating: 0, count: pa.count)
        var over8 = 0, over64 = 0, mx = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = (0..<4).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max()!
            mx = max(mx, d)
            if d > 8 { over8 += 1 }
            if d > 64 { over64 += 1 }
            let g = UInt8(40 + Int(pa[i + 3]) / 3)
            out[i] = d > 8 ? 255 : g
            out[i + 1] = d > 8 ? 0 : g
            out[i + 2] = d > 8 ? 255 : g
            out[i + 3] = 255
        }
        let ctx = context(a.width, a.height)
        ctx.data!.copyMemory(from: out, byteCount: out.count)
        return (ctx.makeImage()!, over8, over64, mx)
    }

    private static func write(_ image: CGImage, _ url: URL) throws {
        let data = try XCTUnwrap(MacPlazaGraphics.png(image))
        try data.write(to: url)
    }

    /// Writes before/after PNGs, diffs and one contact sheet into `PTB_PLAZA_HUD_OUT`.
    func testWritePanelImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let wide = CGSize(width: 960, height: 640), narrow = CGSize(width: 600, height: 372)
        let shots = [
            Shot(name: "pills-all-960", viewport: wide, model: model(countdown: Self.all.countdown, banner: Self.all.banner, hint: Self.all.hint)),
            Shot(name: "hint-600", viewport: narrow, model: model(hint: "피카츄 따라가는 중 · 방향키로 멈추기")),
            Shot(name: "countdown-600", viewport: narrow, model: model(countdown: "\(Self.longName)님의 단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요")),
            Shot(name: "countdown-emoji-cut-600", viewport: narrow,
                 model: model(countdown: "🐱🐶🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵님의 단체 사진 5 · 광장 창을 앞에 두면 함께 찍혀요")),
            Shot(name: "banner-korean-long-600", viewport: narrow, model: model(banner: Self.banners[1])),
            Shot(name: "banner-no-spaces-600", viewport: narrow, model: model(banner: Self.banners[3])),
            Shot(name: "banner-emoji-600", viewport: narrow, model: model(banner: Self.banners[4])),
            Shot(name: "banner-rtl-600", viewport: narrow, model: model(banner: Self.banners[5])),
            Shot(name: "banner-latin-600", viewport: narrow, model: model(banner: Self.banners[6])),
            Shot(name: "clock-960", viewport: wide, model: nil),
        ]
        // The plaza's own map under the panels (sample data), drawn 2 device pixels per map pixel at 2x as at zoom 1.
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        func background(_ v: CGSize, _ scale: CGFloat) -> CGImage {
            let ctx = Self.context(Int(v.width * scale), Int(v.height * scale))
            ctx.interpolationQuality = .none
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: v.height * scale - size.height + 300 * scale, width: size.width, height: size.height))
            return ctx.makeImage()!
        }
        var summary: [String] = []
        var rows: [(label: String, cells: [CGImage])] = []
        for shot in shots {
            for scale in [CGFloat(2), 1] {
                let (before, after, crop) = try beforeAfter(shot, scale: scale)
                let tag = "\(shot.name)@\(Int(scale))x"
                let bg = background(shot.viewport, scale)
                let zoom = scale == 1 ? 2 : 1
                let cells = [Self.cell(before, crop: crop, scale: scale, background: bg, zoom: zoom),
                             Self.cell(after, crop: crop, scale: scale, background: bg, zoom: zoom),
                             Self.cell(before, crop: crop, scale: scale, background: nil, zoom: zoom),
                             Self.cell(after, crop: crop, scale: scale, background: nil, zoom: zoom)]
                let d = Self.diff(Self.cell(before, crop: crop, scale: scale, background: nil, zoom: 1),
                                  Self.cell(after, crop: crop, scale: scale, background: nil, zoom: 1))
                try Self.write(cells[0], out.appendingPathComponent("before-\(tag)-default.png"))
                try Self.write(cells[1], out.appendingPathComponent("after-\(tag)-default.png"))
                try Self.write(cells[2], out.appendingPathComponent("before-\(tag)-transparent.png"))
                try Self.write(cells[3], out.appendingPathComponent("after-\(tag)-transparent.png"))
                try Self.write(d.image, out.appendingPathComponent("diff-\(tag).png"))
                let line = "\(tag): pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
                summary.append(line)
                let zoomed = Self.cell(d.image, crop: CGRect(origin: .zero, size: CGSize(width: CGFloat(d.image.width) / scale,
                                                                                          height: CGFloat(d.image.height) / scale)),
                                       scale: scale, background: nil, zoom: zoom)
                rows.append((line, cells + [zoomed]))
            }
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try Self.write(Self.sheet(rows, columns: ["before · plaza", "after · plaza", "before · transparent", "after · transparent",
                                                  "diff (magenta: a channel off by more than 8)"]),
                       out.appendingPathComponent("contact-sheet.png"))
    }

    /// Rows of cells under column titles, each row labelled.
    private static func sheet(_ rows: [(label: String, cells: [CGImage])], columns: [String]) -> CGImage {
        let gap = 16, label = 34, header = 44
        let widths = columns.indices.map { c in rows.map { $0.cells[c].width }.max() ?? 0 }
        let heights = rows.map { ($0.cells.map(\.height).max() ?? 0) + label }
        let w = widths.reduce(gap) { $0 + $1 + gap }, h = heights.reduce(header + gap) { $0 + $1 + gap }
        let ctx = context(w, h)
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func text(_ s: String, _ x: Int, _ yTop: Int, _ size: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                             .foregroundColor: NSColor.white]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(h - yTop) - size)
            CTLineDraw(line, ctx)
        }
        var x = gap
        for (c, title) in columns.enumerated() {
            text(title, x, 12, 20)
            x += widths[c] + gap
        }
        var y = header + gap
        for (r, row) in rows.enumerated() {
            text(row.label, gap, y + 4, 18)
            var cx = gap
            for (c, cell) in row.cells.enumerated() {
                ctx.draw(cell, in: CGRect(x: cx, y: h - (y + label) - cell.height, width: cell.width, height: cell.height))
                cx += widths[c] + gap
            }
            y += heights[r] + gap
        }
        return ctx.makeImage()!
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 14, hour, minute)
        return Calendar.current.date(from: c)!
    }
}

private struct RenderTestNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}
