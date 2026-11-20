import XCTest
@testable import PokeTokenBar

/// FIXTURE lines and details for the companion header tests (sample data: public species numbers and names, no network).
struct CompanionHeaderFixturePoke: PokeProviding, PokemonDetailProviding {
    static func node(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
    static let names: [Int: [String: String]] = [
        1: ["ko": "이상해씨", "en": "Bulbasaur", "ja": "フシギダネ"], 2: ["ko": "이상해풀", "en": "Ivysaur", "ja": "フシギソウ"],
        3: ["ko": "이상해꽃", "en": "Venusaur", "ja": "フシギバナ"], 4: ["ko": "파이리", "en": "Charmander", "ja": "ヒトカゲ"],
        5: ["ko": "리자드", "en": "Charmeleon", "ja": "リザード"], 6: ["ko": "리자몽", "en": "Charizard", "ja": "リザードン"],
        133: ["ko": "이브이", "en": "Eevee", "ja": "イーブイ"], 422: ["ko": "깝질무", "en": "Shellos", "ja": "カラナクシ"],
        423: ["ko": "트리토돈", "en": "Gastrodon", "ja": "トリトドン"],
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
        PokemonDetails(speciesID: speciesID, name: "fixture-\(speciesID)", height: 7, weight: 69, baseExperience: 64, genderRate: 1,
                       types: Self.types[speciesID] ?? ["normal"], baseStats: [:], abilities: [], moves: [])
    }
}

/// Real `CompanionStore`s in a given saved state (written to a temporary file the store loads), over the fixture provider.
@MainActor enum CompanionHeaderFixtures {
    static func store(active: MonState? = nil, eggUsage: Int = 0, eggTier: Rarity? = nil, language: AppLanguage = .en,
                      suite: String = "companion.header") async -> CompanionStore {
        var state = CompanionState()
        state.active = active
        state.eggUsage = eggUsage
        state.eggTier = eggTier
        state.language = language
        state.installBaselineSet = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-companion-header-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("companion-state.json")
        try? JSONEncoder().encode(state).write(to: url)
        let store = CompanionStore(provider: CompanionHeaderFixturePoke(), clock: { Date() }, fileURL: url, rng: SeededRNG(seed: 9),
                                   dittoDisguiseRollingEnabled: false, defaults: TestDefaults.make(suite: suite))
        if active != nil {
            store.update(todayTokensByProvider: [:], todayDate: "d", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: false)
            for _ in 0..<200 where store.displayName == "Token Egg" { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        return store
    }

    static func mon(_ path: [Int], stage: Int, used: Int, rarity: Rarity = .common, shiny: Bool = false, nature: PokemonNature? = .modest,
                    form: PokemonForm? = nil, boost: Bool = false, forms: Int = 3) -> MonState {
        // `pathIDs` is the realized path (the species so far), `plannedPathIDs` the whole planned line.
        MonState(baseID: path[0], pathIDs: Array(path.prefix(stage + 1)), plannedPathIDs: path, stageIndex: stage, usedAtStage: used, rarity: rarity, totalForms: forms,
                 isShiny: shiny, nature: nature, hasGrowthBoost: boost, form: form)
    }
}

@MainActor
final class CompanionHeaderModelTests: XCTestCase {
    private func lines(_ m: CompanionHeaderModel) -> [String] {
        m.lines.map { line in
            switch line {
            case .title(let s, let shiny, let r): return "title:\(s)\(shiny ? " ✨" : "")\(r.map { " [\($0.text)]" } ?? "")"
            case .types(let b): return "types:" + b.map(\.text).joined(separator: ",")
            case .note(let s): return "note:\(s)"
            case .stage(let s, let b): return "stage:\(s)\(b.map { " [\($0.text)]" } ?? "")"
            case .egg(let s, let imminent, let g): return "egg:\(s)\(imminent ? " !" : "")\(g.map { " [\($0.text)]" } ?? "")"
            case .bar(let v, let d): return "bar:\(String(format: "%.2f", v)) \(d)"
            case .caption(let s, let c): return "caption(\(c)):\(s)"
            case .status(let s): return "status:\(s)"
            }
        }
    }

    /// The Mac's `ProgressDetailTests` corpus, on the twin (the Mac's own function is Mac-only).
    func testProgressDetailIsTheMacsCorpus() async {
        XCTAssertEqual(CompanionHeaderModel.progressDetail(used: 37_200, total: 50_000), "37.2K / 50K · 74%")
        XCTAssertEqual(CompanionHeaderModel.progressDetail(used: 60_000, total: 50_000), "50K / 50K · 100%")
        XCTAssertEqual(CompanionHeaderModel.progressDetail(used: 0, total: 0), "0 / 0 · 0%")
        XCTAssertEqual(CompanionHeaderModel.progressDetail(used: 999, total: 1_000), "999 / 1K · 99%")
    }

    /// A first run: the egg, nothing banked, the first-run hint, "Hatching soon." (the state a PC without AI-tool usage shows).
    func testAFreshEggSaysWhatTheMacSays() async {
        let s = await CompanionHeaderFixtures.store()
        let m = CompanionHeaderModel.make(companion: s)
        let l = L(.en)
        let threshold = s.eggHatchThreshold
        XCTAssertNil(m.sprite.speciesID)
        XCTAssertEqual(lines(m), ["title:Token Egg", "egg:\(l.eggIncubating)", "bar:0.00 0 / \(TokenFormatter.compact(threshold)) · 0%",
                                  "caption(tertiary):\(l.eggToHatch(TokenFormatter.compact(threshold)))",
                                  "caption(tertiary):\(l.eggFirstRunHint(TokenFormatter.compact(threshold)))", "status:\(l.statusEgg)"])
        XCTAssertFalse(m.eggImminent)
        XCTAssertNil(m.evoLine)
        XCTAssertNil(m.graduated)
    }

    /// 95 % banked with a guarantee: imminent (orange text, wiggle), the guarantee badge, no first-run hint; at 90 % exactly the
    /// egg is imminent, below it is not (the Mac's `>= 0.9`).
    func testAnEggAboutToHatch() async {
        let s = await CompanionHeaderFixtures.store(eggUsage: 1, eggTier: .rare, language: .ko)
        let t = s.eggHatchThreshold
        var input = CompanionHeaderInput(store: s)
        input.eggUsage = t * 95 / 100
        input.eggProgress = Double(input.eggUsage) / Double(t)
        input.eggTokensToHatch = t - input.eggUsage
        let m = CompanionHeaderModel.make(input: input)
        let l = L(.ko)
        XCTAssertTrue(m.eggImminent)
        XCTAssertEqual(lines(m)[1], "egg:\(l.eggImminent) ! [\(l.eggGuaranteeHint(.rare))]")
        XCTAssertFalse(lines(m).contains { $0.contains(l.eggFirstRunHint(TokenFormatter.compact(t))) })
        if case .egg(_, _, let g) = m.lines[1] { XCTAssertEqual(g?.tint, .rarity(.rare)) } else { XCTFail("no egg line") }
        input.eggProgress = 0.9
        XCTAssertTrue(CompanionHeaderBuilder(store: input).eggImminent)
        input.eggProgress = 0.8999
        XCTAssertFalse(CompanionHeaderBuilder(store: input).eggImminent)
        input.isHatchRetryDelayed = true
        XCTAssertTrue(lines(CompanionHeaderModel.make(input: input)).contains("caption(systemOrange):\(l.eggHatchDelayed)"))
    }

    /// Mid-level Ivysaur with types loaded, a nature, a growth boost: every line, then the evolution line (done, current, future).
    func testAHatchedCompanionMidLevel() async {
        let s = await CompanionHeaderFixtures.store(active: CompanionHeaderFixtures.mon([1, 2, 3], stage: 1, used: 1_000, boost: true), language: .en)
        await CompanionHeaderSamples.loadDetails(s, speciesID: 2)
        let names = PokemonNameDisplayStore()
        let m = CompanionHeaderModel.make(companion: s, names: names)
        let l = L(.en)
        XCTAssertEqual(m.sprite, PlazaSpriteSubjectKey(speciesID: 2, shiny: false, form: nil, back: false))
        let out = lines(m)
        XCTAssertEqual(out[0], "title:Ivysaur [\(l.rarityLabel(.common).uppercased())]")
        XCTAssertEqual(out[1], "types:…,…", "names not loaded yet: the Mac's \"…\"")
        XCTAssertEqual(out[2], "stage:\(l.stage(2, 3)) · \(PokemonNature.modest.name(.en)) [\(l.growthBoost(PokemonBalance.repeatGrowthMultiplier))]")
        XCTAssertTrue(out[3].hasPrefix("bar:"), out[3])
        XCTAssertEqual(out[3], "bar:\(String(format: "%.2f", s.progress)) \(CompanionHeaderModel.progressDetail(used: 1_000, total: s.threshold))")
        XCTAssertEqual(out[4], "caption(tertiary):\(l.toNextEvolution(TokenFormatter.compact(s.tokensToNext)))")
        XCTAssertEqual(out.last, "status:\(CompanionHeaderBuilder(store: CompanionHeaderInput(store: s)).statusLine)")
        XCTAssertEqual(m.evoLine?.nodes, [EvoLineItem(.species(1), .done), EvoLineItem(.species(2), .current), EvoLineItem(.species(3), .future)])
        XCTAssertEqual(m.evoLine?.mysteryLabel, l.unknownNextEvolution)
    }

    /// Final stage: "to graduation", "Final form"; shiny: ✨ in the title and the shiny sprite (the whole line shiny); back view.
    func testFinalStageShinyAndBack() async {
        let s = await CompanionHeaderFixtures.store(active: CompanionHeaderFixtures.mon([4, 5, 6], stage: 2, used: 10, rarity: .uncommon, shiny: true))
        s.alwaysFacesBack = true
        let m = CompanionHeaderModel.make(companion: s)
        let l = L(.en)
        XCTAssertEqual(lines(m)[0], "title:Charizard ✨ [\(l.rarityLabel(.uncommon).uppercased())]")
        XCTAssertTrue(lines(m).contains("stage:\(l.finalForm) · \(PokemonNature.modest.name(.en))"))
        XCTAssertTrue(lines(m).contains("caption(tertiary):\(l.toGraduation(TokenFormatter.compact(s.tokensToNext)))"))
        XCTAssertEqual(m.sprite, PlazaSpriteSubjectKey(speciesID: 6, shiny: true, form: nil, back: true))
        XCTAssertEqual(m.evoLine?.shiny, true)
        XCTAssertEqual(m.evoLine?.nodes.last, EvoLineItem(.species(6), .current))
    }

    /// A branching line hides its candidates behind one "?" (Eevee); a form variant shows the default-form data note.
    func testBranchingLineAndAForm() async {
        let eevee = await CompanionHeaderFixtures.store(active: CompanionHeaderFixtures.mon([133], stage: 0, used: 0, rarity: .rare, forms: 2))
        XCTAssertEqual(CompanionHeaderModel.make(companion: eevee).evoLine?.nodes, [EvoLineItem(.species(133), .current), EvoLineItem(.mystery, .future)])
        let east = PokemonForm("east")
        let shellos = await CompanionHeaderFixtures.store(active: CompanionHeaderFixtures.mon([422, 423], stage: 0, used: 0, form: east, forms: 2))
        await CompanionHeaderSamples.loadDetails(shellos, speciesID: 422)
        let m = CompanionHeaderModel.make(companion: shellos)
        XCTAssertEqual(m.sprite.form, east)
        XCTAssertTrue(lines(m).contains("note:\(L(.en).defaultFormDataNote)"), "\(lines(m))")
        XCTAssertEqual(m.evoLine?.form, east)
    }

    /// The type badges' texts: "…" while loading, the identifier when the load failed, the language's name once loaded
    /// (uppercased in the app language), English when the language is missing.
    func testTypeNamesWhileLoadingFailedAndLoaded() async {
        var input = CompanionHeaderInput()
        input.hasActive = true
        input.isEgg = false
        input.currentSpeciesID = 2
        input.types = ["grass", "poison"]
        input.language = .ko
        let grass = PokemonNameResource(kind: .type, name: "grass"), poison = PokemonNameResource(kind: .type, name: "poison")
        func types(_ i: CompanionHeaderInput) -> [String] {
            guard case .types(let b)? = CompanionHeaderModel.make(input: i).lines.first(where: { if case .types = $0 { true } else { false } }) else { return [] }
            return b.map(\.text)
        }
        XCTAssertEqual(types(input), ["…", "…"])
        input.failedTypeNames = [poison]
        XCTAssertEqual(types(input), ["…", "POISON"])
        input.typeNames = [grass: ["ko": "풀", "en": "Grass"], poison: ["en": "Poison"]]
        XCTAssertEqual(types(input), ["풀", "POISON"])
        input.language = .de
        XCTAssertEqual(types(input), ["GRASS", "POISON"])
    }

    /// Every display state's status line (the Mac's switch), in three languages, with and without the evolved name.
    func testTheStatusLineInEveryState() async {
        let kinds: [CompanionStateKind] = [.egg, .idle, .working, .focus, .tired, .sleep, .sulk, .levelUp]
        for language in [AppLanguage.ko, .en, .ja] {
            let l = L(language)
            let expected: [CompanionStateKind: String] = [.egg: l.statusEgg, .idle: l.statusIdle, .working: l.statusWorking, .focus: l.statusFocus,
                                                          .tired: l.statusTired, .sleep: l.statusSleep, .sulk: l.statusSulk, .levelUp: l.statusGrew]
            for kind in kinds {
                var input = CompanionHeaderInput()
                input.language = language
                input.displayState = kind
                XCTAssertEqual(CompanionHeaderBuilder(store: input).statusLine, expected[kind])
                input.justEvolvedTo = "Ivysaur"
                XCTAssertEqual(CompanionHeaderBuilder(store: input).statusLine, kind == .levelUp ? l.statusEvolved("Ivysaur") : expected[kind])
            }
        }
    }

    /// Graduated: the orange line under the header; the line is gone with the new egg.
    func testTheGraduationLine() async {
        var input = CompanionHeaderInput()
        input.justGraduated = "Venusaur"
        input.language = .ja
        XCTAssertEqual(CompanionHeaderModel.make(input: input).graduated, L(.ja).graduated("Venusaur"))
        XCTAssertNil(CompanionHeaderModel.make(input: input).evoLine)
    }

    // MARK: celebrations: timings and the one-shot contract

    private func sample(_ d: CompanionCelebrationDriver, from start: Date, until end: TimeInterval) -> (frames: Int, last: TimeInterval, maxRate: Double) {
        var now = start
        var frames = 0
        var last: TimeInterval = 0
        var minGap = Double.infinity
        for _ in 0..<10_000 {
            guard let due = d.nextDue(after: now), due.timeIntervalSince(start) <= end else { break }
            XCTAssertGreaterThan(due, now, "the clock must move on (at \(now.timeIntervalSince(start)) s)")
            guard due > now else { break }
            minGap = min(minGap, due.timeIntervalSince(now))
            now = due
            frames += 1
            last = now.timeIntervalSince(start)
            _ = d.effects(at: now)
        }
        return (frames, last, minGap.isFinite ? 1 / minGap : 0)
    }

    /// Regression (found while writing these tests): a tick armed for a span's start lands a hair before it when `Date`
    /// arithmetic rounds (`start + 1.3` read back as 1.2999999…), and the driver answered the same due again, forever (in
    /// the app: a timer re-armed in the past, a busy loop). Every kind of effect, from starts far from the reference date,
    /// walks to its end with each due later than the one before.
    func testTheEffectClockAlwaysMovesOnWhateverTheRounding() async {
        let starts = [Date(timeIntervalSince1970: 3_000), Date(timeIntervalSince1970: 1_000), Date(timeIntervalSinceReferenceDate: 8.5e8 + 0.3),
                      Date(timeIntervalSince1970: 1_794_547_808.152), Date(timeIntervalSinceReferenceDate: -9.7e8)]
        for start in starts {
            for kind in [CompanionStore.Celebration.hatch(shiny: false), .hatch(shiny: true), .evolve, .dittoReveal(shiny: true)] {
                var input = CompanionHeaderInput()
                input.celebration = kind
                input.celebrationSeq = 1
                input.candyFeedbackAmount = 500
                input.candyFeedbackSeq = 1
                input.mintFeedbackNature = .calm
                input.mintFeedbackSeq = 1
                let d = CompanionCelebrationDriver()
                d.poll(input, consumer: RecordingConsumer(), now: start)
                let run = sample(d, from: start, until: 10)
                XCTAssertLessThanOrEqual(run.last, 3.2, "\(kind) from \(start)")
                XCTAssertNil(d.nextDue(after: start.addingTimeInterval(run.last + 0.01)), "\(kind) from \(start): it ends")
            }
            var egg = CompanionHeaderInput()
            egg.eggProgress = 0.95
            let w = CompanionCelebrationDriver()
            w.poll(egg, consumer: RecordingConsumer(), now: start)
            var now = start
            for _ in 0..<50 {
                guard let due = w.nextDue(after: now) else { return XCTFail("the wiggle stopped") }
                XCTAssertGreaterThan(due.timeIntervalSince(now), 0.1, "a wiggle step at most every 0.108 s, never the same instant again")
                now = due
            }
        }
    }

    /// A plain hatch: flash 0.85 → 0 over 0.8 s, the pop 0.6 → 1; at most 60 frames a second, done within 2.6 s, nothing after.
    func testAPlainHatchPlaysAtSixtyFramesForUnderTwoPointSixSeconds() async {
        var input = CompanionHeaderInput()
        input.celebration = .hatch(shiny: false)
        input.celebrationSeq = 1
        let consumer = RecordingConsumer()
        let d = CompanionCelebrationDriver()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(d.poll(input, consumer: consumer, now: t0))
        XCTAssertEqual(consumer.celebrations, 1)
        let e0 = d.effects(at: t0)
        XCTAssertEqual(e0.flash, 0.85, accuracy: 1e-9)
        XCTAssertEqual(e0.scale, 0.6, accuracy: 1e-9)
        let run = sample(d, from: t0, until: 10)
        XCTAssertLessThanOrEqual(run.maxRate, 60.5)
        XCTAssertLessThanOrEqual(run.last, 2.6)
        XCTAssertGreaterThan(run.frames, 30)
        XCTAssertNil(d.nextDue(after: t0.addingTimeInterval(run.last + 0.1)))
        XCTAssertEqual(d.effects(at: t0.addingTimeInterval(3)), .rest)
    }

    /// A shiny hatch adds the ✨ burst (in after 0.3 s on a spring, held, out from 2.6 s over 0.5 s): between the spring and
    /// the fade nothing moves, so the clock waits for 2.6 s instead of ticking.
    func testAShinyHatchHoldsStillBetweenItsBurstAndItsFade() async {
        var input = CompanionHeaderInput()
        input.celebration = .hatch(shiny: true)
        input.celebrationSeq = 4
        let d = CompanionCelebrationDriver()
        let t0 = Date(timeIntervalSince1970: 2_000)
        d.poll(input, consumer: RecordingConsumer(), now: t0)
        XCTAssertNil(d.effects(at: t0.addingTimeInterval(0.2)).shiny)
        XCTAssertNotNil(d.effects(at: t0.addingTimeInterval(1.5)).shiny)
        XCTAssertEqual(d.effects(at: t0.addingTimeInterval(1.5)).shiny?.opacity ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(d.nextDue(after: t0.addingTimeInterval(1.5))?.timeIntervalSince(t0) ?? 0, 2.6, accuracy: 1e-6)
        XCTAssertNil(d.effects(at: t0.addingTimeInterval(3.11)).shiny)
        let run = sample(d, from: t0, until: 10)
        XCTAssertEqual(run.last, 3.1, accuracy: 0.02)
        XCTAssertLessThan(run.frames, 130, "about 1.1 s + 0.5 s at 60 Hz, not 3.1 s of frames")
    }

    /// Candy "+N XP" (1.3 s and a 0.4 s fade) and mint sparkles (0.9 s and 0.4 s), each consumed as it starts.
    func testCandyAndMintPlayOnceAndEnd() async {
        var input = CompanionHeaderInput()
        input.candyFeedbackAmount = 12_000
        input.candyFeedbackSeq = 2
        input.mintFeedbackNature = .bold
        input.mintFeedbackSeq = 1
        let consumer = RecordingConsumer()
        let d = CompanionCelebrationDriver()
        let t0 = Date(timeIntervalSince1970: 3_000)
        d.poll(input, consumer: consumer, now: t0)
        XCTAssertEqual(consumer.candies, 1)
        XCTAssertEqual(consumer.mints, 1)
        XCTAssertEqual(d.effects(at: t0.addingTimeInterval(1)).candy?.text, "+12K XP")
        XCTAssertNotNil(d.effects(at: t0.addingTimeInterval(0.5)).mint)
        XCTAssertNil(d.effects(at: t0.addingTimeInterval(1.31)).mint)
        XCTAssertNil(d.effects(at: t0.addingTimeInterval(1.71)).candy)
        d.poll(input, consumer: consumer, now: t0.addingTimeInterval(0.1))   // the same sequence numbers again
        XCTAssertEqual(consumer.candies, 1)
        XCTAssertEqual(consumer.mints, 1)
        XCTAssertEqual(sample(d, from: t0, until: 10).last, 1.7, accuracy: 0.02)
    }

    /// The imminent egg wiggles between −5° and +5° along the Mac's eased 0.35 s swing in two steps a swing (−5°, 0°, +5°,
    /// as the eased angle crosses −2.5° and +2.5°), and stops when it is no longer imminent (or animation is off).
    func testTheImminentEggWigglesAlongTheMacsEasedSwing() async {
        var input = CompanionHeaderInput()
        input.eggProgress = 0.95
        let d = CompanionCelebrationDriver()
        let t0 = Date(timeIntervalSince1970: 4_000)
        d.poll(input, consumer: RecordingConsumer(), now: t0)
        XCTAssertEqual(d.effects(at: t0).rotation, -5)
        var poses: [Double] = [], now = t0
        for _ in 0..<8 {
            guard let due = d.nextDue(after: now) else { return XCTFail("the wiggle stopped") }
            now = due
            poses.append(d.effects(at: now).rotation)
        }
        XCTAssertEqual(poses, [0, 5, 0, -5, 0, 5, 0, -5])
        // The Mac's eased angle −5 + 10 × easeInOut(t / 0.35) is −2.5° at the first step and +2.5° at the second.
        let first = d.nextDue(after: t0)?.timeIntervalSince(t0) ?? 0
        XCTAssertEqual(-5 + 10 * PopoverMotion.easeInOut(first / 0.35), -2.5, accuracy: 1e-4)
        XCTAssertEqual(d.nextDue(after: t0.addingTimeInterval(first))?.timeIntervalSince(t0) ?? 0, 0.35 - first, accuracy: 1e-6)
        XCTAssertFalse(d.isCelebrating)
        input.eggProgress = 0.5
        d.poll(input, consumer: RecordingConsumer(), now: t0.addingTimeInterval(1))
        XCTAssertEqual(d.effects(at: t0.addingTimeInterval(1)).rotation, 0)
        XCTAssertNil(d.nextDue(after: t0.addingTimeInterval(1)))
        input.eggProgress = 0.95
        d.poll(input, consumer: RecordingConsumer(), now: t0.addingTimeInterval(2), animates: false)
        XCTAssertNil(d.nextDue(after: t0.addingTimeInterval(2)))
    }

    /// The one-shot contract on a real store (the Mac's `testCelebrationFiresOnHatchAndEvolve`, driven by the Windows
    /// driver): a hatch fires the celebration; the header that shows it consumes it once; a second header (the popover
    /// opened again) finds nothing to play; an evolution fires `.evolve`, played once again.
    func testACelebrationIsConsumedOnceEvenWhenThePopoverOpensTwice() async {
        let s = await CompanionHeaderFixtures.store(eggUsage: 1)
        await s.hatch(baseID: 1)
        XCTAssertEqual(s.celebration, .hatch(shiny: s.currentIsShiny))
        let firstOpen = CompanionCelebrationDriver()
        XCTAssertTrue(firstOpen.poll(CompanionHeaderInput(store: s), consumer: s, now: Date()))
        XCTAssertNil(s.celebration, "consumed as it starts")
        XCTAssertFalse(firstOpen.poll(CompanionHeaderInput(store: s), consumer: s, now: Date()), "an observation after the consume plays nothing")
        let secondOpen = CompanionCelebrationDriver()
        XCTAssertFalse(secondOpen.poll(CompanionHeaderInput(store: s), consumer: s, now: Date()), "the popover opened again: nothing replays")
        XCTAssertEqual(firstOpen.plays + secondOpen.plays, 1)
        s.applyUsage(s.threshold)
        XCTAssertEqual(s.celebration, .evolve)
        XCTAssertTrue(secondOpen.poll(CompanionHeaderInput(store: s), consumer: s, now: Date()))
        XCTAssertNil(s.celebration)
        XCTAssertEqual(secondOpen.plays, 1)
    }

    /// The Windows selftest's plain-hatch fixture (companion.celebrate, whose 2.6 s budget is the plain hatch's) rolls on
    /// `PlainRolls`: no draw of them is a shiny, with or without the charm, so the hatch is plain however many draws come
    /// before it. Run 43967277783 hatched on system dice and rolled the 1-in-64 shiny (3.1 s by design).
    func testThePlainHatchFixtureNeverRollsAShiny() async {
        var dice = CompanionHeaderSamples.PlainRolls()
        let shinies = (0..<10_000).map { _ in dice.next() }.filter {
            CompanionStore.rollsShiny(roll: $0, charmOwned: false) || CompanionStore.rollsShiny(roll: $0, charmOwned: true)
        }
        XCTAssertEqual(shinies.count, 0)
        // The selftest's construction: the sample provider, one token in the egg, base 1.
        var state = CompanionState()
        state.eggUsage = 1
        state.installBaselineSet = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-plain-hatch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("companion-state.json")
        try? JSONEncoder().encode(state).write(to: url)
        let store = CompanionStore(provider: CompanionSamplePoke(), fileURL: url, rng: CompanionHeaderSamples.PlainRolls(),
                                   dittoDisguiseRollingEnabled: false, defaults: TestDefaults.make(suite: "companion.plain-hatch"))
        await store.hatch(baseID: 1)
        XCTAssertEqual(store.celebration, .hatch(shiny: false))
        XCTAssertEqual(store.currentIsShiny, false)
    }
}

@MainActor final class RecordingConsumer: CompanionFeedbackConsuming {
    var celebrations = 0, candies = 0, mints = 0
    func consumeCelebration() { celebrations += 1 }
    func consumeCandyFeedback() { candies += 1 }
    func consumeMintFeedback() { mints += 1 }
}
