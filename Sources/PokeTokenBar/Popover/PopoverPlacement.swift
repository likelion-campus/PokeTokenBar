import Foundation

/// Where the Windows popover appears (stage 7 D2): beside the tray icon, on the taskbar's side of the icon's monitor,
/// inside that monitor's work area with a margin, at that monitor's DPI. Pure and unit-agnostic; Windows passes device
/// pixels in virtual-screen coordinates (a monitor left of the primary has negative x). Shared so it is tested on both
/// systems; the Mac app does not call it. Rectangles are only storage here: overlap and containment are written out, so
/// CoreGraphics and corelibs Foundation cannot differ on an edge case.
enum PopoverPlacement {
    enum Edge: Equatable { case bottom, top, left, right }

    /// One monitor as Windows reports it (`GetMonitorInfoW` bounds and work area, `GetDpiForMonitor`).
    struct Monitor: Equatable {
        var bounds: CGRect
        var work: CGRect
        var dpi: Int
        var isPrimary: Bool
    }

    /// The window's frame (window rectangle, border included), the monitor it is on, the taskbar's side and the DPI the
    /// window is made at.
    struct Result: Equatable {
        var frame: CGRect
        var monitor: Int
        var edge: Edge
        var dpi: Int
    }

    /// The gap between the popover and the taskbar or the work area's edges (Windows 11's flyouts keep 12).
    static let marginDIP: CGFloat = 12

    /// The side the taskbar is on. The shell's taskbar rectangle (`ABM_GETTASKBARPOS`), when it lies on this monitor, says
    /// which side it hugs, also when it auto-hides and only a sliver is on the screen. Otherwise the side the work area is
    /// cut from the monitor (the deepest cut). With neither (a monitor without a taskbar): the bottom, Windows' default.
    static func taskbarEdge(monitor: CGRect, work: CGRect, appBar: CGRect?) -> Edge {
        if let bar = appBar, overlapArea(bar, monitor) > 0 {
            if bar.width >= bar.height { return bar.midY < monitor.midY ? .top : .bottom }
            return bar.midX < monitor.midX ? .left : .right
        }
        let cuts: [(Edge, CGFloat)] = [(.bottom, monitor.maxY - work.maxY), (.top, work.minY - monitor.minY),
                                       (.left, work.minX - monitor.minX), (.right, monitor.maxX - work.maxX)]
        var best: (Edge, CGFloat) = (.bottom, 0)
        for cut in cuts where cut.1 > best.1 { best = cut }
        return best.0
    }

    /// The work area without an auto-hidden taskbar's band on `edge` (it reserves nothing, but it slides in over whatever is
    /// there when the user points at it, and the popover opens right after a click on it). Its full thickness is taken,
    /// wherever the bar is at the moment. A normal taskbar already cut the work area: nothing more is taken.
    static func usableWork(monitor: CGRect, work: CGRect, appBar: CGRect?, edge: Edge) -> CGRect {
        guard let bar = appBar, overlapArea(bar, monitor) > 0 else { return work }
        var minX = work.minX, minY = work.minY, maxX = work.maxX, maxY = work.maxY
        switch edge {
        case .bottom, .top:
            guard bar.height < monitor.height / 2 else { return work }   // not a taskbar
            if edge == .bottom { maxY = min(maxY, monitor.maxY - bar.height) } else { minY = max(minY, monitor.minY + bar.height) }
        case .left, .right:
            guard bar.width < monitor.width / 2 else { return work }
            if edge == .left { minX = max(minX, monitor.minX + bar.width) } else { maxX = min(maxX, monitor.maxX - bar.width) }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The popover's frame. `size` is clamped to the work area less the margins (the page scrolls). Taskbar at the bottom or
    /// top: just above or below it, centred on the icon. Left or right: beside it, top-aligned to the icon, or bottom-aligned
    /// to it when there is no room below (flipped). An icon inside the work area (the overflow flyout, which may stay open
    /// over what is below it) is not covered: the popover keeps a margin from it on the taskbar's side. Then clamped into the
    /// work area. The icon is `anchor` (the shell's rectangle, or the flyout holding it), else `clickPoint`, else the corner
    /// at the end of the taskbar where the notification area is (a second launch with no icon rectangle). Whole pixels.
    static func frame(anchor: CGRect?, clickPoint: CGPoint?, size: CGSize, monitor: CGRect, work: CGRect,
                      edge: Edge, margin: CGFloat) -> CGRect {
        let loX = work.minX + margin, hiX = work.maxX - margin, loY = work.minY + margin, hiY = work.maxY - margin
        let w = max(0, min(size.width, hiX - loX)).rounded(.down), h = max(0, min(size.height, hiY - loY)).rounded(.down)
        let icon = anchor ?? clickPoint.map { CGRect(origin: $0, size: .zero) } ?? corner(of: work, edge: edge)
        var x: CGFloat, y: CGFloat
        switch edge {
        case .bottom:
            x = icon.midX - w / 2
            y = min(hiY, icon.minY - margin) - h
        case .top:
            x = icon.midX - w / 2
            y = max(loY, icon.maxY + margin)
        case .left, .right:
            x = edge == .left ? max(loX, icon.maxX + margin) : min(hiX, icon.minX - margin) - w
            y = icon.minY
            if y + h > hiY { y = icon.maxY - h }
        }
        x = min(max(x.rounded(), loX), hiX - w)
        y = min(max(y.rounded(), loY), hiY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The monitor of the icon: the largest overlap with `anchor`, else the one containing `clickPoint`, else the nearest
    /// (`MonitorFromRect` / `MonitorFromPoint` with `MONITOR_DEFAULTTONEAREST`). No anchor and no point: the primary.
    static func monitorIndex(anchor: CGRect?, clickPoint: CGPoint?, monitors: [Monitor]) -> Int? {
        guard !monitors.isEmpty else { return nil }
        let primary = monitors.firstIndex { $0.isPrimary } ?? 0
        let target: CGRect
        if let anchor {
            target = anchor
            var best: (index: Int, area: CGFloat)?
            for (i, m) in monitors.enumerated() {
                let a = overlapArea(anchor, m.bounds)
                if a > 0, a > (best?.area ?? 0) { best = (i, a) }
            }
            if let best { return best.index }
        } else if let p = clickPoint {
            target = CGRect(origin: p, size: .zero)
            if let i = monitors.firstIndex(where: { p.x >= $0.bounds.minX && p.x < $0.bounds.maxX && p.y >= $0.bounds.minY && p.y < $0.bounds.maxY }) {
                return i
            }
        } else {
            return primary
        }
        var nearest = primary, distance = CGFloat.greatestFiniteMagnitude
        for (i, m) in monitors.enumerated() {
            let dx = max(m.bounds.minX - target.midX, 0, target.midX - m.bounds.maxX)
            let dy = max(m.bounds.minY - target.midY, 0, target.midY - m.bounds.maxY)
            let d = dx * dx + dy * dy
            if d < distance { distance = d; nearest = i }
        }
        return nearest
    }

    /// All of it: the icon's monitor, its taskbar side and usable work area, the window size (`sizeDIP` at the monitor's DPI,
    /// or `dpi` when the window already has one, plus `framePixels` for the window's border at that DPI) and the frame.
    /// `appBar` counts only on the monitor it lies on.
    static func place(anchor: CGRect?, clickPoint: CGPoint?, sizeDIP: CGSize, monitors: [Monitor], appBar: CGRect?,
                      dpi: Int? = nil, marginDIP: CGFloat = marginDIP,
                      framePixels: (Int) -> CGSize = { _ in .zero }) -> Result? {
        guard let index = monitorIndex(anchor: anchor, clickPoint: clickPoint, monitors: monitors) else { return nil }
        let m = monitors[index]
        let windowDPI = dpi ?? m.dpi
        let scale = CGFloat(windowDPI) / 96
        let bar = appBar.flatMap { overlapArea($0, m.bounds) > 0 ? $0 : nil }
        let edge = taskbarEdge(monitor: m.bounds, work: m.work, appBar: bar)
        let work = usableWork(monitor: m.bounds, work: m.work, appBar: bar, edge: edge)
        let border = framePixels(windowDPI)
        let size = CGSize(width: (sizeDIP.width * scale).rounded() + border.width, height: (sizeDIP.height * scale).rounded() + border.height)
        let f = frame(anchor: anchor, clickPoint: clickPoint, size: size, monitor: m.bounds, work: work, edge: edge,
                      margin: (marginDIP * scale).rounded())
        return Result(frame: f, monitor: index, edge: edge, dpi: windowDPI)
    }

    // MARK: -

    /// The end of the taskbar where Windows keeps the notification area: bottom right for a horizontal taskbar's ends
    /// (right, as left-to-right Windows has it), the bottom of a vertical one.
    static func corner(of work: CGRect, edge: Edge) -> CGRect {
        switch edge {
        case .bottom, .right: return CGRect(x: work.maxX, y: work.maxY, width: 0, height: 0)
        case .top: return CGRect(x: work.maxX, y: work.minY, width: 0, height: 0)
        case .left: return CGRect(x: work.minX, y: work.maxY, width: 0, height: 0)
        }
    }

    /// The area two rectangles share (0 when they only touch or do not meet).
    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX), h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0 ? w * h : 0
    }
}
