import SwiftUI
import AppKit

/// 오른쪽 아래 작은 지도. 누가 어디에 있는지 한눈에 보인다. 배경을 숨겨도 이 지도는 불투명하다.
@MainActor
struct PlazaMinimapView: View {
    let model: PlazaMinimapModel
    let mapImage: NSImage
    let worldSize: CGSize

    var body: some View {
        let width = PlazaMinimapModel.width
        let height = (width * worldSize.height / max(worldSize.width, 1)).rounded()
        ZStack {
            Image(nsImage: mapImage).resizable().interpolation(.medium)
            Canvas { context, size in
                let s = size.width / max(worldSize.width, 1)
                let view = model.view
                if view.width > 0 {
                    let rect = CGRect(x: view.minX * s, y: view.minY * s, width: view.width * s, height: view.height * s)
                    context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                let tile = CGFloat(PlazaMap.tileSize) * s
                for dot in model.dots.sorted(by: { !$0.isMe && $1.isMe }) {
                    let r: CGFloat = dot.isMe ? 4.5 : 3.5
                    let center = CGPoint(x: (CGFloat(dot.tile.x) + 0.5) * tile, y: (CGFloat(dot.tile.y) + 0.5) * tile)
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    context.opacity = dot.isAway ? 0.45 : 1
                    context.fill(circle, with: .color(Color(cgColor: dot.color)))
                    context.stroke(circle, with: .color(dot.isMe ? .white : Color(hex: 0x14161F)), lineWidth: dot.isMe ? 1.5 : 1)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
    }
}

/// 마우스·키를 장면에 그대로 넘기는 호스팅 뷰.
final class PlazaMinimapHostingView: NSHostingView<PlazaMinimapView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
