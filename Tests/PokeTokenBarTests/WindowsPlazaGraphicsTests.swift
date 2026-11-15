#if os(Windows)
import Crypto
import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 6 Task 2 on Windows: the plaza's resources are found, WIC decodes them to the Mac's bytes, PNG encode round-trips,
/// the GIF frames and delays equal the Mac's, and the COM rules hold on every kind of thread.
final class WindowsPlazaGraphicsTests: XCTestCase {
    private let graphics = WinPlazaGraphics.shared

    /// What a test thread reports back (a captured `var` cannot be written from a `@Sendable` thread body).
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The art lives in the checkout. `PTB_PLAZA_RESOURCES` says where; CI always sets it, a local run without it is skipped.
    private func requireResources() throws {
        if ProcessInfo.processInfo.environment[WinPlazaAssets.environmentKey] == nil, ProcessInfo.processInfo.environment["CI"] == nil {
            throw XCTSkip("set \(WinPlazaAssets.environmentKey) to the checkout's Resources\\Plaza and windows\\resources\\Plaza")
        }
    }

    // MARK: Resources

    func testBundledPlazaArtIsFoundOnWindows() throws {
        try requireResources()
        var names = PlazaDecodeGoldens.art.map { ($0.name, $0.ext) }
        names += [(PlazaDecodeGoldens.iceGIFName, "gif"), ("Galmuri11", "ttf"), ("Galmuri14", "ttf"),
                  ("Pretendard-Regular", "otf"), ("Pretendard-SemiBold", "otf"), ("Pretendard-Bold", "otf"),
                  ("CREDITS", "md"), ("Pretendard-OFL", "txt")]
        for (name, ext) in names {
            let url = try XCTUnwrap(graphics.assetURL(name, ext: ext), "\(name).\(ext) is not in \(WinPlazaAssets.directories.map(\.path))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        XCTAssertNil(graphics.assetURL("no-such-plaza-file", ext: "png"))
        XCTAssertNil(graphics.assetURL("../plaza-tiles", ext: "png"), "a name that climbs out of the folder resolves to nothing")
        XCTAssertNil(graphics.assetURL("a\\b", ext: "png"))
    }

    func testResourceDirectoriesOrder() {
        let exe = URL(fileURLWithPath: "C:\\Apps\\PokeTokenBar", isDirectory: true)
        let both = WinPlazaGraphics.resourceDirectories(environment: [WinPlazaAssets.environmentKey: "D:\\one;;  E:\\two ;"], executableDirectory: exe)
        XCTAssertEqual(both.count, 3)
        XCTAssertEqual(both[0].lastPathComponent, "one")
        XCTAssertEqual(both[1].lastPathComponent, "two")
        XCTAssertTrue(both[2].path.lowercased().replacingOccurrences(of: "\\", with: "/").hasSuffix("/apps/poketokenbar/resources/plaza"),
                      "the exe folder's Resources\\Plaza comes last: \(both[2].path)")
        let none = WinPlazaGraphics.resourceDirectories(environment: [:], executableDirectory: exe)
        XCTAssertEqual(none.count, 1)
        XCTAssertEqual(none[0], both[2])
        XCTAssertEqual(WinPlazaGraphics.resourceDirectories(environment: [WinPlazaAssets.environmentKey: ""], executableDirectory: exe), none)
    }

    func testAPackagedFolderIgnoresTheEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-res-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = [WinPlazaAssets.environmentKey: "D:\\elsewhere"]
        XCTAssertEqual(WinPlazaAssets.liveDirectories(processEnvironment: env, executableDirectory: dir).count, 2, "unpackaged: env + exe folder")
        try "2.5.0".write(to: dir.appendingPathComponent(WindowsInstall.versionFileName), atomically: true, encoding: .utf8)
        let packaged = WinPlazaAssets.liveDirectories(processEnvironment: env, executableDirectory: dir)
        XCTAssertEqual(packaged.count, 1, "packaged: the exe folder only")
        XCTAssertTrue(packaged[0].path.hasSuffix("Resources/Plaza") || packaged[0].path.hasSuffix("Resources\\Plaza"), packaged[0].path)
    }

    func testResolveFindsTheFirstFolderThatHasTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-res-\(UUID().uuidString)", isDirectory: true)
        let a = root.appendingPathComponent("a", isDirectory: true), b = root.appendingPathComponent("b", isDirectory: true)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: b.appendingPathComponent("x.png"))
        XCTAssertEqual(WinPlazaAssets.resolve("x", ext: "png", in: [a, b])?.deletingLastPathComponent().lastPathComponent, "b")
        try Data([2]).write(to: a.appendingPathComponent("x.png"))
        XCTAssertEqual(WinPlazaAssets.resolve("x", ext: "png", in: [a, b])?.deletingLastPathComponent().lastPathComponent, "a", "earlier folders win")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
        XCTAssertNil(WinPlazaAssets.resolve("dir", ext: "png", in: [a]), "a folder is not a file")
    }

    // MARK: Decode parity with the Mac

    func testDecodedArtMatchesTheMacBytes() throws {
        try requireResources()
        for art in PlazaDecodeGoldens.art {
            let url = try XCTUnwrap(graphics.assetURL(art.name, ext: art.ext))
            let image = try XCTUnwrap(graphics.decodeImage(at: url), "\(art.name) did not decode: \(WinPlazaCodecs.lastError())")
            XCTAssertEqual(image.width, art.width, art.name)
            XCTAssertEqual(image.height, art.height, art.name)
            XCTAssertEqual(sha256Hex(image.pixels.bytes), art.sha256, "\(art.name): pixels differ from the Mac's")
            XCTAssertEqual(image.pixels.alpha, .premultipliedLast)
            XCTAssertEqual(image.pixels.colorSpace, .sRGB)
        }
    }

    func testSemiTransparentFixtureMatchesTheMac() throws {
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64))
        XCTAssertEqual(png, WinIcon.fixturePNG, "the golden fixture is the tray's fixture")
        let straight = try WinPlazaCodecs.decodeStraight(png).get()
        XCTAssertEqual(straight.rgba[12..<16].map { $0 }, [0, 255, 0, 128], "WIC hands back STRAIGHT alpha")
        let image = try XCTUnwrap(graphics.decodeImage(png))
        XCTAssertEqual(image.pixels.bytes, PlazaDecodeGoldens.fixturePremultiplied, "premultiplied with CoreGraphics' rounding")
    }

    // MARK: PNG

    func testPNGRoundTripKeepsPixels() throws {
        // 16 x 16: every alpha step, one row of alpha 0.
        var straight = [UInt8]()
        for y in 0..<16 {
            for x in 0..<16 {
                let a = y == 5 ? 0 : (y * 16 + x)
                straight += [UInt8((x * 17) & 255), UInt8((y * 17) & 255), UInt8((x * y * 3) & 255), UInt8(a & 255)]
            }
        }
        // straight -> PNG -> straight is exact (WIC keeps straight values; alpha 0 stays alpha 0)
        let png = try WinPlazaCodecs.encodePNG(straight: straight, width: 16, height: 16).get()
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG signature")
        let back = try WinPlazaCodecs.decodeStraight(png).get()
        XCTAssertEqual(back.width, 16)
        XCTAssertEqual(back.height, 16)
        for i in stride(from: 0, to: straight.count, by: 4) {
            XCTAssertEqual(back.rgba[i + 3], straight[i + 3], "alpha at \(i / 4)")
            if straight[i + 3] != 0 { XCTAssertEqual(Array(back.rgba[i..<i + 4]), Array(straight[i..<i + 4]), "pixel \(i / 4)") }
        }
        // premultiplied image -> PNG -> image: within one un-premultiply step, alpha-0 rows kept
        let bitmap = PlazaPremultiply.bitmap(straight: straight, width: 16, height: 16)
        let premultiplied = bitmap.bytes
        let encoded = try XCTUnwrap(graphics.encodePNG(PlazaImage(bitmap: bitmap)))
        let decoded = try XCTUnwrap(graphics.decodeImage(encoded)).pixels.bytes
        XCTAssertEqual(decoded.count, premultiplied.count)
        let worst = zip(premultiplied, decoded).map { abs(Int($0) - Int($1)) }.max() ?? 99
        XCTAssertLessThanOrEqual(worst, 1, "round trip changes a premultiplied byte by at most 1")
        for i in stride(from: 0, to: premultiplied.count, by: 4) where premultiplied[i + 3] == 0 {
            XCTAssertEqual(Array(decoded[i..<i + 4]), [0, 0, 0, 0], "alpha 0 pixel \(i / 4) stays transparent black")
        }
    }

    func testBadBytesFailWithAnHRESULTNotACrash() {
        let result = WinPlazaCodecs.decodeStraight(Data([1, 2, 3, 4, 5, 6, 7, 8]))
        guard case .failure(let failure) = result else { return XCTFail("decoded garbage") }
        XCTAssertLessThan(failure.hresult, 0)
        XCTAssertFalse(failure.text.isEmpty, "the failing stage is named: \(failure.text)")
        XCTAssertNil(graphics.decodeImage(Data()))
        XCTAssertNil(graphics.decodeImage(Data("GIF89a".utf8)), "a GIF header with no image")
        XCTAssertTrue(graphics.decodeImageFrames(at: URL(fileURLWithPath: "C:\\no\\such\\file.gif")).isEmpty)
    }

    // MARK: GIF

    func testIceGifFramesMatchTheMac() throws {
        try requireResources()
        let url = try XCTUnwrap(graphics.assetURL(PlazaDecodeGoldens.iceGIFName, ext: "gif"))
        let frames = graphics.decodeImageFrames(at: url)
        XCTAssertEqual(frames.count, PlazaDecodeGoldens.iceGIF.count)
        for (i, pair) in zip(frames, PlazaDecodeGoldens.iceGIF).enumerated() {
            XCTAssertEqual(pair.0.width, PlazaDecodeGoldens.iceGIFSize.width)
            XCTAssertEqual(pair.0.height, PlazaDecodeGoldens.iceGIFSize.height)
            XCTAssertEqual(sha256Hex(pair.0.pixels.bytes), pair.1.sha256, "ice gif frame \(i) differs from ImageIO's")
        }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(PlazaGIFDecoder.framesWithDelays(from: data).map(\.delay), PlazaDecodeGoldens.iceGIF.map(\.delay))
        // the first image of a GIF is its first composited frame (what ImageIO's index 0 is), not WIC's sub-frame
        XCTAssertEqual(graphics.decodeImage(at: url)?.pixels, frames.first?.pixels)
    }

    func testWICAgreesWithTheSharedGIFDecoderOnCountAndDelays() throws {
        typealias Fx = PlazaGIFFixtures
        func frame(_ delay: Int, disposal: Int = 1) -> Fx.Frame {
            var f = Fx.Frame(width: 2, height: 2, indices: [0, 1, 2, 3]); f.delay = delay; f.disposal = disposal; return f
        }
        let gif = Data(Fx.gif(width: 2, height: 2, frames: [frame(0), frame(1), frame(2), frame(10), frame(250)]))
        let own = PlazaGIFDecoder.framesWithDelays(from: gif)
        let wic = try XCTUnwrap(WinPlazaCodecs.wicGIFDelays(gif), "WIC could not read the fixture: \(WinPlazaCodecs.lastError())")
        XCTAssertEqual(wic.count, own.count)
        XCTAssertEqual(wic.delaysCs, [0, 1, 2, 10, 250])
        XCTAssertEqual(wic.delaysCs.map { PlazaGIFDecoder.delaySeconds(centiseconds: $0) }, own.map(\.delay))
        XCTAssertNil(WinPlazaCodecs.wicGIFDelays(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64)!), "a PNG is not a GIF")
    }

    // MARK: COM

    func testWICWorksOnManyThreadsAtOnce() throws {
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64))
        let done = DispatchGroup()
        let failures = Box<[String]>([])
        for _ in 0..<8 {
            done.enter()
            let thread = Thread {
                for _ in 0..<20 {
                    switch WinPlazaCodecs.decodeImage(png) {
                    case .success(let image):
                        if image.pixels.bytes != PlazaDecodeGoldens.fixturePremultiplied { failures.value += ["pixels"] }
                    case .failure(let f): failures.value += [f.text]
                    }
                }
                done.leave()
            }
            thread.start()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.value, [])
    }

    func testAThreadThatIsAnSTAStillDecodes() throws {
        // The main thread is an STA: WIC (the codec's own MTA request returns RPC_E_CHANGED_MODE there) must still work.
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64))
        let finished = DispatchSemaphore(value: 0)
        let report = Box("")
        let thread = Thread {
            let initialised = WinCom.makeCurrentThreadSTA()
            let apartment = WinCom.current()
            var ok = false
            if case .success = WinPlazaCodecs.decodeStraight(png) { ok = true }
            let again = WinCom.current()
            var text = "init=\(initialised) apartment=\(apartment) decoded=\(ok) after=\(again)"
            if !(initialised >= 0 && apartment.isSTA && ok && again.isSTA) { text += " FAIL" }
            report.value = text
            finished.signal()
        }
        thread.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(report.value.hasSuffix("FAIL"), report.value)
        XCTAssertFalse(report.value.isEmpty)
    }

    func testAThreadWithoutCOMGetsAnMTAFromTheCodec() throws {
        let png = try XCTUnwrap(Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64))
        let finished = DispatchSemaphore(value: 0)
        let after = Box(WinCom.Apartment(hresult: -1, type: -1, qualifier: 0))
        let ok = Box(false)
        let thread = Thread {
            if case .success = WinPlazaCodecs.decodeStraight(png) { ok.value = true }
            after.value = WinCom.current()
            finished.signal()
        }
        thread.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(ok.value)
        XCTAssertTrue(after.value.isMTA, "the codec's own thread guard made this thread an MTA: \(after.value)")
    }

    func testTheProbeReportsAvailabilityWithoutCrashing() {
        let availability = WinPlazaGraphics.availability
        XCTAssertGreaterThanOrEqual(availability.wic, 0, availability.summary)
        XCTAssertGreaterThanOrEqual(availability.d2d, 0, availability.summary)
        XCTAssertGreaterThanOrEqual(availability.dwrite, 0, availability.summary)
        XCTAssertEqual(availability.missingDlls, 0, availability.summary)
    }
}
#endif
