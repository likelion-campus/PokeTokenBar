import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 6: "Always show scroll bars" (the legacy scroller, 17 points wide, taking its width from the scrolling window). The
/// SwiftUI view's NSScrollView is forced to the legacy style and the panel's content height (what wrapping decides) must be the same.
@MainActor final class PlazaLegacyScrollerTests: XCTestCase {
    private func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(sub) { return s } }
        return nil
    }

    func testTheLegacyScrollerTakes17PointsAndTheChatLogWrapsAsSwiftUIDidWithIt() async throws {
        XCTAssertEqual(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), PlazaScrollIndicator.legacyWidth)
        let log = PlazaChatLog()
        for i in 0..<45 { log.append(time: Date(), name: "나", text: "줄 \(i) " + String(repeating: "가", count: 20 + i), color: PlazaNameColor.palette[0]) }
        log.isExpanded = true
        let host = NSHostingView(rootView: LegacyPlazaChatLogView(log: log))
        let window = ScaledWindow(scale: 2, size: CGSize(width: 400, height: 400))
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let sv = try XCTUnwrap(findScroll(host))
        for (legacy, always) in [(false, false), (true, true)] {
            sv.scrollerStyle = legacy ? .legacy : .overlay
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let panel = PlazaChatLogPanel(log: log)
            panel.scrollIndicator.alwaysVisible = always
            panel.scrollIndicator.isDisabled = true
            _ = panel.render(scale: 2, viewport: CGSize(width: 960, height: 640), graphics: PlatformPlaza.graphics)
            let swiftUIHeight = try XCTUnwrap(sv.documentView?.frame.height)
            print("LEGACY lines in panel", panel.layout(scale: 2, text: PlatformPlaza.graphics.text).rows.map { $0.lines.count }.reduce(0, +), "reserved", panel.scrollIndicator.reservedWidth)
            print("LEGACY chat log legacy=\(legacy): SwiftUI content \(sv.contentSize.width) x \(swiftUIHeight), panel content height \(panel.scrollState.content)")
            XCTAssertEqual(sv.contentSize.width, legacy ? 340 - PlazaScrollIndicator.legacyWidth : 340)
            XCTAssertEqual(panel.scrollState.content, swiftUIHeight, accuracy: 1, "legacy=\(legacy): the lines wrap the same")
        }
    }
}
