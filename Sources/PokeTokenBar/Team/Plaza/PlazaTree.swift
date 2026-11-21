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
        let size = CGSize(width: CGFloat(PlazaResources.treeCrop.width) * scale, height: CGFloat(PlazaResources.treeCrop.height) * scale)
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

    // 그림 (rulings 3–5)

    static let canopyRows = 0..<38                                  // 자른 그림의 줄: 잎과 그 테두리
    static let groundRows = 38..<48                                 // 땅 치마, 줄기, 잎의 마지막 그늘
    static let bandRows: [Range<Int>] = [0..<10, 10..<20, 20..<30, 30..<48]   // 휘는 띠, 위에서부터. 마지막은 줄기라 움직이지 않는다
    static let bandWeights: [CGFloat] = [1, 2.0 / 3, 1.0 / 3, 0]

    /// 잎 색. 겨울만 밝은 두 초록을 눈색으로(광장이 이 팩 색에 이미 쓰는 표). 어두운 초록과 테두리는 그대로.
    static func canopyColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        season == .winter ? [0x99E550: 0xF6FAFF, 0x6ABE30: 0xC6DAF0] : [:]
    }

    /// 땅 치마 색: 풀숲의 계절 표에, 잎 표의 0x524B24 항목이 있으면 그것을 더한다(그 색의 줄 38 픽셀은 잎의 것이다).
    static func groundColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        PlazaSeasonSheet.tallGrassColors(season).merging(canopyColors(season).filter { $0.key == 0x524B24 }) { $1 }
    }

    /// 계절의 소나무. 번들 풀숲 시트(208×144)가 아니면 nil. 자른 그림에 줄 띠마다 정확한 색 바꿈만 한다.
    static func image(_ tallGrassSheet: PlazaImage, season: PlazaSeason) -> PlazaImage? {
        guard tallGrassSheet.width == 208, tallGrassSheet.height == 144,
              let crop = tallGrassSheet.cropping(to: PlazaResources.treeCrop) else { return nil }
        return PlazaSnowSheet.recolored(crop, rows: [(canopyColors(season), canopyRows), (groundColors(season), groundRows)])
    }

    /// 휘는 띠 네 장(위에서부터). 이어 붙이면 그림 그대로다.
    static func bands(_ image: PlazaImage) -> [PlazaImage] {
        bandRows.compactMap { image.cropping(to: PlazaPixelRect(x: 0, y: $0.lowerBound, width: image.width, height: $0.count)) }
    }

    /// 나무에서 터지는 것: 겨울은 눈, 그 밖에는 초록 잎(봄·가을에도 소나무는 푸르다).
    static func burstKind(_ season: PlazaSeason) -> PlazaWeather.Kind {
        season == .winter ? .snow : .greenLeaves
    }

    /// 작은 지도 그림: 지도 위에 나무를 2배로 얹는다(`Canvas.plot` 의 선분 공식, 미리 곱한 색). `rect` 밖은 그대로다.
    static func baked(_ mapImage: PlazaImage, tree: PlazaImage, at rect: CGRect) -> PlazaImage {
        let w = mapImage.width, h = mapImage.height
        var data = mapImage.pixels.bytes
        let t = tree.pixels.bytes
        let (x0, y0, k) = (Int(rect.minX), Int(rect.minY), Int(scale))
        for ty in 0..<tree.height {
            for tx in 0..<tree.width {
                let si = (ty * tree.width + tx) * 4
                let a = Int(t[si + 3])
                for dy in 0..<k {
                    for dx in 0..<k {
                        let ox = x0 + tx * k + dx, oy = y0 + ty * k + dy
                        guard ox >= 0, oy >= 0, ox < w, oy < h else { continue }
                        let di = (oy * w + ox) * 4
                        for c in 0..<3 { data[di + c] = UInt8(min(255, Int(t[si + c]) + Int(data[di + c]) * (255 - a) / 255)) }
                        data[di + 3] = 255
                    }
                }
            }
        }
        var bitmap = PlazaBitmap(width: w, height: h)
        bitmap.bytes = data
        return PlazaImage(bitmap: bitmap)
    }
}
