#if os(Windows)
import Foundation
import WinSDK
import CPlazaD2D

/// The kit's antialiased shapes (visual polish K2). Every card, tile, pill, hover fill, focus ring and scroll thumb goes
/// through `ptb_paint_shapes` (a CPU Direct2D DC render target, `CPlazaD2DPaint.h`): GDI's `RoundRect` has no antialiasing,
/// and the drawn parts next to those shapes are antialiased by Direct2D, so the two looks sat side by side on one page.
/// Units are device pixels of the DC; strokes are whole pixels (the caller passes `max(1, ctx.px(1))`). A paint that
/// Direct2D cannot serve (the DLL is missing, the target is lost) falls back to the GDI shape, once logged, so the page
/// still draws. Main thread only; it paints on `WM_PAINT`/`WM_DRAWITEM` only, so nothing here wakes an idle page.
@MainActor enum WinPaint {
    /// A colour with the opacity it is laid over what is under it with.
    struct Ink: Equatable {
        var color: COLORREF
        var alpha: Double = 1
    }

    private static var loggedFallback = false
    /// Binds of the painter and the milliseconds they took, since the process started (the open-cost selftest prints them).
    private(set) static var binds = 0
    private(set) static var bindMs = 0.0

    private static func bind(_ dc: HDC, _ b: RECT, _ shapes: inout [PTBPaintShape]) -> Int32 {
        let t0 = WinOpenTrace.now()
        let code = ptb_paint_shapes(UnsafeMutableRawPointer(dc), b.left, b.top, b.right, b.bottom, &shapes, UInt32(shapes.count))
        binds += 1
        bindMs += WinOpenTrace.now() - t0
        return code
    }

    /// 0xAARRGGBB of a `COLORREF` (0x00BBGGRR).
    nonisolated static func argb(_ c: COLORREF, alpha: Double = 1) -> UInt32 {
        let a = UInt32((min(1, max(0, alpha)) * 255).rounded())
        let red: UInt32 = c & 0xFF, green: UInt32 = (c >> 8) & 0xFF, blue: UInt32 = (c >> 16) & 0xFF
        return (a << 24) | (red << 16) | (green << 8) | blue
    }

    /// One rounded rectangle of a batch.
    struct Item {
        var rect: RECT
        var radius: Int32
        var fill: Ink?
        var stroke: Ink?
        var strokeWidth: Int32 = 1
    }

    /// A rounded rectangle over `r` (right and bottom exclusive): `fill`, then `stroke` inside the edge. `under` is the colour
    /// the shape is laid over, used only when the antialiased painter is unavailable. `clip` (the paint's dirty rectangle) limits
    /// the work to the part being repainted.
    static func roundedRect(_ dc: HDC, _ r: RECT, radius: Int32, fill: Ink?, stroke: Ink? = nil, strokeWidth: Int32 = 1,
                            under: COLORREF, ctx: WinUIContext, clip: RECT? = nil) {
        roundedRects(dc, [Item(rect: r, radius: radius, fill: fill, stroke: stroke, strokeWidth: strokeWidth)], under: under, ctx: ctx, clip: clip)
    }

    /// Several rounded rectangles in one bind of the painter (a page's cards): the painter's cost is per bind, not per shape, and the
    /// bound area is the part of their union that `clip` leaves.
    static func roundedRects(_ dc: HDC, _ items: [Item], under: COLORREF, ctx: WinUIContext, clip: RECT? = nil) {
        let drawn = items.filter { $0.rect.right > $0.rect.left && $0.rect.bottom > $0.rect.top }
        guard let first = drawn.first else { return }
        var bounds = first.rect
        for item in drawn.dropFirst() {
            bounds = RECT(left: min(bounds.left, item.rect.left), top: min(bounds.top, item.rect.top),
                          right: max(bounds.right, item.rect.right), bottom: max(bounds.bottom, item.rect.bottom))
        }
        if let clip {
            bounds = RECT(left: max(bounds.left, clip.left), top: max(bounds.top, clip.top), right: min(bounds.right, clip.right), bottom: min(bounds.bottom, clip.bottom))
        }
        guard bounds.right > bounds.left, bounds.bottom > bounds.top, let seen = visible(dc, bounds) else { return }
        bounds = seen
        // A DC with an origin of its own (a child's, in WM_PRINTCLIENT): the painter's bind takes device coordinates, so it would draw
        // somewhere else; those rare edge paints are the plain GDI shape.
        var origin = POINT()
        if GetViewportOrgEx(dc, &origin), origin.x != 0 || origin.y != 0 {
            for item in drawn where intersects(item.rect, bounds) {
                fallback(dc, item.rect, radius: item.radius, fill: item.fill, stroke: item.stroke, strokeWidth: item.strokeWidth, under: under, ctx: ctx)
            }
            return
        }
        var shapes: [PTBPaintShape] = []
        for item in drawn where intersects(item.rect, bounds) {
            let fillARGB: UInt32 = item.fill.map { argb($0.color, alpha: $0.alpha) } ?? 0
            let strokeARGB: UInt32 = item.stroke.map { argb($0.color, alpha: $0.alpha) } ?? 0
            let x = Float(item.rect.left - bounds.left), y = Float(item.rect.top - bounds.top)
            let width = Float(item.rect.right - item.rect.left), height = Float(item.rect.bottom - item.rect.top)
            shapes.append(PTBPaintShape(x: x, y: y, w: width, h: height, radius: Float(item.radius), fill: fillARGB, stroke: strokeARGB,
                                        strokeWidth: item.stroke == nil ? 0 : Float(item.strokeWidth)))
        }
        guard !shapes.isEmpty else { return }
        if bind(dc, bounds, &shapes) >= 0 { return }
        for item in drawn where intersects(item.rect, bounds) {
            fallback(dc, item.rect, radius: item.radius, fill: item.fill, stroke: item.stroke, strokeWidth: item.strokeWidth, under: under, ctx: ctx)
        }
    }

    /// The focus ring (Windows 11): 2 DIP outer in `outer`, rounded, then (when `inner` is set) 1 DIP inside it in `inner`, drawn
    /// inside `r`. A control that is too small for both gives `inner` nil.
    static func focusRing(_ dc: HDC, _ r: RECT, radius: Int32, ctx: WinUIContext, outer: COLORREF, inner: COLORREF?) {
        guard r.right > r.left, r.bottom > r.top else { return }
        let w2 = max(2, ctx.px(2)), w1 = max(1, ctx.px(1))
        let w = Float(r.right - r.left), h = Float(r.bottom - r.top)
        var shapes: [PTBPaintShape] = []
        shapes.append(PTBPaintShape(x: 0, y: 0, w: w, h: h, radius: Float(radius), fill: 0, stroke: argb(outer), strokeWidth: Float(w2)))
        if let inner {
            let inset = Float(w2)
            let innerRadius = max(0, Float(radius) - inset)
            shapes.append(PTBPaintShape(x: inset, y: inset, w: w - 2 * inset, h: h - 2 * inset, radius: innerRadius, fill: 0,
                                        stroke: argb(inner), strokeWidth: Float(w1)))
        }
        if bind(dc, r, &shapes) >= 0 { return }
        fallback(dc, r, radius: radius, fill: nil, stroke: Ink(color: outer), strokeWidth: w2, under: outer, ctx: ctx)
    }

    /// `rect` cut to the DC's clip box (what can actually reach the screen: a themed control asks its parent for its background with
    /// WM_PRINTCLIENT, and the paint then covers the whole pane while only the control's rectangle is open); nil when nothing is.
    static func visible(_ dc: HDC, _ rect: RECT) -> RECT? {
        var box = RECT()
        let kind = GetClipBox(dc, &box)
        var out = rect
        if kind >= 2 /* SIMPLEREGION, COMPLEXREGION */ {
            out = RECT(left: max(rect.left, box.left), top: max(rect.top, box.top), right: min(rect.right, box.right), bottom: min(rect.bottom, box.bottom))
        } else if kind == 1 /* NULLREGION */ {
            return nil
        }
        return out.right > out.left && out.bottom > out.top ? out : nil
    }

    /// Whether `a` and `b` overlap (a card outside the dirty rect is not drawn).
    static func intersects(_ a: RECT, _ b: RECT) -> Bool {
        a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
    }

    /// The aliased GDI shape: what every site drew before the painter.
    private static func fallback(_ dc: HDC, _ r: RECT, radius: Int32, fill: Ink?, stroke: Ink?, strokeWidth: Int32, under: COLORREF,
                                 ctx: WinUIContext) {
        if !loggedFallback {
            loggedFallback = true
            AppLog.write("popover kit: the antialiased painter failed (\(String(cString: ptb_plaza_last_error()))); shapes are drawn with GDI")
        }
        func solid(_ i: Ink) -> COLORREF { i.alpha >= 1 ? i.color : WinUIColors.blend(under, i.color, i.alpha) }
        let pen = stroke.flatMap { CreatePen(0 /* PS_SOLID */, strokeWidth, solid($0)) } ?? CreatePen(5 /* PS_NULL */, 0, 0)
        let oldPen = SelectObject(dc, UnsafeMutableRawPointer(pen))
        let face: HBRUSH? = fill.flatMap { ctx.colors.brush(solid($0)) }
        let oldBrush = SelectObject(dc, face.map { UnsafeMutableRawPointer($0) } ?? GetStockObject(5 /* NULL_BRUSH */))
        _ = RoundRect(dc, r.left, r.top, r.right + 1, r.bottom + 1, 2 * radius, 2 * radius)
        _ = SelectObject(dc, oldBrush)
        _ = SelectObject(dc, oldPen)
        if let pen { _ = DeleteObject(UnsafeMutableRawPointer(pen)) }
    }
}
#endif
