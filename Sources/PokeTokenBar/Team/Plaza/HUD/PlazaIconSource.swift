import Foundation

/// Where a panel gets Pokémon pictures: the roster's and the card's box icons (40x30 pixel art), the card's large
/// sprite and the egg. The Mac wraps `PlazaIconLoader` and `SpriteLoader` (`MacPlazaIcons`), the stub has nothing
/// (Windows until stage 6): a panel then draws what SwiftUI drew while a picture was missing (a grey placeholder).
/// Loads are asynchronous; a panel asks, draws a placeholder, and is told through `onArrival` when something came so
/// it can draw again. Pictures are never drawn in code.
@MainActor protocol PlazaIconSource: AnyObject {
    /// What is in memory right now, without waiting (`nil` species = the egg). Nil when it has not arrived.
    func cachedIcon(speciesID: Int?) -> PlazaImage?
    /// The box icon, loaded if needed (`nil` species = the egg). Nil when it could not be had.
    func icon(speciesID: Int?) async -> PlazaImage?
    /// The card's large character picture (the egg for a nil species; the shiny picture when `shiny`).
    func sprite(speciesID: Int?, shiny: Bool, form: PokemonForm?) async -> PlazaImage?
}

/// Nothing to load with: every picture is missing, so panels draw their placeholders.
@MainActor final class PlazaStubIconSource: PlazaIconSource {
    func cachedIcon(speciesID: Int?) -> PlazaImage? { nil }
    func icon(speciesID: Int?) async -> PlazaImage? { nil }
    func sprite(speciesID: Int?, shiny: Bool, form: PokemonForm?) async -> PlazaImage? { nil }
}

/// What a panel keeps of the pictures it asked for: the loaded ones, the ones being loaded, and a retry for a failed
/// one after `retryDelay` (SwiftUI's roster icon retried once after 5 s) and again on every appearance (`forgetFailures`). `onArrival` is
/// called on the main actor each time a picture arrives. Nothing here runs unless a panel asks for a picture, and
/// nothing polls: a picture that is not coming costs one attempt (two for an icon).
@MainActor final class PlazaPictureCache {
    enum Kind: Hashable { case icon(Int?), sprite(Int?, Bool, String) }

    private let source: any PlazaIconSource
    private var loaded: [Kind: PlazaImage] = [:]
    private var pending: Set<Kind> = []
    private var failed: Set<Kind> = []
    /// Called after a picture arrived.
    var onArrival: (() -> Void)?
    /// How long before a failed box icon is tried once more (SwiftUI: 5 s).
    var retryDelay: Duration = .seconds(5)

    init(source: any PlazaIconSource) { self.source = source }

    /// A panel (or one of its slots) appeared again: pictures that failed are tried once more the next time they are asked for. This is the
    /// whole retry rule, as SwiftUI's `.task(id:)` had it (it ran again each time a slot or the card appeared: a page turn, a new member,
    /// reopening the card, reopening the plaza); there is no timer and no loop, a picture that is not coming costs one attempt per appearance
    /// (two for a box icon: the 5-second second try).
    func forgetFailures() { failed.removeAll() }

    /// The box icon if it is here; else asks for it (once) and returns nil.
    func icon(_ speciesID: Int?) -> PlazaImage? {
        let kind = Kind.icon(speciesID)
        if let image = loaded[kind] { return image }
        if let image = source.cachedIcon(speciesID: speciesID) { loaded[kind] = image; return image }
        request(kind) { await $0.source.icon(speciesID: speciesID) }
        return nil
    }

    func sprite(_ mon: TeamMonSummary) -> PlazaImage? {
        let kind = Kind.sprite(mon.speciesID, mon.isShiny, mon.form?.rawValue ?? "")
        if let image = loaded[kind] { return image }
        request(kind) { await $0.source.sprite(speciesID: mon.speciesID, shiny: mon.isShiny, form: mon.form) }
        return nil
    }

    private func request(_ kind: Kind, _ load: @escaping @MainActor (PlazaPictureCache) async -> PlazaImage?) {
        guard !pending.contains(kind), !failed.contains(kind) else { return }
        pending.insert(kind)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var image = await load(self)
            if image == nil, case .icon = kind {
                try? await Task.sleep(for: self.retryDelay)
                if Task.isCancelled { return }
                image = await load(self)
            }
            self.pending.remove(kind)
            if let image {
                self.loaded[kind] = image
                self.onArrival?()
            } else {
                self.failed.insert(kind)
            }
        }
    }
}
