import Foundation

/// 모닥불·불꽃의 밤빛 그림(`PlazaScene.lightTexture`가 텍스처로 만든다). 2 세계 px당 텍셀 하나. 값은 `multiplier / 2`
/// (곱하기X2가 두 배로 되돌린다). 타원 밖은 (0.5, 0.5, 0.5)라 그대로다. 알파 바이트는 쓰지 않는 불투명 그림이다.
/// `color`와 `level`은 빛의 색과 세기로, 불꽃이 제 값을 넘긴다.
enum PlazaCampfireLightArt {
    static func image(tint: PlazaDaylight.Tint, radii: CGSize, color: (r: Double, g: Double, b: Double) = PlazaCampfireLight.warm,
                      level: Double = 1) -> PlazaImage {
        let n = PlazaCampfireLight.blockCounts(radii: radii)
        var rings: [Double: [UInt8]] = [:]
        var bitmap = PlazaBitmap(width: n.w, height: n.h, fill: PlazaRGBA(r: 255, g: 255, b: 255, a: 255))
        bitmap.alpha = .noneSkipLast
        for j in 0..<n.h {
            for i in 0..<n.w {
                let k = PlazaCampfireLight.blockMix(i: i, j: j, radii: radii)
                if rings[k] == nil {
                    let m = PlazaCampfireLight.multiplier(tint: tint, mix: k * level, color: color)
                    rings[k] = [m.r, m.g, m.b].map { UInt8(min(255, max(0, ($0 / 2 * 255).rounded()))) }
                }
                bitmap[i, j] = PlazaRGBA(r: rings[k]![0], g: rings[k]![1], b: rings[k]![2], a: 255)
            }
        }
        return PlazaImage(bitmap: bitmap)
    }
}
