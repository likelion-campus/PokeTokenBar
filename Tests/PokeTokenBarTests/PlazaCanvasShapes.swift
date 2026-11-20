import Foundation
@testable import PokeTokenBar

/// Text-free canvas scripts, one per operation family, drawn by every platform's canvas and compared with the Mac's pixels
/// (`Tests/PlazaParityGoldens/canvas-shapes/<name>.png`, written by `PlazaCanvasShapesMacTests`). `PlazaCanvasScript` (the
/// full script) has text in it, which Windows cannot draw until the DirectWrite engine; these cases are what pins the rest.
/// `exact` cases use only integer-aligned, opaque or hard-edged drawing, where a canvas has no room for a different answer.
enum PlazaCanvasShapes {
    struct Case: @unchecked Sendable {
        let name: String
        let exact: Bool
        let run: (any PlazaCanvas) -> Void
    }

    static let width = 96, height = 64

    private static let red = PlazaColor(hex: 0xE5484D), green = PlazaColor(hex: 0x30A46C), blue = PlazaColor(hex: 0x3E63DD)
    private static let yellow = PlazaColor(hex: 0xF5D90A), ink = PlazaColor(hex: 0x14161F), pink = PlazaColor(hex: 0xFF9ECF)
    private static let small = PlazaImage(bitmap: PlazaTestImages.patterned(width: 6, height: 5))

    static let cases: [Case] = [
        Case(name: "fills-exact", exact: true) { c in
            c.setFillColor(red); c.fill(CGRect(x: 4, y: 4, width: 20, height: 10))
            c.setFillColor(green); c.fill(CGRect(x: 30, y: 10, width: 12, height: 30))
            c.setFillColor(blue); c.fill(CGRect(x: 20, y: 8, width: 14, height: 6))
            c.setFillGray(0.55); c.fill(CGRect(x: 50, y: 4, width: 10, height: 10))
            c.setFillColor(ink); c.fill(CGRect(x: 70, y: 40, width: 20, height: 20))
        },
        Case(name: "fills-fractional", exact: false) { c in
            c.setFillColor(red); c.fill(CGRect(x: 3.5, y: 3.25, width: 10.3, height: 7.6))
            c.setFillColor(green); c.fill(CGRect(x: 20.75, y: 10.5, width: 12, height: 12.5))
            c.setFillColor(blue); c.fillEllipse(in: CGRect(x: 40, y: 8, width: 21, height: 13))
            c.setFillColor(yellow); c.fillEllipse(in: CGRect(x: 66.5, y: 30.5, width: 20, height: 20))
        },
        Case(name: "transformed", exact: false) { c in
            c.saveState()
            c.translate(x: 20, y: 10); c.scale(x: 1.5, y: 1.25); c.rotate(by: 0.3)
            c.setFillColor(pink); c.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
            c.restoreState()
            c.saveState()
            c.translate(x: 70, y: 40); c.rotate(by: -0.7); c.scale(x: 2, y: 1)
            c.setFillColor(blue); c.fill(CGRect(x: -6, y: -4, width: 12, height: 8))
            c.restoreState()
            c.setFillColor(green); c.fill(CGRect(x: 4, y: 40, width: 12, height: 8))
        },
        Case(name: "clips-exact", exact: true) { c in
            c.saveState()
            c.clip(to: CGRect(x: 4, y: 4, width: 50, height: 40))
            c.saveState()
            c.clip(to: CGRect(x: 20, y: 10, width: 60, height: 30))
            c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            c.restoreState()
            c.setFillColor(blue); c.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            c.restoreState()
            c.setFillColor(green); c.fill(CGRect(x: 60, y: 50, width: 30, height: 10))
        },
        Case(name: "clip-rotated", exact: false) { c in
            c.saveState()
            c.translate(x: 48, y: 32); c.rotate(by: 0.5)
            c.clip(to: CGRect(x: -20, y: -12, width: 40, height: 24))
            c.translate(x: -48, y: -32)
            c.setFillColor(yellow); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            c.setFillColor(ink); c.fill(CGRect(x: 0, y: 28, width: 96, height: 8))
            c.restoreState()
        },
        Case(name: "ellipse-strokes", exact: false) { c in
            c.setStrokeColor(ink)
            c.strokeEllipse(in: CGRect(x: 4, y: 4, width: 26, height: 20), lineWidth: 1)
            c.strokeEllipse(in: CGRect(x: 34.5, y: 4.5, width: 26, height: 20), lineWidth: 2.5)
            c.setStrokeColor(red)
            c.strokeEllipse(in: CGRect(x: 64, y: 8, width: 24, height: 24), lineWidth: 4)
        },
        Case(name: "paths", exact: false) { c in
            var star = PlazaPath()
            for i in 0..<5 {
                let a = Double(i) * 4 * Double.pi / 5 + Double.pi / 2
                let p = CGPoint(x: 20 + 16 * CGFloat(cos(a)), y: 40 + 16 * CGFloat(sin(a)))
                if i == 0 { star.move(to: p) } else { star.line(to: p) }
            }
            star.close()
            c.setFillColor(pink); c.fillPath(star)
            let zig = PlazaPath(points: [CGPoint(x: 44, y: 8), CGPoint(x: 56, y: 28), CGPoint(x: 68, y: 8), CGPoint(x: 80, y: 28)])
            c.setStrokeColor(ink)
            c.setLineJoin(.miter); c.strokePath(zig, lineWidth: 5, cap: .butt)
            c.saveState(); c.translate(x: 0, y: 30)
            c.setLineJoin(.round); c.strokePath(zig, lineWidth: 5, cap: .round)
            c.restoreState()
            c.setStrokeColor(red)
            c.strokePath(PlazaPath(points: [CGPoint(x: 44, y: 56), CGPoint(x: 60, y: 46), CGPoint(x: 76, y: 56)], closed: true), lineWidth: 1, cap: .butt)
            c.setStrokeColor(blue)
            c.strokePath(PlazaPath(rect: CGRect(x: 81.5, y: 40.5, width: 8, height: 8)), lineWidth: 1, cap: .butt)
        },
        Case(name: "rounded", exact: false) { c in
            c.setFillColor(pink)
            c.fillRoundedRect(CGRect(x: 4, y: 40, width: 24, height: 20), radius: 4)
            c.fillRoundedRect(CGRect(x: 32, y: 36, width: 28, height: 24), radius: 10)
            c.setFillColor(blue)
            c.fillRoundedRect(CGRect(x: 64, y: 30, width: 28, height: 30), radius: 14)
            c.setStrokeColor(ink)
            c.strokeRoundedRect(CGRect(x: 4.5, y: 4.5, width: 40, height: 24), radius: 8, lineWidth: 1)
            c.strokeRoundedRect(CGRect(x: 50, y: 4, width: 40, height: 22), radius: 11, lineWidth: 2.5)
        },
        Case(name: "uneven", exact: false) { c in
            c.setFillColor(green)
            c.fillUnevenRoundedRect(CGRect(x: 4, y: 34, width: 40, height: 26), radii: PlazaCornerRadii(topLeading: 10, bottomLeading: 0, bottomTrailing: 20, topTrailing: 5))
            c.setStrokeColor(ink)
            c.strokeUnevenRoundedRect(CGRect(x: 50.5, y: 34.5, width: 40, height: 26), radii: PlazaCornerRadii(topLeading: 0, bottomLeading: 12, bottomTrailing: 0, topTrailing: 12), lineWidth: 1)
            c.saveState()
            c.clip(toUnevenRoundedRect: CGRect(x: 4, y: 4, width: 50, height: 24), radii: PlazaCornerRadii(topLeading: 12, bottomLeading: 12, bottomTrailing: 0, topTrailing: 0))
            c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 96, height: 14))
            c.setFillColor(yellow); c.fill(CGRect(x: 0, y: 14, width: 96, height: 14))
            c.restoreState()
            c.saveState()
            c.clip(toRoundedRect: CGRect(x: 60, y: 4, width: 30, height: 24), radius: 10)
            c.setFillColor(blue); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            c.restoreState()
        },
        Case(name: "images-nearest-exact", exact: true) { c in
            c.setInterpolationNone()
            c.draw(small, in: CGRect(x: 4, y: 4, width: 12, height: 10))
            c.draw(small, in: CGRect(x: 22, y: 4, width: 6, height: 5))
            c.draw(small, in: CGRect(x: 34, y: 4, width: 30, height: 25))
            c.saveState()
            c.translate(x: 90, y: 4); c.scale(x: -1, y: 1)
            c.draw(small, in: CGRect(x: 0, y: 0, width: 12, height: 10))
            c.restoreState()
            c.saveState()
            c.translate(x: 4, y: 60); c.scale(x: 1, y: -1)
            c.draw(small, in: CGRect(x: 0, y: 0, width: 12, height: 10))
            c.restoreState()
        },
        Case(name: "images-nearest-offset", exact: false) { c in
            c.setInterpolationNone()
            c.draw(small, in: CGRect(x: 4.5, y: 4.25, width: 12, height: 10))
            c.draw(small, in: CGRect(x: 30, y: 4, width: 13.5, height: 11))
            c.saveState()
            c.translate(x: 70, y: 30); c.rotate(by: 0.4)
            c.draw(small, in: CGRect(x: 0, y: 0, width: 18, height: 15))
            c.restoreState()
        },
        Case(name: "images-default-interpolation", exact: false) { c in
            c.draw(small, in: CGRect(x: 4, y: 4, width: 18, height: 15))
            c.draw(small, in: CGRect(x: 30.5, y: 4.5, width: 12, height: 10))
            c.draw(small, in: CGRect(x: 52, y: 4, width: 3, height: 2.5))
        },
        Case(name: "alpha-blend", exact: false) { c in
            c.setFillColor(red); c.fill(CGRect(x: 4, y: 4, width: 30, height: 30))
            c.setAlpha(0.5); c.setFillColor(blue); c.fill(CGRect(x: 20, y: 20, width: 30, height: 30))
            c.setAlpha(1)
            c.setFillColor(PlazaColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 0.4)); c.fill(CGRect(x: 40, y: 4, width: 20, height: 20))
            c.setBlend(.multiply); c.setAlpha(0.6); c.setFillColor(yellow)
            c.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
            c.fillEllipse(in: CGRect(x: 60, y: 30, width: 30, height: 24))
            c.setBlend(.normal); c.setAlpha(1)
            c.saveState()
            c.clip(to: CGRect(x: 60, y: 4, width: 30, height: 20))
            c.setFillColor(pink); c.fill(CGRect(x: 60, y: 10, width: 36, height: 5))
            c.setBlend(.sourceAtop)
            c.setFillColor(PlazaColor(srgbRed: 0.1, green: 0.5, blue: 0.7, alpha: 0.5)); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            c.restoreState()
        },
        Case(name: "shadow", exact: false) { c in
            c.setShadow(PlazaShadow(offset: CGSize(width: 3, height: -3), blur: 6, color: PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)))
            c.setFillColor(yellow); c.fill(CGRect(x: 10, y: 24, width: 30, height: 24))
            c.setFillColor(pink); c.fillEllipse(in: CGRect(x: 54, y: 24, width: 28, height: 24))
            c.setShadow(nil)
            c.setFillColor(blue); c.fill(CGRect(x: 4, y: 4, width: 10, height: 6))
        },
        Case(name: "aliased", exact: false) { c in
            c.setShouldAntialias(false)
            c.setFillColor(red); c.fillEllipse(in: CGRect(x: 4, y: 4, width: 26, height: 20))
            c.setFillColor(green); c.fill(CGRect(x: 36.5, y: 4.5, width: 20.4, height: 12.6))
            c.setFillColor(blue); c.fillRoundedRect(CGRect(x: 4, y: 34, width: 30, height: 24), radius: 8)
            c.saveState()
            c.translate(x: 70, y: 34); c.rotate(by: 0.5)
            c.setFillColor(ink); c.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
            c.restoreState()
            c.setShouldAntialias(true); c.setAllowsAntialiasing(false)
            c.setFillColor(yellow); c.fillEllipse(in: CGRect(x: 62, y: 4, width: 24, height: 18))
        },
    ]

    static func render(_ shape: Case, graphics: any PlazaGraphics) -> PlazaImage? {
        guard let canvas = graphics.makeCanvas(width: width, height: height, colorSpace: .sRGB) else { return nil }
        shape.run(canvas)
        return canvas.makeImage()
    }
}
