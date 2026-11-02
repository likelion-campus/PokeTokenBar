import AppKit
import CoreText

/// 포켓몬 위에 뜨는 글 말풍선. 이모트 말풍선처럼 흰 몸통, 어두운 테두리, 아래 꼬리를 그린다. 창 없이 만들 수 있다.
enum PlazaChatBubble {
    private static let fontSize: CGFloat = 14
    private static let dot: CGFloat = 2
    private static let pad: CGFloat = 5
    private static let tailHeight: CGFloat = 4
    /// 글자 영역의 최대 크기. 어떤 글이 와도 그림 크기가 여기서 정해진다.
    static let maxTextWidth: CGFloat = 216
    /// 40자가 들어가는 줄 수보다 넉넉하다. 이모지처럼 대체 글꼴로 그리는 줄은 Galmuri보다 높다.
    static let maxLines = 6
    private static let ink = CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// 포인트 단위 최대 크기. 이미지 픽셀 크기는 여기에 배율을 곱한 값이다.
    static var maxSize: CGSize {
        CGSize(width: maxTextWidth + 2 * (dot + pad), height: maxTextHeight + 2 * (dot + pad) + tailHeight)
    }

    private static var maxTextHeight: CGFloat {
        let font = PlazaResources.font(size: fontSize)
        return ((font.ascender - font.descender + font.leading) * CGFloat(maxLines)).rounded(.up)
    }

    /// `scale`은 포인트당 기기 픽셀 수.
    static func image(text: String, scale: CGFloat) -> CGImage? {
        let scale = max(scale, 1)
        let setter = framesetter(text)
        let textSize = textSize(setter)
        let width = textSize.width + 2 * (dot + pad)
        let height = textSize.height + 2 * (dot + pad) + tailHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int((width * scale).rounded()), height: Int((height * scale).rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        let body = CGRect(x: 0, y: tailHeight, width: width, height: height - tailHeight)
        fillBody(body, color: ink, in: context)
        fillBody(body.insetBy(dx: dot, dy: dot), color: white, in: context)
        fillTail(centerX: (width / 2).rounded(), in: context)
        context.setShouldSmoothFonts(false)
        context.setFillColor(ink)
        let textRect = CGRect(origin: CGPoint(x: dot + pad, y: tailHeight + dot + pad), size: textSize)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: textRect, transform: nil), nil), context)
        return context.makeImage()
    }

    /// 글자 영역에 실제로 그려지는 UTF-16 길이. 글자 영역이 모자라면 뒤쪽 줄이 말없이 빠지므로 테스트가 확인한다.
    static func drawnLength(of text: String) -> Int {
        let setter = framesetter(text)
        let rect = CGRect(origin: .zero, size: textSize(setter))
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        return CTFrameGetVisibleStringRange(frame).length
    }

    private static func framesetter(_ text: String) -> CTFramesetter {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: PlazaResources.font(size: fontSize),
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private static func textSize(_ setter: CTFramesetter) -> CGSize {
        let limit = CGSize(width: maxTextWidth, height: maxTextHeight)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, limit, nil)
        return CGSize(width: min(max(fit.width, 1).rounded(.up), maxTextWidth),
                      height: min(max(fit.height, 1).rounded(.up), maxTextHeight))
    }

    /// 네 귀퉁이를 한 칸씩 뺀 사각형.
    private static func fillBody(_ rect: CGRect, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fill(rect.insetBy(dx: dot, dy: 0))
        context.fill(rect.insetBy(dx: 0, dy: dot))
    }

    private static func fillTail(centerX: CGFloat, in context: CGContext) {
        context.setFillColor(ink)
        context.fill(CGRect(x: centerX - dot * 2, y: tailHeight - dot, width: dot * 4, height: dot * 2))
        context.fill(CGRect(x: centerX - dot, y: 0, width: dot * 2, height: dot))
        context.setFillColor(white)
        context.fill(CGRect(x: centerX - dot, y: tailHeight - dot, width: dot * 2, height: dot * 2))
    }
}
