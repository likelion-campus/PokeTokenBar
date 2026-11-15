import AppKit
import ImageIO
import SpriteKit
@testable import PokeTokenBar

// The Mac-only parts of the harness scenes: the CGImage form of the fixture bytes (the Mac oracles use it) and the
// `real-sprites` scene, which reads the maintainer's cached GIFs (never committed).
extension PlazaRenderScenes {
    /// Raw premultiplied RGBA bytes -> CGImage through a `CGDataProvider`, the construction `PlazaImage(bitmap:)` uses.
    static func image(_ rgba: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: Real sprites

    static var spritesDir: URL? { PlazaRenderEnv.value("PTB_PLAZA_RENDER_SPRITES").map { URL(fileURLWithPath: $0) } }
    static let realSpecies = [25, 6, 150, 94, 133]

    private static func gif(_ url: URL) -> [PlazaFrame]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var out: [PlazaFrame] = []
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gifProps = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gifProps?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gifProps?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            out.append(PlazaFrame(image: PlazaImage(cgImage: image), delay: max(delay, 0.02)))
        }
        return out.isEmpty ? nil : out
    }

    static func realFrames(_ id: Int) -> PlazaCharacterFrames? {
        guard let dir = spritesDir, let front = gif(dir.appendingPathComponent("\(id)-a.gif")) else { return nil }
        let back = gif(dir.appendingPathComponent("\(id)-ba.gif"))
        var f = PlazaCharacterFrames(front: front, back: back ?? front)
        f.backIsFront = back == nil
        return f
    }

    /// Installs the Mac-only hooks (the real-sprite loader and the `real-sprites` scene). Idempotent; the harness tests call it
    /// before reading `PlazaRenderScenes.all`.
    static func installMacHooks() {
        realFramesProvider = { realFrames($0) }
        realSpritesScene = {
            guard spritesDir != nil, realFrames(realSpecies[0]) != nil else { return nil }
            return PlazaRenderScene(name: "real-sprites", viewport: viewport, backing: 2, captures: [10, 30]) { st in
                var o = Options(); o.me = TilePoint(x: 10, y: 12); o.meLook = .real(realSpecies[0])
                let s = stage(o, on: st)
                s.put([member("a", "A", 12, 12), member("b", "B", 8, 14), member("c", "C", 13, 10), member("d", "D", 7, 12)],
                      looks: ["a": .real(realSpecies[1]), "b": .real(realSpecies[2]), "c": .real(realSpecies[3]), "d": .real(realSpecies[4])])
                return setup(s, photo: true) { f in
                    if f == 1 { press(s, 2); _ = s.scene.playDance(memberID: "a", style: "sway") }
                    if f == 2 { s.move("b", to: TilePoint(x: 9, y: 14), walking: true) }
                }
            }
        }
    }
}
