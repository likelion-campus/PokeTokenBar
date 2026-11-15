import Foundation

/// One element of a path made of lines and cubic curves.
enum PlazaCurveElement: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, c1: CGPoint, c2: CGPoint)
    case close
}

/// SwiftUI's `.continuous` rounded corners (`RoundedRectangle`, `UnevenRoundedRectangle`) as Bézier elements, so a
/// canvas that has no SwiftUI draws the same outline. Reverse-engineered from SwiftUI's own paths on the Mac (the
/// measurement is `Tests/PlazaParityGoldens/corners.json`, re-taken by `PlazaParityGoldensMacTests`):
/// - a corner is three cubic curves; in units of the corner's radius `r` the points are fixed constants (single
///   precision, as SwiftUI keeps them);
/// - two corners on one edge share it in proportion to their radii; a radius first shrinks so that two neighbours
///   fit (each takes at most `edge − the neighbour's share`, the neighbour counted at most half the edge);
/// - the first curve starts `t·r` from the corner with `t = min(1.528665, share / r)`; for `t < 1.528665` the first
///   control points are interpolated linearly between their `t = 1` and `t = 1.528665` values.
/// The result is bit-equal to SwiftUI wherever `t` is 1 or 1.528665 on both legs of every corner; between, SwiftUI's
/// single-precision intermediates differ from ours by at most one `Float` step (about 1e-7 relative).
enum PlazaContinuousCorners {
    private static let tMax = Float(1.528665)
    private static let k1Max = Float(1.08849), k2Max = Float(0.868407)
    private static let k1Min = Float(0.96), k2Min = Float(0.82)
    private static let pa = Double(Float(0.0749114)), pb = Double(Float(0.631494))
    private static let qa = Double(Float(0.16906)), qb = Double(Float(0.372824))

    /// SwiftUI's `Path(roundedRect: rect, cornerRadius: radius, style: .continuous)` elements (the rectangle's own
    /// coordinates, y as given).
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> [PlazaCurveElement] {
        let r = Double(radius)
        if r <= 0 { return squareRect(Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height), startsAtTop: true) }
        return outline(x0: Double(rect.minX), y0: Double(rect.minY), w: Double(rect.width), h: Double(rect.height), tl: r, bl: r, br: r, tr: r)
    }

    /// SwiftUI's `UnevenRoundedRectangle` elements, built top-left in `rect`'s size and turned over into canvas
    /// coordinates (origin bottom-left: the shape's top is `rect.maxY`), as `CGPlazaCanvas` draws it.
    static func unevenRoundedRect(_ rect: CGRect, radii: PlazaCornerRadii) -> [PlazaCurveElement] {
        let w = Double(rect.width), h = Double(rect.height)
        let down: [PlazaCurveElement]
        if radii.topLeading <= 0 && radii.bottomLeading <= 0 && radii.bottomTrailing <= 0 && radii.topTrailing <= 0 {
            down = squareRect(0, 0, w, h, startsAtTop: false)
        } else {
            down = outline(x0: 0, y0: 0, w: w, h: h, tl: Double(radii.topLeading), bl: Double(radii.bottomLeading),
                           br: Double(radii.bottomTrailing), tr: Double(radii.topTrailing))
        }
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + rect.minX, y: rect.maxY - p.y) }
        return down.map {
            switch $0 {
            case .move(let p): .move(flip(p))
            case .line(let p): .line(flip(p))
            case .curve(let p, let c1, let c2): .curve(to: flip(p), c1: flip(c1), c2: flip(c2))
            case .close: .close
            }
        }
    }

    private static func squareRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, startsAtTop: Bool) -> [PlazaCurveElement] {
        if startsAtTop {
            return [.move(CGPoint(x: x, y: y)), .line(CGPoint(x: x + w, y: y)), .line(CGPoint(x: x + w, y: y + h)),
                    .line(CGPoint(x: x, y: y + h)), .close]
        }
        return [.move(CGPoint(x: x + w, y: y + h / 2)), .line(CGPoint(x: x + w, y: y + h)), .line(CGPoint(x: x, y: y + h)),
                .line(CGPoint(x: x, y: y)), .line(CGPoint(x: x + w, y: y)), .close]
    }

    private struct Corner { var r: Double; var t1: Float; var t2: Float }

    private static func lerp(_ t: Float, _ lo: Float, _ hi: Float) -> Double {
        if t >= tMax { return Double(hi) }
        return Double(Float(Double(lo) + (Double(hi) - Double(lo)) * (Double(t) - 1) / (Double(tMax) - 1)))
    }

    /// y-down outline starting on the right edge, clockwise on screen: bottom-right, bottom-left, top-left, top-right.
    private static func outline(x0: Double, y0: Double, w: Double, h: Double, tl: Double, bl: Double, br: Double, tr: Double) -> [PlazaCurveElement] {
        func cap(_ other: Double, _ edge: Double) -> Double { edge - min(other, edge / 2) }
        var rTL = max(tl, 0), rBL = max(bl, 0), rBR = max(br, 0), rTR = max(tr, 0)
        let wantTL = rTL, wantBL = rBL, wantBR = rBR, wantTR = rTR
        for _ in 0..<8 {   // a neighbour's shrinking can free room: repeat until nothing moves
            let nTL = min(wantTL, cap(rBL, h), cap(rTR, w)), nBL = min(wantBL, cap(rTL, h), cap(rBR, w))
            let nBR = min(wantBR, cap(rTR, h), cap(rBL, w)), nTR = min(wantTR, cap(rBR, h), cap(rTL, w))
            if nTL == rTL && nBL == rBL && nBR == rBR && nTR == rTR { break }
            (rTL, rBL, rBR, rTR) = (nTL, nBL, nBR, nTR)
        }
        func share(_ r1: Double, _ r2: Double, _ edge: Double) -> (Double, Double) {
            r1 + r2 == 0 ? (edge, edge) : (edge * r1 / (r1 + r2), edge - edge * r1 / (r1 + r2))
        }
        let (left1, left2) = share(rTL, rBL, h), (bottom1, bottom2) = share(rBL, rBR, w)
        let (right1, right2) = share(rTR, rBR, h), (top1, top2) = share(rTL, rTR, w)
        func corner(_ r: Double, _ s1: Double, _ s2: Double) -> Corner {
            r <= 0 ? Corner(r: 0, t1: 0, t2: 0) : Corner(r: r, t1: min(tMax, Float(s1 / r)), t2: min(tMax, Float(s2 / r)))
        }
        let cBR = corner(rBR, right2, bottom2), cBL = corner(rBL, bottom1, left2)
        let cTL = corner(rTL, left1, top1), cTR = corner(rTR, top2, right1)

        var out: [PlazaCurveElement] = [.move(CGPoint(x: x0 + w, y: y0 + h / 2 + (cTR.r - cBR.r) / 2))]
        func emit(_ cx: Double, _ cy: Double, _ u: (Double, Double), _ v: (Double, Double), _ c: Corner) {
            func pt(_ a: Double, _ b: Double) -> CGPoint { CGPoint(x: cx + u.0 * a + v.0 * b, y: cy + u.1 * a + v.1 * b) }
            let r = c.r
            if r <= 0 {
                out.append(.line(pt(0, 0)))
                for _ in 0..<3 { out.append(.curve(to: pt(0, 0), c1: pt(0, 0), c2: pt(0, 0))) }
                return
            }
            out.append(.line(pt(Double(c.t1) * r, 0)))
            out.append(.curve(to: pt(pb * r, pa * r), c1: pt(lerp(c.t1, k1Min, k1Max) * r, 0), c2: pt(lerp(c.t1, k2Min, k2Max) * r, 0)))
            out.append(.curve(to: pt(pa * r, pb * r), c1: pt(qb * r, qa * r), c2: pt(qa * r, qb * r)))
            out.append(.curve(to: pt(0, Double(c.t2) * r), c1: pt(0, lerp(c.t2, k2Min, k2Max) * r), c2: pt(0, lerp(c.t2, k1Min, k1Max) * r)))
        }
        emit(x0 + w, y0 + h, (0, -1), (-1, 0), cBR)
        emit(x0, y0 + h, (1, 0), (0, -1), cBL)
        emit(x0, y0, (0, 1), (1, 0), cTL)
        emit(x0 + w, y0, (-1, 0), (0, 1), cTR)
        out.append(.close)
        return out
    }
}
