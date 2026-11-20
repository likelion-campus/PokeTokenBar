import Foundation

/// 사진 모드의 촬영 틀 기하. 틀은 창에서 가장자리 여백(포인트)을 뺀 영역이고, 지도 밖으로 나가지 않는다.
/// 월드 픽셀(y 아래로)로 돌려준다. frame은 사진에 담기는 영역, visible은 여백까지 포함한 카메라 영역이다.
enum PlazaPhotoFrame {
    static let topInset: CGFloat = 24, sideInset: CGFloat = 24, bottomInset: CGFloat = 44   // 포인트
    static let panSpeed: CGFloat = 256, fastPanSpeed: CGFloat = 512                          // 월드 픽셀 / 초
    static let bracketArm: CGFloat = 18, bracketWidth: CGFloat = 3                           // 포인트

    struct Layout: Equatable {
        let frame: CGRect
        let visible: CGRect
        /// 지도 안으로 잘린 뒤의 frame 중심.
        let center: CGPoint
    }

    /// 뷰포트(포인트) 안에서 틀이 차지하는 사각형(왼쪽 위 원점, y 아래로). 여백이 뷰포트보다 커 틀이 없으면 nil.
    /// 장면의 `layout`과 화면 위 틀 그림이 같은 사각형을 쓰도록 기하는 여기 한 곳에만 둔다.
    static func viewRect(in viewport: CGSize) -> CGRect? {
        // CGRect.width는 음수를 절댓값으로 돌려주므로 여백을 뺀 크기를 먼저 따로 본다.
        let width = viewport.width - 2 * sideInset, height = viewport.height - topInset - bottomInset
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: sideInset, y: topInset, width: width, height: height)
    }

    /// center를 가운데 둔 틀. 창이 여백보다 작아 틀이 없으면 nil.
    /// visible = frame을 여백 ÷ zoom만큼 사방으로 키운 영역(크기 = 뷰포트 ÷ zoom).
    static func layout(center: CGPoint, viewport: CGSize, zoom: Int, backingScale: CGFloat, world: CGSize) -> Layout? {
        guard let inner = viewRect(in: viewport)?.size else { return nil }
        let z = CGFloat(PlazaCamera.clampedZoom(zoom))
        let frame = PlazaCamera.visibleRect(focus: center, viewport: inner, zoom: zoom, backingScale: backingScale, world: world)
        let visible = CGRect(x: frame.minX - sideInset / z, y: frame.minY - topInset / z,
                             width: frame.width + 2 * sideInset / z, height: frame.height + (topInset + bottomInset) / z)
        return Layout(frame: frame, visible: visible, center: CGPoint(x: frame.midX, y: frame.midY))
    }
}
