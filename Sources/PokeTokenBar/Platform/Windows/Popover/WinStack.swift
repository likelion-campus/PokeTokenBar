#if os(Windows)
import Foundation
import WinSDK

/// A child window of the popover that holds controls (stage 7 D6): it routes their notifications (`WinControlRouter`),
/// paints its background (`paint`, default the window colour) also for themed controls that ask their parent to
/// (`WM_PRINTCLIENT`), and gives Tab a way in (`WS_EX_CONTROLPARENT`). Paints only on invalidation.
@MainActor final class WinPane {
    static let className = "PokeTokenBarPane"
    let window: WinSinkWindow
    var hwnd: HWND { window.hwnd }
    let ctx: WinUIContext
    /// Draws the background into the DC for the dirty rect; nil fills the window colour.
    var paint: ((HDC, RECT) -> Void)?
    private var router: WinControlRouter?
    private(set) var paints = 0

    init(parent: HWND, ctx: WinUIContext, rect: RECT) throws {
        self.ctx = ctx
        let style: DWORD = 0x4000_0000 | 0x1000_0000 | 0x0200_0000  // WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN
        window = try WinSinkWindow(className: Self.className, title: "", style: style, exStyle: 0x0001_0000 /* WS_EX_CONTROLPARENT */,
                                   x: rect.left, y: rect.top, width: rect.right - rect.left, height: rect.bottom - rect.top, parent: parent)
        router = WinControlRouter(window: window)
        window.on(0x0014 /* WM_ERASEBKGND */) { [weak self] _, _ in WinOpenTrace.note(.erase, self?.hwnd); return 1 }  // WM_PAINT draws everything (no flicker)
        window.on(0x000F /* WM_PAINT */) { [weak self] _, _ in self?.onPaint() }
        window.on(0x0318 /* WM_PRINTCLIENT */) { [weak self] wParam, _ in
            guard let self, let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
            var r = RECT()
            _ = GetClientRect(self.hwnd, &r)
            self.draw(dc, r)
            return 0
        }
        window.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
        // A multi-line edit in dialog mode posts WM_CLOSE to its parent on Esc; DefWindowProc would destroy the page.
        window.on(0x0010 /* WM_CLOSE */) { _, _ in 0 }
    }

    private func onPaint() -> LRESULT {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return 0 }
        paints += 1
        WinOpenTrace.note(.paint, hwnd)
        draw(dc, ps.rcPaint)
        _ = EndPaint(hwnd, &ps)
        return 0
    }

    func draw(_ dc: HDC, _ r: RECT) {
        if let paint { paint(dc, r); return }
        var rr = r
        _ = FillRect(dc, &rr, ctx.colors.brush(ctx.colors.palette.window))
    }

    func move(_ r: RECT) { WinKit.move(hwnd, r) }

    func invalidate() { _ = InvalidateRect(hwnd, nil, false) }

    func destroy() {
        router?.detach()
        router = nil
        window.destroy()
    }
}

/// A page of the popover laid out top to bottom (stage 7 D6): sections, each an uppercase caption over a card of rows with
/// dividers (the Mac's inset-grouped Settings look) or rows stacked plainly. A row is a label (and hint) on the left and a
/// control on the right, a check box across the row, or a control across the row. The frames come from the shared
/// `PopoverStackLayout` in device pixels; visibility changes lay the page out again (once per main-queue turn), and nothing
/// else moves a control. The pane paints the window colour, the cards and the dividers under the controls.
@MainActor final class WinStack {
    let pane: WinPane
    var ctx: WinUIContext { pane.ctx }
    private(set) var sections: [WinSectionCard] = []
    /// The page's width in pixels.
    var width: Int32 { didSet { if oldValue != width { setNeedsLayout() } } }
    private(set) var frames: PopoverStackFrames?
    /// The page's height changed (a scroll area sets its content height).
    var onHeight: ((Int32) -> Void)?
    private var layoutPending = false
    private var inLayout = false
    // --- parity: a page with metrics of its own (Home and Recap: the Mac's 14 pt padding, not Settings' 16) (begin) ---
    /// The page's metrics in device pixels: the context's (Settings) unless the page asks for its own.
    private(set) lazy var metrics: PopoverStackMetrics = ctx.metrics
    func useMetrics(_ m: PopoverStackMetrics) {
        metrics = m.pixels(dpi: Int(ctx.dpi))
        setNeedsLayout()
    }
    // --- parity (end) ---
    private var sizeRelayouts: [Date] = []
    private var loggedSizeLoop = false
    private(set) var layouts = 0
    private(set) var isDestroyed = false

    init(pane: WinPane, width: Int32) {
        self.pane = pane
        self.width = width
        pane.paint = { [weak self] dc, r in self?.paintBackground(dc, r) }
    }

    @discardableResult
    func addSection(_ caption: String? = nil, card: Bool = true) -> WinSectionCard {
        let label = caption.flatMap {
            WinControls.label($0.uppercased(), style: .caption, weight: 600, role: .secondary, in: pane.hwnd, ctx: ctx)
        }
        let section = WinSectionCard(stack: self, caption: label, card: card)
        sections.append(section)
        setNeedsLayout()
        return section
    }

    // --- parity: a Divider() between two regions (begin) ---
    /// A one-pixel rule between regions (the Mac's `Divider()`): shown or hidden with its region.
    @discardableResult
    func addRule(spacingAbove: CGFloat? = nil) -> WinSectionCard {
        let section = WinSectionCard(stack: self, caption: nil, card: false)
        section.isRule = true
        section.spacingAbove = spacingAbove
        sections.append(section)
        setNeedsLayout()
        return section
    }
    // --- parity (end) ---

    /// Every control of the page in creation (= Tab) order.
    var controls: [WinControl] {
        sections.flatMap { s in [s.caption].compactMap { $0 } + s.rows.flatMap { [$0.nameLabel, $0.label, $0.control, $0.hint].compactMap { $0 } } }
    }

    func setNeedsLayout() {
        guard !layoutPending, !isDestroyed else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in self?.layoutIfNeeded() }
    }

    func layoutIfNeeded() {
        guard layoutPending else { return }
        layout()
    }

    /// Lays the page out now and moves every control to its frame. Controls whose height follows their width (drawn parts)
    /// are measured at their row's width first, and the pass runs again when one changed, so nothing is placed with a stale
    /// height. Afterwards the windows' z-order (= Tab order, and the static before a field is its accessible name) is the
    /// layout's reading order, whatever order the rows were added in.
    func layout() {
        guard !isDestroyed, !inLayout else { return }
        inLayout = true
        defer { inLayout = false }
        layoutPending = false
        layouts += 1
        WakeTrace.count("stackLayout")
        func input() -> [PopoverStackSection] {
            sections.map { s in
                PopoverStackSection(caption: s.caption.map { $0.size(width: width) }, isVisible: s.isVisible, card: s.card, rows: s.rows.map { row in
                    PopoverStackRow(style: row.style, isVisible: row.isVisible, control: row.control?.preferredSize) { [weak row] w in
                        (row?.label?.size(width: Int32(w)), row?.hint?.size(width: Int32(w)))
                    }
                }, isRule: s.isRule, spacingAbove: s.spacingAbove.map { CGFloat(ctx.px($0)) }, rowSpacing: s.rowSpacing.map { CGFloat(ctx.px($0)) })
            }
        }
        var f = PopoverStackLayout.layout(input(), width: CGFloat(width), metrics: metrics)
        var refitted = false
        for (section, sf) in zip(sections, f.sections) {
            guard let sf else { continue }
            for (row, rf) in zip(section.rows, sf.rows) {
                if let fit = row.control?.fitWidth, let cf = rf?.control, fit(Int32(cf.width)) { refitted = true }
            }
        }
        if refitted { f = PopoverStackLayout.layout(input(), width: CGFloat(width), metrics: metrics) }
        let palette = ctx.colors.palette
        for (section, sf) in zip(sections, f.sections) {
            guard let sf else {
                section.caption?.setVisible(false)
                for row in section.rows { row.show(nil, background: palette.window) }
                continue
            }
            if let caption = section.caption, let r = sf.caption {
                caption.background = palette.window
                caption.frame(WinKit.rect(r))
                caption.setVisible(true)
            }
            for (row, rf) in zip(section.rows, sf.rows) { row.show(rf, background: section.card ? palette.card : palette.window) }
        }
        orderWindows()
        let oldHeight = frames?.height
        WinOpenTrace.note(.layout, pane.hwnd, moved: frames != f)   // the settings-open trace: a pass that moved rows
        frames = f
        if oldHeight != f.height { onHeight?(Int32(f.height)) }
        pane.invalidate()
    }

    /// The pane's children in the page's reading order: caption, then per row its accessible name, label, control (all its
    /// windows) and hint. Siblings do not overlap, so the move repaints nothing.
    private func orderWindows() {
        var previous: HWND?
        for section in sections {
            let rows = section.rows.flatMap { [$0.nameLabel, $0.label, $0.control, $0.hint].compactMap { $0 } }
            for control in [section.caption].compactMap({ $0 }) + rows {
                for part in control.parts {
                    let flags = UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOREDRAW | SWP_NOOWNERZORDER)
                    _ = SetWindowPos(part, previous /* nil: HWND_TOP */, 0, 0, 0, 0, flags /* SWP_NOACTIVATE */)
                    previous = part
                }
            }
        }
    }

    /// A control's own size changed (a drawn part's state): one more layout on the next main-queue turn. More than eight of
    /// those within a second is a part whose size feeds back into its layout: logged once and dropped, not looped on.
    fileprivate func sizeChanged() {
        guard !inLayout, !isDestroyed else { return }
        let now = Date()
        sizeRelayouts = sizeRelayouts.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard sizeRelayouts.count <= 8 else {
            if !loggedSizeLoop { AppLog.write("popover kit: a control keeps changing its size; the page stops following it for now") }
            loggedSizeLoop = true
            return
        }
        setNeedsLayout()
    }

    /// The window colour, then each card (rounded, its border) and the dividers, under the controls (`WS_CLIPCHILDREN`).
    private func paintBackground(_ dc: HDC, _ dirty: RECT) {
        let colors = ctx.colors
        var r = dirty
        _ = FillRect(dc, &r, colors.brush(colors.palette.window))
        guard let f = frames else { return }
        let radius = Int32(metrics.cardRadius)
        let hairline = max(1, ctx.px(1))
        // All the cards of the page in one bind of the painter (its cost is per bind).
        var cards: [WinPaint.Item] = []
        for case let s? in f.sections {
            guard let card = s.card else { continue }
            cards.append(WinPaint.Item(rect: WinKit.rect(card), radius: radius, fill: WinPaint.Ink(color: colors.palette.card),
                                       stroke: WinPaint.Ink(color: colors.palette.cardBorder), strokeWidth: hairline))
        }
        WinPaint.roundedRects(dc, cards, under: colors.palette.window, ctx: ctx, clip: dirty)
        for case let s? in f.sections {
            for d in s.dividers {
                var dr = WinKit.rect(d)
                dr.left += 1
                dr.right -= 1
                _ = FillRect(dc, &dr, colors.brush(colors.palette.divider))
            }
        }
    }

    /// Commits changed fields and destroys every control (the pane stays: its owner destroys it).
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        for c in controls { c.destroy() }
        sections = []
        pane.paint = nil
    }
}

/// One section of a `WinStack`.
@MainActor final class WinSectionCard {
    private weak var stack: WinStack?
    let caption: WinControl?
    let card: Bool
    // --- parity: a rule, and the Mac's tighter spacing for a region (DIP) (begin) ---
    fileprivate(set) var isRule = false
    var spacingAbove: CGFloat? { didSet { if oldValue != spacingAbove { stack?.setNeedsLayout() } } }
    var rowSpacing: CGFloat? { didSet { if oldValue != rowSpacing { stack?.setNeedsLayout() } } }
    // --- parity (end) ---
    private(set) var rows: [WinRow] = []
    var isVisible = true { didSet { if oldValue != isVisible { stack?.setNeedsLayout() } } }

    fileprivate init(stack: WinStack, caption: WinControl?, card: Bool) {
        self.stack = stack
        self.caption = caption
        self.card = card
    }

    /// A row with a label (and a hint in the tertiary colour under it) and the control `make` builds in the stack's pane.
    /// The page keeps its windows in reading order (Tab order), and the static right before an edit, a combo box or a slider
    /// is its accessible name: a row without a label passes `accessibleName` (a zero-size static) for those, and the
    /// selftest's tree check fails a field without one.
    @discardableResult
    func addRow(_ label: String?, hint: String? = nil, style: PopoverStackRow.Style = .trailing, accessibleName: String? = nil,
                make: (HWND, WinUIContext) -> WinControl?) -> WinRow {
        guard let stack else { return WinRow(style: style, label: nil, hint: nil, control: nil) }
        let pane = stack.pane.hwnd, ctx = stack.ctx
        let labelControl = label.flatMap { WinControls.label($0, in: pane, ctx: ctx) }
        let nameControl = label == nil ? accessibleName.flatMap { WinControls.label($0, wraps: false, in: pane, ctx: ctx) } : nil
        let control = make(pane, ctx)
        let hintControl = hint.flatMap { WinControls.label($0, style: .caption2, role: .tertiary, in: pane, ctx: ctx) }
        let row = WinRow(style: style, label: labelControl, hint: hintControl, control: control)
        row.nameLabel = nameControl
        return append(row)
    }

    /// A toggle row (`toggleRow`): a check box that is its own label, across the row with the box on the right, the hint under it.
    @discardableResult
    func addToggle(_ title: String, hint: String? = nil, isOn: Bool) -> WinRow {
        addRow(nil, hint: hint, style: .toggle) { pane, ctx in WinControls.checkbox(title, isOn: isOn, in: pane, ctx: ctx) }
    }

    private func append(_ row: WinRow) -> WinRow {
        row.section = self
        rows.append(row)
        row.control?.onSizeChange = { [weak stack] in stack?.sizeChanged() }
        stack?.setNeedsLayout()
        return row
    }

    fileprivate func rowVisibilityChanged() { stack?.setNeedsLayout() }

    // --- stage 7 Task 14: the page's width, for a row that picks one line or two when it is built (begin) ---
    /// The page's width in pixels (0 once the page is gone).
    var pageWidth: Int32 { stack?.width ?? 0 }
    // --- stage 7 Task 14 (end) ---

    // --- stage 7 Task 5: a page region that is made again when its model changes (begin) ---
    /// Destroys every row's controls and forgets the rows; the page lays out again. A region of a page built from a model
    /// (the Home page's limits) makes its rows again when that part of the model changed, and the rest of the page stays.
    func removeRows() {
        for row in rows { [row.label, row.control, row.hint].compactMap { $0 }.forEach { $0.destroy() } }
        rows = []
        stack?.setNeedsLayout()
    }

    /// A row whose label is a control of the caller's making (a text style the Mac's row label, always `body`, does not
    /// have), made first like `addRow`'s: it wraps at the row's width, with `hint` under it and `make`'s control beside it.
    @discardableResult
    func addStyledRow(label makeLabel: ((HWND, WinUIContext) -> WinControl?)?, hint: String? = nil, style: PopoverStackRow.Style = .trailing,
                      make: (HWND, WinUIContext) -> WinControl? = { _, _ in nil }) -> WinRow {
        guard let stack else { return WinRow(style: style, label: nil, hint: nil, control: nil) }
        let pane = stack.pane.hwnd, ctx = stack.ctx
        let labelControl = makeLabel?(pane, ctx)
        let control = make(pane, ctx)
        let hintControl = hint.flatMap { WinControls.label($0, style: .caption2, role: .tertiary, in: pane, ctx: ctx) }
        return append(WinRow(style: style, label: labelControl, hint: hintControl, control: control))
    }
    // --- stage 7 Task 5: a page region that is made again when its model changes (end) ---
}

/// One row of a section: shown or hidden by `isVisible` (the page lays out again).
@MainActor final class WinRow {
    fileprivate weak var section: WinSectionCard?
    let style: PopoverStackRow.Style
    let label: WinControl?
    let hint: WinControl?
    let control: WinControl?
    /// The accessible name of a control without a label (a zero-size static just before it).
    fileprivate(set) var nameLabel: WinControl?
    var isVisible = true { didSet { if oldValue != isVisible { section?.rowVisibilityChanged() } } }

    fileprivate init(style: PopoverStackRow.Style, label: WinControl?, hint: WinControl?, control: WinControl?) {
        self.style = style
        self.label = label
        self.hint = hint
        self.control = control
    }

    fileprivate func show(_ frames: PopoverStackFrames.Row?, background: COLORREF) {
        let nameFrame = frames?.control.map { CGRect(x: $0.minX, y: $0.minY, width: 0, height: 0) }
        let parts: [(WinControl?, CGRect?)] = [(nameLabel, nameFrame), (label, frames?.label), (hint, frames?.hint), (control, frames?.control)]
        for (c, r) in parts {
            guard let c else { continue }
            c.background = background
            if let r {
                c.frame(WinKit.rect(r))
                c.setVisible(true)
            } else {
                c.setVisible(false)
            }
        }
    }
}
#endif
