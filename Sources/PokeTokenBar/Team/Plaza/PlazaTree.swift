import Foundation

/// 큰 나무(PR 5). 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다(`PlazaHotSpring`·`PlazaPond`처럼).
/// 나무의 조정용 상수는 모두 여기에 있다. 자리는 지도의 'B' 칸이다(상수로 두지 않는다).
enum PlazaTree {
    // 하루 규칙 (명세 9.3, 13)
    static let hitsPerDrop = 3                // 조정용 상수 (명세 13, 위임)
    static let dropsPerDay = 1                // 조정용 상수 (명세 13, 위임)
    static let dropItem: ItemKind = .mint     // 조정용 상수 (명세 13, 위임, R3)
    static let maxFallingLeaves = 12          // 조정용 상수 (명세 13, 설계자 판단·미확인)

    // 그림 크기: 번들 시트에서 자른 소나무 42×48 을 3배로 그린다(결정 (c). 지도는 2배).
    static let scale: CGFloat = 3

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

    /// 잎이 아이템 자리를 덮는 칸: 'B' 줄과 그 뒤 한 줄(줄의 열 위). 그림 상자 전체가 아니다(ruling 10).
    static func coveredTiles(in map: PlazaMap) -> Set<TilePoint> {
        let run = tiles(in: map)
        guard let minX = run.map(\.x).min(), let maxX = run.map(\.x).max(),
              let minY = run.map(\.y).min(), let maxY = run.map(\.y).max() else { return [] }
        var out = Set<TilePoint>()
        for y in (minY - 1)...maxY { for x in minX...maxX { out.insert(TilePoint(x: x, y: y)) } }
        return out
    }

    /// 그림의 깊이: 모닥불과 같은 식(맨 아래 줄 아래 끝 기준). 그 줄 이하의 캐릭터는 뒤, 아래 줄은 앞.
    static func z(in map: PlazaMap) -> CGFloat? {
        guard let r = artRect(in: map) else { return nil }
        return 1 + r.maxY / map.pixelSize.height
    }

    // 그림 (rulings 3–5, 15)

    static let canopyRows = 0..<38                                  // 자른 그림의 줄: 잎과 그 테두리
    static let groundRows = 38..<48                                 // 땅 치마, 줄기, 잎의 마지막 그늘
    static let bandRows: [Range<Int>] = [0..<10, 10..<20, 20..<30, 30..<48]   // 휘는 띠, 위에서부터. 마지막은 줄기라 움직이지 않는다
    static let bandWeights: [CGFloat] = [1, 2.0 / 3, 1.0 / 3, 0]

    /// 시트의 잎 네 색, 밝은 쪽부터(결정 (d)의 표가 바꾸는 것). 테두리 `#222034` 와 줄기 색은 건드리지 않는다.
    static let leafColors: [UInt32] = [0x99E550, 0x6ABE30, 0x4B692F, 0x524B24]
    /// 계절의 잎 네 색 (결정 (d), 조정용 표). 여름은 시트 그대로라 줄이 없다.
    static let seasonLeaves: [PlazaSeason: [UInt32]] = [
        .spring: [0xC4F27A, 0x8EDC52, 0x4F8E3C, 0x4A5A2A],
        .autumn: [0xF2C840, 0xE09A2A, 0xA8641A, 0x5E3E16],
        .winter: [0xF4F8FC, 0xCFE0EE, 0x6F93AC, 0x3F4E5E]]

    /// 잎 색 바꿈: `leafColors` 를 `seasonLeaves[s]` 로. 여름은 비어 있다.
    static func canopyColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        guard let to = seasonLeaves[season] else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(leafColors, to))
    }

    /// 땅 치마의 두 색: 밝은 원반과 줄기 쪽 어두운 고리(그림에 테두리는 없다).
    static let skirt: (disc: UInt32, ring: UInt32) = (0x6ABE30, 0x4B692F)
    /// 풀 칸의 그늘색과 가장 어두운 색. 치마가 여름·봄에 입는 색이고, 가을·겨울은 `PlazaSeasonSheet.groundColors` 가 그 계절 색으로 옮긴다 (ruling 15).
    static let skirtGround: (disc: UInt32, ring: UInt32) = (0x328E41, 0x315740)

    /// 땅 치마 색 바꿈: 원반과 고리가 그 계절 땅의 그늘·가장 어두운 색으로. 잎 표의 `#524B24` 항목이 있으면 더한다(줄 38의 그 색은 잎의 것이다).
    static func groundColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        let ground = PlazaSeasonSheet.groundColors(season)
        var colors: PlazaSnowSheet.Colors = [skirt.disc: ground[skirtGround.disc] ?? skirtGround.disc,
                                             skirt.ring: ground[skirtGround.ring] ?? skirtGround.ring]
        if let shade = canopyColors(season)[0x524B24] { colors[0x524B24] = shade }
        return colors
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

    /// 나무에서 터지는 잎: 그 계절의 나무 모습에 맞는, 광장이 이미 가진 입자 격자(ruling 4). `grids` 는 `PlazaWeatherArt.grids(kind)` 의 번호다.
    /// 봄에도 초록(분홍 꽃잎은 소나무에서 나오지 않는다), 가을은 주황과 노랑뿐(낙엽송에 붉은 잎은 없다).
    static func burstArt(_ season: PlazaSeason) -> (kind: PlazaWeather.Kind, grids: [Int]) {
        switch season {
        case .summer, .spring: (.greenLeaves, [0, 1, 2, 3])
        case .autumn: (.leaves, [0, 1, 4, 5])
        case .winter: (.snow, [0, 1, 2])
        }
    }

    /// 잎이 터져 나올 자리: 자른 그림 4..<34 줄의 불투명 픽셀 가운데(월드 픽셀, y 아래로). 알파는 모든 계절이 같다.
    static func canopySpawnPoints(_ image: PlazaImage, artRect: CGRect) -> [CGPoint] {
        let bytes = image.pixels.bytes
        var out: [CGPoint] = []
        for row in 4..<34 {
            for col in 0..<image.width where bytes[(row * image.width + col) * 4 + 3] == 255 {
                out.append(CGPoint(x: artRect.minX + (CGFloat(col) + 0.5) * scale, y: artRect.minY + (CGFloat(row) + 0.5) * scale))
            }
        }
        return out
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
