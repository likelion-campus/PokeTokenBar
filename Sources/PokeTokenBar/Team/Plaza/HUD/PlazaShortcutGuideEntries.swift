import Foundation

/// The shortcut guide's rows and the width it covers (shared data; the guide is drawn by `PlazaShortcutGuidePanel`).
enum PlazaShortcutGuide {
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
}
