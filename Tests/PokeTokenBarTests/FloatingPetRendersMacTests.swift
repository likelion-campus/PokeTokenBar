import SwiftUI
import XCTest
@testable import PokeTokenBar

/// The Mac's own `FloatingPetView` for the floating pet's capture states (stage 7 Task 22), rendered offscreen (`ImageRenderer`,
/// no window) next to which the Windows runner's pictures of the same states are put. Env-gated writer:
/// `PTB_WRITE_PET_RENDERS=<dir>` with `PTB_FIXTURE_SPRITES=<dir>` (scripts/fetch-fixture-sprites.sh: the public sprite files
/// under the sprite store's cache names). Without the variables it does nothing. At scale 1, so a 96-point pet is 96 pixels,
/// as the Windows picture at 100 %; over white, as the Windows sheet composes it. Offscreen the sprite's `.task` does not run,
/// so an animated pet shows its GIF's first frame (the cache's), the frame the Windows capture takes right after it appears.
@MainActor
final class FloatingPetRendersMacTests: XCTestCase {
    func testRenderTheMacPetForEveryCaptureState() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PTB_WRITE_PET_RENDERS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let sprites = env["PTB_FIXTURE_SPRITES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw XCTSkip("set PTB_WRITE_PET_RENDERS and PTB_FIXTURE_SPRITES to write the Mac renders")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let defaults = TestDefaults.make(suite: "pet.renders")
        let spriteStore = SpriteStore(directory: sprites)
        let cases: [(CompanionHeaderSample, Double, String)] = [(.eggIncubating, 96, "egg-96"), (.hatched, 96, "hatched-96"), (.shiny, 96, "shiny-96"),
                                                                 (.back, 96, "back-96"), (.form, 96, "form-96"), (.hatched, 48, "hatched-48"),
                                                                 (.hatched, 192, "hatched-192"), (.hatched, 384, "hatched-384")]
        var written: [String] = []
        for (sample, size, name) in cases {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-pet-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let companion = await CompanionHeaderSamples.store(sample, language: .en, defaults: defaults, directory: dir)
            let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
            store.floatingPetSize = size
            store.floatingPetEnabled = true
            let view = FloatingPetView(spriteStore: spriteStore)
                .environment(store).environment(companion)
                .frame(width: size, height: size)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try data.write(to: out.appendingPathComponent("mac-pet-\(name).png"))
            written.append(name)
        }
        print("PET-RENDERS \(written.count) written to \(out.path): \(written.joined(separator: ", "))")
        XCTAssertEqual(written.count, cases.count)
    }
}
