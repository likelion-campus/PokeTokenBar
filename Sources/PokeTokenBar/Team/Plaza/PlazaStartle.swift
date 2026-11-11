import Foundation

/// 놀래키기: 풀숲에 숨어서 뛴 점프에 바로 옆 팀원이 놀라 펄쩍 뛴다. 몸통박치기처럼 놀라는 쪽 Mac이 정한다.
enum PlazaStartle {
    /// 한 번 놀란 뒤 다시 놀라기까지.
    static let cooldown: TimeInterval = 3

    /// `jumper`가 풀숲 칸에서 뛰었고 `victim`이 풀숲 밖 바로 옆 칸에 있다. 놀란 사람은 풀숲 밖이라 그 점프는 누구도 놀래키지 않는다.
    static func startles(jumper: TilePoint, victim: TilePoint, isGrass: (TilePoint) -> Bool) -> Bool {
        isGrass(jumper) && !isGrass(victim) && PlazaPathfinder.isAdjacent(jumper, victim)
    }

    /// `me`가 지금 뛰면 놀랄 팀원(ID 순).
    static func targets(me: TilePoint, members: [String: TilePoint], isGrass: (TilePoint) -> Bool) -> [String] {
        members.filter { startles(jumper: me, victim: $0.value, isGrass: isGrass) }.keys.sorted()
    }
}
