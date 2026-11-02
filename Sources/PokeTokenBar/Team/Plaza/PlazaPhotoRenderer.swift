import CoreGraphics
import Foundation
import ImageIO

/// 기념사진에 찍히는 캐릭터 하나. 좌표는 월드 픽셀이고 y가 아래로 늘어난다.
struct PlazaPhotoActor {
    let image: CGImage
    let flipped: Bool
    /// 발(그림 아래 가운데). 통통 튐은 빼고 둔다. 앞뒤 순서는 이 값으로 정한다.
    let foot: CGPoint
    /// 걸을 때 그림만 위로 들리는 월드 픽셀. 순서에는 쓰지 않는다.
    var bob: CGFloat = 0
    /// 월드 단위로 키우는 배율(1.5).
    let scale: CGFloat
    let shadow: CGImage?
    /// 그림자 사각형(월드, y 아래로).
    let shadowRect: CGRect
    /// 배율 2로 만든 이름표와 말풍선. 사진 픽셀 그대로 얹는다.
    let plate: CGImage?
    let bubble: CGImage?
}

struct PlazaPhotoInput {
    let mapImage: CGImage
    /// 사진에 담을 월드 영역.
    let visibleRect: CGRect
    /// 월드 픽셀 하나가 차지하는 사진 픽셀(화면 배율 × 2).
    let pixelsPerWorld: Int
    let actors: [PlazaPhotoActor]
}

/// 기념사진을 CoreGraphics로 합성한다. 창이나 SKView가 필요 없고, 모든 그림은 보간 없이 정수 배율로 찍는다.
enum PlazaPhotoRenderer {
    /// 지도 밖은 지도 가장자리 숲과 같은 짙은 초록.
    private static let outsideColor = CGColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255, alpha: 1)
    private static let maxSide = 16_384
    /// 이름표는 스프라이트 머리에서 2픽셀(배율 2의 1포인트) 띄운다.
    private static let plateGap = 2

    static func render(_ input: PlazaPhotoInput) -> CGImage? {
        let ppw = CGFloat(input.pixelsPerWorld)
        let rect = input.visibleRect
        guard input.pixelsPerWorld > 0, rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite else { return nil }
        let width = Int((rect.width * ppw).rounded()), height = Int((rect.height * ppw).rounded())
        guard width > 0, height > 0, width <= maxSide, height <= maxSide,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        /// 위에서 아래로 센 사진 픽셀 사각형을 CoreGraphics 사각형으로 바꾼다.
        func cg(_ x: Int, _ top: Int, _ w: Int, _ h: Int) -> CGRect {
            CGRect(x: x, y: height - top - h, width: w, height: h)
        }
        func px(_ world: CGFloat, origin: CGFloat) -> Int { Int(((world - origin) * ppw).rounded()) }
        func draw(_ image: CGImage, x: Int, top: Int, w: Int, h: Int, mirrored: Bool = false) {
            let dest = cg(x, top, w, h)
            if mirrored {
                context.saveGState()
                context.translateBy(x: dest.midX, y: 0)
                context.scaleBy(x: -1, y: 1)
                context.translateBy(x: -dest.midX, y: 0)
                context.draw(image, in: dest)
                context.restoreGState()
            } else {
                context.draw(image, in: dest)
            }
        }

        context.setFillColor(outsideColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(input.mapImage, x: px(0, origin: rect.minX), top: px(0, origin: rect.minY),
             w: Int((CGFloat(input.mapImage.width) * ppw).rounded()), h: Int((CGFloat(input.mapImage.height) * ppw).rounded()))

        for a in input.actors {
            guard let shadow = a.shadow else { continue }
            draw(shadow, x: px(a.shadowRect.minX, origin: rect.minX), top: px(a.shadowRect.minY, origin: rect.minY),
                 w: Int((a.shadowRect.width * ppw).rounded()), h: Int((a.shadowRect.height * ppw).rounded()))
        }

        // 화면 위쪽에 선(발의 y가 작은) 캐릭터부터. 같으면 입력 순서를 지킨다.
        let ordered = input.actors.enumerated().sorted { ($0.element.foot.y, $0.offset) < ($1.element.foot.y, $1.offset) }.map(\.element)
        for a in ordered {
            let w = Int((CGFloat(a.image.width) * a.scale * ppw).rounded()), h = Int((CGFloat(a.image.height) * a.scale * ppw).rounded())
            draw(a.image, x: px(a.foot.x - CGFloat(a.image.width) * a.scale / 2, origin: rect.minX),
                 top: px(a.foot.y - a.bob, origin: rect.minY) - h, w: w, h: h, mirrored: a.flipped)
        }

        for a in ordered {
            let centerX = px(a.foot.x, origin: rect.minX)
            var top = px(a.foot.y - a.bob, origin: rect.minY) - Int((CGFloat(a.image.height) * a.scale * ppw).rounded())
            if let plate = a.plate {
                top -= plateGap + plate.height
                draw(plate, x: centerX - plate.width / 2, top: top, w: plate.width, h: plate.height)
            }
            if let bubble = a.bubble {
                // 화면처럼 사진 안쪽으로 민다. 이름표가 사진 밖이면 누구 말인지 알 수 없으므로 같이 밖에 둔다.
                let isOnPhoto = (0..<width).contains(centerX) && (0..<height).contains(top)
                top -= bubble.height
                var x = centerX - bubble.width / 2
                if isOnPhoto {
                    x = min(max(x, 0), width - bubble.width)
                    top = max(top, 0)
                }
                draw(bubble, x: x, top: top, w: bubble.width, h: bubble.height)
            }
        }
        return context.makeImage()
    }

    static func pngData(for input: PlazaPhotoInput) -> Data? {
        render(input).flatMap(png)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
