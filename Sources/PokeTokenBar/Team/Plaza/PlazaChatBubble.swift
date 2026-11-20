import Foundation

/// 포켓몬 위에 뜨는 글 말풍선. 이모트 말풍선처럼 흰 몸통, 어두운 테두리, 아래 꼬리를 그린다. 창 없이 만들 수 있다.
enum PlazaChatBubble {
    private static let textSize = PlazaTextSize.body
    private static let dot: CGFloat = 2
    private static let pad: CGFloat = 5
    private static let tailHeight: CGFloat = 4
    /// 글자 영역의 최대 크기. 어떤 글이 와도 그림 크기가 여기서 정해진다.
    static let maxTextWidth: CGFloat = 216
    /// 60자가 들어가는 줄 수보다 넉넉하다. 이모지처럼 대체 글꼴로 그리는 줄은 Galmuri보다 높다.
    static let maxLines = 8
    private static let ink = PlazaColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1)
    private static let white = PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// 포인트 단위 최대 크기. 이미지 픽셀 크기는 여기에 배율을 곱한 값이다.
    static var maxSize: CGSize {
        CGSize(width: maxTextWidth + 2 * (dot + pad), height: maxTextHeight(PlatformPlaza.graphics) + 2 * (dot + pad) + tailHeight)
    }

    private static func maxTextHeight(_ graphics: any PlazaGraphics) -> CGFloat {
        let font = graphics.text.metrics(.plaza(textSize))
        return ((font.ascender - font.descender + font.leading) * CGFloat(maxLines)).rounded(.up)
    }

    /// `scale`은 포인트당 기기 픽셀 수.
    static func image(text: String, scale: CGFloat, graphics: any PlazaGraphics = PlatformPlaza.graphics) -> PlazaImage? {
        let scale = max(scale, 1)
        let paragraph = paragraph(text, graphics)
        let textSize = textSize(paragraph, graphics)
        let width = textSize.width + 2 * (dot + pad)
        let height = textSize.height + 2 * (dot + pad) + tailHeight
        guard let canvas = graphics.makeCanvas(width: Int((width * scale).rounded()), height: Int((height * scale).rounded()),
                                               colorSpace: .sRGB) else { return nil }
        canvas.setShouldAntialias(false)
        canvas.scale(x: scale, y: scale)
        let body = CGRect(x: 0, y: tailHeight, width: width, height: height - tailHeight)
        fillBody(body, color: ink, in: canvas)
        fillBody(body.insetBy(dx: dot, dy: dot), color: white, in: canvas)
        fillTail(centerX: (width / 2).rounded(), in: canvas)
        canvas.setShouldSmoothFonts(false)
        canvas.setFillColor(ink)
        let textRect = CGRect(origin: CGPoint(x: dot + pad, y: tailHeight + dot + pad), size: textSize)
        canvas.draw(paragraph, in: textRect)
        return canvas.makeImage()
    }

    /// 글자 영역에 실제로 그려지는 UTF-16 길이. 글자 영역이 모자라면 뒤쪽 줄이 말없이 빠지므로 테스트가 확인한다.
    static func drawnLength(of text: String, graphics: any PlazaGraphics = PlatformPlaza.graphics) -> Int {
        let paragraph = paragraph(text, graphics)
        return paragraph.visibleLength(in: textSize(paragraph, graphics))
    }

    private static func paragraph(_ text: String, _ graphics: any PlazaGraphics) -> PlazaParagraph {
        graphics.text.paragraph(text, font: .plaza(textSize), alignment: .center)
    }

    private static func textSize(_ paragraph: PlazaParagraph, _ graphics: any PlazaGraphics) -> CGSize {
        let maxTextHeight = maxTextHeight(graphics)
        let limit = CGSize(width: maxTextWidth, height: maxTextHeight)
        let fit = paragraph.suggestedSize(limit: limit)
        return CGSize(width: min(max(fit.width, 1).rounded(.up), maxTextWidth),
                      height: min(max(fit.height, 1).rounded(.up), maxTextHeight))
    }

    /// 네 귀퉁이를 한 칸씩 뺀 사각형.
    private static func fillBody(_ rect: CGRect, color: PlazaColor, in canvas: any PlazaCanvas) {
        canvas.setFillColor(color)
        canvas.fill(rect.insetBy(dx: dot, dy: 0))
        canvas.fill(rect.insetBy(dx: 0, dy: dot))
    }

    private static func fillTail(centerX: CGFloat, in canvas: any PlazaCanvas) {
        canvas.setFillColor(ink)
        canvas.fill(CGRect(x: centerX - dot * 2, y: tailHeight - dot, width: dot * 4, height: dot * 2))
        canvas.fill(CGRect(x: centerX - dot, y: 0, width: dot * 2, height: dot))
        canvas.setFillColor(white)
        canvas.fill(CGRect(x: centerX - dot, y: tailHeight - dot, width: dot * 2, height: dot * 2))
    }
}
