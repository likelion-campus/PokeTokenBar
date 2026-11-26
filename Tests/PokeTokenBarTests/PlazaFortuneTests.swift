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

    func testEveryRowOfALineAndEveryActionFitsTheSlip() async {
        XCTAssertEqual(Set(PlazaFortune.lines).count, PlazaFortune.lines.count, "no line twice")
        for line in PlazaFortune.lines {
            let rows = PlazaFortuneArt.rows(line)
            XCTAssertTrue((1...2).contains(rows.count), line)
            XCTAssertEqual(rows.joined(separator: "\n"), line, "no empty row")
            for row in rows { XCTAssertLessThanOrEqual(PlazaFortuneArt.textWidth(row), PlazaFortuneArt.maxTextWidth, row) }
        }
        for action in PlazaFortune.actions {
            let text = L(.ko).plazaFortuneAction(action)
            XCTAssertLessThanOrEqual(PlazaFortuneArt.textWidth(text), PlazaFortuneArt.maxTextWidth, text)
        }
    }

    /// The bar for a fortune (see `PlazaFortune.lines`): a line is never about a chore, a work tool or the app itself. The list was once
    /// grown from 80 to 200 with such lines ("메일 답장이 금방 끝날 거예요"). A word here is matched at the start of a word of the line.
    /// A slip may speak of itself (쿠키, 쪽지), as a real one does.
    func testNoLineIsAboutAChoreAToolOrTheApp() async {
        let banned = ["메일", "회의", "퇴근", "출근", "점심", "마감", "메모", "알림", "책상", "저장", "목록", "커밋", "빌드", "배포", "코드", "버그",
                      "테스트", "리뷰", "리팩터링", "토큰", "프롬프트", "캐시", "로그", "변수", "주석", "문서", "에이전트", "단축키", "검색",
                      "광장", "가판대", "온천", "모닥불", "연못", "풀숲", "쉼터", "소식판", "포켓몬", "도감", "팀원"]
        for line in PlazaFortune.lines {
            for word in line.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                XCTAssertNil(banned.first { word.hasPrefix($0) }, line)
            }
        }
        XCTAssertFalse(PlazaFortune.lines.contains { $0.contains { $0.isASCII && $0.isLetter } }, "no Latin word (PR, CI) on a slip")
    }

    /// A slip is drawn to cheer up (see `PlazaFortune.lines`). A one-row line that ends as an instruction ("고마운 마음을 전해 보세요") has
    /// no room for a promise: it only hands the reader a task. A two-row line may end with one when its other row promises something.
    func testNoOneRowLineIsOnlyAnInstruction() async {
        for line in PlazaFortune.lines where PlazaFortuneArt.rows(line).count == 1 {
            XCTAssertFalse(line.hasSuffix("세요"), line)
        }
        // The lines the product owner named, and their kind: a literal event, a lesson, the cookie vouching for itself.
        for gone in ["무지개", "주사위", "가위바위보", "금강산", "신발 끈"] {
            XCTAssertFalse(PlazaFortune.lines.contains { $0.contains(gone) }, gone)
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

    /// A long fortune is two rows: the slip is one row taller, at every stage, and both rows are drawn.
    func testATwoRowLineMakesATallerSlipAndDrawsBothRows() async throws {
        let action = L(.ko).plazaFortuneAction(PlazaFortune.actions[0])
        let a = PlazaFortune.lines[0], b = PlazaFortune.lines[1], c = PlazaFortune.lines[2]
        func image(_ line: String, _ stage: PlazaFortuneArt.Stage = .open) throws -> PlazaImage {
            try XCTUnwrap(PlazaFortuneArt.image(stage, line: line, action: action, scale: 2))
        }
        let one = try image(a), two = try image(a + "\n" + b)
        XCTAssertGreaterThan(two.height, one.height)
        XCTAssertEqual(try image(a + "\n" + b, .whole).height, two.height, "one height, so the picture does not jump")
        XCTAssertNotEqual(try image(a + "\n" + c).pixels, two.pixels, "the second row is drawn")
        XCTAssertNotEqual(try image(c + "\n" + b).pixels, two.pixels, "the first row is drawn")
        XCTAssertTrue(PlazaFortune.lines.contains { PlazaFortuneArt.rows($0).count == 2 }, "the list has two-row lines")
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
    /// When you append, raise the counts and keep the earlier hashes as they are and add one for the new count.
    /// 2.5.639 knows the numbers 0..<80 and 2.5.640 0..<200: a teammate on one of them does not see a slip with a later number.
    /// The release after 2.5.642 rewrote all 300 texts once (the old ones were padded with chores and tips), so a teammate on 2.5.642
    /// or older reads its own text for the same number. The release after 2.5.645 replaced 115 of them once more: the product owner
    /// draws a slip to get through a hard day, and lessons, instructions, random predictions ("무지개를 보게 될 운이에요"), wordplay and
    /// flat well-wishing let the reader down. A number keeps its text otherwise.
    func testTheFirstLinesAndActionsKeepTheirNumbers() async {
        func hash(_ list: ArraySlice<String>) -> UInt64 {
            list.joined(separator: "\n").utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
        }
        XCTAssertGreaterThanOrEqual(L(.ko).plazaFortuneLines.count, 300)
        XCTAssertGreaterThanOrEqual(L(.ko).plazaFortuneActions.count, 12)
        XCTAssertEqual(hash(L(.ko).plazaFortuneLines.prefix(300)), 17_429_527_158_946_108_532, "the 300 lines after the second rewrite")
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
