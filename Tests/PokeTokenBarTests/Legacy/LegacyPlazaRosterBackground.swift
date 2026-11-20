// The striped plate the SwiftUI roster, board and card stood on (`PlazaRosterBackground`, from PlazaRosterView.swift), kept so the panels' render tests can
// draw their "before" from the real views and the menus' legacy copies keep their look. Deleted in Task 19 with the rest of `Legacy/`.
import SwiftUI
import AppKit
@testable import PokeTokenBar

@MainActor
struct PlazaRosterBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x2D7F87)))
            // 135° 줄무늬: 6pt 두께 두 색 교대
            let alt = Color(hex: 0x2A7880)
            var x = -size.height
            var odd = false
            while x < size.width {
                if odd {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + 6, y: 0))
                    p.addLine(to: CGPoint(x: x + 6 + size.height, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: size.height)); p.closeSubpath()
                    ctx.fill(p, with: .color(alt))
                }
                odd.toggle(); x += 6
            }
        }
        .clipShape(shape)
        // 바깥 선(0–3pt)을 먼저 그리고 안쪽 선(3–5pt)을 그 위에 그려 2pt 전체가 보이게 한다.
        .overlay(shape.inset(by: 1.5).stroke(Color(hex: 0x1D4F55), lineWidth: 3))
        .overlay(shape.inset(by: 4).stroke(Color(hex: 0x5FB7BD), lineWidth: 2))
    }
}

