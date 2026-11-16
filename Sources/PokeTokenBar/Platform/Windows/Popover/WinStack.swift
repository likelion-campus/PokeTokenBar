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
        window.on(0x0014 /* WM_ERASEBKGND */) { _, _ in 1 }  // WM_PAINT draws everything (no flicker)
        window.on(0x000F /* WM_PAINT */) { [weak self] _, _ in self?.onPaint() }
        window.on(0x0318 /* WM_PRINTCLIENT */) { [weak self] wParam, _ in
            guard let self, let dc = HDC(bitPattern: UInt(wParam)) else { return nil }
            var r = RECT()
            _ = GetClientRect(self.hwnd, &r)
            self.draw(dc, r)
            return 0
        }
        window.on(0x0020 /* WM_SETCURSOR */) { _, lParam in WinKit.arrowCursor(lParam) }
    }

    private func onPaint() -> LRESULT {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return 0 }
        paints += 1
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
    private var borderPen: HPEN?
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

    /// Every control of the page in creation (= Tab) order.
    var controls: [WinControl] {
        sections.flatMap { s in [s.caption].compactMap { $0 } + s.rows.flatMap { [$0.label, $0.control, $0.hint].compactMap { $0 } } }
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

    /// Lays the page out now and moves every control to its frame.
    func layout() {
        guard !isDestroyed else { return }
        layoutPending = false
        layouts += 1
        let input = sections.map { s in
            PopoverStackSection(caption: s.caption.map { $0.size(width: width) }, isVisible: s.isVisible, card: s.card, rows: s.rows.map { row in
                PopoverStackRow(style: row.style, isVisible: row.isVisible, control: row.control?.preferredSize) { [weak row] w in
                    (row?.label?.size(width: Int32(w)), row?.hint?.size(width: Int32(w)))
                }
            })
        }
        let f = PopoverStackLayout.layout(input, width: CGFloat(width), metrics: ctx.metrics)
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
        let oldHeight = frames?.height
        frames = f
        if oldHeight != f.height { onHeight?(Int32(f.height)) }
        pane.invalidate()
    }

    /// The window colour, then each card (rounded, its border) and the dividers, under the controls (`WS_CLIPCHILDREN`).
    private func paintBackground(_ dc: HDC, _ dirty: RECT) {
        let colors = ctx.colors
        var r = dirty
        _ = FillRect(dc, &r, colors.brush(colors.palette.window))
        guard let f = frames else { return }
        if borderPen == nil { borderPen = CreatePen(0 /* PS_SOLID */, max(1, ctx.px(1)), colors.palette.cardBorder) }
        let oldPen = SelectObject(dc, UnsafeMutableRawPointer(borderPen))
        let oldBrush = SelectObject(dc, UnsafeMutableRawPointer(colors.brush(colors.palette.card)))
        let radius = 2 * Int32(ctx.metrics.cardRadius)
        for case let s? in f.sections {
            if let card = s.card {
                let c = WinKit.rect(card)
                _ = RoundRect(dc, c.left, c.top, c.right, c.bottom, radius, radius)
            }
            for d in s.dividers {
                var dr = WinKit.rect(d)
                dr.left += 1
                dr.right -= 1
                _ = FillRect(dc, &dr, colors.brush(colors.palette.divider))
            }
        }
        _ = SelectObject(dc, oldBrush)
        _ = SelectObject(dc, oldPen)
    }

    /// Commits changed fields and destroys every control (the pane stays: its owner destroys it).
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        for c in controls { c.destroy() }
        sections = []
        if let pen = borderPen { _ = DeleteObject(UnsafeMutableRawPointer(pen)) }
        borderPen = nil
        pane.paint = nil
    }
}

/// One section of a `WinStack`.
@MainActor final class WinSectionCard {
    private weak var stack: WinStack?
    let caption: WinControl?
    let card: Bool
    private(set) var rows: [WinRow] = []
    var isVisible = true { didSet { if oldValue != isVisible { stack?.setNeedsLayout() } } }

    fileprivate init(stack: WinStack, caption: WinControl?, card: Bool) {
        self.stack = stack
        self.caption = caption
        self.card = card
    }

    /// A row with a label (and a hint in the tertiary colour under it), made first, then the control `make` builds in the
    /// stack's pane: creation order is Tab order, and the label right before an edit or a combo box is its accessible name.
    @discardableResult
    func addRow(_ label: String?, hint: String? = nil, style: PopoverStackRow.Style = .trailing,
                make: (HWND, WinUIContext) -> WinControl?) -> WinRow {
        guard let stack else { return WinRow(style: style, label: nil, hint: nil, control: nil) }
        let pane = stack.pane.hwnd, ctx = stack.ctx
        let labelControl = label.flatMap { WinControls.label($0, in: pane, ctx: ctx) }
        let control = make(pane, ctx)
        let hintControl = hint.flatMap { WinControls.label($0, style: .caption2, role: .tertiary, in: pane, ctx: ctx) }
        return append(WinRow(style: style, label: labelControl, hint: hintControl, control: control))
    }

    /// A toggle row (`toggleRow`): a check box that is its own label, across the row with the box on the right, the hint under it.
    @discardableResult
    func addToggle(_ title: String, hint: String? = nil, isOn: Bool) -> WinRow {
        addRow(nil, hint: hint, style: .toggle) { pane, ctx in WinControls.checkbox(title, isOn: isOn, in: pane, ctx: ctx) }
    }

    private func append(_ row: WinRow) -> WinRow {
        row.section = self
        rows.append(row)
        stack?.setNeedsLayout()
        return row
    }

    fileprivate func rowVisibilityChanged() { stack?.setNeedsLayout() }

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
    var isVisible = true { didSet { if oldValue != isVisible { section?.rowVisibilityChanged() } } }

    fileprivate init(style: PopoverStackRow.Style, label: WinControl?, hint: WinControl?, control: WinControl?) {
        self.style = style
        self.label = label
        self.hint = hint
        self.control = control
    }

    fileprivate func show(_ frames: PopoverStackFrames.Row?, background: COLORREF) {
        let parts: [(WinControl?, CGRect?)] = [(label, frames?.label), (hint, frames?.hint), (control, frames?.control)]
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
