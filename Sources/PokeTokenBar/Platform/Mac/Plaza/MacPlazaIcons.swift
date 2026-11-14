import AppKit

/// The Mac's `PlazaIconSource` (Track A Task 17c): `PlazaIconLoader` for the box icons and `SpriteLoader` for the card's
/// sprite and the egg, handed on as `PlazaImage`s wrapping the very `CGImage` of the `NSImage` the SwiftUI views drew.
@MainActor final class MacPlazaIcons: PlazaIconSource {
    func cachedIcon(speciesID: Int?) -> PlazaImage? {
        Self.plazaImage(speciesID.map { PlazaIconLoader.cachedIcon(speciesID: $0) } ?? SpriteLoader.cachedEggImage())
    }

    func icon(speciesID: Int?) async -> PlazaImage? {
        if let id = speciesID { return Self.plazaImage(await PlazaIconLoader.icon(speciesID: id)) }
        return Self.plazaImage(await SpriteLoader.eggImage())
    }

    func sprite(speciesID: Int?, shiny: Bool, form: PokemonForm?) async -> PlazaImage? {
        guard let id = speciesID else { return Self.plazaImage(await SpriteLoader.eggImage()) }
        return Self.plazaImage(await SpriteLoader.image(speciesID: id, shiny: shiny, form: form))
    }

    private static func plazaImage(_ image: NSImage?) -> PlazaImage? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(PlazaImage.init(cgImage:))
    }
}
