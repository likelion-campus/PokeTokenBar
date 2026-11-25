import XCTest
@testable import PokeTokenBar

/// The chat line's chrome as a shared panel (stage 6 Task 11, D13; drawn on Windows around the native field). The numbers are
/// the Mac's AppKit chat bar (`PlazaChatInput`'s constraints and layer); `PlazaChatBarPanelTests+Mac` lays the real AppKit bar
/// out and compares. Stub graphics, so it runs on both OSes.
@MainActor final class PlazaChatBarPanelTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    private struct Rig {
        let bar: PlazaChatBarPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics
    }

    /// The body font's line: Galmuri14 at 15 points is 15 + 3 + 3 (`PlazaChatInput.fieldHeight` on the Mac).
    private static let fieldHeight: CGFloat = 21

    private func rig(open: Bool = true, viewport: CGSize = CGSize(width: 960, height: 640), scale: CGFloat = 2) -> Rig {
        let bar = PlazaChatBarPanel(fieldHeight: Self.fieldHeight)
        bar.isOpen = open
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [bar], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        return Rig(bar: bar, hud: hud, host: host, graphics: graphics)
    }

    private func frame(_ r: Rig) -> CGRect? { r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.chatBar] }

    /// The quiz word line has no 😀 on the Mac (hidden); here it is neither drawn, nor read, nor hit, and comes back with the chat line.
    func testTheWordLineHasNoEmojiButton() async {
        let r = rig()
        await flush()
        let button = CGPoint(x: 16 + r.bar.emojiButtonRect.midX, y: 640 - 16 - 37 + r.bar.emojiButtonRect.midY)
        func emojiItems() -> [PlazaAccessibilityItem] { r.host.drawings[.chatBar]?.accessibility.filter { $0.action?.action == "emoji" } ?? [] }
        XCTAssertEqual(emojiItems().count, 1)
        XCTAssertEqual(r.hud.hit(at: button, in: .chatBar)?.action, "emoji")
        r.bar.hasEmojiButton = false
        await flush()
        XCTAssertTrue(emojiItems().isEmpty, "not read out")
        XCTAssertTrue(r.host.drawings[.chatBar]?.tooltips.isEmpty ?? false, "no tooltip")
        XCTAssertEqual(r.hud.hit(at: button, in: .chatBar)?.action, "bar", "the click lands on the plate")
        r.bar.hasEmojiButton = true
        await flush()
        XCTAssertEqual(emojiItems().count, 1)
    }

    func testTheClosedLineDrawsNothingAndTakesNoClick() async {
        let r = rig(open: false)
        XCTAssertFalse(r.bar.isVisible)
        XCTAssertNil(frame(r))
        XCTAssertNil(r.host.drawings[.chatBar])
        XCTAssertNil(r.hud.hit(at: CGPoint(x: 30, y: 620), in: .chatBar))
        r.bar.isOpen = true
        await flush()
        XCTAssertNotNil(r.host.drawings[.chatBar], "opening shows it")
        r.bar.isOpen = false
        await flush()
        XCTAssertNil(r.host.drawings[.chatBar], "closing hides it")
    }

    /// 16 from the bottom-left corner, `PlazaChatLog.width` wide, the field 12 from the top and 4 from the bottom: 37 tall.
    func testTheBarSitsWhereTheMacsDoes() async {
        let r = rig()
        XCTAssertEqual(frame(r), CGRect(x: 16, y: 640 - 16 - 37, width: 360, height: 37))
        XCTAssertEqual(PlazaChatBarPanel.width, PlazaChatLog.width)
        // The AppKit field's frame: its alignment rect (12 from the left, 4 before the button) outset by its 2-point text inset.
        XCTAssertEqual(r.bar.fieldRect, CGRect(x: 10, y: 12, width: 316, height: 21))
        let button = r.bar.emojiButtonRect
        XCTAssertEqual(button, CGRect(x: 328, y: 13, width: 24, height: 19))
        XCTAssertEqual(button.minX - (r.bar.fieldRect.maxX - PlazaChatBarPanel.fieldTextInset), 4, "4 after the field")
        XCTAssertEqual(button.midY, r.bar.fieldRect.midY, "on the field's line")
        // The window keeps its distance from the bottom on any height.
        r.hud.setViewport(CGSize(width: 600, height: 372), scale: 1)
        XCTAssertEqual(frame(r), CGRect(x: 16, y: 372 - 16 - 37, width: 360, height: 37))
    }

    /// Unfolded, the 10 × 4 grid of 32-point cells sits 8 from the top, centred, the field 8 under it; the bar grows upward.
    func testTheGridUnfoldsAboveTheFieldAndTheBarGrowsUpward() async {
        let r = rig()
        r.bar.isEmojiOpen = true
        await flush()
        let height: CGFloat = 8 + 4 * 32 + 8 + 21 + 4
        XCTAssertEqual(frame(r), CGRect(x: 16, y: 640 - 16 - height, width: 360, height: height))
        XCTAssertEqual(r.bar.fieldRect, CGRect(x: 10, y: 8 + 128 + 8, width: 316, height: 21))
        let cells = r.bar.gridCells
        XCTAssertEqual(cells.count, PlazaChatEmojis.all.count)
        XCTAssertEqual(cells.first, CGRect(x: 20, y: 8, width: 32, height: 32))
        XCTAssertEqual(cells[9], CGRect(x: 20 + 9 * 32, y: 8, width: 32, height: 32))
        XCTAssertEqual(cells[10], CGRect(x: 20, y: 40, width: 32, height: 32))
        XCTAssertEqual(cells.last, CGRect(x: 20 + 9 * 32, y: 8 + 3 * 32, width: 32, height: 32))
        XCTAssertEqual(r.bar.gridButtons.first, CGRect(x: 21.5, y: 12, width: 29, height: 24), "the button centred in its cell")
        XCTAssertTrue(cells.allSatisfy { $0.maxY <= r.bar.fieldRect.minY - 8 }, "above the field")
        r.bar.isEmojiOpen = false
        await flush()
        XCTAssertEqual(frame(r)?.height, 37, "folded again")
        XCTAssertEqual(r.bar.gridCells, [])
    }

    /// The grid shows `PlazaChatEmojis.all` row by row: what each cell's item reads and what its hit picks.
    func testTheGridOrderIsTheSharedList() async {
        let r = rig()
        r.bar.isEmojiOpen = true
        await flush()
        let items = r.host.drawings[.chatBar]?.accessibility ?? []
        let picks = items.filter { $0.action?.action == "pick" }
        XCTAssertEqual(picks.map(\.label), PlazaChatEmojis.all)
        XCTAssertEqual(picks.map { $0.action?.index }, Array(PlazaChatEmojis.all.indices))
        for (i, cell) in r.bar.gridCells.enumerated() {
            XCTAssertEqual(r.bar.hit(CGPoint(x: cell.midX, y: cell.midY)), PlazaPanelHit(action: "pick", index: i))
            XCTAssertEqual(r.bar.hit(CGPoint(x: cell.minX + 0.5, y: cell.minY + 0.5))?.action, "bar", "between buttons: the plate (as AppKit's grid)")
        }
        XCTAssertEqual(Set(PlazaChatEmojis.all).count, PlazaChatEmojis.all.count, "no emoji twice")
        XCTAssertTrue(PlazaChatEmojis.all.allSatisfy { $0.count == 1 && TeamChat.prepared($0) == $0 }, "each one character, sent as picked")
    }

    func testHitsAreTheButtonThePlateAndNothingOutside() async {
        let r = rig()
        let b = r.bar.emojiButtonRect, f = r.bar.fieldRect
        XCTAssertEqual(r.bar.hit(CGPoint(x: b.midX, y: b.midY)), PlazaPanelHit(action: "emoji", index: nil))
        XCTAssertEqual(r.bar.hit(CGPoint(x: f.midX, y: f.midY)), PlazaPanelHit(action: "bar", index: nil), "the plate under the field")
        XCTAssertEqual(r.bar.hit(CGPoint(x: 2, y: 2)), PlazaPanelHit(action: "bar", index: nil))
        XCTAssertNil(r.bar.hit(CGPoint(x: 361, y: 10)))
        XCTAssertNil(r.bar.hit(CGPoint(x: 10, y: 38)))
        // Through the HUD, in window points.
        let fr = frame(r) ?? .zero
        XCTAssertEqual(r.hud.hit(at: CGPoint(x: fr.minX + b.midX, y: fr.minY + b.midY), in: .chatBar)?.action, "emoji")
        XCTAssertNil(r.hud.hit(at: CGPoint(x: fr.minX - 1, y: fr.midY), in: .chatBar))
    }

    /// The border is the layer's: 2 points inside the bar, white at 50 %, orange while the megaphone is on; the fill 1D4F5C at 95 %.
    func testTheBorderTurnsOrangeForTheMegaphone() async throws {
        let r = rig()
        await flush()
        func strokes() -> [String] { (r.graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("strokeColor") || $0.hasPrefix("strokeRoundedRect") || $0.hasPrefix("fillColor (0.11") } }
        XCTAssertEqual(r.bar.borderColor, PlazaColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        let calls = try XCTUnwrap(r.graphics.canvases.last?.calls)
        XCTAssertTrue(calls.contains("strokeRoundedRect (1.0, 1.0, 358.0, 35.0) 5.0 2.0"), "\(calls)")
        XCTAssertTrue(calls.contains("fillRoundedRect (0.0, 0.0, 360.0, 37.0) 6.0"), "\(calls)")
        let renders = r.hud.renderCount
        r.bar.isLoud = true
        await flush()
        XCTAssertEqual(r.hud.renderCount, renders + 1)
        XCTAssertEqual(r.bar.borderColor, PlazaColor(hex: 0xF08A24))
        let orange = PlazaColor(hex: 0xF08A24)
        XCTAssertTrue(r.graphics.canvases.last?.calls.contains("strokeColor (\(orange.red), \(orange.green), \(orange.blue), 1.0)") == true, "\(strokes())")
        r.bar.isLoud = true
        await flush()
        XCTAssertEqual(r.hud.renderCount, renders + 1, "the same state renders nothing")
    }

    /// The 😀 button carries the Mac's tooltip and reads as a button; the drawing follows no mouse (no hover look).
    func testTheEmojiButtonHasItsTooltipAndItem() async {
        let r = rig()
        let d = r.host.drawings[.chatBar]
        XCTAssertEqual(d?.tooltips, [PlazaTooltip(frame: r.bar.emojiButtonRect, text: L(.ko).plazaChatEmoji)])
        XCTAssertEqual(d?.accessibility.first?.role, .button)
        XCTAssertEqual(d?.accessibility.first?.label, L(.ko).plazaChatEmoji)
        XCTAssertEqual(d?.accessibility.count, 1, "the folded grid has no items")
        XCTAssertEqual(d?.tracksMouse, false)
    }

    /// Sizes are whole device pixels at fractional scales (the window draws the image 1:1).
    func testTheBarIsWholeDevicePixels() async {
        for scale: CGFloat in [1, 1.25, 1.5, 1.75, 2] {
            let r = rig(scale: scale)
            let s = r.bar.size(in: r.hud.viewport, scale: scale, text: r.graphics.text)
            XCTAssertEqual((s.width * scale).rounded(), s.width * scale, "\(scale)")
            XCTAssertEqual((s.height * scale).rounded(), s.height * scale, "\(scale)")
            XCTAssertGreaterThanOrEqual(s.height, 37)
        }
    }

    /// The field's height on each OS's real engine: the body font's line, rounded up (21 for Galmuri14 at 15 points).
    func testTheFieldIsTheBodyFontsLine() async {
        let m = PlatformPlaza.graphics.text.metrics(.plaza(.body))
        XCTAssertEqual((m.ascender - m.descender + m.leading).rounded(.up), Self.fieldHeight)
    }
}
