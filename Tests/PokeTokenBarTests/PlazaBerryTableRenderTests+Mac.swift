import XCTest
import AppKit
import CoreText
@testable import PokeTokenBar

/// The sheet the user checks the berry five table against the approved mockup on: 600x372 and 960x640 windows, 2, 5 and 8 players, each while a
/// card is being turned and at the moment of a right bell, over the plaza's own map. Sample data (the mockup's names and Pokémon numbers).
/// Pictures come through the app's own loaders (cache or download); a picture that is not there shows its fallback. With `PTB_PLAZA_HUD_OUT`
/// set, one png is written into that directory. The render is offscreen; no window is created or shown.
@MainActor final class PlazaBerryTableRenderTests: XCTestCase {
    private typealias K = PlazaPanelRenderTests
    private typealias T = PlazaBerryTablePanelTests
    private let narrow = CGSize(width: 600, height: 372), wide = CGSize(width: 960, height: 640)

    private static let people: [(name: String, species: Int, card: PlazaBerry.Card, score: Int, deck: Int)] = [
        ("나", 25, PlazaBerry.Card(berry: .cheri, count: 2), 1, 11), ("지아", 133, PlazaBerry.Card(berry: .sitrus, count: 3), 2, 9),
        ("민수", 4, PlazaBerry.Card(berry: .oran, count: 1), 1, 12), ("하늘", 1, PlazaBerry.Card(berry: .sitrus, count: 2), 3, 8),
        ("유진", 7, PlazaBerry.Card(berry: .pecha, count: 4), 0, 13), ("도윤", 39, PlazaBerry.Card(berry: .oran, count: 3), 2, 10),
        ("서준", 52, PlazaBerry.Card(berry: .cheri, count: 1), 0, 12), ("예린", 54, PlazaBerry.Card(berry: .pecha, count: 2), 1, 11),
    ]

    private enum Moment: String { case flipping = "넘기는 중", rang = "종 친 순간" }

    /// The mockup's table for `n` players: five 자뭉 on it at the ring, the hitter 하늘 (민수 with three players, the second one with two).
    private func board(_ n: Int, _ moment: Moment, long: Bool) -> (board: PlazaBerryBoard, hitter: Int) {
        let hitter = n >= 4 ? 3 : n - 1
        var cards = Self.people.prefix(n).map(\.card)
        if n == 3 { cards[2] = PlazaBerry.Card(berry: .sitrus, count: 2) }
        if n == 2 { cards[1] = PlazaBerry.Card(berry: .sitrus, count: 5) }
        let five = Set(cards.indices.filter { cards[$0].berry == .sitrus })
        let seats = (0..<n).map { i -> PlazaBerryBoard.Seat in
            let p = Self.people[i]
            var name = p.name
            if long && i == n - 1 && n > 2 { name = "가나다라마바사아자차카타파하" }
            return PlazaBerryBoard.Seat(id: "m\(i)", name: name, nameColor: PlazaColor(hex: PlazaNameColor.hexes[i % PlazaNameColor.hexes.count]),
                                        mon: TeamMonSummary(speciesID: p.species, isShiny: false, form: nil, speciesName: nil, gender: nil),
                                        score: p.score + (moment == .rang && i == hitter ? 1 : 0), deckLeft: p.deck, top: cards[i], under: 2, isPlaying: true)
        }
        switch moment {
        case .flipping:
            return (PlazaBerryBoard(seats: seats, center: .playing(event: "\(seats[hitter].name)님 카드가 넘어가는 중…"), flip: 4, flippedSeat: hitter, ring: nil, wrong: false), hitter)
        case .rang:
            let ring = PlazaBerryBoard.Ring(clear: 1, seat: hitter, swept: cards.map { Optional($0) }, five: five)
            var after = seats
            for i in after.indices { after[i].top = nil; after[i].under = 0 }
            return (PlazaBerryBoard(seats: after, center: .playing(event: "\(seats[hitter].name)님이 종을 쳤어요 · 0.41초 · +1"), flip: 4, flippedSeat: nil, ring: ring, wrong: false), hitter)
        }
    }

    private func items() async -> [String: PlazaImage] {
        var out: [String: PlazaImage] = [:]
        for name in PlazaBerry.Berry.allCases.map(\.itemName) + [PlazaBerry.bellItem] {
            if let image = await PopoverItemImages.load(name: name) { out[name] = image }
        }
        return out
    }

    /// One window: the board's state reached through the panel's own change path, the clock driven to the middle of the motion.
    private func window(_ n: Int, _ moment: Moment, viewport: CGSize, long: Bool, items: [String: PlazaImage], icons: PlazaStoreIconSource, map: PlazaImage) async throws -> (image: CGImage, loaded: Int) {
        let scale: CGFloat = 2
        let model = PlazaBerryModel()
        model.items = items
        let clock = PlazaAnimationClock(interval: 1.0 / 30, schedule: { _, _ in {} })
        let panel = PlazaBerryTablePanel(model: model, icons: icons, reduceMotion: { false }, clock: clock)
        let hud = PlazaHUD(panels: [panel])
        let host = RecordingPanelHost()
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        let target = board(n, moment, long: long).board
        var start = target
        start.flip = 3
        start.flippedSeat = nil
        start.ring = nil
        if moment == .rang {   // the cards are still on the table before the clear
            start.seats = board(n, .flipping, long: long).board.seats
            start.center = .playing(event: nil)
        }
        model.board = start
        for _ in 0..<40 { await Task.yield() }
        // Pictures arrive asynchronously: wait until the sprites are in (or give up after a while: the fallbacks then show).
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            for _ in 0..<5 { await Task.yield() }
            if panel.spritesLoaded == n { break }
        }
        model.board = target
        for _ in 0..<40 { await Task.yield() }
        for _ in 0..<(moment == .flipping ? 4 : 7) {   // 0.13 s into the card's slide; 0.23 s into the ring: rim, hop and the bell
            clock.driveForTesting()
            for _ in 0..<40 { await Task.yield() }
        }
        let frames = hud.layout(viewport: viewport, scale: scale)
        let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
        ctx.interpolationQuality = .none
        let mapSize = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
        ctx.draw(map.cgImage, in: CGRect(x: -400 * scale, y: viewport.height * scale - mapSize.height + 300 * scale, width: mapSize.width, height: mapSize.height))
        ctx.interpolationQuality = .high
        let drawing = try XCTUnwrap(host.drawings[.berryTable])
        let frame = try XCTUnwrap(frames[.berryTable])
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
        return (try XCTUnwrap(ctx.makeImage()), panel.spritesLoaded)
    }

    func testWriteTableSheet() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        let loaded = await items()
        let icons = PlazaStoreIconSource()
        for p in Self.people { _ = await icons.sprite(speciesID: p.species, shiny: false, form: nil) }

        let counts = [2, 5, 8], moments: [Moment] = [.flipping, .rang]
        let gap = 24, headerH = 150, rowLabelH = 40, captionH = 60
        let shown: CGFloat = 1   // the sheet shows each window at its own point size (the render is at 2x and drawn down)
        let colWidth = Int(wide.width * shown)
        let width = gap + counts.count * moments.count * (colWidth + gap)
        let rows: [(CGSize, Bool)] = [(narrow, false), (wide, false)]
        let height = headerH + rows.reduce(0) { $0 + rowLabelH + Int($1.0.height * shown) + captionH + gap }
        let ctx = K.context(width, height)
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ s: String, _ x: Int, _ yTop: Int, _ size: CGFloat, _ color: NSColor = .white) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - yTop) - size)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes)), ctx)
        }
        text("열매 다섯 · 탁자 화면 (샘플 데이터: 목업의 이름과 포켓몬)", gap, 12, 40)
        text("sample data · rendered offscreen from the real panel code · 2x render shown at 1x", gap, 70, 26, NSColor(white: 0.85, alpha: 1))
        var x = gap
        for n in counts {
            for m in moments {
                text("\(n)명 · \(m.rawValue)", x, headerH - 44, 34, NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1))
                x += colWidth + gap
            }
        }
        var y = headerH
        var notes: [String] = []
        for (viewport, _) in rows {
            text("\(Int(viewport.width))×\(Int(viewport.height))", gap, y + 4, 30)
            y += rowLabelH
            x = gap
            for n in counts {
                for m in moments {
                    let (image, spriteCount) = try await window(n, m, viewport: viewport, long: n != 2, items: loaded, icons: icons, map: map)
                    let w = Int(viewport.width * shown), h = Int(viewport.height * shown)
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(x: x, y: height - y - h, width: w, height: h))
                    let layout = PlazaBerryTableLayout.make(viewport: viewport, seats: n, scale: 2)
                    let caption = String(format: "카드 %.2f · 자리 %.2f", layout.shrink, layout.seatShrink)
                    text(caption, x, y + h + 8, 24, NSColor(white: 0.9, alpha: 1))
                    notes.append("\(Int(viewport.width))x\(Int(viewport.height)) \(n) \(m.rawValue): cards \(layout.shrink) seats \(layout.seatShrink), sprites \(spriteCount)/\(n)")
                    x += colWidth + gap
                }
            }
            y += Int(viewport.height * shown) + captionH + gap
        }
        try K.write(try XCTUnwrap(ctx.makeImage()), out.appendingPathComponent("berry-table-sheet.png"))
        try (notes + ["pictures loaded: \(loaded.keys.sorted())"]).joined(separator: "\n").write(to: out.appendingPathComponent("berry-table-sheet.txt"), atomically: true, encoding: .utf8)
        print("BERRY sheet: \(notes.joined(separator: " | ")); items \(loaded.keys.sorted())")
    }
}
