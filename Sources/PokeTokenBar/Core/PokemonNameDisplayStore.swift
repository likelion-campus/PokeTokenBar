import Foundation
import Observation

/// Synchronous presentation snapshot: reopening a detail starts with the last translated names.
/// The API client still owns disk caching, request deduplication, and freshness checks.
@MainActor @Observable
final class PokemonNameDisplayStore {
    static let shared = PokemonNameDisplayStore()
    private(set) var names: [PokemonNameResource: [String: String]] = [:]

    func load(_ resource: PokemonNameResource, provider: any PokemonNameProviding) async -> Bool {
        do {
            let translations = try await provider.names(for: resource)
            guard !Task.isCancelled else { return false }
            names[resource] = translations
            return true
        } catch {
            return false
        }
    }
}
