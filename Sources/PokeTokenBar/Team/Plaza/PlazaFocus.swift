import Foundation

/// 모닥불 집중 한 번. 끝나는 시각과 앉은 자리만 저장한다.
struct PlazaFocus: Codable, Equatable, Sendable {
    let endsAt: Date
    let minutes: Int
    let seat: TilePoint

    /// 받은 끝 시각을 믿는 상한: 가장 긴 집중(8시간)에 시계 오차 10분.
    static let maxAhead: TimeInterval = 8 * 3600 + 600

    func isActive(at now: Date) -> Bool { endsAt > now }

    /// 지금보다 뒤이고 상한 안인 끝 시각만 통과시킨다.
    static func accepted(_ endsAt: Date?, now: Date) -> Date? {
        guard let endsAt, endsAt > now, endsAt <= now.addingTimeInterval(maxAhead) else { return nil }
        return endsAt
    }
}
