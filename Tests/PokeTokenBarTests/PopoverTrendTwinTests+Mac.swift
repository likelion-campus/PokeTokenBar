import XCTest
import SwiftUI
@testable import PokeTokenBar

/// Stage 7 Task 12: the shared twins of the activity panel's rules (`PopoverTrendMetrics.swift`) give the Mac's own answers,
/// over the corpora of `MonthDailyTrendTests`, `DailyTrendStackTests` and `ActivityVisualizationTests` (the months, windows,
/// stacks and weeks they use) and over 7 days of the year x 4 windows x 5 time zones x both first weekdays. Mac only: the
/// originals are Mac-only. The text side of the promise is `PopoverParityScanTests.testTwinsMatchTheirOriginals`.
@MainActor
final class PopoverTrendTwinTests: XCTestCase {
    private let zones = ["Asia/Seoul", "America/Los_Angeles", "UTC", "Europe/Berlin", "Pacific/Auckland"].map { TimeZone(identifier: $0)! }
    /// Month ends, a leap day, DST days of Los Angeles (spring forward, fall back), a year boundary.
    private let todays = ["2026-02-28", "2024-02-29", "2026-03-08", "2026-11-01", "2026-01-02", "2025-12-31", "2026-07-15"]

    private func usage(_ date: String, _ tokens: Int, cost: Double = 0) -> DailyUsage {
        DailyUsage(date: date, inputTokens: 0, outputTokens: tokens, cacheCreationTokens: 0, cacheReadTokens: 0,
                   totalTokens: tokens, totalCost: cost)
    }

    /// A series of the last `count` days up to `today` with gaps and a spike.
    private func series(today: String, count: Int) -> [DailyUsage] {
        let f = LocalUsageReader.localDayFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let end = f.date(from: today) else { return [] }
        return (0..<count).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let tokens = offset % 5 == 3 ? 0 : (offset == 4 ? 900_000_000 : 1_000 * (offset + 1) * (offset + 1))
            return usage(f.string(from: d), tokens, cost: Double(tokens) / 1e6)
        }.reversed()
    }

    private func inZone<T>(_ zone: TimeZone, _ body: () throws -> T) rethrows -> T {
        let previousTZ = getenv("TZ").map { String(cString: $0) }
        let previousDefault = NSTimeZone.default
        func apply(_ id: String?, _ z: TimeZone) {
            if let id { setenv("TZ", id, 1) } else { unsetenv("TZ") }
            tzset()
            CFTimeZoneResetSystem()
            NSTimeZone.resetSystemTimeZone()
            NSTimeZone.default = z
        }
        apply(zone.identifier, zone)
        defer { apply(previousTZ, previousDefault) }
        XCTAssertEqual(TimeZone.current.identifier, zone.identifier, "the process zone did not change")
        return try body()
    }

    func testColumnsLabelsTicksAndHeightsMatchAcrossMonthsWindowsZonesAndWeekStarts() {
        var compared = 0
        for zone in zones {
            inZone(zone) {
                for today in todays {
                    for window in DailyTrendWindow.allCases {
                        let data = series(today: today, count: 34)
                        let mac = DailyTrendMetrics.columns(series: data, today: today, window: window)
                        let twin = PopoverTrendMetrics.columns(series: data, today: today, window: window)
                        XCTAssertEqual(mac.map { [$0.date, "\($0.tokens)", "\($0.isFuture)"] }, twin.map { [$0.date, "\($0.tokens)", "\($0.isFuture)"] },
                                       "\(zone.identifier) \(today) \(window)")
                        XCTAssertEqual(mac.map { DailyTrendMetrics.axisLabel(for: $0.date, today: today, window: window) },
                                       twin.map { PopoverTrendMetrics.axisLabel(for: $0.date, today: today, window: window) }, "\(zone.identifier) \(today) \(window) labels")
                        XCTAssertEqual(DailyTrendMetrics.showsPeak(mac), PopoverTrendMetrics.showsPeak(twin))
                        let peak = mac.map(\.tokens).max() ?? 0
                        XCTAssertEqual(mac.map { DailyTrendMetrics.barHeight(tokens: $0.tokens, peak: peak) },
                                       twin.map { PopoverTrendMetrics.barHeight(tokens: $0.tokens, peak: peak) })
                        for firstWeekday in [1, 2] {
                            var cal = Calendar(identifier: .gregorian)
                            cal.timeZone = zone
                            cal.firstWeekday = firstWeekday
                            cal.locale = Locale(identifier: firstWeekday == 1 ? "en_US" : "ko_KR")
                            XCTAssertEqual(mac.map { DailyTrendMetrics.showsWeekendTick($0, calendar: cal) },
                                           twin.map { PopoverTrendMetrics.showsWeekendTick($0, calendar: cal) })
                        }
                        compared += 1
                    }
                }
            }
        }
        XCTAssertEqual(compared, zones.count * todays.count * 4)
        XCTAssertEqual([DailyTrendMetrics.track, DailyTrendMetrics.spacing, DailyTrendMetrics.baseline, DailyTrendMetrics.tickHeight],
                       [PopoverTrendMetrics.track, PopoverTrendMetrics.spacing, PopoverTrendMetrics.baseline, PopoverTrendMetrics.tickHeight])
    }

    func testNoDataOneDayAndASpikeBehaveAsTheMac() {
        let today = "2026-07-15"
        for data in [[DailyUsage](), [usage(today, 5)], [usage("2026-07-10", 5_000_000_000), usage(today, 1)]] {
            for window in DailyTrendWindow.allCases {
                XCTAssertEqual(DailyTrendMetrics.columns(series: data, today: today, window: window).map(\.tokens),
                               PopoverTrendMetrics.columns(series: data, today: today, window: window).map(\.tokens))
            }
        }
        // the gate: every combination of the three inputs
        for peak in [0, 1] {
            for history in [false, true] {
                for selectable in [false, true] {
                    XCTAssertEqual(MonthDailyTrend.shouldShowSurface(peak: peak, hasAvailableHistory: history, isSelectable: selectable),
                                   PopoverTrendSurface.shouldShowSurface(peak: peak, hasAvailableHistory: history, isSelectable: selectable))
                }
            }
        }
        for days in 0...5 {
            for includesToday in [false, true] {
                let s = UsageStreak(days: days, includesToday: includesToday)
                XCTAssertEqual(StreakBadge.isShown(s), PopoverStreak.isShown(s))
            }
        }
        XCTAssertEqual(StreakBadge.minimumDays, PopoverStreak.minimumDays)
    }

    func testReadoutStampAndHoverCardMatchInEveryLanguage() {
        let today = "2026-07-15"
        let data = series(today: today, count: 20)
        let stack = DailyTrendStack.ordered([
            DailyTrendStack.ProviderSeries(id: "a", name: "Alpha", days: data, reportsCost: true),
            DailyTrendStack.ProviderSeries(id: "b", name: "Beta", days: Array(data.prefix(9)), reportsCost: false),
        ])
        for language in AppLanguage.allCases {
            let l = L(language)
            for showsCost in [false, true] {
                XCTAssertEqual(MonthDailyTrend.readout(series: data, today: today, showsCost: showsCost, l: l),
                               PopoverTrendSurface.readout(series: data, today: today, showsCost: showsCost, l: l))
                XCTAssertEqual(MonthDailyTrend.readout(series: data, today: "1999-01-01", showsCost: showsCost, l: l), "")
                for day in [today, data[3].date, "2026-07-30", "2020-01-01"] {
                    for s in [stack, Array(stack.prefix(1)), []] {
                        let mac = DailyTrendHover.info(day: day, series: data, stack: s, showsCost: showsCost, l: l)
                        let twin = PopoverTrendHover.info(day: day, series: data, stack: s, showsCost: showsCost, l: l)
                        XCTAssertEqual(mac.map { "\($0.stamp)|\($0.tokens)|\($0.cost ?? "-")|\($0.providers.map { "\($0.id)\($0.name)\($0.tokens)\($0.cost ?? "-")" })" },
                                       twin.map { "\($0.stamp)|\($0.tokens)|\($0.cost ?? "-")|\($0.providers.map { "\($0.id)\($0.name)\($0.tokens)\($0.cost ?? "-")" })" })
                    }
                }
            }
            XCTAssertEqual(DailyTrendMetrics.dayStamp("2026-07-15", language: language), PopoverTrendMetrics.dayStamp("2026-07-15", language: language))
        }
    }

    func testHeatmapGridLabelsAndLevelsMatchAcrossZonesAndWeekStarts() {
        var compared = 0
        for zone in zones {
            for firstWeekday in 1...7 {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                cal.firstWeekday = firstWeekday
                for today in todays {
                    for since in [nil, "2026-01-01", today] {
                        let days = Dictionary(uniqueKeysWithValues: series(today: today, count: 120).map { ($0.date, $0.totalTokens) })
                        let mac = ActivityHeatmapMetrics.recentGrid(days: days, recordedSince: since, today: today, calendar: cal, timeZone: zone)
                        let twin = PopoverHeatmapMetrics.recentGrid(days: days, recordedSince: since, today: today, calendar: cal, timeZone: zone)
                        XCTAssertEqual(mac.map { $0.map { "\($0.date)|\($0.tokens)|\($0.isOutsideRange)" } },
                                       twin.map { $0.map { "\($0.date)|\($0.tokens)|\($0.isOutsideRange)" } }, "\(zone.identifier) \(firstWeekday) \(today)")
                        XCTAssertEqual(twin.count, PopoverHeatmapMetrics.weeks)
                        compared += 1
                    }
                }
                for language in AppLanguage.allCases where firstWeekday <= 2 {
                    XCTAssertEqual(ActivityHeatmapMetrics.weekdayLabels(firstWeekday: firstWeekday, locale: language.displayLocale),
                                   PopoverHeatmapMetrics.weekdayLabels(firstWeekday: firstWeekday, locale: language.displayLocale))
                }
            }
        }
        XCTAssertGreaterThan(compared, 700)
        for peak in [1, 7, 100, 1_000_000] {
            for tokens in [0, 1, peak / 4, peak / 4 + 1, peak / 2, peak * 3 / 4, peak * 3 / 4 + 1, peak] where tokens <= peak {
                XCTAssertEqual(ActivityHeatmapMetrics.level(tokens: tokens, peak: peak), PopoverHeatmapMetrics.level(tokens: tokens, peak: peak))
            }
        }
        XCTAssertEqual([ActivityHeatmapMetrics.cell, ActivityHeatmapMetrics.spacing, CGFloat(ActivityHeatmapMetrics.weeks)],
                       [PopoverHeatmapMetrics.cell, PopoverHeatmapMetrics.spacing, CGFloat(PopoverHeatmapMetrics.weeks)])
        var ledger = UsageLedger()
        ledger.merge([usage("2026-06-01", 10), usage("2026-06-02", 0)])
        let live = [usage("2026-07-01", 5), usage("2026-06-01", 99)]
        XCTAssertEqual(ActivityHeatmapMetrics.days(ledger: ledger, series: live), PopoverHeatmapMetrics.days(ledger: ledger, series: live))
        XCTAssertEqual(ActivityHeatmapMetrics.recordedSince(ledger: ledger, series: live), PopoverHeatmapMetrics.recordedSince(ledger: ledger, series: live))
        XCTAssertEqual(PopoverColorRole.paletteCount, MonthDailyTrend.providerPalette.count)
    }

    /// The model's resolved numbers are the Mac's own expressions over the same inputs.
    func testTheBarsModelHoldsTheMacsHeightsSegmentsAndColours() {
        let today = "2026-07-15"
        let data = series(today: today, count: 15)
        var input = ActivityInput()
        input.series = data
        input.today = today
        input.window = .month
        input.providerOrder = ["a", "b", "c"]
        input.providers = [DailyTrendStack.ProviderSeries(id: "b", name: "B", days: data, reportsCost: true),
                           DailyTrendStack.ProviderSeries(id: "a", name: "A", days: data.map { usage($0.date, $0.totalTokens / 2) }, reportsCost: true)]
        let l = L(.en)
        let model = try! XCTUnwrap(TrendBarsModel.make(input, l: l))
        let columns = DailyTrendMetrics.columns(series: data, today: today, window: .month)
        let peak = columns.map(\.tokens).max() ?? 0
        let stack = DailyTrendStack.ordered(input.providers)
        let colors = DailyTrendStack.colorIndices(for: stack.map(\.id), registry: input.providerOrder, paletteCount: MonthDailyTrend.providerPalette.count)
        XCTAssertTrue(model.stacked)
        XCTAssertEqual(model.legend.map(\.name), stack.map(\.name))
        XCTAssertEqual(model.legend.map(\.colorIndex), stack.map { colors[$0.id] ?? 0 })
        for (c, m) in zip(columns, model.columns) {
            XCTAssertEqual(m.date, c.date)
            XCTAssertEqual(m.height, c.isFuture ? 0 : DailyTrendMetrics.barHeight(tokens: c.tokens, peak: peak))
            let segs = DailyTrendStack.isStacked(stack) && c.tokens > 0 && !c.isFuture
                ? DailyTrendStack.segments(on: c.date, stack: stack, barHeight: m.height) : []
            XCTAssertEqual(m.segments.map(\.height), segs.map(\.height))
            XCTAssertEqual(m.segments.map(\.colorIndex), segs.map { colors[$0.providerID] ?? 0 })
            XCTAssertEqual(m.axisLabel, DailyTrendMetrics.axisLabel(for: c.date, today: today, window: .month))
        }
        XCTAssertEqual(model.readout, MonthDailyTrend.readout(series: data, today: today, showsCost: false, l: l))
        XCTAssertEqual(model.peakText, DailyTrendMetrics.showsPeak(columns) ? TokenFormatter.compact(peak) : nil)
    }
}
