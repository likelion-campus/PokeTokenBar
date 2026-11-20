import Foundation

/// 번들된 풀숲 시트(208×144, 16픽셀 칸)에서 풀숲 조각을 자른다. 시트 그림은 그대로 두고,
/// 새로 그린 픽셀은 흩날리는 잎 두 장뿐이다.
struct PlazaTallGrassArt: @unchecked Sendable {
    private static let cell = 16
    private static let sheetSize = (width: 208, height: 144)

    private let sheetBytes: [UInt8]
    /// 잎 두 장. 각 4×4 시트 픽셀.
    let leaves: [PlazaImage]

    init?(sheet: PlazaImage) {
        guard sheet.width == Self.sheetSize.width, sheet.height == Self.sheetSize.height else { return nil }
        sheetBytes = sheet.pixels.bytes
        leaves = [Self.leaf(["ll", "lm"]), Self.leaf(["l.", "mm"])]
    }

    /// 시트의 해당 칸 16×16.
    func tile(_ s: PlazaTallGrassSlice) -> PlazaImage { slice(s, rows: 0..<Self.cell) }

    /// 아래 띠만. 행 0..<frontFromRow 는 투명.
    func front(_ s: PlazaTallGrassSlice) -> PlazaImage { slice(s, rows: PlazaTallGrass.frontFromRow..<Self.cell) }

    /// 흔들리는 윗부분만. 행 swayRows..<16 은 투명.
    func top(_ s: PlazaTallGrassSlice) -> PlazaImage { slice(s, rows: 0..<PlazaTallGrass.swayRows) }

    private func slice(_ s: PlazaTallGrassSlice, rows: Range<Int>) -> PlazaImage {
        let c = Self.cell
        var out = [UInt8](repeating: 0, count: c * c * 4)
        let originX = s.col * c, originY = (PlazaTallGrass.sheetRowOffset + s.row) * c
        for y in rows {
            let from = ((originY + y) * Self.sheetSize.width + originX) * 4
            out.replaceSubrange((y * c * 4)..<((y + 1) * c * 4), with: sheetBytes[from..<from + c * 4])
        }
        return Self.image(out, width: c, height: c)
    }

    /// 2×2 무늬(`l` 밝은 초록, `m` 짙은 초록, `.` 투명)를 4×4 한가운데 두고 4방향 1픽셀 테두리를 두른다.
    private static func leaf(_ pattern: [String]) -> PlazaImage {
        let rows = pattern.map { Array($0) }
        func painted(_ x: Int, _ y: Int) -> Character? {
            guard (1...2).contains(x), (1...2).contains(y) else { return nil }
            let ch = rows[y - 1][x - 1]
            return ch == "." ? nil : ch
        }
        var out = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let rgb: [UInt8]?
                if let ch = painted(x, y) {
                    rgb = ch == "l" ? [0x99, 0xE5, 0x50] : [0x6A, 0xBE, 0x30]
                } else if painted(x - 1, y) != nil || painted(x + 1, y) != nil
                            || painted(x, y - 1) != nil || painted(x, y + 1) != nil {
                    rgb = [0x22, 0x20, 0x34]
                } else {
                    rgb = nil
                }
                if let rgb {
                    let i = (y * 4 + x) * 4
                    out[i] = rgb[0]; out[i + 1] = rgb[1]; out[i + 2] = rgb[2]; out[i + 3] = 255
                }
            }
        }
        return image(out, width: 4, height: 4)
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) -> PlazaImage {
        var bitmap = PlazaBitmap(width: width, height: height)
        bitmap.bytes = bytes
        return PlazaImage(bitmap: bitmap)
    }
}
