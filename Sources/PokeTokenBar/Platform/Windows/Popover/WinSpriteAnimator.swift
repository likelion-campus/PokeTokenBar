#if os(Windows)
import Foundation
import WinSDK

/// Sprites in a drawn part (stage 7 D16): the slots a part leaves are filled with the companion's pictures. One
/// `PopoverSpritePlayback` per view (the shared state machine, tests on both systems) does the loading through the sprite
/// fetcher (off the main thread), the frame times and the clock; this class paints. Frames are scaled smoothly (as the Mac shows them: `PopoverSpriteScale`), once, to
/// the size they take in the slot at the view's DPI (the work is memoised per frame for the current subject); a tick
/// invalidates only the changed slot's rectangle and `WM_PAINT` blends the scaled frame over the picture (`paintOverlay`).
/// A still sprite may bob (3 DIP, one step per device pixel of the Mac's eased swing); a missing picture is the 🥚 glyph in
/// Segoe UI Emoji.
///
/// Timers: none of its own. The shared clock holds one one-shot timer while the view is shown, animation is on and a slot
/// has a GIF (next frame) or bobs (the next pixel step); it is gone while the view is hidden (`WM_SHOWWINDOW`) or scrolled out (the
/// next tick finds it out), when animation is off (Windows' "show animations" setting), while the display sleeps and
/// after `destroy()`. Frames and the decode cache are freed on `destroy()`. A clock stopped that way comes back by itself, with no
/// timer while it is off: on the view's next paint (a view that comes on screen again is always painted: shown again with its pane,
/// scrolled back, uncovered; a reopened popover or a swapped page builds new views) and when the displays wake (no repaint comes then).
@MainActor final class WinSpriteAnimator {
    struct Stats: Equatable {
        var ticks = 0, invalidations = 0, invalidatedPixels = 0, drawn = 0, scales = 0, glyphs = 0
        var styled = 0  // stage 7 Task 9
        var resumes = 0  // fix/windows-popover-sprite-shown: a stopped clock started again by a display wake (not a paint)
    }

    private(set) var stats = Stats()
    let playback: PopoverSpritePlayback
    private weak var view: WinDrawnView?
    private var token: WinSinkWindow.Token?
    private var scaled: [Int: ScaledSet] = [:]
    private var scratch = Scratch()
    private let displayAsleep: @MainActor () -> Bool
    private let animationsEnabled: @MainActor () -> Bool
    private(set) var isDestroyed = false

    private struct ScaledSet {
        var taskID: String?
        var width: Int, height: Int
        var frames: [ObjectIdentifier: [UInt8]] = [:]
        // --- stage 7 Task 9: the frame desaturated and turned, as the slot asks (begin) ---
        var styled: [String: (bytes: [UInt8], width: Int, height: Int)] = [:]
        // --- stage 7 Task 9 (end) ---
    }

    private struct Scratch {
        var dc: HDC?, bitmap: HBITMAP?, old: HGDIOBJ?, bits: UnsafeMutableRawPointer?
        var width = 0, height = 0
    }

    init(fetcher: any PlazaSpriteFetching = PlatformPlaza.spriteFetcher(), clock: PopoverAnimationClock = PopoverAnimationClock(),
         displayAsleep: @escaping @MainActor () -> Bool = { Platform.current.events.displaysAreAsleep },
         animationsEnabled: @escaping @MainActor () -> Bool = { WinSpriteAnimator.systemAnimationsEnabled() }) {
        playback = PopoverSpritePlayback(fetcher: fetcher, clock: clock)
        self.displayAsleep = displayAsleep
        self.animationsEnabled = animationsEnabled
    }

    /// Takes the view's slots after each `show` (`WinDrawnView.show` calls it).
    func update(slots: [SpriteSlot], in host: WinDrawnView) {
        guard !isDestroyed else { return }
        if view !== host { attach(host) }
        playback.animationsEnabled = animationsEnabled()
        Self.noteAnimations(playback.animationsEnabled, slots: slots)   // fix/windows-pet-still
        playback.bobSteps = max(1, Int((PopoverSpriteModel.bobTravel * host.ctx.scale).rounded()))  // stage 7 Task 9
        playback.update(slots: slots)
        let live = Set(slots.indices)
        scaled = scaled.filter { live.contains($0.key) }
    }

    private func attach(_ host: WinDrawnView) {
        view = host
        host.paintOverlay = { [weak self] dc in self?.paint(dc) }
        token = host.window.on(0x0018 /* WM_SHOWWINDOW */) { [weak self] wParam, _ in
            guard let self else { return nil }
            if wParam == 0 { self.playback.isActive = false }
            return nil
        }
        Self.live[ObjectIdentifier(self)] = LiveAnimator(animator: self)   // fix/windows-popover-sprite-shown
        Self.followDisplayWake()
        playback.shouldTick = { [weak self] in
            guard let self, let view = self.view else { return false }
            self.stats.ticks += 1
            let shown = Self.isShown(view.hwnd), asleep = self.displayAsleep()
            // fix/windows-pet-still: a tick that stops the clock says why (it starts again on a paint or a display wake)
            if !shown || asleep { AppLog.write("popover sprites: the clock stops at a tick: shown=\(shown) displays asleep=\(asleep) (until it is on screen again)") }
            return shown && !asleep
        }
        playback.onInvalidate = { [weak self] index in self?.invalidate(slot: index) }
    }

    // --- fix/windows-popover-sprite-shown: a stopped clock comes back without a paint (begin) ---
    private struct LiveAnimator { weak var animator: WinSpriteAnimator? }
    /// The attached animators, for the display wake (one handler for all: the events keep their handlers for the app's life).
    private static var live: [ObjectIdentifier: LiveAnimator] = [:]
    private static var followsDisplayWake = false

    private static func followDisplayWake() {
        guard !followsDisplayWake else { return }
        followsDisplayWake = true
        Platform.current.events.onScreensWake {
            MainActor.assumeIsolated { for entry in live.values { entry.animator?.resumeIfShown() } }
        }
    }

    /// The clock was stopped (displays asleep) and the view is on screen with the displays awake: it starts.
    private func resumeIfShown() {
        guard !isDestroyed, !playback.isActive, let view, Self.isShown(view.hwnd), !displayAsleep() else { return }
        stats.resumes += 1
        playback.isActive = true
    }
    // --- fix/windows-popover-sprite-shown (end) ---

    /// The shown state said by the host: the popover closing or another page replacing this one.
    func setShown(_ shown: Bool) {
        guard !isDestroyed else { return }
        playback.isActive = shown && Self.isShown(view?.hwnd) && !displayAsleep()
    }

    // --- fix/windows-pet-still: each slot's state in the log when it changes (never per frame) (begin) ---
    private struct SlotState: Equatable { var subject: PlazaSpriteSubjectKey?, frames: Int, loading: Bool, animated: Bool, playing: Bool }
    private var loggedSlots: [Int: SlotState] = [:]
    private func noteSlot(_ index: Int) {
        guard index < playback.models.count, let view, index < view.spriteSlots.count, view.spriteSlots[index].animated else { return }
        let model = playback.models[index]
        let state = SlotState(subject: view.spriteSlots[index].subject, frames: model.frames.count, loading: model.isLoading,
                              animated: model.animated, playing: playback.isActive && playback.animationsEnabled)
        guard loggedSlots[index] != state else { return }
        loggedSlots[index] = state
        let species = state.subject?.speciesID.map { String($0) } ?? "egg"
        AppLog.write("popover sprite #\(species) shiny=\(state.subject?.shiny == true) (slot \(index) of \(view.partName)): \(state.frames) frames, "
                     + "loading=\(state.loading) asked animated=\(state.animated) playing=\(state.playing) GIF asks=\(model.gifAsks) "
                     + "(Show animations=\(playback.animationsEnabled), active=\(playback.isActive), shown=\(Self.isShown(view.hwnd)), "
                     + "displays asleep=\(displayAsleep()), clock armed=\(playback.clock.isArmed))")
        if state.frames > 1, state.playing, Self.looksLeft > 0, let subject = state.subject, looked.insert(subject).inserted {
            Self.looksLeft -= 1
            lookAtThePixels(slot: index, species: species)
        }
    }
    // --- fix/windows-pet-still (end) ---

    // --- fix/windows-pet-and-detail-animation: what the screen shows at a playing slot, once per subject (begin) ---
    private var looked: Set<PlazaSpriteSubjectKey> = []
    /// A diagnostic: the first 12 playing subjects of the process are looked at, no more.
    private static var looksLeft = 12

    /// Five looks 0.5 s apart at the slot, in one log line: the frame index, the ticks and the screen there (captured, hashed,
    /// dropped). A model that moves while the screen does not is told apart from a clock that does not run.
    private func lookAtThePixels(slot index: Int, species: String) {
        let ticks0 = playback.ticks
        Task { @MainActor [weak self] in
            var frames: [Int] = [], screens: [Int] = [], shown: [Bool] = []
            for i in 0..<5 {
                if i > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard let self, !self.isDestroyed, let view = self.view, index < self.playback.models.count, index < view.spriteSlots.count else { return }
                let slot = view.spriteSlots[index].frame, s = view.ctx.scale
                var origin = POINT(x: Int32((slot.minX * s).rounded()), y: Int32((slot.minY * s).rounded()))
                _ = ClientToScreen(view.hwnd, &origin)
                let shot = WinUIDump.screenshot(x: Int(origin.x), y: Int(origin.y), w: max(1, Int((slot.width * s).rounded())), h: max(1, Int((slot.height * s).rounded())))
                frames.append(self.playback.models[index].frameIndex)
                screens.append(shot?.bgra.hashValue ?? 0)
                shown.append(Self.isShown(view.hwnd))
            }
            guard let self, !self.isDestroyed else { return }
            AppLog.write("popover sprite #\(species) (slot \(index) of \(self.view?.partName ?? "none")): 5 looks over 2 s: frames \(frames.map { String($0) }.joined(separator: ",")), "
                         + "ticks +\(self.playback.ticks - ticks0), shown \(shown.map { $0 ? "y" : "n" }.joined()), distinct screens at the slot "
                         + "\(Set(screens).count) (1 = the screen did not change)")
        }
    }
    // --- fix/windows-pet-and-detail-animation (end) ---

    private func invalidate(slot index: Int) {
        noteSlot(index)   // fix/windows-pet-still
        guard let view, !isDestroyed, index < view.spriteSlots.count else { return }
        var r = view.spriteSlots[index].frame
        r.origin.y -= 3          // the bob's travel
        r.size.height += 3
        stats.invalidations += 1
        let s = view.ctx.scale
        stats.invalidatedPixels += Int((r.width * s).rounded()) * Int((r.height * s).rounded())
        view.invalidate(dip: r)
    }

    // MARK: - painting

    private func paint(_ dc: HDC?) {
        guard let dc, let view, !isDestroyed else { return }
        // A paint means the view is on screen: a view that was scrolled out or hidden starts its clock again.
        if !playback.isActive, !displayAsleep() { playback.isActive = true }
        let scale = view.ctx.scale
        for (i, slot) in view.spriteSlots.enumerated() where i < playback.models.count {
            guard slot.subject != nil else { continue }
            let model = playback.models[i]
            let bob = model.bobOffset * scale  // stage 7 Task 9: the bob's step, in device pixels
            if let image = model.current {
                // stage 7 Task 9: an animated slot showing a still (no GIF, or animation off) shows it cropped to its content,
                // as the Mac's `SpriteLoader.animationPlaceholder` (the still's 96 px canvas is padded; GIFs are tight)
                let picture = slot.animated && !model.isAnimating && slot.subject?.speciesID != nil ? placeholder(image) : image
                drawImage(picture, slot: slot, index: i, model: model, bob: bob, scale: scale, into: dc)
            } else if let egg = eggGlyphImage(slot.frame, scale: scale) {  // stage 7 Task 9: the 🥚 in colour
                drawImage(egg, slot: slot, index: i, model: model, bob: bob, scale: scale, into: dc)
                stats.glyphs += 1
            } else {
                drawGlyph(slot: slot, bob: bob, scale: scale, view: view, into: dc)
            }
        }
    }

    private func drawImage(_ image: PlazaImage, slot: SpriteSlot, index: Int, model: PopoverSpriteModel, bob: CGFloat, scale: CGFloat, into dc: HDC) {
        let fit = PopoverSpriteFit.size(for: CGSize(width: image.width, height: image.height), width: slot.frame.width, height: slot.frame.height)
        let w = max(1, Int((fit.width * scale).rounded())), h = max(1, Int((fit.height * scale).rounded()))
        let x = Int(((slot.frame.midX - fit.width / 2) * scale).rounded()), y = Int(((slot.frame.midY - fit.height / 2) * scale + bob).rounded())
        var dest = RECT(left: Int32(x), top: Int32(y), right: Int32(x + w), bottom: Int32(y + h))
        guard RectVisible(dc, &dest) else { return }
        var set = scaled[index] ?? ScaledSet(taskID: nil, width: w, height: h)
        if set.taskID != model.taskID || set.width != w || set.height != h { set = ScaledSet(taskID: model.taskID, width: w, height: h) }
        let id = ObjectIdentifier(image)
        var bytes: [UInt8]
        if let kept = set.frames[id] { bytes = kept } else {
            bytes = PopoverSpriteScale.scaledBGRA(image.pixels, width: w, height: h)  // stage 7 Task 9: smooth, as the Mac shows its sprites
            set.frames[id] = bytes
            stats.scales += 1
        }
        // --- stage 7 Task 9: saturation, rotation and opacity of the slot (begin) ---
        var (dw, dh, dx, dy) = (w, h, x, y)
        if slot.saturation < 0.999 || abs(slot.rotation) > 0.001 {
            let key = "\(id.hashValue)|\(slot.saturation)|\(slot.rotation)"
            if let kept = set.styled[key] { bytes = kept.bytes; dw = kept.width; dh = kept.height } else {
                if slot.saturation < 0.999 { bytes = Self.desaturate(bytes, slot.saturation) }
                if abs(slot.rotation) > 0.001 { (bytes, dw, dh) = PopoverSpriteScale.rotateBilinear(bytes, width: w, height: h, degrees: slot.rotation) }
                set.styled[key] = (bytes: bytes, width: dw, height: dh)
                stats.styled += 1
            }
            dx = x + (w - dw) / 2
            dy = y + (h - dh) / 2
        }
        scaled[index] = set
        guard ensureScratch(dw, dh), let bits = scratch.bits else { return }
        // Rows of the (possibly wider) scratch bitmap, top-down.
        bytes.withUnsafeBytes { src in
            for row in 0..<dh {
                (bits + row * scratch.width * 4).copyMemory(from: src.baseAddress! + row * dw * 4, byteCount: dw * 4)
            }
        }
        _ = GdiFlush()
        let alpha = UInt8(max(0, min(255, (slot.opacity * 255).rounded())))
        let blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: alpha, AlphaFormat: 1)
        _ = GdiAlphaBlend(dc, Int32(dx), Int32(dy), Int32(dw), Int32(dh), scratch.dc, 0, 0, Int32(dw), Int32(dh), blend)
        // --- stage 7 Task 9 (end) ---
        stats.drawn += 1
    }

    // --- stage 7 Task 9: the pixel styles a slot asks for (begin) ---
    /// SwiftUI's `.saturation(s)` on premultiplied BGRA: each colour moves toward its luminance (Rec. 709 weights).
    nonisolated static func desaturate(_ bytes: [UInt8], _ s: Double) -> [UInt8] {
        var out = bytes
        var i = 0
        while i + 3 < out.count {
            let b = Double(out[i]), g = Double(out[i + 1]), r = Double(out[i + 2]), a = Double(out[i + 3])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            func mix(_ c: Double) -> UInt8 { UInt8(max(0, min(a, (lum + s * (c - lum)).rounded()))) }
            let (nb, ng, nr) = (mix(b), mix(g), mix(r))
            out[i] = nb
            out[i + 1] = ng
            out[i + 2] = nr
            i += 4
        }
        return out
    }

    /// The 🥚 the Mac shows where no picture loaded (`Text("🥚")` at 62 % of the box, Apple Color Emoji): Segoe UI Emoji
    /// through the plaza's DirectWrite path, in colour, as a picture the slot draws like a sprite.
    private var eggGlyph: (key: String, image: PlazaImage)?
    private func eggGlyphImage(_ frame: CGRect, scale: CGFloat) -> PlazaImage? {
        let key = "\(frame.width)x\(frame.height)@\(scale)"
        if let kept = eggGlyph, kept.key == key { return kept.image }
        let graphics = PlatformPlaza.graphics
        let font = PlazaFont.emoji(size: frame.height * 0.62)
        let line = graphics.text.line("🥚", font: font)
        let m = graphics.text.metrics(font)
        let space = PlazaPanelSpace(content: frame.size, room: 0)
        guard let image = space.image(scale: scale, graphics: graphics, { canvas in
            canvas.setFillColor(PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            let h = m.ascender - m.descender
            canvas.draw(line, at: space.canvas(CGPoint(x: (frame.width - line.width) / 2, y: (frame.height - h) / 2 + m.ascender)))
        }) else { return nil }
        eggGlyph = (key, image)
        return image
    }
    /// The Mac's `animationPlaceholder`: a still cropped square to its content (`PlazaEggCrop.square` is the same rule),
    /// kept per picture while the view lives.
    private var placeholders: [ObjectIdentifier: (source: PlazaImage, cropped: PlazaImage)] = [:]
    private func placeholder(_ image: PlazaImage) -> PlazaImage {
        let id = ObjectIdentifier(image)
        if let kept = placeholders[id], kept.source === image { return kept.cropped }
        if placeholders.count > 16 { placeholders = [:] }
        let cropped = PlazaEggCrop.square(image)
        placeholders[id] = (image, cropped)
        return cropped
    }
    // --- stage 7 Task 9: the pixel styles a slot asks for (end) ---

    private func drawGlyph(slot: SpriteSlot, bob: CGFloat, scale: CGFloat, view: WinDrawnView, into dc: HDC) {
        var r = RECT(left: Int32((slot.frame.minX * scale).rounded()), top: Int32((slot.frame.minY * scale + bob).rounded()),
                     right: Int32((slot.frame.maxX * scale).rounded()), bottom: Int32((slot.frame.maxY * scale + bob).rounded()))
        guard RectVisible(dc, &r), let font = view.ctx.fonts.emoji(size: slot.frame.height * 0.62) else { return }
        let old = SelectObject(dc, UnsafeMutableRawPointer(font))
        _ = SetBkMode(dc, 1 /* TRANSPARENT */)
        _ = SetTextColor(dc, view.ctx.colors.text(.primary))
        _ = WinStr.w("🥚").withUnsafeBufferPointer { DrawTextW(dc, $0.baseAddress, -1, &r, UINT(0x0001 | 0x0004 | 0x0020 | 0x0800)) }  // CENTER | VCENTER | SINGLELINE | NOPREFIX
        _ = SelectObject(dc, old)
        stats.glyphs += 1
    }

    private func ensureScratch(_ w: Int, _ h: Int) -> Bool {
        if scratch.dc != nil, scratch.width >= w, scratch.height >= h { return true }
        releaseScratch()
        let nw = max(w, scratch.width), nh = max(h, scratch.height)
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = Int32(nw)
        info.bmiHeader.biHeight = -Int32(nh)
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0
        guard let dc = CreateCompatibleDC(nil) else { return false }
        var p: UnsafeMutableRawPointer?
        guard let b = CreateDIBSection(dc, &info, 0, &p, nil, 0), p != nil else {
            AppLog.write("sprite animator: CreateDIBSection \(nw)x\(nh) failed: \(GetLastError())")
            _ = DeleteDC(dc)
            return false
        }
        scratch = Scratch(dc: dc, bitmap: b, old: SelectObject(dc, UnsafeMutableRawPointer(b)), bits: p, width: nw, height: nh)
        return true
    }

    private func releaseScratch() {
        let size = (scratch.width, scratch.height)
        if let dc = scratch.dc {
            _ = SelectObject(dc, scratch.old)
            _ = DeleteDC(dc)
        }
        if let b = scratch.bitmap { _ = DeleteObject(UnsafeMutableRawPointer(b)) }
        scratch = Scratch()
        scratch.width = size.0
        scratch.height = size.1
    }

    // MARK: - environment

    // --- fix/windows-pet-still: why the popover's sprites stand still, in the user's log (begin) ---
    @MainActor private static var loggedAnimations: Bool?
    /// One line in the app's log when the popover's sprite animation turns on or off (the first animated slot shown, then each
    /// change): off is Windows' "Show animations" (windows-differences: the Mac popover ignores Reduce Motion). Never per frame.
    @MainActor static func noteAnimations(_ on: Bool, slots: [SpriteSlot]) {
        guard slots.contains(where: { $0.animated }), on != loggedAnimations else { return }
        loggedAnimations = on
        var raw: Int32 = -1
        let read = SystemParametersInfoW(0x1042 /* SPI_GETCLIENTAREAANIMATION */, 0, &raw, 0)
        AppLog.write("popover sprites: " + (on ? "animate" : "stand still: Windows' \"Show animations\" is off (Settings > Accessibility > Visual effects > Animation effects)")
                     + " (SPI_GETCLIENTAREAANIMATION read=\(read) value=\(raw))")
    }
    // --- fix/windows-pet-still (end) ---

    /// Windows' "Show animations in Windows" (`SPI_GETCLIENTAREAANIMATION`).
    static func systemAnimationsEnabled() -> Bool {
        var on: Int32 = 1
        guard SystemParametersInfoW(0x1042, 0, &on, 0) else { return true }
        return on != 0
    }

    /// The view is on screen: visible up the chain, and its rectangle meets the client area of every window it is a child of, up to
    /// its top-level window (a view scrolled out of its scroll area does not). Only the parent chain: `GetParent` of a top-level popup
    /// is its OWNER, and the popover's owner is the app's hidden sink with an empty client area, so walking on to it read every sprite
    /// of the real popover as not shown and stopped its clock at the first tick (fix/windows-popover-sprite-shown, user's PC kit 11;
    /// the KitWindow, which has no owner, passed).
    static func isShown(_ hwnd: HWND?) -> Bool {
        guard let hwnd, IsWindowVisible(hwnd) else { return false }
        var area = RECT()
        guard GetWindowRect(hwnd, &area) else { return false }
        var node = hwnd
        while GetWindowLongW(node, -16 /* GWL_STYLE */) & 0x4000_0000 /* WS_CHILD */ != 0, let p = GetAncestor(node, UINT(GA_PARENT)) {
            var client = RECT()
            var origin = POINT(x: 0, y: 0)
            guard GetClientRect(p, &client), ClientToScreen(p, &origin) else { return false }
            var bounds = RECT(left: origin.x, top: origin.y, right: origin.x + client.right, bottom: origin.y + client.bottom)
            var meet = RECT()
            guard IntersectRect(&meet, &area, &bounds) else { return false }
            area = meet
            node = p
        }
        return true
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        playback.release()
        scaled = [:]
        placeholders = [:]  // stage 7 Task 9
        releaseScratch()
        if let token, let host = view { host.window.off(token) }
        token = nil
        if let host = view { host.paintOverlay = nil }
        view = nil
        Self.live[ObjectIdentifier(self)] = nil   // fix/windows-popover-sprite-shown
    }
}
#endif
