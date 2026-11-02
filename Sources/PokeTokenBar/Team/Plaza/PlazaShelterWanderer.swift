import Foundation

/// 쉼터에서 쉬는 팀원이 옆 쉼터 칸으로 어슬렁거리는 규칙.
/// 첫 칸과 난수 씨앗은 멤버 ID의 FNV 해시로만 정해, 어느 Mac에서나 같은 모습이다.
struct PlazaShelterWanderer: Sendable {
    static let intervalRange: ClosedRange<TimeInterval> = 4...10

    private(set) var tile: TilePoint
    private let shelter: Set<TilePoint>
    private var rng: UInt64
    private var untilMove: TimeInterval = 0

    init(memberID: String, shelter: [TilePoint]) {
        precondition(!shelter.isEmpty, "shelter must have at least one tile")
        let hash = PlazaNameColor.fnv1a(memberID)
        self.tile = shelter[Int(hash % UInt32(shelter.count))]
        self.shelter = Set(shelter)
        self.rng = UInt64(hash)
        self.untilMove = nextInterval()
    }

    /// 시간이 흘러 옮겼으면 새 칸을, 아니면 nil을 돌려준다. 한 번에 여러 번 옮겼으면 마지막 칸이다.
    mutating func advance(by dt: TimeInterval) -> TilePoint? {
        var remaining = dt
        var moved: TilePoint?
        while remaining >= untilMove {
            remaining -= untilMove
            let options = [PlazaDirection.up, .down, .left, .right]
                .map { PlazaWalker.offset(tile, $0) }
                .filter { shelter.contains($0) }
            if !options.isEmpty {
                tile = options[Int(nextRandom() % UInt64(options.count))]
                moved = tile
            }
            untilMove = nextInterval()
        }
        untilMove -= remaining
        return moved
    }

    private mutating func nextInterval() -> TimeInterval {
        let unit = Double(nextRandom() >> 11) / Double(1 << 53)
        return Self.intervalRange.lowerBound + unit * (Self.intervalRange.upperBound - Self.intervalRange.lowerBound)
    }

    /// SplitMix64
    private mutating func nextRandom() -> UInt64 {
        rng = rng &+ 0x9E37_79B9_7F4A_7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
