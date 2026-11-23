import Foundation

/// The team's shared name. Last writer wins, exactly like `PlazaSchedule`: anyone can rename and every member
/// converges on the newest `changedAt` (ties go to the greater `changedBy`).
struct TeamNameStamp: Codable, Equatable, Sendable {
    var name: String
    var changedAt: Date
    var changedBy: String

    func isNewer(than other: TeamNameStamp?) -> Bool {
        guard let other else { return true }
        if changedAt != other.changedAt { return changedAt > other.changedAt }
        return changedBy > other.changedBy
    }
}
