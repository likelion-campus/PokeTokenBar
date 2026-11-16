import Foundation

/// FIXTURE companion states for the companion header (stage 7 Task 9): the shared tests, the Windows selftest's captures and
/// the Mac's reference renders build the same real `CompanionStore` from the same saved state, so the two systems show the
/// same names and numbers. Sample data only: public species numbers and names, one synthetic long name; nothing asks the
/// network (the lines, details and type names come from the providers below). Not used by the app itself.
enum CompanionHeaderSample: String, CaseIterable, Sendable {
    case eggFirstRun, eggIncubating, eggImminent, hatched, midLevel, aboutToEvolve, finalStage, shiny, form, back, graduated, eevee, longName
}

/// The sample lines, names and details.
struct CompanionSamplePoke: PokeProviding, PokemonDetailProviding {
    static func node(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
    /// The long name is synthetic (a form name with a long label, in German): it shows how a name that does not fit wraps.
    static let longName = "Gastrodon (Östliches Meer, Sammlerstück)"
    static let names: [Int: [String: String]] = [
        1: ["ko": "이상해씨", "en": "Bulbasaur", "ja": "フシギダネ", "de": "Bisasam"],
        2: ["ko": "이상해풀", "en": "Ivysaur", "ja": "フシギソウ", "de": "Bisaknosp"],
        3: ["ko": "이상해꽃", "en": "Venusaur", "ja": "フシギバナ", "de": "Bisaflor"],
        4: ["ko": "파이리", "en": "Charmander", "ja": "ヒトカゲ", "de": "Glumanda"],
        5: ["ko": "리자드", "en": "Charmeleon", "ja": "リザード", "de": "Glutexo"],
        6: ["ko": "리자몽", "en": "Charizard", "ja": "リザードン", "de": "Glurak"],
        133: ["ko": "이브이", "en": "Eevee", "ja": "イーブイ", "de": "Evoli"],
        422: ["ko": "깝질무", "en": "Shellos", "ja": "カラナクシ", "de": "Schalellos"],
        423: ["ko": "트리토돈", "en": "Gastrodon", "ja": "トリトドン", "de": longName],
    ]
    static func line(base: Int) -> EvoLine {
        switch base {
        case 4: return EvoLine(baseID: 4, tree: node(4, [node(5, [node(6)])]), rarity: .uncommon, names: names)
        case 133: return EvoLine(baseID: 133, tree: node(133, [134, 135, 136, 196, 197, 470, 471, 700].map { node($0) }), rarity: .rare, names: names)
        case 422: return EvoLine(baseID: 422, tree: node(422, [node(423)]), rarity: .common, names: names)
        default: return EvoLine(baseID: 1, tree: node(1, [node(2, [node(3)])]), rarity: .common, names: names)
        }
    }
    static let types: [Int: [String]] = [1: ["grass", "poison"], 2: ["grass", "poison"], 3: ["grass", "poison"], 4: ["fire"], 5: ["fire"],
                                         6: ["fire", "flying"], 133: ["normal"], 422: ["water"], 423: ["water", "ground"]]

    func line(baseSpeciesID: Int) async throws -> EvoLine { Self.line(base: baseSpeciesID) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: 1, captureRate: 255)] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { BaseSpecies(id: id, captureRate: 255) }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        PokemonDetails(speciesID: speciesID, name: "sample-\(speciesID)", height: 7, weight: 69, baseExperience: 64, genderRate: 1,
                       types: Self.types[speciesID] ?? ["normal"], baseStats: [:], abilities: [], moves: [])
    }
}

/// The sample type names (what PokéAPI's type resources say, for the shown types).
struct CompanionSampleNames: PokemonNameProviding {
    static let table: [String: [String: String]] = [
        "grass": ["ko": "풀", "en": "Grass", "ja-Hrkt": "くさ", "de": "Pflanze"], "poison": ["ko": "독", "en": "Poison", "ja-Hrkt": "どく", "de": "Gift"],
        "fire": ["ko": "불꽃", "en": "Fire", "ja-Hrkt": "ほのお", "de": "Feuer"], "flying": ["ko": "비행", "en": "Flying", "ja-Hrkt": "ひこう", "de": "Flug"],
        "water": ["ko": "물", "en": "Water", "ja-Hrkt": "みず", "de": "Wasser"], "ground": ["ko": "땅", "en": "Ground", "ja-Hrkt": "じめん", "de": "Boden"],
        "normal": ["ko": "노말", "en": "Normal", "ja-Hrkt": "ノーマル", "de": "Normal"],
    ]
    struct Missing: Error {}
    func names(for resource: PokemonNameResource) async throws -> [String: String] {
        guard let names = Self.table[resource.name] else { throw Missing() }
        return names
    }
}

@MainActor enum CompanionHeaderSamples {
    /// A fixed generator so a sample's hatch rolls the same nature and colour every time.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// `pathIDs` is the realized path (the species so far), `plannedPathIDs` the whole planned line; `progress` is the
    /// fraction of this stage's threshold (at the default difficulty).
    static func mon(_ path: [Int], stage: Int, progress: Double, rarity: Rarity = .common, shiny: Bool = false, nature: PokemonNature = .modest,
                    form: PokemonForm? = nil, boost: Bool = false, forms: Int = 3) -> MonState {
        var m = MonState(baseID: path[0], pathIDs: Array(path.prefix(stage + 1)), plannedPathIDs: path, stageIndex: stage, usedAtStage: 0, rarity: rarity,
                         totalForms: forms, isShiny: shiny, nature: nature, hasGrowthBoost: boost, form: form)
        m.usedAtStage = Int(Double(m.phaseThreshold) * progress)
        return m
    }

    /// A store in `sample`'s state, its line loaded, its details loaded. `directory` holds its saved state.
    static func store(_ sample: CompanionHeaderSample, language: AppLanguage, defaults: UserDefaults, directory: URL) async -> CompanionStore {
        var state = CompanionState()
        state.language = language
        state.installBaselineSet = true
        let egg = PokemonBalance.eggHatchThreshold
        switch sample {
        case .eggFirstRun: break
        case .eggIncubating: state.eggUsage = egg * 42 / 100
        case .eggImminent: state.eggUsage = egg * 95 / 100; state.eggTier = .rare
        case .hatched: state.eggUsage = 1
        case .midLevel, .back: state.active = mon([1, 2, 3], stage: 1, progress: 0.48, boost: true)
        case .aboutToEvolve: state.active = mon([1, 2, 3], stage: 1, progress: 0.97)
        case .finalStage: state.active = mon([1, 2, 3], stage: 2, progress: 0.3)
        case .graduated: state.active = mon([1, 2, 3], stage: 2, progress: 0.999)
        case .shiny: state.active = mon([4, 5, 6], stage: 0, progress: 0.2, rarity: .uncommon, shiny: true)
        case .form: state.active = mon([422, 423], stage: 0, progress: 0.6, form: PokemonForm("east"), forms: 2)
        case .eevee: state.active = mon([133], stage: 0, progress: 0.1, rarity: .rare, forms: 2)
        case .longName: state.active = mon([422, 423], stage: 1, progress: 0.35, rarity: .legendary, form: PokemonForm("east"), boost: true, forms: 2)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("companion-state.json")
        try? JSONEncoder().encode(state).write(to: url)
        let store = CompanionStore(provider: CompanionSamplePoke(), clock: { Date() }, fileURL: url, rng: SplitMix(state: 9),
                                   dittoDisguiseRollingEnabled: false, defaults: defaults)
        func feed(_ burn: BurnTier, today: Int, warning: Bool = false, idle: TimeInterval? = nil) {
            store.update(todayTokensByProvider: ["sample": today], todayDate: "d", monthTotal: 0, burnTier: burn, limitWarning: warning, hasUsageData: true,
                         timeSinceLastUsage: idle)
        }
        if state.active != nil {
            feed(.idle, today: 0)
            for _ in 0..<400 where store.displayName == "Token Egg" { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        switch sample {
        case .hatched: await store.hatch(baseID: 1)
        case .midLevel, .shiny: feed(.normal, today: 100)
        case .aboutToEvolve: feed(.blazing, today: 100)
        case .finalStage, .form, .longName: feed(.idle, today: 100)
        case .eevee: feed(.normal, today: 100, warning: true)
        case .back:
            feed(.normal, today: 100)
            store.alwaysFacesBack = true   // Settings' "Back view" (the app mirrors UsageStore.alwaysFacesBack into the store)
        case .graduated: store.applyUsage(store.tokensToNext)
        case .eggFirstRun, .eggIncubating, .eggImminent: break
        }
        if let id = store.currentSpeciesID { await store.loadPokemonDetails(speciesID: id) }
        return store
    }

    /// The shown types' names into `names` (the display store the header reads).
    static func loadTypeNames(into names: PokemonNameDisplayStore) async {
        for type in CompanionSampleNames.table.keys {
            _ = await names.load(PokemonNameResource(kind: .type, name: type), provider: CompanionSampleNames())
        }
    }
}
