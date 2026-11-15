#if os(Windows)
import CPlazaD2D
import Foundation

/// Image codecs for the plaza on Windows: PNG and the other still formats through WIC (`CPlazaD2D`), GIF through the
/// shared `PlazaGIFDecoder` (WIC returns a GIF's sub-frames uncomposited, so it is only used as a cross-check of delays).
///
/// Alpha and colour, stated once:
/// - WIC hands back STRAIGHT 8-bit RGBA with no colour management and no gamma (the stored values as they are).
/// - Every `PlazaBitmap` the plaza uses is PREMULTIPLIED, so decode premultiplies with the shared `PlazaPremultiply` (CoreGraphics'
///   rounding, `(c * a + 127) / 255`, measured on the Mac over all 65,536 (c, a) pairs), which makes `pixels` byte-equal to the Mac's.
/// - Encode un-premultiplies the way ImageIO does when it writes a PNG (`PlazaPremultiply.straight`), alpha 0 gives 0, 0, 0, 0.
///   A bitmap that is `.noneSkipLast` is opaque: its fourth byte is padding, written as 255.
enum WinPlazaCodecs {
    struct Failure: Error, CustomStringConvertible {
        let hresult: Int32
        let text: String
        var description: String { text }
    }

    /// The text `CPlazaD2D` recorded for the last failure on this thread.
    static func lastError() -> String {
        guard let c = ptb_plaza_last_error() else { return "" }
        return String(cString: c)
    }

    // MARK: WIC

    /// Straight RGBA, row 0 at the top.
    static func decodeStraight(_ data: Data) -> Result<(width: Int, height: Int, rgba: [UInt8]), Failure> {
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        let code = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Int32(bitPattern: 0x80070057) }  // E_INVALIDARG
            return ptb_wic_decode_straight_rgba(base, raw.count, &w, &h, &out)
        }
        guard code >= 0, let out else { return .failure(Failure(hresult: code, text: lastError())) }
        defer { ptb_plaza_free(out) }
        return .success((Int(w), Int(h), Array(UnsafeBufferPointer(start: out, count: Int(w) * Int(h) * 4))))
    }

    static func encodePNG(straight rgba: [UInt8], width: Int, height: Int) -> Result<Data, Failure> {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            return .failure(Failure(hresult: Int32(bitPattern: 0x80070057), text: "encode: \(rgba.count) bytes for \(width)x\(height)"))
        }
        var png: UnsafeMutablePointer<UInt8>?
        var length = 0
        let code = rgba.withUnsafeBufferPointer { ptb_wic_encode_png_straight_rgba($0.baseAddress, UInt32(width), UInt32(height), &png, &length) }
        guard code >= 0, let png else { return .failure(Failure(hresult: code, text: lastError())) }
        defer { ptb_plaza_free(png) }
        return .success(Data(bytes: png, count: length))
    }

    /// WIC's own count and graphic-control delays (1/100 s, nil = none) for a GIF: the cross-check for `PlazaGIFDecoder`.
    static func wicGIFDelays(_ data: Data) -> (count: Int, delaysCs: [Int?])? {
        var count: UInt32 = 0
        var delays = [Int32](repeating: -1, count: 1024)
        let code = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return Int32(bitPattern: 0x80070057) }
            return delays.withUnsafeMutableBufferPointer { ptb_wic_gif_delays(base, raw.count, &count, $0.baseAddress, UInt32($0.count)) }
        }
        guard code >= 0 else { return nil }
        let n = min(Int(count), delays.count)
        return (Int(count), delays.prefix(n).map { $0 < 0 ? nil : Int($0) })
    }

    // MARK: PlazaImage

    private static func isGIF(_ data: Data) -> Bool { data.count >= 6 && data.prefix(4).elementsEqual([0x47, 0x49, 0x46, 0x38]) }

    /// The first image: a GIF's first composited frame (shared decoder), anything else through WIC.
    static func decodeImage(_ data: Data) -> Result<PlazaImage, Failure> {
        if isGIF(data) {
            guard let first = PlazaGIFDecoder.frames(from: data).first else {
                return .failure(Failure(hresult: Int32(bitPattern: 0x88982F60), text: "GIF: no decodable frame"))  // WINCODEC_ERR_BADIMAGE
            }
            return .success(PlazaImage(bitmap: first))
        }
        switch decodeStraight(data) {
        case .failure(let f): return .failure(f)
        case .success(let d):
            return .success(PlazaImage(bitmap: PlazaPremultiply.bitmap(straight: d.rgba, width: d.width, height: d.height)))
        }
    }

    /// Every frame of a GIF (shared decoder); a still image is its one frame.
    static func decodeFrames(_ data: Data) -> Result<[PlazaImage], Failure> {
        guard isGIF(data) else { return decodeImage(data).map { [$0] } }
        let frames = PlazaGIFDecoder.frames(from: data)
        guard !frames.isEmpty else { return .failure(Failure(hresult: Int32(bitPattern: 0x88982F60), text: "GIF: no decodable frame")) }
        return .success(frames.map { PlazaImage(bitmap: $0) })
    }

    static func encodePNG(_ image: PlazaImage) -> Result<Data, Failure> {
        let bitmap = image.pixels
        return encodePNG(straight: PlazaPremultiply.straight(bitmap), width: bitmap.width, height: bitmap.height)
    }
}
#endif
