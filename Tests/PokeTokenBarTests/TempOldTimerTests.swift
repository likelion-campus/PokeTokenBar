import XCTest

@MainActor
final class TempOldTimerTests: XCTestCase {
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    func testOldConstructorFirstFiresAfterTheInterval() async {
        var fired = false
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in fired = true }
        RunLoop.main.add(t, forMode: .common)
        let end = Date().addingTimeInterval(0.2)
        while Date() < end {
            spin()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        t.invalidate()
        XCTAssertFalse(fired, "old constructor fired at once")
    }
}
