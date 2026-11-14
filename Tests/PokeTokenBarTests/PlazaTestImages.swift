import Foundation
@testable import PokeTokenBar

/// Byte-built image fixtures shared by the Mac and Windows tests (no platform decoder involved).
enum PlazaTestImages {
    static func solid(width: Int, height: Int, _ color: PlazaRGBA) -> PlazaBitmap {
        PlazaBitmap(width: width, height: height, fill: color)
    }

    /// Every pixel different and valid premultiplied RGBA (colour bytes never above alpha), with fully transparent,
    /// partly transparent and opaque pixels. `alpha: .noneSkipLast` writes 255 into the padding byte.
    static func patterned(width: Int, height: Int, alpha: PlazaAlphaLayout = .premultipliedLast) -> PlazaBitmap {
        var b = PlazaBitmap(width: width, height: height)
        b.alpha = alpha
        for y in 0..<height {
            for x in 0..<width {
                let a = alpha == .noneSkipLast ? 255 : (x * 53 + y * 29) % 256
                b[x, y] = PlazaRGBA(r: UInt8((x * 7 + y * 3) % (a + 1)), g: UInt8((x * 11 + y * 13) % (a + 1)),
                                    b: UInt8((x * 17 + y * 5) % (a + 1)), a: UInt8(a))
            }
        }
        return b
    }

    /// A native image double: answers from a bitmap and counts how often its pixels were asked for.
    final class FakeNative: PlazaNativeImage, @unchecked Sendable {
        let source: PlazaBitmap
        private let lock = NSLock()
        private var calls = 0
        init(_ source: PlazaBitmap) { self.source = source }
        var width: Int { source.width }
        var height: Int { source.height }
        var pixelCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func pixels() -> PlazaBitmap {
            lock.lock(); calls += 1; lock.unlock()
            return source
        }
        func cropping(to rect: PlazaPixelRect) -> (any PlazaNativeImage)? {
            let c = source.cropped(to: rect)
            return c.width > 0 && c.height > 0 ? FakeNative(c) : nil
        }
    }
}
