import CoreGraphics
import Observation
import AppKit

/// 오른쪽 아래 작은 지도에 찍을 점과 지금 보이는 영역. 위치는 칸, 영역은 월드 픽셀이다.
@MainActor @Observable
final class PlazaMinimapModel {
    struct Dot: Equatable, Identifiable {
        let id: String
        let tile: TilePoint
        let color: CGColor
        let isMe: Bool
        let isAway: Bool
    }

    static let width: CGFloat = 192

    var dots: [Dot] = []
    var view: CGRect = .zero
    /// 팀이 정한 밝은 시간대. 지도의 색과 시계가 따른다.
    var coreTime = PlazaCoreTime.standard
    /// 광장에 떨어진 아이템의 칸.
    var item: TilePoint?
    /// 불이 켜져 있을 때 모닥불 자리의 왼쪽 위 칸. 꺼져 있으면 nil.
    var campfire: TilePoint?
    /// 눈 오는 날의 지도 그림. nil이면 평소 지도를 그린다.
    var seasonMapImage: NSImage?
}
