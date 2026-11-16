#if os(Windows)
import Foundation
import WinSDK

/// The host of a drawn part (stage 7 D7): a child window showing a `PopoverDrawing` made at the window's DPI. The layers
/// are composed into one premultiplied 32-bpp top-down DIB (`PopoverComposite`) and `WM_PAINT` alpha-blends it over the
/// background, 1:1. Every accessibility item becomes a real child: a button item an owner-drawn button (a Tab stop; its
/// label is its window text; Enter or Space press it; the press is the item's hit), a text item an owner-drawn static
/// (read by Narrator as its text). Each paints the picture under it, so the part looks the same with them on top. The
/// drawing's tooltips become tooltip tools; a click reports `hitTest`'s hit to `onHit`. Sprite slots are left to the
/// animator (Task 8): `spriteSlots`, `paintOverlay`, `invalidate(dip:)`. Paints only when shown again or invalidated.
@MainActor final class WinDrawnView {
    static let className = "PokeTokenBarDrawn"

    let window: WinSinkWindow
    var hwnd: HWND { window.hwnd }
    let ctx: WinUIContext
    /// What is behind the picture (the card or the window).
    var background: COLORREF
    var onHit: ((PlazaPanelHit) -> Void)?
    /// What a click at a point (DIP, part coordinates) hits.
    var hitTest: ((CGPoint) -> PlazaPanelHit?)?
    /// Draws over the picture after it is blitted (sprite frames, Task 8).
    var paintOverlay: ((HDC) -> Void)?
    // --- stage 7 Task 12: the pointer and the keys over a part (begin) ---
    /// The pointer over the part (DIP, part coordinates); nil when it left. Set before the first `show`: only then do the
    /// part's items follow the pointer. Windows is asked to tell when the pointer leaves only while it is over the part.
    var onPointer: ((CGPoint?) -> Void)?
    /// A key pressed with the focus on one of the part's items (a virtual-key code); true when handled. Set before the first
    /// `show`: only then do the items take the arrow keys.
    var onKey: ((Int) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    /// Whether Escape is the part's now (a selection to clear).
    var claimsEscape: (() -> Bool)?
    private var overPart = false
    // --- stage 7 Task 12 (end) ---
    /// The view as a control a `WinStack` row places.
    private(set) var control: WinControl!
    /// The sprites in the part's slots (Task 8): fed the slots after every `show`, freed with the view.
    var sprites: WinSpriteAnimator? {
        didSet { if oldValue !== sprites { oldValue?.destroy(); sprites?.update(slots: drawing?.spriteSlots ?? [], in: self) } }
    }

    private(set) var drawing: PopoverDrawing?
    private(set) var items: [WinControl] = []
    private var itemData: [PlazaAccessibilityItem] = []
    private(set) var pixelSize = SIZE(cx: 0, cy: 0)
    private var memDC: HDC?
    private var bitmap: HBITMAP?
    private var oldBitmap: HGDIOBJ?
    private var bits: UnsafeMutableRawPointer?
    private var router: WinControlRouter?
    private var pressed: PlazaPanelHit?
    private var hosted: (any PopoverPart)?
    private var hostedWidth: CGFloat = 0
    private var renderPending = false
    private var tooltipKey: [String] = []  // stage 7 Task 12
    private(set) var isDestroyed = false

    struct Stats: Equatable { var paints = 0, composes = 0, itemBuilds = 0, itemMoves = 0, hits = 0, renders = 0, paintPixels = 0, partialPaints = 0, itemRenames = 0 }
    private(set) var stats = Stats()

    init(parent: HWND, ctx: WinUIContext) throws {
        self.ctx = ctx
        background = ctx.colors.palette.window
        let style: DWORD = 0x4000_0000 | 0x1000_0000 | 0x0200_0000  // WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN
        window = try WinSinkWindow(className: Self.className, title: "", style: style, exStyle: 0x0001_0000 /* WS_EX_CONTROLPARENT */,
                                   x: 0, y: 0, width: 1, height: 1, parent: parent)
        router = WinControlRouter(window: window)
        control = WinControls.drawn(window.hwnd, size: .zero, ctx: ctx) { [weak self] r in self?.place(r) }
        control.onDestroy = { [weak self] in self?.destroy() }  // a page that destroys its controls frees the picture too
        control.fitWidth = { [weak self] width in self?.fit(width: width) ?? false }
        window.on(0x0014 /* WM_ERASEBKGND */) { _, _ in 1 }
        window.on(0x000F /* WM_PAINT */) { [weak self] _, _ in self?.onPaint() }
        window.on(0x0201 /* WM_LBUTTONDOWN */) { [weak self] _, lParam in
            guard let self else { return nil }
            self.pressed = self.hitTest?(self.dip(WinKit.point(lParam)))
            _ = SetCapture(self.hwnd)
            return 0
        }
        window.on(0x0202 /* WM_LBUTTONUP */) { [weak self] _, lParam in
            guard let self else { return nil }
            let was = self.pressed
            self.pressed = nil
            if GetCapture() == self.hwnd { _ = ReleaseCapture() }
            if let was, self.hitTest?(self.dip(WinKit.point(lParam))) == was { self.report(was) }
            return 0
        }
        window.on(0x0215 /* WM_CAPTURECHANGED */) { [weak self] _, _ in self?.pressed = nil; return nil }
        // --- stage 7 Task 12 (begin) ---
        window.on(0x0200 /* WM_MOUSEMOVE */) { [weak self] _, lParam in
            guard let self, let onPointer = self.onPointer else { return nil }
            if !self.overPart {
                self.overPart = true
                var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: self.hwnd, dwHoverTime: 0)
                _ = TrackMouseEvent(&tme)
            }
            onPointer(self.dip(WinKit.point(lParam)))
            return 0
        }
        window.on(0x02A3 /* WM_MOUSELEAVE */) { [weak self] _, _ in
            guard let self, self.onPointer != nil else { return nil }
            self.overPart = false
            self.onPointer?(nil)
            return 0
        }
        // --- stage 7 Task 12 (end) ---
        window.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
    }

    /// The picture's size in DIP (a part's `size(width:scale:text:)`). A new size tells the page (`onSizeChange`), which
    /// lays itself out again, so the rows under a part that grew or shrank move with it.
    func setSize(_ dip: CGSize) {
        setSize(dip, notify: true)
    }

    private func setSize(_ dip: CGSize, notify: Bool) {
        let w = Int32((dip.width * ctx.scale).rounded()), h = Int32((dip.height * ctx.scale).rounded())
        let next = SIZE(cx: max(0, w), cy: max(0, h))
        let changed = next.cx != pixelSize.cx || next.cy != pixelSize.cy
        pixelSize = next
        control.preferredSize = CGSize(width: CGFloat(pixelSize.cx), height: CGFloat(pixelSize.cy))
        _ = SetWindowPos(hwnd, nil, 0, 0, pixelSize.cx, pixelSize.cy, UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
        if changed, notify { control.onSizeChange?() }
    }

    /// The page's layout asks a hosted part for its size at the row's width (pixels): measured and rendered again when the
    /// width is new; true when the size changed (the layout then runs its pass again with it).
    func fit(width px: Int32) -> Bool {
        let width = CGFloat(px) / ctx.scale
        guard hosted != nil, abs(width - hostedWidth) > 0.5 else { return false }
        hostedWidth = width
        let before = pixelSize
        render(notify: false)
        return before.cx != pixelSize.cx || before.cy != pixelSize.cy
    }

    /// Shows a drawing at the current size: composes the picture, makes or moves the accessibility children, sets the
    /// tooltips and repaints.
    func show(_ drawing: PopoverDrawing) {
        guard !isDestroyed else { return }
        self.drawing = drawing
        compose(drawing.drawing.layers)
        // --- stage 7 Task 9: overlays, unchanged tooltips, the dirty region (begin) ---
        composeOverlays(drawing.overlays)
        let rebuilt = stats.itemBuilds
        updateItems(drawing.drawing.accessibility)
        if stats.itemBuilds != rebuilt || drawing.drawing.tooltips != shownTooltips {
            updateTooltips(drawing.drawing.tooltips)
            shownTooltips = drawing.drawing.tooltips
        }
        sprites?.update(slots: drawing.spriteSlots, in: self)
        // --- stage 7 Task 12: a render that knows what changed repaints only that (begin) ---
        // (merged with Task 9: the item children over the region repaint with it, RDW_ALLCHILDREN, rather than all of them)
        if let dirty = drawing.dirty {
            var px = WinKit.rect(CGRect(x: dirty.minX * ctx.scale, y: dirty.minY * ctx.scale, width: dirty.width * ctx.scale, height: dirty.height * ctx.scale))
            px.left -= 1; px.top -= 1; px.right += 1; px.bottom += 1
            _ = RedrawWindow(hwnd, &px, nil, UINT(0x0001 | 0x0080))  // RDW_INVALIDATE | RDW_ALLCHILDREN
            stats.partialPaints += 1
        } else {
            _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0080))  // RDW_INVALIDATE | RDW_ALLCHILDREN (Task 9: items paint what is under them)
        }
        // --- stage 7 Task 12 (end) ---
        // --- stage 7 Task 9 (end) ---
    }

    /// Hosts a part: measures it at `width` DIP, renders it at the window's scale, shows it, and renders again (once per
    /// main-queue turn) whenever the part says it changed.
    func host(_ part: any PopoverPart, width: CGFloat) {
        hosted = part
        hostedWidth = width
        part.onChange = { [weak self] in self?.scheduleRender() }
        hitTest = { [weak part] point in part?.hit(point) }
        render()
    }

    var spriteSlots: [SpriteSlot] { drawing?.spriteSlots ?? [] }

    /// Repaints only `r` (DIP): a sprite slot's frame. The accessibility items over it repaint too (stage 7 Task 9: they
    /// draw the sprites and overlays under them).
    func invalidate(dip r: CGRect) {
        var px = WinKit.rect(CGRect(x: r.minX * ctx.scale, y: r.minY * ctx.scale, width: r.width * ctx.scale, height: r.height * ctx.scale))
        _ = RedrawWindow(hwnd, &px, nil, UINT(0x0001 | 0x0080))  // RDW_INVALIDATE | RDW_ALLCHILDREN
    }

    /// The composed picture's pixel (B, G, R, A premultiplied) at `x`, `y` (the selftest reads it).
    func pixel(x: Int, y: Int) -> [UInt8]? {
        guard let bits, x >= 0, y >= 0, x < Int(pixelSize.cx), y < Int(pixelSize.cy) else { return nil }
        _ = GdiFlush()
        let o = (y * Int(pixelSize.cx) + x) * 4
        return (0..<4).map { bits.load(fromByteOffset: o + $0, as: UInt8.self) }
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        sprites?.destroy()
        sprites = nil
        for item in items { item.destroy() }
        items = []
        ctx.tooltips.removeAll(in: hwnd)
        releaseBitmap()
        releaseOverlays()  // stage 7 Task 9
        router?.detach()
        router = nil
        hosted?.onChange = nil
        hosted = nil
        onHit = nil
        hitTest = nil
        paintOverlay = nil
        control.destroy()
    }

    // MARK: - picture

    private func compose(_ layers: [PlazaPanelLayer]) {
        stats.composes += 1
        let w = Int(pixelSize.cx), h = Int(pixelSize.cy)
        guard w > 0, h > 0 else { releaseBitmap(); return }
        let made = Self.size(of: bitmap)
        if bitmap == nil || made.cx != pixelSize.cx || made.cy != pixelSize.cy { makeBitmap() }
        guard let bits else { return }
        let bytes = PopoverComposite.compose(layers, width: w, height: h, scale: ctx.scale)
        _ = GdiFlush()
        bytes.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, w * h * 4)) }
    }

    private func makeBitmap() {
        releaseBitmap()
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = pixelSize.cx
        info.bmiHeader.biHeight = -pixelSize.cy  // top-down: row 0 first, as PlazaBitmap
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0  // BI_RGB
        guard let dc = CreateCompatibleDC(nil) else { return }
        var p: UnsafeMutableRawPointer?
        guard let b = CreateDIBSection(dc, &info, 0 /* DIB_RGB_COLORS */, &p, nil, 0), p != nil else {
            AppLog.write("popover kit: CreateDIBSection \(pixelSize.cx)x\(pixelSize.cy) failed: \(GetLastError())")
            _ = DeleteDC(dc)
            return
        }
        memDC = dc
        bitmap = b
        bits = p
        oldBitmap = SelectObject(dc, UnsafeMutableRawPointer(b))
    }

    private func releaseBitmap() {
        if let dc = memDC {
            _ = SelectObject(dc, oldBitmap)
            _ = DeleteDC(dc)
        }
        if let b = bitmap { _ = DeleteObject(UnsafeMutableRawPointer(b)) }
        memDC = nil
        bitmap = nil
        bits = nil
        oldBitmap = nil
    }

    private static func size(of bitmap: HBITMAP?) -> SIZE {
        var bm = BITMAP()
        guard let bitmap, GetObjectW(UnsafeMutableRawPointer(bitmap), Int32(MemoryLayout<BITMAP>.size), &bm) != 0 else { return SIZE(cx: 0, cy: 0) }
        return SIZE(cx: bm.bmWidth, cy: bm.bmHeight)
    }

    private func onPaint() -> LRESULT {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return 0 }
        stats.paints += 1
        var r = ps.rcPaint
        _ = FillRect(dc, &r, ctx.colors.brush(background))
        // Only the invalidated rectangle is blended (a sprite frame's tick repaints just its slot).
        let right = min(r.right, pixelSize.cx), bottom = min(r.bottom, pixelSize.cy)
        stats.paintPixels += Int(max(0, r.right - r.left)) * Int(max(0, r.bottom - r.top))
        blit(into: dc, from: POINT(x: r.left, y: r.top), size: SIZE(cx: right - r.left, cy: bottom - r.top), at: POINT(x: r.left, y: r.top))
        paintOverlay?(dc)
        blitOverlays(into: dc, rect: r)  // stage 7 Task 9: over the sprites
        _ = EndPaint(hwnd, &ps)
        return 0
    }

    // --- stage 7 Task 9: layers over the sprites (begin) ---
    private var overlayDC: HDC?
    private var overlayBitmap: HBITMAP?
    private var overlayOld: HGDIOBJ?
    private var overlayBits: UnsafeMutableRawPointer?
    private var overlaySize = SIZE(cx: 0, cy: 0)
    private var shownTooltips: [PlazaTooltip] = []

    /// The drawing's overlays composed into their own picture (none: freed).
    private func composeOverlays(_ layers: [PlazaPanelLayer]) {
        let w = Int(pixelSize.cx), h = Int(pixelSize.cy)
        guard !layers.isEmpty, w > 0, h > 0 else { releaseOverlays(); return }
        if overlayDC == nil || overlaySize.cx != pixelSize.cx || overlaySize.cy != pixelSize.cy {
            releaseOverlays()
            var info = BITMAPINFO()
            info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            info.bmiHeader.biWidth = pixelSize.cx
            info.bmiHeader.biHeight = -pixelSize.cy
            info.bmiHeader.biPlanes = 1
            info.bmiHeader.biBitCount = 32
            info.bmiHeader.biCompression = 0
            guard let dc = CreateCompatibleDC(nil) else { return }
            var p: UnsafeMutableRawPointer?
            guard let b = CreateDIBSection(dc, &info, 0, &p, nil, 0), p != nil else {
                AppLog.write("popover kit: overlay CreateDIBSection \(w)x\(h) failed: \(GetLastError())")
                _ = DeleteDC(dc)
                return
            }
            overlayDC = dc
            overlayBitmap = b
            overlayBits = p
            overlayOld = SelectObject(dc, UnsafeMutableRawPointer(b))
            overlaySize = pixelSize
        }
        guard let overlayBits else { return }
        let bytes = PopoverComposite.compose(layers, width: w, height: h, scale: ctx.scale)
        _ = GdiFlush()
        bytes.withUnsafeBytes { overlayBits.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, w * h * 4)) }
    }

    private func releaseOverlays() {
        if let dc = overlayDC {
            _ = SelectObject(dc, overlayOld)
            _ = DeleteDC(dc)
        }
        if let b = overlayBitmap { _ = DeleteObject(UnsafeMutableRawPointer(b)) }
        overlayDC = nil
        overlayBitmap = nil
        overlayBits = nil
        overlayOld = nil
        overlaySize = SIZE(cx: 0, cy: 0)
    }

    /// `rect` (view pixels) of the overlay picture, blended where `dc` has the view's origin.
    private func blitOverlays(into dc: HDC?, rect r: RECT) {
        guard let overlayDC, overlaySize.cx > 0 else { return }
        let right = min(r.right, overlaySize.cx), bottom = min(r.bottom, overlaySize.cy)
        guard right > r.left, bottom > r.top else { return }
        let blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1)
        _ = GdiAlphaBlend(dc, r.left, r.top, right - r.left, bottom - r.top, overlayDC, r.left, r.top, right - r.left, bottom - r.top, blend)
    }

    /// An item's own paint also draws the sprites and overlays under it: the item covers them (a text line under a burst,
    /// the sprite box under its name), and the view's paint is clipped out where a child is.
    private func paintUnderItem(_ dc: HDC?, at: RECT, size: SIZE) {
        guard let dc, paintOverlay != nil || overlayDC != nil else { return }
        var old = POINT()
        _ = SetViewportOrgEx(dc, -at.left, -at.top, &old)
        paintOverlay?(dc)
        blitOverlays(into: dc, rect: RECT(left: at.left, top: at.top, right: at.left + size.cx, bottom: at.top + size.cy))
        _ = SetViewportOrgEx(dc, old.x, old.y, nil)
    }
    // --- stage 7 Task 9: layers over the sprites (end) ---

    /// `AlphaBlend` (premultiplied source, `AC_SRC_ALPHA`) of a piece of the picture.
    private func blit(into dc: HDC?, from source: POINT, size: SIZE, at dest: POINT) {
        guard let memDC, size.cx > 0, size.cy > 0 else { return }
        let blend = BLENDFUNCTION(BlendOp: 0 /* AC_SRC_OVER */, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 /* AC_SRC_ALPHA */)
        _ = GdiAlphaBlend(dc, dest.x, dest.y, size.cx, size.cy, memDC, source.x, source.y, size.cx, size.cy, blend)
    }

    // MARK: - accessibility children

    private func updateItems(_ new: [PlazaAccessibilityItem]) {
        var sameItems = new.count == itemData.count && zip(new, itemData).allSatisfy { $0.sameExceptFrame($1) }
        // --- stage 7 Task 12: an item whose only change is its text is renamed in place (the focus stays; Narrator is told) (begin) ---
        if !sameItems, new.count == itemData.count, items.count == new.filter({ $0.role != .scrollArea }).count,
           zip(new, itemData).allSatisfy({ $0.role == $1.role && $0.action == $1.action && $0.key == $1.key && $0.isEnabled == $1.isEnabled && $0.inScrollArea == $1.inScrollArea }) {
            for (c, item) in zip(items, new.filter { $0.role != .scrollArea }) {
                let name = item.value.map { "\(item.label), \($0)" } ?? item.label
                if c.text != name {
                    c.text = name
                    _ = NotifyWinEvent(0x800C /* EVENT_OBJECT_NAMECHANGE */, c.hwnd, -4 /* OBJID_CLIENT */, 0 /* CHILDID_SELF */)
                    stats.itemRenames += 1
                }
            }
            sameItems = true
        }
        // --- stage 7 Task 12 (end) ---
        if !sameItems {
            let focusedIndex = items.firstIndex { $0.hwnd == GetFocus() }
            for item in items { item.destroy() }
            items = []
            stats.itemBuilds += 1
            for item in new where item.role != .scrollArea {
                guard let c = WinControls.drawnItem(item, in: hwnd, ctx: ctx) else { continue }
                c.background = background
                let action = item.action
                c.onClick = { [weak self] in if let action { self?.report(action) } }
                c.drawItem = { [weak self, weak c] dis in
                    guard let self, let c else { return }
                    self.paintItem(c, dis)
                }
                // --- stage 7 Task 12: the item forwards the pointer, the keys and the focus (begin) ---
                if onPointer != nil {
                    c.onPointer = { [weak self, weak c] p in
                        guard let self, let c else { return }
                        guard let p else { self.onPointer?(nil); return }
                        let at = WinKit.rect(c.hwnd, in: self.hwnd)
                        self.onPointer?(self.dip(POINT(x: p.x + at.left, y: p.y + at.top)))
                    }
                }
                if onKey != nil {
                    c.onKey = { [weak self] key in self?.onKey?(key) ?? false }
                    c.claimsEscape = { [weak self] in self?.claimsEscape?() ?? false }
                }
                if onFocus != nil { c.onFocus = { [weak self] focused in self?.onFocus?(focused) } }
                // --- stage 7 Task 12 (end) ---
                items.append(c)
            }
            if let i = focusedIndex, i < items.count { _ = SetFocus(items[i].hwnd) }
        } else {
            stats.itemMoves += 1
        }
        itemData = new
        for (c, item) in zip(items, new.filter { $0.role != .scrollArea }) {
            let r = PopoverComposite.pixelRect(item.frame, scale: ctx.scale)
            WinKit.move(c.hwnd, RECT(left: Int32(r.x), top: Int32(r.y), right: Int32(r.x + r.width), bottom: Int32(r.y + r.height)))
            _ = InvalidateRect(c.hwnd, nil, false)
        }
    }

    /// An item paints the picture under it, then its focus rectangle when the keyboard put the focus there.
    private func paintItem(_ c: WinControl, _ dis: UnsafeMutablePointer<DRAWITEMSTRUCT>) {
        let d = dis.pointee
        var r = d.rcItem
        _ = FillRect(d.hDC, &r, ctx.colors.brush(background))
        let at = WinKit.rect(c.hwnd, in: hwnd)
        blit(into: d.hDC, from: POINT(x: at.left, y: at.top), size: SIZE(cx: r.right - r.left, cy: r.bottom - r.top), at: POINT(x: 0, y: 0))
        paintUnderItem(d.hDC, at: at, size: SIZE(cx: r.right - r.left, cy: r.bottom - r.top))  // stage 7 Task 9
        if d.itemState & 0x0010 != 0, d.itemState & 0x0200 == 0 {  // ODS_FOCUS, not ODS_NOFOCUSRECT
            var f = d.rcItem
            _ = InflateRect(&f, -1, -1)
            _ = DrawFocusRect(d.hDC, &f)
        }
    }

    private func updateTooltips(_ tooltips: [PlazaTooltip]) {
        // --- stage 7 Task 12: the same tooltips again change nothing (a hover render would otherwise dismiss a shown one) (begin) ---
        let key = tooltips.map { "\($0.frame)|\($0.text)" } + [String(stats.itemBuilds)]
        guard key != tooltipKey else { return }
        tooltipKey = key
        // --- stage 7 Task 12 (end) ---
        ctx.tooltips.removeAll(in: hwnd)
        for (i, tip) in tooltips.enumerated() {
            let r = PopoverComposite.pixelRect(tip.frame, scale: ctx.scale)
            ctx.tooltips.setRect(tip.text, id: i + 1, rect: RECT(left: Int32(r.x), top: Int32(r.y), right: Int32(r.x + r.width), bottom: Int32(r.y + r.height)),
                                 in: hwnd)
            // A button item over the tooltip's rect takes the mouse there: it carries the same text.
            for (c, item) in zip(items, itemData.filter { $0.role != .scrollArea }) where c.kind == .drawnItem && tip.frame.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) {
                ctx.tooltips.set(tip.text, for: c.hwnd, in: hwnd)
            }
        }
    }

    // MARK: - parts and hits

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.render(notify: true)
        }
    }

    private func render(notify: Bool = true) {
        guard let part = hosted, !isDestroyed else { return }
        stats.renders += 1
        let graphics = PlatformPlaza.graphics
        setSize(part.size(width: hostedWidth, scale: ctx.scale, text: graphics.text), notify: notify)
        show(part.render(scale: ctx.scale, graphics: graphics))
    }

    /// A stack row placed the view at the row's origin (the layout already fitted it to the row's width; a view placed by
    /// other code is fitted here).
    private func place(_ r: RECT) {
        if background != control.background {  // the row says what is behind it (a card or the window)
            background = control.background
            for item in items { item.background = background }
            _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0080))  // RDW_INVALIDATE | RDW_ALLCHILDREN
        }
        if hosted != nil, fit(width: r.right - r.left) { control.onSizeChange?() }
        _ = SetWindowPos(hwnd, nil, r.left, r.top, pixelSize.cx, pixelSize.cy, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    private func dip(_ p: POINT) -> CGPoint { CGPoint(x: CGFloat(p.x) / ctx.scale, y: CGFloat(p.y) / ctx.scale) }

    private func report(_ hit: PlazaPanelHit) {
        stats.hits += 1
        onHit?(hit)
    }
}
#endif
