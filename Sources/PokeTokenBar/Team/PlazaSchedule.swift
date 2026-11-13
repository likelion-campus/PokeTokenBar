import Foundation

/// The team's shared plaza schedule (core time and season period). Last writer wins: anyone can change it and
/// every member converges on the newest `changedAt` (ties go to the greater `changedBy`).
struct PlazaSchedule: Codable, Equatable, Sendable {
    var coreStart: Int
    var coreEnd: Int
    /// The season choice (`PlazaSeasonChoice` raw value). v2.5.632 and earlier wrote "day" | "week" | "month" here for a
    /// weather period they no longer use; those and anything else read as winter. Earlier versions keep and pass on
    /// whatever string they receive, which is why the season travels in this field.
    var seasonPeriod: String
    var changedAt: Date
    var changedBy: String
    /// The nickname of whoever changed it, at the time.
    var changedByName: String

    /// `.standard` when the stored range is invalid.
    var coreTime: PlazaCoreTime { PlazaCoreTime(start: coreStart, end: coreEnd) ?? .standard }
    var season: PlazaSeasonChoice { PlazaSeasonChoice(wire: seasonPeriod) }

    func isNewer(than other: PlazaSchedule?) -> Bool {
        guard let other else { return true }
        if changedAt != other.changedAt { return changedAt > other.changedAt }
        return changedBy > other.changedBy
    }
}
