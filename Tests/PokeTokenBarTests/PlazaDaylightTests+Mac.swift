import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

extension PlazaDaylightTests {

    /// The minimap's map follows the time like the plaza: darker, bluer and greyer at night. With the background
    /// hidden it does not change, as the plaza does not.
    func testMinimapMapFollowsTheTime() throws {
        var green = PlazaBitmap(width: 48, height: 32, fill: PlazaRGBA(r: 110, g: 186, b: 84, a: 255))
        green.colorSpace = .sRGB
        let map = PlazaImage(bitmap: green)
        func corner(hour: Int, hidden: Bool = false) throws -> (r: Int, g: Int, b: Int) {
            let background = PlazaBackgroundModel()
            background.isHidden = hidden
            let panel = PlazaMinimapPanel(model: PlazaMinimapModel(), background: background, worldSize: PlazaMapData.map.pixelSize,
                                          mapImage: { map })
            panel.update(date: at(hour, 0))
            let drawing = panel.render(scale: 1, viewport: .zero, graphics: PlatformPlaza.graphics)
            guard case .image(let image, _)? = drawing.layers.first else { throw XCTSkip("no plate") }
            let px = image.pixels
            let p = px[13 + 12, 13 + 12]   // inside the map, clear of the frame and any dot (a point of the map at (12, 12))
            return (Int(p.r), Int(p.g), Int(p.b))
        }
        let noon = try corner(hour: 12), night = try corner(hour: 22)
        XCTAssertLessThan(night.g, noon.g - 40, "darker at night")
        XCTAssertLessThan(night.g - night.r, noon.g - noon.r, "and less green (greyer, bluer)")
        XCTAssertGreaterThan(night.b * noon.g, noon.b * night.g, "blue holds up better than green")
        let hiddenNoon = try corner(hour: 12, hidden: true), hiddenNight = try corner(hour: 22, hidden: true)
        XCTAssertEqual(hiddenNight.r, hiddenNoon.r)
        XCTAssertEqual(hiddenNight.g, hiddenNoon.g)
    }

    /// The photo tints the map and characters, but not name tags or bubbles, as the plaza does.
    func testPhotoTintsTheMapButNotTheNameTag() throws {
        func solid(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> CGImage {
            var d = [UInt8](repeating: 255, count: w * h * 4)
            for i in stride(from: 0, to: d.count, by: 4) { d[i] = rgb.0; d[i + 1] = rgb.1; d[i + 2] = rgb.2 }
            let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let white = solid(4, 2, (255, 255, 255))
        let actor = PlazaPhotoActor(image: PlazaImage(cgImage: solid(2, 2, (255, 255, 255))), flipped: false, foot: CGPoint(x: 10, y: 15), scale: 1,
                                    shadow: nil, shadowRect: .zero, plate: PlazaImage(cgImage: white), bubble: nil)
        let input = PlazaPhotoInput(mapImage: PlazaImage(cgImage: solid(20, 20, (255, 255, 255))), visibleRect: CGRect(x: 0, y: 0, width: 20, height: 20),
                                    pixelsPerWorld: 1, actors: [actor], tint: D.night)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.renderCG(input))
        var px = [UInt8](repeating: 0, count: photo.width * photo.height * 4)
        let ctx = CGContext(data: &px, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: photo.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: photo.width, height: photo.height))
        func red(_ x: Int, _ y: Int) -> UInt8 { px[(y * photo.width + x) * 4] }   // row 0 is the top
        XCTAssertEqual(Double(red(1, 1)), 255 * D.night.red, accuracy: 2, "the map is darkened by the night colour")
        XCTAssertEqual(Double(red(10, 14)), 255 * D.night.red, accuracy: 2, "so is the character")
        // The plate sits above the character (rows 13-14) with a small gap; find a pure white pixel above it.
        let plateRows = (0..<13).filter { y in (8..<12).contains { red($0, y) == 255 } }
        XCTAssertFalse(plateRows.isEmpty, "the name tag stays untinted")
    }
}
