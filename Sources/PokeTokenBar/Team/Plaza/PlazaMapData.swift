import Foundation

/// 광장 지도 원본. 공원 같은 직접 짠 배치이고, 실제 게임 지도를 옮긴 것이 아니다.
/// 문자 뜻은 `PlazaTile` 참고. 48열 x 32행.
enum PlazaMapData {
    static let rows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTT.TT.TT.TT.TT.TT.TT.TT.TT.TT.TT.TT.TT.TT.TTTT",
        "TT..........T..........PP.....................TT",
        "T....................b.PP.....T...............TT",
        "TT..........b..........PP.........fffffffffff.TT",
        "TT....WWWWWWW..........PP........fffffPffffff..T",
        "T....WWWWWWWWW.........PP........fffffPffffff.TT",
        "TT...WWWWWWWWWb........PP........fffffPffffff.TT",
        "TT...WWWWWWWWW.........PP.....b..fffffPffffff.TT",
        "T....WWWWWWWWW....b....PP........fffffffffff...T",
        "TT....WWWWWWW..........PP.....................TT",
        "TT......b......T.T.....PP.....T.T.............TT",
        "T......................bNb....................TT",
        "TT.................PPPPPPPPPP..................T",
        "TT.........T......F..SSSSSS..F..........T.....TT",
        "T.........T.........SSSSSSSS.F....T......T....TT",
        "TT.....b..........F.SSSSSSSS.........b........TT",
        "TT................F..SSSSSS..F.................T",
        "T..................PPPPPPPPPP.................TT",
        "TTPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPTT",
        "TTPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPTT",
        "T......................PP......................T",
        "TT..............T......PP.....................TT",
        "TT..,,,,,,,,,,,.T......PP....T.....,,,,,,,,,..TT",
        "T...,,,,,,,,,,,.T......PP..........,,,,,,,,,..TT",
        "TT..,,,,,,,,,,,........PP....T.....,,,,,,,,,...T",
        "TT..,,,,,,,,,,,.T......PP....b.....,,,,,,,,,..TT",
        "T...,,,,,,,,,,,.T......PP....T.....,,,,,,,,,..TT",
        "TT..,,,,,,,,,,,.T......PP..b.T................TT",
        "TT..............T......PP....T.................T",
        "TT.TTT.TTT.TTT.TTT.TTT.TTT.TTT.TTT.TTT.TTT.TTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",    ]

    static let map: PlazaMap = {
        do { return try PlazaMap(rows: rows) } catch { fatalError("Invalid plaza map: \(error)") }
    }()
}
