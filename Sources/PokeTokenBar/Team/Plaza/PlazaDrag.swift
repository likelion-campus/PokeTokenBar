import Foundation

/// 끌어당기기 규칙(명세 7). SpriteKit과 무관한 순수 규칙이다.
/// 끄는 쪽 메뉴(`dragStep`)와 받는 쪽 검사(`showDrag`)가 모두 `direction`을 불러 같은 기하를 쓴다.
enum PlazaDrag {
    /// `from`에서 `to`로 가는 방향. 같은 x 또는 같은 y에 있고 같은 칸이 아닐 때만, 아니면 nil.
    static func line(from: TilePoint, to: TilePoint) -> PlazaDirection? {
        if from == to { return nil }
        if from.y == to.y { return to.x > from.x ? .right : .left }
        if from.x == to.x { return to.y > from.y ? .down : .up }
        return nil
    }

    /// b: 끌려가는 쪽에서 끄는 쪽으로 가는 방향. 두 몸이 닿고 발이 같은 줄에 있을 때만, 아니면 nil.
    static func direction(puller: PlazaBody, target: PlazaBody) -> PlazaDirection? {
        puller.touches(target) ? line(from: target.foot, to: puller.foot) : nil
    }

    /// k: `direction`으로 1...`TeamEmote.pushTiles(stage)`칸, 열려 있지 않은 첫 칸 앞까지 물러날 수 있는 칸 수.
    static func stepBack(from: TilePoint, direction: PlazaDirection, stage: Int, isOpen: (TilePoint) -> Bool) -> Int {
        var tile = from
        var k = 0
        for _ in 0..<TeamEmote.pushTiles(stage) {
            let next = PlazaWalker.offset(tile, direction)
            guard isOpen(next) else { break }
            tile = next
            k += 1
        }
        return k
    }

    /// n: 끌려가는 `victim`이 `puller` 쪽으로 미끄러질 칸 수. 끄는 쪽이 `pushTiles`(1...3)칸 물러난 새 자리의 몸과 내 몸이
    /// 처음 맞닿는(겹치지 않는) 칸까지다. 몸은 `PlazaBody`다: 발이 같은 줄이라 옆으로 늘 겹치므로, 가는 줄 방향의 몸 사이 간격이
    /// 1이 될 때까지가 n이다. 몸이 둘 다 1등급이면 예전 발 거리 규칙((발 거리 − 1) + `pushTiles`)과 같다.
    /// 열려 있지 않은 첫 칸 앞에서 멈추고, 같은 줄이 아니면 0이다. 보내는 쪽은 k만 정하고, 이 끝은 받는 쪽이 같은 등급으로 따진다.
    static func slide(victim: PlazaBody, puller: PlazaBody, pushTiles: Int, isOpen: (TilePoint) -> Bool) -> Int {
        guard let d = line(from: victim.foot, to: puller.foot) else { return 0 }
        var moved = puller
        for _ in 0..<TeamEmote.pushTiles(pushTiles) { moved.foot = PlazaWalker.offset(moved.foot, d) }
        // d 쪽으로 본 두 몸의 [아래, 위] 범위. 끄는 쪽이 앞이니 끄는 쪽의 가까운 끝 − 내 먼 끝이 간격이다(1이면 맞닿음).
        func range(_ b: PlazaBody) -> (lo: Int, hi: Int) {
            let s = PlazaBodySize.span(b.size)
            switch d {
            case .left, .right: return (b.foot.x - s.w, b.foot.x + s.w)
            case .up, .down: return (b.foot.y - s.h, b.foot.y)
            }
        }
        let me = range(victim), her = range(moved)
        let gap = (d == .right || d == .down) ? her.lo - me.hi : me.lo - her.hi
        var tile = victim.foot
        var n = 0
        for _ in 0..<max(gap - 1, 0) {
            let next = PlazaWalker.offset(tile, d)
            guard isOpen(next) else { break }
            tile = next
            n += 1
        }
        return n
    }
}

extension PlazaDirection {
    var opposite: PlazaDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

/// 나를 움직이는 이모트(몸통박치기·끌어당기기·물귀신·눈덩이)를 보낸 사람마다 1초에 한 번만 받는 기록.
struct PlazaShove: Sendable {
    // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let receiveCooldown: TimeInterval = 1
    private(set) var lastMoved: [String: Date] = [:]

    /// 1초 이상 지났거나(`now − t >= receiveCooldown`) 시계가 되감긴(`now < t`) 기록을 버린다.
    /// `sender`의 기록이 남아 있으면 거절하고 아무것도 적지 않는다(거절이 1초를 다시 시작하지 않는다). 없으면 `now`를 적고 받는다.
    mutating func admit(_ sender: String, now: Date) -> Bool {
        guard allows(sender, now: now) else { return false }
        record(sender, now: now)
        return true
    }

    /// `sender`의 1초가 아직 안 끝났는지만 본다(아무것도 적지 않는다). 받은 값을 적용하기 전에 묻는다.
    func allows(_ sender: String, now: Date) -> Bool {
        guard let t = lastMoved[sender] else { return true }
        let dt = now.timeIntervalSince(t)
        return !(dt >= 0 && dt < Self.receiveCooldown)
    }

    /// 내가 실제로 움직였을 때 `sender`의 1초를 시작한다. 지난 기록(1초 이상, 또는 시계가 되감긴 것)도 이때 버린다.
    mutating func record(_ sender: String, now: Date) {
        lastMoved = lastMoved.filter { _, t in
            let dt = now.timeIntervalSince(t)
            return dt >= 0 && dt < Self.receiveCooldown
        }
        lastMoved[sender] = now
    }
}
