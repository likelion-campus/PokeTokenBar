import Foundation

/// 모닥불 둘레의 자리와 시간 규칙. SpriteKit과 무관한 값이다.
enum PlazaCampfire {
    struct Seat: Equatable, Sendable {
        let tile: TilePoint
        let facing: PlazaDirection
    }

    /// 앉는 자리. 순서가 동률일 때의 우선순위다.
    static let seats: [Seat] = [
        Seat(tile: TilePoint(x: 35, y: 21), facing: .down),
        Seat(tile: TilePoint(x: 38, y: 21), facing: .down),
        Seat(tile: TilePoint(x: 32, y: 21), facing: .right),
        Seat(tile: TilePoint(x: 41, y: 21), facing: .left),
        Seat(tile: TilePoint(x: 33, y: 24), facing: .right),
        Seat(tile: TilePoint(x: 40, y: 24), facing: .left),
        Seat(tile: TilePoint(x: 35, y: 27), facing: .up),
        Seat(tile: TilePoint(x: 38, y: 27), facing: .up),
    ]

    /// 고를 수 있는 집중 시간(분).
    static let durations = [25, 50, 480]

    static let frameCount = 12
    static let frameDuration: TimeInterval = 0.09
    static let smokeDuration: TimeInterval = 15

    /// 비어 있는 자리 중 제곱거리가 가장 가까운 곳. 동률이면 목록에서 앞선 자리.
    static func nearestFreeSeat(from p: TilePoint, occupied: Set<TilePoint>) -> Seat? {
        var best: (seat: Seat, d: Int)?
        for seat in seats where !occupied.contains(seat.tile) {
            let dx = seat.tile.x - p.x, dy = seat.tile.y - p.y
            let d = dx * dx + dy * dy
            if best == nil || d < best!.d { best = (seat, d) }
        }
        return best?.seat
    }

    /// 남은 시간 표기. 다음 초로 올림하고 0 아래로 내려가지 않는다.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
