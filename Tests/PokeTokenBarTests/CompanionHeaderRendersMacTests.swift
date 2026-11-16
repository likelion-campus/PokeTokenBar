import SwiftUI
import XCTest
@testable import PokeTokenBar

/// The Mac's own `CompanionHeader` for the companion samples (stage 7 Task 9), rendered offscreen (`ImageRenderer`, no window)
/// next to which the Windows captures of the same samples are put. Env-gated writer: `PTB_WRITE_COMPANION_RENDERS=<dir>` with
/// `PTB_FIXTURE_SPRITES=<dir>` (scripts/fetch-fixture-sprites.sh: the public sprite files under the sprite store's cache
/// names). Without the variables it does nothing. The egg art is the app's own memory cache (`SpriteLoader.cachedEggImage`,
/// filled only by a download): offscreen it is empty, so an egg renders as the Mac's 🥚 placeholder here.
@MainActor
final class CompanionHeaderRendersMacTests: XCTestCase {
    func testRenderTheMacHeaderForEverySample() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PTB_WRITE_COMPANION_RENDERS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let sprites = env["PTB_FIXTURE_SPRITES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw XCTSkip("set PTB_WRITE_COMPANION_RENDERS and PTB_FIXTURE_SPRITES to write the Mac renders")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await CompanionHeaderSamples.loadTypeNames(into: .shared)
        let defaults = TestDefaults.make(suite: "companion.renders")
        let spriteStore = SpriteStore(directory: sprites)
        var cases: [(String, CompanionHeaderSample, AppLanguage)] = []
        for lang in [AppLanguage.en, .ko] {
            for sample in CompanionHeaderSample.allCases where sample != .longName { cases.append(("\(name(sample))-\(lang.rawValue)", sample, lang)) }
        }
        cases += [("long-name-de", .longName, .de), ("mid-level-ja", .midLevel, .ja)]
        var written: [String] = []
        for (file, sample, lang) in cases {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-mac-render-\(UUID().uuidString)")
            let store = await CompanionHeaderSamples.store(sample, language: lang, defaults: defaults, directory: dir)
            let view = CompanionHeader(store: store, spriteStore: spriteStore)
                .frame(width: PopoverMetrics.scrollContentWidth, alignment: .leading)
                .padding(PopoverMetrics.padding)
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .environment(\.locale, lang.displayLocale)
            if write(view, to: out.appendingPathComponent("mac-\(file).png")) { written.append(file) }
            try? FileManager.default.removeItem(at: dir)
        }
        // The Mac's nine-node corpus (EvoLineLayoutTests.longNodes) in the popover's width.
        let nodes = [EvoLineItem(.species(133), .current)] + [134, 135, 136, 196, 197, 470, 471, 700].map { EvoLineItem(.species($0), .future) }
        let line = EvoLineView(nodes: nodes, mysteryLabel: L(.en).unknownNextEvolution, maxWidth: PopoverMetrics.scrollContentWidth, spriteStore: spriteStore)
            .padding(PopoverMetrics.padding).background(Color.white).environment(\.colorScheme, .light)
        if write(line, to: out.appendingPathComponent("mac-eevee-long-line.png")) { written.append("eevee-long-line") }
        print("COMPANION-RENDERS \(written.count) written to \(out.path): \(written.joined(separator: ", "))")
        XCTAssertEqual(written.count, cases.count + 1)
    }

    private func name(_ s: CompanionHeaderSample) -> String {
        switch s {
        case .eggFirstRun: "egg-first-run"
        case .eggIncubating: "egg-incubating"
        case .eggImminent: "egg-imminent-guarantee"
        case .hatched: "hatched"
        case .midLevel: "mid-level"
        case .aboutToEvolve: "about-to-evolve"
        case .finalStage: "final"
        case .shiny: "shiny"
        case .form: "form"
        case .back: "back"
        case .graduated: "graduated"
        case .eevee: "eevee"
        case .longName: "long-name"
        }
    }

    private func write(_ view: some View, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// The Mac shows its sprites smoothed although `SpriteView` asks for `.interpolation(.none)`, and the popover on Windows
    /// copies that (`PopoverSpriteScale`, stage 7 Task 9). A sample picture (3-pixel blocks of random colours, opaque) under
    /// the sprite store's name for species 2, drawn by the Mac's `SpriteView` at 76 pt and 2× (152 px from 96), is held next
    /// to the Windows scaler's result and to a nearest one. If the Mac ever turns crisp this fails: switch the scaler back.
    func testTheMacShowsItsSpritesSmoothedAsTheWindowsScalerDoes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sprite-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var source = PlazaBitmap(width: 96, height: 96)
        var rng = SystemRandomNumberGenerator()
        for by in 0..<32 {
            for bx in 0..<32 {
                let c = [UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng)]
                for y in by * 3..<by * 3 + 3 { for x in bx * 3..<bx * 3 + 3 {
                    let i = (y * 96 + x) * 4
                    source.bytes[i] = c[0]; source.bytes[i + 1] = c[1]; source.bytes[i + 2] = c[2]; source.bytes[i + 3] = 255
                } }
            }
        }
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(source.bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 96, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 96 * 4, space: srgb,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                       decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent(SpriteStore.cacheKey(speciesID: 2, animated: false, shiny: false) + ".png"))

        let renderer = ImageRenderer(content: SpriteView(speciesID: 2, size: 76, spriteStore: SpriteStore(directory: dir))
            .frame(width: 76, height: 76).background(Color.white))
        renderer.scale = 2
        let shown = try XCTUnwrap(renderer.cgImage)
        let side = 152
        var mac = [UInt8](repeating: 0, count: side * side * 4)
        let ctx = try XCTUnwrap(CGContext(data: &mac, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(shown, in: CGRect(x: 0, y: 0, width: side, height: side))

        let smooth = PopoverSpriteScale.scaledBGRA(source, width: side, height: side)
        func meanDistance(_ bgraAt: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Double {
            var sum = 0
            for y in 0..<side { for x in 0..<side {
                let i = (y * side + x) * 4, p = bgraAt(x, y)
                sum += abs(Int(mac[i]) - Int(p.2)) + abs(Int(mac[i + 1]) - Int(p.1)) + abs(Int(mac[i + 2]) - Int(p.0))
            } }
            return Double(sum) / Double(side * side * 3)
        }
        let toSmooth = meanDistance { x, y in let i = (y * side + x) * 4; return (smooth[i], smooth[i + 1], smooth[i + 2]) }
        let toNearest = meanDistance { x, y in
            let i = ((y * 96 / side) * 96 + x * 96 / side) * 4
            return (source.bytes[i + 2], source.bytes[i + 1], source.bytes[i])
        }
        XCTAssertGreaterThan(toNearest, 4, "the Mac's render is not the sample picture (did the sprite load?)")
        XCTAssertLessThan(toSmooth, toNearest / 2, "the Mac's sprite is \(toSmooth) per channel from the smooth scaler and \(toNearest) from a nearest one")
    }
}
