import Foundation
import CoreGraphics

/// 언 연못의 그림. 아티스트 파일 세 장에서 정확히 같은 색의 픽셀만 골라 바꿔 칠할 뿐, 새 모양을 그리지 않는다.
/// 지도 그림(눈 지도)의 물 픽셀로 연못별 얼음을 만든다. 번들 파일은 바뀌지 않는다.
struct PlazaIceArt {
    struct GlossPatch: Equatable { let i: Int, j: Int, n: Int; let rx: Double, ry: Double }

    static let fill: UInt32 = 0xADCDEC, band: UInt32 = 0x94B9DF, hilite: UInt32 = 0xC8DEF4, crack: UInt32 = 0x6A97C6
    static let glossColors: [UInt32] = [0xB5D3EF, 0xC0DBF3, 0xD0E5F8]
    static let shardColors: [UInt32: UInt32] = [0x2D2727: 0x6A98C8, 0x39342F: 0x8FB7DE, 0x736353: 0xD8EAF8, 0xB39B83: 0xF4FAFF]
    /// 연못 기준 칸별 윤기 무늬. R(32,14)은 승인된 시안, L(5,13)과 B(20,24)는 구현 계획에서 정했다. 다른 연못은 없다.
    static let glossPatches: [TilePoint: [GlossPatch]] = [
        TilePoint(x: 32, y: 14): [GlossPatch(i: 1, j: 1, n: 2, rx: 30, ry: 22), GlossPatch(i: 4, j: 3, n: 2, rx: 31, ry: 23),
                                  GlossPatch(i: 1, j: 5, n: 1, rx: 15, ry: 12), GlossPatch(i: 5, j: 0, n: 1, rx: 15, ry: 12)],
        TilePoint(x: 5, y: 13): [GlossPatch(i: 1, j: 0, n: 2, rx: 30, ry: 22), GlossPatch(i: 5, j: 1, n: 1, rx: 15, ry: 12),
                                 GlossPatch(i: 8, j: 0, n: 1, rx: 15, ry: 12)],
        TilePoint(x: 20, y: 24): [GlossPatch(i: 1, j: 1, n: 1, rx: 15, ry: 12)]
    ]

    let gloss: CGImage?
    let cracks: [CGImage]
    let shards: [CGImage]

    static let none = PlazaIceArt(gloss: nil, cracks: [], shards: [])

    static func load(bundle: Bundle? = PlazaResources.resourceBundle()) -> PlazaIceArt {
        PlazaIceArt(
            gloss: PlazaResources.iceGlossSheet(in: bundle).map(gloss(fromSheet:)),
            cracks: PlazaResources.iceCrackSheet(in: bundle).map(cracks(fromSheet:)) ?? [],
            shards: shards(fromFrames: PlazaResources.iceShatterFrames(in: bundle)))
    }

    // MARK: Recolours

    /// 시트의 (51,51)…(66,66) 칸. 네 색을 밝기순으로 세워 가장 어두운 색은 지우고 나머지 셋을 `glossColors`로 바꾼다.
    static func gloss(fromSheet sheet: CGImage) -> CGImage {
        let (w, data) = (sheet.width, rgba(sheet))
        var cell = [UInt8](repeating: 0, count: 16 * 16 * 4)
        var colors = Set<UInt32>()
        for y in 0..<16 { for x in 0..<16 { colors.insert(rgb(data, w, 51 + x, 51 + y)) } }
        let ranked = colors.sorted { luma($0) < luma($1) }
        for y in 0..<16 {
            for x in 0..<16 {
                guard let rank = ranked.firstIndex(of: rgb(data, w, 51 + x, 51 + y)), rank >= 1, rank <= 3 else { continue }
                put(&cell, 16, x, y, glossColors[rank - 1])
            }
        }
        return image(cell, 16, 16)
    }

    /// (i·18, 18)의 16×16 칸 여섯 장에서 `#4F87BC` 금 픽셀만 `crack` 색으로 남기고, 뒤의 여섯 장은 좌우로 뒤집은 것.
    static func cracks(fromSheet sheet: CGImage) -> [CGImage] {
        let (w, data) = (sheet.width, rgba(sheet))
        let cells: [[UInt8]] = (0..<6).map { i in
            var cell = [UInt8](repeating: 0, count: 16 * 16 * 4)
            for y in 0..<16 {
                for x in 0..<16 {
                    let at = ((18 + y) * w + i * 18 + x) * 4
                    if data[at + 3] == 255, rgb(data, w, i * 18 + x, 18 + y) == 0x4F87BC { put(&cell, 16, x, y, crack) }
                }
            }
            return cell
        }
        let mirrored: [[UInt8]] = cells.map { cell in
            var out = [UInt8](repeating: 0, count: cell.count)
            for y in 0..<16 { for x in 0..<16 { for k in 0..<4 { out[(y * 16 + x) * 4 + k] = cell[(y * 16 + 15 - x) * 4 + k] } } }
            return out
        }
        return (cells + mirrored).map { image($0, 16, 16) }
    }

    /// 부서지는 바위 gif의 2~4번째 프레임. `shardColors`의 키인 불투명 픽셀만 바꾸고 나머지는 그대로 둔다.
    static func shards(fromFrames frames: [CGImage]) -> [CGImage] {
        guard frames.count >= 4 else { return [] }
        return frames[1...3].map { frame in
            var data = rgba(frame)
            for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] == 255 {
                let key = UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
                if let to = shardColors[key] {
                    data[i] = UInt8(to >> 16 & 0xFF); data[i + 1] = UInt8(to >> 8 & 0xFF); data[i + 2] = UInt8(to & 0xFF)
                }
            }
            return image(data, frame.width, frame.height)
        }
    }

    // MARK: Overlay

    /// `pond` 위의 얼음. 월드 픽셀(타일당 32)로 경계를 한 칸씩 넓힌 영역을 덮고, 왼쪽 위는 월드 ((minX−1)·32, (minY−1)·32)이다.
    /// 지도 그림 밖의 픽셀은 비워 둔다.
    static func overlay(mapImage: CGImage, pond: PlazaIce.Pond, gloss: CGImage?) -> CGImage {
        let tile = PlazaMap.tileSize
        let ox = (pond.minX - 1) * tile, oy = (pond.minY - 1) * tile
        let width = (pond.maxX - pond.minX + 3) * tile, height = (pond.maxY - pond.minY + 3) * tile
        let map = rgba(mapImage)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let outside: [UInt32: UInt32] = [0x1E7CB8: fill, 0x165C88: band, 0x5AAEE4: hilite]
        for y in 0..<height {
            let wy = oy + y
            guard wy >= 0, wy < mapImage.height else { continue }
            for x in 0..<width {
                let wx = ox + x
                guard wx >= 0, wx < mapImage.width else { continue }
                let c = rgb(map, mapImage.width, wx, wy)
                if pond.contains(TilePoint(x: wx / tile, y: wy / tile)) {
                    put(&out, width, x, y, c == 0x165C88 ? band : fill)
                } else if let to = outside[c] {
                    put(&out, width, x, y, to)
                }
            }
        }
        if let gloss, let patches = glossPatches[pond.anchor] {
            let g = rgba(gloss), gw = gloss.width
            for patch in patches {
                let size = tile * patch.n
                for y in 0..<size {
                    for x in 0..<size {
                        let dx = Double(x) - Double(size) / 2, dy = Double(y) - Double(size) / 2
                        guard (dx / patch.rx) * (dx / patch.rx) + (dy / patch.ry) * (dy / patch.ry) <= 1 else { continue }
                        // ×2 nearest of the 16×16 gloss, tiled every 32 px.
                        let sx = (x % 32) / 2, sy = (y % 32) / 2
                        let at = (sy * gw + sx) * 4
                        guard g[at + 3] == 255 else { continue }
                        put(&out, width, tile * (patch.i + 1) + x, tile * (patch.j + 1) + y, rgb(g, gw, sx, sy))
                    }
                }
            }
        }
        return image(out, width, height)
    }

    // MARK: Pixels

    private static func luma(_ c: UInt32) -> Double {
        0.30 * Double(c >> 16 & 0xFF) + 0.59 * Double(c >> 8 & 0xFF) + 0.11 * Double(c & 0xFF)
    }

    private static func rgb(_ data: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> UInt32 {
        let i = (y * w + x) * 4
        return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
    }

    private static func put(_ data: inout [UInt8], _ w: Int, _ x: Int, _ y: Int, _ c: UInt32) {
        let i = (y * w + x) * 4
        data[i] = UInt8(c >> 16 & 0xFF); data[i + 1] = UInt8(c >> 8 & 0xFF); data[i + 2] = UInt8(c & 0xFF); data[i + 3] = 255
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    private static func image(_ data: [UInt8], _ w: Int, _ h: Int) -> CGImage {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)!
    }
}
