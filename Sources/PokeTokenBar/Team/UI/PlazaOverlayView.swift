import SwiftUI
import AppKit

/// 광장 가운데에 뜨는 판. 내용이 없으면 아무것도 그리지 않는다.
@MainActor
struct PlazaOverlayView: View {
    let model: PlazaOverlayModel

    var body: some View {
        ZStack(alignment: .top) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .none:
            Color.clear
        case .board:
            Color.clear   // the board is the shared `PlazaBoardPanel`
        case .card(let state):
            panel(PlazaCardMetrics.panelSize) { PlazaCardView(state: state) }
        case .memberMenu, .campfireMenu:
            Color.clear   // the menus and their tap-outside area are the shared `PlazaMenuPanel`
        }
    }

    private func panel<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(PlazaCardMetrics.panelInset)
            .frame(width: size.width, height: size.height)
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
        MainActor.assumeIsolated {
            switch model.content {
            case .none, .board, .memberMenu, .campfireMenu: nil   // the board and the menus are panels (their own host takes the clicks)
            case .card: super.hitTest(point)
            }
        }
    }
    override var acceptsFirstResponder: Bool { false }
}
