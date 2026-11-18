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

    /// 0xAARRGGBB of a `COLORREF` (0x00BBGGRR).
    nonisolated static func argb(_ c: COLORREF, alpha: Double = 1) -> UInt32 {
        let a = UInt32((min(1, max(0, alpha)) * 255).rounded())
        return a << 24 | (c & 0xFF) << 16 | (c & 0xFF00) | (c >> 16) & 0xFF
    }

    /// A rounded rectangle over `r` (right and bottom exclusive): `fill`, then `stroke` inside the edge. `under` is the colour
    /// the shape is laid over, used only when the antialiased painter is unavailable.
    static func roundedRect(_ dc: HDC, _ r: RECT, radius: Int32, fill: Ink?, stroke: Ink? = nil, strokeWidth: Int32 = 1,
                            under: COLORREF, ctx: WinUIContext) {
        guard r.right > r.left, r.bottom > r.top else { return }
        var shape = PTBPaintShape(x: 0, y: 0, w: Float(r.right - r.left), h: Float(r.bottom - r.top), radius: Float(radius),
                                  fill: fill.map { argb($0.color, alpha: $0.alpha) } ?? 0,
                                  stroke: stroke.map { argb($0.color, alpha: $0.alpha) } ?? 0,
                                  strokeWidth: stroke == nil ? 0 : Float(strokeWidth))
        if ptb_paint_shapes(UnsafeMutableRawPointer(dc), r.left, r.top, r.right, r.bottom, &shape, 1) >= 0 { return }
        fallback(dc, r, radius: radius, fill: fill, stroke: stroke, strokeWidth: strokeWidth, under: under, ctx: ctx)
    }

    /// The focus ring (Windows 11): 2 DIP outer in `outer`, rounded, then (when `inner` is set) 1 DIP inside it in `inner`, drawn
    /// inside `r`. A control that is too small for both gives `inner` nil.
    static func focusRing(_ dc: HDC, _ r: RECT, radius: Int32, ctx: WinUIContext, outer: COLORREF, inner: COLORREF?) {
        guard r.right > r.left, r.bottom > r.top else { return }
        let w2 = max(2, ctx.px(2)), w1 = max(1, ctx.px(1))
        let w = Float(r.right - r.left), h = Float(r.bottom - r.top)
        var shapes = [PTBPaintShape(x: 0, y: 0, w: w, h: h, radius: Float(radius), fill: 0, stroke: argb(outer), strokeWidth: Float(w2))]
        if let inner {
            let inset = Float(w2)
            shapes.append(PTBPaintShape(x: inset, y: inset, w: w - 2 * inset, h: h - 2 * inset, radius: max(0, Float(radius) - inset), fill: 0,
                                        stroke: argb(inner), strokeWidth: Float(w1)))
        }
        if ptb_paint_shapes(UnsafeMutableRawPointer(dc), r.left, r.top, r.right, r.bottom, &shapes, UInt32(shapes.count)) >= 0 { return }
        fallback(dc, r, radius: radius, fill: nil, stroke: Ink(color: outer), strokeWidth: w2, under: outer, ctx: ctx)
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
