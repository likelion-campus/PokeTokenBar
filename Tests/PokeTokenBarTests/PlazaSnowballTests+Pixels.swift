import XCTest
@testable import PokeTokenBar

extension PlazaSnowballTests {

    func testSnowballArtUsesOnlySnowColours() async {
        let allowed: Set<UInt32> = [0xF6FAFF, 0xC6DAF0, 0x8DA3BF]
        let art = PlazaSnowballArt.art()
        XCTAssertEqual(art.ball.scale, 4)
        XCTAssertEqual(art.burst.map(\.scale), [4, 4, 4])
        XCTAssertEqual(art.burst.count, 3)
        for image in ([art.ball] + art.burst).map(\.image) {
            let data = image.pixels.bytes
            for i in 0..<(image.width * image.height) where data[i * 4 + 3] != 0 {
                XCTAssertEqual(data[i * 4 + 3], 255)
                let rgb = UInt32(data[i * 4]) << 16 | UInt32(data[i * 4 + 1]) << 8 | UInt32(data[i * 4 + 2])
                XCTAssertTrue(allowed.contains(rgb), String(rgb, radix: 16))
            }
        }
        let ball = art.ball.image
        XCTAssertEqual(ball.width, 4)
        XCTAssertEqual(ball.height, 4)
        let data = ball.pixels.bytes
        let shade = (0..<16).filter { data[$0 * 4 + 3] == 255 && data[$0 * 4] == 0x8D && data[$0 * 4 + 1] == 0xA3 && data[$0 * 4 + 2] == 0xBF }
        XCTAssertEqual(shade.count, 5)
    }

    @MainActor func testTheBurstNeverDrawsTheBallPicture() async {
        let balloon = PlazaImage(bitmap: PlazaBitmap(width: 14, height: 18, fill: PlazaRGBA(r: 0x2E, g: 0x78, b: 0xC0, a: 255)))
        let art = PlazaSnowballArt.art(.summer, balls: [(balloon, 1)]), layer = PlazaSnowballLayer(worldHeight: 1024)
        layer.setArt(art)
        for burst in [PlazaSnowballFlight.Burst.air, .ground] {
            _ = layer.launch(PlazaSnowballFlight(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 164, y: 500),
                                                 endHeight: burst == .air ? 20 : 0, frames: 2, burst: burst)) {}
        }
        var seen: [PlazaImage] = []
        for _ in 0..<20 { layer.advance(by: 0.05); seen += layer.burstImages }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertFalse(seen.contains { $0 === balloon }, "a burst drew the ball picture")
        XCTAssertTrue(seen.contains { $0 === art.burst[0].image }, "glyph 0 is a burst piece")
    }

    @MainActor func testASeasonChangeMidBurstRedrawsWithTheNewPieces() async {
        let layer = PlazaSnowballLayer(worldHeight: 1024)
        layer.setArt(PlazaSnowballArt.art(.summer))
        _ = layer.launch(PlazaSnowballFlight(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 132, y: 500), endHeight: 0, frames: 1, burst: .ground)) {}
        layer.advance(by: 0.15)                       // landed: burst step 0
        XCTAssertFalse(layer.burstImages.isEmpty)
        let autumn = PlazaSnowballArt.art(.autumn)
        layer.setArt(autumn)
        layer.advance(by: 0.1)                        // step 1
        let ids = Set(autumn.burst.map { ObjectIdentifier($0.image) })
        XCTAssertFalse(layer.burstImages.isEmpty)
        XCTAssertTrue(layer.burstImages.allSatisfy { ids.contains(ObjectIdentifier($0)) })
    }

    /// Several ball pictures (the summer balloons): each throw takes the next one and the count wraps. A season change keeps
    /// each flying ball's place in the order.
    @MainActor func testEachThrowTakesTheNextBallPicture() async {
        let colours: [PlazaImage] = (0..<3).map { PlazaImage(bitmap: PlazaBitmap(width: 16, height: 21, fill: PlazaRGBA(r: UInt8(80 * $0), g: 0, b: 0, a: 255))) }
        let layer = PlazaSnowballLayer(worldHeight: 1024)
        layer.setArt(PlazaSnowballArt.art(.summer, balls: colours.map { ($0, 2) }))
        for _ in 0..<4 {
            _ = layer.launch(PlazaSnowballFlight(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 164, y: 500), endHeight: 0, frames: 30, burst: .ground)) {}
        }
        XCTAssertTrue(zip(layer.ballImages, [colours[0], colours[1], colours[2], colours[0]]).allSatisfy { $0 === $1 })
        XCTAssertEqual(layer.ballSizes, Array(repeating: CGSize(width: 32, height: 42), count: 4), "two world pixels a pixel")
        let one = PlazaImage(bitmap: PlazaBitmap(width: 38, height: 34, fill: PlazaRGBA(r: 242, g: 184, b: 190, a: 255)))
        layer.setArt(PlazaSnowballArt.art(.spring, balls: [(one, 1)]))
        XCTAssertTrue(layer.ballImages.allSatisfy { $0 === one }, "one picture for every ball in the air")
        XCTAssertEqual(layer.ballSizes, Array(repeating: CGSize(width: 38, height: 34), count: 4))
    }
}
