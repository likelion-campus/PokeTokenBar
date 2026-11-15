#if os(Windows)
import CPlazaD2D
import Foundation

/// The photo clipboard on Windows (`ImageClipboarding`), and text. Formats and alpha, stated once:
/// - The photo goes on as TWO formats in one clipboard write: the registered "PNG" format (the encoded bytes as they are, straight
///   alpha as PNG stores it; browsers, Office, Slack and chat apps read it) and `CF_DIBV5` (32-bit BI_BITFIELDS BGRA, bottom-up,
///   STRAIGHT alpha, sRGB; Paint and older apps read it, and Windows derives `CF_DIB`/`CF_BITMAP` from it). The DIB pixels come from
///   decoding the very PNG that goes on the clipboard (WIC returns straight RGBA), so the two formats cannot disagree.
///   The plaza photo is opaque (the map fills it), so premultiplied-or-straight does not change a pixel of it.
/// - Text goes on as `CF_UNICODETEXT`.
/// - Busy (another app has the clipboard open): retries every 10 ms for `timeoutMs` (default 300 ms: the main thread waits at most
///   that long), then returns false with one log line. Failure empties the clipboard rather than leaving half a photo.
/// - Nothing is kept between calls: the owner window lives for the call, no timer, no delayed rendering (the system owns the data).
/// The app never reads the clipboard; `read*` below is for tests and the selftest.
struct WinImageClipboard: ImageClipboarding {
    let timeoutMs: UInt32
    private let log: @Sendable (String) -> Void

    init(timeoutMs: UInt32 = 300, log: @escaping @Sendable (String) -> Void = { AppLog.write($0) }) {
        self.timeoutMs = timeoutMs
        self.log = log
    }

    func writePNG(_ data: Data) -> Bool {
        guard case .success(let image) = WinPlazaCodecs.decodeStraight(data) else {
            log("Plaza clipboard: the photo PNG could not be decoded for the DIB (\(WinPlazaCodecs.lastError())); nothing copied")
            return false
        }
        let code = data.withUnsafeBytes { png -> Int32 in
            image.rgba.withUnsafeBufferPointer { px in
                ptb_clipboard_set_image(png.bindMemory(to: UInt8.self).baseAddress, png.count, px.baseAddress,
                                        UInt32(image.width), UInt32(image.height), timeoutMs)
            }
        }
        guard code >= 0 else {
            log("Plaza clipboard: the photo was not copied (\(WinPlazaCodecs.lastError()))")
            return false
        }
        return true
    }

    /// `CF_UNICODETEXT`, replacing the clipboard. False (with one log line) when it could not be written.
    func writeText(_ text: String) -> Bool {
        let units = Array(text.utf16) + [0]   // the terminator also keeps an empty string a non-empty buffer
        let code = units.withUnsafeBufferPointer { ptb_clipboard_set_text($0.baseAddress, units.count - 1, timeoutMs) }
        guard code >= 0 else {
            log("Plaza clipboard: the text was not copied (\(WinPlazaCodecs.lastError()))")
            return false
        }
        return true
    }

    // MARK: Reading back (tests and the selftest only)

    static let cfUnicodeText: UInt32 = 13
    static let cfDIBV5: UInt32 = 17
    static var pngFormat: UInt32 { ptb_clipboard_png_format() }

    static func read(format: UInt32, timeoutMs: UInt32 = 1000) -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ptb_clipboard_read(format, &bytes, &length, timeoutMs) >= 0, let bytes else { return nil }
        defer { ptb_plaza_free(bytes) }
        return Data(bytes: bytes, count: length)
    }

    static func readText() -> String? {
        guard let data = read(format: cfUnicodeText), data.count >= 2 else { return nil }
        let units = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
    }

    /// The `CF_DIBV5` block as straight RGBA, row 0 at the top (the header is checked: 124 bytes, 32 bpp, bit fields, bottom-up).
    static func readDIBV5() -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let d = read(format: cfDIBV5), d.count > 124 else { return nil }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1)) } }
        let w = Int(Int32(bitPattern: u32(4))), h = Int(Int32(bitPattern: u32(8)))
        guard u32(0) == 124, h > 0, w > 0, d[d.startIndex + 14] == 32, u32(16) == 3, d.count >= 124 + w * h * 4,
              u32(40) == 0x00FF0000, u32(44) == 0x0000FF00, u32(48) == 0x000000FF, u32(52) == 0xFF000000 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = d.startIndex + 124 + (h - 1 - y) * w * 4
            for x in 0..<w {
                out[(y * w + x) * 4] = d[src + x * 4 + 2]
                out[(y * w + x) * 4 + 1] = d[src + x * 4 + 1]
                out[(y * w + x) * 4 + 2] = d[src + x * 4]
                out[(y * w + x) * 4 + 3] = d[src + x * 4 + 3]
            }
        }
        return (w, h, out)
    }

    /// Another thread holds the clipboard open for `milliseconds` (tests: the busy case).
    static func holdOpen(milliseconds: UInt32) -> Bool { ptb_clipboard_hold(milliseconds) >= 0 }
}
#endif
