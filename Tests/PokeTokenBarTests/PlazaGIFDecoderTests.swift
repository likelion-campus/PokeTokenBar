import XCTest
@testable import PokeTokenBar

final class PlazaGIFDecoderTests: XCTestCase {
    typealias Fx = PlazaGIFFixtures

    /// One character per pixel: `.` transparent, K R G B W opaque; rows separated by `/`.
    private func grid(_ bitmap: PlazaBitmap) -> String {
        (0..<bitmap.height).map { y in
            String((0..<bitmap.width).map { x -> Character in
                switch bitmap[x, y] {
                case PlazaRGBA(r: 0, g: 0, b: 0, a: 0): return "."
                case PlazaRGBA(r: 0, g: 0, b: 0, a: 255): return "K"
                case PlazaRGBA(r: 255, g: 0, b: 0, a: 255): return "R"
                case PlazaRGBA(r: 0, g: 255, b: 0, a: 255): return "G"
                case PlazaRGBA(r: 0, g: 0, b: 255, a: 255): return "B"
                case PlazaRGBA(r: 255, g: 255, b: 255, a: 255): return "W"
                default: return "?"
                }
            })
        }.joined(separator: "/")
    }

    private func grids(_ data: [UInt8]) -> [String] { PlazaGIFDecoder.frames(from: Data(data)).map(grid) }

    private func solid(_ index: UInt8, _ w: Int, _ h: Int) -> [UInt8] { [UInt8](repeating: index, count: w * h) }

    // MARK: Pixels

    func testSingleFrameGlobalPalette() {
        let data = Fx.gif(width: 3, height: 2, frames: [.init(width: 3, height: 2, indices: [0, 1, 2, 3, 2, 1])])
        let frames = PlazaGIFDecoder.frames(from: Data(data))
        XCTAssertEqual(frames.map(grid), ["RGB/WBG"])
        XCTAssertEqual(frames[0].alpha, .premultipliedLast)
        XCTAssertEqual(frames[0].colorSpace, .sRGB)
        XCTAssertEqual(frames[0].bytes.count, 3 * 2 * 4)
    }

    func testGIF87aAndEveryMinimumCodeSize() {
        for minCode in 2...8 {
            let indices = (0..<24).map { UInt8($0 % 4) }
            var f = Fx.Frame(width: 6, height: 4, indices: indices)
            f.minCode = minCode
            XCTAssertEqual(grids(Fx.gif(width: 6, height: 4, version: "GIF87a", frames: [f])),
                           ["RGBWRG/BWRGBW/RGBWRG/BWRGBW"], "minCode \(minCode)")
        }
    }

    func testLocalPaletteReplacesTheGlobalOne() {
        var f = Fx.Frame(width: 2, height: 1, indices: [0, 1])
        f.palette = [[0, 0, 255], [255, 0, 0]]
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [f])), ["BR"])
    }

    func testLocalPaletteWithoutAGlobalOne() {
        var f = Fx.Frame(width: 2, height: 1, indices: [1, 0])
        f.palette = [[0, 255, 0], [255, 255, 255]]
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, global: nil, frames: [f])), ["WG"])
    }

    func testNoPaletteAtAllDrawsNothing() {
        let f = Fx.Frame(width: 2, height: 1, indices: [0, 1])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, global: nil, frames: [f])), ["KK"])
    }

    func testSubFrameOffsetsLeaveTheRestTransparent() {
        let f = Fx.Frame(left: 1, top: 2, width: 2, height: 1, indices: [2, 3])
        XCTAssertEqual(grids(Fx.gif(width: 4, height: 4, frames: [f])), ["KKKK/KKKK/KBWK/KKKK"])
    }

    func testTransparentIndexKeepsWhatIsUnderneath() {
        var second = Fx.Frame(width: 2, height: 2, indices: [1, 3, 3, 1])
        second.transparent = 3
        var first = Fx.Frame(width: 2, height: 2, indices: solid(0, 2, 2))
        first.disposal = 1
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 2, frames: [first, second])), ["RR/RR", "GR/RG"])
    }

    func testTransparentIndexOnTheFirstFrameStaysClear() {
        var f = Fx.Frame(width: 2, height: 1, indices: [0, 1])
        f.transparent = 0
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [f])), [".G"])
    }

    func testTransparencyAppliesToOneFrameOnly() {
        var first = Fx.Frame(width: 2, height: 1, indices: [0, 1])
        first.transparent = 0
        let second = Fx.Frame(width: 2, height: 1, indices: [0, 0])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [first, second])), [".G", "RR"])
    }

    // MARK: Disposal

    private func disposalSequence(_ disposal: Int) -> [String] {
        // frame 1 paints the whole canvas red; frame 2 paints a green 2x2 at (1,1) with the disposal under test;
        // frame 3 paints a blue pixel at (3,0) on whatever is left.
        var base = Fx.Frame(width: 4, height: 4, indices: solid(0, 4, 4))
        base.disposal = 1
        var middle = Fx.Frame(left: 1, top: 1, width: 2, height: 2, indices: solid(1, 2, 2))
        middle.disposal = disposal
        var last = Fx.Frame(left: 3, top: 0, width: 1, height: 1, indices: [2])
        last.transparent = 3
        return grids(Fx.gif(width: 4, height: 4, frames: [base, middle, last]))
    }

    func testDisposalNoneAndDoNotDisposeKeepTheFrame() {
        let kept = ["RRRR/RRRR/RRRR/RRRR", "RRRR/RGGR/RGGR/RRRR", "RRRB/RGGR/RGGR/RRRR"]
        XCTAssertEqual(disposalSequence(0), kept)
        XCTAssertEqual(disposalSequence(1), kept)
    }

    func testDisposalRestoreToBackgroundClearsTheFrameRect() {
        XCTAssertEqual(disposalSequence(2), ["RRRR/RRRR/RRRR/RRRR", "RRRR/RGGR/RGGR/RRRR", "RRRB/R..R/R..R/RRRR"])
    }

    func testDisposalRestoreToPreviousBringsBackTheCanvasBeforeTheFrame() {
        XCTAssertEqual(disposalSequence(3), ["RRRR/RRRR/RRRR/RRRR", "RRRR/RGGR/RGGR/RRRR", "RRRB/RRRR/RRRR/RRRR"])
    }

    func testRestoreToPreviousOnTheFirstFrameRestoresAnEmptyCanvas() {
        var first = Fx.Frame(width: 2, height: 1, indices: [0, 1])
        first.disposal = 3
        let second = Fx.Frame(width: 1, height: 1, indices: [2])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [first, second])), ["RG", "BK"])
    }

    func testReservedDisposalValuesBehaveLikeNone() {
        for disposal in 4...7 {
            var first = Fx.Frame(width: 2, height: 1, indices: [0, 1])
            first.disposal = disposal
            let second = Fx.Frame(width: 1, height: 1, indices: [2])
            XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [first, second])), ["RG", "BG"], "disposal \(disposal)")
        }
    }

    // MARK: Interlace and LZW

    func testInterlacedRowsLandInPictureOrder() {
        // 10 rows exercise all four passes; row r is filled with a distinct grey.
        var grey: [[UInt8]] = []
        for row in 0..<10 {
            let level = UInt8(row * 25 + 5)
            grey.append([level, level, level])
        }
        for height in [1, 2, 3, 5, 8, 9, 10] {
            let indices = (0..<height).flatMap { [UInt8](repeating: UInt8($0), count: 3) }
            var f = Fx.Frame(width: 3, height: height, indices: indices)
            f.interlaced = true
            f.minCode = 4
            let frames = PlazaGIFDecoder.frames(from: Data(Fx.gif(width: 3, height: height, global: grey, frames: [f])))
            XCTAssertEqual(frames.count, 1, "height \(height)")
            for y in 0..<height {
                XCTAssertEqual(frames[0][1, y], PlazaRGBA(r: grey[y][0], g: grey[y][1], b: grey[y][2], a: 255), "height \(height) row \(y)")
            }
        }
    }

    func testLZWTableGrowthAndFullTable() {
        // 8-bit noise fills the 4096-entry table many times: with a clear code at the full table, and without one.
        let w = 200, h = 150
        let grey = (0..<256).map { [UInt8($0), UInt8(255 - $0), UInt8($0 / 2)] }
        for clearAtFull in [true, false] {
            for (limit, minCode) in [(256, 8), (4, 2), (16, 4)] {
                var f = Fx.Frame(width: w, height: h, indices: Fx.noise(count: w * h, limit: limit, seed: UInt64(limit)))
                f.minCode = minCode
                f.clearAtFull = clearAtFull
                let frames = PlazaGIFDecoder.frames(from: Data(Fx.gif(width: w, height: h, global: grey, frames: [f])))
                XCTAssertEqual(frames.count, 1, "limit \(limit) clear \(clearAtFull)")
                guard let frame = frames.first else { continue }
                var wrong = 0
                for (i, index) in f.indices.enumerated() {
                    let p = frame[i % w, i / w]
                    if p != PlazaRGBA(r: grey[Int(index)][0], g: grey[Int(index)][1], b: grey[Int(index)][2], a: 255) { wrong += 1 }
                }
                XCTAssertEqual(wrong, 0, "limit \(limit) clear \(clearAtFull)")
            }
        }
    }

    func testRepeatedRunsUseTheKwKwKCode() {
        // A long run of one index makes the encoder emit the code it has not added yet.
        XCTAssertEqual(grids(Fx.gif(width: 9, height: 1, frames: [.init(width: 9, height: 1, indices: solid(1, 9, 1))])), ["GGGGGGGGG"])
    }

    func testDataBeyondThePixelCountIsIgnored() {
        // the stream holds 6 indices for a 2x1 frame
        var f = Fx.Frame(width: 2, height: 1, indices: [0, 1, 2, 3, 2, 1])
        f.width = 2
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [f])), ["RG"])
    }

    // MARK: Extensions, tolerance

    func testExtensionsAreSkipped() {
        let netscape: [UInt8] = [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]
        let comment: [UInt8] = [0x21, 0xFE, 5] + Array("hello".utf8) + [0]
        let plainText: [UInt8] = [0x21, 0x01, 12] + [UInt8](repeating: 0, count: 12) + [3] + Array("abc".utf8) + [0]
        let unknown: [UInt8] = [0x21, 0x77, 2, 9, 9, 0]
        let data = Fx.gif(width: 2, height: 1, prefix: netscape + comment + plainText + unknown,
                          frames: [.init(width: 2, height: 1, indices: [2, 3])])
        XCTAssertEqual(grids(data), ["BW"])
    }

    func testTrailingGarbageAndMissingTrailerAreTolerated() {
        let frames = [Fx.Frame(width: 2, height: 1, indices: [0, 1])]
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: frames) + [1, 2, 3, 4, 5]), ["RG"])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: frames, trailer: false)), ["RG"])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: frames, trailer: false) + [0x00, 0x00, 0xFF]), ["RG"])
    }

    func testDataAfterTheTrailerIsNotDecoded() {
        let one = Fx.gif(width: 2, height: 1, frames: [.init(width: 2, height: 1, indices: [0, 1])])
        let two = Fx.gif(width: 2, height: 1, frames: [.init(width: 2, height: 1, indices: [2, 3])])
        XCTAssertEqual(grids(one + two), ["RG"])
    }

    func testManyFramesCapAtTheLimit() {
        let frame = Fx.Frame(width: 1, height: 1, indices: [0])
        let data = Fx.gif(width: 1, height: 1, frames: [Fx.Frame](repeating: frame, count: PlazaGIFDecoder.Limits.maxFrames + 20))
        XCTAssertEqual(PlazaGIFDecoder.frames(from: Data(data)).count, PlazaGIFDecoder.Limits.maxFrames)
    }

    // MARK: Malformed input

    func testHeaderAndScreenFailures() {
        XCTAssertEqual(PlazaGIFDecoder.frames(from: Data()).count, 0)
        XCTAssertEqual(PlazaGIFDecoder.frames(from: Data("GIF89a".utf8)).count, 0)
        XCTAssertEqual(PlazaGIFDecoder.frames(from: Data("PNG89a0000000".utf8)).count, 0)
        XCTAssertEqual(PlazaGIFDecoder.frames(from: Data("GIF88a0000000".utf8)).count, 0)
        let frame = Fx.Frame(width: 1, height: 1, indices: [0])
        XCTAssertEqual(grids(Fx.gif(width: 0, height: 4, frames: [frame])), [])
        XCTAssertEqual(grids(Fx.gif(width: 4, height: 0, frames: [frame])), [])
        let max = PlazaGIFDecoder.Limits.maxDimension
        XCTAssertEqual(grids(Fx.gif(width: max + 1, height: 1, frames: [frame])), [])
        XCTAssertEqual(grids(Fx.gif(width: 1, height: max + 1, frames: [frame])), [])
        XCTAssertEqual(grids(Fx.gif(width: 65535, height: 65535, frames: [frame])), [])
    }

    func testHugeFrameInsideASmallCanvasIsRefused() {
        let huge = Fx.Frame(width: 65535, height: 65535, indices: [0])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 2, frames: [huge])), [])
    }

    func testBadLZWFailsTheFrame() {
        let ok = Fx.gif(width: 2, height: 1, frames: [.init(width: 2, height: 1, indices: [0, 1])])
        // The image data starts after: header 13 + palette 12 + GCE 8 + descriptor 10 + min code 1 = block size byte.
        let start = 13 + 12 + 8 + 10 + 1
        var tooLarge = ok; tooLarge[start - 1] = 9
        XCTAssertEqual(grids(tooLarge), [])
        var zero = ok; zero[start - 1] = 0
        XCTAssertEqual(grids(zero), [])
        // a stream that ends (end code) before the frame is full
        let early = Fx.gif(width: 4, height: 1, frames: [Fx.Frame(width: 4, height: 1, indices: [0, 1])])
        XCTAssertEqual(grids(early), [])
    }

    func testCodeAboveTheNextFreeEntryFails() {
        // clear, 0, then code 7 where only 6 is free: minCode 2 -> 3-bit codes 100 000 111 101
        let bits: [Int] = [4, 0, 7, 5]
        var acc = 0, n = 0, stream: [UInt8] = []
        for c in bits { acc |= c << n; n += 3; while n >= 8 { stream.append(UInt8(acc & 255)); acc >>= 8; n -= 8 } }
        if n > 0 { stream.append(UInt8(acc & 255)) }
        var d = Fx.gif(width: 3, height: 1, frames: [.init(width: 3, height: 1, indices: [0, 0, 0])])
        let start = 13 + 12 + 8 + 10 + 1
        d.replaceSubrange(start..<d.count - 1, with: Fx.subBlocks(stream))
        XCTAssertEqual(grids(d), [])
        // and with a legal code (6 = the entry the encoder is about to add) it decodes
        var legal = d
        let good: [Int] = [4, 0, 6, 5]
        acc = 0; n = 0; stream = []
        for c in good { acc |= c << n; n += 3; while n >= 8 { stream.append(UInt8(acc & 255)); acc >>= 8; n -= 8 } }
        if n > 0 { stream.append(UInt8(acc & 255)) }
        legal.replaceSubrange(start..<legal.count - 0, with: Fx.subBlocks(stream) + [0x3B])
        XCTAssertEqual(grids(legal), ["RRR"])
    }

    func testFrameOutsideTheCanvasIsClipped() {
        let partly = Fx.Frame(left: 3, top: 1, width: 3, height: 3, indices: solid(2, 3, 3))
        XCTAssertEqual(grids(Fx.gif(width: 4, height: 3, frames: [partly])), ["KKKK/KKKB/KKKB"])
        let outside = Fx.Frame(left: 9, top: 9, width: 2, height: 2, indices: solid(2, 2, 2))
        XCTAssertEqual(grids(Fx.gif(width: 4, height: 3, frames: [outside])), ["KKKK/KKKK/KKKK"])
        let farOut = Fx.Frame(left: 65535, top: 65535, width: 2, height: 2, indices: solid(2, 2, 2))
        var clearing = farOut; clearing.disposal = 2
        XCTAssertEqual(grids(Fx.gif(width: 4, height: 3, frames: [clearing, farOut])), ["KKKK/KKKK/KKKK", "KKKK/KKKK/KKKK"])
        var interlaced = Fx.Frame(left: 0, top: 6, width: 1, height: 12, indices: solid(2, 1, 12))
        interlaced.interlaced = true
        XCTAssertEqual(grids(Fx.gif(width: 1, height: 8, frames: [interlaced])).count, 1)
    }

    func testZeroSizedFrameDrawsNothing() {
        let empty = Fx.Frame(width: 0, height: 0, indices: [])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [empty])), ["KK"])
        var clear = empty; clear.transparent = 0
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [clear])), [".."])
    }

    func testBlankCanvasIsBlackUnlessTheFileDeclaresTransparency() {
        // ImageIO's behaviour (the Mac parity test pins it): without a transparent index anywhere, nothing-painted is black.
        var second = Fx.Frame(left: 1, width: 1, height: 1, indices: [2])
        let first = Fx.Frame(width: 1, height: 1, indices: [0])
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [first, second])), ["RK", "RB"])
        second.transparent = 3   // declared in a later frame: the whole file counts
        XCTAssertEqual(grids(Fx.gif(width: 2, height: 1, frames: [first, second])), ["R.", "RB"])
    }

    func testTruncationAtEveryByteNeverCrashesAndKeepsWholeFramesOnly() {
        var first = Fx.Frame(width: 4, height: 4, indices: Fx.noise(count: 16, limit: 4, seed: 1))
        first.disposal = 1
        first.interlaced = true
        var second = Fx.Frame(left: 1, top: 1, width: 2, height: 2, indices: [3, 2, 1, 0])
        second.palette = Fx.palette4
        second.transparent = 3
        let netscape: [UInt8] = [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]
        let full = Fx.gif(width: 4, height: 4, prefix: netscape, frames: [first, second])
        let expected = grids(full)
        XCTAssertEqual(expected.count, 2)
        for length in 0..<full.count {
            let result = grids(Array(full[0..<length]))
            XCTAssertLessThanOrEqual(result.count, 2, "length \(length)")
            XCTAssertEqual(result, Array(expected.prefix(result.count)), "length \(length)")
        }
        // the cut points that matter: before the first frame completes there is nothing, after it there is one
        XCTAssertEqual(grids(Array(full[0..<(full.count - 1)])).count, 2, "only the trailer is missing")
        XCTAssertEqual(grids(Array(full[0..<20])).count, 0)
    }

    // MARK: Fuzz

    func testRandomByteMutationsNeverCrashOrHang() {
        var a = Fx.Frame(width: 12, height: 10, indices: Fx.noise(count: 120, limit: 4, seed: 7))
        a.interlaced = true; a.disposal = 2
        var b = Fx.Frame(left: 2, top: 3, width: 5, height: 4, indices: Fx.noise(count: 20, limit: 4, seed: 8))
        b.palette = Fx.palette4; b.transparent = 1; b.disposal = 3
        var c = Fx.Frame(width: 30, height: 30, indices: Fx.noise(count: 900, limit: 16, seed: 9))
        c.minCode = 4
        let netscape: [UInt8] = [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]
        let fixtures = [
            Fx.gif(width: 12, height: 10, prefix: netscape, frames: [a, b]),
            Fx.gif(width: 30, height: 30, global: (0..<16).map { [UInt8($0 * 16), 0, 0] }, frames: [c, a]),
            Fx.gif(width: 4, height: 4, version: "GIF87a", frames: [b]),
        ]
        var state: UInt64 = 0x9E3779B97F4A7C15
        func random(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        let start = Date()
        var decoded = 0
        for round in 0..<4000 {
            var d = fixtures[round % fixtures.count]
            for _ in 0..<(1 + random(4)) { d[random(d.count)] = UInt8(random(256)) }
            if round % 5 == 0 { d.removeSubrange(random(d.count)...) }
            if round % 7 == 0 { d.insert(UInt8(random(256)), at: random(d.count)) }
            for frame in PlazaGIFDecoder.frames(from: Data(d)) {
                XCTAssertEqual(frame.bytes.count, frame.width * frame.height * 4)
                decoded += 1
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 60, "4000 mutated decodes (\(decoded) frames)")
    }

    // MARK: Speed

    func testTypicalSpriteDecodesQuickly() {
        let w = 100, h = 100
        let frames = (0..<40).map { i -> Fx.Frame in
            var f = Fx.Frame(width: w, height: h, indices: Fx.noise(count: w * h, limit: 4, seed: UInt64(i)))
            f.disposal = 1
            return f
        }
        let data = Data(Fx.gif(width: w, height: h, frames: frames))
        let start = Date()
        let decoded = PlazaGIFDecoder.frames(from: data)
        let ms = Date().timeIntervalSince(start) * 1000
        print("PlazaGIFDecoder: 100x100 x 40 noisy frames (\(data.count) bytes) decoded in \(Int(ms)) ms")
        XCTAssertEqual(decoded.count, 40)
        XCTAssertLessThan(ms, 2000)
    }
}
