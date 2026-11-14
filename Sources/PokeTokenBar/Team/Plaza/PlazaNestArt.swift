import Foundation

/// 알이 앉는 둥지. 지도 그림과 같은 2배 도트(한 칸 = 월드 2픽셀)로 그린 엮은 짚 그릇이다.
/// 뒤판(`image`)은 알 뒤에, 앞 테두리(`frontImage`)는 알 앞에 그려서 알이 둥지 안에 앉아 보인다.
enum PlazaNestArt {
    /// `O` 테두리, `D` 그늘진 잔가지, `M`·`S` 짚, `L` 빛 받은 짚, `H`·`K` 알이 앉는 패인 곳(K가 더 어둡다).
    static let grid = [
        "................................",
        "........OOOOOOOOOOOOOOOO........",
        ".....OOOLLKKKKKKKKKKKKLLOOO.....",
        "...OOLLKKKKKKKKKKKKKKKKKKLLOO...",
        ".DOLLLKHHHHHHHHHHHHHHHHHHKLLLO..",
        "DOLLDDKHHHHHHHHHHHHHHHHHHKLLDLO.",
        "OLDDLLLKKHHHHHHHHHHHHHHKKLLLLLLO",
        "OLLLLLLDDLKKHHHHHHHHKKDLLLLDLLLO",
        "ODMMDDMDLMMLLMDDMMMLLMDLLMDDMMLO",
        ".ODMSSMMSSSMDSSSSSDMMSSSDMSSMSO.",
        ".DOSMMSSMDSSSSMMMMDSSSMDSSMMDO..",
        "...OOMDDSSSMMMMMMMMMMSSSDMMOO.D.",
        "..D..OOODMMSSSSDDDSSSMDDOOO.....",
        "........OOOOOOOOOOOOOOOO........",
    ]
    static let cols = grid[0].count
    static let rows = grid.count
    /// 이 줄부터 패인 곳이 아닌 칸은 알 앞에 그린다. 알의 아래 끝(발)이 8번째와 9번째 줄 사이에 온다.
    static let frontFromRow = 7
    private static let cell = 2

    static var size: (width: Int, height: Int) { (cols * cell, rows * cell) }

    private static let palette: [Character: [UInt8]] = [
        "O": [0x3B, 0x24, 0x12], "D": [0x6E, 0x46, 0x22], "M": [0x96, 0x63, 0x30], "S": [0xC4, 0x98, 0x52],
        "L": [0xE8, 0xCC, 0x84], "H": [0x5A, 0x3A, 0x1E], "K": [0x3A, 0x23, 0x10],
    ]

    /// 둥지 전체. 알 뒤에 깐다.
    static func image() -> PlazaImage { render { _, _ in true } }

    /// 앞 테두리만. 알 앞에 얹는다.
    static func frontImage() -> PlazaImage { render { y, ch in y >= frontFromRow && ch != "H" && ch != "K" } }

    /// 그 칸의 색. 빈 칸이면 nil.
    static func color(_ x: Int, _ y: Int) -> [UInt8]? {
        let row = grid[y]
        return palette[row[row.index(row.startIndex, offsetBy: x)]]
    }

    private static func render(_ keep: (_ y: Int, _ ch: Character) -> Bool) -> PlazaImage {
        let width = cols * cell, height = rows * cell
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = palette[ch], keep(y, ch) else { continue }
                for dy in 0..<cell {
                    for dx in 0..<cell {
                        let i = ((y * cell + dy) * width + x * cell + dx) * 4
                        data[i] = color[0]; data[i + 1] = color[1]; data[i + 2] = color[2]; data[i + 3] = 255
                    }
                }
            }
        }
        var bitmap = PlazaBitmap(width: width, height: height)
        bitmap.bytes = data
        return PlazaImage(bitmap: bitmap)
    }
}
