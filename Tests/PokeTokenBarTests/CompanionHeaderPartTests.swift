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
        // The wiggle's poses: a pose drawn before is not drawn again (its backdrop and the bar's layer are kept).
        func images(_ d: PopoverDrawing) -> [PlazaImage] { d.drawing.layers.compactMap { if case .image(let i, _) = $0 { i } else { nil } } }
        var pose = CompanionArtEffects.rest
        pose.rotation = -5
        part.setEffects(pose)
        let a = images(part.renderEffectFrame(scale: 2, graphics: graphics))
        pose.rotation = 5
        part.setEffects(pose)
        let b = images(part.renderEffectFrame(scale: 2, graphics: graphics))
        pose.rotation = -5
        part.setEffects(pose)
        let c = images(part.renderEffectFrame(scale: 2, graphics: graphics))
        XCTAssertEqual(a.count, c.count)
        XCTAssertTrue(zip(a, c).allSatisfy { $0 === $1 }, "the same pose reuses every picture")
        XCTAssertFalse(a[0] === b[0], "another angle is another backdrop")
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

    /// A hover's look (stage 7 Task 9): the bar is its own layer, on whole device pixels; open it is 12 pt high with the
    /// readout in it and only its layer is dirty; the column's picture is kept.
    func testAHoverGrowsTheBarLayerWithTheReadoutAndOnlyItsLayerIsDirty() async throws {
        let graphics = PlatformPlaza.graphics
        let part = CompanionHeaderPart(hatchedModel())
        _ = part.size(width: 320, scale: 2, text: graphics.text)
        let bar = try XCTUnwrap(part.barFrame)
        func barLayer(_ d: PopoverDrawing) -> (image: PlazaImage, frame: CGRect)? {
            d.drawing.layers.compactMap { layer -> (PlazaImage, CGRect)? in
                guard case .image(let i, let f) = layer, f.height < 20, f.contains(CGPoint(x: bar.midX, y: bar.midY)) else { return nil }
                return (i, f)
            }.first
        }
        func column(_ d: PopoverDrawing) -> PlazaImage? {
            d.drawing.layers.compactMap { if case .image(let i, let f) = $0, f.origin == .zero { i } else { nil } }.first
        }
        func px(_ l: (image: PlazaImage, frame: CGRect), _ x: CGFloat, _ y: CGFloat) -> PlazaRGBA {
            l.image.pixels[Int(((x - l.frame.minX) * 2).rounded(.down)), Int(((y - l.frame.minY) * 2).rounded(.down))]
        }
        let rest = part.render(scale: 2, graphics: graphics)
        let thin = try XCTUnwrap(barLayer(rest))
        XCTAssertEqual(thin.frame, CompanionHeaderPart.barLayerFrame(bar, scale: 2))
        XCTAssertEqual(thin.frame.minY * 2, (thin.frame.minY * 2).rounded(), "on whole device pixels")
        near(px(thin, bar.minX + 200, bar.midY - 4.5), 0, 0, 0, 0, "thin at rest: nothing 4.5 pt above the middle")
        near(px(thin, bar.minX + 200, bar.midY), 0, 0, 0, 25, "the track at rest")

        part.setBarLook(GrowthBarHover.Look(expand: 1, label: 0))
        let grown = part.renderBarFrame(scale: 2, graphics: graphics)
        let big = try XCTUnwrap(barLayer(grown))
        XCTAssertEqual(grown.dirty, thin.frame)
        near(px(big, bar.minX + 200, bar.midY - 4.5), 0, 0, 0, 25, "12 pt high when grown")
        part.setBarLook(.open)
        let open = part.renderBarFrame(scale: 2, graphics: graphics)
        let shown = try XCTUnwrap(barLayer(open))
        var differing = 0
        for y in 0..<shown.image.pixels.height { for x in 0..<shown.image.pixels.width where shown.image.pixels[x, y] != big.image.pixels[x, y] { differing += 1 } }
        XCTAssertGreaterThan(differing, 50, "the readout is drawn in the grown bar")
        XCTAssertTrue(column(rest) === column(open), "the column's picture is kept across hover frames")
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

    /// A chevron press with animation (stage 7 Task 9): the Mac's `withAnimation(.easeInOut(duration: 0.25))`, sampled at
    /// up to 60 frames a second by the host's clock, landing on the page target.
    func testAChevronPressEasesOverAQuarterSecond() async {
        let graphics = PlatformPlaza.graphics
        let nodes = [EvoLineItem(.species(133), .current)] + [134, 135, 136, 196, 197, 470, 471, 700].map { EvoLineItem(.species($0), .future) }
        let part = EvoLinePart(line(nodes), background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        _ = part.size(width: 320, scale: 1, text: graphics.text)
        let t0 = Date(timeIntervalSince1970: 7_000)
        var now = t0
        part.now = { now }
        part.animatesMoves = true
        XCTAssertTrue(part.press(PlazaPanelHit(action: EvoLinePart.forwardAction, index: nil)))
        XCTAssertEqual(part.layout.scrollX, 0, "a press starts the move")
        XCTAssertEqual(part.nextDue(after: t0), t0.addingTimeInterval(1.0 / 60))
        now = t0.addingTimeInterval(0.125)
        XCTAssertTrue(part.advance(to: now))
        XCTAssertEqual(part.layout.scrollX, 76, accuracy: 0.5, "halfway in time is halfway on the symmetric ease")
        var frames = 0, t = now
        while let due = part.nextDue(after: t), frames < 100 {
            XCTAssertGreaterThan(due, t)
            t = due
            part.advance(to: t)
            frames += 1
        }
        XCTAssertEqual(part.layout.scrollX, 152, "lands on the end")
        XCTAssertNil(part.move)
        XCTAssertTrue((7...8).contains(frames), "the second half at 60 frames a second: \(frames)")
        // a wheel ends a move where it is
        now = t
        XCTAssertTrue(part.press(PlazaPanelHit(action: EvoLinePart.backAction, index: nil)))
        part.advance(to: t.addingTimeInterval(0.1))
        let mid = part.layout.scrollX
        XCTAssertTrue(part.scroll(by: -10))
        XCTAssertNil(part.move)
        XCTAssertEqual(part.layout.scrollX, mid - 10, accuracy: 1e-9)
    }

    /// The wheel and a touchpad (stage 7 Task 9): `WM_MOUSEHWHEEL` positive to the right moves forward, Shift + wheel away
    /// moves back, `chars` × 10 pt a notch in device pixels, a touchpad's small deltas add up; clamped; a line that fits
    /// does not take the wheel.
    func testTheWheelAndATouchpadMoveTheLine() async {
        var wheel = PopoverWheel()
        XCTAssertEqual(EvoLinePart.wheelMove(&wheel, delta: 120, horizontal: true, chars: 3, scale: 1, page: 320), 30)
        XCTAssertEqual(EvoLinePart.wheelMove(&wheel, delta: 120, horizontal: false, chars: 3, scale: 1, page: 320), -30)
        XCTAssertEqual(EvoLinePart.wheelMove(&wheel, delta: 120, horizontal: true, chars: 3, scale: 2, page: 320), 60)
        var sum: CGFloat = 0
        for _ in 0..<8 { sum += EvoLinePart.wheelMove(&wheel, delta: 15, horizontal: true, chars: 3, scale: 1, page: 320) }
        XCTAssertEqual(sum, 30)
        let graphics = PlatformPlaza.graphics
        let nodes = [EvoLineItem(.species(133), .current)] + [134, 135, 136, 196, 197, 470, 471, 700].map { EvoLineItem(.species($0), .future) }
        let part = EvoLinePart(line(nodes), background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        _ = part.size(width: 320, scale: 1, text: graphics.text)
        XCTAssertFalse(part.scroll(by: -30), "at the start: back does nothing")
        XCTAssertTrue(part.scroll(by: 30))
        XCTAssertEqual(part.layout.scrollX, 30)
        XCTAssertTrue(part.scroll(by: 1_000))
        XCTAssertEqual(part.layout.scrollX, 152)
        XCTAssertFalse(part.scroll(by: 1))
        let short = EvoLinePart(line([EvoLineItem(.species(1), .done), EvoLineItem(.species(2), .current)]), background: PlazaColor(srgbRed: 1, green: 1, blue: 1))
        _ = short.size(width: 320, scale: 1, text: graphics.text)
        XCTAssertFalse(short.scroll(by: 30))
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

/// The popover's sprite scaler (`PopoverSpriteScale`, both systems): bilinear when growing, every source pixel counted when
/// shrinking, BGRA out.
final class PopoverSpriteScaleTests: XCTestCase {
    private func row(_ values: [UInt8]) -> PlazaBitmap {
        var b = PlazaBitmap(width: values.count, height: 1)
        for (i, v) in values.enumerated() { b.bytes[i * 4] = v; b.bytes[i * 4 + 1] = v; b.bytes[i * 4 + 2] = v; b.bytes[i * 4 + 3] = 255 }
        return b
    }

    private func greys(_ bgra: [UInt8]) -> [UInt8] { stride(from: 0, to: bgra.count, by: 4).map { bgra[$0] } }

    func testGrowingIsBilinear() {
        // Centres at -0.25, 0.25, 0.75, 1.25 of a black and a white pixel.
        XCTAssertEqual(greys(PopoverSpriteScale.scaledBGRA(row([0, 255]), width: 4, height: 1)), [0, 64, 191, 255])
    }

    func testTheSameSizeKeepsThePixelsAndSwapsToBGRA() {
        var b = PlazaBitmap(width: 1, height: 1)
        b.bytes = [10, 20, 30, 40]
        XCTAssertEqual(PopoverSpriteScale.scaledBGRA(b, width: 1, height: 1), [30, 20, 10, 40])
        b.alpha = .noneSkipLast
        XCTAssertEqual(PopoverSpriteScale.scaledBGRA(b, width: 1, height: 1), [30, 20, 10, 255])
    }

    func testShrinkingCountsEverySourcePixel() {
        // 96 → 40 (an evolution thumbnail at 100 %): a lone white pixel anywhere still shows; two taps would skip some.
        for at in 0..<96 {
            var values = [UInt8](repeating: 0, count: 96)
            values[at] = 255
            XCTAssertGreaterThan(greys(PopoverSpriteScale.scaledBGRA(row(values), width: 40, height: 1)).max() ?? 0, 0, "pixel \(at)")
        }
    }

    func testTapsSumToOne() {
        for (n, m) in [(96, 152), (96, 76), (96, 40), (3, 1), (1, 5)] {
            for taps in PopoverSpriteScale.tent(source: n, target: m) {
                XCTAssertEqual(taps.reduce(0) { $0 + $1.1 }, 1, accuracy: 1e-9)
                XCTAssertTrue(taps.allSatisfy { $0.0 >= 0 && $0.0 < n })
            }
        }
    }
}

/// The Mac's `.easeInOut(duration:).repeatForever(autoreverses: true)` in whole steps (`PopoverEasedSwing`, both systems).
final class PopoverEasedSwingTests: XCTestCase {
    func testOneChangePerStepAtTheEasedCurvesStepMiddles() {
        let swing = PopoverEasedSwing(duration: 0.9, steps: 3)
        XCTAssertEqual(swing.changes.count, 6)
        XCTAssertEqual(swing.changes, swing.changes.sorted())
        XCTAssertEqual(swing.changes[1], 0.45, accuracy: 1e-9)   // the curve's middle
        for (k, c) in swing.changes.prefix(3).enumerated() {
            XCTAssertEqual(PopoverMotion.easeInOut(c / 0.9), (Double(k) + 0.5) / 3, accuracy: 1e-9)
        }
        XCTAssertEqual(swing.level(at: 0), 0)
        XCTAssertEqual(swing.level(at: 0.9), 3)
        XCTAssertEqual(swing.level(at: 1.8), 0)
        XCTAssertEqual(swing.level(at: 2.7), 3)
    }

    /// From any moment — a change's own instant, a hair before or after it — the next change is later and the level moves by
    /// one there: a clock armed with it always moves on.
    func testTheNextChangeIsAlwaysLaterAndOneStepAway() {
        for steps in [1, 2, 3, 6] {
            let swing = PopoverEasedSwing(duration: 0.35, steps: steps)
            var moments: [Double] = []
            for cycle in 0..<3 { for c in swing.changes { let t = Double(cycle) * 0.7 + c; moments += [t, t - 1e-7, t + 1e-7] } }
            for t in moments {
                let next = swing.nextChange(after: t)
                XCTAssertGreaterThan(next, t)
                XCTAssertEqual(abs(swing.level(at: next) - swing.level(at: next - 1e-3)), 1, "steps \(steps) at \(t)")
            }
        }
    }
}

/// The growth bar's hover timeline (`GrowthBarHover`, both systems): the Mac's `LabeledProgressBar.onHover`.
final class GrowthBarHoverTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testItWaitsThreeHundredMillisecondsThenSpringsOpenAndTheReadoutFadesIn() {
        var h = GrowthBarHover()
        h.setHovering(true, at: t0)
        XCTAssertEqual(h.look(at: at(0.29)), .rest)
        XCTAssertEqual(h.nextDue(after: t0), at(0.3))
        let peak = stride(from: 0.3, to: 0.9, by: 0.005).map { h.look(at: at($0)).expand }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.05, "the spring's overshoot (damping 0.55)")
        XCTAssertLessThan(peak, 1.2)
        XCTAssertEqual(h.look(at: at(0.3 + 0.11)).label, 0, "the readout waits 0.12 s")
        XCTAssertEqual(h.look(at: at(0.3 + 0.24)).label, 1)
        XCTAssertEqual(h.look(at: at(1)), .open)
        XCTAssertNil(h.nextDue(after: at(1)))
        var frames = 0, t = t0
        while let due = h.nextDue(after: t), frames < 100 {
            XCTAssertGreaterThan(due, t)
            t = due
            frames += 1
        }
        XCTAssertTrue((28...31).contains(frames), "the wait, then 60 a second until the spring settles (0.48 s): \(frames)")
    }

    func testLeavingShrinksItAtOnce() {
        var h = GrowthBarHover()
        h.setHovering(true, at: t0)
        h.setHovering(false, at: at(2))
        XCTAssertEqual(h.look(at: at(2)).expand, 1, accuracy: 1e-3)
        XCTAssertEqual(h.look(at: at(2.06)).label, 0, "the readout goes in 0.06 s")
        XCTAssertGreaterThan(h.look(at: at(2.1)).expand, 0)
        XCTAssertEqual(h.look(at: at(2.18)), .rest)
        XCTAssertNil(h.nextDue(after: at(2.2)))
        XCTAssertFalse(h.isHovered)
    }

    func testLeavingWithinTheWaitChangesNothing() {
        var h = GrowthBarHover()
        h.setHovering(true, at: t0)
        h.setHovering(false, at: at(0.2))
        XCTAssertEqual(h.look(at: at(0.5)), .rest)
        XCTAssertNil(h.nextDue(after: at(0.2)))
    }

    /// Windows' "show animations" off: the same wait, then the bar jumps open and back.
    func testWithoutAnimationItJumps() {
        var h = GrowthBarHover(animates: false)
        h.setHovering(true, at: t0)
        XCTAssertEqual(h.nextDue(after: t0), at(0.3))
        XCTAssertEqual(h.look(at: at(0.3)), .open)
        XCTAssertNil(h.nextDue(after: at(0.3)))
        h.setHovering(false, at: at(1))
        XCTAssertEqual(h.look(at: at(1)), .rest)
        XCTAssertNil(h.nextDue(after: at(1)))
    }
}
