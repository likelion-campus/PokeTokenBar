import Foundation
import Observation

/// What the activity panel and the streak read from the stores (stage 7 Task 12; the Mac's `ActivityPanel` call in
/// `PopoverView.header` and its two `StreakBadge` call sites), captured once per build. Built on the main actor inside the
/// page's observation tracking, it registers every store member the panel depends on; the models below are then plain
/// values the parts draw.
struct ActivityInput {
    var visualization: ActivityVisualization = .default
    /// `UsageStore.dailyTrendTotals` (the selected window's series).
    var series: [DailyUsage] = []
    /// `UsageStore.monthDailyTotals` (the heatmap keeps this month's live values whatever the window).
    var heatmapSeries: [DailyUsage] = []
    var providers: [DailyTrendStack.ProviderSeries] = []
    var providerOrder: [String] = []
    var history = UsageLedger()
    var showsCost = false
    var window: DailyTrendWindow = .month
    var hasAvailableHistory = false
    /// Today's `localDay` key, injected so nothing reads the clock again.
    var today = ""
    var language: AppLanguage = .en
    var streak = UsageStreak.none
    var facts: PopoverPlatformFacts = .mac

    init() {}

    @MainActor
    init(store: UsageStore, companion: CompanionStore, facts: PopoverPlatformFacts, today: String = LocalUsageReader.todayKey()) {
        visualization = store.activityVisualization
        series = store.dailyTrendTotals
        heatmapSeries = store.monthDailyTotals
        providers = store.trendProviders
        providerOrder = store.registeredProviderIDs
        history = store.dailyLedger
        showsCost = store.showsCost
        window = store.dailyTrendWindow
        hasAvailableHistory = store.hasDailyTrendHistory
        self.today = today
        language = companion.language
        streak = store.currentStreak
        self.facts = facts
    }
}

/// The streak badge as values (`StreakBadge.body`, pinned in twins.txt): nil below two days.
struct StreakModel: Equatable, Sendable {
    var days: Int
    var includesToday: Bool
    /// The tooltip and the accessible label.
    var label: String

    static func make(_ streak: UsageStreak, l: L) -> StreakModel? {
        guard PopoverStreak.isShown(streak) else { return nil }
        let label = streak.includesToday ? l.streakDays(streak.days) : l.streakDaysPending(streak.days)
        return StreakModel(days: streak.days, includesToday: streak.includesToday, label: label)
    }
}

/// The month bars as values (`MonthDailyTrend.body`, pinned in twins.txt): every height, segment, tick and label resolved
/// by the twins, so a part only places them and the tests compare numbers.
struct TrendBarsModel: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        /// `DailyTrendStack.colorIndices` (the palette wraps with `PopoverColorRole.palette`).
        var colorIndex: Int
        var height: CGFloat
    }

    struct Column: Equatable, Sendable {
        var date: String
        var isFuture: Bool
        var isToday: Bool
        var isEmpty: Bool
        /// 0 for a future day (no bar, no floor tick).
        var height: CGFloat
        /// Bottom to top; empty for a single provider.
        var segments: [Segment]
        var weekendTick: Bool
        var axisLabel: String?
    }

    struct LegendItem: Equatable, Sendable {
        var name: String
        var colorIndex: Int
    }

    struct Choice: Equatable, Sendable {
        var window: DailyTrendWindow
        var title: String
        var checked: Bool
    }

    var title: String
    var readout: String
    var peakLabel: String?
    var peakText: String?
    /// False: only the caption shows (no usage in the window, but history exists to choose another window).
    var showsBars: Bool
    var columns: [Column]
    var stacked: Bool
    var legend: [LegendItem]
    var choices: [Choice]
    var windowLabel: String
    var switchHint: String
    var dotCount: Int
    var dotIndex: Int

    /// nil: nothing is drawn (`shouldShowSurface` false).
    static func make(_ input: ActivityInput, l: L) -> TrendBarsModel? {
        let columns = PopoverTrendMetrics.columns(series: input.series, today: input.today, window: input.window)
        let peak = columns.map(\.tokens).max() ?? 0
        let calendar = input.facts.regionCalendar
        let all = ActivityVisualization.allCases
        let dots = (all.count, all.firstIndex(of: .monthlyBars) ?? 0)
        let readout = PopoverTrendSurface.readout(series: input.series, today: input.today, showsCost: input.showsCost, l: l)
        let choices = DailyTrendWindow.allCases.map { Choice(window: $0, title: l.title(for: $0), checked: $0 == input.window) }
        func model(bars: Bool, peak: Int, showsPeak: Bool, columns: [Column], stack: [DailyTrendStack.ProviderSeries],
                   colors: [String: Int]) -> TrendBarsModel {
            TrendBarsModel(title: l.title(for: input.window), readout: readout,
                           peakLabel: showsPeak ? l.peakDay : nil, peakText: showsPeak ? TokenFormatter.compact(peak) : nil,
                           showsBars: bars, columns: columns, stacked: DailyTrendStack.isStacked(stack),
                           legend: DailyTrendStack.isStacked(stack) ? stack.map { LegendItem(name: $0.name, colorIndex: colors[$0.id] ?? 0) } : [],
                           choices: choices, windowLabel: l.dailyTrendPeriod, switchHint: l.activitySwitchHint,
                           dotCount: dots.0, dotIndex: dots.1)
        }
        if peak > 0 {
            let stack = DailyTrendStack.ordered(input.providers)
            let colors = DailyTrendStack.colorIndices(for: stack.map(\.id), registry: input.providerOrder,
                                                      paletteCount: PopoverColorRole.paletteCount)
            let cells: [Column] = columns.map { column in
                let isEmpty = column.tokens == 0
                let height = column.isFuture ? 0 : PopoverTrendMetrics.barHeight(tokens: column.tokens, peak: peak)
                let segments = DailyTrendStack.isStacked(stack) && !isEmpty && !column.isFuture
                    ? DailyTrendStack.segments(on: column.date, stack: stack, barHeight: height)
                        .map { Segment(colorIndex: colors[$0.providerID] ?? 0, height: $0.height) } : []
                return Column(date: column.date, isFuture: column.isFuture, isToday: column.date == input.today, isEmpty: isEmpty,
                              height: height, segments: segments,
                              weekendTick: PopoverTrendMetrics.showsWeekendTick(column, calendar: calendar),
                              axisLabel: PopoverTrendMetrics.axisLabel(for: column.date, today: input.today, window: input.window))
            }
            return model(bars: true, peak: peak, showsPeak: PopoverTrendMetrics.showsPeak(columns), columns: cells, stack: stack, colors: colors)
        } else if PopoverTrendSurface.shouldShowSurface(peak: peak, hasAvailableHistory: input.hasAvailableHistory, isSelectable: true) {
            return model(bars: false, peak: 0, showsPeak: false, columns: [], stack: [], colors: [:])
        }
        return nil
    }
}

/// The 16-week grid as values (`ActivityHeatmap.body`, pinned in twins.txt).
struct HeatmapModel: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        var date: String
        /// 0…4, or -1 for a day outside the range (before recording, or still to come).
        var level: Int
        var isToday: Bool
    }

    var title: String
    /// Today's readout (the caption's text when nothing is hovered).
    var readout: String
    var peakLabel: String?
    var peakText: String?
    /// Rows, from the region's first weekday.
    var weekdayLabels: [String]
    /// Weeks (columns) of seven days.
    var columns: [[Cell]]
    var switchHint: String
    var dotCount: Int
    var dotIndex: Int

    /// nil when no day in the range has usage (the Mac draws nothing).
    static func make(_ input: ActivityInput, l: L) -> HeatmapModel? {
        let calendar = input.facts.regionCalendar
        let grid = PopoverHeatmapMetrics.recentGrid(
            days: PopoverHeatmapMetrics.days(ledger: input.history, series: input.heatmapSeries),
            recordedSince: PopoverHeatmapMetrics.recordedSince(ledger: input.history, series: input.heatmapSeries),
            today: input.today, calendar: calendar, timeZone: calendar.timeZone)
        let used = grid.joined().filter { !$0.isOutsideRange && $0.tokens > 0 }
        let peak = used.map(\.tokens).max() ?? 0
        guard peak > 0 else { return nil }
        let all = ActivityVisualization.allCases
        let showsPeak = used.count > 1
        return HeatmapModel(
            title: l.recentHeatmap,
            readout: readout(grid: grid, series: input.heatmapSeries, day: input.today, showsCost: input.showsCost, l: l),
            peakLabel: showsPeak ? l.peakDay : nil, peakText: showsPeak ? TokenFormatter.compact(peak) : nil,
            weekdayLabels: PopoverHeatmapMetrics.weekdayLabels(firstWeekday: calendar.firstWeekday, locale: l.lang.displayLocale),
            columns: grid.map { column in
                column.map { cell in
                    Cell(date: cell.date, level: cell.isOutsideRange ? -1 : PopoverHeatmapMetrics.level(tokens: cell.tokens, peak: peak),
                         isToday: cell.date == input.today)
                }
            },
            switchHint: l.activitySwitchHint, dotCount: all.count, dotIndex: all.firstIndex(of: .recentHeatmap) ?? 0)
    }

    /// This month's days read like the bars', cost included. Earlier days have tokens only
    /// (`ActivityHeatmap.readout`, pinned in twins.txt).
    static func readout(grid: [[PopoverHeatCell]], series: [DailyUsage], day: String, showsCost: Bool, l: L) -> String {
        if series.contains(where: { $0.date == day }) {
            return PopoverTrendSurface.readout(series: series, today: day, showsCost: showsCost, l: l)
        }
        guard let cell = grid.joined().first(where: { $0.date == day }) else { return "" }
        return "\(PopoverTrendMetrics.dayStamp(day, language: l.lang)) \(TokenFormatter.compact(cell.tokens))"
    }
}

/// What the panel shows, and how a hovered day is told. `shown` is what the drawing depends on; the lookups are closures
/// over the input (a card's text is made when a day is hovered, never for every day).
struct ActivityPanelModel {
    enum Content: Equatable, Sendable {
        case bars(TrendBarsModel)
        case heatmap(HeatmapModel)
    }

    var content: Content?
    var streak: StreakModel?
    /// The trend card of a day (`PopoverTrendHover.info`).
    var cardInfo: (String) -> PopoverTrendHover.Info? = { _ in nil }
    /// The heatmap's caption readout of a day.
    var heatReadout: (String) -> String = { _ in "" }

    struct Shown: Equatable { var content: Content?; var streak: StreakModel? }
    var shown: Shown { Shown(content: content, streak: streak) }

    static func make(_ input: ActivityInput) -> ActivityPanelModel {
        let l = L(input.language)
        var model = ActivityPanelModel()
        model.streak = StreakModel.make(input.streak, l: l)
        switch input.visualization {
        case .monthlyBars:
            model.content = TrendBarsModel.make(input, l: l).map(Content.bars)
            let stack = DailyTrendStack.ordered(input.providers)
            let series = input.series, showsCost = input.showsCost
            model.cardInfo = { day in PopoverTrendHover.info(day: day, series: series, stack: stack, showsCost: showsCost, l: l) }
        case .recentHeatmap:
            model.content = HeatmapModel.make(input, l: l).map(Content.heatmap)
            let calendar = input.facts.regionCalendar
            let grid = PopoverHeatmapMetrics.recentGrid(
                days: PopoverHeatmapMetrics.days(ledger: input.history, series: input.heatmapSeries),
                recordedSince: PopoverHeatmapMetrics.recordedSince(ledger: input.history, series: input.heatmapSeries),
                today: input.today, calendar: calendar, timeZone: calendar.timeZone)
            let series = input.heatmapSeries, showsCost = input.showsCost
            model.heatReadout = { day in HeatmapModel.readout(grid: grid, series: series, day: day, showsCost: showsCost, l: l) }
        }
        return model
    }
}

/// The keys a drawn part answers (Windows virtual-key codes, kept as numbers so the shared parts and their tests need no
/// Windows import).
enum PopoverKey {
    static let escape = 0x1B, end = 0x23, home = 0x24, left = 0x25, up = 0x26, right = 0x27, down = 0x28
}
