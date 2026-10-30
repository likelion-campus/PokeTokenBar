import XCTest
@testable import PokeTokenBar

final class TeamProfileBuilderTests: XCTestCase {
    private func mon(path: [Int], stage: Int = 0, shiny: Bool = false, disguise: Int? = nil,
                     revealed: Bool = false) -> MonState {
        MonState(baseID: path[0], pathIDs: path, stageIndex: stage, usedAtStage: 123_456, rarity: .common,
                 totalForms: path.count, isShiny: shiny, dittoDisguise: disguise, dittoRevealed: revealed)
    }

    private func profile(_ active: MonState?, dex: [CompanionStore.DexSpecies] = []) -> TeamMemberProfile {
        var state = CompanionState()
        state.active = active
        return TeamProfileBuilder.profile(memberID: "m1", nickname: "도토리", state: state, dexSpecies: dex,
                                          speciesName: { "P\($0)" })
    }

    func testEggProfileHasNoSpecies() {
        let p = profile(nil)
        XCTAssertNil(p.current.speciesID)
        XCTAssertNil(p.current.speciesName)
        XCTAssertFalse(p.current.isShiny)
        XCTAssertEqual(p.memberID, "m1")
        XCTAssertEqual(p.nickname, "도토리")
    }

    func testActiveProfileUsesCurrentStageAndShiny() {
        let p = profile(mon(path: [1, 2, 3], stage: 1, shiny: true))
        XCTAssertEqual(p.current.speciesID, 2)
        XCTAssertEqual(p.current.speciesName, "P2")
        XCTAssertTrue(p.current.isShiny)
    }

    func testDisguisedDittoShowsDisguiseWithoutShiny() {
        let hidden = profile(mon(path: [1], shiny: true, disguise: 1))
        XCTAssertEqual(hidden.current.speciesID, 1)
        XCTAssertFalse(hidden.current.isShiny)
        let revealed = profile(mon(path: [1], shiny: true, disguise: 1, revealed: true))
        XCTAssertTrue(revealed.current.isShiny)
    }

    func testDexIsCopiedFieldByField() {
        let dex = [CompanionStore.DexSpecies(id: 25, name: "Pikachu", rarity: .rare, isShiny: true, isRaising: true,
                                             form: nil, names: nil, hasNormal: false)]
        let p = profile(nil, dex: dex)
        XCTAssertEqual(p.dex, [TeamDexSpecies(speciesID: 25, form: nil, name: "Pikachu", rarity: .rare,
                                              hasShiny: true, hasNormal: false)])
    }

    func testProfileJSONHasNoUsageNumbers() throws {
        let dex = [CompanionStore.DexSpecies(id: 25, name: "Pikachu", rarity: .rare, isShiny: false, isRaising: true)]
        let json = String(decoding: try JSONEncoder().encode(profile(mon(path: [1, 2]), dex: dex)), as: UTF8.self)
        for banned in ["token", "Token", "cost", "usage", "limit", "progress", "usedAt", "123456"] {
            XCTAssertFalse(json.contains(banned), banned)
        }
    }
}
