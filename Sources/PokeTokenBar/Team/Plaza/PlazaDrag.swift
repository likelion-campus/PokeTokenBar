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

    /// n: 끌려가는 쪽이 `d`(끌려가는 쪽에서 끄는 쪽으로 가는 방향) 쪽으로 미끄러질 칸 수. 끄는 쪽이 물러난 만큼(`pushTiles`, 1...3) 같이
    /// 미끄러져 둘이 서 있던 배치를 그대로 지킨다(몸 크기와 무관하다: 0칸이 되거나 새로 겹치지 않는다). 발이 한 칸에 겹쳐 있으면
    /// 명세의 (d − 1) + k에서 d = 0이라 k − 1칸이다. 열려 있지 않은 첫 칸 앞에서 멈춘다. 끄는 쪽이 비운 칸은 막지 않는다(받는 쪽은 끄는 쪽의 칸을
    /// 빼고 `isOpen`을 세운다). 보내는 쪽(메뉴 줄)과 받는 쪽이 같은 값으로 부른다.
    static func slide(victim: TilePoint, puller: TilePoint, direction d: PlazaDirection, pushTiles: Int, isOpen: (TilePoint) -> Bool) -> Int {
        let want = TeamEmote.pushTiles(pushTiles) - (victim == puller ? 1 : 0)
        var tile = victim
        var n = 0
        for _ in 0..<max(want, 0) {
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
