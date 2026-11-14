import SwiftUI
import AppKit

/// 왼쪽 위 배경 숨기기 아래의 단축키 안내. 머리줄을 누르면 접히고 펼쳐진다. 누른 뒤에도 키는 장면이 받는다.
@MainActor
struct PlazaShortcutGuide: View {
    /// 키와 하는 일. 장면이 받는 키와 같아야 한다.
    static var entries: [(key: String, label: String)] { entries(season: .winter) }

    /// C 바로 뒤의 V는 계절마다 던지는 것이 다르다(눈뭉치, 꽃잎 뭉치, 물풍선, 낙엽 뭉치).
    static func entries(season: PlazaSeason) -> [(key: String, label: String)] {
        let l = L(.ko)
        var rows: [(key: String, label: String)] = [
            (l.plazaShortcutArrows, l.plazaShortcutWalk), ("Shift", l.plazaShortcutRun), ("Space", l.plazaShortcutTalk),
            ("Enter", l.plazaShortcutChat), ("1–5", l.plazaShortcutEmotes), ("Z", l.plazaJump),
            ("X", l.plazaMenuGreet), ("C", l.plazaMenuTackle), ("D", l.plazaShortcutDance), ("F", l.plazaShortcutFirework), ("P", l.plazaShortcutPhoto), ("G", l.plazaShortcutGroupPhoto),
            ("A", l.plazaShortcutPray), ("−/+", l.plazaShortcutZoom),
        ]
        if let c = rows.firstIndex(where: { $0.key == "C" }) { rows.insert(("V", l.plazaShortcutThrow(season)), at: c + 1) }
        return rows
    }

    /// 창 왼쪽 끝에서 펼친 안내판의 오른쪽 끝까지(포인트). 장면도 읽으므로 값은 공유 코드에 있다.
    static let coveredWidth: CGFloat = PlazaShortcutGuideMetrics.coveredWidth

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
                ForEach(Self.entries(season: model.season), id: \.key) { entry in
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

/// 머리줄 단추만 누를 수 있다. 키는 받지 않아 장면이 첫 응답자를 유지한다.
final class PlazaShortcutGuideHostingView: NSHostingView<PlazaShortcutGuide> {
    override var acceptsFirstResponder: Bool { false }
}
