import SwiftUI

/// Draws the visualization the user picked; a click moves on to the next one.
///
/// **Why not draw both.** Both answer "how has usage been going". Stacking them
/// would spend half the popover's height on two replies to one question. Showing one keeps the
/// popover quiet, and because visualizations do not compete for space, a third or fourth can be
/// added later.
@MainActor
struct ActivityPanel: View {
    let visualization: ActivityVisualization
    /// The selected bar window; it can cover fewer days than this month's live series.
    let series: [DailyUsage]
    /// The grid keeps this month's live values regardless of the selected bar period.
    var heatmapSeries: [DailyUsage]? = nil
    /// The bars split by provider when more than one was used. The grid does not: before this
    /// month only daily totals exist (`history`).
    var providers: [DailyTrendStack.ProviderSeries] = []
    var providerOrder: [String] = []
    /// Days before this month, for the grid. `UsageStore.dailyLedger`.
    var history = UsageLedger()
    let showsCost: Bool
    var window: Binding<DailyTrendWindow>? = nil
    var hasAvailableHistory = false
    let today: String
    let l: L
    let onCycle: () -> Void

    var body: some View {
        chart
            .contentShape(Rectangle())      // make the gaps clickable too
            .onTapGesture(perform: onCycle)
            .help(l.activitySwitchHint)
    }

    @ViewBuilder
    private var chart: some View {
        switch visualization {
        case .monthlyBars:
            MonthDailyTrend(series: series, providers: providers, providerOrder: providerOrder,
                            showsCost: showsCost, window: window, hasAvailableHistory: hasAvailableHistory,
                            today: today, l: l,
                            trailing: AnyView(PageDots(current: visualization)))
        case .recentHeatmap:
            ActivityHeatmap(series: heatmapSeries ?? series, history: history,
                            showsCost: showsCost, today: today, l: l,
                            trailing: AnyView(PageDots(current: visualization)))
        }
    }
}

/// The only visual hint that there is another view. A click cycle is hard to discover; without
/// the dots most people never learn it can switch.
///
/// The count comes from `allCases`, so a contributor adding a case gets another dot for free.
@MainActor
struct PageDots: View {
    let current: ActivityVisualization

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ActivityVisualization.allCases, id: \.self) { item in
                Circle()
                    .fill(item == current ? Color.secondary.opacity(0.75)
                                          : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: 4)
            }
        }
    }
}
