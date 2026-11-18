#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Visual polish K2: the antialiased painter (`ui.kit.paint`) and the focus ring (`ui.kit.focusRing`), judged by pixels read back
/// from a memory DC. Each check carries its own negative control: the same shape drawn the way the kit drew it before (GDI's
/// `RoundRect`, `DrawFocusRect`) is measured with the same measure and must FAIL it, so the check cannot pass on an aliased shape
/// (the fault injection of the rule "a new guard is shown to fail once", built into the run). Windows selftest only.
@MainActor enum WindowsSelftestPopoverPaint {
    /// A top-down 32-bit memory DC filled with `background`.
    private final class Canvas {
        let width: Int, height: Int
        let dc: HDC
        private let bitmap: HBITMAP
        private let old: HGDIOBJ?
        private let bits: UnsafeMutableRawPointer

        init?(_ width: Int, _ height: Int, background: COLORREF) {
            var info = BITMAPINFO()
            info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            info.bmiHeader.biWidth = Int32(width)
            info.bmiHeader.biHeight = -Int32(height)
            info.bmiHeader.biPlanes = 1
            info.bmiHeader.biBitCount = 32
            guard let dc = CreateCompatibleDC(nil) else { return nil }
            var pixels: UnsafeMutableRawPointer?
            guard let bitmap = CreateDIBSection(dc, &info, 0, &pixels, nil, 0), let pixels else { _ = DeleteDC(dc); return nil }
            self.width = width
            self.height = height
            self.dc = dc
            self.bitmap = bitmap
            self.bits = pixels
            old = SelectObject(dc, UnsafeMutableRawPointer(bitmap))
            let brush = CreateSolidBrush(background)
            var r = RECT(left: 0, top: 0, right: Int32(width), bottom: Int32(height))
            _ = FillRect(dc, &r, brush)
            if let brush { _ = DeleteObject(UnsafeMutableRawPointer(brush)) }
        }

        deinit {
            _ = SelectObject(dc, old)
            _ = DeleteObject(UnsafeMutableRawPointer(bitmap))
            _ = DeleteDC(dc)
        }

        /// The pixel as a `COLORREF` (0x00BBGGRR).
        func pixel(_ x: Int, _ y: Int) -> COLORREF {
            _ = GdiFlush()
            let p = bits.assumingMemoryBound(to: UInt8.self)
            let i = (y * width + x) * 4
            return COLORREF(p[i + 2]) | COLORREF(p[i + 1]) << 8 | COLORREF(p[i]) << 16
        }
    }

    /// Pixels in the `size` x `size` corner box at (`x0`, `y0`) that are none of `known`: the antialiased edge. A shape without
    /// antialiasing has none.
    private static func intermediate(_ c: Canvas, x0: Int, y0: Int, size: Int, known: Set<COLORREF>) -> Int {
        var n = 0
        for y in y0..<(y0 + size) {
            for x in x0..<(x0 + size) where !known.contains(c.pixel(x, y)) { n += 1 }
        }
        return n
    }

    /// GDI's classic filled rounded rectangle (what every site drew before the painter): the negative control.
    private static func gdiRoundRect(_ c: Canvas, _ r: RECT, radius: Int32, fill: COLORREF) {
        let pen = CreatePen(5 /* PS_NULL */, 0, 0)
        let brush = CreateSolidBrush(fill)
        let oldPen = SelectObject(c.dc, UnsafeMutableRawPointer(pen))
        let oldBrush = SelectObject(c.dc, UnsafeMutableRawPointer(brush))
        _ = RoundRect(c.dc, r.left, r.top, r.right + 1, r.bottom + 1, 2 * radius, 2 * radius)
        _ = SelectObject(c.dc, oldBrush)
        _ = SelectObject(c.dc, oldPen)
        if let pen { _ = DeleteObject(UnsafeMutableRawPointer(pen)) }
        if let brush { _ = DeleteObject(UnsafeMutableRawPointer(brush)) }
    }

    static func run(_ r: WindowsSelftest.Recorder, _ w: KitWindow) {
        paintCheck(r, w)
        focusRingCheck(r, w)
    }

    private static func paintCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow) {
        let ctx = w.ctx
        let white: COLORREF = 0x00FF_FFFF, ink: COLORREF = 0x0040_2010, edge: COLORREF = 0x0000_00C0
        let size = 48, radius: Int32 = 12
        guard let c = Canvas(size, size, background: white), let control = Canvas(size, size, background: white), let hairline = Canvas(size, size, background: white),
              let alpha = Canvas(size, size, background: white) else {
            r.add("ui.kit.paint", false, "no memory DC")
            return
        }
        let box = RECT(left: 0, top: 0, right: Int32(size), bottom: Int32(size))
        WinPaint.roundedRect(c.dc, box, radius: radius, fill: WinPaint.Ink(color: ink), under: white, ctx: ctx)
        gdiRoundRect(control, box, radius: radius, fill: ink)
        let known: Set<COLORREF> = [white, ink]
        let mid = intermediate(c, x0: 0, y0: 0, size: Int(radius), known: known)
        let midControl = intermediate(control, x0: 0, y0: 0, size: Int(radius), known: known)
        let cornerOutside = c.pixel(0, 0) == white, centre = c.pixel(size / 2, size / 2) == ink
        // a one-pixel stroke on whole pixels is crisp: the edge pixel is the stroke colour, the next one the fill
        WinPaint.roundedRect(hairline.dc, box, radius: radius, fill: WinPaint.Ink(color: ink), stroke: WinPaint.Ink(color: edge), strokeWidth: 1, under: white, ctx: ctx)
        let crisp = hairline.pixel(size / 2, 0) == edge && hairline.pixel(size / 2, 1) == ink && hairline.pixel(0, size / 2) == edge && hairline.pixel(1, size / 2) == ink
        // opacity: 40 % black over white leaves 60 % of 255 at the centre of a shape (the scroll thumb's path)
        WinPaint.roundedRect(alpha.dc, box, radius: radius, fill: WinPaint.Ink(color: 0, alpha: 0.4), under: white, ctx: ctx)
        let g = Int(alpha.pixel(size / 2, size / 2) & 0xFF)
        let blended = abs(g - 153) <= 3
        // the card the kit draws on a page: its corner, read back from the page's own painting (WM_PRINTCLIENT)
        var card = "no card on the page"
        var cardOK = false
        var cardMid = 0
        if let pane = w.scroll?.content.hwnd, let frame = w.stack?.frames?.sections.compactMap({ $0?.card }).first {
            var client = RECT()
            _ = GetClientRect(pane, &client)
            if let page = Canvas(Int(client.right), Int(client.bottom), background: 0x0000_00FF) {
                _ = SendMessageW(pane, 0x0318 /* WM_PRINTCLIENT */, WPARAM(UInt(bitPattern: page.dc)), 0)
                let pal = ctx.colors.palette
                let rad = Int(w.stack?.metrics.cardRadius ?? 8)
                let x0 = Int(frame.minX), y0 = Int(frame.minY)
                cardMid = intermediate(page, x0: x0, y0: y0, size: rad, known: [pal.window, pal.card, pal.cardBorder])
                let inside = page.pixel(x0 + Int(frame.width) / 2, y0 + Int(frame.height) / 2) == pal.card
                cardOK = cardMid >= 3 && inside
                card = "card at (\(x0),\(y0)) radius \(rad): corner pixels that are neither window, card nor border = \(cardMid) (aliased: 0), centre is the card colour=\(inside)"
            }
        }
        // What a bind costs on this machine (informational: the open-cost budget counts frames, and a paint per card was too many):
        // one 330 x 120 card per bind, and eight of them in one bind.
        var timing = "no canvas"
        if let big = Canvas(348, 1100, background: white) {
            let item = { (i: Int) in WinPaint.Item(rect: RECT(left: 8, top: Int32(8 + i * 130), right: 340, bottom: Int32(128 + i * 130)), radius: 8,
                                                  fill: WinPaint.Ink(color: ink), stroke: WinPaint.Ink(color: edge), strokeWidth: 1) }
            let rounds = 30
            let t0 = Date()
            for _ in 0..<rounds { for i in 0..<8 { WinPaint.roundedRects(big.dc, [item(i)], under: white, ctx: ctx) } }
            let separate = Date().timeIntervalSince(t0) * 1000 / Double(rounds)
            let t1 = Date()
            for _ in 0..<rounds { WinPaint.roundedRects(big.dc, (0..<8).map(item), under: white, ctx: ctx) }
            let batched = Date().timeIntervalSince(t1) * 1000 / Double(rounds)
            timing = String(format: "8 cards on a page: %.2f ms as 8 binds, %.2f ms as one bind", separate, batched)
            // the same 8 binds on a window DC (what a WM_PAINT hands out): a read-back of the window's surface would show here
            if let screen = GetDC(w.hwnd) {
                let t2 = Date()
                for _ in 0..<rounds { for i in 0..<8 { WinPaint.roundedRects(screen, [item(i)], under: white, ctx: ctx) } }
                let onWindow = Date().timeIntervalSince(t2) * 1000 / Double(rounds)
                _ = ReleaseDC(w.hwnd, screen)
                _ = InvalidateRect(w.hwnd, nil, true)
                timing += String(format: "; on a window DC %.2f ms as 8 binds", onWindow)
            }
        }
        var drawn: UInt64 = 0, failed: UInt64 = 0
        ptb_paint_stats(&drawn, &failed)
        let ok = mid >= 3 && midControl == 0 && cornerOutside && centre && crisp && blended && cardOK && failed == 0 && drawn > 0
        r.add("ui.kit.paint", ok,
              "painter: radius \(radius) corner box has \(mid) antialiased pixels (the same shape through GDI RoundRect, the negative control: \(midControl), must be 0 or the measure is blind), "
              + "pixel (0,0) outside=\(cornerOutside), centre is the fill=\(centre), 1 px stroke crisp on whole pixels=\(crisp), 40 % black over white -> \(g) (expected 153+-3); \(card); "
              + "batches drawn \(drawn) failed \(failed); \(timing)")
    }

    private static func focusRingCheck(_ r: WindowsSelftest.Recorder, _ w: KitWindow) {
        let ctx = w.ctx
        let white: COLORREF = 0x00FF_FFFF, outer: COLORREF = 0x0000_0000, inner: COLORREF = 0x0000_FF00
        let width = 72, height = 36
        guard let c = Canvas(width, height, background: white), let control = Canvas(width, height, background: white) else {
            r.add("ui.kit.focusRing", false, "no memory DC")
            return
        }
        let box = RECT(left: 0, top: 0, right: Int32(width), bottom: Int32(height))
        WinPaint.focusRing(c.dc, box, radius: 4, ctx: ctx, outer: outer, inner: inner)
        let w2 = Int(max(2, ctx.px(2))), w1 = Int(max(1, ctx.px(1)))
        // across the middle of the top edge: the outer rows, then the inner rows, then the page (a solid ring, not dots)
        let x = width / 2
        let outerRows = (0..<w2).allSatisfy { c.pixel(x, $0) == outer }
        let innerRows = (w2..<(w2 + w1)).allSatisfy { c.pixel(x, $0) == inner }
        let after = c.pixel(x, w2 + w1) == white
        // along the top edge the ring has no gaps
        let run = 12..<(width - 12)
        let solid = run.allSatisfy { c.pixel($0, 0) == outer }
        let rounded = intermediate(c, x0: 0, y0: 0, size: 4, known: [white, outer, inner]) >= 1 && c.pixel(0, 0) == white
        // the negative control: DrawFocusRect is dotted (its pixels alternate), so the same measure fails
        var f = RECT(left: 1, top: 1, right: Int32(width - 1), bottom: Int32(height - 1))
        _ = DrawFocusRect(control.dc, &f)
        let dotted = !run.allSatisfy { control.pixel($0, 1) != white }
        let ok = outerRows && innerRows && after && solid && rounded && dotted
        r.add("ui.kit.focusRing", ok,
              "focus ring \(w2) px outer rows=\(outerRows), \(w1) px inner rows=\(innerRows), page colour after=\(after), top edge solid across \(run.count) px=\(solid), "
              + "corner rounded and antialiased=\(rounded); negative control DrawFocusRect is dotted (a gap in its row)=\(dotted)")
    }
}
#endif
