import SwiftUI
import AppKit

/// 광장 왼쪽 아래 대화 기록. 표시만 하고 입력은 받지 않는다.
@MainActor
struct PlazaChatLogView: View {
    let log: PlazaChatLog

    var body: some View {
        let lines = log.visible
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines) { line in
                (Text(PlazaChatLog.timeText(line.time) + " ").foregroundStyle(Color(hex: 0xF8F8F0).opacity(0.6))
                    + Text(line.name + ": ").foregroundStyle(Color(cgColor: line.color))
                    + Text(line.text).foregroundStyle(Color(hex: 0xF8F8F0)))
                    .font(Font(PlazaResources.font(size: 14)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: PlazaChatLog.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.8)))
        .opacity(lines.isEmpty ? 0 : 1)
    }
}

/// 마우스·키를 장면에 그대로 넘기는 호스팅 뷰.
final class PlazaChatLogHostingView: NSHostingView<PlazaChatLogView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
