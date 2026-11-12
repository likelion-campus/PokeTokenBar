import AppKit
import CoreText

/// 감정 말풍선 그림: 흰 바탕, 어두운 테두리, 아래 꼬리. 도트 격자와 갈무리 글꼴만 쓰고 이모지 글꼴은 쓰지 않는다.
/// CoreGraphics/CoreText만 쓰므로 창 없이 만들 수 있다.
enum PlazaEmoteArt {
    /// 말풍선 몸통과 꼬리의 도트 하나가 차지하는 포인트.
    private static let dot: CGFloat = 2
    /// 인사하기 말풍선의 도트. 1.5배 크고, 도트가 여전히 정수 포인트라 또렷하다.
    private static let largeDot: CGFloat = 3
    /// `#` 테두리, `W` 흰 바탕. 꼬리는 가운데 두 칸.
    private static let bubble = [
        "..##########..",
        ".#WWWWWWWWWW#.",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        "#WWWWWWWWWWWW#",
        ".#WWWWWWWWWW#.",
        "..####WW####..",
        ".....#WW#.....",
        "......##......",
    ]
    private static let heart = [
        ".RR.RR.",
        "RRRRRRR",
        "RRRRRRR",
        ".RRRRR.",
        "..RRR..",
        "...R...",
    ]
    private static let party = [
        "..R.Y..",
        "G....B.",
        ".Y.O..R",
        "..OO.G.",
        ".OOOO..",
        "OOOOO..",
        "OOOO...",
    ]
    // ! 와 ? 도 하트처럼 도트 격자로 그린다. 획은 두 칸 굵기, 글꼴을 쓰지 않아 가장자리가 뭉개지지 않는다.
    private static let exclaim = [
        "##",
        "##",
        "##",
        "##",
        "##",
        "..",
        "##",
        "##",
    ]
    private static let question = [
        ".####.",
        "##..##",
        "....##",
        "...##.",
        "..##..",
        "......",
        "..##..",
        "..##..",
    ]
    private static let ink = CGColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255, alpha: 1)
    private static let palette: [Character: CGColor] = [
        "#": ink,
        "W": CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        "R": CGColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1),
        "Y": CGColor(srgbRed: 0xF5 / 255, green: 0xC4 / 255, blue: 0x2B / 255, alpha: 1),
        "G": CGColor(srgbRed: 0x3F / 255, green: 0xB9 / 255, blue: 0x50 / 255, alpha: 1),
        "B": CGColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1),
        "O": CGColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0x24 / 255, alpha: 1),
        "U": CGColor(srgbRed: 0xF2 / 255, green: 0xEE / 255, blue: 0xE2 / 255, alpha: 1),
        "V": CGColor(srgbRed: 0xC4 / 255, green: 0xBC / 255, blue: 0xAA / 255, alpha: 1),
        // 민트: 풀밭(초록) 위에서 보이도록 청록과 밝은 청록.
        "M": CGColor(srgbRed: 0x2F / 255, green: 0xB8 / 255, blue: 0xA6 / 255, alpha: 1),
        "L": CGColor(srgbRed: 0xB9 / 255, green: 0xF2 / 255, blue: 0xE4 / 255, alpha: 1),
    ]

    /// 포인트 단위 크기. 이미지 픽셀 크기는 여기에 배율을 곱한 값이다.
    static let size = size(large: false)

    static func size(large: Bool) -> CGSize {
        let d = large ? largeDot : dot
        return CGSize(width: CGFloat(bubble[0].count) * d, height: CGFloat(bubble.count) * d)
    }

    /// `scale`은 포인트당 기기 픽셀 수. `large`는 인사하기 말풍선(1.5배).
    static func image(_ kind: TeamEmoteKind, scale: CGFloat, large: Bool = false) -> CGImage {
        let scale = max(scale, 1)
        let dot = large ? largeDot : dot, size = size(large: large)
        let context = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        drawGrid(bubble, cell: dot, origin: .zero, in: context)
        // 몸통 안쪽의 가운데(위에서 다섯 도트 반)에 내용을 둔다.
        let center = CGPoint(x: size.width / 2, y: size.height - 5.5 * dot)
        switch kind {
        case .heart: drawGrid(heart, cell: dot, centeredAt: center, in: context)
        case .party: drawGrid(party, cell: dot, centeredAt: center, in: context)
        case .lol: drawText(L(.ko).plazaEmoteLol, size: large ? .body : .small, centeredAt: center, in: context)
        case .exclaim: drawGrid(exclaim, cell: dot, centeredAt: center, in: context)
        case .question: drawGrid(question, cell: dot, centeredAt: center, in: context)
        case .tackle: drawGrid(impact, cell: dot / 2, centeredAt: center, in: context)
        case .jump: drawGrid(dust, cell: dot, centeredAt: center, in: context)
        case .groupPhoto: drawGrid(camera, cell: dot, centeredAt: center, in: context)
        case .pickup: drawGrid(candy, cell: dot / 2, centeredAt: center, in: context)
        case .firework: drawGrid(spark, cell: dot, centeredAt: center, in: context)
        case .decoyFound: drawGrid(exclaim, cell: dot, centeredAt: center, in: context)
        case .decoyJump: drawGrid(dust, cell: dot, centeredAt: center, in: context)
        case .decoyTackle: drawGrid(impact, cell: dot / 2, centeredAt: center, in: context)
        case .snowball: drawGrid(impact, cell: dot / 2, centeredAt: center, in: context)   // never shown as a bubble
        case .mimicTackle: drawGrid(impact, cell: dot / 2, centeredAt: center, in: context)   // never shown as a bubble
        case .mimicFound: drawGrid(exclaim, cell: dot, centeredAt: center, in: context)   // never shown as a bubble
        case .pull: drawGrid(exclaim, cell: dot, centeredAt: center, in: context)
        case .dance: drawText(L(.ko).plazaEmoteDance, size: large ? .body : .small, centeredAt: center, in: context)
        }
        return context.makeImage()!
    }

    /// 몸통박치기가 맞은 자리에 터지는 충격. 꽉 찬 여덟 갈래 별로, 흰 가운데에서 노랑, 주황으로 번지고 바깥 테두리만 어둡다.
    private static let impact = [
        ".......#.......",
        ".......#.......",
        "..#....#....#..",
        "...##.#Y#.##...",
        "...#O#YYY#O#...",
        "....#YYWYY#....",
        "...#YYWWWYY#...",
        "###YYWWWWWYY###",
        "...#YYWWWYY#...",
        "....#YYWYY#....",
        "...#O#YYY#O#...",
        "...##.#Y#.##...",
        "..#....#....#..",
        ".......#.......",
        ".......#.......",
    ]

    /// 충격 그림의 포인트 단위 크기. 이미지 픽셀 크기는 여기에 배율을 곱한 값이다.
    static let impactSize = CGSize(width: CGFloat(impact[0].count) * dot, height: CGFloat(impact.count) * dot)

    static func impactImage(scale: CGFloat) -> CGImage {
        let scale = max(scale, 1)
        let context = CGContext(data: nil, width: Int((impactSize.width * scale).rounded()), height: Int((impactSize.height * scale).rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        drawGrid(impact, cell: dot, origin: .zero, in: context)
        return context.makeImage()!
    }

    /// 단체 사진. 말풍선으로 뜨지는 않지만 종류마다 그림이 달라야 한다.
    private static let camera = [
        "..##.....",
        "#########",
        "#..###..#",
        "#.#WWW#.#",
        "#..###..#",
        "#########",
    ]

    /// 점프할 때 발밑에서 이는 먼지 한 덩이. 위는 밝고 아래는 그늘진다.
    private static let dust = [
        "..UUU...",
        ".UUUUUV.",
        "UUUUUUVV",
        ".VVVVVV.",
    ]

    static let dustSize = CGSize(width: CGFloat(dust[0].count) * dot, height: CGFloat(dust.count) * dot)

    static func dustImage(scale: CGFloat) -> CGImage {
        let scale = max(scale, 1)
        let context = CGContext(data: nil, width: Int((dustSize.width * scale).rounded()), height: Int((dustSize.height * scale).rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        drawGrid(dust, cell: dot, origin: .zero, in: context)
        return context.makeImage()!
    }

    static let spark = [
        "..Y..",
        ".YWY.",
        "YWWWY",
        ".YWY.",
        "..Y..",
    ]

    /// 광장에 떨어진 이상한 사탕. 둥근 사탕 양쪽에 꼬인 포장이 붙어 있다.
    private static let candy = [
        "##.......##",
        "#Y#.###.#Y#",
        "#YY#BWB#YY#",
        "#YYYBBBYYY#",
        "#YY#BBB#YY#",
        "#Y#.###.#Y#",
        "##.......##",
    ]

    /// 광장에 떨어진 민트. 잎 두 장이 한 줄기에서 벌어진다. 가운데 잎맥이 밝다.
    private static let mintLeaf = [
        ".##.....##.",
        "#MM#...#MM#",
        "#MLM#.#MLM#",
        ".#MLM#MLM#.",
        "..#MMLMM#..",
        "...##L##...",
        ".....#.....",
    ]

    private static func itemGrid(_ kind: ItemKind) -> [String] { kind == .mint ? mintLeaf : candy }

    /// 광장 아이템의 포인트(월드 픽셀) 크기.
    static func itemSize(_ kind: ItemKind) -> CGSize {
        let grid = itemGrid(kind)
        return CGSize(width: CGFloat(grid[0].count) * dot, height: CGFloat(grid.count) * dot)
    }

    static func itemImage(_ kind: ItemKind, scale: CGFloat) -> CGImage {
        let scale = max(scale, 1), size = itemSize(kind)
        let context = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        drawGrid(itemGrid(kind), cell: dot, origin: .zero, in: context)
        return context.makeImage()!
    }

    /// 큰 소식 반짝임 조각 하나. 포인트 단위 크기는 `sparkSize`.
    static let sparkSize = CGSize(width: 5 * dot, height: 5 * dot)

    static func sparkImage(scale: CGFloat) -> CGImage {
        let scale = max(scale, 1)
        let context = CGContext(data: nil, width: Int((sparkSize.width * scale).rounded()), height: Int((sparkSize.height * scale).rounded()),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        context.scaleBy(x: scale, y: scale)
        drawGrid(spark, cell: dot, origin: .zero, in: context)
        return context.makeImage()!
    }

    /// 위에서 아래로 읽는 격자를 그린다. `origin`은 격자 왼쪽 아래 모서리(CG 좌표).
    private static func drawGrid(_ rows: [String], cell: CGFloat, origin: CGPoint, in context: CGContext) {
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let color = palette[ch] else { continue }
                context.setFillColor(color)
                context.fill(CGRect(x: origin.x + CGFloat(col) * cell,
                                    y: origin.y + CGFloat(rows.count - 1 - row) * cell, width: cell, height: cell))
            }
        }
    }

    private static func drawGrid(_ rows: [String], cell: CGFloat, centeredAt center: CGPoint, in context: CGContext) {
        let w = CGFloat(rows.map(\.count).max() ?? 0) * cell, h = CGFloat(rows.count) * cell
        drawGrid(rows, cell: cell, origin: CGPoint(x: center.x - w / 2, y: center.y - h / 2), in: context)
    }

    private static func drawText(_ text: String, size: PlazaTextSize, centeredAt center: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlazaResources.font(size),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        context.setShouldSmoothFonts(false)
        context.setFillColor(ink)
        context.textPosition = CGPoint(x: (center.x - bounds.midX).rounded(), y: (center.y - bounds.midY).rounded())
        CTLineDraw(line, context)
    }
}
