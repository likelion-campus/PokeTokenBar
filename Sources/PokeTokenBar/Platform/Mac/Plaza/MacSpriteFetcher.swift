import AppKit

/// `SpriteLoader`에 위임하는 얇은 어댑터. 네트워크를 타므로 단위 테스트하지 않는다.
/// (Moved from `PlazaCharacterLoader.swift`; the fetch logic is unchanged, the `NSImage`s it gets are handed on as
/// `PlazaImage`s wrapping the very `CGImage` `cgImage(forProposedRect:)` gives, as the loader read them before.)
///
/// 뒷모습만은 `SpriteStore`에서 직접 받는다. `SpriteLoader`는 뒷모습이 없으면 앞모습을 대신 돌려주는데,
/// 광장은 뒷모습이 오지 않았다는 사실(`PlazaCharacterFrames.backIsFront`)을 알아야 다시 시도한다.
struct LivePlazaSpriteFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        guard back else {
            return Self.plazaFrames(await SpriteLoader.animationFrames(speciesID: speciesID, shiny: shiny, form: form))
        }
        for variant in shiny ? [true, false] : [false] {
            guard let data = await SpriteStore.shared.data(speciesID: speciesID, animated: true, shiny: variant,
                                                           form: form, back: true) else { continue }
            let frames = GIFDecoder.frames(from: data)
            if !frames.isEmpty { return Self.plazaFrames(frames) }
        }
        return []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        guard back else {
            return Self.plazaImage(await SpriteLoader.image(speciesID: speciesID, animated: false, shiny: shiny, form: form))
        }
        for variant in shiny ? [true, false] : [false] {
            guard let data = await SpriteStore.shared.data(speciesID: speciesID, animated: false, shiny: variant,
                                                           form: form, back: true) else { continue }
            if let image = NSImage(data: data) { return Self.plazaImage(image) }
        }
        return nil
    }
    func egg() async -> PlazaImage? { Self.plazaImage(await SpriteLoader.eggImage()) }

    /// The loader dropped frames with no `CGImage`; so does this.
    private static func plazaImage(_ image: NSImage?) -> PlazaImage? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(PlazaImage.init(cgImage:))
    }

    private static func plazaFrames(_ frames: [(image: NSImage, delay: TimeInterval)]) -> [(image: PlazaImage, delay: TimeInterval)] {
        frames.compactMap { f in plazaImage(f.image).map { ($0, f.delay) } }
    }
}
