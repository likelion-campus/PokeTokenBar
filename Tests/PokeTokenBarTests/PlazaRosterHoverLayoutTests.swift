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

    /// Guard for the #129 crash: a roster that changed its own height with an animation made the NSHostingView (Auto Layout,
    /// intrinsic size, pinned top-trailing with a width constraint) re-invalidate its constraints on every tick, ~1000+
    /// `updateConstraints` calls per hover against ~20 without the animation; AppKit then raised from
    /// `_NSViewUpdateConstraints` and the app quit. The hover no longer changes the roster, so this checks that the
    /// hosted roster stays at one size and quiet. Offscreen window, ordered front only, never key; the run loop is pumped
    /// 20 ms at a time. A real pointer can't be driven offscreen (synthesized events do not fire `.onHover`).
    func testHoverDoesNotFloodConstraintUpdates() throws {
        let model = PlazaRosterModel()
        model.entries = (0..<6).map { busy("m\($0)") }
        let height: CGFloat = 400   // short window: 3 slots
        model.capacity = PlazaRoster.capacity(forHeight: height)
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
        let before = host.updates, restHeight = host.frame.height
        // The old hover grew the slot; now a hover changes nothing the hosting view can see. Slots still animate their icons.
        for _ in 0..<2 { pump(30) }
        let used = host.updates - before
        XCTAssertEqual(host.frame.height, restHeight)
        XCTAssertLessThan(used, 100, "updateConstraints calls over 1.2 s")
    }
}
