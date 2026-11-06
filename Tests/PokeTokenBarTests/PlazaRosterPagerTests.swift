import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Real clicks on the roster's < > arrows in an offscreen window. It is never made key, so the app is not activated.
@MainActor
final class PlazaRosterPagerTests: XCTestCase {
    /// Stands in for the plaza scene, which holds the keyboard.
    private final class Scene: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Held in memory by setUp, so the rows never reach for the disk or the network.
    private let species = 987_657
    private let panelHeight: CGFloat = 340
    /// Middle of each arrow, from the panel's top right.
    private var nextPoint: CGPoint {
        let m = PlazaRosterMetrics.self
        return CGPoint(x: m.width - m.padding - m.pagerHitSize / 2, y: panelHeight - m.padding - m.headerHeight / 2)
    }
    private var previousPoint: CGPoint { CGPoint(x: nextPoint.x - PlazaRosterMetrics.pagerHitSize, y: nextPoint.y) }

    override func setUp() async throws {
        try await super.setUp()
        let png = try XCTUnwrap(PlazaRosterTests.solidPNG(red: 1))
        _ = await PlazaIconLoader.icon(speciesID: species) { _ in png }
    }

    private func people(_ count: Int) -> [PlazaRosterEntry] {
        (0..<count).map {
            PlazaRosterEntry(id: "m\($0)", nickname: "멤버\($0)", speciesID: species, speciesName: "피카츄", gender: nil,
                             isShiny: false, presence: .idle, isMe: false)
        }
    }

    /// Clicks the panel at each point and returns every turn it asked for, and whether the scene kept the keyboard.
    private func click(_ points: [CGPoint], people count: Int, page: Int = 0) throws -> (turns: [Int], keptKeys: Bool) {
        let model = PlazaRosterModel()
        model.entries = people(count)
        model.page = page
        var turns: [Int] = []
        let frame = NSRect(x: 0, y: 0, width: PlazaRosterMetrics.width, height: panelHeight)
        let roster = PlazaRosterHostingView(rootView: PlazaRosterView(model: model, onTurn: { turns.append($0) }))
        roster.frame = frame
        let scene = Scene(frame: frame)
        let container = NSView(frame: frame)
        container.addSubview(scene)
        container.addSubview(roster)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -10000, dy: -10000), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(scene))
        roster.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for point in points {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        return (turns, window.firstResponder === scene)
    }

    func testArrowsTurnThePageAndTheSceneKeepsTheKeys() throws {
        let result = try click([nextPoint, previousPoint], people: 13, page: 1)
        XCTAssertEqual(result.turns, [1, -1])
        XCTAssertTrue(result.keptKeys)
    }

    func testArrowIsDeadAtItsEnd() throws {
        XCTAssertEqual(try click([previousPoint], people: 7).turns, [])
        XCTAssertEqual(try click([nextPoint], people: 7, page: 1).turns, [])
    }

    func testArrowsAppearFromTheSeventhPerson() throws {
        XCTAssertEqual(try click([nextPoint, previousPoint], people: 6).turns, [])
        XCTAssertTrue(try countReachesTheRightEdge(people: 6))
        XCTAssertFalse(try countReachesTheRightEdge(people: 7), "the arrows push the count left")
    }

    /// `>` sits in the middle of its target, so the last few points show the count only when there are no arrows.
    private func countReachesTheRightEdge(people count: Int) throws -> Bool {
        let model = PlazaRosterModel()
        model.entries = people(count)
        let renderer = ImageRenderer(content: PlazaRosterView(model: model))
        renderer.scale = 1
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let m = PlazaRosterMetrics.self
        let right = Int(m.width - m.padding), top = Int(m.padding)
        return (right - 6..<right).contains { x in
            (top..<top + Int(m.headerHeight)).contains { y in
                (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.greenComponent ?? 0) > 0.9
            }
        }
    }

    func testHitAreaMeetsPointerTargetMinimum() {
        XCTAssertGreaterThanOrEqual(PlazaRosterMetrics.pagerHitSize, 24)
    }
}
