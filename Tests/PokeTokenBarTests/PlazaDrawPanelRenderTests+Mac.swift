import XCTest
import AppKit
import CoreText
@testable import PokeTokenBar

/// The sheet the user picks the drawing quiz's layout from: each candidate, numbered, as the drawer sees it and as a guesser sees it, in the
/// smallest window and the default one, over the plaza's map with the other panels drawn too (in the stack order the candidate needs), so
/// any overlap shows. With `PTB_PLAZA_HUD_OUT` set, one png is written into that directory. Real CoreText; nothing is shown on screen.
@MainActor final class PlazaDrawPanelRenderTests: XCTestCase {
    private typealias K = PlazaPanelRenderTests
    private typealias Rig = PlazaDrawPanelTests.Rig
    private let narrow = CGSize(width: 600, height: 372), wide = CGSize(width: 960, height: 640)

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

    /// The window as the candidate's stack order draws it; also the canvas size in points and the cell size for the caption.
    private func composed(layout: PlazaDrawLayout, role: Role, viewport: CGSize, map: PlazaImage) throws -> (image: CGImage, caption: String) {
        let small = layout == .top && viewport == narrow
        let board: PlazaDrawBoard
        switch role {
        case .drawer: board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 나", time: "⏱ 52", cover: nil, foot: .tools(word: "사과"), canDraw: true)
        case .guesser: board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 민수", time: "⏱ 38", cover: nil,
                                               foot: .lines(["힌트 ○○ (2글자) · 첫 글자 ㅅ", "Enter로 답을 말해요"]), canDraw: false)
        }
        let r = Rig(viewport: viewport, scale: 1, layout: layout, board: board, full: true, chatLines: small ? 3 : 6, guideFolded: small,
                    hint: "그림 퀴즈 · 제시어를 맞혀 보세요", canvas: sample())
        let frames = r.hud.layout(viewport: viewport, scale: 1)
        // `right` covers the minimap and the clock, so it is drawn above them (and below the chat log); `top` is where the stack puts it.
        var order = PlazaPanelID.stackOrder.filter { frames[$0] != nil }
        if layout == .right {
            order.removeAll { $0 == .drawBoard }
            order.insert(.drawBoard, at: order.firstIndex(of: .clock)! + 1)
        }
        let ctx = K.context(Int(viewport.width), Int(viewport.height))
        ctx.interpolationQuality = .none
        ctx.draw(map.cgImage, in: CGRect(x: -400, y: viewport.height - CGFloat(map.height) + 300, width: CGFloat(map.width), height: CGFloat(map.height)))
        for id in order {
            guard let drawing = r.host.drawings[id], let frame = frames[id] else { continue }
            for layer in drawing.layers {
                func bottomLeft(_ rect: CGRect) -> CGRect {
                    let at = rect.offsetBy(dx: frame.minX, dy: frame.minY)
                    return CGRect(x: at.minX, y: viewport.height - at.maxY, width: at.width, height: at.height)
                }
                switch layer {
                case .image(let image, let rect): ctx.draw(image.cgImage, in: bottomLeft(rect))
                case .color(let c, let rect): ctx.setFillColor(c.cgColor); ctx.fill(bottomLeft(rect))
                }
            }
        }
        let placed = r.panel.layout(in: viewport, scale: 1, text: PlatformPlaza.graphics.text)
        var caption = "그림판 \(Int(placed.canvas.width))×\(Int(placed.canvas.height)) · 칸 \(placed.cell)px"
        if !placed.fits { caption += " · 안 들어감" }
        if small { caption += "\n작은 창: 대화 기록 3줄 · 단축키 안내 접힘" }
        return (try XCTUnwrap(ctx.makeImage()), caption)
    }

    private static let names: [PlazaDrawLayout: String] = [.right: "오른쪽 세로", .top: "가운데 위"]
    private static let number: [PlazaDrawLayout: Int] = [.right: 1, .top: 2]

    func testWriteLayoutSheet() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        let columns: [(String, CGSize, Role)] = [("600×372 · 그리는 사람", narrow, .drawer), ("600×372 · 맞히는 사람", narrow, .guesser),
                                                  ("960×640 · 그리는 사람", wide, .drawer), ("960×640 · 맞히는 사람", wide, .guesser)]
        let gap = 24, titleH = 70, rowHeader = 120, captionH = 90
        let colWidths = columns.map { Int($0.1.width) }
        let width = colWidths.reduce(gap) { $0 + $1 + gap }
        let paletteH = 200
        let height = titleH + PlazaDrawLayout.allCases.count * (rowHeader + Int(wide.height) + captionH + gap) + paletteH + gap
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
        for layout in [PlazaDrawLayout.right, .top] {
            text("\(Self.number[layout]!)", gap, y + 6, 84, NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1))
            text("\(Self.names[layout]!)  (\(layout.rawValue))", gap + 90, y + 40, 48)
            y += rowHeader
            x = gap
            for (i, c) in columns.enumerated() {
                let (image, caption) = try composed(layout: layout, role: c.2, viewport: c.1, map: map)
                ctx.draw(image, in: CGRect(x: x, y: height - y - image.height, width: image.width, height: image.height))
                for (k, line) in caption.split(separator: "\n").enumerated() {
                    text(String(line), x, y + Int(c.1.height) + 8 + k * 32, 26, NSColor(white: 0.9, alpha: 1))
                }
                x += colWidths[i] + gap
            }
            y += Int(wide.height) + captionH + gap
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
