import Foundation

/// 봄과 여름에 던지는 것은 포켓몬 아이템 그림이다: 봄은 분홍꽃잎, 여름은 풍선. 저장소와 번들에는 없고, 포켓몬 그림처럼 실행 중에
/// PokéAPI에서 받아 캐시한다(`SpriteStore.data(itemName:)`). 받기 전이나 받지 못했을 때는 번들 그림(`PlazaResources.ballSource`)으로 던진다.
enum PlazaThrowItems {
    /// 그 계절에 던지는 아이템의 PokéAPI 이름. nil이면 번들 그림만 쓴다.
    static func itemName(_ season: PlazaSeason) -> String? {
        switch season {
        case .spring: "pink-petal"
        case .summer: "air-balloon"
        case .autumn, .winter: nil
        }
    }

    /// 풍선의 색: 받은 빨강 그대로(0), 그리고 색상만 돌린 파랑, 초록, 노랑, 보라(도). 던질 때마다 이 차례로 돌아간다.
    static let balloonHues: [Double] = [0, 225, 120, 55, 275]
    /// 이보다 옅은 픽셀(테두리, 줄, 흰 반짝임)은 색상을 돌리지 않는다.
    static let minSaturation = 0.25

    /// 받은 아이템 그림(30×30, 둘레가 비어 있다)으로 던질 그림들을 만든다: 빈 둘레를 잘라내고, 여름 풍선은 색상만 돌린 다섯 색이다.
    /// 모양은 그대로다. 빈 그림이면 빈 목록이다.
    static func balls(_ season: PlazaSeason, item: PlazaImage) -> [PlazaImage] {
        guard let cut = trimmed(item.pixels) else { return [] }
        let hues = season == .summer ? balloonHues : [0]
        return hues.map { PlazaImage(bitmap: $0 == 0 ? cut : hueShifted(cut, degrees: $0)) }
    }

    /// 보이는 픽셀을 모두 담는 가장 작은 사각형으로 자른다. 보이는 픽셀이 없으면 nil.
    static func trimmed(_ bitmap: PlazaBitmap) -> PlazaBitmap? {
        var x0 = bitmap.width, y0 = bitmap.height, x1 = -1, y1 = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.bytes[(y * bitmap.width + x) * 4 + 3] > 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0 else { return nil }
        return bitmap.cropped(to: PlazaPixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
    }

    /// 불투명하고 채도가 `minSaturation` 이상인 픽셀의 색상만 `degrees`만큼 돌린다(HSV; 채도와 밝기는 그대로).
    static func hueShifted(_ bitmap: PlazaBitmap, degrees: Double) -> PlazaBitmap {
        var out = bitmap
        for i in stride(from: 0, to: out.bytes.count, by: 4) where out.bytes[i + 3] == 255 {
            let r = Double(out.bytes[i]) / 255, g = Double(out.bytes[i + 1]) / 255, b = Double(out.bytes[i + 2]) / 255
            let hi = max(r, g, b), lo = min(r, g, b), chroma = hi - lo
            guard hi > 0, chroma / hi >= minSaturation else { continue }
            var h: Double   // 0..<6, 한 칸이 60도
            if hi == r { h = (g - b) / chroma } else if hi == g { h = (b - r) / chroma + 2 } else { h = (r - g) / chroma + 4 }
            h = (h + degrees / 60).truncatingRemainder(dividingBy: 6)
            if h < 0 { h += 6 }
            let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double) = switch Int(h) {
            case 0: (chroma, x, 0)
            case 1: (x, chroma, 0)
            case 2: (0, chroma, x)
            case 3: (0, x, chroma)
            case 4: (x, 0, chroma)
            default: (chroma, 0, x)
            }
            out.bytes[i] = UInt8(((r1 + lo) * 255).rounded())
            out.bytes[i + 1] = UInt8(((g1 + lo) * 255).rounded())
            out.bytes[i + 2] = UInt8(((b1 + lo) * 255).rounded())
        }
        return out
    }
}
