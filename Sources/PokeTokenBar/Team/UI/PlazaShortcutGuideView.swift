import SwiftUI
import AppKit

/// 왼쪽 위 배경 숨기기 아래의 단축키 안내. 팀원 옆이 아니어도 늘 보인다.
@MainActor
struct PlazaShortcutGuide: View {
    /// 글자 키와 하는 일. 장면이 keyCode로 받는 Z, X, C와 같아야 한다.
    static var entries: [(key: String, label: String)] {
        let l = L(.ko)
        return [("Z", l.plazaJump), ("X", l.plazaMenuGreet), ("C", l.plazaMenuTackle)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.entries, id: \.key) { entry in
                HStack(spacing: 6) {
                    Text(entry.key)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1))
                    Text(entry.label)
                }
            }
        }
        .font(Font(PlazaResources.font(.small)))
        .foregroundStyle(Color(hex: 0xF8F8F0))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1D4F5C).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1.5))
    }
}

/// 누를 것이 없어 마우스도 키도 받지 않는다. 아래의 장면이 그대로 받는다.
final class PlazaShortcutGuideHostingView: NSHostingView<PlazaShortcutGuide> {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
