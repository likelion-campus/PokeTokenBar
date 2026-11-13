import XCTest
@testable import PokeTokenBar

/// The glob rules `CustomScanRoots` relies on, held to the same answers on every OS.
final class PlatformGlobTests: XCTestCase {
    static let cases: [(pattern: String, name: String, matches: Bool)] = [
        ("*", "abc", true), ("*", "", true), ("*", ".hidden", true),
        ("inst*", "instances", true), ("inst*", "xinstances", false),
        ("*s", "instances", true), ("*s", "instance", false),
        ("a*c", "abc", true), ("a*c", "ac", true), ("a*c", "abd", false),
        ("a*b*c", "aXXbYYc", true), ("a*b*c", "aXXbYY", false),
        ("?", "a", true), ("?", "", false), ("?", "ab", false), ("a?c", "abc", true), ("a?c", "ac", false),
        ("[ab]c", "ac", true), ("[ab]c", "cc", false), ("[a-c]x", "bx", true), ("[a-c]x", "dx", false),
        ("[!a]x", "bx", true), ("[!a]x", "ax", false), ("[^a]x", "bx", true), ("[^a]x", "ax", false),
        ("[]a]x", "]x", true), ("[a", "[a", false), ("[a", "a", false),
        ("\\*", "*", true), ("\\*", "a", false), ("a\\?", "a?", true),
        ("instance-[0-9]", "instance-7", true), ("instance-[0-9]", "instance-x", false),
        ("projects", "projects", true), ("projects", "project", false), ("", "", true), ("", "a", false),
        ("Ünï*", "Ünïcode", true),
    ]

    func testPinnedCases() {
        for c in Self.cases {
            XCTAssertEqual(PlatformCompat.matchesGlob(c.pattern, c.name), c.matches, "\(c.pattern) vs \(c.name)")
            XCTAssertEqual(PlatformCompat.globMatch(c.pattern, c.name), c.matches, "globMatch \(c.pattern) vs \(c.name)")
        }
    }
}
