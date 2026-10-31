import SwiftUI
import AppKit

/// 광장 가운데에 뜨는 판. 내용이 없으면 아무것도 그리지 않는다.
@MainActor
struct PlazaOverlayView: View {
    let model: PlazaOverlayModel

    var body: some View {
        switch model.content {
        case .none:
            Color.clear
        case .board:
            // 소식판의 내용은 소식 작업이 이 자리에 채운다.
            panel { Color.clear }
        case .card(let state):
            panel { PlazaCardView(state: state) }
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(PlazaRosterMetrics.padding + 4)
            .frame(width: 340, height: 380)
            .background(PlazaRosterBackground())
    }
}

/// 열려 있을 때만 마우스(스크롤, 버튼)를 받는다. 키는 받지 않아 SKView가 첫 응답자를 유지한다.
final class PlazaOverlayHostingView: NSHostingView<PlazaOverlayView> {
    private let model: PlazaOverlayModel

    init(rootView: PlazaOverlayView, model: PlazaOverlayModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init(rootView: PlazaOverlayView) { fatalError("use init(rootView:model:)") }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        MainActor.assumeIsolated { model.content == .none ? nil : super.hitTest(point) }
    }
    override var acceptsFirstResponder: Bool { false }
}
