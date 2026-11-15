#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

/// Stage 6 Task 10: the HUD's panels in the plaza window (`plaza.panels`, `plaza.clicks`, `plaza.cover`, `plaza.photo`,
/// `plaza.wheel`, `plaza.hover`, `plaza.dpiPanels`, `plaza.sizes`). The window shows the controller's real panels over
/// FIXTURE data (sample teammates, board events and chat lines); clicks are real window messages (`SendMessage`) at the
/// pixel of each panel's own accessibility items; captures go to the artifact (`plaza-panels-*.png`).
extension WindowsSelftest {
    private static func pText(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func pumpPanels(_ seconds: TimeInterval = 0.3) async { _ = await waitUntil(timeout: seconds) { false } }

    private static func packed(_ px: CGPoint) -> LPARAM { LPARAM((Int(px.y.rounded()) << 16) | (Int(px.x.rounded()) & 0xFFFF)) }

    private static func screenParam(_ hwnd: HWND, client px: CGPoint) -> LPARAM {
        var p = POINT(x: Int32(px.x.rounded()), y: Int32(px.y.rounded()))
        _ = ClientToScreen(hwnd, &p)
        return LPARAM(Int(UInt32(UInt16(truncatingIfNeeded: p.y)) << 16 | UInt32(UInt16(truncatingIfNeeded: p.x))))
    }

    @MainActor private static func wheelMessage(_ hwnd: HWND, _ delta: Int16, at px: CGPoint) {
        _ = SendMessageW(hwnd, 0x020A, WPARAM(UInt16(bitPattern: delta)) << 16, screenParam(hwnd, client: px))
    }

    /// A window point (points) as a client pixel.
    @MainActor private static func pixel(_ shell: WinPlazaWindow, _ p: CGPoint) -> CGPoint {
        let s = CGFloat(shell.dpiForTesting) / 96
        return CGPoint(x: p.x * s, y: p.y * s)
    }

    @MainActor private static func clickPixel(_ hwnd: HWND, _ px: CGPoint) {
        let l = packed(px)
        _ = SendMessageW(hwnd, 0x0200, 0, l)
        _ = SendMessageW(hwnd, 0x0201, 1, l)
        _ = SendMessageW(hwnd, 0x0202, 0, l)
    }

    /// The buttons of the panel's drawing that carry an action, as window points (the centre of each item). Items of a scroll
    /// area count only when their centre is inside the area's frame (the rest is scrolled out of sight).
    @MainActor private static func buttons(_ panels: WinPlazaPanels, _ id: PlazaPanelID) -> [(centre: CGPoint, hit: PlazaPanelHit, enabled: Bool, label: String)] {
        guard let e = panels.entries[id] else { return [] }
        var out: [(CGPoint, PlazaPanelHit, Bool, String)] = []
        var area: CGRect?
        for item in e.drawing.accessibility {
            if item.role == .scrollArea { area = item.frame; continue }
            guard let hit = item.action else { continue }
            let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
            if item.inScrollArea, let area, !area.contains(centre) { continue }
            out.append((CGPoint(x: e.frame.minX + centre.x, y: e.frame.minY + centre.y), hit, item.isEnabled, item.label))
        }
        return out
    }

    @MainActor static func plazaPanelChecks(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                                    feed: TeamFeedStore) async {
        guard let panels = shell.panelsForTesting else {
            r.add("plaza.panels", false, "the window has no panel host")
            return
        }
        let b = c.overlayBindings
        let hud = b.hud
        let model = b.overlayModel
        let originalAction = hud.onAction
        defer { hud.onAction = originalAction }
        var log: [(PlazaPanelID, PlazaPanelHit)] = []

        // The scripted state: a banner, the guide unfolded, three teammates, a chat log, a board with events.
        func entry(_ i: Int, me: Bool = false, presence: PlazaPresence = .online) -> PlazaRosterEntry {
            PlazaRosterEntry(id: me ? "selftest-me" : "fixture-\(i)", nickname: me ? "selftest" : "Fixture \(i)", speciesID: 25 + i, speciesName: "Pikachu",
                             gender: nil, isShiny: i == 2, presence: presence, isMe: me)
        }
        let fixtureRoster = [entry(0, me: true), entry(1), entry(2, presence: .idle)]
        // The controller's own refresh (its 1 s tick) rewrites the roster from the session: the fixture is put back before each use.
        func seedRoster() async {
            b.rosterModel.entries = fixtureRoster
            await pumpPanels(0.3)
        }
        b.rosterModel.entries = fixtureRoster
        for i in 0..<40 {
            b.chatLog.append(time: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60), name: i % 2 == 0 ? "Fixture 1" : "selftest",
                             text: "line \(i) 안녕하세요 hello world, a longer line that wraps around the log's width", color: PlazaColor(hex: 0x66CCFF))
        }
        if c.areShortcutsFolded { c.toggleShortcuts() }
        model.banner = "selftest banner 소식"
        await pumpPanels(0.5)
        let seed = (0..<14).map { i in
            TeamEvent(id: "ev\(i)", authorID: "a\(i % 3)", authorNickname: "민수\(i % 3)", kind: .hatch, speciesID: 25, fromSpeciesID: nil,
                      speciesName: "깨봉이", fromSpeciesName: nil, form: nil, isShiny: i == 3, nature: nil, rarity: .common,
                      day: PlazaActivity.dayKey(Date()), occurredAt: Date())
        }
        let inserted = feed.insert(seed).count
        let boardPanel = hud.panels.first(where: { $0.id == .board }) as? PlazaBoardPanel

        func shot(_ name: String) -> String {
            shell.drawForTesting()
            guard let rgba = shell.frameRGBAForTesting(), let ws = shell.surfaceForTesting?.windowStats else { return "\(name): no frame" }
            return "\(name) written=\(writeFrame(rgba, Int(ws.bufferWidth), Int(ws.bufferHeight), name))"
        }
        func ids() -> String { WinPlazaPanels.zOrder.filter { panels.entries[$0] != nil }.map { "\($0)" }.joined(separator: ",") }

        // plaza.panels: every panel shows in its state.
        var lines: [String] = []
        var ok = true
        func expect(_ state: String, present: [PlazaPanelID], absent: [PlazaPanelID] = [], png: String) async {
            await pumpPanels(0.35)
            let have = Set(panels.entries.keys)
            let missing = present.filter { !have.contains($0) }, extra = absent.filter { have.contains($0) }
            ok = ok && missing.isEmpty && extra.isEmpty
            lines.append("\(state): shown [\(ids())] missing \(missing) unexpected \(extra) \(shot(png))")
        }
        await expect("default (banner, guide unfolded, roster of 3, chat log of 40, minimap, clock, toggle)",
                     present: [.pills, .shortcuts, .roster, .chatLog, .minimap, .clock, .backgroundToggle], absent: [.menu, .board, .card, .photoFrame],
                     png: "plaza-panels-default.png")
        model.content = .memberMenu(PlazaMemberMenu(memberID: "fixture-1", nickname: "Fixture 1"))
        await expect("member menu", present: [.menu, .roster], png: "plaza-panels-member-menu.png")
        model.content = .campfireMenu(PlazaCampfireMenu(isJoin: false, minutes: [10, 25, 50], selection: 0))
        await expect("campfire menu", present: [.menu], png: "plaza-panels-campfire-menu.png")
        let me = TeamMemberState(memberID: "fixture-1", nickname: "Fixture 1", character: TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "피카츄", gender: nil),
                                 inPlaza: true, tile: nil, facing: nil, isWalking: false)
        var withActivity = me
        var activity = PlazaActivity(day: PlazaActivity.dayKey(Date()))
        activity.addSeconds(3 * 3600 + 25 * 60)
        activity.record(.firework)
        activity.record(.greeting)
        withActivity.activity = activity
        model.content = .card(.loading(me))
        await expect("card loading", present: [.card], png: "plaza-panels-card-loading.png")
        model.content = .card(.loaded(withActivity, TeamMemberProfile(memberID: me.memberID, nickname: "Fixture 1", current: me.character, dex: [])))
        await expect("card loaded with activity", present: [.card], png: "plaza-panels-card-loaded.png")
        model.content = .card(.failed(me))
        await expect("card without a record", present: [.card], png: "plaza-panels-card-failed.png")
        model.content = .board
        await expect("board (\(inserted) FIXTURE events)", present: [.board], png: "plaza-panels-board.png")
        model.content = .none
        c.toggleNameColorPicker()
        await expect("name colour picker", present: [.nameColorPicker, .backgroundToggle], png: "plaza-panels-picker.png")
        c.toggleNameColorPicker()
        await pumpPanels(0.3)
        r.add("plaza.panels", ok, "FIXTURE data; \(lines.joined(separator: "; ")); panel bitmaps \(panels.bitmapBytes / 1024) KB in \(panels.entries.count) panels; "
              + "board panel present: \(boardPanel != nil)")

        // plaza.clicks: a real click (WM_LBUTTONDOWN/UP) at the centre of every action item of every panel reaches its action.
        hud.onAction = { id, hit in log.append((id, hit)) }
        var clickLines: [String] = [], clicksOK = true
        func clickAll(_ id: PlazaPanelID) async {
            var matched = 0, total = 0, disabledActions = 0
            for item in buttons(panels, id) {
                log.removeAll()
                clickPixel(hwnd, pixel(shell, item.centre))
                total += 1
                if item.enabled {
                    if log.contains(where: { $0.0 == id && $0.1 == item.hit }) { matched += 1 }
                } else if !log.isEmpty { disabledActions += 1 }
            }
            let allEnabled = buttons(panels, id).filter(\.enabled).count
            clicksOK = clicksOK && total > 0 && matched == allEnabled
            clickLines.append("\(id): \(matched)/\(allEnabled) enabled items acted (\(total) items, disabled that acted: \(disabledActions))")
        }
        await seedRoster()
        for id in [PlazaPanelID.backgroundToggle, .shortcuts, .roster, .chatLog] { await clickAll(id) }
        c.toggleNameColorPicker()
        await pumpPanels(0.3)
        await clickAll(.nameColorPicker)
        c.toggleNameColorPicker()
        model.content = .memberMenu(PlazaMemberMenu(memberID: "fixture-1", nickname: "Fixture 1"))
        await pumpPanels(0.3)
        await clickAll(.menu)
        model.content = .card(.loaded(withActivity, TeamMemberProfile(memberID: me.memberID, nickname: "Fixture 1", current: me.character, dex: [])))
        await pumpPanels(0.3)
        let cardItems = buttons(panels, .card).count
        model.content = .none
        await pumpPanels(0.3)
        r.add("plaza.clicks", clicksOK, "real window messages at the item pixels: \(clickLines.joined(separator: "; ")); card action items \(cardItems)")

        // plaza.cover: with the card open (a full-window cover), the roster's own slot pixel takes no click and the card takes it.
        await seedRoster()
        let rosterButtons = buttons(panels, .roster)
        model.content = .card(.loading(me))
        await pumpPanels(0.35)
        log.removeAll()
        var coverOK = !rosterButtons.isEmpty
        for item in rosterButtons {
            clickPixel(hwnd, pixel(shell, item.centre))
            coverOK = coverOK && !log.contains { $0.0 == .roster } && panels.host(at: item.centre) == .card
        }
        let toggleButtons = buttons(panels, .backgroundToggle)
        log.removeAll()
        if let t = toggleButtons.first { clickPixel(hwnd, pixel(shell, t.centre)) }
        let aboveOK = log.contains { $0.0 == .backgroundToggle }
        r.add("plaza.cover", coverOK && aboveOK, "card open: \(rosterButtons.count) roster pixels clicked, none reached the roster and the card hosts them: \(coverOK); "
              + "the toggle above the cover still acts: \(aboveOK); roster tips suspended: \(panels.tips.isEmpty)")
        model.content = .none
        await pumpPanels(0.3)

        // plaza.photo: photo mode hides the Mac's set: not drawn, no click.
        let beforeCount = panels.drawList.count
        let beforeIDs = Set(panels.entries.keys).subtracting([.pills])
        shell.setHUDHidden(true)
        model.isPhotoMode = true
        await pumpPanels(0.4)
        let drawnIDs = Set(panels.entries.keys).subtracting(WinPlazaPanels.hiddenInPhotoMode)
        log.removeAll()
        for item in toggleButtons { clickPixel(hwnd, pixel(shell, item.centre)) }
        for item in rosterButtons { clickPixel(hwnd, pixel(shell, item.centre)) }
        let hiddenClicks = log.count
        let photoShot = shot("plaza-panels-photo.png")
        let afterCount = panels.drawList.count
        shell.setHUDHidden(false)
        model.isPhotoMode = false
        await pumpPanels(0.4)
        r.add("plaza.photo", afterCount < beforeCount && hiddenClicks == 0 && Set(panels.entries.keys).subtracting([.pills]) == beforeIDs && afterCount == drawnIDs.count,
              "drawn panels \(beforeCount) -> \(afterCount) -> \(panels.drawList.count) after leaving; clicks on hidden panels: \(hiddenClicks); \(photoShot)")

        // plaza.wheel: the chat log (not a cover) takes the wheel while it can move and passes it on at its end; a cover swallows it.
        c.toggleChatLog()
        await pumpPanels(0.4)
        var wheelLine = ""
        var wheelOK = false
        if let chat = panels.entries[.chatLog], let logPanel = hud.panels.first(where: { $0.id == .chatLog }) as? PlazaChatLogPanel {
            let centre = pixel(shell, CGPoint(x: chat.frame.midX, y: chat.frame.midY))
            for _ in 0..<60 { wheelMessage(hwnd, -120, at: centre) }   // to the bottom
            let p0 = panels.counts.scrollsPassedOn
            wheelMessage(hwnd, -120, at: centre)   // down at the bottom already: nothing to move
            let passedAtEnd = panels.counts.scrollsPassedOn - p0
            wheelMessage(hwnd, 120, at: centre)    // up: the log moves
            wheelMessage(hwnd, 120, at: centre)
            let moved = panels.counts.scrollsPassedOn - p0 == passedAtEnd
            wheelOK = passedAtEnd == 1 && moved
            wheelLine = "chat log expanded (\(Int(chat.frame.width))x\(Int(chat.frame.height))): wheel down at its end passed on \(passedAtEnd) time(s), wheel up moved it: \(moved) (\(String(describing: type(of: logPanel))))"
        } else {
            wheelLine = "no chat log panel shown"
        }
        c.toggleChatLog()
        // the board is a cover: its wheel moves the list; at the end nothing goes on (swallowed), and the scene gets none
        var boardLine = "no board"
        var boardOK = false
        if let boardPanel {
            model.content = .board
            await pumpPanels(0.4)
            if let plate = panels.entries[.board] {
                let list = PlazaBoardStyle.list
                let centre = pixel(shell, CGPoint(x: plate.frame.minX + list.midX, y: plate.frame.minY + list.midY))
                let o0 = boardPanel.scrollState.offset
                wheelMessage(hwnd, -120, at: centre)
                await pumpPanels(0.2)
                let o1 = boardPanel.scrollState.offset
                for _ in 0..<40 { wheelMessage(hwnd, -120, at: centre) }
                await pumpPanels(0.2)
                let end = boardPanel.scrollState.offset
                let s0 = panels.counts.swallowed
                wheelMessage(hwnd, -120, at: centre)
                let swallowed = panels.counts.swallowed - s0
                let shotScrolled = shot("plaza-panels-board-scrolled.png")
                boardOK = o1 > o0 && end >= o1 && boardPanel.scrollState.isAtBottom && swallowed == 1
                boardLine = "board offset \(o0) -> \(o1) after one wheel notch, \(end) at the end (bottom \(boardPanel.scrollState.isAtBottom)); a wheel at the end was swallowed by the cover \(swallowed) time(s) and not passed on; \(shotScrolled)"
            }
            model.content = .none
        }
        r.add("plaza.wheel", wheelOK && boardOK, wheelLine + "; " + boardLine)

        // plaza.hover: the system tooltip of a roster slot after the mouse rests on it (TTM_GETTEXT; the popup is reported).
        await pumpPanels(0.4)
        await seedRoster()
        var hoverOK = false
        var hoverLine = "no tooltip tool"
        if let tooltips = shell.tooltipsForTesting, let tip = panels.tips.first, let index = panels.tips.firstIndex(of: tip) {
            tooltips.setDelay(milliseconds: 80)
            let centre = pixel(shell, CGPoint(x: tip.frame.midX, y: tip.frame.midY))
            var screen = POINT(x: Int32(centre.x), y: Int32(centre.y))
            _ = ClientToScreen(hwnd, &screen)
            if onCI { _ = SetCursorPos(screen.x, screen.y) }
            let l = packed(centre)
            for _ in 0..<5 { _ = SendMessageW(hwnd, 0x0200, 0, l); await pumpPanels(0.1) }
            _ = await waitUntil(timeout: 2.0) { tooltips.isShowing }
            let text = tooltips.text(of: index)
            hoverOK = text == tip.text && tooltips.count == panels.tips.count
            hoverLine = "tool \(index) of \(tooltips.count): TTM_GETTEXT '\(text ?? "nil")' expected '\(tip.text)'; popup showing after the rest: \(tooltips.isShowing), current tool \(tooltips.currentIndex.map(String.init) ?? "none"), rebuilds \(tooltips.rebuilds); focus stayed on the plaza: \(GetFocus() == hwnd || !onCI)"
        }
        r.add("plaza.hover", hoverOK, hoverLine)

        // plaza.transparent: the background hidden (the toggle shows its other state); plaza.sizes: the minimum and a large window.
        c.toggleBackground()
        await pumpPanels(0.5)
        let transparentShot = shot("plaza-panels-transparent.png")
        let toggleShown = panels.entries[.backgroundToggle] != nil
        c.toggleBackground()
        await pumpPanels(0.4)
        r.add("plaza.transparent", toggleShown, "toggle still shown over the see-through window: \(toggleShown); \(transparentShot)")

        var original = RECT()
        _ = GetWindowRect(hwnd, &original)
        var sizeLines: [String] = [], sizesOK = true
        for (w, h, name) in [(600, 372, "plaza-panels-min.png"), (1600, 1000, "plaza-panels-large.png")] as [(Int32, Int32, String)] {
            let f = WinPlazaWindow.frame(shell.dpiForTesting, Int32((Double(w) * Double(shell.dpiForTesting) / 96).rounded()), Int32((Double(h) * Double(shell.dpiForTesting) / 96).rounded()))
            _ = SetWindowPos(hwnd, nil, 0, 0, f.width, f.height, UINT(SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE))
            await pumpPanels(0.5)
            let viewport = hud.viewport
            let allInside = panels.drawList.allSatisfy { d in d.frame.minX >= -1 && d.frame.minY >= -1 && d.frame.maxX <= viewport.width + 1 && d.frame.maxY <= viewport.height + 1 }
            let outside = WinPlazaPanels.zOrder.filter { id in
                guard let e = panels.entries[id] else { return false }
                return e.frame.minX < -1 || e.frame.minY < -1 || e.frame.maxX > viewport.width + 1 || e.frame.maxY > viewport.height + 1
            }
            sizesOK = sizesOK && (w == 600 ? Int(viewport.width) == 600 && Int(viewport.height) == 372 : viewport.width > 600) && !panels.drawList.isEmpty
            sizeLines.append("\(w)x\(h): outside the window \(outside), viewport \(Int(viewport.width))x\(Int(viewport.height)), \(panels.drawList.count) panels, all inside: \(allInside) \(shot(name))")
        }
        _ = SetWindowPos(hwnd, nil, original.left, original.top, original.right - original.left, original.bottom - original.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        await pumpPanels(0.5)
        r.add("plaza.sizes", sizesOK, sizeLines.joined(separator: "; "))

        // plaza.dpiPanels: a DPI change re-renders every shown panel once, at the new scale; the tooltip tools follow.
        var dpiLines: [String] = [], dpiOK = true
        for dpi: UInt32 in [120, 144] {
            let shownCount = panels.entries.count
            let r0 = hud.renderCount
            var rect = original
            _ = withUnsafeMutablePointer(to: &rect) { SendMessageW(hwnd, 0x02E0, WPARAM(dpi | (dpi << 16)), LPARAM(Int(bitPattern: $0))) }
            await pumpPanels(0.5)
            let scale = CGFloat(dpi) / 96
            let rendered = hud.renderCount - r0
            let scales = panels.entries.values.allSatisfy { $0.scale == scale }
            let toolsOK = shell.tooltipsForTesting?.count == panels.tips.count
            dpiOK = dpiOK && scales && rendered >= shownCount && rendered <= shownCount + 3 && toolsOK && hud.scale == scale
            dpiLines.append("\(dpi) dpi: renders \(rendered) for \(shownCount) shown panels, all at scale \(scale): \(scales), tools follow: \(toolsOK) \(shot("plaza-panels-\(dpi)dpi.png"))")
        }
        var back = original
        _ = withUnsafeMutablePointer(to: &back) { SendMessageW(hwnd, 0x02E0, WPARAM(96 | (96 << 16)), LPARAM(Int(bitPattern: $0))) }
        await pumpPanels(0.3)
        _ = SetWindowPos(hwnd, nil, original.left, original.top, original.right - original.left, original.bottom - original.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        await pumpPanels(0.4)
        r.add("plaza.dpiPanels", dpiOK, dpiLines.joined(separator: "; "))
    }
}
#endif
