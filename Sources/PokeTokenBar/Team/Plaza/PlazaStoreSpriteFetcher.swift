import Foundation

/// What the plaza's sprite loaders need from the sprite store: the bytes of a sprite (cache file, else the download) and
/// the egg, and the cache folder. `SpriteStore` is the real one; a test hands in a fake with no network.
protocol PlazaSpriteSource: Sendable {
    var directory: URL { get }
    func data(speciesID: Int, animated: Bool, shiny: Bool, form: PokemonForm?, back: Bool) async -> Data?
    func eggData() async -> Data?
}

extension SpriteStore: PlazaSpriteSource {}

/// Animated GIF bytes to frames with their delays. Must not touch main-actor state; it runs off the main actor.
typealias PlazaGIFFrameDecoder = @Sendable (Data) -> [(image: PlazaImage, delay: TimeInterval)]

/// The GIF path until the shared decoder returns delays itself: `PlazaGIFDecoder` frames and the delays read from the
/// graphic control extensions, as `UI/GIFDecoder` computes them (the unclamped delay, 0.1 s when missing or under
/// 0.02 s; a one-frame GIF is no animation and gives `[]`).
enum PlazaStoreGIF {
    static func frames(from data: Data) -> [(image: PlazaImage, delay: TimeInterval)] {
        let bitmaps = PlazaGIFDecoder.frames(from: data)
        guard bitmaps.count > 1 else { return [] }
        let delays = delays(in: data)
        return bitmaps.enumerated().map { (PlazaImage(bitmap: $1), $0 < delays.count ? delays[$0] : 0.1) }
    }

    /// One delay per image descriptor, in order.
    static func delays(in data: Data) -> [TimeInterval] {
        let b = [UInt8](data)
        guard b.count >= 13, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { return [] }
        var pos = 13
        if b[10] & 0x80 != 0 { pos += 3 << (Int(b[10] & 7) + 1) }
        var out: [TimeInterval] = []
        var pending: TimeInterval?
        func skipSubBlocks() {
            while pos < b.count {
                let n = Int(b[pos]); pos += 1
                if n == 0 { return }
                pos += n
            }
        }
        while pos < b.count {
            switch b[pos] {
            case 0x21:
                guard pos + 1 < b.count else { return out }
                let label = b[pos + 1]
                pos += 2
                if label == 0xF9, pos + 3 < b.count {
                    let seconds = Double(Int(b[pos + 2]) | Int(b[pos + 3]) << 8) / 100
                    pending = seconds < 0.02 ? 0.1 : seconds
                }
                skipSubBlocks()
            case 0x2C:
                guard pos + 10 <= b.count else { return out }
                let flags = b[pos + 9]
                pos += 10
                if flags & 0x80 != 0 { pos += 3 << (Int(flags & 7) + 1) }
                pos += 1
                skipSubBlocks()
                out.append(pending ?? 0.1)
                pending = nil
            default:
                return out
            }
        }
        return out
    }
}

/// The report lines already written (once each per process).
final class PlazaReportedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    /// True the first time `line` is given.
    func first(_ line: String) -> Bool { lock.withLock { seen.insert(line).inserted } }
}

/// What the loader keeps in memory: decoded animations (the Mac's `animationCache`, 16 sets, oldest out first) and the
/// cropped egg (once). Lock-guarded; the decoding runs off the main actor.
final class PlazaSpriteMemory: @unchecked Sendable {
    static let frameSets = 16
    private let lock = NSLock()
    private var frames: [String: [(image: PlazaImage, delay: TimeInterval)]] = [:]
    private var order: [String] = []
    private var egg: PlazaImage?

    func frames(for key: String) -> [(image: PlazaImage, delay: TimeInterval)]? {
        lock.lock(); defer { lock.unlock() }
        return frames[key]
    }

    func keep(_ value: [(image: PlazaImage, delay: TimeInterval)], for key: String) {
        lock.lock(); defer { lock.unlock() }
        if frames[key] == nil { order.append(key) }
        frames[key] = value
        while order.count > Self.frameSets { frames.removeValue(forKey: order.removeFirst()) }
    }

    var cachedEgg: PlazaImage? { lock.lock(); defer { lock.unlock() }; return egg }
    func keepEgg(_ image: PlazaImage) { lock.lock(); egg = image; lock.unlock() }
}

/// `LivePlazaSpriteFetcher` over `SpriteStore` and the platform's image decoder, so the same loader serves every OS.
/// Front pictures: the GIF (shiny, then plain), else the still PNG (shiny, then plain). Back pictures come from the back
/// files only (shiny, then plain); a back sprite that is missing or fails gives nothing, and `PlazaCharacterLoader`
/// stands the front in. Files and decoding run off the main actor; results come back to it. Concurrent asks for one
/// sprite are not merged here (the store's memory cache answers the second; `PlazaPictureCache` merges panel asks).
struct PlazaStoreSpriteFetcher: PlazaSpriteFetching {
    private let source: any PlazaSpriteSource
    private let graphics: any PlazaGraphics
    private let decodeGIF: PlazaGIFFrameDecoder
    private let memory = PlazaSpriteMemory()

    init(store: SpriteStore = .shared, graphics: any PlazaGraphics = PlatformPlaza.graphics) {
        self.init(source: store, graphics: graphics)
    }

    init(source: any PlazaSpriteSource, graphics: any PlazaGraphics = PlatformPlaza.graphics,
         decodeGIF: @escaping PlazaGIFFrameDecoder = { PlazaStoreGIF.frames(from: $0) }) {
        self.source = source
        self.graphics = graphics
        self.decodeGIF = decodeGIF
    }

    /// The cropped egg if it has been loaded, without waiting.
    var cachedEgg: PlazaImage? { memory.cachedEgg }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        await Self.loadFrames(source: source, decode: decodeGIF, memory: memory, speciesID: speciesID, shiny: shiny,
                              form: form, back: back)
    }

    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        await Self.loadStill(source: source, graphics: graphics, speciesID: speciesID, shiny: shiny, form: form, back: back)
    }

    func egg() async -> PlazaImage? {
        if let kept = memory.cachedEgg { return kept }
        return await Self.loadEgg(source: source, graphics: graphics, memory: memory)
    }

    // --- fix/windows-pet-still: what the GIF loader found, in Windows' log (begin) ---
    /// Windows sets it at launch (`AppLog.write`): one line per sprite and answer, what each variant gave (the file, its bytes,
    /// the frames decoded). The real path had never run in CI (every check used a fixture source). Nil on the Mac and in tests.
    nonisolated(unsafe) static var report: (@Sendable (String) -> Void)?
    nonisolated private static let reported = PlazaReportedKeys()
    // --- (end) ---

    @concurrent private static func loadFrames(source: any PlazaSpriteSource, decode: PlazaGIFFrameDecoder,
                                               memory: PlazaSpriteMemory, speciesID: Int, shiny: Bool,
                                               form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        var notes: [String] = []
        func said(_ outcome: String) {
            guard let report else { return }
            let line = "sprites: GIF #\(speciesID) shiny=\(shiny) form=\(form.map { "\($0)" } ?? "none") back=\(back): "
                + notes.joined(separator: ", ") + " -> " + outcome
            if reported.first(line) { report(line) }
        }
        for variant in shiny ? [true, false] : [false] {
            if !back, Task.isCancelled { said("cancelled"); return [] }
            let name = SpriteStore.cacheKey(speciesID: speciesID, animated: true, shiny: variant, form: form, back: back)
            let key = source.directory.appendingPathComponent(name).path
            if let kept = memory.frames(for: key) { return kept }
            guard let data = await source.data(speciesID: speciesID, animated: true, shiny: variant, form: form, back: back)
            else {
                notes.append("\(name).gif: no data")
                continue
            }
            let frames = decode(data)
            notes.append("\(name).gif: \(data.count) bytes, \(frames.count) frames")
            if !frames.isEmpty {
                memory.keep(frames, for: key)
                said("\(frames.count) frames")
                return frames
            }
        }
        said("no frames (the still shows)")
        return []
    }

    @concurrent private static func loadStill(source: any PlazaSpriteSource, graphics: any PlazaGraphics, speciesID: Int,
                                              shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        for variant in shiny ? [true, false] : [false] {
            guard let data = await source.data(speciesID: speciesID, animated: false, shiny: variant, form: form, back: back),
                  let image = graphics.decodeImage(data) else { continue }
            return image
        }
        return nil
    }

    @concurrent private static func loadEgg(source: any PlazaSpriteSource, graphics: any PlazaGraphics,
                                            memory: PlazaSpriteMemory) async -> PlazaImage? {
        guard let data = await source.eggData(), let image = graphics.decodeImage(data) else { return nil }
        let cropped = PlazaEggCrop.square(image)
        memory.keepEgg(cropped)
        return cropped
    }
}
