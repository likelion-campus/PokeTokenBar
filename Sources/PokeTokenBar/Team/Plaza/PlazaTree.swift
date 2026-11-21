import Foundation

/// 큰 나무(PR 5). 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다(`PlazaHotSpring`·`PlazaPond`처럼).
/// 나무의 조정용 상수는 모두 여기에 있다. 자리는 지도의 'B' 칸이다(상수로 두지 않는다).
enum PlazaTree {
    // 하루 규칙 (명세 9.3, 13)
    static let hitsPerDrop = 3                // 조정용 상수 (명세 13, 위임)
    static let dropsPerDay = 1                // 조정용 상수 (명세 13, 위임)
    static let dropItem: ItemKind = .mint     // 조정용 상수 (명세 13, 위임, R3)
    static let maxFallingLeaves = 20          // 조정용 상수 (명세 13, 설계자 판단·미확인). 3단계 때림이 풀 전체를 쓴다

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

    // MARK: 닿기 (명세 9.3, 6.3)

    /// 몸이 덮은 칸 가운데 나무 칸이 아닌 칸에서 `facing` 으로 한 칸 앞이 나무 칸인 것이 있다. 등급 1은 발 앞 칸이 나무 칸일 때다.
    /// 나무 칸 안에 선 몸(구버전 팀원)은 그 칸에서 판정하지 않는다.
    static func isFacing(_ body: PlazaBody, facing: PlazaDirection, tiles: Set<TilePoint>) -> Bool {
        let span = PlazaBodySize.span(body.size)
        for y in (body.foot.y - span.h)...body.foot.y {
            for x in (body.foot.x - span.w)...(body.foot.x + span.w) {
                let cell = TilePoint(x: x, y: y)
                if !tiles.contains(cell), tiles.contains(PlazaWalker.offset(cell, facing)) { return true }
            }
        }
        return false
    }

    /// 몸이 나무 칸 어느 하나와 같거나 상하좌우로 붙어 있다.
    static func touches(_ body: PlazaBody, tiles: Set<TilePoint>) -> Bool {
        tiles.contains { body.touches(PlazaBody(foot: $0, size: 1)) }
    }

    /// 때리는 쪽: 나무를 보고 있으면 그쪽, 아니면 몸이 선 쪽에서 나무로(줄의 서쪽이면 오른쪽, 동쪽이면 왼쪽, 북쪽이면 아래, 남쪽이면 위).
    static func hitDirection(_ body: PlazaBody, facing: PlazaDirection, tiles: Set<TilePoint>) -> PlazaDirection {
        if isFacing(body, facing: facing, tiles: tiles) { return facing }
        let minX = tiles.reduce(Int.max) { min($0, $1.x) }, maxX = tiles.reduce(Int.min) { max($0, $1.x) }
        let minY = tiles.reduce(Int.max) { min($0, $1.y) }
        if body.foot.x < minX { return .right }
        if body.foot.x > maxX { return .left }
        return body.foot.y < minY ? .down : .up
    }

    /// 세게 맞는 마지막 단계. 이 단계는 민트가 떨어지는 때림에만 쓴다(`level`).
    private static let dropLevel = 3

    /// 이번 때림의 세기 1...3. 떨어지는 때림은 3이고, 나머지는 하루 세 번 주기 안에서 1, 2, 2(`hitsPerDrop` 번째 전까지)로 돈다.
    static func level(hits: Int, drops: Bool) -> Int {
        drops ? dropLevel : min(2, (max(hits, 1) - 1) % hitsPerDrop + 1)
    }

    // MARK: 타격감 (결정 (b)). 표의 항목은 [level − 1]

    static let contactAt: TimeInterval = 0.1                       // 몸이 줄기에 닿는다
    static let hitStop: [TimeInterval] = [0.05, 0.067, 0.1]        // 때린 쪽과 나무가 멈춘다 (3, 4, 6 프레임)
    static let lungeDistance: [CGFloat] = [8, 9, 10]               // 월드 픽셀 (태클의 돌진은 8)
    static let recoil: [CGFloat] = [2, 3, 4]                       // 출발점 너머로 물러나는 월드 픽셀
    static let recoilDuration: TimeInterval = 0.08
    static let returnDuration: TimeInterval = 0.14
    static let bend: [CGFloat] = [6, 12, 18]                       // 맨 위 띠의 월드 픽셀 = 나무 픽셀 2, 4, 6칸(처음 3, 6, 9는 잘 안 보인다고 두 배로). 세로 때림은 bend / 144 만큼 늘인다
    static let swingPeriod: TimeInterval = 0.24
    static let swingDecay: TimeInterval = 0.18
    static let swingLength: TimeInterval = 0.8                     // 멈춤이 끝난 뒤. 그다음은 제자리
    static let leaves: [Int] = [8, 12, 20]                         // 한 번에 터지는 잎. 3단계는 풀 전체
    static let leafScale: CGFloat = 3                              // 날씨 격자의 한 칸이 3 월드 픽셀: 나무의 픽셀과 같은 크기
    static let leafPop: ClosedRange<CGFloat> = 30...60             // 월드 픽셀/초, 맞은 쪽과 위로
    static let leafGravity: CGFloat = 160                          // 월드 픽셀/초², `leafFall` 이 될 때까지
    static let leafFall: CGFloat = 75                              // 터진 뒤 잎이 떨어지는 속도(월드 픽셀/초). 날씨 입자(14~24)보다 빠르다: 잎이 눈에 띄게 쏟아지고 땅에 닿는다
    static let leafRest: TimeInterval = 0.3                        // 땅에서 흐려지며 쉰다
    static let leafLife: TimeInterval = 3.2                        // 맨 위 잎이 땅에 닿아 `leafRest` 쉬고 흐려질 만큼. 이때는 모두 없다
    static let dustSpread: [CGFloat] = [10, 12, 14]                // 월드 픽셀, 0.35초 동안(`puffDust` 처럼)
    static let dustOffsetX: CGFloat = 26                           // 줄기 가운데에서 먼지 하나까지: 3배 그림에서 뿌리의 가장자리
    static let impactScale: [CGFloat] = [1.4, 1.6, 1.9]            // 별은 0.6에서 자란다(태클은 1.4)
    static let itemDelay: TimeInterval = 0.05                      // 멈춤이 끝난 뒤
    static let itemFall: TimeInterval = 0.45
    static let itemArc: CGFloat = 12
    static let itemBounce: CGFloat = 2
    static let itemBounceDuration: TimeInterval = 0.1
    static let itemInset: CGFloat = 24                             // 아이템은 그림 가장자리에서 이만큼 안쪽에서 시작한다
    static let itemClearance: CGFloat = 48                         // 뒤에서 때리면 발 위 이만큼에서 시작한다
    static let itemStartRow = 30                                   // 자른 그림의 줄: 아이템이 시작하는 높이
    static let cameraKick: CGFloat = 2                             // 월드 픽셀. 내 3단계 때림만. 0이면 꺼진다
    static let cameraKickDuration: TimeInterval = 0.12
    static let impactGrow: TimeInterval = 0.14                     // 별이 0.6에서 `impactScale` 까지 자라는 시간(태클의 별과 같다)
    static let impactHold: TimeInterval = 0.12                     // 다 자란 뒤 흐려지기 전까지
    static let impactFade: TimeInterval = 0.22
    static let dustLife: TimeInterval = 0.35                       // 먼지가 퍼지며 흐려지는 시간(`puffDust` 처럼)
    static let dustLift: CGFloat = 3                               // 먼지가 일어 오르는 월드 픽셀(`puffDust` 의 3)
    static let cullMargin: CGFloat = 64                            // 그림 사각형에서 이만큼 안에 화면이 닿으면 그린다(낙엽이 옆으로 흘러도 잘리지 않게)

    /// 1...3 으로 맞춘 표 번호.
    private static func index(_ level: Int) -> Int { min(max(level, 1), bend.count) - 1 }

    /// 위쪽 띠의 휨(월드 픽셀, 맞은 쪽으로 +). t 는 때림이 시작한 뒤의 초. 닿기 전 0, 멈춤 동안 최대, 그다음 `bend·e^(−t′/decay)·cos(2πt′/period)`, `swingLength` 뒤 0.
    static func bendAmount(at t: TimeInterval, level: Int) -> CGFloat {
        let l = index(level)
        if t < contactAt { return 0 }
        let after = t - (contactAt + hitStop[l])
        if after < 0 { return bend[l] }
        if after >= swingLength { return 0 }
        return bend[l] * CGFloat(exp(-after / swingDecay) * cos(2 * .pi * after / swingPeriod))
    }

    /// 네 띠의 옆 이동: 나무 픽셀 단위(`scale`)로 반올림한 `bend × bandWeights`. 픽셀 하나가 두 띠에 걸치지 않는다.
    static func bandOffsets(bend: CGFloat) -> [CGFloat] {
        bandWeights.map { (bend / scale * $0).rounded() * scale }
    }

    /// 세로 때림이 뿌리 서 있는 나무를 늘이는 배율: 1 + 나무 픽셀로 반올림한 휨 / 그림 높이.
    static func stretch(bend: CGFloat) -> CGFloat {
        1 + (bend / scale).rounded() * scale / (CGFloat(PlazaResources.treeCrop.height) * scale)
    }

    private static func ease(_ u: Double) -> CGFloat { CGFloat(sin(u * .pi / 2)) }

    /// 때린 쪽이 나무 쪽으로 나아간 거리(월드 픽셀): 0에서 `lungeDistance` 까지 부드럽게 닿고, 멈춤 동안 그대로, `-recoil` 까지 물러났다가 0으로 돌아온다.
    static func lungeOffset(at t: TimeInterval, level: Int) -> CGFloat {
        let l = index(level)
        let holdEnd = contactAt + hitStop[l]
        let recoilEnd = holdEnd + recoilDuration
        if t <= 0 { return 0 }
        if t < contactAt { return lungeDistance[l] * ease(t / contactAt) }
        if t < holdEnd { return lungeDistance[l] }
        if t < recoilEnd { return lungeDistance[l] + (-recoil[l] - lungeDistance[l]) * ease((t - holdEnd) / recoilDuration) }
        if t < recoilEnd + returnDuration { return -recoil[l] * (1 - ease((t - recoilEnd) / returnDuration)) }
        return 0
    }

    /// 돌진이 시작부터 제자리로 돌아올 때까지의 시간.
    static func lungeLength(level: Int) -> TimeInterval {
        contactAt + hitStop[index(level)] + recoilDuration + returnDuration
    }

    /// 내 화면의 카메라 한 번 흔들림(월드 픽셀, 때린 방향으로 +): 3단계에서만, 닿는 순간부터 `cameraKickDuration` 동안 0 → `cameraKick` → 0.
    static func cameraKick(at t: TimeInterval, level: Int) -> CGFloat {
        guard level == dropLevel, t > contactAt, t < contactAt + cameraKickDuration else { return 0 }
        return cameraKick * CGFloat(sin((t - contactAt) / cameraKickDuration * .pi))
    }

    /// 충격 별의 자리(월드 픽셀, y 아래로): 때린 쪽의 발에서 나무 쪽으로 반 칸, 위로 `max(height, 24) · 0.55`(`showImpact` 의 높이).
    static func impactPoint(tacklerFoot: CGPoint, direction: PlazaDirection, height: CGFloat) -> CGPoint {
        let toward = CGFloat(PlazaMap.tileSize) / 2
        let step: CGPoint = switch direction {
        case .right: CGPoint(x: toward, y: 0)
        case .left: CGPoint(x: -toward, y: 0)
        case .down: CGPoint(x: 0, y: toward)
        case .up: CGPoint(x: 0, y: -toward)
        }
        return CGPoint(x: tacklerFoot.x + step.x, y: tacklerFoot.y + step.y - max(height, 24) * 0.55)
    }

    /// 떨어지는 아이템이 시작하는 자리(월드 픽셀, y 아래로): 때린 쪽 위의 잎 속. x 는 때린 쪽의 x 를 그림 안쪽 `itemInset` 으로 맞추고,
    /// y 는 자른 그림의 `itemStartRow` 줄, 뒤에서 때리면(그 줄이 발보다 아래) 발 위 `itemClearance`.
    static func itemStart(artRect: CGRect, tacklerFoot: CGPoint) -> CGPoint {
        CGPoint(x: min(max(tacklerFoot.x, artRect.minX + itemInset), artRect.maxX - itemInset),
                y: min(tacklerFoot.y - itemClearance, artRect.minY + CGFloat(itemStartRow) * scale))
    }
}

/// 나무에서 터진 잎 하나. 월드 픽셀과 픽셀/초(y 아래로).
struct PlazaTreeLeaf: Equatable {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat
    var age: TimeInterval
    /// 땅(`groundY`)에 닿은 때의 `age`.
    var restedAt: TimeInterval?
    let groundY: CGFloat
    /// `PlazaTree.burstArt(season).grids` 중 하나.
    let image: Int
    let phase: CGFloat
}

/// 터진 잎들. 노드 없는 순수 규칙이다: 상한 `maxFallingLeaves` 안에서 터질 때마다 정해진 씨앗으로 같은 모양을 만든다.
struct PlazaTreeLeaves {
    /// x 로 정렬한 잎 속 픽셀. 한 번에 터지는 잎은 이것을 같은 크기로 나눈 조각마다 하나씩 가져가 나무 너비 전체에 퍼진다.
    private let spawnPoints: [CGPoint]
    private let baseY: CGFloat
    private(set) var leaves: [PlazaTreeLeaf] = []
    /// 지금까지 터진 횟수. n 번째는 `fnv1a("plaza-tree-leaves-n")` 으로 씨를 뿌린다.
    private(set) var bursts = 0

    /// `spawnPoints` 는 `PlazaTree.canopySpawnPoints`, `baseY` 는 줄기 밑(그림 맨 아래)이다.
    init(spawnPoints: [CGPoint], baseY: CGFloat) {
        precondition(!spawnPoints.isEmpty, "a tree with no canopy has no leaves")
        self.spawnPoints = spawnPoints.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        self.baseY = baseY
    }

    /// 잎 `count` 장을 잎 속 불투명 픽셀에서 `direction`(맞은 쪽)과 위로 쏜다. 빈 자리를 먼저 쓰고, 다 찼으면 가장 오래된 잎을 다시 시작한다.
    mutating func burst(count: Int, direction: PlazaDirection, grids: [Int]) {
        precondition(!grids.isEmpty, "a burst needs a leaf picture")
        var rng = PlazaSplitMix64(seed: UInt64(PlazaNameColor.fnv1a("plaza-tree-leaves-\(bursts)")))
        bursts += 1
        for k in 0..<max(0, count) {
            // k 번째 잎은 정렬한 픽셀을 `count` 조각으로 나눈 k 번째 조각 안에서 고른다.
            let lo = min(k * spawnPoints.count / count, spawnPoints.count - 1)
            let hi = max((k + 1) * spawnPoints.count / count, lo + 1)
            let at = spawnPoints[lo + Int(rng.next() % UInt64(hi - lo))]
            let pop = PlazaTree.leafPop
            let speed = pop.lowerBound + CGFloat(rng.unit()) * (pop.upperBound - pop.lowerBound)
            let side = CGFloat(rng.unit()), lift = CGFloat(rng.unit())
            let vx: CGFloat = switch direction {
            case .right: speed * (0.5 + 0.5 * side)
            case .left: -speed * (0.5 + 0.5 * side)
            case .up, .down: speed * 0.7 * (2 * side - 1)
            }
            let leaf = PlazaTreeLeaf(x: at.x, y: at.y, vx: vx, vy: -speed * (0.6 + 0.4 * lift), age: 0, restedAt: nil,
                                     groundY: baseY + CGFloat(rng.unit()) * 18,
                                     image: grids[Int(rng.next() % UInt64(grids.count))], phase: CGFloat(rng.unit()) * 2 * .pi)
            if leaves.count < PlazaTree.maxFallingLeaves {
                leaves.append(leaf)
            } else {
                leaves[leaves.enumerated().max { $0.element.age < $1.element.age }!.offset] = leaf
            }
        }
    }

    /// 시간을 흘린다(1/60초 이하로 나눠서). 쏘아 올림 → 중력 → `leafFall` 로 떨어지며 그 종류의 흔들림·옆 쏠림(`PlazaWeather.motion`) → 땅에서 쉼 → 사라짐.
    mutating func advance(by dt: TimeInterval, kind: PlazaWeather.Kind) {
        let motion = PlazaWeather.motion(kind)
        var left = dt
        while left > 1e-9 {
            let h = min(left, 1.0 / 60)
            left -= h
            for i in leaves.indices {
                leaves[i].age += h
                if leaves[i].restedAt != nil { continue }
                let g = CGFloat(h)
                leaves[i].vy = min(leaves[i].vy + PlazaTree.leafGravity * g, PlazaTree.leafFall)
                let sway = CGFloat(motion.drift) + CGFloat(motion.sway) * CGFloat(cos(motion.swayRate * leaves[i].age + Double(leaves[i].phase)))
                leaves[i].vx += (sway - leaves[i].vx) * min(1, 2 * g)
                leaves[i].x += leaves[i].vx * g
                leaves[i].y += leaves[i].vy * g
                if leaves[i].y >= leaves[i].groundY {
                    leaves[i].y = leaves[i].groundY
                    leaves[i].vx = 0
                    leaves[i].vy = 0
                    leaves[i].restedAt = leaves[i].age
                }
            }
        }
        // 다 흐려진 잎(땅에서 `leafRest` 를 쉬었거나 `leafLife` 에 이른 잎)을 치운다.
        leaves.removeAll { Self.alpha($0) <= 0 }
    }

    /// 불투명도: 1, 땅에 닿은 뒤 `leafRest` 동안 0까지. 닿지 못한 잎도 `leafLife` 전 마지막 `leafRest` 동안 흐려져 하늘에서 툭 사라지지 않는다.
    static func alpha(_ leaf: PlazaTreeLeaf) -> CGFloat {
        let resting = leaf.restedAt.map { 1 - (leaf.age - $0) / PlazaTree.leafRest } ?? 1
        let ending = 1 - (leaf.age - (PlazaTree.leafLife - PlazaTree.leafRest)) / PlazaTree.leafRest
        return CGFloat(min(1, max(0, min(resting, ending))))
    }
}

/// 떨어지는 아이템 한 번의 길: 잎 속에서 때린 쪽의 발까지 `itemArc` 만큼 위로 굽은 길로 `itemFall` 동안, 그다음 `itemBounce` 만큼 한 번 튄다.
struct PlazaTreeItemFall: Equatable {
    let from: CGPoint
    let to: CGPoint

    /// 월드 픽셀(y 아래로). `to` 는 때린 순간 때린 쪽의 발 자리다.
    init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }

    /// 떨어지기 시작한 뒤 t 초의 자리. 튐이 끝났거나 시작 전이면 nil.
    func position(at t: TimeInterval) -> CGPoint? {
        guard t >= 0, t < PlazaTree.itemFall + PlazaTree.itemBounceDuration else { return nil }
        if t <= PlazaTree.itemFall {
            let u = CGFloat(t / PlazaTree.itemFall)
            return CGPoint(x: from.x * (1 - u) + to.x * u,
                           y: from.y * (1 - u) + to.y * u - PlazaTree.itemArc * 4 * u * (1 - u))
        }
        let v = (t - PlazaTree.itemFall) / PlazaTree.itemBounceDuration
        return CGPoint(x: to.x, y: to.y - PlazaTree.itemBounce * CGFloat(sin(v * .pi)))
    }
}

/// 그날 나무를 친 횟수. 내 Mac 에만 저장하고 보내지 않는다(`PlazaPreferences.tree`).
struct PlazaTreeDay: Codable, Equatable, Sendable {
    var day: String
    var hits = 0
    var dropped = 0
    static let maxHits = 99_999

    init(day: String) { self.day = day }

    /// `today`(`PlazaActivity.dayKey`)에 한 번 쳤다. 더 늦은 날이면 처음부터 센다. 더 이른 날(시계를 되돌림)이면 저장된 날에 이어 세서
    /// 민트를 또 받지 못한다(결함 부류 "되감긴 시계"). 이번 때림이 민트를 떨어뜨리면 true: `hitsPerDrop` 번째마다, 하루 `dropsPerDay` 번까지.
    mutating func hit(on today: String) -> Bool {
        if today > day { self = PlazaTreeDay(day: today) }
        hits = min(hits + 1, Self.maxHits)
        guard hits % PlazaTree.hitsPerDrop == 0, dropped < PlazaTree.dropsPerDay else { return false }
        dropped += 1
        return true
    }
}
