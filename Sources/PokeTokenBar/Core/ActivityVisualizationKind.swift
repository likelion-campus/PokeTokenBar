import Foundation

/// One way of drawing recent activity in the popover.
///
/// **Adding a visualization starts and ends in this file.** Add a `case` and the compiler points
/// at the two remaining spots — `title(_:)` and `ActivityPanel.chart`, both below — then add one
/// name string to `Localization.swift`. The view itself can live anywhere.
///
/// **Do not add `default:` to either `switch`.** It is the only thing that turns this extension
/// point into a compile error instead of a comment: with a `default`, a new case without a view
/// still builds and the user who picks it gets an empty row.
///
/// Nothing outside this file branches on a specific visualization by name — the same kind of
/// extension point as a `UsageProvider` or `BinaryLocator.commonToolDirectories()`.
enum ActivityVisualization: String, CaseIterable, Sendable {
    /// Day-by-day bars for this month. **The default and first in the cycle** — an existing
    /// install's popover must not change on update.
    case monthlyBars
    /// The last 16 weeks as a calendar grid. Bars compare this month's amounts; the grid shows
    /// weekday patterns ("barely anything on weekends") at a glance, across months.
    case recentHeatmap

    static let `default` = ActivityVisualization.monthlyBars

    /// The next one in the click cycle. It follows `allCases`, so a new case joins the cycle on its own.
    var next: ActivityVisualization {
        let all = Self.allCases
        // The optional is the API's: `self` is always in `allCases`.
        guard let index = all.firstIndex(of: self) else { return Self.default }
        return all[(index + 1) % all.count]
    }

    func title(_ l: L) -> String {
        switch self {
        case .monthlyBars:    return l.dailyTrend
        case .recentHeatmap: return l.recentHeatmap
        }
    }
}
