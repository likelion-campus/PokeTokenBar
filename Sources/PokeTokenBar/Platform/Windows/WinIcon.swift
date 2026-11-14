#if os(Windows)
import CWinShim
import Foundation
import WinSDK

/// An `HICON` made from a PNG (WIC decode in CWinShim). Owns the handle and destroys it.
final class WinIcon {
    let handle: HICON

    init?(png: Data, size: Int) {
        guard size > 0, let decoded = Self.decode(png: png) else { return nil }
        let made = decoded.pixels.withUnsafeBufferPointer {
            ptb_icon_from_bgra($0.baseAddress, UInt32(decoded.width), UInt32(decoded.height), UInt32(size))
        }
        guard let made, let icon = HICON(bitPattern: Int(bitPattern: made)) else { return nil }
        handle = icon
    }

    deinit { _ = DestroyIcon(handle) }

    /// Straight-alpha BGRA, top-down.
    static func decode(png: Data) -> (width: Int, height: Int, pixels: [UInt8])? {
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        let code = png.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return ptb_png_to_bgra(base, raw.count, &w, &h, &out)
        }
        guard code == 0, let out else { return nil }
        defer { ptb_free(out) }
        return (Int(w), Int(h), Array(UnsafeBufferPointer(start: out, count: Int(w) * Int(h) * 4)))
    }

    /// 4 x 4 RGBA: red (255,0,0,255) top-left, green (0,255,0,128) top-right, blue (0,0,255,255) bottom-left,
    /// yellow (255,255,0,64) bottom-right, everything else transparent. Tests and the selftest.
    static let fixturePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAGklEQVR4nGP4z8AARFDwn6GBgRjw/z8SywEA9KkHup1HiTAAAAAASUVORK5CYII=")!
}
#endif
