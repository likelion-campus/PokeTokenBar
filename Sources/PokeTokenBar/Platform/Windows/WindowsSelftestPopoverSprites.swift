#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 8: sprites and animation in the popover (`companion.*`). A drawn part with two sprite slots on the kit
// window: the bundled ice-shatter GIF (5 frames, 0.1 s each; FIXTURE: any species up to 100 gets it) and a species with
// nothing to load (the egg glyph). Windows of the selftest only.

private struct GifFixtureFetcher: PlazaSpriteFetching {
    let frames: [(image: PlazaImage, delay: TimeInterval)]
    /// Fresh picture objects per ask, so the caches' bounds are what keeps memory flat, not object reuse.
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        speciesID <= 100 ? frames.map { (PlazaImage(bitmap: $0.image.pixels), $0.delay) } : []
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// A FIXTURE part: a tinted card with two sprite slots, 80 DIP boxes.
@MainActor final class SpriteFixturePart: PopoverPart {
    var onChange: (() -> Void)?
    private(set) var species = 1
    static let slotA = CGRect(x: 10, y: 10, width: 80, height: 80)
    static let slotB = CGRect(x: 110, y: 10, width: 80, height: 80)

    func setSpecies(_ id: Int) {
        guard id != species else { return }
        species = id
        onChange?()
    }

    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize { CGSize(width: width, height: 100) }

    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing {
        let drawing = PlazaPanelDrawing(layers: [.color(PlazaColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1), frame: CGRect(x: 0, y: 0, width: 280, height: 100))],
                                        accessibility: [], tooltips: [])
        return PopoverDrawing(drawing: drawing, spriteSlots: [
            SpriteSlot(frame: Self.slotA, subject: PlazaSpriteSubjectKey(speciesID: species), bob: false, animated: true),
            SpriteSlot(frame: Self.slotB, subject: PlazaSpriteSubjectKey(speciesID: 500), bob: false, animated: true),
        ])
    }

    func hit(_ point: CGPoint) -> PlazaPanelHit? { nil }
}

@MainActor final class SpritePage {
    var view: WinDrawnView?
    var part: SpriteFixturePart?
    var animator: WinSpriteAnimator?
    let fetcher: any PlazaSpriteFetching
    init(fetcher: any PlazaSpriteFetching) { self.fetcher = fetcher }

    func build(_ s: WinStack) {
        let section = s.addSection("Sprite")
        section.addRow(nil, style: .full) { [weak self] pane, ctx in
            guard let self, let view = try? WinDrawnView(parent: pane, ctx: ctx) else { return nil }
            let part = SpriteFixturePart()
            view.sprites = WinSpriteAnimator(fetcher: self.fetcher, animationsEnabled: { true })  // the runner's "show animations" setting is off
            view.host(part, width: 280)
            self.view = view
            self.part = part
            self.animator = view.sprites
            return view.control
        }
        let filler = s.addSection("Below the sprite")
        for i in 1...14 {
            filler.addRow("Filler row \(i)") { pane, ctx in WinControls.label("scroll the sprite out of view", style: .caption, role: .secondary, wraps: false, in: pane, ctx: ctx) }
        }
    }
}

extension WindowsSelftestPopover {
    static func fixtureGIF() -> (any PlazaSpriteFetching, Int, [TimeInterval])? {
        guard let url = PlatformPlaza.graphics.assetURL(PlazaDecodeGoldens.iceGIFName, ext: "gif"), let data = try? Data(contentsOf: url) else { return nil }
        let frames = PlazaStoreGIF.frames(from: data)
        guard frames.count > 1 else { return nil }
        return (GifFixtureFetcher(frames: frames), frames.count, frames.map(\.delay))
    }

    /// `--popover-sprite-idle-probe`: the idle gate's open, animating window.
    static func startSpriteIdle() {
        Task { @MainActor in
            _ = await WindowsSelftest.waitUntil(timeout: 5) { false }
            guard let (fetcher, _, _) = fixtureGIF() else { AppLog.write("popover sprite idle probe: no fixture GIF"); return }
            let page = SpritePage(fetcher: fetcher)
            guard let w = KitWindow(heightDIP: 220, build: { _, s in page.build(s) }) else {
                AppLog.write("popover sprite idle probe: no window (\(GetLastError()))")
                return
            }
            spriteIdleWindow = w
            w.show(activate: WindowsSelftest.onCI)
            _ = await WindowsSelftest.waitUntil(timeout: 5) { page.animator?.playback.models.first?.isAnimating == true }
            // `gif rate`: frames a second from the GIF's own delays, the idle gate's measure of the clock (Test-AnimatedWork).
            let frames = page.animator?.playback.models.first?.frames ?? []
            let length = frames.reduce(0) { $0 + $1.delay }
            AppLog.write("popover sprite idle probe: open dpi=\(w.ctx.dpi) animating=\(page.animator?.playback.models.first?.isAnimating == true) armed=\(page.animator?.playback.clock.isArmed == true) "
                         + String(format: "gif rate=%.3f/s", length > 0 ? Double(frames.count) / length : 0))
        }
    }

    private static var spriteIdleWindow: KitWindow?

    struct FrameDiff { var count: Int; var w: Int; var h: Int }

    private static func frameDiff(_ a: WinUIDump.Bitmap, _ b: WinUIDump.Bitmap) -> FrameDiff {
        guard a.width == b.width, a.height == b.height else { return FrameDiff(count: -1, w: 0, h: 0) }
        var count = 0, minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        // The page's native scroll bar is not the sprite's: in dark its style collapses with Windows' own animation between the two
        // captures, so its column (up to 24 px at 100 %) is left out.
        for y in 0..<a.height {
            for x in 0..<max(0, a.width - 24) {
                let o = (y * a.width + x) * 4
                if a.bgra[o] != b.bgra[o] || a.bgra[o + 1] != b.bgra[o + 1] || a.bgra[o + 2] != b.bgra[o + 2] {
                    count += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return FrameDiff(count: count, w: count == 0 ? 0 : maxX - minX + 1, h: count == 0 ? 0 : maxY - minY + 1)
    }

    static func spriteChecks(_ r: WindowsSelftest.Recorder) async {
        guard let (fetcher, frameCount, delays) = fixtureGIF() else {
            for n in ["companion.spriteFrames", "companion.clockStops", "companion.spriteMemory"] { r.add(n, false, "the bundled ice-shatter GIF did not load") }
            return
        }
        let dumpDir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("kit", isDirectory: true)
        if let dumpDir { try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true) }
        let loop = delays.reduce(0, +)

        let page = SpritePage(fetcher: fetcher)
        guard let w = KitWindow(heightDIP: 220, build: { _, s in page.build(s) }) else {
            for n in ["companion.spriteFrames", "companion.clockStops", "companion.spriteMemory"] { r.add(n, false, "no window: \(GetLastError())") }
            return
        }
        defer { if !w.isDestroyed { w.destroy() } }
        w.show(activate: false)
        guard let animator = page.animator, let view = page.view else {
            r.add("companion.spriteFrames", false, "no animator or drawn view")
            return
        }
        _ = await WindowsSelftest.waitUntil(timeout: 5) { animator.playback.models.first?.isAnimating == true && animator.playback.clock.isArmed }
        let scale = w.ctx.scale

        // --- companion.spriteFrames: 3 s of the GIF; ticks equal the frames shown; each paint is the slot's rectangle.
        let shotA = capture(w), indexA = animator.playback.models.first?.frameIndex ?? -1
        if let dumpDir, let shotA { _ = WinUIDump.write(shotA, to: dumpDir.appendingPathComponent("sprite-100-a.png")) }
        let ticks0 = animator.playback.ticks, inv0 = animator.stats.invalidations, invPx0 = animator.stats.invalidatedPixels
        let paints0 = view.stats.paints, px0 = view.stats.paintPixels
        let seconds = 3.0
        _ = await WindowsSelftest.waitUntil(timeout: seconds) { false }
        let ticks = animator.playback.ticks - ticks0, inv = animator.stats.invalidations - inv0
        let paints = view.stats.paints - paints0, paintPx = view.stats.paintPixels - px0
        let expected = Int((seconds / loop * Double(frameCount)).rounded())
        _ = await WindowsSelftest.waitUntil(timeout: 1) { animator.playback.models.first?.frameIndex != indexA }
        let shotB = capture(w), indexB = animator.playback.models.first?.frameIndex ?? -1
        if let dumpDir, let shotB { _ = WinUIDump.write(shotB, to: dumpDir.appendingPathComponent("sprite-100-b.png")) }
        let slotPx = Int((80 * scale).rounded()) * Int(((80 + 3) * scale).rounded())
        let wholePx = Int(view.pixelSize.cx) * Int(view.pixelSize.cy)
        let avgPaint = paints > 0 ? paintPx / paints : -1
        let diff = shotA.flatMap { a in shotB.map { frameDiff(a, $0) } } ?? FrameDiff(count: -1, w: 0, h: 0)
        let boxOK = diff.w <= Int((80 * scale).rounded()) + 2 && diff.h <= Int((80 * scale).rounded()) + 2
        let glyphs = animator.stats.glyphs
        let framesOK = abs(ticks - expected) <= max(2, expected / 10) && abs(inv - ticks) <= 2 && abs(paints - ticks) <= max(2, ticks / 10)
        let areaOK = avgPaint > 0 && avgPaint <= slotPx && avgPaint * 3 < wholePx
        // Negative control: the same measure over whole-window invalidations must fail the area check (the check has teeth).
        let n0 = view.stats.paints, npx0 = view.stats.paintPixels
        for _ in 0..<5 {
            _ = InvalidateRect(view.hwnd, nil, false)
            _ = UpdateWindow(view.hwnd)
        }
        let negAvg = (view.stats.paintPixels - npx0) / max(1, view.stats.paints - n0)
        let negFails = !(negAvg <= slotPx && negAvg * 3 < wholePx)
        r.add("companion.spriteFrames", framesOK && areaOK && diff.count > 0 && boxOK && glyphs > 0 && negFails && animator.stats.drawn > 0,
              "Windows show-animations setting on this machine=\(WinSpriteAnimator.systemAnimationsEnabled()) (the fixture overrides it); GIF \(frameCount) frames, \(loop) s per loop, fixture; \(Int(seconds)) s at scale \(scale): clock ticks=\(ticks) (expected \(expected) +-\(max(2, expected / 10))), slot invalidations=\(inv), paints=\(paints); "
              + "paint area per paint=\(avgPaint) px (slot rect \(slotPx) px, whole picture \(wholePx) px); frames drawn=\(animator.stats.drawn), scaled once each=\(animator.stats.scales), egg glyph paints=\(glyphs); "
              + "capture A frame \(indexA) / B frame \(indexB): \(diff.count) px differ, in a box \(diff.w)x\(diff.h) px (slot \(Int((80 * scale).rounded())) px); "
              + "negative control (whole-window invalidation) average=\(negAvg) px -> area check fails=\(negFails)")

        // --- companion.clockStops: scrolled out, hidden (another page), animation off, closed -> no ticks, no timer.
        var steps: [String] = []
        var stopsOK = animator.playback.clock.isArmed
        steps.append("shown: armed=\(animator.playback.clock.isArmed)")
        w.scroll?.scroll(to: 100_000)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { !animator.playback.clock.isArmed }
        let scrolledOut = !animator.playback.clock.isArmed
        let t1 = animator.playback.ticks
        _ = await WindowsSelftest.waitUntil(timeout: 3) { false }
        let scrolledTicks = animator.playback.ticks - t1
        stopsOK = stopsOK && scrolledOut && scrolledTicks == 0
        steps.append("scrolled out: timer gone=\(scrolledOut), ticks in 3 s=\(scrolledTicks)")
        w.scroll?.scroll(to: 0)
        _ = await WindowsSelftest.waitUntil(timeout: 2) { animator.playback.clock.isArmed }
        let backIn = animator.playback.clock.isArmed
        stopsOK = stopsOK && backIn
        steps.append("scrolled back: armed again=\(backIn)")
        _ = ShowWindow(view.hwnd, 0 /* SW_HIDE: the Settings page replaces this one */)
        let hiddenGone = !animator.playback.clock.isArmed
        let t2 = animator.playback.ticks
        _ = await WindowsSelftest.waitUntil(timeout: 3) { false }
        let hiddenTicks = animator.playback.ticks - t2
        stopsOK = stopsOK && hiddenGone && hiddenTicks == 0
        steps.append("hidden (page switch): timer gone at once=\(hiddenGone), ticks in 3 s=\(hiddenTicks)")
        _ = ShowWindow(view.hwnd, 8 /* SW_SHOWNA */)
        _ = RedrawWindow(view.hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0100))
        _ = await WindowsSelftest.waitUntil(timeout: 2) { animator.playback.clock.isArmed }
        let shownAgain = animator.playback.clock.isArmed
        stopsOK = stopsOK && shownAgain
        steps.append("shown again: armed=\(shownAgain)")
        animator.playback.animationsEnabled = false
        let offGone = !animator.playback.clock.isArmed
        animator.playback.animationsEnabled = true
        stopsOK = stopsOK && offGone
        steps.append("animation off: timer gone=\(offGone)")
        _ = await WindowsSelftest.waitUntil(timeout: 1) { animator.playback.clock.isArmed }
        let before = KitResources.now()
        w.destroy()
        _ = await WindowsSelftest.waitUntil(timeout: 0.3) { false }
        let closedOK = animator.isDestroyed && animator.playback.released && !animator.playback.clock.isArmed
            && animator.playback.memory.frameSetCount == 0 && animator.playback.models.isEmpty
        let t3 = animator.playback.ticks
        _ = await WindowsSelftest.waitUntil(timeout: 1.5) { false }
        let closedTicks = animator.playback.ticks - t3
        stopsOK = stopsOK && closedOK && closedTicks == 0
        steps.append("closed: animator destroyed=\(animator.isDestroyed), timer armed=\(animator.playback.clock.isArmed), frames cached=\(animator.playback.memory.frameSetCount), ticks in 1.5 s=\(closedTicks), controls \(before.controls) -> \(KitResources.now().controls)")
        r.add("companion.clockStops", stopsOK, steps.joined(separator: "; "))

        await spriteMemoryCheck(r, fetcher: fetcher, dumpDir: dumpDir)
    }

    private static func spriteMemoryCheck(_ r: WindowsSelftest.Recorder, fetcher: any PlazaSpriteFetching, dumpDir: URL?) async {
        let page = SpritePage(fetcher: fetcher)
        guard let w = KitWindow(heightDIP: 220, build: { _, s in page.build(s) }) else {
            r.add("companion.spriteMemory", false, "no window")
            return
        }
        defer { if !w.isDestroyed { w.destroy() } }
        w.show(activate: false)
        guard let animator = page.animator, let part = page.part else { r.add("companion.spriteMemory", false, "no animator"); return }
        func change(_ id: Int) async {
            part.setSpecies(id)
            _ = await WindowsSelftest.waitUntil(timeout: 3) { animator.playback.models.first?.taskID?.hasPrefix("\(id)-") == true && animator.playback.models.first?.isAnimating == true }
        }
        for id in 1...10 { await change(id) }  // warm-up: caches filled, the fetcher's decoder warm
        let base = ptb_gfx_process_private_bytes(), baseRes = KitResources.now()
        for id in 11...60 { await change(id) }
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
        let after = ptb_gfx_process_private_bytes(), afterRes = KitResources.now()
        let sets = animator.playback.memory.frameSetCount
        let growth = Double(Int64(after) - Int64(base)) / 1_048_576
        let ok = growth < 3 && sets <= PopoverSpriteMemory.frameSets && afterRes.gdi - baseRes.gdi <= 5
        // Frames that finish after a subject changed again must not paint: two quick changes, only the last is shown.
        part.setSpecies(70); part.setSpecies(71)
        _ = await WindowsSelftest.waitUntil(timeout: 3) { animator.playback.models.first?.isAnimating == true && animator.playback.models.first?.taskID?.hasPrefix("71-") == true }
        let lastWins = animator.playback.models.first?.taskID?.hasPrefix("71-") == true
        r.add("companion.spriteMemory", ok && lastWins,
              "50 subject changes after a 10-change warm-up: private bytes \(base) -> \(after) (\(String(format: "%.2f", growth)) MB, budget 3), GDI \(baseRes.gdi) -> \(afterRes.gdi), "
              + "handles \(baseRes.handles) -> \(afterRes.handles), cached frame sets=\(sets) (bound \(PopoverSpriteMemory.frameSets)), scaled frames memoised=\(animator.stats.scales); "
              + "two quick changes: the last one is shown=\(lastWins)")
    }
}
#endif
