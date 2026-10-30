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
    /// 2x2 칸 둥근 나무.
    private static let treeCell: Cell = (5, 16)
    /// 나무 게시판. 그림이 (6,6)부터 2x3 칸보다 좌우로 5픽셀씩 넓어 한 칸 왼쪽에서 3x3 칸으로 읽는다.
    /// 불투명 영역은 이 3x3 안에서 x 11..<37, y 7..<40(시트 픽셀)이다.
    private static let boardCell: Cell = (5, 6)
    private static let boardArtX = 11, boardArtWidth = 26, boardArtBottom = 40

    /// 지도 전체를 한 장으로(width*32 × height*32). 광장을 열 때 한 번 만든다.
    static func mapImage(_ map: PlazaMap, sheet: CGImage) -> CGImage {
        var canvas = Canvas(width: map.width * tile, height: map.height * tile, sheet: SheetPixels(sheet))
        for y in 0..<map.height {
            for x in 0..<map.width {
                let p = TilePoint(x: x, y: y)
                let n = Noise(p)
                canvas.blit(grassCells[n.below(grassCells.count, 1)], cols: 1, rows: 1, x: x * tile, y: y * tile)
                switch map.tile(at: p) {
                case .flowers:
                    canvas.blit(flowerCells[n.below(flowerCells.count, 2)], cols: 1, rows: 1, x: x * tile, y: y * tile)
                case .bush:
                    canvas.blit(bushCell, cols: 1, rows: 1, x: x * tile, y: y * tile)
                default: break
                }
            }
        }
        drawTrees(map, &canvas)
        // 게시판 그림은 2x2 덩어리의 가로 가운데, 아래쪽 끝에 맞추고 한 칸 위로 솟는다.
        let b = map.boardTile
        let artLeft = b.x * tile + (2 * tile - boardArtWidth * scale) / 2
        canvas.blit(boardCell, cols: 3, rows: 3,
                    x: artLeft - boardArtX * scale, y: (b.y + 2) * tile - boardArtBottom * scale)
        return canvas.image()
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
                    let si = ((c.row * PlazaTileArt.cell + sy) * sheet.width + c.col * PlazaTileArt.cell + sx) * 4
                    let a = Int(sheet.bytes[si + 3])
                    if a == 0 { continue }
                    for dy in 0..<PlazaTileArt.scale {
                        for dx in 0..<PlazaTileArt.scale {
                            let ox = x + sx * PlazaTileArt.scale + dx, oy = y + sy * PlazaTileArt.scale + dy
                            guard ox >= 0, oy >= 0, ox < width, oy < height else { continue }
                            let di = (oy * width + ox) * 4
                            for k in 0..<3 {
                                bytes[di + k] = UInt8(min(255, Int(sheet.bytes[si + k]) + Int(bytes[di + k]) * (255 - a) / 255))
                            }
                            bytes[di + 3] = 255
                        }
                    }
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
