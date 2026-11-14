import XCTest
import Observation
@testable import PokeTokenBar

/// The shortcut guide, background toggle, name-colour picker and photo frame as panels (Track A Task 15): what a click
/// does and where, what each shows for its model, the items VoiceOver reads, when each renders, and the click through the
/// controller. Stub graphics (deterministic monospace text), so they run on Windows too; the Mac's real text and the
/// SwiftUI originals are in `PlazaHUDControlRenderTests+Mac`.
@MainActor final class PlazaHUDControlsTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    private let viewport = CGSize(width: 960, height: 640)

    private struct Rig {
        let hud: PlazaHUD
        let host: RecordingPanelHost
        let background: PlazaBackgroundModel, guide: PlazaShortcutGuideModel, color: PlazaNameColorModel, overlay: PlazaOverlayModel
        let toggle: PlazaBackgroundTogglePanel, shortcuts: PlazaShortcutGuidePanel, picker: PlazaNameColorPickerPanel, photo: PlazaPhotoFramePanel
        var actions: ActionLog
    }

    @MainActor final class ActionLog { var actions: [String] = [] }

    private func rig(viewport: CGSize? = nil, scale: CGFloat = 2) -> Rig {
        let background = PlazaBackgroundModel(), guide = PlazaShortcutGuideModel(), color = PlazaNameColorModel(), overlay = PlazaOverlayModel()
        let toggle = PlazaBackgroundTogglePanel(model: background)
        let shortcuts = PlazaShortcutGuidePanel(model: guide, toggle: toggle)
        let picker = PlazaNameColorPickerPanel(model: color, toggle: toggle, background: background)
        let photo = PlazaPhotoFramePanel(model: overlay)
        let hud = PlazaHUD(panels: [photo, shortcuts, toggle, picker], graphics: PlazaStubGraphics(log: { _ in }))
        let host = RecordingPanelHost()
        let log = ActionLog()
        hud.onAction = { id, hit in log.actions.append("\(id) \(hit.action) \(hit.index.map(String.init) ?? "-")") }
        hud.setViewport(viewport ?? self.viewport, scale: scale)
        hud.host = host
        return Rig(hud: hud, host: host, background: background, guide: guide, color: color, overlay: overlay, toggle: toggle,
                   shortcuts: shortcuts, picker: picker, photo: photo, actions: log)
    }

    /// A click (down and up) at `point` of the panel, panel points top-left.
    private func click(_ r: Rig, _ id: PlazaPanelID, _ point: CGPoint) {
        guard let frame = r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[id] else { return XCTFail("\(id) is not shown") }
        let p = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: id)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: id)
    }

    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    // MARK: the guide

    func testGuideFoldsAndUnfoldsOnTheHeaderOnly() async throws {
        let r = rig()
        let open = try XCTUnwrap(r.host.drawings[.shortcuts])
        let rows = PlazaShortcutGuide.entries(season: .winter).count
        XCTAssertEqual(open.accessibility.count, 1 + 2 * rows, "the header button, then each row's key and label")
        let header = try XCTUnwrap(open.accessibility.first)
        XCTAssertEqual(header.role, .button)
        XCTAssertEqual(header.label, L(.ko).plazaShortcutsTitle)
        XCTAssertEqual(header.action, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertTrue(open.accessibility.dropFirst().allSatisfy { $0.role == .staticText && $0.action == nil }, "the rows are static text")
        // Only the header line is a button: not the guide's padding, not a row.
        click(r, .shortcuts, CGPoint(x: header.frame.midX, y: header.frame.midY))
        XCTAssertEqual(r.actions.actions, ["shortcuts toggle -"])
        for item in open.accessibility.dropFirst() {
            click(r, .shortcuts, CGPoint(x: item.frame.midX, y: item.frame.midY))
        }
        click(r, .shortcuts, CGPoint(x: 2, y: 2))
        click(r, .shortcuts, CGPoint(x: header.frame.midX, y: header.frame.maxY + 8))
        XCTAssertEqual(r.actions.actions.count, 1, "a row, the corner padding and the gap under the header do nothing")
        // Folded, it is the header line only, and the panel gets smaller (no relayout: the HUD moves one layer).
        let openHeight = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.shortcuts]).height
        r.guide.isFolded = true
        await flush()
        let folded = try XCTUnwrap(r.host.drawings[.shortcuts])
        XCTAssertEqual(folded.accessibility.count, 1)
        XCTAssertLessThan(try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.shortcuts]).height, openHeight / 4)
    }

    func testGuideFitsTheSmallestWindow() async throws {
        let r = rig(viewport: PlazaWindowController.minContentSize)
        for season in [PlazaSeason.winter, .summer] {
            r.guide.season = season
            await flush()
            let frame = try XCTUnwrap(r.hud.layout(viewport: PlazaWindowController.minContentSize, scale: 2)[.shortcuts])
            XCTAssertLessThanOrEqual(frame.maxY, PlazaWindowController.minContentSize.height, "\(season)")
            XCTAssertLessThanOrEqual(frame.maxX - PlazaPanelStyle.strokeRoom, PlazaShortcutGuide.coveredWidth + 60, "\(season): stub text is wider")
        }
    }

    func testThrowLabelFollowsTheSeason() async throws {
        let r = rig()
        for season in [PlazaSeason.spring, .summer, .autumn, .winter] {
            r.guide.season = season
            await flush()
            let labels = try XCTUnwrap(r.host.drawings[.shortcuts]).accessibility.map(\.label)
            XCTAssertTrue(labels.contains(L(.ko).plazaShortcutThrow(season)), "\(season)")
            XCTAssertEqual(labels.filter { $0 == "V" }.count, 1)
        }
    }

    // MARK: toggle and picker

    func testToggleAndPickerHitTargets() async throws {
        let r = rig()
        let toggle = try XCTUnwrap(r.host.drawings[.backgroundToggle])
        XCTAssertEqual(toggle.accessibility.map(\.role), [.button])
        XCTAssertEqual(toggle.accessibility.first?.label, L(.ko).plazaBackgroundHide)
        let tf = try XCTUnwrap(toggle.accessibility.first).frame
        click(r, .backgroundToggle, CGPoint(x: tf.minX + 1, y: tf.minY + 1))   // padding corner: the label carried its padding
        click(r, .backgroundToggle, CGPoint(x: tf.midX, y: tf.midY))
        click(r, .backgroundToggle, CGPoint(x: tf.maxX + 3, y: tf.midY))
        XCTAssertEqual(r.actions.actions, ["backgroundToggle toggle -", "backgroundToggle toggle -"], "on the pill only")
        r.background.isHidden = true
        await flush()
        XCTAssertEqual(r.host.drawings[.backgroundToggle]?.accessibility.first?.label, L(.ko).plazaBackgroundShow)

        // The picker: closed it is one button; opened, a button per palette colour, labelled as the chat log's.
        r.actions.actions = []
        let closed = try XCTUnwrap(r.host.drawings[.nameColorPicker])
        XCTAssertEqual(closed.accessibility.map(\.label), [L(.ko).plazaNameColor])
        click(r, .nameColorPicker, CGPoint(x: 20, y: 14))
        XCTAssertEqual(r.actions.actions, ["nameColorPicker toggle -"])
        r.color.isOpen = true
        await flush()
        let open = try XCTUnwrap(r.host.drawings[.nameColorPicker])
        XCTAssertEqual(open.accessibility.map(\.label), [L(.ko).plazaNameColor] + (1...PlazaNameColor.hexes.count).map { L(.ko).plazaNameColorChoice($0) })
        XCTAssertTrue(open.accessibility.dropFirst().allSatisfy { $0.role == .button })
        r.actions.actions = []
        for (i, item) in open.accessibility.dropFirst().enumerated() {
            click(r, .nameColorPicker, CGPoint(x: item.frame.midX, y: item.frame.midY))
            XCTAssertEqual(r.actions.actions.last, "nameColorPicker choose \(i)")
            XCTAssertEqual(item.action, PlazaPanelHit(action: "choose", index: i))
        }
        let first = try XCTUnwrap(open.accessibility.dropFirst().first).frame
        let count = r.actions.actions.count
        click(r, .nameColorPicker, CGPoint(x: first.maxX + 2, y: first.midY))        // the gap between two swatches
        click(r, .nameColorPicker, CGPoint(x: first.minX + 0.5, y: first.minY + 0.5))   // the cell's corner: outside its circle
        click(r, .nameColorPicker, CGPoint(x: 3, y: first.maxY + 20))                    // the palette's own padding
        XCTAssertEqual(r.actions.actions.count, count, "gaps, corners and the palette's background are not buttons")
    }

    func testThePickerSitsRightOfTheToggleAndFollowsItsWidth() async throws {
        let r = rig()
        let toggle = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.backgroundToggle])
        let picker = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.nameColorPicker])
        let guide = try XCTUnwrap(r.hud.layout(viewport: viewport, scale: 2)[.shortcuts])
        XCTAssertEqual(picker.minY, toggle.minY, "tops aligned")
        XCTAssertEqual(picker.minX, toggle.maxX + PlazaControlStyle.pickerGap - 2 * PlazaPanelStyle.strokeRoom, "8 points right of the toggle's host")
        XCTAssertEqual(guide.minX, toggle.minX)
        XCTAssertEqual(guide.minY, toggle.maxY + PlazaControlStyle.guideGap - 2 * PlazaPanelStyle.strokeRoom, "6 points under it")
    }

    // MARK: the photo frame

    func testPhotoFrameMatchesViewRect() async throws {
        for size in [CGSize(width: 600, height: 372), CGSize(width: 1280, height: 800), CGSize(width: 961.5, height: 641.5)] {
            let r = rig(viewport: size)
            XCTAssertNil(r.host.drawings[.photoFrame], "outside photo mode: nothing")
            r.overlay.isPhotoMode = true
            await flush()
            let drawing = try XCTUnwrap(r.host.drawings[.photoFrame], "\(size)")
            let hole = try XCTUnwrap(PlazaPhotoFrame.viewRect(in: size))
            let rects = drawing.layers.compactMap { layer -> CGRect? in if case .color(_, let f) = layer { return f } else { return nil } }
            XCTAssertEqual(rects.count, 4)
            let dimmed = rects.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(dimmed, size.width * size.height - hole.width * hole.height, accuracy: size.width + size.height,
                           "everything but the hole is dimmed (to the device pixel)")
            for rect in rects { XCTAssertFalse(rect.intersects(hole.insetBy(dx: 1, dy: 1)), "\(rect) leaves the frame clear") }
            XCTAssertEqual(drawing.layers.count, 4 + 4 + 1, "four dim rectangles, four brackets, the guide")
            XCTAssertNil(r.hud.hit(at: CGPoint(x: size.width / 2, y: size.height / 2), in: .photoFrame), "no clicks")
            XCTAssertNil(r.hud.hit(at: CGPoint(x: 3, y: 3), in: .photoFrame))
            XCTAssertEqual(drawing.accessibility.map(\.label), [L(.ko).plazaPhotoGuide])
            XCTAssertEqual(drawing.accessibility.first?.role, .staticText)
            for layer in drawing.layers {
                if case .image(let image, let f) = layer { XCTAssertLessThan(f.width * f.height * 4, 120_000, "small images only (\(image.width)x\(image.height))") }
            }
        }
        let tiny = rig(viewport: CGSize(width: 40, height: 60))
        tiny.overlay.isPhotoMode = true
        await flush()
        XCTAssertTrue(tiny.host.drawings[.photoFrame]?.layers.isEmpty ?? true, "no room for a frame: nothing drawn")
    }

    func testThePhotoGuideShrinksToSeventyPercentThenCuts() async throws {
        let text = PlazaStubGraphics(log: { _ in }).text
        let line = text.line(L(.ko).plazaPhotoGuide, font: .plaza(.body))
        XCTAssertEqual(PlazaPhotoFramePanel.guide(width: line.width + 1, text: text).scale, 1, "fits: full size")
        let half = PlazaPhotoFramePanel.guide(width: line.width * 0.8, text: text)
        XCTAssertEqual(half.scale, 0.8, accuracy: 1e-9, "shrunk just enough")
        XCTAssertEqual(half.line.width, line.width)
        let small = PlazaPhotoFramePanel.guide(width: line.width * 0.5, text: text)
        XCTAssertEqual(small.scale, 0.7, "never below 70 %")
        XCTAssertLessThanOrEqual(small.line.width * small.scale, line.width * 0.5 + 0.001, "cut with an ellipsis so it fits")
        XCTAssertLessThan(small.line.width, line.width)
    }

    // MARK: rendering only on change

    func testControlsRenderOnlyWhenTheirContentChanges() async throws {
        let r = rig()
        await flush()
        let base = r.hud.renderCounts
        XCTAssertEqual(base[.shortcuts], 1)
        XCTAssertEqual(base[.backgroundToggle], 1)
        XCTAssertEqual(base[.nameColorPicker], 1)
        XCTAssertNil(base[.photoFrame], "hidden outside photo mode")
        r.hud.setViewport(CGSize(width: 1100, height: 700), scale: 2)
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.shortcuts], 1, "a resize moves the guide, it does not draw it again")
        XCTAssertEqual(r.hud.renderCounts[.backgroundToggle], 1)
        r.guide.isFolded = true
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.shortcuts], 2)
        XCTAssertEqual(r.hud.renderCounts[.backgroundToggle], 1)
        r.guide.season = .summer
        await flush()
        XCTAssertEqual(r.hud.renderCounts[.shortcuts], 3, "the season changes the V row's label")
        r.hud.isRendering = false
        r.color.isOpen = true
        r.background.isHidden = true
        r.overlay.isPhotoMode = true
        await flush()
        let hidden = r.hud.renderCounts
        XCTAssertEqual(hidden[.nameColorPicker], 1, "a hidden plaza renders nothing")
        XCTAssertEqual(hidden[.photoFrame], nil)
        r.hud.isRendering = true
        XCTAssertEqual(r.hud.renderCounts[.nameColorPicker], 2, "once when it shows again")
        XCTAssertEqual(r.hud.renderCounts[.photoFrame], 1)
        XCTAssertEqual(r.hud.renderCounts[.backgroundToggle], 2)
    }

    // MARK: through the controller

    private struct NoSprites: PlazaSpriteFetching {
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
        func egg() async -> PlazaImage? { nil }
    }

    private func controller(_ shell: RecordingPlazaShell, saved: @escaping (UInt32) -> Void = { _ in }) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.controls.\(UUID())")),
                              loader: PlazaCharacterLoader(fetcher: NoSprites()),
                              nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                              teamName: { "개발팀" }, chooseNameColor: saved,
                              renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                              shell: shell, chatInput: PlazaStubChatInput())
    }

    /// Every control does what its SwiftUI button did, and each click hands the keys back to the scene (the chat field
    /// loses focus on a click, as it did).
    func testClicksRefocusTheScene() async throws {
        let shell = RecordingPlazaShell()
        var saved: [UInt32] = []
        let c = controller(shell) { saved.append($0) }
        c.show()
        _ = shell.take()
        let hud = c.hud
        func click(_ id: PlazaPanelID, _ hit: PlazaPanelHit) {
            hud.press(hit, in: id)
        }
        click(.shortcuts, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertTrue(c.areShortcutsFolded)
        XCTAssertEqual(shell.take(), [.focusScene])
        click(.nameColorPicker, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertTrue(c.isNameColorPickerOpen)
        XCTAssertEqual(shell.take(), [.focusScene])
        click(.nameColorPicker, PlazaPanelHit(action: "choose", index: 4))
        XCTAssertEqual(saved, [PlazaNameColor.hexes[4]], "the colour is sent on as before: chosen, saved, announced by the session")
        XCTAssertEqual(c.shownNameColor, PlazaNameColor.hexes[4])
        XCTAssertFalse(c.isNameColorPickerOpen)
        XCTAssertEqual(shell.take(), [.focusScene])
        click(.nameColorPicker, PlazaPanelHit(action: "choose", index: 99))
        XCTAssertEqual(saved.count, 1, "an index outside the palette picks nothing")
        click(.backgroundToggle, PlazaPanelHit(action: "toggle", index: nil))
        XCTAssertTrue(c.isBackgroundHidden)
        XCTAssertEqual(shell.take(), [.setTransparent(true), .focusScene])
        // ...and through real mouse events on the panels, not only presses.
        let frame = try XCTUnwrap(hud.layout(viewport: hud.viewport, scale: hud.scale)[.backgroundToggle])
        let p = CGPoint(x: frame.midX, y: frame.midY)
        _ = hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .backgroundToggle)
        _ = hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: .backgroundToggle)
        XCTAssertFalse(c.isBackgroundHidden, "a click on the pill toggles it back")
        c.handleClose()
    }

    func testPhotoModeDrawsTheFrameAndTheControlsStayPanels() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        let ids = c.hud.panels.map(\.id)
        XCTAssertEqual(ids, [.photoFrame, .pills, .clock, .shortcuts, .backgroundToggle, .nameColorPicker])
        XCTAssertNil(shell.panels.drawings[.photoFrame])
        c.scene?.enterPhotoMode()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(shell.panels.drawings[.photoFrame], "photo mode draws the frame")
        c.handleClose()
    }
}
