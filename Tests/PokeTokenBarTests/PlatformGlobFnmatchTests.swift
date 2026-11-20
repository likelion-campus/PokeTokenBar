import XCTest
@testable import PokeTokenBar

/// The Swift matcher Windows uses must agree with the C `fnmatch` the Mac calls, on the pinned cases and a sweep.
final class PlatformGlobFnmatchTests: XCTestCase {
    func testGlobMatchAgreesWithFnmatchOnThePinnedCases() {
        for c in PlatformGlobTests.cases {
            XCTAssertEqual(PlatformCompat.globMatch(c.pattern, c.name), fnmatch(c.pattern, c.name, 0) == 0, "\(c.pattern) vs \(c.name)")
        }
    }

    func testGlobMatchAgreesWithFnmatchOverGeneratedPatterns() {
        let alphabet = ["a", "b", "*", "?", "[", "]", "!", "-"]
        let names = ["", "a", "b", "ab", "ba", "aab", "a.b", "[", "a-b", "!", "]"]
        func patterns(_ n: Int) -> [String] {
            n == 0 ? [""] : patterns(n - 1).flatMap { p in alphabet.map { p + $0 } }
        }
        for p in (0...4).flatMap(patterns) {
            for name in names {
                XCTAssertEqual(PlatformCompat.globMatch(p, name), fnmatch(p, name, 0) == 0, "\(p) vs \(name)")
            }
        }
    }
}
