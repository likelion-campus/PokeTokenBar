import XCTest
import CoreGraphics
@testable import PokeTokenBar

/// A swimmer's cut-off lower half is drawn under the waterline, translucent and tinted, clipped to its pond.
/// The right pond is x32-38, y14-20 (7x7 tiles of 32 world px); sprites are 32x48 (72 world px at x1.5).
@MainActor
final class PlazaSwimLowerHalfTests: XCTestCase {
    private let map = PlazaMapData.map

    private func solid(_ w: Int, _ h: Int, r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func frames() -> PlazaCharacterFrames {
        let f = [PlazaFrame(image: solid(32, 48), delay: 0.1)]
        return PlazaCharacterFrames(front: f, back: f)
    }

    private func scene(start: TilePoint) -> PlazaScene {
        let s = PlazaScene(map: map, mapImage: PlazaTileArt.plainGrassImage(map), start: start, zoom: 2,
                           nickname: "me", pondVisuals: true)
        s.size = CGSize(width: 800, height: 600)
        s.backingOverride = 2
        s.setCharacter(frames())
        return s
    }

    private func add(_ s: PlazaScene, _ list: [(id: String, tile: TilePoint, diving: Bool)]) {
        s.applyMembers(list.map {
            var m = PlazaSceneMember(memberID: $0.id, nickname: $0.id, isAway: false, tile: $0.tile, facing: .down, isWalking: false)
            m.isDiving = $0.diving
            return m
        })
        for m in list { s.setMemberFrames(m.id, frames()) }
    }

    private func settle(_ s: PlazaScene) {
        var t: TimeInterval = 0
        s.update(t)
        for _ in 0..<6 { t += 1.0 / 30; s.update(t) }
    }

    /// Scene y is up, so the pond's top row y14 is the highest.
    private var pondClip: CGRect {
        let h = PlazaMapData.map.pixelSize.height
        return CGRect(x: 32 * 32, y: h - 21 * 32, width: 7 * 32, height: 7 * 32)
    }

    func testSwimmerShowsItsLowerHalfTranslucently() throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("a", TilePoint(x: 34, y: 18), false)])
        settle(s)
        let a = try XCTUnwrap(s.memberActor("a"))
        XCTAssertTrue(a.isSubmergedBodyVisible)
        XCTAssertEqual(a.submergedBodyAlpha, 0.45 * a.characterOpacity, accuracy: 0.001)
        let cut = (72 * 0.55 / 1.5).rounded()   // rows of the 48-row sprite under water
        XCTAssertEqual(a.submergedBodySize, CGSize(width: 48, height: cut * 1.5))
        XCTAssertEqual(a.submergedBodyTextureRect.height, cut / 48, accuracy: 0.001)
        XCTAssertEqual(a.submergedBodyTextureRect.minY, 0, accuracy: 0.001)
    }

    func testLowerHalfIsHiddenOnLandAndWhileDiving() throws {
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("land", TilePoint(x: 30, y: 18), false), ("dive", TilePoint(x: 35, y: 18), true)])
        settle(s)
        XCTAssertFalse(try XCTUnwrap(s.memberActor("land")).isSubmergedBodyVisible)
        XCTAssertNil(try XCTUnwrap(s.memberActor("land")).submergedBodyClip)
        // a diver fades with its character: the body follows that alpha and is gone once hidden.
        let d = try XCTUnwrap(s.memberActor("dive"))
        XCTAssertEqual(d.submergedBodyAlpha, 0.45 * d.characterOpacity, accuracy: 0.001)
    }

    func testClipIsTheSwimmersPondForMeAndForAMember() throws {
        let me = scene(start: TilePoint(x: 33, y: 15))
        settle(me)
        XCTAssertEqual(me.myActor.submergedBodyClip, pondClip)
        let s = scene(start: TilePoint(x: 20, y: 22))
        add(s, [("a", TilePoint(x: 37, y: 19), false)])
        settle(s)
        XCTAssertEqual(try XCTUnwrap(s.memberActor("a")).submergedBodyClip, pondClip)
        XCTAssertNil(s.myActor.submergedBodyClip, "on land")
    }

    // MARK: photo

    private struct Px { let r, g, b: Int }
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> Px {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let o = (y * img.width + x) * 4   // CGContext rows are top-down in the buffer when drawn this way
        return Px(r: Int(d[o]), g: Int(d[o + 1]), b: Int(d[o + 2]))
    }

    /// World 128x128 of plain blue "water"; the pond is the top 64 rows. Swimmer foot at world y=`footY`.
    private func render(footY: CGFloat) throws -> CGImage {
        var a = PlazaPhotoActor(image: solid(32, 48), flipped: false, foot: CGPoint(x: 64, y: footY), scale: 1.5,
                                shadow: nil, shadowRect: .zero, plate: nil, bubble: nil)
        a.sink = 39.6
        a.waterClip = CGRect(x: 0, y: 0, width: 128, height: 64)
        let input = PlazaPhotoInput(mapImage: solid(128, 128, r: 0, g: 0.5, b: 0.7), visibleRect: CGRect(x: 0, y: 0, width: 128, height: 128),
                                    pixelsPerWorld: 2, actors: [a])
        return try XCTUnwrap(PlazaPhotoRenderer.render(input))
    }

    func testPhotoDrawsTheSubmergedBodyInsideThePond() throws {
        let img = try render(footY: 40)   // foot at photo row 80; the body reaches ~row 80+79
        let p = pixel(img, 64 * 2, 80 + 6)
        XCTAssertGreaterThan(p.r, 40, "the red body shows through the water just under the waterline")
        XCTAssertLessThan(p.r, 200, "but translucent, not opaque red")
    }

    func testPhotoClipsTheSubmergedBodyAtThePondEdge() throws {
        let img = try render(footY: 60)   // foot at row 120; the pond ends at row 128
        let inside = pixel(img, 64 * 2, 120 + 4)
        let below = pixel(img, 64 * 2, 128 + 4)
        let plain = pixel(img, 8, 128 + 4)   // same row, beside the swimmer
        XCTAssertGreaterThan(inside.r, 40)
        XCTAssertEqual(below.r, plain.r, "nothing past the pond's bottom edge")
    }
}
