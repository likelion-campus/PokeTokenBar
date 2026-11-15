import CoreGraphics
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import PokeTokenBar

/// `PlazaDecodeGoldens` is what the Windows decoder is held to; this re-measures it on the Mac, so the table cannot drift
/// from what ImageIO and CoreGraphics really give for the repo's own art. When a bundled file changes, this fails with the
/// new values: paste them into `PlazaDecodeGoldens.swift`.
final class PlazaDecodeGoldensMacTests: XCTestCase {
    private let graphics = MacPlazaGraphics()

    private func sha(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

    func testBundledArtHashesAreWhatTheMacDecodes() throws {
        for art in PlazaDecodeGoldens.art {
            let url = try XCTUnwrap(graphics.assetURL(art.name, ext: art.ext), art.name)
            let image = try XCTUnwrap(graphics.decodeImage(at: url), art.name)
            XCTAssertEqual(image.width, art.width, art.name)
            XCTAssertEqual(image.height, art.height, art.name)
            XCTAssertEqual(sha(image.pixels.bytes), art.sha256, "\(art.name): new value above")
        }
    }

    func testIceGifFramesAndDelaysAreWhatTheMacDecodes() throws {
        let url = try XCTUnwrap(graphics.assetURL(PlazaDecodeGoldens.iceGIFName, ext: "gif"))
        let frames = graphics.decodeImageFrames(at: url)
        XCTAssertEqual(frames.count, PlazaDecodeGoldens.iceGIF.count)
        let delays = GIFDecoder.frames(from: try Data(contentsOf: url)).map(\.delay)
        XCTAssertEqual(delays.count, PlazaDecodeGoldens.iceGIF.count)
        for (i, golden) in PlazaDecodeGoldens.iceGIF.enumerated() where i < frames.count && i < delays.count {
            XCTAssertEqual(frames[i].width, PlazaDecodeGoldens.iceGIFSize.width)
            XCTAssertEqual(frames[i].height, PlazaDecodeGoldens.iceGIFSize.height)
            XCTAssertEqual(sha(frames[i].pixels.bytes), golden.sha256, "ice frame \(i)")
            XCTAssertEqual(delays[i], golden.delay, accuracy: 1e-12, "ice frame \(i) delay")
        }
    }

    func testFixturePremultipliedBytesAreWhatTheMacDecodes() throws {
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64))
        let image = try XCTUnwrap(graphics.decodeImage(png))
        XCTAssertEqual(image.width, PlazaDecodeGoldens.fixtureSize)
        XCTAssertEqual(image.pixels.bytes, PlazaDecodeGoldens.fixturePremultiplied)
    }

    /// The Windows rounding rules, checked against CoreGraphics over every (colour, alpha) pair: premultiply is a CoreGraphics
    /// draw, un-premultiply is ImageIO's PNG writer. (`WinPlazaCodecs` repeats the two formulas; this pins them.)
    func testPremultiplyFormulaIsCoreGraphicsOnAllPairs() throws {
        var straight = [UInt8]()
        for a in 0..<256 { for c in 0..<256 { straight += [UInt8(c), UInt8(c), UInt8(c), UInt8(a)] } }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(straight) as CFData))
        let image = try XCTUnwrap(CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let drawn = CGImagePayload(image).pixels().bytes
        var wrong = 0
        for a in 0..<256 { for c in 0..<256 where Int(drawn[(a * 256 + c) * 4]) != (c * a + 127) / 255 { wrong += 1 } }
        XCTAssertEqual(wrong, 0, "(c * a + 127) / 255 is CoreGraphics' premultiply")
    }
}
