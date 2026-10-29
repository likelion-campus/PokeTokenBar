import XCTest
import CryptoKit
@testable import PokeTokenBar

final class TeamCodeTests: XCTestCase {
    func testGeneratedCodeRoundTripsThroughDisplayForm() {
        var rng = SeededRNG(seed: 7)
        let code = TeamCode.generate(using: &rng)
        XCTAssertEqual(code.normalized.count, 26)
        XCTAssertTrue(code.display.hasPrefix("PTB-"))
        XCTAssertEqual(code.display.split(separator: "-").map(\.count), [3, 5, 5, 5, 5, 6])
        XCTAssertEqual(TeamCode(parsing: code.display), code)
        XCTAssertEqual(TeamCode(parsing: "  " + code.normalized.lowercased() + "\n"), code)
        XCTAssertEqual(TeamCode(parsing: code.display.replacingOccurrences(of: "-", with: " ")), code)
    }

    func testParsingRejectsShortOrNonBase32() {
        XCTAssertNil(TeamCode(parsing: "PTB-ABCDE"))
        XCTAssertNil(TeamCode(parsing: String(repeating: "1", count: 26)))
        XCTAssertNil(TeamCode(parsing: String(repeating: "A", count: 27)))
    }

    func testLastCharacterPaddingBitsAreZero() {
        var rng = SeededRNG(seed: 99)
        for _ in 0..<50 {
            let code = TeamCode.generate(using: &rng)
            let last = code.normalized.last!
            XCTAssertTrue("AEIMQUY4".contains(last), "\(last)")
        }
    }

    func testSameCodeSameKeyDifferentCodeDifferentKey() {
        var rng = SeededRNG(seed: 1)
        let a = TeamCode.generate(using: &rng)
        let b = TeamCode.generate(using: &rng)
        let bytes = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(bytes(a.pskKey), bytes(TeamCode(parsing: a.display)!.pskKey))
        XCTAssertNotEqual(bytes(a.pskKey), bytes(b.pskKey))
        XCTAssertEqual(TeamCode.pskIdentity, Data("ptb-team-v1".utf8))
    }
}
