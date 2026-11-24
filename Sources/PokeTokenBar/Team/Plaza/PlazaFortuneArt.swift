import Foundation

/// 포춘쿠키 그림. 쿠키는 번들 그림(`plaza-fortune-cookie.png`, CC0) 하나이고, 모양은 그대로 두고 다섯 색만 지도 타일 시트의
/// 색으로 바꾼다. 쪼개진 쿠키는 같은 그림을 가운데에서 둘로 자른 것이다. 쪽지는 말풍선처럼 앱이 그리는 판이다.
enum PlazaFortuneArt {
    /// 머리 위에 뜨는 그림의 단계. `split` 은 1...`splitSteps`: 쿠키가 벌어지고 쪽지가 그만큼 펴진다.
    enum Stage: Hashable, Sendable { case whole, split(Int), open }
    static let splitSteps = 4

    /// 번들 그림(16×16) 안에서 쿠키가 차지하는 영역.
    static let cookieCrop = PlazaPixelRect(x: 2, y: 4, width: 12, height: 10)
    /// 쿠키의 다섯 색 → 지도 타일 시트의 색(윤곽 둘, 밝은 면 둘, 어두운 면). 새 모양은 없다.
    static let swaps: [(from: PlazaRGBA, to: PlazaRGBA)] = [
        (rgb(90, 73, 39), rgb(86, 58, 63)), (rgb(74, 50, 32), rgb(48, 38, 57)),
        (rgb(218, 202, 129), rgb(224, 208, 120)), (rgb(231, 218, 168), rgb(224, 208, 120)),
        (rgb(200, 158, 86), rgb(200, 176, 96)),
    ]
    /// 지도 타일 시트의 물건 그림자(반투명, 미리 곱한 값).
    static let shadow = PlazaRGBA(r: 13, g: 9, b: 16, a: 102)

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> PlazaRGBA { PlazaRGBA(r: r, g: g, b: b, a: 255) }

    /// 지도 색으로 바꾼 쿠키(12×10). 그림을 못 읽으면 nil.
    static let cookie: PlazaBitmap? = {
        guard let image = PlatformPlaza.graphics.assetURL(PlazaResources.fortuneCookieName, ext: "png")
            .flatMap({ PlatformPlaza.graphics.decodeImage(at: $0) }) else { return nil }
        return recoloured(image.pixels.cropped(to: cookieCrop))
    }()

    static func recoloured(_ source: PlazaBitmap) -> PlazaBitmap {
        var out = source
        for y in 0..<out.height {
            for x in 0..<out.width {
                if let swap = swaps.first(where: { $0.from == out[x, y] }) { out[x, y] = swap.to }
            }
        }
        return out
    }

    static func flipped(_ source: PlazaBitmap) -> PlazaBitmap {
        var out = source
        for y in 0..<out.height { for x in 0..<out.width { out[x, y] = source[source.width - 1 - x, y] } }
        return out
    }

    /// 가판대에 올리는 쿠키 더미: 쿠키 다섯 개를 겹친 것(아래 셋, 위 둘)과, 그 모양대로 깔리는 그림자.
    static func pile(of cookie: PlazaBitmap) -> (art: PlazaBitmap, shadow: PlazaBitmap) {
        var art = PlazaBitmap(width: 29, height: 18)
        let mirror = flipped(cookie)
        for (dx, dy, isFlipped) in [(0, 6, false), (17, 6, true), (8, 8, false), (4, 0, true), (13, 0, false)] {
            let source = isFlipped ? mirror : cookie
            for y in 0..<source.height {
                for x in 0..<source.width where source[x, y].a != 0 { art[dx + x, dy + y] = source[x, y] }
            }
        }
        var under = PlazaBitmap(width: art.width, height: art.height)
        for y in 0..<art.height { for x in 0..<art.width where art[x, y].a != 0 { under[x, y] = shadow } }
        return (art, under)
    }

    // 머리 위 그림의 치수(포인트).
    /// 쿠키 그림 1픽셀의 크기. 폭탄과 같다.
    static let px: CGFloat = 3
    private static let dot: CGFloat = 2
    private static let pad: CGFloat = 5
    private static let band: CGFloat = 4          // 쪽지 양 끝의 붉은 띠
    private static let bandInset: CGFloat = 4
    private static let side: CGFloat = 34         // 쪽지 양옆에 쿠키 조각이 놓일 자리
    private static let shadowOffset: CGFloat = 4
    private static let lineGap: CGFloat = 2
    /// 쪽지 한 줄의 최대 너비. 운세의 모든 줄과 행운의 행동이 이 안에 들어간다.
    static let maxTextWidth: CGFloat = 250
    private static let textSize = PlazaTextSize.body
    private static let ink = PlazaColor(srgbRed: 48 / 255, green: 38 / 255, blue: 57 / 255, alpha: 1)
    private static let paper = PlazaColor(srgbRed: 240 / 255, green: 232 / 255, blue: 208 / 255, alpha: 1)
    private static let red = PlazaColor(srgbRed: 178 / 255, green: 62 / 255, blue: 52 / 255, alpha: 1)
    private static let shade = PlazaColor(srgbRed: 32 / 255, green: 23 / 255, blue: 41 / 255, alpha: 0.4)

    /// 한 줄의 글이 차지하는 너비(포인트). 테스트가 모든 문구에 대해 `maxTextWidth` 이하인지 확인한다.
    static func textWidth(_ text: String, graphics: any PlazaGraphics = PlatformPlaza.graphics) -> CGFloat {
        graphics.text.line(text, font: .plaza(textSize)).width
    }

    /// 운세가 쪽지에서 차지하는 줄. 문구 안의 줄바꿈으로 나눈다(한 줄 또는 두 줄).
    static func rows(_ line: String) -> [String] { line.split(separator: "\n").map(String.init) }

    /// 머리 위에 뜨는 그림 한 장. `text` 는 다 펴진 쪽지(`open`)에만 쓰지만 크기를 정하므로 늘 받는다. `scale` 은 포인트당 기기 픽셀 수.
    static func image(_ stage: Stage, line: String, action: String, scale: CGFloat, withCookie: Bool = true,
                      graphics: any PlazaGraphics = PlatformPlaza.graphics) -> PlazaImage? {
        guard let cookie else { return nil }
        let scale = max(scale, 1)
        let font = graphics.text.metrics(.plaza(textSize))
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let rows = Self.rows(line)
        let textWidth = min((rows + [action]).map { Self.textWidth($0, graphics: graphics) }.max()!.rounded(.up), maxTextWidth)
        let fullWidth = textWidth + 2 * (dot + bandInset + band + pad)
        let slipHeight = CGFloat(rows.count + 1) * lineHeight + CGFloat(rows.count) * lineGap + 2 * (dot + pad)
        let cookieSize = CGSize(width: CGFloat(cookie.width) * px, height: CGFloat(cookie.height) * px)
        let height = slipHeight + shadowOffset

        let slipWidth: CGFloat, tilt: CGFloat
        switch stage {
        case .whole: slipWidth = 0; tilt = 0
        case .split(let step):
            let k = CGFloat(min(max(step, 1), splitSteps))
            slipWidth = (fullWidth * k / CGFloat(splitSteps + 1) / 2).rounded() * 2
            tilt = (8 + 4 * k) * .pi / 180
        case .open: slipWidth = fullWidth; tilt = 24 * .pi / 180
        }
        let width = stage == .whole ? cookieSize.width : slipWidth + 2 * side
        guard let canvas = graphics.makeCanvas(width: Int((width * scale).rounded()), height: Int((height * scale).rounded()),
                                               colorSpace: .sRGB) else { return nil }
        canvas.setShouldAntialias(false)
        canvas.setInterpolationNone()
        canvas.scale(x: scale, y: scale)
        let middle = shadowOffset + slipHeight / 2
        if stage == .whole {
            canvas.draw(PlazaImage(bitmap: cookie), in: CGRect(x: 0, y: (middle - cookieSize.height / 2).rounded(), width: cookieSize.width, height: cookieSize.height))
            return canvas.makeImage()
        }
        // 쪽지: 그림자, 테두리, 종이, 붉은 띠.
        let slip = CGRect(x: side, y: shadowOffset, width: slipWidth, height: slipHeight)
        canvas.setFillColor(shade)
        canvas.fill(slip.offsetBy(dx: shadowOffset, dy: -shadowOffset))
        canvas.setFillColor(ink)
        canvas.fill(slip)
        canvas.setFillColor(paper)
        canvas.fill(slip.insetBy(dx: dot, dy: dot))
        if slipWidth >= 2 * (dot + bandInset + band) + 8 {
            canvas.setFillColor(red)
            canvas.fill(CGRect(x: slip.minX + dot + bandInset, y: slip.minY + dot, width: band, height: slipHeight - 2 * dot))
            canvas.fill(CGRect(x: slip.maxX - dot - bandInset - band, y: slip.minY + dot, width: band, height: slipHeight - 2 * dot))
        }
        if stage == .open {
            canvas.setShouldSmoothFonts(false)
            let textX = slip.minX + dot + bandInset + band + pad
            canvas.setFillColor(ink)
            for (i, row) in rows.enumerated() {   // 위에서부터, 행운의 행동 위에 쌓는다
                canvas.draw(graphics.text.paragraph(row, font: .plaza(textSize), alignment: .center),
                            in: CGRect(x: textX, y: slip.minY + dot + pad + CGFloat(rows.count - i) * (lineHeight + lineGap), width: textWidth, height: lineHeight))
            }
            canvas.setFillColor(red)
            canvas.draw(graphics.text.paragraph(action, font: .plaza(textSize), alignment: .center),
                        in: CGRect(x: textX, y: slip.minY + dot + pad, width: textWidth, height: lineHeight))
        }
        guard withCookie else { return canvas.makeImage() }
        // 쿠키 조각: 쪽지 양 끝 바깥에서 바깥쪽으로 기운다.
        let half = cookie.width / 2
        let halfSize = CGSize(width: CGFloat(half) * px, height: cookieSize.height)
        let pieces: [(PlazaBitmap, CGFloat, CGFloat)] = [
            (cookie.cropped(to: PlazaPixelRect(x: 0, y: 0, width: half, height: cookie.height)), slip.minX - 15, tilt),
            (cookie.cropped(to: PlazaPixelRect(x: half, y: 0, width: cookie.width - half, height: cookie.height)), slip.maxX + 15, -tilt),
        ]
        for (bitmap, x, angle) in pieces {
            canvas.saveState()
            canvas.translate(x: x, y: middle)
            canvas.rotate(by: angle)
            canvas.draw(PlazaImage(bitmap: bitmap), in: CGRect(x: -halfSize.width / 2, y: -halfSize.height / 2, width: halfSize.width, height: halfSize.height))
            canvas.restoreState()
        }
        return canvas.makeImage()
    }
}
