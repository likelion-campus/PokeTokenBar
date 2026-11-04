import Foundation

/// 광장 지도 원본. 탁 트인 풀밭에 꽃과 덤불, 풀숲(g)을 흩어 직접 짠 배치이고, 실제 게임 지도를 옮긴 것이 아니다.
/// 문자 뜻은 `PlazaTile` 참고. 48열 x 32행.
enum PlazaMapData {
    static let rows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTT..........................................TTT",
        "TTT..f.........b.......f..........ggggg......TTT",
        "TTT..ggggggg............f.f.......ggggg.f....TTT",
        "TTT..ggggggg.f...f................ggggg......TTT",
        "TTT..ggggggg..................b.f............TTT",
        "TTT..ggggggg.................................TTT",
        "TTT.....f..........f............f....f.......TTT",
        "TTT..........................ggg.......b.....TTT",
        "TTT.f........................ggg.............TTT",
        "TTT..................................f.f.....TTT",
        "TTT.......b.........................f......f.TTT",
        "TTT...................SNNS..............ggg..TTT",
        "TTT.f..gg.............SNNS.......f......ggg..TTT",
        "TTT....gg.f...f......SSSSSS..............f...TTT",
        "TTT............b.....SSSSSS.......f..........TTT",
        "TTT............................f...f.........TTT",
        "TTT........b.................................TTT",
        "TTT........f..................f..............TTT",
        "TTT............f.......................f.....TTT",
        "TTT.ggggg.........f..............b...f....b..TTT",
        "TTT.ggggg........f.....f...f.................TTT",
        "TTT.ggggg................ggggggg.............TTT",
        "TTT.ggggg.......gg.......ggggggg.............TTT",
        "TTT.............gg.......ggggggg......ff.....TTT",
        "TTT...................f..ggggggg.............TTT",
        "TTT..........................................TTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    ]

    static let map: PlazaMap = {
        do { return try PlazaMap(rows: rows) } catch { fatalError("Invalid plaza map: \(error)") }
    }()
}
