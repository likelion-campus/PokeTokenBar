#if os(Windows)
import Foundation
import WinSDK

/// A scrolling page (stage 7 D6): a viewport with a vertical scroll bar and, inside it, the content pane the page's
/// controls live in, moved up and down as one window. The content's width never changes with its height: it is the viewport
/// beside the bar's lane (`paneWidth`), as the Mac keeps its scroller lane clear (12 pt of padding). The native bar is there
/// only while the content is taller than the viewport (Windows hides it by itself when the range fits the page): where the
/// content fits, the lane is empty, as the Mac's overlay scroller is not drawn until it scrolls (windows-differences.md). The wheel and a precision touchpad
/// scroll it (`SPI_GETWHEELSCROLLLINES` lines of 16 DIP a notch, fractions kept); a control the keyboard focuses is
/// brought into view; a thumb drag (the scroll bar's own modal loop) runs inside `WinModalPump`, so team links keep their
/// heartbeats. No timer: it moves only on input.
@MainActor final class WinScrollArea {
    static let className = "PokeTokenBarScroll"
    static let lineDIP: CGFloat = 16

    let viewport: WinSinkWindow
    let content: WinPane
    let ctx: WinUIContext
    private(set) var offset: Int32 = 0
    private(set) var contentHeight: Int32 = 0
    /// The content's width in pixels: the viewport's client width with the bar's lane taken, whether the bar is shown or not.
    private(set) var paneWidth: Int32 = 0
    /// The bar's width in pixels (the viewport has no border), measured once with the bar shown.
    private var laneWidth: Int32 = 0
    private var wheel = PopoverWheel()

    struct Stats: Equatable {
        var wheelMessages = 0, thumbDrags = 0, reveals = 0, moves = 0
        /// `WinModalPump.depth` seen while a thumb drag's loop ran (the selftest's evidence that the pump served it).
        var pumpDepthDuringDrag = 0
    }
    private(set) var stats = Stats()
    private static var areas: [Int: WinScrollArea] = [:]

    init(parent: HWND, ctx: WinUIContext, rect: RECT) throws {
        self.ctx = ctx
        let style: DWORD = 0x4000_0000 | 0x1000_0000 | 0x0020_0000 | 0x0200_0000  // WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN
        let made = try WinSinkWindow(className: Self.className, title: "", style: style, exStyle: 0x0001_0000 /* WS_EX_CONTROLPARENT */,
                                     x: rect.left, y: rect.top, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: parent)
        Self.updateBar(made.hwnd, height: 0, page: 1, offset: 0, keepLane: true)  // shows the (disabled) bar, so the client width below is the lane's
        var client = RECT()
        _ = GetClientRect(made.hwnd, &client)
        Self.updateBar(made.hwnd, height: 0, page: 1, offset: 0)  // nothing to scroll yet: the bar goes
        let pane: WinPane
        do {
            pane = try WinPane(parent: made.hwnd, ctx: ctx, rect: RECT(left: 0, top: 0, right: client.right, bottom: client.bottom))
        } catch {
            made.destroy()
            throw error
        }
        if ctx.dark { WinDarkMode.setTheme(made.hwnd, "DarkMode_Explorer") }  // the scroll bar's dark style (Task 16)
        viewport = made
        content = pane
        paneWidth = client.right
        laneWidth = (rect.right - rect.left) - client.right
        Self.areas[Int(bitPattern: content.hwnd)] = self
        viewport.on(0x0115 /* WM_VSCROLL */) { [weak self] wParam, lParam in
            guard lParam == 0, let self else { return nil }  // a scroll bar control's WM_VSCROLL is the router's
            self.vscroll(WinKit.loWord(wParam))
            return 0
        }
        viewport.on(0x020A /* WM_MOUSEWHEEL */) { [weak self] wParam, _ in
            guard let self else { return nil }
            self.stats.wheelMessages += 1
            var lines: UINT = 3
            _ = SystemParametersInfoW(0x0068 /* SPI_GETWHEELSCROLLLINES */, 0, &lines, 0)
            let change = self.wheel.offsetChange(delta: WinKit.signedHiWord(wParam), lines: lines, lineHeight: CGFloat(ctx.px(Self.lineDIP)),
                                                 page: CGFloat(self.viewportHeight))
            self.scroll(to: self.offset + Int32(change))
            return 0
        }
        // WM_NCLBUTTONDOWN and WM_NCLBUTTONDBLCLK (the second click of a double click, sent even without CS_DBLCLKS): on the
        // scroll bar DefWindowProc runs its tracking loop (thumb, arrows, track), which starves the main queue otherwise (R11).
        for message: UINT in [0x00A1, 0x00A3] {
            viewport.on(message) { [weak self] wParam, lParam in
                guard wParam == 7 || wParam == 6 /* HTVSCROLL, HTHSCROLL */, let self else { return nil }
                self.stats.thumbDrags += 1
                WinModalPump.begin("scroll")
                defer { WinModalPump.end("scroll") }
                return DefWindowProcW(self.viewport.hwnd, message, wParam, lParam)
            }
        }
        viewport.on(0x0014 /* WM_ERASEBKGND */) { [weak self] wParam, _ in
            guard let self, let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
            WinOpenTrace.note(.erase, self.viewport.hwnd)
            var r = RECT()
            _ = GetClientRect(self.viewport.hwnd, &r)
            _ = FillRect(dc, &r, ctx.colors.brush(ctx.colors.palette.window))
            return 1
        }
        viewport.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
        viewport.on(0x0010 /* WM_CLOSE */) { _, _ in 0 }  // a child never closes the page
    }

    /// The content's width in pixels (the viewport beside its scroll bar's lane).
    var contentWidth: Int32 { paneWidth }

    /// Whether the native scroll bar is on the screen (`STATE_SYSTEM_INVISIBLE` is off): only while the content is taller than the viewport.
    var barVisible: Bool {
        var info = SCROLLBARINFO()
        info.cbSize = DWORD(MemoryLayout<SCROLLBARINFO>.size)
        guard GetScrollBarInfo(viewport.hwnd, Int32(bitPattern: 0xFFFF_FFFB) /* OBJID_VSCROLL */, &info) else { return false }
        return info.rgstate.0 & 0x0000_8000 == 0
    }

    var viewportHeight: Int32 {
        var r = RECT()
        _ = GetClientRect(viewport.hwnd, &r)
        return r.bottom
    }

    /// The page's height (pixels): the bar's range, the pane's size (never shorter than the viewport) and a kept offset.
    func setContentHeight(_ height: Int32) {
        contentHeight = max(0, height)
        offset = Int32(PopoverScrollMath.clamped(CGFloat(offset), content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight)))
        WinKit.move(content.hwnd, RECT(left: 0, top: -offset, right: contentWidth, bottom: -offset + max(contentHeight, viewportHeight)))
        Self.updateBar(viewport.hwnd, height: contentHeight, page: viewportHeight, offset: offset)
    }

    func scroll(to y: Int32) {
        let next = Int32(PopoverScrollMath.clamped(CGFloat(y), content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight)))
        guard next != offset else { return }
        offset = next
        stats.moves += 1
        _ = SetWindowPos(content.hwnd, nil, 0, -offset, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        Self.updateBar(viewport.hwnd, height: contentHeight, page: viewportHeight, offset: offset)
    }

    /// Scrolls so the rect (content pixels) is visible with a 8 DIP margin; no move when it already is.
    func reveal(top: Int32, bottom: Int32) {
        stats.reveals += 1
        let y = PopoverScrollMath.revealing(top: CGFloat(top), bottom: CGFloat(bottom), offset: CGFloat(offset),
                                            viewport: CGFloat(viewportHeight), content: CGFloat(contentHeight), margin: CGFloat(ctx.px(8)))
        scroll(to: Int32(y))
    }

    /// The keyboard moved the focus to `hwnd`: the scroll area it is in (if any) brings it into view.
    static func reveal(_ hwnd: HWND) {
        var node: HWND? = GetParent(hwnd)
        while let n = node {
            if let area = areas[Int(bitPattern: n)] {
                let r = WinKit.rect(hwnd, in: n)
                area.reveal(top: r.top, bottom: r.bottom)
                return
            }
            node = GetParent(n)
        }
    }

    func move(_ r: RECT) {
        WinKit.move(viewport.hwnd, r)
        paneWidth = (r.right - r.left) - laneWidth
        setContentHeight(contentHeight)
    }

    /// The window `bits` is gone (`WinSinkWindow`'s `WM_NCDESTROY`): no entry may outlive its content pane.
    static func forget(_ bits: Int) { areas[bits] = nil }

    /// Scroll areas alive (the selftest reads it).
    static var liveCount: Int { areas.count }

    func destroy() {
        Self.areas[Int(bitPattern: content.hwnd)] = nil
        content.destroy()
        viewport.destroy()
    }

    private func vscroll(_ code: Int) {
        let line = ctx.px(Self.lineDIP), page = max(line, viewportHeight - line)
        switch code {
        case 0: scroll(to: offset - line)  // SB_LINEUP
        case 1: scroll(to: offset + line)  // SB_LINEDOWN
        case 2: scroll(to: offset - page)  // SB_PAGEUP
        case 3: scroll(to: offset + page)  // SB_PAGEDOWN
        case 4, 5:  // SB_THUMBPOSITION, SB_THUMBTRACK: the 32-bit track position
            if WinModalPump.depth > 0 { stats.pumpDepthDuringDrag = max(stats.pumpDepthDuringDrag, WinModalPump.depth) }
            var si = SCROLLINFO()
            si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
            si.fMask = 0x0010  // SIF_TRACKPOS
            if GetScrollInfo(viewport.hwnd, 1 /* SB_VERT */, &si) { scroll(to: si.nTrackPos) }
        case 6: scroll(to: 0)  // SB_TOP
        case 7: scroll(to: contentHeight)  // SB_BOTTOM
        default: break
        }
    }

    /// `SIF_DISABLENOSCROLL` always: it is what enables a bar again when the range grows (a bar hidden by `ShowScrollBar` or by a
    /// range that fits the page keeps its disabled state otherwise: shown, but the thumb and arrows do nothing). `keepLane` keeps the
    /// bar on the screen (disabled when nothing scrolls), which is how the lane is measured; otherwise it is on the screen only while
    /// the content is taller than the page.
    private static func updateBar(_ hwnd: HWND, height: Int32, page: Int32, offset: Int32, keepLane: Bool = false) {
        var si = SCROLLINFO()
        si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        si.fMask = 0x0001 | 0x0002 | 0x0004 | 0x0008  // SIF_RANGE | SIF_PAGE | SIF_POS | SIF_DISABLENOSCROLL
        si.nMin = 0
        si.nMax = max(0, height - 1)
        si.nPage = UINT(max(1, page))
        si.nPos = offset
        _ = SetScrollInfo(hwnd, 1 /* SB_VERT */, &si, true)
        // only a change of state is asked for: a `ShowScrollBar` on a bar that is already as wanted is not harmless here (run 44217166273:
        // the bar's rectangle read back as zeros after it)
        let want = PopoverScrollMath.showsBar(content: CGFloat(height), viewport: CGFloat(page)) || keepLane
        if barShown(hwnd) != want { _ = ShowScrollBar(hwnd, 1, want) }
    }

    private static func barShown(_ hwnd: HWND) -> Bool {
        var info = SCROLLBARINFO()
        info.cbSize = DWORD(MemoryLayout<SCROLLBARINFO>.size)
        guard GetScrollBarInfo(hwnd, Int32(bitPattern: 0xFFFF_FFFB), &info) else { return false }
        return info.rgstate.0 & 0x0000_8000 == 0
    }

    /// For the selftest's failure lines: whether the style has the bar, its range and the state and rectangle the system reports.
    func debugState() -> String {
        var si = SCROLLINFO()
        si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        si.fMask = 0x0001 | 0x0002 | 0x0004 | 0x0010  // SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS
        _ = GetScrollInfo(viewport.hwnd, 1, &si)
        var info = SCROLLBARINFO()
        info.cbSize = DWORD(MemoryLayout<SCROLLBARINFO>.size)
        let ok = GetScrollBarInfo(viewport.hwnd, Int32(bitPattern: 0xFFFF_FFFB), &info)
        let style = UInt(bitPattern: Int(GetWindowLongPtrW(viewport.hwnd, -16 /* GWL_STYLE */)))
        return "style WS_VSCROLL=\(style & 0x0020_0000 != 0) info range \(si.nMin)...\(si.nMax) page \(si.nPage) pos \(si.nPos), GetScrollBarInfo=\(ok) state=0x\(String(info.rgstate.0, radix: 16)) "
            + "rect \(info.rcScrollBar.left),\(info.rcScrollBar.top)-\(info.rcScrollBar.right),\(info.rcScrollBar.bottom) thumb \(info.xyThumbTop)-\(info.xyThumbBottom)"
    }
}
#endif
