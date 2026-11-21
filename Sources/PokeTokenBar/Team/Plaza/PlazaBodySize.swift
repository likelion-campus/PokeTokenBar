import Foundation

/// 몸 크기 등급 규칙(명세 6). SpriteKit과 무관한 순수 규칙이다.
enum PlazaBodySize {
    // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let classes = 1...3
    /// s = 잘라낸 앞 프레임의 긴 변 × `PlazaActor.characterScale`(월드 px). s < 80 → 1, 80 ≤ s < 120 → 2, s ≥ 120 → 3.
    static let class2From: CGFloat = 80
    static let class3From: CGFloat = 120
    /// 등급 1, 2, 3의 몸이 발 기준 옆으로 w칸, 위로 h칸 더 차지한다.
    static let spans: [(w: Int, h: Int)] = [(0, 0), (1, 1), (1, 2)]

    static func size(longSide s: CGFloat) -> Int {
        s >= class3From ? 3 : (s >= class2From ? 2 : 1)
    }

    /// 보이는 앞 프레임으로 잰 등급. 알과 회색 자리표시자는 nil(재지 않는다). 뒷모습은 보지 않는다.
    @MainActor static func size(of frames: PlazaCharacterFrames) -> Int? {
        if frames.isEgg || frames.isPlaceholder { return nil }
        let longest = frames.front.map { max($0.image.width, $0.image.height) }.max() ?? 0
        return size(longSide: CGFloat(longest) * PlazaActor.characterScale)
    }

    /// 받은 값(없음·범위 밖 포함)을 1...3 으로. `TeamEmote.pushTiles` 와 같은 방식.
    static func clamped(_ received: Int?) -> Int {
        min(max(received ?? 1, classes.lowerBound), classes.upperBound)
    }

    /// 선로 위 값: 1은 보내지 않는다.
    static func sent(_ size: Int) -> Int? {
        let n = clamped(size)
        return n > 1 ? n : nil
    }

    static func span(_ size: Int) -> (w: Int, h: Int) { spans[clamped(size) - 1] }
}

/// 발 칸과 등급으로 정해지는 몸. 등급 1은 발 한 칸뿐이라 예전 한 칸 규칙과 같다.
struct PlazaBody: Equatable, Sendable {
    var foot: TilePoint
    var size: Int

    /// 옆과 위로만 자란다. 발 아래는 덮지 않는다.
    func covers(_ t: TilePoint) -> Bool {
        let s = PlazaBodySize.span(size)
        return t.x >= foot.x - s.w && t.x <= foot.x + s.w && t.y >= foot.y - s.h && t.y <= foot.y
    }

    /// 두 몸의 어떤 칸이 같거나 상하좌우로 붙어 있다(대각선은 닿지 않는다). 대칭이다.
    /// 두 직사각형 사이의 맨해튼 거리가 1 이하일 때다.
    func touches(_ o: PlazaBody) -> Bool {
        let a = PlazaBodySize.span(size), b = PlazaBodySize.span(o.size)
        let gapX = max(foot.x - a.w - (o.foot.x + b.w), o.foot.x - b.w - (foot.x + a.w), 0)
        let gapY = max(foot.y - a.h - o.foot.y, o.foot.y - b.h - foot.y, 0)
        return gapX + gapY <= 1
    }
}
