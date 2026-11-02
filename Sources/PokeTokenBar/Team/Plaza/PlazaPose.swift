import Foundation

struct PlazaSpriteChoice: Equatable, Sendable {
    let useBack: Bool
    let flipped: Bool
    let bob: Int
}

/// 방향과 걷는 상태에서 어떤 그림을 어떻게 그릴지 고른다. SpriteKit과 무관하다.
enum PlazaPose {
    /// 아래 = 앞, 위 = 뒤, 왼쪽 = 앞, 오른쪽 = 앞 반전. 걸을 때 bob은 0과 2를 1/8초마다 번갈아, 멈추면 0.
    static func choice(facing: PlazaDirection, isWalking: Bool, clock: TimeInterval) -> PlazaSpriteChoice {
        let bob = isWalking && Int((clock * 8).rounded(.down)) % 2 != 0 ? 2 : 0
        return PlazaSpriteChoice(useBack: facing == .up, flipped: facing == .right, bob: bob)
    }
}
