import XCTest
import Observation
@testable import PokeTokenBar
import AppKit
import SpriteKit
import SwiftUI
import CoreGraphics

extension DisplayLocaleTests {
    func testRelativeTimeFollowsAppLanguageNotSystem() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-3 * 3600)

        func relative(_ lang: AppLanguage) -> String {
            let f = RelativeDateTimeFormatter()
            f.locale = lang.displayLocale
            return f.localizedString(for: past, relativeTo: now)
        }

        XCTAssertTrue(relative(.en).contains("hour"), "영어: \(relative(.en))")
        XCTAssertTrue(relative(.ko).contains("시간"), "한국어: \(relative(.ko))")
        XCTAssertTrue(relative(.ja).contains("時間"), "일본어: \(relative(.ja))")
        XCTAssertTrue(relative(.de).lowercased().contains("stund"), "독일어: \(relative(.de))")
        XCTAssertTrue(relative(.ru).contains("час"), "러시아어: \(relative(.ru))")
        // 다섯 언어가 서로 달라야 한다 — 하나로 고정돼 있으면 매핑이 죽은 것이다.
        XCTAssertEqual(Set([relative(.en), relative(.ko), relative(.ja), relative(.de), relative(.ru)]).count, 5)
    }
}
