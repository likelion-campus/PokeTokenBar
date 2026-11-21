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

    func testEvolutionStageIsThePlaceInItsOwnLine() async {
        let s = state()
        XCTAssertEqual(s.evolutionStage(of: 172), 1)
        XCTAssertEqual(s.evolutionStage(of: 25), 2)
        XCTAssertEqual(s.evolutionStage(of: 2), 2, "from the graduation record")
        XCTAssertEqual(s.evolutionStage(of: 3), 3)
        XCTAssertEqual(s.evolutionStage(of: 26), 1, "Raichu is not reached yet")
        XCTAssertEqual(s.evolutionStage(of: 999), 1)
    }

    /// The plaza character is the representative Pokémon: the companion while following it, or a picked dex species.
    func testRepresentativeEvolutionStageFollowsThePlazaCharacter() async throws {
        let s = try store(state())
        XCTAssertEqual(s.representativeSubject.speciesID, 25)
        XCTAssertEqual(s.representativeEvolutionStage, 2, "Pikachu, followed")
        XCTAssertTrue(s.setRepresentativeSpeciesID(3))
        XCTAssertEqual(s.representativeEvolutionStage, 3, "Venusaur, picked")
        let egg = try store(CompanionState())
        XCTAssertNil(egg.representativeSubject.speciesID)
        XCTAssertEqual(egg.representativeEvolutionStage, 1, "an egg pushes one tile")
    }

    // MARK: - Body size (PR 2)

    private func body(_ x: Int, _ y: Int, _ c: Int) -> PlazaBody { PlazaBody(foot: TilePoint(x: x, y: y), size: c) }

    func testATackleReachesAsFarAsTheBodiesTouch() {
        XCTAssertTrue(body(5, 8, 3).touches(body(5, 5, 1)))
        XCTAssertFalse(body(5, 9, 3).touches(body(5, 5, 1)))
        XCTAssertTrue(body(5, 2, 1).touches(body(5, 5, 3)))
        XCTAssertFalse(body(5, 1, 1).touches(body(5, 5, 3)))
    }

    /// Spec 6.6: a tackler on an earlier version still pushes.
    func testEveryOldReachStillReaches() {
        for ca in 1...3 { for cb in 1...3 {
            for dx in -4...4 { for dy in -4...4 {
                let from = TilePoint(x: 10, y: 10), to = TilePoint(x: 10 + dx, y: 10 + dy)
                if LegacyPlazaTackle.pushes(from: from, to: to) {
                    XCTAssertTrue(PlazaBody(foot: from, size: ca).touches(PlazaBody(foot: to, size: cb)), "\(ca) \(cb) \(dx) \(dy)")
                }
            } }
        } }
    }

    func testThePushGoesFromTheTacklerElseAlongTheLongerAxisElseTheirFacing() {
        let me = TilePoint(x: 5, y: 5)
        func dir(_ x: Int, _ y: Int, _ f: PlazaDirection = .down) -> PlazaDirection {
            PlazaTargeting.turn(from: TilePoint(x: x, y: y), to: me, facing: f)
        }
        XCTAssertEqual(dir(5, 6), .up)
        XCTAssertEqual(dir(5, 8), .up)
        XCTAssertEqual(dir(7, 6), .left)
        XCTAssertEqual(dir(6, 6, .down), .down)
        XCTAssertEqual(dir(6, 6, .right), .right)
    }
}
