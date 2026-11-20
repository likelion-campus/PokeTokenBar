import Foundation

/// 단축키 안내판이 가리는 폭. 장면 카메라(불꽃이 터지는 자리)가 알아야 해서 공유 코드에 둔다(`PlazaRosterMetrics`와 같다).
/// 안내판 그림은 Mac의 `PlazaShortcutGuide`(SwiftUI)가 그린다.
enum PlazaShortcutGuideMetrics {
    /// 창 왼쪽 끝에서 펼친 안내판의 오른쪽 끝까지(포인트).
    static let coveredWidth: CGFloat = 130
}
