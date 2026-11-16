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
                drawImage(image, slot: slot, index: i, model: model, bob: bob, scale: scale, into: dc)
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
        let bytes: [UInt8]
        if let kept = set.frames[id] { bytes = kept } else {
            bytes = Self.scaleNearest(image.pixels, width: w, height: h)
            set.frames[id] = bytes
            stats.scales += 1
        }
        scaled[index] = set
        guard ensureScratch(w, h), let bits = scratch.bits else { return }
        // Rows of the (possibly wider) scratch bitmap, top-down.
        bytes.withUnsafeBytes { src in
            for row in 0..<h {
                (bits + row * scratch.width * 4).copyMemory(from: src.baseAddress! + row * w * 4, byteCount: w * 4)
            }
        }
        _ = GdiFlush()
        let blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1)
        _ = GdiAlphaBlend(dc, Int32(x), Int32(y), Int32(w), Int32(h), scratch.dc, 0, 0, Int32(w), Int32(h), blend)
        stats.drawn += 1
    }

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
        releaseScratch()
        if let token, let host = view { host.window.off(token) }
        token = nil
        if let host = view { host.paintOverlay = nil }
        view = nil
    }
}
#endif
