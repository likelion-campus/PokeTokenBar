// Verbatim copy of Sources/PokeTokenBar/Team/Plaza/PlazaNamePlate.swift before Track A Task 5 (base 98876aa), renamed.
// The oracle for PlazaTextArtParityTests; deleted in Task 19. Do not edit except to port a fix from main.
import AppKit
import CoreText
@testable import PokeTokenBar

/// 캐릭터 머리 위에 붙는 이름 글자: 바탕 없이 색 글자, 어두운 테두리, 부드러운 그림자. CoreGraphics/CoreText만 쓰므로 창 없이 만들 수 있다.
/// 성격은 이름 한 줄 위에 더 작게 같은 색으로 쓴다. 이름표는 아래가 기준이라 이름은 제자리에 있고 위로 자란다.
enum LegacyPlazaNamePlate {
    static let fontSize: CGFloat = 15
    static let titleFontSize: CGFloat = 12
    /// 테두리(3pt)와 그림자(아래로 1pt, 흐림 2pt)가 잘리지 않을 여백.
    static let pad: CGFloat = 5
    /// Widest bitmap in device pixels. SpriteKit aborts the process on a texture above 32,768 px.
    static let maxPixelWidth = 2048
    private static let outlineWidth: CGFloat = 3
    private static let shadowOffset: CGFloat = 1
    private static let shadowBlur: CGFloat = 2

    /// `scale`은 포인트당 기기 픽셀 수. 크기는 포인트 단위로 정수가 되도록 올린다.
    static func image(text: String, title: String? = nil, color: PlazaColor, scale: CGFloat) -> CGImage? {
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

        // 성격은 정해진 문구뿐이라 폭을 따로 자르지 않는다.
        let titleLine = title.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
        }
        var titleAscent: CGFloat = 0, titleDescent: CGFloat = 0
        let titleWidth = titleLine.map { CGFloat(CTLineGetTypographicBounds($0, &titleAscent, &titleDescent, nil)) } ?? 0

        let contentWidth = max(textWidth, titleWidth)
        let width = (contentWidth + 2 * pad).rounded(.up)
        let height = (ascent + descent + titleAscent + titleDescent + 2 * pad).rounded(.up)
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
        // CTLineDraw가 위치를 움직이므로 그릴 때마다 놓는다.
        func drawLines() {
            context.textPosition = CGPoint(x: pad + (contentWidth - textWidth) / 2, y: pad + descent)
            CTLineDraw(line, context)
            if let titleLine {
                context.textPosition = CGPoint(x: pad + (contentWidth - titleWidth) / 2, y: pad + descent + ascent + titleDescent)
                CTLineDraw(titleLine, context)
            }
        }
        // 테두리를 글자 뒤에 먼저 그린다(그림자는 테두리 아래에만). 그다음 채움.
        context.setTextDrawingMode(.stroke)
        context.setLineWidth(outlineWidth)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1))
        drawLines()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setTextDrawingMode(.fill)
        context.setFillColor(color.cgColor)
        drawLines()
        return context.makeImage()
    }
}
