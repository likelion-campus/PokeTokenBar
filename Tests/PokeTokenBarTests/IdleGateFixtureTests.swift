import XCTest
@testable import PokeTokenBar

/// The idle gate's companion state (`scripts/windows/fixtures/idle-companion-state.json`, copied into the installed app's state
/// directory by `idle-gate.ps1` for the Collection and detail windows): 40 species, every 7th shiny, no usage, no real names.
/// `PTB_WRITE_IDLE_FIXTURE=1` rewrites the file; otherwise the test holds it to what the gate expects.
@MainActor
final class IdleGateFixtureTests: XCTestCase {
    private var url: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/windows/fixtures/idle-companion-state.json")
    }

    static func make() -> CompanionState {
        var state = CompanionState()
        state.language = .en
        let rarities: [Rarity] = [.common, .uncommon, .rare, .legendary]
        state.dex = (1...40).map { id in
            DexEntry(id: "idle-\(id)", baseID: id, finalID: id, chainOrder: [id], rarity: rarities[id % 4],
                     caughtAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(id) * 3600), isShiny: id % 7 == 0,
                     names: [id: ["en": "Species \(id)", "ko": "종 \(id)"]])
        }
        return state
    }

    func testTheCommittedFixtureIsWhatTheGateExpects() async throws {
        if ProcessInfo.processInfo.environment["PTB_WRITE_IDLE_FIXTURE"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Self.make()).write(to: url)
        }
        let state = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url))
        XCTAssertEqual(state.dex.count, 40)
        XCTAssertEqual(state.dex.filter(\.isShiny).count, 5)
        XCTAssertTrue(state.dex.allSatisfy { $0.names?[$0.finalID]?["en"] == "Species \($0.finalID)" })
    }
}
