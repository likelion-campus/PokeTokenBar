import XCTest
@testable import PokeTokenBar

/// The berry five table: when it shows, that eight seats never overlap, what a press does, and when its clock runs.
@MainActor
final class PlazaBerryTablePanelTests: XCTestCase {
    private let narrow = CGSize(width: 600, height: 372), wide = CGSize(width: 960, height: 640)

    private static let names = ["나", "지아", "민수", "하늘", "유진", "도윤", "서준", "예린"]

    static func board(seats n: Int = 5, names: [String]? = nil, flip: Int = 0, flippedSeat: Int? = nil, ring: PlazaBerryBoard.Ring? = nil,
                      center: PlazaBerryBoard.Center = .playing(event: nil), wrong: Bool = false) -> PlazaBerryBoard {
        let berries = PlazaBerry.Berry.allCases
        let seats = (0..<n).map { i in
            PlazaBerryBoard.Seat(id: "m\(i)", name: names?[i] ?? Self.names[i % Self.names.count], nameColor: PlazaColor(hex: 0xFF8A80),
                                 mon: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: nil, gender: nil), score: i % 4, deckLeft: 10 + i,
                                 top: PlazaBerry.Card(berry: berries[i % 4], count: 1 + i % 5), under: i % 3, isPlaying: true)
        }
        return PlazaBerryBoard(seats: seats, center: center, flip: flip, flippedSeat: flippedSeat, ring: ring, wrong: wrong)
    }

    static func ring(clear: Int, seats n: Int = 5) -> PlazaBerryBoard.Ring {
        PlazaBerryBoard.Ring(clear: clear, seat: 1, swept: (0..<n).map { PlazaBerry.Card(berry: .sitrus, count: 1 + $0 % 5) }, five: [1, 2])
    }

    /// The panel in a HUD with a recording host and a clock nobody schedules: beats are driven by hand.
    @MainActor struct Rig {
        let model = PlazaBerryModel()
        let clock = PlazaAnimationClock(interval: 1.0 / 30, schedule: { _, _ in {} })
        let panel: PlazaBerryTablePanel
        let hud: PlazaHUD
        let host = RecordingPanelHost()
        let bells = Box<Int>(0)

        init(viewport: CGSize, scale: CGFloat = 2, reduceMotion: Bool = false, board: PlazaBerryBoard? = nil) {
            panel = PlazaBerryTablePanel(model: model, icons: PlazaStubIconSource(), reduceMotion: { reduceMotion }, clock: clock)
            hud = PlazaHUD(panels: [panel])
            let bells = bells
            panel.onBell = { bells.value += 1 }
            hud.setViewport(viewport, scale: scale)
            hud.host = host
            model.board = board
        }

        var renders: Int { hud.renderCounts[.berryTable] ?? 0 }

        func beat() async {
            clock.driveForTesting()
            await settle()
        }

        func mouse(_ kind: PlazaMouseEvent.Kind, _ at: CGPoint) -> Bool { hud.handleMouse(PlazaMouseEvent(kind: kind, location: at), in: .berryTable) }
    }

    @MainActor final class Box<T> { var value: T; init(_ v: T) { value = v } }

    static func settle() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: shown

    func testThePanelShowsOnlyWithABoard() async {
        let r = Rig(viewport: wide)
        XCTAssertFalse(r.panel.isVisible)
        XCTAssertNil(r.hud.layout(viewport: wide, scale: 2)[.berryTable])
        r.model.board = Self.board()
        XCTAssertTrue(r.panel.isVisible)
        XCTAssertEqual(r.hud.layout(viewport: wide, scale: 2)[.berryTable], CGRect(origin: .zero, size: wide), "it covers the window")
        await Self.settle()
        XCTAssertNotNil(r.host.drawings[.berryTable])
        r.model.board = nil
        XCTAssertFalse(r.panel.isVisible)
        await Self.settle()
        XCTAssertNil(r.host.drawings[.berryTable], "the host lets go of it")
    }

    // MARK: layout

    /// Two convex quadrilaterals overlap when no edge normal separates them (the separating-axis test), written out here on its own.
    private func overlap(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        for poly in [a, b] {
            for k in 0..<4 {
                let p = poly[k], q = poly[(k + 1) % 4]
                let n = CGPoint(x: p.y - q.y, y: q.x - p.x)
                let pa = a.map { $0.x * n.x + $0.y * n.y }, pb = b.map { $0.x * n.x + $0.y * n.y }
                if pa.max()! <= pb.min()! || pb.max()! <= pa.min()! { return false }
            }
        }
        return true
    }

    private func corners(_ centre: CGPoint, _ size: CGSize, _ rotation: CGFloat) -> [CGPoint] {
        [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { (sx, sy) -> CGPoint in
            let x = sx * size.width / 2, y = sy * size.height / 2
            return CGPoint(x: centre.x + x * cos(rotation) - y * sin(rotation), y: centre.y + x * sin(rotation) + y * cos(rotation))
        }
    }

    private func box(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }

    func testEightSeatsNeverOverlapAtEverySize() async {
        var shrinks: [String] = []
        for viewport in [narrow, CGSize(width: 760, height: 480), wide] {
            for scale: CGFloat in [1, 2] {
                for n in 2...8 {
                    let tag = "\(Int(viewport.width))x\(Int(viewport.height)) @\(scale) n=\(n)"
                    let layout = PlazaBerryTableLayout.make(viewport: viewport, seats: n, scale: scale)
                    XCTAssertEqual(layout.seats.count, n, tag)
                    shrinks.append("\(tag): cards \(layout.shrink) seats \(layout.seatShrink)")
                    var shapes: [(String, [CGPoint])] = []
                    for (i, s) in layout.seats.enumerated() {
                        XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(s.box), "\(tag) seat \(i) box \(s.box) leaves the window")
                        shapes.append(("pile \(i)", corners(s.pile, layout.card, s.rotation)))
                        shapes.append(("deck \(i)", corners(s.deck, layout.deckCard, s.rotation)))
                        for j in layout.seats.indices where j > i {
                            XCTAssertFalse(overlap(box(s.box), box(layout.seats[j].box)), "\(tag) seat boxes \(i) and \(j) overlap")
                        }
                    }
                    for (k, shape) in shapes.enumerated() {
                        XCTAssertFalse(overlap(shape.1, box(layout.center)), "\(tag) \(shape.0) touches the centre plate")
                        for (i, s) in layout.seats.enumerated() { XCTAssertFalse(overlap(shape.1, box(s.box)), "\(tag) \(shape.0) touches seat \(i)'s box") }
                        for other in shapes[(k + 1)...] { XCTAssertFalse(overlap(shape.1, other.1), "\(tag) \(shape.0) and \(other.0) overlap") }
                        for p in shape.1 {
                            // Inside the rim's outer edge: the felt and the 1.4u wood rim around it.
                            let rim = 1.4 * layout.unit
                            let dx = (p.x - layout.felt.midX) / (layout.felt.width / 2 + rim), dy = (p.y - layout.felt.midY) / (layout.felt.height / 2 + rim)
                            XCTAssertLessThanOrEqual(dx * dx + dy * dy, 1, "\(tag) \(shape.0) leaves the rim")
                        }
                    }
                    XCTAssertTrue(layout.center.contains(layout.bell), "\(tag) the bell is on the plate")
                    // Seat 0 is at the bottom, then clockwise: the angle about the window's middle grows from seat to seat.
                    let angles = layout.seats.map { atan2($0.box.midY - viewport.height / 2, $0.box.midX - viewport.width / 2) }
                    XCTAssertEqual(layout.seats.map(\.box.midY).max(), layout.seats[0].box.midY, "\(tag) seat 0 is the lowest")
                    var turn: CGFloat = 0
                    for i in 1..<n {
                        var step = angles[i] - angles[i - 1]
                        while step < 0 { step += 2 * .pi }
                        XCTAssertLessThan(step, n == 2 ? .pi + 0.1 : .pi, "\(tag) seat \(i) follows seat \(i - 1) clockwise")   // two seats face each other
                        turn += step
                    }
                    XCTAssertLessThan(turn, 2 * .pi, "\(tag) the seats go round once")
                }
            }
        }
        print("BERRY layout factors: \(shrinks.filter { $0.contains("@2.0") })")
    }

    /// The seat boxes shrink only for their own limits: with the cards at 0.5 the boxes stay big (the user's choice of the sheet's candidate 3), and a
    /// seat box is never smaller than the cards' own factor demands.
    func testSeatBoxesShrinkOnlyForTheirOwnLimits() async {
        for viewport in [narrow, CGSize(width: 760, height: 480), wide] {
            for n in 2...8 {
                let layout = PlazaBerryTableLayout.make(viewport: viewport, seats: n, scale: 2)
                XCTAssertGreaterThanOrEqual(layout.seatShrink, 0.85, "\(Int(viewport.width)) n=\(n): the seat boxes are not shrunk by the cards' factor \(layout.shrink)")
                let want = PlazaBerryTableLayout.seatSize.width * layout.unit * layout.seatShrink
                XCTAssertEqual(layout.seats[0].box.width, want, accuracy: 1, "the box is seatSize x its own factor")
            }
        }
    }

    /// The mockup's places, which the overlap search must not be able to move: a seat on the outer ellipse, its pile on the inner one and its deck
    /// beside the pile along the tangent (not along the radius), every card turned to face its seat.
    func testSeatsPilesAndDecksFollowTheMockup() async {
        let viewport = wide
        let u = viewport.width / 100, stageH = 100 * u / 1.6, oy = (viewport.height - stageH) / 2
        for n in [2, 5, 8] {
            let layout = PlazaBerryTableLayout.make(viewport: viewport, seats: n, scale: 2)
            XCTAssertEqual(layout.unit, u, accuracy: 0.001)
            for (i, s) in layout.seats.enumerated() {
                let a = CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
                XCTAssertEqual(s.pile.x, (50 + 29 * cos(a)) * u, accuracy: 0.01, "n=\(n) pile \(i) x")
                XCTAssertEqual(s.pile.y, oy + (50 + 25 * sin(a)) * stageH / 100, accuracy: 0.01, "n=\(n) pile \(i) y")
                XCTAssertEqual(s.deck.x - s.pile.x, 9 * u * -sin(a), accuracy: 0.01, "n=\(n) deck \(i) sits along the tangent")
                XCTAssertEqual(s.deck.y - s.pile.y, 9 * u * cos(a), accuracy: 0.01, "n=\(n) deck \(i) sits along the tangent")
                XCTAssertEqual(s.rotation, a - .pi / 2, accuracy: 0.0001)
            }
        }
    }

    func testLongAndEmojiNamesStayInsideTheirSeat() async throws {
        for names in [Array(repeating: "가나다라마바사아자차카타파하", count: 8), Array(repeating: "🐱🐶🦊🐻🐼🐨🐯🦁", count: 8)] {
            let r = Rig(viewport: narrow, scale: 2, board: Self.board(seats: 8, names: names))
            await Self.settle()
            let drawing = try XCTUnwrap(r.host.drawings[.berryTable])
            XCTAssertEqual(r.panel.placedNames.count, 8)
            for (i, placed) in r.panel.placedNames.enumerated() {
                let seat = r.panel.placedFrames[i]
                XCTAssertTrue(seat.contains(placed.frame), "seat \(i): the name's frame \(placed.frame) is inside the box \(seat)")
                XCTAssertTrue(placed.text.hasSuffix("…"), "seat \(i): \(placed.text)")
                XCTAssertLessThan(placed.text.count, names[i].count + 1)
            }
            let seatItems = drawing.accessibility.prefix(8)
            for (i, item) in seatItems.enumerated() {
                XCTAssertTrue(r.panel.placedFrames[i].contains(item.frame), "seat \(i)'s accessibility frame is inside its box")
                XCTAssertEqual(item.label, L(.ko).plazaBerrySeatLabel(name: names[i], score: i % 4), "VoiceOver reads the whole name")
            }
        }
    }

    // MARK: the bell

    func testTheBellTakesAPressAndNothingElseDoes() async throws {
        let r = Rig(viewport: wide, board: Self.board())
        await Self.settle()
        let bell = PlazaBerryTableLayout.make(viewport: wide, seats: 5, scale: 2).bell
        let at = CGPoint(x: bell.midX, y: bell.midY)
        XCTAssertEqual(r.panel.hit(at), PlazaPanelHit(action: "bell", index: nil))
        XCTAssertTrue(r.mouse(.down, at))
        XCTAssertEqual(r.bells.value, 1, "the press rings at the press, not at the release")
        XCTAssertTrue(r.mouse(.up, at))
        XCTAssertEqual(r.bells.value, 1, "the release does not ring again")
        XCTAssertTrue(r.mouse(.down, CGPoint(x: 6, y: 6)), "the table takes a press anywhere")
        XCTAssertTrue(r.mouse(.up, CGPoint(x: 6, y: 6)))
        XCTAssertEqual(r.panel.hit(CGPoint(x: 6, y: 6)), PlazaPanelHit(action: "table", index: nil))
        XCTAssertEqual(r.bells.value, 1)
    }

    func testAResultHasNoBell() async throws {
        let r = Rig(viewport: wide, board: Self.board(center: .result(lines: ["하늘 우승", "나 3점"])))
        await Self.settle()
        let bell = PlazaBerryTableLayout.make(viewport: wide, seats: 5, scale: 2).bell
        XCTAssertTrue(r.mouse(.down, CGPoint(x: bell.midX, y: bell.midY)))
        XCTAssertEqual(r.bells.value, 0)
        XCTAssertNil(r.host.drawings[.berryTable]?.accessibility.first { $0.role == .button })
    }

    // MARK: motion

    func testAFlipAnimatesOnlyOneStepAndOnlyWithMotion() async throws {
        let r = Rig(viewport: wide, board: Self.board(flip: 3))
        await Self.settle()
        XCTAssertFalse(r.panel.isAnimating, "the first board of a game is a start, not a step")
        r.model.board = Self.board(flip: 4, flippedSeat: 2)
        await Self.settle()
        XCTAssertTrue(r.panel.isAnimating, "+1 flips one card")
        let steps = Int((PlazaBerry.flipAnimation / r.clock.interval).rounded())
        for _ in 0..<(steps - 1) {
            await r.beat()
            XCTAssertTrue(r.panel.isAnimating)
        }
        await r.beat()
        XCTAssertFalse(r.panel.isAnimating, "it stops after flipAnimation of beats")

        let before = r.renders
        r.model.board = Self.board(flip: 7, flippedSeat: 2)
        await Self.settle()
        XCTAssertFalse(r.panel.isAnimating, "+3 is a catch-up, not a flip")
        XCTAssertEqual(r.renders, before + 1, "it renders once")

        let calm = Rig(viewport: wide, reduceMotion: true, board: Self.board(flip: 3))
        await Self.settle()
        let calmBefore = calm.renders
        calm.model.board = Self.board(flip: 4, flippedSeat: 2)
        await Self.settle()
        XCTAssertFalse(calm.panel.isAnimating)
        XCTAssertEqual(calm.renders, calmBefore + 1)
        calm.model.board = Self.board(flip: 4, flippedSeat: 2, ring: Self.ring(clear: 1))
        await Self.settle()
        XCTAssertFalse(calm.panel.isAnimating, "Reduce Motion changes the ring at once too")
        XCTAssertEqual(calm.renders, calmBefore + 2)
    }

    func testAFlippedCardIsVisibleFromTheFirstFrame() async throws {
        let r = Rig(viewport: wide, board: Self.board(flip: 3))
        await Self.settle()
        let seat = PlazaBerryTableLayout.make(viewport: wide, seats: 5, scale: 2).seats[2]
        func images(at point: CGPoint) throws -> Int {
            try XCTUnwrap(r.host.drawings[.berryTable]).layers.filter {
                if case .image(_, let f) = $0 { return abs(f.midX - point.x) < 1 && abs(f.midY - point.y) < 1 }
                return false
            }.count
        }
        XCTAssertEqual(try images(at: seat.deck), 1, "before the flip only the deck is there")
        XCTAssertEqual(try images(at: seat.pile), 3, "the pile is two cards under and the top face")
        r.model.board = Self.board(flip: 4, flippedSeat: 2)
        await Self.settle()
        XCTAssertTrue(r.panel.isAnimating)
        XCTAssertEqual(try images(at: seat.deck), 2, "the new card starts on its deck, face up, from the first frame")
        XCTAssertEqual(try images(at: seat.pile), 2, "its face has left the pile: the two cards under are what stays")
    }

    func testARightBellRimsSweepsAndStops() async throws {
        let r = Rig(viewport: wide, board: Self.board(flip: 3, ring: Self.ring(clear: 1)))
        await Self.settle()
        XCTAssertFalse(r.panel.isAnimating, "a ring already there when the table opens does not play")
        r.model.board = Self.board(flip: 3, ring: Self.ring(clear: 2))
        await Self.settle()
        XCTAssertTrue(r.panel.isAnimating)
        let steps = Int((PlazaBerryTablePanel.ringTotal / r.clock.interval).rounded())
        for _ in 0..<(steps - 1) {
            await r.beat()
            XCTAssertTrue(r.panel.isAnimating)
        }
        await r.beat()
        XCTAssertFalse(r.panel.isAnimating, "0.8 s of beats, then it stops")
        r.model.board = Self.board(flip: 3, ring: Self.ring(clear: 2), center: .playing(event: "하늘님이 종을 쳤어요"))
        await Self.settle()
        XCTAssertFalse(r.panel.isAnimating, "the same ring again starts nothing")
    }

    func testABeatNobodyDrewEndsTheClock() async throws {
        let r = Rig(viewport: wide, board: Self.board(flip: 3))
        await Self.settle()
        r.model.board = Self.board(flip: 4, flippedSeat: 1)
        await Self.settle()
        r.hud.isRendering = false
        r.clock.driveForTesting()
        r.clock.driveForTesting()
        XCTAssertFalse(r.panel.isAnimating, "a plaza that is not drawing runs no clock")
    }

    // MARK: cost and pictures

    func testAHiddenTableCostsNothing() async throws {
        let r = Rig(viewport: wide)
        await Self.settle()
        XCTAssertEqual(r.renders, 0)
        r.model.items = [PlazaBerry.bellItem: PlazaImage(bitmap: PlazaBitmap(width: 4, height: 4, fill: PlazaRGBA(r: 255, g: 215, b: 0, a: 255)))]
        await Self.settle()
        XCTAssertEqual(r.renders, 0, "a picture arriving for no board renders nothing")
        XCTAssertFalse(r.panel.isAnimating)
    }

    func testMissingPicturesDrawTheFallbacks() async throws {
        let r = Rig(viewport: narrow, board: Self.board(seats: 8))
        await Self.settle()
        let drawing = try XCTUnwrap(r.host.drawings[.berryTable])
        XCTAssertFalse(drawing.layers.isEmpty)
        let bell = try XCTUnwrap(drawing.accessibility.first { $0.role == .button })
        XCTAssertEqual(bell.label, L(.ko).plazaBerryBellFallback)
        XCTAssertEqual(bell.action, PlazaPanelHit(action: "bell", index: nil))
        r.model.items = [PlazaBerry.bellItem: PlazaImage(bitmap: PlazaBitmap(width: 4, height: 4, fill: PlazaRGBA(r: 255, g: 215, b: 0, a: 255)))]
        await Self.settle()
        XCTAssertEqual(r.renders, 2, "a picture arriving draws the table again")
    }

    func testTheCentreShowsTheCountdownTheEventAndTheWrongBell() async throws {
        let r = Rig(viewport: wide, board: Self.board(center: .countdown(3)))
        await Self.settle()
        let labels = { try XCTUnwrap(r.host.drawings[.berryTable]).accessibility.map(\.label) }
        XCTAssertTrue(try labels().contains("3"))
        XCTAssertTrue(try labels().contains(L(.ko).plazaBerryRule))
        XCTAssertTrue(try labels().contains(L(.ko).plazaBerryCountdownNote), "the cards turn by themselves")
        r.model.board = Self.board(center: .playing(event: "하늘님이 종을 쳤어요 · 0.41초 · +1점"), wrong: true)
        await Self.settle()
        XCTAssertTrue(try labels().contains("하늘님이 종을 쳤어요 · 0.41초 · +1점"))
        XCTAssertFalse(try labels().contains(L(.ko).plazaBerryCountdownNote), "only the countdown says it")
    }

    // MARK: centre plate text

    private typealias Kind = PlazaBerryTablePanel.PlateRow.Kind

    /// Every centre state the plate shows, with the longest lines the game makes (an 8-seat result with a tie head).
    private func centres(seats n: Int) -> [(String, PlazaBerryBoard.Center)] {
        let l = L(.ko)
        let ranks = (0..<n).map { l.plazaBerryRank(place: $0 + 1, nickname: Self.names[$0], score: 4 - $0 % 4, tied: $0 % 2 == 0) }
        return [("countdown", .countdown(3)),
                ("event", .playing(event: l.plazaBerryMissed(nickname: "서준", tookPoint: false))),
                ("long event", .playing(event: l.plazaBerryRang(nickname: "가나다라마바사아자차카타파하", ms: 410))),
                ("result", .result(lines: [l.plazaBerryTie(names: Self.names.prefix(n).map { $0 })] + ranks + [l.plazaBerryCloseHint]))]
    }

    func testPlateRowsNeverOverlapAndStayInsideThePlate() async throws {
        for viewport in [narrow, wide] {
            for scale in [CGFloat(1), 2] {
                for n in [2, 5, 8] {
                    for (name, center) in centres(seats: n) {
                        let r = Rig(viewport: viewport, scale: scale, board: Self.board(seats: n, center: center))
                        await Self.settle()
                        let plate = try XCTUnwrap(r.panel.plate)
                        let ctx = "\(name) \(Int(viewport.width)) x\(scale) \(n) seats"
                        for (i, a) in plate.rows.enumerated() {
                            XCTAssertTrue(plate.frame.insetBy(dx: -0.01, dy: -0.01).contains(a.frame), "\(a.kind) \(a.text) leaves the plate: \(ctx)")
                            for b in plate.rows[(i + 1)...] {
                                XCTAssertFalse(a.frame.insetBy(dx: 0.01, dy: 0.01).intersects(b.frame.insetBy(dx: 0.01, dy: 0.01)),
                                               "\(a.kind) \(a.text) overlaps \(b.kind) \(b.text): \(ctx)")
                            }
                        }
                        if name == "countdown" {
                            let digit = try XCTUnwrap(plate.rows.first { $0.kind == .digit }, "the digit has its row: \(ctx)")
                            let rule = try XCTUnwrap(plate.rows.first { $0.kind == .rule }, "the rule stays: \(ctx)")
                            XCTAssertGreaterThan(digit.frame.height, rule.frame.height, ctx)
                            let m = PlatformPlaza.graphics.text.metrics(.plaza(.body))
                            XCTAssertGreaterThanOrEqual(digit.frame.height, (m.ascender - m.descender).rounded() * digit.magnify, "the row holds the magnified glyphs: \(ctx)")
                            let note = plate.rows.filter { $0.kind == .note }.map(\.text)
                            XCTAssertTrue(note.isEmpty || note.joined(separator: " ") == L(.ko).plazaBerryCountdownNote, "the note is whole or gone: \(ctx)")
                            if viewport == wide { XCTAssertFalse(note.isEmpty, "the big plate keeps the note: \(ctx)") }
                        }
                    }
                }
            }
        }
    }

    func testThePlateBreaksTheRuleAtSpacesOnly() async throws {
        let rule = L(.ko).plazaBerryRule
        for viewport in [narrow, wide] {
            let r = Rig(viewport: viewport, board: Self.board(center: .playing(event: nil)))
            await Self.settle()
            let pieces = try XCTUnwrap(r.panel.plate).rows.filter { $0.kind == .rule }.map(\.text)
            XCTAssertGreaterThan(pieces.count, 1, "the rule wraps in this plate: \(Int(viewport.width))")
            XCTAssertEqual(pieces.joined(separator: " "), rule, "every break falls at a space: \(Int(viewport.width))")
        }
    }

    func testAWordWiderThanTheLineBreaksInsideItAndOnlyThen() async {
        let wide = PlazaBerryTablePanel.wordLines("가나 다라마바사 아", width: 3) { CGFloat($0.count) }
        XCTAssertEqual(wide, ["가나", "다라마", "바사", "아"])
        XCTAssertEqual(PlazaBerryTablePanel.wordLines("a bb ccc", width: 5) { CGFloat($0.count) }, ["a bb", "ccc"])
        XCTAssertEqual(PlazaBerryTablePanel.wordLines("", width: 5) { CGFloat($0.count) }, [""])
    }
}
