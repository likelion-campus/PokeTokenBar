#if os(Windows)
import Foundation
import WinSDK

/// A scrolling page (stage 7 D6, K2): a viewport with an overlay scroll thumb in a lane at its right edge and, inside it, the
/// content pane the page's controls live in, moved up and down as one window. The content's width never changes with its
/// height: it is the viewport beside the lane (`paneWidth`), the Mac's 12 pt scroller lane (`PopoverView.swift:13-26`), shown
/// or not. The thumb is the Mac's overlay scroller as Windows 11's own overlay bars draw it: a 3 DIP capsule at rest, 6 DIP with
/// the lane tinted while the pointer is in the lane or the thumb is dragged (high contrast: the text colour, no tint). It is
/// drawn only while the content is taller than the viewport and never fades (no timer; windows-differences.md). A drag holds
/// the mouse capture and moves the page from `WM_MOUSEMOVE`, a click in the lane outside the thumb pages towards it; neither
/// runs a modal loop. The wheel and a precision touchpad scroll it (`SPI_GETWHEELSCROLLLINES` lines of 16 DIP a notch, fractions
/// kept); a control the keyboard focuses is brought into view. It moves only on input.
@MainActor final class WinScrollArea {
    static let className = "PokeTokenBarScroll"
    static let laneClassName = "PokeTokenBarScrollLane"
    static let lineDIP: CGFloat = 16
    /// The lane's width (the Mac's `PopoverView` scroller lane), the thumb's widths, its inset from the lane's edge and from the
    /// track's ends, and its shortest length.
    static let laneDIP: CGFloat = 12
    static let restWidthDIP: CGFloat = 3
    static let hotWidthDIP: CGFloat = 6
    static let insetDIP: CGFloat = 3
    static let trackInsetDIP: CGFloat = 2
    static let minThumbDIP: CGFloat = 24

    let viewport: WinSinkWindow
    let content: WinPane
    let ctx: WinUIContext
    private(set) var offset: Int32 = 0
    private(set) var contentHeight: Int32 = 0
    /// The content's width in pixels: the viewport's width with the lane taken, whether the thumb is shown or not.
    private(set) var paneWidth: Int32 = 0
    private var laneWidth: Int32 { ctx.px(Self.laneDIP) }
    private var wheel = PopoverWheel()
    private let lane: WinSinkWindow
    private var hover = false
    /// While the thumb is held: the pointer's distance below the thumb's top.
    private var grab: Int32?
    private var laneTracking = false
    /// What `layoutLane` last applied.
    private var appliedShows = false, appliedLane = [Int32](), appliedThumb: PopoverScrollMath.Thumb?

    struct Stats: Equatable {
        var wheelMessages = 0, thumbDrags = 0, pageClicks = 0, reveals = 0, moves = 0
        /// The greatest `WinModalPump.depth` seen while a drag moved the page: 0 means no modal loop ran (the system bar's did).
        var pumpDepthDuringDrag = 0
    }
    private(set) var stats = Stats()
    private static var areas: [Int: WinScrollArea] = [:]

    init(parent: HWND, ctx: WinUIContext, rect: RECT) throws {
        self.ctx = ctx
        let style: DWORD = 0x4000_0000 | 0x1000_0000 | 0x0200_0000  // WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN
        let made = try WinSinkWindow(className: Self.className, title: "", style: style, exStyle: 0x0001_0000 /* WS_EX_CONTROLPARENT */,
                                     x: rect.left, y: rect.top, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: parent)
        let lanePx = ctx.px(Self.laneDIP)
        let pane: WinPane, laneWindow: WinSinkWindow
        do {
            pane = try WinPane(parent: made.hwnd, ctx: ctx, rect: RECT(left: 0, top: 0, right: max(1, rect.right - rect.left - lanePx), bottom: rect.bottom - rect.top))
            laneWindow = try WinSinkWindow(className: Self.laneClassName, title: "", style: 0x4000_0000 /* WS_CHILD, hidden until it can scroll */, exStyle: 0,
                                           x: max(0, rect.right - rect.left - lanePx), y: 0, width: lanePx, height: rect.bottom - rect.top, parent: made.hwnd)
        } catch {
            made.destroy()
            throw error
        }
        viewport = made
        content = pane
        lane = laneWindow
        paneWidth = max(1, rect.right - rect.left - lanePx)
        Self.areas[Int(bitPattern: content.hwnd)] = self
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
        installLane()
    }

    /// The content's width in pixels (the viewport beside its scroll bar's lane).
    var contentWidth: Int32 { paneWidth }

    /// Whether the thumb is on the screen: only while the content is taller than the viewport (the lane window is shown then).
    var barVisible: Bool {
        thumb != nil && UInt(bitPattern: Int(GetWindowLongPtrW(lane.hwnd, -16 /* GWL_STYLE */))) & 0x1000_0000 /* WS_VISIBLE */ != 0
    }

    var viewportHeight: Int32 {
        var r = RECT()
        _ = GetClientRect(viewport.hwnd, &r)
        return r.bottom
    }

    /// The page's height (pixels): the thumb's range, the pane's size (never shorter than the viewport) and a kept offset.
    func setContentHeight(_ height: Int32) {
        contentHeight = max(0, height)
        offset = Int32(PopoverScrollMath.clamped(CGFloat(offset), content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight)))
        WinKit.move(content.hwnd, RECT(left: 0, top: -offset, right: contentWidth, bottom: -offset + max(contentHeight, viewportHeight)))
        layoutLane()
    }

    func scroll(to y: Int32) {
        let next = Int32(PopoverScrollMath.clamped(CGFloat(y), content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight)))
        guard next != offset else { return }
        offset = next
        stats.moves += 1
        _ = SetWindowPos(content.hwnd, nil, 0, -offset, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        _ = InvalidateRect(lane.hwnd, nil, false)
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
        paneWidth = max(1, (r.right - r.left) - laneWidth)
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

    // MARK: the overlay thumb

    /// The thumb inside the lane's track (client pixels), nil while there is nothing to scroll.
    private var thumb: PopoverScrollMath.Thumb? {
        let inset = CGFloat(ctx.px(Self.trackInsetDIP))
        return PopoverScrollMath.thumb(content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight), offset: CGFloat(offset),
                                       track: CGFloat(viewportHeight) - 2 * inset, minLength: CGFloat(ctx.px(Self.minThumbDIP))).map {
            PopoverScrollMath.Thumb(top: $0.top + inset, length: $0.length)
        }
    }

    /// The thumb's rectangle in screen pixels (the selftest drives the mouse with it).
    var thumbScreenRect: RECT? {
        guard let t = thumb else { return nil }
        var tl = POINT(x: 0, y: Int32(t.top)), br = POINT(x: laneWidth, y: Int32(t.bottom))
        _ = ClientToScreen(lane.hwnd, &tl)
        _ = ClientToScreen(lane.hwnd, &br)
        return RECT(left: tl.x, top: tl.y, right: br.x, bottom: br.y)
    }

    /// Whether the pointer's lane look (the wider thumb on the tinted lane) is on.
    var laneHot: Bool { hover || grab != nil }

    /// Puts the lane window at the viewport's right edge and shows it only while the page can scroll. A layout that changes none of
    /// that (most of them) touches nothing: no window call, no repaint.
    private func layoutLane() {
        var client = RECT()
        _ = GetClientRect(viewport.hwnd, &client)
        let shows = PopoverScrollMath.showsBar(content: CGFloat(contentHeight), viewport: CGFloat(viewportHeight))
        let placed = RECT(left: max(0, client.right - laneWidth), top: 0, right: client.right, bottom: client.bottom)
        let look = thumb
        defer { appliedThumb = look }
        let key = [placed.left, placed.right, placed.bottom]
        if shows == appliedShows, key == appliedLane {
            if look != appliedThumb { _ = InvalidateRect(lane.hwnd, nil, false) }
            return
        }
        appliedShows = shows
        appliedLane = key
        // Placed and shown (or hidden) in one call, never activating (SWP_SHOWWINDOW / SWP_HIDEWINDOW, SWP_NOACTIVATE).
        _ = SetWindowPos(lane.hwnd, nil, placed.left, 0, placed.right - placed.left, placed.bottom,
                         UINT(SWP_NOZORDER | SWP_NOACTIVATE) | (shows ? 0x0040 : 0x0080))
        if !shows { hover = false; grab = nil }
        _ = InvalidateRect(lane.hwnd, nil, false)
    }

    private func installLane() {
        func y(_ lParam: LPARAM) -> Int32 { Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) }
        lane.on(0x0014 /* WM_ERASEBKGND */) { _, _ in 1 }  // WM_PAINT draws everything
        lane.on(0x000F /* WM_PAINT */) { [weak self] _, _ in
            guard let self else { return nil }
            var ps = PAINTSTRUCT()
            guard let dc = BeginPaint(self.lane.hwnd, &ps) else { return 0 }
            self.drawLane(dc)
            _ = EndPaint(self.lane.hwnd, &ps)
            return 0
        }
        lane.on(0x0318 /* WM_PRINTCLIENT */) { [weak self] wParam, _ in
            guard let self, let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
            self.drawLane(dc)
            return 0
        }
        lane.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
        lane.on(0x0010 /* WM_CLOSE */) { _, _ in 0 }
        lane.on(0x0200 /* WM_MOUSEMOVE */) { [weak self] _, lParam in
            guard let self else { return nil }
            if let grab = self.grab {
                self.stats.pumpDepthDuringDrag = max(self.stats.pumpDepthDuringDrag, WinModalPump.depth)
                let inset = CGFloat(self.ctx.px(Self.trackInsetDIP))
                self.scroll(to: Int32(PopoverScrollMath.offset(thumbTop: CGFloat(y(lParam) - grab) - inset, content: CGFloat(self.contentHeight),
                                                               viewport: CGFloat(self.viewportHeight),
                                                               track: CGFloat(self.viewportHeight) - 2 * inset, minLength: CGFloat(self.ctx.px(Self.minThumbDIP)))))
                return 0
            }
            if !self.laneTracking {  // asks Windows to say when the pointer leaves, only while it is over the lane
                self.laneTracking = true
                var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: self.lane.hwnd, dwHoverTime: 0)
                _ = TrackMouseEvent(&tme)
            }
            if !self.hover {
                self.hover = true
                _ = InvalidateRect(self.lane.hwnd, nil, false)
            }
            return 0
        }
        lane.on(0x02A3 /* WM_MOUSELEAVE */) { [weak self] _, _ in
            guard let self else { return nil }
            self.laneTracking = false
            if self.hover {
                self.hover = false
                _ = InvalidateRect(self.lane.hwnd, nil, false)
            }
            return 0
        }
        lane.on(0x0201 /* WM_LBUTTONDOWN */) { [weak self] _, lParam in
            guard let self, let t = self.thumb else { return 0 }
            let py = y(lParam)
            if CGFloat(py) >= t.top, CGFloat(py) < t.bottom {
                self.stats.thumbDrags += 1
                self.grab = py - Int32(t.top)
                _ = SetCapture(self.lane.hwnd)
                _ = InvalidateRect(self.lane.hwnd, nil, false)
            } else {
                self.stats.pageClicks += 1
                let line = self.ctx.px(Self.lineDIP)
                let page = max(line, self.viewportHeight - line)
                self.scroll(to: Int32(PopoverScrollMath.paged(clickY: CGFloat(py), thumb: t, offset: CGFloat(self.offset), page: CGFloat(page),
                                                              content: CGFloat(self.contentHeight), viewport: CGFloat(self.viewportHeight))))
            }
            return 0
        }
        for message: UINT in [0x0202 /* WM_LBUTTONUP */, 0x001F /* WM_CANCELMODE */] {
            lane.on(message) { [weak self] _, _ in
                guard let self, self.grab != nil else { return nil }
                _ = ReleaseCapture()  // WM_CAPTURECHANGED ends the drag
                return 0
            }
        }
        lane.on(0x0215 /* WM_CAPTURECHANGED */) { [weak self] _, _ in
            guard let self, self.grab != nil else { return nil }
            self.grab = nil
            _ = InvalidateRect(self.lane.hwnd, nil, false)
            return 0
        }
    }

    /// The lane: the window colour (tinted while the pointer is in it), then the thumb.
    private func drawLane(_ dc: HDC) {
        var r = RECT()
        _ = GetClientRect(lane.hwnd, &r)
        let pal = ctx.colors.palette
        let hc = ctx.highContrast
        let tint: COLORREF = ctx.dark ? WinUIColors.rgb(255, 255, 255) : WinUIColors.rgb(0, 0, 0)
        _ = FillRect(dc, &r, ctx.colors.brush(laneHot && !hc ? WinUIColors.blend(pal.window, tint, 0.03) : pal.window))
        guard let t = thumb else { return }
        let width = ctx.px(laneHot ? Self.hotWidthDIP : Self.restWidthDIP)
        let right = r.right - ctx.px(Self.insetDIP)
        let box = RECT(left: right - width, top: Int32(t.top), right: right, bottom: Int32(t.bottom))
        // Opacities: Windows 11's overlay bar at rest, firmer under the pointer; high contrast is the text colour, solid.
        let ink = hc ? WinPaint.Ink(color: pal.text) : WinPaint.Ink(color: tint, alpha: laneHot ? 0.55 : (ctx.dark ? 0.45 : 0.40))
        WinPaint.roundedRect(dc, box, radius: width / 2, fill: ink, under: pal.window, ctx: ctx)
    }

    /// For the selftest's failure lines: the content, the viewport and the thumb.
    func debugState() -> String {
        let t = thumb
        return "overlay thumb \(t.map { "\(Int($0.top))...\(Int($0.bottom))" } ?? "none") visible=\(barVisible) hot=\(laneHot) content \(contentHeight) viewport \(viewportHeight) offset \(offset) lane \(laneWidth) px"
    }
}
#endif
