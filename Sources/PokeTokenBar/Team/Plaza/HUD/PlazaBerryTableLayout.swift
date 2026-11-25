import Foundation

/// Where everything on the berry five table goes, in window points with the origin top-left. The numbers are the approved mockup's, in units
/// of `u`: a stage 100u wide and 62.5u high (16:10), centred in the window, where the mockup's percentages are fractions of that stage.
/// Seat `i` of `n` sits at angle `a = π/2 + 2πi/n` (screen y down: seat 0 at the bottom, then clockwise), its pile on the inner ellipse and
/// its deck beside the pile along the tangent, both turned to face their seat.
///
/// Cards and seat boxes shrink by one common factor (`shrink`) in steps of 2 % until nothing overlaps: seat boxes, piles and decks (rotated
/// rectangles) stay clear of each other, of the seat boxes and of the centre plate, and every pile and deck corner lies inside the felt.
struct PlazaBerryTableLayout: Equatable {
    struct Seat: Equatable {
        var box: CGRect
        /// Centres of the face-up pile and of the deck, both rotated by `rotation` about their centre.
        var pile: CGPoint
        var deck: CGPoint
        var rotation: CGFloat
    }

    /// The mockup's unit: one hundredth of the stage's width.
    var unit: CGFloat
    /// 1 when nothing needed to shrink.
    var shrink: CGFloat
    /// The table ellipse's box.
    var felt: CGRect
    /// The centre plate, and the bell inside it.
    var center: CGRect
    var bell: CGRect
    /// A face-up card and a deck card, unrotated.
    var card: CGSize
    var deckCard: CGSize
    var seats: [Seat]

    static let stageAspect: CGFloat = 1.6
    static let shrinkStep: CGFloat = 0.02
    static let minimumShrink: CGFloat = 0.3
    /// The plate's and a seat box's size in `u` before shrinking; the seat box holds the sprite, the name and the five score circles.
    static let plateSize = CGSize(width: 23, height: 22)
    static let seatSize = CGSize(width: 11, height: 12.5)
    static let bellSide: CGFloat = 6, bellTop: CGFloat = 4.2
    /// The least gap two shapes keep, in points (so rounding to device pixels never makes them touch).
    static let clearance: CGFloat = 0.2

    static func make(viewport: CGSize, seats n: Int, scale: CGFloat) -> PlazaBerryTableLayout {
        var f: CGFloat = 1
        while true {
            let layout = build(viewport: viewport, seats: n, scale: scale, shrink: f)
            if layout.isClear(in: viewport) || f - shrinkStep < minimumShrink - 0.0001 { return layout }
            f -= shrinkStep
        }
    }

    private static func build(viewport: CGSize, seats n: Int, scale: CGFloat, shrink f: CGFloat) -> PlazaBerryTableLayout {
        let u = min(viewport.width, viewport.height * stageAspect) / 100
        let stageH = 100 * u / stageAspect
        let ox = (viewport.width - 100 * u) / 2, oy = (viewport.height - stageH) / 2
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        func x(_ percent: CGFloat) -> CGFloat { ox + percent * u }
        func y(_ percent: CGFloat) -> CGFloat { oy + percent * stageH / 100 }
        func rect(_ r: CGRect) -> CGRect { CGRect(x: snap(r.minX), y: snap(r.minY), width: snap(r.width), height: snap(r.height)) }
        func centred(_ c: CGPoint, _ size: CGSize) -> CGRect {
            rect(CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
        }
        let mid = CGPoint(x: x(50), y: y(50))
        let box = CGSize(width: seatSize.width * u * f, height: seatSize.height * u * f)
        let card = CGSize(width: snap(7.6 * u * f), height: snap(10.6 * u * f))
        let deckCard = CGSize(width: snap(6.2 * u * f), height: snap(8.6 * u * f))
        let plate = centred(mid, CGSize(width: plateSize.width * u, height: plateSize.height * u))
        let side = bellSide * u
        var seats: [Seat] = []
        for i in 0..<n {
            let a = .pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
            var seatBox = centred(CGPoint(x: x(50 + 44.5 * cos(a)), y: y(50 + 41.5 * sin(a))), box)
            // A seat the stage's edge would cut off stays in the window.
            seatBox.origin.x = min(max(seatBox.minX, 0), viewport.width - seatBox.width)
            seatBox.origin.y = min(max(seatBox.minY, 0), viewport.height - seatBox.height)
            let pile = CGPoint(x: x(50 + 29 * cos(a)), y: y(50 + 25 * sin(a)))
            let deck = CGPoint(x: pile.x + 9 * u * -sin(a), y: pile.y + 9 * u * cos(a))
            seats.append(Seat(box: seatBox, pile: pile, deck: deck, rotation: a - .pi / 2))
        }
        return PlazaBerryTableLayout(unit: u, shrink: f, felt: rect(CGRect(x: x(13), y: y(13), width: 74 * u, height: 0.74 * stageH)),
                                     center: plate,
                                     bell: rect(CGRect(x: plate.midX - side / 2, y: plate.minY + bellTop * u, width: side, height: side)),
                                     card: card, deckCard: deckCard, seats: seats)
    }

    // MARK: overlap

    /// The four corners of a rectangle of `size` turned by `rotation` about `centre`.
    static func corners(centre: CGPoint, size: CGSize, rotation: CGFloat) -> [CGPoint] {
        let c = cos(rotation), s = sin(rotation)
        return [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { (fx, fy) -> CGPoint in
            let px = fx * size.width, py = fy * size.height
            return CGPoint(x: centre.x + px * c - py * s, y: centre.y + px * s + py * c)
        }
    }

    /// The shapes as rotated rectangles: each seat's pile and deck.
    func pileCorners(_ i: Int) -> [CGPoint] { Self.corners(centre: seats[i].pile, size: card, rotation: seats[i].rotation) }
    func deckCorners(_ i: Int) -> [CGPoint] { Self.corners(centre: seats[i].deck, size: deckCard, rotation: seats[i].rotation) }

    private static func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Two convex quadrilaterals keep at least `gap` apart on some edge normal (the separating-axis test).
    private static func apart(_ a: [CGPoint], _ b: [CGPoint], gap: CGFloat) -> Bool {
        for poly in [a, b] {
            for k in 0..<4 {
                let p = poly[k], q = poly[(k + 1) % 4]
                let nx = p.y - q.y, ny = q.x - p.x
                let length = (nx * nx + ny * ny).squareRoot()
                guard length > 0 else { continue }
                let pa = a.map { ($0.x * nx + $0.y * ny) / length }, pb = b.map { ($0.x * nx + $0.y * ny) / length }
                if pa.max()! + gap <= pb.min()! || pb.max()! + gap <= pa.min()! { return true }
            }
        }
        return false
    }

    /// Nothing overlaps, every seat box is inside the window and every pile and deck corner is inside the felt.
    func isClear(in viewport: CGSize) -> Bool {
        let gap = Self.clearance
        var shapes: [(corners: [CGPoint], seat: Int)] = []
        for i in seats.indices { shapes.append((pileCorners(i), i)); shapes.append((deckCorners(i), i)) }
        let plate = Self.corners(of: center)
        let bounds = CGRect(origin: .zero, size: viewport)
        for seat in seats where !bounds.contains(seat.box) { return false }
        for i in seats.indices {
            for j in seats.indices where j > i && !Self.apart(Self.corners(of: seats[i].box), Self.corners(of: seats[j].box), gap: gap) { return false }
        }
        let rx = felt.width / 2, ry = felt.height / 2
        for (k, shape) in shapes.enumerated() {
            for p in shape.corners {
                let dx = (p.x - felt.midX) / rx, dy = (p.y - felt.midY) / ry
                if dx * dx + dy * dy > 1 { return false }
            }
            if !Self.apart(shape.corners, plate, gap: gap) { return false }
            for seat in seats where !Self.apart(shape.corners, Self.corners(of: seat.box), gap: gap) { return false }
            for other in shapes[(k + 1)...] where !Self.apart(shape.corners, other.corners, gap: gap) { return false }
        }
        return true
    }
}
