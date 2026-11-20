import XCTest
@testable import PokeTokenBar

/// Answers `post` from a queue (an accepted reply once the queue is empty) and records every body.
private actor FakeUsageTransport: UsageReportTransport {
    enum Answer {
        case reply(String)
        case fail
    }

    struct Down: Error {}

    private var queue: [Answer]
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var bodies: [Data] = []

    init(_ queue: [Answer] = []) { self.queue = queue }

    func holdTheNextPost() { holdNext = true }

    func release() {
        gate?.resume()
        gate = nil
    }

    func post(_ body: Data) async throws -> Data {
        bodies.append(body)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        switch queue.isEmpty ? .reply(FakeUsageTransport.accepted) : queue.removeFirst() {
        case .reply(let text): return Data(text.utf8)
        case .fail: throw Down()
        }
    }

    static let accepted = #"{"ok":true,"accepted":{"days":1,"limits":0},"dropped":0}"#
    static func rejected(_ code: String) -> String { #"{"ok":false,"error":"\#(code)"}"# }
}

@MainActor
private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
final class UsageReporterTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let noon = Date(timeIntervalSince1970: 1_794_798_000) // 2026-11-16 12:00 KST
    private let today = "2026-11-16"
    private let email = "someone@likelion.net"

    @MainActor private struct Rig {
        let settings: TeamSettings
        let reporter: UsageReporter
        let transport: FakeUsageTransport
        let clock: Clock
        let defaults: UserDefaults
        let interval: TimeInterval
        var ledger: UsageReportLedger { UsageReportLedger(defaults: defaults, timeZone: TimeZone(identifier: "Asia/Seoul")!) }
    }

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private func daily(_ i: Int) -> DailyUsage {
        DailyUsage(date: today, inputTokens: i, outputTokens: 1, cacheCreationTokens: 0,
                   cacheReadTokens: 0, totalTokens: i + 1, totalCost: 0)
    }

    private func snapshot(_ i: Int) -> ProviderSnapshot {
        ProviderSnapshot(providerID: "codex", displayName: "codex", today: nil, activeBlock: nil, weekTotal: nil,
                         monthTotal: nil, recentDaily: [daily(i)], fetchedAt: noon)
    }

    private func limit(readAt: Date) throws -> ClaudeAccountLimits {
        let json = #"{"seven_day": {"utilization": 42.5, "resets_at": "2026-11-20T00:00:00Z"}, "limits": null}"#
        var status = try JSONDecoder().decode(LimitStatus.self, from: Data(json.utf8))
        status.planDisplayName = "Max"
        status.accountEmail = email
        return ClaudeAccountLimits.defaultAccount(status, isExpired: false, updatedAt: readAt)
    }

    private func makeRig(_ suite: String, ready: Bool = true, answers: [FakeUsageTransport.Answer] = [],
                         inputs: Box<UsageReportInputs>? = nil) -> (Rig, Box<UsageReportInputs>) {
        let defaults = TestDefaults.make(suite: suite)
        let settings = TeamSettings(defaults: defaults)
        var rng = SystemRandomNumberGenerator()
        settings.code = TeamCode.generate(using: &rng)
        settings.nickname = "tester"
        settings.isEnabled = ready
        let box = inputs ?? Box(UsageReportInputs(snapshots: [snapshot(10)], claudeAccounts: [], codex: nil, codexReadAt: nil))
        let transport = FakeUsageTransport(answers)
        let clock = Clock(noon)
        let reporter = UsageReporter(
            settings: settings, defaults: defaults, appVersion: "9.9.9", platform: "mac",
            inputs: { box.value }, transport: transport, now: { clock.date }, timeZone: seoul)
        let rig = Rig(settings: settings, reporter: reporter, transport: transport, clock: clock,
                      defaults: defaults, interval: UsageReportPlanner.sendInterval(memberID: settings.memberID))
        return (rig, box)
    }

    /// Polls until `condition` holds or the deadline passes.
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out: \(message)", file: file, line: line)
    }

    private func decoded(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func days(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try decoded(data)["days"] as? [[String: Any]])
    }

    // MARK: when to send

    func testTheFirstRefreshAfterLaunchSendsAndTheNextOneWaits() async throws {
        let (rig, _) = makeRig("usage.reporter.first.\(UUID())")
        rig.reporter.start()
        await rig.reporter.storeRefreshed().value
        var count = await rig.transport.bodies.count
        XCTAssertEqual(count, 1)

        rig.clock.date = noon.addingTimeInterval(120)
        await rig.reporter.storeRefreshed().value
        await rig.reporter.tick()
        count = await rig.transport.bodies.count
        XCTAssertEqual(count, 1, "two minutes after an attempt nothing goes out")

        // The wait ends at the interval, not before.
        rig.clock.date = noon.addingTimeInterval(rig.interval - 1)
        await rig.reporter.tick()
        count = await rig.transport.bodies.count
        XCTAssertEqual(count, 1)
        rig.clock.date = noon.addingTimeInterval(rig.interval)
        await rig.reporter.storeRefreshed().value
        count = await rig.transport.bodies.count
        XCTAssertEqual(count, 2)
        // Nothing changed, yet the body still goes out so the sheet sees the app is alive.
        let all = await rig.transport.bodies
        XCTAssertTrue(try days(XCTUnwrap(all.last)).isEmpty)
    }

    func testTheHourlyTickSendsWithoutAnyRefresh() async throws {
        let (rig, _) = makeRig("usage.reporter.tick.\(UUID())")
        rig.reporter.start()
        rig.clock.date = noon.addingTimeInterval(rig.interval)
        await rig.reporter.tick()
        let bodies = await rig.transport.bodies
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(try days(bodies[0]).count, 1)
    }

    func testNothingIsSentWhileTheTeamIsOff() async throws {
        let (rig, _) = makeRig("usage.reporter.off.\(UUID())", ready: false)
        rig.reporter.start()
        await rig.reporter.storeRefreshed().value
        await rig.reporter.tick()
        let count = await rig.transport.bodies.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(rig.reporter.isLoopRunning)
        XCTAssertEqual(rig.ledger.offPeriods.count, 1)
        XCTAssertNil(rig.ledger.offPeriods[0].end)
        XCTAssertNil(rig.ledger.firstDay)

        // A nickname the team would reject keeps it off too.
        rig.settings.isEnabled = true
        rig.settings.nickname = "  "
        rig.clock.date = noon.addingTimeInterval(rig.interval)
        await rig.reporter.tick()
        let after = await rig.transport.bodies.count
        XCTAssertEqual(after, 0)
    }

    func testASendAlreadyInFlightBlocksTheNextOne() async throws {
        let (rig, _) = makeRig("usage.reporter.flight.\(UUID())")
        rig.reporter.start()
        await rig.transport.holdTheNextPost()
        let first = rig.reporter.storeRefreshed()
        await eventually("the first post reached the transport") { await rig.transport.bodies.count == 1 }
        rig.clock.date = noon.addingTimeInterval(rig.interval * 2)
        await rig.reporter.tick()
        let during = await rig.transport.bodies.count
        XCTAssertEqual(during, 1)
        await rig.transport.release()
        await first.value
        // Once it is done the next due attempt goes out.
        await rig.reporter.tick()
        let after = await rig.transport.bodies.count
        XCTAssertEqual(after, 2)
    }

    // MARK: team on and off

    func testTurningTheTeamOffAndOnRecordsThePeriodAndTheLoop() async throws {
        let (rig, _) = makeRig("usage.reporter.toggle.\(UUID())")
        rig.reporter.start()
        XCTAssertTrue(rig.reporter.isLoopRunning)
        XCTAssertEqual(rig.ledger.firstDay, today)
        XCTAssertTrue(rig.ledger.offPeriods.isEmpty)

        let offAt = noon.addingTimeInterval(600)
        rig.clock.date = offAt
        rig.settings.isEnabled = false
        await eventually("the observation saw the team go off") { rig.reporter.settingsChangesHandled >= 1 }
        XCTAssertFalse(rig.reporter.isLoopRunning)
        XCTAssertEqual(rig.ledger.offPeriods, [.init(start: offAt, end: nil)])

        let onAt = noon.addingTimeInterval(7200)
        rig.clock.date = onAt
        rig.settings.isEnabled = true
        await eventually("the observation saw the team come back") { rig.reporter.settingsChangesHandled >= 2 }
        XCTAssertTrue(rig.reporter.isLoopRunning)
        XCTAssertEqual(rig.ledger.offPeriods, [.init(start: offAt, end: onAt)])
        // The 10 minutes before it went off still belong to the team; the time off belongs to none.
        XCTAssertEqual(rig.ledger.dayTeams.map(\.seconds), [600])
    }

    /// A sleep the test controls: it records what the loop asks for and waits until released.
    private final class Sleeps: @unchecked Sendable {
        var requested: [Duration] = []
        var gates: [CheckedContinuation<Void, Never>] = []
        var skipFirst = false
        @MainActor func sleep(_ duration: Duration) async {
            requested.append(duration)
            if skipFirst && requested.count == 1 { return }
            await withCheckedContinuation { gates.append($0) }
        }
        func releaseAll() { let all = gates; gates = []; all.forEach { $0.resume() } }
    }

    func testTheLoopSendsByItselfAndStopsWhenTheReporterIsGone() async throws {
        let (rig, _) = makeRig("usage.reporter.loop.\(UUID())")
        let sleeps = Sleeps()
        sleeps.skipFirst = true
        rig.reporter.sleepForTesting = { await sleeps.sleep($0) }
        rig.reporter.start()
        await eventually("the loop sent without any refresh") { await rig.transport.bodies.count == 1 }
        rig.settings.isEnabled = false
        await eventually("the loop stopped") { !rig.reporter.isLoopRunning }
        sleeps.releaseAll()

        // A reporter nobody holds is not kept alive by its sleeping loop.
        weak var weakReporter: UsageReporter?
        let asleep = Sleeps()
        do {
            let (other, _) = makeRig("usage.reporter.loop.gone.\(UUID())")
            other.reporter.sleepForTesting = { await asleep.sleep($0) }
            other.reporter.start()
            await eventually("the loop is asleep") { asleep.gates.count == 1 }
            weakReporter = other.reporter
        }
        await eventually("the sleeping loop let the reporter go") { weakReporter == nil }
        asleep.releaseAll()
    }

    func testARefreshInTheFirstPeriodDoesNotPushTheLoopAWholePeriodLate() async throws {
        let (rig, _) = makeRig("usage.reporter.loopdue.\(UUID())")
        let sleeps = Sleeps()
        rig.reporter.sleepForTesting = { await sleeps.sleep($0) }
        rig.reporter.start()
        await eventually("the loop is asleep") { sleeps.requested.count == 1 }
        XCTAssertEqual(sleeps.requested, [.seconds(rig.interval)], "nothing attempted yet: the whole interval")

        // A refresh sends 10 minutes in; the loop's own schedule ends one interval after the start.
        rig.clock.date = noon.addingTimeInterval(600)
        await rig.reporter.storeRefreshed().value
        rig.clock.date = noon.addingTimeInterval(rig.interval)
        sleeps.releaseAll()
        await eventually("the loop woke and asked for the rest") { sleeps.requested.count == 2 }
        var count = await rig.transport.bodies.count
        XCTAssertEqual(count, 1, "the attempt 10 minutes ago is not yet an interval old")
        XCTAssertEqual(sleeps.requested[1], .seconds(600), "it sleeps to the due time, not another interval")

        // At the due time the loop sends on its own.
        rig.clock.date = noon.addingTimeInterval(600 + rig.interval)
        sleeps.releaseAll()
        await eventually("the loop sent at the due time") { await rig.transport.bodies.count == 2 }
        await eventually("the loop slept again") { sleeps.requested.count == 3 }
        XCTAssertEqual(sleeps.requested[2], .seconds(rig.interval))
        count = await rig.transport.bodies.count
        XCTAssertEqual(count, 2)
        rig.settings.isEnabled = false
        await eventually("the loop stopped") { !rig.reporter.isLoopRunning }
        sleeps.releaseAll()
    }

    // MARK: results

    func testAFailedSendCommitsNothingAndTheNextAttemptResends() async throws {
        let failures: [(String, FakeUsageTransport.Answer)] = [
            ("thrown", .fail),
            ("html", .reply("<html>Sign in</html>")),
            ("device_mismatch", .reply(FakeUsageTransport.rejected("device_mismatch"))),
            ("bad_member", .reply(FakeUsageTransport.rejected("bad_member"))),
        ]
        for (name, failure) in failures {
            let first = noon.addingTimeInterval(-3600)
            let box = Box(UsageReportInputs(snapshots: [snapshot(10)], claudeAccounts: [try limit(readAt: first)],
                                            codex: nil, codexReadAt: nil))
            let (rig, _) = makeRig("usage.reporter.fail.\(name).\(UUID())", answers: [.reply(FakeUsageTransport.accepted), failure],
                                   inputs: box)
            rig.reporter.start()
            await rig.reporter.tick()
            let sentDays = rig.ledger.sentDays
            let sentLimits = rig.ledger.sentLimits
            let sentAt = rig.reporter.lastSentAt
            XCTAssertEqual(sentDays.count, 1, name)
            XCTAssertEqual(sentLimits.count, 1, name)
            XCTAssertEqual(sentAt, noon, name)

            // New numbers and a newer limit read: the failing attempt must leave both unsent.
            box.value = UsageReportInputs(snapshots: [snapshot(20)], claudeAccounts: [try limit(readAt: noon)],
                                          codex: nil, codexReadAt: nil)
            rig.clock.date = noon.addingTimeInterval(rig.interval)
            await rig.reporter.tick()
            XCTAssertEqual(rig.ledger.sentDays, sentDays, name)
            XCTAssertEqual(rig.ledger.sentLimits, sentLimits, name)
            XCTAssertEqual(rig.ledger.lastSentAt, sentAt, name)
            XCTAssertEqual(rig.reporter.lastSentAt, sentAt, name)

            rig.clock.date = noon.addingTimeInterval(rig.interval * 2)
            await rig.reporter.tick()
            let bodies = await rig.transport.bodies
            XCTAssertEqual(bodies.count, 3, name)
            XCTAssertEqual(try days(bodies[2]).count, 1, name)
            let failed = try decoded(bodies[1])
            let retried = try decoded(bodies[2])
            XCTAssertEqual(failed["days"] as? NSArray, retried["days"] as? NSArray, name)
            XCTAssertEqual((retried["limits"] as? [Any])?.count, 1, name)
            XCTAssertNotEqual(rig.ledger.sentDays, sentDays, name)
        }
    }

    func testAnAcceptedSendCommitsAndUnchangedDaysAreNotResent() async throws {
        let box = Box(UsageReportInputs(snapshots: [snapshot(10)], claudeAccounts: [try limit(readAt: noon)],
                                        codex: nil, codexReadAt: nil))
        let (rig, _) = makeRig("usage.reporter.accepted.\(UUID())", inputs: box)
        XCTAssertNil(rig.reporter.lastSentAt)
        rig.reporter.start()
        await rig.reporter.tick()
        XCTAssertEqual(rig.reporter.lastSentAt, noon)
        XCTAssertEqual(rig.ledger.lastSentAt, noon)
        XCTAssertEqual(Array(rig.ledger.sentDays.keys), [today])
        XCTAssertEqual(rig.ledger.sentLimits.values.map { $0 }, [noon.timeIntervalSince1970])

        rig.clock.date = noon.addingTimeInterval(rig.interval)
        await rig.reporter.tick()
        let bodies = await rig.transport.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(try days(bodies[1]).isEmpty)
        XCTAssertTrue((try decoded(bodies[1])["limits"] as? [Any])?.isEmpty == true)

        // A real change goes out again, a restart (a new reporter on the same ledger) does not resend.
        box.value = UsageReportInputs(snapshots: [snapshot(11)], claudeAccounts: [], codex: nil, codexReadAt: nil)
        rig.clock.date = noon.addingTimeInterval(rig.interval * 2)
        await rig.reporter.tick()
        let third = await rig.transport.bodies
        XCTAssertEqual(try days(third[2]).count, 1)
    }

    func testTwoAccountsOfOneLoginCommitTheNewerRead() async throws {
        let older = noon.addingTimeInterval(-600)
        let box = Box(UsageReportInputs(snapshots: [], claudeAccounts: [try limit(readAt: noon), try limit(readAt: older)],
                                        codex: nil, codexReadAt: nil))
        let (rig, _) = makeRig("usage.reporter.twins.\(UUID())", inputs: box)
        rig.reporter.start()
        await rig.reporter.tick()
        XCTAssertEqual(rig.ledger.sentLimits.values.map { $0 }, [noon.timeIntervalSince1970])
    }

    func testTheBodyCarriesNoTeamCodeOrEmail() async throws {
        let box = Box(UsageReportInputs(snapshots: [snapshot(10)], claudeAccounts: [try limit(readAt: noon)],
                                        codex: nil, codexReadAt: nil))
        let (rig, _) = makeRig("usage.reporter.privacy.\(UUID())", inputs: box)
        rig.reporter.start()
        await rig.reporter.tick()
        let sent = await rig.transport.bodies
        let data = try XCTUnwrap(sent.first)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let code = try XCTUnwrap(rig.settings.code)
        XCTAssertFalse(text.contains(code.normalized))
        XCTAssertFalse(text.contains(email))
        XCTAssertTrue(text.contains("likelion.net"), "the domain is the one thing kept")
        let member = try XCTUnwrap(try decoded(data)["member"] as? [String: Any])
        XCTAssertEqual(member["nickname"] as? String, "tester")
        XCTAssertEqual(member["id"] as? String, rig.settings.memberID)
        XCTAssertEqual(member["secret"] as? String, rig.ledger.secret)
        XCTAssertEqual(member["appVersion"] as? String, "9.9.9")
        XCTAssertEqual(member["platform"] as? String, "mac")
        XCTAssertEqual(try days(data).first?["team"] as? String, code.usageTeamID)
        let limits = try XCTUnwrap(try decoded(data)["limits"] as? [[String: Any]])
        XCTAssertEqual(limits.first?["team"] as? String, code.usageTeamID)
    }

    func testTheTeamSwitchMidDayGoesToTheLongerTeam() async throws {
        let (rig, _) = makeRig("usage.reporter.switch.\(UUID())")
        let teamA = try XCTUnwrap(rig.settings.code)
        let nameA = try XCTUnwrap(rig.settings.currentTeam?.name)
        rig.reporter.start()

        // 50 minutes with team A, then the switch, then 20 minutes with team B.
        rig.clock.date = noon.addingTimeInterval(3000)
        var rng = SystemRandomNumberGenerator()
        rig.settings.code = TeamCode.generate(using: &rng)
        await eventually("the observation saw the switch") { rig.reporter.settingsChangesHandled >= 1 }
        XCTAssertTrue(rig.reporter.isLoopRunning)
        rig.clock.date = noon.addingTimeInterval(4200)
        await rig.reporter.tick()

        let sent = await rig.transport.bodies
        let data = try XCTUnwrap(sent.first)
        let day = try XCTUnwrap(try days(data).first)
        XCTAssertEqual(day["team"] as? String, teamA.usageTeamID)
        XCTAssertEqual(day["teamLabel"] as? String, nameA)
        // The current team still owns the limits.
        XCTAssertNotEqual(day["team"] as? String, rig.settings.code?.usageTeamID)
    }
}
