import Foundation
import CoreGraphics
import CoreText
import SpriteKit

/// 연못 물보라 방울·물결 고리·거품·헤엄 고리. 코드로 그리는 픽셀은 이 넷뿐이고 색은 네 가지(진한 물빛·물빛·연한 물빛·하양)만 쓴다.
/// 모두 시트 픽셀 단위(월드 2px)로 만들고, 늘리지 않고 최근접으로 그린다.
enum PlazaPondArt {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let deep: [UInt8] = [0x16, 0x5C, 0x88]     // #165C88
    private static let mid: [UInt8] = [0x29, 0x96, 0xDB]      // #2996DB
    private static let light: [UInt8] = [0x5A, 0xAE, 0xE4]    // #5AAEE4
    private static let white: [UInt8] = [0xFF, 0xFF, 0xFF]    // #FFFFFF

    /// 연못 타일의 물빛(지도 그림에서 잰 값). 헤엄치는 캐릭터의 잠긴 아랫부분에 이 색을 `submergedBlend`만큼 섞는다.
    static let waterColor = SKColor(red: 30 / 255, green: 124 / 255, blue: 184 / 255, alpha: 1)
    /// 잠긴 아랫부분의 불투명도(캐릭터 불투명도에 곱한다)와 물빛을 섞는 비율.
    static let submergedAlpha: CGFloat = 0.45
    static let submergedBlend: CGFloat = 0.3

    /// 3×3. 위·왼쪽은 하양, 가운데는 연한 물빛, 오른쪽·아래는 물빛. 모서리는 투명.
    static func droplet() -> CGImage {
        image([".w.", "wlm", ".m."].map(Array.init), width: 3, height: 3,
              palette: ["w": white, "l": light, "m": mid])
    }

    /// 가로:세로 = 2:1 타원 테두리. 가로 반지름 `radius` 시트 픽셀, 크기 (2r+1)×(2·ry+1).
    static func ring(radius: Int) -> CGImage {
        let rx = max(radius, 2), ry = max(rx / 2, 1)
        let w = 2 * rx + 1, h = 2 * ry + 1
        var grid = [[Character]](repeating: [Character](repeating: ".", count: w), count: h)
        for k in 0..<96 {
            let a = Double(k) / 96 * 2 * Double.pi
            let x = Int((Double(rx) + Double(rx) * cos(a)).rounded())
            let y = Int((Double(ry) + Double(ry) * sin(a)).rounded())
            grid[y][x] = y < ry ? "w" : "l"   // 위쪽 호는 하이라이트
        }
        return image(grid, width: w, height: h, palette: ["w": white, "l": light])
    }

    /// 3×3. 가장자리는 연한 물빛, 가운데는 하양, 모서리는 투명.
    static func bubble() -> CGImage {
        image([".l.", "lwl", ".l."].map(Array.init), width: 3, height: 3, palette: ["l": light, "w": white])
    }

    /// 가로 12 시트 픽셀의 헤엄 물높이 고리.
    static func swimRing() -> CGImage {
        image(["..llllllll..", ".lwwmmmmwwl.", "..dddddddd.."].map(Array.init), width: 12, height: 3,
              palette: ["l": light, "w": white, "m": mid, "d": deep])
    }

    /// "💧" 이모지를 12pt로 그린 이미지. `scale`은 픽셀 배율.
    static func wetImage(scale: CGFloat) -> CGImage {
        let side = Int((16 * scale).rounded(.up))
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "💧", attributes: [.font: font]))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: 8 - bounds.midX, y: 8 - bounds.midY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    /// 위에서 아래로 읽는 격자를 그린다. 팔레트에 없는 글자는 투명.
    private static func image(_ rows: [[Character]], width: Int, height: Int, palette: [Character: [UInt8]]) -> CGImage {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let rgb = palette[ch] else { continue }
                let i = (y * width + x) * 4
                out[i] = rgb[0]; out[i + 1] = rgb[1]; out[i + 2] = rgb[2]; out[i + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(out) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}
