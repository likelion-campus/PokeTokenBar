import SpriteKit

/// 불꽃 조각 그림. 새로 그리지 않고 광장의 반짝임과 눈송이 그림에 색만 바꿔 입힌다. 색도 날씨와 말풍선에 이미 있는 색이다.
enum PlazaFireworkArt {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    /// 그림 한 칸의 월드 픽셀. 타일 그림의 점 크기와 같다.
    static let cell = 2
    private static let core: RGB = (0xF6, 0xFA, 0xFF)

    private static func edge(_ color: PlazaFireworkColor) -> RGB {
        switch color {
        case .gold: (0xF2, 0xC2, 0x30)
        case .red: (0xD1, 0x43, 0x2E)
        case .blue: (0x3B, 0x82, 0xF6)
        case .pink: (0xE8, 0x8D, 0xAC)
        case .mint: (0x2F, 0xB8, 0xA6)
        }
    }

    private static func tail(_ color: PlazaFireworkColor) -> RGB {
        switch color {
        case .gold: (0xE8, 0x83, 0x2A)
        case .red: (0x96, 0x2A, 0x1C)
        case .blue: (0x9C, 0xC0, 0xEE)
        case .pink: (0xF8, 0xBB, 0xCF)
        case .mint: (0xB9, 0xF2, 0xE4)
        }
    }

    /// 칸당 1픽셀 그림. 화면은 `cell`배로 키운다.
    static func image(_ glyph: PlazaFireworkGlyph) -> CGImage {
        let flakes = PlazaWeatherArt.grids(.snow), edge = edge(glyph.color), tail = tail(glyph.color)
        return switch glyph.shape {
        case .spark: PlazaWeatherArt.image(PlazaEmoteArt.spark, palette: ["W": core, "Y": edge])
        case .plus: PlazaWeatherArt.image(flakes[0], palette: ["W": edge])
        case .dot: PlazaWeatherArt.image(flakes[1], palette: ["W": tail, "S": tail])
        case .ember(let n): PlazaWeatherArt.image(flakes[2], palette: ["W": [core, edge, tail][min(n, 2)]])
        }
    }
}

/// 불꽃을 그리는 노드. 시간은 `advance`가 준 간격으로만 흘러 창이 멈추면 불꽃도 멈추고, 타이머는 없다.
/// 스프라이트는 재사용하고 조각 수는 상한을 넘지 않는다. 빛은 곱해져 겹치면 땅이 낮보다 밝아지므로 한 번에 하나만 켠다.
@MainActor final class PlazaFireworkLayer: SKNode {
    /// 하늘에 함께 있을 수 있는 팀원 불꽃의 조각 수. 넘으면 그 발은 터뜨리지 않는다.
    static let maxPieces = 200
    /// 터지는 동안 낮을 밤 색으로 섞는 정도.
    static let dimStrength = 0.7
    /// 어두워지고 밝아지는 데 걸리는 박자 수.
    private static let dimBeats = 3.0

    private struct Burst {
        let style: PlazaFireworkStyle
        let center: CGPoint
        let rise: CGFloat
        /// 쏜 팀원. 나는 nil.
        let owner: String?
        let launchedAt: TimeInterval
    }

    private struct Shown {
        let image: CGImage
        let position: CGPoint
        let size: CGSize
    }

    private struct Light {
        let center: CGPoint
        let color: PlazaFireworkColor
        let level: Double
    }

    private struct Look: Hashable {
        let color: PlazaFireworkColor
        let level: Double
    }

    private var bursts: [Burst] = []
    private var sprites: [SKSpriteNode] = []
    private lazy var lightNode: SKSpriteNode = {
        let node = SKSpriteNode()
        node.blendMode = .multiplyX2
        node.zPosition = -1   // 조각(7) 아래, 모닥불빛과 같은 6에서 낮밤 색 위에 곱한다.
        node.isHidden = true
        addChild(node)
        return node
    }()
    private var images: [PlazaFireworkGlyph: CGImage] = [:]
    private var textures: [PlazaFireworkGlyph: SKTexture] = [:]
    /// 빛 텍스처. 지금 낮밤 색 하나에 대해서만 쌓고, 색이 바뀌면 비운다.
    private var lightTextures: (tint: [Int], byLook: [Look: SKTexture])?
    private var shown: [Shown] = []
    private var light: Light?
    private var clock: TimeInterval = 0
    private var drawnBeat = -1
    /// 낮을 어둡게 하는 정도. 0이면 그대로다.
    private(set) var dimLevel = 0.0

    var isActive: Bool { !bursts.isEmpty || dimLevel > 0 }

    /// 팀원의 불꽃은 조각이 상한을 넘으면 터뜨리지 않고 false. 내 불꽃은 한 번에 한 발뿐이라 상한을 보지 않아,
    /// 하늘이 가득해도 F가 먹히고 조각 수는 상한에 한 발을 더한 값을 넘지 않는다.
    @discardableResult
    func launch(_ style: PlazaFireworkStyle, at burst: CGPoint, rise: CGFloat = PlazaFireworks.riseRange.upperBound,
                owner: String? = nil) -> Bool {
        let inAir = bursts.reduce(0) { $0 + $1.style.pieces.count }
        guard owner == nil || inAir + style.pieces.count <= Self.maxPieces else { return false }
        bursts.append(Burst(style: style, center: burst, rise: rise, owner: owner, launchedAt: clock))
        drawnBeat = -1
        return true
    }

    /// 그 사람의 불꽃이 아직 끝나지 않았다.
    func isFiring(owner: String?) -> Bool { bursts.contains { $0.owner == owner } }

    /// `tint`는 지금 곱하는 낮밤 색으로, 어두울 때만 빛이 켜진다. `firelight`는 그 자리(장면 좌표)에 이미 닿은 모닥불빛(0~1)이다.
    func advance(by dt: TimeInterval, tint: PlazaDaylight.Tint = .none, firelight: (CGPoint) -> Double = { _ in 0 }) {
        guard isActive else { return }
        clock += dt
        bursts.removeAll { clock - $0.launchedAt >= PlazaFireworks.riseDuration + $0.style.duration }
        let beat = Int(clock / PlazaFireworks.beat)
        guard beat != drawnBeat else { return }
        moveDim(beats: drawnBeat < 0 ? 1 : beat - drawnBeat)
        drawnBeat = beat
        draw(at: Double(beat) * PlazaFireworks.beat, tint: tint, firelight: firelight)
    }

    private func moveDim(beats: Int) {
        let step = Self.dimStrength / Self.dimBeats * Double(beats)
        dimLevel = bursts.isEmpty ? max(dimLevel - step, 0) : min(dimLevel + step, Self.dimStrength)
    }

    private func draw(at time: TimeInterval, tint: PlazaDaylight.Tint, firelight: (CGPoint) -> Double) {
        shown = []
        light = nil
        for burst in bursts {
            let age = time - burst.launchedAt - PlazaFireworks.riseDuration
            if age < 0 { addShell(burst, age: age) }
            for piece in burst.style.pieces {
                guard let glyph = piece.glyph(at: age), let offset = piece.offset(at: age) else { continue }
                add(glyph, at: CGPoint(x: burst.center.x + offset.dx, y: burst.center.y + offset.dy))
            }
            // 가장 밝은 불꽃 하나만 빛난다. 모닥불빛이 닿은 땅은 남은 만큼만 밝혀 두 빛이 겹쳐도 낮을 넘지 않는다.
            let level = PlazaFireworks.lightLevel(age: age, duration: burst.style.duration) * (1 - firelight(burst.center))
            if level > 0, level >= light?.level ?? 0, PlazaCampfireLight.strength(tint) > 0 {
                light = Light(center: burst.center, color: burst.style.shell, level: level)
            }
        }
        for node in sprites.dropFirst(shown.count) { node.isHidden = true }
        placeLight(tint: tint)
    }

    /// 터질 자리로 곧장 올라가며 점점 느려지는 포탄과 꼬리 두 점.
    private func addShell(_ burst: Burst, age: TimeInterval) {
        let progress = min(max(1 + age / PlazaFireworks.riseDuration, 0), 1)
        let climbed = 1 - (1 - progress) * (1 - progress)
        for n in 0..<3 {
            let height = burst.rise * (1 - CGFloat(max(climbed - Double(n) * 0.07, 0)))
            add(PlazaFireworkGlyph(shape: .ember(n), color: burst.style.shell), at: CGPoint(x: burst.center.x, y: burst.center.y - height))
        }
    }

    /// 그림 가운데를 `center`에 맞추되 타일 그림의 점 격자에 올린다. 격자에서 벗어나면 조각이 흔들려 보인다.
    private func add(_ glyph: PlazaFireworkGlyph, at center: CGPoint) {
        let image = image(glyph), cell = CGFloat(PlazaFireworkArt.cell)
        let size = CGSize(width: CGFloat(image.width) * cell, height: CGFloat(image.height) * cell)
        let position = CGPoint(x: ((center.x - size.width / 2) / cell).rounded() * cell,
                               y: ((center.y - size.height / 2) / cell).rounded() * cell)
        shown.append(Shown(image: image, position: position, size: size))
        let node = sprite(shown.count - 1)
        node.texture = textures[glyph]
        node.size = size
        node.position = position
        node.isHidden = false
    }

    private func image(_ glyph: PlazaFireworkGlyph) -> CGImage {
        if let image = images[glyph] { return image }
        let image = PlazaFireworkArt.image(glyph)
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        images[glyph] = image
        textures[glyph] = texture
        return image
    }

    private func sprite(_ index: Int) -> SKSpriteNode {
        if index < sprites.count { return sprites[index] }
        let node = SKSpriteNode()
        node.anchorPoint = .zero
        addChild(node)
        sprites.append(node)
        return node
    }

    private func placeLight(tint: PlazaDaylight.Tint) {
        guard let light else { lightNode.isHidden = true; return }
        let key = [tint.red, tint.green, tint.blue].map { Int(($0 * 256).rounded()) }
        if lightTextures?.tint != key { lightTextures = (key, [:]) }
        let radii = PlazaFireworks.lightRadii, counts = PlazaCampfireLight.blockCounts(radii: radii)
        let look = Look(color: light.color, level: light.level)
        if lightTextures?.byLook[look] == nil {
            let rounded = PlazaDaylight.Tint(red: Double(key[0]) / 256, green: Double(key[1]) / 256, blue: Double(key[2]) / 256)
            lightTextures?.byLook[look] = PlazaScene.lightTexture(tint: rounded, radii: radii, color: light.color.light, level: light.level)
        }
        let cell = CGFloat(PlazaFireworkArt.cell)
        lightNode.texture = lightTextures?.byLook[look]
        lightNode.size = CGSize(width: counts.w * 2, height: counts.h * 2)
        lightNode.position = CGPoint(x: (light.center.x / cell).rounded() * cell, y: (light.center.y / cell).rounded() * cell)
        lightNode.isHidden = false
    }

    /// 지금 보이는 조각을 기념사진 좌표(월드, y 아래로)로 돌려준다.
    func photoParticles(worldHeight: CGFloat) -> [PlazaPhotoParticle] {
        shown.map {
            PlazaPhotoParticle(image: $0.image, origin: CGPoint(x: $0.position.x, y: worldHeight - $0.position.y - $0.size.height),
                               size: $0.size)
        }
    }

    func photoLight(tint: PlazaDaylight.Tint, worldHeight: CGFloat) -> PlazaPhotoLight? {
        light.map {
            PlazaPhotoLight(center: CGPoint(x: $0.center.x, y: worldHeight - $0.center.y), radii: PlazaFireworks.lightRadii, tint: tint,
                            color: $0.color.light, level: $0.level)
        }
    }

    /// 테스트용
    var shownCount: Int { sprites.filter { !$0.isHidden }.count }
    var shownLightCount: Int { !lightNode.isHidden && lightNode.texture != nil ? 1 : 0 }
    var shownPositions: [CGPoint] { sprites.filter { !$0.isHidden }.map(\.position) }
    var styleIDs: [String] { bursts.map(\.style.id) }
}
