import CoreGraphics

/// 광장 카메라. 배율은 정수(화면 포인트 ÷ 월드 픽셀)이고 보이는 영역의 원점은 기기 픽셀에 맞춘다.
enum PlazaCamera {
    static let zoomRange = 1...3
    static let defaultZoom = 2

    static func clampedZoom(_ z: Int) -> Int {
        min(max(z, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// 보이는 영역(월드 픽셀, y 아래로). 크기 = 뷰포트 포인트 ÷ zoom.
    /// 지도보다 작은 축은 focus를 가운데 두되 지도 밖이 보이지 않게 [0, world - size]로 자른다.
    /// 지도보다 큰 축은 지도를 가운데 둔다(origin = (world - size) / 2, 음수 가능).
    /// origin은 기기 픽셀 한 칸(1 / (zoom × backingScale) 월드 픽셀) 단위로 반올림한다.
    static func visibleRect(focus: CGPoint, viewport: CGSize, zoom: Int, backingScale: CGFloat, world: CGSize) -> CGRect {
        let z = CGFloat(clampedZoom(zoom))
        let step = 1 / (z * max(backingScale, 1))
        let size = CGSize(width: viewport.width / z, height: viewport.height / z)
        func origin(_ focus: CGFloat, _ size: CGFloat, _ world: CGFloat) -> CGFloat {
            let raw = size >= world ? (world - size) / 2 : min(max(focus - size / 2, 0), world - size)
            return (raw / step).rounded() * step
        }
        return CGRect(x: origin(focus.x, size.width, world.width),
                      y: origin(focus.y, size.height, world.height),
                      width: size.width, height: size.height)
    }
}

extension PlazaCamera {
    /// 오른쪽 rightInset 포인트가 가려질 때, 내 포켓몬이 보이는 영역 가운데 오도록 초점을 오른쪽으로 민다.
    static func focus(for foot: CGPoint, rightInset: CGFloat, zoom: Int) -> CGPoint {
        CGPoint(x: foot.x + (rightInset / CGFloat(clampedZoom(zoom))) / 2, y: foot.y)
    }
}
