import XCTest
import SwiftUI
@testable import PokeTokenBar

/// The roster hosted the way the plaza hosts it (Auto Layout, pinned top-trailing), in a window that is never key.
@MainActor
final class PlazaRosterHoverLayoutTests: XCTestCase {
    private func busy(_ id: String) -> PlazaRosterEntry {
        var a = PlazaActivity(day: "2026-11-14")
        a.seconds = 60; a.iceBreaks = 1; a.fireworks = 1; a.tackles = 1; a.snowballHits = 1; a.greetings = 1; a.pickups = 1
        return PlazaRosterEntry(id: id, nickname: id, speciesID: 25, speciesName: "x", gender: nil, isShiny: false,
                                presence: .online, isMe: false, activity: a)
    }

    final class Probe: NSHostingView<PlazaRosterView> {
        var updates = 0
        override func updateConstraints() { updates += 1; super.updateConstraints() }
        override var acceptsFirstResponder: Bool { false }
    }

    /// A hover animates the hosted roster's height, so its intrinsic size changes on every animation tick. Measured on the
    /// real layout (pinned top-trailing, width constraint): ~1000+ `updateConstraints` calls per expand or collapse, against
    /// ~20 with the animation removed. AppKit stops a window after (number of views) extra passes, which crashes the app
    /// with `_NSViewUpdateConstraints` / `_crashOnException:`. Offscreen window, ordered front only, never key; the run loop
    /// is pumped 20 ms at a time. The app's own crash itself was not reproduced (no real pointer offscreen); this checks the
    /// pass count. Expected failure until the form of the expansion is settled.
    func testHoverDoesNotFloodConstraintUpdates() throws {
        let model = PlazaRosterModel()
        model.entries = (0..<6).map { busy("m\($0)") }
        let height: CGFloat = 400   // short window: 3 slots, the list scrolls
        model.capacity = PlazaRoster.capacity(forHeight: height)
        model.maxListHeight = PlazaRoster.maxListHeight(forHeight: height)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: height))
        window.contentView = container
        let host = Probe(rootView: PlazaRosterView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor, constant: PlazaRosterMetrics.margin),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -PlazaRosterMetrics.margin),
            host.widthAnchor.constraint(equalToConstant: PlazaRosterMetrics.width),
        ])
        window.orderFront(nil)
        defer { window.close() }
        func pump(_ n: Int) {
            for _ in 0..<n {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                container.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
        }
        pump(5)
        let before = host.updates
        for id in ["m0", "m2"] {
            model.hoveredID = id; pump(30)
            model.hoveredID = nil; pump(30)
        }
        let used = host.updates - before
        XCTExpectFailure("hover animates the hosting view's size; see the defect log") {
            XCTAssertLessThan(used, 100, "updateConstraints calls for two hover round trips")
        }
    }
}
