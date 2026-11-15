#if os(Windows)
import CPlazaD2D
import Crypto
import Foundation
import WinSDK

/// Stage 6 Task 2: the graphics foundation. The UI thread is an STA, WIC works on it and on worker threads, the Direct2D /
/// DirectWrite / WIC factories exist but are made lazily, the bundled files resolve and decode like the Mac's, GIF delays
/// agree. Every line prints measured values. Packaged and installed runs resolve the files from `<exe folder>\Resources\Plaza`.
extension WindowsSelftest {
    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hresultText(_ v: Int32) -> String { "0x" + String(UInt32(bitPattern: v), radix: 16, uppercase: true) }

    private static func isLoaded(_ dll: String) -> Bool {
        dll.withCString(encodedAs: UTF16.self) { GetModuleHandleW($0) } != nil
    }

    /// Run first: nothing of ours has asked for a Direct2D or DirectWrite object yet, so neither DLL is in the process.
    @MainActor static func graphicsLazinessCheck(_ r: Recorder) {
        let d2d = isLoaded("d2d1.dll"), dwrite = isLoaded("dwrite.dll")
        r.add("plaza.graphics.lazy", !d2d && !dwrite,
              "before any plaza call: d2d1.dll loaded=\(d2d) dwrite.dll loaded=\(dwrite) (delay-loaded, nothing created at launch)")
    }

    @MainActor static func plazaGraphicsChecks(_ r: Recorder) async {
        let fixture = Data(base64Encoded: PlazaDecodeGoldens.fixturePNGBase64) ?? Data()

        // --- COM: the UI thread is an STA, and everything that used COM before still works on it.
        let beforeWork = WinCom.current()
        let trayDecode = WinIcon.decode(png: WinIcon.fixturePNG)  // the tray's path: CWinShim, CoInitializeEx(MTA) -> RPC_E_CHANGED_MODE
        let wicOnMain = WinPlazaCodecs.decodeStraight(fixture)
        let wicMainOK: Bool
        if case .success = wicOnMain { wicMainOK = true } else { wicMainOK = false }
        let afterWork = WinCom.current()
        let initCode = WinCom.initializeResult
        r.add("com.uiThreadSTA", beforeWork.isSTA && afterWork.isSTA && (initCode ?? -1) >= 0 && trayDecode != nil && wicMainOK,
              "atLaunchBeforeInit=\(WinCom.atLaunch.map(\.description) ?? "unmeasured") CoInitializeEx(STA)=\(initCode.map(hresultText) ?? "not called") "
                + "now=\(beforeWork) afterTrayAndWicDecode=\(afterWork) trayDecode=\(trayDecode != nil) wicDecodeOnMain=\(wicMainOK)")

        // --- COM on worker threads: a fresh thread gets its own MTA, WIC works there, the thread ends cleanly.
        struct Worker: Sendable { var before: String, after: String, tray: Bool, wic: Bool, pixels: [UInt8] }
        let worker: Worker = await withCheckedContinuation { continuation in
            let thread = Thread {
                let before = WinCom.current()
                let tray = WinIcon.decode(png: WinIcon.fixturePNG) != nil
                var wic = false, pixels: [UInt8] = []
                if case .success(let d) = WinPlazaCodecs.decodeStraight(fixture) { wic = true; pixels = d.rgba }
                continuation.resume(returning: Worker(before: before.description, after: WinCom.current().description, tray: tray, wic: wic, pixels: pixels))
            }
            thread.start()
        }
        let again = WinPlazaCodecs.decodeStraight(fixture)
        var againOK = false
        if case .success = again { againOK = true }
        r.add("com.workerThreads", worker.tray && worker.wic && worker.after.hasPrefix("MTA") && againOK && WinCom.current().isSTA,
              "fresh thread: apartment before=\(worker.before) after=\(worker.after) trayDecode=\(worker.tray) wicDecode=\(worker.wic); "
                + "after the thread ended the main thread decodes again=\(againOK) and is \(WinCom.current())")

        // --- the three factories (created now, not at launch)
        let availability = WinPlazaGraphics.availability
        r.add("plaza.graphics.available", availability.isAvailable,
              "\(availability.summary) after the probe: d2d1.dll loaded=\(isLoaded("d2d1.dll")) dwrite.dll loaded=\(isLoaded("dwrite.dll"))")

        // --- resources: every kind resolves from the app's own folder and decodes
        let exeDirectory = URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true)
        let packaged = WindowsInstall.isPackagedLayout
        let allowedPrefix = (WinPath.native(exeDirectory) + "\\Resources\\Plaza\\").lowercased()
        let graphics = WinPlazaGraphics.shared
        var problems: [String] = [], seen: [String] = []
        func resolve(_ name: String, _ ext: String) -> URL? {
            guard let url = graphics.assetURL(name, ext: ext) else { problems.append("\(name).\(ext) not found"); return nil }
            let native = WinPath.native(url)
            seen.append("\(name).\(ext)")
            if packaged, !native.lowercased().hasPrefix(allowedPrefix) { problems.append("\(name).\(ext) resolved outside the app folder: \(native)") }
            return url
        }
        for art in PlazaDecodeGoldens.art {
            guard let url = resolve(art.name, art.ext) else { continue }
            guard let image = graphics.decodeImage(at: url) else { problems.append("\(art.name).\(art.ext) did not decode (\(WinPlazaCodecs.lastError()))"); continue }
            let hash = sha256Hex(image.pixels.bytes)
            if image.width != art.width || image.height != art.height || hash != art.sha256 {
                problems.append("\(art.name): \(image.width)x\(image.height) sha=\(hash.prefix(12)) expected \(art.width)x\(art.height) sha=\(art.sha256.prefix(12))")
            }
        }
        if let gif = resolve(PlazaDecodeGoldens.iceGIFName, "gif") {
            let frames = graphics.decodeImageFrames(at: gif)
            if frames.count != PlazaDecodeGoldens.iceGIF.count { problems.append("ice gif has \(frames.count) frames, expected \(PlazaDecodeGoldens.iceGIF.count)") }
            for (i, pair) in zip(frames, PlazaDecodeGoldens.iceGIF).enumerated() where sha256Hex(pair.0.pixels.bytes) != pair.1.sha256 {
                problems.append("ice gif frame \(i) differs from the Mac")
            }
        }
        var fonts: [String] = []
        for (name, ext) in [("Galmuri11", "ttf"), ("Galmuri14", "ttf"), ("Pretendard-Regular", "otf"), ("Pretendard-SemiBold", "otf"), ("Pretendard-Bold", "otf")] {
            guard let url = resolve(name, ext) else { continue }
            var supported: Int32 = 0, faces: UInt32 = 0
            let code = WinPath.native(url).withCString(encodedAs: UTF16.self) { ptb_dwrite_analyze_font($0, &supported, &faces) }
            let size = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Int? in
                defer { try? handle.close() }
                return (try? handle.seekToEnd()).map { Int($0) }
            } ?? 0
            if code < 0 || supported == 0 || faces < 1 || size < 100_000 {
                problems.append("\(name).\(ext): DirectWrite hr=\(hresultText(code)) supported=\(supported) faces=\(faces) bytes=\(size) (\(WinPlazaCodecs.lastError()))")
            }
            fonts.append("\(name).\(ext)=\(size)B/\(faces)face")
        }
        let escaped = packaged ? "env ignored" : "env PTB_PLAZA_RESOURCES honoured"
        r.add("plaza.resources", problems.isEmpty,
              "layout=\(packaged ? "packaged" : "unpackaged") (\(escaped)) folders=\(WinPlazaAssets.directories.map { WinPath.native($0) }) "
                + "resolved=\(seen.count) \(problems.isEmpty ? "art+gif decode bytes equal the Mac, fonts accepted by DirectWrite: \(fonts.joined(separator: " "))" : "problems=\(problems)")")

        // --- PNG: semi-transparent fixture equals the Mac's bytes; round trip keeps pixels and alpha-0 rows
        var parity = "decode failed", parityOK = false
        if let image = graphics.decodeImage(fixture) {
            parityOK = image.pixels.bytes == PlazaDecodeGoldens.fixturePremultiplied
            parity = "premultiplied == Mac: \(parityOK) alpha=\(image.pixels.bytes.enumerated().filter { $0.offset % 4 == 3 && $0.element != 0 }.map(\.element))"
        }
        var roundTrip = "no image", roundTripOK = false
        if let image = graphics.decodeImage(fixture), let png = graphics.encodePNG(image), let back = graphics.decodeImage(png) {
            let a = image.pixels.bytes, b = back.pixels.bytes
            let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? -1
            let zeroRows = stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] != 0 || (b[$0] == 0 && b[$0 - 1] == 0 && b[$0 - 2] == 0 && b[$0 - 3] == 0) }
            roundTripOK = worst <= 1 && a.count == b.count && zeroRows && back.width == image.width
            roundTrip = "png=\(png.count)B maxDiff=\(worst) alpha0StaysZero=\(zeroRows)"
        }
        r.add("plaza.codec.png", parityOK && roundTripOK, "fixture \(parity); round trip \(roundTrip)")

        // --- GIF: the shared decoder's frames and delays equal the Mac's; WIC's own count and delays agree
        var gifDetail = "ice gif not found", gifOK = false
        if let url = graphics.assetURL(PlazaDecodeGoldens.iceGIFName, ext: "gif"), let data = try? Data(contentsOf: url) {
            let own = PlazaGIFDecoder.framesWithDelays(from: data)
            let wic = WinPlazaCodecs.wicGIFDelays(data)
            let ownDelays = own.map(\.delay)
            let golden = PlazaDecodeGoldens.iceGIF.map(\.delay)
            let wicDelays = wic?.delaysCs.map { PlazaGIFDecoder.delaySeconds(centiseconds: $0) } ?? []
            gifOK = ownDelays == golden && wic?.count == own.count && wicDelays == ownDelays
            gifDetail = "frames=\(own.count) delays=\(ownDelays) mac=\(golden) wicFrames=\(wic.map { String($0.count) } ?? "n/a") wicDelaysCs=\(wic?.delaysCs.map { $0.map(String.init) ?? "-" } ?? [])"
        }
        r.add("plaza.codec.gif", gifOK, gifDetail + " (pixels: PlazaGIFDecoder, the authority; WIC only cross-checks count and delays)")
    }
}
#endif
