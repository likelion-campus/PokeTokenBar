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
}
