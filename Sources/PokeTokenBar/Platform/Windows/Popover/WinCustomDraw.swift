#if os(Windows)
import Foundation
import WinSDK

// Visual polish K3: the popover's native controls, repainted. The controls stay the system's classes (`Button` push, check box
// and push-like radio, `msctls_trackbar32`), so their role, checked state, keyboard handling and accessible names are the
// system's; only the picture is ours, painted from `NM_CUSTOMDRAW` (comctl32 v6). In high contrast nothing here runs: the
// notification is answered with `CDRF_DODEFAULT` and the system draws the control in its own colours.
//
// No timers: hover is `TrackMouseEvent` (Windows says when the pointer leaves), pressed and focus are read from the button's own
// state (`BM_GETSTATE`), and every repaint is asked for by an input event.

/// A radio group's look.
enum WinSegmentStyle: Equatable, Sendable {
    /// One connected track, the selected segment raised (the Mac's segmented picker).
    case segmented
    /// Separate capsule chips (the Mac's `CapsuleTabBar`).
    case chips
}

/// A push button's look (the Mac's `.bordered`, `.borderedProminent` and `.borderless`).
enum WinButtonStyle: Equatable, Sendable {
    case secondary, primary, plain
}

/// A rectangle in device pixels as numbers (shapes are placed at fractional positions).
struct WinFRect: Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    func insetBy(dx: Double, dy: Double) -> WinFRect { WinFRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy) }
}

/// Antialiased rounded shapes for GDI device contexts: the shape's coverage is computed per pixel from its distance field and
/// alpha-blended through a small DIB, so the corners are smooth without GDI+ (no background thread, no startup) and without
/// Direct2D. A local helper until the popover's shared painter (K2) lands; the shapes can move to it then.
enum WinAA {
    /// A filled rounded rectangle (`radius` is clamped to half the shorter side: a capsule or a circle when large).
    static func fillRound(_ dc: HDC, _ rect: WinFRect, radius: Double, color: COLORREF, alpha: Double = 1) {
        paint(dc, rect, radius: radius, stroke: nil, belowY: nil, color: color, alpha: alpha)
    }

    /// The outline of a rounded rectangle, `stroke` pixels thick, inside `rect`. With `belowY` only the part of the outline lower
    /// than that row is drawn (the darker bottom edge of a raised control).
    static func ring(_ dc: HDC, _ rect: WinFRect, radius: Double, stroke: Double, color: COLORREF, alpha: Double = 1, belowY: Double? = nil) {
        paint(dc, rect, radius: radius, stroke: stroke, belowY: belowY, color: color, alpha: alpha)
    }

    private static func paint(_ dc: HDC, _ rect: WinFRect, radius: Double, stroke: Double?, belowY: Double?, color: COLORREF, alpha: Double) {
        guard rect.width > 0, rect.height > 0, alpha > 0 else { return }
        let x0 = Int(rect.minX.rounded(.down)) - 1, y0 = Int(rect.minY.rounded(.down)) - 1
        let w = Int(rect.maxX.rounded(.up)) + 1 - x0, h = Int(rect.maxY.rounded(.up)) + 1 - y0
        guard w > 0, h > 0 else { return }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(w)
        info.bmiHeader.biHeight = -Int32(h)  // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0  // BI_RGB
        guard let mem = CreateCompatibleDC(dc) else { return }
        defer { _ = DeleteDC(mem) }
        var bits: UnsafeMutableRawPointer?
        guard let dib = CreateDIBSection(mem, &info, 0 /* DIB_RGB_COLORS */, &bits, nil, 0), let bits else { return }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(dib)) }
        let old = SelectObject(mem, UnsafeMutableRawPointer(dib))
        defer { _ = SelectObject(mem, old) }

        let pixels = bits.bindMemory(to: UInt32.self, capacity: w * h)
        let cx = rect.midX, cy = rect.midY, hw = rect.width / 2, hh = rect.height / 2
        let r = max(0, min(radius, hw, hh))
        let red = Double(color & 0xFF), green = Double((color >> 8) & 0xFF), blue = Double((color >> 16) & 0xFF)
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        for row in 0..<h {
            let py = Double(y0 + row) + 0.5
            for col in 0..<w {
                let px = Double(x0 + col) + 0.5
                let qx = abs(px - cx) - (hw - r), qy = abs(py - cy) - (hh - r)
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let d = outside + min(max(qx, qy), 0) - r  // signed distance to the shape's edge (negative inside)
                var coverage = clamp(0.5 - d)
                if let stroke { coverage -= clamp(0.5 - d - stroke) }
                if let belowY, py < belowY { coverage = 0 }
                let a = coverage * alpha
                if a <= 0 { pixels[row * w + col] = 0; continue }
                let alpha8 = UInt32((a * 255).rounded())
                let rr = UInt32((red * a).rounded()), gg = UInt32((green * a).rounded()), bb = UInt32((blue * a).rounded())
                pixels[row * w + col] = alpha8 << 24 | rr << 16 | gg << 8 | bb  // premultiplied BGRA
            }
        }
        let blend = BLENDFUNCTION(BlendOp: 0 /* AC_SRC_OVER */, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1 /* AC_SRC_ALPHA */)
        _ = GdiAlphaBlend(dc, Int32(x0), Int32(y0), Int32(w), Int32(h), mem, 0, 0, Int32(w), Int32(h), blend)
    }
}

/// The colours of the custom-drawn controls: Windows 11's control tokens (microsoft-ui-xaml `Common_themeresources_any.xaml`
/// values, alpha-composited over what is behind the control), light and dark. High contrast never gets here.
struct WinLook {
    let palette: WinUIColors.Palette
    let dark: Bool
    /// What is behind the control (the page or the card).
    let bg: COLORREF
    /// Device pixels per DIP.
    let scale: Double

    @MainActor init(_ c: WinControl) {
        palette = c.ctx.colors.palette
        dark = c.ctx.dark
        bg = c.background
        scale = Double(c.ctx.scale)
    }

    /// DIP to device pixels, as a number (shapes are drawn at fractional sizes; strokes are whole device pixels).
    func px(_ dip: Double) -> Double { dip * scale }
    /// A 1 DIP stroke in whole device pixels (never 1.5 px at 150 %): 1 px up to 175 %, 2 px from 200 %.
    var hairlinePx: Double { scale >= 1.9 ? 2 : 1 }

    var ink: COLORREF { dark ? 0x00FF_FFFF : 0 }
    func mix(_ base: COLORREF, _ alpha: Double) -> COLORREF { WinUIColors.blend(base, ink, alpha) }

    /// The segmented control's track, the raised segment, the chip fills.
    var track: COLORREF { mix(bg, dark ? 0.06 : 0.04) }
    var thumb: COLORREF { dark ? WinUIColors.blend(track, 0x00FF_FFFF, 0.10) : 0x00FF_FFFF }
    var hover: Double { dark ? 0.06 : 0.037 }
    var pressed: Double { dark ? 0.042 : 0.024 }
    /// The control's stroke and its darker bottom edge (Windows 11's "elevation" border).
    var stroke: COLORREF { mix(bg, dark ? 0.07 : 0.10) }
    var bottomEdge: COLORREF { mix(bg, dark ? 0.09 : 0.16) }
    /// A switch's off border, a slider's track, a separator.
    var strong: COLORREF { mix(bg, dark ? 0.544 : 0.446) }
    /// A push button's fill at rest, hovered and pressed.
    func buttonFill(hot: Bool, pressed: Bool) -> COLORREF {
        let rest = dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.06) : WinUIColors.blend(bg, 0x00FF_FFFF, 0.70)
        if pressed { return dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.033) : WinUIColors.blend(rest, 0, 0.06) }
        if hot { return dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.084) : WinUIColors.blend(rest, 0, 0.04) }
        return rest
    }
    var accent: COLORREF { palette.accent }
    /// Accent-coloured text (a selected chip): a step darker in light, lighter in dark, as Windows 11's accent text colours, so it
    /// reads on the chip's own accent tint (the plain accent was about 3:1 on it in dark).
    var accentText: COLORREF { dark ? WinUIColors.blend(accent, 0x00FF_FFFF, 0.5) : WinUIColors.blend(accent, 0, 0.25) }
    /// Text on the accent fill: white, or black where the accent is light (Windows 11's dark convention).
    var onAccent: COLORREF {
        func channel(_ v: UInt32) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * channel(accent & 0xFF) + 0.7152 * channel((accent >> 8) & 0xFF) + 0.0722 * channel((accent >> 16) & 0xFF)
        // white needs (1.05 / (l + 0.05)) >= 3 to stay readable on large control text; light accents (dark mode's lifted one) get black
        return (dark ? l > 0.2 : l > 0.45) ? 0 : 0x00FF_FFFF
    }
}

/// The painters, called from the router's `NM_CUSTOMDRAW`.
@MainActor enum WinCustomDraw {
    /// SELFTEST HOOK, not a setting: custom draw answers "do the default" (the guard's fault injection, `popover.customDraw.fault`).
    static var testDisabled = false
    private static let skipDefault: LRESULT = 0x0004  // CDRF_SKIPDEFAULT

    /// What the system sends a button or trackbar, painted here; nil (the system's own drawing) in high contrast and for stages
    /// that need no answer.
    static func handle(_ c: WinControl, _ header: UnsafeMutablePointer<NMHDR>) -> LRESULT? {
        guard !testDisabled, !c.ctx.highContrast, let part = header.pointee.hwndFrom else { return nil }
        return header.withMemoryRebound(to: NMCUSTOMDRAW.self, capacity: 1) { pointer -> LRESULT? in
            let nm = pointer.pointee
            guard let dc = nm.hdc else { return nil }
            switch c.kind {
            case .button, .checkbox, .radioGroup:
                guard nm.dwDrawStage == 0x0001 /* CDDS_PREPAINT */ else { return nil }
                c.customDrawCount += 1
                // The paint rectangle is the whole client area of the button.
                var client = RECT()
                _ = GetClientRect(part, &client)
                paintButtonKinds(c, part, dc, client)
                return skipDefault
            case .trackbar:
                // The whole bar in the first stage: the system's per-part stages (channel, thumb) were not delivered on the runner
                // when asked for, so nothing here depends on them (the thumb's place comes from `TBM_GETTHUMBRECT`).
                guard nm.dwDrawStage == 0x0001 /* CDDS_PREPAINT */ else { return nil }
                c.customDrawCount += 1
                paintTrackbar(c, part, dc)
                return skipDefault
            default:
                return nil
            }
        }
    }

    private static func paintButtonKinds(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT) {
        let look = WinLook(c)
        let state = ButtonState(c, part)
        switch c.kind {
        case .button: paintButton(c, part, dc, client, look, state)
        case .checkbox: paintSwitch(c, part, dc, client, look, state)
        default: c.segmentStyle == .chips ? paintChip(c, part, dc, client, look, state) : paintSegment(c, part, dc, client, look, state)
        }
    }

    private static func paintTrackbar(_ c: WinControl, _ part: HWND, _ dc: HDC) {
        var client = RECT()
        _ = GetClientRect(part, &client)
        let look = WinLook(c)
        fillBackground(c, dc, client)
        paintChannel(c, part, dc, look)
        paintThumb(c, part, dc, nativeThumb(part), look)
    }

    /// The same pictures without `NM_CUSTOMDRAW`: when the system painted a control (`WM_PAINT`, `WM_PRINTCLIENT`) and custom draw
    /// did not run (a class that does not send it in some theme), the subclass paints over the system's picture. The selftest
    /// reports which path ran per class; this one is a safety net, not the design.
    static func paintFallback(_ c: WinControl, _ part: HWND, _ dc: HDC) {
        c.fallbackPaintCount += 1
        var client = RECT()
        _ = GetClientRect(part, &client)
        switch c.kind {
        case .button, .checkbox, .radioGroup:
            paintButtonKinds(c, part, dc, client)
        case .trackbar:
            paintTrackbar(c, part, dc)
        default:
            break
        }
    }

    /// What a button window says about itself right now.
    struct ButtonState {
        var checked: Bool, pressed: Bool, focusRing: Bool, disabled: Bool, hot: Bool

        @MainActor init(_ c: WinControl, _ part: HWND) {
            let bst = WinKit.send(part, 0x00F2 /* BM_GETSTATE */)
            checked = bst & 0x3 == 0x1  // BST_CHECKED
            pressed = bst & 0x4 != 0  // BST_PUSHED
            // `WM_QUERYUISTATE`: UISF_HIDEFOCUS (1) is set until the keyboard is used, as for the system's own focus rectangle.
            focusRing = bst & 0x8 != 0 && WinKit.send(part, 0x0129) & 0x1 == 0  // BST_FOCUS
            disabled = !IsWindowEnabled(part)
            hot = c.hotPart == part
        }
    }

    // MARK: - drawing helpers

    private static func rectD(_ r: RECT) -> WinFRect {
        WinFRect(x: Double(r.left), y: Double(r.top), width: Double(r.right - r.left), height: Double(r.bottom - r.top))
    }

    private static func text(_ dc: HDC, _ s: String, font: HFONT?, color: COLORREF, in rect: RECT, flags: UINT) {
        var box = rect
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        _ = SetTextColor(dc, color)
        _ = WinStr.w(s).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &box, flags | UINT(DT_NOPREFIX)) }
        _ = SelectObject(dc, old)
    }

    /// The focus ring of a custom-drawn control: 2 DIP in the text colour outside, 1 DIP in the page colour inside, so it shows
    /// on any surface (Windows 11's focus visual). `rect` is the outer edge.
    private static func focusRing(_ dc: HDC, _ rect: WinFRect, radius: Double, _ look: WinLook) {
        let outer = max(2, look.px(2)).rounded()
        WinAA.ring(dc, rect, radius: radius, stroke: outer, color: look.dark ? 0x00FF_FFFF : 0)
        WinAA.ring(dc, rect.insetBy(dx: outer, dy: outer), radius: max(0, radius - outer), stroke: look.hairlinePx, color: look.bg)
    }

    private static func fillBackground(_ c: WinControl, _ dc: HDC, _ client: RECT) {
        var r = client
        _ = FillRect(dc, &r, c.ctx.colors.brush(c.background))
    }

    // MARK: - segmented control

    private static func paintSegment(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let n = c.parts.count
        guard let i = c.parts.firstIndex(of: part), n > 0 else { return }
        let r = rectD(client)
        let radius = look.px(6)
        // The track: the whole control's rounded rectangle, drawn here as this segment's slice (the neighbours' sides reach
        // outside the window and are clipped).
        let reach = radius * 2
        let trackRect = WinFRect(x: r.minX - (i > 0 ? reach : 0), y: r.minY, width: r.width + (i > 0 ? reach : 0) + (i < n - 1 ? reach : 0), height: r.height)
        WinAA.fillRound(dc, trackRect, radius: radius, color: look.track)
        let inset = look.px(2)
        let thumb = r.insetBy(dx: inset, dy: inset)
        let thumbRadius = look.px(4)
        var ink = look.palette.text
        if s.checked {
            WinAA.fillRound(dc, thumb, radius: thumbRadius, color: look.thumb)
            WinAA.ring(dc, thumb, radius: thumbRadius, stroke: look.hairlinePx, color: look.stroke)
            WinAA.ring(dc, thumb, radius: thumbRadius, stroke: look.hairlinePx, color: look.bottomEdge, belowY: Double(thumb.maxY) - thumbRadius)
        } else if !s.disabled, s.pressed || s.hot {
            WinAA.fillRound(dc, thumb, radius: thumbRadius, color: look.ink, alpha: s.pressed ? look.pressed : look.hover)
            if s.pressed { ink = look.palette.secondaryText }
        }
        // a thin separator between two unselected neighbours (hidden next to the raised segment)
        if i < n - 1, !s.checked, WinKit.send(c.parts[i + 1], 0x00F0 /* BM_GETCHECK */) != 1 {
            let h = look.px(12)
            WinAA.fillRound(dc, WinFRect(x: r.maxX - look.hairlinePx, y: r.midY - h / 2, width: look.hairlinePx, height: h), radius: 0, color: look.strong, alpha: 0.5)
        }
        if s.disabled { ink = look.palette.disabled }
        text(dc, WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: c.font, color: ink,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, r.insetBy(dx: 0, dy: 0), radius: look.px(5), look) }
    }

    // MARK: - capsule chips

    private static func paintChip(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        guard let i = c.parts.firstIndex(of: part) else { return }
        let r = rectD(client)
        let radius = r.height / 2
        var fill = s.checked ? WinUIColors.blend(look.bg, look.accent, 0.15) : look.mix(look.bg, 0.05)
        if !s.disabled, s.pressed || s.hot {
            fill = WinUIColors.blend(fill, look.ink, s.pressed ? 0.06 : 0.03)
        }
        WinAA.fillRound(dc, r, radius: radius, color: fill)
        var ink = s.checked ? look.accentText : look.palette.secondaryText
        if s.disabled { ink = look.palette.disabled }
        let mark = c.chipMarks.indices.contains(i) && c.chipMarks[i] ? "\u{25CF} " : ""
        text(dc, mark + WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: s.checked ? (c.boldFont ?? c.font) : c.font, color: ink,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, r, radius: radius, look) }
    }

    // MARK: - push buttons

    private static func paintButton(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let r = rectD(client).insetBy(dx: 0, dy: 0)
        let radius = look.px(4)
        var ink = look.palette.text
        switch c.buttonStyle {
        case .secondary:
            WinAA.fillRound(dc, r, radius: radius, color: look.buttonFill(hot: s.hot && !s.disabled, pressed: s.pressed && !s.disabled))
            WinAA.ring(dc, r, radius: radius, stroke: look.hairlinePx, color: look.stroke)
            if !s.disabled { WinAA.ring(dc, r, radius: radius, stroke: look.hairlinePx, color: look.bottomEdge, belowY: Double(r.maxY) - radius) }
            if s.pressed, !s.disabled { ink = look.palette.secondaryText }
        case .primary:
            var fill = look.accent
            ink = look.onAccent
            if s.disabled {
                fill = look.mix(look.bg, look.dark ? 0.158 : 0.217)
                ink = look.dark ? look.palette.disabled : 0x00FF_FFFF
            } else if s.pressed {
                fill = WinUIColors.blend(look.bg, look.accent, 0.8)
                ink = WinUIColors.blend(fill, ink, 0.7)
            } else if s.hot {
                fill = WinUIColors.blend(look.bg, look.accent, 0.9)
            }
            WinAA.fillRound(dc, r, radius: radius, color: fill)
            if !s.disabled { WinAA.ring(dc, r, radius: radius, stroke: look.hairlinePx, color: WinUIColors.blend(fill, 0, 0.2), belowY: Double(r.maxY) - radius) }
        case .plain:
            if !s.disabled, s.pressed || s.hot { WinAA.fillRound(dc, r, radius: radius, color: look.ink, alpha: s.pressed ? look.pressed : look.hover) }
        }
        if s.disabled { ink = look.palette.disabled }
        text(dc, WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: c.font, color: ink,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, r, radius: radius + look.px(1), look) }
    }

    // MARK: - switch

    /// The switch the check box is drawn as: the label at the left, a 40 x 20 DIP track at the right.
    static func switchTrack(in client: RECT, _ look: WinLook) -> WinFRect {
        let w = look.px(40), h = look.px(20)
        let r = rectD(client)
        let right = r.maxX - look.px(3)  // room for the focus ring
        return WinFRect(x: right - w, y: (r.midY - h / 2).rounded(), width: w, height: h)
    }

    private static func paintSwitch(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let track = switchTrack(in: client, look)
        let on = WinKit.send(part, 0x00F0 /* BM_GETCHECK */) == 1
        let radius = track.height / 2
        let knobDiameter = look.px(s.pressed ? 14 : (s.hot ? 14 : 12))
        let knobWidth = s.pressed ? look.px(17) : knobDiameter
        let margin = look.px(4)
        var knobColor: COLORREF
        if on {
            var fill = look.accent
            knobColor = look.onAccent
            if s.disabled {
                fill = look.mix(look.bg, look.dark ? 0.158 : 0.217)
                knobColor = look.dark ? look.palette.disabled : 0x00FF_FFFF
            } else if s.hot || s.pressed {
                fill = WinUIColors.blend(look.bg, look.accent, 0.9)
            }
            WinAA.fillRound(dc, track, radius: radius, color: fill)
        } else {
            let border = s.disabled ? look.palette.disabled : look.strong
            WinAA.fillRound(dc, track, radius: radius, color: look.mix(look.bg, s.hot && !s.disabled ? 0.058 : 0.024))
            WinAA.ring(dc, track, radius: radius, stroke: look.hairlinePx, color: border)
            knobColor = border
        }
        let knobX = on ? track.maxX - margin - knobWidth - (look.px(12) - knobDiameter) / 2 : track.minX + margin + (look.px(12) - knobDiameter) / 2
        let knob = WinFRect(x: knobX, y: track.midY - knobDiameter / 2, width: knobWidth, height: knobDiameter)
        WinAA.fillRound(dc, knob, radius: knobDiameter / 2, color: knobColor)
        // the label, left of the switch (wraps within the row's height, cut with an ellipsis)
        var box = client
        box.right = Int32(track.minX.rounded()) - Int32(look.px(12))
        guard box.right > box.left else { return }
        let label = WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&")
        let ink = s.disabled ? look.palette.disabled : look.palette.text
        let oneLine = c.ctx.measure(label, font: c.font).cx <= box.right - box.left
        if oneLine {
            text(dc, label, font: c.font, color: ink, in: box, flags: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        } else {
            let wrapped = c.ctx.measure(label, font: c.font, width: box.right - box.left)
            let height = min(wrapped.cy, client.bottom - client.top)
            box.top = max(client.top, (client.top + client.bottom - height) / 2)
            box.bottom = box.top + height
            text(dc, label, font: c.font, color: ink, in: box, flags: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_END_ELLIPSIS))
        }
        if s.focusRing { focusRing(dc, track.insetBy(dx: -look.px(3), dy: -look.px(3)), radius: radius + look.px(3), look) }
    }

    // MARK: - slider

    /// The thumb's rectangle as the system reports it, in the bar's client pixels.
    private static func nativeThumb(_ part: HWND) -> RECT {
        var r = RECT()
        _ = withUnsafeMutablePointer(to: &r) { WinKit.send(part, 0x0419 /* TBM_GETTHUMBRECT */, 0, Int(bitPattern: $0)) }
        return r
    }

    private static func paintChannel(_ c: WinControl, _ part: HWND, _ dc: HDC, _ look: WinLook) {
        var client = RECT()
        _ = GetClientRect(part, &client)
        let disabled = !IsWindowEnabled(part)
        let thumb = nativeThumb(part)
        let height = look.px(4)
        let edge = look.px(5)  // the bar's window reaches this far past the track's row (see `WinControl.frame`)
        let r = rectD(client)
        let track = WinFRect(x: r.minX + edge, y: (r.midY - height / 2).rounded(), width: r.width - 2 * edge, height: height)
        WinAA.fillRound(dc, track, radius: height / 2, color: disabled ? look.palette.disabled : look.strong)
        let centre = Double(thumb.left + thumb.right) / 2
        if centre > track.minX {
            let filled = WinFRect(x: track.minX, y: track.minY, width: min(track.width, centre - track.minX), height: track.height)
            WinAA.fillRound(dc, filled, radius: height / 2, color: disabled ? look.palette.disabled : look.accent)
        }
    }

    private static func paintThumb(_ c: WinControl, _ part: HWND, _ dc: HDC, _ nativeRect: RECT, _ look: WinLook) {
        var client = RECT()
        _ = GetClientRect(part, &client)
        let disabled = !IsWindowEnabled(part)
        let focused = GetFocus() == part && WinKit.send(part, 0x0129) & 0x1 == 0
        let dragging = GetCapture() == part
        let hot = c.hotPart == part
        let d = look.px(20)
        let centre = (x: Double(nativeRect.left + nativeRect.right) / 2, y: Double(client.top + client.bottom) / 2)
        let thumb = WinFRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d)
        WinAA.fillRound(dc, thumb, radius: d / 2, color: look.thumb)
        WinAA.ring(dc, thumb, radius: d / 2, stroke: look.hairlinePx, color: look.stroke)
        WinAA.ring(dc, thumb, radius: d / 2, stroke: look.hairlinePx, color: look.bottomEdge, belowY: Double(thumb.midY) + d / 4)
        let dot = look.px(dragging ? 10 : (hot ? 14 : 12))
        WinAA.fillRound(dc, WinFRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot), radius: dot / 2,
                        color: disabled ? look.palette.disabled : look.accent)
        if focused {
            let outer = thumb.insetBy(dx: -look.px(3), dy: -look.px(3))
            focusRing(dc, outer, radius: outer.width / 2, look)
        }
    }
}
#endif
