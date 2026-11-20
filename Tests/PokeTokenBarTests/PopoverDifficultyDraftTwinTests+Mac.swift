import XCTest
@testable import PokeTokenBar

/// The shared twins of the Settings page's Difficulty and Backup & transfer logic behave as the Mac's originals (stage 7 Task 15,
/// D8). Mac only: `DifficultyDraft` and `SettingsView` are upstream SwiftUI files. The text side of the same promise is
/// `PopoverParityScanTests.testTwinsMatchTheirOriginals` (twins.txt).
@MainActor
final class PopoverDifficultyDraftTwinTests: XCTestCase {
    private struct Offline: PokeProviding {
        struct Unavailable: Error {}
        func line(baseSpeciesID: Int) async throws -> EvoLine { throw Unavailable() }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { throw Unavailable() }
        func baseSpecies(id: Int) async throws -> BaseSpecies? { throw Unavailable() }
    }

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func store(growth: Double, shop: Double, egg: Int) throws -> CompanionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-twin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("companion-state.json")
        var state = CompanionState()
        state.eggUsage = egg
        try JSONEncoder().encode(state).write(to: file)
        let defaults = TestDefaults.make(suite: "ptb.twin.difficulty")
        defaults.set(growth, forKey: "growthDifficulty")
        defaults.set(shop, forKey: "shopDifficulty")
        return CompanionStore(provider: Offline(), fileURL: file, defaults: defaults)
    }

    /// The same random edits, the same Save, on a Mac draft and its twin, each over its own identical store: every observable agrees.
    func testTheTwinDraftBehavesAsTheMacsOverRandomEdits() async throws {
        var rng = SplitMix(state: 0x15)
        for round in 0..<60 {
            let growth = Double.random(in: 0.1...2, using: &rng), shop = Double.random(in: 0.1...2, using: &rng)
            let egg = Int.random(in: 0...150_000_000, using: &rng)
            let macStore = try store(growth: growth, shop: shop, egg: egg), twinStore = try store(growth: growth, shop: shop, egg: egg)
            var mac = DifficultyDraft(companion: macStore)
            var twin = PopoverDifficultyDraft(companion: twinStore)
            XCTAssertEqual([mac.growth, mac.shop], [twin.growth, twin.shop], "round \(round)")
            for _ in 0..<3 {
                let g = PopoverDifficultySlider.value(atPosition: Int.random(in: 0...PopoverDifficultySlider.resolution, using: &rng))
                let s = PopoverDifficultySlider.value(atPosition: Int.random(in: 0...PopoverDifficultySlider.resolution, using: &rng))
                if Bool.random(using: &rng) { mac.growth = g; twin.growth = g }
                if Bool.random(using: &rng) { mac.shop = s; twin.shop = s }
                XCTAssertEqual(mac.differs(from: macStore), twin.differs(from: twinStore), "round \(round)")
            }
            mac.save(to: macStore)
            twin.save(to: twinStore)
            XCTAssertEqual([mac.growth, mac.shop], [twin.growth, twin.shop], "round \(round)")
            XCTAssertEqual([macStore.growthDifficulty, macStore.shopDifficulty], [twinStore.growthDifficulty, twinStore.shopDifficulty])
            XCTAssertEqual(macStore.state.eggUsage, twinStore.state.eggUsage, "round \(round): the banked progress was rescaled the same")
            XCTAssertEqual(mac.differs(from: macStore), twin.differs(from: twinStore))
        }
    }

    func testTheExportedAtTextIsTheMacs() async throws {
        for language in AppLanguage.allCases {
            for seconds in [0.0, 1_700_000_000, 1_790_000_123] {
                let date = Date(timeIntervalSince1970: seconds)
                XCTAssertEqual(PopoverTransferFormat.exportedAtText(date, language: language), SettingsView.exportedAtText(date, language: language),
                               "\(language) \(seconds)")
            }
        }
    }
}
