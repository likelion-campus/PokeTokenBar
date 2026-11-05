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

    var body: some View {
        ZStack(alignment: .top) {
            content
            if model.isPhotoMode { photoFrame }
            VStack(spacing: 8) {
                if let countdown = model.countdown {
                    Text(countdown)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color(hex: 0x1D4F55).opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xF2C14E), lineWidth: 2))
                        .allowsHitTesting(false)
                }
                if let banner = model.banner {
                    Text(banner)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: 360)
                        .background(Color(hex: 0x1D4F55).opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x5FB7BD), lineWidth: 2))
                        .allowsHitTesting(false)
                }
                if let hint = model.hint {
                    Text(hint)
                        .font(Font(PlazaResources.font(.body)))
                        .foregroundStyle(Color(hex: 0xF8F8F0))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
                        .allowsHitTesting(false)
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

    /// 사진 모드의 틀. 사진에 담기는 영역은 창에서 여백(포인트)을 뺀 사각형이다. 아무것도 클릭을 받지 않는다.
    private var photoFrame: some View {
        GeometryReader { geo in
            let frame = CGRect(x: PlazaPhotoFrame.sideInset, y: PlazaPhotoFrame.topInset,
                               width: geo.size.width - 2 * PlazaPhotoFrame.sideInset,
                               height: geo.size.height - PlazaPhotoFrame.topInset - PlazaPhotoFrame.bottomInset)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Path { p in
                    // 선이 틀 안쪽에 놓이도록 선 두께의 절반만큼 들여 그린다.
                    let arm = PlazaPhotoFrame.bracketArm, h = PlazaPhotoFrame.bracketWidth / 2
                    let r = frame.insetBy(dx: h, dy: h)
                    for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                             (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                        p.addLine(to: corner)
                        p.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: PlazaPhotoFrame.bracketWidth, lineCap: .butt, lineJoin: .miter))
                Text(L(.ko).plazaPhotoGuide)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: frame.width, height: PlazaPhotoFrame.bottomInset, alignment: .center)
                    .position(x: geo.size.width / 2, y: geo.size.height - PlazaPhotoFrame.bottomInset / 2)
            }
        }
        .allowsHitTesting(false)
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
