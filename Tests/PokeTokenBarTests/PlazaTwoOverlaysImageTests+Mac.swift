import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Task 17w review item 13: the whole 960 x 640 window with two overlays open at once (the roster is always there): chat log + roster + card, and
/// chat log + roster + board. "Before" is the deleted SwiftUI views stacked in the old z-order (roster, overlay, chat log) over the plaza map;
/// "after" is the REAL window's panel hosts (`PlazaMacWindow` through the rig) over the same map. With `PTB_PLAZA_HUD_OUT` set it writes
/// before/after/diff PNGs and a sheet.
@MainActor final class PlazaTwoOverlaysImageTests: XCTestCase {
    typealias Rig = ContentRig
    typealias K = PlazaPanelRenderTests
    private var dirs: [URL] = []
    override func tearDown() async throws { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }

    private func feed() -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaTwoOverlays-\(UUID())")
        dirs.append(dir)
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        let f = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "member-1", clock: { now })
        for i in (0..<14).reversed() {
            f.insert(TeamEvent(id: "e\(i)", authorID: "a", authorNickname: "민수", kind: .hatch, speciesID: 25, fromSpeciesID: nil, speciesName: "포켓몬\(i)", fromSpeciesName: nil,
                               form: nil, isShiny: i == 2, nature: nil, rarity: .common, day: "2026-10-30", occurredAt: now.addingTimeInterval(-3600 - Double(i) * 60)))
        }
        f.insert(TeamReaction(id: "r0", eventID: "e1", authorID: "x", authorNickname: "영희", kind: .cute, text: nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100)))
        return f
    }

    func testWriteTheWholeWindowWithTwoOverlaysOpen() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Rig.blockNetwork()
        let seeded = Array(900_001...900_006)
        await Rig.seedIcons(seeded)
        for id in seeded { Rig.seedSprite(id); Rig.seedSprite(id, shiny: true) }
        let viewport = CGSize(width: 960, height: 640)
        let map = try XCTUnwrap(PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(PlazaMapData.map, sheet: $0, tallGrass: nil) })
        func background(_ scale: CGFloat) -> CGImage {
            let ctx = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            ctx.interpolationQuality = .none
            let size = CGSize(width: CGFloat(map.width) * scale, height: CGFloat(map.height) * scale)
            ctx.draw(map.cgImage, in: CGRect(x: -300 * scale, y: viewport.height * scale - size.height + 200 * scale, width: size.width, height: size.height))
            return ctx.makeImage()!
        }
        let people = (0..<4).map { PlazaRosterEntry(id: "m\($0)", nickname: "친구\($0)", speciesID: seeded[$0], speciesName: "포켓몬\($0)", gender: $0 == 1 ? .male : nil,
                                                    isShiny: $0 == 2, presence: [.online, .idle, .focus, .asleep][$0], isMe: $0 == 0) }
        let m = TeamMemberState(memberID: "m-민수", nickname: "민수", character: TeamMonSummary(speciesID: seeded[0], isShiny: true, form: nil, speciesName: "포켓몬", gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        let dex = (0..<12).map { TeamDexSpecies(speciesID: seeded[$0 % 6], form: nil, name: "포켓몬\($0)", rarity: [.common, .uncommon, .rare, .legendary][$0 % 4], hasShiny: $0 % 3 == 0, hasNormal: true) }
        let card = PlazaCardState.loaded(m, TeamMemberProfile(memberID: m.memberID, nickname: "민수", current: m.character, dex: dex))
        var rows: [(label: String, cells: [CGImage])] = []
        var summary: [String] = []
        for (name, content) in [("card", PlazaOverlayContent.card(card)), ("board", .board)] {
            let theFeed = feed()
            let rig = try PlazaWindowRig(feed: theFeed, icons: MacPlazaIcons())
            defer { rig.close() }
            let scale = rig.hud.scale
            rig.overlays.rosterModel.entries = people
            rig.overlays.rosterModel.isAnimating = false
            for i in 0..<5 { rig.overlays.chatLog.append(time: Date(timeIntervalSince1970: 1_700_000_000), name: "친구\(i % 3)", text: "안녕하세요 \(i)", color: PlazaNameColor.palette[i % 6], isLoud: i == 3) }
            rig.overlays.overlayModel.content = content
            rig.controller.scene?.isOverlayOpen = true
            for _ in 0..<5 { await rig.flush(); await Rig.settle(100) }
            // AFTER: the window's hosts, bottom first, over the map.
            let bg = background(scale)
            let after = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            after.draw(bg, in: CGRect(x: 0, y: 0, width: bg.width, height: bg.height))
            after.scaleBy(x: scale, y: scale)
            for id in [PlazaPanelID.roster, .board, .card, .chatLog] { if let l = rig.host(id)?.layer { l.render(in: after) } }
            let afterImage = after.makeImage()!
            // BEFORE: the deleted views stacked in the old order (roster, overlay, chat log).
            let rosterModel = PlazaRosterModel()
            rosterModel.entries = people
            rosterModel.isAnimating = false
            let overlayModel = PlazaOverlayModel()
            overlayModel.content = content
            let logModel = PlazaChatLog()
            for i in 0..<5 { logModel.append(time: Date(timeIntervalSince1970: 1_700_000_000), name: "친구\(i % 3)", text: "안녕하세요 \(i)", color: PlazaNameColor.palette[i % 6], isLoud: i == 3) }
            let rosterImage = try XCTUnwrap(K.render(LegacyPlazaRosterView(model: rosterModel), scale: scale))
            let overlayView = LegacyPlazaOverlayView(model: overlayModel, feed: theFeed, myMemberID: "member-1")
            let hosted = try Rig.Before(overlayView, viewport: viewport, scale: scale, fill: true).capture()
            await Rig.settle(400)
            let hosted2 = try Rig.Before(overlayView, viewport: viewport, scale: scale, fill: true)
            await Rig.settle(400)
            let patch = name == "card" ? PlazaCardStyle.lower.offsetBy(dx: (viewport.width - PlazaCardMetrics.panelSize.width) / 2, dy: (viewport.height - PlazaCardMetrics.panelSize.height) / 2)
                                       : PlazaBoardStyle.list.offsetBy(dx: (viewport.width - 340) / 2, dy: (viewport.height - 380) / 2)
            _ = hosted
            let overlayImage = try Rig.renderedWithPatch(overlayView, viewport: viewport, scale: scale, hosted: try hosted2.capture(), patch: patch)
            let logBefore = Rig.Before(LegacyPlazaChatLogView(log: logModel), viewport: viewport, scale: scale)
            await Rig.settle(300)
            let logImage = try logBefore.placed(at: CGPoint(x: 16, y: viewport.height - 16 - logBefore.size.height))
            let before = K.context(Int(viewport.width * scale), Int(viewport.height * scale))
            before.draw(bg, in: CGRect(x: 0, y: 0, width: bg.width, height: bg.height))
            let rs = CGSize(width: CGFloat(rosterImage.width), height: CGFloat(rosterImage.height))
            before.draw(rosterImage, in: CGRect(x: (viewport.width - PlazaRosterMetrics.margin) * scale - rs.width, y: (viewport.height - PlazaRosterMetrics.margin) * scale - rs.height, width: rs.width, height: rs.height))
            before.draw(overlayImage, in: CGRect(x: 0, y: 0, width: overlayImage.width, height: overlayImage.height))
            before.draw(logImage, in: CGRect(x: 0, y: 0, width: logImage.width, height: logImage.height))
            let beforeImage = before.makeImage()!
            let d = K.diff(beforeImage, afterImage)
            try K.write(beforeImage, out.appendingPathComponent("before-\(name)@\(Int(scale))x.png"))
            try K.write(afterImage, out.appendingPathComponent("after-\(name)@\(Int(scale))x.png"))
            try K.write(d.image, out.appendingPathComponent("diff-\(name)@\(Int(scale))x.png"))
            let line = "two-overlays-\(name)@\(Int(scale))x: pixels differing >8: \(d.over8), >64: \(d.over64), max \(d.max)"
            summary.append(line)
            rows.append((line, [beforeImage, afterImage, d.image]))
        }
        try summary.joined(separator: "\n").write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        try K.write(K.sheet(rows, columns: ["before (SwiftUI, old z-order)", "after (the real window's hosts)", "diff"]), out.appendingPathComponent("sheet-two-overlays.png"))
    }
}
