import Foundation
import Observation

/// What the companion header reads, captured once per build (stage 7 Task 9; the Mac's `CompanionHeader`). Fields are named as
/// the `CompanionStore` members the Mac view reads (`state.active?.usedAtStage` is `usedAtStage`, `state.eggUsage` is
/// `eggUsage`), so the builder below reads exactly what the Mac body reads. Built inside the section's
/// `withObservationTracking`, it registers every member the header depends on. The type names are what
/// `PokemonNameDisplayStore` holds for the shown types (the Mac's `PokemonNameLabel` reads the same store).
struct CompanionHeaderInput: Equatable, Sendable {
    var language: AppLanguage = .en
    var hasActive = false
    var isEgg = true
    var currentSpeciesID: Int?
    var currentIsShiny = false
    var currentForm: PokemonForm?
    var facesBack = false
    var displayName = "Token Egg"
    var rarity: Rarity?
    /// `pokemonDetailsByID[currentSpeciesID]?.types`; nil until the details are loaded.
    var types: [String]?
    var typeNames: [PokemonNameResource: [String: String]] = [:]
    var failedTypeNames: Set<PokemonNameResource> = []
    var stageText = ""
    var currentNature: PokemonNature?
    var growthMultiplier: Int?
    var progress: Double = 0
    var usedAtStage = 0
    var threshold = 1
    var tokensToNext = 0
    var isFinalStage = false
    var eggProgress: Double = 0
    var eggUsage = 0
    var eggHatchThreshold = 1
    var eggGuarantee: Rarity?
    var isHatchRetryDelayed = false
    var eggTokensToHatch = 0
    var eggStarted = false
    var displayState: CompanionStateKind = .egg
    var justEvolvedTo: String?
    var justGraduated: String?
    var lineNodes: [EvoLineItem] = []
    var celebration: CompanionStore.Celebration?
    var celebrationSeq = 0
    var candyFeedbackSeq = 0
    var candyFeedbackAmount = 0
    var mintFeedbackSeq = 0
    var mintFeedbackNature: PokemonNature?

    var l: L { L(language) }

    init() {}

    /// The store as the Mac header reads it, with the type names `names` holds and the ones that failed to load.
    @MainActor init(store: CompanionStore, names: PokemonNameDisplayStore = .shared, failedTypeNames: Set<PokemonNameResource> = []) {
        language = store.language
        hasActive = store.hasActive
        isEgg = store.isEgg
        currentSpeciesID = store.currentSpeciesID
        currentIsShiny = store.currentIsShiny
        currentForm = store.currentForm
        facesBack = store.facesBack
        displayName = store.displayName
        rarity = store.rarity
        types = store.currentSpeciesID.flatMap { store.pokemonDetailsByID[$0]?.types }
        for type in types ?? [] {
            let resource = PokemonNameResource(kind: .type, name: type)
            if let found = names.names[resource] { typeNames[resource] = found }
        }
        self.failedTypeNames = failedTypeNames.filter { r in (types ?? []).contains(r.name) }
        stageText = store.stageText
        currentNature = store.currentNature
        growthMultiplier = store.growthMultiplier
        progress = store.progress
        usedAtStage = store.state.active?.usedAtStage ?? 0
        threshold = store.threshold
        tokensToNext = store.tokensToNext
        isFinalStage = store.isFinalStage
        eggProgress = store.eggProgress
        eggUsage = store.state.eggUsage
        eggHatchThreshold = store.eggHatchThreshold
        eggGuarantee = store.eggGuarantee
        isHatchRetryDelayed = store.isHatchRetryDelayed
        eggTokensToHatch = store.eggTokensToHatch
        eggStarted = store.eggStarted
        displayState = store.displayState
        justEvolvedTo = store.justEvolvedTo
        justGraduated = store.justGraduated
        lineNodes = store.lineNodes
        celebration = store.celebration
        celebrationSeq = store.celebrationSeq
        candyFeedbackSeq = store.candyFeedbackSeq
        candyFeedbackAmount = store.candyFeedbackAmount
        mintFeedbackSeq = store.mintFeedbackSeq
        mintFeedbackNature = store.mintFeedbackNature
    }
}

/// The header as values: the sprite, the column beside it top to bottom, the evolution line and the graduation line. The
/// Windows page only places these; every text, colour and number comes from here.
struct CompanionHeaderModel: Equatable, Sendable {
    enum BadgeStyle: Equatable, Sendable { case solid, tinted }

    /// The Mac's `Badge`: a capsule with 8 pt bold text, white on the tint (`solid`) or the tint on a faint tint (`tinted`).
    struct Badge: Equatable, Sendable {
        var text: String
        var tint: PopoverBadgeTint
        var style: BadgeStyle = .solid
    }

    /// One line of the column, as the Mac body writes them (`caption2` unless named otherwise; every text wraps at the
    /// column's width, as SwiftUI's `Text` does in the scroll view).
    enum Line: Equatable, Sendable {
        /// The name (callout, semibold), ✨ for a shiny one, the rarity badge.
        case title(String, shiny: Bool, rarity: Badge?)
        case types([Badge])
        /// Secondary (the default-form data note).
        case note(String)
        /// Stage and nature (secondary) with the growth boost badge.
        case stage(String, boost: Badge?)
        /// Incubating (secondary) or imminent (orange), with the guarantee badge.
        case egg(String, imminent: Bool, guarantee: Badge?)
        /// The growth bar: the fill and the "X / Y · Z%" detail (its tooltip and accessible value on Windows).
        case bar(value: Double, detail: String)
        /// A caption in a colour (tertiary, or orange for the delayed hatch).
        case caption(String, color: PopoverColorRole)
        /// The status line (secondary).
        case status(String)
    }

    var sprite: PlazaSpriteSubjectKey
    /// The sprite's accessible name (the Mac's `DexEntryLink` names it `displayName`; the link itself is tier 3).
    var spriteLabel: String
    var lines: [Line]
    /// The egg is about to hatch: it wiggles.
    var eggImminent: Bool
    var evoLine: EvoLineModel?
    var graduated: String?

    /// Hover tooltip for the growth bars: "X / Y · Z%". Twin of `CompanionHeader.progressDetail` (twins.txt).
    nonisolated static func progressDetail(used: Int, total: Int) -> String {
        let used = min(used, total)
        let percent = total > 0 ? used * 100 / total : 0
        return "\(TokenFormatter.compact(used)) / \(TokenFormatter.compact(total)) · \(percent)%"
    }

    @MainActor static func make(companion: CompanionStore, names: PokemonNameDisplayStore = .shared,
                                failedTypeNames: Set<PokemonNameResource> = []) -> CompanionHeaderModel {
        make(input: CompanionHeaderInput(store: companion, names: names, failedTypeNames: failedTypeNames))
    }

    static func make(input: CompanionHeaderInput) -> CompanionHeaderModel {
        let b = CompanionHeaderBuilder(store: input)
        return CompanionHeaderModel(
            sprite: PlazaSpriteSubjectKey(speciesID: input.currentSpeciesID, shiny: input.currentIsShiny, form: input.currentForm,
                                          back: input.facesBack),
            spriteLabel: input.displayName, lines: b.lines, eggImminent: b.eggImminent, evoLine: b.evoLine, graduated: b.graduated)
    }
}

/// The evolution line's values (the Mac's `EvoLineView` call in `CompanionHeader.body`).
struct EvoLineModel: Equatable, Sendable {
    var nodes: [EvoLineItem]
    var shiny: Bool
    var form: PokemonForm?
    var mysteryLabel: String
    var previousLabel: String
    var nextLabel: String
}

/// `CompanionHeader`'s private members over a captured input as the view's `store`: `statusLine` and `eggImminent` are
/// twins (their bodies read as the Mac's, twins.txt); `lines`, `evoLine` and `graduated` rebuild `CompanionHeader.body`
/// as values (pinned in twins.txt, equivalence on real stores in `PopoverTwinEquivalenceTests+Mac`).
struct CompanionHeaderBuilder {
    let store: CompanionHeaderInput

    /// 부화 임박(90%+) — 알이 흔들리고 문구가 바뀐다.
    var eggImminent: Bool { store.isEgg && store.eggProgress >= 0.9 }

    var statusLine: String {
        let l = store.l
        switch store.displayState {
        case .egg:     return l.statusEgg
        case .idle:    return l.statusIdle
        case .working: return l.statusWorking
        case .focus:   return l.statusFocus
        case .tired:   return l.statusTired
        case .sleep:   return l.statusSleep
        case .sulk:    return l.statusSulk
        case .levelUp: return store.justEvolvedTo.map { l.statusEvolved($0) } ?? l.statusGrew
        }
    }

    typealias Line = CompanionHeaderModel.Line
    typealias Badge = CompanionHeaderModel.Badge

    /// A type badge's text: `PokemonNameLabel(.type, type, language:)` uppercased (`.textCase(.uppercase)`, the app language).
    func typeName(_ type: String) -> String {
        let item = PopoverNameItem(resource: PokemonNameResource(kind: .type, name: type))
        return PopoverNameText(items: [item], language: store.language, names: store.typeNames, failed: store.failedTypeNames).text
            .uppercased(with: store.language.displayLocale)
    }

    /// The column beside the sprite, top to bottom (`CompanionHeader.body`'s inner `VStack`).
    var lines: [Line] {
        let l = store.l
        var out: [Line] = []
        out.append(.title(store.displayName, shiny: store.currentIsShiny,
                          rarity: store.rarity.map { Badge(text: l.rarityLabel($0).uppercased(), tint: .rarity($0)) }))
        if store.hasActive, let id = store.currentSpeciesID, let types = store.types {
            out.append(.types(types.map { Badge(text: typeName($0), tint: .type(PopoverPokemonType(apiName: $0))) }))
            if !PokemonForm.isDefault(store.currentForm, speciesID: id) { out.append(.note(l.defaultFormDataNote)) }
        }
        if store.hasActive {
            let nature = store.currentNature.map { " · \($0.name(store.language))" } ?? ""
            out.append(.stage(store.stageText + nature,
                              boost: store.growthMultiplier.map { Badge(text: l.growthBoost($0), tint: .orange, style: .tinted) }))
            out.append(.bar(value: store.progress,
                            detail: CompanionHeaderModel.progressDetail(used: store.usedAtStage, total: store.threshold)))
            if store.tokensToNext > 0 {
                let amount = TokenFormatter.compact(store.tokensToNext)
                out.append(.caption(store.isFinalStage ? l.toGraduation(amount) : l.toNextEvolution(amount), color: .tertiary))
            }
        } else {
            out.append(.egg(eggImminent ? l.eggImminent : l.eggIncubating, imminent: eggImminent,
                            guarantee: store.eggGuarantee.map { Badge(text: l.eggGuaranteeHint($0), tint: .rarity($0)) }))
            out.append(.bar(value: store.eggProgress,
                            detail: CompanionHeaderModel.progressDetail(used: store.eggUsage, total: store.eggHatchThreshold)))
            if store.isEgg, store.isHatchRetryDelayed {
                out.append(.caption(l.eggHatchDelayed, color: .systemOrange))
            } else {
                out.append(.caption(l.eggToHatch(TokenFormatter.compact(store.eggTokensToHatch)), color: .tertiary))
            }
            if !store.eggStarted {
                out.append(.caption(l.eggFirstRunHint(TokenFormatter.compact(store.eggHatchThreshold)), color: .tertiary))
            }
        }
        out.append(.status(statusLine))
        return out
    }

    /// The evolution line under the header (only while a Pokémon is raised and its line is known).
    var evoLine: EvoLineModel? {
        guard store.hasActive, !store.lineNodes.isEmpty else { return nil }
        let l = store.l
        return EvoLineModel(nodes: store.lineNodes, shiny: store.currentIsShiny, form: store.currentForm,
                            mysteryLabel: l.unknownNextEvolution, previousLabel: l.evolutionScrollPrevious,
                            nextLabel: l.evolutionScrollNext)
    }

    /// "X graduated → …" (orange) right after a graduation.
    var graduated: String? { store.justGraduated.map { store.l.graduated($0) } }
}

// MARK: - badges: colours and type names (twins of UI/Badge.swift, UI/CompanionView.swift, UI/PokemonNameLabel.swift)

/// The 18 main-series types, keyed by PokeAPI's canonical lowercase English name. Twin of `PokemonType` (its `hex`).
enum PopoverPokemonType: String, CaseIterable, Sendable {
    case normal, fire, water, electric, grass, ice, fighting, poison, ground,
         flying, psychic, bug, rock, ghost, dragon, dark, steel, fairy

    init?(apiName: String) { self.init(rawValue: apiName.lowercased()) }

    /// Classic type-chart colors.
    var hex: UInt32 {
        switch self {
        case .normal: 0xAAAA99
        case .fire: 0xFF4422
        case .water: 0x3399FF
        case .electric: 0xFFCC33
        case .grass: 0x77CC55
        case .ice: 0x66CCFF
        case .fighting: 0xBB5544
        case .poison: 0xAA5599
        case .ground: 0xDDBB55
        case .flying: 0x8899FF
        case .psychic: 0xFF5599
        case .bug: 0xAABB22
        case .rock: 0xBBAA66
        case .ghost: 0x6666BB
        case .dragon: 0x7766EE
        case .dark: 0x775544
        case .steel: 0xAAAABB
        case .fairy: 0xEE99EE
        }
    }
}

/// What a badge is coloured by (the Mac's `BadgeTint`; its `color` is pinned, the values are compared on the Mac).
enum PopoverBadgeTint: Equatable, Sendable {
    /// nil = a PokeAPI type outside the 18 (stellar, shadow, unknown) → neutral gray.
    case type(PopoverPokemonType?)
    case rarity(Rarity?)
    case accent, orange, secondary

    /// The tint's colour (light appearance): a type's chart colour, else the Mac's role.
    var color: PlazaColor {
        switch self {
        case .type(let type):
            guard let hex = type?.hex else { return PopoverColorRole.systemGray.plazaColor() }
            return PlazaColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                              blue: Double(hex & 0xFF) / 255, alpha: 1)
        case .rarity(let rarity): return CompanionBadges.rarityColor(rarity).plazaColor()
        case .accent: return PopoverColorRole.accent.plazaColor()
        case .orange: return PopoverColorRole.systemOrange.plazaColor()
        case .secondary: return PopoverColorRole.secondary.plazaColor()
        }
    }

    var isType: Bool { if case .type = self { true } else { false } }
}

enum CompanionBadges {
    /// The rarity's colour. Twin of the Mac's file-level `rarityColor` (twins.txt).
    static func rarityColor(_ r: Rarity?) -> PopoverColorRole {
        switch r {
        case .uncommon: return .systemGreen
        case .rare: return .systemBlue
        case .legendary: return .systemOrange
        default: return .systemGray
        }
    }
}

/// Twin of `PokemonNameItem`.
struct PopoverNameItem: Hashable, Sendable {
    let resource: PokemonNameResource
    var suffix = ""
}

/// Twin of `PokemonNameText` (its `text`): "…" while loading, the identifier when the load failed or no language matched.
struct PopoverNameText {
    let items: [PopoverNameItem]
    let language: AppLanguage
    let names: [PokemonNameResource: [String: String]]
    var failed: Set<PokemonNameResource> = []

    var text: String {
        items.map { item in
            guard let translations = names[item.resource] else {
                return (failed.contains(item.resource)
                        ? PokemonNameLocalization.identifier(item.resource.name) : "…") + item.suffix
            }
            return (language.resolveName(translations)
                    ?? PokemonNameLocalization.identifier(item.resource.name)) + item.suffix
        }.joined(separator: " · ")
    }
}
