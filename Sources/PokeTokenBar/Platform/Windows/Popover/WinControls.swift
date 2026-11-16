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
    fileprivate var hot = false
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
        case .button, .glyphButton, .checkbox, .radioGroup, .drawnItem: true
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
            case .combo: WinKit.send(hwnd, 0x0147 /* CB_GETCURSEL */)
            case .tabs: WinKit.send(hwnd, 0x130B /* TCM_GETCURSEL */)
            case .radioGroup: parts.firstIndex { WinKit.send($0, 0x00F0) == 1 } ?? -1
            default: -1
            }
        }
        set {
            switch kind {
            case .combo: WinKit.send(hwnd, 0x014E /* CB_SETCURSEL */, newValue)
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
        return CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy))
    }

    // MARK: placement

    func frame(_ r: RECT) {
        if let onFrame { onFrame(r); return }
        let w = r.right - r.left
        switch kind {
        case .radioGroup:
            let n = Int32(parts.count)
            for (i, part) in parts.enumerated() {
                let x0 = r.left + w * Int32(i) / n, x1 = r.left + w * Int32(i + 1) / n
                WinKit.move(part, RECT(left: x0, top: r.top, right: x1, bottom: r.bottom))
            }
        case .trackbar where parts.count == 2:
            let valueW = Int32(valueWidth), gap = ctx.px(6)
            WinKit.move(parts[0], RECT(left: r.left, top: r.top, right: r.right - valueW - gap, bottom: r.bottom))
            WinKit.move(parts[1], RECT(left: r.right - valueW, top: r.top, right: r.right, bottom: r.bottom))
        case .stepper where parts.count == 2:
            let arrows = ctx.px(17)
            WinKit.move(parts[0], RECT(left: r.left, top: r.top, right: r.right - arrows, bottom: r.bottom))
            WinKit.move(parts[1], RECT(left: r.right - arrows, top: r.top, right: r.right, bottom: r.bottom))
        case .combo:
            // A drop-down list's window height is the height of the open list; the closed field sizes itself to the font.
            WinKit.move(hwnd, RECT(left: r.left, top: r.top, right: r.right, bottom: r.top + ctx.px(260)))
        default:
            WinKit.move(hwnd, r)
        }
    }

    fileprivate var valueWidth: CGFloat = 0

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
            WinKit.setText(parts[0], format(snapped))
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
        switch message {
        case 0x0007:  // WM_SETFOCUS: keyboard focus inside a scroll area brings the control into view
            if GetKeyState(0x01 /* VK_LBUTTON */) >= 0 { WinScrollArea.reveal(hwnd) }
            return nil
        case 0x0008:  // WM_KILLFOCUS: a field commits when the focus leaves it
            if c.kind == .edit { c.commitIfChanged() }
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
        case .button, .glyphButton, .drawnItem: true
        default: false
        }
    }

    fileprivate func clicked(_ part: HWND) {
        clicks += 1
        switch kind {
        case .checkbox: onToggle?(isOn)
        case .radioGroup: if let i = parts.firstIndex(of: part) { onSelect?(i) }
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
        case (.button, 0), (.glyphButton, 0), (.checkbox, 0), (.radioGroup, 0), (.drawnItem, 0):  // BN_CLICKED
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
        switch (c.kind, code) {
        case (.link, -2), (.link, -4):  // NM_CLICK, NM_RETURN
            c.clicked(c.hwnd)
            return 0
        case (.tabs, -551):  // TCN_SELCHANGE
            c.onSelect?(c.selection)
            return 0
        case (.stepper, -722):  // UDN_DELTAPOS: the kit keeps the value; the up-down's own position never moves
            let delta = header.withMemoryRebound(to: NMUPDOWN.self, capacity: 1) { Int($0.pointee.iDelta) }
            c.applyValue(c.currentValue + delta * c.step, notify: true)
            return 1
        default:
            return nil
        }
    }

    private static func scroll(_ lParam: LPARAM) -> LRESULT? {
        guard let part = HWND(bitPattern: Int(lParam)), let c = WinControl.control(part), c.kind == .trackbar else { return nil }
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
        if message == 0x0133 || message == 0x0134 { return nil }  // edits and lists draw as the system draws them
        if colors.highContrast {
            guard message == 0x0138 else { return nil }
            _ = SetBkColor(dc, GetSysColor(5))
            _ = SetTextColor(dc, GetSysColor(8))
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(GetSysColorBrush(5))))
        }
        _ = SetBkColor(dc, c.background)
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
                      wraps: Bool = true, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let ss: DWORD = (wraps ? 0x0000 /* SS_LEFT */ : 0x000C /* SS_LEFTNOWORDWRAP */ | 0x4000 /* SS_ENDELLIPSIS */) | 0x0080 /* SS_NOPREFIX */
        guard let h = WinKit.create("Static", text, style: child | ss, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(style, weight: weight)
        WinKit.setFont(h, font)
        let s = ctx.measure(text, font: font)
        let c = WinControl(kind: .label, ctx: ctx, parts: [h], size: CGSize(width: CGFloat(s.cx), height: CGFloat(s.cy)),
                           background: ctx.colors.palette.window, font: font)
        c.role = role
        return c
    }

    static func button(_ title: String, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard let h = WinKit.create("Button", WinKit.title(title), style: child | tabStop | group | 0x0000 /* BS_PUSHBUTTON */, parent: parent, id: id())
        else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        let s = ctx.measure(title, font: font)
        return WinControl(kind: .button, ctx: ctx, parts: [h],
                          size: CGSize(width: CGFloat(s.cx + ctx.px(24)), height: CGFloat(max(s.cy + ctx.px(10), ctx.px(26)))),
                          background: ctx.colors.palette.window, font: font)
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

    /// A check box that spans its row with the box on the right and the label on the left (the Mac's toggle rows,
    /// Windows 11 Settings' switches); the label is its accessible name.
    static func checkbox(_ title: String, isOn: Bool, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let bs: DWORD = 0x0003 /* BS_AUTOCHECKBOX */ | 0x0020 /* BS_LEFTTEXT, BS_RIGHTBUTTON */ | 0x2000 /* BS_MULTILINE */
        guard let h = WinKit.create("Button", WinKit.title(title), style: child | tabStop | group | bs, parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        let s = ctx.measure(title, font: font)
        let c = WinControl(kind: .checkbox, ctx: ctx, parts: [h],
                           size: CGSize(width: CGFloat(s.cx + WinKit.metric(71 /* SM_CXMENUCHECK */, dpi: ctx.dpi) + ctx.px(8)),
                                        height: CGFloat(max(s.cy, WinKit.metric(72 /* SM_CYMENUCHECK */, dpi: ctx.dpi)) + ctx.px(2))),
                           background: ctx.colors.palette.window, font: font)
        c.isOn = isOn
        return c
    }

    /// Push-like radio buttons side by side (the Mac's segmented pickers): one Tab stop, arrows move inside the group.
    static func radioGroup(_ titles: [String], selected: Int, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        guard !titles.isEmpty else { return nil }
        let font = ctx.fonts.font(.callout)
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
                           size: CGSize(width: CGFloat((widest + ctx.px(20)) * Int32(parts.count)), height: CGFloat(height + ctx.px(10))),
                           background: ctx.colors.palette.window, font: font)
        c.selection = selected
        return c
    }

    /// A drop-down list (the Mac's menu pickers).
    static func combo(_ items: [String], selected: Int, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        let style = child | tabStop | group | 0x0003 /* CBS_DROPDOWNLIST */ | 0x0020_0000 /* WS_VSCROLL */
        guard let h = WinKit.create("ComboBox", "", style: style, parent: parent, id: id(),
                                    rect: RECT(left: 0, top: 0, right: 100, bottom: ctx.px(260))) else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        var widest: Int32 = 0
        for item in items {
            WinKit.send(h, 0x0143 /* CB_ADDSTRING */, 0, text: item)
            widest = max(widest, ctx.measure(item, font: font).cx)
        }
        WinKit.send(h, 0x1701 /* CB_SETMINVISIBLE */, min(12, max(1, items.count)))
        var r = RECT()
        _ = GetWindowRect(h, &r)
        let c = WinControl(kind: .combo, ctx: ctx, parts: [h],
                           size: CGSize(width: CGFloat(widest + WinKit.metric(2 /* SM_CXVSCROLL */, dpi: ctx.dpi) + ctx.px(18)),
                                        height: CGFloat(r.bottom - r.top)),
                           background: ctx.colors.palette.window, font: font)
        c.selection = selected
        return c
    }

    /// A text field of `kind` (D5), `width` DIP wide when given (grown with Windows' text size, as its text grows), else the
    /// row's width.
    static func edit(_ kind: WinEditKind, text: String = "", width: CGFloat? = nil, in parent: HWND, ctx: WinUIContext) -> WinControl? {
        var es: DWORD = 0x0080  // ES_AUTOHSCROLL
        var lines = 1
        switch kind {
        case .password: es |= 0x0020  // ES_PASSWORD
        case .multiLine(let n, _):
            es = 0x0004 | 0x0040 | 0x0020_0000  // ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL (no ES_WANTRETURN: Enter commits)
            lines = max(1, n)
        default: break
        }
        guard let h = WinKit.create("Edit", text, style: child | tabStop | group | es, exStyle: 0x0200 /* WS_EX_CLIENTEDGE */,
                                    parent: parent, id: id()) else { return nil }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(h, font)
        if let cue = kind.cue { WinKit.send(h, 0x1501 /* EM_SETCUEBANNER */, 1, text: cue) }
        let line = ctx.lineHeight(font)
        let c = WinControl(kind: .edit, ctx: ctx, parts: [h],
                           size: CGSize(width: width.map { CGFloat(ctx.px($0 * CGFloat(ctx.textScale))) } ?? 100_000,
                                        height: CGFloat(line * Int32(lines) + ctx.px(10))),
                           background: ctx.colors.palette.window, font: font)
        c.editKind = kind
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
        let c = WinControl(kind: .trackbar, ctx: ctx, parts: [bar, valueText], size: CGSize(width: CGFloat(ctx.px(width)), height: CGFloat(ctx.px(26))),
                           background: ctx.colors.palette.window, font: font)
        c.range = range
        c.step = step
        c.format = format
        c.valueWidth = CGFloat(valueW)
        c.currentValue = Self.unset
        c.applyValue(value, notify: false)
        return c
    }

    /// The Mac's `Stepper`: the value as read-only text (focusable: the arrow keys step it) and up/down arrows.
    static func stepper(range: ClosedRange<Int>, step: Int, value: Int, format: @escaping (Int) -> String, in parent: HWND,
                        ctx: WinUIContext) -> WinControl? {
        guard let field = WinKit.create("Edit", "", style: child | tabStop | group | 0x0800 /* ES_READONLY */ | 0x0002 /* ES_RIGHT */,
                                        exStyle: 0x0200, parent: parent, id: id()) else { return nil }
        let udStyle = child | 0x0020 /* UDS_ARROWKEYS */ | 0x0100 /* UDS_HOTTRACK */
        guard let arrows = WinKit.create("msctls_updown32", "", style: udStyle, parent: parent, id: id()) else {
            _ = DestroyWindow(field)
            return nil
        }
        let font = ctx.fonts.font(.body)
        WinKit.setFont(field, font)
        WinKit.send(arrows, 0x0469 /* UDM_SETBUDDY */, Int(bitPattern: UnsafeMutableRawPointer(field)))
        WinKit.send(arrows, 0x046F /* UDM_SETRANGE32 */, 0, 100)
        WinKit.send(arrows, 0x0471 /* UDM_SETPOS32 */, 0, 50)
        let valueW = max(ctx.measure(format(range.lowerBound), font: font).cx, ctx.measure(format(range.upperBound), font: font).cx)
        let c = WinControl(kind: .stepper, ctx: ctx, parts: [field, arrows],
                           size: CGSize(width: CGFloat(valueW + ctx.px(17 + 14)), height: CGFloat(ctx.lineHeight(font) + ctx.px(10))),
                           background: ctx.colors.palette.window, font: font)
        c.range = range
        c.step = step
        c.format = format
        c.currentValue = Self.unset
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
        let d = dis.pointee
        let state = d.itemState
        let colors = c.ctx.colors.palette
        let pressed = state & 0x0001 != 0, disabled = state & 0x0004 != 0, focused = state & 0x0010 != 0, hideFocus = state & 0x0200 != 0
        var r = d.rcItem
        let fill = pressed ? colors.pressed : (c.hot ? colors.hot : c.background)
        _ = FillRect(d.hDC, &r, c.ctx.colors.brush(fill))
        if let glyph = c.glyph {
            let old = SelectObject(d.hDC, UnsafeMutableRawPointer(c.font))
            _ = SetBkMode(d.hDC, 1 /* TRANSPARENT */)
            _ = SetTextColor(d.hDC, disabled ? GetSysColor(17 /* COLOR_GRAYTEXT */) : (pressed && c.ctx.highContrast ? GetSysColor(14) : colors.text))
            _ = WinStr.w(glyph.text).withUnsafeBufferPointer {
                DrawTextW(d.hDC, $0.baseAddress, -1, &r, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX))
            }
            _ = SelectObject(d.hDC, old)
        }
        if focused, !hideFocus {
            var f = d.rcItem
            _ = InflateRect(&f, -c.ctx.px(2), -c.ctx.px(2))
            _ = DrawFocusRect(d.hDC, &f)
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
#endif
