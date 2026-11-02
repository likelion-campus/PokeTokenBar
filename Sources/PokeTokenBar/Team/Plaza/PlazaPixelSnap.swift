import CoreGraphics

/// 광장 노드를 기기 픽셀 격자에 맞추는 순수 계산.
/// 노드가 가운데 기준(anchor 0.5)이면 가운데만 맞춰서는 안 된다. 기기 픽셀 폭이 홀수일 때 왼쪽 가장자리가 .5에 놓여
/// nearest 필터가 열을 빼거나 겹쳐 그린다. 그래서 왼쪽 가장자리를 맞춘 뒤 폭의 절반을 더해 가운데를 구한다.
enum PlazaPixelSnap {
    /// 월드 좌표에서 기기 픽셀 한 칸의 크기.
    static func step(backing: CGFloat, zoom: Int) -> CGFloat {
        1 / (CGFloat(PlazaCamera.clampedZoom(zoom)) * max(backing, 1))
    }

    static func snap(_ v: CGFloat, backing: CGFloat, zoom: Int) -> CGFloat {
        let s = step(backing: backing, zoom: zoom)
        return (v / s).rounded() * s
    }

    /// 가운데 기준 노드의 가운데 x(월드). 왼쪽 가장자리가 기기 격자에 놓인다.
    static func centerX(footX: CGFloat, width: CGFloat, backing: CGFloat, zoom: Int) -> CGFloat {
        snap(footX - width / 2, backing: backing, zoom: zoom) + width / 2
    }

    /// 카메라 공간(화면 포인트, 뷰포트 가운데가 원점)에 둘 이름판 위치. 아래 가운데 기준(anchor 0.5, 0)이다.
    /// 홀수 크기 뷰포트는 가운데가 반 픽셀이라 뷰포트 반 크기를 더해 왼쪽·아래 가장자리를 맞춘 뒤 다시 뺀다.
    static func platePosition(footSceneX: CGFloat, topY: CGFloat, cameraPos: CGPoint, plateWidth: CGFloat,
                              viewport: CGSize, backing: CGFloat, zoom: Int) -> CGPoint {
        let z = CGFloat(PlazaCamera.clampedZoom(zoom))
        let b = max(backing, 1)
        func snapView(_ v: CGFloat) -> CGFloat { (v * b).rounded() / b }
        let halfW = viewport.width / 2, halfH = viewport.height / 2
        let left = snapView((footSceneX - cameraPos.x) * z - plateWidth / 2 + halfW) - halfW
        let y = snapView((topY - cameraPos.y) * z + 1 + halfH) - halfH
        return CGPoint(x: left + plateWidth / 2, y: y)
    }
}
