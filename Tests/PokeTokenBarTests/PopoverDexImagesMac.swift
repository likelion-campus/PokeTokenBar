import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PokeTokenBar

/// Stage 7 Task 20: writes the Collection parts as the Mac canvas draws them (sample data, offscreen, no window) to the folder in
/// `PTB_DEX_PNG_DIR`, for the PR images; without the variable it only checks the renders are not blank. The sprites are not part
/// of a part's picture (the host paints them), so each slot shows a labelled stand-in square here. Mac only: CoreGraphics.
@MainActor
final class PopoverDexImagesMac: XCTestCase {
    private func store(count: Int, language: AppLanguage) throws -> CompanionStore {
        struct Offline: PokeProviding {
            func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
            func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
            func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-img-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = language
        let rarities: [Rarity] = [.common, .uncommon, .rare, .legendary]
        let names = ["Bulbasaur", "Ivysaur", "Venusaur", "Charmander", "Charmeleon", "Charizard", "Squirtle", "Wartortle", "Blastoise", "Pikachu"]
        var dex: [DexEntry] = []
        for id in 1...count {
            let chain: [Int] = id % 3 == 0 ? [id - 2, id - 1, id] : [id]
            var named: [Int: [String: String]] = [:]
            for n in chain {
                let en: String = n <= 10 ? names[n - 1] : "Species \(n)"
                named[n] = ["en": en, "ko": "이름\(n)"]
            }
            dex.append(DexEntry(id: "e\(id)", baseID: chain[0], finalID: id, chainOrder: chain, rarity: rarities[id % 4],
                                caughtAt: Date().addingTimeInterval(-Double(id) * 5400), isShiny: id % 7 == 0, names: named))
        }
        state.dex = dex
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: Offline(), fileURL: file, rng: SeededRNG(seed: 3))
    }

    private func png(_ drawing: PopoverDrawing, size: CGSize, to url: URL, scale: CGFloat) throws {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        var bytes = PopoverComposite.compose(drawing.drawing.layers, width: w, height: h, scale: scale)
        func over(_ top: [UInt8]) {
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(top[i + 3])
                for c in 0..<4 { bytes[i + c] = UInt8(min(255, Int(top[i + c]) + Int(bytes[i + c]) * (255 - a) / 255)) }
            }
        }
        // the sprites' stand-ins (BGRA, premultiplied): a tinted square per slot
        var stand = [UInt8](repeating: 0, count: w * h * 4)
        for slot in drawing.spriteSlots {
            let r = slot.frame
            for y in Int(r.minY * scale)..<min(h, Int(r.maxY * scale)) {
                for x in Int(r.minX * scale)..<min(w, Int(r.maxX * scale)) where x >= 0 && y >= 0 {
                    let o = (y * w + x) * 4
                    stand[o] = 200; stand[o + 1] = 170; stand[o + 2] = 150; stand[o + 3] = 255
                }
            }
        }
        over(stand)
        if !drawing.overlays.isEmpty { over(PopoverComposite.compose(drawing.overlays, width: w, height: h, scale: scale)) }
        for i in stride(from: 0, to: w * h * 4, by: 4) {   // over white
            let keep = 255 - Int(bytes[i + 3])
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, Int(bytes[i + c]) + 255 * keep / 255)) }
            bytes[i + 3] = 255
        }
        var rgba = bytes
        for i in stride(from: 0, to: w * h * 4, by: 4) { rgba.swapAt(i, i + 2) }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testTheCollectionPartsDrawOnTheMacCanvasAndWriteTheirImages() throws {
        let dir = ProcessInfo.processInfo.environment["PTB_DEX_PNG_DIR"].map { URL(fileURLWithPath: $0) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let graphics = PlatformPlaza.graphics
        let scale: CGFloat = 2
        for language in [AppLanguage.en, .ko] {
            let tag = language.rawValue
            let full = try store(count: 120, language: language)
            let few = try store(count: 5, language: language)
            var s = DexBrowserState()
            var cases: [(String, CompanionStore, DexBrowserState)] = [("grid-few-\(tag)", few, s), ("grid-full-\(tag)", full, s)]
            s.selectedID = "3"
            s.page = 2
            cases.append(("grid-selected-\(tag)", full, s))
            var f = DexBrowserState()
            f.toggleRarity(.rare)
            f.setSearch("")
            cases.append(("grid-filter-\(tag)", full, f))
            var n = DexBrowserState()
            n.setSearch("zzz")
            cases.append(("grid-search-none-\(tag)", full, n))
            for (name, st, state) in cases {
                let part = DexBodyPart(DexBodyModel.make(store: st, state: state), height: 456)
                part.raisingText = st.l.dexRaising.uppercased()
                let size = part.size(width: 332, scale: scale, text: graphics.text)
                let d = part.render(scale: scale, graphics: graphics)
                XCTAssertFalse(d.drawing.layers.isEmpty, name)
                if let dir { try png(d, size: size, to: dir.appendingPathComponent("mac-canvas-\(name).png"), scale: scale) }
            }
            for (name, st, state) in [("log-\(tag)", full, DexBrowserState())] {
                let part = DexLogPart(DexLogModel.make(store: st, state: state), height: 456, language: language)
                let size = part.size(width: 332, scale: scale, text: graphics.text)
                let d = part.render(scale: scale, graphics: graphics)
                XCTAssertFalse(d.drawing.layers.isEmpty, name)
                if let dir { try png(d, size: size, to: dir.appendingPathComponent("mac-canvas-\(name).png"), scale: scale) }
            }
            let empty = DexEmptyPart(title: full.l.dexEmptyTitle, hint: full.l.dexEmptyHint)
            let size = empty.size(width: 332, scale: scale, text: graphics.text)
            if let dir { try png(empty.render(scale: scale, graphics: graphics), size: size, to: dir.appendingPathComponent("mac-canvas-empty-\(tag).png"), scale: scale) }
        }
    }
}
