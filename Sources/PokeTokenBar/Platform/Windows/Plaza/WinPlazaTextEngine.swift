#if os(Windows)
import CPlazaD2D
import Foundation

/// The DirectWrite engine's fonts (stage 6, Task 9): the bundled Galmuri and Pretendard files as a private collection
/// (nothing is installed), made once, on the first text call (the first plaza art or panel), never at launch.
/// A missing file is logged once and its text falls back to Malgun Gothic; DirectWrite itself missing makes `handle` nil
/// (logged once) and the engine measures with the stub's monospace and draws nothing.
final class WinTextFonts: @unchecked Sendable {
    static let files: [(name: String, ext: String)] = [
        ("Galmuri11", "ttf"), ("Galmuri14", "ttf"), ("Pretendard-Regular", "otf"), ("Pretendard-SemiBold", "otf"), ("Pretendard-Bold", "otf"),
    ]

    static let shared = WinTextFonts(directories: WinPlazaAssets.directories, measuringMode: 0, log: { AppLog.write($0) })

    let handle: OpaquePointer?
    /// File names that were not found, and found files DirectWrite refused.
    let missing: [String], refused: [String]
    /// What making the collection cost (ms), for the report.
    let creationMilliseconds: Double
    private let lock = NSLock()
    private var metricsCache: [PlazaFont: PlazaFontMetrics] = [:]

    /// `measuringMode`: 0 natural (the plaza's), 1 GDI classic, 2 GDI natural (tests compare).
    init(directories: [URL], measuringMode: Int32, log: (String) -> Void) {
        let started = Date()
        var made: OpaquePointer?
        var missing: [String] = [], refused: [String] = []
        if ptb_text_engine_create(measuringMode, &made) < 0 || made == nil {
            log("plaza text unavailable (DirectWrite): \(WinPlazaCodecs.lastError()); text is measured as monospace and not drawn")
            made = nil
        } else {
            for file in Self.files {
                guard let url = WinPlazaAssets.resolve(file.name, ext: file.ext, in: directories) else {
                    missing.append("\(file.name).\(file.ext)")
                    continue
                }
                let code = WinPath.native(url).withCString(encodedAs: UTF16.self) { ptb_text_engine_add_font(made, $0) }
                if code < 0 { refused.append("\(file.name).\(file.ext) (\(WinPlazaCodecs.lastError()))") }
            }
            if ptb_text_engine_finish(made) < 0 {
                log("plaza text: the font collection could not be made: \(WinPlazaCodecs.lastError())")
            }
            if !missing.isEmpty || !refused.isEmpty {
                log("plaza text: bundled fonts missing \(missing) refused \(refused) in \(directories.map { WinPath.native($0) }); "
                    + "their text falls back to Malgun Gothic")
            }
        }
        handle = made
        self.missing = missing
        self.refused = refused
        creationMilliseconds = Date().timeIntervalSince(started) * 1000
    }

    deinit { if let handle { ptb_text_engine_release(handle) } }

    /// The locale text formats are made with from now on (the app language: the system fallback picks Han and kana glyph forms
    /// by it, so Japanese kanji are not drawn in Korean forms). Default "ko-kr".
    func setLocale(_ name: String) {
        guard let handle else { return }
        _ = name.withCString(encodedAs: UTF16.self) { ptb_text_engine_set_locale(handle, $0) }
    }

    /// BCP 47 locale of an app language for DirectWrite.
    static func locale(for language: AppLanguage) -> String {
        switch language {
        case .ko: "ko-kr"
        case .ja: "ja-jp"
        case .es: "es-es"
        case .fr: "fr-fr"
        case .pt: "pt-br"
        case .de: "de-de"
        case .ru: "ru-ru"
        case .en: "en-us"
        }
    }

    /// The engine's number, weight and size for a plaza font: Galmuri11 / Galmuri14 for `.plaza`, Pretendard for `.system`,
    /// Segoe UI Emoji for `.emoji` (spec §5: the Mac's system font and Apple Color Emoji cannot ship on Windows).
    static func spec(_ font: PlazaFont) -> (font: Int32, weight: Int32, size: Double) {
        switch font {
        case .plaza(let size): (size == .small ? 0 : 1, 400, Double(size.points))
        case .system(let size, let weight): (2, weight == .regular ? 400 : (weight == .semibold ? 600 : 700), Double(size))
        case .emoji(let size): (3, 400, Double(size))
        case .mono(let size, let weight): (5, weight == .regular ? 400 : (weight == .semibold ? 600 : 700), Double(size))
        }
    }

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics? {
        guard let handle else { return nil }
        lock.lock()
        if let known = metricsCache[font] { lock.unlock(); return known }
        lock.unlock()
        let s = Self.spec(font)
        var info = PTBFontInfo()
        guard ptb_text_font_info(handle, s.font, s.weight, s.size, &info, nil, 0, nil, 0) >= 0 else { return nil }
        let m = PlazaFontMetrics(ascender: CGFloat(info.ascent), descender: -CGFloat(info.descent), leading: CGFloat(info.leading))
        lock.lock()
        metricsCache[font] = m
        lock.unlock()
        return m
    }

    /// One font's names and metrics (tests and the report).
    struct FontReport {
        var family: String, face: String
        var info: PTBFontInfo
    }

    func report(_ font: PlazaFont) -> FontReport? {
        guard let handle else { return nil }
        let s = Self.spec(font)
        var info = PTBFontInfo()
        var family = [UInt16](repeating: 0, count: 128), face = [UInt16](repeating: 0, count: 128)
        let code = family.withUnsafeMutableBufferPointer { f in
            face.withUnsafeMutableBufferPointer { g in ptb_text_font_info(handle, s.font, s.weight, s.size, &info, f.baseAddress, 128, g.baseAddress, 128) }
        }
        guard code >= 0 else { return nil }
        return FontReport(family: WinTextHandle.string(family), face: WinTextHandle.string(face), info: info)
    }

    /// Whether the private (`system` false) or the system collection has a family named `name`.
    func hasFamily(_ name: String, system: Bool) -> Bool {
        guard let handle else { return false }
        var exists: Int32 = 0
        _ = name.withCString(encodedAs: UTF16.self) { ptb_text_has_family(handle, system ? 1 : 0, $0, &exists) }
        return exists != 0
    }
}

/// One DirectWrite line (C handle), released with the last reference.
final class WinTextHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    let info: PTBTextLineInfo

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
        var i = PTBTextLineInfo()
        _ = ptb_text_line_info(pointer, &i)
        info = i
    }

    deinit { ptb_text_line_release(pointer) }

    static func string(_ units: [UInt16]) -> String { String(decoding: units.prefix { $0 != 0 }, as: UTF16.self) }

    func clusters() -> [PTBTextCluster] {
        var out = [PTBTextCluster](repeating: PTBTextCluster(), count: Int(info.clusters))
        let n = out.withUnsafeMutableBufferPointer { ptb_text_line_clusters(pointer, $0.baseAddress, UInt32($0.count)) }
        return Array(out.prefix(max(0, Int(n))))
    }

    /// Ascent, descent, leading per UTF-16 unit.
    func unitMetrics(_ units: Int) -> [Double] {
        var out = [Double](repeating: 0, count: 3 * units)
        let code = out.withUnsafeMutableBufferPointer { ptb_text_line_unit_metrics(pointer, $0.baseAddress, UInt32(units)) }
        return code >= 0 ? out : [Double](repeating: 0, count: 3 * units)
    }

    /// Glyph ink relative to the origin, y up; `.zero` when nothing has ink.
    func inkBounds() -> CGRect {
        var b = [Double](repeating: 0, count: 4)
        _ = b.withUnsafeMutableBufferPointer { ptb_text_line_ink_bounds(pointer, $0.baseAddress) }
        return b[2] > 0 || b[3] > 0 ? CGRect(x: b[0], y: b[1], width: b[2], height: b[3]) : .zero
    }

    /// The family that drew each glyph piece, and whether the piece is a colour layer (tests and the report).
    func pieceFamilies() -> [(family: String, color: Bool)] {
        (0..<Int(info.pieces)).map { i in
            var name = [UInt16](repeating: 0, count: 128)
            var color: Int32 = 0
            _ = name.withUnsafeMutableBufferPointer { ptb_text_line_piece_family(pointer, UInt32(i), $0.baseAddress, 128, &color) }
            return (Self.string(name), color != 0)
        }
    }
}

/// A piece of text in one font, in its own colour or (nil) the canvas's.
struct WinTextSpec: Sendable {
    var text: String
    var font: PlazaFont
    var color: PlazaColor?
}

/// The engine's line (`PlazaTextLine.native`): one or more DirectWrite lines side by side, each `dx` from the origin (a
/// truncated line is its kept start and the ellipsis's line). `specs` is the whole line's text in its fonts and colours.
final class WinTextLine: @unchecked Sendable {
    struct Segment {
        let handle: WinTextHandle
        let dx: CGFloat
        let text: String
        let utf16Offset: Int
    }

    let segments: [Segment]
    let specs: [WinTextSpec]
    let rightToLeft: Bool
    private let lock = NSLock()
    private var cached: WinMeasured?

    init(segments: [Segment], specs: [WinTextSpec], rightToLeft: Bool) {
        self.segments = segments
        self.specs = specs
        self.rightToLeft = rightToLeft
    }

    var text: String { specs.map(\.text).joined() }

    /// The line's clusters as `PlazaLineBreaker` takes them, with each cluster's font metrics.
    var measured: WinMeasured {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var clusters: [PlazaBreakCluster] = [], metrics: [PlazaFontMetrics] = []
        for s in segments {
            let m = WinMeasured.make(s.text, s.handle)
            clusters += m.clusters.map { var c = $0; c.utf16 = (c.utf16.lowerBound + s.utf16Offset)..<(c.utf16.upperBound + s.utf16Offset); return c }
            metrics += m.metrics
        }
        let made = WinMeasured(clusters: clusters, metrics: metrics)
        cached = made
        return made
    }

    func inkBounds() -> CGRect {
        var out = CGRect.null
        for s in segments {
            let b = s.handle.inkBounds()
            if b != .zero { out = out.union(b.offsetBy(dx: s.dx, dy: 0)) }
        }
        return out.isNull ? .zero : out
    }
}

/// Grapheme clusters measured by DirectWrite, made the way the Mac's builder makes them (`PlazaParityGoldensMacTests
/// .clusters(of:font:)`): Swift `Character`s; each DirectWrite cluster's advance goes to the character its first unit is in
/// (a ligature's whole advance to its first character, as CoreText gives a glyph's advance to its string index); a line may
/// end after a character when the DirectWrite cluster that ends with it may wrap after (UAX #14 as DirectWrite reads it),
/// corrected by the two UAX #14 rules DirectWrite's analyser does not apply and CoreText (ICU) does, measured on the corpus
/// (`breakCorrected`); white space, newline, Hangul and word-character from the scalars, as on the Mac.
struct WinMeasured: Sendable {
    let clusters: [PlazaBreakCluster]
    let metrics: [PlazaFontMetrics]

    static func isHangul(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xA960...0xA97F).contains(v)
            || (0xD7B0...0xD7FF).contains(v)
    }

    static func isWordCharacter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark,
             .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// UAX #14 classes PR (prefix: currency, `+`, `\`, `±`, `№` …) and PO (postfix: `%`, `‰`, `°`, `¢`, primes …).
    static let prefixOrPostfix: Set<UInt32> = Set<UInt32>([
        0x24, 0x2B, 0x5C, 0xA3, 0xA4, 0xA5, 0xB1, 0x58F, 0x7FE, 0x7FF, 0x9FB, 0xAF1, 0xBF9, 0xE3F, 0x17DB, 0x2116, 0x2212, 0x2213,
        0xFE69, 0xFF04, 0xFFE1, 0xFFE5, 0xFFE6,
        0x25, 0xA2, 0xB0, 0x60B, 0x66A, 0x9F2, 0x9F3, 0x9F9, 0xD79, 0x2103, 0x2109, 0xA838, 0xFDFC, 0xFE6A, 0xFF05, 0xFFE0,
    ]).union(UInt32(0x20A0)...UInt32(0x20CF)).union(UInt32(0x2030)...UInt32(0x2037))

    /// A letter of UAX #14 class AL or HL: alphabetic, not Hangul, not ideographic, not kana, not a South-East Asian script
    /// (class SA, broken by dictionary).
    static func isAlphabeticLetter(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        guard s.properties.isAlphabetic, !s.properties.isIdeographic, !isHangul(s) else { return false }
        if (0x0E00...0x0EFF).contains(v) || (0x1000...0x109F).contains(v) || (0x1780...0x17FF).contains(v) || (0x3040...0x31FF).contains(v)
            || (0xFF66...0xFF9F).contains(v) { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isRegionalIndicator(_ s: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(s.value) }

    /// DirectWrite's opportunity after `current`, corrected where its analyser predates UAX #14 (CoreText follows it):
    /// - LB24 `(AL | HL) × (PR | PO)`: no break between a letter and a prefix or postfix after it (`Users\name`, `a+b`);
    /// - LB30a: a break between two flags (regional-indicator pairs).
    static func breakCorrected(_ directWrite: Bool, current: Character, next: Character?) -> Bool {
        guard let next, let last = current.unicodeScalars.last, let first = next.unicodeScalars.first else { return directWrite }
        if directWrite, isAlphabeticLetter(last), prefixOrPostfix.contains(first.value) { return false }
        if !directWrite, current.unicodeScalars.count == 2, current.unicodeScalars.allSatisfy(isRegionalIndicator), isRegionalIndicator(first) {
            return true
        }
        return directWrite
    }

    static func make(_ text: String, _ handle: WinTextHandle) -> WinMeasured {
        let units = text.utf16.count
        let dw = handle.clusters()
        var advanceAt = [Double](repeating: 0, count: units + 1)     // a DirectWrite cluster's width at its first unit
        var breakAfter = [Bool](repeating: false, count: units + 1)  // may wrap after the unit before this end
        var u = 0
        for c in dw {
            if u < advanceAt.count { advanceAt[u] += Double(c.width) }
            u += Int(c.length)
            if u <= units { breakAfter[u] = c.flags & 4 != 0 }
        }
        let unit = handle.unitMetrics(units)
        var clusters: [PlazaBreakCluster] = [], metrics: [PlazaFontMetrics] = []
        clusters.reserveCapacity(text.count)
        u = 0
        let characters = Array(text)
        for (index, ch) in characters.enumerated() {
            let end = u + ch.utf16.count
            var width = 0.0
            var ascent = 0.0, descent = 0.0, leading = 0.0
            for k in u..<min(end, units) {
                width += advanceAt[k]
                ascent = max(ascent, unit[3 * k]); descent = max(descent, unit[3 * k + 1]); leading = max(leading, unit[3 * k + 2])
            }
            let scalars = ch.unicodeScalars
            clusters.append(PlazaBreakCluster(
                utf16: u..<end, width: CGFloat(width),
                isWhitespace: scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) && ![0xA0, 0x2007, 0x202F].contains($0.value) },
                isNewline: scalars.contains { "\n\r\u{2028}\u{2029}\u{85}".unicodeScalars.contains($0) },
                canBreakAfter: breakCorrected(end <= units && breakAfter[end], current: ch, next: index + 1 < characters.count ? characters[index + 1] : nil),
                isHangul: scalars.first.map(isHangul) ?? false,
                isWordCharacter: scalars.first.map(isWordCharacter) ?? false))
            metrics.append(PlazaFontMetrics(ascender: CGFloat(ascent), descender: -CGFloat(descent), leading: CGFloat(leading)))
            u = end
        }
        return WinMeasured(clusters: clusters, metrics: metrics)
    }
}

/// The engine's paragraph (`PlazaParagraph.native`): the whole text measured once; the frame's lines per width are made on
/// demand (the last width kept).
final class WinTextParagraph: @unchecked Sendable {
    let text: String
    let font: PlazaFont
    let alignment: PlazaTextAlignment
    let rightToLeft: Bool
    let whole: WinTextLine
    private let engine: WinPlazaTextEngine
    private let lock = NSLock()
    private var laidOut: (width: CGFloat, lines: [(frame: PlazaTextFrame.Line, line: PlazaTextLine)])?

    init(text: String, font: PlazaFont, alignment: PlazaTextAlignment, rightToLeft: Bool, whole: WinTextLine, engine: WinPlazaTextEngine) {
        self.text = text
        self.font = font
        self.alignment = alignment
        self.rightToLeft = rightToLeft
        self.whole = whole
        self.engine = engine
    }

    func frameLines(width: CGFloat) -> [PlazaTextFrame.Line] {
        let m = whole.measured
        return PlazaTextFrame.lines(m.clusters, metrics: m.metrics, width: width)
    }

    /// The frame's lines at `width`, each with the line to draw.
    func drawn(width: CGFloat) -> [(frame: PlazaTextFrame.Line, line: PlazaTextLine)] {
        lock.lock()
        if let laidOut, laidOut.width == width { lock.unlock(); return laidOut.lines }
        lock.unlock()
        let units = Array(text.utf16)
        let lines = frameLines(width: width).map { f -> (frame: PlazaTextFrame.Line, line: PlazaTextLine) in
            let piece = String(decoding: units[f.range], as: UTF16.self)
            return (f, engine.plainLine(piece, font: font, rightToLeft: rightToLeft))
        }
        lock.lock()
        laidOut = (width, lines)
        lock.unlock()
        return lines
    }
}

/// `PlazaTextEngine` on DirectWrite (stage 6, Task 9; plan D10). DirectWrite measures (advances with kerning, fallback fonts,
/// UAX #14 opportunities, bidi) and draws; the rules are the shared ones the Mac's CoreText / TextKit were measured into:
/// `PlazaLineBreaker` (`.swiftUIText` for `wrappedLines`, `.coreTextFrame` for paragraphs), `PlazaTextFrame` (frame layout,
/// suggested size, visible length, truncation). Metrics are hhea scaled as CoreText scales them.
struct WinPlazaTextEngine: PlazaTextEngine {
    private let injected: WinTextFonts?
    private static let stub = PlazaStubTextEngine()

    /// `fonts` nil: the process's fonts, made on first use.
    init(fonts: WinTextFonts? = nil) { injected = fonts }

    var fonts: WinTextFonts { injected ?? .shared }

    private static let logLock = NSLock()
    nonisolated(unsafe) private static var logged = Set<String>()
    private static func logOnce(_ line: String) {
        logLock.lock()
        let first = logged.count < 16 && logged.insert(line).inserted
        logLock.unlock()
        if first { AppLog.write(line) }
    }

    // MARK: making lines

    /// `spec` cut where a character asks for emoji presentation (U+FE0F, or a keycap U+20E3): those are drawn in the emoji
    /// font even when the spec's font has the base character (`©️`, `1️⃣`), as CoreText draws them in Apple Color Emoji.
    static func fontRuns(_ spec: WinTextSpec) -> [(length: Int, font: PlazaFont)] {
        let emoji = PlazaFont.emoji(size: CGFloat(WinTextFonts.spec(spec.font).size))
        var out: [(length: Int, font: PlazaFont)] = []
        for ch in spec.text {
            let font = ch.unicodeScalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 } ? emoji : spec.font
            if let last = out.last, last.font == font { out[out.count - 1].length += ch.utf16.count } else { out.append((ch.utf16.count, font)) }
        }
        return out
    }

    /// A DirectWrite line of `specs`, or nil (logged once) when the engine cannot make one.
    func native(_ specs: [WinTextSpec], rightToLeft: Bool) -> WinTextLine? {
        guard let engine = fonts.handle else { return nil }
        var units: [UInt16] = [], runs: [PTBTextRun] = []
        for s in specs {
            let c = s.color
            var start = units.count
            for piece in Self.fontRuns(s) {
                let f = WinTextFonts.spec(piece.font)
                runs.append(PTBTextRun(start: UInt32(start), length: UInt32(piece.length), font: f.font, weight: f.weight, size: f.size,
                                       ownColor: c == nil ? 0 : 1, r: c?.red ?? 0, g: c?.green ?? 0, b: c?.blue ?? 0, a: c?.alpha ?? 1))
                start += piece.length
            }
            units += Array(s.text.utf16)
        }
        let allSpecs = specs.isEmpty ? [WinTextSpec(text: "", font: .plaza(.body), color: nil)] : specs
        if runs.isEmpty {
            let f = WinTextFonts.spec(.plaza(.body))
            runs = [PTBTextRun(start: 0, length: 0, font: f.font, weight: f.weight, size: f.size, ownColor: 0, r: 0, g: 0, b: 0, a: 1)]
        }
        var made: OpaquePointer?
        let code = units.withUnsafeBufferPointer { u in
            runs.withUnsafeBufferPointer { r in
                ptb_text_line_create(engine, u.baseAddress, UInt32(u.count), r.baseAddress, UInt32(r.count), rightToLeft ? 1 : 0, &made)
            }
        }
        guard code >= 0, let made else {
            Self.logOnce("plaza text: a line could not be made: \(WinPlazaCodecs.lastError())")
            return nil
        }
        let text = allSpecs.map(\.text).joined()
        return WinTextLine(segments: [.init(handle: WinTextHandle(made), dx: 0, text: text, utf16Offset: 0)], specs: allSpecs, rightToLeft: rightToLeft)
    }

    private func wrap(_ native: WinTextLine, runs: [PlazaTextRun]) -> PlazaTextLine {
        var width: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        for s in native.segments {
            width += CGFloat(s.handle.info.width)
            ascent = max(ascent, CGFloat(s.handle.info.ascent))
            descent = max(descent, CGFloat(s.handle.info.descent))
            leading = max(leading, CGFloat(s.handle.info.leading))
        }
        return PlazaTextLine(width: width, ascent: ascent, descent: descent, leading: leading, native: native, runs: runs)
    }

    func plainLine(_ text: String, font: PlazaFont, rightToLeft: Bool) -> PlazaTextLine {
        guard let n = native([WinTextSpec(text: text, font: font, color: nil)], rightToLeft: rightToLeft) else {
            return Self.stub.line(text, font: font)
        }
        return wrap(n, runs: [])
    }

    /// `glyph` in the symbol font (font number 4: Segoe Fluent Icons, else Segoe MDL2 Assets) at `size` points; the HUD's eye icons
    /// (D15). nil when DirectWrite is unavailable. The line has no `runs` and is not meant for measuring text.
    func symbolLine(_ glyph: String, size: Double) -> PlazaTextLine? {
        guard let engine = fonts.handle else { return nil }
        let units = Array(glyph.utf16)
        guard !units.isEmpty else { return nil }
        let runs = [PTBTextRun(start: 0, length: UInt32(units.count), font: 4, weight: 400, size: size, ownColor: 0, r: 0, g: 0, b: 0, a: 1)]
        var made: OpaquePointer?
        let code = units.withUnsafeBufferPointer { u in
            runs.withUnsafeBufferPointer { r in
                ptb_text_line_create(engine, u.baseAddress, UInt32(u.count), r.baseAddress, UInt32(r.count), 0, &made)
            }
        }
        guard code >= 0, let made else { return nil }
        let native = WinTextLine(segments: [.init(handle: WinTextHandle(made), dx: 0, text: glyph, utf16Offset: 0)],
                                 specs: [WinTextSpec(text: glyph, font: .plaza(.body), color: nil)], rightToLeft: false)
        return wrap(native, runs: [])
    }

    private static func specs(_ runs: [PlazaTextRun]) -> [WinTextSpec] { runs.map { WinTextSpec(text: $0.text, font: $0.font, color: $0.color) } }

    /// The parts of `specs` inside `range` (UTF-16 offsets into their joined text), as the Mac's `pieces(of:in:)`.
    static func pieces(_ specs: [WinTextSpec], in range: Range<Int>) -> [WinTextSpec] {
        var out: [WinTextSpec] = []
        var start = 0
        for s in specs {
            let units = Array(s.text.utf16)
            let lo = max(range.lowerBound, start), hi = min(range.upperBound, start + units.count)
            if lo < hi {
                var piece = s
                piece.text = String(decoding: units[(lo - start)..<(hi - start)], as: UTF16.self)
                out.append(piece)
            }
            start += units.count
        }
        return out
    }

    // MARK: PlazaTextEngine

    func metrics(_ font: PlazaFont) -> PlazaFontMetrics {
        fonts.metrics(font) ?? Self.stub.metrics(font)
    }

    func line(_ text: String, font: PlazaFont) -> PlazaTextLine {
        plainLine(text, font: font, rightToLeft: PlazaTextFrame.isRightToLeft(text[...]))
    }

    func line(_ runs: [PlazaTextRun]) -> PlazaTextLine {
        let specs = Self.specs(runs)
        guard let n = native(specs, rightToLeft: PlazaTextFrame.isRightToLeft(specs.map(\.text).joined()[...])) else { return Self.stub.line(runs) }
        return wrap(n, runs: runs)
    }

    /// `PlazaTextFrame.truncation` over the line's clusters; the kept start is made again as its own line and the ellipsis's
    /// line follows it at the kept width (the kept advances are the whole line's, as CoreText keeps the line's glyphs).
    func truncated(_ line: PlazaTextLine, width: CGFloat, ellipsis: PlazaTextLine) -> PlazaTextLine? {
        guard let n = line.native as? WinTextLine, let e = ellipsis.native as? WinTextLine else {
            return Self.stub.truncated(line, width: width, ellipsis: ellipsis)
        }
        let clusters = n.measured.clusters
        guard let kept = PlazaTextFrame.truncation(clusters, width: width, ellipsisWidth: ellipsis.width) else { return nil }
        if kept == clusters.count { return line }
        let keptUnits = kept == 0 ? 0 : clusters[kept - 1].utf16.upperBound
        let keptWidth = clusters.prefix(kept).reduce(CGFloat(0)) { $0 + $1.width }
        var segments: [WinTextLine.Segment] = []
        let start = Self.pieces(n.specs, in: 0..<keptUnits)
        if keptUnits > 0, let prefix = native(start, rightToLeft: n.rightToLeft) { segments += prefix.segments }
        segments += e.segments.map { .init(handle: $0.handle, dx: keptWidth + $0.dx, text: $0.text, utf16Offset: keptUnits + $0.utf16Offset) }
        let joined = WinTextLine(segments: segments, specs: start + e.specs, rightToLeft: n.rightToLeft)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        for s in segments {
            ascent = max(ascent, CGFloat(s.handle.info.ascent))
            descent = max(descent, CGFloat(s.handle.info.descent))
            leading = max(leading, CGFloat(s.handle.info.leading))
        }
        return PlazaTextLine(width: keptWidth + ellipsis.width, ascent: ascent, descent: descent, leading: leading, native: joined)
    }

    func paragraph(_ text: String, font: PlazaFont, alignment: PlazaTextAlignment) -> PlazaParagraph {
        let rtl = PlazaTextFrame.isRightToLeft(text[...])
        guard let whole = native([WinTextSpec(text: text, font: font, color: nil)], rightToLeft: rtl) else {
            return Self.stub.paragraph(text, font: font, alignment: alignment)
        }
        let p = WinTextParagraph(text: text, font: font, alignment: alignment, rightToLeft: rtl, whole: whole, engine: self)
        let length = text.utf16.count
        return PlazaParagraph(
            native: p,
            suggestedSize: { PlazaTextFrame.suggestedSize(p.frameLines(width: $0.width), limit: $0) },
            visibleLength: { PlazaTextFrame.visibleLength(p.frameLines(width: $0.width), height: $0.height, textLength: length) })
    }

    func wrappedLines(_ text: String, font: PlazaFont, width: CGFloat) -> [PlazaTextLine] {
        wrapped([WinTextSpec(text: text, font: font, color: nil)], width: width, keepRuns: false)
    }

    func wrappedLines(_ runs: [PlazaTextRun], width: CGFloat) -> [PlazaTextLine] {
        wrapped(Self.specs(runs), width: width, keepRuns: true)
    }

    /// `.swiftUIText` breaks over the whole text's clusters; each line is made again from its piece of the text in the whole
    /// text's direction, its width the whole text's advances over the line (what a CTTypesetter line of that range measures).
    private func wrapped(_ specs: [WinTextSpec], width: CGFloat, keepRuns: Bool) -> [PlazaTextLine] {
        let text = specs.map(\.text).joined()
        let rtl = PlazaTextFrame.isRightToLeft(text[...])
        guard let whole = native(specs, rightToLeft: rtl) else {
            return keepRuns ? Self.stub.wrappedLines(specs.map { PlazaTextRun(text: $0.text, font: $0.font, color: $0.color ?? .white) }, width: width)
                : Self.stub.wrappedLines(text, font: specs.first?.font ?? .plaza(.body), width: width)
        }
        let m = whole.measured
        let ranges = PlazaLineBreaker.lines(m.clusters, width: width, rule: .swiftUIText)
        return ranges.map { r in
            let pieces = Self.pieces(specs, in: r)
            let lineSpecs = pieces.isEmpty ? [WinTextSpec(text: "", font: specs.first?.font ?? .plaza(.body), color: nil)] : pieces
            let runs = keepRuns ? pieces.map { PlazaTextRun(text: $0.text, font: $0.font, color: $0.color ?? .white) } : []
            guard let n = native(lineSpecs, rightToLeft: rtl) else { return Self.stub.line(pieces.map(\.text).joined(), font: lineSpecs[0].font) }
            var w: CGFloat = 0, ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            var any = false
            for (c, f) in zip(m.clusters, m.metrics) where c.utf16.lowerBound >= r.lowerBound && c.utf16.upperBound <= r.upperBound {
                w += c.width
                ascent = max(ascent, f.ascender); descent = max(descent, -f.descender); leading = max(leading, f.leading)
                any = true
            }
            if !any, let f = zip(m.clusters, m.metrics).first(where: { $0.0.utf16.lowerBound >= r.lowerBound })?.1 {
                ascent = f.ascender; descent = -f.descender; leading = f.leading   // an empty line: the font of what ended it
            }
            return PlazaTextLine(width: w, ascent: ascent, descent: descent, leading: leading, native: n, runs: runs)
        }
    }
}
#endif
