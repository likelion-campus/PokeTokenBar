import XCTest
import AppKit
import CoreText
@testable import PokeTokenBar

/// The sheet the user picks the drawing quiz's layout from: each layout, numbered, as the drawer sees it and as a guesser sees it, in the
/// smallest window and the default one, over the plaza's map with the other panels drawn too, so the overlaps show. With
/// `PTB_PLAZA_HUD_OUT` set, one png is written into that directory. Real CoreText; nothing is shown on screen.
@MainActor final class PlazaDrawPanelRenderTests: XCTestCase {
    private typealias K = PlazaPanelRenderTests
    private let narrow = CGSize(width: 600, height: 372), wide = CGSize(width: 960, height: 640)

    /// Records what each panel draws and where, to compose the window by hand.
    @MainActor private final class Shell: PlazaPanelHost {
        var drawings: [PlazaPanelID: (PlazaPanelDrawing, CGRect)] = [:]
        func show(_ id: PlazaPanelID, drawing: PlazaPanelDrawing, frame: CGRect, scale: CGFloat) { drawings[id] = (drawing, frame) }
        func hide(_ id: PlazaPanelID) { drawings[id] = nil }
    }

    private enum Role: String { case drawer = "그리는 사람", guesser = "맞히는 사람" }

    /// A few simple strokes: a house with a roof, a sun, a tree and the ground.
    private func sample() -> PlazaDrawCanvas {
        var c = PlazaDrawCanvas()
        c.stroke(points: [0, 52, 95, 52], color: 8, width: 3)                                   // the ground
        c.stroke(points: [20, 52, 20, 30, 50, 30, 50, 52], color: 1, width: 3)                  // the walls
        c.stroke(points: [16, 30, 35, 14, 54, 30], color: 2, width: 3)                          // the roof
        c.stroke(points: [30, 52, 30, 42, 38, 42, 38, 52], color: 6, width: 1)                  // the door
        c.stroke(points: [78, 10, 78, 10], color: 4, width: 5)                                   // the sun
        for (dx, dy) in [(-7, 0), (7, 0), (0, -7), (0, 7)] { c.stroke(points: [78, 10, 78 + dx, 10 + dy], color: 4, width: 1) }
        c.stroke(points: [70, 52, 70, 38], color: 8, width: 3)                                   // the tree
        c.stroke(points: [64, 38, 70, 28, 76, 38, 64, 38], color: 5, width: 3)
        return c
    }

    private func composed(layout: PlazaDrawLayout, role: Role, viewport: CGSize, map: PlazaImage, scale: CGFloat) throws -> CGImage {
        let overlay = PlazaOverlayModel()
        overlay.hint = "그림 퀴즈 · 제시어를 맞혀 보세요"
        let pills = PlazaPillsPanel(model: overlay)
        let log = PlazaChatLog()
        let now = Date()
        log.append(time: now, name: "지은", text: "집인가?", color: PlazaColor(hex: 0xFF8A80))
        log.append(time: now, name: "도윤", text: "ㅋㅋㅋ 지붕이 귀엽다", color: PlazaColor(hex: 0x80D8FF))
        log.append(time: now, name: "지은", text: "사과!", color: PlazaColor(hex: 0xFF8A80))
        let roster = PlazaRosterModel()
        roster.entries = [
            PlazaRosterEntry(id: "me", nickname: "나", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: .online, isMe: true),
            PlazaRosterEntry(id: "a", nickname: "민수", speciesID: 6, speciesName: "리자몽", gender: nil, isShiny: false, presence: .online, isMe: false),
            PlazaRosterEntry(id: "b", nickname: "지은", speciesID: 133, speciesName: "이브이", gender: nil, isShiny: false, presence: .idle, isMe: false),
        ]
        let clock = PlazaClockPanel(worldSize: PlazaMapData.map.pixelSize)
        clock.update("낮 14:20")
        let minimap = PlazaMinimapPanel(model: PlazaMinimapModel(), background: PlazaBackgroundModel(), worldSize: PlazaMapData.map.pixelSize,
                                        mapImage: { map })
        let model = PlazaDrawModel()
        model.layout = layout
        model.canvas = sample()
        switch role {
        case .drawer:
            model.board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 나", time: "⏱ 52", cover: nil, foot: .tools(word: "사과"), canDraw: true)
        case .guesser:
            model.board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 민수", time: "⏱ 38", cover: nil,
                                         foot: .lines(["힌트 ○○ (2글자) · 첫 글자 ㅅ", "Enter로 답을 말해요"]), canDraw: false)
        }
        let panels: [any PlazaPanel] = [PlazaRosterPanel(model: roster, icons: PlazaStubIconSource()), PlazaDrawPanel(model: model, pills: pills), pills,
                                        PlazaChatLogPanel(log: log), minimap, clock]
        let hud = PlazaHUD(panels: panels)
        let shell = Shell()
        hud.setViewport(viewport, scale: scale)
        hud.host = shell
        let w = Int(viewport.width * scale), h = Int(viewport.height * scale)
        let ctx = K.context(w, h)
        ctx.interpolationQuality = .none
        let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
        ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: viewport.height * scale - size.height + 300 * scale, width: size.width, height: size.height))
        for panel in panels {
            guard let (drawing, frame) = shell.drawings[panel.id] else { continue }
            for layer in drawing.layers {
                func bottomLeft(_ r: CGRect) -> CGRect {
                    let at = r.offsetBy(dx: frame.minX, dy: frame.minY)
                    return CGRect(x: at.minX * scale, y: (viewport.height - at.maxY) * scale, width: at.width * scale, height: at.height * scale)
                }
                switch layer {
                case .image(let image, let r): ctx.draw(image.cgImage, in: bottomLeft(r))
                case .color(let c, let r): ctx.setFillColor(c.cgColor); ctx.fill(bottomLeft(r))
                }
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private static let names: [PlazaDrawLayout: String] = [.center: "가운데 큰 판", .top: "위쪽에 붙인 판", .side: "오른쪽 옆에 붙인 판"]
    private static let number: [PlazaDrawLayout: Int] = [.center: 1, .top: 2, .side: 3]

    func testWriteLayoutSheet() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        let columns: [(String, CGSize, Role)] = [("600×372 · 그리는 사람", narrow, .drawer), ("600×372 · 맞히는 사람", narrow, .guesser),
                                                  ("960×640 · 그리는 사람", wide, .drawer), ("960×640 · 맞히는 사람", wide, .guesser)]
        let gap = 24, titleH = 70, rowHeader = 120
        let colWidths = columns.map { Int($0.1.width) }
        let width = colWidths.reduce(gap) { $0 + $1 + gap }
        let paletteH = 200
        let height = titleH + PlazaDrawLayout.allCases.count * (rowHeader + Int(wide.height) + gap) + paletteH + gap
        let ctx = K.context(width, height)
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ s: String, _ x: Int, _ yTop: Int, _ size: CGFloat, _ color: NSColor = .white) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - yTop) - size)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes)), ctx)
        }
        var x = gap
        for (i, c) in columns.enumerated() {
            text(c.0, x, 16, 36)
            x += colWidths[i] + gap
        }
        var y = titleH
        for layout in PlazaDrawLayout.allCases {
            let n = Self.number[layout]!
            text("\(n)", gap, y + 6, 84, NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1))
            text("\(Self.names[layout]!)  (\(layout.rawValue))", gap + 90, y + 40, 48)
            y += rowHeader
            x = gap
            for (i, c) in columns.enumerated() {
                let image = try composed(layout: layout, role: c.2, viewport: c.1, map: map, scale: 1)
                ctx.draw(image, in: CGRect(x: x, y: height - y - image.height, width: image.width, height: image.height))
                x += colWidths[i] + gap
            }
            y += Int(wide.height) + gap
        }
        text("팔레트 (0 은 바탕)", gap, y + 4, 40)
        let hexes = ["F6F1E3", "2B2233", "D2453B", "E8862E", "F2C14E", "3F9D4B", "3B7BD1", "7D4FC2", "8A5A36"]
        for (i, p) in PlazaDraw.palette.enumerated() {
            let sx = gap + i * 280
            ctx.setFillColor(CGColor(srgbRed: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: 1))
            ctx.fill(CGRect(x: sx, y: height - (y + 60) - 80, width: 80, height: 80))
            text("\(i)", sx + 92, y + 56, 56)
            text("#\(hexes[i])", sx + 92, y + 118, 24, NSColor(white: 0.8, alpha: 1))
        }
        XCTAssertEqual(hexes.map { $0.lowercased() }, PlazaDraw.palette.map { String(format: "%02x%02x%02x", $0.r, $0.g, $0.b) })
        try K.write(try XCTUnwrap(ctx.makeImage()), out.appendingPathComponent("draw-layout-sheet.png"))
    }
}
