import XCTest
@testable import PokeTokenBar

private struct EmptyFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

private struct BoardProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [1: ["en": "P1", "ko": "포1"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: 1, captureRate: 255)] }
}

/// 배너 타이머를 시계 대신 손으로 푼다.
@MainActor
private final class SleepGate {
    private(set) var durations: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>?] = []

    func sleep(_ d: Duration) async {
        durations.append(d)
        await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ index: Int) {
        waiting[index]?.resume()
        waiting[index] = nil
    }

    func releaseAll() { for i in waiting.indices { release(i) } }
}

private let spaceKey: UInt16 = 49, escKey: UInt16 = 53

private func event(_ id: String = "e1", author: String = "a", nick: String = "민수", kind: TeamEventKind = .hatch,
                   species: String = "깨봉이", from: String? = nil, shiny: Bool = false,
                   day: String = "2026-10-30", at: Date? = nil) -> TeamEvent {
    TeamEvent(id: id, authorID: author, authorNickname: nick, kind: kind, speciesID: 25, fromSpeciesID: from == nil ? nil : 24,
              speciesName: species, fromSpeciesName: from, form: nil, isShiny: shiny, nature: nil, rarity: .common,
              day: day, occurredAt: at)
}

final class PlazaBoardTextTests: XCTestCase {
    private let l = L(.ko)

    func testEventTextPerKind() async {
        XCTAssertEqual(l.teamEventText(event()), "민수의 알에서 깨봉이가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(shiny: true)), "민수의 알에서 이로치 깨봉이가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .dittoReveal)), "민수의 포켓몬은 사실 메타몽이었어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .graduate)), "민수의 깨봉이가 졸업했어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "딱충이", from: "깨봉이")), "민수의 깨봉이가 딱충이로 진화했어요")
    }

    func testEventTextParticlesFollowFinalConsonant() async {
        // 받침 있음: 이 / 으로, 받침 없음: 가 / 로, ㄹ 받침: 로
        XCTAssertEqual(l.teamEventText(event(species: "피카츄")), "민수의 알에서 피카츄가 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(species: "꼬렛")), "민수의 알에서 꼬렛이 나왔어요!")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "리자드", from: "파이리")), "민수의 파이리가 리자드로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "리자몽", from: "리자드")), "민수의 리자드가 리자몽으로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "이상해꽃", from: "이상해풀")), "민수의 이상해풀이 이상해꽃으로 진화했어요")
        XCTAssertEqual(l.teamEventText(event(kind: .evolve, species: "알", from: "삐")), "민수의 삐가 알로 진화했어요")
    }

    func testEventTextHasNoUsageNumbers() async {
        for kind in [TeamEventKind.hatch, .evolve, .graduate, .dittoReveal] {
            let text = l.teamEventText(event(kind: kind, from: "깨봉이", shiny: true))
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "\(kind): \(text)")
        }
    }
}
