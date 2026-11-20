import Foundation

/// 입자 그림. 한 칸이 월드 픽셀 하나라 지도 도트와 같은 크기로 보인다. 회전 대신 좌우로 뒤집은 그림을 따로 둔다.
enum PlazaWeatherArt {
    /// 위에서 아래로 읽는 도트 격자.
    static func grids(_ kind: PlazaWeather.Kind) -> [[String]] {
        switch kind {
        case .clear: []
        case .snow: [[".W.", "WWW", ".W."], ["WW", "WS"], ["W"]]
        case .petals: both([".PP", "PPp"])
        case .greenLeaves: both(["GG.", "GgG", ".GG"]) + both(["HH.", "HhH", ".HH"])
        case .leaves: both(["OO.", "OoO", ".OO"]) + both(["RR.", "RrR", ".RR"]) + both(["YY.", "YyY", ".YY"])
        }
    }

    private static func both(_ grid: [String]) -> [[String]] { [grid, grid.map { String($0.reversed()) }] }
}
