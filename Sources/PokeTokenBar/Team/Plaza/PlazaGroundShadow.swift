import CoreGraphics

/// 캐릭터 발밑에 깔리는 연한 타원 그림자. 월드 픽셀 단위의 또렷한 도트 타원이다.
enum PlazaGroundShadow {
    static let alpha: CGFloat = 0.22

    /// 배율을 적용한 앞모습 폭 `w`에서 `width = clamp(round(w * 0.85), 20, 140)`(짝수), `height = max(6, round(width * 0.32))`.
    static func size(forSpriteWidth w: Int) -> (width: Int, height: Int) {
        var width = min(max(Int((Double(w) * 0.85).rounded()), 20), 140)
        if width % 2 != 0 { width += 1 }
        width = min(width, 140)
        return (width, max(6, Int((Double(width) * 0.32).rounded())))
    }

    static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.setAllowsAntialiasing(false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
