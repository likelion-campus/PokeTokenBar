import Foundation

/// Per-provider stacking of the daily trend bars — pure, like `DailyTrendMetrics`, so the
/// ordering and the height split can be checked headlessly. The split is where a view-local
/// version goes quietly wrong: independently scaled segments do not sum to the bar, and the
/// stacked bar then disagrees with the single-color bar's height for the same day.
enum DailyTrendStack {
    struct ProviderSeries {
        var id: String
        var name: String
        var days: [DailyUsage]
        var reportsCost: Bool
    }

    struct Segment: Equatable {
        var providerID: String
        var tokens: Int
        var height: CGFloat
    }

    /// Providers that used anything this month, largest month total first (bottom of the stack).
    /// Ties break on id so the order cannot flip between refreshes.
    static func ordered(_ providers: [ProviderSeries]) -> [ProviderSeries] {
        let totals: [(provider: ProviderSeries, tokens: Int)] = providers.map { provider in
            (provider, provider.days.reduce(0) { $0 + $1.totalTokens })
        }
        return totals
            .filter { $0.tokens > 0 }
            .sorted { lhs, rhs in
                lhs.tokens != rhs.tokens ? lhs.tokens > rhs.tokens : lhs.provider.id < rhs.provider.id
            }
            .map(\.provider)
    }

    /// Whether the row stacks at all. With one provider (or none) the row stays the plain
    /// single-color bar with today in the accent color.
    static func isStacked(_ ordered: [ProviderSeries]) -> Bool { ordered.count > 1 }

    /// Segments of `date`'s bar, bottom → top in `ordered` order. Zero-token providers are left
    /// out. Heights come from cumulative shares, so they add up to exactly `barHeight` with no
    /// rounding drift. Empty when nobody used anything that day.
    static func segments(on date: String, stack ordered: [ProviderSeries],
                         barHeight: CGFloat) -> [Segment] {
        let parts = ordered.compactMap { provider -> (String, Int)? in
            let tokens = provider.days.first { $0.date == date }?.totalTokens ?? 0
            return tokens > 0 ? (provider.id, tokens) : nil
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }

        var segments: [Segment] = []
        var running = 0
        var placed: CGFloat = 0
        for (index, part) in parts.enumerated() {
            running += part.1
            let top = index == parts.count - 1
                ? barHeight
                : barHeight * CGFloat(running) / CGFloat(total)
            segments.append(Segment(providerID: part.0, tokens: part.1, height: top - placed))
            placed = top
        }
        return segments
    }

    /// Palette slot per provider id: its registration index (`UsageStore.registeredProviderIDs`) modulo the
    /// palette. It depends on nothing but that index, so a provider keeps its color as others become
    /// active or idle and as usage rank shifts during the month. Past the palette size colors repeat;
    /// the legend and tooltip name the providers, so a shared color stays readable.
    static func colorIndices(for ids: [String], registry: [String],
                             paletteCount: Int) -> [String: Int] {
        var slots: [String: Int] = [:]
        for id in ids {
            slots[id] = (registry.firstIndex(of: id) ?? 0) % paletteCount
        }
        return slots
    }
}
