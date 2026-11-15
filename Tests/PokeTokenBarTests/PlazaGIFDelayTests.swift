import XCTest
@testable import PokeTokenBar

/// `PlazaGIFDecoder.framesWithDelays` gives each frame the delay `UI/GIFDecoder` gives it from ImageIO. The rule, from
/// `GIFDecoder.delay`: the graphic control extension's delay in 1/100 s (ImageIO's "unclamped" value); under 0.02 s becomes
/// 0.1 s; no graphic control extension at all is 0.1 s. The Mac side compares the same fixtures with `UI/GIFDecoder`
/// (`PlazaGIFDecoderParityTests+Mac`).
final class PlazaGIFDelayTests: XCTestCase {
    typealias Fx = PlazaGIFFixtures

    private func frame(delay: Int, disposal: Int = 1, transparent: Int? = nil) -> Fx.Frame {
        var f = Fx.Frame(width: 2, height: 2, indices: [0, 1, 2, 3])
        f.delay = delay
        f.disposal = disposal
        f.transparent = transparent
        return f
    }

    func testGifDelaysMatchGIFDecoder() {
        // 0 and 1 (hundredths) are "too fast" and become 0.1; 2 is the smallest delay kept; 10 is 0.1; 7 and 65535 pass through.
        let delays = [0, 1, 2, 10, 7, 65535]
        let gif = Data(Fx.gif(width: 2, height: 2, frames: delays.map { frame(delay: $0) }))
        let got = PlazaGIFDecoder.framesWithDelays(from: gif).map(\.delay)
        let want: [TimeInterval] = [0.1, 0.1, 0.02, 0.1, 0.07, 655.35]
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 1e-9) }
    }

    func testAFrameWithNoGraphicControlExtensionGetsTheDefault() {
        var bare = Fx.Frame(width: 2, height: 2, indices: [0, 1, 2, 3])
        bare.delay = 0  // delay 0, disposal 0, no transparency: the builder writes no extension at all
        let gif = Data(Fx.gif(width: 2, height: 2, frames: [frame(delay: 50), bare, frame(delay: 25)]))
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: gif).map(\.delay), [0.5, 0.1, 0.25])
    }

    /// A GIF that declares a transparent colour is decoded once; one that never does is decoded a second time (ImageIO paints
    /// opaque black where nothing paints). The delays must come out of whichever pass produced the frames.
    func testDelaysComeFromThePassThatProducedTheFrames() {
        let opaque = Data(Fx.gif(width: 2, height: 2, frames: [frame(delay: 30), frame(delay: 0), frame(delay: 3)]))
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: opaque).map(\.delay), [0.3, 0.1, 0.03])
        let transparent = Data(Fx.gif(width: 2, height: 2, frames: [frame(delay: 30, transparent: 3), frame(delay: 0), frame(delay: 3)]))
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: transparent).map(\.delay), [0.3, 0.1, 0.03])
    }

    func testFramesAndFramesWithDelaysAgreeOnPixels() {
        let gif = Data(Fx.gif(width: 2, height: 2, frames: [frame(delay: 5), frame(delay: 9, disposal: 2), frame(delay: 12, transparent: 1)]))
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: gif).map(\.bitmap), PlazaGIFDecoder.frames(from: gif))
    }

    func testOneFrameAndGarbageAndTruncationKeepFramesAndDelaysTheSameLength() {
        let one = Data(Fx.gif(width: 2, height: 2, frames: [frame(delay: 40)]))
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: one).map(\.delay), [0.4], "a single frame is returned with its delay")
        XCTAssertTrue(PlazaGIFDecoder.framesWithDelays(from: Data([1, 2, 3])).isEmpty)
        let full = Fx.gif(width: 2, height: 2, frames: [frame(delay: 20), frame(delay: 30), frame(delay: 40)])
        for cut in stride(from: 13, to: full.count, by: 3) {
            let data = Data(full.prefix(cut))
            XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: data).count, PlazaGIFDecoder.frames(from: data).count, "cut at \(cut)")
        }
    }

    func testDelaySecondsRule() {
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: nil), 0.1)
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: 0), 0.1)
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: 1), 0.1)
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: 2), 0.02, accuracy: 1e-12)
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: 10), 0.1, accuracy: 1e-12)
        XCTAssertEqual(PlazaGIFDecoder.delaySeconds(centiseconds: 100), 1.0, accuracy: 1e-12)
    }
}
