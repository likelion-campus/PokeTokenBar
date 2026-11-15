import Foundation
@testable import PokeTokenBar

/// The Mac's plaza photos, the reference the Windows photo must match (stage 6 Task 12). Eight of the harness's nine photo scenes
/// (`PlazaPreviewScenes.photoScenes`; the ninth, `real-sprites`, needs cached Pokémon art) are built from fixture bytes, driven to
/// their last capture frame, and photographed offscreen by the shared `PlazaPhotoRenderer` through `PlatformPlaza.graphics`
/// (CoreGraphics on the Mac, the Windows canvas on Windows). The Mac's PNGs and the name-plate cells live in
/// `Tests/PlazaParityGoldens/photos/` (outside the test target, read through `#filePath`) and are written by
///
///     TZ=UTC PTB_PLAZA_GOLDENS_WRITE=1 swift test --filter PlazaPhotoGoldensMacTests/testWritePhotoGoldens
///
/// UTC because the scenes' wall clock is built with `Calendar.current` and the item spawn follows the real instant: the Windows
/// runner is UTC, so the goldens are too.
///
/// `plateCells`: the 8 x 8 photo-pixel cells where the photo differs from the same photo without any name plate or bubble. Those
/// are text, drawn by each OS's own engine; the compare is report-only inside them (the union of the Mac's and Windows' cells).
struct PlazaPhotoGoldenManifest: Codable {
    struct Entry: Codable {
        var width: Int, height: Int
        /// [x, y] cell indices (photo pixel / `PlazaPhotoGoldens.cell`).
        var plateCells: [[Int]]
    }
    var scenes: [String: Entry]
}

@MainActor
enum PlazaPhotoGoldens {
    static let cell = 8
    static var directory: URL { PlazaParityGoldens.directory.appendingPathComponent("photos", isDirectory: true) }
    static func pngURL(_ scene: String) -> URL { directory.appendingPathComponent("\(scene).png") }
    static func loadManifest() throws -> PlazaPhotoGoldenManifest {
        try JSONDecoder().decode(PlazaPhotoGoldenManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    /// The scene's photo input at its last capture frame (the harness takes the photo at the end of the run).
    static func photoInput(_ scene: PlazaPreviewScenes.Scene) async -> PlazaPhotoInput? {
        var input: PlazaPhotoInput?
        await PlazaPreviewScenes.run(scene, stage: PlazaHeadlessStage(size: CGSize(width: 960, height: 640))) { frame, setup in
            if frame == scene.captures.max() { input = setup.scene.photoInput() }
        }
        return input
    }

    /// The same input with every name plate and speech bubble taken off.
    static func withoutText(_ input: PlazaPhotoInput) -> PlazaPhotoInput {
        var copy = input
        copy.actors = input.actors.map { a in
            var b = PlazaPhotoActor(image: a.image, flipped: a.flipped, foot: a.foot, bob: a.bob, scale: a.scale, shadow: a.shadow,
                                    shadowRect: a.shadowRect, front: a.front, plate: nil, bubble: nil, opacity: a.opacity,
                                    plateBaseY: a.plateBaseY, sink: a.sink, waterClip: a.waterClip, eggSunk: a.eggSunk)
            b.lift = a.lift; b.squash = a.squash; b.tilt = a.tilt
            return b
        }
        return copy
    }

    /// Cells of the photo that hold text on this OS: where the photo differs from the text-less one.
    static func plateCells(_ input: PlazaPhotoInput, photo: PlazaImage) -> Set<[Int]> {
        guard let bare = PlazaPhotoRenderer.render(withoutText(input)), bare.width == photo.width, bare.height == photo.height else { return [] }
        let a = photo.pixels.bytes, b = bare.pixels.bytes
        var cells = Set<[Int]>()
        for y in 0..<photo.height {
            for x in 0..<photo.width where a[(y * photo.width + x) * 4..<(y * photo.width + x) * 4 + 4] != b[(y * photo.width + x) * 4..<(y * photo.width + x) * 4 + 4] {
                cells.insert([x / cell, y / cell])
            }
        }
        return cells
    }

    struct Comparison {
        var width = 0, height = 0
        var maxOutside = 0          // worst channel difference outside every plate cell
        var wrongOutside = 0        // pixels outside plate cells that differ by more than the tolerance
        var pixelsOutside = 0
        var worstAt = ""
        var differInPlates = 0, pixelsInPlates = 0
        var sizeMatches = true
    }

    /// `got` against the Mac's `want` (both premultiplied RGBA, row 0 on top). Inside `mask` cells nothing is judged.
    static func compare(got: PlazaImage, want: PlazaImage, mask: Set<[Int]>, tolerance: Int) -> Comparison {
        var c = Comparison(width: want.width, height: want.height)
        guard got.width == want.width, got.height == want.height else { c.sizeMatches = false; return c }
        let g = got.pixels.bytes, w = want.pixels.bytes
        for y in 0..<want.height {
            for x in 0..<want.width {
                let i = (y * want.width + x) * 4
                var worst = 0
                for k in 0..<4 { worst = max(worst, abs(Int(g[i + k]) - Int(w[i + k]))) }
                if mask.contains([x / cell, y / cell]) {
                    c.pixelsInPlates += 1
                    if worst > 0 { c.differInPlates += 1 }
                } else {
                    c.pixelsOutside += 1
                    if worst > tolerance { c.wrongOutside += 1 }
                    if worst > c.maxOutside { c.maxOutside = worst; c.worstAt = "\(x),\(y): got \(Array(g[i..<i + 4])) Mac \(Array(w[i..<i + 4]))" }
                }
            }
        }
        return c
    }
}
