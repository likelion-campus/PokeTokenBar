import Foundation

/// 큰 나무(PR 5). 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다(`PlazaHotSpring`·`PlazaPond`처럼).
/// 나무의 조정용 상수는 모두 여기에 있다. 자리는 지도의 'B' 칸이다(상수로 두지 않는다).
enum PlazaTree {
    // 하루 규칙 (명세 9.3, 13)
    static let hitsPerDrop = 3                // 조정용 상수 (명세 13, 위임)
    static let dropsPerDay = 1                // 조정용 상수 (명세 13, 위임)
    static let dropItem: ItemKind = .mint     // 조정용 상수 (명세 13, 위임, R3)
    static let maxFallingLeaves = 12          // 조정용 상수 (명세 13, 설계자 판단·미확인)

    // 그림 크기: 번들 시트에서 자른 소나무 42×48 을 2배로 그린다(지도의 밀도).
    static let scale: CGFloat = 2
    static let cropWidth = 42
    static let cropHeight = 48

    // 자리: 지도의 'B' (ruling 2)

    /// 지도의 모든 'B' 칸. 나무 없는 지도는 [].
    static func tiles(in map: PlazaMap) -> Set<TilePoint> {
        var out = Set<TilePoint>()
        for y in 0..<map.height {
            for x in 0..<map.width where map.isBigTree(TilePoint(x: x, y: y)) { out.insert(TilePoint(x: x, y: y)) }
        }
        return out
    }

    /// 그림이 서는 월드 픽셀 사각형(y 아래로). 'B' 줄의 가운데 열에 가운데를 맞추고 맨 아래 줄의 아래 끝에 바닥을 맞춘다.
    static func artRect(in map: PlazaMap) -> CGRect? {
        let run = tiles(in: map)
        guard let minX = run.map(\.x).min(), let maxX = run.map(\.x).max(), let maxY = run.map(\.y).max() else { return nil }
        let tile = CGFloat(PlazaMap.tileSize)
        let size = CGSize(width: CGFloat(cropWidth) * scale, height: CGFloat(cropHeight) * scale)
        let centerX = CGFloat(minX + maxX + 1) / 2 * tile
        let bottom = CGFloat(maxY + 1) * tile
        return CGRect(x: centerX - size.width / 2, y: bottom - size.height, width: size.width, height: size.height)
    }

    /// 그림이 덮는 칸(명세 9.1의 3×3). 그 칸에 놓인 아이템은 보이지 않는다(ruling 10).
    static func coveredTiles(in map: PlazaMap) -> Set<TilePoint> {
        guard let r = artRect(in: map) else { return [] }
        let tile = CGFloat(PlazaMap.tileSize)
        var out = Set<TilePoint>()
        for y in Int((r.minY / tile).rounded(.down))..<Int((r.maxY / tile).rounded(.up)) {
            for x in Int((r.minX / tile).rounded(.down))..<Int((r.maxX / tile).rounded(.up)) { out.insert(TilePoint(x: x, y: y)) }
        }
        return out
    }

    /// 그림의 깊이: 모닥불과 같은 식(맨 아래 줄 아래 끝 기준). 그 줄 이하의 캐릭터는 뒤, 아래 줄은 앞.
    static func z(in map: PlazaMap) -> CGFloat? {
        guard let r = artRect(in: map) else { return nil }
        return 1 + r.maxY / map.pixelSize.height
    }
}
