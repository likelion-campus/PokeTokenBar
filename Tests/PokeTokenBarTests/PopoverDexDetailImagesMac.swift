import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PokeTokenBar

/// Stage 7 Task 21: the Mac's own SwiftUI `PokemonDetailView` rendered offscreen (`ImageRenderer`, no window) next to the shared
/// `DexDetailPart` drawn on the Mac canvas, for the PR sheet (`PTB_DEX_PNG_DIR`); without the variable it only checks both render.
/// Sprites are not part of either picture here (SwiftUI's come from the sprite store, offline; the part's are host slots).
@MainActor
final class PopoverDexDetailImagesMac: XCTestCase {
    private struct Provider: PokeProviding, PokemonDetailProviding {
        func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
        func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
        func pokemonDetails(speciesID: Int) async throws -> PokemonDetails {
            PokemonDetails(speciesID: speciesID, name: "bulbasaur", height: 7, weight: 69, baseExperience: 64, genderRate: 1, types: ["grass", "poison"],
                           baseStats: ["hp": 45, "attack": 49, "defense": 49, "special-attack": 65, "special-defense": 65, "speed": 45],
                           abilities: [PokemonAbilityOption(name: "overgrow", slot: 1, isHidden: false), PokemonAbilityOption(name: "chlorophyll", slot: 3, isHidden: true)],
                           moves: (0..<30).map { PokemonMoveOption(name: "move-\($0)", learnMethods: [PokemonMoveLearnMethod(method: "level-up", level: $0), PokemonMoveLearnMethod(method: "machine", level: 0)]) })
        }
    }

    func testTheDetailPageOnTheMacAndOnTheSharedPart() async throws {
        let dir = ProcessInfo.processInfo.environment["PTB_DEX_PNG_DIR"].map { URL(fileURLWithPath: $0) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for language in [AppLanguage.en, .ko] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-detail-img-\(UUID()).json")
            addTeardownBlock { try? FileManager.default.removeItem(at: file) }
            var state = CompanionState()
            state.language = language
            var profile = PokemonProfile.generate(seed: 42, instanceID: "img")
            profile.level = 16
            profile.moves = [PokemonKnownMove(name: "tackle", learnedAtLevel: 1), PokemonKnownMove(name: "vine-whip", learnedAtLevel: 7)]
            state.dex = [DexEntry(id: "img-1", baseID: 1, finalID: 1, chainOrder: [1], rarity: .rare, caughtAt: Date(timeIntervalSince1970: 1_700_000_000), isShiny: true,
                                  nature: .adamant, profile: profile, names: [1: ["en": "Bulbasaur", "ko": "이상해씨"]])]
            try JSONEncoder().encode(state).write(to: file)
            let store = CompanionStore(provider: Provider(), detailProvider: Provider(), fileURL: file, rng: SeededRNG(seed: 1))
            await store.loadPokemonDetails(speciesID: 1)
            let species = try XCTUnwrap(store.dexSpecies.first)
            // the Mac's view
            let view = PokemonDetailView(store: store, species: species, onBack: {})
                .frame(width: PopoverMetrics.contentWidth, height: 520)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            // NSHostingView drawn into a bitmap without a window (nothing is ordered in, no focus is taken)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.contentWidth, height: 520)
            host.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let mac = try XCTUnwrap(rep.cgImage)
            XCTAssertGreaterThan(mac.width, 100)
            // the shared part
            let graphics = PlatformPlaza.graphics
            let part = DexDetailPart(DexDetailModel.make(store: store, species: species, state: DexDetailState(), names: [:], failed: []), height: 520)
            let size = part.size(width: 332, scale: 2, text: graphics.text)
            let drawing = part.render(scale: 2, graphics: graphics)
            XCTAssertFalse(drawing.drawing.layers.isEmpty)
            guard let dir else { continue }
            func write(_ image: CGImage, _ name: String) {
                let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
            write(mac, "mac-swiftui-detail-\(language.rawValue).png")
            let w = Int(size.width * 2), h = Int(size.height * 2)
            var bytes = PopoverComposite.compose(drawing.drawing.layers, width: w, height: h, scale: 2)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let keep = 255 - Int(bytes[i + 3])
                for c in 0..<3 { bytes[i + c] = UInt8(min(255, Int(bytes[i + c]) + 255 * keep / 255)) }
                bytes[i + 3] = 255
                bytes.swapAt(i, i + 2)
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let canvas = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            write(canvas, "mac-canvas-detail-\(language.rawValue).png")
        }
    }
}
