import Foundation

/// Shared twins of the Mac popover's private formatting helpers (stage 7, D8, P5). The originals are private members of
/// `PopoverView` or extensions in `UI/PopoverView.swift` (upstream-owned, Mac-only), so they cannot be called from here;
/// each twin below names its original. Where the twin's body can read as the Mac's (after the colour names are mapped to
/// roles), `twins.txt` compares the two texts; the others are compared, through a verbatim copy of the Mac's body, by
/// `PopoverTwinEquivalenceTests+Mac` over a corpus. What the Mac reads from the environment (`store.limitDisplayMode`,
/// `companion.language`, `Date()`, `Calendar.current`, the default time zone) is a parameter here.
enum PopoverFormat {
    /// `PopoverView.resetClockWindow`: a reset this close (or today) shows the clock only.
    static let resetClockWindow: TimeInterval = 6 * 3600

    /// Twin of `PopoverView.limitPercentText(_:)`: the row's percentage in the display mode, with the
    /// "left" suffix in the remaining mode. Warning colours still follow the real utilization.
    static func limitPercentText(_ utilization: Double, mode: UsageStore.LimitDisplayMode, l: L) -> String {
        let text = TokenFormatter.percent(UsageStore.displayPercent(utilization, mode: mode))
        return mode == .remaining ? l.percentRemaining(text) : text
    }

    /// Twin of `PopoverView.resetClockSuffix(_:)`: the wall-clock time after a countdown, " (19:26)" when the reset is
    /// today or within `resetClockWindow`, else with the weekday and day (" (Thursday 10, 19:26)"). Weekday names in the
    /// app language, always 24 h. `calendar` gives the day and the time zone (the Mac: `Calendar.current` and the
    /// default time zone, which are the same zone).
    static func resetClockSuffix(_ reset: Date, now: Date, language: AppLanguage, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = language.displayLocale
        f.timeZone = calendar.timeZone
        let nearby = calendar.isDate(reset, inSameDayAs: now)
            || reset.timeIntervalSince(now) <= resetClockWindow
        f.setLocalizedDateFormatFromTemplate(nearby ? "HHmm" : "EEEEdHHmm")
        return " (\(f.string(from: reset)))"
    }

    /// Twin of `PopoverView.paceFraction(reset:span:)`: the pace line needs both the reset and the window's length.
    static func paceFraction(reset: Date?, span: TimeInterval?, now: Date) -> Double? {
        guard let reset, let span else { return nil }
        return UsageStore.paceFraction(resetsAt: reset, span: span, now: now)
    }

    /// Twin of `PopoverView.paceHelp(_:tier:utilization:)`: the row's tooltip. The tier and its delta first (the row
    /// shows only a colour), then the pace hint, whose number follows the display mode like the marker.
    static func paceHelp(pace: Double?, tier: PaceTier?, utilization: Double, mode: UsageStore.LimitDisplayMode,
                         l: L) -> String? {
        guard let pace else { return nil }
        let hint = l.paceHint(TokenFormatter.percent(UsageStore.displayPercent(pace * 100, mode: mode)))
        guard let tier else { return hint }
        var head = l.paceTier(tier)
        if let delta = l.paceDelta(PaceTier.roundedDelta(utilization: utilization, pace: pace)) {
            head += " · " + delta
        }
        return head + "\n" + hint
    }

    /// Twin of `PopoverView.grokProductName(_:)`: billing product ids → the names grok.com shows.
    static func grokProductName(_ product: String?) -> String {
        switch product {
        case "GrokBot": return "Grok"
        case "GrokBuild": return "Grok Build"
        case "Api": return "API"
        default: return product ?? ""
        }
    }

    /// Twin of `LimitProgressBar.markerFraction(pace:mode:)`: the pace marker's position (0…1) through the same
    /// transform as the fill, so the remaining mode flips both.
    static func markerFraction(pace: Double?, mode: UsageStore.LimitDisplayMode) -> Double? {
        guard let pace else { return nil }
        return UsageStore.displayPercent(pace * 100, mode: mode) / 100
    }

    /// Twin of `PaceTier.color`: the gauge's fill colour per tier.
    static func paceColor(_ tier: PaceTier) -> PopoverColorRole {
        switch tier {
        case .wayUnder: return .systemBlue
        case .under: return .systemTeal
        case .onPace: return .systemGreen
        case .slightlyOver: return .systemYellow
        case .over: return .systemOrange
        case .wayOver: return .systemRed
        }
    }

    /// Twin of `PaceTier.percentColor`: the percentage's colour. Yellow text hardly reads on a light background, so that
    /// tier keeps the primary text colour.
    static func percentColor(_ tier: PaceTier) -> PopoverColorRole { tier == .slightlyOver ? .primary : paceColor(tier) }

    /// Twin of `PopoverView.statusColor(_:)`: the status banner's dot.
    static func statusColor(_ indicator: ProviderStatusIndicator) -> PopoverColorRole {
        switch indicator {
        case .operational:         return .systemGreen
        case .minor, .maintenance: return .systemYellow
        case .major:               return .systemOrange
        case .critical:            return .systemRed
        case .unknown:             return .systemGray
        }
    }

    /// Twin of `PopoverView.timeFormatter` (`dateFormat = "HH:mm"`, the default locale and time zone): the forecast's
    /// depletion time. The Mac's defaults are `Locale.current` and the zone of `Calendar.current`; here they come from
    /// the platform facts (`regionLocale`, `regionCalendar`).
    static func forecastTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
