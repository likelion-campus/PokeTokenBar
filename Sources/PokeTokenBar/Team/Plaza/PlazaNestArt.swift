import CoreGraphics
import Foundation

/// 알 밑에 까는 둥지. 지도 그림과 같은 2배 도트(한 칸 = 월드 2픽셀)로 그리고, 가운데 패인 곳에 알이 앉는다.
enum PlazaNestArt {
    static let cols = 24
    static let rows = 9
    private static let cell = 2

    static var size: (width: Int, height: Int) { (cols * cell, rows * cell) }

    private static let hollow: [UInt8] = [0x4A, 0x2E, 0x18]
    private static let twig: [UInt8] = [0x8B, 0x5A, 0x2B]
    private static let straw: [UInt8] = [0xC9, 0xA1, 0x5A]
    private static let light: [UInt8] = [0xE6, 0xC7, 0x7A]

    static func image() -> CGImage {
        let width = cols * cell, height = rows * cell
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<rows {
            for x in 0..<cols {
                guard let color = color(x, y) else { continue }
                for dy in 0..<cell {
                    for dx in 0..<cell {
                        let i = ((y * cell + dy) * width + x * cell + dx) * 4
                        data[i] = color[0]; data[i + 1] = color[1]; data[i + 2] = color[2]; data[i + 3] = 255
                    }
                }
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// 바깥 타원 안쪽만 칠한다. 위쪽 가운데는 어두운 패인 곳이고, 나머지 테두리는 잔가지 무늬다.
    static func color(_ x: Int, _ y: Int) -> [UInt8]? {
        let nx = (Double(x) + 0.5 - Double(cols) / 2) / (Double(cols) / 2)
        let ny = (Double(y) + 0.5 - Double(rows) / 2) / (Double(rows) / 2)
        guard nx * nx + ny * ny < 1 else { return nil }
        let hx = nx / 0.7, hy = (Double(y) + 0.5 - 3.2) / 2.3
        if y < 5, hx * hx + hy * hy < 1 { return hollow }
        switch (x * 2 + y * 3) % 7 {
        case 0: return light
        case 3, 5: return twig
        default: return straw
        }
    }
}
