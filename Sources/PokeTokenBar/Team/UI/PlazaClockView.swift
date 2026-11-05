import SwiftUI
import AppKit

/// 작은 지도 위의 시계. 때(새벽·낮·저녁·밤)와 이 Mac의 시각을 1분마다 바꾼다.
@MainActor
struct PlazaClock: View {
    let model: PlazaMinimapModel

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(PlazaDaylight.clockText(context.date, core: model.coreTime))
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
        }
    }
}

/// 누를 것이 없어 마우스도 키도 받지 않는다. 아래의 장면이 그대로 받는다.
final class PlazaClockHostingView: NSHostingView<PlazaClock> {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
