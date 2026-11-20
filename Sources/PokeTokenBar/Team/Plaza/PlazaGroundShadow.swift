import Foundation

/// 캐릭터 발밑에 깔리는 연한 타원 그림자. 월드 픽셀 단위의 또렷한 도트 타원이다.
enum PlazaGroundShadow {
    static let alpha: CGFloat = 0.30

    /// 배율을 적용한 앞모습 폭 `w`에서 `width = clamp(round(w * 0.70), 20, 140)`(짝수), `height = max(6, round(width * 0.32))`.
    static func size(forSpriteWidth w: Int) -> (width: Int, height: Int) {
        var width = min(max(Int((Double(w) * 0.70).rounded()), 20), 140)
        if width % 2 != 0 { width += 1 }
        width = min(width, 140)
        return (width, max(6, Int((Double(width) * 0.32).rounded())))
    }

    /// 가운데가 가장 진하고 가장자리로 갈수록 옅어지는 도트 타원. 월드 픽셀 해상도 그대로라 단계가 보인다.
    static func image(width: Int, height: Int) -> PlazaImage {
        var bitmap = PlazaBitmap(width: width, height: height)
        let hw = Double(width) / 2, hh = Double(height) / 2
        for y in 0..<height {
            let ny = (Double(y) + 0.5 - hh) / hh
            for x in 0..<width {
                let nx = (Double(x) + 0.5 - hw) / hw
                let d = nx * nx + ny * ny
                guard d < 1 else { continue }
                // 검정이라 미리 곱한 색은 0이다.
                bitmap.bytes[(y * width + x) * 4 + 3] = UInt8((Double(alpha) * pow(1 - d, 0.8) * 255).rounded())
            }
        }
        return PlazaImage(bitmap: bitmap)
    }
}
