import Foundation

/// `MacPlazaIcons` over the sprite store and the platform's image decoder: box icons (`icon-<id>.png` in the sprite
/// folder, else downloaded and saved), the card's large sprite and the egg. Pictures kept this run: every box icon
/// (small, as `PlazaIconLoader` keeps them) and the cropped egg. Files, the download and decoding run off the main
/// actor. A failed icon is retried once by `PlazaPictureCache`, not here.
@MainActor final class PlazaStoreIconSource: PlazaIconSource {
    typealias Fetch = @Sendable (URL) async -> Data?

    private let source: any PlazaSpriteSource
    private let graphics: any PlazaGraphics
    private let fetch: Fetch
    private let sprites: PlazaStoreSpriteFetcher
    private var icons: [Int: PlazaImage] = [:]

    convenience init(store: SpriteStore = .shared, graphics: any PlazaGraphics = PlatformPlaza.graphics,
                     fetch: @escaping Fetch = { await PlazaIconStore.download($0) }) {
        self.init(source: store, graphics: graphics, fetch: fetch)
    }

    init(source: any PlazaSpriteSource, graphics: any PlazaGraphics = PlatformPlaza.graphics,
         fetch: @escaping Fetch = { await PlazaIconStore.download($0) },
         decodeGIF: @escaping PlazaGIFFrameDecoder = { PlazaStoreGIF.frames(from: $0) }) {
        self.source = source
        self.graphics = graphics
        self.fetch = fetch
        sprites = PlazaStoreSpriteFetcher(source: source, graphics: graphics, decodeGIF: decodeGIF)
    }

    func cachedIcon(speciesID: Int?) -> PlazaImage? {
        speciesID.map { icons[$0] } ?? sprites.cachedEgg
    }

    func icon(speciesID: Int?) async -> PlazaImage? {
        guard let id = speciesID else { return await sprites.egg() }
        if let kept = icons[id] { return kept }
        guard let image = await Self.loadIcon(speciesID: id, directory: source.directory, graphics: graphics, fetch: fetch)
        else { return nil }
        icons[id] = image
        return image
    }

    func sprite(speciesID: Int?, shiny: Bool, form: PokemonForm?) async -> PlazaImage? {
        guard let id = speciesID else { return await sprites.egg() }
        return await sprites.still(speciesID: id, shiny: shiny, form: form, back: false)
    }

    /// The cache file if it decodes, else the download (saved atomically once it decodes).
    @concurrent private static func loadIcon(speciesID: Int, directory: URL, graphics: any PlazaGraphics,
                                             fetch: Fetch) async -> PlazaImage? {
        let file = directory.appendingPathComponent(PlazaIconStore.fileName(speciesID: speciesID))
        if let cached = try? Data(contentsOf: file), let image = graphics.decodeImage(cached) { return image }
        guard let data = await fetch(PlazaIconStore.url(speciesID: speciesID)),
              let image = graphics.decodeImage(data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return image
    }
}
