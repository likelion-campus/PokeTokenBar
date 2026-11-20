import Foundation

/// The device-side memory of the usage reporter: the secret, the first day, the periods with the team
/// off, the time spent per team per day, and what was already sent. Everything lives in `UserDefaults`.
@MainActor
final class UsageReportLedger {
    struct OffPeriod: Codable, Equatable {
        var start: Date
        var end: Date?
    }

    struct TeamStamp: Equatable {
        let id: String
        let label: String
    }

    struct DayTeamEntry: Codable, Equatable {
        var day: String
        var team: String
        var label: String
        var seconds: Double
    }

    private enum Key {
        static let secret = "usageReport.secret"
        static let firstDay = "usageReport.firstDay"
        static let offPeriods = "usageReport.offPeriods"
        static let dayTeams = "usageReport.dayTeams"
        static let sentDays = "usageReport.sentDays"
        static let sentLimits = "usageReport.sentLimits"
        static let lastSentAt = "usageReport.lastSentAt"
    }

    private let defaults: UserDefaults
    private let timeZone: TimeZone
    /// In memory only: the previous presence call. The first call after init counts nothing.
    private var anchor: (time: Date, team: TeamStamp?)?

    init(defaults: UserDefaults, timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.timeZone = timeZone
    }

    var secret: String {
        if let existing = defaults.string(forKey: Key.secret) { return existing }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        defaults.set(value, forKey: Key.secret)
        return value
    }

    var firstDay: String? { defaults.string(forKey: Key.firstDay) }

    func markReady(now: Date) {
        guard firstDay == nil else { return }
        defaults.set(dayString(now), forKey: Key.firstDay)
    }

    var offPeriods: [OffPeriod] { load(Key.offPeriods) ?? [] }

    func teamTurnedOff(now: Date) {
        var periods = offPeriods
        guard periods.last?.end != nil || periods.isEmpty else { return }
        periods.append(OffPeriod(start: now, end: nil))
        save(periods, Key.offPeriods)
    }

    func teamTurnedOn(now: Date) {
        var periods = offPeriods
        guard let last = periods.last, last.end == nil else { return }
        periods[periods.count - 1].end = now
        save(periods, Key.offPeriods)
    }

    func recordPresence(now: Date, team: TeamStamp?) {
        defer { anchor = (now, team) }
        guard let previous = anchor, let prevTeam = previous.team else { return }
        let seconds = min(now.timeIntervalSince(previous.time), UsageReportConfig.presenceCap)
        guard seconds > 0 else { return }
        let day = dayString(now)
        var entries = dayTeams
        if let i = entries.firstIndex(where: { $0.day == day && $0.team == prevTeam.id }) {
            entries[i].seconds += seconds
            entries[i].label = prevTeam.label
        } else {
            entries.append(DayTeamEntry(day: day, team: prevTeam.id, label: prevTeam.label, seconds: seconds))
        }
        save(entries, Key.dayTeams)
    }

    var dayTeams: [DayTeamEntry] { load(Key.dayTeams) ?? [] }

    nonisolated static func dominantTeam(on day: String, in entries: [DayTeamEntry]) -> TeamStamp? {
        let best = entries.filter { $0.day == day }.min { a, b in
            a.seconds != b.seconds ? a.seconds > b.seconds : a.team < b.team
        }
        return best.map { TeamStamp(id: $0.team, label: $0.label) }
    }

    var sentDays: [String: String] { load(Key.sentDays) ?? [:] }
    var sentLimits: [String: Double] { load(Key.sentLimits) ?? [:] }

    var lastSentAt: Date? {
        guard defaults.object(forKey: Key.lastSentAt) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: Key.lastSentAt))
    }

    func commit(days: [String: String], limits: [String: Double], at: Date) {
        save(sentDays.merging(days) { _, new in new }, Key.sentDays)
        save(sentLimits.merging(limits) { _, new in new }, Key.sentLimits)
        defaults.set(at.timeIntervalSince1970, forKey: Key.lastSentAt)
        prune(now: at)
    }

    func prune(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cutoffDate = calendar.date(byAdding: .day, value: -UsageReportConfig.retentionDays, to: now) ?? now
        let cutoff = dayString(cutoffDate)
        save(dayTeams.filter { $0.day >= cutoff }, Key.dayTeams)
        save(sentDays.filter { $0.key >= cutoff }, Key.sentDays)
        save(offPeriods.filter { period in
            guard let end = period.end else { return true }
            return dayString(end) >= cutoff
        }, Key.offPeriods)
    }

    private func dayString(_ date: Date) -> String {
        LocalUsageReader.localDayFormatter(timeZone: timeZone).string(from: date)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
