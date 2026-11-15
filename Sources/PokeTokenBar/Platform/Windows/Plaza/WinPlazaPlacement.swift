#if os(Windows)
import CPlazaD2D
import Foundation

/// Where the plaza window opens (D6): the Mac's frame autosave (`setFrameAutosaveName` after `center()`) on Windows.
///
/// - Saved under `plaza.windowPlacement` in the app's settings (`WinSyncingDefaults`, so it reaches the disk within 2 s and
///   on every exit): the normal (not maximized) window's top-left in screen pixels, its content size in DIP, the maximized
///   flag and the monitor's device name. Written when a move or resize ends and when the window closes.
/// - Restored when the saved rect, at the DPI of a monitor, overlaps that monitor's work area: then clamped into it (moved
///   on and, if larger, shrunk to it), the named monitor first. Otherwise (first open, the monitor is gone) the default
///   content size, centred in the primary monitor's work area, as the Mac centres.
/// - The content never gets smaller than `PlazaWindowController.minContentSize`.
@MainActor enum WinPlazaPlacement {
    static let defaultKey = "plaza.windowPlacement"
    /// The Mac's `SKView` frame (`PlazaMacWindow.open`).
    static let defaultContent = CGSize(width: 960, height: 640)

    struct Rect: Equatable, Sendable {
        var left: Int32, top: Int32, right: Int32, bottom: Int32
        var width: Int32 { right - left }
        var height: Int32 { bottom - top }
        func intersectionArea(_ o: Rect) -> Int64 {
            let w = Int64(min(right, o.right)) - Int64(max(left, o.left))
            let h = Int64(min(bottom, o.bottom)) - Int64(max(top, o.top))
            return w > 0 && h > 0 ? w * h : 0
        }
    }

    struct Monitor: Equatable, Sendable {
        var name: String
        var bounds: Rect
        var work: Rect
        var dpi: UInt32
        var isPrimary: Bool
    }

    struct Saved: Equatable, Sendable {
        var left: Int32, top: Int32
        var contentWidth: Double, contentHeight: Double
        var maximized: Bool
        var monitor: String

        /// `1;left;top;width;height;maximized;monitor`: one string, no number bridging to depend on.
        var encoded: String {
            "1;\(left);\(top);\(contentWidth);\(contentHeight);\(maximized ? 1 : 0);\(monitor)"
        }

        init(left: Int32, top: Int32, contentWidth: Double, contentHeight: Double, maximized: Bool, monitor: String) {
            self.left = left
            self.top = top
            self.contentWidth = contentWidth
            self.contentHeight = contentHeight
            self.maximized = maximized
            self.monitor = monitor
        }

        init?(encoded: String) {
            let parts = encoded.split(separator: ";", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 7, parts[0] == "1", let l = Int32(parts[1]), let t = Int32(parts[2]),
                  let w = Double(parts[3]), let h = Double(parts[4]), w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
            self.init(left: l, top: t, contentWidth: w, contentHeight: h, maximized: parts[5] == "1", monitor: parts[6])
        }
    }

    /// The window rect for a `w × h` pixel client at `dpi`, relative to the client's origin (non-client insets).
    typealias Frame = (_ dpi: UInt32, _ width: Int32, _ height: Int32) -> Rect

    struct Placement: Equatable {
        var rect: Rect
        var dpi: UInt32
        var maximized: Bool
        var restored: Bool
    }

    static func read(_ defaults: UserDefaults, key: String = defaultKey) -> Saved? {
        defaults.string(forKey: key).flatMap(Saved.init(encoded:))
    }

    static func save(_ saved: Saved, to defaults: UserDefaults, key: String = defaultKey) {
        defaults.set(saved.encoded, forKey: key)
    }

    static func restore(saved: Saved?, monitors: [Monitor], min: CGSize = PlazaWindowController.minContentSize,
                        frame: Frame) -> Placement {
        func size(_ content: CGSize, dpi: UInt32) -> Rect {
            let scale = Double(dpi) / 96
            let w = Int32((Double(max(content.width, min.width)) * scale).rounded())
            let h = Int32((Double(max(content.height, min.height)) * scale).rounded())
            return frame(dpi, w, h)
        }
        func clamp(_ r: Rect, into work: Rect) -> Rect {
            let w = Swift.min(r.width, work.width), h = Swift.min(r.height, work.height)
            let left = Swift.min(Swift.max(r.left, work.left), work.right - w)
            let top = Swift.min(Swift.max(r.top, work.top), work.bottom - h)
            return Rect(left: left, top: top, right: left + w, bottom: top + h)
        }
        if let saved {
            let content = CGSize(width: saved.contentWidth, height: saved.contentHeight)
            var best: (monitor: Monitor, rect: Rect, area: Int64)?
            for m in monitors {
                let f = size(content, dpi: m.dpi)
                let r = Rect(left: saved.left, top: saved.top, right: saved.left + f.width, bottom: saved.top + f.height)
                let area = r.intersectionArea(m.work)
                guard area > 0 else { continue }
                let named = m.name == saved.monitor
                if let b = best {
                    let bNamed = b.monitor.name == saved.monitor
                    if bNamed && !named { continue }
                    if bNamed == named && area <= b.area { continue }
                }
                best = (m, r, area)
            }
            if let best { return Placement(rect: clamp(best.rect, into: best.monitor.work), dpi: best.monitor.dpi, maximized: saved.maximized, restored: true) }
        }
        guard let primary = monitors.first(where: \.isPrimary) ?? monitors.first else {
            let f = size(defaultContent, dpi: 96)
            return Placement(rect: Rect(left: 100, top: 100, right: 100 + f.width, bottom: 100 + f.height), dpi: 96, maximized: false, restored: false)
        }
        let f = size(defaultContent, dpi: primary.dpi)
        let w = primary.work
        let left = w.left + (w.width - f.width) / 2, top = w.top + (w.height - f.height) / 2
        let r = clamp(Rect(left: left, top: top, right: left + f.width, bottom: top + f.height), into: w)
        return Placement(rect: r, dpi: primary.dpi, maximized: false, restored: false)
    }

    /// The monitors now (`EnumDisplayMonitors`, effective DPI).
    static func monitors() -> [Monitor] {
        var raw = [PTBMonitor](repeating: PTBMonitor(), count: 16)
        let n = Int(raw.withUnsafeMutableBufferPointer { ptb_monitors($0.baseAddress, UInt32($0.count)) })
        return raw.prefix(n).map { m in
            let name = withUnsafeBytes(of: m.name) { bytes -> String in
                let units = bytes.bindMemory(to: UInt16.self)
                return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
            }
            return Monitor(name: name,
                           bounds: Rect(left: m.monitor.0, top: m.monitor.1, right: m.monitor.2, bottom: m.monitor.3),
                           work: Rect(left: m.work.0, top: m.work.1, right: m.work.2, bottom: m.work.3),
                           dpi: m.dpi == 0 ? 96 : m.dpi, isPrimary: m.primary != 0)
        }
    }

    /// The real non-client frame of the plaza window's style (`AdjustWindowRectExForDpi`).
    static func frame(style: UInt32, exStyle: UInt32) -> Frame {
        { dpi, w, h in
            var out: (Int32, Int32, Int32, Int32) = (0, 0, w, h)
            _ = withUnsafeMutableBytes(of: &out) { ptb_window_frame_for_client(style, exStyle, dpi, w, h, $0.baseAddress!.assumingMemoryBound(to: Int32.self)) }
            return Rect(left: out.0, top: out.1, right: out.2, bottom: out.3)
        }
    }
}
#endif
