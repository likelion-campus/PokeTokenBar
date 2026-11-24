import XCTest
@testable import PokeTokenBar

/// Antigravity API group titles are English. Popover already maps them through `L`;
/// alerts / candy / pet bubbles must use the same mapping (#322).
@MainActor
final class AntigravityGroupLocalizationTests: XCTestCase {

    func testGroupTitleMapsKnownAPINamesInEveryLanguage() async {
        for lang in AppLanguage.allCases {
            let l = L(lang)
            XCTAssertEqual(l.antigravityGroupTitle("Gemini Models"), l.antigravityGeminiGroup, "\(lang)")
            XCTAssertEqual(l.antigravityGroupTitle("Claude and GPT models"), l.antigravityThirdPartyGroup, "\(lang)")
            XCTAssertEqual(l.antigravityGroupTitle("GPT Models"), l.antigravityThirdPartyGroup, "\(lang)")
            XCTAssertEqual(l.antigravityGroupTitle("3P quota"), l.antigravityThirdPartyGroup, "\(lang)")
            XCTAssertEqual(l.antigravityGroupTitle("Custom Team Cap"), "Custom Team Cap", "\(lang)")
        }
    }

    func testKoreanCandyAndAlertWindowsDropEnglishAPIGroupNames() async {
        let suite = "agy-i18n-\(UUID().uuidString)"
        let defaults = TestDefaults.make(suite: suite)

        let gemini = AntigravityQuotaGroup(
            displayName: "Gemini Models",
            buckets: [
                AntigravityQuotaBucket(bucketId: "gemini-api-5h", displayName: "5h",
                                       window: "5h", remainingFraction: 0),
            ])
        let thirdParty = AntigravityQuotaGroup(
            displayName: "Claude and GPT models",
            buckets: [
                AntigravityQuotaBucket(bucketId: "claude-api-weekly", displayName: "weekly",
                                       window: "weekly", remainingFraction: 0),
            ])
        let status = AntigravityRateLimitStatus(groups: [gemini, thirdParty])
        let store = UsageStore(
            providers: [AGI18nProvider()],
            claudeLimitsProvider: AGI18nClaude(),
            codexLimitsProvider: AGI18nCodex(),
            antigravityLimitsProvider: AGI18nAntigravity(status: status),
            statusProvider: AGI18nStatus(),
            autoRefresh: false,
            defaults: defaults)
        store.localizationLanguage = .ko
        await store.refresh(scheduleEmptyRetry: false)

        let l = L(.ko)
        let candyNames = store.candyEligibleWindows.map(\.name)
        XCTAssertEqual(
            Set(candyNames),
            [
                "\(l.antigravityGeminiGroup) \(l.fiveHourSession)",
                "\(l.antigravityThirdPartyGroup) \(l.weekly)",
            ])
        XCTAssertFalse(candyNames.contains(where: { $0.contains("Gemini Models") }))
        XCTAssertFalse(candyNames.contains(where: { $0.contains("Claude and GPT") }))

        let alertNames = store.buildLimitWindows().windows.map(\.name)
        XCTAssertEqual(
            Set(alertNames),
            [
                "\(l.antigravityGeminiGroup) \(l.fiveHourSession)",
                "\(l.antigravityThirdPartyGroup) \(l.weekly)",
            ])
        XCTAssertFalse(alertNames.contains(where: { $0.contains("Gemini Models") }))
        XCTAssertFalse(alertNames.contains(where: { $0.contains("Claude and GPT") }))
    }

    /// [audit-stability #7] Two groups that both map to "gemini" shared one candy key, so one at 100% granted and
    /// the other re-armed the tier on every poll.
    func testTwoGeminiGroupsGetDistinctCandyKeys() async {
        let defaults = TestDefaults.make(suite: "agy-keys-\(UUID().uuidString)")
        func group(_ name: String, _ id: String, remaining: Double) -> AntigravityQuotaGroup {
            AntigravityQuotaGroup(displayName: name, buckets: [
                AntigravityQuotaBucket(bucketId: id, displayName: "5h", window: "5h", remainingFraction: remaining)])
        }
        let status = AntigravityRateLimitStatus(groups: [group("Gemini Models", "g1", remaining: 0),
                                                          group("Gemini Flash", "g2", remaining: 0.6)])
        let store = UsageStore(
            providers: [AGI18nProvider()], claudeLimitsProvider: AGI18nClaude(), codexLimitsProvider: AGI18nCodex(),
            antigravityLimitsProvider: AGI18nAntigravity(status: status), statusProvider: AGI18nStatus(),
            autoRefresh: false, defaults: defaults)
        await store.refresh(scheduleEmptyRetry: false)
        let keys = store.candyEligibleWindows.map(\.key)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 2, "window keys must be unique: \(keys)")
    }
}

private struct AGI18nClaude: ClaudeLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus {
        throw LimitsError.keychainInteractionNotAllowed
    }
}
private struct AGI18nCodex: CodexLimitsProviding {
    func fetch() async throws -> CodexRateLimitStatus? { nil }
}
private struct AGI18nAntigravity: AntigravityLimitsProviding {
    var status: AntigravityRateLimitStatus
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { status }
}
private final class AGI18nStatus: ProviderStatusProviding, @unchecked Sendable {
    func fetch() async -> [String: ProviderStatus] { [:] }
}
private final class AGI18nProvider: UsageProvider, @unchecked Sendable {
    let id = "antigravity"
    let displayName = "Antigravity"
    func fetchDaily() async throws -> DailyUsage? {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: 0, outputTokens: 0,
                   cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 1, totalCost: 0)
    }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
}
