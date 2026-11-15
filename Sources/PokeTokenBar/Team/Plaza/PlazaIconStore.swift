import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the PokéAPI Gen-VII box icons live and what they are called in the sprite folder. The Mac's `PlazaIconLoader`
/// and the shared `PlazaStoreIconSource` both read the URL and the cache file name from here.
enum PlazaIconStore {
    static func url(speciesID: Int) -> URL {
        URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-vii/icons/\(speciesID).png")!
    }

    /// The icon's file in the sprite cache folder (`SpriteStore.directory`).
    static func fileName(speciesID: Int) -> String { "icon-\(speciesID).png" }

    /// The body of a 200 answer; nil on any other status or on a network failure.
    static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await PlatformCompat.oneShotData(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
