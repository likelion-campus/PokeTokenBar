import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Pure decisions for the usage reporter: which days and limits go into the next body.
enum UsageReportPlanner {
    typealias OffPeriod = UsageReportLedger.OffPeriod
    typealias TeamStamp = UsageReportLedger.TeamStamp
    typealias DayTeamEntry = UsageReportLedger.DayTeamEntry
    typealias LimitCandidate = (key: String, readAt: Double, limit: UsageReportBody.Limit)

    static func tools(from snapshots: [ProviderSnapshot]) -> [String: [UsageReportBody.Tool]] {
        var result: [String: [UsageReportBody.Tool]] = [:]
        for snapshot in snapshots {
            for day in snapshot.recentDaily ?? [] {
                guard day.inputTokens > 0 || day.outputTokens > 0
                        || day.cacheCreationTokens > 0 || day.cacheReadTokens > 0 else { continue }
                result[day.date, default: []].append(UsageReportBody.Tool(
                    tool: snapshot.providerID, input: day.inputTokens, output: day.outputTokens,
                    cacheWrite: day.cacheCreationTokens, cacheRead: day.cacheReadTokens))
            }
        }
        return result.mapValues { $0.sorted { $0.tool < $1.tool } }
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static func dayRange(now: Date, timeZone: TimeZone, firstDay: String?) -> [String] {
        guard let firstDay else { return [] }
        let calendar = calendar(timeZone)
        let f = formatter(timeZone)
        let today = calendar.startOfDay(for: now)
        let days = (0...20).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(f.string(from:))
        }
        return days.filter { $0 >= firstDay }
    }

    static func isFullyOff(_ day: String, periods: [OffPeriod], now: Date, timeZone: TimeZone) -> Bool {
        let calendar = calendar(timeZone)
        guard let date = formatter(timeZone).date(from: day) else { return false }
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return periods.contains { $0.start <= start && ($0.end ?? now) >= next }
    }

    static func days(range: [String], tools: [String: [UsageReportBody.Tool]], dayTeams: [DayTeamEntry],
                     current: TeamStamp, offPeriods: [OffPeriod], now: Date,
                     timeZone: TimeZone) -> [UsageReportBody.Day] {
        var result: [UsageReportBody.Day] = []
        for day in range {
            if isFullyOff(day, periods: offPeriods, now: now, timeZone: timeZone) { continue }
            let team = UsageReportLedger.dominantTeam(on: day, in: dayTeams)
                ?? dayTeams.map(\.day).filter { $0 < day }.max()
                    .flatMap { UsageReportLedger.dominantTeam(on: $0, in: dayTeams) }
                ?? current
            result.append(UsageReportBody.Day(
                date: day, team: team.id, teamLabel: team.label.isEmpty ? nil : team.label,
                tools: tools[day] ?? []))
        }
        return result
    }

    static func changed(_ days: [UsageReportBody.Day], sent: [String: String]) -> [UsageReportBody.Day] {
        days.filter { UsageReportBody.fingerprint($0) != sent[$0.date] }
    }

    static func claudeLimit(_ account: ClaudeAccountLimits, memberID: String, team: String) -> LimitCandidate? {
        let status = account.status
        guard !account.isExpired, let updatedAt = account.updatedAt else { return nil }
        let plan = status.planDisplay?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !plan.isEmpty else { return nil }
        let percent: Double
        let reset: Date
        if let used = status.sevenDay?.utilization, let date = status.sevenDay?.resetDate {
            (percent, reset) = (used, date)
        } else if let entry = (status.limits ?? []).first(where: {
            $0.kind == "weekly_all" && $0.percent != nil && $0.resetDate != nil
        }), let used = entry.percent, let date = entry.resetDate {
            (percent, reset) = (used, date)
        } else {
            return nil
        }
        let id = UsageReportIDs.account(email: status.accountEmail, memberID: memberID, localAccountID: account.id)
        return (key: "\(id)|claude", readAt: updatedAt.timeIntervalSince1970, limit: UsageReportBody.Limit(
            tool: "claude", account: id, domain: UsageReportIDs.domain(email: status.accountEmail),
            plan: String(plan.prefix(40)), usedPercent: percent, resetsAt: UsageReportIDs.isoUTC(reset),
            readAt: UsageReportIDs.isoUTC(updatedAt), team: team))
    }

    static func codexLimit(_ status: CodexRateLimitStatus?, readAt: Date?, memberID: String,
                           team: String) -> LimitCandidate? {
        guard let status, let readAt, let plan = status.rateLimits.planType, !plan.isEmpty else { return nil }
        let window = [status.rateLimits.primary, status.rateLimits.secondary].compactMap { $0 }
            .first { $0.windowSpan == LimitWindowSpan.sevenDay && $0.resetDate != nil }
        guard let window, let reset = window.resetDate else { return nil }
        let id = UsageReportIDs.account(email: nil, memberID: memberID, localAccountID: "codex")
        return (key: "\(id)|codex", readAt: readAt.timeIntervalSince1970, limit: UsageReportBody.Limit(
            tool: "codex", account: id, domain: "", plan: plan, usedPercent: Double(window.usedPercent),
            resetsAt: UsageReportIDs.isoUTC(reset), readAt: UsageReportIDs.isoUTC(readAt), team: team))
    }

    static func newLimits(_ candidates: [LimitCandidate], sent: [String: Double]) -> [LimitCandidate] {
        Array(candidates.filter { $0.readAt > (sent[$0.key] ?? -1) }.prefix(UsageReportConfig.maxLimits))
    }

    /// `baseInterval` plus a stable per-member offset in `0..<spreadWindow`, so members do not send together.
    static func sendInterval(memberID: String) -> TimeInterval {
        let bytes = Array(SHA256.hash(data: Data(memberID.utf8)).prefix(2))
        let value = Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return UsageReportConfig.baseInterval + TimeInterval(value % Int(UsageReportConfig.spreadWindow))
    }
}
