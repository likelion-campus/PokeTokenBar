import Foundation

// MARK: Task 21 — the Pokémon detail page as values (the Mac's `PokemonDetailView`, UI/CompanionView.swift)

/// What the detail page keeps while it is open: the Mac's three `@State`s.
struct DexDetailState: Equatable {
    var selectedInstanceID = ""
    var selectedForm: PokemonForm?
    var selectedShiny: Bool?
}

/// The derived members of `PokemonDetailView` (which form, which appearance, which individual), copied verbatim from the Mac view
/// so a body reads as the Mac's (twins.txt pins each member; `DexDetailTests` drives the rules). The stored values are the view's.
@MainActor
struct DexDetailResolver {
    let store: CompanionStore
    let species: CompanionStore.DexSpecies
    var selectedInstanceID = ""
    var selectedForm: PokemonForm?
    var selectedShiny: Bool?

    init(store: CompanionStore, species: CompanionStore.DexSpecies, state: DexDetailState = DexDetailState()) {
        self.store = store
        self.species = species
        selectedInstanceID = state.selectedInstanceID
        selectedForm = state.selectedForm
        selectedShiny = state.selectedShiny
    }

    var formSpecies: [CompanionStore.DexSpecies] {
        store.formSpecies(speciesID: species.id)
    }

    var displayedSpecies: CompanionStore.DexSpecies {
        let forms = formSpecies
        return forms.first { $0.form == selectedForm }
            ?? forms.first { store.isRepresentative($0) }
            ?? forms.first ?? species
    }

    var allIndividuals: [DexEntry] {
        store.pokemonIndividuals(speciesID: species.id, form: displayedSpecies.form)
    }
    var displayedShiny: Bool {
        if let selectedShiny,
           selectedShiny ? displayedSpecies.isShiny : displayedSpecies.hasNormal { return selectedShiny }
        return allIndividuals.first?.isShiny ?? displayedSpecies.isShiny
    }
    var individuals: [DexEntry] {
        allIndividuals.filter { $0.isShiny == displayedShiny }
    }
    var individual: DexEntry? {
        individuals.first { $0.id == selectedInstanceID } ?? individuals.first
    }

    func individualLabel(_ entry: DexEntry, index: Int) -> String {
        let appearance = entry.isShiny ? "✨ \(store.l.dexShinyLabel)" : store.l.dexNormalLabel
        let date = entry.caughtAt.map {
            $0.formatted(Date.FormatStyle(date: .numeric, time: .omitted)
                .locale(Locale(identifier: store.language.rawValue)))
        } ?? (store.isActiveDexEntry(entry) ? store.l.dexRaising : "—")
        return "#\(index + 1) · \(appearance) · Lv. \(entry.profile?.level ?? 5) · \(date)"
    }

    /// Unown's 28 letters fill seven columns; named forms get wider cells for their labels. Twin of the Mac's static.
    static func formPickerColumns(formCount: Int) -> Int {
        formCount > 8 ? (formCount > 20 ? 7 : 6) : min(formCount, 4)
    }
}

/// The page's values. Every text is final (names resolved through the shared `PopoverNameText`: "…" while loading).
struct DexDetailModel: Equatable {
    struct FormCell: Equatable {
        var form: PokemonForm
        var label: String
        var owned: Bool
        var isShiny: Bool
        var isRepresentative: Bool
        var isSelected: Bool
        var accessibleName: String
        /// "Not collected" / "Shiny" / "".
        var accessibleValue: String
    }
    struct Forms: Equatable {
        var title: String
        var columns: Int
        var cells: [FormCell]
        var speciesID: Int
    }
    struct Appearance: Equatable {
        var title: String
        var normal: String
        var shiny: String
        var isShiny: Bool
    }
    struct Identity: Equatable {
        var speciesID: Int
        var shinySprite: Bool
        var form: PokemonForm?
        var name: String
        var rarity: String
        var types: [TypeBadge]
        var formNote: String?
        var shinyLine: String?
        var raising: String?
        var repTitle: String
        var isRepresentative: Bool
        var repForm: PokemonForm?
    }
    struct TypeBadge: Equatable {
        var text: String
        var tint: PopoverBadgeTint
    }
    struct IndividualChoice: Equatable {
        var id: String
        var label: String
        var selected: Bool
    }
    struct Pair: Equatable {
        var label: String
        var value: String
    }
    struct Stat: Equatable {
        var label: String
        var value: Int
        var iv: Int?
    }
    struct Move: Equatable {
        var key: String
        var name: String
        var detail: String
    }
    struct Individual: Equatable {
        var title: String
        var pairs: [Pair]
        var prayer: String?
        var prayerNote: String?
        var abilityLabel: String
        var ability: String
        var statsTitle: String
        var stats: [Stat]
        var scaleMaximum: Int
        var movesTitle: String
        var moves: [Move]
        var noMoves: String?
    }
    struct BaseStats: Equatable {
        var title: String
        var stats: [Stat]
        var scaleMaximum: Int
    }
    struct Species: Equatable {
        var title: String
        var pairs: [Pair]
        var abilitiesTitle: String
        var abilities: String
    }
    struct MoveList: Equatable {
        var title: String
        var moves: [Move]
    }
    enum Content: Equatable {
        case details(individual: Individual?, base: BaseStats?, species: Species, moves: MoveList)
        case unavailable(text: String, retry: String)
        case loading(text: String)
    }

    var back: String
    var idText: String
    var forms: Forms?
    var appearance: Appearance?
    var identity: Identity
    var individualPicker: [IndividualChoice]
    var individualPickerTitle: String
    var preview: String?
    var content: Content
    /// The name resources the page shows, most important first (types, abilities, then the moves): what the host loads.
    var nameResources: [PokemonNameResource]
    /// The resolver's picks (the host keeps them as the page's state).
    var selectedForm: PokemonForm?
    var selectedInstanceID: String

    @MainActor
    static func make(store: CompanionStore, species: CompanionStore.DexSpecies, state: DexDetailState,
                     names: [PokemonNameResource: [String: String]], failed: Set<PokemonNameResource>) -> DexDetailModel {
        var r = DexDetailResolver(store: store, species: species, state: state)
        // `.task`: the first form and the first individual are picked once.
        if r.selectedForm == nil { r.selectedForm = r.displayedSpecies.form }
        if r.selectedInstanceID.isEmpty { r.selectedInstanceID = r.individuals.first?.id ?? "" }
        let l = store.l
        let language = store.language
        func name(_ kind: PokemonNameResource.Kind, _ raw: String, suffix: String = "") -> String {
            PopoverNameText(items: [PopoverNameItem(resource: .init(kind: kind, name: raw), suffix: suffix)], language: language, names: names, failed: failed).text
        }
        let shown = r.displayedSpecies
        let displayedShiny = r.displayedShiny
        let individuals = r.individuals
        let individual = r.individual
        var resources: [PokemonNameResource] = []
        // forms
        var forms: Forms?
        if PokemonForm.hasForms(speciesID: species.id) {
            let owned = r.formSpecies
            let all = PokemonForm.forms(speciesID: species.id)
            let selected = shown.form
            forms = Forms(title: l.formsCollected(owned.count, of: all.count),
                          columns: DexDetailResolver.formPickerColumns(formCount: all.count),
                          cells: all.map { form in
                              let o = owned.first { $0.form == form }
                              let label = PokemonForm.label(speciesID: species.id, form: form, language: language) ?? ""
                              return FormCell(form: form, label: label, owned: o != nil, isShiny: o?.isShiny == true,
                                              isRepresentative: o.map { store.isRepresentative($0) } == true, isSelected: selected == form,
                                              accessibleName: "\(species.name) [\(label)]",
                                              accessibleValue: o == nil ? l.formNotCollected : (o?.isShiny == true ? l.dexShinyLabel : ""))
                          }, speciesID: species.id)
        }
        let appearance = shown.hasNormal && shown.isShiny
            ? Appearance(title: l.dexAppearance, normal: l.dexNormalLabel, shiny: "✨ \(l.dexShinyLabel)", isShiny: displayedShiny) : nil
        // identity
        let details = store.pokemonDetailsByID[species.id]
        var types: [TypeBadge] = []
        if let details {
            for t in details.types {
                resources.append(.init(kind: .type, name: t))
                types.append(TypeBadge(text: name(.type, t).uppercased(with: language.displayLocale), tint: .type(PopoverPokemonType(apiName: t))))
            }
        }
        let isRep = store.isRepresentative(shown)
        let identity = Identity(
            speciesID: shown.id, shinySprite: displayedShiny, form: shown.form, name: shown.name, rarity: l.rarityLabel(shown.rarity), types: types,
            formNote: details != nil && !PokemonForm.isDefault(shown.form, speciesID: shown.id) ? l.defaultFormDataNote : nil,
            shinyLine: displayedShiny ? "✨ \(l.dexShinyLabel)" : nil,
            raising: individual.map { store.isActiveDexEntry($0) } == true ? l.dexRaising : nil,
            repTitle: isRep ? l.representativeFollowCurrent : l.representativeSet, isRepresentative: isRep, repForm: shown.form)
        let picker = individuals.count > 1
            ? individuals.enumerated().map { IndividualChoice(id: $1.id, label: r.individualLabel($1, index: $0), selected: $1.id == individual?.id) } : []
        // content
        let content: Content
        if let details {
            func statRows(_ stats: [PokemonComputedStat]) -> [Stat] { stats.map { Stat(label: l.statLabel($0.name), value: $0.value, iv: $0.iv) } }
            var ind: Individual?
            var base: BaseStats?
            if let individual, let profile = individual.profile {
                let stats = PokemonStatCalculator.stats(details: details, profile: profile, nature: individual.nature)
                if let ability = profile.abilityName { resources.append(.init(kind: .ability, name: ability)) }
                for m in profile.moves { resources.append(.init(kind: .move, name: m.name)) }
                ind = Individual(
                    title: l.pokemonIndividual,
                    pairs: [Pair(label: l.level, value: "\(profile.level)"), Pair(label: l.gender, value: l.genderLabel(profile.gender)),
                            Pair(label: l.nature, value: individual.nature?.name(language) ?? "—")],
                    prayer: (individual.prayers?.count ?? 0) > 0 ? l.prayerBornWith(individual.prayers!.count) : nil,
                    prayerNote: (individual.prayers?.count ?? 0) > 0 ? l.prayerReachedHeaven : nil,
                    abilityLabel: l.ability,
                    ability: profile.abilityName.map { name(.ability, $0, suffix: profile.abilityIsHidden ? " · " + l.hiddenAbility : "") } ?? "—",
                    statsTitle: l.actualStats, stats: statRows(stats),
                    scaleMaximum: PokemonStatCalculator.displayScaleMaximum(for: stats.map(\.value)),
                    movesTitle: l.activeMoves,
                    moves: profile.moves.map { move in Move(key: move.name, name: name(.move, move.name), detail: "Lv. \(move.learnedAtLevel)") },
                    noMoves: profile.moves.isEmpty ? l.noLevelMoves : nil)
            } else {
                base = BaseStats(title: l.baseStats,
                                 stats: PokemonStatCalculator.order.compactMap { s in details.baseStats[s].map { Stat(label: l.statLabel(s), value: $0, iv: nil) } },
                                 scaleMaximum: 300)
            }
            for a in details.abilities { resources.append(.init(kind: .ability, name: a.name)) }
            let abilities = PopoverNameText(items: details.abilities.map {
                PopoverNameItem(resource: .init(kind: .ability, name: $0.name), suffix: $0.isHidden ? " (\(l.hidden))" : "")
            }, language: language, names: names, failed: failed).text
            for m in details.moves { resources.append(.init(kind: .move, name: m.name)) }
            content = .details(
                individual: ind, base: base,
                species: Species(title: l.speciesData,
                                 pairs: [Pair(label: l.height, value: String(format: "%.1f m", Double(details.height) / 10)),
                                         Pair(label: l.weight, value: String(format: "%.1f kg", Double(details.weight) / 10)),
                                         Pair(label: l.baseStatTotal, value: "\(details.baseStatTotal)")],
                                 abilitiesTitle: l.possibleAbilities, abilities: abilities),
                moves: MoveList(title: l.completeMoveList(details.moves.count), moves: details.moves.map { m in
                    Move(key: m.name, name: name(.move, m.name),
                         detail: m.learnMethods.map(l.moveMethod).reduce(into: [String]()) { out, v in if !out.contains(v) { out.append(v) } }.joined(separator: " · "))
                }))
        } else if store.failedPokemonDetailIDs.contains(species.id) {
            content = .unavailable(text: l.pokemonDetailsUnavailable, retry: l.retry)
        } else {
            content = .loading(text: l.loadingPokemonDetails)
        }
        var seen = Set<PokemonNameResource>()
        resources = resources.filter { seen.insert($0).inserted }
        return DexDetailModel(back: l.back, idText: "#\(species.id)", forms: forms, appearance: appearance, identity: identity,
                              individualPicker: picker, individualPickerTitle: l.pokemonIndividual,
                              preview: individuals.isEmpty ? l.dexAppearancePreview : nil, content: content, nameResources: resources,
                              selectedForm: r.selectedForm, selectedInstanceID: r.selectedInstanceID)
    }
}
// MARK: end Task 21
