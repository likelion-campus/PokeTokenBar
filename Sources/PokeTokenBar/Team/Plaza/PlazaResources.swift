import Foundation

/// Plaza text sizes. Galmuri is a pixel font: strokes are even only when one font pixel is a whole number of
/// device pixels. At 14pt one Galmuri11 pixel is 2.33 device pixels on a Retina screen, so strokes come out 2 or
/// 3 pixels wide and the letters look broken. Both sizes below are whole on 1x and 2x screens.
enum PlazaTextSize: CaseIterable {
    /// Galmuri14 (a 15-pixel grid) at 15pt.
    case body
    /// Galmuri11 (a 12-pixel grid) at 12pt.
    case small

    var points: CGFloat {
        switch self {
        case .body: 15
        case .small: 12
        }
    }

    /// PostScript name (read with `fc-scan`).
    var fontName: String {
        switch self {
        case .body: "Galmuri14-Regular"
        case .small: "Galmuri11-Regular"
        }
    }

    var fileName: String {
        switch self {
        case .body: "Galmuri14"
        case .small: "Galmuri11"
        }
    }
}

/// The bundled plaza resources (`Resources/Plaza`) by name. Loading them is the platform's: the Mac reads the SwiftPM
/// resource bundle (`MacPlazaAssets.swift`), other OSes go through `PlazaGraphics.assetURL`.
enum PlazaResources {
    static let bundleName = "PokeTokenBar_PokeTokenBar.bundle"

    static let tileSheetName = "plaza-tiles"           // png
    static let waterBalloonName = "plaza-water-balloon" // png
    static let leafSheetName = "plaza-leaf-sheet"       // png, 128×160, 받은 그대로. 가을 공은 여기서 한 칸을 자른다
    static let sakuraName = "plaza-sakura"              // png, 38×34, "Spring VFX Pack" 의 벚꽃 한 송이. 봄 공
    static let balloonSheetName = "plaza-balloons"      // png, 80×21, "Balloon Pop Sprite" 다섯 색의 첫 프레임을 옆으로 이어 붙인 것. 여름 공
    /// 풍선 시트의 다섯 칸(16×21): 빨강, 파랑, 초록, 노랑, 보라.
    static let balloonFrames: [PlazaPixelRect] = (0..<5).map { PlazaPixelRect(x: 16 * $0, y: 0, width: 16, height: 21) }
    static let tallGrassSheetName = "plaza-tallgrass"   // png
    static let iceCrackSheetName = "plaza-ice-cracks"   // png
    static let iceGlossSheetName = "plaza-ice-gloss"    // png
    static let iceShatterName = "plaza-ice-shatter"     // gif
    static let steamSheetName = "plaza-steam"           // png, 224×32, "Smoke Puff" (smoke_5.png) 받은 그대로. 온천 김
    /// 김 시트의 앞 여섯 칸(32×32). 일곱째 칸은 비어 있다.
    static let steamFrames: [PlazaPixelRect] = (0..<6).map { PlazaPixelRect(x: 32 * $0, y: 0, width: 32, height: 32) }
    static let bombSheetName = "plaza-bomb"             // png, 64×16, "16-bit animated bomb" 의 네 프레임을 옆으로 이어 붙인 것. 미니게임 폭탄
    static let fortuneCookieName = "plaza-fortune-cookie" // png, 16×16, "16x16 Food" 의 fortune_cookie.png 받은 그대로. 포춘쿠키
    /// The bomb's four 16×16 frames, the fuse spark flickering.
    static let bombFrames: [PlazaPixelRect] = (0..<4).map { PlazaPixelRect(x: 16 * $0, y: 0, width: 16, height: 16) }

    /// 큰 나무: `plaza-tallgrass.png` 안의 RedVoxel 소나무. 새 파일 없이 실행 중에 잘라 쓴다.
    static let treeCrop = PlazaPixelRect(x: 83, y: 48, width: 42, height: 48)

    /// 계절이 던지는 공 그림들의 파일, 자를 영역(nil이면 파일 전체), 그림 한 픽셀의 월드 픽셀 수. 여럿이면 던질 때마다
    /// 차례로 돌아가며 쓴다. 겨울은 파일이 없어 격자 눈뭉치다. 풍선(16×21)은 2배로 그려 벚꽃(38×34)과 비슷한 크기다.
    static func ballSources(_ season: PlazaSeason) -> [(name: String, crop: PlazaPixelRect?, scale: CGFloat)] {
        switch season {
        case .winter: []
        case .spring: [(sakuraName, nil, 1)]
        case .summer: balloonFrames.map { (balloonSheetName, $0, 2) }
        case .autumn: [(leafSheetName, PlazaPixelRect(x: 33, y: 33, width: 17, height: 15), 1)]
        }
    }
}
