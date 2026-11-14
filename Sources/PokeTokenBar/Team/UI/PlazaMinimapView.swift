import SwiftUI
import AppKit

/// 오른쪽 아래 작은 지도. 누가 어디에 있는지 한눈에 보인다. 배경을 숨기면 지도 그림과 바탕을 반투명하게 낮추고
/// 점과 영역 표시만 또렷하게 남긴다. 지도 그림은 광장처럼 때에 따라 색이 바뀌고 밤에는 채도도 낮아진다. 점과 영역 표시는 그대로다.
@MainActor
struct PlazaMinimapView: View {
    let model: PlazaMinimapModel
    var background = PlazaBackgroundModel()
    let mapImage: NSImage
    let worldSize: CGSize
    /// 정해진 시각으로 그린다(테스트용). nil이면 지금 시각을 1분마다 따른다.
    var fixedDate: Date?

    var body: some View {
        let width = PlazaMinimapModel.width
        let height = (width * worldSize.height / max(worldSize.width, 1)).rounded()
        let dimmed = background.isHidden
        ZStack {
            if let fixedDate {
                mapLayer(at: fixedDate, dimmed: dimmed)
            } else {
                TimelineView(.everyMinute) { context in mapLayer(at: context.date, dimmed: dimmed) }
            }
            Canvas { context, size in
                let s = size.width / max(worldSize.width, 1)
                let view = model.view
                if view.width > 0 {
                    let rect = CGRect(x: view.minX * s, y: view.minY * s, width: view.width * s, height: view.height * s)
                    context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                let tile = CGFloat(PlazaMap.tileSize) * s
                if let fire = model.campfire {
                    // 모닥불 자리는 2×2칸이라 중심은 왼쪽 위 칸에서 한 칸 오른쪽·아래다.
                    let c = CGPoint(x: (CGFloat(fire.x) + 1) * tile, y: (CGFloat(fire.y) + 1) * tile)
                    let square = Path(CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
                    context.opacity = 1
                    context.fill(square, with: .color(Color(hex: 0xF08A24)))
                    context.stroke(square, with: .color(Color(hex: 0x14161F)), lineWidth: 1)
                }
                if let item = model.item {
                    let c = CGPoint(x: (CGFloat(item.x) + 0.5) * tile, y: (CGFloat(item.y) + 0.5) * tile)
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: c.x, y: c.y - 4))
                    diamond.addLine(to: CGPoint(x: c.x + 4, y: c.y))
                    diamond.addLine(to: CGPoint(x: c.x, y: c.y + 4))
                    diamond.addLine(to: CGPoint(x: c.x - 4, y: c.y))
                    diamond.closeSubpath()
                    context.opacity = 1
                    context.fill(diamond, with: .color(Color(hex: 0xF2C14E)))
                    context.stroke(diamond, with: .color(Color(hex: 0x14161F)), lineWidth: 1)
                }
                for dot in model.dots.sorted(by: { !$0.isMe && $1.isMe }) {
                    let r: CGFloat = dot.isMe ? 4.5 : 3.5
                    let center = CGPoint(x: (CGFloat(dot.tile.x) + 0.5) * tile, y: (CGFloat(dot.tile.y) + 0.5) * tile)
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    context.opacity = dot.isAway ? 0.45 : 1
                    context.fill(circle, with: .color(Color(plaza: dot.color)))
                    context.stroke(circle, with: .color(dot.isMe ? .white : Color(hex: 0x14161F)), lineWidth: dot.isMe ? 1.5 : 1)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(dimmed ? Color.black.opacity(Self.dimmedPanelOpacity) : Color(hex: 0x1D4F5C)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(dimmed ? 0.3 : 0.5), lineWidth: 1.5))
    }

    /// 배경을 숨겼으면 광장처럼 색을 바꾸지 않는다.
    private func mapLayer(at date: Date, dimmed: Bool) -> some View {
        let minute = PlazaDaylight.minute(of: date)
        let tint = dimmed ? .none : PlazaDaylight.tint(minute: minute, core: model.coreTime)
        return Image(nsImage: model.seasonMapImage?.nsImage ?? mapImage).resizable().interpolation(.medium)
            .colorMultiply(Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue))
            .saturation(dimmed ? 1 : PlazaDaylight.minimapSaturation(minute: minute, core: model.coreTime))
            .opacity(dimmed ? Self.dimmedMapOpacity : 1)
    }

    static let dimmedMapOpacity = 0.3
    static let dimmedPanelOpacity = 0.45
}

/// 마우스·키를 장면에 그대로 넘기는 호스팅 뷰.
final class PlazaMinimapHostingView: NSHostingView<PlazaMinimapView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
