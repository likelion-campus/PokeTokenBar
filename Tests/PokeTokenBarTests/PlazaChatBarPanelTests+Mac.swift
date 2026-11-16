import XCTest
import AppKit
@testable import PokeTokenBar

/// The shared chat bar (`PlazaChatBarPanel`, drawn on Windows) against the Mac's AppKit chat bar it copies: the real
/// `PlazaChatInput` laid out by Auto Layout in a window that is never shown, at the plaza's input width.
@MainActor final class PlazaChatBarPanelMacTests: XCTestCase {
    /// `rect` (a subview frame in the bar's unflipped coordinates) with the origin at the bar's top-left.
    private func topLeft(_ rect: NSRect, in bar: NSView) -> CGRect {
        CGRect(x: rect.minX, y: bar.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func laidOut(emojiOpen: Bool) -> (PlazaChatInput, NSWindow) {
        let input = PlazaChatInput()
        input.open()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PlazaChatLog.width, height: 300), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let host = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView = host
        input.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(input.view)
        NSLayoutConstraint.activate([
            input.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            input.view.widthAnchor.constraint(equalToConstant: PlazaChatLog.width),
            input.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        if emojiOpen { input.emojiButton.performClick(nil) }
        host.layoutSubtreeIfNeeded()
        return (input, w)
    }

    func testTheSharedBarIsTheAppKitBar() {
        for open in [false, true] {
            let (input, w) = laidOut(emojiOpen: open)
            defer { w.contentView = nil }
            let bar = PlazaChatBarPanel(fieldHeight: PlazaChatInput.fieldHeight)
            bar.isEmojiOpen = open
            let view = input.view
            XCTAssertEqual(view.frame.size.width, bar.barSize.width, "open=\(open)")
            XCTAssertEqual(view.frame.size.height, bar.barSize.height, "open=\(open)")
            XCTAssertEqual(topLeft(input.field.frame, in: view), bar.fieldRect, "field, open=\(open)")
            XCTAssertEqual(topLeft(input.emojiButton.frame, in: view), bar.emojiButtonRect, "😀 button, open=\(open)")
            if open {
                let buttons = input.emojiPanelButtons.map { topLeft($0.convert($0.bounds, to: view), in: view) }
                XCTAssertEqual(buttons, bar.gridButtons)
            }
        }
    }

    func testTheSharedListAndLookAreTheMacs() {
        XCTAssertEqual(PlazaChatInput.emojis, PlazaChatEmojis.all)
        XCTAssertEqual(PlazaChatInput.emojiColumns, PlazaChatEmojis.columns)
        XCTAssertEqual(PlazaChatInput.emojiCell, PlazaChatEmojis.cell)
        XCTAssertEqual(PlazaChatInput.fieldHeight, 21)
        let input = PlazaChatInput()
        let layer = try? XCTUnwrap(input.view.layer)
        XCTAssertEqual(layer?.borderWidth, PlazaChatBarPanel.borderWidth)
        XCTAssertEqual(layer?.cornerRadius, PlazaChatBarPanel.cornerRadius)
        func rgba(_ c: CGColor?) -> [CGFloat] { c?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [] }
        func rgba(_ c: PlazaColor) -> [CGFloat] { [c.red, c.green, c.blue, c.alpha] }
        func near(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.002 } }
        XCTAssertTrue(near(rgba(layer?.backgroundColor), rgba(PlazaChatBarPanel.fill)), "\(rgba(layer?.backgroundColor))")
        XCTAssertTrue(near(rgba(layer?.borderColor), rgba(PlazaChatBarPanel.border)))
        input.open()
        _ = input.control(input.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(near(rgba(input.view.layer?.borderColor), rgba(PlazaChatBarPanel.loudBorder)), "the megaphone's border")
    }
}
