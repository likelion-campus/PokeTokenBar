import XCTest
@testable import PokeTokenBar

/// "In Collection, below the 4x4 list, the paging arrows' colour blends into the background - they cannot be seen" (user report, dark mode,
/// real PC). The arrows were font glyphs rastered by the platform; they are now stroked paths in the label colours. This renders the real
/// `DexBodyPart` (page 1, a middle page, the last) in light, dark and both high-contrast themes, composes it over the window colour and
/// measures the pixels in each arrow's box: an enabled arrow reaches 3:1 against its surface, a disabled one (first/last page) 1.5:1.
/// Mac only: the canvas is CoreGraphics. The other drawn glyphs' pairs are held at the token level below.
@MainActor
final class DexPagerInkTests: XCTestCase {
    private func store(count: Int) throws -> CompanionStore {
        struct Offline: PokeProviding {
            func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
            func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
            func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dex-pager-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        let rarities: [Rarity] = [.common, .uncommon, .rare, .legendary]
        state.dex = (1...count).map { id in
            DexEntry(id: "e\(id)", baseID: id, finalID: id, chainOrder: [id], rarity: rarities[id % 4], caughtAt: Date().addingTimeInterval(-Double(id) * 5400),
                     isShiny: id % 7 == 0, names: [id: ["en": "Species \(id)", "ko": "종 \(id)"]])
        }
        try JSONEncoder().encode(state).write(to: file)
        return CompanionStore(provider: Offline(), fileURL: file, rng: SeededRNG(seed: 3))
    }

    private static let black = PopoverHighContrast(window: 0x000000, text: 0xFFFFFF, highlight: 0x1AEBFF, highlightText: 0x000000)
    private static let white = PopoverHighContrast(window: 0xFFFFFF, text: 0x000000, highlight: 0x0000C0, highlightText: 0xFFFFFF)
    private static let appearances: [(String, PopoverAppearance, PopoverHighContrast?, UInt32)] = [
        ("light", .light, nil, 0xF3F3F3), ("dark", .dark, nil, 0x202020), ("high contrast black", .light, black, 0x000000), ("high contrast white", .light, white, 0xFFFFFF),
    ]

    /// The worst (lowest) contrast between the surface and the ink pixels in `box`: the strongest pixel is what the eye finds.
    private func peakContrast(_ page: Int, count: Int, surface: UInt32, arrow: (DexBodyPart.Layout) -> CGRect?, enabled: Bool) throws -> Double {
        let graphics = PlatformPlaza.graphics
        let scale: CGFloat = 2
        let st = try store(count: count)
        var state = DexBrowserState()
        state.page = page
        let part = DexBodyPart(DexBodyModel.make(store: st, state: state), height: 456)
        let size = part.size(width: 332, scale: scale, text: graphics.text)
        let drawing = part.render(scale: scale, graphics: graphics)
        let lay = try XCTUnwrap(part.laid)
        let box = try XCTUnwrap(arrow(lay))
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let bytes = PopoverComposite.compose(drawing.drawing.layers, width: w, height: h, scale: scale)
        var best = 1.0
        for y in Int(box.minY * scale)..<min(h, Int(box.maxY * scale)) {
            for x in Int(box.minX * scale)..<min(w, Int(box.maxX * scale)) {
                let o = (y * w + x) * 4
                let a = Double(bytes[o + 3]) / 255
                func ch(_ shift: UInt32, _ premul: UInt8) -> UInt32 {
                    let under = Double((surface >> shift) & 0xFF)
                    return UInt32(max(0, min(255, (Double(premul) + under * (1 - a)).rounded())))
                }
                let px = ch(0, bytes[o]) | ch(8, bytes[o + 1]) << 8 | ch(16, bytes[o + 2]) << 16   // BGRA premultiplied
                best = max(best, PopoverSurface.contrast(px, surface))
            }
        }
        _ = enabled
        return best
    }

    func testThePagerArrowsAreVisibleOnEveryPageInEveryAppearance() async throws {
        let saved = (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast)
        defer { (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast) = saved }
        for (name, appearance, hc, surface) in Self.appearances {
            PopoverAppearanceState.appearance = appearance
            PopoverAppearanceState.highContrast = hc
            // 120 species = 8 pages: page 1 (previous disabled), a middle page (both), the last page (next disabled)
            for (page, prevOn, nextOn) in [(0, false, true), (3, true, true), (7, true, false)] {
                let prev = try peakContrast(page, count: 120, surface: surface, arrow: { $0.prev }, enabled: prevOn)
                let next = try peakContrast(page, count: 120, surface: surface, arrow: { $0.next }, enabled: nextOn)
                XCTAssertGreaterThanOrEqual(prev, prevOn ? 3 : 1.5, "\(name), page \(page + 1): the previous arrow is \(prev):1 on its surface")
                XCTAssertGreaterThanOrEqual(next, nextOn ? 3 : 1.5, "\(name), page \(page + 1): the next arrow is \(next):1 on its surface")
            }
        }
    }

    /// The other glyph and label pairs the drawn Dex parts paint, in the colours Windows draws (`displayValue(windows: true)`).
    func testTheDrawnDexInkReachesItsThresholdsInEveryAppearance() async throws {
        let saved = (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast)
        defer { (PopoverAppearanceState.appearance, PopoverAppearanceState.highContrast) = saved }
        func over(_ c: PlazaColor, _ base: UInt32) -> UInt32 {
            func ch(_ v: Double, _ shift: UInt32) -> UInt32 {
                UInt32(max(0, min(255, (v * c.alpha * 255 + Double((base >> shift) & 0xFF) * (1 - c.alpha)).rounded())))
            }
            return ch(c.red, 16) << 16 | ch(c.green, 8) << 8 | ch(c.blue, 0)
        }
        for (name, appearance, hc, page) in Self.appearances where hc == nil {   // the high-contrast pairs are the theme's own text on its window
            PopoverAppearanceState.appearance = appearance
            PopoverAppearanceState.highContrast = hc
            func windows(_ role: PopoverColorRole) -> PlazaColor {
                let v = role.displayValue(appearance, windows: true)
                return PlazaColor(srgbRed: v.red, green: v.green, blue: v.blue, alpha: v.alpha)
            }
            let card = over(PopoverAppearance.current.controlFill(alpha: 0.9), page)
            let accent = PopoverColorRole.accent.plazaColor()
            let tint = over(DexPainter.tint(accent, 0.22), page)
            let pairs: [(String, UInt32, UInt32, Double)] = [
                ("page text '1 / 8' (secondary on the window)", over(windows(.secondary), page), page, 4.5),
                ("cell number tag (secondary on the window)", over(windows(.secondary), page), page, 4.5),
                ("footer representative glyph (primary on its button)", over(PopoverColorRole.primary.plazaColor(), card), card, 3),
                ("selected chip check (primary on the chip tint)", over(PopoverColorRole.primary.plazaColor(), tint), tint, 3),
                ("complete chip count (accent on the window)", over(accent, page), page, 3),
                ("search glyph (tertiary on the window)", over(windows(.tertiary), page), page, 3),
            ]
            func rgb(_ c: PlazaColor) -> UInt32 { over(c, 0x000000) }
            var badges: [(String, UInt32, UInt32, Double)] = []
            var fills: [(String, PlazaColor)] = PopoverPokemonType.allCases.map { ("\($0) type badge", PopoverBadgeTint.type($0).color) }
            fills += [Rarity.common, .uncommon, .rare, .legendary].map { ("\($0) rarity badge", CompanionBadges.rarityColor($0).plazaColor()) }
            for (what, fill) in fills {
                badges.append(("solid \(what) text", rgb(DexPainter.ink(on: fill)), rgb(fill), 4.5))
            }
            // the tinted badge (RAISING): the accent on its 14 % tint over the window
            let faint = over(DexPainter.tint(accent, 0.14), page)
            badges.append(("tinted accent badge text", over(DexPainter.tintedInk(accent), faint), faint, 3))
            for (what, ink, surface, floor) in pairs + badges {
                let ratio = PopoverSurface.contrast(ink, surface)
                XCTAssertGreaterThanOrEqual(ratio, floor, "\(name): \(what) is \(ratio):1 (needs \(floor))")
            }
        }
    }
}
