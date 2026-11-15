import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// The canvas-drawn roster (Track A Task 17c) against `PlazaRosterView`, the SwiftUI view the Mac still shows: the size its
/// hosting view measures, where its text sits, and the pixels in a window at 1x and 2x. The "before" is the real view in a
/// hosting view in a never-shown window (forced backing scale), the "after" the panel through the host's layers; sample
/// pictures stand in for the downloaded icons. With `PTB_PLAZA_HUD_OUT` set it writes before/after images, diffs and a
/// contact sheet there.
@MainActor final class PlazaRosterPanelRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    typealias Rig = ContentRig
    static let seeded = Array(900_001...900_006)

    struct Mem {
        var nick: String, species: String = "피카츄", sid: Int? = 900_001, gender: PokemonGender? = nil, shiny = false
        var presence: PlazaPresence = .online, me = false
    }
    struct Case {
        var name: String
        var members: [Mem]
        var page = 0
        var capacity = 6
        var animating = false
        var wait = 250
        var viewport = CGSize(width: 960, height: 640)
    }

    static func members(_ n: Int, _ make: (Int) -> Mem = { Mem(nick: "친구\($0)", species: "포켓몬\($0)", sid: seeded[$0 % 6]) }) -> [Mem] { (0..<n).map(make) }
    static let korean = "아주아주아주아주긴한국어닉네임입니다"
    static let cases: [Case] = [
        Case(name: "empty", members: []),
        Case(name: "one-me", members: [Mem(nick: "나", me: true)]),
        Case(name: "full-page", members: [Mem(nick: "나", species: "이상해씨", sid: 900_002, gender: .female, shiny: true, me: true),
                                          Mem(nick: "민수", species: "파이리", sid: 900_003, gender: .male),
                                          Mem(nick: "지연", species: "꼬부기", sid: 900_004, presence: .focus),
                                          Mem(nick: "하늘", species: "피카츄", sid: 900_005, gender: .female, presence: .idle),
                                          Mem(nick: "바다", species: "푸린", sid: 900_006, shiny: true, presence: .asleep),
                                          Mem(nick: "나무", species: "알", sid: nil)]),
        Case(name: "pages-p0", members: members(14)),
        Case(name: "pages-p1", members: members(14), page: 1),
        Case(name: "pages-p2", members: members(14), page: 2),
        Case(name: "capacity-2", members: members(5), capacity: 2),
        Case(name: "long-korean", members: [Mem(nick: korean, species: "아주아주아주아주아주긴포켓몬이름이에요", gender: .male, shiny: true),
                                            Mem(nick: "Averyveryverylongnicknamethatgoesonandon", species: "Averyveryverylongspeciesnameoverflowing", gender: .female),
                                            Mem(nick: "짧", species: "짧", presence: .idle)]),
        Case(name: "long-with-marks", members: [Mem(nick: korean, gender: .female, shiny: true, presence: .asleep), Mem(nick: "ＷＷＷＷＷＷＷＷＷＷＷＷ", gender: .male, shiny: true, presence: .focus)]),
        Case(name: "every-state", members: [Mem(nick: "나", me: true), Mem(nick: "접속", presence: .online), Mem(nick: "집중", presence: .focus),
                                            Mem(nick: "자리", presence: .idle), Mem(nick: "잠", presence: .asleep),
                                            Mem(nick: "내자리", presence: .idle, me: true)]),
        Case(name: "icons-missing", members: [Mem(nick: "없음", sid: 990_001), Mem(nick: "없음2", sid: 990_002, presence: .idle), Mem(nick: "알", species: "알", sid: nil)]),
        Case(name: "animating-at-rest", members: members(4), animating: true),
        Case(name: "small-window", members: members(5), capacity: PlazaRoster.capacity(forHeight: 372), viewport: CGSize(width: 600, height: 372)),
    ]

    private func model(_ c: Case) -> PlazaRosterModel {
        let m = PlazaRosterModel()
        m.entries = PlazaRoster.sorted(c.members.enumerated().map { i, x in
            PlazaRosterEntry(id: "m\(i)", nickname: x.nick, speciesID: x.sid, speciesName: x.species, gender: x.gender, isShiny: x.shiny,
                             presence: x.presence, isMe: x.me)
        })
        m.capacity = c.capacity
        m.page = c.page
        m.isAnimating = c.animating
        return m
    }

    override func setUp() async throws {
        Rig.blockNetwork()
        await Rig.seedIcons(Self.seeded)
        _ = await SpriteLoader.eggImage()   // the egg from the sprite cache, if this Mac has one: in memory for both sides
    }

    func origin(_ viewport: CGSize, _ size: CGSize) -> CGPoint { CGPoint(x: viewport.width - PlazaRosterMetrics.margin - size.width, y: PlazaRosterMetrics.margin) }

    /// `ImageRenderer` draws the roster (it has no scroll view) with SwiftUI's text shadows the right way up; a hosting view's
    /// `cacheDisplay` turns them over (see `ContentRig.renderedWithPatch`). Its icons are the ones in `PlazaIconLoader`'s memory;
    /// the bounce (a task in a window) is not run, so this is the "down" state; `testTheBounceMovesTheIconAsSwiftUIDid` has the rest.
    private func before(_ c: Case, scale: CGFloat) async throws -> (image: CGImage, size: CGSize) {
        let view = LegacyPlazaRosterView(model: model(c))
        let shown = try XCTUnwrap(K.render(view, scale: scale))
        let size = CGSize(width: CGFloat(shown.width) / scale, height: CGFloat(shown.height) / scale)
        let ctx = K.context(Int(c.viewport.width * scale), Int(c.viewport.height * scale))
        let o = origin(c.viewport, size)
        ctx.draw(shown, in: CGRect(x: o.x * scale, y: (c.viewport.height - o.y) * scale - CGFloat(shown.height), width: CGFloat(shown.width), height: CGFloat(shown.height)))
        return (try XCTUnwrap(ctx.makeImage()), size)
    }

    private func after(_ c: Case, scale: CGFloat) async throws -> (image: CGImage, rig: Rig.After, panel: PlazaRosterPanel) {
        let panel = PlazaRosterPanel(model: model(c))
        let a = Rig.After(panel, viewport: c.viewport, scale: scale)
        for _ in 0..<20 { await Task.yield() }
        return (try a.image(c.viewport, scale: scale), a, panel)
    }

    /// How SwiftUI scales a pixel-art picture with `.interpolation(.none)`: through `ImageRenderer` and through a hosting view's
    /// `cacheDisplay`, counting the in-between colours along one edge of a 2x enlargement.
    func testHowSwiftUIEnlargesPixelArt() throws {
        let image = try XCTUnwrap(NSImage(data: Rig.iconData(900_001)))
        let view = Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 40, height: 30)
        let direct = try XCTUnwrap(K.render(view, scale: 2))
        let host = Rig.Before(view, viewport: CGSize(width: 40, height: 30), scale: 2)
        let hosted = try host.capture()
        func softEdge(_ im: CGImage) -> Int {
            let px = K.rgba(im), w = im.width
            var n = 0
            for x in 0..<w { let i = (30 * w + x) * 4; let a = px[i + 3]; if a > 10 && a < 245 { n += 1 } }
            return n
        }
        print("PIXELART imageRenderer soft \(softEdge(direct)) hosted soft \(softEdge(hosted)) sizes \(direct.width) \(hosted.width)")
    }

    func testSampleIconsDecodeAndAreSeeded() throws {
        let img = try XCTUnwrap(NSImage(data: Rig.iconData(900_001)))
        XCTAssertEqual(img.size, CGSize(width: 40, height: 30))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Rig.iconData(900_001)))
        XCTAssertGreaterThan(rep.colorAt(x: 20, y: 15)?.alphaComponent ?? 0, 0.9)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertNotNil(PlazaIconLoader.cachedIcon(speciesID: 900_001))
    }

    func testPanelFramesAreTheHostingViewFramesSwiftUIHad() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let (_, size) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                XCTAssertEqual(a.rig.frame, CGRect(origin: origin(c.viewport, size), size: size), "\(c.name)@\(scale): SwiftUI measured \(size)")
                print("FRAME \(c.name)@\(Int(scale))x \(size)")
            }
        }
    }

    func testPanelLooksLikeItsSwiftUIOriginal() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let (b, _) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                let d = K.diff(b, a.image)
                print("ERR \(c.name)@\(Int(scale))x over8 \(d.over8) over64 \(d.over64) max \(d.max)")
                // Measured: text and plate match to antialiasing (the 2x error is the shadows' and glyph edges'), a layout slip is
                // hundreds of pixels more than 64 off. Pinned with room.
                XCTAssertLessThan(d.over8, scale == 1 ? 3300 : 12_000, "\(c.name)@\(scale): \(d.over8) pixels off by more than 8")
                XCTAssertLessThan(d.over64, 60, "\(c.name)@\(scale): \(d.over64) pixels off by more than 64")
            }
        }
    }

    func testWriteRosterImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        var shots: [Rig.Shot] = []
        for c in Self.cases where Rig.only(c.name) {
            for scale in [CGFloat(2), 1] {
                let (b, size) = try await before(c, scale: scale)
                let a = try await after(c, scale: scale)
                let o = origin(c.viewport, size)
                shots.append(Rig.Shot(tag: c.name, scale: scale, before: b, after: a.image,
                                      crop: CGRect(x: o.x - 8, y: o.y - 8, width: size.width + 16, height: size.height + 16), viewport: c.viewport))
            }
        }
        try Rig.write(shots, to: dir)
    }
}
