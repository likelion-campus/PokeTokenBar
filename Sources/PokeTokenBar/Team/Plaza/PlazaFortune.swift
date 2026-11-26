import Foundation

/// One fortune: which line and which lucky action. Sent to teammates as two small numbers, so each app shows its own text.
struct PlazaFortuneDraw: Codable, Equatable, Sendable {
    var line: Int
    var action: Int
}

/// 포춘쿠키. 광장의 가판대('K' 칸)에서 하루에 한 번 쿠키를 깬다. 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다.
/// 문구는 날짜와 팀원 ID로 정해져 서버가 없어도 같은 날 같은 사람에게 같은 쪽지가 나온다.
enum PlazaFortune {
    /// 가판대 그림: 지도 타일 시트(`plaza-tiles.png`, ArMM1998, CC0) 안의 천막 가판대. 새 파일 없이 지도에 굽는다.
    static let stallCrop = PlazaPixelRect(x: 289, y: 358, width: 83, height: 86)

    /// 지도의 모든 'K' 칸. 가판대 없는 지도는 [].
    static func stallTiles(in map: PlazaMap) -> [TilePoint] {
        var out: [TilePoint] = []
        for y in 0..<map.height {
            for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .stall { out.append(TilePoint(x: x, y: y)) }
        }
        return out
    }

    /// 그날 그 팀원의 쪽지. 같은 날짜와 ID면 어느 기기에서나 같다.
    static func draw(day: String, memberID: String) -> PlazaFortuneDraw {
        var rng = PlazaSplitMix64(seed: UInt64(PlazaNameColor.fnv1a("plaza-fortune-\(day)-\(memberID)")))
        return PlazaFortuneDraw(line: Int(rng.next() % UInt64(lines.count)), action: Int(rng.next() % UInt64(actions.count)))
    }

    /// 팀원이 보낸 값은 이 버전이 아는 범위 안일 때만 쓴다(나중 버전의 문구 번호는 버린다).
    static func accepted(_ d: PlazaFortuneDraw?) -> PlazaFortuneDraw? {
        guard let d, lines.indices.contains(d.line), actions.indices.contains(d.action) else { return nil }
        return d
    }

    /// 쪽지에 쓰는 운세(한 줄 또는 두 줄)와 행운의 행동. 범위 밖이면 nil.
    static func text(_ d: PlazaFortuneDraw) -> (line: String, action: String)? {
        guard let d = accepted(d) else { return nil }
        return (lines[d.line], L(.ko).plazaFortuneAction(actions[d.action]))
    }

    // 쪽지가 뜨는 흐름(초). 처음 깰 때: 쿠키가 떠올라 흔들리다 갈라지고 쪽지가 펴진다. 다시 볼 때: 쪽지만 펴진다.
    static let wobbleStart: TimeInterval = 0.4
    static let splitStart: TimeInterval = 1.1
    static let splitStepDuration: TimeInterval = 0.09
    static let readDuration: TimeInterval = 6

    /// 오늘의 운세. 쪽지는 힘든 하루에 기운을 내려고 뽑는다(2026-11-26 사용자). 기준은 하나다: 일하다 지친 사람이 읽고 기분이
    /// 조금 나아지는가. 좋은 일의 예고, 읽는 사람에 대한 좋은 말, 애쓴 것이 보답받는다는 약속, 약속이 되는 속담("고생 끝에 낙이 와요")을
    /// 쓴다. 쓰지 않는 것: 가르치는 속담과 교훈("급할수록 돌아가요"), 약속 없는 지시("~해 보세요"), 특정 사건을 그대로 맞히는 예언
    /// ("무지개를 보게 될 운이에요"), 말장난과 쿠키가 제 이야기를 하는 문구, 밋밋한 덕담, 압박이나 비꼼으로 읽힐 말, 잡무 예고·생활 요령·
    /// 개발과 업무 용어·광장과 앱 이야기(`PlazaFortuneTests` 가 낱말과 한 줄 지시형을 막는다). 수를 채우려고 약한 문구를 넣지 않는다.
    /// 한 줄이거나 줄바꿈으로 나눈 두 줄이고, 각 줄이 쪽지 한 줄(`PlazaFortuneArt.maxTextWidth`)에 들어가야 한다(테스트가 확인한다).
    /// 번호가 곧 팀원에게 보내는 값이라, 새 문구는 끝에만 더한다. 문구는 두 번 고쳐 썼다(2.5.642 다음 버전에서 300줄 전부, 2.5.645 다음
    /// 버전에서 115줄): 그보다 옛 버전의 팀원은 같은 번호에서 그 버전의 문구를 본다.
    static let lines: [String] = L(.ko).plazaFortuneLines

    /// 행운의 행동. 모두 광장에서 바로 할 수 있는 일이다. 새 행동도 끝에만 더한다.
    static let actions: [String] = L(.ko).plazaFortuneActions
}
