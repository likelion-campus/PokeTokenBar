import XCTest
@testable import PokeTokenBar

private struct OfflineLineProvider: PokeProviding {
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw CancellationError() }
}

/// How far a plaza tackle pushes: the tackler's evolution stage, from the representative Pokémon on the plaza.
@MainActor
final class PlazaTackleReachTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Pichu, Pikachu, Raichu: the companion has reached Pikachu. Bulbasaur's line graduated as Venusaur.
    private func state() -> CompanionState {
        var s = CompanionState()
        s.active = MonState(baseID: 172, pathIDs: [172, 25, 26], stageIndex: 1, usedAtStage: 0,
                            rarity: .common, totalForms: 3)
        s.dex = [DexEntry(baseID: 1, finalID: 3, chainOrder: [1, 2, 3], rarity: .common, caughtAt: now)]
        return s
    }

    private func store(_ state: CompanionState) throws -> CompanionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("companion-state.json")
        try JSONEncoder().encode(state).write(to: url)
        let suite = "reach-tests-\(UUID().uuidString)"
        let date = now
        return CompanionStore(provider: OfflineLineProvider(), clock: { date }, fileURL: url,
                              dittoDisguiseRollingEnabled: false, defaults: TestDefaults.make(suite: suite))
    }

    func testEvolutionStageIsThePlaceInItsOwnLine() {
        let s = state()
        XCTAssertEqual(s.evolutionStage(of: 172), 1)
        XCTAssertEqual(s.evolutionStage(of: 25), 2)
        XCTAssertEqual(s.evolutionStage(of: 2), 2, "from the graduation record")
        XCTAssertEqual(s.evolutionStage(of: 3), 3)
        XCTAssertEqual(s.evolutionStage(of: 26), 1, "Raichu is not reached yet")
        XCTAssertEqual(s.evolutionStage(of: 999), 1)
    }

    /// The plaza character is the representative Pokémon: the companion while following it, or a picked dex species.
    func testRepresentativeEvolutionStageFollowsThePlazaCharacter() throws {
        let s = try store(state())
        XCTAssertEqual(s.representativeSubject.speciesID, 25)
        XCTAssertEqual(s.representativeEvolutionStage, 2, "Pikachu, followed")
        XCTAssertTrue(s.setRepresentativeSpeciesID(3))
        XCTAssertEqual(s.representativeEvolutionStage, 3, "Venusaur, picked")
        let egg = try store(CompanionState())
        XCTAssertNil(egg.representativeSubject.speciesID)
        XCTAssertEqual(egg.representativeEvolutionStage, 1, "an egg pushes one tile")
    }
}
