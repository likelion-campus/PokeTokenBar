import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

private struct QuietHomeProvider: UsageProvider {
    let id = "fixture"
    let displayName = "Fixture"
    var reportsCost = false
    let enrichment: ProviderEnrichment
    func fetchDaily() async throws -> DailyUsage? { nil }
    func fetchEnrichment() async -> ProviderEnrichment { enrichment }
}

private struct QuietHomeClaude: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus {
        throw LimitsError.keychainInteractionNotAllowed
    }
}
private struct QuietHomeCodex: CodexLimitsProviding {
    func fetch() async throws -> CodexRateLimitStatus? { nil }
}
private struct QuietHomeAntigravity: AntigravityLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus {
        throw LimitsError.keychainInteractionNotAllowed
    }
}
private struct QuietHomeCursor: CursorLimitsProviding {
    func fetch() async throws -> CursorRateLimitStatus? { nil }
}
private struct QuietHomeStatus: ProviderStatusProviding {
    func fetch() async -> [String: ProviderStatus] { [:] }
}
private struct QuietHomePokemon: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 129, tree: EvoNode(speciesID: 129, children: [EvoNode(speciesID: 130, children: [])]),
                rarity: .common, names: [129: ["ko": "잉어킹"], 130: ["ko": "갸라도스"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

/// Render the production home after the real refresh pipeline returns no usage today.
/// Optional PNG output is fixture data, isolated from the user's saves and credentials.
@MainActor
final class ZeroUsageHomeRenderingTests: XCTestCase {
    func testQuietDayKeepsHistoricalGraphVisible() async throws {
        try await render(history: true)
    }

    func testEmptyHistoryStillShowsZeroPeriodSummaries() async throws {
        try await render(history: false)
    }

    func testRecapLabelKeepsPeriodCostsOnOneLine() async throws {
        for language in [AppLanguage.en, .de] {
            try await render(history: true, language: language, costs: .source)
        }
    }

    func testUnavailablePeriodCostsKeepGermanHomeWithinPopover() async throws {
        try await render(history: true, language: .de, costs: .unavailable)
    }


    /// The quiet-day month: every day before `day` has usage, `day` itself (today) has none.
    /// A pure function of the date so the date sweep below can feed it any day.
    static func quietSeries(monthPrefix: String, day: Int, history: Bool) -> [DailyUsage] {
        (0..<day).map { offset in
            let tokens = history && offset < day - 1 ? (offset % 6 + 1) * 230_000 : 0
            return DailyUsage(date: String(format: "%@-%02d", monthPrefix, offset + 1), inputTokens: tokens,
                              outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
                              totalTokens: tokens, totalCost: 0)
        }
    }

    /// The condition `MonthDailyTrend` uses to draw bars: some column in the window has tokens.
    static func drawsBars(series: [DailyUsage], today: String, window: DailyTrendWindow) -> Bool {
        (DailyTrendMetrics.columns(series: series, today: today, window: window).map(\.tokens).max() ?? 0) > 0
    }

    func testQuietDayBarsAreDrawnOnEveryCalendarDate() async {
        // Every day of every month of 2026 (all seven weekdays start a month) plus a leap February.
        let months = (1...12).map { (2026, $0) } + [(2028, 2)]
        for (year, month) in months {
            let first = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 1))!
            let length = Calendar(identifier: .gregorian).range(of: .day, in: .month, for: first)!.count
            let prefix = String(format: "%04d-%02d", year, month)
            for day in 1...length {
                let today = String(format: "%@-%02d", prefix, day)
                for window in DailyTrendWindow.allCases {
                    let drawn = Self.drawsBars(series: Self.quietSeries(monthPrefix: prefix, day: day, history: true),
                                               today: today, window: window)
                    XCTAssertEqual(drawn, day > 1, "\(today) \(window)")
                    XCTAssertFalse(Self.drawsBars(series: Self.quietSeries(monthPrefix: prefix, day: day, history: false),
                                                  today: today, window: window), "\(today) \(window) empty history")
                }
            }
        }
    }

    private func render(history: Bool, language: AppLanguage = .ko, costs: CostCoverage? = nil) async throws {
        let suite = "QuietHome-\(UUID())"
        let defaults = try XCTUnwrap(TestDefaults.make(suite: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = language
        state.active = MonState(baseID: 129, pathIDs: [129, 130], stageIndex: 1,
                                usedAtStage: 170_100_000, rarity: .common, totalForms: 2, nature: .hardy)
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(provider: QuietHomePokemon(), fileURL: file, defaults: defaults)
        companion.update(todayTokensByProvider: [:], todayDate: LocalUsageReader.todayKey(), monthTotal: 0,
                         burnTier: .idle, limitWarning: false, hasUsageData: false)
        let formatter = LocalUsageReader.localDayFormatter()
        let now = Date()
        let day = Calendar.current.component(.day, from: now)
        let series = Self.quietSeries(monthPrefix: LocalUsageReader.monthKey(now), day: day, history: history)
        let weekKey = formatter.string(from: LocalUsageReader.startOfWeek(now))
        let enrichment = ProviderEnrichment(blocksOK: true,
            weekTotal: costs != nil
                ? PeriodUsage(period: weekKey, totalTokens: 4_800_000, totalCost: costs == .unavailable ? 0 : 31.64,
                              costCoverage: costs ?? .source)
                : PeriodUsage(period: weekKey, daily: series.filter { $0.date >= weekKey }),
            monthTotal: costs != nil
                ? PeriodUsage(period: LocalUsageReader.monthKey(now), totalTokens: 17_900_000,
                              totalCost: costs == .unavailable ? 0 : 121.30,
                              costCoverage: costs ?? .source)
                : PeriodUsage(period: LocalUsageReader.monthKey(now), daily: series),
            monthDaily: series, periodsOK: true)
        let store = UsageStore(providers: [QuietHomeProvider(reportsCost: costs != nil, enrichment: enrichment)],
            claudeLimitsProvider: QuietHomeClaude(), discoverClaudeConfigDirs: { [] },
            readDefaultIdentity: { nil }, claudeUsageEntries: { _ in [] },
            codexLimitsProvider: QuietHomeCodex(), antigravityLimitsProvider: QuietHomeAntigravity(),
            cursorLimitsProvider: QuietHomeCursor(), statusProvider: QuietHomeStatus(),
            autoRefresh: false, defaults: defaults)
        await store.refresh(scheduleEmptyRetry: false)
        XCTAssertEqual(store.todayTotalTokens, 0)
        XCTAssertEqual(store.monthTotalTokens, costs != nil ? 17_900_000 : series.reduce(0) { $0 + $1.totalTokens })

        let height = 604.0
        let host = NSHostingView(rootView: PopoverView()
            .environment(store).environment(companion).environment(UpdateChecker(defaults: defaults))
            .environment(PopoverNavigation()).environment(TeamSettings(defaults: defaults))
            .environment(\.colorScheme, .dark)
            .environment(\.controlActiveState, .active)
            .frame(width: PopoverMetrics.width, height: height)
            .background(Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1))))
        host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: PopoverMetrics.width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderInForTest()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        // Keep caption OCR at 4x regardless of the runner's screen backing scale: at 2x the hosted runner read 이번 as 미번 and Diese as Dlese.
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * 4).rounded(.up)),
            pixelsHigh: Int((bounds.height * 4).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        XCTAssertGreaterThanOrEqual(CGFloat(bitmap.pixelsWide) / bounds.width, 4)
        XCTAssertGreaterThanOrEqual(CGFloat(bitmap.pixelsHigh) / bounds.height, 4)
        host.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        switch language {
        case .en: request.recognitionLanguages = ["en-US"]
        case .de: request.recognitionLanguages = ["de-DE", "en-US"]
        default: request.recognitionLanguages = ["ko-KR", "en-US"]
        }
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        let normalizedText = text.replacingOccurrences(of: " ", with: "")
        let chartCaptions = [
            companion.l.title(for: store.dailyTrendWindow).replacingOccurrences(of: " ", with: ""),
            companion.l.dailyTrend.replacingOccurrences(of: " ", with: ""),
        ]
        // The caption shares a text line with the date readout ("11. 24. (화) 0"), so the OCR's top reading of that line
        // can garble the caption on one date and not on the next. Accept the caption in any of the 10 candidates; the
        // empty-history case below still proves the caption is absent when no chart is drawn.
        let chartVisible = (request.results ?? []).contains { observation in
            observation.topCandidates(10).contains { candidate in
                chartCaptions.contains { candidate.string.replacingOccurrences(of: " ", with: "").contains($0) }
            }
        }
        let candidates = (request.results ?? []).enumerated().map { index, observation in
            let alternatives = observation.topCandidates(10).map {
                "\($0.string.debugDescription) confidence=\($0.confidence)"
            }.joined(separator: " | ")
            return "observation \(index) bbox=\(NSStringFromRect(observation.boundingBox)): \(alternatives)"
        }.joined(separator: "\n")
        let diagnostics = "OCR revision=\(request.revision) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)\n\(candidates)"
        for label in [companion.l.todayTokens, companion.l.thisWeek, companion.l.thisMonth] {
            XCTAssertTrue(normalizedText.contains(label.replacingOccurrences(of: " ", with: "")),
                          "Missing visible \(label): \(text)\n\(diagnostics)")
        }
        if costs == .source {
            // A split currency value creates separate OCR observations; do not join their digits.
            for amount in ["$31.64", "$121.30"] {
                XCTAssertTrue((request.results ?? []).contains {
                    $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "").contains(amount) == true
                }, "Split or missing period cost \(amount) in \(language.rawValue): \(text)\n\(diagnostics)")
            }
        }
        if costs == .unavailable {
            let unavailable = companion.l.costUnavailable.replacingOccurrences(of: " ", with: "")
            XCTAssertEqual((request.results ?? []).filter {
                $0.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "").contains(unavailable) == true
            }.count, 2, "Both unavailable period costs must stay visible\n\(diagnostics)")
        }
        if costs == nil {
            // The original quiet-day fixtures own chart coverage; cost fixtures target the period row.
            if history && day > 1 {
                XCTAssertTrue(Self.drawsBars(series: store.dailyTrendTotals, today: LocalUsageReader.todayKey(),
                                             window: store.dailyTrendWindow),
                              "The store's trend window has no bars to draw")
                XCTAssertTrue(chartVisible,
                              "Historical chart missing: \(text)\n\(diagnostics)")
            } else {
                XCTAssertFalse(chartVisible,
                               "Empty history must not invent a chart\n\(diagnostics)")
            }
        }
        if let output = ProcessInfo.processInfo.environment["PTB_ZERO_USAGE_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = costs != nil ? "\(language.rawValue)-period-costs-\(costs == .source ? "known" : "unavailable").png"
                : (history ? "ko-zero-today-with-history.png" : "ko-zero-all-periods.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
        }
    }
}
