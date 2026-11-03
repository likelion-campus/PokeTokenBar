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
            .font(Font(PlazaResources.font(size: 12)))
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
            + Text(line.name + ": ").foregroundStyle(Color(cgColor: line.color))
            + Text(line.text).foregroundStyle(line.isLoud ? Color(hex: 0xFFE060) : Color(hex: 0xF8F8F0)))
            .font(Font(PlazaResources.font(size: 14)))
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

/// 왼쪽 위 배경 숨기기 단추. 누른 뒤에도 키는 장면이 받는다.
@MainActor
struct PlazaBackgroundToggle: View {
    let model: PlazaBackgroundModel
    let toggle: () -> Void

    var body: some View {
        let l = L(.ko)
        Button(action: toggle) {
            Label(model.isHidden ? l.plazaBackgroundShow : l.plazaBackgroundHide,
                  systemImage: model.isHidden ? "eye" : "eye.slash")
                .font(Font(PlazaResources.font(size: 12)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

@MainActor @Observable
final class PlazaBackgroundModel {
    var isHidden = false
}

final class PlazaBackgroundToggleHostingView: NSHostingView<PlazaBackgroundToggle> {
    override var acceptsFirstResponder: Bool { false }
}

/// 배경 숨기기 오른쪽의 이름 색 단추. 누르면 아래에 고를 색이 펼쳐지고, 하나를 누르면 그 색이 되고 접힌다.
/// 누른 뒤에도 키는 장면이 받는다.
@MainActor
struct PlazaNameColorPicker: View {
    static let columns = 6
    static let swatch: CGFloat = 20
    let model: PlazaNameColorModel
    let toggle: () -> Void
    let choose: (UInt32) -> Void

    var body: some View {
        let l = L(.ko)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: model.current)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(hex: 0x14161F), lineWidth: 1.5))
                    Text(l.plazaNameColor)
                }
                .font(Font(PlazaResources.font(size: 12)))
                .foregroundStyle(Color(hex: 0xF8F8F0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .focusable(false)
            if model.isOpen {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.swatch + 4), spacing: 4), count: Self.columns), spacing: 4) {
                    ForEach(Array(PlazaNameColor.hexes.enumerated()), id: \.offset) { i, hex in
                        Button { choose(hex) } label: {
                            Circle().fill(Color(hex: hex)).frame(width: Self.swatch, height: Self.swatch)
                                .overlay(Circle().stroke(Color(hex: 0x14161F), lineWidth: 1.5))
                                .padding(2)
                                .overlay(Circle().stroke(Color.white, lineWidth: hex == model.current ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel(l.plazaNameColorChoice(i + 1))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            }
        }
    }
}

@MainActor @Observable
final class PlazaNameColorModel {
    /// 지금 이름표 색(RGB). 고르지 않았으면 멤버 ID의 색.
    var current: UInt32 = PlazaNameColor.hexes[0]
    var isOpen = false
}

final class PlazaNameColorPickerHostingView: NSHostingView<PlazaNameColorPicker> {
    override var acceptsFirstResponder: Bool { false }
}
