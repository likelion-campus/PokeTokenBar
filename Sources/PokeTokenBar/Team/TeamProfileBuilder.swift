import Foundation

/// Builds the profile a teammate sees when they open my card. Carries species and dex facts only,
/// never usage, cost or growth progress.
enum TeamProfileBuilder {
    static func profile(memberID: String, nickname: String, state: CompanionState,
                        dexSpecies: [CompanionStore.DexSpecies],
                        speciesName: (Int) -> String?) -> TeamMemberProfile {
        let current: TeamMonSummary
        if let active = state.active {
            // A disguised Ditto goes out as its disguise; `displaysShiny` already hides its shine.
            let id = active.currentID
            current = TeamMonSummary(speciesID: id, isShiny: active.displaysShiny,
                                     form: PokemonForm.resolved(speciesID: id, form: active.form),
                                     speciesName: speciesName(id), gender: active.profile?.gender)
        } else {
            current = TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        }
        let dex = dexSpecies.map {
            TeamDexSpecies(speciesID: $0.id, form: $0.form, name: $0.name, rarity: $0.rarity,
                           hasShiny: $0.isShiny, hasNormal: $0.hasNormal)
        }
        return TeamMemberProfile(memberID: memberID, nickname: nickname, current: current, dex: dex)
    }
}
