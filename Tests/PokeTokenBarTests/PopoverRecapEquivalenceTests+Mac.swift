import XCTest
@testable import PokeTokenBar

/// The shared recap twin behaves as the Mac's `RecapContent` (stage 7 Task 13, D8). Mac only: the original lives in `UI/`.
/// `PopoverParityScanTests` holds the twin's source to the original's (twins.txt); this drives both over every language, scope,
/// offset, first weekday, a few ledgers and two "now"s (one at a year boundary) and compares everything the recap prints.
@MainActor
final class PopoverRecapEquivalenceTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func calendar(_ firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar(2).date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func usage(_ day: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: day, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: tokens,
                   totalCost: 0, costCoverage: .source)
    }

    func testTheTwinPrintsWhatTheMacPrints() async throws {
        let formatter = LocalUsageReader.localDayFormatter(timeZone: utc)
        func key(_ d: Date) -> String { formatter.string(from: d) }
        var full = UsageLedger()
        full.merge([usage(key(date(2025, 6, 1)), 0), usage(key(date(2026, 9, 18)), 3_000), usage(key(date(2026, 9, 17)), 5_000),
                    usage(key(date(2026, 12, 30)), 700), usage(key(date(2027, 1, 2)), 12_345_678), usage(key(date(2026, 1, 5)), 40)])
        var first = UsageLedger()
        first.merge([usage(key(date(2026, 9, 16)), 0), usage(key(date(2026, 9, 18)), 3_000)])
        let ledgers: [(String, UsageLedger)] = [("full", full), ("empty", UsageLedger()), ("first", first)]
        let nows = [date(2026, 9, 18), date(2027, 1, 2)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recap-equivalence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = TestDefaults.make(suite: "recap-equivalence")
        var compared = 0
        for (name, ledger) in ledgers {
            ledger.save(to: defaults)
            let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
            let companion = CompanionStore(fileURL: url, defaults: defaults)
            for language in AppLanguage.allCases {
                companion.setLanguage(language)
                for scope in RecapScope.allCases {
                    for offset in [0, -1] {
                        for firstWeekday in [1, 2, 7] {
                            for now in nows {
                                let cal = calendar(firstWeekday)
                                let mac = RecapContent(store: store, companion: companion, scope: scope, offset: offset, now: now, calendar: cal)
                                let twin = PopoverRecapContent(store: store, companion: companion, scope: scope, offset: offset, now: now, calendar: cal)
                                let where_ = "\(name) \(language) \(scope) \(offset) fw\(firstWeekday) \(now)"
                                XCTAssertEqual(twin.periodLabel(), mac.periodLabel(), where_)
                                XCTAssertEqual(twin.bucketLabels(), mac.bucketLabels(), where_)
                                XCTAssertEqual(twin.recap.buckets, mac.recap.buckets, where_)
                                XCTAssertEqual(twin.recap.total, mac.recap.total, where_)
                                XCTAssertEqual(twin.recap.delta, mac.recap.delta, where_)
                                for bucket in mac.recap.buckets {
                                    XCTAssertEqual(twin.dayLabel(bucket.key), mac.dayLabel(bucket.key), where_)
                                    XCTAssertEqual(twin.accessibilityLabel(bucket), mac.accessibilityLabel(bucket), where_)
                                }
                                XCTAssertEqual(twin.graduates.map(\.name), mac.graduates.map(\.name), where_)
                                XCTAssertEqual(twin.scope, mac.scope)
                                XCTAssertEqual(twin.language, mac.language)
                                compared += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(compared, 3 * 8 * 3 * 2 * 3 * 2)
    }

    /// What `RecapScreen` and `RecapCard` print from `RecapContent`, evaluated here the way their bodies do, equals the page model.
    func testThePageModelEqualsTheMacBodiesExpressions() async throws {
        let formatter = LocalUsageReader.localDayFormatter(timeZone: utc)
        var ledger = UsageLedger()
        ledger.merge([usage(formatter.string(from: date(2026, 8, 1)), 0), usage(formatter.string(from: date(2026, 9, 18)), 3_000),
                      usage(formatter.string(from: date(2026, 9, 17)), 5_000), usage(formatter.string(from: date(2026, 9, 11)), 2_000)])
        let defaults = TestDefaults.make(suite: "recap-equivalence-page")
        ledger.save(to: defaults)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recap-equivalence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        let companion = CompanionStore(fileURL: url, defaults: defaults)
        let now = date(2026, 9, 18)
        for language in AppLanguage.allCases {
            companion.setLanguage(language)
            for scope in RecapScope.allCases {
                for offset in [0, -1] {
                    let mac = RecapContent(store: store, companion: companion, scope: scope, offset: offset, now: now, calendar: calendar(2))
                    var nav = RecapNavigation()
                    nav.select(scope)
                    nav.offset = offset
                    let twin = PopoverRecapContent(store: store, companion: companion, scope: scope, offset: offset, now: now, calendar: calendar(2))
                    let m = RecapPageModel(twin, navigation: nav)
                    let l = mac.l, recap = mac.recap
                    let w = "\(language) \(scope) \(offset)"
                    // RecapScreen.body
                    XCTAssertEqual(m.back, l.back, w)
                    XCTAssertEqual(m.scopeNames, RecapScope.allCases.map { l.recapScopeName($0) }, w)
                    XCTAssertEqual(m.scopeLabel, l.recapOpen, w)
                    XCTAssertEqual(m.previous, l.recapPrevious, w)
                    XCTAssertEqual(m.canGoBack, recap.canGoBack, w)
                    XCTAssertEqual(m.current, l.recapCurrentPeriod(scope), w)
                    XCTAssertEqual(m.canGoToCurrent, offset != 0, w)
                    XCTAssertEqual(m.next, l.recapNext, w)
                    XCTAssertEqual(m.canGoForward, offset < 0, w)
                    XCTAssertEqual(m.bestDayLine, recap.bestDay.map { l.recapBestDayLine(mac.dayLabel($0.key), TokenFormatter.grouped($0.tokens)) }, w)
                    XCTAssertEqual(m.compareSoFar, recap.isInProgress && recap.delta != nil ? l.recapCompareSoFar(scope) : nil, w)
                    // RecapCard.header / screen / deltaChip / meters
                    XCTAssertEqual(m.card.title, mac.periodLabel().uppercased(), w)
                    XCTAssertEqual(m.card.total, TokenFormatter.compact(recap.total), w)
                    XCTAssertEqual(m.card.unit, l.recapTokensUnit.uppercased(), w)
                    XCTAssertEqual(m.card.delta?.text, recap.delta.map { "\($0 >= 0 ? "▲" : "▼")\(TokenFormatter.percent(abs($0) * 100))" }, w)
                    XCTAssertEqual(m.card.delta?.up, recap.delta.map { $0 >= 0 }, w)
                    XCTAssertEqual(m.card.readouts.map(\.label), [l.recapBestDay, l.recapBestStreak, l.recapActiveDays, l.recapGraduates].map { $0.uppercased() }, w)
                    XCTAssertEqual(m.card.readouts.map(\.value), [recap.bestDay.map { TokenFormatter.compact($0.tokens) } ?? "--", l.recapDays(recap.bestStreak),
                                                                    "\(recap.activeDays)/\(recap.countedDays)", "\(recap.graduated.count)"], w)
                    let peak = max(1, recap.buckets.map(\.tokens).max() ?? 1)
                    let lit = recap.buckets.map { b in b.tokens > 0 ? max(1, Int((Double(b.tokens) / Double(peak) * Double(8)).rounded())) : 0 }
                    XCTAssertEqual(m.card.meters.map(\.lit), lit, w)
                    XCTAssertEqual(m.card.meters.map(\.label), mac.bucketLabels(), w)
                    XCTAssertEqual(m.card.meters.map(\.description), recap.buckets.map { mac.accessibilityLabel($0) }, w)
                    XCTAssertEqual(m.card.noGraduates, l.recapNoGraduates, w)
                    XCTAssertEqual(PopoverRecapMetrics.cardHeight, 226)
                }
            }
        }
    }
}
