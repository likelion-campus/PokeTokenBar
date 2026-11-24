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
    var gender: PokemonGender?
    /// Shown above the name in the plaza. Left out when unknown; earlier versions ignore it.
    @LossyOptional var nature: PokemonNature? = nil

    /// What a peer sent, without a name or form too long to be real, and without a species this version has no sprite for
    /// (it shows as an egg: nothing is fetched for it). The character still shows.
    var bounded: TeamMonSummary {
        var c = self
        if let id = speciesID, !PokedexRegion.nationalRange.contains(id) { c.speciesID = nil; c.speciesName = nil; c.form = nil }
        if (speciesName?.utf8.count ?? 0) > TeamWire.maxFieldBytes { c.speciesName = nil }
        if (form?.rawValue.utf8.count ?? 0) > TeamWire.maxFieldBytes { c.form = nil }
        return c
    }
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
    /// One cell per species, and one more per catalogued form of it: the most an honest dex has.
    static let maxDexEntries = PokedexRegion.nationalRange.reduce(0) { $0 + max(1, PokemonForm.entries(speciesID: $1).count) }

    var memberID: String
    var nickname: String
    var current: TeamMonSummary
    var dex: [TeamDexSpecies]

    /// What a peer sent, within what a real dex holds: a species of this version, at most `maxDexEntries` cells, and a name
    /// no longer than a field (a longer one reads as the number, as a species without a name does). The card lays out
    /// every name when it opens, so none of this is left to the card.
    var bounded: TeamMemberProfile {
        var p = self
        p.current = current.bounded
        p.dex = Array(dex.lazy.filter { PokedexRegion.nationalRange.contains($0.speciesID) }.prefix(Self.maxDexEntries).map {
            var e = $0
            if e.name.utf8.count > TeamWire.maxFieldBytes { e.name = "#\(e.speciesID)" }
            return e
        })
        return p
    }
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
