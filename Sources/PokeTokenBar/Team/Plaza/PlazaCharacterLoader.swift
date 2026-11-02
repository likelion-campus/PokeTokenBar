import AppKit
import CoreGraphics

struct PlazaFrame: @unchecked Sendable {
    let image: CGImage
    let delay: TimeInterval
}

/// 광장 캐릭터의 앞·뒤 프레임. 둘 다 비어 있지 않다.
struct PlazaCharacterFrames: Sendable {
    let front: [PlazaFrame]
    let back: [PlazaFrame]
    /// True when nothing could be fetched and the grey circle stands in. A later request may succeed.
    var isPlaceholder = false
}

/// `SpriteLoader`와 호출부가 모두 메인 액터라 `NSImage`가 격리 경계를 넘지 않는다.
@MainActor
protocol PlazaSpriteFetching: Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)]
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage?
    func egg() async -> NSImage?
}

/// `SpriteLoader`에 위임하는 얇은 어댑터. 네트워크를 타므로 단위 테스트하지 않는다.
struct LivePlazaSpriteFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)] {
        await SpriteLoader.animationFrames(speciesID: speciesID, shiny: shiny, form: form, back: back)
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage? {
        await SpriteLoader.image(speciesID: speciesID, animated: false, shiny: shiny, form: form, back: back)
    }
    func egg() async -> NSImage? { await SpriteLoader.eggImage() }
}

@MainActor
final class PlazaCharacterLoader {
    private let fetcher: PlazaSpriteFetching

    init(fetcher: PlazaSpriteFetching = LivePlazaSpriteFetcher()) {
        self.fetcher = fetcher
    }

    func frames(for subject: CompanionStore.RepresentativeSubject) async -> PlazaCharacterFrames {
        let placeholder = [PlazaFrame(image: Self.placeholder(), delay: 0.1)]
        guard let id = subject.speciesID else {
            let egg = await eggFrames()
            let both = egg.isEmpty ? placeholder : egg
            return PlazaCharacterFrames(front: both, back: both, isPlaceholder: egg.isEmpty)
        }
        let front = await direction(id, subject, back: false)
        let back = await direction(id, subject, back: true)
        let shownFront = front.isEmpty ? placeholder : front
        return PlazaCharacterFrames(front: shownFront, back: back.isEmpty ? shownFront : back,
                                    isPlaceholder: front.isEmpty)
    }

    /// 한 방향의 프레임. 이로치 → 일반 순서로, 각각 움직이는 그림 → 정지 그림.
    private func direction(_ id: Int, _ subject: CompanionStore.RepresentativeSubject, back: Bool) async -> [PlazaFrame] {
        for shiny in subject.isShiny ? [true, false] : [false] {
            if PokemonAssets.hasAnimatedSprite(speciesID: id) {
                let anim = await fetcher.animated(speciesID: id, shiny: shiny, form: subject.form, back: back)
                let cgs = anim.compactMap { f in Self.cgImage(f.image).map { ($0, f.delay) } }
                if !cgs.isEmpty {
                    let trimmed = PlazaSpriteCrop.trimmed(cgs.map { $0.0 })
                    return zip(trimmed, cgs).map { PlazaFrame(image: $0, delay: $1.1) }
                }
            }
            if let img = await fetcher.still(speciesID: id, shiny: shiny, form: subject.form, back: back),
               let cg = Self.cgImage(img) {
                return PlazaSpriteCrop.trimmed([cg]).map { PlazaFrame(image: $0, delay: 0.1) }
            }
        }
        return []
    }

    private func eggFrames() async -> [PlazaFrame] {
        guard let img = await fetcher.egg(), let cg = Self.cgImage(img) else { return [] }
        return PlazaSpriteCrop.trimmed([cg]).map { PlazaFrame(image: $0, delay: 0.1) }
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 그림을 못 받았을 때 코드로 그리는 회색 동그라미.
    private static func placeholder() -> CGImage {
        let size = 16
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
        return ctx.makeImage()!
    }
}

enum PlazaSpriteCrop {
    /// 모든 프레임의 불투명 픽셀을 합친 경계로 똑같이 잘라 발 위치가 프레임마다 흔들리지 않게 한다.
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
            // 버퍼의 0번 행이 이미지의 맨 위다.
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
}
