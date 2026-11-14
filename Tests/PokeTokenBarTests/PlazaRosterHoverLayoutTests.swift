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
    /// `_NSViewUpdateConstraints` and the app quit. The hover no longer changes the roster, so this drives the state changes that
    /// do move its height (members joining and leaving, page turns) and checks they stay quiet. Injecting
    /// `.animation(.easeOut(0.18), value: model.entries)` on the list makes it fail with ~9500 calls (clean: 36). Offscreen window, ordered front only, never key; the run loop is pumped
    /// 20 ms at a time. A real pointer can't be driven offscreen (synthesized events do not fire `.onHover`).
    func testHoverDoesNotFloodConstraintUpdates() throws {
        let model = PlazaRosterModel()
        model.entries = (0..<6).map { busy("m\($0)") }
        let height: CGFloat = 600   // room for all six slots, so the entry count sets the height
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
        let before = host.updates
        // Real state changes that move the roster's height: members joining and leaving, and a page turn.
        var heights = Set<CGFloat>()
        for round in 0..<4 {
            model.entries = (0..<(round % 2 == 0 ? 2 : 6)).map { busy("m\($0)") }
            pump(15)
            heights.insert(host.frame.height)
        }
        model.entries = (0..<8).map { busy("m\($0)") }   // two pages
        pump(15)
        model.turnPage(by: 1); pump(15)
        model.turnPage(by: -1); pump(15)
        let used = host.updates - before
        XCTAssertGreaterThan(heights.count, 1, "test precondition: the changes really change the height")
        XCTAssertLessThan(used, 100, "updateConstraints calls over the state changes")
    }
}
