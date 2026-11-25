import XCTest
@testable import PokeTokenBar

/// The drawing quiz board in the real HUD, as the controller builds it: in a small window the chat log shows 3 lines and the shortcuts guide is
/// folded while the board shows (nothing saved), in a big one nothing changes, and the display modes treat the board as a panel the game opened.
@MainActor final class PlazaDrawRoomTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    private let narrow = CGSize(width: 600, height: 372), wide = CGSize(width: 960, height: 640)

    @MainActor private struct Open {
        let c: PlazaWindowController
        let shell: RecordingPlazaShell
        let prefs: PlazaPreferences
        var panel: PlazaDrawPanel { c.hud.panels.first { $0.id == .drawBoard } as! PlazaDrawPanel }
    }

    private func open(_ viewport: CGSize, scale: CGFloat, guideFolded: Bool = false, lines: Int = 8) -> Open {
        let prefs = PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.drawroom.\(UUID())"))
        prefs.areShortcutsFolded = guideFolded
        let shell = RecordingPlazaShell()
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: PlazaStubSpriteFetcher(log: { _ in })),
                                      nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      teamName: { "개발팀" }, renderCheckSleep: Self.park, focusTickSleep: Self.park, dittoLoopSleep: Self.park, dittoSeed: { 7 },
                                      shell: shell, chatInput: PlazaStubChatInput())
        c.show()
        for i in 0..<lines { c.overlayBindings.chatLog.append(time: Date(), name: "지은", text: "추측 \(i)", color: PlazaColor(hex: 0xFF8A80)) }
        c.hud.setViewport(viewport, scale: scale)
        return Open(c: c, shell: shell, prefs: prefs)
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    private let board = PlazaDrawBoard(head: "그림 퀴즈 3/6 · 그리는 사람 나", time: "⏱ 52", cover: nil, foot: .tools(word: "사과"), canDraw: true)

    func testASmallWindowMakesRoomWhileTheBoardShowsAndGivesItBack() async throws {
        for scale in [CGFloat(1), 1.25, 1.5, 2] {
            let o = open(narrow, scale: scale)
            await settle()
            let tag = "600x372 @\(scale)"
            XCTAssertEqual(o.c.chatLogVisibleCount, 6, tag)
            XCTAssertFalse(o.c.showsShortcutsFolded, tag)
            o.c.drawModel.board = board
            await settle()
            let placed = o.panel.layout(in: narrow, scale: scale, text: o.c.hud.graphics.text)
            XCTAssertEqual(o.c.chatLogVisibleCount, 3, "\(tag): the log shows 3 lines")
            XCTAssertTrue(o.c.showsShortcutsFolded, "\(tag): the guide is folded")
            XCTAssertFalse(o.c.areShortcutsFolded, "\(tag): the saved choice is untouched")
            XCTAssertFalse(o.prefs.areShortcutsFolded, tag)
            XCTAssertFalse(o.c.isChatLogExpanded, tag)
            XCTAssertTrue(placed.fits, "\(tag): fits")
            XCTAssertGreaterThanOrEqual(placed.cell, 2, tag)
            let frames = o.c.hud.layout(viewport: narrow, scale: scale)
            let mine = try XCTUnwrap(frames[.drawBoard], tag)
            XCTAssertTrue(CGRect(origin: .zero, size: narrow).contains(mine), "\(tag): inside the window \(mine)")
            for id in [PlazaPanelID.chatLog, .minimap, .clock, .shortcuts, .backgroundToggle, .nameColorPicker, .pills] {
                if let f = frames[id] { XCTAssertFalse(mine.intersects(f), "\(tag): \(id) is clear \(mine) \(f)") }
            }
            XCTAssertNotNil(frames[.chatLog], tag)
            o.c.drawModel.board = nil
            await settle()
            XCTAssertEqual(o.c.chatLogVisibleCount, 6, "\(tag): the log is back")
            XCTAssertFalse(o.c.showsShortcutsFolded, "\(tag): the guide is back")
            XCTAssertFalse(o.prefs.areShortcutsFolded, tag)
            o.c.handleClose()
        }
    }

    func testABigWindowReducesNothingAndTheBoardIsCentred() async throws {
        let o = open(wide, scale: 2)
        await settle()
        o.c.drawModel.board = board
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 6)
        XCTAssertFalse(o.c.showsShortcutsFolded)
        let mine = try XCTUnwrap(o.c.hud.layout(viewport: wide, scale: 2)[.drawBoard])
        XCTAssertEqual(mine.midX, wide.width / 2, accuracy: 1)
        o.c.handleClose()
    }

    func testAGuideTheUserFoldedStaysFolded() async throws {
        let o = open(narrow, scale: 1, guideFolded: true)
        await settle()
        o.c.drawModel.board = board
        await settle()
        XCTAssertTrue(o.c.showsShortcutsFolded)
        o.c.drawModel.board = nil
        await settle()
        XCTAssertTrue(o.c.showsShortcutsFolded, "the user's own fold is still there")
        XCTAssertTrue(o.c.areShortcutsFolded)
        XCTAssertTrue(o.prefs.areShortcutsFolded)
        o.c.handleClose()
    }

    func testAnUnfoldedLogLooksFoldedWhileTheBoardShowsAndComesBack() async throws {
        let o = open(narrow, scale: 1)
        o.c.toggleChatLog()
        await settle()
        o.c.drawModel.board = board
        await settle()
        XCTAssertTrue(o.c.isChatLogExpanded, "the user's choice is untouched")
        XCTAssertEqual(o.c.chatLogVisibleCount, 3)
        XCTAssertTrue(try XCTUnwrap(o.panel.layout(in: narrow, scale: 1, text: o.c.hud.graphics.text)).fits)
        o.c.drawModel.board = nil
        await settle()
        XCTAssertTrue(o.c.isChatLogExpanded)
        o.c.handleClose()
    }

    func testOnceReducedItStaysReducedWhileTheBoardShows() async throws {
        let o = open(narrow, scale: 1)
        await settle()
        o.c.drawModel.board = board
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 3)
        o.c.hud.setViewport(wide, scale: 2)
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 3, "a bigger window does not flip it back")
        XCTAssertTrue(o.c.showsShortcutsFolded)
        o.c.drawModel.board = nil
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 6)
        o.c.handleClose()
    }

    /// The display modes: with the UI hidden the board stays (it is the game's, not UI chrome), in photo mode it is hidden, and photo mode gives
    /// the log and the guide back.
    func testTheBoardStaysWithTheUIHiddenAndGoesInPhotoMode() async throws {
        let o = open(narrow, scale: 1)
        await settle()
        o.c.drawModel.board = board
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 3)
        _ = o.shell.take()
        o.c.cycleDisplayMode()   // all shown -> UI hidden
        await settle()
        XCTAssertEqual(o.shell.take().compactMap { call -> Set<PlazaPanelID>? in if case .setHiddenPanels(let ids) = call { ids } else { nil } }.last, PlazaPanelID.hiddenWithUI)
        XCTAssertFalse(PlazaPanelID.hiddenWithUI.contains(.drawBoard), "the board stays shown")
        XCTAssertEqual(o.c.chatLogVisibleCount, 3, "the board still has its room")
        o.c.cycleDisplayMode()
        o.c.cycleDisplayMode()
        o.c.cycleDisplayMode()   // back to all shown
        _ = o.shell.take()
        o.c.scene?.enterPhotoMode()
        await settle()
        let photo = o.shell.take().compactMap { call -> Set<PlazaPanelID>? in if case .setHiddenPanels(let ids) = call { ids } else { nil } }.last
        XCTAssertEqual(photo, PlazaPanelID.hiddenInPhotoMode)
        XCTAssertTrue(photo?.contains(.drawBoard) == true, "photo mode hides it")
        XCTAssertEqual(o.c.chatLogVisibleCount, 6, "hidden: the log is as the user left it")
        o.c.scene?.exitPhotoMode()
        await settle()
        XCTAssertEqual(o.c.chatLogVisibleCount, 3, "and it makes room again when it returns")
        o.c.handleClose()
    }
}
