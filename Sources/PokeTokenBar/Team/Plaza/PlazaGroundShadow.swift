import CoreGraphics

/// 캐릭터 발밑에 깔리는 연한 타원 그림자. 월드 픽셀 단위의 또렷한 도트 타원이다.
enum PlazaGroundShadow {
    static let alpha: CGFloat = 0.22

    /// 앞모습 폭 `w`에서 `width = clamp(round(w * 0.6), 14, 80)`(짝수), `height = max(4, round(width * 0.3))`.
    static func size(forSpriteWidth w: Int) -> (width: Int, height: Int) {
        var width = min(max(Int((Double(w) * 0.6).rounded()), 14), 80)
        if width % 2 != 0 { width += 1 }
        width = min(width, 80)
        return (width, max(4, Int((Double(width) * 0.3).rounded())))
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
