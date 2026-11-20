// Verbatim copy of the pre-Task-4 (base 98876aa) code named below, renamed. The oracle for PlazaArtParityTests;
// deleted in Task 19. Do not edit except to port a fix from main.
// Source: PlazaCharacterLoader.swift (placeholder, PlazaSpriteCrop.trimmed) and PlazaScene.lightTexture (the image).
import CoreGraphics
import Foundation
@testable import PokeTokenBar

enum LegacyPlazaCharacterArt {
    static func placeholder() -> CGImage {
        let size = 16
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
        return ctx.makeImage()!
    }

    static func trimmed(_ frames: [CGImage]) -> [CGImage] {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for img in frames {
            let w = img.width, h = img.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let data = ctx.data else { continue }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for y in 0..<h {
                for x in 0..<w where px[(y * w + x) * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return frames }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return frames.map { $0.cropping(to: rect) ?? $0 }
    }

    /// The CGImage inside PlazaScene.lightTexture (before the SKTexture is made).
    static func lightImage(tint: PlazaDaylight.Tint, radii: CGSize, color: (r: Double, g: Double, b: Double) = PlazaCampfireLight.warm,
                           level: Double = 1) -> CGImage {
        let n = PlazaCampfireLight.blockCounts(radii: radii)
        var rings: [Double: [UInt8]] = [:]
        var data = [UInt8](repeating: 255, count: n.w * n.h * 4)
        for j in 0..<n.h {
            for i in 0..<n.w {
                let k = PlazaCampfireLight.blockMix(i: i, j: j, radii: radii)
                if rings[k] == nil {
                    let m = PlazaCampfireLight.multiplier(tint: tint, mix: k * level, color: color)
                    rings[k] = [m.r, m.g, m.b].map { UInt8(min(255, max(0, ($0 / 2 * 255).rounded()))) }
                }
                let o = (j * n.w + i) * 4
                data[o] = rings[k]![0]; data[o + 1] = rings[k]![1]; data[o + 2] = rings[k]![2]
            }
        }
        return CGImage(width: n.w, height: n.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n.w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
