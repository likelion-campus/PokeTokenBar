import Foundation
import CoreGraphics

/// 광장 타일을 코드로 그린 원본 도트. 한 칸은 32x32 월드 픽셀이고 도트 1개 = 월드 픽셀 1개다.
/// 모든 칸은 완전히 불투명하며(풀 바닥을 먼저 깐다), 잡음은 칸 위치로 시드를 만든 결정적 난수다.
enum PlazaTileArt {
    /// 32×32. 같은 (tile, 위치, 이웃)이면 항상 같은 픽셀(위치로 시드를 만든 결정적 난수).
    static func tileImage(at p: TilePoint, in map: PlazaMap) -> CGImage {
        makeImage(width: size, height: size, rgba: tileCanvas(at: p, in: map).bytes)
    }

    /// 지도 전체를 한 장으로(width*32 × height*32). 광장을 열 때 한 번 만든다.
    static func mapImage(_ map: PlazaMap) -> CGImage {
        let w = map.width * size, h = map.height * size
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for ty in 0..<map.height {
            for tx in 0..<map.width {
                let tile = tileCanvas(at: TilePoint(x: tx, y: ty), in: map).bytes
                for row in 0..<size {
                    let src = row * size * 4
                    let dst = ((ty * size + row) * w + tx * size) * 4
                    out.replaceSubrange(dst..<dst + size * 4, with: tile[src..<src + size * 4])
                }
            }
        }
        return makeImage(width: w, height: h, rgba: out)
    }

    private static let size = PlazaMap.tileSize

    // MARK: - 팔레트

    private struct RGB: Equatable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ hex: UInt32) {
            r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF)
        }
    }

    /// 팔레트 한 곳. 옛 휴대용 게임기처럼 색 수를 적게 쓴다.
    private enum Pal {
        static let grass = RGB(0x6DB955), grassDark = RGB(0x58A548), grassLight = RGB(0x84CC66)
        static let tallBase = RGB(0x4E9A44), tallBlade = RGB(0x2F7A3A), tallTip = RGB(0x8AD06A)
        static let pathBase = RGB(0xD9BE85), pathDark = RGB(0xC4A66C), pathLight = RGB(0xE8D4A2)
        static let pathEdge = RGB(0x8E7448), pathEdgeSoft = RGB(0xB39559)
        static let water = RGB(0x4A8FD6), waterDark = RGB(0x3B78BE), waterLight = RGB(0x8EC4F0)
        static let shore = RGB(0x2E5E96), shoreSoft = RGB(0xE6D9A8)
        static let outline = RGB(0x24351F), leaf = RGB(0x2F8A3A), leafLight = RGB(0x4FB04C), leafDark = RGB(0x226B30)
        static let shadow = RGB(0x4A8E3E)
        static let trunk = RGB(0x8A5A2B), trunkDark = RGB(0x5E3B1B)
        static let rock = RGB(0x9A9AA6), rockLight = RGB(0xC4C4D0), rockDark = RGB(0x6E6E7C)
        static let wood = RGB(0xC48A4A), woodLight = RGB(0xDDA663), woodDark = RGB(0x8E5E30), woodLine = RGB(0x6E4624)
        static let sign = RGB(0xE9CE92), signText = RGB(0x7A5430)
        static let petals: [RGB] = [RGB(0xE5484D), RGB(0xFFFFFF), RGB(0xF28CB8), RGB(0xF5D547)]
        static let flowerCenter = RGB(0xF5D547), flowerStem = RGB(0x2F7A3A)
    }

    // MARK: - 캔버스

    private struct Canvas {
        var bytes = [UInt8](repeating: 255, count: PlazaTileArt.size * PlazaTileArt.size * 4)

        mutating func set(_ x: Int, _ y: Int, _ c: RGB) {
            guard x >= 0, y >= 0, x < PlazaTileArt.size, y < PlazaTileArt.size else { return }
            let i = (y * PlazaTileArt.size + x) * 4
            bytes[i] = c.r; bytes[i + 1] = c.g; bytes[i + 2] = c.b; bytes[i + 3] = 255
        }

        mutating func fill(_ c: RGB) {
            for y in 0..<PlazaTileArt.size { for x in 0..<PlazaTileArt.size { set(x, y, c) } }
        }

        /// 양끝 포함 직사각형.
        mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGB) {
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 { set(x, y, c) } }
        }

        /// 1칸 테두리가 있는 직사각형.
        mutating func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, fill: RGB, outline: RGB) {
            rect(x0, y0, x1, y1, outline)
            rect(x0 + 1, y0 + 1, x1 - 1, y1 - 1, fill)
        }
    }

    /// 칸 위치로 만드는 결정적 난수(splitmix64).
    private struct Noise {
        let seed: UInt64
        init(_ p: TilePoint) {
            seed = UInt64(truncatingIfNeeded: p.x) &* 0x9E37_79B9_7F4A_7C15
                ^ UInt64(truncatingIfNeeded: p.y) &* 0xC2B2_AE3D_27D4_EB4F
        }
        func value(_ a: Int, _ b: Int = 0, _ salt: Int = 0) -> Int {
            var z = seed &+ UInt64(truncatingIfNeeded: a) &* 0xBF58_476D_1CE4_E5B9
                &+ UInt64(truncatingIfNeeded: b) &* 0x94D0_49BB_1331_11EB
                &+ UInt64(truncatingIfNeeded: salt) &* 0xD6E8_FEB8_6659_FD93
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z & 0x7FFF_FFFF)
        }
        /// 0..<n
        func below(_ n: Int, _ a: Int, _ b: Int = 0, _ salt: Int = 0) -> Int { value(a, b, salt) % n }
    }

    // MARK: - 칸 분배

    private static func tileCanvas(at p: TilePoint, in map: PlazaMap) -> Canvas {
        var c = Canvas()
        let n = Noise(p)
        let up = map.tile(at: TilePoint(x: p.x, y: p.y - 1))
        let down = map.tile(at: TilePoint(x: p.x, y: p.y + 1))
        let left = map.tile(at: TilePoint(x: p.x - 1, y: p.y))
        let right = map.tile(at: TilePoint(x: p.x + 1, y: p.y))
        switch map.tile(at: p) {
        case .grass: drawGrass(&c, n)
        case .tallGrass: drawTallGrass(&c, n)
        case .flowers: drawFlowers(&c, n)
        case .path: drawPath(&c, n, up: up, down: down, left: left, right: right)
        case .shelter: drawShelter(&c, n, up: up, down: down, left: left, right: right)
        case .water: drawWater(&c, n, up: up, down: down, left: left, right: right)
        case .tree: drawTree(&c, n)
        case .rock: drawRock(&c, n)
        case .fence: drawFence(&c, n)
        case .board: drawBoard(&c, n)
        }
        return c
    }

    // MARK: - 바닥

    private static func drawGrass(_ c: inout Canvas, _ n: Noise) {
        for y in 0..<size {
            for x in 0..<size {
                let v = n.below(100, x, y, 1)
                c.set(x, y, v < 9 ? Pal.grassDark : (v < 13 ? Pal.grassLight : Pal.grass))
            }
        }
        // 작은 풀잎 몇 개(V자 두 점)
        for i in 0..<3 {
            let x = 3 + n.below(size - 6, i, 0, 2), y = 4 + n.below(size - 8, i, 0, 3)
            c.set(x, y, Pal.grassDark); c.set(x + 2, y, Pal.grassDark); c.set(x + 1, y + 1, Pal.grassDark)
        }
    }

    private static func drawTallGrass(_ c: inout Canvas, _ n: Noise) {
        c.fill(Pal.tallBase)
        for y in 0..<size { for x in 0..<size where n.below(100, x, y, 4) < 8 { c.set(x, y, Pal.tallBlade) } }
        // 위로 뻗은 풀잎: 4칸 간격 열마다 높이가 다른 잎
        var x = 1
        while x < size - 1 {
            let top = 5 + n.below(10, x, 0, 5)
            let base = 22 + n.below(9, x, 0, 6)
            for y in top...base { c.set(x, y, Pal.tallBlade); c.set(x + 1, y, Pal.tallBlade) }
            c.set(x, top, Pal.tallTip); c.set(x + 1, top + 1, Pal.tallTip)
            c.set(x - 1, top + 3, Pal.tallBlade)
            c.set(x + 2, top + 5, Pal.tallBlade)
            x += 4
        }
    }

    private static func drawFlowers(_ c: inout Canvas, _ n: Noise) {
        drawGrass(&c, n)
        // 3x2 격자 칸마다 한 송이씩, 일부는 비운다
        let slotsX = [4, 14, 24], slotsY = [7, 20]
        for (iy, sy) in slotsY.enumerated() {
            for (ix, sx) in slotsX.enumerated() {
                let k = iy * 3 + ix
                if n.below(6, k, 0, 7) == 0 { continue }
                let fx = sx + n.below(3, k, 1, 8), fy = sy + n.below(3, k, 2, 9)
                let petal = Pal.petals[n.below(Pal.petals.count, k, 3, 10)]
                c.set(fx + 1, fy + 3, Pal.flowerStem); c.set(fx + 1, fy + 4, Pal.flowerStem)
                c.set(fx, fy + 1, petal); c.set(fx + 2, fy + 1, petal)
                c.set(fx + 1, fy, petal); c.set(fx + 1, fy + 2, petal)
                c.set(fx + 1, fy + 1, Pal.flowerCenter == petal ? Pal.petals[0] : Pal.flowerCenter)
            }
        }
    }

    // MARK: - 길

    private static func drawPath(_ c: inout Canvas, _ n: Noise,
                                 up: PlazaTile, down: PlazaTile, left: PlazaTile, right: PlazaTile) {
        for y in 0..<size {
            for x in 0..<size {
                let v = n.below(100, x, y, 11)
                c.set(x, y, v < 8 ? Pal.pathDark : (v < 12 ? Pal.pathLight : Pal.pathBase))
            }
        }
        // 작은 돌 알갱이
        for i in 0..<3 {
            let x = 4 + n.below(size - 8, i, 0, 12), y = 4 + n.below(size - 8, i, 0, 13)
            c.set(x, y, Pal.pathDark); c.set(x + 1, y, Pal.pathDark)
        }
        let open: (PlazaTile) -> Bool = { $0 != .path && $0 != .shelter }
        // 이웃이 길이 아니면 그 변에 안쪽 연한 줄 + 바깥 짙은 줄
        for i in 0..<size {
            if open(up) { c.set(i, 0, Pal.pathEdge); c.set(i, 1, Pal.pathEdgeSoft) }
            if open(down) { c.set(i, size - 1, Pal.pathEdge); c.set(i, size - 2, Pal.pathEdgeSoft) }
            if open(left) { c.set(0, i, Pal.pathEdge); c.set(1, i, Pal.pathEdgeSoft) }
            if open(right) { c.set(size - 1, i, Pal.pathEdge); c.set(size - 2, i, Pal.pathEdgeSoft) }
        }
    }

    private static func drawShelter(_ c: inout Canvas, _ n: Noise,
                                    up: PlazaTile, down: PlazaTile, left: PlazaTile, right: PlazaTile) {
        c.fill(Pal.wood)
        // 가로 판자: 8줄마다 이음선, 판자마다 세로 이음 위치가 다르다
        for y in 0..<size {
            if y % 8 == 7 {
                for x in 0..<size { c.set(x, y, Pal.woodLine) }
                continue
            }
            if y % 8 == 0 { for x in 0..<size { c.set(x, y, Pal.woodLight) } }
            for x in 0..<size where n.below(100, x, y, 14) < 6 { c.set(x, y, Pal.woodDark) }
            let joint = (y / 8 * 11 + 5) % size
            c.set(joint, y, Pal.woodLine)
            if y % 8 == 3 { c.set((joint + 3) % size, y, Pal.woodDark); c.set((joint + size - 3) % size, y, Pal.woodDark) }
        }
        // 가장자리 (쉼터가 아닌 이웃 변)
        for i in 0..<size {
            if up != .shelter { c.set(i, 0, Pal.woodLine) }
            if down != .shelter { c.set(i, size - 1, Pal.woodLine) }
            if left != .shelter { c.set(0, i, Pal.woodLine) }
            if right != .shelter { c.set(size - 1, i, Pal.woodLine) }
        }
    }

    // MARK: - 연못

    private static func drawWater(_ c: inout Canvas, _ n: Noise,
                                  up: PlazaTile, down: PlazaTile, left: PlazaTile, right: PlazaTile) {
        c.fill(Pal.water)
        for y in 0..<size { for x in 0..<size where n.below(100, x, y, 15) < 10 { c.set(x, y, Pal.waterDark) } }
        // 물결무늬 하이라이트(가로 3점 줄)
        for i in 0..<3 {
            let x = 3 + n.below(size - 8, i, 0, 16), y = 5 + n.below(size - 10, i, 0, 17)
            c.set(x, y, Pal.waterLight); c.set(x + 1, y, Pal.waterLight); c.set(x + 2, y, Pal.waterLight)
        }
        let land: (PlazaTile) -> Bool = { $0 != .water }
        // 물가: 바깥 모래빛 줄 + 안쪽 짙은 줄
        for i in 0..<size {
            if land(up) { c.set(i, 0, Pal.shoreSoft); c.set(i, 1, Pal.shore) }
            if land(down) { c.set(i, size - 1, Pal.shoreSoft); c.set(i, size - 2, Pal.shore) }
            if land(left) { c.set(0, i, Pal.shoreSoft); c.set(1, i, Pal.shore) }
            if land(right) { c.set(size - 1, i, Pal.shoreSoft); c.set(size - 2, i, Pal.shore) }
        }
    }

    // MARK: - 물체 (풀 바닥 위)

    /// 타원 안쪽 여부.
    private static func inEllipse(_ x: Int, _ y: Int, cx: Double, cy: Double, rx: Double, ry: Double) -> Double {
        let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
        return dx * dx + dy * dy
    }

    private static func drawTree(_ c: inout Canvas, _ n: Noise) {
        drawGrass(&c, n)
        // 바닥 그림자
        for y in 0..<size { for x in 0..<size where inEllipse(x, y, cx: 16, cy: 28, rx: 12, ry: 3.5) <= 1 {
            c.set(x, y, Pal.shadow)
        } }
        // 줄기
        c.box(13, 21, 18, 30, fill: Pal.trunk, outline: Pal.outline)
        for y in 22...29 { c.set(17, y, Pal.trunkDark) }
        // 둥근 수관
        for y in 0..<27 {
            for x in 0..<size {
                let d = inEllipse(x, y, cx: 16, cy: 13.5, rx: 14, ry: 13)
                if d > 1 { continue }
                let edge = d > 0.78
                var col = Pal.leaf
                if !edge {
                    let hx = Double(x) - 16, hy = Double(y) - 13.5
                    if hx + hy < -9 && n.below(100, x, y, 18) < 55 { col = Pal.leafLight }
                    else if hx + hy > 8 { col = Pal.leafDark }
                    else if n.below(100, x, y, 19) < 8 { col = Pal.leafDark }
                }
                c.set(x, y, edge ? Pal.outline : col)
            }
        }
    }

    private static func drawRock(_ c: inout Canvas, _ n: Noise) {
        drawGrass(&c, n)
        for y in 0..<size { for x in 0..<size where inEllipse(x, y, cx: 16, cy: 26, rx: 13, ry: 4) <= 1 {
            c.set(x, y, Pal.shadow)
        } }
        for y in 0..<size {
            for x in 0..<size {
                let d = inEllipse(x, y, cx: 16, cy: 19, rx: 11.5, ry: 9)
                if d > 1 { continue }
                if d > 0.72 { c.set(x, y, Pal.outline); continue }
                let hx = Double(x) - 16, hy = Double(y) - 19
                c.set(x, y, hx + hy < -6 ? Pal.rockLight : (hx + hy > 5 ? Pal.rockDark : Pal.rock))
            }
        }
        // 금
        for i in 0..<4 { c.set(15 + i, 18 + i / 2, Pal.rockDark) }
    }

    private static func drawFence(_ c: inout Canvas, _ n: Noise) {
        drawGrass(&c, n)
        c.rect(0, 26, size - 1, 29, Pal.shadow)
        for ry in [12, 19] {
            c.rect(0, ry, size - 1, ry + 3, Pal.outline)
            c.rect(0, ry + 1, size - 1, ry + 2, Pal.woodLight)
        }
        for px in [3, 24] {
            c.rect(px, 7, px + 4, 28, Pal.outline)
            c.rect(px + 1, 8, px + 3, 27, Pal.wood)
            c.rect(px + 3, 8, px + 3, 27, Pal.woodDark)
            c.set(px + 1, 8, Pal.woodLight); c.set(px + 2, 8, Pal.woodLight)
        }
    }

    private static func drawBoard(_ c: inout Canvas, _ n: Noise) {
        drawGrass(&c, n)
        c.rect(6, 28, 25, 30, Pal.shadow)
        // 기둥
        c.box(13, 17, 18, 30, fill: Pal.wood, outline: Pal.outline)
        for y in 18...29 { c.set(17, y, Pal.woodDark) }
        // 판
        c.box(3, 3, 28, 19, fill: Pal.sign, outline: Pal.outline)
        c.rect(4, 18, 27, 18, Pal.woodDark)
        // 글 줄 느낌의 점선
        for (row, len) in [(7, 18), (11, 14), (15, 16)] {
            var x = 7
            while x < 7 + len { c.rect(x, row, x + 2, row, Pal.signText); x += 4 }
        }
        c.set(5, 5, Pal.outline); c.set(26, 5, Pal.outline)
    }

    // MARK: - CGImage

    private static func makeImage(width: Int, height: Int, rgba: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}
