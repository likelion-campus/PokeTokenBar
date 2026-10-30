import AppKit
import CoreText

/// 캐릭터 머리 위에 붙는 이름 글자: 바탕 없이 흰 글자와 부드러운 그림자. CoreGraphics/CoreText만 쓰므로 창 없이 만들 수 있다.
enum PlazaNamePlate {
    static let fontSize: CGFloat = 12
    /// 그림자(아래로 1pt, 흐림 2pt)가 잘리지 않을 여백.
    static let pad: CGFloat = 4
    private static let shadowOffset: CGFloat = 1
    private static let shadowBlur: CGFloat = 2

    /// `scale`은 포인트당 기기 픽셀 수. 크기는 포인트 단위로 정수가 되도록 올린다.
    static func image(text: String, scale: CGFloat) -> CGImage {
        let scale = max(scale, 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let width = (textWidth + 2 * pad).rounded(.up)
        let height = (ascent + descent + 2 * pad).rounded(.up)
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        // 그림자 변위·흐림은 CTM의 영향을 받지 않으므로 기기 픽셀로 직접 준다.
        context.setShadow(offset: CGSize(width: 0, height: -shadowOffset * scale), blur: shadowBlur * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}
