import Foundation
import XCTest
@testable import PokeTokenBar

/// The cross-OS comparer's own rules on synthetic captures (both OSes): what it lets through, and what it must fail.
@MainActor
final class PlazaCrossCompareTests: XCTestCase {
    private func sprite(_ depth: Int = 1, origin: Character, x: Double = 0, y: Double = 49, w: Int = 28, h: Int = 25, hash: String = "aaaa", ordinal: Int = 0,
                        rect: PlazaCrossRect? = PlazaCrossRect(l: 10, t: 10, r: 38, b: 35)) -> PlazaCrossLine {
        PlazaCrossLine(origin: origin, rect: rect, text: String(repeating: " ", count: depth)
            + "SKSpriteNode name=- p=\(String(format: "%.4f,%.4f", x, y)) z=10.0000 a=1.0000 h=0 sc=1.0000,1.0000 rot=0 size=\(w).0000x\(h).0000 anchor=0.5000,0 color=1.0000,1.0000,1.0000,0 cbf=0 blend=0 tex\(ordinal):\(w)x\(h)#\(hash)")
    }

    private func root() -> PlazaCrossLine { PlazaCrossLine(origin: "-", rect: nil, text: "PlazaScene name=- p=0,0 z=0 a=1.0000 h=0 sc=1.0000,1.0000 rot=0") }

    private func capture(_ lines: [PlazaCrossLine], rgba: [UInt8]? = nil, w: Int = 64, h: Int = 48) -> PlazaCrossCapture {
        PlazaCrossCapture(stem: "t@1", kind: .scene, width: w, height: h, rgba: rgba ?? [UInt8](repeating: 120, count: w * h * 4), lines: lines)
    }

    func testIdenticalCapturesPass() async {
        let c = capture([root(), sprite(origin: "p"), sprite(origin: "t")])
        let r = PlazaCrossCompare.compare(mac: c, win: c)
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.treeState, "same")
        XCTAssertEqual(r.pixels.differingAll, 0)
    }

    func testTextTextureSizeAndHashAreAllowed() async {
        let mac = capture([root(), sprite(origin: "t", w: 33, h: 28, hash: "aaaa")])
        let win = capture([root(), sprite(origin: "t", w: 28, h: 25, hash: "bbbb")])
        let r = PlazaCrossCompare.compare(mac: mac, win: win)
        XCTAssertTrue(r.treeFailures.isEmpty, r.treeFailures.joined())
        XCTAssertEqual(r.allowed.filter { $0.cls == "a" }.count, 2, "size and texture")
    }

    func testPositionMovesAreBoundedByTheSiblingsTextDelta() async {
        // plate (text, 5 wider, 3 taller), emote (no texture), wet mark: the wet mark moves 3 pt in x (<= 5 + 1)
        let plateMac = sprite(origin: "t", w: 33, h: 28), plateWin = sprite(origin: "t", w: 28, h: 25)
        let wetMac = sprite(origin: "t", x: 18, y: 61.5, w: 16, h: 16, hash: "cccc", ordinal: 1)
        var wetWin = wetMac
        wetWin.text = wetWin.text.replacingOccurrences(of: "p=18.0000,61.5000", with: "p=15.0000,61.5000")
        let r = PlazaCrossCompare.compare(mac: capture([root(), plateMac, wetMac]), win: capture([root(), plateWin, wetWin]))
        XCTAssertTrue(r.treeFailures.isEmpty, r.treeFailures.joined())
        XCTAssertEqual(r.allowed.filter { $0.cls == "b" }.count, 1)
        // 7 pt is more than the delta allows
        wetWin.text = wetMac.text.replacingOccurrences(of: "p=18.0000,61.5000", with: "p=11.0000,61.5000")
        XCTAssertEqual(PlazaCrossCompare.compare(mac: capture([root(), plateMac, wetMac]), win: capture([root(), plateWin, wetWin])).treeFailures.count, 1)
    }

    func testAMovedNodeWithoutTextNearbyFailsBeyondOnePoint() async {
        let a = sprite(origin: "p", x: 10, y: 10)
        XCTAssertTrue(PlazaCrossCompare.compare(mac: capture([root(), a]), win: capture([root(), sprite(origin: "p", x: 10.5, y: 10)])).treeFailures.isEmpty)
        XCTAssertEqual(PlazaCrossCompare.compare(mac: capture([root(), a]), win: capture([root(), sprite(origin: "p", x: 12, y: 10)])).treeFailures.count, 1)
    }

    func testCanvasWithoutTextMayChangeItsHashButNotItsSize() async {
        let mac = capture([root(), sprite(origin: "c", w: 16, h: 16, hash: "aaaa")])
        XCTAssertTrue(PlazaCrossCompare.compare(mac: mac, win: capture([root(), sprite(origin: "c", w: 16, h: 16, hash: "bbbb")])).treeFailures.isEmpty)
        XCTAssertFalse(PlazaCrossCompare.compare(mac: mac, win: capture([root(), sprite(origin: "c", w: 17, h: 16, hash: "aaaa")])).treeFailures.isEmpty)
    }

    func testPixelArtMustMatchExactly() async {
        let mac = capture([root(), sprite(origin: "p", hash: "aaaa")])
        XCTAssertFalse(PlazaCrossCompare.compare(mac: mac, win: capture([root(), sprite(origin: "p", hash: "bbbb")])).treeFailures.isEmpty)
    }

    func testADroppedNodeAndAChangedOriginFail() async {
        let a = capture([root(), sprite(origin: "p"), sprite(origin: "p", x: 5)])
        let dropped = capture([root(), sprite(origin: "p")])
        let r = PlazaCrossCompare.compare(mac: a, win: dropped)
        XCTAssertEqual(r.treeState, "DIFF(1)")
        XCTAssertFalse(r.passed)
        XCTAssertFalse(PlazaCrossCompare.compare(mac: capture([root(), sprite(origin: "t")]), win: capture([root(), sprite(origin: "c")])).treeFailures.isEmpty)
    }

    func testAnUnexpectedFieldFails() async {
        var other = sprite(origin: "p")
        other.text = other.text.replacingOccurrences(of: "z=10.0000", with: "z=11.0000")
        XCTAssertFalse(PlazaCrossCompare.compare(mac: capture([root(), sprite(origin: "p")]), win: capture([root(), other])).treeFailures.isEmpty)
    }

    func testPixelToleranceAndTheMasks() async {
        let w = 100, h = 100
        let base = [UInt8](repeating: 100, count: w * h * 4)
        func shifted(by d: UInt8, pixels: Int) -> [UInt8] {
            var v = base
            for p in 0..<pixels { v[p * 4] = 100 + d }
            return v
        }
        let lines = [root(), sprite(origin: "p", rect: nil)]
        func compare(_ rgba: [UInt8]) -> PlazaCrossCompare.Result {
            PlazaCrossCompare.compare(mac: capture(lines, rgba: base, w: w, h: h), win: capture(lines, rgba: rgba, w: w, h: h))
        }
        XCTAssertTrue(compare(shifted(by: 3, pixels: w * h)).passed, "3 levels everywhere is inside the tolerance")
        XCTAssertFalse(compare(shifted(by: 4, pixels: w * h)).passed, "4 levels everywhere is not")
        XCTAssertTrue(compare(shifted(by: 9, pixels: 5)).pixelsPass, "5 pixels of 10000 above the tolerance are under 0.1 %")
        XCTAssertFalse(compare(shifted(by: 9, pixels: 50)).pixelsPass, "50 of 10000 are over")
        let r = compare(shifted(by: 9, pixels: 50))
        XCTAssertEqual(r.pixels.maxDiff, 9)
        XCTAssertEqual(r.pixels.worst?.x, 0)
    }

    func testMasksCoverTextRectanglesOnBothSidesGrown() async {
        let w = 100, h = 100
        let base = [UInt8](repeating: 100, count: w * h * 4)
        var win = base
        for y in 20..<30 { for x in 20..<40 { win[(y * w + x) * 4 + 1] = 250 } }
        let mac = capture([root(), sprite(origin: "t", w: 20, h: 10, rect: PlazaCrossRect(l: 20, t: 20, r: 40, b: 30))], rgba: base, w: w, h: h)
        let text = sprite(origin: "t", w: 21, h: 10, hash: "bbbb", rect: PlazaCrossRect(l: 20, t: 20, r: 41, b: 30))
        let covered = PlazaCrossCompare.compare(mac: mac, win: capture([root(), text], rgba: win, w: w, h: h))
        XCTAssertTrue(covered.passed, covered.treeFailures.joined())
        XCTAssertEqual(covered.pixels.over, 0)
        XCTAssertEqual(covered.pixels.differingMasked, 200)
        // the same pixel change under a node whose line did not change is not covered
        let plain = PlazaCrossCompare.compare(mac: capture([root(), sprite(origin: "t", rect: PlazaCrossRect(l: 20, t: 20, r: 40, b: 30))], rgba: base, w: w, h: h),
                                              win: capture([root(), sprite(origin: "t", rect: PlazaCrossRect(l: 20, t: 20, r: 40, b: 30))], rgba: win, w: w, h: h))
        XCTAssertFalse(plain.pixelsPass)
        XCTAssertEqual(plain.pixels.over, 200)
    }

    func testFractionalScalesGetTheirOwnEdgeFlipBoundAndKnownBugsMustKeepFailing() async {
        let w = 100, h = 100
        let base = [UInt8](repeating: 100, count: w * h * 4)
        var flips = base
        for p in 0..<30 { flips[p * 4] = 200 }   // 0.3 % of the frame
        var mac = capture([root()], rgba: base, w: w, h: h)
        var win = capture([root()], rgba: flips, w: w, h: h)
        XCTAssertFalse(PlazaCrossCompare.compare(mac: mac, win: win).pixelsPass, "0.3 % is over the whole-number-scale bound")
        mac.stem = "base-noon-1.25x@10"; win.stem = mac.stem
        XCTAssertTrue(PlazaCrossCompare.compare(mac: mac, win: win).pixelsPass, "but inside the fractional-scale bound")
        // a listed known bug that passes is reported as a failure of the list; one that fails is acceptable
        let name = PlazaCrossCompare.knownRendererBugs.keys.sorted()[0]
        mac.stem = name; win.stem = name
        let failing = PlazaCrossCompare.compare(mac: mac, win: capture([root()], rgba: [UInt8](repeating: 0, count: w * h * 4), w: w, h: h))
        var failingNamed = failing; failingNamed.stem = name
        let same = PlazaCrossCompare.compare(mac: mac, win: mac)
        XCTAssertTrue(failingNamed.known != nil && !failingNamed.passed && failingNamed.acceptable)
        XCTAssertTrue(same.known != nil && same.passed && !same.acceptable)
        XCTAssertTrue(PlazaCrossCompare.summary([same]).contains("remove it from knownRendererBugs"))
    }

    func testAOnePixelShiftIsCaught() async {
        let w = 64, h = 48
        var base = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v = UInt8((x / 4 + y / 4) % 2 * 200 + 20); for c in 0..<3 { base[(y * w + x) * 4 + c] = v }; base[(y * w + x) * 4 + 3] = 255 } }
        var shifted = base
        for y in 0..<h { for x in 1..<w { for c in 0..<4 { shifted[(y * w + x) * 4 + c] = base[(y * w + x - 1) * 4 + c] } } }
        let lines = [root()]
        XCTAssertFalse(PlazaCrossCompare.compare(mac: capture(lines, rgba: base, w: w, h: h), win: capture(lines, rgba: shifted, w: w, h: h)).passed)
    }

    func testReferenceRoundTripsAndDeduplicates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-cross-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        func frame(_ w: Int, _ h: Int, seed: Int) -> [UInt8] { (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: (($0 / 4) % w / 8 + ($0 / 4) / w / 8) * 31 + seed + ($0 % 4)) } }
        var a = PlazaCrossCapture(stem: "a@1", kind: .scene, width: 70, height: 35, rgba: frame(70, 35, seed: 1), lines: [root(), sprite(origin: "t")])
        var b = PlazaCrossCapture(stem: "b@2", kind: .scene, width: 70, height: 35, rgba: frame(70, 35, seed: 1), lines: [root()])
        b.rgba[(34 * 70 + 69) * 4] ^= 0xFF   // one pixel in the corner block differs
        var p = PlazaCrossCapture(stem: "photo-a", kind: .photo, width: 17, height: 3, rgba: frame(17, 3, seed: 9))
        p.photoRects = [PlazaCrossRect(l: 1, t: 2, r: 3, b: 4)]
        a.lines[1].rect = nil
        try PlazaCrossReference.write([b, a, p], to: dir)
        let reader = try PlazaCrossReference.Reader(directory: dir)
        XCTAssertEqual(reader.stems, ["a@1", "b@2", "photo-a"])
        for original in [a, b, p] {
            let back = try reader.capture(original.stem)
            XCTAssertEqual(back.rgba, original.rgba, original.stem)
            XCTAssertEqual(back.lines, original.lines, original.stem)
            XCTAssertEqual(back.photoRects, original.photoRects, original.stem)
            XCTAssertEqual(PlazaTreeDump.sha256Hex(back.rgba), reader.entries[original.stem]?.sha256)
        }
        let atlas = try Data(contentsOf: dir.appendingPathComponent("atlas.bin")).count / PlazaCrossReference.blockBytes
        XCTAssertLessThanOrEqual(atlas, 5 * 3 + 1 + 2, "a@1 and b@2 share every block but one")
    }

    func testTheReportNamesTheWorstCapturesAndSkips() async throws {
        let w = 64, h = 48
        let base = [UInt8](repeating: 100, count: w * h * 4)
        var bad = base
        for i in 0..<(w * 20) { bad[i * 4] = 200 }
        var m1 = capture([root()], rgba: base, w: w, h: h); m1.stem = "good@1"
        var m2 = capture([root()], rgba: base, w: w, h: h); m2.stem = "bad@1"
        var w2 = capture([root()], rgba: bad, w: w, h: h); w2.stem = "bad@1"
        var w1 = m1; w1.stem = "good@1"
        let mac = ["good@1": m1, "bad@1": m2], win = ["good@1": w1, "bad@1": w2]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-cross-report-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try PlazaCrossReport.run(stems: ["good@1", "bad@1"], mac: { mac[$0]! }, win: { win[$0]! }, skipped: ["real-sprites: needs the cache"], to: dir)
        XCTAssertTrue(out.summary.hasPrefix("CROSS: 1 fail: bad@1"), out.summary)
        XCTAssertEqual(PlazaCrossReport.worstFirst(out.results).first?.stem, "bad@1")
        let md = try String(contentsOf: dir.appendingPathComponent("report.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("skipped") || md.contains("real-sprites: needs the cache"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("worst-1-bad@1.png").path))
    }
}
