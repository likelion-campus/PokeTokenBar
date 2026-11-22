/// 내가 바라보는 팀원을 찾는 규칙. SpriteKit과 무관한 순수 함수다.
enum PlazaTargeting {
    static func facingTile(from: TilePoint, facing: PlazaDirection) -> TilePoint {
        PlazaWalker.offset(from, facing)
    }

    /// 바라보는 쪽을 뺀 나머지 세 방향. 위, 아래, 왼쪽, 오른쪽 순서다.
    static func otherSides(_ facing: PlazaDirection) -> [PlazaDirection] {
        [PlazaDirection.up, .down, .left, .right].filter { $0 != facing }
    }

    /// 팀원을 찾는 하나의 규칙(스페이스·X·C·안내 줄·이모트 키): `memberAhead` 다음 `memberAround`.
    /// 몸이 전부 등급 1이면 예전 한 칸 규칙과 똑같다.
    static func member(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String? {
        memberAhead(me: me, facing: facing, members: members) ?? memberAround(me: me, facing: facing, members: members)
    }

    /// 1. 바라보는 칸을 덮는 몸 2. 발이 내 칸에 있는 몸. 소식판과 모닥불은 이 둘 다음에 보므로, 내 칸을 몸으로만 덮은 팀원이
    /// 옆 소식판·모닥불보다 먼저 잡히지 않는다(몸이 내 칸을 덮는 경우는 `memberAround` 의 첫 단계).
    static func memberAhead(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String? {
        if let id = covering(facingTile(from: me.foot, facing: facing), members: members) { return id }
        return members.filter { $0.value.foot == me.foot }.keys.min()
    }

    /// 3. 내 칸을 덮는 몸 4. 옆 칸(`otherSides` 순서)을 덮는 몸 5. 그 밖에 내 몸에 닿는 몸: 발 맨해튼 거리가 가까운 쪽, 같으면 ID가 작은 쪽.
    static func memberAround(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String? {
        if let id = covering(me.foot, members: members) { return id }
        for d in otherSides(facing) {
            if let id = covering(PlazaWalker.offset(me.foot, d), members: members) { return id }
        }
        return members.filter { me.touches($0.value) }
            .min { a, b in
                let da = abs(a.value.foot.x - me.foot.x) + abs(a.value.foot.y - me.foot.y)
                let db = abs(b.value.foot.x - me.foot.x) + abs(b.value.foot.y - me.foot.y)
                return da != db ? da < db : a.key < b.key
            }?.key
    }

    /// 한 칸을 덮는 몸이 여럿이면 그 칸에 발이 가장 가까운 쪽(앞에 선 작은 팀원이 뒤의 큰 팀원에 가려지지 않게), 같으면 ID가 작은 쪽.
    /// 몸이 전부 등급 1이면 덮는 몸은 발이 그 칸에 있는 몸뿐이라 예전처럼 ID 순이다.
    static func covering(_ tile: TilePoint, members: [String: PlazaBody]) -> String? {
        members.filter { $0.value.covers(tile) }.min { a, b in
            let da = abs(a.value.foot.x - tile.x) + abs(a.value.foot.y - tile.y)
            let db = abs(b.value.foot.x - tile.x) + abs(b.value.foot.y - tile.y)
            return da != db ? da < db : a.key < b.key
        }?.key
    }

    /// 돌아서기(내가 팀원 쪽으로)와 미는 방향(민 쪽에서 맞는 쪽으로)이 같이 쓰는 규칙: 발이 바로 옆이면 그 방향,
    /// 아니면 차이가 큰 축. 대각선(차이가 같음)이면 `facing` 이 상대 쪽을 향할 때만 `facing`, 반대쪽이면 같은 축에서 상대 쪽으로 돈다
    /// (그래야 대각선으로 닿은 팀원을 밀 때 민 쪽 쪽으로 밀리지 않는다). 등급 1이면 대각선이 닿지 않아 예전 옆 칸 규칙과 그 대체 방향과 같다.
    static func turn(from: TilePoint, to: TilePoint, facing: PlazaDirection) -> PlazaDirection {
        let dx = to.x - from.x, dy = to.y - from.y
        if abs(dx) + abs(dy) == 1 { return PlazaPathfinder.direction(from: from, to: to) }
        if abs(dx) == abs(dy) {
            switch facing {
            case .right: return dx < 0 ? .left : .right
            case .left: return dx > 0 ? .right : .left
            case .down: return dy < 0 ? .up : .down
            case .up: return dy > 0 ? .down : .up
            }
        }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    static func member(on tile: TilePoint, members: [String: TilePoint]) -> String? {
        members.filter { $0.value == tile }.keys.min()
    }
}
