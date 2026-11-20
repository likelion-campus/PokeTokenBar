import CoreGraphics
import XCTest
@testable import PokeTokenBar

/// Byte equality between a legacy art builder's `CGImage` and the converted builder's `PlazaImage` (as the Mac hands it
/// to SpriteKit, `.cgImage`): size, pixel format, colour space, interpolation, intent and every data-provider byte
/// (row padding included: the render harness hashes those bytes). A difference names the first differing pixel.
enum PlazaArtParity {
    static func assertIdentical(_ legacy: CGImage, _ new: PlazaImage, _ label: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        assertIdentical(legacy, new.cgImage, label, file: file, line: line)
    }

    static func assertIdentical(_ legacy: CGImage, _ new: CGImage, _ label: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        let a = describe(legacy), b = describe(new)
        XCTAssertEqual(a, b, "\(label): image format differs", file: file, line: line)
        guard let da = legacy.dataProvider?.data as Data?, let db = new.dataProvider?.data as Data? else {
            return XCTFail("\(label): no data provider bytes", file: file, line: line)
        }
        if let message = firstDifference(Array(da), Array(db), bytesPerRow: legacy.bytesPerRow) {
            XCTFail("\(label): \(message)", file: file, line: line)
        }
    }

    static func describe(_ image: CGImage) -> String {
        "\(image.width)x\(image.height) bpc \(image.bitsPerComponent) bpp \(image.bitsPerPixel) bpr \(image.bytesPerRow)"
            + " info \(image.bitmapInfo.rawValue) alpha \(image.alphaInfo.rawValue)"
            + " space \(image.colorSpace?.name.map { $0 as String } ?? "nil") model \(image.colorSpace?.model.rawValue ?? -1)"
            + " interpolate \(image.shouldInterpolate) intent \(image.renderingIntent.rawValue) decode \(image.decode == nil ? "nil" : "set")"
    }

    /// nil when equal; otherwise the count of differing bytes and the first one as (x, y, channel, legacy, new).
    static func firstDifference(_ a: [UInt8], _ b: [UInt8], bytesPerRow: Int) -> String? {
        if a == b { return nil }
        guard a.count == b.count else { return "byte counts differ: legacy \(a.count), new \(b.count)" }
        var count = 0, first: Int?
        for i in a.indices where a[i] != b[i] {
            count += 1
            if first == nil { first = i }
        }
        let i = first!
        let y = i / bytesPerRow, x = (i % bytesPerRow) / 4, channel = ["r", "g", "b", "a"][i % 4]
        return "\(count) bytes differ; first at pixel (\(x), \(y)) channel \(channel): legacy \(a[i]), new \(b[i])"
    }
}
