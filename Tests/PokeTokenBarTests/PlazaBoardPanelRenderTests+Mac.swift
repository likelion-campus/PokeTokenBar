import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// The canvas-drawn news board (Track A Task 17d) against `PlazaBoardView` inside `PlazaOverlayView`, as the Mac window shows it
/// (a hosting view over the whole window in a never-shown window at a forced backing scale), and the panel through the host's
/// layers. A `ScrollView` is scrolled by moving its `NSScrollView`'s clip view. With `PTB_PLAZA_HUD_OUT` set it writes the images.
@MainActor final class PlazaBoardPanelRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    typealias Rig = ContentRig
    private var dirs: [URL] = []

    struct Ev {
        var id: String, species = "깨봉이", kind: TeamEventKind = .hatch, shiny = false, day = "2026-10-30", nick = "민수", dated = true
        var reactions: [(by: String, kind: TeamReactionKind, mine: Bool)] = []
    }
    struct Case {
        var name: String
        var events: [Ev]
        var scroll: CGFloat = 0
        var viewport = CGSize(width: 960, height: 640)
    }

    /// The feed keeps species names of at most 64 bytes (`TeamWire.maxFieldBytes`): 21 Hangul syllables.
    static let korean = "아주 긴 한국어 이름의 포켓몬입니다 정말"
    static func many(_ n: Int) -> [Ev] {
        (0..<n).map { i in
            var e = Ev(id: "e\(i)", species: "포켓몬\(i)", kind: i % 4 == 0 ? .graduate : .hatch, shiny: i % 5 == 3)
            if i % 3 == 0 { e.reactions = [("영희", .cute, false), ("철수", .cute, false), ("나", .lol, true)] }
            return e
        }
    }
    static let cases: [Case] = [
        Case(name: "empty", events: []),
        Case(name: "few", events: [Ev(id: "a", reactions: [("영희", .cute, false), ("철수", .cute, false), ("영희", .congrats, false)]),
                                   Ev(id: "b", species: "이상해씨", kind: .graduate, shiny: true, day: "2026-10-29", dated: false, reactions: [("나", .lol, true)]),
                                   Ev(id: "c", species: "파이리", day: "2026-10-28", dated: false)]),
        Case(name: "many-top", events: many(30)),
        Case(name: "many-scrolled", events: many(30), scroll: 400),
        Case(name: "many-bottom", events: many(30), scroll: 100_000),
        Case(name: "long-notes", events: [Ev(id: "a", species: korean, kind: .graduate), Ev(id: "b", species: String(repeating: "abcdefghij", count: 6)),
                                          Ev(id: "c", species: korean, reactions: [("긴이름긴이름긴이름", .cute, false), ("또다른긴이름", .cute, false), ("세번째긴이름입니다", .cute, false),
                                                                                 ("네번째긴이름입니다", .cute, false), ("다섯번째긴이름입니다", .cute, false)])]),
        Case(name: "emoji", events: [Ev(id: "a", species: "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀", reactions: [("🐶🐱", .cute, false)]), Ev(id: "b", species: "🔥 불꽃 🐕 and 😀")]),
        Case(name: "rtl", events: [Ev(id: "a", species: "שלום עולם זה טקסט ארוך מאוד בעברית"), Ev(id: "b", species: "English ואז עברית then 한국어", reactions: [("שלום", .lol, false)])]),
        Case(name: "small-window", events: many(6), viewport: CGSize(width: 600, height: 380)),
    ]

    private func feed(_ c: Case) -> TeamFeedStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaBoardPanelRenderTests-\(UUID())")
        dirs.append(dir)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let f = TeamFeedStore(fileURL: dir.appendingPathComponent("team-feed.json"), myMemberID: "me", clock: { Date(timeIntervalSince1970: 1_793_400_000) }, calendar: cal)
        // The feed lists the newest first: the array's order is the board's, an event a minute older than the one before it.
        for (i, e) in c.events.enumerated().reversed() {
            f.insert(TeamEvent(id: e.id, authorID: "a", authorNickname: e.nick, kind: e.kind, speciesID: 25, fromSpeciesID: nil, speciesName: e.species, fromSpeciesName: nil,
                               form: nil, isShiny: e.shiny, nature: nil, rarity: .common, day: e.day,
                               occurredAt: e.dated ? Date(timeIntervalSince1970: 1_793_400_000 - 3600 - Double(i) * 60) : nil))
            for (i, r) in e.reactions.enumerated() {
                f.insert(TeamReaction(id: "\(e.id)-r\(i)", eventID: e.id, authorID: r.mine ? "me" : r.by, authorNickname: r.by, kind: r.kind, text: nil, createdAt: Date(timeIntervalSince1970: 1_793_000_100)))
            }
        }
        return f
    }

    override func tearDown() async throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews { if let s = findScroll(sub) { return s } }
        return nil
    }

    /// `limit`: how far the panel can scroll. SwiftUI's lazy stack estimates its content taller than it is and lets the scroll view
    /// go past the real end, so the "before" is not scrolled further than the content really goes.
    private func before(_ c: Case, scale: CGFloat, limit: CGFloat = .infinity) async throws -> (image: CGImage, scrolled: CGFloat) {
        let model = PlazaOverlayModel()
        model.content = .board
        let theFeed = feed(c)
        let b = Rig.Before(PlazaOverlayView(model: model, feed: theFeed, myMemberID: "me"), viewport: c.viewport, scale: scale, fill: true)
        await Rig.settle()
        var scrolled: CGFloat = 0
        if c.scroll > 0, let sv = findScroll(b.host) {
            let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
            scrolled = min(c.scroll, maxY, limit)
            print("SCROLLVIEW \(c.name)@\(scale) doc \(sv.documentView?.frame ?? .zero) clip \(sv.contentView.bounds) flipped \(sv.documentView?.isFlipped == true) sv \(sv.frame)")
            // In steps, as a wheel scrolls: a lazy stack lays out the rows it passes (a jump leaves its estimate of the rows it skipped).
            for y in stride(from: 100, to: scrolled, by: 100) + [scrolled] {
                sv.contentView.scroll(to: NSPoint(x: 0, y: sv.documentView?.isFlipped == true ? y : maxY - y))
                sv.reflectScrolledClipView(sv.contentView)
                await Rig.settle(60)
            }
            await Rig.settle()
        }
        let hosted = try b.capture()
        let size: CGSize = CGSize(width: 340, height: 380)
        let origin = CGPoint(x: (c.viewport.width - size.width) / 2, y: (c.viewport.height - size.height) / 2)
        let list = PlazaBoardStyle.list
        return (try Rig.renderedWithPatch(PlazaOverlayView(model: model, feed: theFeed, myMemberID: "me"), viewport: c.viewport, scale: scale, hosted: hosted,
                                          patch: list.offsetBy(dx: origin.x, dy: origin.y)), scrolled)
    }

    private func after(_ c: Case, scale: CGFloat, scrolled: CGFloat? = nil) async throws -> (image: CGImage, rig: Rig.After, panel: PlazaBoardPanel) {
        let model = PlazaOverlayModel()
        model.content = .board
        let panel = PlazaBoardPanel(model: model, feed: feed(c), myMemberID: "me")
        let a = Rig.After(panel, viewport: c.viewport, scale: scale)
        for _ in 0..<20 { await Task.yield() }
        let dy = scrolled ?? c.scroll
        if dy > 0 {
            _ = panel.scroll(dx: 0, dy: -dy, at: CGPoint(x: 100, y: 100))
            for _ in 0..<20 { await Task.yield() }
        }
        return (try a.image(c.viewport, scale: scale), a, panel)
    }

    func testPanelFrameIsWhereTheOverlayPutIt() async throws {
        for c in Self.cases {
            let a = try await after(c, scale: 2)
            XCTAssertEqual(a.rig.frame, CGRect(x: (c.viewport.width - 340) / 2, y: (c.viewport.height - 380) / 2, width: 340, height: 380), c.name)
        }
    }

    func testPanelLooksLikeItsSwiftUIOriginal() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let limit = try await after(c, scale: scale).panel.scrollState.maxOffset
                let (b, scrolled) = try await before(c, scale: scale, limit: limit)
                let a = try await after(c, scale: scale, scrolled: scrolled)
                XCTAssertEqual(b.width, a.image.width, "\(c.name)@\(scale) width"); XCTAssertEqual(b.height, a.image.height, "\(c.name)@\(scale) height")
                guard b.width == a.image.width, b.height == a.image.height else { continue }
                let d = K.diff(b, a.image)
                print("ERR \(c.name)@\(Int(scale))x over8 \(d.over8) over64 \(d.over64) max \(d.max) scrolled \(scrolled)")
                let emoji = c.name == "emoji"   // colour emoji sit one device pixel higher than SwiftUI's (Task 14's known difference)
                XCTAssertLessThan(d.over8, emoji ? 20_000 : (scale == 1 ? 1000 : 3000), "\(c.name)@\(scale): \(d.over8) pixels off by more than 8")
                XCTAssertLessThan(d.over64, emoji ? 7000 : 20, "\(c.name)@\(scale): \(d.over64) pixels off by more than 64")
            }
        }
    }

    func testWriteBoardImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        var shots: [Rig.Shot] = []
        for c in Self.cases where Rig.only(c.name) {
            for scale in [CGFloat(2), 1] {
                let limit = try await after(c, scale: scale).panel.scrollState.maxOffset
                let (b, scrolled) = try await before(c, scale: scale, limit: limit)
                let a = try await after(c, scale: scale, scrolled: scrolled)
                shots.append(Rig.Shot(tag: c.name, scale: scale, before: b, after: a.image, crop: CGRect(x: (c.viewport.width - 340) / 2 - 8, y: max(0, (c.viewport.height - 380) / 2 - 8), width: 356, height: 396), viewport: c.viewport))
            }
        }
        try Rig.write(shots, to: dir)
    }
}
