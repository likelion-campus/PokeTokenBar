import XCTest
@testable import PokeTokenBar

final class UsageReportPlannerTests: XCTestCase {
    typealias Planner = UsageReportPlanner
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let now = Date(timeIntervalSince1970: 1_794_798_000) // 2026-11-16T03:00:00Z = 12:00 KST

    private func kst(_ day: String, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func daily(_ date: String, _ i: Int, _ o: Int, _ cw: Int, _ cr: Int) -> DailyUsage {
        DailyUsage(date: date, inputTokens: i, outputTokens: o, cacheCreationTokens: cw,
                   cacheReadTokens: cr, totalTokens: i + o + cw + cr, totalCost: 0)
    }

    private func snapshot(_ id: String, _ days: [DailyUsage]?) -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, displayName: id, today: nil, activeBlock: nil, weekTotal: nil,
                         monthTotal: nil, recentDaily: days, fetchedAt: now)
    }

    func testNowIsTheExpectedLocalDay() {
        XCTAssertEqual(Planner.dayRange(now: now, timeZone: seoul, firstDay: "2026-11-16"), ["2026-11-16"])
    }

    func testToolsComeFromEverySnapshotAndSkipZeroDays() {
        let tools = Planner.tools(from: [
            snapshot("codex", [daily("2026-11-15", 0, 0, 0, 0), daily("2026-11-16", 1, 2, 3, 4)]),
            snapshot("claude_code", [daily("2026-11-15", 5, 0, 0, 0), daily("2026-11-16", 0, 0, 0, 9)]),
            snapshot("none", nil),
        ])
        XCTAssertEqual(tools["2026-11-15"], [.init(tool: "claude_code", input: 5, output: 0, cacheWrite: 0, cacheRead: 0)])
        XCTAssertEqual(tools["2026-11-16"]?.map(\.tool), ["claude_code", "codex"])
        XCTAssertEqual(tools["2026-11-16"]?[1], .init(tool: "codex", input: 1, output: 2, cacheWrite: 3, cacheRead: 4))
    }

    func testTheRangeStartsAtTheFirstDayAndCoversAtMost21Days() {
        XCTAssertEqual(Planner.dayRange(now: now, timeZone: seoul, firstDay: "2026-11-16"), ["2026-11-16"])
        let long = Planner.dayRange(now: now, timeZone: seoul, firstDay: "2026-10-17")
        XCTAssertEqual(long.count, 21)
        XCTAssertEqual(long.first, "2026-10-27")
        XCTAssertEqual(long.last, "2026-11-16")
        XCTAssertEqual(Planner.dayRange(now: now, timeZone: seoul, firstDay: nil), [])
    }

    private func plan(_ range: [String], offPeriods: [UsageReportLedger.OffPeriod] = [],
                      dayTeams: [UsageReportLedger.DayTeamEntry] = [],
                      tools: [String: [UsageReportBody.Tool]] = [:],
                      current: UsageReportLedger.TeamStamp = .init(id: "t_cur", label: "Cur")) -> [UsageReportBody.Day] {
        Planner.days(range: range, tools: tools, dayTeams: dayTeams, current: current,
                     offPeriods: offPeriods, now: now, timeZone: seoul)
    }

    func testADayInsideATeamOffPeriodIsNotSent() {
        let range = ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"]
        let closed = UsageReportLedger.OffPeriod(start: kst("2026-11-12", 18), end: kst("2026-11-15", 9))
        XCTAssertEqual(plan(range, offPeriods: [closed]).map(\.date), ["2026-11-12", "2026-11-15"])

        let open = UsageReportLedger.OffPeriod(start: kst("2026-11-14", 0), end: nil)
        let all = ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16"]
        XCTAssertEqual(plan(all, offPeriods: [open]).map(\.date), ["2026-11-13", "2026-11-16"])
    }

    func testADayWithoutRecordsUsesTheNearestEarlierTeamElseTheCurrent() {
        let entries = [
            UsageReportLedger.DayTeamEntry(day: "2026-10-22", team: "t_old", label: "Old", seconds: 10),
            UsageReportLedger.DayTeamEntry(day: "2026-11-14", team: "t_a", label: "A", seconds: 5),
            UsageReportLedger.DayTeamEntry(day: "2026-11-14", team: "t_b", label: "B", seconds: 50),
        ]
        let days = plan(["2026-10-27", "2026-11-14", "2026-11-15"], dayTeams: entries)
        XCTAssertEqual(days.map(\.team), ["t_old", "t_b", "t_b"])
        // Nothing earlier at all: the current team.
        let first = plan(["2026-10-21"], dayTeams: entries)
        XCTAssertEqual(first.first?.team, "t_cur")
        XCTAssertEqual(plan(["2026-11-15"]).first?.team, "t_cur")
    }

    func testAnEmptyLabelIsLeftOutAndADayWithoutUsageHasNoTools() {
        let entries = [UsageReportLedger.DayTeamEntry(day: "2026-11-15", team: "t_x", label: "", seconds: 9)]
        let tool = UsageReportBody.Tool(tool: "codex", input: 1, output: 1, cacheWrite: 0, cacheRead: 0)
        let days = plan(["2026-11-14", "2026-11-15"], dayTeams: entries, tools: ["2026-11-15": [tool]])
        XCTAssertNil(days[1].teamLabel)
        XCTAssertEqual(days[1].tools, [tool])
        XCTAssertEqual(days[0].tools, [])
        XCTAssertEqual(days[0].teamLabel, "Cur")
    }

    func testOnlyChangedDaysAreKept() {
        let tool = UsageReportBody.Tool(tool: "codex", input: 1, output: 1, cacheWrite: 0, cacheRead: 0)
        let a = UsageReportBody.Day(date: "2026-11-14", team: "t", teamLabel: nil, tools: [tool])
        let b = UsageReportBody.Day(date: "2026-11-15", team: "t", teamLabel: nil, tools: [tool])
        let sent = [a.date: UsageReportBody.fingerprint(a), b.date: UsageReportBody.fingerprint(b)]
        XCTAssertEqual(Planner.changed([a, b], sent: sent), [])
        var b2 = b
        b2.tools[0].output = 2
        XCTAssertEqual(Planner.changed([a, b2], sent: sent), [b2])
        let c = UsageReportBody.Day(date: "2026-11-16", team: "t", teamLabel: nil, tools: [])
        XCTAssertEqual(Planner.changed([c], sent: sent), [c])
    }

    // MARK: limits

    private func status(sevenDay: String = "null", limits: String = "null", plan: String? = "Max",
                        email: String? = "Kim@Likelion.NET") throws -> LimitStatus {
        let json = #"{"seven_day": \#(sevenDay), "limits": \#(limits)}"#
        var status = try JSONDecoder().decode(LimitStatus.self, from: Data(json.utf8))
        status.planDisplayName = plan
        status.accountEmail = email
        return status
    }

    private func account(_ status: LimitStatus, expired: Bool = false, updated: Date? = nil) -> ClaudeAccountLimits {
        ClaudeAccountLimits.defaultAccount(status, isExpired: expired, updatedAt: updated)
    }

    func testTheClaudeLimitUsesSevenDayThenWeeklyAllAndSkipsExpired() throws {
        let read = Date(timeIntervalSince1970: 1_794_790_000)
        let week = #"{"utilization": 42.5, "resets_at": "2026-11-20T00:00:00Z"}"#
        let ok = try status(sevenDay: week)
        let result = try XCTUnwrap(Planner.claudeLimit(account(ok, updated: read), memberID: "m1", team: "t_1"))
        let id = UsageReportIDs.account(email: "Kim@Likelion.NET", memberID: "m1", localAccountID: "default")
        XCTAssertEqual(result.key, "\(id)|claude")
        XCTAssertEqual(result.readAt, read.timeIntervalSince1970)
        XCTAssertEqual(result.limit.tool, "claude")
        XCTAssertEqual(result.limit.domain, "likelion.net")
        XCTAssertEqual(result.limit.usedPercent, 42.5)
        XCTAssertEqual(result.limit.resetsAt, "2026-11-20T00:00:00Z")
        XCTAssertEqual(result.limit.readAt, UsageReportIDs.isoUTC(read))
        XCTAssertEqual(result.limit.team, "t_1")

        // Plan is trimmed and cut to 40 characters.
        let long = try status(sevenDay: week, plan: "  " + String(repeating: "p", count: 50) + "  ")
        XCTAssertEqual(Planner.claudeLimit(account(long, updated: read), memberID: "m1", team: "t")?.limit.plan.count, 40)

        XCTAssertNil(Planner.claudeLimit(account(ok, expired: true, updated: read), memberID: "m1", team: "t"))
        XCTAssertNil(Planner.claudeLimit(account(ok, updated: nil), memberID: "m1", team: "t"))
        XCTAssertNil(Planner.claudeLimit(account(try status(sevenDay: week, plan: "  "), updated: read), memberID: "m1", team: "t"))
        XCTAssertNil(Planner.claudeLimit(account(try status(sevenDay: week, plan: nil), updated: read), memberID: "m1", team: "t"))

        // No email falls back to the member-based account id and an empty domain.
        let anon = try XCTUnwrap(Planner.claudeLimit(account(try status(sevenDay: week, email: nil), updated: read), memberID: "m1", team: "t"))
        XCTAssertEqual(anon.limit.account, "m_m1_default")
        XCTAssertEqual(anon.limit.domain, "")

        // Weekly data: seven_day half-set falls through to limits[weekly_all].
        let entry = #"[{"kind":"session","percent":9,"resets_at":"2026-11-16T09:00:00Z"},{"kind":"weekly_all","percent":77,"resets_at":"2026-11-21T00:00:00Z"}]"#
        let viaLimits = try XCTUnwrap(Planner.claudeLimit(account(try status(sevenDay: #"{"utilization": 5}"#, limits: entry), updated: read), memberID: "m1", team: "t"))
        XCTAssertEqual(viaLimits.limit.usedPercent, 77)
        XCTAssertEqual(viaLimits.limit.resetsAt, "2026-11-21T00:00:00Z")
        let noReset = try XCTUnwrap(Planner.claudeLimit(account(try status(sevenDay: "null", limits: entry), updated: read), memberID: "m1", team: "t"))
        XCTAssertEqual(noReset.limit.usedPercent, 77)

        // No weekly data in either source.
        let sessionOnly = #"[{"kind":"session","percent":9,"resets_at":"2026-11-16T09:00:00Z"}]"#
        XCTAssertNil(Planner.claudeLimit(account(try status(limits: sessionOnly), updated: read), memberID: "m1", team: "t"))
        let halfWeekly = #"[{"kind":"weekly_all","percent":77},{"kind":"weekly_all","resets_at":"2026-11-21T00:00:00Z"}]"#
        XCTAssertNil(Planner.claudeLimit(account(try status(sevenDay: #"{"utilization": 5}"#, limits: halfWeekly), updated: read), memberID: "m1", team: "t"))
        XCTAssertNil(Planner.claudeLimit(account(try status(), updated: read), memberID: "m1", team: "t"))
    }

    private func codex(plan: String?, primaryMins: Int?, secondaryMins: Int?, secondaryReset: Bool = true) throws -> CodexRateLimitStatus {
        func window(_ mins: Int?, _ used: Int, _ reset: Bool) -> String {
            guard let mins else { return "null" }
            return #"{"usedPercent": \#(used), "windowDurationMins": \#(mins)\#(reset ? #", "resetsAt": 1794900000"# : "")}"#
        }
        let planJSON = plan.map { "\"\($0)\"" } ?? "null"
        let json = #"{"rateLimits": {"primary": \#(window(primaryMins, 11, true)), "secondary": \#(window(secondaryMins, 63, secondaryReset)), "planType": \#(planJSON)}}"#
        return try JSONDecoder().decode(CodexRateLimitStatus.self, from: Data(json.utf8))
    }

    func testTheCodexLimitPicksTheSevenDayWindow() throws {
        let read = Date(timeIntervalSince1970: 1_794_790_000)
        let both = try codex(plan: "plus", primaryMins: 300, secondaryMins: 10_080)
        let result = try XCTUnwrap(Planner.codexLimit(both, readAt: read, memberID: "m1", team: "t_1"))
        let id = UsageReportIDs.account(email: nil, memberID: "m1", localAccountID: "codex")
        XCTAssertEqual(result.key, "\(id)|codex")
        XCTAssertEqual(result.limit.tool, "codex")
        XCTAssertEqual(result.limit.plan, "plus")
        XCTAssertEqual(result.limit.usedPercent, 63)
        XCTAssertEqual(result.limit.domain, "")
        XCTAssertEqual(result.limit.resetsAt, UsageReportIDs.isoUTC(Date(timeIntervalSince1970: 1_794_900_000)))
        XCTAssertEqual(result.readAt, read.timeIntervalSince1970)

        // The primary window is the weekly one.
        let primaryWeekly = try XCTUnwrap(Planner.codexLimit(
            try codex(plan: "plus", primaryMins: 10_080, secondaryMins: nil), readAt: read, memberID: "m1", team: "t"))
        XCTAssertEqual(primaryWeekly.limit.usedPercent, 11)

        XCTAssertNil(Planner.codexLimit(try codex(plan: nil, primaryMins: 300, secondaryMins: 10_080), readAt: read, memberID: "m1", team: "t"))
        XCTAssertNil(Planner.codexLimit(try codex(plan: "", primaryMins: 300, secondaryMins: 10_080), readAt: read, memberID: "m1", team: "t"))
        XCTAssertNil(Planner.codexLimit(nil, readAt: read, memberID: "m1", team: "t"))
        XCTAssertNil(Planner.codexLimit(both, readAt: nil, memberID: "m1", team: "t"))
        // No seven-day window, or one without a reset date.
        XCTAssertNil(Planner.codexLimit(try codex(plan: "plus", primaryMins: 300, secondaryMins: nil), readAt: read, memberID: "m1", team: "t"))
        XCTAssertNil(Planner.codexLimit(try codex(plan: "plus", primaryMins: 300, secondaryMins: 10_080, secondaryReset: false), readAt: read, memberID: "m1", team: "t"))
    }

    func testLimitsAreSentOnlyWhenReadAgainAndCappedAt16() {
        func candidate(_ key: String, _ readAt: Double) -> Planner.LimitCandidate {
            (key: key, readAt: readAt, limit: UsageReportBody.Limit(
                tool: "claude", account: key, domain: "", plan: "p", usedPercent: 1,
                resetsAt: "", readAt: "", team: "t"))
        }
        let kept = Planner.newLimits(
            [candidate("a", 100), candidate("b", 200), candidate("c", 0), candidate("d", 300)],
            sent: ["a": 100, "b": 150, "d": 400])
        XCTAssertEqual(kept.map(\.key), ["b", "c"])
        let many = (0..<20).map { candidate("k\($0)", 5) }
        XCTAssertEqual(Planner.newLimits(many, sent: [:]).map(\.key), (0..<16).map { "k\($0)" })
    }

    func testTheSendIntervalIsStableAndWithinTheSpread() {
        XCTAssertEqual(Planner.sendInterval(memberID: "m1"), Planner.sendInterval(memberID: "m1"))
        var seen = Set<TimeInterval>()
        for i in 0..<50 {
            let value = Planner.sendInterval(memberID: "member-\(i)")
            XCTAssertGreaterThanOrEqual(value, 3600)
            XCTAssertLessThan(value, 4200)
            seen.insert(value)
        }
        XCTAssertGreaterThan(seen.count, 10)
    }
}
