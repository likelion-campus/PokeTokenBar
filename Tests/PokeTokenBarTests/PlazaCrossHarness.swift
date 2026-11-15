import Foundation
@testable import PokeTokenBar

/// What both OSes' cross harnesses share: the scene list, the driver and the photo.
@MainActor
enum PlazaCrossHarness {
    static let clockBase: TimeInterval = 1000
    static let warmUpUpdates = 15

    /// The scenes the cross compare renders: the harness scenes that need no cached Pokémon art (`real-sprites` reads the
    /// maintainer's sprite cache, which no runner has) and `base-noon` at the fractional scales.
    static var scenes: [PlazaRenderScene] {
        PlazaRenderScenes.all.filter { $0.name != "real-sprites" } + PlazaRenderScenes.crossExtras
    }

    /// Scenes that exist on the Mac and cannot run elsewhere yet, with the capability they wait for: the compare prints
    /// them as `skipped: needs <capability>` and the Windows harness asserts the list it skipped equals this one.
    static let alwaysSkipped: [(name: String, needs: String)] = [("real-sprites", "the Pokémon sprite cache (not committed)")]

    /// The Mac harness's driving rule (`PlazaRenderRun.run`) on any stage: 15 updates at t = 0, then per frame `step(frame)` and
    /// one update at `clockBase + frame / 60`; at a capture frame 15 more updates at the same time. `capture` runs after them.
    static func drive(_ scene: PlazaRenderScene, stage: any PlazaStage, prepare: (_ setup: PlazaRenderSetup) -> Void = { _ in },
                      capture: (_ frame: Int, _ setup: PlazaRenderSetup) async throws -> Void) async rethrows {
        let setup = scene.build(stage)
        prepare(setup)
        setup.step(0)
        for _ in 0..<warmUpUpdates { setup.scene.stageUpdate(clockBase) }
        let last = scene.captures.max() ?? 0
        guard last > 0 else { return }
        for frame in 1...last {
            setup.step(frame)
            let t = clockBase + Double(frame) / 60
            setup.scene.stageUpdate(t)
            if scene.captures.contains(frame) {
                for _ in 0..<warmUpUpdates { setup.scene.stageUpdate(t) }
                try await capture(frame, setup)
            }
        }
    }

    /// The scene's photo (`PlazaPhotoRenderer`), when the scene takes one: premultiplied RGBA and the plate rectangles.
    static func photo(of scene: PlazaRenderScene, setup: PlazaRenderSetup) -> PlazaCrossCapture? {
        guard setup.photo, let input = setup.scene.photoInput(), let image = PlazaPhotoRenderer.render(input) else { return nil }
        var c = PlazaCrossCapture(stem: "photo-\(scene.name)", kind: .photo, width: image.width, height: image.height, rgba: image.pixels.bytes)
        c.photoRects = PlazaCrossPhoto.textRects(input)
        return c
    }

    static func rgba(fromBGRA bgra: [UInt8]) -> [UInt8] {
        var out = bgra
        var i = 0
        while i + 3 < out.count { out.swapAt(i, i + 2); i += 4 }
        return out
    }
}
