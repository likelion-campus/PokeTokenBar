import XCTest
@testable import PokeTokenBar

private struct DetailProvider: PokeProviding, PokemonDetailProviding {
    var fail = false
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
        if fail { throw URLError(.notConnectedToInternet) }
        return DetailProvider.details(speciesID)
    }
    static func details(_ id: Int, moves: Int = 80) -> PokemonDetails {
        PokemonDetails(speciesID: id, name: "species-\(id)", height: 7, weight: 69, baseExperience: 64, genderRate: 1, types: ["grass", "poison"],
                       baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
                       abilities: [PokemonAbilityOption(name: "overgrow", slot: 1, isHidden: false), PokemonAbilityOption(name: "chlorophyll", slot: 3, isHidden: true)],
                       moves: (0..<moves).map { PokemonMoveOption(name: "move-\($0)", learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: $0), PokemonMoveLearnMethod(method: "machine", level: 0)]) })
    }
}

/// Stage 7 Task 20/21: the detail page's rules (which form, appearance and individual) and its drawn part.
@MainActor
final class DexDetailTests: XCTestCase {
    private func makeStore(fail: Bool = false, entries: [DexEntry]) throws -> CompanionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-detail-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = .en
        state.dex = entries
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: DetailProvider(fail: fail), detailProvider: DetailProvider(fail: fail), fileURL: file, rng: SeededRNG(seed: 5))
    }

    private func entry(_ id: Int, shiny: Bool = false, form: PokemonForm? = nil, level: Int = 12, caught: Double = 0) -> DexEntry {
        var profile = PokemonProfile.generate(seed: UInt64(id * 31 + (shiny ? 1 : 0)), instanceID: "p-\(id)-\(shiny)-\(caught)")
        profile.level = level
        profile.moves = [PokemonKnownMove(name: "move-1", learnedAtLevel: 1), PokemonKnownMove(name: "move-7", learnedAtLevel: 7)]
        return DexEntry(id: "e-\(id)-\(shiny)-\(caught)", baseID: id, finalID: id, chainOrder: [id], rarity: .common,
                        caughtAt: Date(timeIntervalSince1970: 1_700_000_000 + caught), isShiny: shiny, nature: .adamant, profile: profile,
                        names: [id: ["en": "Species \(id)"]], form: form)
    }

    private func species(_ store: CompanionStore, _ id: Int) throws -> CompanionStore.DexSpecies {
        try XCTUnwrap(store.dexSpecies.first { $0.id == id })
    }

    func testTheResolverPicksTheMacsFormAppearanceAndIndividual() async throws {
        let forms = PokemonForm.forms(speciesID: 201)
        let store = try makeStore(entries: [entry(201, form: forms[0]), entry(201, shiny: true, form: forms[1], caught: 5)])
        let sp = try species(store, 201)
        var r = DexDetailResolver(store: store, species: sp)
        // nothing chosen: the first collected form
        XCTAssertEqual(r.displayedSpecies.form, forms[0])
        XCTAssertFalse(r.displayedShiny)
        XCTAssertEqual(r.individuals.count, 1)
        r.selectedForm = forms[1]
        XCTAssertEqual(r.displayedSpecies.form, forms[1])
        XCTAssertTrue(r.displayedShiny)
        // an appearance nobody has falls back to the individuals' own
        r.selectedShiny = false
        XCTAssertTrue(r.displayedShiny)
        XCTAssertEqual(DexDetailResolver.formPickerColumns(formCount: 28), 7)
        XCTAssertEqual(DexDetailResolver.formPickerColumns(formCount: 12), 6)
        XCTAssertEqual(DexDetailResolver.formPickerColumns(formCount: 3), 3)
        XCTAssertEqual(DexDetailResolver.formPickerColumns(formCount: 8), 4)
    }

    func testTheModelShowsLoadingThenDetailsThenUnavailable() async throws {
        let store = try makeStore(entries: [entry(1), entry(2)])
        let sp = try species(store, 1)
        func model() -> DexDetailModel { DexDetailModel.make(store: store, species: sp, state: DexDetailState(), names: [:], failed: []) }
        guard case .loading(let text) = model().content else { return XCTFail("expected loading") }
        XCTAssertEqual(text, store.l.loadingPokemonDetails)
        await store.loadPokemonDetails(speciesID: 1)
        guard case .details(let individual, let base, let speciesCard, let moves) = model().content else { return XCTFail("expected details") }
        let ind = try XCTUnwrap(individual)
        XCTAssertNil(base)
        XCTAssertEqual(ind.stats.count, 6)
        XCTAssertEqual(ind.pairs.first?.value, "12")
        XCTAssertFalse(ind.moves.isEmpty)
        XCTAssertTrue(ind.moves.allSatisfy { $0.detail.hasPrefix("Lv. ") })
        XCTAssertEqual(speciesCard.pairs.map(\.value), ["0.7 m", "6.9 kg", "318"])
        XCTAssertEqual(moves.moves.count, 80)
        XCTAssertTrue(moves.moves[3].detail.contains("Lv. 3") && moves.moves[3].detail.contains("TM"), moves.moves[3].detail)
        XCTAssertEqual(model().identity.types.map(\.text), ["…", "…"])   // names not loaded: the Mac's "…"
        let named = DexDetailModel.make(store: store, species: sp, state: DexDetailState(),
                                        names: [.init(kind: .type, name: "grass"): ["en": "Grass"], .init(kind: .ability, name: "overgrow"): ["en": "Overgrow"]], failed: [])
        XCTAssertEqual(named.identity.types.first?.text, "GRASS")
        // the names the page wants, types and abilities first
        XCTAssertEqual(named.nameResources.prefix(2).map(\.kind), [.type, .type])
        // species 2's entry has no details loaded and a failing provider
        let failing = try makeStore(fail: true, entries: [entry(3)])
        await failing.loadPokemonDetails(speciesID: 3)
        guard case .unavailable(_, let retry) = DexDetailModel.make(store: failing, species: try self.species(failing, 3), state: DexDetailState(), names: [:], failed: []).content
        else { return XCTFail("expected unavailable") }
        XCTAssertEqual(retry, failing.l.retry)
    }

    func testThePickersAppearOnlyWhereTheMacShowsThem() async throws {
        let store = try makeStore(entries: [entry(5), entry(5, shiny: true, caught: 9), entry(5, caught: 3)])
        await store.loadPokemonDetails(speciesID: 5)
        let sp = try species(store, 5)
        // the newest individual is shiny: the page opens on the shiny appearance (one individual, no picker)
        XCTAssertEqual(DexDetailModel.make(store: store, species: sp, state: DexDetailState(), names: [:], failed: []).individualPicker.count, 0)
        let m = DexDetailModel.make(store: store, species: sp, state: DexDetailState(selectedShiny: false), names: [:], failed: [])
        XCTAssertNotNil(m.appearance)                       // normal and shiny both collected
        XCTAssertNil(m.forms)                               // no forms
        XCTAssertEqual(m.individualPicker.count, 2)         // two normal individuals
        XCTAssertEqual(m.individualPicker.filter(\.selected).count, 1)
        let shiny = DexDetailModel.make(store: store, species: sp, state: DexDetailState(selectedShiny: true), names: [:], failed: [])
        XCTAssertEqual(shiny.individualPicker.count, 0)     // one shiny: no picker
        XCTAssertEqual(shiny.identity.shinyLine, "✨ \(store.l.dexShinyLabel)")
        let single = try makeStore(entries: [entry(6)])
        XCTAssertNil(DexDetailModel.make(store: single, species: try self.species(single, 6), state: DexDetailState(), names: [:], failed: []).appearance)
    }

    // MARK: the part

    private func part(_ store: CompanionStore, id: Int, state: DexDetailState = DexDetailState(), moves: Int = 80) async throws -> (DexDetailPart, any PlazaGraphics) {
        await store.loadPokemonDetails(speciesID: id)
        let graphics = PlatformPlaza.graphics
        let p = DexDetailPart(DexDetailModel.make(store: store, species: try species(store, id), state: state, names: [:], failed: []), height: 520)
        _ = p.size(width: 332, scale: 1, text: graphics.text)
        return (p, graphics)
    }

    func testThePartPinsBackAndScrollsTheRestWithItsButtons() async throws {
        let store = try makeStore(entries: [entry(1), entry(1, shiny: true, caught: 4)])
        let (p, graphics) = try await part(store, id: 1)
        let d = p.render(scale: 1, graphics: graphics)
        let back = try XCTUnwrap(d.drawing.accessibility.first { $0.action?.action == DexDetailPart.backAction })
        XCTAssertEqual(p.hit(CGPoint(x: back.frame.midX, y: back.frame.midY))?.action, DexDetailPart.backAction)
        XCTAssertEqual(d.drawing.accessibility.filter { $0.action?.action == DexDetailPart.appearanceAction }.count, 2)
        XCTAssertEqual(d.drawing.accessibility.filter { $0.action?.action == DexDetailPart.repAction }.count, 1)
        let hero = try XCTUnwrap(d.spriteSlots.first { $0.frame.width == 104 })
        XCTAssertTrue(hero.animated)
        XCTAssertEqual(hero.subject?.speciesID, 1)
        let before = d.drawing.accessibility.first { $0.action?.action == DexDetailPart.repAction }?.frame
        XCTAssertTrue(p.scroll(by: 60))
        let after = p.render(scale: 1, graphics: graphics).drawing.accessibility.first { $0.action?.action == DexDetailPart.repAction }?.frame
        XCTAssertEqual((before?.minY ?? 0) - 60, after?.minY ?? 999, accuracy: 0.5)
        // Back stays where it was
        XCTAssertEqual(p.render(scale: 1, graphics: graphics).drawing.accessibility.first { $0.action?.action == DexDetailPart.backAction }?.frame, back.frame)
    }

    func testAHundredsLongMoveListCostsAScreenfulAndNamesAreRequestedForWhatIsInView() async throws {
        let store = try makeStore(entries: [entry(1)])
        let graphics = PlatformPlaza.graphics
        await store.loadPokemonDetails(speciesID: 1)
        let sp = try species(store, 1)
        let model = DexDetailModel.make(store: store, species: sp, state: DexDetailState(), names: [:], failed: [])
        XCTAssertEqual(model.nameResources.filter { $0.kind == .move }.count, 80)
        let p = DexDetailPart(model, height: 520)
        _ = p.size(width: 332, scale: 1, text: graphics.text)
        _ = p.render(scale: 1, graphics: graphics)
        XCTAssertTrue(p.visibleMoveKeys().isEmpty || p.visibleMoveKeys().count < 80)
        _ = p.scroll(by: .greatestFiniteMagnitude)
        _ = p.render(scale: 1, graphics: graphics)
        let atEnd = p.visibleMoveKeys()
        XCTAssertTrue(atEnd.contains("move-79"))
        XCTAssertFalse(atEnd.contains("move-0"), "rows far above the view are not requested")
        XCTAssertLessThan(atEnd.count, 60)
        // thumb drag
        let lay = try XCTUnwrap(p.laid)
        p.scroll(by: -.greatestFiniteMagnitude)
        _ = p.render(scale: 1, graphics: graphics)
        let thumb = try XCTUnwrap(p.thumbRect(try XCTUnwrap(p.laid)))
        XCTAssertEqual(p.hit(CGPoint(x: thumb.midX, y: thumb.midY))?.action, DexDetailPart.thumbAction)
        p.setPointer(CGPoint(x: thumb.midX, y: thumb.midY + 80))
        XCTAssertGreaterThan(p.scrollY, 0)
        _ = lay
    }

    func testTheFormGridDisablesFormsNobodyCollected() async throws {
        let forms = PokemonForm.forms(speciesID: 201)
        let store = try makeStore(entries: [entry(201, form: forms[0]), entry(201, shiny: true, form: forms[2], caught: 2)])
        let (p, graphics) = try await part(store, id: 201)
        let d = p.render(scale: 1, graphics: graphics)
        let cells = d.drawing.accessibility.filter { $0.action?.action == DexDetailPart.formAction }
        XCTAssertGreaterThan(cells.count, 6, "the grid shows every form, collected or not")
        XCTAssertEqual(cells.filter(\.isEnabled).count, 2)
        XCTAssertEqual(cells.filter { $0.value == store.l.formNotCollected }.count, cells.count - 2)
        let enabled = try XCTUnwrap(cells.first { $0.isEnabled })
        XCTAssertEqual(p.hit(CGPoint(x: enabled.frame.midX, y: enabled.frame.midY))?.action, DexDetailPart.formAction)
        let disabled = try XCTUnwrap(cells.first { !$0.isEnabled })
        XCTAssertNil(p.hit(CGPoint(x: disabled.frame.midX, y: disabled.frame.midY)))
        XCTAssertTrue(d.spriteSlots.contains { $0.opacity == 0.25 })
    }
}
