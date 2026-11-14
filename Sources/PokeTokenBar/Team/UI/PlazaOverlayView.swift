import SwiftUI
import AppKit

/// 광장 가운데에 뜨는 판. 내용이 없으면 아무것도 그리지 않는다.
@MainActor
struct PlazaOverlayView: View {
    let model: PlazaOverlayModel
    var feed: TeamFeedStore?
    var myMemberID = ""
    var onReact: (_ eventID: String, _ kind: TeamReactionKind) -> Void = { _, _ in }
    var onMenuChoose: (_ action: PlazaMemberAction, _ memberID: String) -> Void = { _, _ in }
    /// 메뉴 밖을 눌렀다.
    var onMenuCancel: () -> Void = {}
    var onCampfireChoose: (_ index: Int) -> Void = { _ in }
    /// The countdown, banner and hint pills' stack (the shared `PlazaPillsPanel`, drawn above this view). A menu still
    /// opens below them, so the stack keeps their room.
    var pillsSize: () -> CGSize = { .zero }

    var body: some View {
        ZStack(alignment: .top) {
            content
            VStack(spacing: 8) {
                let pills = pillsSize()
                if pills.height > 0 {
                    Color.clear.frame(width: pills.width, height: pills.height).allowsHitTesting(false)
                }
                // 안내가 있던 자리에 뜬다(메뉴가 열리면 안내는 숨는다).
                if case .memberMenu(let menu) = model.content {
                    PlazaMemberMenuView(menu: menu, onChoose: { onMenuChoose($0, menu.memberID) })
                }
                if case .campfireMenu(let menu) = model.content {
                    PlazaCampfireMenuView(menu: menu, onChoose: onCampfireChoose)
                }
            }
            .padding(.top, PlazaRosterMetrics.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .none:
            Color.clear
        case .board:
            panel(CGSize(width: 340, height: 380)) {
                if let feed { PlazaBoardView(feed: feed, myMemberID: myMemberID, onReact: onReact) }
            }
        case .card(let state):
            panel(PlazaCardMetrics.panelSize) { PlazaCardView(state: state) }
        case .memberMenu, .campfireMenu:
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: onMenuCancel)
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
        MainActor.assumeIsolated { model.content == .none ? nil : super.hitTest(point) }
    }
    override var acceptsFirstResponder: Bool { false }
}
