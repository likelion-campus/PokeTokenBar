import Foundation

struct PlazaFrame: @unchecked Sendable {
    let image: PlazaImage
    let delay: TimeInterval
}

/// 광장 캐릭터의 앞·뒤 프레임. 둘 다 비어 있지 않다.
struct PlazaCharacterFrames: Sendable {
    let front: [PlazaFrame]
    let back: [PlazaFrame]
    /// True when nothing could be fetched and the grey circle stands in. A later request may succeed.
    var isPlaceholder = false
    /// True when no back picture came and the front stands in. It may not exist at all, so retries are limited.
    var backIsFront = false
    /// 알이면 발밑에 그림자 대신 둥지를 깐다.
    var isEgg = false
}

/// 스프라이트를 가져오는 쪽(Mac은 `SpriteLoader`/`SpriteStore`, `MacSpriteFetcher.swift`)이 메인 액터라 이미지가 격리 경계를 넘지 않는다.
@MainActor
protocol PlazaSpriteFetching: Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)]
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage?
    func egg() async -> PlazaImage?
}

/// Nothing to fetch with (Windows until stage 6, and the Mac checking the shared set): every character gets the grey
/// placeholder. Logs one line on first use.
struct PlazaStubSpriteFetcher: PlazaSpriteFetching {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; let was = done; done = true; return !was }
    }
    private let once = Once()
    let log: @Sendable (String) -> Void

    private func fire() { if once.first() { log("Plaza stub: sprite fetching unavailable") } }
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        fire(); return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { fire(); return nil }
    func egg() async -> PlazaImage? { fire(); return nil }
}

@MainActor
final class PlazaCharacterLoader {
    private let fetcher: PlazaSpriteFetching

    init(fetcher: PlazaSpriteFetching = PlatformPlaza.spriteFetcher()) {
        self.fetcher = fetcher
    }

    func frames(for subject: CompanionStore.RepresentativeSubject) async -> PlazaCharacterFrames {
        let placeholder = [PlazaFrame(image: Self.placeholder(), delay: 0.1)]
        guard let id = subject.speciesID else {
            let egg = await eggFrames()
            let both = egg.isEmpty ? placeholder : egg
            return PlazaCharacterFrames(front: both, back: both, isPlaceholder: egg.isEmpty, isEgg: true)
        }
        let front = await direction(id, subject, back: false)
        let back = await direction(id, subject, back: true)
        let shownFront = front.isEmpty ? placeholder : front
        return PlazaCharacterFrames(front: shownFront, back: back.isEmpty ? shownFront : back,
                                    isPlaceholder: front.isEmpty, backIsFront: !front.isEmpty && back.isEmpty)
    }

    /// 한 방향의 프레임. 이로치 → 일반 순서로, 각각 움직이는 그림 → 정지 그림.
    private func direction(_ id: Int, _ subject: CompanionStore.RepresentativeSubject, back: Bool) async -> [PlazaFrame] {
        for shiny in subject.isShiny ? [true, false] : [false] {
            if PokemonAssets.hasAnimatedSprite(speciesID: id) {
                let anim = await fetcher.animated(speciesID: id, shiny: shiny, form: subject.form, back: back)
                if !anim.isEmpty {
                    let trimmed = PlazaSpriteCrop.trimmed(anim.map { $0.image })
                    return zip(trimmed, anim).map { PlazaFrame(image: $0, delay: $1.delay) }
                }
            }
            if let img = await fetcher.still(speciesID: id, shiny: shiny, form: subject.form, back: back) {
                return PlazaSpriteCrop.trimmed([img]).map { PlazaFrame(image: $0, delay: 0.1) }
            }
        }
        return []
    }

    private func eggFrames() async -> [PlazaFrame] {
        guard let img = await fetcher.egg() else { return [] }
        return PlazaSpriteCrop.trimmed([img]).map { PlazaFrame(image: $0, delay: 0.1) }
    }

    /// 그림을 못 받았을 때 코드로 그리는 회색 동그라미. 장치 RGB 캔버스에 장치 회색(0.55)으로 칠한다.
    /// Windows 스텁 캔버스에서는 투명한 16x16이다(그리는 쪽은 stage 6).
    private static func placeholder() -> PlazaImage {
        let size = 16
        let canvas = PlatformPlaza.graphics.makeCanvas(width: size, height: size, colorSpace: .deviceRGB)!
        canvas.setFillGray(0.55)
        canvas.fillEllipse(in: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
        return canvas.makeImage()!
    }
}

enum PlazaSpriteCrop {
    /// 모든 프레임의 불투명 픽셀을 합친 경계로 똑같이 잘라 발 위치가 프레임마다 흔들리지 않게 한다.
    static func trimmed(_ frames: [PlazaImage]) -> [PlazaImage] {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for img in frames {
            let w = img.width, h = img.height
            let px = img.pixels.bytes
            // 버퍼의 0번 행이 이미지의 맨 위다.
            for y in 0..<h {
                for x in 0..<w where px[(y * w + x) * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return frames }
        let rect = PlazaPixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return frames.map { $0.cropping(to: rect) ?? $0 }
    }
}
