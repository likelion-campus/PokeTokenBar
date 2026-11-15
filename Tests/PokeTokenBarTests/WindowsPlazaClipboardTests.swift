#if os(Windows)
import CPlazaD2D
import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 12 on Windows: the photo on the clipboard (PNG + DIBV5), text, a busy clipboard, the photo against the Mac's,
/// and memory over many photos. These write the REAL clipboard, so they run only where `CI` is set (the runner), never on a
/// developer's PC; `PTB_ALLOW_CLIPBOARD_TESTS=1` overrides that on purpose.
@MainActor
final class WindowsPlazaClipboardTests: XCTestCase {
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func requireRunner() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CI"] != nil || env["PTB_ALLOW_CLIPBOARD_TESTS"] == "1", "these tests replace the clipboard; they run on the CI runner only")
    }

    /// 6 x 4, every pixel distinct, with semi-transparent ones (straight values 200/100/50 alpha 128, 255/0/0 alpha 0 is stored 0,0,0,0).
    private func fixture() -> PlazaBitmap {
        var b = PlazaBitmap(width: 6, height: 4)
        for y in 0..<4 { for x in 0..<6 { b[x, y] = PlazaRGBA(r: UInt8(10 + x * 30), g: UInt8(20 + y * 50), b: UInt8(200 - x * 10 - y * 20), a: 255) } }
        b[0, 0] = PlazaRGBA(r: 250, g: 10, b: 10, a: 255)   // top-left: red, to tell the orientation
        b[5, 3] = PlazaRGBA(r: 10, g: 10, b: 250, a: 255)   // bottom-right: blue
        b[2, 1] = PlazaRGBA(r: 100, g: 50, b: 25, a: 128)   // premultiplied, as the plaza stores it
        b[3, 1] = PlazaRGBA(r: 0, g: 0, b: 0, a: 0)
        return b
    }

    private func straightBytes(_ png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        switch WinPlazaCodecs.decodeStraight(png) {
        case .success(let s): return s
        case .failure(let e): XCTFail("decode: \(e)"); throw e
        }
    }

    func testPhotoGoesOnTheClipboardAsPNGAndDIBV5() async throws {
        try requireRunner()
        let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(PlazaImage(bitmap: fixture())))
        let log = LogBox()
        XCTAssertTrue(WinImageClipboard(log: { log.add($0) }).writePNG(png), log.lines.joined(separator: "; "))
        XCTAssertTrue(log.lines.isEmpty)

        XCTAssertEqual(WinImageClipboard.read(format: WinImageClipboard.pngFormat), png, "the PNG format holds the bytes as encoded")
        let want = try straightBytes(png)
        let dib = try XCTUnwrap(WinImageClipboard.readDIBV5(), "no valid CF_DIBV5")
        XCTAssertEqual(dib.width, 6)
        XCTAssertEqual(dib.height, 4)
        XCTAssertEqual(dib.rgba, want.rgba, "the DIB's pixels (straight alpha, top row first after undoing bottom-up) are the PNG's")
        XCTAssertEqual(Array(dib.rgba[0..<4]), [250, 10, 10, 255], "top-left is red: not upside down")
        XCTAssertEqual(Array(dib.rgba[(3 * 6 + 5) * 4..<(3 * 6 + 5) * 4 + 4]), [10, 10, 250, 255], "bottom-right is blue")
        let semi = Array(dib.rgba[(1 * 6 + 2) * 4..<(1 * 6 + 2) * 4 + 4])
        XCTAssertEqual(semi[3], 128)
        XCTAssertEqual(semi[0], PlazaPremultiply.straight(100, alpha: 128), "alpha is STRAIGHT in the DIB (colour divided by alpha)")
        XCTAssertEqual(Array(dib.rgba[(1 * 6 + 3) * 4..<(1 * 6 + 3) * 4 + 4]), [0, 0, 0, 0])
    }

    func testTheRealPhotoRoundTripsThroughTheClipboard() async throws {
        try requireRunner()
        let scene = try XCTUnwrap(PlazaPreviewScenes.photoScenes.first { $0.name == "base-noon" })
        let made = await PlazaPhotoGoldens.photoInput(scene)
        let input = try XCTUnwrap(made)
        let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input))
        let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(photo))
        XCTAssertTrue(WinImageClipboard().writePNG(png))
        let dib = try XCTUnwrap(WinImageClipboard.readDIBV5())
        XCTAssertEqual(dib.width, photo.width)
        XCTAssertEqual(dib.height, photo.height)
        let fromPNG = try XCTUnwrap(PlatformPlaza.graphics.decodeImage(try XCTUnwrap(WinImageClipboard.read(format: WinImageClipboard.pngFormat))))
        XCTAssertEqual(fromPNG.pixels.bytes, photo.pixels.bytes, "the clipboard's PNG decodes to the photo, pixel for pixel")
        XCTAssertEqual(dib.rgba, photo.pixels.bytes, "an opaque photo is the same in straight and premultiplied form: the DIB equals it")
    }

    func testTextGoesOnAsUnicode() async throws {
        try requireRunner()
        let log = LogBox()
        let clip = WinImageClipboard(log: { log.add($0) })
        for text in ["PTB-ABCD-1234", "안녕하세요 팀코드 \u{1F95A}\u{1F600} é", "line one\r\nline two", ""] {
            XCTAssertTrue(clip.writeText(text), log.lines.joined(separator: "; "))
            XCTAssertEqual(WinImageClipboard.readText(), text)
        }
        XCTAssertNil(WinImageClipboard.read(format: WinImageClipboard.pngFormat, timeoutMs: 50), "text replaces the photo formats")
    }

    func testABusyClipboardFailsHonestly() async throws {
        try requireRunner()
        XCTAssertTrue(WinImageClipboard().writeText("before"))
        let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(PlazaImage(bitmap: fixture())))
        let log = LogBox()
        let clip = WinImageClipboard(timeoutMs: 60, log: { log.add($0) })

        XCTAssertTrue(WinImageClipboard.holdOpen(milliseconds: 600), "the other thread could not open the clipboard")
        let started = Date()
        XCTAssertFalse(clip.writePNG(png), "another window has the clipboard open: the copy must say it failed")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.05, "it retried for its timeout first")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "and did not wait for the other window")
        XCTAssertFalse(clip.writeText("during"))
        XCTAssertEqual(log.lines.count, 2, "one log line per failed copy: \(log.lines)")
        XCTAssertTrue(log.lines.allSatisfy { $0.contains("not copied") && $0.contains("busy") }, "\(log.lines)")

        // Released: the old contents are untouched, and the next copy works.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(WinImageClipboard.readText(), "before", "a failed copy leaves the clipboard as it was")
        XCTAssertTrue(clip.writePNG(png))

        // A holder that lets go within the timeout is waited for.
        XCTAssertTrue(WinImageClipboard.holdOpen(milliseconds: 150))
        XCTAssertTrue(WinImageClipboard(timeoutMs: 2000).writePNG(png), "retried until the other window closed it")
        XCTAssertNotNil(WinImageClipboard.read(format: WinImageClipboard.pngFormat))
    }

    func testBytesThatAreNoPNGAreNotCopied() async throws {
        try requireRunner()
        XCTAssertTrue(WinImageClipboard().writeText("keep"))
        let log = LogBox()
        XCTAssertFalse(WinImageClipboard(log: { log.add($0) }).writePNG(Data([1, 2, 3, 4])))
        XCTAssertEqual(log.lines.count, 1)
        XCTAssertEqual(WinImageClipboard.readText(), "keep")
    }

    /// Fifty photos in a row: the system owns each clipboard block until the next copy replaces it, so the process does not grow.
    func testFiftyPhotosDoNotGrowTheProcess() async throws {
        try requireRunner()
        let scene = try XCTUnwrap(PlazaPreviewScenes.photoScenes.first { $0.name == "base-noon" })
        let made = await PlazaPhotoGoldens.photoInput(scene)
        let input = try XCTUnwrap(made)
        let clip = WinImageClipboard()
        func one() throws {
            let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input))
            let png = try XCTUnwrap(PlatformPlaza.graphics.encodePNG(photo))
            XCTAssertTrue(clip.writePNG(png))
        }
        for _ in 0..<5 { try one() }
        let before = ptb_gfx_process_private_bytes(), handlesBefore = ptb_process_handle_count()
        for _ in 0..<50 { try one() }
        let after = ptb_gfx_process_private_bytes(), handlesAfter = ptb_process_handle_count()
        let growth = Double(after) / 1_048_576 - Double(before) / 1_048_576
        print("PLAZA-PHOTO memory: 50 photos, private bytes \(before / 1_048_576) -> \(after / 1_048_576) MB (growth \(String(format: "%.1f", growth)) MB), handles \(handlesBefore) -> \(handlesAfter)")
        XCTAssertLessThan(growth, 40, "private bytes grew over 50 photos")
        XCTAssertLessThanOrEqual(handlesAfter, handlesBefore + 4, "handles grew over 50 photos")
    }

    // MARK: Against the Mac

    /// The eight photo scenes, rendered by the Windows canvas and text engine, against the Mac's PNGs: ±2 outside the name plates and
    /// bubbles (each OS's own text), report-only inside them. With `PTB_PHOTO_OUT` the Windows photos are written there.
    func testPhotoBytesLookLikeTheMacs() async throws {
        try XCTSkipUnless(TimeZone.current.secondsFromGMT() == 0, "the Mac goldens were made with TZ=UTC")
        let manifest = try PlazaPhotoGoldens.loadManifest()
        let out = ProcessInfo.processInfo.environment["PTB_PHOTO_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var summary: [String] = []
        for scene in PlazaPreviewScenes.photoScenes {
            let made = await PlazaPhotoGoldens.photoInput(scene)
            let input = try XCTUnwrap(made, scene.name)
            let photo = try XCTUnwrap(PlazaPhotoRenderer.render(input), scene.name)
            let golden = try XCTUnwrap(PlatformPlaza.graphics.decodeImage(Data(contentsOf: PlazaPhotoGoldens.pngURL(scene.name))), scene.name)
            let entry = try XCTUnwrap(manifest.scenes[scene.name], scene.name)
            let mask = PlazaPhotoGoldens.plateCells(input, photo: photo).union(entry.plateCells)
            let c = PlazaPhotoGoldens.compare(got: photo, want: golden, mask: mask, tolerance: 2)
            if let out, let png = PlatformPlaza.graphics.encodePNG(photo) { try png.write(to: out.appendingPathComponent("photo-\(scene.name).png")) }
            let line = "\(scene.name): \(photo.width)x\(photo.height) (Mac \(golden.width)x\(golden.height)); outside plates max diff \(c.maxOutside), "
                + "\(c.wrongOutside) of \(c.pixelsOutside) px over 2\(c.worstAt.isEmpty ? "" : " (worst \(c.worstAt))"); in plates \(c.differInPlates) of \(c.pixelsInPlates) px differ (report only)"
            summary.append(line)
            XCTAssertTrue(c.sizeMatches, "\(scene.name): size \(photo.width)x\(photo.height) is not the Mac's \(golden.width)x\(golden.height)")
            XCTAssertEqual(c.wrongOutside, 0, line)
        }
        print("PLAZA-PHOTO parity:\n" + summary.joined(separator: "\n"))
    }
}
#endif
