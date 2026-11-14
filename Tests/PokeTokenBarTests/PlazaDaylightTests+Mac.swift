import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

extension PlazaDaylightTests {

    /// The minimap's map follows the time like the plaza: darker, bluer and greyer at night. With the background
    /// hidden it does not change, as the plaza does not.
    func testMinimapMapFollowsTheTime() throws {
        let map = NSImage(size: NSSize(width: 48, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.43, green: 0.73, blue: 0.33, alpha: 1).setFill(); rect.fill(); return true
        }
        func corner(hour: Int, hidden: Bool = false) throws -> (r: Int, g: Int, b: Int) {
            let background = PlazaBackgroundModel()
            background.isHidden = hidden
            let view = PlazaMinimapView(model: PlazaMinimapModel(), background: background, mapImage: map,
                                        worldSize: PlazaMapData.map.pixelSize, fixedDate: at(hour, 0))
            let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let i = (12 * image.width + 12) * 4   // inside the map, clear of the frame and any dot
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
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
