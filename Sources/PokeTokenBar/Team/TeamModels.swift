import Foundation

enum TeamEventKind: String, Codable, Equatable, Sendable {
    case hatch, evolve, graduate, dittoReveal

    /// Everything except a plain evolution is a "big" moment.
    var isBig: Bool { self != .evolve }
}

/// A feed event published by a team member. Carries no usage numbers by design.
struct TeamEvent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let authorID: String
    let authorNickname: String
    let kind: TeamEventKind

    let speciesID: Int
    let fromSpeciesID: Int?
    let speciesName: String
    let fromSpeciesName: String?

    let form: PokemonForm?
    let isShiny: Bool
    let nature: PokemonNature?
    let rarity: Rarity

    /// Local calendar day, "yyyy-MM-dd".
    let day: String
    /// nil means only the date is known.
    let occurredAt: Date?
}

enum TeamReactionKind: String, Codable, Equatable, Sendable {
    case cute, lol, congrats, comment
}

struct TeamReaction: Identifiable, Codable, Equatable, Sendable {
    static let maxCommentLength = 40

    let id: String
    let eventID: String
    let authorID: String
    let authorNickname: String
    let kind: TeamReactionKind
    let text: String?
    let createdAt: Date
}

/// speciesID nil means the member is still carrying an egg.
struct TeamMonSummary: Codable, Equatable, Sendable {
    var speciesID: Int?
    var isShiny: Bool
    var form: PokemonForm?
    var speciesName: String?
}

struct TeamDexSpecies: Codable, Equatable, Sendable {
    var speciesID: Int
    var form: PokemonForm?
    var name: String
    var rarity: Rarity
    var hasShiny: Bool
    var hasNormal: Bool
}

struct TeamMemberProfile: Codable, Equatable, Sendable {
    var memberID: String
    var nickname: String
    var current: TeamMonSummary
    var dex: [TeamDexSpecies]
}

/// What CompanionStore reports: the species/individual part of a TeamEvent only.
struct CompanionTeamEvent: Equatable, Sendable {
    var kind: TeamEventKind
    var speciesID: Int
    var fromSpeciesID: Int?
    var speciesName: String
    var fromSpeciesName: String?
    var form: PokemonForm?
    var isShiny: Bool
    var nature: PokemonNature?
    var rarity: Rarity
}
