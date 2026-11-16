import XCTest
@testable import PokeTokenBar

// The Windows popover's recap (stage 7 Task 13): the twin of the Mac's `RecapContent`, the page model and the card part. Shared
// (the Mac and the Windows runner both run it); `PopoverRecapEquivalenceTests+Mac` holds the twin to the Mac's original.
//
// The calendar is fixed (UTC, weeks from Monday unless a test says so) and so is "now" (Friday 18 September 2026, noon), so
// nothing depends on the machine running the suite. The goldens below were read from the Mac's own formatters; on Windows the
// same strings must come out of Foundation's (task 1's probe pinned four languages, these pin all eight).

private let utc = TimeZone(identifier: "UTC")!

private func calendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private let now = date(2026, 9, 18)

private func key(_ date: Date) -> String { LocalUsageReader.localDayFormatter(timeZone: utc).string(from: date) }

private func usage(_ day: String, _ tokens: Int) -> DailyUsage {
    DailyUsage(date: day, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: tokens,
               totalCost: 0, costCoverage: .source)
}

private func ledger(since: Date, _ days: [(Date, Int)]) -> UsageLedger {
    var ledger = UsageLedger()
    ledger.merge([usage(key(since), 0)] + days.map { usage(key($0.0), $0.1) })
    return ledger
}

private struct Golden {
    var week: String, month: String, year: String
    var weekdays: String, months: String
    var day: String, weekBucket: String, yearBucket: String
}

@MainActor
final class PopoverRecapTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("popover-recap-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// A store holding `ledger` and a companion in `language`.
    private func stores(_ ledger: UsageLedger, language: AppLanguage = .en) -> (UsageStore, CompanionStore) {
        let defaults = TestDefaults.make(suite: "popover-recap")
        ledger.save(to: defaults)
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: url, defaults: defaults)
        companion.setLanguage(language)
        return (store, companion)
    }

    private func content(_ s: (UsageStore, CompanionStore), _ scope: RecapScope = .week, offset: Int = 0, now: Date = now,
                         calendar: Calendar = calendar()) -> PopoverRecapContent {
        PopoverRecapContent(store: s.0, companion: s.1, scope: scope, offset: offset, now: now, calendar: calendar)
    }

    private func page(_ s: (UsageStore, CompanionStore), _ scope: RecapScope = .week, offset: Int = 0, now: Date = now) -> RecapPageModel {
        var nav = RecapNavigation()
        nav.select(scope)
        nav.offset = offset
        return RecapPageModel(content(s, scope, offset: offset, now: now), navigation: nav)
    }

    private static let full = ledger(since: date(2026, 8, 1), [(date(2026, 9, 18), 3_000), (date(2026, 9, 17), 5_000), (date(2026, 9, 11), 2_000)])

    // MARK: navigation

    func testNavigationFollowsTheMacsButtons() {
        var nav = RecapNavigation()
        XCTAssertEqual(nav.scope, .week)
        XCTAssertFalse(nav.canGoToCurrent)
        XCTAssertFalse(nav.canGoForward)
        nav.goForward()
        XCTAssertEqual(nav.offset, 0, "the future has no usage")
        nav.goBack(canGoBack: false)
        XCTAssertEqual(nav.offset, 0, "disabled where the ledger has no earlier day")
        nav.goBack(canGoBack: true)
        nav.goBack(canGoBack: true)
        XCTAssertEqual(nav.offset, -2)
        XCTAssertTrue(nav.canGoToCurrent)
        XCTAssertTrue(nav.canGoForward)
        nav.goForward()
        XCTAssertEqual(nav.offset, -1)
        nav.select(.week)
        XCTAssertEqual(nav.offset, -1, "choosing the scope already shown changes nothing")
        nav.select(.month)
        XCTAssertEqual(nav, RecapNavigation(scope: .month, offset: 0), "another scope starts at the running period")
        nav.goBack(canGoBack: true)
        nav.goToCurrent()
        XCTAssertEqual(nav.offset, 0)
    }

    func testAMeterLightsOneSegmentForAnyUsageAndEightForThePeak() {
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 0, peak: 100), 0)
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 1, peak: 1_000_000), 1, "quiet is not nothing")
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 100, peak: 100), 8)
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 50, peak: 100), 4)
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 56, peak: 100), 4)   // 4.48 rounds down
        XCTAssertEqual(PopoverRecapMetrics.lit(tokens: 57, peak: 100), 5)
        XCTAssertEqual(PopoverRecapMetrics.meterSpacing(.week), 6)
        XCTAssertEqual(PopoverRecapMetrics.meterSpacing(.month), 1.5)
        XCTAssertEqual(PopoverRecapMetrics.meterSpacing(.year), 4)
    }

    // MARK: what each data state shows

    func testNoUsageAtAllShowsDashesAndNothingElse() {
        let m = page(stores(UsageLedger()))
        XCTAssertEqual(m.card.total, "0")
        XCTAssertEqual(m.card.unit, "TOKENS")
        XCTAssertNil(m.card.delta)
        XCTAssertEqual(m.card.meters.count, 7)
        XCTAssertTrue(m.card.meters.allSatisfy { $0.lit == 0 && !$0.hasData && $0.description.hasSuffix(", no data") })
        XCTAssertEqual(m.card.readouts, [.init(label: "BEST DAY", value: "--"), .init(label: "BEST STREAK", value: "0d"),
                                         .init(label: "ACTIVE DAYS", value: "0/0"), .init(label: "GRADUATED", value: "0")])
        XCTAssertEqual(m.card.noGraduates, "No graduation in this period.")
        XCTAssertNil(m.bestDayLine)
        XCTAssertNil(m.compareSoFar)
        XCTAssertFalse(m.canGoBack)
        XCTAssertFalse(m.canGoToCurrent)
        XCTAssertFalse(m.canGoForward)
        let ko = page(stores(UsageLedger(), language: .ko))
        XCTAssertEqual(ko.card.readouts.map(\.value), ["--", "0일", "0/0", "0"])
        XCTAssertEqual(ko.card.unit, "토큰")
        XCTAssertNil(ko.bestDayLine)
    }

    func testARunningWeekComparesTheSameDaysOfTheLastOne() {
        let m = page(stores(Self.full))
        XCTAssertEqual(m.card.title, Self.goldens[.en]!.week.uppercased())
        XCTAssertEqual(m.card.total, "8K")
        XCTAssertEqual(m.card.delta?.text, "▲300%")
        XCTAssertEqual(m.card.delta?.up, true)
        XCTAssertEqual(m.card.meters.map(\.lit), [0, 0, 0, 8, 5, 0, 0])
        XCTAssertEqual(m.card.meters.map(\.hasData), [true, true, true, true, true, false, false])
        XCTAssertEqual(m.card.meters.map(\.isCurrent), [false, false, false, false, true, false, false])
        XCTAssertEqual(m.card.readouts.map(\.value), ["5K", "2d", "2/5", "0"])
        XCTAssertEqual(m.bestDayLine, "Your best day was Thursday, Sep 17 — 5,000 tokens.")
        XCTAssertEqual(m.compareSoFar, "Compared with the same days last week")
        XCTAssertTrue(m.canGoBack)
        XCTAssertEqual(m.current, "This week")
        let ko = page(stores(Self.full, language: .ko))
        XCTAssertEqual(ko.card.title, "2026년 9월 14일~20일")
        XCTAssertEqual(ko.bestDayLine, "최고의 날은 9월 17일 목요일 — 5,000 토큰.")
        XCTAssertEqual(ko.compareSoFar, "지난주 같은 기간과 비교")
        let ja = page(stores(Self.full, language: .ja))
        XCTAssertEqual(ja.bestDayLine, "最高の日は 9月17日 木曜日、5,000 トークン。")
    }

    func testAFinishedWeekHasNoSoFarNoteAndAFallHasADownArrow() {
        let s = stores(Self.full)
        let last = page(s, .week, offset: -1)
        XCTAssertNil(last.compareSoFar, "a finished period is compared whole, and the note is only for a running one")
        XCTAssertEqual(last.card.title, content(s, .week, offset: -1).periodLabel().uppercased())
        XCTAssertTrue(last.card.title.hasPrefix("SEP 7"), last.card.title)
        XCTAssertEqual(last.card.total, "2K")
        XCTAssertNil(last.card.delta, "the week before is not covered by the ledger")
        XCTAssertTrue(last.canGoToCurrent)
        XCTAssertTrue(last.canGoForward)
        let falling = stores(ledger(since: date(2026, 8, 1), [(date(2026, 9, 18), 1_000), (date(2026, 9, 17), 1_000), (date(2026, 9, 10), 4_000),
                                                            (date(2026, 9, 9), 4_000)]))
        let m = page(falling)
        XCTAssertEqual(m.card.delta?.text, "▼75%")
        XCTAssertEqual(m.card.delta?.up, false)
    }

    func testTheFirstWeekOfUseClaimsNoJump() {
        let m = page(stores(ledger(since: date(2026, 9, 16), [(date(2026, 9, 18), 3_000), (date(2026, 9, 17), 5_000)])))
        XCTAssertNil(m.card.delta, "days the app never saw would count as zero and invent a jump")
        XCTAssertNil(m.compareSoFar)
        XCTAssertFalse(m.canGoBack)
        XCTAssertEqual(m.card.meters.map(\.hasData), [false, false, true, true, true, false, false], "before the ledger and the future are unknown, not zero")
        XCTAssertEqual(m.card.readouts[2].value, "2/3")
    }

    func testAMissingComparisonAndAMonthAndAYear() {
        let s = stores(Self.full)
        let month = page(s, .month)
        XCTAssertEqual(month.card.title, "SEPTEMBER 2026")
        XCTAssertEqual(month.card.meters.count, 30)
        XCTAssertEqual(month.card.meters.map(\.label).filter { !$0.isEmpty }, ["1", "8", "15", "22", "29"])
        XCTAssertEqual(month.current, "This month")
        XCTAssertEqual(month.card.readouts[2].value, "3/18")
        let year = page(s, .year)
        XCTAssertEqual(year.card.title, "2026")
        XCTAssertEqual(year.card.meters.count, 12)
        XCTAssertEqual(year.card.meters.map(\.lit), [0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0], "September holds all of it")
        XCTAssertEqual(year.current, "This year")
        XCTAssertFalse(year.canGoBack, "the ledger starts in 2026: nothing earlier")
    }

    func testVeryLargeNumbersAreGroupedByTheRegionAndCompactedByTheApp() {
        let big = 12_345_678_901
        let m = page(stores(ledger(since: date(2026, 8, 1), [(date(2026, 9, 18), big), (date(2026, 9, 11), 2_000)])))
        XCTAssertEqual(m.card.total, "12.35B")
        XCTAssertEqual(m.card.readouts[0].value, "12.35B")
        XCTAssertEqual(m.bestDayLine, "Your best day was Friday, Sep 18 — \(TokenFormatter.grouped(big)) tokens.")
        XCTAssertEqual(m.card.delta?.text, "▲\(TokenFormatter.percent((Double(big) - 2_000) / 2_000 * 100))")
        XCTAssertFalse(TokenFormatter.grouped(big).isEmpty)
    }

    // MARK: the eight languages

    private static let goldens: [AppLanguage: Golden] = [
        .ko: Golden(week: "2026년 9월 14일~20일", month: "2026년 9월", year: "2026",
                   weekdays: "월|화|수|목|금|토|일", months: "1월|2월|3월|4월|5월|6월|7월|8월|9월|10월|11월|12월",
                   day: "9월 17일 목요일", weekBucket: "9월 14일 월요일, 0", yearBucket: "2026년 1월, 기록 없음"),
        .en: Golden(week: "Sep 14 – 20, 2026", month: "September 2026", year: "2026",
                   weekdays: "MO|TU|WE|TH|FR|SA|SU", months: "J|F|M|A|M|J|J|A|S|O|N|D",
                   day: "Thursday, Sep 17", weekBucket: "Monday, Sep 14, 0", yearBucket: "January 2026, no data"),
        .ja: Golden(week: "2026年9月14日～20日", month: "2026年9月", year: "2026",
                   weekdays: "月|火|水|木|金|土|日", months: "1|2|3|4|5|6|7|8|9|10|11|12",
                   day: "9月17日 木曜日", weekBucket: "9月14日 月曜日, 0", yearBucket: "2026年1月, 記録なし"),
        .es: Golden(week: "14 – 20 sept 2026", month: "septiembre de 2026", year: "2026",
                   weekdays: "LU|MA|MI|JU|VI|SÁ|DO", months: "E|F|M|A|M|J|J|A|S|O|N|D",
                   day: "jueves, 17 sept", weekBucket: "lunes, 14 sept, 0", yearBucket: "enero de 2026, sin datos"),
        .fr: Golden(week: "14–20 sept. 2026", month: "septembre 2026", year: "2026",
                   weekdays: "LU|MA|ME|JE|VE|SA|DI", months: "J|F|M|A|M|J|J|A|S|O|N|D",
                   day: "jeudi 17 sept.", weekBucket: "lundi 14 sept., 0", yearBucket: "janvier 2026, pas de données"),
        .pt: Golden(week: "14 – 20 de set. de 2026", month: "setembro de 2026", year: "2026",
                   weekdays: "SE|TE|QU|QU|SE|SÁ|DO", months: "J|F|M|A|M|J|J|A|S|O|N|D",
                   day: "quinta-feira, 17 de set.", weekBucket: "segunda-feira, 14 de set., 0", yearBucket: "janeiro de 2026, sem dados"),
        .de: Golden(week: "14.–20. Sept. 2026", month: "September 2026", year: "2026",
                   weekdays: "MO|DI|MI|DO|FR|SA|SO", months: "J|F|M|A|M|J|J|A|S|O|N|D",
                   day: "Donnerstag, 17. Sept.", weekBucket: "Montag, 14. Sept., 0", yearBucket: "Januar 2026, keine Daten"),
        .ru: Golden(week: "14—20 сент. 2026 г.", month: "сентябрь 2026 г.", year: "2026",
                   weekdays: "ПН|ВТ|СР|ЧТ|ПТ|СБ|ВС", months: "Я|Ф|М|А|М|И|И|А|С|О|Н|Д",
                   day: "четверг, 17 сент.", weekBucket: "понедельник, 14 сент., 0", yearBucket: "январь 2026 г., нет данных"),
    ]

    func testEveryLanguageReadsTheMacsDatesAndLabels() {
        XCTAssertEqual(Self.goldens.count, AppLanguage.allCases.count)
        let s = stores(Self.full)
        for language in AppLanguage.allCases {
            s.1.setLanguage(language)
            let g = Self.goldens[language]!
            let week = content(s, .week), month = content(s, .month), year = content(s, .year)
            XCTAssertEqual(week.periodLabel(), g.week, "\(language) week")
            XCTAssertEqual(month.periodLabel(), g.month, "\(language) month")
            XCTAssertEqual(year.periodLabel(), g.year, "\(language) year")
            XCTAssertEqual(week.bucketLabels().joined(separator: "|"), g.weekdays, "\(language) weekdays")
            XCTAssertEqual(year.bucketLabels().joined(separator: "|"), g.months, "\(language) months")
            XCTAssertEqual(week.dayLabel("2026-09-17"), g.day, "\(language) day")
            XCTAssertEqual(week.accessibilityLabel(week.recap.buckets[0]), g.weekBucket, "\(language) a week's bucket")
            XCTAssertEqual(year.accessibilityLabel(year.recap.buckets[0]), g.yearBucket, "\(language) a year's bucket")
        }
    }

    // MARK: week and year boundaries

    func testWeeksFollowTheFirstWeekdayAndCrossTheYear() {
        let s = stores(ledger(since: date(2026, 8, 1), [(date(2027, 1, 2), 100)]))
        let saturday = date(2027, 1, 2)
        // Monday start: 28 Dec - 3 Jan; Sunday start: 27 Dec - 2 Jan; Saturday start: 2 - 8 Jan.
        let spans: [(Int, String, String)] = [(2, "2026-12-28", "2027-01-03"), (1, "2026-12-27", "2027-01-02"), (7, "2027-01-02", "2027-01-08")]
        for (firstWeekday, start, last) in spans {
            let c = content(s, .week, now: saturday, calendar: calendar(firstWeekday: firstWeekday))
            let lastDay = calendar().date(byAdding: .day, value: -1, to: c.recap.period.end)!
            XCTAssertEqual(key(c.recap.period.start), start, "first weekday \(firstWeekday)")
            XCTAssertEqual(key(lastDay), last, "first weekday \(firstWeekday)")
            XCTAssertEqual(c.recap.buckets.count, 7)
            XCTAssertEqual(c.recap.buckets.first?.key, start)
            XCTAssertEqual(c.bucketLabels().first, ["MO", "SU", "SA"][[2, 1, 7].firstIndex(of: firstWeekday)!], "the first meter is the first weekday")
        }
        let across = content(s, .week, now: saturday).periodLabel()
        XCTAssertTrue(across.contains("2026") && across.contains("2027"), across)
        XCTAssertTrue(content(s, .week, now: saturday, calendar: calendar(firstWeekday: 7)).periodLabel().contains("2027"))
        XCTAssertEqual(content(s, .month, offset: -1, now: saturday).periodLabel(), "December 2026")
        XCTAssertEqual(content(s, .year, offset: -1, now: saturday).periodLabel(), "2026")
        XCTAssertEqual(content(s, .year, now: saturday).periodLabel(), "2027")
    }

    // MARK: the card part

    private let graphics = PlatformPlaza.graphics

    private func render(_ model: RecapCardModel, width: CGFloat = 332, scale: CGFloat = 1) -> (RecapCardPart, PopoverDrawing, RecapCardPart.Layout) {
        let part = RecapCardPart(model)
        let size = part.size(width: width, scale: scale, text: graphics.text)
        XCTAssertEqual(size, CGSize(width: width, height: 226))
        return (part, part.render(scale: scale, graphics: graphics), part.layout(width: width, text: graphics.text))
    }

    func testTheCardFitsItsFrameInEveryScopeAndLanguage() {
        for language in [AppLanguage.en, .ko, .de, .ru] {
            let s = stores(Self.full, language: language)
            for scope in RecapScope.allCases {
                let model = RecapCardModel(content(s, scope))
                let (_, drawing, l) = render(model)
                let frame = CGRect(origin: .zero, size: l.size).insetBy(dx: -0.01, dy: -0.01)
                for r in [l.screen, l.strip, l.companion] + l.columns + l.readouts {
                    XCTAssertTrue(frame.contains(r), "\(language) \(scope): \(r) leaves the card")
                }
                XCTAssertEqual(l.columns.count, model.meters.count)
                XCTAssertEqual(drawing.drawing.tooltips.count, model.meters.count, "one tooltip per meter")
                for (i, tip) in drawing.drawing.tooltips.enumerated() { XCTAssertEqual(tip.text, model.meters[i].description) }
                // The meters sit in the screen, in order, and do not overlap.
                for (a, b) in zip(l.columns, l.columns.dropFirst()) { XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.001) }
                XCTAssertTrue(l.screen.insetBy(dx: -0.01, dy: -0.01).contains(l.columns.first!))
                XCTAssertTrue(l.screen.insetBy(dx: -0.01, dy: -0.01).contains(l.columns.last!))
                // The static texts of the card do not overlap each other (a Windows host makes a child control of each) and none
                // covers a sprite slot (the host paints the sprites over the picture, under such controls).
                let items = drawing.drawing.accessibility
                for i in items.indices {
                    for j in items.indices where j > i {
                        XCTAssertTrue(items[i].frame.insetBy(dx: 0.5, dy: 0.5).intersection(items[j].frame.insetBy(dx: 0.5, dy: 0.5)).isNull,
                                      "\(language) \(scope): '\(items[i].label)' overlaps '\(items[j].label)'")
                    }
                    for slot in drawing.spriteSlots {
                        XCTAssertTrue(items[i].frame.intersection(slot.frame).isNull, "\(language) \(scope): '\(items[i].label)' covers a sprite")
                    }
                }
                XCTAssertEqual(drawing.spriteSlots.count, 1 + model.graduates.count)
            }
        }
    }

    func testTheCardAccessibilityReadsEveryNumberAndTheMetersTheirDescription() {
        let s = stores(Self.full)
        let model = RecapCardModel(content(s))
        let (_, drawing, _) = render(model)
        let labels = drawing.drawing.accessibility.map(\.label)
        XCTAssertTrue(labels.contains(Self.goldens[.en]!.week.uppercased()))
        XCTAssertTrue(labels.contains("8K TOKENS"))
        XCTAssertTrue(labels.contains("▲300%"))
        XCTAssertTrue(labels.contains("BEST DAY 5K"))
        XCTAssertTrue(labels.contains("ACTIVE DAYS 2/5"))
        XCTAssertTrue(labels.contains("No graduation in this period."))
        XCTAssertTrue(labels.contains("Thursday, Sep 17, 5,000"))
        XCTAssertTrue(labels.contains { $0.hasSuffix(", no data") }, "the unknown days say so")
        XCTAssertEqual(drawing.drawing.accessibility.count, 3 + model.meters.count + 4 + 1)
        XCTAssertEqual(drawing.spriteSlots.first?.subject, PlazaSpriteSubjectKey(speciesID: nil), "no companion yet: the egg")
        XCTAssertEqual(drawing.spriteSlots.first?.animated, false)
    }

    func testTheCardIsDrawnWithTheMacsColoursAndSegments() throws {
        let s = stores(Self.full)
        let model = RecapCardModel(content(s))
        for scale in [CGFloat(1), 2] {
            let (_, drawing, l) = render(model, scale: scale)
            guard case .image(let image, let frame)? = drawing.drawing.layers.first else { return XCTFail("no image layer") }
            XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 332, height: 226))
            XCTAssertEqual(image.width, Int(332 * scale))
            func px(_ p: CGPoint) -> PlazaRGBA { image.pixels[Int(p.x * scale), Int(p.y * scale)] }
            func near(_ p: PlazaRGBA, _ r: Int, _ g: Int, _ b: Int, _ what: String, tolerance: Int = 4) {
                for (got, want) in zip([Int(p.r), Int(p.g), Int(p.b)], [r, g, b]) {
                    XCTAssertLessThanOrEqual(abs(got - want), tolerance, "\(what) at scale \(scale): \([p.r, p.g, p.b]) vs \([r, g, b])")
                }
            }
            // the peak day (Thursday 17) is lit to the top at full height, the current day (Friday) at 55 % + current = full strength
            let peak = model.meters.firstIndex { $0.lit == 8 }!
            let bottom = l.blockRects[peak].last!
            near(px(CGPoint(x: bottom.midX, y: bottom.midY)), 0x82 * 55 / 100 + 13 * 45 / 100, 0xFA * 55 / 100 + 18 * 45 / 100, 0x9E * 55 / 100 + 20 * 45 / 100, "a lit block of a past day (LCD at 55 % over the ink)", tolerance: 6)
            let today = model.meters.firstIndex { $0.isCurrent }!
            let currentBottom = l.blockRects[today].last!
            near(px(CGPoint(x: currentBottom.midX, y: currentBottom.midY)), 0x82, 0xFA, 0x9E, "a lit block of today (the LCD green)")
            // an unlit block of a known day is the ink with 9 % LCD, of an unknown day 3.5 %
            let known = l.blockRects[0][0]
            near(px(CGPoint(x: known.midX, y: known.midY)), 13 + (130 - 13) * 9 / 100, 18 + (250 - 18) * 9 / 100, 20 + (158 - 20) * 9 / 100, "an unlit block of a known day")
            let unknown = l.blockRects[6][0]
            near(px(CGPoint(x: unknown.midX, y: unknown.midY)), 13 + (130 - 13) * 35 / 1000, 18 + (250 - 18) * 35 / 1000, 20 + (158 - 20) * 35 / 1000, "an unlit block of an unknown day", tolerance: 5)
            // the case: red at the top, darker at the bottom, the hinge side darker still
            let top = px(CGPoint(x: 166, y: 3)), bottomShell = px(CGPoint(x: 166, y: 222))
            near(top, 214, 54, 46, "the case at the top", tolerance: 8)
            XCTAssertLessThan(bottomShell.r, top.r)
            XCTAssertLessThan(px(CGPoint(x: 2, y: 100)).r, px(CGPoint(x: 8, y: 100)).r, "the hinge side is darker")
            // outside the rounded corner nothing is drawn
            XCTAssertEqual(px(CGPoint(x: 0, y: 0)).a, 0)
        }
    }

    func testTheCardIsUpdatedInPlaceOnlyWhenSomethingDiffers() {
        let s = stores(Self.full)
        let model = RecapCardModel(content(s))
        let part = RecapCardPart(model)
        var changes = 0
        part.onChange = { changes += 1 }
        part.update(model)
        XCTAssertEqual(changes, 0)
        part.update(RecapCardModel(content(s, .month)))
        XCTAssertEqual(changes, 1)
        part.update(RecapCardModel(content(s, .month)))
        XCTAssertEqual(changes, 1)
    }

    func testTheDeltaChipAndGraduatesAreDrawn() {
        let dex = [DexEntry(id: "a", baseID: 10, finalID: 10, chainOrder: [10], rarity: .common, caughtAt: date(2026, 9, 17),
                            isShiny: true, names: [10: ["en": "Caterpie"]]),
                   DexEntry(id: "b", baseID: 25, finalID: 26, chainOrder: [25, 26], rarity: .rare, caughtAt: date(2026, 9, 15),
                            names: [26: ["en": "Raichu"]])]
        let json = String(decoding: try! JSONEncoder().encode(dex), as: UTF8.self)
        try? Data(#"{"installBaselineSet":true,"usedSinceInstall":1000,"lastDate":"d","dex":\#(json)}"#.utf8).write(to: url)
        let s = stores(Self.full)
        let model = RecapCardModel(content(s))
        XCTAssertEqual(model.graduates.map(\.speciesID), [10, 26])
        XCTAssertEqual(model.graduates.map(\.isShiny), [true, false])
        XCTAssertEqual(model.readouts[3].value, "2")
        let (_, drawing, l) = render(model)
        XCTAssertEqual(l.chips.count, 2)
        XCTAssertEqual(drawing.spriteSlots.count, 3)
        XCTAssertEqual(drawing.spriteSlots[1].subject, PlazaSpriteSubjectKey(speciesID: 10, shiny: true))
        XCTAssertNotNil(l.chip, "the delta chip has a box")
        XCTAssertTrue(drawing.drawing.accessibility.map(\.label).contains("Caterpie"))
        for chip in l.chips { XCTAssertTrue(chip.box.maxX <= l.strip.maxX + 0.01) }
    }
}
