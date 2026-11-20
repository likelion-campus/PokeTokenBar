import XCTest
@testable import PokeTokenBar

/// Both systems pin the same bytes. The constants were computed on the Mac with CryptoKit
/// (HMAC<SHA256>, key = the normalized code's UTF-8, message = "poketokenbar.team.psk.v1") and cross-checked with
/// Python's hmac module. A change here is a wire break: Macs and PCs would stop joining the same team.
final class TeamWireKnownAnswerTests: XCTestCase {
    private func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    func testPSKBytesMatchAKnownAnswer() throws {
        let code = try XCTUnwrap(TeamCode(parsing: "PTB-AAAA-BBBB-CCCC"))
        XCTAssertEqual(code.normalized, "AAAABBBBCCCC")
        let key = code.pskKey.withUnsafeBytes { hex($0) }
        XCTAssertEqual(key, "52d70b32eed4a929129c8c078c13eb57fe4441ac765420cda79001225c716c85")
        XCTAssertEqual(String(decoding: TeamCode.pskIdentity, as: UTF8.self), "ptb-team-v1")
    }

    func testFrameBytesMatchAKnownAnswer() throws {
        // 4-byte big-endian length (21) + {"profileRequest":{}}
        XCTAssertEqual(hex(try TeamWire.encode(.profileRequest)), "000000157b2270726f66696c6552657175657374223a7b7d7d")
    }
}
