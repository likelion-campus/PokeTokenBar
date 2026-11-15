import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 7 D2: where the Windows popover appears. Pure maths, run on both systems (device pixels, virtual-screen coordinates:
/// a monitor left of the primary has negative x). Every case: the four taskbar edges, two monitors (one at negative x and
/// another DPI), an auto-hidden taskbar, a work area smaller than the popover, a missing anchor (click point, then corner).
final class PopoverPlacementTests: XCTestCase {
    typealias P = PopoverPlacement

    // A 1920 x 1080 primary at 100 % and a 2560 x 1440 monitor at 150 % to its left (negative x), bottom-aligned.
    static let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let left = CGRect(x: -2560, y: -360, width: 2560, height: 1440)
    static let bar: CGFloat = 48

    /// The work area with a taskbar `thickness` thick on `edge` of `monitor`.
    static func work(_ monitor: CGRect, _ edge: P.Edge, _ thickness: CGFloat = bar) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: monitor.minX, y: monitor.minY, width: monitor.width, height: monitor.height - thickness)
        case .top: return CGRect(x: monitor.minX, y: monitor.minY + thickness, width: monitor.width, height: monitor.height - thickness)
        case .left: return CGRect(x: monitor.minX + thickness, y: monitor.minY, width: monitor.width - thickness, height: monitor.height)
        case .right: return CGRect(x: monitor.minX, y: monitor.minY, width: monitor.width - thickness, height: monitor.height)
        }
    }

    /// The taskbar band itself.
    static func band(_ monitor: CGRect, _ edge: P.Edge, _ thickness: CGFloat = bar) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: monitor.minX, y: monitor.maxY - thickness, width: monitor.width, height: thickness)
        case .top: return CGRect(x: monitor.minX, y: monitor.minY, width: monitor.width, height: thickness)
        case .left: return CGRect(x: monitor.minX, y: monitor.minY, width: thickness, height: monitor.height)
        case .right: return CGRect(x: monitor.maxX - thickness, y: monitor.minY, width: thickness, height: monitor.height)
        }
    }

    /// A 32 x 32 tray icon inside the band, towards the end where Windows keeps the notification area (far enough from the
    /// corner that a centred popover fits; the clamp at the corner has its own test).
    static func icon(_ monitor: CGRect, _ edge: P.Edge, _ thickness: CGFloat = bar) -> CGRect {
        let b = band(monitor, edge, thickness)
        switch edge {
        case .bottom, .top: return CGRect(x: b.maxX - 400, y: b.midY - 16, width: 32, height: 32)
        case .left, .right: return CGRect(x: b.midX - 16, y: b.maxY - 120, width: 32, height: 32)
        }
    }

    /// A positive-area overlap, written out (CoreGraphics and corelibs Foundation differ on empty-rect edge cases).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) > max(a.minX, b.minX) && min(a.maxY, b.maxY) > max(a.minY, b.minY)
    }

    static func inside(_ r: CGRect, _ work: CGRect, margin: CGFloat) -> Bool {
        r.minX >= work.minX + margin && r.maxX <= work.maxX - margin && r.minY >= work.minY + margin && r.maxY <= work.maxY - margin
    }

    // MARK: - the taskbar edge

    func testTheEdgeIsWhereTheWorkAreaIsCut() {
        for monitor in [Self.primary, Self.left] {
            for edge in [P.Edge.bottom, .top, .left, .right] {
                XCTAssertEqual(P.taskbarEdge(monitor: monitor, work: Self.work(monitor, edge), appBar: nil), edge, "\(edge) on \(monitor)")
                XCTAssertEqual(P.taskbarEdge(monitor: monitor, work: Self.work(monitor, edge), appBar: Self.band(monitor, edge)), edge)
            }
        }
    }

    /// An auto-hidden taskbar reserves nothing: the work area is the whole monitor, and the shell's taskbar rectangle
    /// (`ABM_GETTASKBARPOS`) says which side it slides in from, also when it is out of sight (only a sliver on the monitor).
    func testAnAutoHiddenTaskbarIsFoundByItsRectangle() {
        let m = Self.primary
        for edge in [P.Edge.bottom, .top, .left, .right] {
            XCTAssertEqual(P.taskbarEdge(monitor: m, work: m, appBar: Self.band(m, edge)), edge, "shown \(edge)")
            let hidden: CGRect
            switch edge {
            case .bottom: hidden = Self.band(m, edge).offsetBy(dx: 0, dy: Self.bar - 2)
            case .top: hidden = Self.band(m, edge).offsetBy(dx: 0, dy: -(Self.bar - 2))
            case .left: hidden = Self.band(m, edge).offsetBy(dx: -(Self.bar - 2), dy: 0)
            case .right: hidden = Self.band(m, edge).offsetBy(dx: Self.bar - 2, dy: 0)
            }
            XCTAssertEqual(P.taskbarEdge(monitor: m, work: m, appBar: hidden), edge, "hidden \(edge)")
        }
        // No cut and no taskbar on this monitor (a second monitor without one): Windows' default side.
        XCTAssertEqual(P.taskbarEdge(monitor: m, work: m, appBar: nil), .bottom)
        XCTAssertEqual(P.taskbarEdge(monitor: m, work: m, appBar: Self.band(Self.left, .left)), .bottom, "another monitor's taskbar")
    }

    func testTheUsableWorkAreaLeavesOutAnAutoHiddenTaskbar() {
        let m = Self.primary
        XCTAssertEqual(P.usableWork(monitor: m, work: m, appBar: Self.band(m, .bottom), edge: .bottom), Self.work(m, .bottom))
        XCTAssertEqual(P.usableWork(monitor: m, work: m, appBar: Self.band(m, .left), edge: .left), Self.work(m, .left))
        let hidden = Self.band(m, .right).offsetBy(dx: Self.bar - 2, dy: 0)
        XCTAssertEqual(P.usableWork(monitor: m, work: m, appBar: hidden, edge: .right), Self.work(m, .right), "the bar's full thickness, out of sight or not")
        // A normal taskbar already cut the work area: nothing more is taken.
        XCTAssertEqual(P.usableWork(monitor: m, work: Self.work(m, .top), appBar: Self.band(m, .top), edge: .top), Self.work(m, .top))
        XCTAssertEqual(P.usableWork(monitor: m, work: Self.work(m, .top), appBar: nil, edge: .top), Self.work(m, .top))
        // A nonsense rectangle (half the screen or more) is not a taskbar.
        XCTAssertEqual(P.usableWork(monitor: m, work: m, appBar: CGRect(x: 0, y: 500, width: 1920, height: 580), edge: .bottom), m)
    }

    // MARK: - the frame

    func testEachEdgePlacesTheWindowBesideTheIconInsideTheWorkArea() {
        let size = CGSize(width: 360, height: 600), margin: CGFloat = 12
        for monitor in [Self.primary, Self.left] {
            for edge in [P.Edge.bottom, .top, .left, .right] {
                let work = Self.work(monitor, edge), icon = Self.icon(monitor, edge)
                let f = P.frame(anchor: icon, clickPoint: nil, size: size, monitor: monitor, work: work, edge: edge, margin: margin)
                XCTAssertEqual(f.size, size, "\(edge) on \(monitor)")
                XCTAssertTrue(Self.inside(f, work, margin: margin), "\(edge) on \(monitor): \(f) not inside \(work)")
                switch edge {
                case .bottom:
                    XCTAssertEqual(f.maxY, work.maxY - margin, "just above the taskbar")
                    XCTAssertEqual(f.midX, icon.midX, accuracy: 0.5, "centred on the icon")
                case .top:
                    XCTAssertEqual(f.minY, work.minY + margin, "just below the taskbar")
                    XCTAssertEqual(f.midX, icon.midX, accuracy: 0.5)
                case .left:
                    XCTAssertEqual(f.minX, work.minX + margin, "beside the taskbar")
                    XCTAssertEqual(f.maxY, icon.maxY, "flipped: no room below the icon's top, so its bottom is level with the icon's")
                case .right:
                    XCTAssertEqual(f.maxX, work.maxX - margin)
                    XCTAssertEqual(f.maxY, icon.maxY)
                }
            }
        }
    }

    func testAVerticalTaskbarWithTheIconHighUpTopAlignsWithTheIcon() {
        let m = Self.primary, work = Self.work(m, .left)
        let icon = CGRect(x: 8, y: 100, width: 32, height: 32)
        let f = P.frame(anchor: icon, clickPoint: nil, size: CGSize(width: 360, height: 600), monitor: m, work: work, edge: .left, margin: 12)
        XCTAssertEqual(f.minY, icon.minY, "room below: top-aligned to the icon")
        XCTAssertEqual(f.minX, work.minX + 12)
    }

    func testAnIconAtTheScreenEdgeIsClampedIntoTheWorkArea() {
        let m = Self.primary, work = Self.work(m, .bottom)
        let corner = CGRect(x: 1900, y: 1040, width: 20, height: 40)
        let f = P.frame(anchor: corner, clickPoint: nil, size: CGSize(width: 360, height: 600), monitor: m, work: work, edge: .bottom, margin: 12)
        XCTAssertEqual(f.maxX, work.maxX - 12)
        let start = CGRect(x: 0, y: 1040, width: 20, height: 40)
        let g = P.frame(anchor: start, clickPoint: nil, size: CGSize(width: 360, height: 600), monitor: m, work: work, edge: .bottom, margin: 12)
        XCTAssertEqual(g.minX, work.minX + 12)
    }

    /// R12: 600 DIP at 150 % is 900 px, more than a 720 px work area: the height is clamped and the page scrolls.
    func testAWorkAreaSmallerThanThePopoverClampsItsSize() {
        let m = CGRect(x: 0, y: 0, width: 1280, height: 768), work = Self.work(m, .bottom)
        let f = P.frame(anchor: Self.icon(m, .bottom), clickPoint: nil, size: CGSize(width: 540, height: 900), monitor: m, work: work,
                        edge: .bottom, margin: 18)
        XCTAssertEqual(f.height, work.height - 36)
        XCTAssertEqual(f.width, 540)
        XCTAssertTrue(Self.inside(f, work, margin: 18), "\(f)")
        // Narrower than the popover, too.
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let t = P.frame(anchor: nil, clickPoint: nil, size: CGSize(width: 360, height: 600), monitor: tiny, work: tiny, edge: .bottom, margin: 12)
        XCTAssertEqual(t, CGRect(x: 12, y: 12, width: 276, height: 176))
    }

    func testAMissingAnchorUsesTheClickPointThenTheCorner() {
        let m = Self.primary, work = Self.work(m, .bottom), size = CGSize(width: 360, height: 600)
        let click = CGPoint(x: 1500, y: 1060)
        let fromClick = P.frame(anchor: nil, clickPoint: click, size: size, monitor: m, work: work, edge: .bottom, margin: 12)
        XCTAssertEqual(fromClick.midX, click.x, accuracy: 0.5)
        XCTAssertEqual(fromClick.maxY, work.maxY - 12)
        // An anchor wins over the click point (D2's order).
        let icon = Self.icon(m, .bottom)
        XCTAssertEqual(P.frame(anchor: icon, clickPoint: click, size: size, monitor: m, work: work, edge: .bottom, margin: 12).midX, icon.midX, accuracy: 0.5)
        // Neither: the corner at the end of the taskbar where the notification area is (bottom right, as Windows 11's flyouts).
        let corner = P.frame(anchor: nil, clickPoint: nil, size: size, monitor: m, work: work, edge: .bottom, margin: 12)
        XCTAssertEqual(corner, CGRect(x: work.maxX - 12 - 360, y: work.maxY - 12 - 600, width: 360, height: 600))
        let top = P.frame(anchor: nil, clickPoint: nil, size: size, monitor: m, work: Self.work(m, .top), edge: .top, margin: 12)
        XCTAssertEqual(top.origin, CGPoint(x: m.maxX - 12 - 360, y: Self.bar + 12))
        let leftEdge = P.frame(anchor: nil, clickPoint: nil, size: size, monitor: m, work: Self.work(m, .left), edge: .left, margin: 12)
        XCTAssertEqual(leftEdge.origin, CGPoint(x: Self.bar + 12, y: m.maxY - 12 - 600))
        let rightEdge = P.frame(anchor: nil, clickPoint: nil, size: size, monitor: m, work: Self.work(m, .right), edge: .right, margin: 12)
        XCTAssertEqual(rightEdge.origin, CGPoint(x: m.maxX - Self.bar - 12 - 360, y: m.maxY - 12 - 600))
    }

    // MARK: - the monitor and the whole placement

    static let monitors = [
        P.Monitor(bounds: primary, work: work(primary, .bottom), dpi: 96, isPrimary: true),
        P.Monitor(bounds: left, work: work(left, .bottom, 72), dpi: 144, isPrimary: false),
    ]

    func testTheMonitorIsTheAnchorsElseThePrimary() {
        XCTAssertEqual(P.monitorIndex(anchor: Self.icon(Self.primary, .bottom), clickPoint: nil, monitors: Self.monitors), 0)
        XCTAssertEqual(P.monitorIndex(anchor: Self.icon(Self.left, .bottom, 72), clickPoint: nil, monitors: Self.monitors), 1)
        XCTAssertEqual(P.monitorIndex(anchor: nil, clickPoint: CGPoint(x: -100, y: 900), monitors: Self.monitors), 1)
        XCTAssertEqual(P.monitorIndex(anchor: nil, clickPoint: CGPoint(x: 0, y: 900), monitors: Self.monitors), 0, "x = 0 is the primary's (half-open)")
        XCTAssertEqual(P.monitorIndex(anchor: nil, clickPoint: nil, monitors: Self.monitors), 0)
        // A rect across both: the one with the larger part; off every monitor: the nearest.
        XCTAssertEqual(P.monitorIndex(anchor: CGRect(x: -10, y: 500, width: 30, height: 10), clickPoint: nil, monitors: Self.monitors), 0)
        XCTAssertEqual(P.monitorIndex(anchor: CGRect(x: -3000, y: 0, width: 10, height: 10), clickPoint: nil, monitors: Self.monitors), 1)
        XCTAssertEqual(P.monitorIndex(anchor: CGRect(x: 2500, y: 100, width: 10, height: 10), clickPoint: nil, monitors: Self.monitors), 0)
        XCTAssertNil(P.monitorIndex(anchor: nil, clickPoint: nil, monitors: []))
        // The primary is found by its flag, not its position in the list.
        XCTAssertEqual(P.monitorIndex(anchor: nil, clickPoint: nil, monitors: Self.monitors.reversed()), 1)
    }

    func testThePlacementUsesTheAnchorMonitorsDPI() throws {
        let border: (Int) -> CGSize = { _ in CGSize(width: 2, height: 2) }   // WS_BORDER, one pixel a side at any DPI
        let onPrimary = try XCTUnwrap(P.place(anchor: Self.icon(Self.primary, .bottom), clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600),
                                              monitors: Self.monitors, appBar: nil, framePixels: border))
        XCTAssertEqual(onPrimary.monitor, 0)
        XCTAssertEqual(onPrimary.dpi, 96)
        XCTAssertEqual(onPrimary.edge, .bottom)
        XCTAssertEqual(onPrimary.frame.size, CGSize(width: 362, height: 602))
        XCTAssertEqual(onPrimary.frame.maxY, Self.monitors[0].work.maxY - 12)
        // The left monitor at 150 %: 540 x 900 px + the border, the margin 18 px, everything at negative x.
        let icon = Self.icon(Self.left, .bottom, 72)
        let onLeft = try XCTUnwrap(P.place(anchor: icon, clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600), monitors: Self.monitors,
                                           appBar: nil, framePixels: border))
        XCTAssertEqual(onLeft.monitor, 1)
        XCTAssertEqual(onLeft.dpi, 144)
        XCTAssertEqual(onLeft.frame.size, CGSize(width: 542, height: 902))
        XCTAssertEqual(onLeft.frame.maxY, Self.monitors[1].work.maxY - 18)
        XCTAssertEqual(onLeft.frame.midX, icon.midX, accuracy: 0.5)
        XCTAssertLessThan(onLeft.frame.maxX, 0)
        XCTAssertTrue(Self.inside(onLeft.frame, Self.monitors[1].work, margin: 18))
        // The DPI of a window that changed scale while open (WM_DPICHANGED) overrides the monitor's.
        let rescaled = try XCTUnwrap(P.place(anchor: Self.icon(Self.primary, .bottom), clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600),
                                             monitors: Self.monitors, appBar: nil, dpi: 120))
        XCTAssertEqual(rescaled.dpi, 120)
        XCTAssertEqual(rescaled.frame.size, CGSize(width: 450, height: 750))
        XCTAssertEqual(rescaled.frame.maxY, Self.monitors[0].work.maxY - 15)
    }

    func testThePlacementTakesTheTaskbarOnlyOnItsOwnMonitor() throws {
        // An auto-hidden taskbar on the primary's right; the popover opens on the primary beside it.
        let auto = [P.Monitor(bounds: Self.primary, work: Self.primary, dpi: 96, isPrimary: true), Self.monitors[1]]
        let icon = Self.icon(Self.primary, .right)
        let r = try XCTUnwrap(P.place(anchor: icon, clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600), monitors: auto,
                                      appBar: Self.band(Self.primary, .right)))
        XCTAssertEqual(r.edge, .right)
        XCTAssertEqual(r.frame.maxX, Self.primary.maxX - Self.bar - 12, "clear of the taskbar when it slides in")
        // The same taskbar rectangle seen from the other monitor is ignored there.
        let other = try XCTUnwrap(P.place(anchor: Self.icon(Self.left, .bottom, 72), clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600),
                                          monitors: auto, appBar: Self.band(Self.primary, .right)))
        XCTAssertEqual(other.edge, .bottom)
        // A second launch with no anchor: the primary's corner.
        let launch = try XCTUnwrap(P.place(anchor: nil, clickPoint: nil, sizeDIP: CGSize(width: 360, height: 600), monitors: Self.monitors, appBar: nil))
        XCTAssertEqual(launch.monitor, 0)
        XCTAssertEqual(launch.frame.origin, CGPoint(x: 1920 - 12 - 360, y: 1080 - 48 - 12 - 600))
    }

    /// Every edge × both monitors × shown / auto-hidden × three anchors: the frame is inside the usable work area, never
    /// over the taskbar, at whole pixels.
    func testEveryCombinationStaysInsideAndOffTheTaskbar() throws {
        for (index, monitor) in [Self.primary, Self.left].enumerated() {
            let dpi = index == 0 ? 96 : 144, scale = CGFloat(dpi) / 96
            for edge in [P.Edge.bottom, .top, .left, .right] {
                for autoHide in [false, true] {
                    let band = Self.band(monitor, edge)
                    let work = autoHide ? monitor : Self.work(monitor, edge)
                    let others = index == 0 ? [Self.monitors[1]] : [Self.monitors[0]]
                    let mine = P.Monitor(bounds: monitor, work: work, dpi: dpi, isPrimary: index == 0)
                    let monitors = index == 0 ? [mine] + others : others + [mine]
                    let icon = Self.icon(monitor, edge)
                    for (anchor, click) in [(icon, nil), (nil, CGPoint(x: icon.midX, y: icon.midY)), (nil, nil)] as [(CGRect?, CGPoint?)] {
                        let r = try XCTUnwrap(P.place(anchor: anchor, clickPoint: click, sizeDIP: CGSize(width: 360, height: 600),
                                                      monitors: monitors, appBar: band))
                        let label = "\(edge) monitor \(index) autoHide=\(autoHide) anchor=\(anchor != nil) click=\(click != nil)"
                        if anchor != nil || click != nil {
                            XCTAssertEqual(r.edge, edge, label)
                            XCTAssertEqual(r.dpi, dpi, label)
                            XCTAssertTrue(Self.inside(r.frame, Self.work(monitor, edge), margin: (12 * scale).rounded()), "\(label): \(r.frame)")
                        }
                        XCTAssertFalse(Self.overlaps(r.frame, band), "\(label): over the taskbar")
                        XCTAssertEqual(r.frame.minX, r.frame.minX.rounded(), label)
                        XCTAssertEqual(r.frame.minY, r.frame.minY.rounded(), label)
                        XCTAssertEqual(r.frame.width, r.frame.width.rounded(), label)
                    }
                }
            }
        }
    }
}
