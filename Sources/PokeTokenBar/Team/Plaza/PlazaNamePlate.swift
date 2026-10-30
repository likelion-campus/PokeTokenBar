import AppKit
import CoreText

/// 캐릭터 머리 위에 붙는 대화창 모양 이름판. CoreGraphics/CoreText만 쓰므로 창 없이 만들 수 있다.
enum PlazaNamePlate {
    private static let background = rgb(0xF8, 0xF8, 0xF0)
    private static let textColor = rgb(0x30, 0x38, 0x48)
    private static let meBorder = rgb(0xD0, 0x48, 0x48)
    private static let otherBorder = rgb(0x58, 0x60, 0x78)
    private static let shadowColor = CGColor(srgbRed: 0x20 / 255, green: 0x28 / 255, blue: 0x38 / 255, alpha: 0.6)

    static let border: CGFloat = 2
    private static let corner: CGFloat = 4
    static let shadow: CGFloat = 2
    static let padX: CGFloat = 5
    static let padY: CGFloat = 3
    private /// Galmuri11 is drawn on a 100-unit grid of 1200 units/em, so 12 pt is its native pixel size.
    static let fontSize: CGFloat = 12

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// `scale`은 포인트당 기기 픽셀 수. 크기는 포인트 단위로 정수가 되도록 올린다.
    static func image(text: String, isMe: Bool, scale: CGFloat) -> CGImage {
        let scale = max(scale, 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlazaResources.font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let bodyWidth = (textWidth + 2 * (padX + border)).rounded(.up)
        let bodyHeight = (ascent + descent + 2 * (padY + border)).rounded(.up)
        let pixelWidth = Int(bodyWidth * scale)
        let pixelHeight = Int((bodyHeight + shadow) * scale)

        let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)

        func fill(_ rect: CGRect, radius: CGFloat, color: CGColor) {
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        let body = CGRect(x: 0, y: shadow, width: bodyWidth, height: bodyHeight)
        fill(body.offsetBy(dx: 0, dy: -shadow), radius: corner, color: shadowColor)
        fill(body, radius: corner, color: isMe ? meBorder : otherBorder)
        fill(body.insetBy(dx: border, dy: border), radius: corner - border, color: background)

        // 도트 글꼴은 격자에 맞아야 또렷하다: 글자에는 안티앨리어싱·스무딩을 끄고 기준선은 정수 포인트에 둔다.
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.textPosition = CGPoint(x: border + padX, y: shadow + border + padY + descent.rounded())
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}
