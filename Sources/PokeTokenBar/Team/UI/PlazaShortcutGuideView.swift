import SwiftUI
import AppKit

/// 왼쪽 위 배경 숨기기 아래의 단축키 안내. 머리줄을 누르면 접히고 펼쳐진다. 누른 뒤에도 키는 장면이 받는다.
@MainActor
struct PlazaShortcutGuide: View {
    /// 키와 하는 일. 장면이 받는 키와 같아야 한다.
    static var entries: [(key: String, label: String)] {
        let l = L(.ko)
        return [
            (l.plazaShortcutArrows, l.plazaShortcutWalk), ("Shift", l.plazaShortcutRun), ("Space", l.plazaShortcutTalk),
            ("Enter", l.plazaShortcutChat), ("1–5", l.plazaShortcutEmotes), ("Z", l.plazaJump),
            ("X", l.plazaMenuGreet), ("C", l.plazaMenuTackle), ("P", l.plazaShortcutPhoto), ("G", l.plazaShortcutGroupPhoto),
            ("−/+", l.plazaShortcutZoom),
        ]
    }

    let model: PlazaShortcutGuideModel
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Text(L(.ko).plazaShortcutsTitle)
                    Image(systemName: model.isFolded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            if !model.isFolded {
                ForEach(Self.entries, id: \.key) { entry in
                    HStack(spacing: 6) {
                        Text(entry.key)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.15)))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1))
                        Text(entry.label)
                    }
                    .fixedSize()   // 키 이름이 "Spa…"처럼 잘리지 않게 한다.
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

@MainActor @Observable
final class PlazaShortcutGuideModel {
    var isFolded = false
}

/// 머리줄 단추만 누를 수 있다. 키는 받지 않아 장면이 첫 응답자를 유지한다.
final class PlazaShortcutGuideHostingView: NSHostingView<PlazaShortcutGuide> {
    override var acceptsFirstResponder: Bool { false }
}
