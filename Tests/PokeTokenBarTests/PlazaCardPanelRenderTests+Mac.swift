import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

/// The canvas-drawn member card (Track A Task 17d) against `PlazaCardView` inside `PlazaOverlayView`, as the Mac window shows it,
/// and the panel through the host's layers; sample pictures stand in for the downloaded ones. With `PTB_PLAZA_HUD_OUT` set it
/// writes the images.
@MainActor final class PlazaCardPanelRenderTests: XCTestCase {
    typealias K = PlazaPanelRenderTests
    typealias Rig = ContentRig
    static let seeded = Array(900_001...900_006)

    struct Case {
        var name: String
        var state: PlazaCardState
        var scroll: CGFloat = 0
        var viewport = CGSize(width: 960, height: 640)
        var dark = false   // the SwiftUI view in the dark colour scheme, the panel with `isDark`
    }

    static func activity(_ n: Int = 1) -> PlazaActivity {
        var a = PlazaActivity(day: PlazaActivity.dayKey(Date()))
        a.addSeconds(3 * 3600 + 25 * 60)
        for _ in 0..<(12 * n) { a.record(.iceBreak) }
        for _ in 0..<(3 * n) { a.record(.firework) }
        a.record(.tackle); a.record(.snowballHit); a.record(.greeting); a.record(.pickup)
        return a
    }
    static func member(_ nick: String = "민수", species: Int? = 900_001, name: String? = "피카츄", shiny: Bool = false, color: UInt32? = nil, activity: PlazaActivity? = PlazaCardPanelRenderTests.activity()) -> TeamMemberState {
        var m = TeamMemberState(memberID: "member-\(nick)", nickname: nick, character: TeamMonSummary(speciesID: species, isShiny: shiny, form: nil, speciesName: name, gender: nil),
                                inPlaza: true, tile: nil, facing: nil, isWalking: false)
        m.nameColor = color
        m.activity = activity
        return m
    }
    static func dex(_ n: Int) -> [TeamDexSpecies] {
        (0..<n).map { i in
            TeamDexSpecies(speciesID: i % 7 == 6 ? 990_000 + i : seeded[i % 6], form: nil,
                           name: i == 2 ? "아주아주긴포켓몬이름입니다" : i == 4 ? "Averyverylongspeciesname" : "포켓몬\(i)",
                           rarity: [.common, .uncommon, .rare, .legendary][i % 4], hasShiny: i % 3 == 0, hasNormal: true)
        }
    }
    static func profile(_ m: TeamMemberState, dex: [TeamDexSpecies], current: TeamMonSummary? = nil) -> TeamMemberProfile {
        TeamMemberProfile(memberID: m.memberID, nickname: m.nickname, current: current ?? m.character, dex: dex)
    }

    static let cases: [Case] = makeCases()
    /// A function, not a closure initialiser: Swift 6.1 (the Mac CI's Xcode 16) crashes lowering the closure form.
    private static func makeCases() -> [Case] {
        let m = member()
        let longMember = member("가나다라마바사아자차카타", species: 900_005, name: "리자드", shiny: true, color: PlazaNameColor.hexes[3])
        let other = TeamMonSummary(speciesID: 900_006, isShiny: false, form: nil, speciesName: "리자몽", gender: nil)
        var stale = member(activity: nil)
        stale.activity = PlazaActivity(day: "2001-01-01")
        return [
            Case(name: "loading", state: .loading(m)),
            Case(name: "failed", state: .failed(m)),
            Case(name: "loaded-activity", state: .loaded(m, profile(m, dex: dex(12)))),
            Case(name: "loaded-no-record", state: .loaded(member(activity: nil), profile(member(activity: nil), dex: dex(12)))),
            Case(name: "loaded-stale-record", state: .loaded(stale, profile(stale, dex: dex(5)))),
            Case(name: "long-nickname", state: .loaded(longMember, profile(longMember, dex: dex(40), current: other))),
            Case(name: "latin-nickname", state: .loading(member("Averyverylongnicknamex", species: 900_002, name: "Bulbasaur"))),
            Case(name: "dex-few", state: .loaded(m, profile(m, dex: dex(3)))),
            Case(name: "dex-many-top", state: .loaded(m, profile(m, dex: dex(80)))),
            Case(name: "dex-many-scrolled", state: .loaded(m, profile(m, dex: dex(80))), scroll: 150),
            Case(name: "dex-many-600", state: .loaded(m, profile(m, dex: dex(80))), scroll: 600),
            Case(name: "dex-many-930", state: .loaded(m, profile(m, dex: dex(80))), scroll: 930),
            Case(name: "dex-many-bottom", state: .loaded(m, profile(m, dex: dex(80))), scroll: 100_000),
            Case(name: "small-window", state: .loaded(m, profile(m, dex: dex(20))), viewport: CGSize(width: 600, height: 460)),
            Case(name: "large-window", state: .loaded(m, profile(m, dex: dex(80))), scroll: 150, viewport: CGSize(width: 1920, height: 1080)),
            Case(name: "dark-header", state: .loaded(longMember, profile(longMember, dex: dex(12), current: other)), dark: true),
            Case(name: "dark-dex", state: .loaded(m, profile(m, dex: dex(80))), scroll: 150, dark: true),
        ]
    }

    override func setUp() async throws {
        Rig.blockNetwork(for: self)
        await Rig.seedIcons(Self.seeded)
        for id in Self.seeded { Rig.seedSprite(id); Rig.seedSprite(id, shiny: true) }
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
        model.content = .card(c.state)
        let b = Rig.Before(LegacyPlazaOverlayView(model: model).environment(\.colorScheme, c.dark ? .dark : .light), viewport: c.viewport, scale: scale, fill: true)
        await Rig.settle(400)
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
        let size: CGSize = PlazaCardMetrics.panelSize
        let origin = CGPoint(x: (c.viewport.width - size.width) / 2, y: (c.viewport.height - size.height) / 2)
        let list = PlazaCardStyle.lower
        return (try Rig.renderedWithPatch(LegacyPlazaOverlayView(model: model).environment(\.colorScheme, c.dark ? .dark : .light), viewport: c.viewport, scale: scale, hosted: hosted,
                                          patch: list.offsetBy(dx: origin.x, dy: origin.y)), scrolled)
    }

    private func after(_ c: Case, scale: CGFloat, scrolled: CGFloat? = nil) async throws -> (image: CGImage, rig: Rig.After, panel: PlazaCardPanel) {
        let model = PlazaOverlayModel()
        model.content = .card(c.state)
        let panel = PlazaCardPanel(model: model)
        panel.scrollIndicator.isDisabled = true   // the SwiftUI original draws no scroller off screen; the indicator has its own tests
        panel.isDark = c.dark
        let a = Rig.After(panel, viewport: c.viewport, scale: scale)
        for _ in 0..<20 { await Task.yield() }
        let dy = scrolled ?? c.scroll
        if dy > 0 {
            _ = panel.scroll(dx: 0, dy: -dy, at: CGPoint(x: 100, y: 300))
            for _ in 0..<20 { await Task.yield() }
        }
        return (try a.image(c.viewport, scale: scale), a, panel)
    }

    /// The four rarity colours are what SwiftUI's `rarityColor` resolves to in an `ImageRenderer` (the system's current appearance).
    func testRarityColoursAreSwiftUIs() throws {
        for r in [Rarity.common, .uncommon, .rare, .legendary] {
            let image = try XCTUnwrap(K.render(Rectangle().fill(rarityColor(r)).frame(width: 4, height: 4), scale: 1))
            let px = K.rgba(image)
            let want = PlazaCardStyle.rarity(r)
            print("RARITY \(r) swiftui \(px[0]) \(px[1]) \(px[2]) panel \(Int((want.red * 255).rounded())) \(Int((want.green * 255).rounded())) \(Int((want.blue * 255).rounded()))")
            XCTAssertEqual(Int(px[0]), Int((want.red * 255).rounded()), accuracy: 1, "\(r) red")
            XCTAssertEqual(Int(px[1]), Int((want.green * 255).rounded()), accuracy: 1, "\(r) green")
            XCTAssertEqual(Int(px[2]), Int((want.blue * 255).rounded()), accuracy: 1, "\(r) blue")
        }
    }

    /// The SwiftUI card's rarity colours followed dark mode (`.green`, `.blue`, `.orange` and `.gray` are adaptive system colours): the
    /// panel's dark set is what SwiftUI resolves in the dark colour scheme, and its light set is unchanged.
    func testRarityColoursFollowTheAppearanceAsSwiftUIsDid() throws {
        for dark in [false, true] {
            for r in [Rarity.common, .uncommon, .rare, .legendary] {
                let image = try XCTUnwrap(K.render(Rectangle().fill(rarityColor(r)).frame(width: 4, height: 4).environment(\.colorScheme, dark ? .dark : .light), scale: 1))
                let px = K.rgba(image)
                let want = PlazaCardStyle.rarity(r, dark: dark)
                print("RARITY \(dark ? "dark" : "light") \(r) swiftui \(px[0]) \(px[1]) \(px[2]) panel \(Int((want.red * 255).rounded())) \(Int((want.green * 255).rounded())) \(Int((want.blue * 255).rounded()))")
                XCTAssertEqual(Int(px[0]), Int((want.red * 255).rounded()), accuracy: 1, "\(dark) \(r) red")
                XCTAssertEqual(Int(px[1]), Int((want.green * 255).rounded()), accuracy: 1, "\(dark) \(r) green")
                XCTAssertEqual(Int(px[2]), Int((want.blue * 255).rounded()), accuracy: 1, "\(dark) \(r) blue")
            }
        }
    }

    /// Review item 7: what SwiftUI's system colours resolve to in the four combinations of appearance and Increase Contrast. MEASURED: the
    /// high-contrast appearances resolve to the same four values as the plain ones for these colours, so Increase Contrast changes nothing
    /// and the panel's light/dark sets are right for all four (this pins that).
    func testRarityColoursInEveryAppearanceAndContrastAreSwiftUIs() throws {
        for (dark, high, name) in [(false, false, NSAppearance.Name.aqua), (true, false, .darkAqua), (false, true, .accessibilityHighContrastAqua),
                                   (true, true, .accessibilityHighContrastDarkAqua)] {
            for r in [Rarity.common, .uncommon, .rare, .legendary] {
                // SwiftUI's `.green`, `.blue`, `.orange`, `.gray` are the system colours; resolved under the appearance (which carries dark and
                // Increase Contrast) they are what the card drew.
                let system: NSColor = switch r { case .uncommon: .systemGreen; case .rare: .systemBlue; case .legendary: .systemOrange; default: .systemGray }
                var resolved: NSColor?
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance { resolved = system.usingColorSpace(.sRGB) }
                let c = try XCTUnwrap(resolved)
                let want = PlazaCardStyle.rarity(r, dark: dark)
                let got = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                print("RARITY2 \(dark ? "dark" : "light") \(high ? "high" : "std") \(r) swiftui \(got) panel \(Int((want.red * 255).rounded())) \(Int((want.green * 255).rounded())) \(Int((want.blue * 255).rounded()))")
                XCTAssertEqual(got.0, Int((want.red * 255).rounded()), accuracy: 1, "\(dark) \(high) \(r) red")
                XCTAssertEqual(got.1, Int((want.green * 255).rounded()), accuracy: 1, "\(dark) \(high) \(r) green")
                XCTAssertEqual(got.2, Int((want.blue * 255).rounded()), accuracy: 1, "\(dark) \(high) \(r) blue")
            }
        }
    }

    func testPrintMetrics() {
        for f in [PlazaFont.plaza(.small), .plaza(.body)] {
            let m = PlatformPlaza.graphics.text.metrics(f)
            print("METRICS \(f) asc \(m.ascender) desc \(m.descender) lead \(m.leading)")
            let ns = PlazaResources.font(f == .plaza(.small) ? .small : .body)
            print("NSFONT \(ns.pointSize) asc \(ns.ascender) desc \(ns.descender) lead \(ns.leading) lh \(NSLayoutManager().defaultLineHeight(for: ns))")
        }
    }

    func testPanelFrameIsWhereTheOverlayPutIt() async throws {
        for c in Self.cases {
            let a = try await after(c, scale: 2)
            let size = PlazaCardMetrics.panelSize
            XCTAssertEqual(a.rig.frame, CGRect(x: (c.viewport.width - size.width) / 2, y: (c.viewport.height - size.height) / 2, width: size.width, height: size.height), c.name)
        }
    }

    func testPanelLooksLikeItsSwiftUIOriginal() async throws {
        for c in Self.cases {
            for scale in [CGFloat(1), 2] {
                let limit = try await after(c, scale: scale).panel.scrollState.maxOffset
                let (b, scrolled) = try await before(c, scale: scale, limit: limit)
                let a = try await after(c, scale: scale, scrolled: scrolled)
                XCTAssertEqual(b.width, a.image.width, "\(c.name)@\(scale) width")
                guard b.width == a.image.width, b.height == a.image.height else { continue }
                let d = K.diff(b, a.image)
                print("ERR \(c.name)@\(Int(scale))x over8 \(d.over8) over64 \(d.over64) max \(d.max) scrolled \(scrolled)")
                let emoji = c.name == "emoji"   // colour emoji sit one device pixel higher than SwiftUI's (Task 14's known difference)
                XCTAssertLessThan(d.over8, emoji ? 20_000 : (scale == 1 ? 2800 : 13000), "\(c.name)@\(scale): \(d.over8) pixels off by more than 8")
                XCTAssertLessThan(d.over64, emoji ? 7000 : 20, "\(c.name)@\(scale): \(d.over64) pixels off by more than 64")
            }
        }
    }

    func testWriteCardImages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PTB_PLAZA_HUD_OUT"] else { throw XCTSkip("PTB_PLAZA_HUD_OUT not set") }
        var shots: [Rig.Shot] = []
        for c in Self.cases where Rig.only(c.name) {
            for scale in [CGFloat(2), 1] {
                let limit = try await after(c, scale: scale).panel.scrollState.maxOffset
                let (b, scrolled) = try await before(c, scale: scale, limit: limit)
                let a = try await after(c, scale: scale, scrolled: scrolled)
                let size = PlazaCardMetrics.panelSize
                shots.append(Rig.Shot(tag: c.name, scale: scale, before: b, after: a.image,
                                      crop: CGRect(x: (c.viewport.width - size.width) / 2 - 8, y: max(0, (c.viewport.height - size.height) / 2 - 8), width: size.width + 16, height: size.height + 16), viewport: c.viewport))
            }
        }
        try Rig.write(shots, to: dir)
    }
}
