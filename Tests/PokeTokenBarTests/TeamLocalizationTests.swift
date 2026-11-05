import XCTest
@testable import PokeTokenBar

final class TeamLocalizationTests: XCTestCase {
    func testTeamSourcesHaveNoHangulLiterals() throws {
        let team = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/Team")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: team, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator
        where url.pathExtension == "swift" && url.lastPathComponent != "TeamLocalization.swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where LocalizedUILiteralTests.hasHangulStringLiteral(line) {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 0)
        XCTAssertTrue(offenders.isEmpty, "Move Hangul literals into TeamLocalization.swift: \(offenders.joined(separator: ", "))")
    }

    func testPlazaStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.plazaOpen, "광장 열기"); XCTAssertEqual(l.plazaWindowTitle, "팀 광장")
    }
}

final class PlazaPhotoTextTests: XCTestCase {
    func testPhotoModeStrings() {
        XCTAssertEqual(L(.ko).plazaPhotoGuide, "📷 사진 모드 · 방향키 이동 · Shift 빠르게 · −/+ 확대 · Space 찍기 · G 단체 사진 · Esc 나가기")
        XCTAssertEqual(L(.ko).plazaPhotoCopied, "사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기")
    }

    func testGroupPhotoCountdownStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: nil, seconds: 3, joined: true, frontmost: true), "단체 사진 3 · 모두 모여요!")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: nil, seconds: 3, joined: false, frontmost: true), "단체 사진 3 · P를 누르면 함께 찍어요")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: "민수", seconds: 3, joined: true, frontmost: true), "민수님의 단체 사진 3 · 함께 찍는 중")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: "민수", seconds: 3, joined: false, frontmost: true), "민수님의 단체 사진 3 · P를 누르면 함께 찍어요")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: nil, seconds: 3, joined: true, frontmost: false), "단체 사진 3 · 광장 창을 앞에 두면 함께 찍혀요")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: "민수", seconds: 3, joined: true, frontmost: false), "민수님의 단체 사진 3 · 광장 창을 앞에 두면 함께 찍혀요")
        XCTAssertEqual(l.plazaGroupPhotoCountdown(starter: "민수", seconds: 3, joined: false, frontmost: false), "민수님의 단체 사진 3 · P를 누르면 함께 찍어요")
    }
}
