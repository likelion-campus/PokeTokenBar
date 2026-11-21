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
    static let leafSheetName = "plaza-leaf-sheet"       // png, 128×160, 받은 그대로. 봄·가을 공은 여기서 한 칸씩 자른다
    static let tallGrassSheetName = "plaza-tallgrass"   // png
    static let iceCrackSheetName = "plaza-ice-cracks"   // png
    static let iceGlossSheetName = "plaza-ice-gloss"    // png
    static let iceShatterName = "plaza-ice-shatter"     // gif

    /// 계절이 던지는 공 그림의 파일과 자를 영역(nil이면 파일 전체). 겨울은 파일이 없어 격자 눈뭉치다.
    static func ballSource(_ season: PlazaSeason) -> (name: String, crop: PlazaPixelRect?)? {
        switch season {
        case .winter: nil
        case .spring: (leafSheetName, PlazaPixelRect(x: 33, y: 129, width: 17, height: 15))
        case .summer: (waterBalloonName, nil)
        case .autumn: (leafSheetName, PlazaPixelRect(x: 33, y: 33, width: 17, height: 15))
        }
    }
}
