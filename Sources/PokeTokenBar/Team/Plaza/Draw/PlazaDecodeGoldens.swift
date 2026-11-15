import Foundation

/// What the Mac's decoder (ImageIO + the CoreGraphics draw in `CGImagePayload.pixels()`) makes of the repo's own art, as a
/// few small values. The Windows decoder (WIC + the shared `PlazaPremultiply`) must give the same bytes: the Windows
/// self-test and `WindowsPlazaGraphicsTests` compare against this table, and `PlazaDecodeGoldensMacTests` re-measures it on
/// the Mac so it cannot drift from what the Mac really does. Data only; no code reads a file.
enum PlazaDecodeGoldens {
    /// A bundled still image: its size and the SHA-256 of `PlazaImage.pixels.bytes` (premultiplied sRGB RGBA8, row 0 on top).
    struct Art: Sendable {
        let name: String, ext: String
        let width: Int, height: Int
        let sha256: String
    }

    static let art: [Art] = [
        Art(name: "plaza-tiles", ext: "png", width: 640, height: 576,
            sha256: "9464397f44b1e19f649f31b4972631257b38f5d7788d7035f2cf91f1d1a7fc09"),
        Art(name: "plaza-tallgrass", ext: "png", width: 208, height: 144,
            sha256: "6a3c1c6329d9029f65e6303e24b00c537686505d6dc52eb9cdd4434a094824de"),
        Art(name: "plaza-ice-cracks", ext: "png", width: 256, height: 256,
            sha256: "cac5599782a0e73a463cb868d7154358f1f6aafb56218f9bf50a1c74ed686572"),
        Art(name: "plaza-ice-gloss", ext: "png", width: 84, height: 67,
            sha256: "6fe306dfb6a7701bef62cb649756f43a450c7b1019cf257e8fa334ad6e9700e0"),
        Art(name: "plaza-water-balloon", ext: "png", width: 14, height: 18,
            sha256: "535a1133578e3def6997427f1a92dddef27ba1f623a93bb3d198913727bde002"),
    ]

    /// `plaza-ice-shatter.gif`, frame by frame as `decodeImageFrames` returns it (ImageIO), with the delay `UI/GIFDecoder` gives.
    struct GIFFrame: Sendable {
        let sha256: String
        let delay: TimeInterval
    }

    static let iceGIFName = "plaza-ice-shatter"
    static let iceGIFSize = (width: 32, height: 32)
    static let iceGIF: [GIFFrame] = [
        GIFFrame(sha256: "e321a7ad81e901614c952dbcee2db6e924edff35c62f5172fbdd63e4f51a1558", delay: 0.1),
        GIFFrame(sha256: "be909ade2e22abf492ff9cc726e98f88a0de911d037a4cf519ed1883ee3658e6", delay: 0.1),
        GIFFrame(sha256: "2e31c33cf7315d3dcf98f6044274e23b2042afc4aef6aebb7aec338723fb0aa8", delay: 0.1),
        GIFFrame(sha256: "5a85cfcc4fe328b4be34866dff3b8aa400afafd670d0ab458dd7001d20bfd182", delay: 0.1),
    ]

    /// A 4 x 4 straight-alpha PNG with semi-transparent pixels (red 255, green 128, blue 255, yellow 64 alpha; the rest alpha 0)
    /// and what the Mac's decoder makes of it: premultiplied, with CoreGraphics' rounding. The same bytes `WinIcon.fixturePNG` has.
    static let fixturePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAGklEQVR4nGP4z8AARFDwn6GBgRjw/z8SywEA9KkHup1HiTAAAAAASUVORK5CYII="
    static let fixtureSize = 4
    static let fixturePremultiplied: [UInt8] = [
        255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 128,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 64, 64, 0, 64,
    ]
}
