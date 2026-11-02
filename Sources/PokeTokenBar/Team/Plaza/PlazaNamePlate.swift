import AppKit
import CoreText

/// 캐릭터 머리 위에 붙는 이름 글자: 바탕 없이 색 글자, 어두운 테두리, 부드러운 그림자. CoreGraphics/CoreText만 쓰므로 창 없이 만들 수 있다.
enum PlazaNamePlate {
    static let fontSize: CGFloat = 15
    /// 테두리(3pt)와 그림자(아래로 1pt, 흐림 2pt)가 잘리지 않을 여백.
    static let pad: CGFloat = 5
    /// Widest bitmap in device pixels. SpriteKit aborts the process on a texture above 32,768 px.
    static let maxPixelWidth = 2048
    private static let outlineWidth: CGFloat = 3
    private static let shadowOffset: CGFloat = 1
    private static let shadowBlur: CGFloat = 2

    /// `scale`은 포인트당 기기 픽셀 수. 크기는 포인트 단위로 정수가 되도록 올린다.
    static func image(text: String, color: CGColor, scale: CGFloat) -> CGImage? {
        let scale = max(scale, 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // One Character can be thousands of points wide, so the Character count of a name bounds nothing.
        let maxTextWidth = (CGFloat(maxPixelWidth) / scale).rounded(.down) - 2 * pad
        if textWidth > maxTextWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(maxTextWidth), .end, ellipsis)
                ?? CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes))
            textWidth = min(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)), maxTextWidth)
        }

        let width = (textWidth + 2 * pad).rounded(.up)
        let height = (ascent + descent + 2 * pad).rounded(.up)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        // 그림자 변위·흐림은 CTM의 영향을 받지 않으므로 기기 픽셀로 직접 준다.
        context.setShadow(offset: CGSize(width: 0, height: -shadowOffset * scale), blur: shadowBlur * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        // 테두리를 글자 뒤에 먼저 그린다(그림자는 테두리 아래에만). 그다음 채움.
        context.setTextDrawingMode(.stroke)
        context.setLineWidth(outlineWidth)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1))
        CTLineDraw(line, context)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.textPosition = CGPoint(x: pad, y: pad + descent)   // CTLineDraw가 움직인 위치를 되돌린다
        context.setTextDrawingMode(.fill)
        context.setFillColor(color)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
