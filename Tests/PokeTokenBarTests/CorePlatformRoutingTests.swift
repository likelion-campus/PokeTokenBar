import AppKit
import CoreGraphics
import XCTest
@testable import PokeTokenBar

// The Core hubs (UsageStore, CompanionStore) reach notifications and system events only through `Platform.current`.
// A recording platform proves the routing; the Mac* types are exercised separately as far as a test process allows.

@MainActor
private final class RecordingNotifications: LocalNotifying {
    struct Post: Equatable { let id: String; let title: String; let body: String; let sound: Bool }
    var isAvailable = true
    private(set) var posts: [Post] = []
    private(set) var authorizationRequests = 0
    func requestAuthorization() async -> Bool { authorizationRequests += 1; return true }
    func post(id: String, title: String, body: String, sound: Bool) {
        posts.append(Post(id: id, title: title, body: body, sound: sound))
    }
}

@MainActor
private final class RecordingEvents: SystemEvents {
    var wake: [@Sendable () -> Void] = []
    var screensSleep: [@Sendable () -> Void] = []
    var screensWake: [@Sendable () -> Void] = []
    var dayChange: [@Sendable () -> Void] = []
    var displaysAreAsleep = false
    func onWake(_ f: @escaping @Sendable () -> Void) { wake.append(f) }
    func onScreensSleep(_ f: @escaping @Sendable () -> Void) { screensSleep.append(f) }
    func onScreensWake(_ f: @escaping @Sendable () -> Void) { screensWake.append(f) }
    func onDayChange(_ f: @escaping @Sendable () -> Void) { dayChange.append(f) }
}

private final class CountingSecrets: SecretStoring, @unchecked Sendable {
    nonisolated(unsafe) var reads = 0
    func read(service: String, account: String?) -> Result<Data, SecretError> { reads += 1; return .failure(.notFound) }
}

private struct FixedProvider: UsageProvider {
    let id = "claude_code"
    let displayName = "Claude Code"
    let reportsCost = true
    let tokens: Int
    func fetchDaily() async throws -> DailyUsage? {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: 0, outputTokens: 0,
                   cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: tokens, totalCost: 0)
    }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
}

private struct FixedClaudeLimits: ClaudeLimitsProviding {
    let status: LimitStatus?
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus {
        guard let status else { throw LimitsError.keychainInteractionNotAllowed }
        return status
    }
}

private struct NoCodexLimits: CodexLimitsProviding {
    func fetch() async throws -> CodexRateLimitStatus? { nil }
}

private struct NoAntigravityLimits: AntigravityLimitsProviding {
    func fetch(allowKeychainPrompt: Bool) async throws -> AntigravityRateLimitStatus { throw LimitsError.keychainInteractionNotAllowed }
}

private struct NoStatus: ProviderStatusProviding {
    func fetch() async -> [String: ProviderStatus] { [:] }
}

private final class AwakeFlag: @unchecked Sendable {
    nonisolated(unsafe) var asleep: Bool
    init(asleep: Bool) { self.asleep = asleep }
}

private func fiveHour(_ utilization: Double) -> LimitStatus {
    let json = "{\"five_hour\":{\"utilization\":\(utilization),\"resets_at\":null}}"
    return try! JSONDecoder().decode(LimitStatus.self, from: Data(json.utf8))
}

@MainActor
final class CorePlatformRoutingTests: XCTestCase {
    private var savedPlatform: Platform!
    private var notifications: RecordingNotifications!
    private var events: RecordingEvents!
    private var secrets: CountingSecrets!

    override func setUp() async throws {
        try await super.setUp()
        savedPlatform = Platform.current
        notifications = RecordingNotifications()
        events = RecordingEvents()
        secrets = CountingSecrets()
        Platform.current = Platform(notifications: notifications, secrets: secrets, events: events,
                                    idle: MacIdleClock())
    }

    override func tearDown() async throws {
        Platform.current = savedPlatform
        try await super.tearDown()
    }

    private func makeStore(claude: LimitStatus? = nil, asleep: AwakeFlag = AwakeFlag(asleep: false),
                           suite: String) -> UsageStore {
        UsageStore(providers: [FixedProvider(tokens: 1_000)],
                   claudeLimitsProvider: FixedClaudeLimits(status: claude),
                   codexLimitsProvider: NoCodexLimits(),
                   antigravityLimitsProvider: NoAntigravityLimits(),
                   statusProvider: NoStatus(),
                   autoRefresh: false, defaults: TestDefaults.make(suite: suite),
                   displaysAsleep: { asleep.asleep })
    }

    private func fire(_ hooks: [@Sendable () -> Void], file: StaticString = #filePath, line: UInt = #line) {
        guard let hook = hooks.first else { return XCTFail("the store registered no hook", file: file, line: line) }
        hook()
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), what)
    }

    // MARK: system events

    func testWakeTriggersTheSameRefreshAsBefore() async {
        let asleep = AwakeFlag(asleep: true)
        let store = makeStore(asleep: asleep, suite: "routing-wake")
        XCTAssertEqual(events.wake.count, 1, "init registers exactly one wake hook")
        store.suspendPolling()
        XCTAssertTrue(store.isPollingSuspended)
        asleep.asleep = false
        fire(events.wake)   // what didWake does: handleSystemWake -> clear stale suspension + refresh
        await waitUntil("wake refreshes") { !store.isPollingSuspended && store.todayTotalTokens == 1_000 }
        XCTAssertFalse(store.isPollingSuspended)
        XCTAssertEqual(store.todayTotalTokens, 1_000)
    }

    func testScreensSleepAndWakeSuspendAndResumePolling() async {
        let store = makeStore(suite: "routing-screens")
        fire(events.screensSleep)
        await waitUntil("suspended") { store.isPollingSuspended }
        fire(events.screensWake)
        await waitUntil("resumed") { !store.isPollingSuspended && store.todayTotalTokens == 1_000 }
        XCTAssertFalse(store.isPollingSuspended)
    }

    func testDayChangeRollsTheDayAsBefore() async {
        let store = makeStore(suite: "routing-day")
        XCTAssertEqual(events.dayChange.count, 1)
        XCTAssertEqual(store.todayTotalTokens, 0)
        fire(events.dayChange)   // NSCalendarDayChanged: refresh() so "today" is rebuilt
        await waitUntil("day change refreshes") { store.todayTotalTokens == 1_000 }
        XCTAssertEqual(store.todayTotalTokens, 1_000)
    }

    func testDisplaySleepStateComesFromThePlatformByDefault() async {
        events.displaysAreAsleep = true
        let store = UsageStore(providers: [FixedProvider(tokens: 1)],
                               claudeLimitsProvider: FixedClaudeLimits(status: nil),
                               codexLimitsProvider: NoCodexLimits(),
                               antigravityLimitsProvider: NoAntigravityLimits(),
                               statusProvider: NoStatus(),
                               autoRefresh: false, defaults: TestDefaults.make(suite: "routing-display"))
        store.suspendPolling()
        await store.runSuspendedPollingProbe()
        XCTAssertTrue(store.isPollingSuspended, "the platform says the display sleeps")
        events.displaysAreAsleep = false
        await store.runSuspendedPollingProbe()
        XCTAssertFalse(store.isPollingSuspended, "the platform says the display is awake")
    }

    // MARK: notifications

    func testLimitAlertPostsThroughThePlatform() async {
        let store = makeStore(claude: fiveHour(99), suite: "routing-limit")
        await store.refresh(scheduleEmptyRetry: false)
        XCTAssertEqual(notifications.posts.count, 1, "\(notifications.posts)")
        let post = notifications.posts[0]
        XCTAssertTrue(post.id.hasSuffix("-critical"), post.id)
        XCTAssertTrue(post.sound, "critical alerts play the default sound")
    }

    func testWarningAlertIsSilentAndUnavailablePlatformPostsNothing() async {
        let store = makeStore(claude: fiveHour(85), suite: "routing-warn")
        await store.refresh(scheduleEmptyRetry: false)
        XCTAssertEqual(notifications.posts.map(\.sound), [false])
        XCTAssertTrue(notifications.posts[0].id.hasSuffix("-warning"))

        notifications.isAvailable = false
        let quiet = makeStore(claude: fiveHour(99), suite: "routing-quiet")
        let before = notifications.posts.count
        await quiet.refresh(scheduleEmptyRetry: false)
        XCTAssertEqual(notifications.posts.count, before, "the availability gate stops the post (bundle check)")
    }

    func testNotificationAuthorizationGoesThroughThePlatform() async {
        let store = makeStore(suite: "routing-auth")
        store.requestNotificationAuthorizationIfNeeded()
        store.requestNotificationAuthorizationIfNeeded()
        await waitUntil("auth requested") { self.notifications.authorizationRequests >= 1 }
        XCTAssertEqual(notifications.authorizationRequests, 1, "idempotent")
    }

    func testCandyNotificationPostsThroughThePlatform() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routing-candy-\(UUID()).json")
        let store = CompanionStore(clock: { Date() }, fileURL: url, defaults: TestDefaults.make(suite: "routing-candy"))
        store.grantCandies(from: [], limitsReady: true)   // seeds the feature
        store.grantCandies(from: [CandyWindow(key: "routing.weekly", name: "Test", kind: .weekly,
                                              utilization: 100, epoch: "e1")], limitsReady: true)
        XCTAssertEqual(notifications.posts.count, 1, "\(notifications.posts)")
        XCTAssertTrue(notifications.posts[0].id.hasPrefix("companion-event-"))
        XCTAssertTrue(notifications.posts[0].sound)
        XCTAssertNil(store.latestEvent, "candy grants do not pop on the pet")
    }

    // MARK: secrets (the automatic path still makes no silent Keychain calls)

    func testKeychainReadStillMakesZeroSilentCalls() async {
        let saved = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = saved }
        KeychainReader.resetQueryCountForTesting()
        _ = try? await OAuthLimitsProvider().fetch(allowKeychainPrompt: false)
        _ = try? await AntigravityRateLimitsProvider().fetch(allowKeychainPrompt: false)
        XCTAssertEqual(KeychainReader.queryCount, 0)
        XCTAssertEqual(secrets.reads, 0)
    }

    // MARK: the real Mac implementations

    func testMacSystemEventsFireTheirHooksOnTheObservedCenters() async {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let mac = MacSystemEvents(center: center, workspaceCenter: workspace)
        let fired = expectation(description: "four hooks")
        fired.expectedFulfillmentCount = 4
        mac.onDayChange { fired.fulfill() }
        mac.onWake { fired.fulfill() }
        mac.onScreensSleep { fired.fulfill() }
        mac.onScreensWake { fired.fulfill() }
        center.post(name: .NSCalendarDayChanged, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(mac.displaysAreAsleep, CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }

    func testMacNotificationsAreUnavailableOutsideAnAppBundle() {
        // `UNUserNotificationCenter.current()` crashes here; the hubs must see "unavailable" and never call it.
        XCTAssertFalse(MacNotifications().isAvailable)
        XCTAssertEqual(MacNotifications().isAvailable, AppEnv.isBundledApp)
    }
}
