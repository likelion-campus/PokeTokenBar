import SpriteKit

/// 날씨 입자를 그리는 노드. 입자는 재사용하는 스프라이트라 날씨 종류나 입자 수가 바뀔 때만 만든다.
/// 시간은 `update`가 준 간격으로만 흘러 창이 멈추면 입자도 멈추고, 타이머는 없다.
@MainActor final class PlazaWeatherLayer: SKNode {
    private(set) var kind = PlazaWeather.Kind.clear
    private var field: PlazaWeatherField?
    private var images: [CGImage] = []
    private var textures: [SKTexture] = []
    private var sprites: [SKSpriteNode] = []
    /// 오늘의 날씨. 날이 바뀔 때까지 달력을 다시 계산하지 않는다.
    private var day: (interval: DateInterval, period: PlazaWeather.Period, kind: PlazaWeather.Kind)?

    /// `visible`은 보이는 영역(장면 좌표)이고, `step`은 기기 픽셀 하나의 월드 크기. 숨기면 입자를 걷는다.
    func update(date: Date, isHidden: Bool, dt: TimeInterval, period: PlazaWeather.Period = .day, visible: CGRect, step: CGFloat) {
        let wanted = isHidden ? PlazaWeather.Kind.clear : kind(at: date, period: period)
        let count = PlazaWeather.count(wanted, area: visible.width * visible.height)
        if wanted != kind || count != sprites.count { rebuild(wanted, count: count, visible: visible) }
        field?.advance(by: dt, in: visible)
        place(step: step)
    }

    private func kind(at date: Date, period: PlazaWeather.Period) -> PlazaWeather.Kind {
        // DateInterval.contains 는 끝을 포함해 자정 0시가 어제로 읽힌다. 끝은 빼고 비교한다.
        if let day, day.period == period, date >= day.interval.start, date < day.interval.end { return day.kind }
        var calendar = Calendar(identifier: .gregorian)   // 일본력·불기여도 날씨는 같아야 한다
        calendar.timeZone = .current
        let k = PlazaWeather.kind(on: date, calendar: calendar, period: period)
        day = calendar.dateInterval(of: .day, for: date).map { ($0, period, k) }
        return k
    }

    private func rebuild(_ wanted: PlazaWeather.Kind, count: Int, visible: CGRect) {
        if wanted != kind {
            kind = wanted
            images = PlazaWeatherArt.images(wanted)
            textures = images.map {
                let t = SKTexture(cgImage: $0)
                t.filteringMode = .nearest
                return t
            }
        }
        removeAllChildren()
        sprites = []
        guard count > 0 else { field = nil; return }
        let f = PlazaWeatherField(kind: wanted, count: count, in: visible)
        sprites = f.particles.map { p in
            let node = SKSpriteNode(texture: textures[p.variant], size: CGSize(width: images[p.variant].width, height: images[p.variant].height))
            node.anchorPoint = .zero
            addChild(node)
            return node
        }
        field = f
    }

    /// 입자를 기기 픽셀 격자에 맞춘다. 격자에서 벗어나면 최근접 보간이 열을 빼거나 겹쳐 그린다.
    private func place(step: CGFloat) {
        guard let particles = field?.particles else { return }
        for (node, p) in zip(sprites, particles) {
            node.position = CGPoint(x: (CGFloat(p.x) / step).rounded() * step, y: (CGFloat(p.y) / step).rounded() * step)
        }
    }

    /// 지금 화면에 있는 입자를 기념사진 좌표(월드, y 아래로)로 돌려준다.
    func photoParticles(worldHeight: CGFloat) -> [PlazaPhotoParticle] {
        guard let particles = field?.particles else { return [] }
        return zip(sprites, particles).map { node, p in
            PlazaPhotoParticle(image: images[p.variant],
                               origin: CGPoint(x: node.position.x, y: worldHeight - node.position.y - node.size.height),
                               size: node.size)
        }
    }

    /// 테스트용
    var particleCount: Int { sprites.count }
    var particlePositions: [CGPoint] { sprites.map(\.position) }
}
