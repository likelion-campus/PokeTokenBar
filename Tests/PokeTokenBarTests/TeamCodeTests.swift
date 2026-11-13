import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import PokeTokenBar

final class TeamCodeTests: XCTestCase {
    func testGeneratedCodeRoundTripsThroughDisplayForm() {
        var rng = SeededRNG(seed: 7)
        let code = TeamCode.generate(using: &rng)
        XCTAssertEqual(code.normalized.count, 12)
        XCTAssertTrue(code.display.hasPrefix("PTB-"))
        XCTAssertEqual(code.display.split(separator: "-").map(\.count), [3, 4, 4, 4])
        XCTAssertEqual(TeamCode(parsing: code.display), code)
        XCTAssertEqual(TeamCode(parsing: "  " + code.normalized.lowercased() + "\n"), code)
        XCTAssertEqual(TeamCode(parsing: code.display.replacingOccurrences(of: "-", with: " ")), code)
    }

    func testParsingRejectsShortOrNonBase32() {
        XCTAssertNil(TeamCode(parsing: "PTB-ABCDE"))
        XCTAssertNil(TeamCode(parsing: String(repeating: "1", count: 12)))
        XCTAssertNil(TeamCode(parsing: String(repeating: "1", count: 26)))
        for count in [11, 13, 25, 27] {
            XCTAssertNil(TeamCode(parsing: String(repeating: "A", count: count)), "\(count)")
        }
    }

    /// Codes made by v2.5.601 stay valid after the update and keep deriving the same key.
    func testLegacyCodeStillWorks() throws {
        let legacy = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let code = try XCTUnwrap(TeamCode(parsing: "ptb-abcde-fghij-klmno-pqrst-uvwxyz"))
        XCTAssertEqual(code.normalized, legacy)
        XCTAssertEqual(code.display, "PTB-ABCDE-FGHIJ-KLMNO-PQRST-UVWXYZ")
        let expected = HMAC<SHA256>.authenticationCode(for: Data("poketokenbar.team.psk.v1".utf8),
                                                       using: SymmetricKey(data: Data(legacy.utf8)))
        XCTAssertEqual(code.pskKey.withUnsafeBytes { Data($0) }, Data(expected))
    }

    func testGeneratedCodesUseAllSixtyBits() {
        var rng = SeededRNG(seed: 99)
        var seen = Set<Character>()
        for _ in 0..<200 { seen.formUnion(TeamCode.generate(using: &rng).normalized) }
        XCTAssertEqual(seen.count, 32, "every base32 character appears")
        var first = Set<Character>()
        for _ in 0..<200 { first.insert(TeamCode.generate(using: &rng).normalized.first!) }
        XCTAssertGreaterThan(first.count, 16, "the top bits vary too")
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
