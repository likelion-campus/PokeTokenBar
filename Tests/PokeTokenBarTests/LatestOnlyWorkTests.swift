import Foundation
import XCTest
@testable import PokeTokenBar

/// The Settings counts' queue (stage 7 Task 14 review): a blocked request (a share that does not answer) holds the one queue
/// thread; requests that came in meanwhile are replaced by the newest per key; never two at once.
final class LatestOnlyWorkTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var order: [String] = []
        private(set) var mostAtOnce = 0
        func begin(_ name: String) {
            lock.lock(); order.append(name); running += 1; mostAtOnce = max(mostAtOnce, running); lock.unlock()
        }
        func end() { lock.lock(); running -= 1; lock.unlock() }
        var snapshot: (order: [String], mostAtOnce: Int) { lock.lock(); defer { lock.unlock() }; return (order, mostAtOnce) }
    }

    private func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    func testABlockedRequestHoldsTheOnlyThreadAndTheNewestWins() {
        let work = LatestOnlyWork(label: "ptb.test.latest-only")
        let trace = Trace()
        let gate = DispatchSemaphore(value: 0)
        work.submit(key: "scan", after: 0) { trace.begin("scan1"); gate.wait(); trace.end() }   // a dead share
        XCTAssertTrue(wait(2) { trace.snapshot.order == ["scan1"] })
        for i in 2...4 { work.submit(key: "scan", after: 0) { trace.begin("scan\(i)"); trace.end() } }
        work.submit(key: "found", after: 0) { trace.begin("found1"); trace.end() }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(trace.snapshot.order, ["scan1"], "nothing else runs while the first one is blocked")
        gate.signal()
        XCTAssertTrue(wait(2) { trace.snapshot.order.count == 3 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(trace.snapshot.order, ["scan1", "scan4", "found1"], "the replaced requests never ran; the other key's did")
        XCTAssertEqual(trace.snapshot.mostAtOnce, 1)
    }

    func testTheDelayLetsANewerRequestReplaceTheOlderAndCancelDropsIt() {
        let work = LatestOnlyWork(label: "ptb.test.latest-only.delay")
        let trace = Trace()
        work.submit(key: "k", after: 0.2) { trace.begin("old"); trace.end() }
        work.submit(key: "k", after: 0.2) { trace.begin("new"); trace.end() }
        XCTAssertTrue(wait(2) { trace.snapshot.order == ["new"] })
        work.submit(key: "k", after: 0.2) { trace.begin("dropped"); trace.end() }
        work.cancel(key: "k")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(trace.snapshot.order, ["new"])
    }
}
