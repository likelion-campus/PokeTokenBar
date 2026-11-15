import Foundation

// Moved verbatim from the Mac-only PlazaCardView.swift (Track A Task 17d): the card panel is shared.
/// 카드 판과 그림 크기. 그림은 원본 도트의 1.5배라 Retina 화면에서 도트 하나가 고르게 3픽셀이 된다(광장 캐릭터와 같은 배율).
enum PlazaCardMetrics {
    static let panelSize = CGSize(width: 380, height: 460)
    static let panelInset = PlazaRosterMetrics.padding + 4
    /// 광장 캐릭터. PokéAPI 앞모습(96픽셀)의 1.5배.
    static let spriteSide: CGFloat = 144
    /// 도감 칸의 박스 아이콘. 원본(40x30)의 1.5배.
    static let iconSize = CGSize(width: 60, height: 45)
    /// 아이콘 아래에 이름 한 줄(작은 글자)이 들어간다.
    static let cellSize = CGSize(width: 64, height: 66)
    static let columns = 5
    static let spacing: CGFloat = 4
    /// 오늘 광장 칸: 제목, 두 열 네 줄, 위아래 여백. 줄 수가 달라도 고정이다.
    static let activityRowHeight: CGFloat = 16
    static let activityTitleHeight: CGFloat = 18
    static let activityPadding: CGFloat = 8
    static let activityHeight: CGFloat = activityPadding + activityTitleHeight + 4 * activityRowHeight + activityPadding
    /// 카드 안쪽 세로 간격(머리, 오늘 광장 칸, 도감 격자 사이).
    static let stackSpacing: CGFloat = 8
}
