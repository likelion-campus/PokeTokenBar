import XCTest
@testable import PokeTokenBar

/// 포춘쿠키의 규칙과 그림: 쪽지 뽑기, 받은 값의 범위, 문구 길이, 가판대 자리, 말 걸기, 그림 단계.
@MainActor
final class PlazaFortuneTests: XCTestCase {
    private let map = PlazaMapData.map
    private func p(_ x: Int, _ y: Int) -> TilePoint { TilePoint(x: x, y: y) }

    // MARK: - Drawing a slip

    func testTheSameDayAndMemberAlwaysDrawTheSameSlip() async {
        let a = PlazaFortune.draw(day: "2026-11-23", memberID: "m1")
        XCTAssertEqual(a, PlazaFortune.draw(day: "2026-11-23", memberID: "m1"))
        XCTAssertNotNil(PlazaFortune.accepted(a))
    }

    func testDaysAndMembersSpreadOverTheLines() async {
        let byDay = Set((1...30).map { PlazaFortune.draw(day: String(format: "2026-11-%02d", $0), memberID: "m1").line })
        let byMember = Set((1...30).map { PlazaFortune.draw(day: "2026-11-23", memberID: "m\($0)").line })
        XCTAssertGreaterThan(byDay.count, 15, "a member's month is not one line")
        XCTAssertGreaterThan(byMember.count, 15, "a team's day is not one line")
    }

    func testAReceivedSlipOutsideTheListsIsDropped() async {
        XCTAssertNil(PlazaFortune.accepted(nil))
        XCTAssertNil(PlazaFortune.accepted(.init(line: -1, action: 0)))
        XCTAssertNil(PlazaFortune.accepted(.init(line: PlazaFortune.lines.count, action: 0)))
        XCTAssertNil(PlazaFortune.accepted(.init(line: 0, action: -1)))
        XCTAssertNil(PlazaFortune.accepted(.init(line: 0, action: PlazaFortune.actions.count)))
        XCTAssertNil(PlazaFortune.accepted(.init(line: .max, action: .min)))
        XCTAssertNil(PlazaFortune.text(.init(line: PlazaFortune.lines.count, action: 0)))
        let last = PlazaFortuneDraw(line: PlazaFortune.lines.count - 1, action: PlazaFortune.actions.count - 1)
        XCTAssertEqual(PlazaFortune.accepted(last), last)
        XCTAssertEqual(PlazaFortune.text(last)?.line, PlazaFortune.lines.last)
        XCTAssertEqual(PlazaFortune.text(last)?.action, "행운의 행동 · " + PlazaFortune.actions.last!)
    }

    func testEveryLineAndActionFitsOneLineOfTheSlip() async {
        XCTAssertEqual(Set(PlazaFortune.lines).count, PlazaFortune.lines.count, "no line twice")
        for line in PlazaFortune.lines {
            XCTAssertLessThanOrEqual(PlazaFortuneArt.textWidth(line), PlazaFortuneArt.maxTextWidth, line)
        }
        for action in PlazaFortune.actions {
            let text = L(.ko).plazaFortuneAction(action)
            XCTAssertLessThanOrEqual(PlazaFortuneArt.textWidth(text), PlazaFortuneArt.maxTextWidth, text)
        }
    }

    // MARK: - The wire

    func testAFortuneEmoteCarriesItsSlipAndAnUnreadableOneBecomesNil() async throws {
        let emote = TeamEmote(kind: .fortune, fortune: PlazaFortuneDraw(line: 3, action: 4))
        let data = try JSONEncoder().encode(emote)
        XCTAssertEqual(try JSONDecoder().decode(TeamEmote.self, from: data), emote)
        let odd = try JSONDecoder().decode(TeamEmote.self, from: Data(#"{"kind":"fortune","fortune":{"line":"x"}}"#.utf8))
        XCTAssertEqual(odd.kind, .fortune)
        XCTAssertNil(odd.fortune)
        let plain = try JSONEncoder().encode(TeamEmote(kind: .jump))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("fortune"), "other kinds do not carry the key")
    }

    func testAFortuneNotifiesNobodyAndEndsTheSendersDance() async {
        XCTAssertFalse(TeamEmoteKind.fortune.notifiesTarget)
        XCTAssertTrue(TeamEmoteKind.fortune.endsSendersDance)
    }

    // MARK: - The stall on the map

    func testTheStallStandsInTheTopRightCornerAndBlocksWalkingAndThrows() async {
        let tiles = PlazaFortune.stallTiles(in: map)
        XCTAssertEqual(Set(tiles), Set((3...5).flatMap { y in (40...44).map { p($0, y) } }))
        for t in tiles {
            XCTAssertFalse(map.isWalkable(t))
            XCTAssertFalse(map.isWater(t))
            XCTAssertTrue(PlazaSnowball.blocksBall(t, in: map))
            XCTAssertFalse(PlazaSnow.isSnowGround(t, in: map))
        }
        for x in 40...44 { XCTAssertTrue(map.isWalkable(p(x, 6)), "the row in front of the counter is open") }
        XCTAssertTrue(map.isWalkable(p(39, 4)), "a lane between the tall grass and the stall")
        XCTAssertEqual(map.tile(at: p(45, 4)), .tree, "its right side is the border")
        XCTAssertTrue(Set(PlazaItems.openTiles(in: map)).isDisjoint(with: tiles), "no item drops inside the stall")
    }

    func testSpaceReachesTheStallAheadOrBesideAndTheBoardStillWinsItsOwnTile() async {
        func hit(_ tile: TilePoint, _ facing: PlazaDirection) -> PlazaInteractionHit? {
            PlazaInteraction.target(me: PlazaBody(foot: tile, size: 1), facing: facing, map: map, members: [:])
        }
        XCTAssertEqual(hit(p(42, 6), .up), .init(target: .stall, facing: .up))
        XCTAssertEqual(hit(p(42, 6), .left), .init(target: .stall, facing: .up), "beside it without facing it")
        XCTAssertEqual(hit(p(39, 4), .down), .init(target: .stall, facing: .right))
        XCTAssertNil(hit(p(42, 7), .up), "two tiles away")
        XCTAssertEqual(hit(p(23, 6), .up)?.target, .board)
    }

    // MARK: - Art

    func testTheCookieKeepsItsShapeAndTakesTheMapColours() async throws {
        let cookie = try XCTUnwrap(PlazaFortuneArt.cookie)
        XCTAssertEqual(cookie.width, 12)
        XCTAssertEqual(cookie.height, 10)
        let allowed = Set(PlazaFortuneArt.swaps.map(\.to))
        var opaque = 0
        for y in 0..<cookie.height {
            for x in 0..<cookie.width where cookie[x, y].a != 0 {
                opaque += 1
                XCTAssertTrue(allowed.contains(cookie[x, y]), "(\(x), \(y)) kept a colour the map does not have")
            }
        }
        XCTAssertEqual(opaque, 96, "the artist's 96 pixels, none added or dropped")
        var source = PlazaBitmap(width: 2, height: 1)
        source[0, 0] = PlazaFortuneArt.swaps[0].from
        source[1, 0] = PlazaRGBA(r: 1, g: 2, b: 3, a: 255)
        let out = PlazaFortuneArt.recoloured(source)
        XCTAssertEqual(out[0, 0], PlazaFortuneArt.swaps[0].to)
        XCTAssertEqual(out[1, 0], PlazaRGBA(r: 1, g: 2, b: 3, a: 255), "a colour outside the list is left alone")
    }

    func testThePileIsFiveCookiesWithAShadowOfTheSameShape() async throws {
        let cookie = try XCTUnwrap(PlazaFortuneArt.cookie)
        let pile = PlazaFortuneArt.pile(of: cookie)
        XCTAssertEqual(pile.art.width, 29)
        XCTAssertEqual(pile.art.height, 18)
        for y in 0..<18 {
            for x in 0..<29 {
                XCTAssertEqual(pile.art[x, y].a != 0, pile.shadow[x, y].a != 0)
                if pile.shadow[x, y].a != 0 { XCTAssertEqual(pile.shadow[x, y], PlazaFortuneArt.shadow) }
            }
        }
        XCTAssertEqual(pile.art[0, 6 + 4].a, 255, "the left ground cookie")
        XCTAssertEqual(pile.art[28, 6 + 4].a, 255, "the right ground cookie, mirrored")
    }

    func testTheSlipGrowsStepByStepAndOnlyTheOpenOneCarriesText() async throws {
        let line = PlazaFortune.lines[0], action = L(.ko).plazaFortuneAction(PlazaFortune.actions[0])
        func image(_ s: PlazaFortuneArt.Stage, cookie: Bool = true) throws -> PlazaImage {
            try XCTUnwrap(PlazaFortuneArt.image(s, line: line, action: action, scale: 2, withCookie: cookie))
        }
        let whole = try image(.whole)
        XCTAssertEqual(whole.width, 12 * 3 * 2)
        var widths = [whole.width]
        for step in 1...PlazaFortuneArt.splitSteps { widths.append(try image(.split(step)).width) }
        let open = try image(.open)
        widths.append(open.width)
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, widths.count, "every step is wider than the one before")
        XCTAssertEqual(Set(try ([.whole, .split(1), .open] as [PlazaFortuneArt.Stage]).map { try image($0).height }).count, 1,
                       "one height, so the picture does not jump")
        let ink = PlazaRGBA(r: 48, g: 38, b: 57, a: 255)
        func inkInside(_ image: PlazaImage) -> Int {   // ink pixels well inside the paper, away from the outline and the bands
            let b = image.pixels
            var n = 0
            for y in 20..<(b.height - 28) { for x in 100..<(b.width - 100) where b[x, y] == ink { n += 1 } }
            return n
        }
        XCTAssertGreaterThan(inkInside(open), 100, "the open slip has letters")
        let bare = try image(.open, cookie: false)
        XCTAssertEqual(bare.width, open.width)
        XCTAssertNotEqual(bare.pixels, open.pixels, "the cookie halves are gone when the slip is shown again")
        XCTAssertEqual(inkInside(bare), inkInside(open))
        let other = try XCTUnwrap(PlazaFortuneArt.image(.open, line: PlazaFortune.lines[1], action: action, scale: 2))
        XCTAssertNotEqual(other.pixels, open.pixels)
    }

    func testTheCookieFloatsThenSplitsThenTheSlipStaysToBeRead() async {
        typealias A = PlazaActor
        XCTAssertEqual(A.fortuneStage(elapsed: 0, reveal: true), .whole)
        XCTAssertEqual(A.fortuneStage(elapsed: PlazaFortune.splitStart - 0.01, reveal: true), .whole)
        XCTAssertEqual(A.fortuneStage(elapsed: PlazaFortune.splitStart + 0.01, reveal: true), .split(1))
        let unrolled = Double(PlazaFortuneArt.splitSteps) * PlazaFortune.splitStepDuration
        XCTAssertEqual(A.fortuneStage(elapsed: PlazaFortune.splitStart + unrolled - 0.01, reveal: true), .split(PlazaFortuneArt.splitSteps))
        XCTAssertEqual(A.fortuneStage(elapsed: PlazaFortune.splitStart + unrolled + 0.01, reveal: true), .open)
        XCTAssertEqual(A.fortuneStage(elapsed: 0, reveal: false), .split(1), "shown again: no whole cookie first")
        XCTAssertEqual(A.fortuneStage(elapsed: unrolled + 0.01, reveal: false), .open)
        XCTAssertEqual(A.fortuneDuration(reveal: true) - A.fortuneDuration(reveal: false), PlazaFortune.splitStart, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(A.fortuneDuration(reveal: false) - unrolled, PlazaFortune.readDuration - 1e-9)
    }

    /// Teammates send the line and action as numbers, so the order of both lists is a wire contract: new entries go at the end only.
    /// When you append, raise the counts and keep the first-80 / first-12 hashes as they are.
    func testTheFirstLinesAndActionsKeepTheirNumbers() async {
        func hash(_ list: ArraySlice<String>) -> UInt64 {
            list.joined(separator: "\n").utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        }
        XCTAssertGreaterThanOrEqual(L(.ko).plazaFortuneLines.count, 80)
        XCTAssertGreaterThanOrEqual(L(.ko).plazaFortuneActions.count, 12)
        XCTAssertEqual(hash(L(.ko).plazaFortuneLines.prefix(80)), 14_248_402_198_470_895_138)
        XCTAssertEqual(hash(L(.ko).plazaFortuneActions.prefix(12)), 4_205_960_783_727_730_735)
    }

    /// A calendar with leap months repeats a month number, and teammates compare the key, so the plaza's day is read in the
    /// Gregorian calendar whatever the device uses.
    func testTheDayKeyIsGregorianOnAnyCalendar() async {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = chinese.timeZone
        let date = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
        XCTAssertEqual(PlazaActivity.dayKey(date, calendar: chinese), "2026-11-23")
    }
}

extension PlazaMapData {
    /// Today's rows as they were before the fortune stall: its 'K' tiles back to grass, and the flower it replaced at (40, 5).
    /// For the tests that pin the map or its picture to an earlier version.
    static var rowsBeforeTheStall: [String] {
        var out = rows.map { $0.replacingOccurrences(of: "K", with: ".") }
        var row = Array(out[5]); row[40] = "f"; out[5] = String(row)
        return out
    }
}
