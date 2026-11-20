import Foundation

// The Windows popover's recap (stage 7 Task 13): the shared twin of the Mac's `RecapContent` (`UI/UsageRecapView.swift`,
// upstream-owned and Mac-only), and the values the recap page and its card are drawn from. Compiled and tested on both
// systems; the Mac app does not call it.
//
// `PopoverRecapContent` is the Mac's struct body, line for line, with the name changed: `twins.txt` compares the two bodies
// (comments and white space dropped) and `PopoverTwinEquivalenceTests+Mac` drives both over every language, scope, offset,
// first weekday and ledger shape. Change the Mac first, then copy the change here. Dates come from the display locale
// (`language.displayLocale`) exactly as the Mac does: Foundation on Windows has `DateIntervalFormatter` and the
// `setLocalizedDateFormatFromTemplate` templates (Task 1's formatter probe), so no fallback of ours stands in.

/// Everything the recap prints, read once.
@MainActor
struct PopoverRecapContent {
    let language: AppLanguage
    let recap: UsageRecap
    let companionSpeciesID: Int?
    let companionShiny: Bool
    let companionForm: PokemonForm?
    let graduates: [(entry: DexEntry, name: String)]
    private let calendar: Calendar
    /// Built once per read: a `DateFormatter` is expensive and the card asks for a label per meter.
    private let dayKeyFormatter: DateFormatter
    private let dayNameFormatter: DateFormatter
    private let monthNameFormatter: DateFormatter

    init(store: UsageStore, companion: CompanionStore, scope: RecapScope, offset: Int,
         now: Date = Date(), calendar: Calendar = RecapPeriod.calendar()) {
        language = companion.language
        self.calendar = calendar
        let period = RecapPeriod(scope: scope, containing: now, calendar: calendar)
            .shifted(by: offset, calendar: calendar)
        recap = UsageRecap.make(ledger: store.dailyLedger, dex: companion.state.dex, period: period,
                                now: now, calendar: calendar)
        // The Pokémon being raised right now, not the pinned representative: the recap is about
        // usage that just happened, so it shows who lived it.
        companionSpeciesID = companion.currentSpeciesID
        companionShiny = companion.currentIsShiny
        companionForm = companion.currentForm
        graduates = recap.graduated.prefix(4).map { entry in
            let name = companion.dexStoredChainNames(entry)?[entry.finalID] ?? "#\(entry.finalID)"
            // Four chips share a row: only Unown's letter fits, the sprite already shows other forms.
            return (entry, PokemonForm.displayName(name, speciesID: entry.finalID, form: entry.form, label: nil))
        }
        dayKeyFormatter = LocalUsageReader.localDayFormatter(timeZone: calendar.timeZone)
        dayNameFormatter = Self.formatter(language, calendar, template: "EEEE d MMM")
        monthNameFormatter = Self.formatter(language, calendar, template: "MMMM y")
    }

    private static func formatter(_ language: AppLanguage, _ calendar: Calendar, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.displayLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    var l: L { L(language) }
    var scope: RecapScope { recap.period.scope }

    /// "14–20 Sept 2026", "September 2026" or "2026", from the display locale. It titles the card.
    func periodLabel() -> String {
        switch scope {
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.locale = language.displayLocale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateTemplate = "dMMMy"
            let lastDay = calendar.date(byAdding: .day, value: -1, to: recap.period.end) ?? recap.period.start
            return formatter.string(from: recap.period.start, to: lastDay)
        case .month:
            return monthNameFormatter.string(from: recap.period.start)
        case .year:
            return String(calendar.component(.year, from: recap.period.start))
        }
    }

    /// One short label per meter, from the display locale so there is nothing of ours to translate.
    /// Weekdays take two letters (one collides: mardi/mercredi, Tuesday/Thursday), a month labels
    /// only its weekly marks since 31 numbers do not fit, and a year uses month initials.
    func bucketLabels() -> [String] {
        let symbols = DateFormatter()
        symbols.locale = language.displayLocale
        let weekdays = symbols.shortStandaloneWeekdaySymbols ?? []
        let months = symbols.veryShortStandaloneMonthSymbols ?? []
        return recap.buckets.map { bucket in
            guard let date = dayKeyFormatter.date(from: bucket.key) else { return "" }
            switch scope {
            case .week:
                guard !weekdays.isEmpty else { return "" }
                let weekday = calendar.component(.weekday, from: date)   // 1-based
                return String(weekdays[(weekday - 1) % weekdays.count].prefix(2)).uppercased()
            case .month:
                let day = calendar.component(.day, from: date)
                return [1, 8, 15, 22, 29].contains(day) ? "\(day)" : ""
            case .year:
                guard !months.isEmpty else { return "" }
                let month = calendar.component(.month, from: date)   // 1-based
                return months[(month - 1) % months.count].uppercased()
            }
        }
    }

    func dayLabel(_ key: String) -> String {
        guard let date = dayKeyFormatter.date(from: key) else { return key }
        return dayNameFormatter.string(from: date)
    }

    func accessibilityLabel(_ bucket: UsageRecap.Bucket) -> String {
        let name: String
        if scope == .year, let date = dayKeyFormatter.date(from: bucket.key) {
            name = monthNameFormatter.string(from: date)
        } else {
            name = dayLabel(bucket.key)
        }
        return "\(name), \(bucket.hasData ? TokenFormatter.grouped(bucket.tokens) : l.recapNoData)"
    }

}

// MARK: - what the card and the page print

/// The numbers of the Mac's `RecapCard` that more than one place needs (each is pinned to the Mac body in `twins.txt`, so a
/// change there fails until this follows).
enum PopoverRecapMetrics {
    /// `RecapCard.meterBlocks`: segments per meter. Eight reads as a level gauge; more would turn back into a plain bar.
    static let meterBlocks = 8
    /// `RecapCard.size.height`.
    static let cardHeight: CGFloat = 226

    /// The space between the meters of a scope (`RecapCard.meters`).
    static func meterSpacing(_ scope: RecapScope) -> CGFloat {
        switch scope {
        case .week: 6
        case .month: 1.5
        case .year: 4
        }
    }

    /// The label font under a meter (`RecapCard.meters`).
    static func labelSize(_ scope: RecapScope) -> CGFloat { scope == .week ? 8 : 7 }

    /// Lit segments (`RecapCard.meter`): a bucket with usage always lights one, so "quiet" and "nothing" stay distinct.
    static func lit(tokens: Int, peak: Int) -> Int {
        tokens > 0 ? max(1, Int((Double(tokens) / Double(peak) * Double(meterBlocks)).rounded())) : 0
    }
}

/// Which period the page shows: a twin of `RecapScreen`'s two `@State` values and the rules on its buttons. The offset is 0 for
/// the running period and never positive, the future has no usage; changing the scope starts again at the running period.
struct RecapNavigation: Equatable {
    var scope: RecapScope = .week
    var offset = 0

    /// The segmented picker (`.onChange(of: scope) { offset = 0 }`: choosing the scope already shown changes nothing).
    mutating func select(_ next: RecapScope) {
        guard next != scope else { return }
        scope = next
        offset = 0
    }

    /// "Previous": disabled unless the previous period holds a day the ledger covers (`recap.canGoBack`).
    mutating func goBack(canGoBack: Bool) {
        guard canGoBack else { return }
        offset -= 1
    }

    /// The running period's button, disabled while it is already shown.
    mutating func goToCurrent() { offset = 0 }

    /// "Next": disabled at the running period.
    mutating func goForward() {
        guard offset < 0 else { return }
        offset += 1
    }

    var canGoToCurrent: Bool { offset != 0 }
    var canGoForward: Bool { offset < 0 }
}

/// What `RecapCard` draws, as values: every text already formatted. Equal models draw the same card.
struct RecapCardModel: Equatable {
    struct Meter: Equatable {
        /// `yyyy-MM-dd` of the bucket's first day.
        var key: String
        /// The short label under the meter (empty for most days of a month).
        var label: String
        var lit: Int
        var isCurrent: Bool
        var hasData: Bool
        /// The tooltip and the accessible text (`RecapContent.accessibilityLabel`).
        var description: String
    }

    struct Readout: Equatable {
        /// Upper case, as the card prints it.
        var label: String
        var value: String
    }

    struct Graduate: Equatable {
        var id: String
        var speciesID: Int
        var isShiny: Bool
        var form: PokemonForm?
        var name: String
    }

    var scope: RecapScope
    /// The period, upper case (the card's title).
    var title: String
    var total: String
    /// "TOKENS", upper case.
    var unit: String
    /// The chip: "▲12%" (`up`) or "▼8%"; nil unless the ledger covers the whole compared stretch.
    var delta: (text: String, up: Bool)?
    var meters: [Meter]
    /// Best day and best streak (left column), active days and graduates (right column).
    var readouts: [Readout]
    var companionSpeciesID: Int?
    var companionShiny: Bool
    var companionForm: PokemonForm?
    var graduates: [Graduate]
    var noGraduates: String

    static func == (a: RecapCardModel, b: RecapCardModel) -> Bool {
        a.scope == b.scope && a.title == b.title && a.total == b.total && a.unit == b.unit && a.delta?.text == b.delta?.text
            && a.delta?.up == b.delta?.up && a.meters == b.meters && a.readouts == b.readouts
            && a.companionSpeciesID == b.companionSpeciesID && a.companionShiny == b.companionShiny
            && a.companionForm == b.companionForm && a.graduates == b.graduates && a.noGraduates == b.noGraduates
    }

    /// Twin of the texts `RecapCard` builds in `header`, `screen`, `deltaChip`, `meters` and `graduateStrip`.
    @MainActor init(_ content: PopoverRecapContent) {
        let recap = content.recap
        let l = content.l
        scope = content.scope
        title = content.periodLabel().uppercased()
        total = TokenFormatter.compact(recap.total)
        unit = l.recapTokensUnit.uppercased()
        // No chip unless the ledger covers the whole compared stretch: a fresh install must not claim a jump over days it
        // never saw.
        if let delta = recap.delta {
            let up = delta >= 0
            self.delta = ("\(up ? "▲" : "▼")\(TokenFormatter.percent(abs(delta) * 100))", up)
        } else {
            delta = nil
        }
        let peak = max(1, recap.buckets.map(\.tokens).max() ?? 1)
        let labels = content.bucketLabels()
        meters = recap.buckets.enumerated().map { index, bucket in
            Meter(key: bucket.key, label: labels.indices.contains(index) ? labels[index] : "",
                  lit: PopoverRecapMetrics.lit(tokens: bucket.tokens, peak: peak), isCurrent: bucket.isCurrent,
                  hasData: bucket.hasData, description: content.accessibilityLabel(bucket))
        }
        readouts = [
            Readout(label: l.recapBestDay.uppercased(), value: recap.bestDay.map { TokenFormatter.compact($0.tokens) } ?? "--"),
            Readout(label: l.recapBestStreak.uppercased(), value: l.recapDays(recap.bestStreak)),
            Readout(label: l.recapActiveDays.uppercased(), value: "\(recap.activeDays)/\(recap.countedDays)"),
            Readout(label: l.recapGraduates.uppercased(), value: "\(recap.graduated.count)"),
        ]
        companionSpeciesID = content.companionSpeciesID
        companionShiny = content.companionShiny
        companionForm = content.companionForm
        graduates = content.graduates.map {
            Graduate(id: $0.entry.id, speciesID: $0.entry.finalID, isShiny: $0.entry.isShiny, form: $0.entry.form, name: $0.name)
        }
        noGraduates = l.recapNoGraduates
    }
}

/// What the recap page prints and enables: the Mac's `RecapScreen` as values. The card is `RecapCardModel`.
struct RecapPageModel: Equatable {
    var language: AppLanguage
    var navigation: RecapNavigation
    /// `l.back`.
    var back: String
    /// The segmented picker: one name per scope in `RecapScope.allCases` order, and its accessible name (`l.recapOpen`).
    var scopeNames: [String]
    var scopeLabel: String
    var previous: String
    var canGoBack: Bool
    /// The running period's button ("This week", "This month", "This year"); enabled away from the running period.
    var current: String
    var canGoToCurrent: Bool
    var next: String
    var canGoForward: Bool
    var card: RecapCardModel
    /// "Your best day was …": absent when no day had usage.
    var bestDayLine: String?
    /// "Compared with the same days last week": only under a running period whose chip compares something.
    var compareSoFar: String?

    var selectedScope: Int { RecapScope.allCases.firstIndex(of: navigation.scope) ?? 0 }

    @MainActor init(_ content: PopoverRecapContent, navigation: RecapNavigation) {
        let l = content.l, recap = content.recap
        language = content.language
        self.navigation = navigation
        back = l.back
        scopeNames = RecapScope.allCases.map { l.recapScopeName($0) }
        scopeLabel = l.recapOpen
        previous = l.recapPrevious
        canGoBack = recap.canGoBack
        current = l.recapCurrentPeriod(navigation.scope)
        canGoToCurrent = navigation.canGoToCurrent
        next = l.recapNext
        canGoForward = navigation.canGoForward
        card = RecapCardModel(content)
        bestDayLine = recap.bestDay.map { l.recapBestDayLine(content.dayLabel($0.key), TokenFormatter.grouped($0.tokens)) }
        compareSoFar = recap.isInProgress && recap.delta != nil ? l.recapCompareSoFar(navigation.scope) : nil
    }

    /// The model of the page the stores' data and `navigation` say (the Mac's `RecapScreen.body`).
    @MainActor static func make(store: UsageStore, companion: CompanionStore, navigation: RecapNavigation, now: Date = Date(),
                                calendar: Calendar = RecapPeriod.calendar()) -> RecapPageModel {
        RecapPageModel(PopoverRecapContent(store: store, companion: companion, scope: navigation.scope, offset: navigation.offset,
                                           now: now, calendar: calendar), navigation: navigation)
    }
}
