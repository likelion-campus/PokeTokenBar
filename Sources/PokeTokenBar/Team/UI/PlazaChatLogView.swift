import SwiftUI
import AppKit

/// 광장 왼쪽 아래 대화 기록. 접으면 마지막 몇 줄, 펼치면 담아 둔 줄을 모두 스크롤해서 본다.
@MainActor
struct PlazaChatLogView: View {
    let log: PlazaChatLog
    var toggle: () -> Void = {}

    var body: some View {
        let l = L(.ko)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l.plazaChatLogTitle).opacity(0.6)
                Spacer()
                Button(log.isExpanded ? l.plazaChatLogCollapse : l.plazaChatLogExpand, action: toggle)
                    .buttonStyle(.plain).focusable(false)
            }
            .font(Font(PlazaResources.font(.small)))
            .foregroundStyle(Color(hex: 0xF8F8F0))
            if log.isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(log.lines) { lineView($0).id($0.id) }
                        }
                    }
                    .frame(height: PlazaChatLog.expandedHeight)
                    .onAppear { proxy.scrollTo(log.lines.last?.id, anchor: .bottom) }
                    .onChange(of: log.lines.last?.id) { _, id in proxy.scrollTo(id, anchor: .bottom) }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(log.visible) { lineView($0) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: PlazaChatLog.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.8)))
        .opacity(log.lines.isEmpty ? 0 : 1)
    }

    private func lineView(_ line: PlazaChatLog.Line) -> some View {
        (Text(PlazaChatLog.timeText(line.time) + " ").foregroundStyle(Color(hex: 0xF8F8F0).opacity(0.6))
            + Text(line.isLoud ? "📢 " : "")
            + Text(line.name + ": ").foregroundStyle(Color(plaza: line.color))
            + Text(line.text).foregroundStyle(line.isLoud ? Color(hex: 0xFFE060) : Color(hex: 0xF8F8F0)))
            .font(Font(PlazaResources.font(.body)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 기록이 있을 때만 마우스를 받는다(펼치기 단추와 스크롤). 키는 받지 않아 장면이 계속 받는다.
final class PlazaChatLogHostingView: NSHostingView<PlazaChatLogView> {
    private let log: PlazaChatLog

    init(rootView: PlazaChatLogView, log: PlazaChatLog) {
        self.log = log
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init(rootView: PlazaChatLogView) { fatalError("use init(rootView:log:)") }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        MainActor.assumeIsolated { log.lines.isEmpty ? nil : super.hitTest(point) }
    }
    override var acceptsFirstResponder: Bool { false }
}
