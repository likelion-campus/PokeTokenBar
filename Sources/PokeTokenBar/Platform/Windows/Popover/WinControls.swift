#if os(Windows)
import Foundation
import WinSDK

/// What a text field is (stage 7 D5).
enum WinEditKind: Equatable, Sendable {
    /// One line with a grey cue text when empty; Enter, focus loss and closing the page commit it (the Mac's three commit
    /// points: onSubmit, focus, disappear).
    case text(cue: String?)
    /// A team code: like `text`, and a paste drops every space and line break (a code copied across a chat's line wrap).
    case code(cue: String?)
    /// A session key: `ES_PASSWORD` with the default bullet; the caller clears it after a successful save; never logged.
    case password(cue: String?)
    /// Folders, one per line: Ctrl+Enter makes a new line, Enter commits.
    case multiLine(lines: Int, cue: String?)

    var cue: String? {
        switch self {
        case .text(let c), .code(let c), .password(let c), .multiLine(_, let c): c
        }
    }

    /// What a paste into a code field inserts.
    static func codePaste(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}

/// One native control of the popover (or a radio group, a trackbar with its value, a stepper with its value: several
/// windows that lay out as one). The window text is the accessible name; the kit's subclass gives every control the
/// popover's keys (Enter commits a field or presses a button), reports focus (the scroll area brings it into view) and
/// keeps the wheel for the page over pickers and sliders that are not focused. Main thread only.
@MainActor final class WinControl {
    enum Kind: Equatable, Sendable {
        case label, button, glyphButton, checkbox, radioGroup, combo, edit, trackbar, stepper, link, tabs, drawnItem, drawn
        case progress  // stage 7 Task 14: the marquee beside Save while a key is checked
    }

    let kind: Kind
    let ctx: WinUIContext
    /// The focusable window (a radio group's first button).
    let hwnd: HWND
    /// Every window of the control, `hwnd` first.
    private(set) var parts: [HWND]
    /// The preferred size in pixels at the context's DPI (labels: one line; `size(width:)` wraps).
    var preferredSize: CGSize
    /// What is behind it (the card or the window): the brush its `WM_CTLCOLOR*` answers with.
    var background: COLORREF
    /// Labels: which text colour (D15).
    var role: WinUIColors.Role = .primary
    // --- stage 7 Task 5: a label in a colour of its own (the percent text, a status dot) (begin) ---
    /// Labels: this colour instead of the role's (the Mac's percent colour); high contrast keeps the system's.
    var textColor: COLORREF? {
        didSet { if oldValue != textColor { for part in parts { _ = InvalidateRect(part, nil, true) } } }
    }
    // --- stage 7 Task 5 (end) ---
    fileprivate(set) var font: HFONT?

    // --- stage 7 parity: a wrapping label with the Mac's `lineLimit(n)` (begin) ---
    /// Labels: at most this many lines, the last one cut with an ellipsis (`SS_ENDELLIPSIS` on a wrapping static clips at the height).
    var maxLines: Int?
    // --- stage 7 parity (end) ---
    var onClick: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onValue: ((Int) -> Void)?
    var onCommit: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    /// `drawn` controls lay themselves out.
    var onFrame: ((RECT) -> Void)?
    /// Runs when the control is destroyed, before its windows go (a drawn view frees its picture).
    var onDestroy: (() -> Void)?
    /// The control's preferred size changed by itself (a drawn part's state): its page lays out again (set by the section).
    var onSizeChange: (() -> Void)?
    /// A control whose height follows its width (a drawn part) measures itself at the row's width in pixels during the
    /// page's layout; true when its preferred size changed (the layout then runs its pass again).
    var fitWidth: ((Int32) -> Bool)?
    /// `drawnItem`: paints the item (the drawn view's picture under it and the focus rectangle).
    var drawItem: ((UnsafeMutablePointer<DRAWITEMSTRUCT>) -> Void)?
    // --- stage 7 Task 12: a drawn item that follows the pointer and the arrow keys (begin) ---
    /// `drawnItem`: the pointer over it (client pixels), nil when it left. The item asks Windows to say when it leaves
    /// (`TrackMouseEvent`) only while it is over it: nothing is tracked while the mouse is elsewhere.
    var onPointer: ((POINT?) -> Void)?
    /// `drawnItem`: a key pressed while it has the focus (a virtual-key code); true when handled (the item then also takes
    /// the arrow keys, which a button hands to the dialog manager otherwise).
    var onKey: ((Int) -> Bool)?
    /// `drawnItem`: the keyboard focus came or went.
    var onFocus: ((Bool) -> Void)?
    /// `drawnItem`: whether Escape is the item's now (a selection to clear); otherwise Escape reaches the popover as usual.
    var claimsEscape: (() -> Bool)?
    // --- stage 7 Task 20: a drawn item's context menu (right click, the menu key, Shift+F10) (begin) ---
    /// `drawnItem`: `WM_CONTEXTMENU` over the item, with the pointer's screen point (nil: from the keyboard); true when handled.
    var onContextMenu: ((POINT?) -> Bool)?
    /// `drawnItem`: the pointing hand over it (the Mac's `DexEntryLink`).
    var showsHandCursor = false
    // --- stage 7 Task 20 (end) ---
    fileprivate var tracking = false
    // --- stage 7 Task 12 (end) ---

    // Kind-specific state.
    fileprivate(set) var editKind: WinEditKind?
    fileprivate(set) var isMarqueeOn = false  // stage 7 Task 14: a marquee bar animating
    fileprivate var lastCommitted = ""
    fileprivate var swallowReturnChar = false
    fileprivate var range: ClosedRange<Int> = 0...0
    fileprivate var step = 1
    fileprivate var format: (Int) -> String = { String($0) }
    fileprivate var currentValue = 0
    fileprivate(set) var glyph: (text: String, isIcon: Bool)?
    /// A pill button (`WinControls.pillButton`): the Mac's borderless, capsule and prominent buttons, drawn by the kit.
    fileprivate(set) var pill: WinPill?
    /// A glyph button's glyph colour instead of the text colour (the footer's orange triangle); high contrast keeps the system's.
    var glyphColor: COLORREF?
    fileprivate var hot = false
    // --- visual polish K3: native controls repainted through NM_CUSTOMDRAW (begin) ---
    /// Radio groups: a connected segmented control (the main tabs, the pickers) or a row of capsule chips (provider tabs).
    var segmentStyle: WinSegmentStyle = .segmented
    /// Segmented groups: fill the row's width (the main tab strip) instead of being as wide as their labels.
    var fillsRow = false
    /// Chips: a marker dot before the title (the Mac's "●" on a tab with news), drawn by the chip, not part of the window text.
    var chipMarks: [Bool] = []
    /// Chips: each chip's width in pixels (they are as wide as their title, 8 DIP apart).
    var chipWidths: [Int32] = []
    /// Chips: the semibold face of the selected chip.
    var boldFont: HFONT?
    /// Push buttons: the look (secondary = the Mac's `.bordered`, primary = `.borderedProminent`, plain = `.borderless`) and the small size.
    var buttonStyle: WinButtonStyle = .secondary
    var isSmallButton = false
    /// The window of this control the pointer is over (one per control: a segment, the thumb's trackbar), nil when it is elsewhere.
    /// Set by `WM_MOUSEMOVE` and cleared by `WM_MOUSELEAVE`: nothing is polled and no timer runs.
    fileprivate(set) var hotPart: HWND?
    // --- visual polish K4: drop-down, stepper, field frame (begin) ---
    /// Drop-downs: the entries of the menu (the old combo box's list), the chosen one, and what is shown instead of the chosen entry.
    fileprivate(set) var items: [String] = []
    fileprivate var comboSel = -1
    fileprivate(set) var comboDisplay: String?
    /// Drop-downs and steppers: the row's label, the first part of the accessible name ("Language: English").
    fileprivate(set) var accessibleLabel: String?
    /// A drop-down that opens a menu of the caller's making (`onClick`), not the item list's.
    var customMenu = false
    /// Drop-downs: the widest the button gets (pixels; 0 = as wide as its entries).
    fileprivate var maxComboWidth: Int32 = 0
    /// Steppers: 1 = the upper half, 2 = the lower (hovered, pressed); 0 = none.
    fileprivate(set) var hotHalf = 0, pressedHalf = 0
    /// Fields: the frame (rounded, hairline, focus ring) is painted in the non-client area.
    fileprivate(set) var framed = false
    fileprivate(set) var menuOpens = 0
    /// Fields: how many times the frame was painted by `WM_NCPAINT` (the selftest proves the wiring).
    var framePaints = 0
    /// SELFTEST HOOK: answers a drop-down's menu instead of opening the system's.
    nonisolated(unsafe) static var testMenu: (([TrayMenuModel.Item?]) -> Int?)?
    // --- visual polish K4 (end) ---
    /// How many times custom draw painted a window of this control (the selftest proves it ran: a control that silently
    /// fell back to the system's drawing shows 0).
    var customDrawCount = 0
    /// How many times the subclass painted over the system's picture because custom draw did not run (a safety net; 0 when it works).
    var fallbackPaintCount = 0
    /// Whether this kind is repainted by `WinCustomDraw` (not in high contrast: the system draws those).
    var usesCustomDraw: Bool {
        switch kind {
        case .button, .checkbox, .radioGroup, .trackbar, .combo, .stepper: true
        default: false
        }
    }
    /// SELFTEST HOOK, not a setting: a state forced onto one window of the control (by part index) so the gallery capture can show
    /// the hover, pressed and focus looks that a capture cannot otherwise reach.
    var testHot: Int?, testPressed: Int?, testFocus: Int?
    func forceState(hot: Int? = nil, pressed: Int? = nil, focus: Int? = nil) {
        testHot = hot; testPressed = pressed; testFocus = focus
        for part in parts { _ = framed ? RedrawWindow(part, nil, nil, UINT(0x0400 | 0x0001)) : InvalidateRect(part, nil, false) }
    }
    /// SELFTEST HOOK: a stepper's halves shown hovered and pressed (1 = upper, 2 = lower).
    func forceHalves(hot: Int, pressed: Int) {
        hotHalf = hot; pressedHalf = pressed
        _ = InvalidateRect(hwnd, nil, false)
    }
    func isForced(_ part: HWND, _ index: Int?) -> Bool { index.map { parts.indices.contains($0) && parts[$0] == part } ?? false }
    /// Whether `part` is painted by `WinCustomDraw` (a slider's value text is an ordinary static).
    func drawsItself(_ part: HWND) -> Bool { usesCustomDraw && (kind != .trackbar || part == hwnd) }
    // --- visual polish K3 (end) ---
    private(set) var isDestroyed = false
    /// Counts the selftest reads.
    fileprivate(set) var commits = 0, clicks = 0

    fileprivate init(kind: Kind, ctx: WinUIContext, parts: [HWND], size: CGSize, background: COLORREF, font: HFONT?) {
        self.kind = kind
        self.ctx = ctx
        hwnd = parts[0]
        self.parts = parts
        preferredSize = size
        self.background = background
        self.font = font
        for part in parts { Self.register(self, part) }
        // Dark mode (Task 16): the common controls' dark visual styles; high contrast keeps the system's own.
        if ctx.dark, let theme = WinDarkMode.themeName(for: kind) {
            for (i, part) in parts.enumerated() {
                _ = i
                WinDarkMode.setTheme(part, theme)
            }
        }
    }

    // MARK: state

    var text: String {
        get { usesMnemonics ? WinKit.plainTitle(WinKit.text(of: hwnd)) : WinKit.text(of: hwnd) }
        set {
            WinKit.setText(hwnd, usesMnemonics ? WinKit.title(newValue) : newValue)
            if kind == .edit { lastCommitted = newValue }
        }
    }

    /// Buttons, check boxes, radio buttons and their accessible names read `&` as an access-key prefix: the kit doubles it.
    var usesMnemonics: Bool {
        switch kind {
        case .button, .glyphButton, .checkbox, .radioGroup, .drawnItem, .combo, .stepper: true
        default: false
        }
    }

    var isOn: Bool {
        get { WinKit.send(hwnd, 0x00F0 /* BM_GETCHECK */) == 1 }
        set { WinKit.send(hwnd, 0x00F1 /* BM_SETCHECK */, newValue ? 1 : 0) }
    }

    var selection: Int {
        get {
            switch kind {
            case .combo: comboSel
            case .tabs: WinKit.send(hwnd, 0x130B /* TCM_GETCURSEL */)
            case .radioGroup: parts.firstIndex { WinKit.send($0, 0x00F0) == 1 } ?? -1
            default: -1
            }
        }
        set {
            switch kind {
            case .combo:
                guard comboSel != newValue else { return }
                comboSel = newValue
                refreshComboText()
            case .tabs: WinKit.send(hwnd, 0x130C /* TCM_SETCURSEL */, newValue)
            case .radioGroup: for (i, part) in parts.enumerated() { WinKit.send(part, 0x00F1, i == newValue ? 1 : 0) }
            default: break
            }
        }
    }

    /// A trackbar's or a stepper's value (snapped to the step, inside the range).
    var value: Int {
        get { currentValue }
        set { applyValue(newValue, notify: false) }
    }

    var isEnabled: Bool {
        get { IsWindowEnabled(hwnd) }
        set { for part in parts { _ = EnableWindow(part, newValue) } }
    }

    /// The hover text (a tooltip tool on every part).
    var tooltip: String? {
        didSet { for part in parts { ctx.tooltips.set(tooltip, for: part, in: GetParent(part)) } }
    }

    /// The label's size wrapped at `width` pixels (other kinds: the preferred size).
    func size(width: Int32) -> CGSize {
        guard kind == .label else { return preferredSize }
        let s = ctx.measure(text, font: font, width: max(1, width))
        if let maxLines { return CGSize(width: CGFloat(s.cx), height: CGFloat(min(s.cy, ctx.lineHeight(font) * Int32(maxLines)))) }
        return CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy))
    }

    // MARK: placement

    func frame(_ r: RECT) {
        if let onFrame { onFrame(r); return }
        let w = r.right - r.left
        switch kind {
        case .radioGroup where !fillsRow && chipWidths.isEmpty:
            // sized to its content at the row's left edge (the Mac's `.fixedSize()` pickers), equal segments
            let total = min(w, Int32(preferredSize.width.rounded(.up)))
            let n = Int32(parts.count)
            for (i, part) in parts.enumerated() {
                WinKit.move(part, RECT(left: r.left + total * Int32(i) / n, top: r.top, right: r.left + total * Int32(i + 1) / n, bottom: r.bottom))
            }
        case .radioGroup where !chipWidths.isEmpty:
            var x = r.left
            for (i, part) in parts.enumerated() {
                WinKit.move(part, RECT(left: x, top: r.top, right: x + chipWidths[i], bottom: r.bottom))
                x += chipWidths[i] + ctx.px(8)
            }
        case .radioGroup:
            let n = Int32(parts.count)
            for (i, part) in parts.enumerated() {
                let x0 = r.left + w * Int32(i) / n, x1 = r.left + w * Int32(i + 1) / n
                WinKit.move(part, RECT(left: x0, top: r.top, right: x1, bottom: r.bottom))
            }
        case .trackbar where parts.count == 2:
            let valueW = Int32(valueWidth), gap = ctx.px(6)
            // The drawn thumb is wider than the system's: the bar's window reaches a little into the gaps on both sides so the
            // thumb at either end is not cut (the system's thumb is about 11 px wide, ours 20 DIP).
            let reach = min(ctx.px(5), gap - 1)
            WinKit.move(parts[0], RECT(left: r.left - reach, top: r.top, right: r.right - valueW - gap + reach, bottom: r.bottom))
            // the value text is one line, centred on the track (a static draws from its top edge)
            let line = ctx.lineHeight(font), top = r.top + max(0, (r.bottom - r.top - line) / 2)
            WinKit.move(parts[1], RECT(left: r.right - valueW, top: top, right: r.right, bottom: top + line))
        case .combo:
            // the button sits at the row's trailing edge, as wide as its entries (the Mac's `.fixedSize()` menu picker); the row gives it
            // the width it asked for, except where the row is narrower
            WinKit.move(hwnd, r)
        default:
            WinKit.move(hwnd, r)
        }
    }

    fileprivate var valueWidth: CGFloat = 0

    /// The selftest reads whether the control is shown.
    var isVisibleForTesting: Bool { IsWindowVisible(hwnd) }

    func setVisible(_ visible: Bool) {
        for part in parts { WinKit.setVisible(part, visible) }
    }

    /// Commits a changed field, then destroys every window of the control (page close: the third commit point, D5).
    func destroy() {
        guard !isDestroyed else { return }
        commitIfChanged()
        isDestroyed = true
        onDestroy?()
        // Every callback goes: a page that captured itself in one would otherwise keep itself alive through its controls.
        onDestroy = nil; onClick = nil; onToggle = nil; onSelect = nil; onValue = nil; onCommit = nil; onChange = nil
        onFrame = nil; drawItem = nil; onSizeChange = nil; fitWidth = nil
        onPointer = nil; onKey = nil; onFocus = nil; claimsEscape = nil; onContextMenu = nil
        format = { String($0) }
        for part in parts {
            ctx.tooltips.set(nil, for: part, in: GetParent(part))
            Self.forget(part)
            _ = DestroyWindow(part)
        }
    }

    // MARK: behaviour

    fileprivate func commit() {
        guard kind == .edit else { return }
        let t = text
        lastCommitted = t
        commits += 1
        onCommit?(t)
    }

    func commitIfChanged() {
        guard kind == .edit, !isDestroyed, text != lastCommitted else { return }
        commit()
    }

    fileprivate func applyValue(_ v: Int, notify: Bool) {
        let snapped = Self.snap(v, range: range, step: step)
        let changed = snapped != currentValue
        currentValue = snapped
        switch kind {
        case .trackbar:
            WinKit.send(parts[0], 0x0405 /* TBM_SETPOS */, 1, snapped)
            if parts.count > 1 { WinKit.setText(parts[1], format(snapped)) }
        case .stepper:
            refreshStepperText()
        default:
            return
        }
        if notify, changed { onValue?(snapped) }
    }

    /// `v` inside `range` on a multiple of `step` from its lower bound.
    nonisolated static func snap(_ v: Int, range: ClosedRange<Int>, step: Int) -> Int {
        let s = max(1, step)
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        let k = ((Double(clamped - range.lowerBound) / Double(s)).rounded())
        return min(range.upperBound, range.lowerBound + Int(k) * s)
    }

    // MARK: the registry (every window of every control, for the routers and the subclass)

    private static var byWindow: [Int: WinControl] = [:]
    static func control(_ hwnd: HWND?) -> WinControl? { hwnd.flatMap { byWindow[Int(bitPattern: $0)] } }
    static var liveCount: Int { Set(byWindow.values.map { ObjectIdentifier($0) }).count }

    private static func register(_ control: WinControl, _ part: HWND) {
        byWindow[Int(bitPattern: part)] = control
        _ = SetWindowSubclass(part, winKitSubclass, 0x5054_4B54, 0)
    }

    fileprivate static func forget(_ part: HWND) {
        guard byWindow.removeValue(forKey: Int(bitPattern: part)) != nil else { return }
        _ = RemoveWindowSubclass(part, winKitSubclass, 0x5054_4B54)
    }

    /// The kit's subclass of every control window. nil = the control's own handling.
    fileprivate static func subclassed(_ bits: Int, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let hwnd = HWND(bitPattern: bits), let c = control(hwnd) else { return nil }
        let isMultiLine: Bool = { if case .multiLine? = c.editKind { return true }; return false }()
        let isCode: Bool = { if case .code? = c.editKind { return true }; return false }()
        let isPassword: Bool = { if case .password? = c.editKind { return true }; return false }()  // stage 7 Task 14
        let ctrlDown = GetKeyState(0x11 /* VK_CONTROL */) < 0
        if message == 0x000F { WinOpenTrace.note(.paint, hwnd) } else if message == 0x0014 { WinOpenTrace.note(.erase, hwnd) }  // settings-open trace
        switch message {
        case 0x0007:  // WM_SETFOCUS: keyboard focus inside a scroll area brings the control into view
            if GetKeyState(0x01 /* VK_LBUTTON */) >= 0 { WinScrollArea.reveal(hwnd) }
            c.onFocus?(true)
            if c.framed { _ = RedrawWindow(hwnd, nil, nil, UINT(0x0400 | 0x0001)) }  // RDW_FRAME | RDW_INVALIDATE: the frame's focus ring
            if c.drawsItself(hwnd) { _ = InvalidateRect(hwnd, nil, false) }  // the focus ring is ours to draw
            return nil
        case 0x0008:  // WM_KILLFOCUS: a field commits when the focus leaves it
            if c.kind == .edit { c.commitIfChanged() }
            c.onFocus?(false)
            if c.framed { _ = RedrawWindow(hwnd, nil, nil, UINT(0x0400 | 0x0001)) }
            if c.drawsItself(hwnd) { _ = InvalidateRect(hwnd, nil, false) }
            return nil
        case 0x0087 where c.onKey != nil:  // stage 7 Task 12: a drawn item that answers the arrow keys
            var code = DefSubclassProc(hwnd, message, wParam, lParam) | 0x0001  // DLGC_WANTARROWS
            if let msg = UnsafePointer<MSG>(bitPattern: Int(lParam)), msg.pointee.message == UINT(WM_KEYDOWN),
               msg.pointee.wParam == WPARAM(VK_RETURN) || (msg.pointee.wParam == WPARAM(VK_ESCAPE) && c.claimsEscape?() == true) { code |= 0x0004 }  // DLGC_WANTALLKEYS
            return code
        case UINT(WM_KEYDOWN) where c.onKey != nil && wParam != WPARAM(VK_RETURN):  // stage 7 Task 12
            return c.onKey?(Int(wParam)) == true ? 0 : nil
        case 0x0020 where c.showsHandCursor && Int(lParam) & 0xFFFF == 1 /* HTCLIENT */:  // WM_SETCURSOR (stage 7 Task 20)
            _ = SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32649 /* IDC_HAND */)))
            return 1
        case 0x007B where c.onContextMenu != nil:  // WM_CONTEXTMENU over a drawn item (stage 7 Task 20)
            let point: POINT? = lParam == -1 ? nil : POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
            return c.onContextMenu?(point) == true ? 0 : nil
        case 0x0200 where c.onPointer != nil:  // WM_MOUSEMOVE over a drawn item (stage 7 Task 12)
            if !c.tracking {
                c.tracking = true
                var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: hwnd, dwHoverTime: 0)
                _ = TrackMouseEvent(&tme)
            }
            c.onPointer?(POINT(x: Int32(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: Int32(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))))
            return nil
        case 0x02A3 where c.onPointer != nil:  // WM_MOUSELEAVE (stage 7 Task 12)
            c.tracking = false
            c.onPointer?(nil)
            return nil
        case 0x0087:  // WM_GETDLGCODE
            guard let msg = UnsafePointer<MSG>(bitPattern: Int(lParam)), msg.pointee.message == UINT(WM_KEYDOWN) else { return nil }
            let key = msg.pointee.wParam
            if isMultiLine, key == WPARAM(VK_TAB) || key == WPARAM(VK_ESCAPE) {
                // A multi-line edit wants every key; in a dialog it then sends WM_NEXTDLGCTL for Tab and posts WM_CLOSE for Esc
                // to its parent pane. Left to the dialog manager, Tab moves on and Esc reaches the window (review finding 2).
                return DefSubclassProc(hwnd, message, wParam, lParam) & ~LRESULT(0x0004 | 0x0002)  // DLGC_WANTALLKEYS | DLGC_WANTTAB
            }
            // Take Enter, so IsDialogMessageW hands it to the control instead of IDOK to the window.
            guard key == WPARAM(VK_RETURN), c.takesReturn, !(isMultiLine && ctrlDown) else { return nil }
            return DefSubclassProc(hwnd, message, wParam, lParam) | 0x0004  // DLGC_WANTALLKEYS
        case UINT(WM_KEYDOWN) where wParam == WPARAM(VK_RETURN) && c.takesReturn && !(isMultiLine && ctrlDown):
            c.swallowReturnChar = true
            if c.kind == .edit { c.commit() } else { WinKit.send(hwnd, 0x00F5 /* BM_CLICK */) }
            return 0
        case UINT(WM_CHAR) where (wParam == 0x0D || wParam == 0x0A) && c.swallowReturnChar:
            c.swallowReturnChar = false
            return 0
        case 0x0302 where isCode:  // WM_PASTE into a code field
            // No text on the clipboard: nothing happens, as on the Mac (Paste is disabled there). The edit's own paste is no
            // fallback: with an empty clipboard it clears the selection too (seen on the runner).
            guard let raw = WinClipboardText.read(), !raw.isEmpty else { return 0 }
            WinKit.send(hwnd, 0x00C2 /* EM_REPLACESEL */, 1, text: WinEditKind.codePaste(raw))
            return 0
        // --- stage 7 Task 14: a paste into a session-key field (begin) ---
        case 0x0302 where isPassword:  // WM_PASTE (Ctrl+V and the edit's own menu)
            // A key copied from the browser often comes with spaces or a line break around it. A single-line edit pastes only
            // up to the first line break ("\nsk-ant-…" would paste nothing): the surrounding white space goes first, as the Mac's
            // `SessionKeyStore.normalize` trims it; what is left in the middle stays for the check to refuse.
            guard let raw = WinClipboardText.read() else { return 0 }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            WinKit.send(hwnd, 0x00C2 /* EM_REPLACESEL */, 1, text: trimmed)
            return 0
        // --- stage 7 Task 14 (end) ---
        case 0x00A1, 0x00A3:  // WM_NCLBUTTONDOWN / DBLCLK: on a scroll bar DefWindowProc runs its tracking loop
            guard wParam == 6 || wParam == 7 else { return nil }  // HTHSCROLL, HTVSCROLL (a multi-line field's own bar)
            WinModalPump.begin("scroll")
            defer { WinModalPump.end("scroll") }
            return DefSubclassProc(hwnd, message, wParam, lParam)
        case 0x007B where c.kind == .edit:  // WM_CONTEXTMENU: the edit's own menu is a modal loop
            WinModalPump.begin("menu")
            defer { WinModalPump.end("menu") }
            return DefSubclassProc(hwnd, message, wParam, lParam)
        case 0x020A where (c.kind == .combo || c.kind == .trackbar) && GetFocus() != hwnd:  // WM_MOUSEWHEEL: the page scrolls
            return SendMessageW(GetParent(hwnd), message, wParam, lParam)
        // --- visual polish K4: a field's frame, a drop-down's Alt+Down, a stepper's halves (begin) ---
        case 0x0083 where c.framed:  // WM_NCCALCSIZE: the frame's padding is the field's non-client area
            let result = DefSubclassProc(hwnd, message, wParam, lParam)
            WinCustomDraw.insetField(c, wParam, lParam)
            return result
        case 0x0085 where c.framed && !WinCustomDraw.testDisabled:  // WM_NCPAINT
            WinCustomDraw.paintFieldFrame(c, hwnd, wParam)
            return 0
        case 0x0104 where c.kind == .combo && wParam == WPARAM(VK_DOWN):  // WM_SYSKEYDOWN: Alt+Down opens
            c.openMenu()
            return 0
        case 0x0201 where c.kind == .stepper:  // WM_LBUTTONDOWN
            _ = SetFocus(hwnd)
            _ = SetCapture(hwnd)
            c.pressedHalf = c.half(at: lParam)
            c.stepHalf(c.pressedHalf)
            _ = InvalidateRect(hwnd, nil, false)
            return 0
        case 0x0202 where c.kind == .stepper:  // WM_LBUTTONUP
            if GetCapture() == hwnd { _ = ReleaseCapture() }
            c.pressedHalf = 0
            _ = InvalidateRect(hwnd, nil, false)
            return 0
        case 0x0200 where c.kind == .stepper:  // WM_MOUSEMOVE: the half under the pointer
            let half = c.half(at: lParam)
            if c.hotPart != hwnd {
                c.hotPart = hwnd
                var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: hwnd, dwHoverTime: 0)
                _ = TrackMouseEvent(&tme)
            }
            if half != c.hotHalf { c.hotHalf = half; _ = InvalidateRect(hwnd, nil, false) }
            return nil
        case 0x02A3 where c.kind == .stepper:  // WM_MOUSELEAVE
            c.hotPart = nil
            c.hotHalf = 0
            _ = InvalidateRect(hwnd, nil, false)
            return nil
        // --- visual polish K4 (end) ---
        // --- visual polish K3: hover of a custom-drawn control (begin) ---
        case 0x000F where c.drawsItself(hwnd) && !c.ctx.highContrast && !WinCustomDraw.testDisabled:  // WM_PAINT: the safety net (see `paintFallback`)
            let before = c.customDrawCount
            let dirty = GetUpdateRect(hwnd, nil, false)  // an empty update region paints nothing, with or without custom draw
            let result = DefSubclassProc(hwnd, message, wParam, lParam)
            if dirty, c.customDrawCount == before, let dc = GetDC(hwnd) {
                WinCustomDraw.paintFallback(c, hwnd, dc)
                _ = ReleaseDC(hwnd, dc)
            }
            return result
        case 0x0318 where c.drawsItself(hwnd) && !c.ctx.highContrast && !WinCustomDraw.testDisabled:  // WM_PRINTCLIENT
            let before = c.customDrawCount
            let result = DefSubclassProc(hwnd, message, wParam, lParam)
            if c.customDrawCount == before, let dc = HDC(bitPattern: UInt(wParam)) { WinCustomDraw.paintFallback(c, hwnd, dc) }
            return result
        case 0x0200 where c.drawsItself(hwnd) && c.hotPart != hwnd:  // WM_MOUSEMOVE: hover look until WM_MOUSELEAVE (no timer: Windows says when it leaves)
            let before = c.hotPart
            c.hotPart = hwnd
            var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: hwnd, dwHoverTime: 0)
            _ = TrackMouseEvent(&tme)
            if let before { _ = InvalidateRect(before, nil, false) }
            _ = InvalidateRect(hwnd, nil, false)
            return nil
        case 0x02A3 where c.drawsItself(hwnd):  // WM_MOUSELEAVE
            if c.hotPart == hwnd { c.hotPart = nil }
            _ = InvalidateRect(hwnd, nil, false)
            return nil
        case 0x0014 where c.drawsItself(hwnd) && !c.ctx.highContrast:  // WM_ERASEBKGND: custom draw paints every pixel (no flicker from a background pass)
            return 1
        // --- visual polish K3 (end) ---
        case 0x0200 where c.kind == .glyphButton && !c.hot:  // WM_MOUSEMOVE: hover look until WM_MOUSELEAVE
            c.hot = true
            var tme = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002 /* TME_LEAVE */, hwndTrack: hwnd,
                                      dwHoverTime: 0)
            _ = TrackMouseEvent(&tme)
            _ = InvalidateRect(hwnd, nil, false)
            return nil
        case 0x02A3 where c.kind == .glyphButton:  // WM_MOUSELEAVE
            c.hot = false
            _ = InvalidateRect(hwnd, nil, false)
            return nil
        case 0x0082:  // WM_NCDESTROY: a window destroyed with its parent
            forget(hwnd)
            return nil
        default:
            return nil
        }
    }

    /// Fields and every kind of button take Enter themselves.
    private var takesReturn: Bool {
        switch kind {
        case .edit: editKind != nil
        case .button, .glyphButton, .drawnItem, .combo, .stepper: true
        default: false
        }
    }

    fileprivate func clicked(_ part: HWND) {
        clicks += 1
        switch kind {
        case .checkbox: onToggle?(isOn)
        case .radioGroup: if let i = parts.firstIndex(of: part) { onSelect?(i) }
        case .combo: if customMenu { onClick?() } else { openMenu() }
        default: onClick?()
        }
    }
}

/// One function pointer for SetWindowSubclass and RemoveWindowSubclass (a subclass is identified by it and the id).
nonisolated(unsafe) private let winKitSubclass: SUBCLASSPROC = { h, m, w, l, _, _ in winKitSubclassProc(h, m, w, l) }

/// The window's handle crosses into the main actor as its bits (`HWND` is not Sendable), as the message hook does.
private func winKitSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    let bits = Int(bitPattern: hwnd)
    if let r = MainActor.assumeIsolated({ WinControl.subclassed(bits, message, wParam, lParam) }) { return r }
    return DefSubclassProc(hwnd, message, wParam, lParam)
}

/// The clipboard's text (`CF_UNICODETEXT`), read only for a paste into a code field.
enum WinClipboardText {
    static func read() -> String? {
        guard OpenClipboard(nil) else { return nil }
        defer { _ = CloseClipboard() }
        guard let data = GetClipboardData(13 /* CF_UNICODETEXT */), let p = GlobalLock(data) else { return nil }
        defer { _ = GlobalUnlock(data) }
        return String(decodingCString: p.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }
}

/// Answers the notifications a window's controls send to it (`WM_COMMAND`, `WM_NOTIFY`, `WM_HSCROLL`/`WM_VSCROLL`,
/// `WM_DRAWITEM`, `WM_CTLCOLOR*`) by finding the control in the kit's registry, so any window of the popover can hold
/// controls. `detach` removes exactly its registrations.
@MainActor final class WinControlRouter {
    private let window: WinSinkWindow
    private var tokens: [WinSinkWindow.Token] = []

    init(window: WinSinkWindow) {
        self.window = window
        tokens.append(window.on(UINT(WM_COMMAND)) { wParam, lParam in Self.command(wParam, lParam) })
        tokens.append(window.on(0x004E /* WM_NOTIFY */) { _, lParam in Self.notify(lParam) })
        tokens.append(window.on(0x0114 /* WM_HSCROLL */) { _, lParam in Self.scroll(lParam) })
        tokens.append(window.on(0x0115 /* WM_VSCROLL */) { _, lParam in Self.scroll(lParam) })
        tokens.append(window.on(0x002B /* WM_DRAWITEM */) { _, lParam in Self.drawItem(lParam) })
        for message: UINT in [0x0133, 0x0134, 0x0135, 0x0138] {  // WM_CTLCOLOREDIT, LISTBOX, BTN, STATIC
            tokens.append(window.on(message) { wParam, lParam in Self.color(message, wParam, lParam) })
        }
    }

    func detach() {
        for t in tokens { window.off(t) }
        tokens = []
    }

    private static func command(_ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let part = HWND(bitPattern: Int(lParam)), let c = WinControl.control(part) else { return nil }
        let code = WinKit.hiWord(wParam)
        switch (c.kind, code) {
        case (.button, 0), (.glyphButton, 0), (.checkbox, 0), (.radioGroup, 0), (.drawnItem, 0), (.combo, 0), (.stepper, 0):  // BN_CLICKED
            c.clicked(part)
        case (.combo, 1):  // CBN_SELCHANGE
            c.onSelect?(c.selection)
        case (.edit, 0x0300):  // EN_CHANGE
            c.onChange?(c.text)
        default:
            return nil
        }
        return 0
    }

    private static func notify(_ lParam: LPARAM) -> LRESULT? {
        guard let header = UnsafeMutablePointer<NMHDR>(bitPattern: Int(lParam)), let c = WinControl.control(header.pointee.hwndFrom) else { return nil }
        let code = Int32(bitPattern: header.pointee.code)
        if code == -12 /* NM_CUSTOMDRAW */, c.usesCustomDraw { return WinCustomDraw.handle(c, header) }  // visual polish K3
        switch (c.kind, code) {
        case (.link, -2), (.link, -4):  // NM_CLICK, NM_RETURN
            c.clicked(c.hwnd)
            return 0
        case (.tabs, -551):  // TCN_SELCHANGE
            c.onSelect?(c.selection)
            return 0
        default:
            return nil
        }
    }

    private static func scroll(_ lParam: LPARAM) -> LRESULT? {
        guard let part = HWND(bitPattern: Int(lParam)), let c = WinControl.control(part), c.kind == .trackbar else { return nil }
        if !c.ctx.highContrast { _ = InvalidateRect(c.parts[0], nil, false) }  // the drawn thumb is wider than the system's: the whole bar repaints
        c.applyValue(WinKit.send(c.parts[0], 0x0400 /* TBM_GETPOS */), notify: true)
        return 0
    }

    private static func drawItem(_ lParam: LPARAM) -> LRESULT? {
        guard let dis = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: Int(lParam)), let c = WinControl.control(dis.pointee.hwndItem) else { return nil }
        switch c.kind {
        case .glyphButton: WinControls.drawGlyphButton(c, dis)
        case .drawnItem: c.drawItem?(dis)
        default: return nil
        }
        return 1
    }

    /// The background behind a control, and the text colour of labels; high contrast keeps the system's.
    private static func color(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        guard let part = HWND(bitPattern: Int(lParam)), let c = WinControl.control(part),
              let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
        let colors = c.ctx.colors
        if colors.dark, message == 0x0133 || message == 0x0134 {  // dark: the field and the drop-down list in the field colour
            _ = SetBkColor(dc, colors.palette.field)
            _ = SetTextColor(dc, colors.palette.text)
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(colors.brush(colors.palette.field))))
        }
        if message == 0x0133 || message == 0x0134 { return nil }  // edits and lists draw as the system draws them
        if colors.highContrast {
            guard message == 0x0138 else { return nil }
            _ = SetBkColor(dc, colors.palette.window)
            _ = SetTextColor(dc, colors.palette.text)
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(colors.brush(colors.palette.window))))
        }
        _ = SetBkColor(dc, c.background)
        // Dark: every text the system draws through this message (a read-only field, a check box's text where the theme
        // lets us) is light; a themed check box or radio button draws its own light text in its dark style.
        if colors.dark, c.kind != .label, !(c.kind == .trackbar && part != c.hwnd) {
            _ = SetTextColor(dc, colors.palette.text)
        }
        if c.kind == .label || (c.kind == .trackbar && part != c.hwnd) { _ = SetTextColor(dc, c.textColor ?? colors.text(c.role)) }  // stage 7 Task 5: textColor
        return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(colors.brush(c.background))))
    }
}

/// The control factory (stage 7 D5, D6, D12): every control the popover's pages are built from, made with the context's
/// font for its DPI, `WS_GROUP` on each so arrow keys stay inside radio groups, and the kit's subclass. Sizes are pixels.
/// Creation order is Tab order: create a row's label before its control (the accessible name of an edit or combo box is
/// the static text just before it).
@MainActor enum WinControls {
    private static let child: DWORD = 0x4000_0000 | 0x1000_0000  // WS_CHILD | WS_VISIBLE
    private static let tabStop: DWORD = 0x0001_0000, group: DWORD = 0x0002_0000
    private static var nextID = 0x100
    private static var initialized = false

    /// comctl32 v6's classes (the manifest asks for v6): buttons, edits, combo boxes, trackbars, up-downs, tabs, tooltips, links.
    static func initializeCommonControls() {
        guard !initialized else { return }
        initialized = true
        var icc = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: 0x0000_40FF | 0x0000_8000)
        if !InitCommonControlsEx(&icc) { AppLog.write("popover kit: InitCommonControlsEx failed") }
    }

    private static func id() -> Int {
        nextID += 1
        if nextID > 0x7FFF { nextID = 0x100 }
        return nextID
    }

    /// Static text: wrapping (`SS_LEFT`) or one line cut with an ellipsis; never `&` prefixes (D5).
    static func label(_ text: String, style: PopoverTextStyle = .body, weight: Int? = nil, role: WinUIColors.Role = .primary,
                      wraps: Bool = true, maxLines: Int? = nil, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let ss: DWORD = (wraps ? (maxLines != nil ? 0x4000 /* SS_ENDELLIPSIS: clipped at the line limit */ : 0x0000) /* SS_LEFT */ : 0x000C /* SS_LEFTNOWORDWRAP */ | 0x4000 /* SS_ENDELLIPSIS */) | 0x0080 /* SS_NOPREFIX */
        guard let h = WinKit.create("Static", text, style: child | ss, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(style, weight: weight)
        WinKit.setFont(h, font)
        let s = ctx.measure(text, font: font)
        let c = WinControl(kind: .label, ctx: ctx, parts: [h], size: CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy)),
                           background: ctx.colors.palette.window, font: font)
        c.role = role
        c.maxLines = wraps ? maxLines : nil
        return c
    }

    /// A push button (`BS_PUSHBUTTON`, repainted by `WinCustomDraw`): regular is 28 DIP high with the body text, small 24 DIP with
    /// the callout text (the Mac's `.controlSize(.small)`), at least 56 DIP wide.
    static func button(_ title: String, style: WinButtonStyle = .secondary, small: Bool = false, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", WinKit.title(title), style: child | tabStop | group | 0x0000 /* BS_PUSHBUTTON */, parent: parent, id: id())
        else { return nil }
        let font = ctx.fonts.font(small ? .callout : .body)
        WinKit.setFont(h, font)
        let s = ctx.measure(title, font: font)
        let c = WinControl(kind: .button, ctx: ctx, parts: [h],
                           size: CGSize(width: CGFloat(max(s.cx + ctx.px(24), ctx.px(56))), height: CGFloat(max(s.cy + ctx.px(8), ctx.px(small ? 24 : 28)))),
                           background: ctx.colors.palette.window, font: font)
        c.buttonStyle = style
        c.isSmallButton = small
        return c
    }

    /// A square owner-drawn button showing the symbol's Fluent / MDL2 glyph (or its fallback text); its window text is the
    /// accessible label, it draws its focus rectangle after keyboard use, and Enter or Space press it.
    static func glyphButton(symbol: String, label: String, size: CGFloat = 16, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", WinKit.title(label), style: child | tabStop | group | 0x000B /* BS_OWNERDRAW */, parent: parent, id: id())
        else { return nil }
        let side = CGFloat(ctx.px(size + 12))
        let c = WinControl(kind: .glyphButton, ctx: ctx, parts: [h], size: CGSize(width: side, height: side),
                           background: ctx.colors.palette.window, font: nil)
        if let text = WinGlyphs.text(symbol: symbol, fluent: ctx.fonts.iconIsFluent) {
            c.glyph = (text, true)
            c.font = ctx.fonts.icon(size: size)
        } else {
            c.glyph = (WinGlyphs.fallback(symbol: symbol) ?? label, false)
            c.font = ctx.fonts.emoji(size: size)
        }
        return c
    }

    /// A check box that spans its row with the label on the left and a switch (40 x 20 DIP) on the right, as the Mac's and Windows 11
    /// Settings' toggle rows. It stays a `BS_AUTOCHECKBOX` (role check box, checked state, Space toggles); `WinCustomDraw` paints the
    /// switch. The label is its accessible name.
    static func checkbox(_ title: String, isOn: Bool, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let bs: DWORD = 0x0003 /* BS_AUTOCHECKBOX */ | 0x0020 /* BS_LEFTTEXT, BS_RIGHTBUTTON */ | 0x2000 /* BS_MULTILINE */
        guard let h = WinKit.create("Button", WinKit.title(title), style: child | tabStop | group | bs, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        let s = ctx.measure(title, font: font)
        let c = WinControl(kind: .checkbox, ctx: ctx, parts: [h],
                           size: CGSize(width: CGFloat(s.cx + ctx.px(40 + 12 + 3)), height: CGFloat(max(s.cy + ctx.px(8), ctx.px(28)))),
                           background: ctx.colors.palette.window, font: font)
        c.isOn = isOn
        return c
    }

    /// Push-like radio buttons (the Mac's segmented pickers), painted by `WinCustomDraw` as one connected control: a shared track
    /// with the selected segment raised. One Tab stop, arrows move inside the group; `tall` is the main tab strip's 30 DIP.
    static func radioGroup(_ titles: [String], selected: Int, tall: Bool = false, fillsRow: Bool = false, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard !titles.isEmpty else { return nil }
        let font = ctx.fonts.font(.body)
        var parts: [HWND] = []
        var widest: Int32 = 0, height: Int32 = 0
        for (i, title) in titles.enumerated() {
            let first: DWORD = i == 0 ? tabStop | group : 0
            guard let h = WinKit.create("Button", WinKit.title(title), style: child | first | 0x0009 /* BS_AUTORADIOBUTTON */ | 0x1000 /* BS_PUSHLIKE */,
                                        parent: parent, id: id()) else {
                for p in parts { _ = DestroyWindow(p) }
                return nil
            }
            WinKit.setFont(h, font)
            let s = ctx.measure(title, font: font)
            widest = max(widest, s.cx)
            height = max(height, s.cy)
            parts.append(h)
        }
        let c = WinControl(kind: .radioGroup, ctx: ctx, parts: parts,
                           size: CGSize(width: CGFloat((widest + ctx.px(16)) * Int32(parts.count)), height: CGFloat(max(height + ctx.px(8), ctx.px(tall ? 30 : 28)))),
                           background: ctx.colors.palette.window, font: font)
        c.selection = selected
        c.fillsRow = fillsRow
        return c
    }

    /// Capsule chips as push-like radio buttons (Home's provider and account tabs): the selected one is exposed to screen readers
    /// as the checked radio button, which the drawn pills it replaces could not say. `names` are the accessible names (window
    /// texts); a chip's `marks` entry draws the marker dot before its title. No chip is checked when `selected` is nil.
    static func chipGroup(names: [String], marks: [Bool], selected: Int?, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard !names.isEmpty else { return nil }
        let regular = ctx.fonts.font(.caption), bold = ctx.fonts.font(.caption, weight: 600)
        var parts: [HWND] = []
        var widths: [Int32] = []
        for (i, name) in names.enumerated() {
            let first: DWORD = i == 0 ? tabStop | group : 0
            guard let h = WinKit.create("Button", WinKit.title(name), style: child | first | 0x0009 /* BS_AUTORADIOBUTTON */ | 0x1000 /* BS_PUSHLIKE */,
                                        parent: parent, id: id()) else {
                for p in parts { _ = DestroyWindow(p) }
                return nil
            }
            WinKit.setFont(h, regular)
            let shown = (marks.indices.contains(i) && marks[i] ? "\u{25CF} " : "") + name
            widths.append(ctx.measure(shown, font: i == selected ? bold : regular).cx + 2 * ctx.px(10))
            parts.append(h)
        }
        let total = widths.reduce(0, +) + ctx.px(8) * Int32(parts.count - 1)
        let c = WinControl(kind: .radioGroup, ctx: ctx, parts: parts, size: CGSize(width: CGFloat(total), height: CGFloat(max(ctx.lineHeight(regular) + ctx.px(8), ctx.px(24)))),
                           background: ctx.colors.palette.window, font: regular)
        c.segmentStyle = .chips
        c.chipMarks = marks
        c.chipWidths = widths
        c.boldFont = bold
        if let selected { c.selection = selected }
        return c
    }

    /// A drop-down (the Mac's menu-style `Picker`, replacing the combo box): a button showing the chosen entry and a chevron, opening
    /// the kit's popup menu (`WinPopupMenu`: arrow keys, Enter and Esc, the system's dismissal). A `BS_PUSHBUTTON` painted by
    /// `WinCustomDraw`, so MSAA reports a push button whose name is "label: value" (the row sets the label); Space, Enter, F4 and
    /// Alt+Down open the menu, Up, Down, Home and End change the value in place.
    static func combo(_ items: [String], selected: Int, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", "", style: child | tabStop | group | 0x0000 /* BS_PUSHBUTTON */, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        let c = WinControl(kind: .combo, ctx: ctx, parts: [h], size: .zero, background: ctx.colors.palette.window, font: font)
        c.items = items
        c.comboSel = selected
        c.maxComboWidth = ctx.px(240)
        c.onKey = { [weak c] key in c?.comboKey(key) ?? false }
        c.refreshComboText()
        c.preferredSize = c.comboSize()
        return c
    }

    /// A drop-down whose menu the caller makes (`onClick`) and that shows `title`: the Representative Pokémon row. `maxWidth` DIP.
    static func menuButton(title: String, maxWidth: CGFloat, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let c = combo([], selected: -1, in: parent, ctx: ctx) else { return nil }
        c.customMenu = true
        c.maxComboWidth = ctx.px(maxWidth)
        c.setDisplay(title)
        return c
    }

    /// A text field of `kind` (D5), `width` DIP wide when given (grown with Windows' text size, as its text grows), else the
    /// row's width.
    static func edit(_ kind: WinEditKind, text: String = "", width: CGFloat? = nil, bordered: Bool = true, in parent: HWND, ctx: WinUIContext) -> WinControl? {  // bordered: stage 7 parity (a field inside a frame of its own)
        var es: DWORD = 0x0080  // ES_AUTOHSCROLL
        var lines = 1
        switch kind {
        case .password: es |= 0x0020  // ES_PASSWORD
        case .multiLine(let n, _):
            es = 0x0004 | 0x0040 | 0x0020_0000  // ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL (no ES_WANTRETURN: Enter commits)
            lines = max(1, n)
        default: break
        }
        guard let h = WinKit.create("Edit", text, style: child | tabStop | group | es, exStyle: 0, parent: parent, id: id()) else { return nil }
        let isMulti: Bool = { if case .multiLine = kind { return true }; return false }()
        let font = ctx.fonts.font(isMulti ? .caption : .body)  // the Mac's multi-line fields are `.caption`
        WinKit.setFont(h, font)
        if let cue = kind.cue { WinKit.send(h, 0x1501 /* EM_SETCUEBANNER */, 1, text: cue) }
        let line = ctx.lineHeight(font)
        let c = WinControl(kind: .edit, ctx: ctx, parts: [h],
                           size: CGSize(width: width.map { CGFloat(ctx.px($0 * CGFloat(ctx.textScale))) } ?? 100_000,
                                        height: CGFloat(bordered ? max(line * Int32(lines) + ctx.px(bordered && lines > 1 ? 12 : 8), ctx.px(28)) : line * Int32(lines) + ctx.px(10))),
                           background: ctx.colors.palette.window, font: font)
        c.editKind = kind
        if bordered {
            // The frame is the field's own non-client area (K4): padding, a hairline and the focus ring, painted by `WinCustomDraw.paintFieldFrame`.
            c.framed = true
            _ = SetWindowPos(h, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED))
        }
        // A multi-line field's scroll bar is dark only in the Explorer style (the field style leaves it light).
        if ctx.dark, isMulti { WinDarkMode.setTheme(h, "DarkMode_Explorer") }
        c.lastCommitted = text
        return c
    }

    /// A slider (the Mac's `Slider` with a step) and its value text on the right.
    static func trackbar(range: ClosedRange<Int>, step: Int, value: Int, format: @escaping (Int) -> String, width: CGFloat = 200,
                         in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let style = child | tabStop | group | 0x0010 /* TBS_NOTICKS */
        guard let bar = WinKit.create("msctls_trackbar32", "", style: style, parent: parent, id: id()) else { return nil }
        guard let valueText = WinKit.create("Static", "", style: child | 0x0002 /* SS_RIGHT */ | 0x0080 /* SS_NOPREFIX */, parent: parent, id: id())
        else { _ = DestroyWindow(bar); return nil }
        let font = ctx.fonts.font(.callout)
        WinKit.setFont(valueText, font)
        WinKit.send(bar, 0x0407 /* TBM_SETRANGEMIN */, 0, range.lowerBound)
        WinKit.send(bar, 0x0408 /* TBM_SETRANGEMAX */, 1, range.upperBound)
        WinKit.send(bar, 0x0417 /* TBM_SETLINESIZE */, 0, step)
        WinKit.send(bar, 0x0415 /* TBM_SETPAGESIZE */, 0, step)
        let valueW = max(ctx.measure(format(range.lowerBound), font: font).cx, ctx.measure(format(range.upperBound), font: font).cx)
        let c = WinControl(kind: .trackbar, ctx: ctx, parts: [bar, valueText], size: CGSize(width: CGFloat(ctx.px(width)), height: CGFloat(ctx.px(28))),
                           background: ctx.colors.palette.window, font: font)
        c.range = range
        c.step = step
        c.format = format
        c.valueWidth = CGFloat(valueW)
        c.currentValue = Self.unset
        c.applyValue(value, notify: false)
        return c
    }

    /// The Mac's `Stepper`: "×N" and a pair of chevrons (the upper half adds a step, the lower takes one), one focusable button
    /// (`BS_PUSHBUTTON`, painted by `WinCustomDraw`) as wide as its value ("×99" at the most; not as the maximum). Up, Down,
    /// PageUp, PageDown, Home and End change the value; its accessible name is "name: ×N" and changes with the value.
    static func stepper(range: ClosedRange<Int>, step: Int, value: Int, format: @escaping (Int) -> String, name: String? = nil,
                        in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", "", style: child | tabStop | group | 0x0000 /* BS_PUSHBUTTON */, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.callout, weight: 600)
        WinKit.setFont(h, font)
        let widest = format(min(range.upperBound, 99))
        let valueW = max(ctx.measure(format(range.lowerBound), font: font).cx, ctx.measure(widest, font: font).cx)
        let c = WinControl(kind: .stepper, ctx: ctx, parts: [h],
                           size: CGSize(width: CGFloat(valueW + ctx.px(6 + 18)), height: CGFloat(ctx.px(28))),
                           background: ctx.colors.palette.window, font: font)
        c.range = range
        c.step = step
        c.format = format
        c.accessibleLabel = name
        c.currentValue = Self.unset
        c.onKey = { [weak c] key in c?.stepperKey(key) ?? false }
        c.applyValue(value, notify: false)
        return c
    }

    /// A text link (`SysLink`): Tab reaches it, Enter or a click opens it.
    static func link(_ title: String, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let escaped = title.replacingOccurrences(of: "<", with: "‹")
        guard let h = WinKit.create("SysLink", "<a>\(escaped)</a>", style: child | tabStop | group | 0x0001 /* LWS_TRANSPARENT */,
                                    parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.callout)
        WinKit.setFont(h, font)
        let s = ctx.measure(title, font: font)
        return WinControl(kind: .link, ctx: ctx, parts: [h], size: CGSize(width: CGFloat(s.cx + ctx.px(2)), height: CGFloat(s.cy + ctx.px(2))),
                          background: ctx.colors.palette.window, font: font)
    }

    /// A tab row (`SysTabControl32`, tabs only: the page under it is the popover's).
    static func tabs(_ titles: [String], selected: Int, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("SysTabControl32", "", style: child | tabStop | group | 0x0400_0000 /* WS_CLIPSIBLINGS */, parent: parent,
                                    id: id(), rect: RECT(left: 0, top: 0, right: ctx.px(332), bottom: ctx.px(40))) else { return nil }
        let font = ctx.fonts.font(.callout)
        WinKit.setFont(h, font)
        for (i, title) in titles.enumerated() {
            var wide = WinStr.w(WinKit.title(title))
            wide.withUnsafeMutableBufferPointer { buffer in
                var item = TCITEMW()
                item.mask = 0x0001  // TCIF_TEXT
                item.pszText = buffer.baseAddress
                _ = withUnsafeMutablePointer(to: &item) { WinKit.send(h, 0x133E /* TCM_INSERTITEMW */, i, Int(bitPattern: $0)) }
            }
        }
        var last = RECT()
        _ = withUnsafeMutablePointer(to: &last) { WinKit.send(h, 0x130A /* TCM_GETITEMRECT */, max(0, titles.count - 1), Int(bitPattern: $0)) }
        let c = WinControl(kind: .tabs, ctx: ctx, parts: [h], size: CGSize(width: CGFloat(last.right + ctx.px(4)), height: CGFloat(last.bottom + ctx.px(2))),
                           background: ctx.colors.palette.window, font: font)
        c.selection = selected
        return c
    }

    /// An accessibility item of a drawn part as a real child (D7): a `button` item an owner-drawn button (Tab stop, its
    /// label as window text, a press is the item's hit), a text item an owner-drawn static (read as its text). Both paint
    /// the picture under them through `drawItem`.
    static func drawnItem(_ item: PlazaAccessibilityItem, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let name = item.value.map { "\(item.label), \($0)" } ?? item.label
        let isButton = item.role == .button || item.role == .menuItem
        let style = isButton ? child | tabStop | group | 0x000B /* BS_OWNERDRAW */ : child | 0x000D /* SS_OWNERDRAW */ | 0x0080
        guard let h = WinKit.create(isButton ? "Button" : "Static", isButton ? WinKit.title(name) : name, style: style, parent: parent, id: id()) else { return nil }
        let c = WinControl(kind: .drawnItem, ctx: ctx, parts: [h], size: .zero, background: ctx.colors.palette.window, font: nil)
        if !item.isEnabled { c.isEnabled = false }
        return c
    }

    /// A drawn view's window as a control the stack can place.
    static func drawn(_ hwnd: HWND, size: CGSize, ctx: WinUIContext, frame: @escaping (RECT) -> Void) -> WinControl {
        let c = WinControl(kind: .drawn, ctx: ctx, parts: [hwnd], size: size, background: ctx.colors.palette.window, font: nil)
        c.onFrame = frame
        return c
    }

    /// No value yet: the first `applyValue` always sets the control.
    fileprivate static let unset = Int.min

    /// The glyph button's picture: its background (pressed and hovered a step darker), the glyph centred, the focus
    /// rectangle when the keyboard put the focus there.
    static func drawGlyphButton(_ c: WinControl, _ dis: UnsafeMutablePointer<DRAWITEMSTRUCT>) {
        if let pill = c.pill { drawPill(c, pill, dis); return }
        let d = dis.pointee
        let state = d.itemState
        let colors = c.ctx.colors.palette
        let pressed = state & 0x0001 != 0, disabled = state & 0x0004 != 0, focused = state & 0x0010 != 0, hideFocus = state & 0x0200 != 0
        var r = d.rcItem
        // A rounded fill (4 DIP, antialiased) under the pointer or the press; at rest the button is its background only.
        _ = FillRect(d.hDC, &r, c.ctx.colors.brush(c.background))
        if !disabled, pressed || c.hot {
            WinPaint.roundedRect(d.hDC, r, radius: c.ctx.px(4), fill: WinPaint.Ink(color: pressed ? colors.pressed : colors.hot),
                                 under: c.background, ctx: c.ctx)
        }
        if let glyph = c.glyph {
            let old = SelectObject(d.hDC, UnsafeMutableRawPointer(c.font))
            _ = SetBkMode(d.hDC, 1 /* TRANSPARENT */)
            _ = SetTextColor(d.hDC, disabled ? c.ctx.colors.palette.disabled : (pressed && c.ctx.highContrast ? WinUIContext.sysColor(14) : (c.ctx.highContrast ? colors.text : (c.glyphColor ?? (pressed || c.hot ? colors.text : colors.secondaryText)))))
            _ = WinStr.w(glyph.text).withUnsafeBufferPointer {
                DrawTextW(d.hDC, $0.baseAddress, -1, &r, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            _ = SelectObject(d.hDC, old)
        }
        if focused, !hideFocus {
            var f = d.rcItem
            _ = InflateRect(&f, -c.ctx.px(1), -c.ctx.px(1))
            WinPaint.focusRing(d.hDC, f, radius: c.ctx.px(4), ctx: c.ctx, outer: colors.text,
                               inner: f.bottom - f.top >= c.ctx.px(22) ? c.background : nil)
        }
    }
}
// --- stage 7 Task 14: a small marquee progress bar (the Mac's small ProgressView beside Save) (begin) ---
extension WinControls {
    /// comctl32's marquee progress bar (`PBS_MARQUEE`), `width` × 6 pt: the Mac shows a small spinner while a key is checked;
    /// Windows has no spinner control, and its busy indicator in a form is the marquee bar. Still until `setMarquee(true)`
    /// (comctl32 animates it on its own timer while on; nothing runs while it is off).
    static func marquee(width: CGFloat = 36, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("msctls_progress32", "", style: child | 0x0008 /* PBS_MARQUEE */, parent: parent, id: id())
        else { return nil }
        return WinControl(kind: .progress, ctx: ctx, parts: [h], size: CGSize(width: CGFloat(ctx.px(width)), height: CGFloat(ctx.px(6))),
                          background: ctx.colors.palette.window, font: nil)
    }
}

extension WinControl {
    /// A marquee bar's animation on or off (`PBM_SETMARQUEE`, a step every 30 ms while on).
    func setMarquee(_ on: Bool) {
        guard kind == .progress, isMarqueeOn != on else { return }
        isMarqueeOn = on
        _ = WinKit.send(hwnd, 0x040A /* PBM_SETMARQUEE */, on ? 1 : 0, 30)
    }
}
// --- stage 7 Task 14 (end) ---

// --- stage 7 Task 14: a glyph button that changes its symbol (the Advanced disclosure's chevron) (begin) ---
extension WinControl {
    /// Shows `symbol` instead (a disclosure's chevron turning down): the same font size, the window text (its accessible
    /// name) unchanged, one repaint.
    func setGlyph(symbol: String, size: CGFloat = 16) {
        guard kind == .glyphButton else { return }
        if let text = WinGlyphs.text(symbol: symbol, fluent: ctx.fonts.iconIsFluent) {
            guard glyph?.text != text else { return }
            glyph = (text, true)
            font = ctx.fonts.icon(size: size)
        } else {
            glyph = (WinGlyphs.fallback(symbol: symbol) ?? text, false)
            font = ctx.fonts.emoji(size: size)
        }
        _ = InvalidateRect(hwnd, nil, false)
    }
}
// --- stage 7 Task 14 (end) ---

// --- parity: the Mac's button looks, drawn (begin) ---
/// What a pill button shows. SwiftUI's `.buttonStyle(.borderless)` (text in the accent colour, a fill only under the pointer),
/// a `Capsule` fill (Home's Details and the provider tabs), and `.borderedProminent` (the accent fill, white text) have no
/// Win32 counterpart, so the kit draws them: owner-drawn buttons with the same keyboard and accessibility behaviour as the
/// glyph button (the window text is the accessible name).
struct WinPill: Equatable {
    enum Style: Equatable { case borderless, capsule, tab, prominent, disclosure }
    var style: Style
    var title: String
    /// An SF Symbol name (the glyph table maps it) before the title, or after it with `glyphAfter`.
    var glyph: String?
    var glyphAfter = false
    var selected = false
    /// `.foregroundStyle(.secondary)` on a borderless button.
    var secondary = false
    var textStyle: PopoverTextStyle = .caption
    var bold = false
    /// Content from the left edge (a disclosure row: the whole row is the button), not centred.
    var leftAligned = false
    /// `.foregroundStyle(Color.accentColor)` on a borderless button (Settings' Back); without it the text is the primary colour, as
    /// SwiftUI's borderless buttons draw it on the Mac.
    var accent = false
}

extension WinControls {
    /// A pill button; `label` is its accessible name when that differs from the title.
    static func pillButton(_ pill: WinPill, label: String? = nil, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", WinKit.title(label ?? pill.title), style: child | tabStop | group | 0x000B /* BS_OWNERDRAW */,
                                    parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(pill.textStyle, weight: pill.bold ? 600 : nil)
        let c = WinControl(kind: .glyphButton, ctx: ctx, parts: [h], size: .zero, background: ctx.colors.palette.window, font: font)
        c.pill = pill
        c.preferredSize = pillSize(c, pill)
        return c
    }

    private static func pillGlyph(_ pill: WinPill, ctx: WinUIContext) -> (text: String, font: HFONT?)? {
        guard let symbol = pill.glyph else { return nil }
        let size = pill.textStyle.size
        if let text = WinGlyphs.text(symbol: symbol, fluent: ctx.fonts.iconIsFluent) { return (text, ctx.fonts.icon(size: size)) }
        return WinGlyphs.fallback(symbol: symbol).map { ($0, ctx.fonts.emoji(size: size)) }
    }

    private static func pillPadding(_ style: WinPill.Style, ctx: WinUIContext) -> (h: Int32, v: Int32) {
        switch style {
        case .capsule: (ctx.px(8), ctx.px(4))   // Details: .padding(.horizontal, 8).padding(.vertical, 4)
        case .tab: (ctx.px(10), ctx.px(4))      // CapsuleTabBar
        case .prominent: (ctx.px(10), ctx.px(3))
        case .borderless: (ctx.px(4), ctx.px(2))
        case .disclosure: (0, ctx.px(2))
        }
    }

    static func pillSize(_ c: WinControl, _ pill: WinPill) -> CGSize {  // stage 7 Task 20: was fileprivate
        let ctx = c.ctx
        let title = ctx.measure(pill.title, font: c.font)
        let glyph = pillGlyph(pill, ctx: ctx).map { ctx.measure($0.text, font: $0.font) }
        let gap = glyph == nil ? Int32(0) : ctx.px(4)
        let pad = pillPadding(pill.style, ctx: ctx)
        let w = title.cx + (glyph?.cx ?? 0) + gap + 2 * pad.h
        let h = max(title.cy, glyph?.cy ?? 0) + 2 * pad.v
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    private static func drawPillText(_ dc: HDC, _ text: String, font: HFONT?, box: RECT) {
        var box = box
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        _ = WinStr.w(text).withUnsafeBufferPointer {
            DrawTextW(dc, $0.baseAddress, -1, &box, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
        }
        _ = SelectObject(dc, old)
    }

    /// The pill's picture: the page colour, the fill (a hovered or pressed borderless button gets one too), the glyph and the
    /// title centred, the focus rectangle after keyboard use.
    fileprivate static func drawPill(_ c: WinControl, _ pill: WinPill, _ dis: UnsafeMutablePointer<DRAWITEMSTRUCT>) {
        let d = dis.pointee
        let ctx = c.ctx, pal = ctx.colors.palette, bg = c.background
        let state = d.itemState
        let pressed = state & 0x0001 != 0, disabled = state & 0x0004 != 0, focused = state & 0x0010 != 0, hideFocus = state & 0x0200 != 0
        var r = d.rcItem
        _ = FillRect(d.hDC, &r, ctx.colors.brush(bg))
        let high = ctx.highContrast
        var fill: COLORREF?
        var ink = pal.text
        var radius = (r.bottom - r.top) / 2  // a capsule
        switch pill.style {
        case .capsule:
            ink = pal.text
            fill = high ? nil : WinUIColors.blend(bg, pal.text, 0.08)
        case .tab:
            ink = pill.selected ? pal.accent : pal.secondaryText
            fill = high ? nil : (pill.selected ? WinUIColors.blend(bg, pal.accent, 0.18) : WinUIColors.blend(bg, pal.secondaryText, 0.08))
        case .prominent:
            ink = high ? WinUIContext.sysColor(14 /* COLOR_HIGHLIGHTTEXT */) : WinUIColors.rgb(255, 255, 255)
            fill = disabled && !high ? WinUIColors.blend(bg, pal.accent, 0.35) : pal.accent
            radius = ctx.px(5)
        case .borderless:
            ink = pill.accent ? pal.accent : (pill.secondary ? pal.secondaryText : pal.text)
            radius = ctx.px(4)
        case .disclosure:
            ink = pal.text
            radius = ctx.px(4)
        }
        if high, pill.style != .prominent { ink = pal.text }
        if high, pill.style == .borderless, pill.accent { ink = pal.text }
        if !disabled, pressed || c.hotForPill {
            let base = fill ?? bg
            fill = WinUIColors.blend(base, pill.style == .prominent ? WinUIColors.rgb(0, 0, 0) : pal.text, pressed ? 0.14 : 0.07)
        }
        if let fill { WinPaint.roundedRect(d.hDC, r, radius: radius, fill: WinPaint.Ink(color: fill), under: bg, ctx: ctx) }
        let textColor = disabled ? ctx.colors.palette.disabled : ink
        _ = SetBkMode(d.hDC, 1 /* TRANSPARENT */)
        _ = SetTextColor(d.hDC, textColor)
        let glyph = pillGlyph(pill, ctx: ctx)
        let title = ctx.measure(pill.title, font: c.font)
        let glyphSize = glyph.map { ctx.measure($0.text, font: $0.font) }
        let gap = glyph == nil ? Int32(0) : ctx.px(4)
        let total = title.cx + (glyphSize?.cx ?? 0) + gap
        var x = pill.leftAligned ? r.left + pillPadding(pill.style, ctx: ctx).h : r.left + max(0, (r.right - r.left - total) / 2)
        // A disclosure's chevron is the secondary colour (`.foregroundStyle(.secondary)`), its title the primary.
        let glyphInk: COLORREF = pill.style == .disclosure && !high ? pal.secondaryText : textColor
        var pieces: [(text: String, font: HFONT?, width: Int32, color: COLORREF)] = []
        if let glyph, let glyphSize, !pill.glyphAfter { pieces.append((glyph.text, glyph.font, glyphSize.cx, glyphInk)) }
        pieces.append((pill.title, c.font, title.cx, textColor))
        if let glyph, let glyphSize, pill.glyphAfter { pieces.append((glyph.text, glyph.font, glyphSize.cx, glyphInk)) }
        for piece in pieces {
            _ = SetTextColor(d.hDC, disabled ? ctx.colors.palette.disabled : piece.color)
            drawPillText(d.hDC, piece.text, font: piece.font, box: RECT(left: x, top: r.top, right: x + piece.width, bottom: r.bottom))
            x += piece.width + gap
        }
        if focused, !hideFocus {
            // 2 DIP rounded ring in the text colour around the pill's own shape; the 1 DIP inner line only where the pill is tall enough for it
            // beside its text (the Mac's paddings are 2-4 DIP).
            WinPaint.focusRing(d.hDC, d.rcItem, radius: radius, ctx: ctx, outer: pal.text,
                               inner: d.rcItem.bottom - d.rcItem.top >= ctx.px(26) ? bg : nil)
        }
    }
}

extension WinControl {
    /// The pill's glyph symbol (the selftest reads it, as it read a glyph button's text).
    var pillGlyph: String? { pill?.glyph }
    var isPill: Bool { pill != nil }

    /// Another symbol before the title (a disclosure's chevron turning down): one repaint.
    func setPillGlyph(_ symbol: String) {
        guard var p = pill, p.glyph != symbol else { return }
        p.glyph = symbol
        pill = p
        _ = InvalidateRect(hwnd, nil, false)
    }
}

// --- stage 7 Task 20: a pill whose title changes (Settings' representative Pokémon) (begin) ---
extension WinControl {
    /// Another title: the window text (the accessible name), the size, one repaint; the page lays out again when the width changed.
    func setPillTitle(_ title: String) {
        guard var p = pill, p.title != title else { return }
        p.title = title
        pill = p
        text = title
        let before = preferredSize
        preferredSize = WinControls.pillSize(self, p)
        _ = InvalidateRect(hwnd, nil, false)
        if before != preferredSize { onSizeChange?() }
    }
}
// --- stage 7 Task 20 (end) ---

extension WinControl {
    /// A hover text for one window of a group (a chip with its own help), where `tooltip` gives every part the same one.
    func setTooltip(_ text: String?, forPart index: Int) {
        guard parts.indices.contains(index) else { return }
        ctx.tooltips.set(text, for: parts[index], in: GetParent(parts[index]))
    }
}

extension WinControl {
    /// The pointer is over the button (the kit's hover look).
    fileprivate var hotForPill: Bool { hot }
}
// --- parity (end) ---

// --- visual polish K4: the drop-down and the stepper (begin) ---
extension WinControl {
    /// The text the drop-down shows: `display`, else the chosen entry.
    var comboShown: String { comboDisplay ?? (items.indices.contains(comboSel) ? items[comboSel] : "") }
    var itemCount: Int { items.count }
    func itemTitle(_ index: Int) -> String { items.indices.contains(index) ? items[index] : "" }

    /// The window text is the accessible name: "Language: English" (the row's label, then the value); a change is announced.
    fileprivate func refreshComboText() {
        guard kind == .combo else { return }
        let name = (accessibleLabel.map { "\($0): " } ?? "") + comboShown
        let before = WinKit.text(of: hwnd)
        WinKit.setText(hwnd, WinKit.title(name))
        if before != WinKit.text(of: hwnd), IsWindowVisible(hwnd) { _ = NotifyWinEvent(0x800C /* EVENT_OBJECT_NAMECHANGE */, hwnd, -4 /* OBJID_CLIENT */, 0) }
        _ = InvalidateRect(hwnd, nil, false)
    }

    /// The button's size: its widest entry (or the shown text) and the chevron, at most `maxComboWidth`.
    fileprivate func comboSize() -> CGSize {
        var widest: Int32 = 0
        for text in items + [comboDisplay].compactMap({ $0 }) { widest = max(widest, ctx.measure(text, font: font).cx) }
        var w = widest + ctx.px(12 + 8 + 12 + 10)
        w = max(w, ctx.px(64))
        if maxComboWidth > 0 { w = min(w, maxComboWidth) }
        return CGSize(width: CGFloat(w), height: CGFloat(ctx.px(28)))
    }

    private func resizeAfterChange() {
        let before = preferredSize
        preferredSize = comboSize()
        if before != preferredSize { onSizeChange?() }
    }

    /// Another list (the core-time end hours after a new start, the accounts after a sign-in): the choice stays when it still exists.
    func setItems(_ titles: [String]) {
        guard kind == .combo, titles != items else { return }
        items = titles
        if comboSel >= titles.count { comboSel = titles.isEmpty ? -1 : 0 }
        refreshComboText()
        resizeAfterChange()
    }

    /// A drop-down that shows `title` instead of an entry (the Representative Pokémon button).
    func setDisplay(_ title: String) {
        guard kind == .combo, comboDisplay != title else { return }
        comboDisplay = title
        refreshComboText()
        resizeAfterChange()
    }

    /// The row's label: "Label: value" is the accessible name.
    func setAccessibleLabel(_ label: String) {
        guard kind == .combo || kind == .stepper, accessibleLabel != label else { return }
        accessibleLabel = label
        if kind == .combo { refreshComboText() } else { refreshStepperText() }
    }

    /// Opens the menu under the button: the entries, the chosen one checked; the pick sets the value.
    func openMenu() {
        guard kind == .combo, isEnabled, !items.isEmpty else { return }
        let entries: [TrayMenuModel.Item?] = items.enumerated().map { i, title in
            TrayMenuModel.Item(title: title, enabled: true, checked: i == comboSel, action: .none)
        }
        menuOpens += 1
        var r = RECT()
        _ = GetWindowRect(hwnd, &r)
        let owner = GetAncestor(hwnd, 2 /* GA_ROOT */) ?? hwnd
        let chosen = Self.testMenu?(entries) ?? WinPopupMenu.run(entries, at: POINT(x: r.left, y: r.bottom), owner: owner, below: true)
        guard let chosen, chosen != comboSel else { return }
        comboSel = chosen
        refreshComboText()
        onSelect?(chosen)
    }

    /// Up, Down, Home and End change the value without opening, F4 opens (the combo box's keys); true when handled.
    fileprivate func comboKey(_ key: Int) -> Bool {
        guard !customMenu || key == 0x73 else { return false }
        func pick(_ i: Int) -> Bool {
            guard items.indices.contains(i), i != comboSel else { return true }
            comboSel = i
            refreshComboText()
            onSelect?(i)
            return true
        }
        switch key {
        case 0x26: return pick(max(0, comboSel - 1))  // VK_UP
        case 0x28: return pick(min(items.count - 1, comboSel + 1))  // VK_DOWN
        case 0x24: return pick(0)  // VK_HOME
        case 0x23: return pick(items.count - 1)  // VK_END
        case 0x73: openMenu(); return true  // VK_F4
        default: return false
        }
    }

    // MARK: stepper

    fileprivate func refreshStepperText() {
        guard kind == .stepper else { return }
        let name = (accessibleLabel.map { "\($0): " } ?? "") + format(currentValue)
        let before = WinKit.text(of: hwnd)
        WinKit.setText(hwnd, WinKit.title(name))
        if before != WinKit.text(of: hwnd), IsWindowVisible(hwnd) { _ = NotifyWinEvent(0x800C, hwnd, -4, 0) }  // the value is announced as a name change
        _ = InvalidateRect(hwnd, nil, false)
    }

    /// The text the stepper draws: "×N".
    var stepperShown: String { format(currentValue) }

    /// Which half of the spin box a client point is in: 1 the upper, 2 the lower, 0 outside it.
    fileprivate func half(at lParam: LPARAM) -> Int {
        let p = WinKit.point(lParam)
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        guard p.x >= client.right - ctx.px(18), p.x < client.right, p.y >= client.top, p.y < client.bottom else { return 0 }
        return p.y < (client.top + client.bottom) / 2 ? 1 : 2
    }

    fileprivate func stepHalf(_ half: Int) {
        guard half != 0 else { return }
        applyValue(currentValue + (half == 1 ? step : -step), notify: true)
    }

    fileprivate func stepperKey(_ key: Int) -> Bool {
        switch key {
        case 0x26: applyValue(currentValue + step, notify: true)  // VK_UP
        case 0x28: applyValue(currentValue - step, notify: true)  // VK_DOWN
        case 0x21: applyValue(currentValue + 10 * step, notify: true)  // VK_PRIOR
        case 0x22: applyValue(currentValue - 10 * step, notify: true)  // VK_NEXT
        case 0x24: applyValue(range.lowerBound, notify: true)  // VK_HOME
        case 0x23: applyValue(range.upperBound, notify: true)  // VK_END
        default: return false
        }
        return true
    }

    /// Whether either half can still move (the range's ends dim the chevrons).
    var canStepUp: Bool { currentValue + step <= range.upperBound }
    var canStepDown: Bool { currentValue - step >= range.lowerBound }

    /// SELFTEST: the same as clicking a half.
    func clickHalf(_ half: Int) { stepHalf(half) }
}
// --- visual polish K4 (end) ---
#endif
