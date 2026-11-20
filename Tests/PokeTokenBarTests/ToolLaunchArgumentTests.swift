import XCTest
@testable import PokeTokenBar

/// F19: a tool that resolves to an npm `.cmd` shim is run by cmd.exe, which interprets `& | < > ^ % !`.
/// Rule: a launched tool gets only fixed, code-defined arguments free of those characters. Free-form text (paths,
/// user input) is never passed through a batch shim; a call that needs it resolves the shim's target `.exe` or
/// escapes for `cmd.exe /d /s /c` in the same change.
final class ToolLaunchArgumentTests: XCTestCase {
    func testBatchSafetyRejectsCmdMetacharacters() {
        for bad in ["a&b", "a|b", "a<b", "a>b", "a^b", "100%", "!x", "a\nb", "a\r"] {
            XCTAssertFalse(PlatformCompat.isBatchSafe(bad), bad)
        }
        for good in ["app-server", "--stdio", "list", "--cask", "has space", "quo\"te", "C:\\x\\y", "/a/b", ""] {
            XCTAssertTrue(PlatformCompat.isBatchSafe(good), good)
        }
    }
}
