import XCTest
@testable import PokeTokenBar

final class WakeTraceTests: XCTestCase {
    /// A message can carry any 64-bit word (the shell's file dialog posts one at or above 2^63); `Int(wParam)` trapped there
    /// (exit 0xC000041D, #270). `message` takes the unsigned word, so the trigger values are accepted as they are.
    func testMessageAcceptsAnyWParamBits() {
        for w in [UInt.max, UInt(Int.max) + 1, 0, 1] {
            WakeTrace.message(0x0113, wParam: w, target: "t")
            WakeTrace.message(0x0118, wParam: w, target: "t")
        }
        XCTAssertTrue(WakeTrace.snapshot("t", loops: 0).hasPrefix("wake trace t: loops=0"))
    }
}
