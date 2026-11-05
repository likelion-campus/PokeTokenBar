import Foundation

/// The team's shared plaza schedule (core time and season period). Last writer wins: anyone can change it and
/// every member converges on the newest `changedAt` (ties go to the greater `changedBy`).
struct PlazaSchedule: Codable, Equatable, Sendable {
    var coreStart: Int
    var coreEnd: Int
    /// "day" | "week" | "month"; anything else reads as `.day`.
    var seasonPeriod: String
    var changedAt: Date
    var changedBy: String
    /// The nickname of whoever changed it, at the time.
    var changedByName: String

    /// `.standard` when the stored range is invalid.
    var coreTime: PlazaCoreTime { PlazaCoreTime(start: coreStart, end: coreEnd) ?? .standard }
    var period: PlazaWeather.Period { PlazaWeather.Period(rawValue: seasonPeriod) ?? .day }

    func isNewer(than other: PlazaSchedule?) -> Bool {
        guard let other else { return true }
        if changedAt != other.changedAt { return changedAt > other.changedAt }
        return changedBy > other.changedBy
    }
}
