import Foundation

/// 오른쪽 연못: 온천. 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다(`PlazaPond`·`PlazaDrag`처럼).
/// 온천의 조정용 상수는 모두 여기에 있다.
enum PlazaHotSpring {
    static let flushAfter: TimeInterval = 180            // 조정용 상수 (명세 13, 위임)
    static let flushFade: TimeInterval = 60              // 조정용 상수 (명세 13, 위임)
    static let flushRise: TimeInterval = 2               // 명세 8.4 구현자 재량
    static let flushBlend: CGFloat = 0.45                // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let flushColor = PlazaColor(hex: 0xE0503C)    // 조정용 상수 (명세 13, 설계자 판단·미확인)
    /// 물색 네 쌍: 명세 8.2의 세 쌍과 코드로 그리는 물보라·고리의 `#2996DB`(계획 ruling 3, 앞 두 색의 중간값).
    static let waterColors: PlazaSnowSheet.Colors = [0x1E7CB8: 0x4FA8A0, 0x165C88: 0x2F7C78, 0x5AAEE4: 0x9AD8CC, 0x2996DB: 0x74C0B6]
    /// 온천에 잠긴 아랫부분의 물빛(`PlazaPondArt.waterColor`의 짝).
    static let waterColor = PlazaColor(hex: 0x4FA8A0)

    /// 온천 둘레의 돌. 시트 칸 (col, row) 에서 cols×rows 칸을 지도 칸 `at` 에 그대로 복사한다.
    struct Prop: Equatable { let col: Int, row: Int, cols: Int, rows: Int; let at: TilePoint; let inWater: Bool }

    /// 시트 plaza-tiles.png 의 칸을 그대로 쓴다(코드로 그린 모양 없음).
    /// P1 (12,10) 물 속 납작한 돌, P2 (14,10) 조약돌 둘, P3 (11,7)-(12,8) 바위 한 쌍, P4 (37,5)-(38,6) 둑의 회색 바위,
    /// P5 (7,5) 풀이 난 돌, P6 (10,5) 풀이 난 조약돌.
    static let props: [Prop] = [
        Prop(col: 12, row: 10, cols: 1, rows: 1, at: TilePoint(x: 32, y: 16), inWater: true),
        Prop(col: 14, row: 10, cols: 1, rows: 1, at: TilePoint(x: 36, y: 14), inWater: true),
        Prop(col: 11, row: 7, cols: 2, rows: 2, at: TilePoint(x: 37, y: 19), inWater: true),
        Prop(col: 37, row: 5, cols: 2, rows: 2, at: TilePoint(x: 39, y: 16), inWater: false),
        Prop(col: 7, row: 5, cols: 1, rows: 1, at: TilePoint(x: 31, y: 21), inWater: false),
        Prop(col: 10, row: 5, cols: 1, rows: 1, at: TilePoint(x: 39, y: 13), inWater: false),
    ]
    /// 물 속 바위 칸. 거품 테두리와 그림자까지 있어 물색을 같이 바꾼다.
    static let waterPropCells: [(col: Int, row: Int)] = [(12, 10), (14, 10), (11, 7), (12, 7), (11, 8), (12, 8)]
    /// 둑의 풀 돌 칸. 가을·겨울에는 땅과 같은 색으로 바랜다(`PlazaSeasonSheet`).
    static let bankStoneCells: [(col: Int, row: Int)] = [(7, 5), (10, 5)]
    static let autumnStoneColors: PlazaSnowSheet.Colors = [0x2ECA35: 0x8E9A44, 0x328E41: 0x6E7634]
    static let winterStoneColors: PlazaSnowSheet.Colors = [0x2ECA35: 0xE8F0FA, 0x328E41: 0xB2C7E0]

    /// 온천 칸을 행 우선 순서로. 온천 없는 지도는 [].
    static func tiles(in map: PlazaMap) -> [TilePoint] {
        var out: [TilePoint] = []
        for y in 0..<map.height {
            for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .hotSpring { out.append(TilePoint(x: x, y: y)) }
        }
        return out
    }

    /// 온천 칸이거나 그 여덟 이웃인가(물과 물가를 온천 시트로 그리는 칸).
    static func usesSpringWater(_ p: TilePoint, in map: PlazaMap) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where map.isHotSpring(TilePoint(x: p.x + dx, y: p.y + dy)) { return true }
        }
        return false
    }

    /// 온천이 있는 지도에서만 돌을 모두 돌려준다. 물 속 돌이 온천이 아닌 칸을 덮거나 둑의 돌이 걸을 수 없는 칸을 덮으면 [](전부 아니면 전무).
    static func props(in map: PlazaMap) -> [Prop] {
        guard !tiles(in: map).isEmpty else { return [] }
        for prop in props {
            for dy in 0..<prop.rows {
                for dx in 0..<prop.cols {
                    let t = TilePoint(x: prop.at.x + dx, y: prop.at.y + dy)
                    if prop.inWater ? !map.isHotSpring(t) : !map.isWalkable(t) { return [] }
                }
            }
        }
        return props
    }

    /// 온천 그림이 닿는 칸 상자: 온천과 그 둘레 한 칸, 거기에 돌을 합친 것. 온천 없는 지도는 nil.
    static func artBounds(in map: PlazaMap) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let spring = tiles(in: map)
        guard !spring.isEmpty else { return nil }
        var b = (minX: spring.map(\.x).min()! - 1, minY: spring.map(\.y).min()! - 1,
                 maxX: spring.map(\.x).max()! + 1, maxY: spring.map(\.y).max()! + 1)
        for prop in props(in: map) {
            b = (min(b.minX, prop.at.x), min(b.minY, prop.at.y),
                 max(b.maxX, prop.at.x + prop.cols - 1), max(b.maxY, prop.at.y + prop.rows - 1))
        }
        return b
    }

    /// 계절 시트의 물 칸·물가 칸·물 속 바위 칸에서 물색을 온천색으로 바꾼 사본.
    /// 바꾼 뒤에 그려야 바위의 반투명 그림자가 청록 물 위에 섞인다(계획 ruling 2).
    static func sheet(_ seasonSheet: PlazaImage) -> PlazaImage {
        let cells = [PlazaTileArt.waterCell] + PlazaPond.shoreCells + waterPropCells
        return PlazaSnowSheet.recolored(seasonSheet, pieces: [(waterColors, cells)])
    }

    /// 물보라 방울·고리·헤엄 고리의 모든 불투명 픽셀에 물색 네 쌍을 적용한 사본(모양은 그대로).
    static func recolored(_ art: PlazaImage) -> PlazaImage {
        let cells = (0..<((art.height + 15) / 16)).flatMap { row in (0..<((art.width + 15) / 16)).map { (col: $0, row: row) } }
        return PlazaSnowSheet.recolored(art, pieces: [(waterColors, cells)])
    }

    /// 사진 전용: premultiplied rgb 에 `1 − f + f·c` 를 곱한다(Windows 렌더러의 colorBlendFactor 식). 알파는 그대로다.
    static func tinted(_ image: PlazaImage, blend f: CGFloat, color: PlazaColor = flushColor) -> PlazaImage {
        var bitmap = PlazaBitmap(width: image.width, height: image.height)
        let source = image.pixels.bytes
        let k = [1 - f + f * CGFloat(color.red), 1 - f + f * CGFloat(color.green), 1 - f + f * CGFloat(color.blue)]
        var out = source
        for i in stride(from: 0, to: source.count, by: 4) {
            for c in 0..<3 { out[i + c] = UInt8(min(255, (CGFloat(source[i + c]) * k[c]).rounded())) }
        }
        bitmap.bytes = out
        return PlazaImage(bitmap: bitmap)
    }
}

/// 온천의 김. 조정용 상수는 여기 있다.
enum PlazaSteam {
    static let maxWisps = 8                       // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let life: TimeInterval = 3             // 명세 8.3
    static let rise: CGFloat = 24                 // 수명 동안 오르는 월드 픽셀 (명세 8.3)
    static let peakAlpha: CGFloat = 0.6           // 명세 8.3
    static let peakAt: TimeInterval = 0.75        // 구현자 재량: 투명도가 0 에서 0.6 까지 여기서 오르고 `life` 에서 0
    static let spawnInterval: TimeInterval = 0.5  // life / spawnInterval = 동시에 여섯 개쯤
    static let frameCount = 6                     // smoke_5.png 의 앞 여섯 32×32 칸. 칸 = min(5, ⌊나이 / life × 6⌋), 0.5초씩
    static let scale: CGFloat = 2                 // 시트 픽셀 하나가 월드 픽셀 둘 (3.2 의 타일 밀도): 한 칸은 64×64
    static let z: CGFloat = 2.9                   // 캐릭터(1...2)·물보라(2.5) 위, 날씨(3)·낮밤(5) 아래
    static let cullMargin = CGFloat(PlazaMap.tileSize)   // 명세 8.3 "여유 한 칸"
}

/// 김 한 줄기. 태어난 자리(월드 픽셀, y 아래로)와 나이.
struct PlazaSteamWisp: Equatable {
    let x: CGFloat, y: CGFloat
    var age: TimeInterval
}

/// 김의 움직임. 노드 없이 값만 다뤄, 같은 씨앗과 같은 `dt` 열이면 같은 결과다.
struct PlazaSteamField {
    private(set) var wisps: [PlazaSteamWisp] = []
    private var rng: PlazaSplitMix64
    private let tiles: [TilePoint]
    private var sinceSpawn: TimeInterval = PlazaSteam.spawnInterval

    /// 씨앗은 고정이라(`fnv1a("plaza-steam")`) 두 시스템의 렌더가 같다. 처음에 `life` 만큼 0.05초씩 미리 돌려 김이 이미 올라 있다.
    init(tiles: [TilePoint], seed: UInt64 = UInt64(PlazaNameColor.fnv1a("plaza-steam"))) {
        self.tiles = tiles
        rng = PlazaSplitMix64(seed: seed)
        for _ in 0..<Int((PlazaSteam.life / 0.05).rounded()) { advance(by: 0.05) }
    }

    /// 나이를 먹이고 수명이 다한 것을 버리고, `spawnInterval` 마다 한 줄기를 온천 칸 위에 새로 띄운다(`maxWisps` 까지).
    mutating func advance(by dt: TimeInterval) {
        for i in wisps.indices { wisps[i].age += dt }
        wisps.removeAll { $0.age >= PlazaSteam.life }
        sinceSpawn += dt
        while sinceSpawn >= PlazaSteam.spawnInterval, wisps.count < PlazaSteam.maxWisps, !tiles.isEmpty {
            sinceSpawn -= PlazaSteam.spawnInterval
            let t = tiles[Int(rng.next() % UInt64(tiles.count))]
            let size = CGFloat(PlazaMap.tileSize)
            wisps.append(PlazaSteamWisp(x: (CGFloat(t.x) + CGFloat(rng.unit())) * size, y: (CGFloat(t.y) + CGFloat(rng.unit())) * size, age: 0))
        }
        sinceSpawn = min(sinceSpawn, PlazaSteam.spawnInterval)
    }

    /// 시트의 칸 번호(0..<6).
    static func frame(age: TimeInterval) -> Int {
        min(PlazaSteam.frameCount - 1, max(0, Int(age * Double(PlazaSteam.frameCount) / PlazaSteam.life)))
    }

    /// 0 에서 `peakAt` 까지 `peakAlpha` 로 오르고 `life` 까지 0 으로 내린다.
    static func alpha(age: TimeInterval) -> CGFloat {
        guard age > 0, age < PlazaSteam.life else { return 0 }
        let k = age < PlazaSteam.peakAt ? age / PlazaSteam.peakAt : (PlazaSteam.life - age) / (PlazaSteam.life - PlazaSteam.peakAt)
        return PlazaSteam.peakAlpha * CGFloat(k)
    }

    /// 수명 동안 `rise` 만큼 곧게 오른다(월드 픽셀).
    static func lift(age: TimeInterval) -> CGFloat { PlazaSteam.rise * CGFloat(age / PlazaSteam.life) }
}
