import XCTest
@testable import PokeTokenBar

/// Stage 7 Task 12: the activity panel's models and parts (`PopoverActivityModel`, `TrendBarsPart`, `HeatmapPart`,
/// `StreakPart`) on whichever canvas runs: the data states, the hover and keyboard contract, the card, the accessible text
/// and the redraw cost of a hover. The numbers against the Mac's own are `PopoverTrendTwinTests+Mac`.
@MainActor
final class PopoverActivityTests: XCTestCase {
    private let today = "2026-07-15"

    private func usage(_ date: String, _ tokens: Int, cost: Double = 0) -> DailyUsage {
        DailyUsage(date: date, inputTokens: 0, outputTokens: tokens, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: tokens, totalCost: cost)
    }

    private func month(_ values: [Int: Int]) -> [DailyUsage] {
        values.keys.sorted().map { usage(String(format: "2026-07-%02d", $0), values[$0] ?? 0, cost: Double(values[$0] ?? 0) / 1e6) }
    }

    private func facts(firstWeekday: Int) -> PopoverPlatformFacts {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = firstWeekday
        cal.locale = Locale(identifier: "en_US")
        return .windows(regionLocale: Locale(identifier: "en_US"), regionCalendar: cal)
    }

    private func input(_ values: [Int: Int], visualization: ActivityVisualization = .monthlyBars, firstWeekday: Int = 2) -> ActivityInput {
        var i = ActivityInput()
        i.series = month(values)
        i.heatmapSeries = i.series
        i.today = today
        i.visualization = visualization
        i.facts = facts(firstWeekday: firstWeekday)
        i.window = .month
        return i
    }

    private func bars(_ values: [Int: Int]) throws -> TrendBarsModel {
        guard case .bars(let m)? = ActivityPanelModel.make(input(values)).content else { throw XCTSkip("no bars") }
        return m
    }

    // MARK: data states

    func testNoDataShowsNothingLikeTheMac() async {
        for v in ActivityVisualization.allCases {
            let m = ActivityPanelModel.make(input([:], visualization: v))
            XCTAssertNil(m.content, "\(v): a first run with no usage draws nothing, as the Mac's panel")
            XCTAssertNil(m.streak)
        }
        // History in another window keeps the caption (the window can be chosen) but no bars.
        var i = input([:])
        i.hasAvailableHistory = true
        guard case .bars(let m)? = ActivityPanelModel.make(i).content else { return XCTFail("caption only expected") }
        XCTAssertFalse(m.showsBars)
        XCTAssertTrue(m.columns.isEmpty)
    }

    func testOneDayHidesThePeakAndAMonthWithGapsKeepsEveryColumn() async throws {
        let one = try bars([15: 5_000])
        XCTAssertNil(one.peakText, "a single used day: the peak equals the readout")
        XCTAssertEqual(one.columns.count, 31)
        XCTAssertEqual(one.columns.filter(\.isFuture).count, 16)
        XCTAssertEqual(one.columns.first { $0.isToday }?.date, today)
        let gaps = try bars([1: 100, 3: 0, 5: 800, 9: 100_000_000, 15: 2_000])
        XCTAssertNotNil(gaps.peakText)
        XCTAssertEqual(gaps.columns.first { $0.date == "2026-07-03" }?.height, PopoverTrendMetrics.baseline)
        XCTAssertTrue(gaps.columns.first { $0.date == "2026-07-03" }?.isEmpty == true)
        XCTAssertEqual(gaps.columns.first { $0.date == "2026-07-09" }?.height, PopoverTrendMetrics.track, "the spike fills the track")
        XCTAssertEqual(gaps.columns.first { $0.date == "2026-07-05" }?.height, PopoverTrendMetrics.baseline, "a tiny day keeps the floor")
        XCTAssertEqual(gaps.columns.first { $0.date == "2026-07-20" }?.height, 0, "a future day is blank")
    }

    func testTheStreakShowsFromTwoDays() async {
        for (days, shown) in [(0, false), (1, false), (2, true), (9, true)] {
            var i = input([15: 1])
            i.streak = UsageStreak(days: days, includesToday: true)
            XCTAssertEqual(ActivityPanelModel.make(i).streak != nil, shown, "\(days) days")
        }
        var i = input([15: 1])
        i.streak = UsageStreak(days: 4, includesToday: false)
        let pending = ActivityPanelModel.make(i).streak
        XCTAssertEqual(pending?.label, L(.en).streakDaysPending(4))
    }

    func testTheHeatmapStartsItsRowsOnTheRegionsFirstWeekday() async throws {
        var labels: [Int: [String]] = [:]
        for first in [1, 2] {
            guard case .heatmap(let h)? = ActivityPanelModel.make(input([1: 10, 15: 20], visualization: .recentHeatmap, firstWeekday: first)).content else {
                return XCTFail("heatmap expected")
            }
            labels[first] = h.weekdayLabels
            XCTAssertEqual(h.columns.count, PopoverHeatmapMetrics.weeks)
            XCTAssertTrue(h.columns.allSatisfy { $0.count == 7 })
            let todayCell = h.columns.joined().first { $0.isToday }
            XCTAssertNotNil(todayCell)
        }
        XCTAssertEqual(labels[2]?.first, "M")
        XCTAssertEqual(labels[1]?.first, "S")
        XCTAssertNotEqual(labels[1], labels[2])
        XCTAssertEqual(labels[1]?.last, "S")
        XCTAssertEqual(labels[2]?.last, "S")
    }

    // MARK: the legend wraps like WrappingHStack

    func testTheLegendWrapsAtTheWidth() async {
        let frames = PopoverWrapLayout.arrange([CGSize(width: 100, height: 10), CGSize(width: 100, height: 10), CGSize(width: 100, height: 10)],
                                               width: 250, spacing: 8, lineSpacing: 2)
        XCTAssertEqual(frames.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 108, y: 0), CGPoint(x: 0, y: 12)])
        XCTAssertEqual(PopoverWrapLayout.size(of: frames), CGSize(width: 208, height: 22))
        XCTAssertEqual(PopoverWrapLayout.arrange([], width: 10, spacing: 1, lineSpacing: 1), [])
    }

    // MARK: the bars part

    private func part(_ values: [Int: Int], stacked: Bool = false) throws -> TrendBarsPart {
        var i = input(values)
        if stacked {
            i.providerOrder = ["a", "b"]
            i.providers = [DailyTrendStack.ProviderSeries(id: "a", name: "Alpha", days: i.series, reportsCost: true),
                           DailyTrendStack.ProviderSeries(id: "b", name: "Beta", days: i.series.map { usage($0.date, $0.totalTokens / 2) }, reportsCost: false)]
        }
        let made = ActivityPanelModel.make(i)
        guard case .bars(let m)? = made.content else { throw XCTSkip("no bars") }
        return TrendBarsPart(m, cardInfo: made.cardInfo)
    }

    func testHoverRedrawsOnlyTheColumnsAndMakesNoText() async throws {
        let part = try part([1: 100, 5: 800, 9: 100_000_000, 15: 2_000], stacked: true)
        let graphics = PlatformPlaza.graphics
        _ = part.size(width: 332, scale: 1, text: graphics.text)
        let first = part.render(scale: 1, graphics: graphics)
        XCTAssertNil(first.dirty, "the first render paints everything")
        part.drawing.resetCounts()
        var changes = 0
        part.onChange = { changes += 1 }
        let layout = part.size(width: 332, scale: 1, text: graphics.text)
        XCTAssertGreaterThan(layout.height, 60, "caption, bars, ticks, axis and the stacked legend")
        // Over the 9th column, in the bars band.
        let step = (332 - PopoverTrendMetrics.spacing * 30) / 31 + PopoverTrendMetrics.spacing
        let y = 4 + ActivityDrawing.lineHeight(10, text: graphics.text) + 3 + 10
        part.pointerMoved(CGPoint(x: step * 8.5, y: y))
        XCTAssertEqual(part.selectedDate, "2026-07-09")
        XCTAssertEqual(changes, 1)
        let hovered = part.render(scale: 1, graphics: graphics)
        let dirty = try XCTUnwrap(hovered.dirty, "a hover reports the part it changed")
        XCTAssertLessThan(dirty.width, 20)
        XCTAssertLessThan(dirty.height * dirty.width, 332 * layout.height / 10)
        XCTAssertEqual(part.drawing.madeTexts, 0, "no text is made again for a hover")
        XCTAssertLessThanOrEqual(part.drawing.made, 2, "only the bars it changes are drawn again")
        // The same column again changes nothing.
        part.pointerMoved(CGPoint(x: step * 8.5 + 1, y: y))
        XCTAssertEqual(changes, 1)
        // Leaving the part clears the selection; a future day and the caption are not targets.
        part.pointerMoved(nil)
        XCTAssertNil(part.selectedDate)
        part.pointerMoved(CGPoint(x: step * 25.5, y: y))
        XCTAssertNil(part.selectedDate, "a future day is not a hover target")
        part.pointerMoved(CGPoint(x: step * 8.5, y: 2))
        XCTAssertNil(part.selectedDate)
        // As the Mac: the target is the bar itself. Day 1 (100 tokens) is a floor tick; above it nothing is hovered.
        part.pointerMoved(CGPoint(x: 1, y: y))
        XCTAssertNil(part.selectedDate, "above a short bar is not the bar")
    }

    func testTheCardNamesTheDayAndEachProvider() async throws {
        let part = try part([9: 100_000_000, 15: 2_000], stacked: true)
        let graphics = PlatformPlaza.graphics
        _ = part.size(width: 332, scale: 1, text: graphics.text)
        XCTAssertNil(part.card(scale: 1, graphics: graphics), "no card without a selection")
        XCTAssertTrue(part.key(PopoverKey.end))
        let card = try XCTUnwrap(part.card(scale: 1, graphics: graphics))
        XCTAssertFalse(card.drawing.layers.isEmpty)
        XCTAssertLessThan(card.frame.minY, 0, "the card floats above the bars, over the caption")
        XCTAssertGreaterThanOrEqual(card.frame.minX + TrendBarsPart.cardRoom, 0, "clamped at the left edge")
        XCTAssertLessThanOrEqual(card.frame.maxX - TrendBarsPart.cardRoom, 332 + 0.5, "clamped at the right edge")
        XCTAssertTrue(part.accessibleName.contains("Alpha"), part.accessibleName)
        XCTAssertTrue(part.accessibleName.contains("Beta"), part.accessibleName)
    }

    func testArrowKeysWalkTheSelectableDaysAndEscapeClears() async throws {
        let part = try part([1: 100, 5: 800, 15: 2_000])
        _ = part.size(width: 332, scale: 1, text: PlatformPlaza.graphics.text)
        XCTAssertFalse(part.key(PopoverKey.escape), "nothing to clear: the popover's own Escape runs")
        XCTAssertTrue(part.key(PopoverKey.left))
        XCTAssertEqual(part.keyboardDate, today, "the first arrow selects today")
        XCTAssertTrue(part.key(PopoverKey.right))
        XCTAssertEqual(part.keyboardDate, today, "the future is not selectable")
        XCTAssertTrue(part.key(PopoverKey.left))
        XCTAssertEqual(part.keyboardDate, "2026-07-14")
        XCTAssertTrue(part.key(PopoverKey.home))
        XCTAssertEqual(part.keyboardDate, "2026-07-01")
        XCTAssertTrue(part.key(PopoverKey.left))
        XCTAssertEqual(part.keyboardDate, "2026-07-01", "stops at the first day")
        XCTAssertTrue(part.key(PopoverKey.end))
        XCTAssertEqual(part.keyboardDate, today)
        XCTAssertFalse(part.key(0x41), "other keys are not ours")
        let bottom = 4 + ActivityDrawing.lineHeight(10, text: PlatformPlaza.graphics.text) + 3 + PopoverTrendMetrics.track
        part.pointerMoved(CGPoint(x: 1, y: bottom - 0.5))
        XCTAssertEqual(part.selectedDate, "2026-07-01", "the pointer wins while it is over a day")
        part.pointerMoved(nil)
        XCTAssertEqual(part.selectedDate, today)
        XCTAssertTrue(part.key(PopoverKey.escape))
        XCTAssertNil(part.keyboardDate)
        part.focusChanged(false)
    }

    func testTheItemsCarryTheSummaryTheTitleMenuAndTheSwitchHint() async throws {
        let part = try part([1: 100, 5: 800, 15: 2_000])
        let graphics = PlatformPlaza.graphics
        _ = part.size(width: 332, scale: 1, text: graphics.text)
        let drawing = part.render(scale: 1, graphics: graphics).drawing
        XCTAssertEqual(drawing.accessibility.map(\.role), [.button, .button])
        XCTAssertEqual(drawing.accessibility.map { $0.action?.action }, ["window", "cycle"], "the title first, then the chart: reading order")
        let panel = drawing.accessibility[1]
        let title = drawing.accessibility[0]
        XCTAssertGreaterThanOrEqual(panel.frame.minY, title.frame.maxY - 0.001, "the two buttons touch and never overlap (their edges meet; CGRect.intersects counts that on Windows)")
        XCTAssertGreaterThan(panel.frame.height, 40, "the chart's button is the whole band under the caption")
        XCTAssertTrue(panel.label.contains(L(.en).title(for: .month)), panel.label)
        XCTAssertTrue(panel.label.contains("Peak"), panel.label)
        XCTAssertEqual(panel.value, L(.en).activitySwitchHint)
        XCTAssertEqual(title.label, L(.en).dailyTrendPeriod)
        XCTAssertEqual(part.hit(CGPoint(x: 100, y: 40))?.action, "cycle")
        XCTAssertEqual(part.hit(CGPoint(x: 5, y: 10))?.action, "window")
        XCTAssertEqual(drawing.tooltips.map(\.text), [L(.en).activitySwitchHint])
    }

    // MARK: the heatmap and the streak parts

    func testTheHeatmapHoverChangesOnlyTheReadout() async throws {
        let made = ActivityPanelModel.make(input([1: 100, 5: 800, 15: 2_000], visualization: .recentHeatmap))
        guard case .heatmap(let m)? = made.content else { return XCTFail("heatmap expected") }
        let part = HeatmapPart(m, readout: made.heatReadout)
        let graphics = PlatformPlaza.graphics
        let size = part.size(width: 332, scale: 1, text: graphics.text)
        XCTAssertEqual(size.height, 4 + ActivityDrawing.lineHeight(10, text: graphics.text) + 3 + 7 * 10 + 6 * 2)
        _ = part.render(scale: 1, graphics: graphics)
        part.drawing.resetCounts()
        let todayColumn = try XCTUnwrap(m.columns.firstIndex { $0.contains { $0.isToday } })
        let todayRow = try XCTUnwrap(m.columns[todayColumn].firstIndex { $0.isToday })
        let layout = CGPoint(x: 0, y: 0)
        _ = layout
        XCTAssertEqual(part.shownReadout, m.readout, "today's readout until something is hovered")
        // Walk to an earlier day by the keyboard: the caption follows, the picture does not.
        XCTAssertTrue(part.key(PopoverKey.left))
        XCTAssertEqual(part.keyboardDate, today)
        XCTAssertTrue(part.key(PopoverKey.left))
        XCTAssertNotEqual(part.keyboardDate, today)
        XCTAssertNotEqual(part.shownReadout, m.readout)
        XCTAssertTrue(part.shownReadout.contains("0"), part.shownReadout)
        let hovered = part.render(scale: 1, graphics: graphics)
        XCTAssertNotNil(hovered.dirty)
        XCTAssertLessThan(hovered.dirty?.height ?? 99, 20, "only the caption")
        XCTAssertLessThanOrEqual(part.drawing.made, 1, "one text made for the new readout, no grid")
        XCTAssertTrue(part.accessibleName.contains(part.shownReadout))
        XCTAssertGreaterThanOrEqual(todayRow, 0)
    }

    func testTheStreakPartSaysItsLabel() async {
        let part = StreakPart(StreakModel(days: 5, includesToday: true, label: "5-day streak"))
        let graphics = PlatformPlaza.graphics
        let size = part.size(width: 332, scale: 1, text: graphics.text)
        XCTAssertLessThan(size.width, 60, "as wide as its content")
        let d = part.render(scale: 1, graphics: graphics)
        XCTAssertEqual(d.drawing.accessibility.map(\.label), ["5-day streak"])
        XCTAssertEqual(d.drawing.tooltips.map(\.text), ["5-day streak"])
        XCTAssertEqual(d.drawing.accessibility[0].frame.minX, 0)
        XCTAssertLessThanOrEqual(d.drawing.accessibility[0].frame.maxX, size.width + 0.5)
    }
}
