import Foundation

/// 광장에 가끔 떨어지는 아이템(이상한 사탕, 민트). 유닉스 시각을 3시간씩 나눈 칸마다 하나가 떨어진다.
/// 칸 번호만으로 떨어지는 때·자리·종류를 정해 어느 Mac에서나 같고, 밟은 사람이 가방에 넣는다.
/// 일하는 틈에 가끔 들르는 정도가 되도록 드물게 떨어지고, 떨어졌다고 알리지 않는다.
enum PlazaItems {
    /// 칸 하나의 길이. 칸마다 하나가 떨어진다.
    static let slotLength: TimeInterval = 3 * 3600
    /// 칸이 시작하고 이 시간 안의 어느 분에 떨어진다. 떨어진 뒤로는 칸이 끝날 때까지 있다.
    static let appearWindow: TimeInterval = 2 * 3600
    /// 이상한 사탕이 나올 몫. 나머지는 민트다. 사탕은 100M XP짜리라 한도 보상(주 5개)을 넘지 않게 드물게 둔다:
    /// 일하는 시간(세 칸쯤)에 팀 전체로 하루 한 개 남짓이다.
    static let candyShare = 0.4

    struct Spawn: Equatable, Sendable {
        let slot: Int
        let kind: ItemKind
        let tile: TilePoint
        let appearsAt: Date
        let endsAt: Date
    }

    static func slot(at date: Date) -> Int { Int((date.timeIntervalSince1970 / slotLength).rounded(.down)) }

    /// 그 칸의 아이템. 놓을 칸이 없으면 nil.
    static func spawn(slot: Int, candidates: [TilePoint]) -> Spawn? {
        guard !candidates.isEmpty else { return nil }
        var rng = PlazaSplitMix64(seed: UInt64(PlazaNameColor.fnv1a("plaza-item-\(slot)")))
        let start = Date(timeIntervalSince1970: Double(slot) * slotLength)
        let minute = Int(rng.next() % UInt64(appearWindow / 60))
        let kind: ItemKind = rng.unit() < candyShare ? .rareCandy : .mint
        let tile = candidates[Int(rng.next() % UInt64(candidates.count))]
        return Spawn(slot: slot, kind: kind, tile: tile, appearsAt: start.addingTimeInterval(Double(minute) * 60),
                     endsAt: start.addingTimeInterval(slotLength))
    }

    /// 지금 광장에 있는 아이템. 아직 안 떨어졌거나 누가 주웠으면 nil.
    static func current(at date: Date, candidates: [TilePoint], picked: Set<Int>) -> Spawn? {
        visible(spawn(slot: slot(at: date), candidates: candidates), at: date, picked: picked)
    }

    /// `date`가 속한 칸의 아이템이 지금 떠 있는가. 장면은 칸의 아이템을 담아 두고 이것만 화면마다 묻는다.
    static func visible(_ spawn: Spawn?, at date: Date, picked: Set<Int>) -> Spawn? {
        guard let spawn, !picked.contains(spawn.slot), date >= spawn.appearsAt else { return nil }
        return spawn
    }

    /// 아이템이 모닥불 자리에 떨어졌는가. 이전 버전과 같은 자리를 뽑되 불 속의 아이템은 보이지 않게 한다.
    static func isOnCampfire(_ spawn: Spawn, map: PlazaMap) -> Bool { map.tile(at: spawn.tile) == .campfire }

    /// 떨어질 수 있는 칸: 걸을 수 있고(모닥불 자리는 이전 버전의 자리와 같도록 풀밭으로 센다), 쉼터가 아니고, 소식판 바로 옆이 아닌 칸(스페이스로 말 걸기와 겹치지 않게).
    static func candidates(in map: PlazaMap) -> [TilePoint] {
        let shelter = Set(map.shelterTiles)
        var out: [TilePoint] = []
        for y in 0..<map.height {
            for x in 0..<map.width {
                let t = TilePoint(x: x, y: y)
                guard map.isWalkable(t) || map.tile(at: t) == .campfire, !shelter.contains(t) else { continue }
                let nearBoard = [PlazaDirection.up, .down, .left, .right].contains { map.tile(at: PlazaWalker.offset(t, $0)) == .board }
                if !nearBoard { out.append(t) }
            }
        }
        return out
    }
}
