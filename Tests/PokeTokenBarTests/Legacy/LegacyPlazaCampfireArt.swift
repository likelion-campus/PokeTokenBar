// Verbatim copy of Sources/PokeTokenBar/Team/Plaza/PlazaCampfireArt.swift before Track A Task 4 (base 98876aa), renamed. The oracle for
// PlazaArtParityTests; deleted in Task 19. Do not edit except to port a fix from main.
@testable import PokeTokenBar
import CoreGraphics
import Foundation

/// 모닥불 픽셀 아트. 32x40 칸에 절차적으로 그리고 정수 배로 키운다. 규칙은 사용자가 시안으로 승인한 그대로다.
enum LegacyPlazaCampfireArt {
    enum State: Hashable { case ready, lit, ended }

    static let cells = (w: 32, h: 40)
    static let worldSize = CGSize(width: 64, height: 80)
    private static let cellsW = cells.w, cellsH = cells.h

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535
    }

    /// Value noise that repeats every `period` lattice cells in y, so an upward scroll of one period loops cleanly.
    private static func noise(_ x: Double, _ y: Double, period: Int, seed: Int) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        func w(_ v: Int) -> Int { ((v % period) + period) % period }
        let a = hash(x0 + seed, w(y0)), b = hash(x0 + 1 + seed, w(y0))
        let c = hash(x0 + seed, w(y0 + 1)), d = hash(x0 + 1 + seed, w(y0 + 1))
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = a + (b - a) * sx, bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    /// A tiny cell raster, y up from the bottom. A cell holds 0xRRGGBB and an alpha (0 = empty).
    struct Raster {
        let w: Int, h: Int
        var rgb: [UInt32], alpha: [UInt8]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; rgb = Array(repeating: 0, count: w * h); alpha = Array(repeating: 0, count: w * h) }
        func filled(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && alpha[y * w + x] > 0 }
        mutating func set(_ x: Int, _ y: Int, _ c: UInt32, _ a: UInt8 = 255) {
            guard (0..<w).contains(x), (0..<h).contains(y) else { return }
            rgb[y * w + x] = c; alpha[y * w + x] = a
        }
        mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ c: (Int, Int, Double) -> UInt32?) {
            for y in 0..<h { for x in 0..<w {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= 1, let col = c(x, y, d) { set(x, y, col) }
            } }
        }
        mutating func segment(_ a: (Double, Double), _ b: (Double, Double), width: Double, _ c: (Int, Int, Double) -> UInt32?) {
            let vx = b.0 - a.0, vy = b.1 - a.1, len2 = vx * vx + vy * vy
            for y in 0..<h { for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let t = max(0, min(1, ((px - a.0) * vx + (py - a.1) * vy) / len2))
                let qx = a.0 + vx * t, qy = a.1 + vy * t
                // signed offset across the log: positive is the upper side
                let side = ((px - qx) * -vy + (py - qy) * vx) / len2.squareRoot()
                let d = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
                if d <= width / 2, t > 0, t < 1, let col = c(x, y, side) { set(x, y, col) }
            } }
        }
        /// The same shape with a one-cell outline around it (four neighbours), like the tile sheet's sprites.
        func outlined(_ c: UInt32) -> Raster {
            var out = self
            for y in 0..<h { for x in 0..<w where !filled(x, y) {
                if filled(x - 1, y) || filled(x + 1, y) || filled(x, y - 1) || filled(x, y + 1) { out.set(x, y, c) }
            } }
            return out
        }
        mutating func over(_ top: Raster) {
            for i in 0..<(w * h) where top.alpha[i] > 0 {
                if top.alpha[i] == 255 || alpha[i] == 0 { rgb[i] = top.rgb[i]; alpha[i] = max(alpha[i], top.alpha[i]); continue }
                let a = Double(top.alpha[i]) / 255
                func mix(_ s: Int) -> UInt32 {
                    let p = Double((rgb[i] >> s) & 0xFF), q = Double((top.rgb[i] >> s) & 0xFF)
                    return UInt32(p * (1 - a) + q * a) << s
                }
                rgb[i] = mix(16) | mix(8) | mix(0)
            }
        }
        func image(scale k: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: w * k, height: h * k, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 0 {
                let c = rgb[y * w + x], a = CGFloat(alpha[y * w + x]) / 255
                ctx.setFillColor(CGColor(srgbRed: CGFloat(c >> 16 & 0xFF) / 255, green: CGFloat(c >> 8 & 0xFF) / 255,
                                         blue: CGFloat(c & 0xFF) / 255, alpha: a))
                ctx.fill(CGRect(x: x * k, y: y * k, width: k, height: k))
            } }
            return ctx.makeImage()!
        }
    }

    static let ink: UInt32 = 0x201729, inkSoft: UInt32 = 0x302639
    static let bark0: UInt32 = 0x331F29, bark1: UInt32 = 0x563A3F, bark2: UInt32 = 0x79584F, bark3: UInt32 = 0x94785C, bark4: UInt32 = 0xBC9A78
    static let cut0: UInt32 = 0xC8B060, cut1: UInt32 = 0xE0D078
    static let stone0: UInt32 = 0x505060, stone1: UInt32 = 0x949EA8, stone2: UInt32 = 0xBBBFC3, stone3: UInt32 = 0xD5D5D5
    static let grass0: UInt32 = 0x328E41, grass1: UInt32 = 0x6ADD4B

    static func logLayer(_ a: (Double, Double), _ b: (Double, Double)) -> Raster {
        var r = Raster(cellsW, cellsH)
        r.segment(a, b, width: 3.8) { x, y, side in
            if side > 0.9 { return bark4 }
            if side < -0.9 { return bark1 }
            return abs(side) < 0.3 && hash(x * 7, y * 3) < 0.5 ? bark2 : bark3
        }
        r.ellipse(a.0, a.1, 2.1, 2.0) { _, _, d in d > 0.6 ? cut0 : cut1 }
        r.set(Int(a.0), Int(a.1), bark3)
        return r.outlined(ink)
    }

    /// 불이 붙었을 때의 통나무. 아래 10줄까지만 남겨 불꽃 위로 껍질이 비치지 않게 한다.
    static func litLogs() -> Raster {
        var logs = logLayer((7, 3.4), (22, 11.5))
        logs.over(logLayer((25, 3.4), (10, 11.5)))
        for y in 10..<cellsH { for x in 0..<cellsW { logs.alpha[y * cellsW + x] = 0 } }
        return logs
    }

    static func image(_ state: State, phase: Int, scale: Int) -> CGImage {
        let t = Double(phase % PlazaCampfire.frameCount) / Double(PlazaCampfire.frameCount)
        let W = cellsW, H = cellsH
        var canvas = Raster(W, H)

        // Ground: a dirt patch with a ragged grassy rim, like the sheet's dirt tile.
        var ground = Raster(W, H)
        ground.ellipse(16, 6.2, 15.6, 6.8) { x, y, d in
            let n = hash(x * 3 + 7, y * 5 + 1)
            if d > 0.9 && n < 0.5 { return nil }
            if d > 0.78 && n > 0.86 { return grass1 }
            if hash(x, y) < 0.12 { return bark2 }
            if hash(x + 40, y) < 0.06 { return bark4 }
            return bark3
        }
        canvas.over(ground)

        let stones = (0..<11).map { i -> (Double, Double, Bool) in
            let a = Double(i) / 11 * 2 * .pi + 0.2
            return (16 + 10.4 * cos(a), 6.8 + 3.9 * sin(a), sin(a) > 0.05)
        }
        func stoneLayer(_ front: Bool) -> Raster {
            var r = Raster(W, H)
            for s in stones where s.2 != front {
                r.ellipse(s.0, s.1, 2.3, 1.7) { x, y, _ in
                    let top = Double(y) + 0.5 > s.1 + 0.4, bottom = Double(y) + 0.5 < s.1 - 0.9
                    if top && Double(x) + 0.5 < s.0 { return stone3 }
                    return top ? stone2 : bottom ? stone0 : stone1
                }
            }
            return r.outlined(inkSoft)
        }
        canvas.over(stoneLayer(false))

        // Fire bed: grey ash with charcoal; embers glow while lit and fade after.
        var bed = Raster(W, H)
        bed.ellipse(16, 6.8, 8.2, 2.8) { x, y, d in d > 0.65 ? stone1 : hash(x + 9, y) < 0.35 ? inkSoft : stone0 }
        switch state {
        case .lit:
            for (i, (x, y)) in [(11, 6), (14, 5), (18, 6), (21, 6), (16, 7), (13, 7), (19, 7)].enumerated() {
                let on = sin(2 * .pi * (t * 2 + Double(i) * 0.37)) > -0.2
                bed.set(x, y, on ? 0xF8A030 : 0xC0401E)
            }
        case .ended:
            for (i, (x, y)) in [(13, 6), (17, 7), (19, 6)].enumerated() {
                let glow = sin(2 * .pi * (t + Double(i) * 0.3))
                bed.set(x, y, glow > 0.3 ? 0xF08A24 : glow > -0.4 ? 0xC0401E : 0x8E2A1C)
            }
        case .ready: break
        }
        canvas.over(bed)

        // Two logs crossed in front, bark like the sheet's log: dark underside, light top edge, yellow cut ends.
        func capLayer(_ a: (Double, Double)) -> Raster {
            var r = Raster(W, H)
            r.ellipse(a.0, a.1, 2.1, 2.0) { _, _, d in d > 0.6 ? cut0 : cut1 }
            r.set(Int(a.0), Int(a.1), bark3)
            return r.outlined(ink)
        }
        if state == .lit {
            // Lit: the fire burns on top of the logs; only their cut ends show in front of the stones.
            let logs = litLogs()
            canvas.over(logs)
            let bands: [(Double, UInt32)] = [(0.96, 0xFFF4C2), (0.64, 0xF8CF3A), (0.43, 0xF08A24), (0.22, 0xD8382E), (0.09, 0x9E2A1E)]
            var flame = Raster(W, H)
            for y in 6..<H { for x in 0..<W {
                let h = Double(y - 6) + 0.5
                let xc = Double(x) + 0.5 - 16
                let sway = 0.8 * sin(2 * .pi * t + h * 0.2) * min(1, h / 16)
                let xs = xc - sway
                let dome = 1 - pow(abs(xs) / 10, 2)
                guard dome > 0 else { continue }
                var s = 1 - h / (27 * pow(dome, 0.75))
                if h < 4 { s += 0.18 * max(0, 1 - abs(xc) / 9) }
                // The logs show through the very bottom of the flames.
                if h < 2 + 2.2 * noise(Double(x) * 0.7, t * 6, period: 6, seed: 91), logs.filled(x, y) { continue }
                let n = 0.62 * noise(xs * 0.3, h * 0.2 - t * 4, period: 4, seed: 11)
                    + 0.38 * noise(xs * 0.6, h * 0.4 - t * 8, period: 8, seed: 57)
                let i = s + 0.8 * (n - 0.5)
                guard let band = bands.first(where: { i > $0.0 }) else { continue }
                flame.set(x, y, band.1 == 0xFFF4C2 && (h > 6 || h < 2.5 || abs(xc) > 4.5) ? 0xF8CF3A : band.1)
            } }
            canvas.over(flame)
        }

        canvas.over(stoneLayer(true))
        if state == .lit {
            canvas.over(capLayer((7, 3.4)))
            canvas.over(capLayer((25, 3.4)))
        } else {
            canvas.over(logLayer((7, 3.4), (22, 11.5)))
            canvas.over(logLayer((25, 3.4), (10, 11.5)))
        }

        switch state {
        case .lit:
            for (i, (phase, dx)) in [(0.0, -4.0), (0.27, 3.0), (0.55, -1.0), (0.8, 5.0)].enumerated() {
                let p = (t + phase).truncatingRemainder(dividingBy: 1)
                guard p < 0.9 else { continue }
                let y = 20 + p * 17
                let x = 16 + dx + 1.5 * sin(2 * .pi * (p * 1.5 + Double(i) * 0.3))
                canvas.set(Int(x), Int(y), p < 0.35 ? 0xFFE070 : p < 0.7 ? 0xF08A24 : 0xC0401E)
            }
        case .ended:
            // A thin wisp of smoke: puffs rise, swell and fade.
            var smoke = Raster(W, H)
            for k in 0..<4 {
                let p = (t + Double(k) / 4).truncatingRemainder(dividingBy: 1)
                let cy = 10 + p * 24, cx = 16 + 2.2 * sin(2 * .pi * (p * 1.2 + 0.1))
                let r = 1.8 + p * 1.8
                let a = UInt8(max(0, min(1, (1 - p) * 1.25)) * 170)
                var puff = Raster(W, H)
                puff.ellipse(cx, cy, r, r * 0.9) { _, y, _ in Double(y) + 0.5 > cy ? stone3 : stone2 }
                for i in 0..<(W * H) where puff.alpha[i] > 0 { puff.alpha[i] = a }
                smoke.over(puff)
            }
            canvas.over(smoke)
        case .ready: break
        }

        return canvas.image(scale: scale)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedFrames: [State: [CGImage]] = [:]

    /// 8배 프레임 목록. 프로세스 동안 상태별로 한 번만 만든다. ready는 1장, 나머지는 12장.
    static func frames(_ state: State) -> [CGImage] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cachedFrames[state] { return cached }
        let count = state == .ready ? 1 : PlazaCampfire.frameCount
        let made = (0..<count).map { image(state, phase: $0, scale: 8) }
        cachedFrames[state] = made
        return made
    }
}
