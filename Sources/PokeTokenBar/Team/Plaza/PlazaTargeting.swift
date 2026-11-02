/// 내가 바라보는 팀원을 찾는 규칙. SpriteKit과 무관한 순수 함수다.
enum PlazaTargeting {
    static func facingTile(from: TilePoint, facing: PlazaDirection) -> TilePoint {
        PlazaWalker.offset(from, facing)
    }

    /// 바라보는 쪽을 뺀 나머지 세 방향. 위, 아래, 왼쪽, 오른쪽 순서다.
    static func otherSides(_ facing: PlazaDirection) -> [PlazaDirection] {
        [PlazaDirection.up, .down, .left, .right].filter { $0 != facing }
    }

    /// 바라보는 칸의 팀원을 먼저, 없으면 같은 칸, 그다음 바로 옆 칸(`otherSides` 순서)의 팀원. 한 칸에 여럿이면 ID가 작은 쪽.
    static func member(from: TilePoint, facing: PlazaDirection, members: [String: TilePoint]) -> String? {
        let tiles = [facingTile(from: from, facing: facing), from] + otherSides(facing).map { PlazaWalker.offset(from, $0) }
        for tile in tiles {
            if let id = member(on: tile, members: members) { return id }
        }
        return nil
    }

    static func member(on tile: TilePoint, members: [String: TilePoint]) -> String? {
        members.filter { $0.value == tile }.keys.min()
    }
}
