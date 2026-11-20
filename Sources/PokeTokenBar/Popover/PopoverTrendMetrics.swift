import Foundation

// Twins of the Mac popover's trend rules (stage 7 Task 12, D8): `DailyTrendColumn`, `DailyTrendMetrics`, `DailyTrendHover`
// (UI/PopoverView.swift), copied verbatim under new names. `PopoverParityScanTests` holds each body to its original
// (twins.txt, renames DailyTrend… = PopoverTrend…), and `PopoverTrendTwinTests+Mac` drives original and twin over the
// Mac's own corpora. A Mac change fails the scan until it is carried here. The Windows page passes its own calendar
// (`PlatformCompat.regionCalendar`) where a rule takes `calendar: .current`; the default stays the original's.

/// 일별 추이 축의 한 칸. `isFuture` 는 이번 달 중 아직 오지 않은 날이다.
struct PopoverTrendColumn: Identifiable, Equatable {
    let date: String
    let tokens: Int
    let isFuture: Bool
    var id: String { date }
}

/// 추이 막대의 기하 — 뷰 밖의 순수 함수로 둔다. SwiftUI 안에 두면 헤드리스로 검증할 수 없고,
/// 이 계산은 0 과 최댓값 경계에서 조용히 틀리기 쉽다(0 을 0pt 로 그리면 "그날이 없는" 것처럼 보인다).
enum PopoverTrendMetrics {
    /// 막대 트랙 높이. 헤더가 이미 촘촘하므로 스파크라인 수준으로 낮게 잡는다.
    static let track: CGFloat = 26
    static let spacing: CGFloat = 1.5
    /// 사용 없는 날에 남기는 바닥 눈금. 0pt 로 그리면 그 날짜 칸이 사라진 것처럼 보이고, 축이
    /// 밀리지 않았다는 사실(=0 을 명시적으로 채웠다)이 화면에서 안 읽힌다.
    static let baseline: CGFloat = 1.5
    /// 주말 표시 밑줄 두께.
    static let tickHeight: CGFloat = 1.5

    /// `tokens` 를 `peak` 대비 비율로 트랙 안에 눕힌다.
    /// - `peak <= 0`: 스케일이 없다 → 전부 바닥 눈금 (호출부가 이미 게이트하지만 0 나눗셈은 막는다).
    /// - `tokens <= 0`: 바닥 눈금.
    /// - 그 외: 최소 `baseline` 을 보장해 아주 작은 날도 사라지지 않는다.
    static func barHeight(tokens: Int, peak: Int) -> CGFloat {
        guard peak > 0, tokens > 0 else { return baseline }
        let ratio = min(1, Double(tokens) / Double(peak))
        return max(baseline, CGFloat(ratio) * track)
    }

    /// 설정된 윈도우(7일/14일/21일/이번 달)에 따른 칼럼 목록 생성.
    static func columns(series: [DailyUsage], today: String, window: DailyTrendWindow = .month) -> [PopoverTrendColumn] {
        switch window {
        case .month:
            return monthColumns(series: series, today: today)
        case .d7, .d14, .d21:
            guard let days = window.dayCount else { return monthColumns(series: series, today: today) }
            return rollingColumns(series: series, today: today, count: days)
        }
    }

    /// 롤링 윈도우 칼럼 (과거 N일 ~ 오늘). 모든 칼럼이 이미 도달한 날이므로 `isFuture: false`.
    static func rollingColumns(series: [DailyUsage], today: String, count: Int) -> [PopoverTrendColumn] {
        guard let todayDate = LocalUsageReader.localDayFormatter().date(from: today) else {
            return series.map { PopoverTrendColumn(date: $0.date, tokens: $0.totalTokens, isFuture: false) }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let fmt = LocalUsageReader.localDayFormatter()
        let tokensByDay = Dictionary(series.map { ($0.date, $0.totalTokens) }, uniquingKeysWith: +)

        return (0..<count).reversed().map { offset in
            let dateObj = cal.date(byAdding: .day, value: -offset, to: todayDate) ?? todayDate
            let dateStr = fmt.string(from: dateObj)
            return PopoverTrendColumn(date: dateStr, tokens: tokensByDay[dateStr] ?? 0, isFuture: false)
        }
    }

    /// 이번 달 전체(1일~말일)의 칼럼. 시리즈에 있는 날은 그 토큰을, 오늘까지인데 시리즈에 없는 날은
    /// 0 을, 오늘 이후는 `isFuture` 로 채운다.
    ///
    /// 데이터 쪽(`monthDailySeries`)은 그대로 오늘에서 끝난다. 미래 날짜를 데이터에 넣으면 회고 원장
    /// (`UsageLedger.merge`)이 "시리즈의 0 은 진짜 0"이라고 믿는 계약이 깨지므로, 채우기는 뷰 경계에서만 한다.
    /// 다른 달의 날짜(자정을 넘긴 직후 아직 지난달 시리즈를 들고 있는 프로바이더)는 축에 들어오지 않는다.
    /// `today` 를 해석할 수 없으면 시리즈를 그대로 칼럼으로 쓴다(테스트할 분기가 아니라 API 강제다).
    static func monthColumns(series: [DailyUsage], today: String) -> [PopoverTrendColumn] {
        let month = String(today.prefix(7))   // "yyyy-MM"
        guard let year = Int(today.prefix(4)), let monthNumber = Int(month.suffix(2)),
              let todayOfMonth = Int(today.suffix(2)),
              let length = daysInMonth(year: year, month: monthNumber)
        else {
            return series.map { PopoverTrendColumn(date: $0.date, tokens: $0.totalTokens, isFuture: false) }
        }
        let tokensByDay = Dictionary(series.map { ($0.date, $0.totalTokens) }, uniquingKeysWith: +)
        return (1...length).map { day in
            let date = String(format: "%@-%02d", month, day)
            return PopoverTrendColumn(date: date, tokens: tokensByDay[date] ?? 0, isFuture: day > todayOfMonth)
        }
    }

    /// 주말 밑줄은 지난날과 오늘에만 긋는다. 막대가 없는 미래 칸 아래에 밑줄만 남으면 의미 없는
    /// 기호("__ __")로 읽힌다.
    static func showsWeekendTick(_ column: PopoverTrendColumn, calendar: Calendar = .current) -> Bool {
        !column.isFuture && isWeekend(column.date, calendar: calendar)
    }

    /// 쓴 날이 둘 이상일 때만 캡션에 최댓값을 적는다. 하루뿐이면 리드아웃(오늘)과 같은 숫자다.
    static func showsPeak(_ columns: [PopoverTrendColumn]) -> Bool {
        columns.filter { $0.tokens > 0 }.count > 1
    }

    /// 그레고리력 기준 그 달의 일수. 날짜 키가 `en_US_POSIX` 그레고리력이므로 같은 달력을 쓴다.
    /// 시각을 다루지 않으므로 서머타임과 무관하게 UTC 로 계산한다.
    private static func daysInMonth(year: Int, month: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return range.count
    }

    /// 축에 숫자를 붙일 날인가 — 1일, 7일 간격, 그리고 오늘.
    ///
    /// 오늘을 항상 붙이는 이유: 오늘 사용량이 적으면 막대가 바닥 눈금 한 줄이라 강조색만으로는
    /// 위치를 못 찾는다(31일 렌더에서 실제로 안 보였다). 축의 숫자가 그때 유일한 단서다.
    ///
    /// **오늘 옆의 정기 라벨은 지운다.** 한 달이 다 찬 축은 칼럼이 약 9pt 인데 두 자리 숫자는
    /// 약 11pt 라, 오늘이 7의 배수 바로 옆이면(22일·29일 등) `21 22` 가 간격 없이 붙어 한 숫자로
    /// 읽힌다(8월 실데이터로 렌더해서 확인했다). 오늘은 절대 지우지 않으므로 라벨이 0개가 되는
    /// 상태는 없고, 인접한 정기 라벨 하나를 잃는 대가는 없다 — 오늘 위치를 알면 그 옆도 안다.
    static func axisLabel(for date: String, today: String, window: DailyTrendWindow = .month,
                          labelInterval: Int = 7, minimumSeparation: Int = 3) -> String?
    {
        // `Int(...)` 옵셔널 해제는 API 강제다 — 시리즈의 날짜는 항상 "yyyy-MM-dd" 라 실패하지
        // 않는다(테스트할 분기가 아니다).
        guard let dayOfMonth = Int(date.suffix(2)) else { return nil }
        if date == today { return "\(dayOfMonth)" }

        switch window {
        case .month:
            let isRegular = dayOfMonth == 1 || (labelInterval > 0 && dayOfMonth % labelInterval == 0)
            guard isRegular else { return nil }
            if let todayOfMonth = Int(today.suffix(2)),
               abs(dayOfMonth - todayOfMonth) < minimumSeparation { return nil }
            return "\(dayOfMonth)"
        case .d7:
            guard let diff = LocalUsageReader.dayDifference(from: date, to: today), diff > 0 else { return nil }
            if dayOfMonth == 1 {
                // In a 7-day window, midpoint is diff == 3. Label "1" only if it is far enough
                // from both today and the midpoint to avoid visual collision.
                guard diff >= minimumSeparation && (diff == 3 || abs(diff - 3) >= minimumSeparation) else {
                    return nil
                }
                return "\(dayOfMonth)"
            }
            if diff == 3 && diff >= minimumSeparation {
                return "\(dayOfMonth)"
            }
            return nil
        case .d14, .d21:
            guard let diff = LocalUsageReader.dayDifference(from: date, to: today), diff > 0 else { return nil }
            if dayOfMonth == 1 {
                return diff >= minimumSeparation ? "\(dayOfMonth)" : nil
            }
            if diff % 7 == 0 && diff >= minimumSeparation {
                // If the 1st of this month is in the window and separated from today,
                // it takes precedence as a landmark. Suppress regular marks that sit
                // within minimumSeparation of the 1st of the month to avoid visual collision.
                let diffToFirst = diff - (dayOfMonth - 1)
                if diffToFirst >= minimumSeparation && abs(dayOfMonth - 1) < minimumSeparation {
                    return nil
                }
                if let year = Int(date.prefix(4)), let month = Int(date.dropFirst(5).prefix(2)),
                   let daysInCurMonth = daysInMonth(year: year, month: month) {
                    let daysToNextFirst = daysInCurMonth - dayOfMonth + 1
                    let diffToNextFirst = diff - daysToNextFirst
                    if diffToNextFirst >= minimumSeparation && daysToNextFirst < minimumSeparation {
                        return nil
                    }
                }
                return "\(dayOfMonth)"
            }
            return nil
        }
    }

    /// `calendar` 는 테스트 주입 구멍 — 주말이 어느 요일인지는 로케일이 정한다(금·토인 지역도
    /// 있다). 프로덕션은 사용자 달력을 그대로 따라야 하므로 기본값을 쓴다.
    static func isWeekend(_ date: String, calendar: Calendar = .current) -> Bool {
        guard let parsed = LocalUsageReader.localDayFormatter().date(from: date) else { return false }
        return calendar.isDateInWeekend(parsed)
    }

    /// 월·일 + 요일을 **그 언어가 쓰는 순서로** — ko "8. 24. (월)", en "Mon, 8/24", fr "lun. 24/08".
    ///
    /// 두 가지를 로케일 템플릿(`MdE`)에 맡긴다.
    /// ① **요일 이름**: 6개 언어 × 7요일을 `Localization.swift` 에 손으로 적으면 OS 가 이미 가진 것을
    ///    다시 적는 셈이다.
    /// ② **월·일 순서**: `"\(month)/\(day)"` 로 조립하면 프랑스어·스페인어·포르투갈어에서도 미국식
    ///    순서(8/24)가 강제된다 — 그 언어들은 24/08 이 맞다.
    ///
    /// 로케일은 반드시 `AppLanguage` 에서 온다. `DateFormatter` 를 기본값으로 만들면 시스템 로케일을
    /// 따라, 앱 언어를 바꾼 사용자에게 한 화면 두 언어가 된다(defect-log §표시·UI 의 `.relative` 부류).
    static func dayStamp(_ date: String, language: AppLanguage) -> String {
        guard let parsed = LocalUsageReader.localDayFormatter().date(from: date) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = language.displayLocale
        formatter.setLocalizedDateFormatFromTemplate("MdE")
        return formatter.string(from: parsed)
    }
}

/// What the trend tooltip says for one day — pure, so the wording rules can be checked without hovering.
enum PopoverTrendHover {
    struct Row: Equatable {
        var id: String
        var name: String
        var tokens: String
        var cost: String?
    }

    struct Info: Equatable {
        var stamp: String
        var tokens: String
        var cost: String?
        /// Per-provider split, in stack order; only when the bars stack, and only providers that used
        /// something that day.
        var providers: [Row]
    }

    /// Cost follows the totals' rule: shown only with `showsCost`, and per provider only for those that
    /// bill (`reportsCost`). Nil for a day outside the series.
    static func info(day: String, series: [DailyUsage], stack: [DailyTrendStack.ProviderSeries],
                     showsCost: Bool, l: L) -> Info? {
        let total = series.first(where: { $0.date == day }) ?? DailyUsage(
            date: day, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0, totalCost: 0, costCoverage: .empty)
        let rows: [Row] = DailyTrendStack.isStacked(stack) ? stack.compactMap { provider in
            guard let usage = provider.days.first(where: { $0.date == day }), usage.totalTokens > 0 else { return nil }
            return Row(id: provider.id, name: provider.name, tokens: TokenFormatter.compact(usage.totalTokens),
                       cost: showsCost && provider.reportsCost ? usage.usageCost.text(l) : nil)
        } : []
        return Info(stamp: PopoverTrendMetrics.dayStamp(day, language: l.lang),
                    tokens: TokenFormatter.compact(total.totalTokens),
                    cost: showsCost ? total.usageCost.text(l) : nil,
                    providers: rows)
    }
}

/// `MonthDailyTrend.readout` and `.shouldShowSurface`, whole (twins.txt).
enum PopoverTrendSurface {
    nonisolated static func shouldShowSurface(peak: Int, hasAvailableHistory: Bool,
                                              isSelectable: Bool) -> Bool {
        peak > 0 || (isSelectable && hasAvailableHistory)
    }

    nonisolated static func readout(series: [DailyUsage], today: String, showsCost: Bool, l: L) -> String {
        guard let day = series.first(where: { $0.date == today }) else { return "" }
        let stamp = PopoverTrendMetrics.dayStamp(day.date, language: l.lang)
        let tokens = TokenFormatter.compact(day.totalTokens)
        guard showsCost else { return "\(stamp) \(tokens)" }
        return "\(stamp) \(tokens) \(day.usageCost.text(l))"
    }
}

/// `StreakBadge.isShown` with its constant (twins.txt).
enum PopoverStreak {
    nonisolated static let minimumDays = 2

    nonisolated static func isShown(_ streak: UsageStreak) -> Bool { streak.days >= minimumDays }
}

/// `WrappingHStack.arrange` over measured sizes instead of SwiftUI subviews: the legend's line breaking. The Mac body is
/// pinned in twins.txt (a SwiftUI layout cannot read as its twin); `PopoverTrendTwinTests+Mac` compares the frames with
/// the Mac's `WrappingHStack` over sizes and widths.
enum PopoverWrapLayout {
    static func arrange(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }

    /// `WrappingHStack.sizeThatFits` over the frames.
    static func size(of frames: [CGRect]) -> CGSize {
        CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
}

// MARK: - the heatmap (UI/ActivityHeatmap.swift)

/// One cell of the heatmap.
struct PopoverHeatCell: Equatable, Sendable {
    let date: String
    let tokens: Int
    /// Inside the grid but not part of the range. The grid is cut into whole weeks so the weekday
    /// rows line up, which puts days outside the range into the first and last columns.
    /// Dropping them shortens a column and shifts every weekday below; drawing them as zero reads
    /// as "unused day".
    let isOutsideRange: Bool
}

/// The members of `ActivityHeatmapMetrics` that do not draw (twins.txt, member by member): the geometry, the weeks and
/// the levels. The colours are roles (`PopoverColorRole.heatmap(level:)`, held to the Mac's greens by `mac-colors.json`).
enum PopoverHeatmapMetrics {
    /// Row height. Cells take the row's width, so the grid fills the popover like the bars do
    /// instead of sitting as a small block at the left edge.
    static let cell: CGFloat = 10
    static let spacing: CGFloat = 2

    /// One-letter weekday names for the rows, starting at `firstWeekday` like `columns`. Without them
    /// nothing says which row is the weekend — the pattern the grid exists to show. The names come
    /// from the display language; the first weekday from the region, as in `columns`.
    static func weekdayLabels(firstWeekday: Int, locale: Locale) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols    // Sunday first
        let start = (firstWeekday - 1) % symbols.count
        return Array(symbols[start...] + symbols[..<start])
    }

    /// Weeks (columns) × weekdays (rows): the fewest whole weeks covering `first`…`last`.
    ///
    /// The weekday a column starts on is `calendar.firstWeekday` — Monday in some regions, Sunday
    /// in others, and that is the locale's call, not this code's.
    ///
    /// Days advance through `Calendar` rather than a fixed 86400 seconds: on a DST day the local day
    /// is 23 or 25 hours long and the grid would slip a day. Worse, that bug is green or red
    /// depending on the contributor's time zone — it passes in Asia/Seoul — so `calendar` and
    /// `timeZone` are injectable.
    static func columns(days: [String: Int], first: String, last: String,
                        calendar: Calendar = .current,
                        timeZone: TimeZone = .current) -> [[PopoverHeatCell]] {
        var cal = calendar
        cal.timeZone = timeZone
        let formatter = LocalUsageReader.localDayFormatter(timeZone: timeZone)
        // Not a day key: give up on the grid (empty rather than a crash). Production passes the
        // window's first day and today, so this does not happen; the optionals are the API's.
        guard first <= last,
              let firstDate = formatter.date(from: first),
              let lastDate = formatter.date(from: last),
              let gridStart = cal.dateInterval(of: .weekOfYear, for: firstDate)?.start
        else { return [] }

        var columns: [[PopoverHeatCell]] = []
        var cursor = gridStart
        while cursor <= lastDate {
            var column: [PopoverHeatCell] = []
            for offset in 0..<7 {
                // The optional is the API's — it does not fail in the Gregorian calendar.
                guard let date = cal.date(byAdding: .day, value: offset, to: cursor) else { continue }
                let key = formatter.string(from: date)
                // "yyyy-MM-dd" sorts lexicographically the same way it sorts chronologically.
                column.append(PopoverHeatCell(date: key, tokens: days[key] ?? 0,
                                           isOutsideRange: key < first || key > last))
            }
            columns.append(column)
            guard let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = nextWeek
        }
        return columns
    }

    /// How far back the popover's grid reaches. Long enough that a weekday habit shows over more
    /// than one month, short enough that the cells keep the bars' row height in the popover's width
    /// (a year, 53 columns, would not fit).
    static let weeks = 16

    /// The popover's grid: the last `weeks` weeks, ending with the week `today` falls in. The window
    /// rolls with today rather than resetting on the 1st, so the grid never opens nearly empty.
    ///
    /// `days` reaches past this month only through `UsageLedger` — providers report the current
    /// month alone. Days before `recordedSince` the app was not recording, and days after `today`
    /// have not happened: both are marked outside the range, so neither reads as an unused day.
    static func recentGrid(days: [String: Int], recordedSince: String?, today: String,
                           calendar: Calendar = .current,
                           timeZone: TimeZone = .current) -> [[PopoverHeatCell]] {
        var cal = calendar
        cal.timeZone = timeZone
        let formatter = LocalUsageReader.localDayFormatter(timeZone: timeZone)
        guard let todayDate = formatter.date(from: today),
              let thisWeek = cal.dateInterval(of: .weekOfYear, for: todayDate)?.start,
              let firstWeek = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }
        let windowStart = formatter.string(from: firstWeek)
        // With nothing recorded yet, only today can be vouched for (the series is about to fill it).
        let first = max(windowStart, recordedSince ?? today)
        // Lay the grid out from the window's first week even when recording began later, so the
        // width stays `weeks` columns, then mark the unrecorded days.
        return columns(days: days, first: windowStart, last: today,
                       calendar: calendar, timeZone: timeZone)
            .map { column in
                column.map { cell in
                    cell.date < first
                        ? PopoverHeatCell(date: cell.date, tokens: cell.tokens, isOutsideRange: true)
                        : cell
                }
            }
    }

    /// The ledger's days with this month's live series laid over them. The ledger is written once
    /// per refresh, so today in the ledger can trail the series the bars draw; taking the larger
    /// keeps the two views agreeing on today (the same rule as `UsageLedger.merge`).
    static func days(ledger: UsageLedger, series: [DailyUsage]) -> [String: Int] {
        var days = ledger.tokensByDay
        for day in series where day.totalTokens > 0 {
            days[day.date] = max(days[day.date] ?? 0, day.totalTokens)
        }
        return days
    }

    /// The first day the grid can vouch for: the ledger's coverage, or the 1st of this month when
    /// the series reaches back further (a fresh ledger that has not been saved yet).
    static func recordedSince(ledger: UsageLedger, series: [DailyUsage]) -> String? {
        [ledger.coveredSince, series.map(\.date).min()].compactMap { $0 }.min()
    }

    /// Shade level 0…4: 0 is an unused day, 1…4 are quartiles of the peak.
    ///
    /// No `peak == 0` guard: `peak` is the window's maximum, so once `tokens > 0` holds,
    /// `peak >= tokens > 0` does too (and the caller only draws when `peak > 0`).
    static func level(tokens: Int, peak: Int) -> Int {
        guard tokens > 0 else { return 0 }
        let ratio = Double(tokens) / Double(peak)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.50 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }
}
