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
        Art(name: "plaza-leaf-sheet", ext: "png", width: 128, height: 160,
            sha256: "0a588662ca1bf02feabeb812875408374b2f0e1188b0b03a96e38b659250abcb"),
        Art(name: "plaza-steam", ext: "png", width: 224, height: 32,
            sha256: "cd831445626aa84efc3827315ee4bf5fe20c19ef499268cb488f54132a2ccf01"),
        Art(name: "plaza-bomb", ext: "png", width: 64, height: 16,
            sha256: "b986c094bc6a859f57f9ae0dd3a02c8daa1362279ced1a19469921da4fe273c0"),
        Art(name: "plaza-fortune-cookie", ext: "png", width: 16, height: 16,
            sha256: "1dc7e1bfa03e636d6ffce32ecaf407d36a62727e5b0fa444e7b2a63dc9ad2255"),
        Art(name: "plaza-balloons", ext: "png", width: 80, height: 21,
            sha256: "02b2c88ad52a023f03ea4fb0fcdf7d9f7b2e3231ab8d8c6880123b61b07dc184"),
        Art(name: "plaza-sakura", ext: "png", width: 18, height: 16,
            sha256: "cb2efa9a4751bc63218cc1bbbeae03030ec782682780b49dca021befcbb73ba3"),
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

    /// A second fixture whose colour bytes are not 0 or 255, so a different rounding (floor, ceiling) changes 43 of its 96
    /// colour bytes: 8 x 4 pixels, alphas 0...255, made on the Mac by ImageIO from `fixture2Straight` (a straight-alpha
    /// CGImage), then read back by ImageIO and drawn into a premultiplied context: `fixture2Premultiplied`.
    static let fixture2PNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAYAAACzzX7wAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAACKADAAQAAAABAAAABAAAAABQdJZTAAAAZ0lEQVQIHWPkZj3BoBptyoiE+YBsASCWB2JeFo0bK1JUo+9Kq95Ywah6A6TwrqjqjbtGQL6YRrSpAkjBbKAAGxCHAgWjgIpsgFhKA6zorg1IwUKgwE6gcSJARSDMpRG9Qg4oxgXE3wCr2i9At57eMAAAAABJRU5ErkJggg=="
    static let fixture2Size = (width: 8, height: 4)
    static let fixture2Straight: [UInt8] = [
        11, 5, 200, 0, 48, 96, 253, 1, 85, 187, 50, 2, 122, 22, 103, 3,
        159, 113, 156, 17, 196, 204, 209, 33, 233, 39, 6, 64, 14, 130, 59, 77,
        51, 221, 112, 100, 88, 56, 165, 127, 125, 147, 218, 128, 162, 238, 15, 129,
        199, 73, 68, 150, 236, 164, 121, 200, 17, 255, 174, 222, 54, 90, 227, 254,
        91, 181, 24, 255, 128, 16, 77, 5, 165, 107, 130, 90, 202, 198, 183, 180,
        239, 33, 236, 240, 20, 124, 33, 10, 57, 215, 86, 60, 94, 50, 139, 120,
        131, 141, 192, 160, 168, 232, 245, 190, 205, 67, 42, 210, 242, 158, 95, 230,
        23, 249, 148, 250, 60, 84, 201, 40, 97, 175, 254, 70, 134, 10, 51, 110,
    ]
    static let fixture2Premultiplied: [UInt8] = [
        0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 2, 1, 0, 1, 3,
        11, 8, 10, 17, 25, 26, 27, 33, 58, 10, 2, 64, 4, 39, 18, 77,
        20, 87, 44, 100, 44, 28, 82, 127, 63, 74, 109, 128, 82, 120, 8, 129,
        117, 43, 40, 150, 185, 129, 95, 200, 15, 222, 151, 222, 54, 90, 226, 254,
        91, 181, 24, 255, 3, 0, 2, 5, 58, 38, 46, 90, 143, 140, 129, 180,
        225, 31, 222, 240, 1, 5, 1, 10, 13, 51, 20, 60, 44, 24, 65, 120,
        82, 88, 120, 160, 125, 173, 183, 190, 169, 55, 35, 210, 218, 143, 86, 230,
        23, 244, 145, 250, 9, 13, 32, 40, 27, 48, 70, 70, 58, 4, 22, 110,
    ]
}
