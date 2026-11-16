import XCTest
@testable import PokeTokenBar

/// The companion header's drawn parts through the plaza canvas of the system under test (CoreGraphics on the Mac, Direct2D
/// on Windows): layout, slots, effects, the growth bar's pixels and the evolution line's scrolling.
@MainActor
final class CompanionHeaderPartTests: XCTestCase {
    private func near(_ p: PlazaRGBA, _ r: Int, _ g: Int, _ b: Int, _ a: Int, _ what: String, tolerance: Int = 3,
                      file: StaticString = #filePath, line: UInt = #line) {
        let got = [Int(p.r), Int(p.g), Int(p.b), Int(p.a)], want = [r, g, b, a]
        for i in 0..<4 { XCTAssertLessThanOrEqual(abs(got[i] - want[i]), tolerance, "\(what): \(got) vs \(want)", file: file, line: line) }
    }

    private func eggModel(progress: Double = 0.4) -> CompanionHeaderModel {
        var input = CompanionHeaderInput()
        input.language = .en
        input.eggHatchThreshold = 50_000
        input.eggUsage = Int(progress * 50_000)
        input.eggProgress = progress
        input.eggTokensToHatch = 50_000 - input.eggUsage
        input.eggStarted = input.eggUsage > 0
        return CompanionHeaderModel.make(input: input)
    }

    private func hatchedModel() -> CompanionHeaderModel {
        var input = CompanionHeaderInput()
        input.language = .en
        input.hasActive = true
        input.isEgg = false
        input.currentSpeciesID = 2
        input.displayName = "Ivysaur"
        input.rarity = .common
        input.types = ["grass", "poison"]
        input.stageText = "Stage 2 / 3"
        input.currentNature = .modest
        input.progress = 0.5
        input.usedAtStage = 25_000
        input.threshold = 50_000
        input.tokensToNext = 25_000
        input.displayState = .working
        input.lineNodes = [EvoLineItem(.species(1), .done), EvoLineItem(.species(2), .current), EvoLineItem(.species(3), .future)]
        return CompanionHeaderModel.make(input: input)
    }

    func testTheBlockIsTheSpriteBoxAndTheColumnCentredOnIt() async {
        let graphics = PlatformPlaza.graphics
        for model in [eggModel(), hatchedModel()] {
            let part = CompanionHeaderPart(model)
            let size = part.size(width: 320, scale: 1, text: graphics.text)
            let lay = part.layout(width: 320, text: graphics.text)
            XCTAssertEqual(size.width, 320)
            XCTAssertGreaterThanOrEqual(size.height, 76)
            XCTAssertEqual(lay.box.width, 76)
            XCTAssertEqual(lay.box.minX, 0)
            XCTAssertEqual(lay.column.minX, 88, "12 pt beside the 76 pt box")
            XCTAssertEqual(lay.box.midY, size.height / 2, accuracy: 0.5, "the box is centred in the block")
            XCTAssertEqual(lay.column.midY, size.height / 2, accuracy: 0.5, "and the column on it")
            XCTAssertEqual(lay.bars.count, 1)
            XCTAssertEqual(lay.bars.first?.frame.width, 320 - 88)
            XCTAssertEqual(lay.bars.first?.frame.height, 12)
            let drawing = part.render(scale: 1, graphics: graphics)
            XCTAssertEqual(drawing.spriteSlots.count, 1)
            XCTAssertEqual(drawing.spriteSlots.first?.frame, lay.box)
            XCTAssertEqual(drawing.spriteSlots.first?.bob, true)
            XCTAssertEqual(drawing.spriteSlots.first?.animated, true)
            XCTAssertEqual(drawing.drawing.accessibility.first?.label, model.spriteLabel)
            guard case .bar(_, let detail)? = model.lines.first(where: { if case .bar = $0 { true } else { false } }) else { return XCTFail("no bar") }
            XCTAssertEqual(drawing.drawing.tooltips.map(\.text), [detail], "the bar's detail is its tooltip")
            XCTAssertEqual(drawing.drawing.accessibility.filter { $0.label == detail }.count, 1, "and its accessible text, once")
            XCTAssertTrue(drawing.overlays.isEmpty, "no celebration, nothing over the sprite")
        }
    }

    func testWindowsTextSizeGrowsTheTextNotTheBox() async {
        let graphics = PlatformPlaza.graphics
        let small = CompanionHeaderPart(hatchedModel()).layout(width: 320, text: graphics.text)
        let large = CompanionHeaderPart(hatchedModel(), textScale: 1.5).layout(width: 320, text: graphics.text)
        XCTAssertEqual(large.box.width, 76)
        XCTAssertGreaterThan(large.column.height, small.column.height * 1.25)
    }

    func testAnEffectFrameScalesAndTurnsTheSlotAndOnlyItsBoxIsDirty() async {
        let graphics = PlatformPlaza.graphics
        let part = CompanionHeaderPart(eggModel(progress: 0.95))
        _ = part.size(width: 320, scale: 2, text: graphics.text)
        let first = part.render(scale: 2, graphics: graphics)
        var e = CompanionArtEffects.rest
        e.scale = 0.6
        e.flash = 0.85
        e.rotation = 5
        part.setEffects(e)
        let frame = part.renderEffectFrame(scale: 2, graphics: graphics)
        let box = part.layout(width: 320, text: graphics.text).box
        let slot = frame.spriteSlots[0]
        XCTAssertEqual(slot.frame.width, 76 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(slot.frame.midX, box.midX, accuracy: 1e-9)
        XCTAssertEqual(slot.frame.midY, box.midY, accuracy: 1e-9)
        XCTAssertEqual(slot.rotation, 5)
        XCTAssertFalse(frame.overlays.isEmpty, "the flash is drawn over the sprite")
        XCTAssertEqual(frame.dirty, box.insetBy(dx: -26, dy: -26).intersection(CGRect(origin: .zero, size: part.size(width: 320, scale: 2, text: graphics.text))))
        // The column's picture is the same image across effect frames (only the box is drawn again).
        func columnImage(_ d: PopoverDrawing) -> PlazaImage? {
            d.drawing.layers.compactMap { if case .image(let i, let f) = $0, f.origin == .zero { i } else { nil } }.first
        }
        XCTAssertTrue(columnImage(first) === columnImage(frame))
    }

    func testTheGrowthBarsPixelsAtScaleOneAndTwo() async throws {
        for scale in [CGFloat(1), 2] {
            let part = GrowthBarPart(.init(value: 0.5, detail: "25K / 50K · 50%"))
            let graphics = PlatformPlaza.graphics
            XCTAssertEqual(part.size(width: 200, scale: scale, text: graphics.text), CGSize(width: 200, height: 12))
            let drawing = part.render(scale: scale, graphics: graphics)
            guard case .image(let image, _)? = drawing.drawing.layers.first else { return XCTFail("no layer") }
            let bits = image.pixels
            func px(_ x: CGFloat, _ y: CGFloat) -> PlazaRGBA { bits[Int(x * scale), Int(y * scale)] }
            near(px(40, 6), 0xFF, 0x8D, 0x28, 255, "the orange fill at scale \(scale)")
            near(px(150, 6), 0, 0, 0, 25, "the track (secondary at 20 %) at scale \(scale)")
            near(px(150, 1), 0, 0, 0, 0, "above the 6 pt track at scale \(scale)")
            XCTAssertEqual(drawing.drawing.tooltips.first?.text, "25K / 50K · 50%")
        }
        XCTAssertEqual(GrowthBarPart.fillWidth(value: 1.7, width: 100), 100, "clamped like the Mac's min(1, max(0, value))")
        XCTAssertEqual(GrowthBarPart.fillWidth(value: -1, width: 100), 0)
    }

    // MARK: the evolution line

    private func line(_ nodes: [EvoLineItem]) -> EvoLineModel {
        EvoLineModel(nodes: nodes, shiny: false, form: nil, mysteryLabel: "Unknown next evolution", previousLabel: "Show previous evolutions",
                     nextLabel: "Show next evolutions")
    }

    func testAThreeStageLineDoesNotScroll() async {
        let graphics = PlatformPlaza.graphics
        let part = EvoLinePart(line([EvoLineItem(.species(1), .done), EvoLineItem(.species(2), .current), EvoLineItem(.mystery, .future)]),
                               background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        XCTAssertEqual(part.size(width: 320, scale: 1, text: graphics.text), CGSize(width: 148, height: 42), "40×3 + 10×2 + 2×4, the Mac's 148 pt")
        let d = part.render(scale: 1, graphics: graphics)
        XCTAssertEqual(d.spriteSlots.map(\.frame.minX), [0, 54], "a column every 54 pt; the ? is drawn, not a sprite")
        XCTAssertEqual(d.spriteSlots.map(\.opacity), [1, 1])
        XCTAssertEqual(d.spriteSlots.map(\.animated), [false, false], "the Mac's line shows still sprites")
        XCTAssertTrue(d.overlays.isEmpty, "no fade, no chevron")
        XCTAssertEqual(d.drawing.accessibility.map(\.label), ["Unknown next evolution"])
        XCTAssertNil(part.hit(CGPoint(x: 140, y: 20)))
    }

    func testFutureNodesAreDimmedAndDesaturated() async {
        let graphics = PlatformPlaza.graphics
        let part = EvoLinePart(line([EvoLineItem(.species(1), .current), EvoLineItem(.species(2), .future)]), background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        _ = part.size(width: 320, scale: 1, text: graphics.text)
        let slots = part.render(scale: 1, graphics: graphics).spriteSlots
        XCTAssertEqual(slots.map(\.opacity), [1, 0.32])
        XCTAssertEqual(slots.map(\.saturation), [1, 0.4])
    }

    /// The Mac's nine-node corpus (`EvoLineLayoutTests.longNodes`, synthetic: the store's line hides branches behind one "?",
    /// so a real Home line has at most four nodes): 472 pt in 320 scrolls; the forward chevron and the trailing fade show; a
    /// press moves one screen and lands at the end; then only the back chevron shows; a press back returns to the start.
    func testANineNodeLineScrollsWithChevronsAndFades() async {
        let graphics = PlatformPlaza.graphics
        let nodes = [EvoLineItem(.species(133), .current)] + [134, 135, 136, 196, 197, 470, 471, 700].map { EvoLineItem(.species($0), .future) }
        let part = EvoLinePart(line(nodes), background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        XCTAssertEqual(part.size(width: 320, scale: 1, text: graphics.text), CGSize(width: 320, height: 42))
        var d = part.render(scale: 1, graphics: graphics)
        XCTAssertEqual(d.drawing.accessibility.filter { $0.role == .button }.map(\.label), ["Show next evolutions"])
        XCTAssertEqual(d.overlays.count, 2, "the fade and one chevron")
        XCTAssertEqual(part.hit(CGPoint(x: part.forwardChevron.midX, y: part.forwardChevron.midY))?.action, EvoLinePart.forwardAction)
        XCTAssertNil(part.hit(CGPoint(x: part.backChevron.midX, y: part.backChevron.midY)), "nothing to the left yet")
        XCTAssertTrue(part.press(PlazaPanelHit(action: EvoLinePart.forwardAction, index: nil)))
        XCTAssertEqual(part.layout.scrollX, 472 - 320, "page target 6 → 324, clamped to the end")
        d = part.render(scale: 1, graphics: graphics)
        XCTAssertEqual(d.spriteSlots.first?.frame.minX, -152)
        XCTAssertEqual(d.drawing.accessibility.filter { $0.role == .button }.map(\.label), ["Show previous evolutions"])
        XCTAssertFalse(part.press(PlazaPanelHit(action: EvoLinePart.forwardAction, index: nil)), "at the end: forward does nothing")
        XCTAssertTrue(part.press(PlazaPanelHit(action: EvoLinePart.backAction, index: nil)))
        XCTAssertEqual(part.layout.scrollX, 0)
    }

    /// The Mac's `EvoLineLayoutTests` pure corpus on the twin (on both systems; the Mac's own statics are compared in
    /// `PopoverTwinEquivalenceTests+Mac`).
    func testTheMacsLayoutCorpusOnTheTwin() async {
        let w = PopoverWindowMetrics.contentWidth
        XCTAssertEqual(EvoLineLayout.rowWidth(count: 3, thumb: 40, hasNames: false), 148)
        XCTAssertFalse(EvoLineLayout.needsScroll(count: 6, thumb: 40, hasNames: false, maxWidth: w))
        XCTAssertTrue(EvoLineLayout.needsScroll(count: 7, thumb: 40, hasNames: false, maxWidth: w))
        XCTAssertFalse(EvoLineLayout.needsScroll(count: 4, thumb: 56, hasNames: true, maxWidth: w - 16))
        XCTAssertTrue(EvoLineLayout.needsScroll(count: 5, thumb: 56, hasNames: true, maxWidth: w - 16))
        XCTAssertFalse(EvoLineLayout.needsScroll(count: 99, thumb: 40, hasNames: false, maxWidth: .infinity))
        let content = EvoLineLayout.rowWidth(count: 9, thumb: 40, hasNames: false)
        var a = EvoLineLayout.scrollAffordance(scrollX: 0, contentWidth: content, maxWidth: w)
        XCTAssertFalse(a.back); XCTAssertTrue(a.forward)
        a = EvoLineLayout.scrollAffordance(scrollX: 70, contentWidth: content, maxWidth: w)
        XCTAssertTrue(a.back); XCTAssertTrue(a.forward)
        a = EvoLineLayout.scrollAffordance(scrollX: content - w, contentWidth: content, maxWidth: w)
        XCTAssertTrue(a.back); XCTAssertFalse(a.forward)
        func target(_ forward: Bool, at x: CGFloat) -> Int {
            EvoLineLayout.pageTarget(forward: forward, scrollX: x, count: 9, thumb: 40, hasNames: false, maxWidth: w)
        }
        XCTAssertEqual(target(true, at: 0), 6)
        XCTAssertGreaterThan(target(true, at: 54), target(true, at: 0))
        XCTAssertEqual(target(true, at: 300), 8)
        XCTAssertEqual(target(false, at: 0), 0)
        XCTAssertEqual(target(false, at: 140), 0)
        XCTAssertEqual(EvoLineLayout.dexLinkTarget(for: EvoLineItem(.species(2), .current), links: [1: "1", 2: "2"]), "2")
        XCTAssertNil(EvoLineLayout.dexLinkTarget(for: EvoLineItem(.mystery, .future), links: [1: "1"]))
    }
}
