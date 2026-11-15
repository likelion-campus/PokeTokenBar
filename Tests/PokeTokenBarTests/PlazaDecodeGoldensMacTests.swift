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

    func testMidRangeFixturePremultipliedBytesAreWhatTheMacDecodes() throws {
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixture2PNGBase64))
        let image = try XCTUnwrap(graphics.decodeImage(png))
        XCTAssertEqual(image.width, PlazaDecodeGoldens.fixture2Size.width)
        XCTAssertEqual(image.height, PlazaDecodeGoldens.fixture2Size.height)
        XCTAssertEqual(image.pixels.bytes, PlazaDecodeGoldens.fixture2Premultiplied)
    }
}
