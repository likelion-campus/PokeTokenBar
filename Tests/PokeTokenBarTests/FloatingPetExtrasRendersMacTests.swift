import SwiftUI
import XCTest
@testable import PokeTokenBar

/// The Mac's own `FloatingPetView` for the pet extras' capture states (stage 7 Task 23): the agent speech bubbles (waiting with
/// a label and two more, done), the hearts after strokes and a prayer particle at mid-flight, rendered offscreen
/// (`ImageRenderer`, no window) as the reference next to which the Windows runner's pictures are put. Env-gated writer:
/// `PTB_WRITE_PET_RENDERS=<dir>` with `PTB_FIXTURE_SPRITES=<dir>`; without them it does nothing. At scale 1 over white, the panel
/// size the Mac gives the pet with a bubble (`panelSize(petSize:showingBubble:)`).
@MainActor
final class FloatingPetExtrasRendersMacTests: XCTestCase {
    func testRenderTheMacPetExtrasForEveryCaptureState() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["PTB_WRITE_PET_RENDERS"].map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let sprites = env["PTB_FIXTURE_SPRITES"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw XCTSkip("set PTB_WRITE_PET_RENDERS and PTB_FIXTURE_SPRITES to write the Mac renders")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let defaults = TestDefaults.make(suite: "pet.extras.renders")
        let spriteStore = SpriteStore(directory: sprites)
        let waiting = AgentActivitySummary(done: nil, waiting: .init(label: "poketokenbar", message: "Approve the plan before I continue"),
                                           otherWaitingCount: 2, working: true)
        let done = AgentActivitySummary(done: .init(label: nil, message: nil), waiting: nil, otherWaitingCount: 0, working: false)
        let cases: [(String, CompanionHeaderSample, AppLanguage, AgentActivitySummary, Bool)] = [
            ("bubble-waiting-en", .hatched, .en, waiting, false), ("bubble-waiting-ko", .hatched, .ko, waiting, false),
            ("bubble-done-en", .hatched, .en, done, false), ("hearts-en", .hatched, .en, AgentActivitySummary(), true),
        ]
        var written: [String] = []
        for (name, sample, language, summary, hearts) in cases {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-pet-extras-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let companion = await CompanionHeaderSamples.store(sample, language: language, defaults: defaults, directory: dir)
            let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
            store.floatingPetSize = 96
            store.floatingPetEnabled = true
            let agent = FloatingPetAgentModel()
            agent.summary = summary
            let heartState = PetHeartState()
            heartState.isShowing = hearts
            let size = FloatingPetController.panelSize(petSize: 96, showingBubble: true)
            let view = FloatingPetView(animated: false, agent: agent, spriteStore: spriteStore, hearts: heartState)
                .environment(store).environment(companion)
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try data.write(to: out.appendingPathComponent("mac-pet-\(name).png"))
            written.append(name)
        }
        // One prayer particle at mid-flight over a 96-point box (the frame the Windows capture takes at the same progress).
        let particle = PrayerEmojiFrame(xFraction: 0.5, petSize: 96, emojiSize: PrayerEmojiLayer.emojiSize(petSize: 96), progress: 0.5)
            .frame(width: 96, height: 96).background(Color.white)
        let renderer = ImageRenderer(content: particle)
        renderer.scale = 1
        if let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try data.write(to: out.appendingPathComponent("mac-pet-prayer-mid.png"))
            written.append("prayer-mid")
        }
        print("PET-EXTRAS-RENDERS \(written.count) written to \(out.path): \(written.joined(separator: ", "))")
        XCTAssertEqual(written.count, cases.count + 1)
    }
}
