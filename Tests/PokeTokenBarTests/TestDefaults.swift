import XCTest

/// The only place in `Tests/` allowed to create a `UserDefaults` suite.
///
/// Every suite writes a `<suite>.plist` into `~/Library/Preferences`, and the cfprefsd agent keeps
/// directory handles open while it does. `removePersistentDomain(forName:)` does not help: it empties the
/// domain but leaves a ~50-byte plist behind. A UUID-named suite per test therefore piles up hundreds of
/// thousands of files and can wedge cfprefsd for the whole login session.
///
/// cfprefsd writes dirty domains a few seconds *after* the last change, and writes them again if the file
/// is deleted before that. So deleting right after a test (or at process exit) does not stick. When the
/// bundle finishes this deletes every plist it created, then keeps sweeping until cfprefsd's delayed
/// writes have landed and been deleted too. That costs a few seconds once per `swift test` run.
/// `TestDefaultsScanTests` fails if any other file calls the raw initializer.
final class TestDefaults: NSObject, XCTestObservation, @unchecked Sendable {
    private static let shared = TestDefaults()
    private let lock = NSLock()
    private var opened: [String: UserDefaults] = [:]
    private var observing = false

    /// Opens `suite` like `UserDefaults(suiteName:)` would and schedules its cleanup. Calling it again
    /// with the same name (to re-open a store) is fine.
    static func make(suite: String) -> UserDefaults {
        shared.open(suite)
    }

    private func open(_ suite: String) -> UserDefaults {
        lock.lock()
        let defaults = opened[suite] ?? UserDefaults(suiteName: suite)!
        opened[suite] = defaults
        let needsObserver = !observing
        observing = true
        lock.unlock()
        if needsObserver { XCTestObservationCenter.shared.addTestObserver(self) }
        return defaults
    }

    /// Deletes the plists that exist right now and returns how many there were.
    private func sweep() -> Int {
        lock.lock()
        let all = opened
        lock.unlock()
        let dir = NSHomeDirectory() + "/Library/Preferences"
        var removed = 0
        for (name, defaults) in all {
            defaults.synchronize()
            if (try? FileManager.default.removeItem(atPath: "\(dir)/\(name).plist")) != nil { removed += 1 }
        }
        return removed
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let start = Date()
        var lastRemoval = start
        // Delayed writes land in batches a few seconds after the last change, so keep sweeping until at
        // least 10 s have passed and the last 4 s found nothing new (hard stop at 25 s).
        while Date().timeIntervalSince(start) < 25 {
            if sweep() > 0 { lastRemoval = Date() }
            if Date().timeIntervalSince(start) >= 10, Date().timeIntervalSince(lastRemoval) >= 4 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
