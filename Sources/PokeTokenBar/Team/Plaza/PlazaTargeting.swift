/// 내가 바라보는 팀원을 찾는 규칙. SpriteKit과 무관한 순수 함수다.
enum PlazaTargeting {
    static func facingTile(from: TilePoint, facing: PlazaDirection) -> TilePoint {
        PlazaWalker.offset(from, facing)
    }

    /// 바라보는 칸의 팀원을 먼저, 없으면 같은 칸의 팀원. 여럿이면 ID가 작은 쪽.
    static func member(from: TilePoint, facing: PlazaDirection, members: [String: TilePoint]) -> String? {
        let ahead = facingTile(from: from, facing: facing)
        for tile in [ahead, from] {
            if let id = members.filter({ $0.value == tile }).keys.min() { return id }
        }
        return nil
    }
}
