#if os(Windows)
import Foundation
import WinSDK

/// What the popover's placement asks Windows (stage 7 D2): the icon's rectangle, the point the shell reported, the
/// monitors with their work areas and DPI, the shell's taskbar rectangle. The maths is the shared `PopoverPlacement`.
@MainActor enum WinPopoverAnchor {
    struct Inputs {
        var anchor: RECT?
        var clickPoint: POINT?
        var monitors: [PopoverPlacement.Monitor]
        var appBar: RECT?
    }

    /// The selftest's synthetic work areas (`popover.placement`): given what the system said, what to place with.
    static var environmentForTesting: ((Inputs) -> Inputs)?

    /// D2's order: the shell's icon rectangle, else the point the shell sent with the click or key (the overflow flyout, or
    /// Explorer cannot say), else the cursor (`useCursor`). A second launch passes neither and no cursor: the primary's corner.
    static func inputs(anchor: RECT?, point: POINT?, useCursor: Bool) -> Inputs {
        var click = point
        if anchor == nil, click == nil, useCursor {
            var p = POINT()
            if GetCursorPos(&p) { click = p }
        }
        var made = Inputs(anchor: anchor, clickPoint: click, monitors: monitors(), appBar: taskbarRect())
        if let environmentForTesting { made = environmentForTesting(made) }
        return made
    }

    /// `EnumDisplayMonitors` with each monitor's work area and effective DPI (the plaza's list).
    static func monitors() -> [PopoverPlacement.Monitor] {
        WinPlazaPlacement.monitors().map { m in
            PopoverPlacement.Monitor(bounds: cgRect(m.bounds), work: cgRect(m.work), dpi: Int(m.dpi), isPrimary: m.isPrimary)
        }
    }

    /// The shell's taskbar rectangle (`SHAppBarMessage(ABM_GETTASKBARPOS)`), also while it auto-hides; nil when it cannot say.
    static func taskbarRect() -> RECT? {
        var data = APPBARDATA()
        data.cbSize = DWORD(MemoryLayout<APPBARDATA>.size)
        guard SHAppBarMessage(DWORD(5 /* ABM_GETTASKBARPOS */), &data) != 0 else { return nil }
        return data.rc
    }

    static func cgRect(_ r: RECT) -> CGRect {
        CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.right - r.left), height: CGFloat(r.bottom - r.top))
    }

    static func cgRect(_ r: WinPlazaPlacement.Rect) -> CGRect {
        CGRect(x: CGFloat(r.left), y: CGFloat(r.top), width: CGFloat(r.width), height: CGFloat(r.height))
    }

    static func cgPoint(_ p: POINT) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }

    static func contains(_ r: RECT, _ p: POINT) -> Bool { p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom }
}
#endif
