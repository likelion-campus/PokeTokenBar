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

/// The colours of the custom-drawn controls: Windows 11's control tokens (microsoft-ui-xaml `Common_themeresources_any.xaml`
/// values, alpha-composited over what is behind the control), light and dark. High contrast never gets here.
struct WinLook {
    let ctx: WinUIContext
    let palette: WinUIColors.Palette
    let dark: Bool
    /// What is behind the control (the page or the card).
    let bg: COLORREF
    /// Device pixels per DIP.
    let scale: Double

    @MainActor init(_ c: WinControl) {
        ctx = c.ctx
        palette = c.ctx.colors.palette
        dark = c.ctx.dark
        bg = c.background
        scale = Double(c.ctx.scale)
    }

    /// DIP to device pixels, as a number (shapes are drawn at fractional sizes; strokes are whole device pixels).
    func px(_ dip: Double) -> Double { dip * scale }
    /// DIP to whole device pixels.
    func ipx(_ dip: Double) -> Int32 { Int32((dip * scale).rounded()) }
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
    /// Dark: white 30 % over the card is about 2.7:1 against it (Windows' own 7 % was nearly invisible on a card); light: black 12 %.
    var stroke: COLORREF { mix(bg, dark ? 0.30 : 0.12) }
    var bottomEdge: COLORREF { mix(bg, dark ? 0.36 : 0.20) }
    /// A switch's off border, a slider's track, a separator.
    var strong: COLORREF { mix(bg, dark ? 0.544 : 0.446) }
    /// A push button's fill at rest, hovered and pressed.
    func buttonFill(hot: Bool, pressed: Bool) -> COLORREF {
        let rest = dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.09) : WinUIColors.blend(bg, 0x00FF_FFFF, 0.70)
        if pressed { return dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.05) : WinUIColors.blend(rest, 0, 0.06) }
        if hot { return dark ? WinUIColors.blend(bg, 0x00FF_FFFF, 0.13) : WinUIColors.blend(rest, 0, 0.04) }
        return rest
    }
    var accent: COLORREF { palette.accent }
    /// Accent-coloured text (a selected chip): a step darker in light, lighter in dark, as Windows 11's accent text colours, so it
    /// reads on the chip's own accent tint (the plain accent was about 3:1 on it in dark).
    var accentText: COLORREF { dark ? WinUIColors.blend(accent, 0x00FF_FFFF, 0.5) : WinUIColors.blend(accent, 0, 0.25) }
    /// A selected chip's text: the accent text colour, moved further if the chip's current fill (hover and press tint it) leaves it under 3:1.
    func chipInk(fill: COLORREF) -> COLORREF { ctx.colors.legible(accentText, over: fill) }
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

    /// SELFTEST HOOK: paint straight on the window's DC, as before the flicker fix (the check that must fail on it).
    nonisolated(unsafe) static var testUnbuffered = false
    /// Whole control pictures copied to the screen in one blit (the selftest compares it with the paints).
    private(set) static var blits = 0

    /// A control is drawn in several steps (the page colour, the track, the raised segment, the text, the ring). On the window's own DC each
    /// step is on the screen the moment it is made, so a repaint under the pointer flashed the page colour and the bare track before the
    /// segment came back. The picture is made on a memory bitmap and copied in one blit, so the screen only ever shows a finished one.
    static func buffered(_ dc: HDC, _ client: RECT, _ body: (HDC) -> Void) {
        let w = client.right - client.left, h = client.bottom - client.top
        guard !testUnbuffered, w > 0, h > 0, let mem = CreateCompatibleDC(dc) else { body(dc); return }
        defer { _ = DeleteDC(mem) }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = client.right
        info.bmiHeader.biHeight = -client.bottom
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        var bits: UnsafeMutableRawPointer?
        guard let bitmap = CreateDIBSection(dc, &info, 0, &bits, nil, 0), bits != nil else { body(dc); return }
        defer { _ = DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        let old = SelectObject(mem, UnsafeMutableRawPointer(bitmap))
        defer { _ = SelectObject(mem, old) }
        body(mem)
        _ = BitBlt(dc, client.left, client.top, w, h, mem, client.left, client.top, DWORD(SRCCOPY))
        blits += 1
    }

    private static func paintButtonKinds(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT) {
        buffered(dc, client) { paintButtonKindsNow(c, part, $0, client) }
    }

    private static func paintButtonKindsNow(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT) {
        let look = WinLook(c)
        let state = ButtonState(c, part)
        switch c.kind {
        case .button: paintButton(c, part, dc, client, look, state)
        case .checkbox: paintSwitch(c, part, dc, client, look, state)
        default: c.segmentStyle == .chips ? paintChip(c, part, dc, client, look, state) : paintSegment(c, part, dc, client, look, state)
        }
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
            pressed = bst & 0x4 != 0 || c.isForced(part, c.testPressed)  // BST_PUSHED
            // `WM_QUERYUISTATE`: UISF_HIDEFOCUS (1) is set until the keyboard is used, as for the system's own focus rectangle.
            focusRing = bst & 0x8 != 0 && WinKit.send(part, 0x0129) & 0x1 == 0 || c.isForced(part, c.testFocus)  // BST_FOCUS
            disabled = !IsWindowEnabled(part)
            hot = c.hotPart == part || c.isForced(part, c.testHot)
        }
    }

    // MARK: - drawing helpers

    private static func ink(_ color: COLORREF, _ alpha: Double = 1) -> WinPaint.Ink { WinPaint.Ink(color: color, alpha: alpha) }

    /// One bind of the painter for a control's shapes, kept inside `client` (a segment's track reaches past its window).
    private static func shapes(_ dc: HDC, _ items: [WinPaint.Item], _ look: WinLook, _ client: RECT) {
        WinPaint.roundedRects(dc, items, under: look.bg, ctx: look.ctx, clip: client)
    }

    private static func inset(_ r: RECT, _ d: Int32) -> RECT { RECT(left: r.left + d, top: r.top + d, right: r.right - d, bottom: r.bottom - d) }

    private static func text(_ dc: HDC, _ s: String, font: HFONT?, color: COLORREF, in rect: RECT, flags: UINT) {
        var box = rect
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        _ = SetTextColor(dc, color)
        _ = WinStr.w(s).withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &box, flags | UINT(DT_NOPREFIX)) }
        _ = SelectObject(dc, old)
    }

    /// The focus ring (K2's painter: 2 DIP outer in the text colour, 1 DIP inner in the page colour inside it), drawn inside `rect`.
    private static func focusRing(_ dc: HDC, _ rect: RECT, radius: Int32, _ look: WinLook) {
        WinPaint.focusRing(dc, rect, radius: radius, ctx: look.ctx, outer: look.dark ? 0x00FF_FFFF : 0,
                           inner: rect.bottom - rect.top >= look.ipx(20) ? look.bg : nil)
    }

    private static func fillBackground(_ c: WinControl, _ dc: HDC, _ client: RECT) {
        var r = client
        _ = FillRect(dc, &r, c.ctx.colors.brush(c.background))
    }

    /// A raised surface: `body` over a band of the bottom-edge colour one hairline lower (Windows 11's darker bottom edge), with the stroke.
    private static func raised(_ r: RECT, radius: Int32, fill: COLORREF, edge: COLORREF, stroke: COLORREF?, _ look: WinLook) -> [WinPaint.Item] {
        let band = Int32(look.hairlinePx)
        let body = RECT(left: r.left, top: r.top, right: r.right, bottom: r.bottom - band)
        let under = RECT(left: r.left, top: r.top + band, right: r.right, bottom: r.bottom)
        return [WinPaint.Item(rect: under, radius: radius, fill: ink(edge), stroke: nil),
                WinPaint.Item(rect: body, radius: radius, fill: ink(fill), stroke: stroke.map { ink($0) }, strokeWidth: Int32(look.hairlinePx))]
    }

    // MARK: - segmented control

    private static func paintSegment(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let n = c.parts.count
        guard let i = c.parts.firstIndex(of: part), n > 0 else { return }
        let radius = look.ipx(6)
        // The track: the whole control's rounded rectangle, drawn as this segment's slice (the neighbours' sides reach outside the
        // window and are clipped).
        let reach = radius * 2
        let trackRect = RECT(left: client.left - (i > 0 ? reach : 0), top: client.top, right: client.right + (i < n - 1 ? reach : 0), bottom: client.bottom)
        var list = [WinPaint.Item(rect: trackRect, radius: radius, fill: ink(look.track), stroke: nil)]
        let thumb = inset(client, look.ipx(2))
        let thumbRadius = look.ipx(4)
        var textInk = look.palette.text
        if s.checked {
            list.append(contentsOf: raised(thumb, radius: thumbRadius, fill: look.thumb, edge: look.bottomEdge, stroke: look.stroke, look))
        } else if !s.disabled, s.pressed || s.hot {
            list.append(WinPaint.Item(rect: thumb, radius: thumbRadius, fill: ink(look.ink, s.pressed ? look.pressed : look.hover), stroke: nil))
            if s.pressed { textInk = look.palette.secondaryText }
        }
        // a thin separator between two unselected neighbours (hidden next to the raised segment)
        if i < n - 1, !s.checked, WinKit.send(c.parts[i + 1], 0x00F0 /* BM_GETCHECK */) != 1 {
            let h = look.ipx(12), w = Int32(look.hairlinePx), mid = (client.top + client.bottom) / 2
            list.append(WinPaint.Item(rect: RECT(left: client.right - w, top: mid - h / 2, right: client.right, bottom: mid - h / 2 + h), radius: 0,
                                      fill: ink(look.strong, 0.5), stroke: nil))
        }
        shapes(dc, list, look, client)
        if s.disabled { textInk = look.palette.disabled }
        text(dc, WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: c.font, color: textInk,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, inset(client, look.ipx(1)), radius: look.ipx(5), look) }
    }

    // MARK: - capsule chips

    private static func paintChip(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        guard let i = c.parts.firstIndex(of: part) else { return }
        let radius = (client.bottom - client.top) / 2
        var fill = s.checked ? WinUIColors.blend(look.bg, look.accent, 0.15) : look.mix(look.bg, 0.05)
        if !s.disabled, s.pressed || s.hot { fill = WinUIColors.blend(fill, look.ink, s.pressed ? 0.06 : 0.03) }
        shapes(dc, [WinPaint.Item(rect: client, radius: radius, fill: ink(fill), stroke: nil)], look, client)
        var textInk = s.checked ? look.chipInk(fill: fill) : look.palette.secondaryText
        if s.disabled { textInk = look.palette.disabled }
        let mark = c.chipMarks.indices.contains(i) && c.chipMarks[i] ? "\u{25CF} " : ""
        text(dc, mark + WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: s.checked ? (c.boldFont ?? c.font) : c.font, color: textInk,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, client, radius: radius, look) }
    }

    // MARK: - push buttons

    private static func paintButton(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let radius = look.ipx(4)
        var textInk = look.palette.text
        var list: [WinPaint.Item] = []
        switch c.buttonStyle {
        case .secondary:
            let fill = look.buttonFill(hot: s.hot && !s.disabled, pressed: s.pressed && !s.disabled)
            if s.disabled {
                list = [WinPaint.Item(rect: client, radius: radius, fill: ink(fill), stroke: ink(look.stroke), strokeWidth: Int32(look.hairlinePx))]
            } else {
                list = raised(client, radius: radius, fill: fill, edge: look.bottomEdge, stroke: look.stroke, look)
            }
            if s.pressed, !s.disabled { textInk = look.palette.secondaryText }
        case .primary:
            var fill = look.accent
            textInk = look.onAccent
            if s.disabled {
                fill = look.mix(look.bg, look.dark ? 0.158 : 0.217)
                textInk = look.dark ? look.palette.disabled : 0x00FF_FFFF
                list = [WinPaint.Item(rect: client, radius: radius, fill: ink(fill), stroke: nil)]
            } else {
                if s.pressed {
                    fill = WinUIColors.blend(look.bg, look.accent, 0.8)
                    textInk = WinUIColors.blend(fill, textInk, 0.7)
                } else if s.hot {
                    fill = WinUIColors.blend(look.bg, look.accent, 0.9)
                }
                list = raised(client, radius: radius, fill: fill, edge: WinUIColors.blend(fill, 0, 0.25), stroke: nil, look)
            }
        case .plain:
            if !s.disabled, s.pressed || s.hot {
                list = [WinPaint.Item(rect: client, radius: radius, fill: ink(look.ink, s.pressed ? look.pressed : look.hover), stroke: nil)]
            }
        }
        shapes(dc, list, look, client)
        if s.disabled, c.buttonStyle != .primary || !look.dark { textInk = look.palette.disabled }
        text(dc, WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&"), font: c.font, color: textInk,
             in: client, flags: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        if s.focusRing { focusRing(dc, client, radius: radius + look.ipx(1), look) }
    }

    // MARK: - switch

    /// The switch the check box is drawn as: the label at the left, a 40 x 20 DIP track at the right (client pixels).
    static func switchTrack(in client: RECT, _ look: WinLook) -> RECT {
        let w = look.ipx(40), h = look.ipx(20)
        let right = client.right - look.ipx(3)  // room for the focus ring
        let top = (client.top + client.bottom - h) / 2
        return RECT(left: right - w, top: top, right: right, bottom: top + h)
    }

    private static func paintSwitch(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT, _ look: WinLook, _ s: ButtonState) {
        fillBackground(c, dc, client)
        let track = switchTrack(in: client, look)
        let on = WinKit.send(part, 0x00F0 /* BM_GETCHECK */) == 1
        let radius = (track.bottom - track.top) / 2
        let knobH = look.ipx(s.pressed || s.hot ? 14 : 12)
        let knobW = s.pressed ? look.ipx(17) : knobH
        let margin = look.ipx(4) + (look.ipx(12) - knobH) / 2
        let knobColor: COLORREF
        var list: [WinPaint.Item] = []
        if on {
            var fill = look.accent
            var knob = look.onAccent
            if s.disabled {
                fill = look.mix(look.bg, look.dark ? 0.158 : 0.217)
                knob = look.dark ? look.palette.disabled : 0x00FF_FFFF
            } else if s.hot || s.pressed {
                fill = WinUIColors.blend(look.bg, look.accent, 0.9)
            }
            knobColor = knob
            list.append(WinPaint.Item(rect: track, radius: radius, fill: ink(fill), stroke: nil))
        } else {
            let border = s.disabled ? look.palette.disabled : look.strong
            knobColor = border
            list.append(WinPaint.Item(rect: track, radius: radius, fill: ink(look.mix(look.bg, s.hot && !s.disabled ? 0.058 : 0.024)),
                                      stroke: ink(border), strokeWidth: Int32(look.hairlinePx)))
        }
        let knobLeft = on ? track.right - margin - knobW : track.left + margin
        let knobTop = (track.top + track.bottom - knobH) / 2
        list.append(WinPaint.Item(rect: RECT(left: knobLeft, top: knobTop, right: knobLeft + knobW, bottom: knobTop + knobH), radius: knobH / 2, fill: ink(knobColor), stroke: nil))
        shapes(dc, list, look, client)
        // the label, left of the switch (wraps within the row's height, cut with an ellipsis)
        var box = client
        box.right = track.left - look.ipx(12)
        if box.right > box.left {
            let label = WinKit.text(of: part).replacingOccurrences(of: "&&", with: "&")
            let textInk = s.disabled ? look.palette.disabled : look.palette.text
            if c.ctx.measure(label, font: c.font).cx <= box.right - box.left {
                text(dc, label, font: c.font, color: textInk, in: box, flags: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
            } else {
                let wrapped = c.ctx.measure(label, font: c.font, width: box.right - box.left)
                let height = min(wrapped.cy, client.bottom - client.top)
                box.top = max(client.top, (client.top + client.bottom - height) / 2)
                box.bottom = box.top + height
                text(dc, label, font: c.font, color: textInk, in: box, flags: UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_END_ELLIPSIS))
            }
        }
        if s.focusRing {
            let d = look.ipx(3)
            focusRing(dc, RECT(left: track.left - d, top: track.top - d, right: track.right + d, bottom: track.bottom + d), radius: radius + d, look)
        }
    }

    // MARK: - slider

    /// The thumb's rectangle as the system reports it, in the bar's client pixels.
    private static func nativeThumb(_ part: HWND) -> RECT {
        var r = RECT()
        _ = withUnsafeMutablePointer(to: &r) { WinKit.send(part, 0x0419 /* TBM_GETTHUMBRECT */, 0, Int(bitPattern: $0)) }
        return r
    }

    private static func paintTrackbar(_ c: WinControl, _ part: HWND, _ dc: HDC) {
        var client = RECT()
        _ = GetClientRect(part, &client)
        buffered(dc, client) { paintTrackbarNow(c, part, $0, client) }
    }

    private static func paintTrackbarNow(_ c: WinControl, _ part: HWND, _ dc: HDC, _ client: RECT) {
        let look = WinLook(c)
        fillBackground(c, dc, client)
        let disabled = !IsWindowEnabled(part)
        let thumb = nativeThumb(part)
        let focused = (GetFocus() == part && WinKit.send(part, 0x0129) & 0x1 == 0) || c.isForced(part, c.testFocus)
        let dragging = GetCapture() == part || c.isForced(part, c.testPressed)
        let hot = c.hotPart == part || c.isForced(part, c.testHot)
        let h = look.ipx(4), edge = look.ipx(5)  // the bar's window reaches 5 DIP past the track's row (see `WinControl.frame`)
        let midY = (client.top + client.bottom) / 2
        let track = RECT(left: client.left + edge, top: midY - h / 2, right: client.right - edge, bottom: midY - h / 2 + h)
        let centreX = (thumb.left + thumb.right) / 2
        let d = look.ipx(20)
        let thumbRect = RECT(left: centreX - d / 2, top: midY - d / 2, right: centreX - d / 2 + d, bottom: midY - d / 2 + d)
        let dot = look.ipx(dragging ? 10 : (hot ? 14 : 12))
        let dotRect = RECT(left: centreX - dot / 2, top: midY - dot / 2, right: centreX - dot / 2 + dot, bottom: midY - dot / 2 + dot)
        var list = [WinPaint.Item(rect: track, radius: h / 2, fill: ink(disabled ? look.palette.disabled : look.strong), stroke: nil)]
        if centreX > track.left {
            list.append(WinPaint.Item(rect: RECT(left: track.left, top: track.top, right: min(track.right, centreX), bottom: track.bottom), radius: h / 2,
                                      fill: ink(disabled ? look.palette.disabled : look.accent), stroke: nil))
        }
        list.append(contentsOf: raised(thumbRect, radius: d / 2, fill: look.thumb, edge: look.bottomEdge, stroke: look.stroke, look))
        list.append(WinPaint.Item(rect: dotRect, radius: dot / 2, fill: ink(disabled ? look.palette.disabled : look.accent), stroke: nil))
        shapes(dc, list, look, client)
        if focused {
            let g = look.ipx(3)
            focusRing(dc, RECT(left: thumbRect.left - g, top: thumbRect.top - g, right: thumbRect.right + g, bottom: thumbRect.bottom + g), radius: d / 2 + g, look)
        }
    }
}
#endif
