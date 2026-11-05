import Foundation
import CoreGraphics

/// 광장 지도를 CC0 타일셋(`PlazaResources.tileSheet()`, 16픽셀 칸)으로 조합해 한 장으로 만든다.
/// 시트 그림 1픽셀은 월드 2x2 픽셀로 그린다(보간 없음). 한 칸 = 월드 32픽셀.
enum PlazaTileArt {
    private static let tile = PlazaMap.tileSize
    private static let cell = 16
    private static let scale = 2

    /// 시트 칸 좌표 (열, 행).
    private typealias Cell = (col: Int, row: Int)
    private static let grassCells: [Cell] = [(0, 9), (1, 9), (0, 10), (1, 10), (5, 9), (8, 9), (5, 10), (8, 10)]
    private static let flowerCells: [Cell] = [(0, 8), (1, 8), (2, 12), (3, 11), (3, 12)]
    private static let bushCell: Cell = (2, 14)
    private static let waterCell: Cell = (3, 7)
    private static let lilySingle: Cell = (2, 0)
    private static let lilyPair: [Cell] = [(4, 0), (5, 0)]
    private static let lilySingleTile = TilePoint(x: 33, y: 18)
    private static let lilyPairTile = TilePoint(x: 35, y: 15)
    /// 2x2 칸 둥근 나무.
    private static let treeCell: Cell = (5, 16)
    /// 소식판 팻말의 재료. 기둥 하나가 달린 작은 팻말 한 칸이다. 이 칸의 픽셀로 2x2 칸 큰 팻말을 만든다(`signSource`).
    static let signCell: (col: Int, row: Int) = (34, 2)
    /// 큰 팻말의 시트 픽셀 크기. 2배로 그려 2x2 칸을 덮는다.
    static let signSize = 32

    /// 큰 팻말의 (x, y)(시트 픽셀, 0..<32)가 작은 팻말 칸의 어느 픽셀을 쓰는지. 시트에 큰 팻말이 없어 새 색 없이 늘려 만든다.
    /// 판자는 테두리를 두고 안쪽 무늬를 되풀이해 넓고 높게 만들고, 기둥은 양쪽에 하나씩 길게 세운다.
    static func signSource(x: Int, y: Int) -> (x: Int, y: Int) {
        let sy = switch y {
        case 0: 0
        case 1...16: 1 + (y - 1) % 7
        case 17: 8
        case 18: 9
        case 19...26: 10
        default: y - 16
        }
        let sx = y <= 18 ? (x == 0 ? 0 : x == signSize - 1 ? 15 : 1 + (x - 1) % 14) : x % 16
        return (sx, sy)
    }

    /// 지도 전체를 한 장으로(width*32 × height*32). 광장을 열 때 한 번 만든다.
    static func mapImage(_ map: PlazaMap, sheet: CGImage, tallGrass: PlazaTallGrassArt? = nil) -> CGImage {
        var canvas = Canvas(width: map.width * tile, height: map.height * tile, sheet: SheetPixels(sheet))
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                let n = Noise(p)
                if map.isWater(p) {
                    canvas.blit(waterCell, cols: 1, rows: 1, x: x * tile, y: y * tile)
                    continue
                }
                canvas.blit(grassCells[n.below(grassCells.count, 1)], cols: 1, rows: 1, x: x * tile, y: y * tile)
                if case .cell(let col, let row) = PlazaPond.shore(at: p, isWater: map.isWater) {
                    canvas.blit((col, row), cols: 1, rows: 1, x: x * tile, y: y * tile)
                    continue
                }
                switch map.tile(at: p) {
                case .flowers:
                    canvas.blit(flowerCells[n.below(flowerCells.count, 2)], cols: 1, rows: 1, x: x * tile, y: y * tile)
                case .bush:
                    canvas.blit(bushCell, cols: 1, rows: 1, x: x * tile, y: y * tile)
                default: break
                }
            }
        }
        drawLilyPads(map, &canvas)
        if let tallGrass { drawTallGrass(map, tallGrass, &canvas) }
        drawTrees(map, &canvas)
        let b = map.boardTile
        for sy in 0..<signSize {
            for sx in 0..<signSize {
                let s = signSource(x: sx, y: sy)
                canvas.plot(sheetX: signCell.col * cell + s.x, sheetY: signCell.row * cell + s.y,
                            x: b.x * tile + sx * scale, y: b.y * tile + sy * scale)
            }
        }
        return canvas.image()
    }

    /// 연잎: 물 칸 위에 한 칸짜리 하나와 두 칸짜리 하나. 그 자리가 물이 아닌 지도(작은 테스트 지도)에는 그리지 않는다.
    private static func drawLilyPads(_ map: PlazaMap, _ canvas: inout Canvas) {
        let single = lilySingleTile, pair = lilyPairTile
        if map.isWater(single) {
            canvas.blit(lilySingle, cols: 1, rows: 1, x: single.x * tile, y: single.y * tile)
        }
        for (i, c) in lilyPair.enumerated() where map.isWater(TilePoint(x: pair.x + i, y: pair.y)) {
            canvas.blit(c, cols: 1, rows: 1, x: (pair.x + i) * tile, y: pair.y * tile)
        }
    }

    /// 풀숲 칸마다 이웃에 맞는 조각을 잔디 위에 2배로 겹친다. 그림이 없으면 그리지 않아 풀밭으로 남는다.
    private static func drawTallGrass(_ map: PlazaMap, _ art: PlazaTallGrassArt, _ canvas: inout Canvas) {
        var sources: [PlazaTallGrassSlice: SheetPixels] = [:]
        let isGrass: (TilePoint) -> Bool = { map.tile(at: $0) == .tallGrass }
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                guard isGrass(p) else { continue }
                let s = PlazaTallGrass.slice(at: p, isGrass: isGrass)
                let source = sources[s] ?? SheetPixels(art.tile(s))
                sources[s] = source
                for sy in 0..<cell {
                    for sx in 0..<cell {
                        canvas.plot(from: source, sheetX: sx, sheetY: sy, x: x * tile + sx * scale, y: y * tile + sy * scale)
                    }
                }
            }
        }
    }

    /// 나무는 2x2 칸이며 (x + y)가 짝수인 자리에 놓아 줄마다 한 칸씩 엇갈린다.
    /// 위쪽부터 그려 아래 나무가 위를 덮는다. 덮는 칸이 모두 나무일 때만 놓는다(지도 밖은 무시).
    private static func drawTrees(_ map: PlazaMap, _ canvas: inout Canvas) {
        guard map.height >= 2 else { return }
        for oy in 0..<(map.height - 1) {
            for ox in -1..<map.width where (ox + oy) % 2 == 0 {
                var covers = false, allTrees = true
                for dy in 0...1 {
                    for dx in 0...1 {
                        let x = ox + dx, y = oy + dy
                        guard x >= 0, x < map.width else { continue }
                        if map.tile(at: TilePoint(x: x, y: y)) == .tree { covers = true } else { allTrees = false }
                    }
                }
                if covers && allTrees {
                    canvas.blit(treeCell, cols: 2, rows: 2, x: ox * tile, y: oy * tile)
                }
            }
        }
    }

    /// 칸 위치로 만드는 결정적 난수(splitmix64).
    private struct Noise {
        let seed: UInt64
        init(_ p: TilePoint) {
            seed = UInt64(truncatingIfNeeded: p.x) &* 0x9E37_79B9_7F4A_7C15
                ^ UInt64(truncatingIfNeeded: p.y) &* 0xC2B2_AE3D_27D4_EB4F
        }
        /// 0..<n
        func below(_ n: Int, _ salt: Int) -> Int {
            var z = seed &+ UInt64(truncatingIfNeeded: salt) &* 0xD6E8_FEB8_6659_FD93
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z & 0x7FFF_FFFF) % n
        }
    }

    /// 시트의 RGBA8(premultiplied) 바이트. 맨 윗줄부터.
    private struct SheetPixels {
        let width: Int, height: Int
        let bytes: [UInt8]
        init(_ image: CGImage) {
            width = image.width; height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            data.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            bytes = data
        }
    }

    private struct Canvas {
        let width: Int, height: Int
        let sheet: SheetPixels
        var bytes: [UInt8]

        init(width: Int, height: Int, sheet: SheetPixels) {
            self.width = width; self.height = height; self.sheet = sheet
            bytes = [UInt8](repeating: 255, count: width * height * 4)
        }

        /// 시트의 (cols x rows)칸 영역을 2배로 키워 (x, y)(왼쪽 위, 월드 픽셀)에 겹쳐 그린다.
        mutating func blit(_ c: Cell, cols: Int, rows: Int, x: Int, y: Int) {
            let sw = cols * PlazaTileArt.cell, sh = rows * PlazaTileArt.cell
            for sy in 0..<sh {
                for sx in 0..<sw {
                    plot(sheetX: c.col * PlazaTileArt.cell + sx, sheetY: c.row * PlazaTileArt.cell + sy,
                         x: x + sx * PlazaTileArt.scale, y: y + sy * PlazaTileArt.scale)
                }
            }
        }

        /// 시트 픽셀 하나를 2x2로 키워 (x, y)(왼쪽 위, 월드 픽셀)에 겹쳐 그린다.
        mutating func plot(sheetX: Int, sheetY: Int, x: Int, y: Int) {
            plot(from: sheet, sheetX: sheetX, sheetY: sheetY, x: x, y: y)
        }

        mutating func plot(from sheet: SheetPixels, sheetX: Int, sheetY: Int, x: Int, y: Int) {
            let si = (sheetY * sheet.width + sheetX) * 4
            let a = Int(sheet.bytes[si + 3])
            if a == 0 { return }
            for dy in 0..<PlazaTileArt.scale {
                for dx in 0..<PlazaTileArt.scale {
                    let ox = x + dx, oy = y + dy
                    guard ox >= 0, oy >= 0, ox < width, oy < height else { continue }
                    let di = (oy * width + ox) * 4
                    for k in 0..<3 {
                        bytes[di + k] = UInt8(min(255, Int(sheet.bytes[si + k]) + Int(bytes[di + k]) * (255 - a) / 255))
                    }
                    bytes[di + 3] = 255
                }
            }
        }

        func image() -> CGImage {
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: info, provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        }
    }

    /// 시트가 없을 때 쓰는 단색 잔디 지도.
    static func plainGrassImage(_ map: PlazaMap) -> CGImage {
        let w = map.width * tile, h = map.height * tile
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = 0x6D; bytes[i + 1] = 0xB9; bytes[i + 2] = 0x55 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
