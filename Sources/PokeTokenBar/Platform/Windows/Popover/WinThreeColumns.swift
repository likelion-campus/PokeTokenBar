#if os(Windows)
import Foundation
import WinSDK

/// The Recap page's Previous | current period | Next line (`HStack { Button; Spacer(); Button; Spacer(); Button }`): the first at
/// the left edge, the last at the right edge, the middle one centred in the space between them. One row of the page; Tab goes
/// through the children in creation order.
@MainActor final class WinThreeColumns {
    let pane: WinPane
    let ctx: WinUIContext
    private(set) var control: WinControl!
    private var parts: [WinControl?] = []

    init?(parent: HWND, ctx: WinUIContext, build: (HWND) -> (WinControl?, WinControl?, WinControl?)) {
        guard let made = try? WinPane(parent: parent, ctx: ctx, rect: RECT(left: 0, top: 0, right: 10, bottom: 10)) else { return nil }
        pane = made
        self.ctx = ctx
        let made3 = build(made.hwnd)
        parts = [made3.0, made3.1, made3.2]
        let height = parts.compactMap { $0 }.map(\.preferredSize.height).max() ?? 0
        control = WinControls.drawn(made.hwnd, size: CGSize(width: 0, height: height), ctx: ctx) { [self] r in self.place(r) }
        control.onDestroy = { [self] in self.destroyChildren() }
    }

    private func place(_ r: RECT) {
        WinKit.move(pane.hwnd, r)
        let width = r.right - r.left, height = r.bottom - r.top
        guard width > 0 else { return }
        func size(_ c: WinControl?) -> (w: Int32, h: Int32) { c.map { (Int32($0.preferredSize.width.rounded(.up)), Int32($0.preferredSize.height.rounded(.up))) } ?? (0, 0) }
        func put(_ c: WinControl?, x: Int32) {
            guard let c else { return }
            let s = size(c)
            c.frame(RECT(left: x, top: (height - s.h) / 2, right: x + s.w, bottom: (height - s.h) / 2 + s.h))
        }
        let a = size(parts[0]), b = size(parts[1]), c = size(parts[2])
        put(parts[0], x: 0)
        put(parts[2], x: width - c.w)
        let room = max(0, width - c.w - a.w - b.w)
        put(parts[1], x: a.w + room / 2)
    }

    private func destroyChildren() {
        control.onFrame = nil
        parts.compactMap { $0 }.forEach { $0.destroy() }
        parts = []
        pane.destroy()
    }
}
#endif
