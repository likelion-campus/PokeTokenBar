#if os(Windows)
import CPlazaD2D
import Foundation

/// The plaza's graphics on Windows: bundled assets and image codecs (WIC), canvases on Direct2D (`WinPlazaCanvas`), text on DirectWrite
/// (`WinPlazaTextEngine`).
///
/// Availability: the Direct2D / DirectWrite / WIC factories are created only when something asks (`availability`, the
/// first decode), never at launch. When one cannot be made the property says so, one line goes to the log, and the
/// callers that need it get nil / empty instead of a crash.
final class WinPlazaGraphics: PlazaGraphics, @unchecked Sendable {
    static let shared = WinPlazaGraphics()

    /// What a probe of the three factories found (`ptb_gfx_probe`), made once on first use.
    struct Availability: Sendable {
        let wic: Int32, d2d: Int32, dwrite: Int32, missingDlls: UInt32
        var isAvailable: Bool { wic >= 0 && d2d >= 0 && dwrite >= 0 }
        var summary: String {
            func hex(_ v: Int32) -> String { "0x" + String(UInt32(bitPattern: v), radix: 16, uppercase: true) }
            return "wic=\(hex(wic)) d2d=\(hex(d2d)) dwrite=\(hex(dwrite)) missingDlls=0x\(String(missingDlls, radix: 16))"
        }
    }

    /// Lazy and thread-safe (a `static let`). Logs one line when something is unavailable.
    static let availability: Availability = {
        var probe = PTBGfxProbe()
        _ = ptb_gfx_probe(&probe)
        let result = Availability(wic: probe.wic, d2d: probe.d2d, dwrite: probe.dwrite, missingDlls: probe.missingDlls)
        if !result.isAvailable { AppLog.write("plaza graphics unavailable: \(result.summary) (\(WinPlazaCodecs.lastError()))") }
        return result
    }()

    private let noted = NoteOnce()

    /// DirectWrite (Task 9); its fonts are made on the first text call, not here.
    let text: any PlazaTextEngine = WinPlazaTextEngine()

    func makeCanvas(width: Int, height: Int, colorSpace: PlazaColorSpace) -> (any PlazaCanvas)? {
        guard width > 0, height > 0 else { return nil }
        let a = Self.availability
        guard a.wic >= 0, a.d2d >= 0 else { return nil }   // the canvas needs WIC and Direct2D, not DirectWrite
        return WinPlazaCanvas(width: width, height: height, colorSpace: colorSpace)
    }

    static func resourceDirectories(environment: [String: String], executableDirectory: URL) -> [URL] {
        WinPlazaAssets.resourceDirectories(environment: environment, executableDirectory: executableDirectory)
    }

    func assetURL(_ name: String, ext: String) -> URL? {
        if let url = WinPlazaAssets.resolve(name, ext: ext, in: WinPlazaAssets.directories) { return url }
        noted.note("asset \(name).\(ext)", "plaza asset \(name).\(ext) not found in: "
            + WinPlazaAssets.directories.map { WinPath.native($0) }.joined(separator: "; "))
        return nil
    }

    func decodeImage(at url: URL) -> PlazaImage? {
        guard let data = read(url) else { return nil }
        return decodeImage(data)
    }

    func decodeImage(_ data: Data) -> PlazaImage? {
        switch WinPlazaCodecs.decodeImage(data) {
        case .success(let image): return image
        case .failure(let failure):
            noted.note("decode \(failure.text)", "plaza decode failed: \(failure.text) (\(data.count) bytes)")
            return nil
        }
    }

    func decodeImageFrames(at url: URL) -> [PlazaImage] {
        guard let data = read(url) else { return [] }
        switch WinPlazaCodecs.decodeFrames(data) {
        case .success(let frames): return frames
        case .failure(let failure):
            noted.note("frames \(failure.text)", "plaza frame decode failed: \(failure.text) (\(url.lastPathComponent))")
            return []
        }
    }

    func encodePNG(_ image: PlazaImage) -> Data? {
        switch WinPlazaCodecs.encodePNG(image) {
        case .success(let data): return data
        case .failure(let failure):
            noted.note("encode \(failure.text)", "plaza PNG encode failed: \(failure.text)")
            return nil
        }
    }

    private func read(_ url: URL) -> Data? {
        do { return try Data(contentsOf: url) } catch {
            noted.note("read \(url.path)", "plaza file unreadable: \(WinPath.native(url)): \(error)")
            return nil
        }
    }
}

/// One log line per distinct key (bounded), so a missing file or a bad sprite is reported once, not on every frame.
private final class NoteOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()

    func note(_ key: String, _ line: String) {
        lock.lock()
        let first = seen.count < 64 && seen.insert(key).inserted
        lock.unlock()
        if first { AppLog.write(line) }
    }
}
#endif
