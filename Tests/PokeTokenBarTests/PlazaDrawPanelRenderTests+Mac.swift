import XCTest
import AppKit
import CoreText
@testable import PokeTokenBar

/// The drawing quiz panel's pictures for the pull request. With `PTB_PLAZA_HUD_OUT` set they are written into that directory. Real CoreText;
/// nothing is shown on screen.
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

    /// The window as the HUD's stack order draws it, at `scale`. In the small window the HUD is in the state the board needs there (the chat
    /// log shows 3 lines, the shortcuts guide is folded).
    private func composed(role: Role, viewport: CGSize, scale: CGFloat, map: PlazaImage) throws -> CGImage {
        let small = viewport == narrow
        // The lines are the shipping ones (`L(.ko)`), not sample text.
        let l = L(.ko)
        let board: PlazaDrawBoard, hint: String
        switch role {
        case .drawer:
            board = PlazaDrawBoard(head: l.plazaDrawHead(turn: 3, of: 6, drawer: nil), time: l.plazaDrawTime(seconds: 52), cover: nil, foot: .tools(word: "사과"), canDraw: true)
            hint = l.plazaDrawMyDrawing
        case .guesser:
            board = PlazaDrawBoard(head: l.plazaDrawHead(turn: 3, of: 6, drawer: "민수"), time: l.plazaDrawTime(seconds: 38), cover: nil,
                                   foot: .lines([l.plazaDrawHintLetters(2), l.plazaDrawHintInitials("ㅅㄱ")]), canDraw: false)
            hint = l.plazaDrawOtherDrawing
        }
        let r = Rig(viewport: viewport, scale: scale, board: board, full: true, chatLines: small ? 3 : 6, guideFolded: small,
                    hint: hint, canvas: sample())
        let frames = r.hud.layout(viewport: viewport, scale: scale)
        let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.interpolationQuality = .none
        ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: (viewport.height - CGFloat(map.height) + 300) * scale, width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale))
        for id in PlazaPanelID.stackOrder {
            guard let drawing = r.host.drawings[id], let frame = frames[id] else { continue }
            for layer in drawing.layers {
                func bottomLeft(_ rect: CGRect) -> CGRect {
                    let at = rect.offsetBy(dx: frame.minX, dy: frame.minY)
                    return CGRect(x: at.minX * scale, y: (viewport.height - at.maxY) * scale, width: at.width * scale, height: at.height * scale)
                }
                switch layer {
                case .image(let image, let rect): ctx.draw(image.cgImage, in: bottomLeft(rect))
                case .color(let c, let rect): ctx.setFillColor(c.cgColor); ctx.fill(bottomLeft(rect))
                }
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The HUD's stack order drawn over the plaza map at `scale`, for the panels `hud` holds.
    private func compose(_ hud: PlazaHUD, _ host: RecordingPanelHost, viewport: CGSize, scale: CGFloat, map: PlazaImage) throws -> CGImage {
        let frames = hud.layout(viewport: viewport, scale: scale)
        let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.interpolationQuality = .none
        ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: (viewport.height - CGFloat(map.height) + 300) * scale, width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale))
        for id in PlazaPanelID.stackOrder {
            guard let drawing = host.drawings[id], let frame = frames[id] else { continue }
            for layer in drawing.layers {
                func bottomLeft(_ rect: CGRect) -> CGRect {
                    let at = rect.offsetBy(dx: frame.minX, dy: frame.minY)
                    return CGRect(x: at.minX * scale, y: (viewport.height - at.maxY) * scale, width: at.width * scale, height: at.height * scale)
                }
                switch layer {
                case .image(let image, let rect): ctx.draw(image.cgImage, in: bottomLeft(rect))
                case .color(let c, let rect): ctx.setFillColor(c.cgColor); ctx.fill(bottomLeft(rect))
                }
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The M menu (the real overlay content and panel) with `kinds` and the game at `selection` chosen.
    private func menuImage(kinds: [PlazaGameKind], selection: Int, map: PlazaImage) throws -> CGImage {
        let overlay = PlazaOverlayModel()
        let pills = PlazaPillsPanel(model: overlay)
        let hud = PlazaHUD(panels: [PlazaMenuPanel(model: overlay, pills: pills), pills])
        let host = RecordingPanelHost()
        var menu = PlazaGameMenu()
        menu.kinds = kinds
        menu.selection = selection
        overlay.content = .gameMenu(menu)   // set before the host is attached, as the draw rig does
        hud.setViewport(wide, scale: 2)
        hud.host = host
        return try compose(hud, host, viewport: wide, scale: 2, map: map)
    }

    /// A game card as `PlazaGameView.make` builds it from an engine that heard `state`, in the real card panel.
    private func cardImage(_ state: PlazaGameState, joined: Int, now: Date, map: PlazaImage) throws -> CGImage {
        let names = ["a": "지은", "b": "도윤", "c": "민수"]
        var engine = PlazaGameEngine(me: "a")
        engine.learn(state, from: state.host, now: now)
        let view = PlazaGameView.make(engine: engine, now: now, joinedCount: joined, canPlay: true, flash: nil, name: { names[$0] })
        let game = PlazaGameModel(), overlay = PlazaOverlayModel()
        let pills = PlazaPillsPanel(model: overlay)
        let hud = PlazaHUD(panels: [PlazaGameCardPanel(game: game, overlay: overlay, pills: pills), pills])
        let host = RecordingPanelHost()
        game.card = try XCTUnwrap(view.card)
        hud.setViewport(wide, scale: 2)
        hud.host = host
        return try compose(hud, host, viewport: wide, scale: 2, map: map)
    }

    /// The minigame menu before and after the drawing quiz, and the quiz's invitation and ranking cards. Sample nicknames only.
    func testWriteMinigameCardImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        try K.write(try menuImage(kinds: [.bomb], selection: 0, map: map), out.appendingPathComponent("draw-quiz-menu-before.png"))
        try K.write(try menuImage(kinds: [.bomb, .draw], selection: 1, map: map), out.appendingPathComponent("draw-quiz-menu-after.png"))

        let now = Date(timeIntervalSince1970: 1_800_000_100)
        // 도윤 opened a quiz 12 s ago; 3 are in so far.
        let open = PlazaGameState(id: "b@1", kind: PlazaGameKind.draw.rawValue, host: "b", opensAt: now.timeIntervalSince1970 - 12)
        try K.write(try cardImage(open, joined: 3, now: now, map: map), out.appendingPathComponent("draw-quiz-invitation.png"))

        // An ended quiz: 지은 and 도윤 tie for first, 민수 is last, and the last turn was solved.
        var ended = PlazaGameState(id: "b@1", kind: PlazaGameKind.draw.rawValue, host: "b", opensAt: now.timeIntervalSince1970 - 200)
        ended.startsAt = now.timeIntervalSince1970 - 170
        ended.players = ["a", "b", "c"]
        ended.endedAt = now.timeIntervalSince1970 - 5
        ended.draw = PlazaDrawState(order: ["a", "b", "c"], turn: 3, step: 9, scores: ["a": 25, "b": 25, "c": 10],
                                    last: .init(turn: 2, drawer: "c", word: "사과", solver: "a"))
        try K.write(try cardImage(ended, joined: 3, now: now, map: map), out.appendingPathComponent("draw-quiz-ranking.png"))
    }

    /// The pictures for the pull request: the board as the drawer and a guesser see it, at the default window and the smallest, over the plaza.
    func testWritePullRequestImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        for (name, viewport, role) in [("draw-quiz-drawer-960", wide, Role.drawer), ("draw-quiz-guesser-960", wide, .guesser),
                                       ("draw-quiz-drawer-600", narrow, .drawer), ("draw-quiz-guesser-600", narrow, .guesser)] {
            try K.write(try composed(role: role, viewport: viewport, scale: 2, map: map), out.appendingPathComponent("\(name).png"))
        }
    }
}
