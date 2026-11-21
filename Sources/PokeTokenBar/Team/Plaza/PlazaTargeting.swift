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

    /// 1. 바라보는 칸을 덮는 몸 2. 내 발 칸을 덮는 몸. 한 칸을 여럿이 덮으면 ID가 작은 쪽.
    static func memberAhead(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String? {
        for tile in [facingTile(from: me.foot, facing: facing), me.foot] {
            if let id = covering(tile, members: members) { return id }
        }
        return nil
    }

    /// 3. 옆 칸(`otherSides` 순서)을 덮는 몸 4. 그 밖에 내 몸에 닿는 몸: 발 맨해튼 거리가 가까운 쪽, 같으면 ID가 작은 쪽.
    static func memberAround(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String? {
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

    private static func covering(_ tile: TilePoint, members: [String: PlazaBody]) -> String? {
        members.filter { $0.value.covers(tile) }.keys.min()
    }

    /// 돌아서기(내가 팀원 쪽으로)와 미는 방향(민 쪽에서 맞는 쪽으로)이 같이 쓰는 규칙: 발이 바로 옆이면 그 방향,
    /// 아니면 차이가 큰 축, 같으면 `facing`. 등급 1이면 예전 옆 칸 규칙과 그 대체 방향과 같다.
    static func turn(from: TilePoint, to: TilePoint, facing: PlazaDirection) -> PlazaDirection {
        let dx = to.x - from.x, dy = to.y - from.y
        if abs(dx) + abs(dy) == 1 { return PlazaPathfinder.direction(from: from, to: to) }
        if abs(dx) == abs(dy) { return facing }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    static func member(on tile: TilePoint, members: [String: TilePoint]) -> String? {
        members.filter { $0.value == tile }.keys.min()
    }
}
