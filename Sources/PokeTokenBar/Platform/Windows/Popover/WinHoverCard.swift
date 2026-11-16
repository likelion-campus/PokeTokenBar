#if os(Windows)
import Foundation
import WinSDK

/// The trend chart's hover card (stage 7 Task 12; the Mac's `tooltipCard`, which floats above the bars without the tooltip
/// delay): a small layered pop-up window painted from a part's drawing (`PlazaPanelDrawing`, premultiplied, so the card's soft
/// shadow and rounded corners blend with what is behind). It never takes the activation or the mouse (`WS_EX_NOACTIVATE`,
/// `WS_EX_TRANSPARENT`), is owned by the popover, and exists only while a day is selected: no timer, nothing while the
/// pointer is elsewhere. Showing is `SetWindowPos(SWP_SHOWWINDOW | SWP_NOACTIVATE)`, never an activation.
@MainActor final class WinHoverCard {
    static let className = "PokeTokenBarHoverCard"
    private var window: WinSinkWindow?
    private let owner: HWND
    private(set) var shows = 0
    private(set) var isShown = false
    private(set) var lastRect = RECT()
    /// The pixel at (x, y) of the last picture (the selftest checks the card is not blank), B, G, R, A premultiplied.
    private(set) var lastPixels: [UInt8] = []
    private(set) var lastSize = SIZE(cx: 0, cy: 0)

    init(owner: HWND) { self.owner = owner }

    var hwnd: HWND? { window?.hwnd }

    /// Shows `drawing` (`size` DIP at `scale`) with its top-left corner at `screen` (device pixels), moved inside the work
    /// area of the monitor it is on.
    func show(_ drawing: PlazaPanelDrawing, size: CGSize, scale: CGFloat, at screen: POINT) {
        let w = Int(PopoverComposite.pixelRect(CGRect(origin: .zero, size: size), scale: scale).width)
        let h = Int(PopoverComposite.pixelRect(CGRect(origin: .zero, size: size), scale: scale).height)
        guard w > 0, h > 0 else { hide(); return }
        if window == nil {
            let style: DWORD = 0x8000_0000  // WS_POPUP
            let ex: DWORD = 0x0008_0000 | 0x0000_0080 | 0x0800_0000 | 0x0000_0020 | 0x0000_0008  // LAYERED | TOOLWINDOW | NOACTIVATE | TRANSPARENT | TOPMOST
            window = try? WinSinkWindow(className: Self.className, title: "", style: style, exStyle: ex, x: 0, y: 0, width: 1, height: 1, parent: owner)
            if window == nil { AppLog.write("popover hover card: no window (\(GetLastError()))"); return }
        }
        guard let hwnd = window?.hwnd else { return }
        let bytes = PopoverComposite.compose(drawing.layers, width: w, height: h, scale: scale)
        lastPixels = bytes
        lastSize = SIZE(cx: Int32(w), cy: Int32(h))
        var origin = screen
        if let monitor = MonitorFromPoint(origin, DWORD(MONITOR_DEFAULTTONEAREST)) {
            var info = MONITORINFO()
            info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            if GetMonitorInfoW(monitor, &info) {
                origin.x = max(info.rcWork.left, min(origin.x, info.rcWork.right - Int32(w)))
                origin.y = max(info.rcWork.top, min(origin.y, info.rcWork.bottom - Int32(h)))
            }
        }
        guard paint(hwnd, bytes, w, h, at: &origin) else { return }
        lastRect = RECT(left: origin.x, top: origin.y, right: origin.x + Int32(w), bottom: origin.y + Int32(h))
        _ = SetWindowPos(hwnd, HWND(bitPattern: -1) /* HWND_TOPMOST */, origin.x, origin.y, Int32(w), Int32(h), UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW))
        shows += 1
        isShown = true
    }

    func hide() {
        guard isShown, let hwnd = window?.hwnd else { return }
        _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_HIDEWINDOW))
        isShown = false
    }

    func destroy() {
        window?.destroy()
        window = nil
        isShown = false
    }

    /// The picture into the layered window (`UpdateLayeredWindow`, per-pixel alpha); the DIB is made and freed here, the
    /// system keeps its own copy.
    private func paint(_ hwnd: HWND, _ bytes: [UInt8], _ w: Int, _ h: Int, at origin: inout POINT) -> Bool {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(w)
        info.bmiHeader.biHeight = -Int32(h)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0
        guard let screenDC = GetDC(nil), let memDC = CreateCompatibleDC(screenDC) else { return false }
        defer { _ = ReleaseDC(nil, screenDC); _ = DeleteDC(memDC) }
        var raw: UnsafeMutableRawPointer?
        guard let bitmap = CreateDIBSection(memDC, &info, 0, &raw, nil, 0), let bits = raw else {
            AppLog.write("popover hover card: CreateDIBSection failed (\(GetLastError()))")
            return false
        }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        let old = SelectObject(memDC, UnsafeMutableRawPointer(bitmap))
        defer { _ = SelectObject(memDC, old) }
        bytes.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, w * h * 4)) }
        var size = SIZE(cx: Int32(w), cy: Int32(h))
        var source = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION(BlendOp: 0 /* AC_SRC_OVER */, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 /* AC_SRC_ALPHA */)
        let ok = UpdateLayeredWindow(hwnd, screenDC, &origin, &size, memDC, &source, 0, &blend, 2 /* ULW_ALPHA */)
        if !ok { AppLog.write("popover hover card: UpdateLayeredWindow failed (\(GetLastError()))") }
        return ok
    }
}
#endif
