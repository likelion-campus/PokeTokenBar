#if os(Windows)
import Foundation
import WinSDK

/// Sprites in a drawn part (stage 7 D16): the slots a part leaves are filled with the companion's pictures. One
/// `PopoverSpritePlayback` per view (the shared state machine, tests on both systems) does the loading through the sprite
/// fetcher (off the main thread), the frame times and the clock; this class paints. Frames are scaled nearest, once, to
/// the size they take in the slot at the view's DPI (the work is memoised per frame for the current subject); a tick
/// invalidates only the changed slot's rectangle and `WM_PAINT` blends the scaled frame over the picture (`paintOverlay`).
/// A still sprite may bob (two offsets, 3 DIP); a missing picture is the 🥚 glyph in Segoe UI Emoji.
///
/// Timers: none of its own. The shared clock holds one one-shot timer while the view is shown, animation is on and a slot
/// has a GIF (next frame) or bobs (0.9 s); it is gone while the view is hidden (`WM_SHOWWINDOW`) or scrolled out (the
/// next tick finds it out), when animation is off (Windows' "show animations" setting), while the display sleeps and
/// after `destroy()`. Frames and the decode cache are freed on `destroy()`.
@MainActor final class WinSpriteAnimator {
    struct Stats: Equatable {
        var ticks = 0, invalidations = 0, invalidatedPixels = 0, drawn = 0, scales = 0, glyphs = 0
        var styled = 0  // stage 7 Task 9
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
        playback.shouldTick = { [weak self] in
            guard let self, let view = self.view else { return false }
            self.stats.ticks += 1
            return Self.isShown(view.hwnd) && !self.displayAsleep()
        }
        playback.onInvalidate = { [weak self] index in self?.invalidate(slot: index) }
    }

    /// The shown state said by the host: the popover closing or another page replacing this one.
    func setShown(_ shown: Bool) {
        guard !isDestroyed else { return }
        playback.isActive = shown && Self.isShown(view?.hwnd) && !displayAsleep()
    }

    private func invalidate(slot index: Int) {
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
            let bob = model.bobUp ? -3 * scale : 0
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
            bytes = Self.scaleNearest(image.pixels, width: w, height: h)
            set.frames[id] = bytes
            stats.scales += 1
        }
        // --- stage 7 Task 9: saturation, rotation and opacity of the slot (begin) ---
        var (dw, dh, dx, dy) = (w, h, x, y)
        if slot.saturation < 0.999 || abs(slot.rotation) > 0.001 {
            let key = "\(id.hashValue)|\(slot.saturation)|\(slot.rotation)"
            if let kept = set.styled[key] { bytes = kept.bytes; dw = kept.width; dh = kept.height } else {
                if slot.saturation < 0.999 { bytes = Self.desaturate(bytes, slot.saturation) }
                if abs(slot.rotation) > 0.001 { (bytes, dw, dh) = Self.rotateNearest(bytes, width: w, height: h, degrees: slot.rotation) }
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

    /// SwiftUI's `.rotationEffect` (clockwise degrees, about the centre), nearest neighbour into the turned picture's
    /// bounding box (the sprites stay pixel-crisp).
    nonisolated static func rotateNearest(_ bytes: [UInt8], width w: Int, height h: Int, degrees: Double) -> ([UInt8], Int, Int) {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        let ow = Int((abs(Double(w) * c) + abs(Double(h) * s)).rounded(.up)), oh = Int((abs(Double(w) * s) + abs(Double(h) * c)).rounded(.up))
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        let cx = Double(w) / 2, cy = Double(h) / 2, ocx = Double(ow) / 2, ocy = Double(oh) / 2
        for y in 0..<oh {
            for x in 0..<ow {
                let px = Double(x) + 0.5 - ocx, py = Double(y) + 0.5 - ocy
                let sx = Int((c * px + s * py + cx).rounded(.down)), sy = Int((-s * px + c * py + cy).rounded(.down))
                guard sx >= 0, sy >= 0, sx < w, sy < h else { continue }
                let si = (sy * w + sx) * 4, oi = (y * ow + x) * 4
                out[oi] = bytes[si]; out[oi + 1] = bytes[si + 1]; out[oi + 2] = bytes[si + 2]; out[oi + 3] = bytes[si + 3]
            }
        }
        return (out, ow, oh)
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

    /// Nearest-neighbour scaling to a premultiplied BGRA picture (sprites stay crisp, as the Mac's `.interpolation(.none)`).
    nonisolated static func scaleNearest(_ bitmap: PlazaBitmap, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let sw = bitmap.width, sh = bitmap.height
        guard sw > 0, sh > 0 else { return out }
        let opaque = bitmap.alpha == .noneSkipLast
        bitmap.bytes.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let sy = min(sh - 1, y * sh / height)
                for x in 0..<width {
                    let s = (sy * sw + min(sw - 1, x * sw / width)) * 4
                    let o = (y * width + x) * 4
                    out[o] = src[s + 2]; out[o + 1] = src[s + 1]; out[o + 2] = src[s]
                    out[o + 3] = opaque ? 255 : src[s + 3]
                }
            }
        }
        return out
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

    /// Windows' "Show animations in Windows" (`SPI_GETCLIENTAREAANIMATION`).
    static func systemAnimationsEnabled() -> Bool {
        var on: Int32 = 1
        guard SystemParametersInfoW(0x1042, 0, &on, 0) else { return true }
        return on != 0
    }

    /// The view is on screen: visible up the chain, not minimized, and its rectangle meets every ancestor's client area
    /// (a view scrolled out of its scroll area does not).
    static func isShown(_ hwnd: HWND?) -> Bool {
        guard let hwnd, IsWindowVisible(hwnd) else { return false }
        var area = RECT()
        guard GetWindowRect(hwnd, &area) else { return false }
        var parent = GetParent(hwnd)
        while let p = parent {
            var client = RECT()
            var origin = POINT(x: 0, y: 0)
            guard GetClientRect(p, &client), ClientToScreen(p, &origin) else { return false }
            var bounds = RECT(left: origin.x, top: origin.y, right: origin.x + client.right, bottom: origin.y + client.bottom)
            var meet = RECT()
            guard IntersectRect(&meet, &area, &bounds) else { return false }
            area = meet
            parent = GetParent(p)
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
    }
}
#endif
