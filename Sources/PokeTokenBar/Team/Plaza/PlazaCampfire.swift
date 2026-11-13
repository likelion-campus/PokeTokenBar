import Foundation

/// 팀이 함께 쓰는 모닥불 스위치. 누가 켜거나 끄면 그 Mac의 벽시계(유닉스 초, `PlazaIceBreak.at` 과 같은 약속)와 함께
/// 프레즌스에 실려 가고, 모두가 더 늦은 쪽을 따른다.
struct PlazaCampfireSwitch: Codable, Equatable, Sendable {
    /// true: 켰다. false: 껐다. nil: 손대지 않은 상태로 돌렸다(집중하는 사람이 있으면 켜진다).
    var lit: Bool?
    var at: Double
}

/// 모닥불 둘레의 자리와 시간 규칙. SpriteKit과 무관한 값이다.
enum PlazaCampfire {
    struct Seat: Equatable, Sendable {
        let tile: TilePoint
        let facing: PlazaDirection
    }

    /// 구덩이 왼쪽 위 칸에서 본 자리 오프셋과 바라보는 방향. 순서가 동률일 때의 우선순위다.
    private static let seatOffsets: [(dx: Int, dy: Int, facing: PlazaDirection)] = [
        (-1, -2, .down), (2, -2, .down), (-4, -2, .right), (5, -2, .left),
        (-3, 1, .right), (4, 1, .left), (-1, 4, .up), (2, 4, .up),
    ]

    /// 앉는 자리. 지도의 모닥불 자리(왼쪽 위 칸)에서 도출한다. 순서가 동률일 때의 우선순위다.
    static let seats: [Seat] = {
        guard let origin = PlazaMapData.map.campfireTiles.first else { return [] }
        return seatOffsets.map { Seat(tile: TilePoint(x: origin.x + $0.dx, y: origin.y + $0.dy), facing: $0.facing) }
    }()

    /// 고를 수 있는 집중 시간(분).
    static let durations = [25, 50, 480]

    static let frameCount = 12
    static let frameDuration: TimeInterval = 0.09
    static let smokeDuration: TimeInterval = 15

    /// 받은 스위치의 `at` 이 내 시계보다 앞서도 봐주는 시계 어긋남.
    static let clockSlack: TimeInterval = 60

    /// s.at 이 유한하고 now + 60초 이하일 때만 s.
    static func accepted(_ s: PlazaCampfireSwitch?, now: Date) -> PlazaCampfireSwitch? {
        guard let s, s.at.isFinite, s.at <= now.timeIntervalSince1970 + clockSlack else { return nil }
        return s
    }

    /// `at` 이 더 큰 쪽. nil 은 진다. 같으면 끔 > 켬 > 손대지 않음 순서로 이긴다(어느 Mac에서 합쳐도 같다).
    static func merged(_ a: PlazaCampfireSwitch?, _ b: PlazaCampfireSwitch?) -> PlazaCampfireSwitch? {
        guard let a else { return b }
        guard let b else { return a }
        if b.at != a.at { return b.at > a.at ? b : a }
        func rank(_ s: PlazaCampfireSwitch) -> Int { s.lit == false ? 2 : (s.lit == true ? 1 : 0) }
        return rank(b) > rank(a) ? b : a
    }

    /// 내가 지금 바꾼 스위치. 아는 스위치의 시계가 내 것보다 앞서 있어도 내 것이 이기게 그보다 조금 뒤로 찍는다.
    static func flipped(to lit: Bool?, after known: PlazaCampfireSwitch?, now: Date) -> PlazaCampfireSwitch {
        PlazaCampfireSwitch(lit: lit, at: max(now.timeIntervalSince1970, (known?.at ?? -.infinity) + 0.001))
    }

    /// 스위치가 켬이나 끔이면 그대로, 아니면 집중하는 사람이 있을 때 켜진다.
    static func isLit(_ s: PlazaCampfireSwitch?, anyoneFocusing: Bool) -> Bool { s?.lit ?? anyoneFocusing }

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

    /// 저장된 자리 칸에 제곱거리가 가장 가까운 자리(점유는 보지 않는다). 동률이면 목록에서 앞선 자리.
    /// 모닥불이 옮겨지기 전 버전에서 저장한 집중을 새 자리로 옮길 때 쓴다.
    static func nearestSeat(to p: TilePoint) -> Seat? {
        var best: (seat: Seat, d: Int)?
        for seat in seats {
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
