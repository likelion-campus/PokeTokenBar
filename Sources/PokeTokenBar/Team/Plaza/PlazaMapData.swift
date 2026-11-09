import Foundation

/// 광장 지도 원본. 탁 트인 풀밭에 꽃과 덤불, 풀숲(g)을 흩어 직접 짠 배치이고, 실제 게임 지도를 옮긴 것이 아니다.
/// 문자 뜻은 `PlazaTile` 참고. 48열 x 32행.
enum PlazaMapData {
    static let rows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTT..........................................TTT",
        "TTT..f.........b......SNNS........ggggg......TTT",
        "TTT..ggggggg..........SNNSf.......ggggg.f....TTT",
        "TTT..ggggggg.f...f...SSSSSS.......ggggg......TTT",
        "TTT..ggggggg.........SSSSSS...b.f............TTT",
        "TTT..ggggggg.................................TTT",
        "TTT.....f..........f............f....f.......TTT",
        "TTT..........................ggg.......b.....TTT",
        "TTT.f........................ggg.............TTT",
        "TTT..................................f.f.....TTT",
        "TTT..wwwwwwwwww.....................f......f.TTT",
        "TTT..wwwwwwwwww.................wwwwwww.ggg..TTT",
        "TTT.fwwwwwwwwww........FF.......wwwwwww.ggg..TTT",
        "TTT.......f...f........FF.......wwwwwww..f...TTT",
        "TTT............b................wwwwwww......TTT",
        "TTT............................fwwwwwww......TTT",
        "TTT...b....b....................wwwwwww......TTT",
        "TTT........f..................f.wwwwwww......TTT",
        "TTT............f.......................f.....TTT",
        "TTT.ggggg.........f..............b...f....b..TTT",
        "TTT.ggggg........f.....f...f.................TTT",
        "TTT.ggggg...........www..ggggggg.............TTT",
        "TTT.ggggg.......gg..www..ggggggg.............TTT",
        "TTT.............gg..www..ggggggg......ff.....TTT",
        "TTT...................f..ggggggg.............TTT",
        "TTT..........................................TTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    ]

    /// 아이템 자리를 뽑는 데 쓰는 고정 배치(v2.5.613 지도). 쉼터·소식판·모닥불을 옮겨도 칸 번호가 같은 자리에 떨어지도록,
    /// 이 배치의 후보 목록으로만 자리를 뽑는다. 이 줄들은 절대 바꾸지 않는다(바꾸면 버전마다 아이템 자리가 갈린다).
    /// 지금 지도에서 그 칸이 막혔으면 아이템은 보이지 않는다(`PlazaItems.isShown`).
    static let itemLayoutRows: [String] = [
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTT..........................................TTT",
        "TTT..f.........b.......f.....................TTT",
        "TTT.....................f.f.............f....TTT",
        "TTT..........f...f...........................TTT",
        "TTT...........................b.f............TTT",
        "TTT.......f..................................TTT",
        "TTT.....f..........f............f....f.......TTT",
        "TTT....................................b.....TTT",
        "TTT.f........................................TTT",
        "TTT..................................f.f.....TTT",
        "TTT.......b.........................f......f.TTT",
        "TTT...................SNNS...................TTT",
        "TTT.f.................SNNS.......f...........TTT",
        "TTT.......f...f......SSSSSS..............f...TTT",
        "TTT............b.....SSSSSS.......f..........TTT",
        "TTT............................f...f.........TTT",
        "TTT........b.................................TTT",
        "TTT........f..................f..............TTT",
        "TTT............f.......................f.....TTT",
        "TTT...............f..............b...f....b..TTT",
        "TTT..............f.....f...f.................TTT",
        "TTT..........................................TTT",
        "TTT..........................................TTT",
        "TTT..............f...........f........ff.....TTT",
        "TTT...................f......................TTT",
        "TTT..........................................TTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
        "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
    ]

    static let map: PlazaMap = {
        do { return try PlazaMap(rows: rows) } catch { fatalError("Invalid plaza map: \(error)") }
    }()

    /// `itemLayoutRows`로 만든 지도. 한 번만 만든다.
    static let itemLayoutMap: PlazaMap = {
        do { return try PlazaMap(rows: itemLayoutRows) } catch { fatalError("Invalid item layout: \(error)") }
    }()
}
